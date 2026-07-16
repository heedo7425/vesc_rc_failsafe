#!/usr/bin/env python3
"""auto 모드 검증용 테스트 발행자 (자율주행 스택 흉내).
vesc_driver가 구독하는 토픽으로 연속 발행:
  /vesc/commands/motor/speed    = ERPM (기본 1875 = 1 m/s, speed_to_erpm_gain=1875)
  /vesc/commands/servo/position = 0.3 <-> 0.7  (1초마다 좌우)
50 Hz. → vesc_driver가 SET_RPM/SET_SERVO_POS로 VESC에 보냄 → arbiter가 auto에서 통과.

사용: python3 auto_test_pub.py         (기본 1m/s)
      python3 auto_test_pub.py 3000    (3000 ERPM 지정)
"""
import sys
import rclpy
from rclpy.node import Node
from std_msgs.msg import Float64


class AutoTestPub(Node):
    def __init__(self, erpm):
        super().__init__('auto_test_pub')
        # publish to both namespaced and plain topics (vesc_driver may run under
        # /vesc via launch, or bare via `ros2 run`)
        self.speed_pubs = [
            self.create_publisher(Float64, '/vesc/commands/motor/speed', 10),
            self.create_publisher(Float64, '/commands/motor/speed', 10)]
        self.servo_pubs = [
            self.create_publisher(Float64, '/vesc/commands/servo/position', 10),
            self.create_publisher(Float64, '/commands/servo/position', 10)]
        self.erpm = float(erpm)
        self.t = 0.0
        self.dt = 0.02  # 50 Hz
        self.create_timer(self.dt, self.tick)
        self.get_logger().info(
            f'auto_test_pub: speed={self.erpm} ERPM, servo 0.3<->0.7 @1s, 50Hz')

    def tick(self):
        s = Float64(); s.data = self.erpm
        for p in self.speed_pubs:
            p.publish(s)
        self.t += self.dt
        left = (int(self.t) % 2 == 0)
        v = Float64(); v.data = 0.3 if left else 0.7
        for p in self.servo_pubs:
            p.publish(v)


def main():
    erpm = float(sys.argv[1]) if len(sys.argv) > 1 else 1875.0
    rclpy.init()
    node = AutoTestPub(erpm)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        # 종료 시 정지 명령 (컴퓨터 "죽음" 시뮬레이션은 그냥 Ctrl-C)
        pass
    finally:
        rclpy.shutdown()


if __name__ == '__main__':
    main()
