;; ─────────────────────────────────────────────────────────────
;;  Deep Noise Engine — WebAssembly DSP core
;;  레이어: White / Pink / Brown / Deep(서브 베이스) / Rain(빗방울)
;;  체인:  믹스 → 베이스 셸프 → 로우패스(+스웰 변조) → Air → 스웰 AM
;;         → 웜스(새츄레이션) → DC 차단 → 마스터 → 세이프티 클리퍼
;; ─────────────────────────────────────────────────────────────
(module
  (import "m" "tan" (func $tan (param f64) (result f64)))
  (import "m" "sin" (func $sin (param f64) (result f64)))
  (import "m" "cos" (func $cos (param f64) (result f64)))
  (memory (export "memory") 1)

  ;; ── 메모리 맵 ──────────────────────────────────────────────
  ;; 0     출력 L (128 f32)      512   출력 R (128 f32)
  ;; 1024  채널 L 상태 (128B)    1152  채널 R 상태 (128B)
  ;; 1280  딥 레이어 상태        1344  공통 RNG
  ;; 2048  필터 계수 (각 16B: a1 a2 a3 k)
  ;; 3072  파라미터 목표값       3200  파라미터 현재값(스무딩)
  ;;
  ;; 채널 상태 오프셋: 0 rng, 4..28 pink b0..b6, 32 brown,
  ;; 36/40 bass svf, 44/48 lp svf, 52 air lp, 56 dc x1, 60 dc y1,
  ;; 64/68 rain svf, 72 rain env, 80 rain rng

  (global $sr     (mut f32) (f32.const 48000))
  (global $lo     (mut f32) (f32.const 0))
  (global $bp     (mut f32) (f32.const 0))
  (global $mA     (mut f32) (f32.const 1))   ;; 공통 노이즈 비율
  (global $mB     (mut f32) (f32.const 0))   ;; 채널 독립 노이즈 비율
  (global $rainP  (mut f32) (f32.const 0))
  (global $airC   (mut f32) (f32.const 0.3))
  (global $dcR    (mut f32) (f32.const 0.998))
  (global $s1 (mut f32) (f32.const 0)) (global $c1 (mut f32) (f32.const 1))
  (global $s2 (mut f32) (f32.const 0)) (global $c2 (mut f32) (f32.const 1))
  (global $swCur  (mut f32) (f32.const 1))

  ;; 레이어별 RMS 보정 게인
  (global $GW f32 (f32.const 0.30))
  (global $GP f32 (f32.const 0.95))
  (global $GB f32 (f32.const 0.95))
  (global $GD f32 (f32.const 1.5))
  (global $GR f32 (f32.const 4.5))

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

  ;; TPT 상태변수필터 계수 (Simper)
  (func $svfcoef (param $c i32) (param $fc f32) (param $q f32)
    (local $g f32) (local $k f32) (local $a1 f32)
    (local.set $fc (f32.min (local.get $fc) (f32.mul (global.get $sr) (f32.const 0.45))))
    (local.set $fc (f32.max (local.get $fc) (f32.const 5)))
    (local.set $g (f32.demote_f64 (call $tan (f64.promote_f32
      (f32.div (f32.mul (f32.const 3.14159265) (local.get $fc)) (global.get $sr))))))
    (local.set $k (f32.div (f32.const 1) (local.get $q)))
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
    (i32.store (i32.const 1024) (i32.const 0x2545F491))
    (i32.store (i32.const 1152) (i32.const 0x9E3779B9))
    (i32.store (i32.const 1104) (i32.const 0x7F4A7C15))
    (i32.store (i32.const 1232) (i32.const 0x1B873593))
    (i32.store (i32.const 1344) (i32.const 0x68E31DA4))
    (call $svfcoef (i32.const 2080) (f32.const 90) (f32.const 0.7))     ;; bass shelf
    (call $svfcoef (i32.const 2128) (f32.const 2600) (f32.const 0.6))   ;; rain bandpass
    (global.set $airC (f32.min (f32.const 1)
      (f32.div (f32.mul (f32.const 6.2831853) (f32.const 2500)) (global.get $sr))))
    (global.set $dcR (f32.sub (f32.const 1)
      (f32.div (f32.mul (f32.const 6.2831853) (f32.const 12)) (global.get $sr))))
    (global.set $s1 (f32.const 0)) (global.set $c1 (f32.const 1))
    (global.set $s2 (f32.const 0.6)) (global.set $c2 (f32.const 0.8)))

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

  ;; ── 채널 1샘플 ─────────────────────────────────────────────
  (func $chan (param $b i32) (param $wC f32) (param $deep f32) (param $amp f32) (param $out i32)
    (local $wX f32) (local $w f32) (local $pink f32) (local $br f32)
    (local $env f32) (local $r f32) (local $x f32) (local $a f32) (local $wv f32) (local $y f32)

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
    (local.set $br (f32.add (f32.mul (f32.load offset=32 (local.get $b)) (f32.const 0.980392))
                            (f32.mul (local.get $w) (f32.const 0.0196078))))
    (f32.store offset=32 (local.get $b) (local.get $br))
    (local.set $br (f32.mul (local.get $br) (f32.const 3.5)))

    ;; Rain: 랜덤 트리거 → 짧은 엔벨로프의 노이즈 버스트 → 밴드패스
    (local.set $env (f32.mul (f32.load offset=72 (local.get $b)) (f32.const 0.993)))
    (local.set $r (f32.mul (f32.add (call $rand (i32.add (local.get $b) (i32.const 80))) (f32.const 1)) (f32.const 0.5)))
    (if (f32.lt (local.get $r) (global.get $rainP))
      (then
        (local.set $a (f32.add (f32.const 0.25)
          (f32.mul (f32.const 0.75) (f32.abs (call $rand (i32.add (local.get $b) (i32.const 80)))))))
        (local.set $env (f32.max (local.get $env) (f32.mul (local.get $a) (local.get $a))))))
    (f32.store offset=72 (local.get $b) (local.get $env))
    (call $svf (i32.add (local.get $b) (i32.const 64)) (i32.const 2128) (f32.mul (local.get $env) (local.get $wX)))

    ;; 믹스
    (local.set $x (f32.add
      (f32.add (f32.mul (f32.mul (call $p (i32.const 1)) (global.get $GW)) (local.get $w))
               (f32.mul (f32.mul (call $p (i32.const 2)) (global.get $GP)) (local.get $pink)))
      (f32.add (f32.mul (f32.mul (call $p (i32.const 3)) (global.get $GB)) (local.get $br))
               (f32.add (local.get $deep)
                        (f32.mul (f32.mul (call $p (i32.const 12)) (global.get $GR)) (global.get $bp))))))

    ;; 베이스 셸프: x + g·LP(x)
    (call $svf (i32.add (local.get $b) (i32.const 36)) (i32.const 2080) (local.get $x))
    (local.set $x (f32.add (local.get $x) (f32.mul (call $p (i32.const 6)) (global.get $lo))))

    ;; 메인 로우패스 (톤)
    (call $svf (i32.add (local.get $b) (i32.const 44)) (i32.const 2096) (local.get $x))
    (local.set $x (global.get $lo))

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

    (f32.store (local.get $out) (call $sat (f32.mul (local.get $y) (call $p (i32.const 0))))))

  ;; ── 블록 처리 ───────────────────────────────────────────────
  (func (export "process") (param $n i32)
    (local $i i32) (local $id i32) (local $addr i32) (local $cur f32) (local $tgt f32)
    (local $wC f32) (local $dl f32) (local $deep f32) (local $amp f32) (local $sw f32)
    (local $depth f32) (local $d f32) (local $cs1 f32) (local $sn1 f32) (local $cs2 f32) (local $sn2 f32)
    (local $t f32) (local $mag f32)

    ;; 파라미터 스무딩 (블록당)
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

    ;; 스테레오 폭
    (local.set $t (f32.min (f32.const 1) (f32.max (f32.const 0) (call $p (i32.const 9)))))
    (global.set $mA (f32.sqrt (f32.sub (f32.const 1) (local.get $t))))
    (global.set $mB (f32.sqrt (local.get $t)))

    ;; 빗방울 밀도
    (local.set $t (call $p (i32.const 13)))
    (global.set $rainP (f32.mul (f32.mul (local.get $t) (local.get $t))
      (f32.div (f32.const 300) (global.get $sr))))

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

      (local.set $addr (i32.shl (local.get $i) (i32.const 2)))
      (call $chan (i32.const 1024) (local.get $wC) (local.get $deep) (local.get $amp) (local.get $addr))
      (call $chan (i32.const 1152) (local.get $wC) (local.get $deep) (local.get $amp)
                  (i32.add (local.get $addr) (i32.const 512)))

      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop))))
)
