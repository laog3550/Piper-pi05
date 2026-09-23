#!/usr/bin/env bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="$(cd -- "${script_dir}/.." && pwd)"
errors=0

pass() { printf '[OK]      %s\n' "$1"; }
fail() { printf '[MISSING] %s\n' "$1"; errors=$((errors + 1)); }

if [[ -f /opt/ros/humble/setup.bash ]]; then
  source /opt/ros/humble/setup.bash
  pass "ROS 2 Humble"
else
  fail "ROS 2 Humble"
fi

set -u

if [[ -f "${workspace_dir}/.venv/bin/activate" ]]; then
  source "${workspace_dir}/.venv/bin/activate"
  pass "workspace virtual environment"
else
  fail "workspace virtual environment"
fi

for command_name in ros2 colcon rosdep ip candump; do
  if command -v "${command_name}" >/dev/null 2>&1; then
    pass "command: ${command_name}"
  else
    fail "command: ${command_name}"
  fi
done

python - <<'PY'
from importlib.util import find_spec

modules = ("rclpy", "can", "scipy", "piper_sdk", "pyAgxArm", "cffi")
missing = [module for module in modules if find_spec(module) is None]
for module in modules:
    print(f"[{'OK' if module not in missing else 'MISSING'}]      Python module: {module}")
raise SystemExit(bool(missing))
PY
if [[ $? -ne 0 ]]; then
  errors=$((errors + 1))
fi

for package_name in \
  rclpy \
  ament_cmake \
  control_msgs \
  controller_manager \
  moveit_configs_utils \
  moveit_ros_move_group \
  robot_state_publisher \
  rviz2 \
  tf2_ros \
  xacro; do
  if ros2 pkg prefix "${package_name}" >/dev/null 2>&1; then
    pass "ROS package: ${package_name}"
  else
    fail "ROS package: ${package_name}"
  fi
done

echo
echo "CAN inventory (read-only; interfaces are not activated):"
ip -brief link show type can 2>/dev/null || true

echo
if [[ ${errors} -eq 0 ]]; then
  echo "Environment check passed."
else
  echo "Environment check found ${errors} missing requirement group(s)." >&2
fi
exit "${errors}"
