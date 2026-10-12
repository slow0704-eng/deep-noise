// 빌드: src/engine.wat → WebAssembly 바이너리 → index.html에 base64로 인라인
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
  const html = fs.readFileSync(path.join(__dirname, 'src/template.html'), 'utf8')
    .replace('/*__WASM_BASE64__*/', Buffer.from(buffer).toString('base64'));
  fs.writeFileSync(path.join(__dirname, 'index.html'), html);
  // 임베드용(문서 골격 없는) 버전: 호스트가 <html><head><body>를 감싸는 환경용
  const fragment = html
    .replace(/<!doctype html>\s*/i, '').replace(/<html[^>]*>\s*/i, '')
    .replace(/<\/?head>\s*/gi, '').replace(/<body>\s*/i, '')
    .replace(/<\/body>\s*/i, '').replace(/<\/html>\s*/i, '')
    .replace(/<meta charset[^>]*>\s*/i, '').replace(/<meta name="viewport"[^>]*>\s*/i, '');
  fs.writeFileSync(path.join(__dirname, 'dist/embed.html'), fragment);
  console.log(`engine.wasm ${buffer.length} bytes → index.html, dist/embed.html`);
})();
