#!/usr/bin/env python3
"""Publish Piper feedback without exposing any command subscriber or service."""

from pathlib import Path
from typing import Dict

from diagnostic_msgs.msg import DiagnosticArray, DiagnosticStatus, KeyValue
from piper_sdk import C_PiperInterface
import rclpy
from rclpy.node import Node
from sensor_msgs.msg import JointState


class PiperReadonlyStateNode(Node):
    """Receive and publish one arm's feedback without transmitting CAN frames."""

    def __init__(self) -> None:
        super().__init__('readonly_state', start_parameter_services=False)
        self.declare_parameter('role', 'unconfigured')
        self.declare_parameter('can_port', 'can0')
        self.declare_parameter('expected_serial', '')
        self.declare_parameter('gripper_exist', True)
        self.declare_parameter('publish_rate_hz', 20.0)
        self.declare_parameter('stale_timeout_sec', 1.0)

        self.role = self.get_parameter('role').value
        self.can_port = self.get_parameter('can_port').value
        self.expected_serial = self.get_parameter('expected_serial').value
        self.gripper_exist = self.get_parameter('gripper_exist').value
        publish_rate_hz = float(self.get_parameter('publish_rate_hz').value)
        self.stale_timeout_sec = float(
            self.get_parameter('stale_timeout_sec').value
        )
        if publish_rate_hz <= 0.0:
            raise ValueError('publish_rate_hz must be positive')
        if self.stale_timeout_sec <= 0.0:
            raise ValueError('stale_timeout_sec must be positive')
        if not self.expected_serial:
            raise ValueError('expected_serial must be configured')

        actual_serial = self._read_usb_serial()
        if actual_serial != self.expected_serial:
            raise RuntimeError(
                f'{self.can_port} USB serial mismatch for {self.role}: '
                f'expected {self.expected_serial}, got {actual_serial or "-"}'
            )
        self.actual_serial = actual_serial

        self.joint_pub = self.create_publisher(JointState, 'joint_states', 10)
        self.diagnostic_pub = self.create_publisher(
            DiagnosticArray, '/diagnostics', 10
        )

        self._last_feedback_stamp = 0.0
        self._last_feedback_monotonic = None
        self._startup_stats = self._read_link_stats()

        # The official control node calls ConnectPort() with its defaults,
        # which runs PiperInit() and transmits query frames.  Passing
        # piper_init=False is the central receive-only safety invariant here.
        self.piper = C_PiperInterface(
            can_name=self.can_port,
            judge_flag=True,
            can_auto_init=True,
        )
        self.piper.ConnectPort(piper_init=False, start_thread=True)

        self.timer = self.create_timer(1.0 / publish_rate_hz, self._on_timer)
        self.get_logger().info(
            f'receive-only state active: role={self.role}, '
            f'can_port={self.can_port}; command subscribers/services=0'
        )

    def _stat_path(self, field: str) -> Path:
        return Path('/sys/class/net') / self.can_port / 'statistics' / field

    def _read_usb_serial(self) -> str:
        device_path = Path('/sys/class/net') / self.can_port / 'device'
        try:
            resolved = device_path.resolve(strict=True)
        except (FileNotFoundError, OSError):
            return ''
        for candidate in (resolved, *resolved.parents):
            serial_path = candidate / 'serial'
            try:
                serial = serial_path.read_text().strip()
            except (FileNotFoundError, OSError):
                continue
            if serial:
                return serial
        return ''

    def _read_link_stats(self) -> Dict[str, int]:
        result = {}
        for field in (
            'rx_packets',
            'tx_packets',
            'rx_errors',
            'tx_errors',
            'rx_dropped',
            'tx_dropped',
        ):
            try:
                result[field] = int(self._stat_path(field).read_text().strip())
            except (FileNotFoundError, OSError, ValueError):
                result[field] = -1
        return result

    def _link_is_up(self) -> bool:
        try:
            flags = int(
                (Path('/sys/class/net') / self.can_port / 'flags')
                .read_text()
                .strip(),
                16,
            )
        except (FileNotFoundError, OSError, ValueError):
            return False
        return bool(flags & 0x1)

    @staticmethod
    def _kv(key: str, value) -> KeyValue:
        return KeyValue(key=key, value=str(value))

    def _publish_joint_state(self, joint, high_speed, gripper) -> None:
        feedback_stamp = float(joint.time_stamp)
        if feedback_stamp <= 0.0:
            return
        if feedback_stamp != self._last_feedback_stamp:
            self._last_feedback_stamp = feedback_stamp
            self._last_feedback_monotonic = self.get_clock().now()

        raw = joint.joint_state
        positions = [
            raw.joint_1,
            raw.joint_2,
            raw.joint_3,
            raw.joint_4,
            raw.joint_5,
            raw.joint_6,
        ]
        motors = [
            high_speed.motor_1,
            high_speed.motor_2,
            high_speed.motor_3,
            high_speed.motor_4,
            high_speed.motor_5,
            high_speed.motor_6,
        ]

        message = JointState()
        message.header.stamp = self.get_clock().now().to_msg()
        message.name = [f'{self.role}_joint{i}' for i in range(1, 7)]
        message.position = [value / 1000.0 * 0.017453292519943295
                            for value in positions]
        message.velocity = [motor.motor_speed / 1000.0 for motor in motors]
        message.effort = [motor.effort / 1000.0 for motor in motors]

        if self.gripper_exist:
            stroke = gripper.gripper_state.grippers_angle / 1000000.0
            effort = gripper.gripper_state.grippers_effort / 1000.0
            message.name.extend([
                f'{self.role}_gripper_base',
                f'{self.role}_gripper_left',
                f'{self.role}_gripper_right',
            ])
            message.position.extend([0.0, stroke / 2.0, -stroke / 2.0])
            message.velocity.extend([0.0, 0.0, 0.0])
            message.effort.extend([0.0, effort / 2.0, -effort / 2.0])

        self.joint_pub.publish(message)

    def _publish_diagnostics(self, arm_status) -> None:
        stats = self._read_link_stats()
        status = DiagnosticStatus()
        status.name = f'pi05/{self.role}/readonly_can'
        status.hardware_id = self.can_port
        status.level = DiagnosticStatus.OK
        status.message = 'receive-only feedback healthy'

        link_up = self._link_is_up()
        if not link_up:
            status.level = DiagnosticStatus.ERROR
            status.message = 'CAN interface is missing or DOWN'

        feedback_age = None
        if self._last_feedback_monotonic is not None:
            elapsed = self.get_clock().now() - self._last_feedback_monotonic
            feedback_age = elapsed.nanoseconds / 1e9
        if link_up and (
            feedback_age is None or feedback_age > self.stale_timeout_sec
        ):
            status.level = max(status.level, DiagnosticStatus.WARN)
            status.message = 'Piper feedback is missing or stale'

        rx_errors = stats['rx_errors']
        tx_errors = stats['tx_errors']
        if rx_errors > 0 or tx_errors > 0:
            status.level = DiagnosticStatus.ERROR
            status.message = 'SocketCAN error counter is nonzero'

        initial_tx = self._startup_stats.get('tx_packets', -1)
        tx_delta = (
            stats['tx_packets'] - initial_tx
            if initial_tx >= 0 and stats['tx_packets'] >= 0
            else -1
        )
        if tx_delta > 0:
            status.level = DiagnosticStatus.ERROR
            status.message = 'host TX detected during read-only session'

        piper_state = arm_status.arm_status
        piper_error = int(getattr(piper_state, 'arm_status', 0))
        if piper_error != 0:
            status.level = DiagnosticStatus.ERROR
            status.message = f'Piper reports arm_status={piper_error}'

        status.values = [
            self._kv('role', self.role),
            self._kv('can_interface', self.can_port),
            self._kv('usb_serial', self.actual_serial),
            self._kv('link', 'UP' if link_up else 'DOWN'),
            self._kv('read_only', True),
            self._kv('command_subscriptions', 0),
            self._kv('command_services', 0),
            self._kv('feedback_age_sec',
                     '-' if feedback_age is None else f'{feedback_age:.3f}'),
            self._kv('can_fps', f'{self.piper.GetCanFps():.1f}'),
            self._kv('rx_packets', stats['rx_packets']),
            self._kv('tx_packets', stats['tx_packets']),
            self._kv('tx_delta_since_start', tx_delta),
            self._kv('rx_errors', rx_errors),
            self._kv('tx_errors', tx_errors),
            self._kv('rx_dropped', stats['rx_dropped']),
            self._kv('tx_dropped', stats['tx_dropped']),
            self._kv('piper_ctrl_mode',
                     getattr(piper_state, 'ctrl_mode', '-')),
            self._kv('piper_arm_status', piper_error),
            self._kv('piper_motion_status',
                     getattr(piper_state, 'motion_status', '-')),
        ]

        message = DiagnosticArray()
        message.header.stamp = self.get_clock().now().to_msg()
        message.status = [status]
        self.diagnostic_pub.publish(message)

    def _on_timer(self) -> None:
        joint = self.piper.GetArmJointMsgs()
        high_speed = self.piper.GetArmHighSpdInfoMsgs()
        gripper = self.piper.GetArmGripperMsgs()
        arm_status = self.piper.GetArmStatus()
        self._publish_joint_state(joint, high_speed, gripper)
        self._publish_diagnostics(arm_status)

    def destroy_node(self):
        if hasattr(self, 'piper'):
            self.piper.DisconnectPort()
        return super().destroy_node()


def main(args=None) -> None:
    """Run the receive-only state node."""
    rclpy.init(args=args)
    node = None
    try:
        node = PiperReadonlyStateNode()
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        if node is not None:
            node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
