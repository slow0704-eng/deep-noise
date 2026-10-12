# Deep Noise

WebAssembly 음향 엔진으로 깊은 저음과 넓은 음색의 노이즈를 만들어 재생하는 웹 플레이어입니다.

`index.html` 하나에 엔진(WASM, base64 인라인)과 UI가 모두 들어 있어 브라우저에서 바로 열 수 있습니다.
`file://`로 열었을 때 소리가 나지 않으면 `python -m http.server`로 띄운 뒤 `http://localhost:8000`에서 여세요.

## 기능
- 레이어: White · Pink · Brown · Deep 서브베이스(25–120Hz, 모노) · 빗방울
- 음색: 베이스 부스트(최대 +14dB), 톤(로우패스), Air, 웜스(새츄레이션)
- 공간: 스테레오 폭, 파도 스웰(깊이·속도)
- 프리셋 8종, 실시간 스펙트럼, 슬립 타이머(마지막 1분 페이드아웃), 설정 자동 저장, Space 재생/정지

## 구조
| 파일 | 역할 |
|---|---|
| `src/engine.wat` | DSP 엔진 (WebAssembly 텍스트) |
| `src/template.html` | UI와 AudioWorklet 코드 |
| `build.cjs` | WAT → WASM 컴파일 후 `index.html`, `dist/embed.html` 생성 |
| `dist/engine.wasm` | 빌드된 엔진 바이너리 |

## 빌드
```
npm install
npm run build
```
