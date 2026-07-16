# Bring-up 체크리스트 (하드웨어에서 한 블록씩 검증)

VESC Tool → LispBM(VESC Scripting) 탭에 firmware/rc_failsafe.lisp 붙여넣고,
아래 순서로 한 단계씩 살린다. **바퀴는 항상 들고 시작. current 상한은 낮게.**

## 0. 사전 설정 (VESC Tool)
- [ ] 펌웨어 6.05 확인 (App Settings-General → Firmware)
- [ ] App General → **servo output 활성**
- [ ] 모터 FOC 감지/설정 완료 (별도 표준 절차)
- [ ] 컴퓨터는 USB 연결 (UART 비워둠)

## 1. RC 디코더만
- [ ] UART에 RC 신호선 배선 (CRSF: Rx TX → VESC UART RX, non-inverted 직결)
- [ ] `ch` 리스트를 print로 출력, 송신기 스틱/스위치 움직일 때 값 변하는지
- [ ] baud/극성/프레임 싱크 정상? (여기서 프로토콜 문제 다 드러남)

## 2. 채널 매핑 확정
- [ ] CH-STEER / CH-THR / CH-MODE / CH-ARM 인덱스를 실제 송신기에 맞춤
- [ ] aux 스위치 방향(manual/auto, arm/disarm) 부호 확인

## 3. 출력 단독 테스트
- [ ] `set-servo` 로 조향 서보 좌우+center 동작 (모터 비활성 상태)
- [ ] 바퀴 들고 `set-current-rel` 낮은 값으로 모터 방향/스로틀 감각

## 4. Failsafe (제일 중요)
- [ ] 제어루프/RC수신 **스레드 분리(spawn)** 적용
- [ ] RC 송신기 끄기 → 100ms 내 DISARM(모터 정지, 서보 center) 되는지
- [ ] arm 스위치 OFF → 즉시 DISARM
- [ ] estop 채널 → 즉시 DISARM

## 5. Arbitration
- [ ] MANUAL 모드: RC로 완전 조종
- [ ] AUTO 모드 + 컴퓨터 setpoint(custom data): 컴퓨터 명령 반영
- [ ] AUTO 모드 중 **컴퓨터 USB 뽑기** → 200ms 후 RC 수동 폴백 (★핵심 시나리오)
- [ ] 폴백 시 조향 급변 없는지

## 6. ROS 통합
- [ ] custom app data 송수신 얇은 드라이버 (ros/ 아래)
- [ ] 현재 모드가 ROS로 리포트되는지
