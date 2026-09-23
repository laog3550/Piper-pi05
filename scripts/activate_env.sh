#!/usr/bin/env bash

# Source this file from the workspace root or any other directory:
#   source scripts/activate_env.sh

_piper_script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_piper_ws_dir="$(cd -- "${_piper_script_dir}/.." && pwd)"

if [[ ! -f /opt/ros/humble/setup.bash ]]; then
  echo "ROS 2 Humble was not found at /opt/ros/humble." >&2
  return 1 2>/dev/null || exit 1
fi

if [[ ! -f "${_piper_ws_dir}/.venv/bin/activate" ]]; then
  echo "Virtual environment not found. Run scripts/setup_python_env.sh first." >&2
  return 1 2>/dev/null || exit 1
fi

_piper_restore_nounset=0
if [[ $- == *u* ]]; then
  _piper_restore_nounset=1
  set +u
fi
source /opt/ros/humble/setup.bash
source "${_piper_ws_dir}/.venv/bin/activate"

# ROS 2 console scripts are generated with the system Python interpreter.
# Make workspace-venv packages (notably piper_sdk) visible to those scripts
# while retaining ROS packages from the system installation.
_piper_venv_site="$("${_piper_ws_dir}/.venv/bin/python" -c \
  'import site; print(site.getsitepackages()[0])')"
export PYTHONPATH="${_piper_venv_site}${PYTHONPATH:+:${PYTHONPATH}}"

if [[ -f "${_piper_ws_dir}/install/local_setup.bash" ]]; then
  source "${_piper_ws_dir}/install/local_setup.bash"
fi

if [[ ${_piper_restore_nounset} -eq 1 ]]; then
  set -u
fi

export PIPER_WS="${_piper_ws_dir}"
echo "Piper workspace environment active: ${PIPER_WS}"

unset _piper_script_dir _piper_ws_dir _piper_restore_nounset _piper_venv_site
