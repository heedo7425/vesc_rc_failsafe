; UART 수신 진단 (읽기 전용, 모터/서보 명령 없음).
; 버퍼[0..46] = 최근 수신 바이트, 버퍼[47] = 수신 카운터(mod 256).
; 0xAA 초기화 → 리더가 실제로 덮어쓰는지 확인 (idle vs 데이터 구분).

(def baud 420000)          ; CRSF(ELRS). 안 잡히면 115200/100000/250000 등으로 교체.
(def rb (bufcreate 48))
(bufclear rb 0xAA)
(def idx 0)
(def total 0)

(uart-start baud)

(spawn (fn ()
  (let ((one (bufcreate 1)))
    (print "reader up")
    (loopwhile t
      (progn
        (uart-read-bytes one 1 0)
        (bufset-u8 rb (mod idx 47) (bufget-u8 one 0))
        (setq idx (+ idx 1))
        (setq total (+ total 1)))))))

(loopwhile t
  (progn
    (bufset-u8 rb 47 (mod total 256))
    (send-data rb)
    (sleep 0.3)))
