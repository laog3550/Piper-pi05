#!/usr/bin/env bash
set -eo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="$(cd -- "${script_dir}/.." && pwd)"
venv_dir="${workspace_dir}/.venv"

if [[ ! -f /opt/ros/humble/setup.bash ]]; then
  echo "ROS 2 Humble was not found at /opt/ros/humble." >&2
  exit 1
fi

source /opt/ros/humble/setup.bash
set -u

if [[ ! -d "${venv_dir}" ]]; then
  python3 -m venv --system-site-packages "${venv_dir}"
fi

source "${venv_dir}/bin/activate"
python -m pip install --upgrade pip
python -m pip install -r "${workspace_dir}/requirements.txt"
python -m pip check

echo "Python environment is ready."
echo "Activate it with: source ${workspace_dir}/scripts/activate_env.sh"
