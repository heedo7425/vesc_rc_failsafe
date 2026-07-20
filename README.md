# VESC RC-Failsafe Arbiter (F1TENTH)

자율주행 PC가 죽어도 **RC 조종(joy)이 살아있는** F1TENTH 스택.
RC 수신기를 VESC에 직접 물리고, **VESC 커스텀 펌웨어**가 RC와 컴퓨터 명령을
중재(arbitrate)한다. **컴퓨터의 표준 `vesc_driver` 명령 경로는 바꾸지 않는다.**

```
RC 송신기 ──2.4GHz──▶ 수신기(ELRS/CRSF) ──UART(COMM)──┐
                                                      ├──▶ [VESC 펌웨어 arbiter] ──▶ 모터 + 서보
자율주행 PC ──USB(표준 vesc_driver: SET_RPM/SET_SERVO)─┘        │
                                                               └──50Hz 피드백──▶ PC (/rc/state)
```

우선순위(단일 writer): **RC끊김 > arm OFF(estop) > 수동(RC) > 자동(컴퓨터) > 자동인데 컴퓨터죽음→RC폴백**

---

## 0. 준비물 / 채널 맵

- 하드웨어: **VESC 6 MkVI / MkVI HP** (`60_mk6` / `60_mk6_hp`), 베이스 펌웨어 **6.05**
- RC: ELRS(CRSF) 수신기 + 송신기. **CRSF T패드 → VESC COMM RX**, G→GND, V→5V
- PC: **ROS 2 (humble/jazzy 둘 다 확인됨)**

| RC 채널(0-based) | 용도 | 판정 |
|---|---|---|
| ch0 | 조향 | -1~1 |
| ch2 | 스로틀 | -1~1 |
| ch5 | **arm** (마스터/estop) | >1500 = arm |
| ch6 | **mode** | LOW=수동, HIGH=자동 |

---

## 1. 펌웨어 (차/VESC 단위, 한 번)

```bash
git clone https://github.com/heedo7425/bldc.git
cd bldc && git checkout feat/rc-failsafe-arbiter
make arm_sdk_install          # gcc-arm-none-eabi 7-2018-q2 자동 설치
make 60_mk6_hp                # -> build/60_mk6_hp/60_mk6_hp.bin  (MkVI는 make 60_mk6)
```
> fork 없이 스톡 bldc에 얹으려면: `release_6_05` 체크아웃 후
> `firmware/bldc_changes/app_arbiter.c` 를 `applications/` 에 복사 +
> `git apply firmware/bldc_changes/bldc_existing_files.patch` → `make 60_mk6_hp`.

**VESC Tool 로 플래시 & 설정:**
1. Firmware 탭 → Custom File → `build/60_mk6_hp/60_mk6_hp.bin` → Upload
2. App Settings → General → **App to Use = Custom User App**
3. App Settings → General → **Enable Servo Output = True**
4. Motor → **FOC 감지(Setup Wizard) 완료** (센서리스 시동에 필수)

> 디버그: VESC Tool Terminal 에 `arb` → 1초마다 arbiter 상태 출력(다시 `arb`로 끔).

---

## 2. PC (머신 단위)

`vesc_driver` 가 우리 피드백 패킷을 파싱·발행하도록 **패치**가 필요하다
(안 하면 미등록 패킷 에러 스팸 + `/rc/state` 안 나옴).

### 의존성 (한 번)
```bash
sudo apt install -y libasio-dev     # transport_drivers(io_context)가 표준 asio.hpp 필요
```

### 방법 A (권장) — 전용 ws 자동 생성, **팀 스택 무변경**
팀 스택에 이미 있는 `vesc_msgs` / `vesc_driver` / `transport_drivers` 를 복사해
패치된 전용 ws(`~/vesc_test`)를 만든다.
```bash
git clone https://github.com/heedo7425/vesc_rc_failsafe.git
cd vesc_rc_failsafe
./ros/patch/setup_vesc_test.sh <팀_스택_src_경로>
#   예: ./ros/patch/setup_vesc_test.sh ~/unicorn_ws/src
```
→ `~/vesc_test` 에 빌드 완료. 기존 팀 워크스페이스는 **하나도 안 바뀐다.**

### 방법 B — 기존 vesc_driver 에 in-place 패치 (이 차만)
```bash
./ros/patch/apply.sh  <vesc_driver 패키지 경로>
#   예: ./ros/patch/apply.sh ~/unicorn_ws/src/.../vesc/vesc_driver
cd <ws> && colcon build --packages-select vesc_driver
# 되돌리기: ./ros/patch/revert.sh <같은 경로>
```

### 실행
```bash
source install/setup.bash
ros2 run vesc_driver vesc_driver_node --ros-args \
  --params-file install/vesc_driver/share/vesc_driver/params/vesc_config.yaml \
  -p port:=/dev/ttyACM0
```
자율주행 스택은 **평소대로** `vesc_driver` 명령 토픽에 발행하면 된다 (무변경).

---

## 3. 확인 — `/rc/state`

`std_msgs/Float64MultiArray`, `data = [mode, servo, steer, throttle, speed_ms]`
- **mode**: 0=정지/disarm, 1=수동(RC), 2=자동(컴퓨터), 3=자동-폴백(RC)
- **servo** 0~1 (적용된 서보) · **steer/throttle** -1~1 (RC 원값) · **speed_ms** m/s (텔레메트리, 모든 모드)

**터미널 2개:**
```bash
# 터미널 1: 위 "실행" 명령으로 vesc_driver 켜두기
# 터미널 2:
source install/setup.bash
ros2 topic echo /rc/state
```
조종기에서 **arm(ch5) HIGH** → `mode` 1로, **조향 스틱** → `servo`/`steer` 변함,
**mode(ch6) HIGH** → `mode` 2. (disarm 이면 계속 `[0, 0.5, 0, 0, 0]`)

> speed 변환값이 다르면 실행에 `-p speed_to_erpm_gain:=<값>` (기본 1875).
> 수동 odom 정확화: odom 노드의 조향 입력을 `/rc/state` 의 servo/steer 로 연결.

## 4. 테스트 (자동/폴백)
```bash
python3 ros/auto_test_pub.py    # 속도 1875ERPM + 서보 좌우 1초주기 (자율주행 흉내)
```
- 수동(ch6 LOW)+arm → 스틱으로 조종 · 자동(ch6 HIGH)+arm+test_pub → 컴퓨터가 구동
- 자동 중 test_pub `Ctrl-C` → 0.5s 뒤 RC 폴백 · 자동 중 ch6→수동 → RC 즉시 인계

---

## 트러블슈팅
| 증상 | 원인/해결 |
|---|---|
| `asio.hpp: No such file` | `sudo apt install libasio-dev` |
| `/rc/state` 토픽은 있는데 데이터 없음 | VESC에 **arbiter 펌웨어 미플래시** (1단계) |
| vesc_driver `Segmentation fault` | 옛 패치 버전. 최신 patch 재적용(생성자 전 도착 패킷 가드 포함) |
| 서보/모터 무반응 | App=Custom + Servo Output=True 확인 / 모터는 FOC 감지 필요 |
| 모터 떨기만 함(안 돎) | FOC 센서리스 시동 — 재감지(flux linkage), 3상 배선 확인 |
| 툴 슬라이더로 모터 안 돎 | **정상** — arbiter가 수동/폴백일 때 comm 명령 차단. RC 스틱으로 테스트 |

## 파일
| 경로 | 설명 |
|---|---|
| `firmware/bldc_changes/app_arbiter.c` | arbiter 본체 (CRSF + 중재 + 피드백) |
| `firmware/bldc_changes/bldc_existing_files.patch` | conf_general.h / commands.c(게이트) / app.h |
| `ros/patch/vesc_driver_arbiter_feedback.patch` | vesc_driver 피드백 파싱·발행 (패키지 상대, `-p1`) |
| `ros/patch/setup_vesc_test.sh` | **전용 ws 자동 생성** (권장) |
| `ros/patch/apply.sh` / `revert.sh` | 기존 vesc_driver in-place 패치 / 원복 |
| `ros/auto_test_pub.py` | 자동 모드 테스트 발행자 |
| `DESIGN.md` / `BRINGUP.md` | 설계 / 브링업 노트 · `firmware/*.lisp` LispBM PoC |

펌웨어 fork: https://github.com/heedo7425/bldc (branch `feat/rc-failsafe-arbiter`)
