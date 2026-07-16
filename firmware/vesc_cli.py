#!/usr/bin/env python3
"""VESC 시리얼 CLI (GUI 없이 /dev/ttyACM0 직접).

기능:
  fw                  펌웨어 버전
  stats               LispBM 실행 통계 (running 여부)
  readcode [n]        플래시된 lisp 코드 앞부분 read-only 검사
  run / stop          LispBM 시작 / 정지 (SET_RUNNING)
  repl "<expr>"       LispBM 표현식 실시간 평가 (프린트 결과 수집)

사용:  python3 vesc_cli.py <cmd> [args]   (기본 포트 /dev/ttyACM0)
"""
import serial, sys, time

# --- COMM_PACKET_ID (fw 6.06) ---
COMM_FW_VERSION       = 0
COMM_LISP_READ_CODE   = 130
COMM_LISP_WRITE_CODE  = 131
COMM_LISP_ERASE_CODE  = 132
COMM_LISP_SET_RUNNING = 133
COMM_LISP_GET_STATS   = 134
COMM_LISP_PRINT       = 135
COMM_LISP_REPL_CMD    = 138

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
    """buf에서 완결된 프레임들을 뽑아 payload 리스트로 반환, 소비한 바이트는 제거."""
    out = []
    i = 0
    while i < len(buf):
        if buf[i] == 0x02 and i + 1 < len(buf):
            ln = buf[i+1]; hdr = 2
        elif buf[i] == 0x03 and i + 2 < len(buf):
            ln = (buf[i+1] << 8) | buf[i+2]; hdr = 3
        else:
            i += 1; continue
        total = hdr + ln + 3
        if i + total > len(buf):
            break  # 아직 덜 옴
        payload = bytes(buf[i+hdr : i+hdr+ln])
        stop = buf[i+total-1]
        if stop == 0x03:
            out.append(payload)
            i += total
        else:
            i += 1
    del buf[:i]
    return out

def collect(ser, seconds, want_id=None):
    """seconds 동안 들어오는 프레임 모두 수집. want_id 지정 시 그 id만 payload 반환."""
    buf = bytearray(); res = []
    t0 = time.time()
    while time.time() - t0 < seconds:
        chunk = ser.read(512)
        if chunk:
            buf += chunk
            for p in parse_frames(buf):
                if p and (want_id is None or p[0] == want_id):
                    res.append(p)
        else:
            if res and want_id is None:
                break
    return res

def open_port(port):
    ser = serial.Serial(port, 115200, timeout=0.2)
    time.sleep(0.2); ser.reset_input_buffer()
    return ser

def send(ser, payload):
    ser.write(frame(payload)); ser.flush()

# ---------------- commands ----------------
def cmd_fw(ser):
    send(ser, bytes([COMM_FW_VERSION]))
    ps = collect(ser, 1.0, COMM_FW_VERSION)
    if not ps: return print("no reply")
    p = ps[0]; major, minor = p[1], p[2]
    end = p.index(0, 3); hw = p[3:end].decode(errors="replace")
    print(f"FW {major}.{minor:02d}  HW '{hw}'")

def cmd_stats(ser):
    send(ser, bytes([COMM_LISP_GET_STATS]))
    ps = collect(ser, 1.0)
    for p in ps:
        print(f"id={p[0]} len={len(p)} raw={p[:40].hex()}")
    if not ps: print("no reply (lisp 미실행일 수 있음)")

def cmd_readcode(ser, n=64):
    # [130][int32 len][int32 offset]  (little-endian 추정)
    import struct
    send(ser, bytes([COMM_LISP_READ_CODE]) + struct.pack("<ii", n, 0))
    ps = collect(ser, 1.0, COMM_LISP_READ_CODE)
    if not ps: return print("READ_CODE 무응답 (다른 레이아웃일 수 있음)")
    p = ps[0]
    print(f"raw reply ({len(p)}B): {p.hex()}")
    # 뒷부분을 텍스트로도
    txt = bytes(b if 32 <= b < 127 else 46 for b in p[5:])
    print("as text:", txt.decode(errors='replace'))

def cmd_setrunning(ser, val):
    send(ser, bytes([COMM_LISP_SET_RUNNING, 1 if val else 0]))
    ps = collect(ser, 1.5)
    for p in ps:
        print(f"reply id={p[0]} {p.hex()}")
    print("SET_RUNNING", val, "sent")

def cmd_reboot(ser):
    COMM_REBOOT = 29
    send(ser, bytes([COMM_REBOOT]))
    print("reboot 전송")

def cmd_listen(ser, secs=4.0):
    # 실행중인 스크립트의 send-data(36) 프레임을 secs 동안 전부 수집 (early-break 없음)
    COMM_CUSTOM_APP_DATA = 36
    buf = bytearray(); data = []; maxcnt = -1; nonzero = 0
    t0 = time.time()
    while time.time() - t0 < secs:
        chunk = ser.read(512)
        if not chunk: continue
        buf += chunk
        for p in parse_frames(buf):
            if not p: continue
            if p[0] == COMM_LISP_PRINT:
                print("PRINT:", p[1:].split(b"\x00")[0].decode(errors="replace"))
            elif p[0] == COMM_CUSTOM_APP_DATA:
                data.append(p)
                body = p[1:]
                if len(body) >= 48:
                    cnt = body[47]
                    maxcnt = max(maxcnt, cnt)
                    nonzero += sum(1 for b in body[:47] if b != 0xAA)
    print(f"프레임 {len(data)}개, 최대 카운터={maxcnt}, 0xAA아닌 바이트 관측={nonzero}")
    for p in data[-4:]:
        print("data:", p[1:].hex())

def cmd_repl(ser, expr, wait=1.5):
    # 실행중이 아니면 프린트가 안 올 수 있음 → 먼저 stats 안 봄, 그냥 시도
    send(ser, bytes([COMM_LISP_REPL_CMD]) + expr.encode() + b"\x00")
    ps = collect(ser, wait, COMM_LISP_PRINT)
    if not ps:
        print("(no LISP_PRINT — lisp 미실행? 'run' 먼저 시도)")
    for p in ps:
        print(p[1:].split(b"\x00")[0].decode(errors="replace"))

def main():
    args = sys.argv[1:]
    if not args: return print(__doc__)
    cmd = args[0]
    port = "/dev/ttyACM0"
    # 마지막 인자가 /dev/... 면 포트로
    if args and args[-1].startswith("/dev/"):
        port = args[-1]; args = args[:-1]
    ser = open_port(port)
    try:
        if cmd == "fw": cmd_fw(ser)
        elif cmd == "stats": cmd_stats(ser)
        elif cmd == "readcode": cmd_readcode(ser, int(args[1]) if len(args) > 1 else 64)
        elif cmd == "run": cmd_setrunning(ser, True)
        elif cmd == "stop": cmd_setrunning(ser, False)
        elif cmd == "reboot": cmd_reboot(ser)
        elif cmd == "listen": cmd_listen(ser, float(args[1]) if len(args) > 1 else 4.0)
        elif cmd == "repl": cmd_repl(ser, args[1], float(args[2]) if len(args) > 2 else 1.5)
        else: print("unknown cmd:", cmd)
    finally:
        ser.close()

if __name__ == "__main__":
    main()
