"""레이어 혼합비 피팅: 엔진 레이어를 하나씩 렌더해 레퍼런스 스펙트럼에 맞춘다.

사용법:
    python tools/fit_reference.py <rain|train|fire> [--wav reference/<장면>_ref.wav] [--profile src/profiles/<장면>.json]

독립 음원의 파워는 더해지므로, 1/3옥타브 대역 파워에서
    레퍼런스 ≈ Σ wᵢ · 레이어ᵢ   (wᵢ ≥ 0, 레이어 레벨 = √wᵢ)
를 대역별 상대 오차 기준 NNLS로 푼다. 로우패스 컷오프는 후보마다 같은 피팅을 반복해
잔차가 가장 작은 값을 고른다.

스펙트럼만 맞추면 사건(빗방울·덜컹·타닥) 에너지가 드문 큰 사건에 몰려 타격감이 어긋나므로,
2단계로 사건 레이어의 파워를 α배로 고정하고 나머지를 다시 NNLS로 풀면서
렌더 결과의 HPSS 타격 성분 비율이 레퍼런스와 같아지는 α를 이분 탐색한다.
마지막으로 렌더 RMS가 TARGET_RMS가 되도록 전체 레벨을 맞춘다. 결과는 프로파일의 "fit" 블록에 저장되고
src/scene_model.js가 휴리스틱 대신 이 값을 쓴다.
"""
import argparse
import json
import sys
import subprocess
import tempfile
from pathlib import Path

import librosa
import numpy as np
from scipy.optimize import nnls
from scipy.signal import welch

ROOT = Path(__file__).resolve().parent.parent
# 장면별 피팅 레이어 (이름 = scene_model.js의 키, 엔진 파라미터 id).
#   event: 2단계에서 타격 성분 비율로 맞추는 사건 레이어, hits: 타격음 버스(버스 LP)를 지나는 레이어,
#   pitches/pitch_id: 사건 공진 주파수 배수의 격자 후보와 그 파라미터
SCENES = {
    "rain":  {"layers": [("pink", 2), ("brown", 3), ("deep", 4), ("dropLevel", 12), ("pitLevel", 25)],
              "event": 12, "hits": (12, 25), "pitches": (0.5, 0.63, 0.8, 1.0), "pitch_id": "27"},
    "train": {"layers": [("pink", 2), ("brown", 3), ("deep", 4), ("clackLevel", 29)],
              "event": 29, "hits": (29,), "pitches": (1.0,), "pitch_id": "33"},
    "fire":  {"layers": [("white", 1), ("pink", 2), ("brown", 3), ("deep", 4), ("crackleLevel", 34)],
              "event": 34, "hits": (34,), "pitches": (1.0,), "pitch_id": "27"},
}
LAYERS, DROP, HITS, SCENE = [], 0, (), "rain"      # fit()이 장면에 맞게 채운다
EDGES = 20 * 2 ** (np.arange(0, 30) / 3)            # 20 Hz – 약 10 kHz, 1/3옥타브
EDGES = EDGES[EDGES < 16000]
RENDER_S = 20
TARGET_RMS = 0.12        # 마스터 볼륨 60% 기준 출력 RMS
CENTERS = np.sqrt(EDGES[:-1] * EDGES[1:])
# 청감 가중: 귀가 가장 예민한 2–6 kHz(최대 3.5 kHz 부근)를 최대 3배로 본다
EAR = 1 + 2 * np.exp(-np.log2(CENTERS / 3500) ** 2 / (2 * 0.9 ** 2))
OVER = 2.0               # 2 kHz 이상에서 레퍼런스보다 '많은' 쪽 오차 배수(밝음 과잉 = 귀 피로)


def bands(f, pxx):
    return np.array([pxx[(f >= lo) & (f < hi)].sum() for lo, hi in zip(EDGES[:-1], EDGES[1:])])


def band_power(y, sr):
    return bands(*welch(y, fs=sr, nperseg=8192))


MASTER = 1.5 * 0.6 ** 2   # tools/render_scene.cjs의 마스터(볼륨 60%)
FIT_GAIN = 0.1


def tone_gain(f, sr, lp, q, slope, air, hit=False):
    """엔진 톤 체인(LP → 2단 LP 크로스페이드 → Air 셸프)의 |H(f)|².
    TPT SVF는 컷오프에서 사전 왜곡한 쌍선형 변환과 같아서 응답을 해석적으로 계산할 수 있다(engine.wat와 같은 식).
    hit: 타격음 레이어(사건·잔빗소리)는 같은 컷오프의 버스 LP(Q 0.707)를 한 번 더 거친다."""
    def svf_lp(fc, qq):
        fc = min(fc, 0.45 * sr)
        x = np.tan(np.pi * f / sr) / np.tan(np.pi * fc / sr)
        return 1 / (1 - x ** 2 + 1j * x / qq)
    h = svf_lp(lp, q) / np.sqrt(max(1, q * np.sqrt(2)))           # $qcomp
    h = h * ((1 - slope) + slope * svf_lp(lp, 0.707))
    if hit:
        h = h * svf_lp(lp, 0.707)
    c = min(1, 2 * np.pi * 2500 / sr)
    a = c / (1 - (1 - c) * np.exp(-2j * np.pi * f / sr))           # Air의 1차 LP
    return np.abs(h * ((1 + air) - air * a)) ** 2


def render_y(params, tmp):
    pj, wav = Path(tmp) / "p.json", Path(tmp) / "r.wav"
    pj.write_text(json.dumps(params))
    subprocess.run(["node", str(ROOT / "tools/render_scene.cjs"), SCENE, str(RENDER_S), str(wav), str(pj)],
                   check=True, capture_output=True)
    y, sr = librosa.load(wav, sr=None, mono=True)
    return y[sr:], sr                                # 첫 1초(스무딩·페이드) 제외


def render(params, tmp):
    return band_power(*render_y(params, tmp))


def percussive_ratio(y):
    H, P = librosa.decompose.hpss(librosa.stft(y, n_fft=2048, hop_length=512), margin=2.0)
    p, h = (np.abs(P) ** 2).sum(), (np.abs(H) ** 2).sum()
    return p / (p + h)


def fit(scene, ref_wav, profile_path):
    global LAYERS, DROP, HITS, SCENE
    cfg = SCENES[scene]
    SCENE, LAYERS, HITS = scene, cfg["layers"], cfg["hits"]
    DROP = [pid for _, pid in LAYERS].index(cfg["event"])
    PITCHES, PID = cfg["pitches"], cfg["pitch_id"]
    y, sr = librosa.load(ref_wav, sr=None, mono=True)
    ref = band_power(y, sr)
    ref_n = ref / ref.sum()
    prof = json.loads(Path(profile_path).read_text(encoding="utf-8"))
    # 이전 피팅 결과(특히 음높이 배수)가 렌더러의 기본값에 섞이지 않게 지우고 시작한다
    prof.pop("fit", None)
    Path(profile_path).write_text(json.dumps(prof, ensure_ascii=False, indent=2), encoding="utf-8")
    roll = prof["analysis"]["spectral"]["rolloff85_hz_median"]

    W = EAR / (ref_n + 1e-6)                         # 대역별 상대 오차 × 청감 가중
    others = [i for i in range(len(LAYERS)) if i != DROP]
    target = prof["analysis"]["transient"]["percussive_ratio"]

    def err_db(A, w):
        """청감 가중 대역 RMS 오차(dB). 2 kHz 이상의 과잉은 OVER배로 본다."""
        d = 10 * np.log10((A @ w + 1e-12) / ref_n)
        d = np.where((d > 0) & (CENTERS >= 2000), d * OVER, d)
        return float(np.sqrt(np.sum(EAR * d ** 2) / EAR.sum()))

    def solve(A, wd):
        """방울 파워 가중치를 wd로 고정하고 나머지 레이어를 NNLS로 푼다."""
        w = np.zeros(len(LAYERS))
        w[DROP] = wd
        wo, _ = nnls(A[:, others] * W[:, None], (ref_n - A[:, DROP] * wd) * W)
        w[others] = wo
        return w

    with tempfile.TemporaryDirectory() as tmp:
        off = {str(i): 0 for _, i in LAYERS}
        # 스웰은 끄고, 하이패스는 src/scene_model.js와 같은 규칙(누적 에너지 1% 지점)으로 건다.
        # 저역이 비어 있는 레퍼런스에서 하이패스 없이 맞추면 그 대역 상대 오차 때문에 베드가 0으로 풀린다.
        c1 = prof["analysis"]["spectral"]["cumulative_1pct_hz"]
        off.update({"10": 0, "16": min(400, c1) if c1 >= 25 else 0})
        # 피팅용 렌더는 마스터를 1/10로 낮춰 출력 리미터가 개입하지 않는 선형 구간에서 잰다
        # (레이어를 레벨 1로 따로 렌더하면 피크가 커서 리미터가 레이어 파워를 깎는다).
        off["0"] = MASTER * FIT_GAIN

        def params(lp, w, scale=1.0):
            return {**off, "7": lp[0], "15": lp[1], "28": lp[2], "8": lp[3], PID: lp[4], "5": lp[5], **{str(pid): float(np.sqrt(v) * scale) for (_, pid), v in zip(LAYERS, w)}}

        # 1단계: 톤 (LP 컷오프, Q, 기울기, Air 셸프)과 방울 음높이 배수의 격자 탐색.
        #   레이어는 톤 필터를 끈 채(LP 20 kHz) 음높이 후보별로 한 번씩만 렌더하고, 필터는 해석적
        #   응답을 곱해 적용한다(선형 체인이라 같음). 베드 레이어는 음높이와 무관해 한 번만 렌더한다.
        #   Q를 올리면 컷오프 부근이 볼록해지고, 기울기 1(24 dB/oct)이면 그 위가 더 가파르게 떨어진다.
        #   Air < 0은 2.5 kHz 위를 낮추는 셸프. 음높이 배수는 '톡'·'툭'·잔빗소리 공진 주파수를 함께 옮긴다
        #   (타격 순간의 스펙트럼 중심은 넓은 대역 타격음의 공진 피크보다 높게 나오기 쉽다).
        flat = {"7": 20000, "15": 0.707, "28": 0, "8": 0}

        def psd(over, hit):
            yy, srr = render_y({**off, **flat, **over}, tmp)
            f, pxx = welch(yy, fs=srr, nperseg=8192)
            return f, pxx / tone_gain(f, srr, 20000, 0.707, 0, 0, hit), srr

        #   딥 서브베이스는 중심 주파수(SUBS) 후보마다 렌더한다: 저음 덩어리가 45 Hz가 아니라 80 Hz 부근인
        #   레퍼런스(장작 불의 울림, 객실 주행음)는 서브 중심을 옮겨야 그 대역이 채워진다.
        SUBS = (35, 50, 70, 100)
        layer_psd = {}
        for n, pid in LAYERS:
            for pt in (PITCHES if pid in HITS else SUBS if pid == 4 else (None,)):
                layer_psd[(pid, pt)] = psd({str(pid): 1, PID: pt if pid in HITS else 1, "5": pt if pid == 4 else 45}, pid in HITS)

        def key(pid, lp):
            return lp[4] if pid in HITS else lp[5] if pid == 4 else None
        fr, _, srr = layer_psd[(LAYERS[0][1], None)]
        #   컷오프 후보: 롤오프의 배수 + 고정 격자(초저역이 롤오프를 끌어내린 레퍼런스에서도 고역 사건을 담을 수 있게)
        cutoffs = sorted({min(20000, roll * k) for k in (1.0, 1.3, 1.7, 2.2, 3.0, 4.0, 5.5, 8.0)}
                         | {300, 600, 1000, 2000, 3500, 5000, 6000, 7000, 8500, 12000, 16000})
        bases = {}
        # 대역 합산은 행렬곱으로(격자가 커서 마스크 반복은 느리다)
        M = np.array([(fr >= lo) & (fr < hi) for lo, hi in zip(EDGES[:-1], EDGES[1:])], dtype=float)
        for c in cutoffs:
            for q in (0.707, 1.0, 1.4):
                for sl in (0, 0.5, 1):
                    for air in (0.3, 0, -0.3, -0.5, -0.7):
                        g = {h: tone_gain(fr, srr, c, q, sl, air, h) for h in (False, True)}
                        for pt in PITCHES:
                            for sub in SUBS:
                                lp = (c, q, sl, air, pt, sub)
                                bases[lp] = np.array([M @ (layer_psd[(pid, key(pid, lp))][1] * g[pid in HITS])
                                                      for _, pid in LAYERS]).T / ref.sum()
        free = {k: err_db(A, nnls(A * W[:, None], ref_n * W)[0]) for k, A in bases.items()}
        for k in sorted(free, key=free.get)[:5]:
            w = nnls(bases[k] * W[:, None], ref_n * W)[0]
            print(f"  LP {k[0]:7.0f} Hz Q {k[1]:.2f} {12 + 12 * k[2]:.0f} dB/oct Air {k[3]:+.1f} 음높이 ×{k[4]:.2f} 서브 {k[5]} Hz → 오차 {free[k]:5.2f} dB, 레벨 "
                  + ", ".join(f"{n} {np.sqrt(v):.3f}" for (n, _), v in zip(LAYERS, w)))
        lp = min(free, key=free.get)
        w_free = nnls(bases[lp] * W[:, None], ref_n * W)[0]
        # 스펙트럼만으로는 사건 레이어가 0으로 풀릴 수 있다(타격음이 배경보다 훨씬 작은 레퍼런스) → 기준 파워를 잡아 둔다
        wd0 = max(w_free[DROP], 0.05 * w_free.sum())

        # 2단계: 사건 파워를 바꿔 가며 타격 성분 비율을 맞추고(로그 이분 탐색),
        #        그 방울 파워에서 로우패스를 다시 고른다. 두 번 번갈아 반복.
        for rnd in range(2):
            lo, hi = 0.005, 4.0
            for _ in range(9):
                alpha = np.sqrt(lo * hi)
                w = solve(bases[lp], alpha * wd0)
                pr = percussive_ratio(render_y(params(lp, w), tmp)[0])
                print(f"  [{rnd + 1}] LP {lp[0]:.0f} Hz Q {lp[1]:.2f} {12 + 12 * lp[2]:.0f} dB/oct Air {lp[3]:+.1f} 음높이 ×{lp[4]:.2f}, 사건 파워 ×{alpha:.3f} → 타격 성분 {pr:.3f} (목표 {target:.3f})")
                lo, hi = (alpha, hi) if pr < target else (lo, alpha)
            wd = alpha * wd0
            lp = min(bases, key=lambda k: err_db(bases[k], solve(bases[k], wd)))
        w = solve(bases[lp], wd)
        band_err = err_db(bases[lp], w)

        # 3단계: 출력 레벨 정규화(슬라이더 범위 0–1을 넘지 않게)
        #   여기서부터는 실제 마스터(렌더러 기본값)로 렌더한다. 피팅 렌더와 같은 출력이 되는 레벨은 √w × FIT_GAIN.
        del off["0"]
        y, _ = render_y(params(lp, w, FIT_GAIN), tmp)
        scale = FIT_GAIN * TARGET_RMS / float(np.sqrt(np.mean(y ** 2)))
        scale = min(scale, 1 / float(np.sqrt(w).max()))
        lv = np.sqrt(w) * scale
        y, _ = render_y(params(lp, w, scale), tmp)
    prof["fit"] = {"lpHz": round(lp[0], 1), "lpQ": lp[1], "lpSlope": lp[2], "air": lp[3], "pitch": lp[4], "subHz": lp[5], "band_rms_error_db": round(band_err, 2),
                   "percussive_ratio": round(float(percussive_ratio(y)), 3),
                   "render_rms": round(float(np.sqrt(np.mean(y ** 2))), 4),
                   "render_peak": round(float(np.abs(y).max()), 3),
                   **{n: round(float(v), 3) for (n, _), v in zip(LAYERS, lv)}}
    Path(profile_path).write_text(json.dumps(prof, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"저장: {profile_path} fit = {prof['fit']}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # Windows 콘솔(cp949)에서도 출력이 깨지지 않게
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scene", choices=SCENES)
    ap.add_argument("--wav", help="레퍼런스 WAV (기본 reference/<장면>_ref.wav)")
    ap.add_argument("--profile", help="프로파일 JSON (기본 src/profiles/<장면>.json)")
    a = ap.parse_args()
    fit(a.scene, a.wav or str(ROOT / f"reference/{a.scene}_ref.wav"), a.profile or str(ROOT / f"src/profiles/{a.scene}.json"))
