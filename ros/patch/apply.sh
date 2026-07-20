#!/bin/bash
# 기존 vesc_driver 패키지에 RC-failsafe 피드백 패치를 in-place 적용한다 (이 차만).
# 팀 스택을 직접 바꾸므로, 안 건드리려면 setup_vesc_test.sh(전용 ws) 를 쓸 것.
#
# 사용: ./apply.sh <vesc_driver 패키지 경로>
# 예:   ./apply.sh ~/unicorn_ws/src/unicorn-racing-stack/sensor/vesc/vesc_driver
set -e
VD="${1:?사용: apply.sh <vesc_driver 패키지 경로>}"
PATCH="$(cd "$(dirname "$0")" && pwd)/vesc_driver_arbiter_feedback.patch"
cd "$VD"
if git apply --check -p1 "$PATCH" 2>/dev/null; then
  git apply -p1 "$PATCH"; echo "[apply] 패치 적용됨: $VD"
elif git apply --reverse --check -p1 "$PATCH" 2>/dev/null; then
  echo "[apply] 이미 적용돼 있음 — 건너뜀"
else
  echo "[apply] ERROR: 패치가 깨끗이 안 붙음 (vesc_driver 버전 차이?)"; exit 1
fi
echo "[apply] 이제 워크스페이스에서: colcon build --packages-select vesc_driver"
