; =====================================================================
;  ⚠ 디코더는 iBUS 기준 스켈레톤. BetaFPV=ELRS면 CRSF로 교체 필요.
;    RC 프로토콜 확정 후 [1] 수신 섹션만 CRSF/SBUS/iBUS로 스왑.
;    또한 v0는 블로킹 read 이슈 있음 → spawn 스레드 분리로 반드시 수정(BRINGUP [4]).
; =====================================================================
;  VESC RC-Failsafe Arbiter  (LispBM v0 skeleton)
;  - 유일한 모터/서보 writer. RC(iBUS) = 최상위, 컴퓨터(USB custom data) = 종속
;  - 하드웨어에서 아래 [BRINGUP] 순서대로 한 블록씩 검증하며 살릴 것
;  - 확장함수 이름은 펌웨어 버전마다 다를 수 있음 → [VERIFY] 표시된 곳 확인
; =====================================================================

; ---------------- config ----------------
(def uart-baud 115200)      ; iBUS. SBUS면 100000+8E2+인버터(별도 처리 필요)
(def rc-timeout   0.10)     ; s. RC 프레임 끊기면 DISARM
(def cmd-timeout  0.20)     ; s. 컴퓨터 setpoint 오래되면 = 컴퓨터 사망
(def loop-dt      0.01)     ; s. 100 Hz 제어루프

; 스로틀/조향 매핑 (차량 감각 튜닝 지점)
(def thr-deadband 0.06)     ; 중립 데드밴드
(def thr-max-cur  1.0)      ; set-current-rel 상한 (-1..1), 초기엔 낮게!
(def str-center   0.5)      ; servo 중앙 (0..1)
(def str-range    0.35)     ; 좌우 최대 편차

; iBUS 채널 매핑 (수신기 채널 순서에 맞게 조정) [VERIFY]
(def CH-STEER 0)  ; ch1
(def CH-THR   1)  ; ch2
(def CH-MODE  4)  ; ch5  aux 스위치 (auto/manual)
(def CH-ARM   5)  ; ch6  arm/estop 스위치

; ---------------- state ----------------
(def last-rc-t   (systime))
(def last-cmd-t  (systime))
(def cmd-thr 0.0)   ; 컴퓨터가 보낸 throttle setpoint (-1..1)
(def cmd-str 0.0)   ; 컴퓨터가 보낸 steer setpoint   (-1..1)
(def ch (list 1500 1500 1500 1500 1000 1000 1500 1500 1500 1500 1500 1500 1500 1500))

; =====================================================================
;  [1] iBUS 수신 (32B: 0x20 0x40, 14ch x2 LE, chk LE)
; =====================================================================
(def buf (bufcreate 32))

(defun ibus-checksum-ok ()
  (let ((s 0xFFFF))
    (looprange i 0 30 (setq s (- s (bufget-u8 buf i))))
    (= (mod s 65536)
       (+ (bufget-u8 buf 30) (* 256 (bufget-u8 buf 31))))))

(defun ibus-read-frame ()   ; 헤더 동기 후 한 프레임 채우면 t, 아니면 nil
  (uart-read-bytes buf 1 0)                       ; [VERIFY] uart-read-bytes 시그니처
  (if (= (bufget-u8 buf 0) 0x20)
      (progn
        (uart-read-bytes buf 1 1)
        (if (= (bufget-u8 buf 1) 0x40)
            (progn (uart-read-bytes buf 30 2)
                   (ibus-checksum-ok))
            nil))
      nil))

(defun ibus-extract ()      ; buf → ch 리스트(14) 갱신
  (looprange i 0 14
    (setix ch i (+ (bufget-u8 buf (+ 2 (* 2 i)))
                   (* 256 (bufget-u8 buf (+ 3 (* 2 i))))))))

; 1000..2000us → -1..1  (중앙 1500)
(defun norm (us) (/ (- us 1500.0) 500.0))
; -1..1 → 0..1
(defun to-servo (x) (+ str-center (* str-range x)))

(defun expo-db (x)          ; 데드밴드 + 약한 expo
  (if (< (abs x) thr-deadband) 0.0
      (let ((s (* x (abs x))))            ; x^2 expo
        (* thr-max-cur s))))

; =====================================================================
;  [2] 컴퓨터 setpoint 수신 (USB custom app data)  [BRINGUP 후반]
;  ROS 쪽에서 COMM_CUSTOM_APP_DATA 로 [thr, str] 바이트를 보냄
; =====================================================================
(defun on-cmd (data)        ; data = byte array
  ; TODO: 프로토콜 확정 후 파싱. 예: int16 thr, int16 str (x1000)
  (setq cmd-thr (/ (- (bufget-i16 data 0) 0) 1000.0))   ; [VERIFY] bufget-i16
  (setq cmd-str (/ (bufget-i16 data 2) 1000.0))
  (setq last-cmd-t (systime)))
; (event-enable 'event-data-rx)   ; [VERIFY] custom-data 이벤트 이름
; (defun proc-event (e) (match e ((event-data-rx (? d)) (on-cmd d))))

; =====================================================================
;  [3] 안전 출력 헬퍼 (모터/서보 writer는 여기 하나뿐)
; =====================================================================
(defun drive (thr str)      ; thr:-1..1(current-rel), str:-1..1
  (set-current-rel (expo-db thr))       ; [VERIFY] set-current-rel
  (set-servo (to-servo str))            ; [VERIFY] set-servo (servo핀 출력)
  (timeout-reset))                      ; 모터 timeout 갱신

(defun disarm ()
  (set-current-rel 0.0)
  (set-brake 2.0)                       ; [VERIFY] 약한 브레이크 or (set-current 0)
  (set-servo str-center))

; =====================================================================
;  [4] arbitration 상태기계
; =====================================================================
(defun mode-manual () (< (norm (ix ch CH-MODE)) 0.0))   ; aux 스위치 아래=manual
(defun armed ()       (> (norm (ix ch CH-ARM)) 0.0))    ; arm 스위치 위=arm

(defun step ()
  (let ((rc-fresh  (< (secs-since last-rc-t)  rc-timeout))
        (cmd-fresh (< (secs-since last-cmd-t) cmd-timeout)))
    (cond
      ((not rc-fresh)      (disarm))               ; RC 끊김 → 정지 (최우선)
      ((not (armed))       (disarm))               ; arm 안 됨 → 정지
      ((mode-manual)       (drive (norm (ix ch CH-THR)) (norm (ix ch CH-STEER))))
      (cmd-fresh           (drive cmd-thr cmd-str))          ; AUTO + 컴퓨터 살아있음
      (t                   (drive (norm (ix ch CH-THR))      ; AUTO지만 컴퓨터 사망
                                  (norm (ix ch CH-STEER))))))) ; → RC 수동 폴백 (★핵심)

; =====================================================================
;  [5] 메인 루프
; =====================================================================
(uart-start uart-baud)      ; [VERIFY] servo핀을 UART로 뺏기지 않는지 확인!
(loopwhile t
  (progn
    (if (ibus-read-frame)
        (progn (ibus-extract) (setq last-rc-t (systime))))
    (step)
    (sleep loop-dt)))
