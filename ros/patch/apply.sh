#!/bin/bash
# 기존 vesc_driver 패키지에 RC-failsafe 피드백 패치를 in-place 적용한다 (이 차만).
# 자율주행 launch 가 띄우는 바로 그 vesc_driver 에 적용해야 통합 실행된다.
# git 커밋을 안 하므로 팀 공유 레포(원격)는 그대로 — 이 차의 로컬 working copy 만 바뀐다.
#
# 사용: ./apply.sh <vesc_driver 패키지 경로>
# 예:   ./apply.sh ~/unicorn_ws/src/unicorn-racing-stack/sensor/vesc/vesc_driver
set -e
VD="${1:?사용: apply.sh <vesc_driver 패키지 경로>}"
PATCH="$(cd "$(dirname "$0")" && pwd)/vesc_driver_arbiter_feedback.patch"
cd "$VD"
# git apply 는 git repo 안에서 repo-root 기준이라 안 맞음 -> cwd 기준인 patch 사용
if patch -p1 --dry-run --forward < "$PATCH" >/dev/null 2>&1; then
  patch -p1 --forward --no-backup-if-mismatch < "$PATCH"
  echo "[apply] 패치 적용됨: $VD"
elif patch -p1 --dry-run --reverse < "$PATCH" >/dev/null 2>&1; then
  echo "[apply] 이미 적용돼 있음 — 건너뜀"
else
  echo "[apply] ERROR: 패치가 깨끗이 안 붙음 (vesc_driver 버전 차이?)"; exit 1
fi
echo "[apply] 이제 워크스페이스 루트에서: colcon build --packages-select vesc_driver"
