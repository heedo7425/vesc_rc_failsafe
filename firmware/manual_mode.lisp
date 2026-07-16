; ===== 마일스톤2: 수동 모드 (RC -> 서보 + 모터) — 검증됨 2026-07-15 =====
; steer(ch0)->set-servo, thr(ch2)->set-current-rel
; arm 스위치(ch5): HIGH(>1500)일 때만 모터 활성 / RC 끊기면 failsafe 정지
; ★ crsf 성공판정은 전역 frames 카운터 증가로 (let 지역변수 리턴은 이 fw에서 전파 안 됨)
; ★ 바퀴 없는 맨모터 테스트. servo output은 App General에서 활성 필요.
(uart-start 420000)
(def buf (bufcreate 64))
(def pl (bufcreate 22))
(def frames 0)
(def prev-frames 0)
(def miss 0)

; 튜닝값
(def str-range 0.35)   ; 서보 좌우 편차 (중앙 0.5 기준)
(def thr-max 0.50)     ; 모터 current-rel 상한

(defun getch (i)
  (let ((bo (/ (* i 11) 8)) (sh (mod (* i 11) 8)))
    (bitwise-and
      (bitwise-or (bitwise-or
        (shr (bufget-u8 pl bo) sh)
        (shl (bufget-u8 pl (+ bo 1)) (- 8 sh)))
        (shl (bufget-u8 pl (+ bo 2)) (- 16 sh)))
      0x7ff)))

(defun crsf-poll ()
  (let ((n (uart-read buf 64)))
    (looprange i 0 (- n 25)
      (if (and (= (bufget-u8 buf i) 0xc8) (= (bufget-u8 buf (+ i 2)) 0x16))
          (progn
            (looprange k 0 22 (bufset-u8 pl k (bufget-u8 buf (+ i 3 k))))
            (setq frames (+ frames 1)))))))

(defun norm (ch)
  (let ((x (/ (- ch 992) 819.0)))
    (if (> x 1.0) 1.0 (if (< x -1.0) -1.0 x))))
(defun db (x) (if (< (abs x) 0.05) 0.0 x))

(loopwhile t
  (progn
    (crsf-poll)
    (if (> frames prev-frames) (setq miss 0) (setq miss (+ miss 1)))
    (setq prev-frames frames)
    (if (< miss 5)
        ; --- RC 살아있음 ---
        (progn
          (set-servo (+ 0.5 (* str-range (norm (getch 0)))))
          (if (> (getch 5) 1500)
              (set-current-rel (* thr-max (db (norm (getch 2)))))
              (set-current-rel 0.0)))
        ; --- RC 끊김: failsafe ---
        (progn
          (set-current-rel 0.0)
          (set-servo 0.5)))
    (sleep 0.02)))
