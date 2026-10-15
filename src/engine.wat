;; ─────────────────────────────────────────────────────────────
;;  Deep Noise Engine — WebAssembly DSP core
;;  레이어: White / Pink / Brown / Deep(서브 베이스) / 빗방울(푸아송 드롭 + 잔빗소리)
;;          / 기차(레일 이음매 덜컹) / 벽난로(군집 푸아송 타닥·펑 + 불꽃 일렁임)
;;          / 시냇물(음높이가 올라가는 공기방울) / 바람(돌풍 엔벨로프 + 공진 휘파람) / 여름밤(풀벌레 울음)
;;  빗소리 모델은 Andy Farnell "Designing Sound"의 절차적 접근을 따른다:
;;  지속적인 배경(브라운·핑크 노이즈 베드) + 푸아송 과정으로 도착하는 개별 방울.
;;  방울 간격은 지수분포(−ln U / λ)로 뽑고, 방울마다 크기·종류(유리 '톡' / 잎 '툭')·
;;  공진 밴드패스 주파수와 Q·스테레오 위치를 무작위로 정해 짧은 노이즈 임펄스를 울린다.
;;  세 장면의 개별 사건은 같은 이벤트 보이스 풀(노이즈 임펄스 → 공진 BP)을 쓰고 스케줄러만 다르다:
;;    빗방울 = 푸아송 과정, 기차 = 대차 2개 × 차축 2개가 레일 이음매를 지나는 주기 패턴,
;;    벽난로 = 군집 푸아송(Neyman–Scott: 군집 도착은 푸아송, 군집 안의 타닥은 짧은 지수 간격).
;;  시냇물·여름밤은 같은 보이스의 사인 모드(노이즈 대신 사인파 → BP 없이)를 쓴다:
;;    공기방울 = 푸아송 도착, 터지면서 음높이가 지수적으로 올라가는 사인(Minnaert 공명, van den Doel),
;;    풀벌레 = 개체 셋이 각자의 주기로 '찌르르'(짧은 사인 펄스 묶음)를 반복.
;;  바람 = 2단 평활 노이즈 돌풍(≈0.1 Hz)이 베드 세기와 공진 휘파람(노이즈 → BP)의 세기·음높이를 함께 흔든다.
;;  실내(독서실·사무실) = 조용한 실내 공기(베드) + 사람의 활동:
;;    책상 위 손길 = 군집 푸아송(타이핑 한 묶음 / 필기 한 줄) 안에서 고른 리듬으로 이어지는 사건 —
;;      키보드 = 짧은 '딸깍'(키캡) + 낮은 '톡'(바닥에 닿음) + 늦게 오는 작은 복귀음,
;;      연필 = 어택이 느린 넓은 대역 '스슥'(보이스별 어택) + 종이 결의 미세한 알갱이,
;;    책장 넘김 = 드문 푸아송 도착, 느리게 부푸는 '사락'(공기) + 종이가 구겨지는 알갱이 묶음,
;;    먼 대화 = 화자 둘의 성대 펄스(톱니파, 억양) → 모음 포먼트 BP 둘, 음절(≈4 Hz)·문장(말/쉼) 엔벨로프.
;;  체인:  믹스 → 베이스 셸프 → 로우패스(Q, +스웰 변조) → 하이패스(Q) → Air
;;         → 스웰 AM → 웜스(새츄레이션) → DC 차단 → 엔벨로프·마스터
;;         → 스테레오 링크 룩어헤드 피크 리미터(−2 dBFS) → 소프트 니 클리퍼(0 dBFS 천장)
;;  필터는 TPT 상태변수필터(Simper): RBJ 바이쿼드와 같은 2차 응답이면서
;;  컷오프를 실시간으로 움직여도 안정적이고 지퍼 노이즈가 적다.
;; ─────────────────────────────────────────────────────────────
(module
  (import "m" "tan" (func $tan (param f64) (result f64)))
  (import "m" "sin" (func $sin (param f64) (result f64)))
  (import "m" "cos" (func $cos (param f64) (result f64)))
  (import "m" "log" (func $log (param f64) (result f64)))
  (import "m" "exp" (func $exp (param f64) (result f64)))
  (memory (export "memory") 1)

  ;; ── 메모리 맵 ──────────────────────────────────────────────
  ;; 0     출력 L (128 f32)      512   출력 R (128 f32)
  ;; 1024  채널 L 상태 (128B)    1152  채널 R 상태 (128B)
  ;; 1280  딥 레이어 상태        1344  공통 RNG     1348  방울 스케줄러 RNG
  ;; 2048  필터 계수 (각 16B: a1 a2 a3 k)
  ;; 3072  파라미터 목표값 (128 f32)   3584  파라미터 현재값(스무딩)
  ;; 1352  불꽃 일렁임 RNG   1356  돌풍 RNG   1360  풀벌레 개체 3 × 16B (다음 울음·남은 펄스·다음 펄스)
  ;; 1408  먼 대화 화자 2 × 96B (아래 $talker 참고)   1600  대화 RNG
  ;; 1616  타이핑 스케줄러, 1632 필기 스케줄러 (각 16B: 다음 묶음까지 샘플, 남은 사건 수, 다음 사건까지 샘플, 묶음 위치)
  ;; 4096  이벤트 보이스 풀 32 × 128B (고정 할당, 라운드로빈 재사용)
  ;;       공통: 16..28 svf 계수, 32 게인, 36/40 팬 L/R, 44 활성, 52 감쇠
  ;;       채널별(L = +0, R = +64): 0/4 svf, 8 원 엔벨로프, 12 어택 스무딩 엔벨로프, 48 rng, 56 시작 지연(샘플),
;;       60 사인 위상(0..1)
;;       사인 모드: 84 위상 증가량(주기/샘플), 88 샘플당 음높이 배수, 92 모드(0 노이즈 BP, 1 사인)
;;       96 어택 스무딩 계수(기본 ≈0.25 ms — 연필 '스슥'·책장 '사락'은 느리게 부푼다)
  ;; 8192  리미터 룩어헤드 L (64 f32)   8448  리미터 룩어헤드 R (64 f32)
  ;;
  ;; 채널 상태 오프셋: 0 rng, 4..28 pink b0..b6, 32 brown,
  ;; 36/40 bass svf, 44/48 lp svf, 52 air lp, 56 dc x1, 60 dc y1,
  ;; 64/68 잔빗소리 svf, 72 env, 76 다음 트리거까지 샘플, 80 rng, 88/92 hp svf,
  ;; 96/100 lp 2단 svf, 104 잔빗소리 env(어택 스무딩), 108/112 타격음 버스 LP svf, 116/120 바람 휘파람 BP svf
  ;; 필터 계수: 2048/2064 deep, 2080 bass, 2096 lp, 2112 lp 2단, 2128 잔빗소리, 2144 hp, 2160 타격음 버스 LP,
  ;;            2176 바람 휘파람 BP, 2192 + 48·화자: 포먼트 F1·F2 BP, 거리 LP
  ;;
  ;; 파라미터: 0 마스터, 1-4 white/pink/brown/deep, 5 서브 주파수, 6 베이스,
  ;; 7 LP 컷오프, 8 air, 9 폭, 10/11 스웰 깊이/속도, 12 방울 레벨, 13 방울 빈도 λ(회/초),
  ;; 14 웜스, 15 LP Q, 16 HP 컷오프(<10.5Hz면 바이패스), 17 HP Q,
  ;; 18 게이트(0/1, 스무딩 없이 목표값 사용), 19 페이드 인(초), 20 페이드 아웃(초),
  ;; 21 '톡' 중심(Hz), 22 '툭' 중심(Hz), 23 톡 비율, 24 '툭' 임펄스 감쇠(ms),
  ;; 25 잔빗소리 레벨, 26 잔빗소리 빈도 배수(λ 대비), 27 방울 음높이 배수,
  ;; 28 LP 기울기(0 = 12 dB/oct, 1 = 24 dB/oct, 사이는 크로스페이드),
  ;; 29 기차 덜컹 레벨, 30 이음매 주기(초), 31 덜컹 저역 '쿵' 중심(Hz), 32 금속성 '칵' 중심(Hz), 33 덜컹 음높이 배수,
  ;; 34 벽난로 타닥 레벨, 35 군집 도착 빈도(/초), 36 군집당 평균 타닥 수, 37 타닥 중심(Hz),
  ;; 38 '펑' 비율, 39 불꽃 일렁임 깊이, 40 '펑' 중심(Hz),
;; 41 시냇물 방울 레벨, 42 방울 빈도 λ(회/초), 43 방울 중심(Hz), 44 방울 음높이 상승(감쇠 시간당 배수 − 1), 45 방울 음높이 배수,
;; 46 돌풍 깊이, 47 돌풍 속도(Hz), 48 휘파람 레벨, 49 휘파람 중심(Hz),
;; 51 풀벌레 레벨, 52 울음 주기(초), 53 풀벌레 음높이(Hz), 54 울음당 펄스 수, 55 펄스 빈도(Hz),
  ;; 56 두 번째 종 음높이(Hz, 0이면 첫 종 × 0.94), 57 장면 출력 보정 게인(배수, 기본 1 — 레이어가 최대여도 모자란 음량을 채운다)
  ;; 58 타이핑 레벨, 59 묶음 도착 빈도(/초), 60 묶음당 평균 타수, 61 묶음 안 리듬(타/초), 62 키캡 중심(Hz), 68 타이핑 음높이 배수,
  ;; 69 필기 레벨, 70 한 줄 도착 빈도(/초), 71 줄당 평균 획 수, 72 줄 안 리듬(획/초), 73 연필 중심(Hz), 74 필기 음높이 배수,
  ;; 64 책장 넘김 레벨, 65 책장 넘김 빈도(/초), 66 먼 대화 레벨, 67 대화 거리 LP(Hz)

  (global $sr     (mut f32) (f32.const 48000))
  (global $lo     (mut f32) (f32.const 0))
  (global $bp     (mut f32) (f32.const 0))
  (global $mA     (mut f32) (f32.const 1))   ;; 공통 노이즈 비율
  (global $mB     (mut f32) (f32.const 0))   ;; 채널 독립 노이즈 비율
  (global $dropT  (mut f32) (f32.const 0))   ;; 다음 방울까지 남은 샘플
  (global $vi     (mut i32) (i32.const 0))   ;; 다음에 쓸 보이스
  (global $dL     (mut f32) (f32.const 0))
  (global $dR     (mut f32) (f32.const 0))
  (global $pitD   (mut f32) (f32.const 0.993))
  (global $pitA   (mut f32) (f32.const 0.03))    ;; 잔빗소리 어택 스무딩 계수
  (global $brA    (mut f32) (f32.const 0.980392)) ;; 브라운 누설 계수(샘플레이트 보정)
  (global $airC   (mut f32) (f32.const 0.3))
  (global $dcR    (mut f32) (f32.const 0.998))
  (global $s1 (mut f32) (f32.const 0)) (global $c1 (mut f32) (f32.const 1))
  (global $s2 (mut f32) (f32.const 0)) (global $c2 (mut f32) (f32.const 1))
  (global $swCur  (mut f32) (f32.const 1))
  (global $lpG    (mut f32) (f32.const 1))   ;; 공진 보정 게인
  (global $hpG    (mut f32) (f32.const 1))
  (global $hpOn   (mut i32) (i32.const 0))
  (global $envL   (mut f32) (f32.const 0))   ;; 앰플리튜드 엔벨로프 0..1
  (global $dropA  (mut f32) (f32.const 0.08))   ;; 방울 어택 스무딩 계수(≈0.25 ms)
  (global $limPk  (mut f32) (f32.const 0))      ;; 리미터 피크 추종값
  (global $limG   (mut f32) (f32.const 1))      ;; 리미터 현재 게인
  (global $limAt  (mut f32) (f32.const 0.08))   ;; 게인 하강(어택) 계수 ≈0.25 ms
  (global $limRl  (mut f32) (f32.const 0.9998)) ;; 피크 추종 릴리스 ≈100 ms
  (global $li     (mut i32) (i32.const 0))      ;; 룩어헤드 링 버퍼 위치(바이트)
  (global $LIM  f32 (f32.const 0.794))   ;; 리미터 천장 −2 dBFS
  (global $KNEE f32 (f32.const 0.9))     ;; 클리퍼가 휘기 시작하는 지점

  ;; 레이어별 RMS 보정 게인
  (global $GW f32 (f32.const 0.90))   ;; 화이트: 다른 색과 같은 출력 RMS가 되도록(샤워처럼 화이트가 주인 장면에서 레벨이 모자라지 않게)
  (global $GP f32 (f32.const 0.95))
  (global $GB f32 (f32.const 0.95))
  (global $GD f32 (f32.const 1.5))
  (global $GR f32 (f32.const 16))    ;; 방울 (보이스 출력이 좁은 대역이라 큼)
  (global $GT f32 (f32.const 4.5))   ;; 잔빗소리
  (global $GC f32 (f32.const 16))    ;; 기차 덜컹
  (global $GK f32 (f32.const 16))    ;; 벽난로 타닥
  (global $GS f32 (f32.const 2.5))   ;; 사인 보이스(시냇물 방울·풀벌레): 짧은 펄스라 평균 파워가 작다
  (global $GH f32 (f32.const 2))     ;; 바람 휘파람
  (global $GA f32 (f32.const 16))    ;; 책상 손길·책장 넘김
  (global $GM f32 (f32.const 0.5))   ;; 먼 대화
  ;; 책장 넘김: 다음 넘김까지 샘플, 남은 알갱이 수, 다음 알갱이까지 샘플, 위치
  (global $pgT (mut f32) (f32.const 0)) (global $pgN (mut i32) (i32.const 0))
  (global $pgG (mut f32) (f32.const 0)) (global $pgP (mut f32) (f32.const 0))
  (global $tkL (mut f32) (f32.const 0)) (global $tkR (mut f32) (f32.const 0))   ;; 대화 출력
  (global $tkA (mut f32) (f32.const 0.002))   ;; 음절 엔벨로프 스무딩(≈10 ms)
  ;; 시냇물 스케줄러: 다음 방울까지 샘플
  (global $bbT (mut f32) (f32.const 0))
  ;; 돌풍: 불꽃 일렁임과 같은 2단 평활 노이즈, 속도는 파라미터(블록마다 계수·정규화 갱신)
  (global $gu1 (mut f32) (f32.const 0)) (global $gu2 (mut f32) (f32.const 0))
  (global $guC (mut f32) (f32.const 0.00001)) (global $guN (mut f32) (f32.const 1))
  (global $gn  (mut f32) (f32.const 0))   ;; 현재 돌풍 값(분산 1)
  (global $wg  (mut f32) (f32.const 1))   ;; 돌풍 베드 게인

  ;; 기차 스케줄러: 다음 타격까지 샘플, 패턴 위치(0..3), 속도 흔들림
  (global $ckT (mut f32) (f32.const 0)) (global $ckI (mut i32) (i32.const 0)) (global $ckD (mut f32) (f32.const 0))
  ;; 벽난로 스케줄러: 다음 군집까지 샘플, 군집에 남은 타닥 수, 다음 타닥까지 샘플, 군집 위치
  (global $crT (mut f32) (f32.const 0)) (global $crN (mut i32) (i32.const 0))
  (global $crG (mut f32) (f32.const 0)) (global $crP (mut f32) (f32.const 0))
  ;; 불꽃 일렁임: 2단 평활 노이즈(≈2.5 Hz) → 분산 1로 정규화 → 베드 게인
  (global $fl1 (mut f32) (f32.const 0)) (global $fl2 (mut f32) (f32.const 0))
  (global $flC (mut f32) (f32.const 0.0003)) (global $flN (mut f32) (f32.const 1))
  (global $fn  (mut f32) (f32.const 0))   ;; 현재 일렁임 값(분산 1)
  (global $fg  (mut f32) (f32.const 1))   ;; 베드 게인

  (func $p (param $id i32) (result f32)
    (f32.load (i32.add (i32.const 3584) (i32.shl (local.get $id) (i32.const 2)))))

  ;; xorshift32 → [-1, 1)
  (func $rand (param $a i32) (result f32) (local $x i32)
    (local.set $x (i32.load (local.get $a)))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 13))))
    (local.set $x (i32.xor (local.get $x) (i32.shr_u (local.get $x) (i32.const 17))))
    (local.set $x (i32.xor (local.get $x) (i32.shl (local.get $x) (i32.const 5))))
    (i32.store (local.get $a) (local.get $x))
    (f32.mul (f32.convert_i32_s (local.get $x)) (f32.const 4.656613e-10)))

  ;; 부드러운 포화 (rational tanh 근사)
  (func $sat (param $x f32) (result f32) (local $x2 f32)
    (local.set $x (f32.min (f32.const 3) (f32.max (f32.const -3) (local.get $x))))
    (local.set $x2 (f32.mul (local.get $x) (local.get $x)))
    (f32.div (f32.mul (local.get $x) (f32.add (f32.const 27) (local.get $x2)))
             (f32.add (f32.const 27) (f32.mul (f32.const 9) (local.get $x2)))))

  ;; 소프트 니 클리퍼: |x| ≤ KNEE는 그대로(무왜곡), 그 위는 tanh형 곡선으로 1.0에 접근.
  ;; $sat(3) = 1이고 기울기 0이라 |x| ≥ KNEE + 3(1−KNEE)에서도 꺾임 없이 천장에 붙는다.
  (func $clip (param $x f32) (result f32) (local $a f32)
    (local.set $a (f32.abs (local.get $x)))
    (if (result f32) (f32.le (local.get $a) (global.get $KNEE))
      (then (local.get $x))
      (else (f32.copysign
        (f32.add (global.get $KNEE)
          (f32.mul (f32.sub (f32.const 1) (global.get $KNEE))
            (call $sat (f32.div (f32.sub (local.get $a) (global.get $KNEE))
                                (f32.sub (f32.const 1) (global.get $KNEE))))))
        (local.get $x)))))

  ;; TPT 상태변수필터 계수 (Simper)
  (func $svfcoef (param $c i32) (param $fc f32) (param $q f32)
    (local $g f32) (local $k f32) (local $a1 f32)
    (local.set $fc (f32.min (local.get $fc) (f32.mul (global.get $sr) (f32.const 0.45))))
    (local.set $fc (f32.max (local.get $fc) (f32.const 5)))
    (local.set $g (f32.demote_f64 (call $tan (f64.promote_f32
      (f32.div (f32.mul (f32.const 3.14159265) (local.get $fc)) (global.get $sr))))))
    (local.set $k (f32.div (f32.const 1) (f32.max (local.get $q) (f32.const 0.3))))
    (local.set $a1 (f32.div (f32.const 1)
      (f32.add (f32.const 1) (f32.mul (local.get $g) (f32.add (local.get $g) (local.get $k))))))
    (f32.store (local.get $c) (local.get $a1))
    (f32.store offset=4 (local.get $c) (f32.mul (local.get $g) (local.get $a1)))
    (f32.store offset=8 (local.get $c) (f32.mul (local.get $g) (f32.mul (local.get $g) (local.get $a1))))
    (f32.store offset=12 (local.get $c) (local.get $k)))

  ;; SVF 1샘플 처리 → $lo, $bp
  (func $svf (param $s i32) (param $c i32) (param $x f32)
    (local $ic1 f32) (local $ic2 f32) (local $v1 f32) (local $v2 f32) (local $v3 f32)
    (local.set $ic1 (f32.load (local.get $s)))
    (local.set $ic2 (f32.load offset=4 (local.get $s)))
    (local.set $v3 (f32.sub (local.get $x) (local.get $ic2)))
    (local.set $v1 (f32.add (f32.mul (f32.load (local.get $c)) (local.get $ic1))
                            (f32.mul (f32.load offset=4 (local.get $c)) (local.get $v3))))
    (local.set $v2 (f32.add (local.get $ic2)
                   (f32.add (f32.mul (f32.load offset=4 (local.get $c)) (local.get $ic1))
                            (f32.mul (f32.load offset=8 (local.get $c)) (local.get $v3)))))
    (f32.store (local.get $s) (f32.sub (f32.mul (f32.const 2) (local.get $v1)) (local.get $ic1)))
    (f32.store offset=4 (local.get $s) (f32.sub (f32.mul (f32.const 2) (local.get $v2)) (local.get $ic2)))
    (global.set $lo (local.get $v2))
    (global.set $bp (local.get $v1)))

  ;; ── 초기화 ─────────────────────────────────────────────────
  (func (export "init") (param $sr f32)
    (local $i i32)
    (global.set $sr (local.get $sr))
    (local.set $i (i32.const 1024))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (i32.const 1648)))
      (i32.store (local.get $i) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $l)))
    (local.set $i (i32.const 4096))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (i32.const 8704)))
      (i32.store (local.get $i) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $l)))
    (i32.store (i32.const 1024) (i32.const 0x2545F491))
    (i32.store (i32.const 1152) (i32.const 0x9E3779B9))
    (i32.store (i32.const 1104) (i32.const 0x7F4A7C15))
    (i32.store (i32.const 1232) (i32.const 0x1B873593))
    (i32.store (i32.const 1344) (i32.const 0x68E31DA4))
    (i32.store (i32.const 1348) (i32.const 0x3C6EF372))
    (i32.store (i32.const 1352) (i32.const 0x510E527F))
    (i32.store (i32.const 1356) (i32.const 0x1F83D9AB))
    (i32.store (i32.const 1600) (i32.const 0x5BE0CD19))
    ;; 화자 둘: 낮은 목소리(≈115 Hz)와 높은 목소리(≈205 Hz), 첫 말은 엇갈리게
    (f32.store (i32.const 1452) (f32.const 115))
    (f32.store (i32.const 1548) (f32.const 205))
    (f32.store (i32.const 1412) (f32.const 115))
    (f32.store (i32.const 1508) (f32.const 205))
    (f32.store (i32.const 1428) (f32.const 20000))
    (f32.store (i32.const 1524) (f32.const 90000))
    (f32.store (i32.const 1436) (f32.const 500)) (f32.store (i32.const 1440) (f32.const 1500))
    (f32.store (i32.const 1532) (f32.const 500)) (f32.store (i32.const 1536) (f32.const 1500))
    (f32.store (i32.const 1616) (f32.const 24000))
    (f32.store (i32.const 1632) (f32.const 60000))
    (global.set $pgT (f32.const 240000)) (global.set $pgN (i32.const 0)) (global.set $pgG (f32.const 0))
    (global.set $tkL (f32.const 0)) (global.set $tkR (f32.const 0))
    (global.set $tkA (f32.sub (f32.const 1) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -100) (local.get $sr)))))))
    ;; 풀벌레 첫 울음을 엇갈리게
    (f32.store (i32.const 1360) (f32.const 9000))
    (f32.store (i32.const 1376) (f32.const 23000))
    (f32.store (i32.const 1392) (f32.const 37000))
    (f32.store (i32.const 1100) (f32.const 1000))   ;; 잔빗소리 첫 트리거 L/R 엇갈리게
    (f32.store (i32.const 1228) (f32.const 1700))
    (global.set $dropT (f32.const 2000)) (global.set $vi (i32.const 0))
    (global.set $limPk (f32.const 0)) (global.set $limG (f32.const 1)) (global.set $li (i32.const 0))
    (global.set $ckT (f32.const 4000)) (global.set $ckI (i32.const 0)) (global.set $ckD (f32.const 0))
    (global.set $crT (f32.const 3000)) (global.set $crN (i32.const 0)) (global.set $crG (f32.const 0))
    (global.set $fl1 (f32.const 0)) (global.set $fl2 (f32.const 0)) (global.set $fn (f32.const 0)) (global.set $fg (f32.const 1))
    (global.set $bbT (f32.const 1500))
    (global.set $gu1 (f32.const 0)) (global.set $gu2 (f32.const 0)) (global.set $gn (f32.const 0)) (global.set $wg (f32.const 1))
    ;; 일렁임 평활 계수(2.5 Hz)와 정규화: 같은 1차 LP 두 단의 임펄스 응답 제곱합
    ;; Σh² = c⁴(1+a²)/(1−a²)³ (a = 1−c), 균등 노이즈 분산 1/3
    (global.set $flC (f32.sub (f32.const 1) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -15.70796) (local.get $sr)))))))
    (call $flnorm)
    ;; 방울 어택 ≈ 0.25 ms: 네모난 시작이 만드는 광대역 '틱'을 둥글린다
    (global.set $dropA (f32.sub (f32.const 1) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -4000) (local.get $sr)))))))
    ;; 리미터: 게인 하강 ≈ 0.25 ms(룩어헤드 1.33 ms 안에 99% 도달), 피크 릴리스 ≈ 100 ms
    (global.set $limAt (global.get $dropA))
    (global.set $limRl (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -10) (local.get $sr))))))
    ;; 잔빗소리 버스트 감쇠 ≈ 3 ms
    ;; 잔빗소리 어택 ≈ 0.8 ms: 계단식 시작이 만드는 광대역 '틱'(지지직거림)을 없앤다
    (global.set $pitA (f32.sub (f32.const 1) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -1250) (local.get $sr)))))))
    ;; 브라운 적분기 코너 ≈ 151 Hz (48 kHz에서 기존 0.980392와 같고, 다른 샘플레이트에서도 같은 색)
    (global.set $brA (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -950.6) (local.get $sr))))))
    (global.set $pitD (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -333) (local.get $sr))))))
    (call $svfcoef (i32.const 2080) (f32.const 90) (f32.const 0.7))     ;; bass shelf
    (global.set $airC (f32.min (f32.const 1)
      (f32.div (f32.mul (f32.const 6.2831853) (f32.const 2500)) (global.get $sr))))
    (global.set $dcR (f32.sub (f32.const 1)
      (f32.div (f32.mul (f32.const 6.2831853) (f32.const 12)) (global.get $sr))))
    (global.set $s1 (f32.const 0)) (global.set $c1 (f32.const 1))
    (global.set $s2 (f32.const 0.6)) (global.set $c2 (f32.const 0.8))
    (global.set $envL (f32.const 0))
    ;; 출력 보정 게인 기본값 1(호스트가 보내지 않아도 소리가 나게)
    (f32.store (i32.const 3300) (f32.const 1))
    (f32.store (i32.const 3812) (f32.const 1))
    ;; 손길 음높이 배수 기본값 1
    (f32.store (i32.const 3344) (f32.const 1)) (f32.store (i32.const 3856) (f32.const 1))
    (f32.store (i32.const 3368) (f32.const 1)) (f32.store (i32.const 3880) (f32.const 1)))

  (func $flnorm (global.set $flN (call $lpnorm (global.get $flC))))

  ;; 1차 LP(계수 c) 두 단을 지난 균등 노이즈를 분산 1로 만드는 배수
  (func $lpnorm (param $cf f32) (result f32) (local $c f64) (local $a f64) (local $b f64) (local $c4 f64) (local $v f64)
    (local.set $c (f64.promote_f32 (local.get $cf)))
    (local.set $a (f64.sub (f64.const 1) (local.get $c)))
    (local.set $b (f64.sub (f64.const 1) (f64.mul (local.get $a) (local.get $a))))
    (local.set $c4 (f64.mul (f64.mul (local.get $c) (local.get $c)) (f64.mul (local.get $c) (local.get $c))))
    (local.set $v (f64.div (f64.mul (f64.mul (f64.const 0.333333) (local.get $c4))
                                    (f64.add (f64.const 1) (f64.mul (local.get $a) (local.get $a))))
                           (f64.mul (local.get $b) (f64.mul (local.get $b) (local.get $b)))))
    (f32.demote_f64 (f64.div (f64.const 1) (f64.sqrt (local.get $v)))))

  ;; 현재 엔벨로프 레벨 (0이면 완전 무음)
  (func (export "env") (result f32) (global.get $envL))

  ;; Q가 높을수록 공진 피크가 커지므로 레벨을 낮춰 헤드룸 확보
  (func $qcomp (param $q f32) (result f32)
    (f32.div (f32.const 1) (f32.sqrt (f32.max (f32.const 1) (f32.mul (local.get $q) (f32.const 1.4142136))))))

  (func (export "setParam") (param $id i32) (param $v f32)
    (f32.store (i32.add (i32.const 3072) (i32.shl (local.get $id) (i32.const 2))) (local.get $v)))

  ;; 마스터 볼륨(0)을 제외한 모든 파라미터를 즉시 목표값으로
  (func (export "snap") (local $i i32)
    (local.set $i (i32.const 1))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (i32.const 128)))
      (f32.store (i32.add (i32.const 3584) (i32.shl (local.get $i) (i32.const 2)))
        (f32.load (i32.add (i32.const 3072) (i32.shl (local.get $i) (i32.const 2)))))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $l))))

  ;; ── 빗방울: 푸아송 스케줄러 + 보이스 풀 ─────────────────────
  (func $u01 (param $a i32) (result f32)
    (f32.mul (f32.add (call $rand (local.get $a)) (f32.const 1)) (f32.const 0.5)))

  ;; 푸아송 과정의 도착 간격: −ln(1−U)·sr/λ  (지수분포, 샘플 단위)
  (func $interval (param $a i32) (param $rate f32) (result f32)
    (if (result f32) (f32.lt (local.get $rate) (f32.const 0.01))
      (then (f32.const 1e9))
      (else (f32.max (f32.const 1)
        (f32.div (f32.mul (f32.neg (f32.demote_f64 (call $log (f64.promote_f32
                   (f32.sub (f32.const 1) (call $u01 (local.get $a)))))))
                          (global.get $sr))
                 (local.get $rate))))))

  (func $pow2 (param $x f32) (result f32)
    (f32.demote_f64 (call $exp (f64.promote_f32 (f32.mul (local.get $x) (f32.const 0.6931472))))))

  ;; 이벤트 하나를 가장 오래된 보이스에 할당: 노이즈 임펄스(지수 감쇠 τ ms) → 공진 BP(fc, Q)
  ;; amp는 BP 정규화 전 진폭, pan은 −1..1
  (func $voice (param $fc f32) (param $q f32) (param $tau f32) (param $amp f32) (param $pan f32)
    (local $v i32) (local $late i32)
    (local.set $v (i32.add (i32.const 4096) (i32.shl (global.get $vi) (i32.const 7))))
    (global.set $vi (i32.and (i32.add (global.get $vi) (i32.const 1)) (i32.const 31)))
    (call $svfcoef (i32.add (local.get $v) (i32.const 16)) (local.get $fc) (local.get $q))
    (f32.store offset=96 (local.get $v) (global.get $dropA))
    (local.set $tau (f32.min (f32.const 600) (f32.max (f32.const 0.3) (local.get $tau))))
    (f32.store offset=52 (local.get $v) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -1000) (f32.mul (local.get $tau) (global.get $sr)))))))
    ;; 게인: 진폭 × k(BP 피크를 1로) × √Q(좁은 대역의 에너지 손실 보상)
    (f32.store offset=32 (local.get $v)
      (f32.mul (local.get $amp) (f32.mul (f32.load offset=28 (local.get $v)) (f32.sqrt (local.get $q)))))
    ;; 등전력 팬
    (local.set $pan (f32.min (f32.const 0.95) (f32.max (f32.const -0.95) (local.get $pan))))
    (f32.store offset=36 (local.get $v) (f32.sqrt (f32.mul (f32.const 0.5) (f32.sub (f32.const 1) (local.get $pan)))))
    (f32.store offset=40 (local.get $v) (f32.sqrt (f32.mul (f32.const 0.5) (f32.add (f32.const 1) (local.get $pan)))))
    ;; 스테레오 디코릴레이션: L/R이 각자 독립된 노이즈로 울려 공진 위상이 서로 무작위이고,
    ;; 작게 들리는 쪽은 2–10 ms 늦게 시작한다(먼저 도착한 쪽으로 정위되는 선행음 효과와 같은 방향)
    (f32.store offset=8   (local.get $v) (f32.const 1))
    (f32.store offset=72  (local.get $v) (f32.const 1))
    (f32.store offset=12  (local.get $v) (f32.const 0))
    (f32.store offset=76  (local.get $v) (f32.const 0))
    (f32.store offset=56  (local.get $v) (f32.const 0))
    (f32.store offset=120 (local.get $v) (f32.const 0))
    (local.set $late (select (i32.const 56) (i32.const 120) (f32.gt (local.get $pan) (f32.const 0))))
    (f32.store (i32.add (local.get $v) (local.get $late))
      (f32.mul (f32.add (f32.const 0.002) (f32.mul (f32.const 0.008) (call $u01 (i32.const 1348)))) (global.get $sr)))
    (i32.store offset=48  (local.get $v) (i32.or (i32.load (i32.const 1348)) (i32.const 1)))
    (drop (call $rand (i32.const 1348)))
    (i32.store offset=112 (local.get $v) (i32.or (i32.load (i32.const 1348)) (i32.const 1)))
    (i32.store offset=92 (local.get $v) (i32.const 0))
    (i32.store offset=44 (local.get $v) (i32.const 1)))

  ;; 사인 보이스: 노이즈 BP 대신 사인파(무작위 시작 위상, L/R 따로). glide = 감쇠 시간 τ 동안 음높이가 (1+glide)배.
  ;; 공기방울은 터지며 반지름이 줄어 공명(Minnaert)이 올라가고, 풀벌레는 glide 0의 짧은 펄스다.
  (func $tone (param $fc f32) (param $tau f32) (param $amp f32) (param $pan f32) (param $glide f32)
    (local $v i32)
    (local.set $v (i32.add (i32.const 4096) (i32.shl (global.get $vi) (i32.const 7))))
    (call $voice (local.get $fc) (f32.const 1) (local.get $tau) (local.get $amp) (local.get $pan))
    (local.set $tau (f32.min (f32.const 600) (f32.max (f32.const 0.3) (local.get $tau))))
    (i32.store offset=92 (local.get $v) (i32.const 1))
    (f32.store offset=32 (local.get $v) (local.get $amp))
    (f32.store offset=84 (local.get $v) (f32.div (f32.min (local.get $fc) (f32.mul (global.get $sr) (f32.const 0.45))) (global.get $sr)))
    (f32.store offset=88 (local.get $v) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.mul (f32.demote_f64 (call $log (f64.promote_f32 (f32.add (f32.const 1) (f32.max (f32.const 0) (local.get $glide))))))
                        (f32.const 1000))
               (f32.mul (local.get $tau) (global.get $sr)))))))
    (f32.store offset=60  (local.get $v) (call $u01 (i32.const 1348)))
    (f32.store offset=124 (local.get $v) (call $u01 (i32.const 1348))))

  ;; 사인 근사(위상 0..1 → sin 2π·위상): 포물선 + 1회 보정, 최대 오차 ≈0.1%
  (func $sinp (param $p f32) (result f32) (local $u f32) (local $y f32)
    (local.set $u (f32.sub (f32.mul (f32.const 2) (local.get $p)) (f32.const 1)))     ;; −1..1, sin(2πp) = −sin(πu)
    (local.set $y (f32.mul (f32.const 4) (f32.mul (local.get $u) (f32.sub (f32.const 1) (f32.abs (local.get $u))))))
    (f32.neg (f32.add (local.get $y) (f32.mul (f32.const 0.225)
      (f32.sub (f32.mul (local.get $y) (f32.abs (local.get $y))) (local.get $y))))))

  ;; 시냇물 공기방울 하나: 크기 U² 분포(작은 방울이 많다), 작을수록 높고 짧게 울린다
  (func $bubble (local $sz f32) (local $fc f32) (local $lv f32)
    (local.set $lv (f32.mul (call $p (i32.const 41)) (global.get $GS)))
    (if (f32.le (local.get $lv) (f32.const 1e-4)) (then (return)))
    (local.set $sz (call $u01 (i32.const 1348)))
    (local.set $sz (f32.mul (local.get $sz) (local.get $sz)))
    ;; 중심에서 ±0.9 oct 흔들고, 큰 방울은 아래로
    (local.set $fc (f32.mul (f32.mul (call $p (i32.const 43)) (call $p (i32.const 45)))
      (call $pow2 (f32.sub (f32.mul (f32.const 0.9) (call $rand (i32.const 1348))) (f32.mul (f32.const 0.9) (f32.sub (local.get $sz) (f32.const 0.3)))))))
    (call $tone (local.get $fc)
      ;; 감쇠 ≈ 9 ms × √(700/f), 3–25 ms
      (f32.min (f32.const 25) (f32.max (f32.const 3)
        (f32.mul (f32.mul (f32.const 9) (f32.sqrt (f32.div (f32.const 700) (local.get $fc))))
                 (f32.add (f32.const 0.7) (f32.mul (f32.const 0.6) (call $u01 (i32.const 1348)))))))
      (f32.mul (local.get $lv) (f32.add (f32.const 0.2) (f32.mul (f32.const 0.8) (local.get $sz))))
      (f32.mul (f32.const 0.8) (call $rand (i32.const 1348)))
      (f32.mul (call $p (i32.const 44)) (f32.add (f32.const 0.5) (call $u01 (i32.const 1348))))))

  ;; 풀벌레 한 개체(i = 0..2)의 1샘플: 주기마다 울음 하나 = 펄스 K개(사인, 감쇠 6 ms)
  ;; 개체마다 주기·음높이·위치·세기가 조금씩 다르고, 주기는 울음마다 ±8% 흔들린다
  (func $cricket (param $i i32) (param $per f32) (param $fc f32) (param $pan f32) (param $g f32)
    (local $a i32) (local $lv f32)
    (local.set $a (i32.add (i32.const 1360) (i32.shl (local.get $i) (i32.const 4))))
    (f32.store (local.get $a) (f32.sub (f32.load (local.get $a)) (f32.const 1)))
    (if (f32.le (f32.load (local.get $a)) (f32.const 0))
      (then
        (f32.store offset=4 (local.get $a) (f32.max (f32.const 1) (f32.nearest (call $p (i32.const 54)))))
        (f32.store offset=8 (local.get $a) (f32.const 0))
        (f32.store (local.get $a) (f32.add (f32.load (local.get $a))
          (f32.mul (f32.mul (f32.max (f32.const 0.05) (f32.mul (call $p (i32.const 52)) (local.get $per))) (global.get $sr))
                   (f32.add (f32.const 1) (f32.mul (f32.const 0.08) (call $rand (i32.const 1348)))))))))
    (if (f32.gt (f32.load offset=4 (local.get $a)) (f32.const 0))
      (then
        (f32.store offset=8 (local.get $a) (f32.sub (f32.load offset=8 (local.get $a)) (f32.const 1)))
        (if (f32.le (f32.load offset=8 (local.get $a)) (f32.const 0))
          (then
            (local.set $lv (f32.mul (f32.mul (call $p (i32.const 51)) (global.get $GS)) (local.get $g)))
            (if (f32.gt (local.get $lv) (f32.const 1e-4))
              (then (call $tone (local.get $fc) (f32.const 6)
                      (f32.mul (local.get $lv) (f32.add (f32.const 0.8) (f32.mul (f32.const 0.2) (call $u01 (i32.const 1348)))))
                      (local.get $pan) (f32.const 0))))
            (f32.store offset=4 (local.get $a) (f32.sub (f32.load offset=4 (local.get $a)) (f32.const 1)))
            (f32.store offset=8 (local.get $a) (f32.add (f32.load offset=8 (local.get $a))
              (f32.div (global.get $sr) (f32.max (f32.const 2) (call $p (i32.const 55)))))))))))

  ;; 방금 할당한 보이스(주소)의 어택을 attack ms로, 양쪽 시작을 delay 샘플 늦춘다
  (func $shape (param $v i32) (param $attack f32) (param $delay f32)
    (f32.store offset=96 (local.get $v) (f32.sub (f32.const 1) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -1000) (f32.mul (f32.max (f32.const 0.05) (local.get $attack)) (global.get $sr))))))))
    (f32.store offset=56 (local.get $v) (f32.add (f32.load offset=56 (local.get $v)) (local.get $delay)))
    (f32.store offset=120 (local.get $v) (f32.add (f32.load offset=120 (local.get $v)) (local.get $delay))))

  (func $nextv (result i32)
    (i32.add (i32.const 4096) (i32.shl (global.get $vi) (i32.const 7))))

  ;; 책상 손길 하나. 키보드: 키캡 '딸깍'(밝고 짧음) + 바닥 '톡'(낮음) + 50–110 ms 뒤 작은 복귀음,
  ;; 가끔(8%) 스페이스·엔터처럼 크고 낮은 키. 연필: 어택 4–10 ms로 부푸는 '스슥' + 종이 결 알갱이 2–4개
  (func $desk (param $pencil i32) (param $lv f32) (param $fc f32) (param $pan f32)
    (local $u f32) (local $big f32) (local $k i32) (local $v i32)
    (local.set $pan (f32.add (local.get $pan) (f32.mul (f32.const 0.06) (call $rand (i32.const 1348)))))
    (local.set $u (call $u01 (i32.const 1348)))
    (if (i32.eqz (local.get $pencil))
      (then
        (local.set $big (select (f32.const 1) (f32.const 0) (f32.lt (call $u01 (i32.const 1348)) (f32.const 0.08))))
        ;; 키캡
        (call $voice (f32.mul (local.get $fc) (call $pow2 (f32.sub (f32.mul (f32.const 0.35) (call $rand (i32.const 1348))) (f32.mul (f32.const 0.4) (local.get $big)))))
          (f32.add (f32.const 2) (f32.mul (f32.const 2) (call $u01 (i32.const 1348))))
          (f32.add (f32.const 0.8) (f32.mul (f32.const 1.2) (call $u01 (i32.const 1348))))
          (f32.mul (local.get $lv) (f32.add (f32.const 0.5) (f32.mul (f32.const 0.5) (local.get $u))))
          (local.get $pan))
        ;; 바닥에 닿는 '톡'
        (call $voice (f32.mul (f32.mul (local.get $fc) (f32.const 0.17)) (call $pow2 (f32.sub (f32.mul (f32.const 0.25) (call $rand (i32.const 1348))) (f32.mul (f32.const 0.5) (local.get $big)))))
          (f32.add (f32.const 1.5) (call $u01 (i32.const 1348)))
          (f32.add (f32.const 3) (f32.mul (f32.const 4) (local.get $big)))
          (f32.mul (f32.mul (local.get $lv) (f32.const 0.45)) (f32.add (f32.const 1) (f32.mul (f32.const 0.6) (local.get $big))))
          (local.get $pan))
        ;; 복귀음
        (local.set $v (call $nextv))
        (call $voice (f32.mul (f32.mul (local.get $fc) (f32.const 0.8)) (call $pow2 (f32.mul (f32.const 0.3) (call $rand (i32.const 1348)))))
          (f32.const 2.5) (f32.const 1)
          (f32.mul (f32.mul (local.get $lv) (f32.const 0.25)) (local.get $u))
          (local.get $pan))
        (call $shape (local.get $v) (f32.const 0.25)
          (f32.mul (f32.add (f32.const 0.05) (f32.mul (f32.const 0.06) (call $u01 (i32.const 1348)))) (global.get $sr))))
      (else
        ;; 획: 위아래로 긋는 방향마다 결이 달라 음높이가 ±0.5 oct 흔들린다
        (local.set $v (call $nextv))
        (call $voice (f32.mul (local.get $fc) (call $pow2 (f32.mul (f32.const 0.5) (call $rand (i32.const 1348)))))
          (f32.add (f32.const 0.8) (f32.mul (f32.const 0.6) (call $u01 (i32.const 1348))))
          (f32.add (f32.const 12) (f32.mul (f32.const 30) (call $u01 (i32.const 1348))))
          (f32.mul (local.get $lv) (f32.mul (f32.const 0.35) (f32.add (f32.const 0.4) (f32.mul (f32.const 0.6) (local.get $u)))))
          (local.get $pan))
        (call $shape (local.get $v) (f32.add (f32.const 4) (f32.mul (f32.const 6) (call $u01 (i32.const 1348)))) (f32.const 0))
        (local.set $k (i32.add (i32.const 2) (i32.trunc_f32_u (f32.mul (f32.const 2.99) (call $u01 (i32.const 1348))))))
        (block $d (loop $l
          (br_if $d (i32.eqz (local.get $k)))
          (local.set $v (call $nextv))
          (call $voice (f32.mul (f32.mul (local.get $fc) (f32.const 1.3)) (call $pow2 (f32.mul (f32.const 0.6) (call $rand (i32.const 1348)))))
            (f32.const 1.5) (f32.add (f32.const 0.3) (f32.mul (f32.const 0.5) (call $u01 (i32.const 1348))))
            (f32.mul (local.get $lv) (f32.mul (f32.const 0.3) (call $u01 (i32.const 1348))))
            (local.get $pan))
          (call $shape (local.get $v) (f32.const 0.25)
            (f32.mul (f32.mul (f32.const 0.035) (call $u01 (i32.const 1348))) (global.get $sr)))
          (local.set $k (i32.sub (local.get $k) (i32.const 1)))
          (br $l))))))

  ;; 책장 넘김 알갱이: 종이가 휘며 구겨지는 짧은 '사', U³ 세기
  (func $crinkle (local $lv f32) (local $u f32)
    (local.set $lv (f32.mul (call $p (i32.const 64)) (global.get $GA)))
    (local.set $u (call $u01 (i32.const 1348)))
    (call $voice (f32.mul (f32.const 3000) (call $pow2 (f32.mul (f32.const 0.8) (call $rand (i32.const 1348)))))
      (f32.add (f32.const 1.2) (f32.mul (f32.const 2) (call $u01 (i32.const 1348))))
      (f32.add (f32.const 0.8) (f32.mul (f32.const 3) (call $u01 (i32.const 1348))))
      (f32.mul (local.get $lv) (f32.mul (f32.const 0.5) (f32.add (f32.const 0.15) (f32.mul (f32.const 0.85) (f32.mul (local.get $u) (f32.mul (local.get $u) (local.get $u)))))))
      (f32.add (global.get $pgP) (f32.mul (f32.const 0.08) (call $rand (i32.const 1348))))))

  ;; 책장 한 장: 넘어가며 공기를 미는 '사락'(어택 60–120 ms, 감쇠 ≈150 ms) + 알갱이 8–20개(평균 22 ms 간격)
  (func $page (local $lv f32) (local $v i32)
    (local.set $lv (f32.mul (call $p (i32.const 64)) (global.get $GA)))
    (global.set $pgP (f32.mul (f32.const 0.6) (call $rand (i32.const 1348))))
    (local.set $v (call $nextv))
    (call $voice (f32.mul (f32.const 1700) (call $pow2 (f32.mul (f32.const 0.4) (call $rand (i32.const 1348)))))
      (f32.const 0.7)
      (f32.add (f32.const 110) (f32.mul (f32.const 80) (call $u01 (i32.const 1348))))
      (f32.mul (local.get $lv) (f32.const 0.18))
      (global.get $pgP))
    (call $shape (local.get $v) (f32.add (f32.const 60) (f32.mul (f32.const 60) (call $u01 (i32.const 1348)))) (f32.const 0))
    (global.set $pgN (i32.add (i32.const 8) (i32.trunc_f32_u (f32.mul (f32.const 12) (call $u01 (i32.const 1348))))))
    (global.set $pgG (f32.mul (f32.const 0.02) (global.get $sr))))

  ;; 책상 손길 스케줄러 1샘플(a = 상태 주소, id = 레벨 파라미터, 그 뒤 넷이 빈도·묶음 크기·리듬·중심, pm = 음높이 배수)
  ;; 묶음 도착은 푸아송, 묶음 크기는 지수분포(평균), 묶음 안은 고른 리듬(평균 1/λ, ±40%, 가끔 멈칫)
  (func $deskSched (param $a i32) (param $id i32) (param $pm i32) (param $pencil i32) (local $k f32) (local $lv f32)
    (local.set $lv (f32.mul (call $p (local.get $id)) (global.get $GA)))
    (if (f32.le (local.get $lv) (f32.const 1e-4)) (then (return)))
    (f32.store (local.get $a) (f32.sub (f32.load (local.get $a)) (f32.const 1)))
    (if (i32.and (f32.le (f32.load (local.get $a)) (f32.const 0)) (f32.le (f32.load offset=4 (local.get $a)) (f32.const 0)))
      (then
        (local.set $k (f32.neg (f32.demote_f64 (call $log (f64.promote_f32
          (f32.sub (f32.const 1) (call $u01 (i32.const 1348))))))))
        (f32.store offset=4 (local.get $a) (f32.floor (f32.min (f32.const 80)
          (f32.add (f32.const 1) (f32.mul (local.get $k)
            (f32.max (f32.const 0) (f32.sub (call $p (i32.add (local.get $id) (i32.const 2))) (f32.const 1))))))))
        (f32.store offset=12 (local.get $a) (f32.mul (f32.const 0.25) (call $rand (i32.const 1348))))
        (f32.store offset=8 (local.get $a) (f32.const 0))
        (f32.store (local.get $a) (f32.add (f32.load (local.get $a))
          (call $interval (i32.const 1348) (call $p (i32.add (local.get $id) (i32.const 1))))))))
    (if (f32.gt (f32.load offset=4 (local.get $a)) (f32.const 0))
      (then
        (f32.store offset=8 (local.get $a) (f32.sub (f32.load offset=8 (local.get $a)) (f32.const 1)))
        (if (f32.le (f32.load offset=8 (local.get $a)) (f32.const 0))
          (then
            (call $desk (local.get $pencil) (local.get $lv)
              (f32.mul (call $p (i32.add (local.get $id) (i32.const 4))) (call $p (local.get $pm)))
              (f32.load offset=12 (local.get $a)))
            (f32.store offset=4 (local.get $a) (f32.sub (f32.load offset=4 (local.get $a)) (f32.const 1)))
            (f32.store offset=8 (local.get $a) (f32.mul
              (f32.div (global.get $sr) (f32.max (f32.const 0.5) (call $p (i32.add (local.get $id) (i32.const 3)))))
              (f32.add (f32.add (f32.const 0.6) (f32.mul (f32.const 0.8) (call $u01 (i32.const 1348))))
                (select (f32.const 1.5) (f32.const 0) (f32.lt (call $u01 (i32.const 1348)) (f32.const 0.1)))))))))))

  ;; 실내 스케줄러 1샘플: 타이핑·필기와 책장 넘김
  (func $indoor
    (call $deskSched (i32.const 1616) (i32.const 58) (i32.const 68) (i32.const 0))
    (call $deskSched (i32.const 1632) (i32.const 69) (i32.const 74) (i32.const 1))
    (if (f32.gt (call $p (i32.const 64)) (f32.const 1e-4))
      (then
        (global.set $pgT (f32.sub (global.get $pgT) (f32.const 1)))
        (if (f32.le (global.get $pgT) (f32.const 0))
          (then
            (call $page)
            (global.set $pgT (f32.add (global.get $pgT)
              (f32.max (f32.mul (f32.const 1.5) (global.get $sr)) (call $interval (i32.const 1348) (call $p (i32.const 65))))))))
        (if (global.get $pgN)
          (then
            (global.set $pgG (f32.sub (global.get $pgG) (f32.const 1)))
            (if (f32.le (global.get $pgG) (f32.const 0))
              (then
                (call $crinkle)
                (global.set $pgN (i32.sub (global.get $pgN) (i32.const 1)))
                (global.set $pgG (call $interval (i32.const 1348) (f32.const 45))))))))))

  ;; ── 먼 대화: 화자 하나(t = 1408 + 96·i) ──────────────────────
  ;; 0 성대 위상, 4 f0, 8 f0 목표, 12 엔벨로프, 16 음절에 남은 샘플, 20 말/쉼에 남은 샘플, 24 말하는 중(0/1),
  ;; 28/32 F1/F2, 36/40 F1/F2 목표, 44 기본 f0, 48/52 F1 BP, 56/60 F2 BP, 64/68 거리 LP, 72 음절 세기, 76 음절 길이
  ;; 포먼트 계수는 블록마다 갱신(process), 여기서는 샘플마다 음원·엔벨로프·필터를 돌린다.
  (func $talker (param $t i32) (param $c i32) (result f32)
    (local $ph f32) (local $x f32) (local $a f32) (local $len f32)
    ;; 말/쉼: 말 1.5–5 s, 쉼 0.6–5 s
    (f32.store offset=20 (local.get $t) (f32.sub (f32.load offset=20 (local.get $t)) (f32.const 1)))
    (if (f32.le (f32.load offset=20 (local.get $t)) (f32.const 0))
      (then
        (f32.store offset=24 (local.get $t) (f32.sub (f32.const 1) (f32.load offset=24 (local.get $t))))
        (f32.store offset=20 (local.get $t) (f32.mul (global.get $sr)
          (select (f32.add (f32.const 1.5) (f32.mul (f32.const 3.5) (call $u01 (i32.const 1600))))
                  (f32.add (f32.const 0.6) (f32.mul (f32.const 4.4) (call $u01 (i32.const 1600))))
                  (f32.gt (f32.load offset=24 (local.get $t)) (f32.const 0.5)))))
        ;; 문장 첫머리 억양을 조금 높게
        (f32.store offset=8 (local.get $t) (f32.mul (f32.load offset=44 (local.get $t)) (f32.const 1.15)))))
    ;; 음절: 110–280 ms, 모음(F1 300–800 Hz, F2 900–2400 Hz)과 세기를 새로 뽑고 억양은 문장 끝으로 갈수록 내려간다
    (f32.store offset=16 (local.get $t) (f32.sub (f32.load offset=16 (local.get $t)) (f32.const 1)))
    (if (f32.le (f32.load offset=16 (local.get $t)) (f32.const 0))
      (then
        (local.set $len (f32.mul (global.get $sr) (f32.add (f32.const 0.11) (f32.mul (f32.const 0.17) (call $u01 (i32.const 1600))))))
        (f32.store offset=16 (local.get $t) (local.get $len))
        (f32.store offset=76 (local.get $t) (local.get $len))
        (f32.store offset=36 (local.get $t) (f32.add (f32.const 300) (f32.mul (f32.const 500) (call $u01 (i32.const 1600)))))
        (f32.store offset=40 (local.get $t) (f32.add (f32.const 900) (f32.mul (f32.const 1500) (call $u01 (i32.const 1600)))))
        (f32.store offset=72 (local.get $t) (f32.mul (f32.load offset=24 (local.get $t))
          (select (f32.const 0) (f32.add (f32.const 0.45) (f32.mul (f32.const 0.55) (call $u01 (i32.const 1600))))
                  (f32.lt (call $u01 (i32.const 1600)) (f32.const 0.12)))))
        (f32.store offset=8 (local.get $t) (f32.max (f32.mul (f32.load offset=44 (local.get $t)) (f32.const 0.8))
          (f32.mul (f32.load offset=8 (local.get $t))
            (call $pow2 (f32.sub (f32.mul (f32.const 0.12) (call $rand (i32.const 1600))) (f32.const 0.03))))))))
    ;; 엔벨로프: 음절 앞 70%는 모음(세기), 뒤 30%는 자음 틈(0) — ≈10 ms 스무딩
    (local.set $a (select (f32.load offset=72 (local.get $t)) (f32.const 0)
      (f32.gt (f32.load offset=16 (local.get $t)) (f32.mul (f32.const 0.3) (f32.load offset=76 (local.get $t))))))
    (f32.store offset=12 (local.get $t) (f32.add (f32.load offset=12 (local.get $t))
      (f32.mul (global.get $tkA) (f32.sub (local.get $a) (f32.load offset=12 (local.get $t))))))
    ;; 포먼트·f0는 목표로 미끄러진다(조음이 이어지는 느낌)
    (f32.store offset=28 (local.get $t) (f32.add (f32.load offset=28 (local.get $t))
      (f32.mul (f32.const 0.0015) (f32.sub (f32.load offset=36 (local.get $t)) (f32.load offset=28 (local.get $t))))))
    (f32.store offset=32 (local.get $t) (f32.add (f32.load offset=32 (local.get $t))
      (f32.mul (f32.const 0.0015) (f32.sub (f32.load offset=40 (local.get $t)) (f32.load offset=32 (local.get $t))))))
    (f32.store offset=4 (local.get $t) (f32.add (f32.load offset=4 (local.get $t))
      (f32.mul (f32.const 0.0008) (f32.sub (f32.load offset=8 (local.get $t)) (f32.load offset=4 (local.get $t))))))
    (if (f32.lt (f32.load offset=12 (local.get $t)) (f32.const 1e-4))
      (then (return (f32.const 0))))
    ;; 성대 펄스: 톱니파(위상 지터 ±1%) + 숨소리 노이즈
    (local.set $ph (f32.add (f32.load (local.get $t))
      (f32.div (f32.mul (f32.load offset=4 (local.get $t)) (f32.add (f32.const 1) (f32.mul (f32.const 0.01) (call $rand (i32.const 1600)))))
               (global.get $sr))))
    (local.set $ph (f32.sub (local.get $ph) (f32.floor (local.get $ph))))
    (f32.store (local.get $t) (local.get $ph))
    (local.set $x (f32.add (f32.sub (f32.const 1) (f32.mul (f32.const 2) (local.get $ph)))
                           (f32.mul (f32.const 0.25) (call $rand (i32.const 1600)))))
    (call $svf (i32.add (local.get $t) (i32.const 48)) (local.get $c) (local.get $x))
    (local.set $a (global.get $bp))
    (call $svf (i32.add (local.get $t) (i32.const 56)) (i32.add (local.get $c) (i32.const 16)) (local.get $x))
    (local.set $a (f32.add (local.get $a) (f32.mul (f32.const 0.5) (global.get $bp))))
    (call $svf (i32.add (local.get $t) (i32.const 64)) (i32.add (local.get $c) (i32.const 32)) (local.get $a))
    (f32.mul (global.get $lo) (f32.load offset=12 (local.get $t))))

  ;; 대화 1샘플 → $tkL/$tkR: 화자마다 다른 위치, 반대쪽에도 조금(방 울림)
  (func $talk (local $a f32) (local $b f32) (local $g f32)
    (local.set $g (f32.mul (call $p (i32.const 66)) (global.get $GM)))
    (if (f32.le (local.get $g) (f32.const 1e-5))
      (then (global.set $tkL (f32.const 0)) (global.set $tkR (f32.const 0)) (return)))
    (local.set $a (f32.mul (local.get $g) (call $talker (i32.const 1408) (i32.const 2192))))
    (local.set $b (f32.mul (local.get $g) (call $talker (i32.const 1504) (i32.const 2240))))
    (global.set $tkL (f32.add (f32.mul (local.get $a) (f32.const 0.85)) (f32.mul (local.get $b) (f32.const 0.45))))
    (global.set $tkR (f32.add (f32.mul (local.get $a) (f32.const 0.5)) (f32.mul (local.get $b) (f32.const 0.85)))))

  ;; 블록마다 화자의 포먼트 BP(F1 Q 4, F2 Q 6)·거리 LP 계수
  (func $talkcoef (param $t i32) (param $c i32)
    (call $svfcoef (local.get $c) (f32.load offset=28 (local.get $t)) (f32.const 4))
    (call $svfcoef (i32.add (local.get $c) (i32.const 16)) (f32.load offset=32 (local.get $t)) (f32.const 6))
    (call $svfcoef (i32.add (local.get $c) (i32.const 32)) (call $p (i32.const 67)) (f32.const 0.707)))

  ;; 빗방울 하나
  (func $trigger
    (local $sz f32) (local $fc f32) (local $q f32) (local $tau f32) (local $g f32)
    ;; 크기: U² 분포 — 작은 방울이 많고 큰 방울은 드물다
    (local.set $sz (call $u01 (i32.const 1348)))
    (local.set $sz (f32.mul (local.get $sz) (local.get $sz)))
    (if (f32.lt (call $u01 (i32.const 1348)) (call $p (i32.const 23)))
      (then ;; '톡': 유리에 닿는 단단한 타격 — 높은 Q, 짧은 임펄스
        (local.set $fc (call $p (i32.const 21)))
        (local.set $q (f32.add (f32.const 6) (f32.mul (f32.const 14) (call $u01 (i32.const 1348)))))
        (local.set $tau (f32.mul (call $p (i32.const 24)) (f32.const 0.15)))
        (local.set $g (f32.const 1)))
      (else ;; '툭': 잎·지붕에 닿는 둔탁한 타격 — 낮은 Q, 긴 임펄스
        (local.set $fc (f32.mul (call $p (i32.const 22)) (call $pow2 (f32.mul (f32.const 0.8) (call $rand (i32.const 1348))))))
        (local.set $q (f32.add (f32.const 1.2) (f32.mul (f32.const 1.8) (call $u01 (i32.const 1348)))))
        (local.set $tau (call $p (i32.const 24)))
        (local.set $g (f32.const 0.8))))
    ;; 큰 방울일수록 낮게 울린다
    (local.set $fc (f32.mul (local.get $fc)
      (f32.mul (call $p (i32.const 27)) (f32.sub (f32.const 1.25) (f32.mul (f32.const 0.5) (local.get $sz))))))
    ;; '톡' 공진은 2–6 kHz 안에만 둔다: 중심을 [2000·2^0.4, 6000/2^0.4]로 묶고 나서 ±0.4 oct 흔든다.
    ;; 흔든 뒤에 자르면 경계(2 kHz)에 방울이 몰려 그 대역만 솟는다.
    (if (f32.ge (local.get $g) (f32.const 1))
      (then (local.set $fc (f32.mul
        (f32.min (f32.const 4547) (f32.max (f32.const 2640) (local.get $fc)))
        (call $pow2 (f32.mul (f32.const 0.4) (call $rand (i32.const 1348))))))))
    ;; 지수 감쇠 2–15 ms: 타격 직후 급격히 줄고 꼬리는 부드럽게 사라진다
    (call $voice (local.get $fc) (local.get $q)
      (f32.min (f32.const 15) (f32.max (f32.const 2) (local.get $tau)))
      (f32.mul (f32.mul (local.get $g) (f32.add (f32.const 0.25) (f32.mul (f32.const 0.75) (local.get $sz))))
               (f32.mul (call $p (i32.const 12)) (global.get $GR)))
      (f32.mul (f32.const 0.85) (call $rand (i32.const 1348)))))

  ;; 기차: 객차 한 량의 대차 2개 × 차축 2개가 레일 이음매(주기 T)를 차례로 지난다.
  ;; 25 m 레일, 차축 간격 2.5 m, 대차 간격 17.5 m → 타격 위치 0, 0.1T, 0.7T, 0.8T ('덜컹 … 덜컹')
  ;; 타격마다 저역 '쿵'(차체로 전해지는 충격)과 짧은 금속성 '칵'(바퀴–레일)을 함께 울린다.
  (func $clack
    (local $a f32) (local $lv f32) (local $pm f32) (local $pan f32) (local $gap f32)
    (local.set $lv (f32.mul (call $p (i32.const 29)) (global.get $GC)))
    (local.set $pm (call $p (i32.const 33)))
    ;; 앞 차축(0, 2)이 조금 세고, 대차마다 위치가 조금 다르다
    (local.set $a (f32.mul (select (f32.const 1) (f32.const 0.8) (i32.eqz (i32.and (global.get $ckI) (i32.const 1))))
                           (f32.add (f32.const 0.8) (f32.mul (f32.const 0.4) (call $u01 (i32.const 1348))))))
    (local.set $pan (f32.mul (f32.const 0.3) (call $rand (i32.const 1348))))
    (if (f32.gt (local.get $lv) (f32.const 1e-4))
      (then
        (call $voice (f32.mul (f32.mul (call $p (i32.const 31)) (local.get $pm)) (call $pow2 (f32.mul (f32.const 0.15) (call $rand (i32.const 1348)))))
          (f32.add (f32.const 1.5) (call $u01 (i32.const 1348))) (f32.const 30)
          (f32.mul (local.get $lv) (local.get $a)) (local.get $pan))
        (call $voice (f32.mul (f32.mul (call $p (i32.const 32)) (local.get $pm)) (call $pow2 (f32.mul (f32.const 0.3) (call $rand (i32.const 1348)))))
          (f32.add (f32.const 3) (f32.mul (f32.const 3) (call $u01 (i32.const 1348)))) (f32.const 3)
          (f32.mul (f32.mul (local.get $lv) (local.get $a)) (f32.const 0.6)) (local.get $pan))))
    ;; 다음 타격까지: 0.1T, 0.6T, 0.1T, 0.2T. 주기마다 속도가 ±4% 안에서 천천히 흔들린다.
    (if (i32.eqz (global.get $ckI))
      (then (global.set $ckD (f32.add (f32.mul (global.get $ckD) (f32.const 0.95))
                                      (f32.mul (f32.const 0.3) (call $rand (i32.const 1348)))))))
    (local.set $gap (select (f32.const 0.1)
      (select (f32.const 0.6) (f32.const 0.2) (i32.eq (global.get $ckI) (i32.const 1)))
      (i32.eqz (i32.and (global.get $ckI) (i32.const 1)))))
    (global.set $ckT (f32.add (global.get $ckT)
      (f32.mul (f32.mul (local.get $gap) (f32.max (f32.const 0.1) (call $p (i32.const 30))))
               (f32.mul (global.get $sr) (f32.add (f32.const 1) (f32.mul (f32.const 0.04) (global.get $ckD)))))))
    (global.set $ckI (i32.and (i32.add (global.get $ckI) (i32.const 1)) (i32.const 3))))

  ;; 벽난로 타닥 하나: 대부분 아주 짧고 밝은 '타닥', 가끔 낮고 굵은 '펑'(장작 속 수분·가스가 터짐)
  (func $crackle
    (local $lv f32) (local $u f32)
    (local.set $lv (f32.mul (call $p (i32.const 34)) (global.get $GK)))
    (if (f32.le (local.get $lv) (f32.const 1e-4)) (then (return)))
    (if (f32.lt (call $u01 (i32.const 1348)) (call $p (i32.const 38)))
      (then
        (call $voice (f32.mul (call $p (i32.const 40)) (call $pow2 (f32.mul (f32.const 0.5) (call $rand (i32.const 1348)))))
          (f32.add (f32.const 1) (call $u01 (i32.const 1348))) (f32.const 6)
          (f32.mul (local.get $lv) (f32.add (f32.const 0.6) (f32.mul (f32.const 0.4) (call $u01 (i32.const 1348)))))
          (global.get $crP)))
      (else
        ;; 세기는 U³ 분포(작은 타닥이 대부분, 큰 타닥은 드묾), 감쇠 0.6–2 ms
        (local.set $u (call $u01 (i32.const 1348)))
        (call $voice (f32.mul (call $p (i32.const 37)) (call $pow2 (f32.mul (f32.const 0.9) (call $rand (i32.const 1348)))))
          (f32.add (f32.const 0.8) (f32.mul (f32.const 1.5) (call $u01 (i32.const 1348))))
          (f32.add (f32.const 0.6) (f32.mul (f32.const 1.4) (call $u01 (i32.const 1348))))
          (f32.mul (local.get $lv) (f32.add (f32.const 0.1)
            (f32.mul (f32.const 0.9) (f32.mul (local.get $u) (f32.mul (local.get $u) (local.get $u))))))
          (f32.add (global.get $crP) (f32.mul (f32.const 0.1) (call $rand (i32.const 1348))))))))

  ;; 스케줄러 1샘플: 빗방울·기차·벽난로
  (func $schedule
    (local $k f32)
    ;; 빗방울
    (global.set $dropT (f32.sub (global.get $dropT) (f32.const 1)))
    (block $d (loop $l
      (br_if $d (f32.gt (global.get $dropT) (f32.const 0)))
      (if (f32.gt (call $p (i32.const 12)) (f32.const 1e-4)) (then (call $trigger)))
      (global.set $dropT (f32.add (global.get $dropT) (call $interval (i32.const 1348) (call $p (i32.const 13)))))
      (br $l)))
    ;; 기차
    (global.set $ckT (f32.sub (global.get $ckT) (f32.const 1)))
    (block $d (loop $l
      (br_if $d (f32.gt (global.get $ckT) (f32.const 0)))
      (call $clack)
      (br $l)))
    ;; 벽난로: 군집 도착(불꽃이 일렁여 커질 때 더 잦다) → 군집 안 타닥들
    (global.set $crT (f32.sub (global.get $crT) (f32.const 1)))
    (if (i32.and (f32.le (global.get $crT) (f32.const 0)) (i32.eqz (global.get $crN)))
      (then
        (local.set $k (f32.mul (f32.const -1) (f32.demote_f64 (call $log (f64.promote_f32
          (f32.sub (f32.const 1) (call $u01 (i32.const 1348))))))))
        (global.set $crN (i32.trunc_f32_u (f32.min (f32.const 12)
          (f32.add (f32.const 1) (f32.mul (local.get $k) (f32.max (f32.const 0) (f32.sub (call $p (i32.const 36)) (f32.const 1))))))))
        (global.set $crP (f32.mul (f32.const 0.7) (call $rand (i32.const 1348))))
        (global.set $crG (f32.const 0))
        (global.set $crT (f32.add (global.get $crT) (call $interval (i32.const 1348)
          (f32.mul (call $p (i32.const 35))
            (f32.max (f32.const 0) (f32.add (f32.const 1) (f32.mul (f32.mul (f32.const 0.6) (call $p (i32.const 39))) (global.get $fn))))))))))
    (if (global.get $crN)
      (then
        (global.set $crG (f32.sub (global.get $crG) (f32.const 1)))
        (if (f32.le (global.get $crG) (f32.const 0))
          (then
            (call $crackle)
            (global.set $crN (i32.sub (global.get $crN) (i32.const 1)))
            ;; 군집 안 간격: 평균 12 ms 지수분포
            (global.set $crG (call $interval (i32.const 1348) (f32.const 83)))))))
    ;; 시냇물: 푸아송 도착 공기방울
    (global.set $bbT (f32.sub (global.get $bbT) (f32.const 1)))
    (block $d (loop $l
      (br_if $d (f32.gt (global.get $bbT) (f32.const 0)))
      (call $bubble)
      (global.set $bbT (f32.add (global.get $bbT) (call $interval (i32.const 1348) (call $p (i32.const 42)))))
      (br $l)))
    ;; 여름밤: 풀벌레 세 개체
    ;; 레퍼런스에 다른 종이 함께 울면(두 번째 스펙트럼 피크) 가운데 한 마리를 그 높이로 — 울음 높이 슬라이더를 같은 비율로 따른다
    (call $cricket (i32.const 0) (f32.const 1) (call $p (i32.const 53)) (f32.const -0.55) (f32.const 1))
    (call $cricket (i32.const 1) (f32.const 1.17)
      (select (call $p (i32.const 56)) (f32.mul (call $p (i32.const 53)) (f32.const 0.94)) (f32.gt (call $p (i32.const 56)) (f32.const 0)))
      (f32.const 0.6) (f32.const 0.8))
    (call $cricket (i32.const 2) (f32.const 0.86) (f32.mul (call $p (i32.const 53)) (f32.const 1.06)) (f32.const 0.05) (f32.const 0.6))
    (call $indoor))

  ;; 보이스의 한 채널 1샘플: 시작 지연 → 지수 감쇠 엔벨로프(어택 스무딩) × 노이즈 → 공진 BP → $bp
  ;; 사인 모드(v+92 = 1)는 BP 없이 엔벨로프 × 사인 → $bp ($lo = 0)
  (func $side (param $s i32) (param $c i32) (param $dec f32) (param $v i32)
    (local $e f32) (local $ph f32)
    (if (f32.gt (f32.load offset=56 (local.get $s)) (f32.const 0))
      (then
        (f32.store offset=56 (local.get $s) (f32.sub (f32.load offset=56 (local.get $s)) (f32.const 1)))
        (if (i32.load offset=92 (local.get $v))
          (then (global.set $bp (f32.const 0)) (global.set $lo (f32.const 0)))
          (else (call $svf (local.get $s) (local.get $c) (f32.const 0)))))
      (else
        (f32.store offset=8 (local.get $s) (f32.mul (f32.load offset=8 (local.get $s)) (local.get $dec)))
        (local.set $e (f32.load offset=12 (local.get $s)))
        (local.set $e (f32.add (local.get $e)
          (f32.mul (f32.load offset=96 (local.get $v)) (f32.sub (f32.load offset=8 (local.get $s)) (local.get $e)))))
        (f32.store offset=12 (local.get $s) (local.get $e))
        (if (i32.load offset=92 (local.get $v))
          (then
            (local.set $ph (f32.add (f32.load offset=60 (local.get $s)) (f32.load offset=84 (local.get $v))))
            (local.set $ph (f32.sub (local.get $ph) (f32.floor (local.get $ph))))
            (f32.store offset=60 (local.get $s) (local.get $ph))
            (global.set $bp (f32.mul (local.get $e) (call $sinp (local.get $ph))))
            (global.set $lo (f32.const 0)))
          (else
            (call $svf (local.get $s) (local.get $c)
              (f32.mul (local.get $e) (call $rand (i32.add (local.get $s) (i32.const 48))))))))))

  ;; 1샘플: 스케줄러 진행 + 활성 보이스 합산 → $dL, $dR (레이어 레벨은 보이스 게인에 들어 있다)
  (func $drops
    (local $v i32) (local $q f32) (local $l f32) (local $r f32) (local $gn f32)
    (call $schedule)
    (local.set $v (i32.const 4096))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $v) (i32.const 8192)))
      (if (i32.load offset=44 (local.get $v))
        (then
          (local.set $gn (f32.load offset=32 (local.get $v)))
          (call $side (local.get $v) (i32.add (local.get $v) (i32.const 16)) (f32.load offset=52 (local.get $v)) (local.get $v))
          (local.set $l (f32.add (local.get $l)
            (f32.mul (global.get $bp) (f32.mul (local.get $gn) (f32.load offset=36 (local.get $v))))))
          (local.set $q (f32.add (f32.abs (global.get $bp)) (f32.abs (global.get $lo))))
          (call $side (i32.add (local.get $v) (i32.const 64)) (i32.add (local.get $v) (i32.const 16)) (f32.load offset=52 (local.get $v)) (local.get $v))
          ;; 사인 모드: 음높이 상승(공기방울)
          (if (i32.load offset=92 (local.get $v))
            (then (f32.store offset=84 (local.get $v) (f32.min (f32.const 0.45)
              (f32.mul (f32.load offset=84 (local.get $v)) (f32.load offset=88 (local.get $v)))))))
          (local.set $r (f32.add (local.get $r)
            (f32.mul (global.get $bp) (f32.mul (local.get $gn) (f32.load offset=40 (local.get $v))))))
          (local.set $q (f32.add (local.get $q) (f32.add (f32.abs (global.get $bp)) (f32.abs (global.get $lo)))))
          ;; 양쪽 임펄스(지연 포함)와 공진 꼬리가 모두 사라지면 보이스 해제
          (if (i32.and (i32.and (f32.lt (f32.load offset=8 (local.get $v)) (f32.const 1e-4))
                                (f32.lt (f32.load offset=72 (local.get $v)) (f32.const 1e-4)))
                       (f32.lt (local.get $q) (f32.const 1e-6)))
            (then (i32.store offset=44 (local.get $v) (i32.const 0))
                  (f32.store (local.get $v) (f32.const 0))
                  (f32.store offset=4 (local.get $v) (f32.const 0))
                  (f32.store offset=64 (local.get $v) (f32.const 0))
                  (f32.store offset=68 (local.get $v) (f32.const 0))))))
      (local.set $v (i32.add (local.get $v) (i32.const 128)))
      (br $l)))
    (call $talk)
    (global.set $dL (f32.add (local.get $l) (global.get $tkL)))
    (global.set $dR (f32.add (local.get $r) (global.get $tkR))))

  ;; ── 채널 1샘플 ─────────────────────────────────────────────
  (func $chan (param $b i32) (param $wC f32) (param $deep f32) (param $drop f32) (param $amp f32) (param $g f32) (param $out i32)
    (local $wX f32) (local $w f32) (local $pink f32) (local $br f32)
    (local $env f32) (local $cnt f32) (local $pit f32) (local $x f32) (local $a f32) (local $wv f32) (local $y f32)

    (local.set $wX (call $rand (local.get $b)))
    (local.set $w (f32.add (f32.mul (local.get $wC) (global.get $mA))
                           (f32.mul (local.get $wX) (global.get $mB))))

    ;; Pink (Paul Kellet refined)
    (f32.store offset=4  (local.get $b) (f32.add (f32.mul (f32.const 0.99886) (f32.load offset=4  (local.get $b))) (f32.mul (local.get $w) (f32.const 0.0555179))))
    (f32.store offset=8  (local.get $b) (f32.add (f32.mul (f32.const 0.99332) (f32.load offset=8  (local.get $b))) (f32.mul (local.get $w) (f32.const 0.0750759))))
    (f32.store offset=12 (local.get $b) (f32.add (f32.mul (f32.const 0.96900) (f32.load offset=12 (local.get $b))) (f32.mul (local.get $w) (f32.const 0.1538520))))
    (f32.store offset=16 (local.get $b) (f32.add (f32.mul (f32.const 0.86650) (f32.load offset=16 (local.get $b))) (f32.mul (local.get $w) (f32.const 0.3104856))))
    (f32.store offset=20 (local.get $b) (f32.add (f32.mul (f32.const 0.55000) (f32.load offset=20 (local.get $b))) (f32.mul (local.get $w) (f32.const 0.5329522))))
    (f32.store offset=24 (local.get $b) (f32.sub (f32.mul (f32.const -0.7616) (f32.load offset=24 (local.get $b))) (f32.mul (local.get $w) (f32.const 0.0168980))))
    (local.set $pink (f32.add (f32.add (f32.add (f32.load offset=4 (local.get $b)) (f32.load offset=8 (local.get $b)))
                                       (f32.add (f32.load offset=12 (local.get $b)) (f32.load offset=16 (local.get $b))))
                     (f32.add (f32.add (f32.load offset=20 (local.get $b)) (f32.load offset=24 (local.get $b)))
                              (f32.add (f32.load offset=28 (local.get $b)) (f32.mul (local.get $w) (f32.const 0.5362))))))
    (f32.store offset=28 (local.get $b) (f32.mul (local.get $w) (f32.const 0.115926)))
    (local.set $pink (f32.mul (local.get $pink) (f32.const 0.11)))

    ;; Brown (누설 적분기)
    (local.set $br (f32.add (f32.mul (f32.load offset=32 (local.get $b)) (global.get $brA))
                            (f32.mul (local.get $w) (f32.sub (f32.const 1) (global.get $brA)))))
    (f32.store offset=32 (local.get $b) (local.get $br))
    (local.set $br (f32.mul (local.get $br) (f32.const 3.5)))

    ;; 잔빗소리: 채널마다 독립된 푸아송 과정 → 3 ms 노이즈 버스트 → 밴드패스
    (local.set $env (f32.mul (f32.load offset=72 (local.get $b)) (global.get $pitD)))
    (local.set $cnt (f32.sub (f32.load offset=76 (local.get $b)) (f32.const 1)))
    (block $d (loop $l
      (br_if $d (f32.gt (local.get $cnt) (f32.const 0)))
      (local.set $a (f32.add (f32.const 0.25)
        (f32.mul (f32.const 0.75) (call $u01 (i32.add (local.get $b) (i32.const 80))))))
      (local.set $env (f32.max (local.get $env) (f32.mul (local.get $a) (local.get $a))))
      (local.set $cnt (f32.add (local.get $cnt) (call $interval (i32.add (local.get $b) (i32.const 80))
        (f32.mul (call $p (i32.const 13)) (call $p (i32.const 26))))))
      (br $l)))
    (f32.store offset=72 (local.get $b) (local.get $env))
    (local.set $env (f32.add (f32.load offset=104 (local.get $b))
      (f32.mul (global.get $pitA) (f32.sub (local.get $env) (f32.load offset=104 (local.get $b))))))
    (f32.store offset=104 (local.get $b) (local.get $env))
    (f32.store offset=76 (local.get $b) (local.get $cnt))
    (call $svf (i32.add (local.get $b) (i32.const 64)) (i32.const 2128) (f32.mul (local.get $env) (local.get $wX)))
    (local.set $pit (f32.mul (f32.mul (call $p (i32.const 25)) (global.get $GT)) (global.get $bp)))
    ;; 타격음 버스 LP(Q 0.707, 컷오프 = 베드 LP): 메인 LP와 겹쳐 타격음은 베드보다 12 dB/oct 더
    ;; 가파르게 떨어진다 → 컷오프 위에서 BP 스커트의 날카로운 고역이 베드 위로 튀지 않고 그 아래로 스며든다
    (call $svf (i32.add (local.get $b) (i32.const 108)) (i32.const 2160) (f32.add (local.get $pit) (local.get $drop)))
    (local.set $pit (global.get $lo))
    ;; 바람 휘파람: 채널 독립 노이즈 → 공진 BP(Q 5), 돌풍이 셀수록 제곱으로 커진다
    ;; (꺼져 있으면 계산하지 않는다 — 상태가 0에서 다시 시작해도 레벨이 0에서 올라오므로 튀지 않는다)
    (if (f32.gt (call $p (i32.const 48)) (f32.const 1e-5))
      (then
        (call $svf (i32.add (local.get $b) (i32.const 116)) (i32.const 2176) (local.get $wX))
        (local.set $pit (f32.add (local.get $pit) (f32.mul (f32.mul (f32.mul (call $p (i32.const 48)) (global.get $GH)) (global.get $bp))
                                                           (f32.mul (global.get $wg) (global.get $wg)))))))

    ;; 믹스
    ;; 베드(노이즈 + 딥)는 불꽃 일렁임·돌풍 게인을 받는다
    (local.set $x (f32.add (local.get $pit) (f32.mul (f32.mul (global.get $fg) (global.get $wg))
      (f32.add (f32.add (f32.mul (f32.mul (call $p (i32.const 1)) (global.get $GW)) (local.get $w))
                        (f32.mul (f32.mul (call $p (i32.const 2)) (global.get $GP)) (local.get $pink)))
               (f32.add (f32.mul (f32.mul (call $p (i32.const 3)) (global.get $GB)) (local.get $br))
                        (local.get $deep))))))

    ;; 베이스 셸프: x + g·LP(x)
    (call $svf (i32.add (local.get $b) (i32.const 36)) (i32.const 2080) (local.get $x))
    (local.set $x (f32.add (local.get $x) (f32.mul (call $p (i32.const 6)) (global.get $lo))))

    ;; 메인 로우패스 (톤)
    (call $svf (i32.add (local.get $b) (i32.const 44)) (i32.const 2096) (local.get $x))
    (local.set $x (f32.mul (global.get $lo) (global.get $lpG)))
    ;; 2단(Q 0.707)을 기울기만큼 섞는다: 컷오프 위를 24 dB/oct로 깎아 고역의 쏴— 하는 피로감을 줄임
    (call $svf (i32.add (local.get $b) (i32.const 96)) (i32.const 2112) (local.get $x))
    (local.set $x (f32.add (local.get $x)
      (f32.mul (call $p (i32.const 28)) (f32.sub (global.get $lo) (local.get $x)))))

    ;; 하이패스: hp = x − k·bp − lo (상태는 항상 갱신해 바이패스 전환 시 튀지 않게)
    (call $svf (i32.add (local.get $b) (i32.const 88)) (i32.const 2144) (local.get $x))
    (if (global.get $hpOn)
      (then (local.set $x (f32.mul (global.get $hpG)
        (f32.sub (f32.sub (local.get $x) (f32.mul (f32.load (i32.const 2156)) (global.get $bp)))
                 (global.get $lo))))))

    ;; Air: x + g·HP1(x)
    (local.set $a (f32.load offset=52 (local.get $b)))
    (local.set $a (f32.add (local.get $a) (f32.mul (global.get $airC) (f32.sub (local.get $x) (local.get $a)))))
    (f32.store offset=52 (local.get $b) (local.get $a))
    (local.set $x (f32.add (local.get $x) (f32.mul (call $p (i32.const 8)) (f32.sub (local.get $x) (local.get $a)))))

    ;; 스웰 AM
    (local.set $x (f32.mul (local.get $x) (local.get $amp)))

    ;; 웜스: 레벨 보존형 새츄레이션 블렌드
    (local.set $wv (call $p (i32.const 14)))
    (local.set $a (f32.add (f32.const 1) (f32.mul (f32.const 3) (local.get $wv))))
    (local.set $x (f32.add (f32.mul (local.get $x) (f32.sub (f32.const 1) (local.get $wv)))
                           (f32.div (f32.mul (local.get $wv) (call $sat (f32.mul (local.get $x) (local.get $a)))) (local.get $a))))

    ;; DC / 초저역 차단 (12Hz)
    (local.set $y (f32.add (f32.sub (local.get $x) (f32.load offset=56 (local.get $b)))
                           (f32.mul (global.get $dcR) (f32.load offset=60 (local.get $b)))))
    (f32.store offset=56 (local.get $b) (local.get $x))
    (f32.store offset=60 (local.get $b) (local.get $y))

    ;; 클리핑 방지는 process()의 스테레오 리미터·클리퍼가 맡는다
    (f32.store (local.get $out) (f32.mul (local.get $y) (local.get $g))))

  ;; ── 블록 처리 ───────────────────────────────────────────────
  (func (export "process") (param $n i32)
    (local $i i32) (local $id i32) (local $addr i32) (local $cur f32) (local $tgt f32)
    (local $wC f32) (local $dl f32) (local $deep f32) (local $amp f32) (local $sw f32)
    (local $depth f32) (local $d f32) (local $cs1 f32) (local $sn1 f32) (local $cs2 f32) (local $sn2 f32)
    (local $t f32) (local $mag f32)
    (local $m f32) (local $mst f32) (local $e f32) (local $einc f32) (local $edec f32) (local $gate f32) (local $g f32)
    (local $xl f32) (local $xr f32) (local $pk f32) (local $lg f32)

    ;; 파라미터 스무딩 (블록당). 마스터는 블록 안에서 샘플 단위로 보간한다.
    (local.set $m (call $p (i32.const 0)))
    (local.set $id (i32.const 0))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $id) (i32.const 128)))
      (local.set $addr (i32.shl (local.get $id) (i32.const 2)))
      (local.set $cur (f32.load offset=3584 (local.get $addr)))
      (local.set $tgt (f32.load offset=3072 (local.get $addr)))
      (f32.store offset=3584 (local.get $addr)
        (f32.add (local.get $cur) (f32.mul (f32.sub (local.get $tgt) (local.get $cur)) (f32.const 0.04))))
      (local.set $id (i32.add (local.get $id) (i32.const 1)))
      (br $l)))
    (local.set $mst (f32.div (f32.sub (call $p (i32.const 0)) (local.get $m))
                             (f32.convert_i32_u (local.get $n))))

    ;; 엔벨로프: 게이트 목표값(스무딩 전)과 페이드 시간 → 샘플당 증감량
    (local.set $gate (f32.load (i32.const 3144)))
    (local.set $einc (f32.div (f32.const 1)
      (f32.mul (f32.max (call $p (i32.const 19)) (f32.const 0.005)) (global.get $sr))))
    (local.set $edec (f32.div (f32.const 1)
      (f32.mul (f32.max (call $p (i32.const 20)) (f32.const 0.005)) (global.get $sr))))
    (local.set $e (global.get $envL))

    ;; 하이패스 계수
    (call $svfcoef (i32.const 2144) (call $p (i32.const 16)) (call $p (i32.const 17)))
    (global.set $hpOn (f32.gt (call $p (i32.const 16)) (f32.const 10.5)))
    (global.set $hpG (call $qcomp (call $p (i32.const 17))))
    (global.set $lpG (call $qcomp (call $p (i32.const 15))))

    ;; 스테레오 폭
    (local.set $t (f32.min (f32.const 1) (f32.max (f32.const 0) (call $p (i32.const 9)))))
    (global.set $mA (f32.sqrt (f32.sub (f32.const 1) (local.get $t))))
    (global.set $mB (f32.sqrt (local.get $t)))

    ;; 잔빗소리 밴드패스: '톡'과 같은 대역(유리 표면의 잘게 부서지는 타격)
    (call $svfcoef (i32.const 2128)
      (f32.min (f32.const 6000) (f32.max (f32.const 2000)
        (f32.mul (call $p (i32.const 21)) (call $p (i32.const 27))))) (f32.const 3))
    ;; 돌풍 평활 계수(속도 Hz)·정규화, 휘파람 BP: 돌풍이 셀수록 음높이도 올라간다(±0.5 oct × 깊이)
    (global.set $guC (f32.sub (f32.const 1) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.mul (f32.const -6.2831853) (f32.max (f32.const 0.01) (call $p (i32.const 47)))) (global.get $sr)))))))
    (global.set $guN (call $lpnorm (global.get $guC)))
    (call $svfcoef (i32.const 2176)
      (f32.mul (call $p (i32.const 49)) (call $pow2 (f32.mul (f32.mul (f32.const 0.5) (call $p (i32.const 46)))
        (f32.min (f32.const 2) (f32.max (f32.const -2) (global.get $gn)))))) (f32.const 5))
    ;; 먼 대화 포먼트·거리 LP
    (if (f32.gt (call $p (i32.const 66)) (f32.const 1e-5))
      (then (call $talkcoef (i32.const 1408) (i32.const 2192))
            (call $talkcoef (i32.const 1504) (i32.const 2240))))
    ;; 타격음 버스 LP: 베드 LP와 같은 컷오프(스웰 변조 제외)
    (call $svfcoef (i32.const 2160) (call $p (i32.const 7)) (f32.const 0.707))

    ;; 딥 레이어 필터 (2단 LP, 약간의 공진)
    (call $svfcoef (i32.const 2048) (call $p (i32.const 5)) (f32.const 1.1))
    (call $svfcoef (i32.const 2064) (call $p (i32.const 5)) (f32.const 0.6))

    ;; 스웰 LFO 회전 계수
    (local.set $depth (call $p (i32.const 10)))
    (local.set $d (f32.div (f32.mul (f32.const 6.2831853) (call $p (i32.const 11))) (global.get $sr)))
    (local.set $cs1 (f32.demote_f64 (call $cos (f64.promote_f32 (local.get $d)))))
    (local.set $sn1 (f32.demote_f64 (call $sin (f64.promote_f32 (local.get $d)))))
    (local.set $d (f32.mul (local.get $d) (f32.const 0.37)))
    (local.set $cs2 (f32.demote_f64 (call $cos (f64.promote_f32 (local.get $d)))))
    (local.set $sn2 (f32.demote_f64 (call $sin (f64.promote_f32 (local.get $d)))))
    ;; 위상자 정규화
    (local.set $mag (f32.sqrt (f32.add (f32.mul (global.get $s1) (global.get $s1)) (f32.mul (global.get $c1) (global.get $c1)))))
    (global.set $s1 (f32.div (global.get $s1) (local.get $mag)))
    (global.set $c1 (f32.div (global.get $c1) (local.get $mag)))
    (local.set $mag (f32.sqrt (f32.add (f32.mul (global.get $s2) (global.get $s2)) (f32.mul (global.get $c2) (global.get $c2)))))
    (global.set $s2 (f32.div (global.get $s2) (local.get $mag)))
    (global.set $c2 (f32.div (global.get $c2) (local.get $mag)))

    ;; 메인 LP: 파도 마루에서 밝아지도록 스웰로 변조
    (call $svfcoef (i32.const 2096)
      (f32.mul (call $p (i32.const 7))
        (f32.sub (f32.const 1) (f32.mul (f32.mul (local.get $depth) (f32.const 0.6))
                                        (f32.sub (f32.const 1) (global.get $swCur)))))
      (call $p (i32.const 15)))
    (call $svfcoef (i32.const 2112)
      (f32.mul (call $p (i32.const 7))
        (f32.sub (f32.const 1) (f32.mul (f32.mul (local.get $depth) (f32.const 0.6))
                                        (f32.sub (f32.const 1) (global.get $swCur)))))
      (f32.const 0.707))

    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))

      (local.set $wC (call $rand (i32.const 1344)))

      ;; Deep: 모노 브라운 → 2단 공진 LP (서브 베이스는 모노가 가장 단단함)
      (local.set $dl (f32.add (f32.mul (f32.load (i32.const 1280)) (f32.const 0.995))
                              (f32.mul (local.get $wC) (f32.const 0.05))))
      (f32.store (i32.const 1280) (local.get $dl))
      (call $svf (i32.const 1288) (i32.const 2048) (local.get $dl))
      (call $svf (i32.const 1296) (i32.const 2064) (global.get $lo))
      (local.set $deep (f32.mul (global.get $lo) (f32.mul (call $p (i32.const 4)) (global.get $GD))))

      ;; 스웰
      (local.set $t (global.get $s1))
      (global.set $s1 (f32.add (f32.mul (global.get $s1) (local.get $cs1)) (f32.mul (global.get $c1) (local.get $sn1))))
      (global.set $c1 (f32.sub (f32.mul (global.get $c1) (local.get $cs1)) (f32.mul (local.get $t) (local.get $sn1))))
      (local.set $t (global.get $s2))
      (global.set $s2 (f32.add (f32.mul (global.get $s2) (local.get $cs2)) (f32.mul (global.get $c2) (local.get $sn2))))
      (global.set $c2 (f32.sub (f32.mul (global.get $c2) (local.get $cs2)) (f32.mul (local.get $t) (local.get $sn2))))
      (local.set $sw (f32.add (f32.const 0.5) (f32.mul (f32.const 0.5)
        (f32.add (f32.mul (f32.const 0.7) (global.get $s1)) (f32.mul (f32.const 0.3) (global.get $s2))))))
      (local.set $sw (f32.mul (local.get $sw) (local.get $sw)))
      (global.set $swCur (local.get $sw))
      (local.set $amp (f32.sub (f32.const 1) (f32.mul (f32.mul (local.get $depth) (f32.const 0.85))
                                                      (f32.sub (f32.const 1) (local.get $sw)))))

      ;; 엔벨로프(선형 램프 → smoothstep 곡선) × 보간된 마스터
      (if (f32.gt (local.get $gate) (f32.const 0.5))
        (then (local.set $e (f32.min (f32.const 1) (f32.add (local.get $e) (local.get $einc)))))
        (else (local.set $e (f32.max (f32.const 0) (f32.sub (local.get $e) (local.get $edec))))))
      (local.set $m (f32.add (local.get $m) (local.get $mst)))
      (local.set $g (f32.mul (f32.mul (local.get $m) (call $p (i32.const 57)))
        (f32.mul (f32.mul (local.get $e) (local.get $e))
                 (f32.sub (f32.const 3) (f32.mul (f32.const 2) (local.get $e))))))

      ;; 불꽃 일렁임
      (global.set $fl1 (f32.add (global.get $fl1) (f32.mul (global.get $flC) (f32.sub (call $rand (i32.const 1352)) (global.get $fl1)))))
      (global.set $fl2 (f32.add (global.get $fl2) (f32.mul (global.get $flC) (f32.sub (global.get $fl1) (global.get $fl2)))))
      (global.set $fn (f32.mul (global.get $fl2) (global.get $flN)))
      (global.set $fg (f32.max (f32.const 0) (f32.add (f32.const 1) (f32.mul (f32.mul (f32.const 0.35) (call $p (i32.const 39))) (global.get $fn)))))
      ;; 돌풍: 바람이 잦아들어도 완전히 끊기지 않게 바닥 0.08
      (global.set $gu1 (f32.add (global.get $gu1) (f32.mul (global.get $guC) (f32.sub (call $rand (i32.const 1356)) (global.get $gu1)))))
      (global.set $gu2 (f32.add (global.get $gu2) (f32.mul (global.get $guC) (f32.sub (global.get $gu1) (global.get $gu2)))))
      (global.set $gn (f32.mul (global.get $gu2) (global.get $guN)))
      (global.set $wg (f32.max (f32.const 0.08) (f32.add (f32.const 1) (f32.mul (f32.mul (f32.const 0.55) (call $p (i32.const 46))) (global.get $gn)))))

      (call $drops)
      (local.set $addr (i32.shl (local.get $i) (i32.const 2)))
      (call $chan (i32.const 1024) (local.get $wC) (local.get $deep) (global.get $dL) (local.get $amp) (local.get $g) (local.get $addr))
      (call $chan (i32.const 1152) (local.get $wC) (local.get $deep) (global.get $dR) (local.get $amp) (local.get $g)
                  (i32.add (local.get $addr) (i32.const 512)))

      ;; 스테레오 링크 피크 리미터(룩어헤드 64샘플 ≈ 1.33 ms): 현재 입력의 피크로 게인을 미리 낮추고
      ;; 64샘플 지연된 신호에 적용 → 푸아송 임펄스가 겹친 순간 피크를 왜곡 없이 −2 dBFS 아래로
      (local.set $xl (f32.load (local.get $addr)))
      (local.set $xr (f32.load offset=512 (local.get $addr)))
      (local.set $pk (f32.max (f32.mul (global.get $limPk) (global.get $limRl))
                              (f32.max (f32.abs (local.get $xl)) (f32.abs (local.get $xr)))))
      (global.set $limPk (local.get $pk))
      (local.set $lg (f32.min (f32.const 1) (f32.div (global.get $LIM) (f32.max (local.get $pk) (f32.const 1e-9)))))
      (global.set $limG (if (result f32) (f32.lt (local.get $lg) (global.get $limG))
        (then (f32.add (global.get $limG) (f32.mul (global.get $limAt) (f32.sub (local.get $lg) (global.get $limG)))))
        (else (local.get $lg))))
      (f32.store (local.get $addr)
        (call $clip (f32.mul (f32.load offset=8192 (global.get $li)) (global.get $limG))))
      (f32.store offset=512 (local.get $addr)
        (call $clip (f32.mul (f32.load offset=8448 (global.get $li)) (global.get $limG))))
      (f32.store offset=8192 (global.get $li) (local.get $xl))
      (f32.store offset=8448 (global.get $li) (local.get $xr))
      (global.set $li (i32.and (i32.add (global.get $li) (i32.const 4)) (i32.const 255)))

      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (global.set $envL (local.get $e)))
)
