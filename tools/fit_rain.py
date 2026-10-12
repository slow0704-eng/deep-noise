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


def band_power(y, sr):
    f, pxx = welch(y, fs=sr, nperseg=8192)
    return np.array([pxx[(f >= lo) & (f < hi)].sum() for lo, hi in zip(EDGES[:-1], EDGES[1:])])


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
    roll = prof["analysis"]["spectral"]["rolloff85_hz_median"]

    W = 1 / (ref_n + 1e-6)                           # 대역별 상대 오차
    others = [i for i in range(len(LAYERS)) if i != DROP]
    target = prof["analysis"]["transient"]["percussive_ratio"]

    def err_db(A, w):
        return float(np.sqrt(np.mean((10 * np.log10((A @ w + 1e-12) / ref_n)) ** 2)))

    def solve(A, wd):
        """방울 파워 가중치를 wd로 고정하고 나머지 레이어를 NNLS로 푼다."""
        w = np.zeros(len(LAYERS))
        w[DROP] = wd
        wo, _ = nnls(A[:, others] * W[:, None], (ref_n - A[:, DROP] * wd) * W)
        w[others] = wo
        return w

    with tempfile.TemporaryDirectory() as tmp:
        off = {str(i): 0 for _, i in LAYERS}
        off.update({"10": 0, "16": 0})               # 스웰·하이패스 끔

        def params(lp, w, scale=1.0):
            return {**off, "7": lp[0], "15": lp[1], **{str(pid): float(np.sqrt(v) * scale) for (_, pid), v in zip(LAYERS, w)}}

        # 1단계: 로우패스 (컷오프, Q) 후보마다 레이어 기저를 렌더하고 자유 NNLS.
        #        Q를 올리면 컷오프 부근이 볼록해지고 그 위가 가파르게 떨어진다.
        bases = {}
        cutoffs = sorted({min(20000, roll * k) for k in (1.0, 1.3, 1.7, 2.2, 3.0, 4.0, 5.5, 8.0)})
        for lp in [(c, q) for c in cutoffs for q in (0.707, 1.4, 2.8)]:
            bases[lp] = np.array([render({**off, "7": lp[0], "15": lp[1], str(pid): 1}, tmp) / ref.sum()
                                  for _, pid in LAYERS]).T
            w, _ = nnls(bases[lp] * W[:, None], ref_n * W)
            print(f"  LP {lp[0]:7.0f} Hz Q {lp[1]:.2f} → 대역 RMS 오차 {err_db(bases[lp], w):5.2f} dB, 레벨 "
                  + ", ".join(f"{n} {np.sqrt(v):.3f}" for (n, _), v in zip(LAYERS, w)))
        lp = min(bases, key=lambda k: err_db(bases[k], nnls(bases[k] * W[:, None], ref_n * W)[0]))
        wd0 = nnls(bases[lp] * W[:, None], ref_n * W)[0][DROP]

        # 2단계: 방울 파워를 줄여 가며 타격 성분 비율을 맞추고(로그 이분 탐색),
        #        그 방울 파워에서 로우패스를 다시 고른다. 두 번 번갈아 반복.
        for rnd in range(2):
            lo, hi = 0.02, 1.0
            for _ in range(7):
                alpha = np.sqrt(lo * hi)
                w = solve(bases[lp], alpha * wd0)
                pr = percussive_ratio(render_y(params(lp, w), tmp)[0])
                print(f"  [{rnd + 1}] LP {lp[0]:.0f} Hz Q {lp[1]:.2f}, 방울 파워 ×{alpha:.3f} → 타격 성분 {pr:.3f} (목표 {target:.3f})")
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
    prof["fit"] = {"lpHz": round(lp[0], 1), "lpQ": lp[1], "band_rms_error_db": round(band_err, 2),
                   "percussive_ratio": round(float(percussive_ratio(y)), 3),
                   "render_rms": round(float(np.sqrt(np.mean(y ** 2))), 4),
                   "render_peak": round(float(np.abs(y).max()), 3),
                   **{n: round(float(v), 3) for (n, _), v in zip(LAYERS, lv)}}
    Path(profile_path).write_text(json.dumps(prof, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"저장: {profile_path} fit = {prof['fit']}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wav")
    ap.add_argument("--profile", default=str(ROOT / "src/rain_profile.json"))
    a = ap.parse_args()
    fit(a.wav, a.profile)
