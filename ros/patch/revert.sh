#!/bin/bash
# vesc_driver를 순정으로 원복 + 재빌드.
set -e
WS="${WS:-/home/hmcl/unicorn_ws/ICRA2026_SH_ros2}"
PATCH="$(cd "$(dirname "$0")" && pwd)/vesc_driver_arbiter_feedback.patch"
cd "$WS"
if git apply --reverse --check "$PATCH" 2>/dev/null; then
  git apply --reverse "$PATCH"; echo "[revert] vesc_driver 순정 복원"
else
  echo "[revert] 적용 안 돼 있음 (이미 순정?)"
fi
source install/setup.bash 2>/dev/null || true
colcon build --packages-select vesc_driver
