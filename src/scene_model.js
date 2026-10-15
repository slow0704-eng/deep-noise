// 레퍼런스 분석(JSON, tools/analyze_reference.py) → 장면 엔진 물리 파라미터.
//   사건 장면: 빗소리·기차·벽난로·시냇물·바람·여름밤·독서실·사무실 / 배경만 있는 장면: 샤워·폭포·선풍기
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
  // hpHz는 하이패스를 격자에서 고른 피팅에만 있다(없으면 위의 누적 에너지 규칙)
  if (f) for (const k of ['white', 'pink', 'brown', 'deep', 'subHz', 'lpHz', 'lpQ', 'lpSlope', 'air', 'hpHz', 'makeup']) if (f[k] != null) m[k] = f[k];
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

// 시냇물: 물 흐름의 넓은 쏴—(베드) + 푸아송 도착 공기방울(음높이가 올라가는 사인)
function streamFromProfile(ref) {
  const d = { rate:25, bubbleHz:800, glide:.6, bubbleLevel:.4, pitch:1,
              white:.1, pink:.4, brown:.3, deep:.05, subHz:45, lpHz:9000, lpQ:.707, lpSlope:0, air:0, hpHz:60, swell:0, width:.7 };
  const a = ref && ref.analysis;
  if (!a) return d;
  const t = a.transient, f = ref.fit;
  const m = {
    ...d,
    rate:     clamp(t.rate_corrected_hz ?? d.rate, 5, 150),            // 불감 시간 보정된 푸아송 λ
    bubbleHz: clamp(t.low_peak_hz ?? d.bubbleHz, 300, 1500),           // 타격 순간 300–1500 Hz 피크
    ...bedFromProfile(a, f, d),
  };
  if (f && f.bubbleLevel != null) m.bubbleLevel = f.bubbleLevel;
  if (f && f.pitch) m.pitch = f.pitch;                                  // 피팅된 방울 음높이 배수
  return m;
}

// 바람: 돌풍 엔벨로프가 흔드는 넓은 노이즈 + 공진 휘파람
function windFromProfile(ref) {
  const d = { gust:.6, gustHz:.12, howlHz:500, howlLevel:.3,
              white:0, pink:.4, brown:.6, deep:.1, subHz:45, lpHz:3000, lpQ:.707, lpSlope:1, air:0, hpHz:40, swell:0, width:.9 };
  const a = ref && ref.analysis;
  if (!a) return d;
  const f = ref.fit;
  const m = {
    ...d,
    // 느린 세기 변동(2초 창 CV)이 클수록 돌풍이 깊다. 엔진 돌풍 게인 1 + 0.55·깊이·N(0,1)의 CV ≈ 0.55·깊이
    gust:   clamp(a.rms.slow_cv / .55, .2, 1),
    gustHz: clamp(a.rms.gust_hz ?? d.gustHz, .03, .5),                 // 세기 엔벨로프 자기상관 → 돌풍 속도
    ...bedFromProfile(a, f, d),
    swell:  0,                                                          // 주기적인 스웰 대신 무작위 돌풍
  };
  if (f && f.howlLevel != null) m.howlLevel = f.howlLevel;
  if (f && f.pitch) m.howlHz = f.pitch;                                 // 피팅 격자 값 = 휘파람 중심(Hz)
  return m;
}

// 여름밤: 낮은 밤공기(베드) + 풀벌레 세 마리의 '찌르르'(사인 펄스 묶음)
function nightFromProfile(ref) {
  const d = { cricketHz:4500, cricket2Hz:0, period:.9, pulses:3, pulseHz:30, cricketLevel:.3,
              white:0, pink:.2, brown:.3, deep:.05, subHz:45, lpHz:10000, lpQ:.707, lpSlope:0, air:0, hpHz:80, swell:0, width:.8 };
  const a = ref && ref.analysis;
  if (!a) return d;
  const to = a.tonal || {}, f = ref.fit;
  const pulseHz = to.pulse_hz && to.pulse_strength > .05 ? clamp(to.pulse_hz, 10, 80) : d.pulseHz;
  const period = to.period_strength >= .1 ? clamp(to.period_s, .2, 3) : d.period;
  const m = {
    ...d,
    cricketHz: clamp(to.peak_hz ?? d.cricketHz, 2000, 9000),            // 2–10 kHz 평균 스펙트럼 피크
    cricket2Hz: to.peak2_hz ? clamp(to.peak2_hz, 2000, 9000) : 0,        // 다른 종의 울음 높이(없으면 0)
    pulseHz, period,
    // 한 울음의 길이 ≈ 울음 주기 × 점유율 → 펄스 수
    pulses:    clamp(Math.round(period * (to.duty ?? .3) * pulseHz), 1, 40),
    ...bedFromProfile(a, f, d),
  };
  if (f && f.cricketLevel != null) m.cricketLevel = f.cricketLevel;
  return m;
}

// 실내 장면 공통: 사람의 손길(묶음 도착은 푸아송, 묶음 안은 고른 리듬)의 묶음 빈도를 온셋 빈도에서 정한다.
// 보정 온셋 빈도 ≈ 손길 빈도라 보고, 묶음당 사건 수(size)로 나눈 값이 묶음 도착 빈도다.
function indoorFromProfile(ref, d) {
  const a = ref && ref.analysis;
  const m = { ...d };
  if (a) {
    const f = ref.fit, perSec = a.transient.rate_corrected_hz;
    // 녹음의 온셋에는 말소리·의자 소리도 섞인다 → 손길이 쉼 없이 이어지지 않게 묶음이 차지하는 시간을 60%까지로
    if (perSec) m.burstRate = clamp(perSec / d.burstSize, .02, .6 * d.handRhythm / d.burstSize);
    // 키캡 '딸깍'은 타격 순간의 스펙트럼 중심(연필은 녹음의 타격이 책·발소리라 기본값 유지)
    if (d.handFromOnset && a.transient.centroid_hz) m.handHz = clamp(a.transient.centroid_hz, 2000, 7000);
    Object.assign(m, bedFromProfile(a, f, d), { swell: 0 });
    for (const k of ['handLevel', 'murmurLevel']) if (f && f[k] != null) m[k] = f[k];
    if (f && f.pitch) m.handPitch = f.pitch;                             // 피팅된 손길 음높이 배수
  }
  // 책장 넘김은 드물어(수십 초에 한 번) 20초 렌더로는 피팅이 흔들린다 → 손길 레벨에 비례
  m.pageLevel = clamp(m.handLevel * d.pageRatio, 0, 1);
  return m;
}

// 독서실: 조용한 공조음(베드) + 연필 필기(한 줄 ≈ 12획, 초당 7획) + 가끔 책장 넘김
const studyFromProfile = ref => indoorFromProfile(ref, { handHz:3500, handPitch:1, burstRate:.2, burstSize:12, handRhythm:7,
  handLevel:.3, pageRatio:.9, pageRate:.05, murmurLevel:0, murmurHz:1200,
  white:0, pink:.3, brown:.6, deep:.1, subHz:45, lpHz:4000, lpQ:.707, lpSlope:1, air:0, hpHz:40, swell:0, width:.6 });
// 사무실: 공조음(베드) + 키보드 타이핑(한 묶음 ≈ 25타, 초당 8타) + 먼 대화 + 드문 서류 넘김
const officeFromProfile = ref => indoorFromProfile(ref, { handHz:4000, handFromOnset:true, handPitch:1, burstRate:.3, burstSize:25, handRhythm:8,
  handLevel:.3, pageRatio:.35, pageRate:.02, murmurLevel:.3, murmurHz:1200,
  white:0, pink:.4, brown:.5, deep:.1, subHz:50, lpHz:5000, lpQ:.707, lpSlope:1, air:0, hpHz:60, swell:0, width:.6 });

// 배경만 있는 장면(샤워·폭포·선풍기): 피팅된 노이즈 색과 톤이 전부다
const bedScene = d => ref => {
  const a = ref && ref.analysis;
  return a ? { ...d, ...bedFromProfile(a, ref.fit, d) } : d;
};
const showerFromProfile    = bedScene({ white:.8, pink:.2, brown:0, deep:0, subHz:45, lpHz:12000, lpQ:.707, lpSlope:0, air:0, hpHz:150, swell:0, width:.8 });
const waterfallFromProfile = bedScene({ white:.1, pink:.8, brown:.3, deep:.2, subHz:45, lpHz:8000, lpQ:.707, lpSlope:0, air:0, hpHz:30, swell:0, width:1 });
const fanFromProfile       = bedScene({ white:0, pink:.2, brown:.9, deep:.3, subHz:60, lpHz:2500, lpQ:.707, lpSlope:1, air:0, hpHz:40, swell:0, width:.5 });

const SCENE_MODELS = { rain: rainFromProfile, train: trainFromProfile, fire: fireFromProfile,
  stream: streamFromProfile, wind: windFromProfile, night: nightFromProfile,
  shower: showerFromProfile, waterfall: waterfallFromProfile, fan: fanFromProfile,
  study: studyFromProfile, office: officeFromProfile };

// 엔진 파라미터 바인딩 {id: 값} — 해당 장면만 켜고 다른 장면의 사건 레이어는 끈다.
// 볼륨(0)·게이트(18)·페이드(19, 20)·스웰 속도(11)는 호출하는 쪽이 정한다.
function sceneBinding(scene, m) {
  const p = {
    1: m.white || 0, 2: m.pink || 0, 3: m.brown || 0, 4: m.deep || 0, 5: m.subHz, 6: 0, 7: m.lpHz, 8: m.air || 0,
    9: m.width, 10: m.swell, 14: 0, 15: m.lpQ || .707, 16: m.hpHz, 17: .707, 28: m.lpSlope ?? 1, 57: m.makeup || 1,
    12: 0, 25: 0, 29: 0, 34: 0, 39: 0, 41: 0, 46: 0, 48: 0, 51: 0, 58: 0, 69: 0, 64: 0, 66: 0, 27: 1, 33: 1, 45: 1, 68: 1, 74: 1,
  };
  if (scene === 'rain') Object.assign(p, { 12: m.dropLevel, 13: m.rate, 21: m.tokHz, 22: m.tukHz, 23: m.pTok,
    24: m.decayMs, 25: m.pitLevel, 26: m.pitMul });
  if (scene === 'train') Object.assign(p, { 29: m.clackLevel, 30: m.period, 31: m.thumpHz, 32: m.knockHz });
  if (scene === 'fire') Object.assign(p, { 34: m.crackleLevel, 35: m.clusterRate, 36: m.clusterSize, 37: m.crackleHz,
    38: m.popRatio, 39: m.flicker, 40: m.popHz });
  if (scene === 'stream') Object.assign(p, { 41: m.bubbleLevel, 42: m.rate, 43: m.bubbleHz, 44: m.glide, 45: m.pitch });
  if (scene === 'wind') Object.assign(p, { 46: m.gust, 47: m.gustHz, 48: m.howlLevel, 49: m.howlHz });
  if (scene === 'night') Object.assign(p, { 51: m.cricketLevel, 52: m.period, 53: m.cricketHz, 54: m.pulses, 55: m.pulseHz, 56: m.cricket2Hz });
  // 손길: 독서실 = 연필 필기(69–74), 사무실 = 키보드 타이핑(58–62, 68)
  const hand = { study: 69, office: 58 }[scene];
  if (hand) Object.assign(p, { [hand]: m.handLevel, [hand + 1]: m.burstRate, [hand + 2]: m.burstSize, [hand + 3]: m.handRhythm,
    [hand + 4]: m.handHz, [scene === 'study' ? 74 : 68]: m.handPitch, 64: m.pageLevel, 65: m.pageRate, 66: m.murmurLevel, 67: m.murmurHz });
  return p;
}
if (typeof module !== 'undefined') module.exports = { SCENE_MODELS, sceneBinding };
