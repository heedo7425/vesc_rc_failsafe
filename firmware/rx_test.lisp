; ===== event-data-rx 최소 수신 테스트 =====
; 컴퓨터가 custom app data(4B: int16 steer, int16 thr, x1000)를 보내면 print.
; GUI에서 Run → 콘솔에 "rx-test ready" → 컴퓨터가 보내면 (rx N steer X thr Y) 떠야 함.
(def rxs 0)
(def cmd-steer 0.0)
(def cmd-thr 0.0)

(defun on-data (data)
  (if (>= (buflen data) 4)
      (progn
        (setq cmd-steer (/ (bufget-i16 data 0) 1000.0))
        (setq cmd-thr   (/ (bufget-i16 data 2) 1000.0))
        (setq rxs (+ rxs 1))
        (print (list 'rx rxs 'steer cmd-steer 'thr cmd-thr)))))

(event-register-handler (spawn (fn ()
  (loopwhile t
    (recv ((event-data-rx . (? d)) (on-data d))
          (_ nil))))))
(event-enable 'event-data-rx)
(print "rx-test ready")
(loopwhile t (sleep 1))
