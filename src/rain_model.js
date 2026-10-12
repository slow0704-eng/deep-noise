// 레퍼런스 분석(JSON, tools/analyze_rain.py) → 빗소리 엔진 물리 파라미터.
// build.cjs가 페이지에 인라인하고, tools/render_rain.cjs도 같은 함수를 쓴다.
// 프로파일이 없으면 기본값, "fit" 블록이 있으면 피팅된 레이어 레벨을 우선한다.
function rainFromProfile(ref) {
  const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));
  const d = { rate:18, tokHz:2600, tukHz:700, pTok:.5, decayMs:12, pitMul:6, pitLevel:.25, dropLevel:.8,
              pink:.25, brown:.5, lpHz:6000, hpHz:0, deep:.15, subHz:45, swell:.1, width:1 };
  const a = ref && ref.analysis;
  if (!a) return d;
  const t = a.transient, sp = a.spectral, be = sp.band_energy;
  const hi = be['4000-8000'] + be['8000-16000'] + be['16000-24000'];
  const perc = t.percussive_ratio;
  // 스펙트럼 기울기: −3 dB/oct = 핑크, −6 dB/oct = 브라운
  const brownFrac = clamp((-sp.slope_db_per_oct - 3) / 3, 0, 1);
  const bed = clamp(1.6 * (1 - perc), .3, 1);
  const hl = t.high_low_ratio;
  const f = ref.fit;   // tools/fit_rain.py의 NNLS 피팅 결과가 있으면 레벨·컷오프는 그 값을 쓴다
  const m = {
    rate:     clamp(t.rate_corrected_hz ?? t.onset_rate_hz, 2, 150),   // 불감 시간 보정된 푸아송 λ
    tokHz:    clamp(t.centroid_hz, 1200, 8000),                         // 타격 순간 스펙트럼 중심
    tukHz:    clamp(t.low_peak_hz, 200, 1500),                          // 타격 순간 300–1500 Hz 피크
    pTok:     clamp(hl / (1 + hl), .1, .9),                             // 고역/저역 타격 에너지 비
    decayMs:  clamp((t.decay_ms_median ?? 48) * .25, 2, 30),            // STFT 프레임 번짐(≈43 ms) 보정
    pitMul:   clamp(10 + 300 * hi, 10, 30),                             // 개별 온셋으로 들리지 않을 만큼 촘촘한 질감
    pitLevel: clamp(hi * 8, .1, .7),
    dropLevel: clamp(perc * 1.6, .2, 1),                                // 타격 성분 비율
    pink:     bed * (1 - brownFrac),
    brown:    bed * brownFrac,
    lpHz:     clamp(sp.rolloff85_hz_median * 1.3, 1500, 20000),
    lpQ:      .707,
    hpHz:     sp.cumulative_1pct_hz >= 25 ? clamp(sp.cumulative_1pct_hz, 25, 400) : 0,
    deep:     clamp(be['20-60'] * 4, 0, .6),
    subHz:    45,
    swell:    clamp(a.rms.slow_cv * 2, 0, .6),                          // 느린 세기 변동 → 파도 스웰
    width:    1,
  };
  if (f) for (const k of ['pink', 'brown', 'deep', 'dropLevel', 'pitLevel', 'lpHz', 'lpQ']) if (f[k] != null) m[k] = f[k];
  return m;
}
if (typeof module !== 'undefined') module.exports = { rainFromProfile };
