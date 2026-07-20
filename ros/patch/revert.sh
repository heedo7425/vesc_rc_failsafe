#!/bin/bash
# apply.sh 로 in-place 적용한 vesc_driver 를 순정으로 원복한다.
# 사용: ./revert.sh <vesc_driver 패키지 경로>
set -e
VD="${1:?사용: revert.sh <vesc_driver 패키지 경로>}"
PATCH="$(cd "$(dirname "$0")" && pwd)/vesc_driver_arbiter_feedback.patch"
cd "$VD"
if patch -p1 --dry-run --reverse < "$PATCH" >/dev/null 2>&1; then
  patch -p1 --reverse --no-backup-if-mismatch < "$PATCH"
  echo "[revert] 순정 복원: $VD"
else
  echo "[revert] 적용 안 돼 있음 (이미 순정?)"
fi
echo "[revert] 이제 워크스페이스 루트에서: colcon build --packages-select vesc_driver"
