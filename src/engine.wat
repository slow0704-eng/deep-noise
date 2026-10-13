;; ─────────────────────────────────────────────────────────────
;;  Deep Noise Engine — WebAssembly DSP core
;;  레이어: White / Pink / Brown / Deep(서브 베이스) / 빗방울(푸아송 드롭 + 잔빗소리)
;;  빗소리 모델은 Andy Farnell "Designing Sound"의 절차적 접근을 따른다:
;;  지속적인 배경(브라운·핑크 노이즈 베드) + 푸아송 과정으로 도착하는 개별 방울.
;;  방울 간격은 지수분포(−ln U / λ)로 뽑고, 방울마다 크기·종류(유리 '톡' / 잎 '툭')·
;;  공진 밴드패스 주파수와 Q·스테레오 위치를 무작위로 정해 짧은 노이즈 임펄스를 울린다.
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
  ;; 3072  파라미터 목표값       3200  파라미터 현재값(스무딩)
  ;; 4096  방울 보이스 풀 16 × 128B (고정 할당, 라운드로빈 재사용)
  ;;       공통: 16..28 svf 계수, 32 게인, 36/40 팬 L/R, 44 활성, 52 감쇠
  ;;       채널별(L = +0, R = +64): 0/4 svf, 8 원 엔벨로프, 12 어택 스무딩 엔벨로프, 48 rng, 56 시작 지연(샘플)
  ;; 6144  리미터 룩어헤드 L (64 f32)   6400  리미터 룩어헤드 R (64 f32)
  ;;
  ;; 채널 상태 오프셋: 0 rng, 4..28 pink b0..b6, 32 brown,
  ;; 36/40 bass svf, 44/48 lp svf, 52 air lp, 56 dc x1, 60 dc y1,
  ;; 64/68 잔빗소리 svf, 72 env, 76 다음 트리거까지 샘플, 80 rng, 88/92 hp svf,
  ;; 96/100 lp 2단 svf, 104 잔빗소리 env(어택 스무딩), 108/112 타격음 버스 LP svf
  ;; 필터 계수: 2048/2064 deep, 2080 bass, 2096 lp, 2112 lp 2단, 2128 잔빗소리, 2144 hp, 2160 타격음 버스 LP
  ;;
  ;; 파라미터: 0 마스터, 1-4 white/pink/brown/deep, 5 서브 주파수, 6 베이스,
  ;; 7 LP 컷오프, 8 air, 9 폭, 10/11 스웰 깊이/속도, 12 방울 레벨, 13 방울 빈도 λ(회/초),
  ;; 14 웜스, 15 LP Q, 16 HP 컷오프(<10.5Hz면 바이패스), 17 HP Q,
  ;; 18 게이트(0/1, 스무딩 없이 목표값 사용), 19 페이드 인(초), 20 페이드 아웃(초),
  ;; 21 '톡' 중심(Hz), 22 '툭' 중심(Hz), 23 톡 비율, 24 '툭' 임펄스 감쇠(ms),
  ;; 25 잔빗소리 레벨, 26 잔빗소리 빈도 배수(λ 대비), 27 방울 음높이 배수,
  ;; 28 LP 기울기(0 = 12 dB/oct, 1 = 24 dB/oct, 사이는 크로스페이드)

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
  (global $GW f32 (f32.const 0.30))
  (global $GP f32 (f32.const 0.95))
  (global $GB f32 (f32.const 0.95))
  (global $GD f32 (f32.const 1.5))
  (global $GR f32 (f32.const 16))    ;; 방울 (보이스 출력이 좁은 대역이라 큼)
  (global $GT f32 (f32.const 4.5))   ;; 잔빗소리

  (func $p (param $id i32) (result f32)
    (f32.load (i32.add (i32.const 3200) (i32.shl (local.get $id) (i32.const 2)))))

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
      (br_if $d (i32.ge_u (local.get $i) (i32.const 1408)))
      (i32.store (local.get $i) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $l)))
    (local.set $i (i32.const 4096))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $i) (i32.const 6656)))
      (i32.store (local.get $i) (i32.const 0))
      (local.set $i (i32.add (local.get $i) (i32.const 4)))
      (br $l)))
    (i32.store (i32.const 1024) (i32.const 0x2545F491))
    (i32.store (i32.const 1152) (i32.const 0x9E3779B9))
    (i32.store (i32.const 1104) (i32.const 0x7F4A7C15))
    (i32.store (i32.const 1232) (i32.const 0x1B873593))
    (i32.store (i32.const 1344) (i32.const 0x68E31DA4))
    (i32.store (i32.const 1348) (i32.const 0x3C6EF372))
    (f32.store (i32.const 1100) (f32.const 1000))   ;; 잔빗소리 첫 트리거 L/R 엇갈리게
    (f32.store (i32.const 1228) (f32.const 1700))
    (global.set $dropT (f32.const 2000)) (global.set $vi (i32.const 0))
    (global.set $limPk (f32.const 0)) (global.set $limG (f32.const 1)) (global.set $li (i32.const 0))
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
    (global.set $envL (f32.const 0)))

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
      (br_if $d (i32.ge_u (local.get $i) (i32.const 32)))
      (f32.store (i32.add (i32.const 3200) (i32.shl (local.get $i) (i32.const 2)))
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

  ;; 방울 하나를 가장 오래된 보이스에 할당
  (func $trigger
    (local $v i32) (local $sz f32) (local $fc f32) (local $q f32) (local $tau f32) (local $pan f32) (local $g f32)
    (local $late i32)
    (local.set $v (i32.add (i32.const 4096) (i32.shl (global.get $vi) (i32.const 7))))
    (global.set $vi (i32.and (i32.add (global.get $vi) (i32.const 1)) (i32.const 15)))
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
    (call $svfcoef (i32.add (local.get $v) (i32.const 16)) (local.get $fc) (local.get $q))
    ;; 지수 감쇠 2–15 ms: 타격 직후 급격히 줄고 꼬리는 부드럽게 사라진다
    (local.set $tau (f32.min (f32.const 15) (f32.max (f32.const 2) (local.get $tau))))
    (f32.store offset=52 (local.get $v) (f32.demote_f64 (call $exp (f64.promote_f32
      (f32.div (f32.const -1000) (f32.mul (local.get $tau) (global.get $sr)))))))
    ;; 게인: 진폭 × k(BP 피크를 1로) × √Q(좁은 대역의 에너지 손실 보상)
    (f32.store offset=32 (local.get $v)
      (f32.mul (f32.mul (local.get $g) (f32.add (f32.const 0.25) (f32.mul (f32.const 0.75) (local.get $sz))))
               (f32.mul (f32.load offset=28 (local.get $v)) (f32.sqrt (local.get $q)))))
    ;; 등전력 팬
    (local.set $pan (f32.mul (f32.const 0.85) (call $rand (i32.const 1348))))
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
    (i32.store offset=44 (local.get $v) (i32.const 1)))

  ;; 보이스의 한 채널 1샘플: 시작 지연 → 지수 감쇠 엔벨로프(어택 스무딩) × 노이즈 → 공진 BP → $bp
  (func $side (param $s i32) (param $c i32) (param $dec f32)
    (local $e f32)
    (if (f32.gt (f32.load offset=56 (local.get $s)) (f32.const 0))
      (then
        (f32.store offset=56 (local.get $s) (f32.sub (f32.load offset=56 (local.get $s)) (f32.const 1)))
        (call $svf (local.get $s) (local.get $c) (f32.const 0)))
      (else
        (f32.store offset=8 (local.get $s) (f32.mul (f32.load offset=8 (local.get $s)) (local.get $dec)))
        (local.set $e (f32.load offset=12 (local.get $s)))
        (local.set $e (f32.add (local.get $e)
          (f32.mul (global.get $dropA) (f32.sub (f32.load offset=8 (local.get $s)) (local.get $e)))))
        (f32.store offset=12 (local.get $s) (local.get $e))
        (call $svf (local.get $s) (local.get $c)
          (f32.mul (local.get $e) (call $rand (i32.add (local.get $s) (i32.const 48))))))))

  ;; 1샘플: 스케줄러 진행 + 활성 보이스 합산 → $dL, $dR
  (func $drops
    (local $v i32) (local $q f32) (local $l f32) (local $r f32) (local $gn f32)
    (global.set $dropT (f32.sub (global.get $dropT) (f32.const 1)))
    (block $d (loop $l
      (br_if $d (f32.gt (global.get $dropT) (f32.const 0)))
      (call $trigger)
      (global.set $dropT (f32.add (global.get $dropT) (call $interval (i32.const 1348) (call $p (i32.const 13)))))
      (br $l)))
    (local.set $v (i32.const 4096))
    (block $d (loop $l
      (br_if $d (i32.ge_u (local.get $v) (i32.const 6144)))
      (if (i32.load offset=44 (local.get $v))
        (then
          (local.set $gn (f32.load offset=32 (local.get $v)))
          (call $side (local.get $v) (i32.add (local.get $v) (i32.const 16)) (f32.load offset=52 (local.get $v)))
          (local.set $l (f32.add (local.get $l)
            (f32.mul (global.get $bp) (f32.mul (local.get $gn) (f32.load offset=36 (local.get $v))))))
          (local.set $q (f32.add (f32.abs (global.get $bp)) (f32.abs (global.get $lo))))
          (call $side (i32.add (local.get $v) (i32.const 64)) (i32.add (local.get $v) (i32.const 16)) (f32.load offset=52 (local.get $v)))
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
    (global.set $dL (local.get $l))
    (global.set $dR (local.get $r)))

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
    (call $svf (i32.add (local.get $b) (i32.const 108)) (i32.const 2160)
      (f32.add (local.get $pit) (f32.mul (f32.mul (call $p (i32.const 12)) (global.get $GR)) (local.get $drop))))
    (local.set $pit (global.get $lo))

    ;; 믹스
    (local.set $x (f32.add
      (f32.add (f32.mul (f32.mul (call $p (i32.const 1)) (global.get $GW)) (local.get $w))
               (f32.mul (f32.mul (call $p (i32.const 2)) (global.get $GP)) (local.get $pink)))
      (f32.add (f32.mul (f32.mul (call $p (i32.const 3)) (global.get $GB)) (local.get $br))
               (f32.add (local.get $deep) (local.get $pit)))))

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
      (br_if $d (i32.ge_u (local.get $id) (i32.const 32)))
      (local.set $addr (i32.shl (local.get $id) (i32.const 2)))
      (local.set $cur (f32.load offset=3200 (local.get $addr)))
      (local.set $tgt (f32.load offset=3072 (local.get $addr)))
      (f32.store offset=3200 (local.get $addr)
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
      (local.set $g (f32.mul (local.get $m)
        (f32.mul (f32.mul (local.get $e) (local.get $e))
                 (f32.sub (f32.const 3) (f32.mul (f32.const 2) (local.get $e))))))

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
        (call $clip (f32.mul (f32.load offset=6144 (global.get $li)) (global.get $limG))))
      (f32.store offset=512 (local.get $addr)
        (call $clip (f32.mul (f32.load offset=6400 (global.get $li)) (global.get $limG))))
      (f32.store offset=6144 (global.get $li) (local.get $xl))
      (f32.store offset=6400 (global.get $li) (local.get $xr))
      (global.set $li (i32.and (i32.add (global.get $li) (i32.const 4)) (i32.const 255)))

      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)))
    (global.set $envL (local.get $e)))
)
