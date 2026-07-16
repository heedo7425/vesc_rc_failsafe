; 결정적 UART 진단. 프레임: [0xEE][n mod256][rx0..rx3]
; EE=새 스크립트 실행 확인, n=수신카운터, rx0..3=받은 바이트(루프백시 11 22 33 44)
(uart-start 115200)
(def rx (bufcreate 4))
(bufclear rx 0xAA)
(def n 0)

(spawn (fn ()
  (loopwhile t
    (progn (uart-read-bytes rx 4 0) (setq n (+ n 1))))))

(def tx (bufcreate 4))
(bufset-u8 tx 0 0x11)
(bufset-u8 tx 1 0x22)
(bufset-u8 tx 2 0x33)
(bufset-u8 tx 3 0x44)

(def rep (bufcreate 6))
(loopwhile t
  (progn
    (uart-write tx)
    (bufset-u8 rep 0 0xee)
    (bufset-u8 rep 1 (mod n 256))
    (bufset-u8 rep 2 (bufget-u8 rx 0))
    (bufset-u8 rep 3 (bufget-u8 rx 1))
    (bufset-u8 rep 4 (bufget-u8 rx 2))
    (bufset-u8 rep 5 (bufget-u8 rx 3))
    (send-data rep)
    (sleep 0.2)))
