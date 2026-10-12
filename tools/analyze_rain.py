"""레퍼런스 빗소리 분석: WAV → JSON 프로파일.

사용법:
    python tools/analyze_rain.py reference/rain_ref.wav [-o src/rain_profile.json]

측정 항목
- spectral: 스펙트럼 중심(평균·중앙값·분위수), 85% 롤오프, 스펙트럼 기울기(dB/옥타브),
            대역별 에너지 비율, 누적 에너지 1% 지점
- rms:      RMS 에너지(선형·dB), 변동계수, 2초 단위 느린 변동(바람·세기 변화)
- transient: HPSS로 분리한 타격 성분 기준 — 온셋 빈도, 온셋 간격(IOI) 통계와 푸아송 적합도,
             타격 순간의 스펙트럼 중심('톡'), 300–1500 Hz 피크('툭'), 고/저역 비, 감쇠 시간
엔진 파라미터로의 변환은 src/template.html의 rainFromProfile()이 담당한다.
"""
import argparse
import json
import sys
from pathlib import Path

import librosa
import numpy as np

N_FFT, HOP = 2048, 512
BANDS = [(20, 60), (60, 250), (250, 1000), (1000, 4000), (4000, 8000), (8000, 16000), (16000, 24000)]


def r(x, n=3):
    return float(round(float(x), n))


def band_ratios(power, freqs):
    total = power.sum() + 1e-20
    return {f"{lo}-{hi}": r(power[(freqs >= lo) & (freqs < hi)].sum() / total, 4) for lo, hi in BANDS}


def analyze(path):
    y, sr = librosa.load(path, sr=None, mono=True)
    dur = len(y) / sr
    S = np.abs(librosa.stft(y, n_fft=N_FFT, hop_length=HOP)) ** 2
    freqs = librosa.fft_frequencies(sr=sr, n_fft=N_FFT)
    mean_pow = S.mean(axis=1)

    # ── 스펙트럼 ─────────────────────────────────────────
    cent = librosa.feature.spectral_centroid(S=S, sr=sr, n_fft=N_FFT)[0]
    roll = librosa.feature.spectral_rolloff(S=S, sr=sr, n_fft=N_FFT, roll_percent=.85)[0]
    sel = (freqs >= 100) & (freqs <= 10000)
    slope = np.polyfit(np.log2(freqs[sel]), 10 * np.log10(mean_pow[sel] + 1e-20), 1)[0]
    audible = freqs >= 20                      # DC·초저역 제외
    cum = np.cumsum(mean_pow[audible]) / mean_pow[audible].sum()

    # ── RMS ─────────────────────────────────────────────
    rms = librosa.feature.rms(S=S, frame_length=N_FFT)[0]
    per_s = sr / HOP
    win = max(1, int(2 * per_s))
    slow = np.array([rms[i:i + win].mean() for i in range(0, len(rms) - win + 1, win)])

    # ── 타격(트랜지언트) ─────────────────────────────────
    D = librosa.stft(y, n_fft=N_FFT, hop_length=HOP)
    H, P = librosa.decompose.hpss(D, margin=2.0)
    Pp, Hp = np.abs(P) ** 2, np.abs(H) ** 2
    perc_ratio = Pp.sum() / (Pp.sum() + Hp.sum() + 1e-20)

    env = librosa.onset.onset_strength(S=librosa.power_to_db(Pp), sr=sr, hop_length=HOP)
    onsets = librosa.onset.onset_detect(onset_envelope=env, sr=sr, hop_length=HOP, units="frames")
    t_on = onsets * HOP / sr
    ioi = np.diff(t_on)
    # 푸아송 과정이면 간격은 지수분포 → 변동계수(CV)≈1, KS 거리가 작다.
    # 온셋 검출기는 한 번 잡은 뒤 일정 시간(불감 시간 τ) 다음 온셋을 못 잡으므로
    # 간격에서 τ를 뺀 '이동 지수분포'로 적합하고, 빈도는 비마비형 불감 시간 보정
    # λ = λ_obs / (1 − λ_obs·τ)로 복원한다.
    def ks_exp(x):
        xs = np.sort(x)
        lam = 1 / xs.mean()
        return np.max(np.abs(np.arange(1, len(xs) + 1) / len(xs) - (1 - np.exp(-lam * xs))))
    rate_obs = len(onsets) / dur
    if len(ioi) > 10:
        tau = float(ioi.min())
        ks, ks_shift = ks_exp(ioi), ks_exp(ioi - tau)
        shifted = ioi - tau
        cv_shift = shifted.std() / shifted.mean()
        rate_true = rate_obs / max(1e-3, 1 - rate_obs * tau)
    else:
        tau = ks = ks_shift = cv_shift = float("nan")
        rate_true = rate_obs

    # 배경(지속 성분): 하모닉 쪽 평균 스펙트럼 — 빗방울이 섞이지 않은 '베드'의 색
    bed_pow = Hp.mean(axis=1)
    bed_slope = np.polyfit(np.log2(freqs[sel]), 10 * np.log10(bed_pow[sel] + 1e-20), 1)[0]
    bed_cum = np.cumsum(bed_pow[audible]) / bed_pow[audible].sum()
    bed_cent = (freqs * bed_pow).sum() / bed_pow.sum()

    on_spec = Pp[:, onsets].mean(axis=1) if len(onsets) else mean_pow
    t_cent = (freqs * on_spec).sum() / (on_spec.sum() + 1e-20)
    lo_sel = (freqs >= 300) & (freqs <= 1500)
    low_peak = freqs[lo_sel][np.argmax(on_spec[lo_sel])]
    hi_e = on_spec[(freqs >= 2000) & (freqs < 12000)].sum()
    lo_e = on_spec[lo_sel].sum()

    # 감쇠: 온셋 이후 타격 성분 에너지가 피크 대비 -20 dB가 되는 데 걸리는 시간
    p_env = Pp.sum(axis=0)
    decays = []
    for f in onsets:
        seg = p_env[f:f + int(.15 * per_s)]
        if len(seg) < 3:
            continue
        k = int(np.argmax(seg))
        below = np.nonzero(seg[k:] < seg[k] * .01)[0]
        if len(below):
            decays.append(below[0] * HOP / sr * 1000)

    return {
        "file": Path(path).name,
        "sample_rate": int(sr),
        "duration_s": r(dur, 1),
        "spectral": {
            "centroid_hz": {"mean": r(cent.mean(), 1), "median": r(np.median(cent), 1),
                            "p10": r(np.percentile(cent, 10), 1), "p90": r(np.percentile(cent, 90), 1)},
            "rolloff85_hz_median": r(np.median(roll), 1),
            "slope_db_per_oct": r(slope, 2),
            "cumulative_1pct_hz": r(freqs[audible][np.searchsorted(cum, .01)], 1),
            "band_energy": band_ratios(mean_pow, freqs),
        },
        "bed": {
            "slope_db_per_oct": r(bed_slope, 2),
            "centroid_hz": r(bed_cent, 1),
            "rolloff85_hz": r(freqs[audible][np.searchsorted(bed_cum, .85)], 1),
            "band_energy": band_ratios(bed_pow, freqs),
        },
        "rms": {
            "mean": r(rms.mean(), 5), "std": r(rms.std(), 5),
            "mean_db": r(20 * np.log10(rms.mean() + 1e-12), 2),
            "cv": r(rms.std() / (rms.mean() + 1e-12)),
            "slow_cv": r(slow.std() / (slow.mean() + 1e-12)) if len(slow) > 1 else 0.0,
        },
        "transient": {
            "percussive_ratio": r(perc_ratio),
            "onset_count": int(len(onsets)),
            "onset_rate_hz": r(rate_obs, 2),
            "detector_dead_time_ms": r(tau * 1000, 1),
            "rate_corrected_hz": r(rate_true, 2),
            "ioi_ms_mean": r(ioi.mean() * 1000, 1) if len(ioi) else None,
            "ioi_cv": r(ioi.std() / ioi.mean()) if len(ioi) > 1 else None,
            "poisson_ks": r(ks),
            "poisson_ks_dead_time": r(ks_shift),
            "ioi_cv_dead_time": r(cv_shift),
            "centroid_hz": r(t_cent, 1),
            "low_peak_hz": r(low_peak, 1),
            "high_low_ratio": r(hi_e / (lo_e + 1e-20)),
            "band_energy": band_ratios(on_spec, freqs),
            "decay_ms_median": r(np.median(decays), 1) if decays else None,
        },
    }


COMPARE = [
    ("스펙트럼 중심 중앙값 (Hz)", ("spectral", "centroid_hz", "median")),
    ("85% 롤오프 (Hz)", ("spectral", "rolloff85_hz_median")),
    ("기울기 (dB/oct)", ("spectral", "slope_db_per_oct")),
    ("배경 기울기 (dB/oct)", ("bed", "slope_db_per_oct")),
    ("배경 중심 (Hz)", ("bed", "centroid_hz")),
    ("250–1k 에너지", ("spectral", "band_energy", "250-1000")),
    ("1k–4k 에너지", ("spectral", "band_energy", "1000-4000")),
    ("4k–8k 에너지", ("spectral", "band_energy", "4000-8000")),
    ("RMS 변동계수", ("rms", "cv")),
    ("타격 성분 비율", ("transient", "percussive_ratio")),
    ("보정 온셋 빈도 (/s)", ("transient", "rate_corrected_hz")),
    ("불감시간 보정 IOI CV", ("transient", "ioi_cv_dead_time")),
    ("타격 중심 '톡' (Hz)", ("transient", "centroid_hz")),
    ("타격 저역 피크 '툭' (Hz)", ("transient", "low_peak_hz")),
]


def compare(ref, got):
    def pick(d, keys):
        for k in keys:
            d = d.get(k) if isinstance(d, dict) else None
        return d
    print(f"{'항목':<26}{'레퍼런스':>12}{'엔진 렌더':>12}{'차이':>9}")
    for name, keys in COMPARE:
        a, b = pick(ref, keys), pick(got, keys)
        diff = f"{(b - a) / abs(a) * 100:+.0f}%" if a not in (None, 0) and b is not None else "—"
        print(f"{name:<26}{a!s:>12}{b!s:>12}{diff:>9}")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")   # Windows 콘솔(cp949)에서도 출력이 깨지지 않게
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wav")
    ap.add_argument("-o", "--out", default="src/rain_profile.json")
    ap.add_argument("--compare", metavar="PROFILE_JSON", help="결과를 이 프로파일과 비교해 표로 출력")
    a = ap.parse_args()

    prof = {"source": None, "analysis": analyze(a.wav)}
    meta = Path(a.wav).with_suffix(".json")
    if meta.exists():
        prof["source"] = json.loads(meta.read_text(encoding="utf-8"))
    Path(a.out).write_text(json.dumps(prof, ensure_ascii=False, indent=2), encoding="utf-8")
    t = prof["analysis"]["transient"]
    print(f"저장: {a.out} — 온셋 {t['onset_rate_hz']}/s (보정 {t['rate_corrected_hz']}/s), "
          f"불감시간 보정 IOI CV {t['ioi_cv_dead_time']}, KS {t['poisson_ks_dead_time']}, "
          f"톡 {t['centroid_hz']} Hz, 툭 {t['low_peak_hz']} Hz")
    if a.compare:
        ref = json.loads(Path(a.compare).read_text(encoding="utf-8"))["analysis"]
        compare(ref, prof["analysis"])
