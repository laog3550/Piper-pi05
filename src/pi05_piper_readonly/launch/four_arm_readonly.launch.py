"""Launch receive-only feedback nodes for all four Piper arms."""

from pathlib import Path

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, LogInfo, OpaqueFunction
from launch.substitutions import (
    EnvironmentVariable,
    LaunchConfiguration,
    PathJoinSubstitution,
)
from launch_ros.actions import Node


EXPECTED_ROLES = {
    'master_left',
    'master_right',
    'follower_left',
    'follower_right',
}


def _load_mapping(path: Path):
    mapping = {}
    for line_number, line in enumerate(path.read_text().splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        fields = stripped.split()
        if len(fields) != 4:
            raise RuntimeError(
                f'invalid CAN mapping at {path}:{line_number}'
            )
        role, interface, serial, bitrate = fields
        if role not in EXPECTED_ROLES:
            raise RuntimeError(f'unknown Piper role in CAN mapping: {role}')
        if role in mapping:
            raise RuntimeError(f'duplicate Piper role in CAN mapping: {role}')
        if bitrate != '1000000':
            raise RuntimeError(f'{role} must use bitrate 1000000')
        mapping[role] = (interface, serial)
    if set(mapping) != EXPECTED_ROLES:
        missing = ', '.join(sorted(EXPECTED_ROLES - set(mapping)))
        raise RuntimeError(f'CAN mapping is missing roles: {missing}')
    return mapping


def _create_readers(context):
    mapping_path = Path(LaunchConfiguration('mapping_file').perform(context))
    if not mapping_path.is_file():
        raise RuntimeError(
            f'CAN mapping not found: {mapping_path}; copy the example first'
        )
    mapping = _load_mapping(mapping_path)
    actions = []
    for role in sorted(EXPECTED_ROLES):
        interface, expected_serial = mapping[role]
        actions.append(Node(
            package='pi05_piper_readonly',
            executable='readonly_state_node',
            namespace=role,
            name='readonly_state',
            output='screen',
            emulate_tty=True,
            parameters=[{
                'role': role,
                'can_port': interface,
                'expected_serial': expected_serial,
                'gripper_exist': True,
                'publish_rate_hz': 20.0,
                'stale_timeout_sec': 1.0,
            }],
        ))
    return actions


def generate_launch_description() -> LaunchDescription:
    """Create four isolated state readers with no command paths."""
    actions = [
        DeclareLaunchArgument(
            'mapping_file',
            default_value=PathJoinSubstitution([
                EnvironmentVariable('PIPER_WS'),
                'config',
                'piper_can_map.conf',
            ]),
            description='Local, Git-ignored four-arm CAN mapping',
        ),
        LogInfo(msg=(
            'Pi05 receive-only mode: motion topic forwarding is disabled; '
            'no command subscribers or enable services are created.'
        )),
        OpaqueFunction(function=_create_readers),
    ]

    return LaunchDescription(actions)
