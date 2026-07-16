; UART 루프백 테스트: TX로 패턴 쏘고 RX로 되읽음.
; VESC의 TX핀↔RX핀을 점퍼로 직접 연결하고 실행.
; rb[0..6]=수신 바이트, rb[7]=카운터. 0x55 37 99 01 패턴이 보이면 UART 정상.

(def baud 115200)
(def rb (bufcreate 8))
(bufclear rb 0xAA)
(def total 0)

(def out (bufcreate 4))
(bufset-u8 out 0 0x55)
(bufset-u8 out 1 0x37)
(bufset-u8 out 2 0x99)
(bufset-u8 out 3 0x01)

(uart-start baud)

; 송신 스레드
(spawn (fn ()
  (loopwhile t
    (progn (uart-write out) (sleep 0.05)))))

; 수신 스레드
(spawn (fn ()
  (let ((one (bufcreate 1)))
    (print "loopback reader up")
    (loopwhile t
      (progn
        (uart-read-bytes one 1 0)
        (bufset-u8 rb (mod total 7) (bufget-u8 one 0))
        (setq total (+ total 1)))))))

(loopwhile t
  (progn
    (bufset-u8 rb 7 (mod total 256))
    (send-data rb)
    (sleep 0.3)))
