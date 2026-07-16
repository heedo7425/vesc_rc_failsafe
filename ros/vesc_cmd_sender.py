#!/usr/bin/env python3
"""컴퓨터 -> VESC custom app data 송신 테스트 하네스.
arbiter/rx_test.lisp가 event-data-rx로 받을 [int16 steer, int16 thr] (x1000, big-endian) 송신.
동시에 VESC의 LISP_PRINT를 읽어 콘솔에 표시 (VESC Tool 없이 arbiter 출력 확인용).

사용:
  python3 vesc_cmd_sender.py [port] [--thr 0.0]
  기본: 서보 1초마다 좌우(±0.8) 반복, thr=0.0
  ※ VESC Tool은 Disconnect 해서 포트 비워둘 것 (lisp은 VESC에서 계속 돎)
"""
import serial, sys, struct, time

COMM_CUSTOM_APP_DATA = 36
COMM_LISP_PRINT = 135

def crc16(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= (b << 8); crc &= 0xFFFF
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc & 0xFFFF

def frame(payload: bytes) -> bytes:
    n = len(payload)
    head = bytes([0x02, n]) if n <= 255 else bytes([0x03, (n >> 8) & 0xFF, n & 0xFF])
    c = crc16(payload)
    return head + payload + bytes([(c >> 8) & 0xFF, c & 0xFF, 0x03])

def parse_frames(buf: bytearray):
    out = []; i = 0
    while i < len(buf):
        if buf[i] == 0x02 and i + 1 < len(buf):
            ln = buf[i+1]; hdr = 2
        elif buf[i] == 0x03 and i + 2 < len(buf):
            ln = (buf[i+1] << 8) | buf[i+2]; hdr = 3
        else:
            i += 1; continue
        total = hdr + ln + 3
        if i + total > len(buf): break
        if buf[i+total-1] == 0x03:
            out.append(bytes(buf[i+hdr:i+hdr+ln])); i += total
        else:
            i += 1
    del buf[:i]
    return out

def send_cmd(ser, steer, thr):
    payload = bytes([COMM_CUSTOM_APP_DATA]) + struct.pack('>hh',
                    int(max(-1,min(1,steer))*1000), int(max(-1,min(1,thr))*1000))
    ser.write(frame(payload)); ser.flush()

def main():
    port = "/dev/ttyACM0"
    thr = 0.0
    args = sys.argv[1:]
    for a in args:
        if a.startswith("/dev/"): port = a
    if "--thr" in args:
        thr = float(args[args.index("--thr")+1])

    ser = serial.Serial(port, 115200, timeout=0.02)
    time.sleep(0.2); ser.reset_input_buffer()
    print(f"[sender] {port} thr={thr}, 서보 ±0.8 1초 주기. Ctrl-C 종료.")
    rbuf = bytearray()
    t0 = time.time()
    sign = 1
    last_flip = t0
    try:
        while True:
            now = time.time()
            if now - last_flip >= 1.0:
                sign = -sign; last_flip = now
            steer = 0.8 * sign
            send_cmd(ser, steer, thr)
            # VESC로부터 오는 프린트 읽어 표시
            chunk = ser.read(256)
            if chunk:
                rbuf += chunk
                for p in parse_frames(rbuf):
                    if p and p[0] == COMM_LISP_PRINT:
                        print("[vesc]", p[1:].split(b"\x00")[0].decode(errors="replace"))
            time.sleep(0.05)
    except KeyboardInterrupt:
        send_cmd(ser, 0.0, 0.0)
        ser.close()
        print("\n[sender] 종료")

if __name__ == "__main__":
    main()
