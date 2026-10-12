"""레이어 혼합비 피팅: 엔진 레이어를 하나씩 렌더해 레퍼런스 스펙트럼에 맞춘다.

사용법:
    python tools/fit_rain.py reference/rain_ref.wav [--profile src/rain_profile.json]

독립 음원의 파워는 더해지므로, 1/3옥타브 대역 파워에서
    레퍼런스 ≈ Σ wᵢ · 레이어ᵢ   (wᵢ ≥ 0, 레이어 레벨 = √wᵢ)
를 대역별 상대 오차 기준 NNLS로 푼다. 로우패스 컷오프는 후보마다 같은 피팅을 반복해
잔차가 가장 작은 값을 고른다.

스펙트럼만 맞추면 빗방울 에너지가 드문 큰 방울에 몰려 타격감이 과해지므로,
2단계로 방울 레이어의 파워를 α배로 고정하고 나머지를 다시 NNLS로 풀면서
렌더 결과의 HPSS 타격 성분 비율이 레퍼런스와 같아지는 α를 이분 탐색한다.
마지막으로 렌더 RMS가 TARGET_RMS가 되도록 전체 레벨을 맞춘다. 결과는 프로파일의 "fit" 블록에 저장되고
src/rain_model.js가 휴리스틱 대신 이 값을 쓴다.
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
# 엔진 파라미터 id: 2 pink, 3 brown, 4 deep, 12 방울, 25 잔빗소리, 7 LP 컷오프
LAYERS = [("pink", 2), ("brown", 3), ("deep", 4), ("dropLevel", 12), ("pitLevel", 25)]
EDGES = 20 * 2 ** (np.arange(0, 30) / 3)            # 20 Hz – 약 10 kHz, 1/3옥타브
EDGES = EDGES[EDGES < 16000]
RENDER_S = 20
DROP = 3                 # LAYERS에서 방울 레이어 위치
TARGET_RMS = 0.12        # 마스터 볼륨 60% 기준 출력 RMS
CENTERS = np.sqrt(EDGES[:-1] * EDGES[1:])
# 청감 가중: 귀가 가장 예민한 2–6 kHz(최대 3.5 kHz 부근)를 최대 3배로 본다
EAR = 1 + 2 * np.exp(-np.log2(CENTERS / 3500) ** 2 / (2 * 0.9 ** 2))
OVER = 2.0               # 2 kHz 이상에서 레퍼런스보다 '많은' 쪽 오차 배수(밝음 과잉 = 귀 피로)


def bands(f, pxx):
    return np.array([pxx[(f >= lo) & (f < hi)].sum() for lo, hi in zip(EDGES[:-1], EDGES[1:])])


def band_power(y, sr):
    return bands(*welch(y, fs=sr, nperseg=8192))


def tone_gain(f, sr, lp, q, slope, air):
    """엔진 톤 체인(LP → 2단 LP 크로스페이드 → Air 셸프)의 |H(f)|².
    TPT SVF는 컷오프에서 사전 왜곡한 쌍선형 변환과 같아서 응답을 해석적으로 계산할 수 있다(engine.wat와 같은 식)."""
    def svf_lp(fc, qq):
        fc = min(fc, 0.45 * sr)
        x = np.tan(np.pi * f / sr) / np.tan(np.pi * fc / sr)
        return 1 / (1 - x ** 2 + 1j * x / qq)
    h = svf_lp(lp, q) / np.sqrt(max(1, q * np.sqrt(2)))           # $qcomp
    h = h * ((1 - slope) + slope * svf_lp(lp, 0.707))
    c = min(1, 2 * np.pi * 2500 / sr)
    a = c / (1 - (1 - c) * np.exp(-2j * np.pi * f / sr))           # Air의 1차 LP
    return np.abs(h * ((1 + air) - air * a)) ** 2


def render_y(params, tmp):
    pj, wav = Path(tmp) / "p.json", Path(tmp) / "r.wav"
    pj.write_text(json.dumps(params))
    subprocess.run(["node", str(ROOT / "tools/render_rain.cjs"), str(RENDER_S), str(wav), str(pj)],
                   check=True, capture_output=True)
    y, sr = librosa.load(wav, sr=None, mono=True)
    return y[sr:], sr                                # 첫 1초(스무딩·페이드) 제외


def render(params, tmp):
    return band_power(*render_y(params, tmp))


def percussive_ratio(y):
    H, P = librosa.decompose.hpss(librosa.stft(y, n_fft=2048, hop_length=512), margin=2.0)
    p, h = (np.abs(P) ** 2).sum(), (np.abs(H) ** 2).sum()
    return p / (p + h)


def fit(ref_wav, profile_path):
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
        # 스웰은 끄고, 하이패스는 src/rain_model.js와 같은 규칙(누적 에너지 1% 지점)으로 건다.
        # 저역이 비어 있는 레퍼런스에서 하이패스 없이 맞추면 그 대역 상대 오차 때문에 베드가 0으로 풀린다.
        c1 = prof["analysis"]["spectral"]["cumulative_1pct_hz"]
        off.update({"10": 0, "16": min(400, c1) if c1 >= 25 else 0})

        def params(lp, w, scale=1.0):
            return {**off, "7": lp[0], "15": lp[1], "28": lp[2], "8": lp[3], "27": lp[4], **{str(pid): float(np.sqrt(v) * scale) for (_, pid), v in zip(LAYERS, w)}}

        # 1단계: 톤 (LP 컷오프, Q, 기울기, Air 셸프)과 방울 음높이 배수의 격자 탐색.
        #   레이어는 톤 필터를 끈 채(LP 20 kHz) 음높이 후보별로 한 번씩만 렌더하고, 필터는 해석적
        #   응답을 곱해 적용한다(선형 체인이라 같음). 베드 레이어는 음높이와 무관해 한 번만 렌더한다.
        #   Q를 올리면 컷오프 부근이 볼록해지고, 기울기 1(24 dB/oct)이면 그 위가 더 가파르게 떨어진다.
        #   Air < 0은 2.5 kHz 위를 낮추는 셸프. 음높이 배수는 '톡'·'툭'·잔빗소리 공진 주파수를 함께 옮긴다
        #   (타격 순간의 스펙트럼 중심은 넓은 대역 타격음의 공진 피크보다 높게 나오기 쉽다).
        flat = {"7": 20000, "15": 0.707, "28": 0, "8": 0}

        def psd(over):
            yy, srr = render_y({**off, **flat, **over}, tmp)
            f, pxx = welch(yy, fs=srr, nperseg=8192)
            return f, pxx / tone_gain(f, srr, 20000, 0.707, 0, 0), srr

        PITCHES = (0.5, 0.63, 0.8, 1.0)
        layer_psd = {}
        for n, pid in LAYERS:
            for pt in (PITCHES if pid in (12, 25) else (None,)):
                layer_psd[(pid, pt)] = psd({str(pid): 1, "27": pt or 1})
        fr, _, srr = layer_psd[(LAYERS[0][1], None)]
        cutoffs = sorted({min(20000, roll * k) for k in (1.0, 1.3, 1.7, 2.2, 3.0, 4.0, 5.5, 8.0)} | {5000, 6000, 7000, 8500})
        bases = {}
        for lp in [(c, q, sl, air, pt) for c in cutoffs for q in (0.707, 1.0, 1.4) for sl in (0, 0.5, 1)
                   for air in (0.3, 0, -0.3, -0.5, -0.7) for pt in PITCHES]:
            g = tone_gain(fr, srr, *lp[:4])
            bases[lp] = np.array([bands(fr, layer_psd[(pid, lp[4] if pid in (12, 25) else None)][1] * g) / ref.sum()
                                  for _, pid in LAYERS]).T
        free = {k: err_db(A, nnls(A * W[:, None], ref_n * W)[0]) for k, A in bases.items()}
        for k in sorted(free, key=free.get)[:5]:
            w = nnls(bases[k] * W[:, None], ref_n * W)[0]
            print(f"  LP {k[0]:7.0f} Hz Q {k[1]:.2f} {12 + 12 * k[2]:.0f} dB/oct Air {k[3]:+.1f} 음높이 ×{k[4]:.2f} → 오차 {free[k]:5.2f} dB, 레벨 "
                  + ", ".join(f"{n} {np.sqrt(v):.3f}" for (n, _), v in zip(LAYERS, w)))
        lp = min(free, key=free.get)
        wd0 = nnls(bases[lp] * W[:, None], ref_n * W)[0][DROP]

        # 2단계: 방울 파워를 줄여 가며 타격 성분 비율을 맞추고(로그 이분 탐색),
        #        그 방울 파워에서 로우패스를 다시 고른다. 두 번 번갈아 반복.
        for rnd in range(2):
            lo, hi = 0.02, 1.0
            for _ in range(7):
                alpha = np.sqrt(lo * hi)
                w = solve(bases[lp], alpha * wd0)
                pr = percussive_ratio(render_y(params(lp, w), tmp)[0])
                print(f"  [{rnd + 1}] LP {lp[0]:.0f} Hz Q {lp[1]:.2f} {12 + 12 * lp[2]:.0f} dB/oct Air {lp[3]:+.1f} 음높이 ×{lp[4]:.2f}, 방울 파워 ×{alpha:.3f} → 타격 성분 {pr:.3f} (목표 {target:.3f})")
                lo, hi = (alpha, hi) if pr < target else (lo, alpha)
            wd = alpha * wd0
            lp = min(bases, key=lambda k: err_db(bases[k], solve(bases[k], wd)))
        w = solve(bases[lp], wd)
        band_err = err_db(bases[lp], w)

        # 3단계: 출력 레벨 정규화(슬라이더 범위 0–1을 넘지 않게)
        y, _ = render_y(params(lp, w), tmp)
        scale = TARGET_RMS / float(np.sqrt(np.mean(y ** 2)))
        scale = min(scale, 1 / float(np.sqrt(w).max()))
        lv = np.sqrt(w) * scale
        y, _ = render_y(params(lp, w, scale), tmp)
    prof["fit"] = {"lpHz": round(lp[0], 1), "lpQ": lp[1], "lpSlope": lp[2], "air": lp[3], "pitch": lp[4], "band_rms_error_db": round(band_err, 2),
                   "percussive_ratio": round(float(percussive_ratio(y)), 3),
                   "render_rms": round(float(np.sqrt(np.mean(y ** 2))), 4),
                   "render_peak": round(float(np.abs(y).max()), 3),
                   **{n: round(float(v), 3) for (n, _), v in zip(LAYERS, lv)}}
    Path(profile_path).write_text(json.dumps(prof, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"저장: {profile_path} fit = {prof['fit']}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # Windows 콘솔(cp949)에서도 출력이 깨지지 않게
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wav")
    ap.add_argument("--profile", default=str(ROOT / "src/rain_profile.json"))
    a = ap.parse_args()
    fit(a.wav, a.profile)
