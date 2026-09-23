# Piper dual-arm Pi 0.5 workspace

ROS 2 Humble workspace for the planned four-arm setup:

- `master_left`
- `master_right`
- `follower_left`
- `follower_right`

This repository contains environment bootstrap files and an S1 SocketCAN
management layer. Robot control code is intentionally not configured at this
stage.

## Supported environment

- Ubuntu 22.04 (jammy)
- ROS 2 Humble
- Python 3.10 virtual environment with access to ROS system packages

## Bootstrap

Install system dependencies (requires sudo):

```bash
cd /home/mips/robot/pi05_humble_ws
./scripts/setup_system_deps.sh
```

Create or update the Python environment:

```bash
./scripts/setup_python_env.sh
```

Activate ROS, the Python environment, and the workspace overlay:

```bash
source scripts/activate_env.sh
```

Run the read-only environment check:

```bash
./scripts/check_environment.sh
```

Build after ROS packages have been added under `src/`:

```bash
source scripts/activate_env.sh
rosdep check --from-paths src --ignore-src --rosdistro humble
colcon build --symlink-install
```

## SDK policy

The official `piper_ros` Humble control nodes currently import `piper_sdk`, so
that SDK is included for compatibility. `pyAgxArm` is also pinned for later
evaluation, but migrating control code to it is a separate project stage.

## CAN safety

The bootstrap and check scripts never bring up a CAN interface, set a bitrate,
or transmit frames. The S1 manager identifies the four USB-CAN adapters by
factory serial number, reuses the official Piper activation script, and never
starts a robot-control process. See [docs/S1_CAN_MANAGEMENT.md](docs/S1_CAN_MANAGEMENT.md)
for the fixed role mapping, read-only diagnostics, start/stop commands, safety
boundary, and rollback procedure.

Create the machine-local mapping before using the manager. The real file is
ignored by Git so hardware identifiers are never committed:

```bash
cp config/piper_can_map.conf.example config/piper_can_map.conf
```

## Four-arm receive-only ROS launch

The `pi05_piper_readonly` package starts one feedback reader per arm. It uses
the official `piper_sdk` parser with `PiperInit` disabled, exposes no command
subscriber or enable service, and publishes namespaced joint feedback plus
standard ROS diagnostics:

```bash
source scripts/activate_env.sh
ros2 launch pi05_piper_readonly four_arm_readonly.launch.py
```

Motion topic forwarding is intentionally absent during S1. See
[docs/S1_CAN_MANAGEMENT.md](docs/S1_CAN_MANAGEMENT.md) for preflight and
diagnostic commands.
