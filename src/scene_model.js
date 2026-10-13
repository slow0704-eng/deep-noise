// 레퍼런스 분석(JSON, tools/analyze_reference.py) → 장면(빗소리·기차·벽난로) 엔진 물리 파라미터.
// build.cjs가 페이지에 인라인하고, tools/render_scene.cjs·fit_reference.py도 같은 함수를 쓴다.
// 프로파일이 없으면 기본값, "fit" 블록이 있으면 피팅된 레이어 레벨·톤을 우선한다.
const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

// 세 장면이 공유하는 배경(베드)·톤 파라미터: 하이패스, 스웰, 스테레오 폭, 그리고 피팅 결과
function bedFromProfile(a, f, d) {
  const sp = a.spectral;
  const m = {
    hpHz:  sp.cumulative_1pct_hz >= 25 ? clamp(sp.cumulative_1pct_hz, 25, 400) : 0,   // 누적 에너지 1% 지점
    swell: clamp(a.rms.slow_cv * 2, 0, .6),                                          // 느린 세기 변동 → 파도 스웰
    // 배경 노이즈의 L/R 상관이 1 − 폭이 되도록(폭 1 = 완전 독립)
    width: a.stereo_corr != null ? clamp(1 - a.stereo_corr, .1, 1) : d.width,
  };
  if (f) for (const k of ['white', 'pink', 'brown', 'deep', 'subHz', 'lpHz', 'lpQ', 'lpSlope', 'air']) if (f[k] != null) m[k] = f[k];
  return m;
}

function rainFromProfile(ref) {
  const d = { rate:18, tokHz:2600, tukHz:700, pTok:.5, decayMs:12, pitMul:6, pitLevel:.25, dropLevel:.8,
              white:0, pink:.25, brown:.5, lpHz:6000, lpQ:.707, lpSlope:1, air:0, hpHz:0, deep:.15, subHz:45, swell:.1, width:1 };
  const a = ref && ref.analysis;
  if (!a) return d;
  const t = a.transient, sp = a.spectral, be = sp.band_energy;
  const hi = be['4000-8000'] + be['8000-16000'] + be['16000-24000'];
  const perc = t.percussive_ratio;
  // 스펙트럼 기울기: −3 dB/oct = 핑크, −6 dB/oct = 브라운
  const brownFrac = clamp((-sp.slope_db_per_oct - 3) / 3, 0, 1);
  const bed = clamp(1.6 * (1 - perc), .3, 1);
  const hl = t.high_low_ratio;
  const f = ref.fit;   // tools/fit_reference.py의 NNLS 피팅 결과
  const m = {
    ...d,
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
    deep:     clamp(be['20-60'] * 4, 0, .6),
    ...bedFromProfile(a, f, d),
  };
  if (f) for (const k of ['dropLevel', 'pitLevel']) if (f[k] != null) m[k] = f[k];
  // 피팅된 음높이 배수: 타격 순간 스펙트럼 중심 → 공진 피크로 옮긴다(슬라이더 '빗방울 음높이'는 그 위에서 가운데)
  if (f && f.pitch) { m.tokHz *= f.pitch; m.tukHz *= f.pitch; }
  return m;
}

// 기차: 객실 안의 낮은 주행음(베드) + 레일 이음매를 지나는 '덜컹' 주기 패턴
function trainFromProfile(ref) {
  const d = { period:1.2, thumpHz:110, knockHz:400, clackLevel:.4,
              white:0, pink:.1, brown:.8, deep:.5, subHz:40, lpHz:900, lpQ:.707, lpSlope:1, air:0, hpHz:25, swell:.15, width:.4 };
  const a = ref && ref.analysis;
  if (!a) return d;
  const t = a.transient, pr = a.periodicity, f = ref.fit;
  const m = {
    ...d,
    // 100–1000 Hz 세기 엔벨로프의 자기상관 피크가 충분히 또렷할 때만 이음매 주기로 쓴다
    period:  pr && pr.strength >= .12 ? clamp(pr.period_s, .4, 3) : d.period,
    thumpHz: clamp(t.sub_peak_hz ?? d.thumpHz, 50, 300),     // 타격 순간 40–300 Hz 피크: 차체로 전해지는 '쿵'
    knockHz: clamp(t.low_peak_hz ?? d.knockHz, 250, 3000),    // 타격 순간 300–1500 Hz 피크: 바퀴–레일의 '덩'
    ...bedFromProfile(a, f, d),
  };
  if (f && f.clackLevel != null) m.clackLevel = f.clackLevel;
  return m;
}

// 벽난로: 불꽃의 낮은 울림(베드, 일렁임 AM) + 군집 푸아송 '타닥'과 드문 '펑'
function fireFromProfile(ref) {
  const d = { clusterRate:3, clusterSize:2.5, crackleHz:3500, popHz:700, popRatio:.12, flicker:.5, crackleLevel:.4,
              white:.05, pink:.3, brown:.6, deep:.3, subHz:45, lpHz:8000, lpQ:.707, lpSlope:0, air:0, hpHz:25, swell:.05, width:.3 };
  const a = ref && ref.analysis;
  if (!a) return d;
  const t = a.transient, f = ref.fit;
  // 온셋 검출기(불감 시간 ≈30 ms)는 군집 안의 타닥을 대부분 따로 잡으므로 보정 온셋 빈도 ≈ 타닥 빈도.
  // 간격 CV가 1보다 크면 군집이 뚜렷하다 → 군집당 타닥 수를 늘리고 군집 빈도는 그만큼 줄인다.
  const size = clamp(1 + 4 * ((t.ioi_cv_dead_time ?? 1) - .9), 1.2, 5);
  const hl = t.high_low_ratio ?? 4;
  const m = {
    ...d,
    clusterSize: size,
    clusterRate: clamp((t.rate_corrected_hz ?? 9) / size, .3, 30),
    crackleHz:   clamp(t.centroid_hz ?? d.crackleHz, 1500, 8000),   // 타격 순간 스펙트럼 중심
    popHz:       clamp(t.low_peak_hz ?? d.popHz, 300, 1500),        // 타격 순간 300–1500 Hz 피크
    popRatio:    clamp(1 / (1 + hl), .05, .5),                      // 저역/고역 타격 에너지 비
    // 배경 세기의 짧은 변동(2초 창 CV). 비처럼 고른 배경이 ≈0.07이라 그 위만 일렁임으로 본다
    flicker:     clamp(((a.rms.fast_cv ?? .2) - .07) * 4, 0, 1),
    ...bedFromProfile(a, f, d),
  };
  if (f && f.crackleLevel != null) m.crackleLevel = f.crackleLevel;
  return m;
}

const SCENE_MODELS = { rain: rainFromProfile, train: trainFromProfile, fire: fireFromProfile };

// 엔진 파라미터 바인딩 {id: 값} — 해당 장면만 켜고 다른 장면의 사건 레이어는 끈다.
// 볼륨(0)·게이트(18)·페이드(19, 20)·스웰 속도(11)는 호출하는 쪽이 정한다.
function sceneBinding(scene, m) {
  const p = {
    1: m.white || 0, 2: m.pink || 0, 3: m.brown || 0, 4: m.deep || 0, 5: m.subHz, 6: 0, 7: m.lpHz, 8: m.air || 0,
    9: m.width, 10: m.swell, 14: 0, 15: m.lpQ || .707, 16: m.hpHz, 17: .707, 28: m.lpSlope ?? 1,
    12: 0, 25: 0, 29: 0, 34: 0, 39: 0, 27: 1, 33: 1,
  };
  if (scene === 'rain') Object.assign(p, { 12: m.dropLevel, 13: m.rate, 21: m.tokHz, 22: m.tukHz, 23: m.pTok,
    24: m.decayMs, 25: m.pitLevel, 26: m.pitMul });
  if (scene === 'train') Object.assign(p, { 29: m.clackLevel, 30: m.period, 31: m.thumpHz, 32: m.knockHz });
  if (scene === 'fire') Object.assign(p, { 34: m.crackleLevel, 35: m.clusterRate, 36: m.clusterSize, 37: m.crackleHz,
    38: m.popRatio, 39: m.flicker, 40: m.popHz });
  return p;
}
if (typeof module !== 'undefined') module.exports = { rainFromProfile, trainFromProfile, fireFromProfile, SCENE_MODELS, sceneBinding };
