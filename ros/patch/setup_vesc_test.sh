#!/bin/bash
# 팀 스택은 안 건드리고, RC-failsafe 피드백이 적용된 vesc_driver만 든
# 전용 워크스페이스를 만들어 빌드한다.
#
# 사용:
#   ./setup_vesc_test.sh <team_stack_src_dir> [target_ws]
# 예:
#   ./setup_vesc_test.sh ~/unicorn_ws/src ~/vesc_test
#
# <team_stack_src_dir> 아래에서 vesc_msgs / vesc_driver / transport_drivers 를
# 자동으로 찾아 복사하고, vesc_driver 에 패치를 적용한 뒤 colcon build 한다.
set -e
SRC="${1:?사용: setup_vesc_test.sh <team_stack_src_dir> [target_ws=~/vesc_test]}"
TGT="${2:-$HOME/vesc_test}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/vesc_driver_arbiter_feedback.patch"

find_pkg() { find "$SRC" -type d -name "$1" 2>/dev/null | grep -vE '/(build|install|log)/' | head -1; }
VM=$(find_pkg vesc_msgs); VD=$(find_pkg vesc_driver); TD=$(find_pkg transport_drivers)
for p in "$VM:vesc_msgs" "$VD:vesc_driver" "$TD:transport_drivers"; do
  [ -n "${p%%:*}" ] || { echo "[setup] ${p##*:} 를 $SRC 아래에서 못 찾음"; exit 1; }
done
echo "[setup] vesc_msgs        = $VM"
echo "[setup] vesc_driver      = $VD"
echo "[setup] transport_drivers= $TD"

mkdir -p "$TGT/src" && cd "$TGT/src"
rm -rf vesc_msgs vesc_driver transport_drivers
cp -r "$VM" vesc_msgs
cp -r "$VD" vesc_driver
cp -r "$TD" transport_drivers

( cd vesc_driver && patch -p1 --forward --no-backup-if-mismatch < "$PATCH" )   # 패키지 상대경로 패치
echo "[setup] 패치 적용됨. 빌드 시작..."

cd "$TGT"
source /opt/ros/*/setup.bash 2>/dev/null || true
colcon build

echo ""
echo "[setup] 완료. 실행:"
echo "  source $TGT/install/setup.bash"
echo "  ros2 run vesc_driver vesc_driver_node --ros-args \\"
echo "    --params-file install/vesc_driver/share/vesc_driver/params/vesc_config.yaml \\"
echo "    -p port:=/dev/ttyACM0"
echo "  # 다른 터미널: ros2 topic echo /rc/state   # [mode, servo, steer, throttle, speed_ms]"
