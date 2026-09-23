#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify the operating system." >&2
  exit 1
fi

source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_CODENAME:-}" != "jammy" ]]; then
  echo "This script supports Ubuntu 22.04 (jammy) only." >&2
  exit 1
fi

if [[ ! -f /opt/ros/humble/setup.bash ]]; then
  echo "ROS 2 Humble must be installed before running this script." >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y \
  build-essential \
  cmake \
  git \
  python3-colcon-common-extensions \
  python3-rosdep \
  python3-venv \
  can-utils \
  ethtool \
  ros-humble-control-msgs \
  ros-humble-controller-manager \
  ros-humble-joint-state-publisher \
  ros-humble-joint-state-publisher-gui \
  ros-humble-moveit \
  ros-humble-robot-state-publisher \
  ros-humble-ros2-control \
  ros-humble-ros2-controllers \
  ros-humble-rviz2 \
  ros-humble-warehouse-ros-mongo \
  ros-humble-xacro

echo "System dependencies are installed."
echo "No CAN interface was configured or activated."
