; ===== 마일스톤3: Arbiter 완성 (RC 수동 + 컴퓨터 자동 + 폴백 + estop) =====
; 단일 writer. 채널: ch0=조향 ch2=스로틀 ch5=arm(마스터/estop) ch6=모드(LOW수동/HIGH자동)
; 컴퓨터는 custom app data(4B: int16 steer, int16 thr, x1000, big-endian)로 setpoint 제출.
; 우선순위: RC끊김>arm off>수동>자동(컴퓨터fresh)>자동인데 컴퓨터죽음→RC폴백
; ★교훈: let body는 progn으로 감쌀것 / cond대신 nested if / 전역 def변수 setq로 상태전달
; ★event-data-rx 수신 검증됨(2026-07-15)
(uart-start 420000)
(def buf (bufcreate 64))
(def pl (bufcreate 22))
(def frames 0)
(def prev-frames 0)
(def rc-miss 0)
(def cmd-steer 0.0)
(def cmd-thr 0.0)
(def cmd-count 0)
(def prev-cmd 0)
(def cmd-miss 999)
(def str-range 0.35)
(def thr-max 0.50)
(def tick 0)

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
(defun clamp (x) (if (> x 1.0) 1.0 (if (< x -1.0) -1.0 x)))

; ---- 컴퓨터 명령 수신 (custom app data) — 검증됨 ----
(defun on-data (data)
  (if (>= (buflen data) 4)
      (progn
        (setq cmd-steer (/ (bufget-i16 data 0) 1000.0))
        (setq cmd-thr   (/ (bufget-i16 data 2) 1000.0))
        (setq cmd-count (+ cmd-count 1)))))
(event-register-handler (spawn (fn ()
  (loopwhile t
    (recv ((event-data-rx . (? d)) (on-data d))
          (_ nil))))))
(event-enable 'event-data-rx)

; ---- 출력 (단일 writer) ----
(defun drive (st th)
  (set-servo (+ 0.5 (* str-range (clamp st))))
  (set-current-rel (* thr-max (clamp th))))
(defun stop-all ()
  (set-current-rel 0.0)
  (set-servo 0.5))

; ---- arbitration 루프 ----
(loopwhile t
  (progn
    (crsf-poll)
    (if (> frames prev-frames) (setq rc-miss 0) (setq rc-miss (+ rc-miss 1)))
    (setq prev-frames frames)
    (if (> cmd-count prev-cmd) (setq cmd-miss 0) (setq cmd-miss (+ cmd-miss 1)))
    (setq prev-cmd cmd-count)
    (let ((rc-alive (< rc-miss 5))
          (armed (> (getch 5) 1500))
          (auto (> (getch 6) 1500))
          (cmd-fresh (< cmd-miss 25)))
      (progn
        (if (not rc-alive)
            (stop-all)
            (if (not armed)
                (stop-all)
                (if (not auto)
                    (drive (norm (getch 0)) (db (norm (getch 2))))
                    (if cmd-fresh
                        (drive cmd-steer cmd-thr)
                        (drive (norm (getch 0)) (db (norm (getch 2))))))))
        (setq tick (+ tick 1))
        (if (= (mod tick 25) 0)
            (print (list 'rc rc-alive 'arm armed 'mode (if auto 'AUTO 'MANUAL)
                         'cmd-fresh cmd-fresh 'cmds cmd-count 'steer (getch 0))))))
    (sleep 0.02)))
