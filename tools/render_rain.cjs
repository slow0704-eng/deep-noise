// 빗소리 엔진 오프라인 렌더: 레퍼런스 프로파일로 바인딩한 엔진 출력을 WAV로 저장한다.
// 같은 분석기(analyze_rain.py)로 다시 분석해 레퍼런스와 비교하는 검증 루프용.
// 사용법: node tools/render_rain.cjs [초=60] [출력=reference/render.wav] [덮어쓸 파라미터.json]
//   덮어쓸 파라미터: {"엔진 id": 값} — tools/fit_rain.py가 레이어별 기저 렌더에 사용
const fs = require('fs'), path = require('path');
const { rainFromProfile } = require('../src/rain_model.js');

const root = path.join(__dirname, '..');
const sec = +(process.argv[2] || 60);
const outPath = path.resolve(root, process.argv[3] || 'reference/render.wav');
const profPath = path.join(root, 'src/rain_profile.json');
const ref = fs.existsSync(profPath) ? JSON.parse(fs.readFileSync(profPath, 'utf8')) : null;
const m = rainFromProfile(ref);

const SR = 48000;
const bytes = fs.readFileSync(path.join(root, 'dist/engine.wasm'));
const e = new WebAssembly.Instance(new WebAssembly.Module(bytes),
  { m: { tan: Math.tan, sin: Math.sin, cos: Math.cos, log: Math.log, exp: Math.exp } }).exports;
e.init(SR);
const P = {
  0: 1.5 * .6 * .6, 1: 0, 2: m.pink, 3: m.brown, 4: m.deep, 5: m.subHz, 6: 0, 7: m.lpHz, 8: m.air, 9: m.width,
  10: m.swell, 11: .1, 12: m.dropLevel, 13: m.rate, 14: 0, 15: m.lpQ, 16: m.hpHz, 17: .707,
  18: 1, 19: .005, 20: .8, 21: m.tokHz, 22: m.tukHz, 23: m.pTok, 24: m.decayMs, 25: m.pitLevel, 26: m.pitMul, 27: 1,
  28: m.lpSlope,
};
if (process.argv[4]) Object.assign(P, JSON.parse(fs.readFileSync(process.argv[4], 'utf8')));
for (const [k, v] of Object.entries(P)) e.setParam(+k, v);
e.snap();

const L = new Float32Array(e.memory.buffer, 0, 128), R = new Float32Array(e.memory.buffer, 512, 128);
const blocks = Math.ceil(sec * SR / 128), n = blocks * 128;
const pcm = Buffer.alloc(44 + n * 4);
let o = 44, peak = 0, bad = 0;
const t0 = process.hrtime.bigint();
for (let b = 0; b < blocks; b++) {
  e.process(128);
  for (let i = 0; i < 128; i++) {
    const l = L[i], r = R[i];
    if (!Number.isFinite(l) || !Number.isFinite(r)) bad++;
    peak = Math.max(peak, Math.abs(l), Math.abs(r));
    pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, l)) * 32767), o); o += 2;
    pcm.writeInt16LE(Math.round(Math.max(-1, Math.min(1, r)) * 32767), o); o += 2;
  }
}
const ms = Number(process.hrtime.bigint() - t0) / 1e6;
// WAV 헤더 (PCM 16-bit 스테레오)
pcm.write('RIFF', 0); pcm.writeUInt32LE(36 + n * 4, 4); pcm.write('WAVE', 8);
pcm.write('fmt ', 12); pcm.writeUInt32LE(16, 16); pcm.writeUInt16LE(1, 20); pcm.writeUInt16LE(2, 22);
pcm.writeUInt32LE(SR, 24); pcm.writeUInt32LE(SR * 4, 28); pcm.writeUInt16LE(4, 32); pcm.writeUInt16LE(16, 34);
pcm.write('data', 36); pcm.writeUInt32LE(n * 4, 40);
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, pcm);
console.log(`렌더: ${path.relative(root, outPath)} ${sec}s, 피크 ${peak.toFixed(3)}, NaN ${bad}, ` +
  `처리 ${ms.toFixed(0)} ms (실시간 대비 ×${(sec * 1000 / ms).toFixed(0)})`);
console.log('바인딩된 파라미터:', JSON.stringify(m, (k, v) => typeof v === 'number' ? +v.toFixed(3) : v));
