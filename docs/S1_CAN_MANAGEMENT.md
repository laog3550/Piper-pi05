# S1: four-Piper CAN management

This stage manages SocketCAN interfaces only.  It does not start a Piper SDK or
ROS control node, enable a motor, or construct a CAN motion frame.

## Design

The official Piper scripts were reviewed from the installed `piper_sdk 0.6.2`:

- `find_all_can_port.sh` enumerates SocketCAN interfaces and reports the
  `ethtool -i` `bus-info` value.
- `can_activate.sh` resolves one adapter from that `bus-info`, sets its bitrate,
  brings it up, and renames it.  Its current official default is 1,000,000
  bit/s.
- `can_config.sh` and `can_muti_activate.sh` store a physical USB-port-to-name
  table and perform the same `ip link` operations for multiple adapters.  The
  shipped files are templates: `can_config.sh` defaults to one adapter, while
  the current `can_muti_activate.sh` example contains duplicate target names
  and must not be used unchanged for four arms.

The project keeps the official activation path, but fixes identity at a more
stable layer.  Each of the four installed candleLight/`gs_usb` adapters exposes
a unique `ID_SERIAL_SHORT`.  `scripts/piper_can.sh` resolves that serial to the
adapter's current interface and current `bus-info`, then calls the official
`can_activate.sh` with a 1,000,000 bit/s bitrate.  USB enumeration order and the
temporary `can0` through `can3` names are therefore irrelevant.

Linux interface names are limited to 15 characters, so the logical names are:

| Piper role | Interface | Bitrate |
| --- | --- | ---: |
| `master_left` | `can_ml` | 1,000,000 |
| `master_right` | `can_mr` | 1,000,000 |
| `follower_left` | `can_fl` | 1,000,000 |
| `follower_right` | `can_fr` | 1,000,000 |

Adapter serial numbers and observed USB ports are machine-specific and must not
be committed. Copy `config/piper_can_map.conf.example` to the Git-ignored
`config/piper_can_map.conf`, then fill in the physically verified serial for
each role. Moving an adapter to another USB socket does not change its role.

Keep each adapter labelled with its role and serial number. If a pair changes
later, update only the serial-to-role row in
`config/piper_can_map.conf` while all interfaces are down, reinstall the
persistent mapping, and reconnect the USB adapters.

## Commands

Read-only inventory and diagnosis:

```bash
cd /home/mips/robot/pi05_humble_ws
./scripts/piper_can.sh scan
./scripts/piper_can.sh status
./scripts/piper_can.sh diagnose
```

Install boot/replug-stable names, then reconnect the adapters or reboot:

```bash
sudo ./scripts/piper_can.sh install-mapping
```

Configure all four interfaces with the official Piper activation script:

```bash
sudo ./scripts/piper_can.sh start
```

Stop host-side SocketCAN interfaces:

```bash
sudo ./scripts/piper_can.sh stop
```

`start` only brings SocketCAN up.  Do not launch a Piper/ROS control node during
S1.  Although no host motion command is sent, an attached arm may publish its
normal CAN status traffic once the bus is up.

## Four-arm receive-only ROS launch

The official `piper_ctrl_single_node` is intentionally not used: it creates
motion subscribers and an enable service.  The official
`piper_read_slave_joint` is also not launched unchanged because its default
`ConnectPort()` call runs `PiperInit()` and transmits query frames.

`pi05_piper_readonly` reuses the official `piper_sdk` receive/parser path while
calling `ConnectPort(piper_init=False)`.  It creates no ROS subscriber, no ROS
service, and no CAN send call.  Each arm publishes only:

- `/<role>/joint_states`
- `/diagnostics` with interface, freshness, RX/TX/error counters and Piper
  status

Before opening SocketCAN, every node verifies that its interface exposes the
USB serial assigned to that role.  A stale or swapped system `.link` mapping
therefore makes the node fail closed instead of publishing another arm's state
under the wrong namespace.

Preflight, including a zero-TX baseline:

```bash
cd /home/mips/robot/pi05_humble_ws
sudo ./scripts/piper_can.sh start
./scripts/piper_can.sh status
```

Launch all four read-only readers:

```bash
source scripts/activate_env.sh
ros2 launch pi05_piper_readonly four_arm_readonly.launch.py
```

Check state and diagnostics:

```bash
ros2 topic list | sort
ros2 topic hz /master_left/joint_states
ros2 topic echo /diagnostics
./scripts/piper_can.sh diagnose
```

There must be no `pos_cmd`, `joint_ctrl_cmd`, `enable_cmd`, `enable_flag`, or
`enable_srv` endpoint in this launch.  The diagnostics raise an error if host
TX increases after a reader starts, even if another process caused the TX.

## Rollback

First bring all mapped host interfaces down, then remove the persistent naming
files:

```bash
sudo ./scripts/piper_can.sh stop
sudo ./scripts/piper_can.sh remove-mapping
```

Reconnect the adapters or reboot.  Linux will return to its ordinary dynamic
`can0`, `can1`, ... enumeration.  Removing mapping files does not uninstall or
replace the kernel `gs_usb` driver or any official Piper package.
