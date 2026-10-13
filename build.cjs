// 빌드: src/engine.wat → WebAssembly 바이너리 → index.html에 base64로 인라인
//       src/profiles/*.json + src/scene_model.js → 장면(빗소리·기차·벽난로) 엔진 초기 파라미터로 인라인
// 사용법: npm install && npm run build
const fs = require('fs'), path = require('path');
(async () => {
  const wabt = await require('wabt')();
  const src = fs.readFileSync(path.join(__dirname, 'src/engine.wat'), 'utf8');
  const mod = wabt.parseWat('engine.wat', src);
  mod.validate();
  const { buffer } = mod.toBinary({});
  fs.mkdirSync(path.join(__dirname, 'dist'), { recursive: true });
  fs.writeFileSync(path.join(__dirname, 'dist/engine.wasm'), buffer);
  // 장면 레퍼런스: tools/analyze_reference.py(+fit_reference.py)가 만든 프로파일을 엔진 초기 파라미터로 바인딩
  const profiles = {};
  for (const scene of ['rain', 'train', 'fire']) {
    const f = path.join(__dirname, `src/profiles/${scene}.json`);
    profiles[scene] = fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, 'utf8')) : null;
  }
  const model = fs.readFileSync(path.join(__dirname, 'src/scene_model.js'), 'utf8');
  const html = fs.readFileSync(path.join(__dirname, 'src/template.html'), 'utf8')
    .replace('/*__WASM_BASE64__*/', () => Buffer.from(buffer).toString('base64'))
    .replace('/*__SCENE_PROFILES__*/null', () => JSON.stringify(profiles).replace(/</g, '\\u003c'))   // </script> 차단
    .replace('/*__SCENE_MODEL__*/', () => model);
  fs.writeFileSync(path.join(__dirname, 'index.html'), html);
  // 임베드용(문서 골격 없는) 버전: 호스트가 <html><head><body>를 감싸는 환경용
  const fragment = html
    .replace(/<!doctype html>\s*/i, '').replace(/<html[^>]*>\s*/i, '')
    .replace(/<\/?head>\s*/gi, '').replace(/<body>\s*/i, '')
    .replace(/<\/body>\s*/i, '').replace(/<\/html>\s*/i, '')
    .replace(/<meta charset[^>]*>\s*/i, '').replace(/<meta name="viewport"[^>]*>\s*/i, '');
  fs.writeFileSync(path.join(__dirname, 'dist/embed.html'), fragment);
  const bound = Object.entries(profiles).map(([k, v]) => `${k}${v ? (v.fit ? '(피팅)' : '(분석)') : '(기본값)'}`).join(' ');
  console.log(`engine.wasm ${buffer.length} bytes, 장면 프로파일 ${bound} → index.html, dist/embed.html`);
})();
