#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
workspace_dir="$(cd -- "${script_dir}/.." && pwd)"
map_file="${PIPER_CAN_MAP_FILE:-${workspace_dir}/config/piper_can_map.conf}"
link_dir="/etc/systemd/network"

declare -a roles=() interfaces=() serials=() bitrates=()

usage() {
  cat <<'EOF'
Usage: scripts/piper_can.sh COMMAND

Read-only commands:
  scan             List detected CAN adapters, USB identity and mapped role
  status           Show role/interface, UP/DOWN, bitrate, RX/TX and errors
  diagnose         Show status followed by detailed SocketCAN statistics

Administrative commands (run with sudo):
  start            Map all four adapters, configure 1 Mbps and bring CAN up
  stop             Bring the four mapped CAN interfaces down
  install-mapping  Install persistent serial-number based systemd .link files
  remove-mapping   Remove only the four persistent mapping files

These commands configure SocketCAN only.  They do not run a Piper/ROS node and
do not construct or transmit any motor-control CAN frame.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

load_map() {
  [[ -r "${map_file}" ]] || die "mapping file is not readable: ${map_file}"

  local role iface serial bitrate extra
  while read -r role iface serial bitrate extra; do
    [[ -z "${role:-}" || "${role}" == \#* ]] && continue
    [[ -z "${extra:-}" ]] || die "invalid extra field in mapping row for ${role}"
    roles+=("${role}")
    interfaces+=("${iface}")
    serials+=("${serial}")
    bitrates+=("${bitrate}")
  done < "${map_file}"

  [[ ${#roles[@]} -eq 4 ]] || die "mapping must contain exactly four Piper roles"

  local expected=(master_left master_right follower_left follower_right)
  local i j found
  for role in "${expected[@]}"; do
    found=0
    for i in "${!roles[@]}"; do
      [[ "${roles[$i]}" == "${role}" ]] && found=$((found + 1))
    done
    [[ ${found} -eq 1 ]] || die "mapping must contain role ${role} exactly once"
  done

  for i in "${!roles[@]}"; do
    [[ "${interfaces[$i]}" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "invalid interface name: ${interfaces[$i]}"
    [[ ${#interfaces[$i]} -le 15 ]] || die "interface name exceeds Linux's 15-character limit: ${interfaces[$i]}"
    [[ "${serials[$i]}" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "invalid USB serial for ${roles[$i]}"
    [[ "${bitrates[$i]}" == "1000000" ]] || die "${roles[$i]} must use Piper's official 1000000 bitrate"
    for ((j = i + 1; j < ${#roles[@]}; j++)); do
      [[ "${interfaces[$i]}" != "${interfaces[$j]}" ]] || die "duplicate interface name: ${interfaces[$i]}"
      [[ "${serials[$i]}" != "${serials[$j]}" ]] || die "duplicate USB serial: ${serials[$i]}"
    done
  done
}

can_interfaces() {
  ip -brief link show type can 2>/dev/null | awk '{print $1}'
}

serial_for_interface() {
  udevadm info --query=property --path="/sys/class/net/$1" 2>/dev/null |
    sed -n 's/^ID_SERIAL_SHORT=//p' | head -n 1
}

bus_for_interface() {
  ethtool -i "$1" 2>/dev/null | awk '$1 == "bus-info:" {print $2; exit}'
}

interface_for_serial() {
  local wanted="$1" iface actual
  while read -r iface; do
    [[ -n "${iface}" ]] || continue
    actual="$(serial_for_interface "${iface}")"
    if [[ "${actual}" == "${wanted}" ]]; then
      printf '%s\n' "${iface}"
      return 0
    fi
  done < <(can_interfaces)
  return 1
}

role_for_serial() {
  local wanted="$1" i
  for i in "${!roles[@]}"; do
    if [[ "${serials[$i]}" == "${wanted}" ]]; then
      printf '%s\n' "${roles[$i]}"
      return 0
    fi
  done
  printf '%s\n' UNMAPPED
}

serial_is_managed() {
  local wanted="$1" configured
  for configured in "${serials[@]}"; do
    [[ "${configured}" == "${wanted}" ]] && return 0
  done
  return 1
}

find_official_activate() {
  if [[ -n "${PIPER_CAN_ACTIVATE_SH:-}" ]]; then
    [[ -r "${PIPER_CAN_ACTIVATE_SH}" ]] || die "PIPER_CAN_ACTIVATE_SH is not readable"
    printf '%s\n' "${PIPER_CAN_ACTIVATE_SH}"
    return
  fi

  local found
  found="$(find "${workspace_dir}/.venv/lib" -path '*/site-packages/piper_sdk/can_activate.sh' -print -quit 2>/dev/null || true)"
  [[ -n "${found}" ]] || die "official piper_sdk can_activate.sh not found; run scripts/setup_python_env.sh"
  printf '%s\n' "${found}"
}

require_read_tools() {
  require_command ip
  require_command ethtool
  require_command udevadm
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "this command changes network state; run it with sudo"
}

scan() {
  printf '%-8s %-14s %-24s %-18s %s\n' INTERFACE BUS-INFO USB-SERIAL ROLE DRIVER
  local iface bus serial role driver
  while read -r iface; do
    [[ -n "${iface}" ]] || continue
    bus="$(bus_for_interface "${iface}")"
    serial="$(serial_for_interface "${iface}")"
    role="$(role_for_serial "${serial}")"
    driver="$(ethtool -i "${iface}" 2>/dev/null | awk '$1 == "driver:" {print $2; exit}')"
    printf '%-8s %-14s %-24s %-18s %s\n' \
      "${iface}" "${bus:--}" "${serial:--}" "${role}" "${driver:--}"
  done < <(can_interfaces)
}

read_stat() {
  local iface="$1"
  local field="$2"
  local path="/sys/class/net/${iface}/statistics/${field}"
  [[ -r "${path}" ]] && cat "${path}" || printf '%s\n' '-'
}

status() {
  printf '%-16s %-8s %-7s %-9s %10s %10s %8s %8s %-12s\n' \
    ROLE IFACE LINK BITRATE RX-PKTS TX-PKTS RX-ERR TX-ERR CAN-STATE

  local i iface flags link details bitrate can_state
  local rx_packets tx_packets rx_errors tx_errors failures=0
  for i in "${!roles[@]}"; do
    iface="$(interface_for_serial "${serials[$i]}" || true)"
    if [[ -z "${iface}" ]]; then
      printf '%-16s %-8s %-7s %-9s %10s %10s %8s %8s %-12s\n' \
        "${roles[$i]}" MISSING DOWN - - - - - MISSING
      failures=$((failures + 1))
      continue
    fi

    flags="$(ip -o link show dev "${iface}" | sed -n 's/^[^<]*<\([^>]*\)>.*/\1/p')"
    if [[ ",${flags}," == *,UP,* ]]; then link=UP; else link=DOWN; fi
    details="$(ip -details link show dev "${iface}")"
    bitrate="$(sed -n 's/.*bitrate \([0-9][0-9]*\).*/\1/p' <<<"${details}" | head -n 1)"
    can_state="$(awk '/can state/ {print $3; exit}' <<<"${details}")"
    rx_packets="$(read_stat "${iface}" rx_packets)"
    tx_packets="$(read_stat "${iface}" tx_packets)"
    rx_errors="$(read_stat "${iface}" rx_errors)"
    tx_errors="$(read_stat "${iface}" tx_errors)"
    printf '%-16s %-8s %-7s %-9s %10s %10s %8s %8s %-12s\n' \
      "${roles[$i]}" "${iface}" "${link}" "${bitrate:--}" \
      "${rx_packets}" "${tx_packets}" "${rx_errors}" "${tx_errors}" "${can_state:--}"

    [[ "${iface}" == "${interfaces[$i]}" ]] || failures=$((failures + 1))
    [[ "${link}" == UP ]] || failures=$((failures + 1))
    [[ "${bitrate:-}" == "${bitrates[$i]}" ]] || failures=$((failures + 1))
    [[ "${rx_errors}" == 0 && "${tx_errors}" == 0 ]] || failures=$((failures + 1))
  done

  return "${failures}"
}

diagnose() {
  local result=0 iface
  status || result=$?
  echo
  echo "Detailed SocketCAN state and counters:"
  while read -r iface; do
    [[ -n "${iface}" ]] || continue
    echo "----- ${iface} -----"
    ip -details -statistics link show dev "${iface}"
  done < <(can_interfaces)
  return "${result}"
}

start_can() {
  require_root
  require_command modprobe
  local official_activate
  official_activate="$(find_official_activate)"
  modprobe gs_usb

  local -a current=() buses=() temporary=()
  local i iface bus other tmp
  for i in "${!roles[@]}"; do
    iface="$(interface_for_serial "${serials[$i]}" || true)"
    [[ -n "${iface}" ]] || die "adapter missing for ${roles[$i]} (${serials[$i]})"
    bus="$(bus_for_interface "${iface}")"
    [[ -n "${bus}" ]] || die "cannot read bus-info for ${roles[$i]} on ${iface}"
    current+=("${iface}")
    buses+=("${bus}")
    tmp="pc_s1_${i}"
    ip link show dev "${tmp}" >/dev/null 2>&1 && die "temporary interface name already exists: ${tmp}"
    temporary+=("${tmp}")
  done

  # Refuse to overwrite a target name owned by an unrelated network device.
  for i in "${!roles[@]}"; do
    if ip link show dev "${interfaces[$i]}" >/dev/null 2>&1; then
      other="$(serial_for_interface "${interfaces[$i]}")"
      serial_is_managed "${other}" || die "target ${interfaces[$i]} is occupied by an unmanaged device"
    fi
  done

  # Neutral temporary names avoid rename collisions when logical names already
  # exist but adapters were deliberately reassigned in the mapping file.
  for i in "${!roles[@]}"; do
    ip link set dev "${current[$i]}" down
    ip link set dev "${current[$i]}" name "${temporary[$i]}"
  done

  for i in "${!roles[@]}"; do
    echo "Activating ${roles[$i]} as ${interfaces[$i]} via official can_activate.sh"
    bash "${official_activate}" "${interfaces[$i]}" "${bitrates[$i]}" "${buses[$i]}"
  done

  echo "All four SocketCAN interfaces are configured. No Piper/ROS control node was started."
  status
}

stop_can() {
  require_root
  local i iface missing=0
  for i in "${!roles[@]}"; do
    iface="$(interface_for_serial "${serials[$i]}" || true)"
    if [[ -z "${iface}" ]]; then
      echo "WARN: adapter missing for ${roles[$i]}" >&2
      missing=1
      continue
    fi
    ip link set dev "${iface}" down
    echo "Stopped ${roles[$i]} (${iface})"
  done
  return "${missing}"
}

install_mapping() {
  require_root
  require_command install
  mkdir -p "${link_dir}"

  local i destination temporary_file
  for i in "${!roles[@]}"; do
    destination="${link_dir}/20-piper-can-${roles[$i]}.link"
    temporary_file="$(mktemp)"
    cat > "${temporary_file}" <<EOF
[Match]
Property=ID_SERIAL_SHORT=${serials[$i]}
Driver=gs_usb
Type=can

[Link]
Name=${interfaces[$i]}
EOF
    install -m 0644 "${temporary_file}" "${destination}"
    rm -f -- "${temporary_file}"
    echo "Installed ${destination}"
  done
  udevadm control --reload
  echo "Persistent names apply after reconnecting the USB-CAN adapters or rebooting."
}

remove_mapping() {
  require_root
  local role destination
  for role in master_left master_right follower_left follower_right; do
    destination="${link_dir}/20-piper-can-${role}.link"
    if [[ -e "${destination}" ]]; then
      rm -f -- "${destination}"
      echo "Removed ${destination}"
    fi
  done
  udevadm control --reload
  echo "Removal applies after reconnecting the USB-CAN adapters or rebooting."
}

main() {
  [[ $# -eq 1 ]] || { usage; exit 2; }

  case "$1" in
    scan)
      require_read_tools
      load_map
      scan
      ;;
    status)
      require_read_tools
      load_map
      status
      ;;
    diagnose)
      require_read_tools
      load_map
      diagnose
      ;;
    start)
      require_read_tools
      load_map
      start_can
      ;;
    stop)
      require_read_tools
      load_map
      stop_can
      ;;
    install-mapping)
      require_command udevadm
      load_map
      install_mapping
      ;;
    remove-mapping)
      require_command udevadm
      remove_mapping
      ;;
    -h|--help|help) usage ;;
    *) usage; die "unknown command: $1" ;;
  esac
}

main "$@"
