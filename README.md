# Deep Noise

WebAssembly 음향 엔진으로 깊은 저음과 넓은 음색의 노이즈를 만들어 재생하는 웹 플레이어입니다.

`index.html` 하나에 엔진(WASM, base64 인라인)과 UI가 모두 들어 있어 브라우저에서 바로 열 수 있습니다.
`file://`로 열었을 때 소리가 나지 않으면 `python -m http.server`로 띄운 뒤 `http://localhost:8000`에서 여세요.

## 기능
- 레이어: White · Pink · Brown · Deep 서브베이스(25–120Hz, 모노) · 빗방울
- 노이즈 타입 전환: White · Pink · Brown을 레벨을 유지한 채 클릭 없이 크로스페이드
- 필터: 로우패스·하이패스 컷오프와 Q(공진) — TPT 상태변수필터(바이쿼드와 같은 2차 응답, 실시간 변조에 안정적), Q에 따른 레벨 보정
- 엔벨로프: 엔진 내부 샘플 단위 페이드 인/아웃(5ms–10초), 볼륨은 블록 안에서 샘플 단위 보간
- 음색: 베이스 부스트(최대 +14dB), Air, 웜스(새츄레이션)
- 공간: 스테레오 폭, 파도 스웰(깊이·속도)
- 프리셋 8종, 실시간 스펙트럼, 슬립 타이머(마지막 1분 페이드아웃), 설정 자동 저장, Space 재생/정지

## 성능·안정성
- 오디오 스레드(`process`)는 할당 없음: WASM 메모리 뷰를 한 번만 만들어 재사용, 파라미터는 `Float32Array` 한 개로 모아 전송
- `latencyHint: 'playback'`로 하드웨어 버퍼를 크게 잡아 드롭아웃 방지
- 초기화: 기능 확인 → WASM 검증 → 워클릿 등록(blob → data URL 폴백) → `ready` 핸드셰이크(타임아웃 5초) → 그래프 연결. 실패하면 정리 후 다음 클릭에서 재시도
- 정지 시 페이드 아웃이 끝났다는 엔진 신호를 받은 뒤에만 `AudioContext`를 suspend

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
