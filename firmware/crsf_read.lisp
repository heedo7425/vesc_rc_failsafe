; ===== CRSF RC 읽기 (VESC LispBM, 검증됨 2026-07-15) =====
; ELRS 수신기 CRSF T패드 -> COMM RX(PB11), V->5V, G->GND
; baud 420000. 채널: ch0=조향, ch2=스로틀, ch5/ch6=aux 스위치
; 값 범위 172~1811, 중앙 992
(uart-start 420000)
(def buf (bufcreate 64))
(def pl (bufcreate 22))

; 11비트 채널 언팩 (payload pl에서 i번째 채널)
(defun getch (i)
  (let ((bo (/ (* i 11) 8))
        (sh (mod (* i 11) 8)))
    (bitwise-and
      (bitwise-or (bitwise-or
        (shr (bufget-u8 pl bo) sh)
        (shl (bufget-u8 pl (+ bo 1)) (- 8 sh)))
        (shl (bufget-u8 pl (+ bo 2)) (- 16 sh)))
      0x7ff)))

; 한 번 읽어서 최신 RC 프레임을 pl에 채우고 t 반환(프레임 없으면 nil)
(defun crsf-poll ()
  (let ((n (uart-read buf 64)) (got nil))
    (looprange i 0 (- n 25)
      (if (and (not got)
               (= (bufget-u8 buf i) 0xc8)
               (= (bufget-u8 buf (+ i 2)) 0x16))
          (progn
            (looprange k 0 22 (bufset-u8 pl k (bufget-u8 buf (+ i 3 k))))
            (setq got t))))
    got))

; 모니터: 채널 값 출력
(loopwhile t
  (progn
    (if (crsf-poll)
        (print (list 'steer (getch 0) 'thr (getch 2) 'b5 (getch 5) 'b6 (getch 6))))
    (sleep 0.15)))
