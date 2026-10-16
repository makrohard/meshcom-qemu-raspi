# Stock MeshCom firmware in QEMU

This repository boots the **unmodified MeshCom firmware**
([icssw-org/MeshCom-Firmware](https://github.com/icssw-org/MeshCom-Firmware)) in Espressif's ESP32 QEMU,
headless, without a board. No MeshCom source file is changed: `scripts/apply-overlay.sh` adds a build
variant and the emulated-network code as new files and refuses a tree with a modified tracked file.

## What it shows
- The firmware builds for a classic ESP32 target and boots under `qemu-system-xtensa`.
- The web UI answers on `http://127.0.0.1:18083/`, the net console on `127.0.0.1:12323`.
- MeshCom's own Ethernet mode carries the network: QEMU emulates an OpenCores Ethernet MAC, and the
  variant's stand-ins let the firmware's Ethernet code report it.
- With the external-radio build the firmware connects to a `meshcom-loraham-bridge`, configures its
  radio and sends its frames through it.
- With the `*-gpsd` builds, NMEA written into UART1 reaches MeshCom's GPS parser.
- Settings persist in the node's flash image across rebuilds that keep the partition table (otherwise
  they are reset, with a log line); a firmware reboot is a QEMU exit that `scripts/run.sh` restarts.

## Run it
```bash
scripts/setup.sh                 # the pinned MeshCom commit into .work/ (--ref <sha> for another)
scripts/apply-overlay.sh         # our files into the stock tree
scripts/prepare-openeth.sh       # the OpenETH driver matching the framework's ESP-IDF
scripts/build.sh                 # the qemu-headless firmware and its flash image
scripts/run.sh                   # first start: one provisioning boot, then the node
```
Needs `git`, `curl`, `libslirp0`, PlatformIO and a `qemu-system-xtensa` on `PATH` or passed as
`scripts/run.sh --qemu <path>` (`scripts/build-qemu.sh <dir>` builds the validated
one into `<dir>/qemu/bin/`). Then set the node's callsign on the console: `--setcall <call>`.

## Uses for firmware work
- Boot a branch without hardware: `scripts/setup.sh --src <path or URL> --ref <branch or sha>`.
- Reproduce a report on a given commit, with the console and the web UI on the host.
- A CI smoke test: `tests/test-boot-gates.sh` builds four variants, boots one and checks the
  network, console, web UI, external radio, GPS, MTU, settings, restarts and link loss; most checks
  have a control that must make them fail; h, j and k have none, and k2 covers k's fresh-node failure
  case.

## What it does not do
- No local radio, Wi-Fi, BLE, display, sensors, PMU or battery: QEMU emulates none of them. Radio
  traffic needs the external-radio build and a bridge.
- The spectrum page answers without a scan; mDNS is not tested.
- Emulated timing is not the board's: timing-sensitive behaviour still needs hardware.
- The QEMU build carries one temporary speed patch (`patches/qemu/`), submitted as espressif/qemu#183.

## Validated
```
validated against MeshCom f2b3a3496a76f327abec8b7228bce436cafe9606 on 2026-10-16:
  x86_64 Linux (Fedora 43): tests/test-boot-gates.sh --main --controls --slow, all as expected;
  aarch64 Raspberry Pi 5: tests/test-boot-gates.sh --main, all as expected;
  PlatformIO 6.1.19, Arduino-ESP32 2.0.17 (ESP-IDF 4.4.7), QEMU esp-develop-9.2.2-20260417 + patches/qemu
```
