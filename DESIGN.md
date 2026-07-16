# VESC RC-Failsafe Firmware — 설계

## 목표
F1TENTH 차량에서 **컴퓨터가 죽어도 RC 조종(joy)은 살아있게** 한다.
기존 스택은 joy가 컴퓨터 안 논리입력이라 컴퓨터 사망 시 같이 죽음.
여기서는 RC 수신기를 VESC에 직결하고 **VESC 펌웨어(LispBM)가 직접 RC를 디코딩**하여
컴퓨터 생사와 무관하게 수동 조종이 유지되도록 한다.

## 핵심 원칙: 권한 역전 + 단일 writer
- RC = 펌웨어 내부 **최상위 권한** (항상 살아있음)
- 컴퓨터 = **종속 입력**. watchdog이 fresh하다고 인정할 때만 채택
- **모터/서보에 쓰는 주체는 LispBM 스크립트 오직 하나.**
  컴퓨터는 표준 VESC 명령(SET_RPM/SET_SERVO_POS)을 쓰면 안 되고,
  `COMM_CUSTOM_APP_DATA` 로 원하는 throttle/steer setpoint를 스크립트에 "제출"만 한다.
  (안 그러면 컴퓨터와 스크립트가 모터를 두고 race → arbitration 붕괴)

## 하드웨어 (확정)
- VESC: **MK6 / MK6 HP**, 펌웨어 **6.05** (팀 표준, vesc_fw_archive/6.05/60_MK6/VESC_default.bin)
- 컴퓨터 ↔ VESC: **USB (native CDC, /dev/ttyACM)** → UART가 비어 RC용으로 확보됨
- RC 수신기: **BetaFPV (ELRS 계열로 추정 → CRSF)**  ※ 정확 모델/프로토콜 확인 필요
- 스티어링 서보: **VESC PPM 포트 (JST-PH 3핀), servo output 활성** (App General)
- 구동모터: VESC 3상

## 배선
```
컴퓨터 ──USB──────────────→ VESC (custom app data)
RC Rx CRSF TX ──UART RX──→ VESC (non-inverted, 420k, 인버터 불필요)
VESC PPM포트 ──신호──────→ 스티어링 서보
VESC 3상 ────────────────→ 구동모터
```

## RC 프로토콜 분기 (확정 대기)
BetaFPV 수신기 종류에 따라 디코더가 갈림:
- **ELRS → CRSF**: 420000 8N1, non-inverted, 16ch×11bit + crc8. 배선 최선. (유력)
- FrSky → SBUS: 100000 8E2, **반전** → 인버터 트랜지스터 필요
- FlySky → iBUS: 115200 8N1, 14ch×16bit. 배선 쉬움

→ 정확 모델 확인 후 해당 디코더만 확정 구현. 나머지 아키텍처는 프로토콜 무관.

## Arbitration 상태기계 (100Hz)
```
rc_fresh  = (마지막 RC프레임 < 100ms) && (프로토콜 failsafe 플래그 정상)
cmd_fresh = (마지막 컴퓨터 setpoint < 200ms)

not rc_fresh        → DISARM (모터 정지, 서보 center)   # 최우선 안전
not armed(RC arm채널)→ DISARM
mode == MANUAL      → RC가 모터+서보 직접 구동
mode == AUTO & cmd_fresh  → 컴퓨터 setpoint 구동
mode == AUTO & !cmd_fresh → RC 수동 폴백  ★핵심 요구사항 (컴퓨터 사망)
```

## 반드시 지킬 안전 항목
1. **제어루프와 RC수신을 스레드 분리(spawn)** — 블로킹 read가 failsafe를 막지 않게.
   RC 끊겨도 제어루프는 100Hz로 돌며 secs-since로 끊김 감지 → DISARM.
2. **Arming 시퀀스** — 부팅 시 모터 비활성. arm채널 ON + 스로틀 중립 후에만 구동.
3. **RC failsafe 플래그 디코딩** — 프레임 존재만 보지 말고 CRSF/SBUS의 lost/failsafe 표시 확인.
   수신기 failsafe는 "hold"가 아닌 "no-output/중립"으로 설정.
4. **Estop 채널** — TX 물리 스위치 = 최우선 비상정지 (모드/컴퓨터 무관).
5. **모드 스위치 히스테리시스** — 주행 중 채널 노이즈로 auto↔manual 채터링 방지.
6. **핸드오버** — 컴퓨터→RC 폴백 시 조향 급변 완화(center 경유 or 램프).
7. **텔레메트리** — manual 중에도 VESC 상태 + 현재 모드를 ROS로 리포트 (누가 운전 중인지).

## 구현 순서
LispBM PoC 먼저 → 성능/기능 한계 시 C(app_custom) 포크. (BRINGUP.md 참조)

## ROS 통합 (후반)
표준 vesc_driver 대신 custom app data를 주고받는 얇은 드라이버 필요.
- 송신: [thr, str] setpoint (+ 필요시 mode 힌트)
- 수신: VESC 텔레메트리 + 현재 arbitration 모드
```

