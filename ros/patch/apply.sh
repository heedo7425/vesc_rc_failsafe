#!/bin/bash
# RC-failsafe arbiter feedback를 vesc_driver에 적용 (이 차만) + 재빌드.
# 원본 vesc_driver는 안 건드림 — patch로만 적용.
set -e
WS="${WS:-/home/hmcl/unicorn_ws/ICRA2026_SH_ros2}"
PATCH="$(cd "$(dirname "$0")" && pwd)/vesc_driver_arbiter_feedback.patch"
cd "$WS"
if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"; echo "[apply] vesc_driver 패치 적용됨"
elif git apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "[apply] 이미 적용돼 있음 — 건너뜀"
else
  echo "[apply] ERROR: patch가 깨끗이 안 붙음 (vesc_driver가 바뀌었나?)"; exit 1
fi
source install/setup.bash 2>/dev/null || true
colcon build --packages-select vesc_driver
echo "[apply] 완료 — vesc_driver가 /vesc/rc/{mode,servo_position,steer,throttle} 발행"
