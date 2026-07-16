# VESC RC-Failsafe Arbiter (F1TENTH)

컴퓨터(자율주행 PC)가 죽어도 **RC 조종(joy)이 살아있는** F1TENTH 스택.
RC 수신기를 VESC에 직접 물리고, **VESC 커스텀 펌웨어**가 RC와 컴퓨터 명령을
중재(arbitrate)한다. 컴퓨터의 표준 `vesc_driver` 명령 경로는 **바꾸지 않는다.**

## 동작 개요

- RC 수신기(ELRS/CRSF) → **VESC COMM UART(USART3)** 직결
- 컴퓨터 → **USB** 로 표준 VESC 명령(`SET_RPM`/`SET_SERVO_POS`, 즉 `vesc_driver`)
- 펌웨어 안의 arbiter(단일 writer)가 우선순위로 중재:

  | 조건 | 동작 |
  |---|---|
  | RC 프레임 끊김 | 정지 (최우선 안전) |
  | arm 스위치 OFF | 정지 (estop) |
  | **수동**(mode 스위치 LOW) | RC가 모터·서보 구동, 컴퓨터 명령 무시 |
  | **자동**(mode HIGH) + 컴퓨터 살아있음 | 컴퓨터 명령 통과 |
  | **자동** + 컴퓨터 죽음(0.5s 무명령) | **RC로 자동 폴백** |

- 수동 모드에서도 PC가 상태를 볼 수 있게, 펌웨어가 `[mode, servo, steer, throttle]`을
  50Hz로 PC에 되보고 → `vesc_driver`(패치판)가 **`/rc/state`** 토픽으로 발행.

## RC 송신기 채널 맵 (필수)

| 채널(0-based) | 용도 |
|---|---|
| ch0 | 조향 (steer) |
| ch2 | 스로틀 (throttle) |
| ch5 | **arm** (마스터 enable / estop). HIGH=arm |
| ch6 | **mode**. LOW=수동, HIGH=자동 |

값 범위 CRSF 172~1811 (중앙 992), 스위치 HIGH 판정 > 1500.

---

# 새로 세팅하는 사람용 순서

## 1. 펌웨어 (VESC)

대상 하드웨어: **VESC 6 MkVI / MkVI HP** (`60_mk6` / `60_mk6_hp`), 베이스 fw **6.05**.

### 방법 A — fork 브랜치 (권장)
```bash
git clone https://github.com/heedo7425/bldc.git
cd bldc && git checkout feat/rc-failsafe-arbiter
make arm_sdk_install          # gcc-arm-none-eabi 7-2018-q2 자동 설치
make 60_mk6_hp                # -> build/60_mk6_hp/60_mk6_hp.bin
```
### 방법 B — 스톡 bldc에 패치 (fork 없이)
```bash
git clone https://github.com/vedderb/bldc.git
cd bldc && git checkout release_6_05
cp <repo>/firmware/bldc_changes/app_arbiter.c applications/
git apply <repo>/firmware/bldc_changes/bldc_existing_files.patch
make arm_sdk_install && make 60_mk6_hp
```

### 플래시 & VESC 설정 (VESC Tool)
1. Firmware 탭 → Custom File → `build/60_mk6_hp/60_mk6_hp.bin` → Upload
2. App Settings → General → **App to Use = Custom User App**
3. App Settings → General → **Enable Servo Output = True**
4. 모터: FOC 감지(Motor Setup Wizard) 완료해 둘 것 (센서리스 시동)

> 배선: RC 수신기 **T(CRSF out) → COMM RX(PB11)**, **G → GND**, **V → 5V**.
> 디버그: VESC Tool Terminal 에서 `arb` 입력 → 1초마다 arbiter 상태 출력(다시 `arb`로 끔).

## 2. PC (ROS 2 Jazzy) — 컴퓨터 명령 + `/rc/state` 피드백

`vesc_driver`가 우리 피드백 패킷을 파싱·발행하도록 **패치**가 필요하다
(안 하면 미등록 패킷 에러 스팸). **원본 vesc_driver는 안 건드리고 patch로만.**

### 의존성 (한 번)
```bash
sudo apt install -y libasio-dev     # io_context가 표준 asio.hpp 필요
```

### 방법 A — 기존 스택에 적용 (이 차만)
```bash
cd <your_ws_with_vesc_driver>
bash <repo>/ros/patch/apply.sh      # patch 적용 + colcon build (되돌리기: revert.sh)
```
`apply.sh`는 `git apply` 로 얹으므로 **커밋 안 하면 팀 레포 무영향**. 다른 차·사람 그대로.

### 방법 B — 깨끗한 전용 ws (도커 없이 로컬)
```bash
mkdir -p ~/vesc_ws/src && cd ~/vesc_ws/src
# 필요한 패키지만: vesc_msgs, vesc_driver, transport_drivers(io_context/serial_driver/asio_cmake_module)
cp -r <stack>/vesc_msgs <stack>/vesc_driver <stack>/transport_drivers .
cd vesc_driver && patch -p1 < <repo>/ros/patch/vesc_driver_arbiter_feedback.patch
cd ~/vesc_ws && source /opt/ros/jazzy/setup.bash && colcon build
```

### 실행
```bash
source install/setup.bash
ros2 run vesc_driver vesc_driver_node --ros-args \
  --params-file install/vesc_driver/share/vesc_driver/params/vesc_config.yaml \
  -p port:=/dev/ttyACM0
```
자율주행 스택은 **평소대로** `vesc_driver`가 구독하는 명령 토픽에 발행하면 된다 (무변경).

## 3. `/rc/state` 토픽

`std_msgs/Float64MultiArray`, `data = [mode, servo, steer, throttle]`
- mode: 0=정지/disarm, 1=수동(RC), 2=자동(컴퓨터), 3=자동-폴백(RC)
- servo: 0.0~1.0 (적용된 서보), steer/throttle: -1.0~1.0 (RC 원값)

```bash
ros2 topic echo /rc/state     # 스틱/스위치 움직이면 값 변함
```
수동 모드 odom 정확화: odom 노드의 조향 입력을 이 servo(또는 steer)에 연결.

## 4. 테스트

```bash
# 자동 모드 검증(자율주행 흉내): 속도 1875ERPM + 서보 좌우 1초주기
python3 <repo>/ros/auto_test_pub.py
```
- 수동(ch6 LOW)+arm → 조향/스로틀 스틱으로 조종
- 자동(ch6 HIGH)+arm + 위 test_pub → 모터·서보를 컴퓨터가 구동
- 자동 중 test_pub Ctrl-C → 0.5s 뒤 RC 폴백
- 자동 중 ch6→수동 → RC 즉시 인계

---

## 파일

| 경로 | 설명 |
|---|---|
| `firmware/bldc_changes/app_arbiter.c` | arbiter 본체 (CRSF 디코드 + 중재 + 피드백) |
| `firmware/bldc_changes/bldc_existing_files.patch` | conf_general.h / commands.c(게이트) / app.h 변경 |
| `ros/patch/vesc_driver_arbiter_feedback.patch` | vesc_driver 피드백 파싱·발행 패치 |
| `ros/patch/apply.sh` / `revert.sh` | 패치 적용 / 원복 |
| `ros/auto_test_pub.py` | 자동 모드 테스트 발행자 |
| `DESIGN.md` / `BRINGUP.md` | 설계 / 브링업 노트 |
| `firmware/*.lisp` | 초기 LispBM PoC (참고용, C로 이식됨) |

펌웨어 fork: https://github.com/heedo7425/bldc (branch `feat/rc-failsafe-arbiter`)
