# MeshCom Firmware on QEMU (classic ESP32, headless)

Runs the **stock MeshCom firmware** ([icssw-org/MeshCom-Firmware](https://github.com/icssw-org/MeshCom-Firmware))
headless in Espressif's ESP32 QEMU, with emulated Ethernet, so the MeshCom web UI (`http://127.0.0.1:18083/`)
and net console (`127.0.0.1:12323`) are reachable from the host. With the external-radio profile the firmware
talks to a `meshcom-loraham-bridge`, and through it to a real radio. Used by LoRaHAM Pi Control; usable by
firmware developers to boot MeshCom without hardware.

## Run
Prerequisites: `git curl libslirp0`, PlatformIO (`pipx install platformio`), and a `qemu-system-xtensa`
(`scripts/build-qemu.sh <dir> --link-gate <script>` builds the verified one; any on `PATH` is used otherwise).
```bash
scripts/setup.sh && scripts/apply-overlay.sh && scripts/prepare-openeth.sh && scripts/build.sh && scripts/run.sh
```
`run.sh` runs in the foreground; a first start provisions the node (below). `scripts/stop.sh` stops it,
`scripts/status.sh` shows its state, `scripts/clean.sh` removes `.work/` and `.run/`.

## House rules
- **Pinned by commit.** `scripts/setup.sh` checks out `DEFAULT_REF`, a MeshCom commit; a tag is a label
  only (upstream moves tags: `v4.40a.hbserver` moved on 2026-10-13). `--ref <sha|branch|tag>` and
  `--src <path|URL>` select another revision or repository.
- **Our files only.** No MeshCom file is changed. `apply-overlay.sh` copies `overlay/variants/qemu-headless/`
  and `overlay/src/qemu/` into the stock tree and refuses (rc 4) a tree with a modified tracked file.
- **The QEMU speed patch is temporary.** `patches/qemu/` is submitted as espressif/qemu#183 and goes once an
  Espressif release tag contains it (`patches/qemu/README.md`; issue #1 here tracks it).
- **No secrets in the tree.** The bridge password comes from `XR_PASSWORD` at build time.

## How the stock firmware runs under QEMU
- **Network:** QEMU emulates the OpenCores Ethernet MAC. A strong `initVariant()` (`src/qemu/qemu_ethmode.cpp`)
  starts it before `setup()` and reports its address to MeshCom's Ethernet mode (`HAS_ETHERNET`,
  `node_netmode` 1). `ETHClass2.h`/`EthernetUdp.h` in the variant stand in for the W5500 libraries that
  mode calls, so its code reports the emulated network. Readiness is withdrawn when the link or the address
  goes away, and returns with them.
- **No hardware:** with the external radio the firmware does not begin a local radio; without it
  `radio.begin()` finds no chip and the boot continues. The display probe finds nothing; BLE and the battery
  are off (`DISABLE_BLE`, `DISABLE_BATTERY`).
- **Reboots:** QEMU runs with `-no-reboot`, so a guest reset ends QEMU (inside qemu-xtensa a reset wedges in
  the ROM), and `run.sh` starts it again: `[run] guest reset after <s> s -> restart #<n>`, also counted in
  `.run/restarts`. Settings that make MeshCom reboot itself (`--setcall`, `--netmode`, …) therefore cost one
  restart. Exit codes: 0 stopped · 1 setup error · 2 usage · 3 provisioning failed · 5 QEMU error ·
  75 restart limit (3 runs shorter than 60 s in a row, or more than 10 restarts within an hour).
- **Provisioning:** on a node image without a matching `<image>.provisioned` marker, `run.sh` first boots once
  and sends MeshCom's own console commands over UART0: placeholder Wi-Fi credentials (stock code turns the
  web server off without them; Ethernet mode never uses them), `--webserver on`, `--netconsole on`,
  `--mesh off`, `--gateway off`, `--extudp off`, `--gps on` (`*-gpsd`), `--wifiap off`, `--netmode eth`.
  The marker is written only after the next boot's `--info` shows Ethernet mode with mesh, extudp and gateway
  off and the web page answers; otherwise exit 3. Then set the node's callsign: `--setcall <call>` on the
  console (LoRaHAM Pi Control sends it after each start). Until a callsign is set, MeshCom forces its AP flag
  on and refuses to transmit.
- **The node image** (`.state/node-flash.bin`, or `--node-image`) keeps the settings across rebuilds
  (`scripts/node-image.sh`); `<image>.efuse` gives the node its MAC and so its MeshCom node ID.

## Profiles
| env | adds |
|---|---|
| `qemu-headless` | web UI and console over the emulated Ethernet |
| `qemu-headless-extradio` | the external radio: `XR_HOST=10.0.2.2 XR_PORT=<port> XR_PASSWORD=<secret> scripts/build.sh --env qemu-headless-extradio`; an empty password still builds password authentication |
| `qemu-headless-gpsd`, `qemu-headless-extradio-gpsd` | UART1 on `.run/gps-uart1.sock`, fed by `scripts/gps-relay.py` (`--mode fixture` from `fixtures/gps/`, or `--mode gpsd`, [docs/gpsd-host-setup.md](docs/gpsd-host-setup.md)); start the relay before the node |

Pass the same `--env` to `build.sh` and `run.sh`. `10.0.2.2` is QEMU's address for the host; a bridge bound
to `127.0.0.1` is reachable there. The full daemon + bridge + QEMU stack: [STACK.md](STACK.md).

## Tests
- Quick, no QEMU: `tests/test-apply-overlay.sh`, `tests/test-run-supervisor.sh`, `tests/test-node-image.sh`,
  `tests/test-node-efuse.sh`, `tests/test-setup-src.sh`, `tests/test-build-qemu.sh`, `tests/test-fetch-qemu.sh`.
- Slow, the real firmware: `BRIDGE=<meshcom-loraham-bridge> QEMU_BIN=<qemu-system-xtensa> tests/test-boot-gates.sh
  --main --controls --slow` builds the four envs, provisions a fresh node and checks the network, console,
  web, external radio, GPS, MTU, settings, restarts and link loss; `--controls` proves each check can fail.
- `scripts/test.sh` is the host test LoRaHAM Pi Control runs after a build (boot marker plus diagnostics).
- The weekly workflow `.github/workflows/boot-gates.yml` runs the slow test against upstream `dev`; a failure
  opens or updates one issue naming the upstream commit and the failing gate. GitHub pauses scheduled
  workflows after 60 days without a commit to the default branch; re-enable it in the Actions tab.

## Maintenance: moving the MeshCom pin
```bash
scripts/setup.sh --ref <sha>
scripts/apply-overlay.sh
scripts/prepare-openeth.sh
for e in qemu-headless qemu-headless-extradio qemu-headless-gpsd qemu-headless-extradio-gpsd; do scripts/build.sh --env $e; done
BRIDGE=… QEMU_BIN=… tests/test-boot-gates.sh --main --controls --slow
```
Then set `DEFAULT_REF` and the verified block below. How a break shows, as a guide:
- **a compile error** in `src/qemu/` or the variant: upstream renamed something our files use (the settings
  struct, `EspETH`, the W5500 calls in `src/esp32/esp32_eth.cpp`, `initVariant`, `externalRadioNetworkReady`);
- **a failing boot gate**: an upstream change in start-up order, Ethernet-mode gates or console commands;
- **a failing XR gate**: the external-radio protocol or the bridge.
A change to a `platformio.ini` makes PlatformIO clean every env's build, so build all four again.

## Limitations
- No radio without the external-radio profile; no Wi-Fi, BLE, display, sensors, PMU or battery.
- QEMU user-mode networking: the host reaches the guest only through the forwarded ports.
- The spectrum page is the stock one: with no local chip it answers after about 10 s without a scan.
- mDNS runs as on an Ethernet board and is not tested.

## Verified
```
validated against MeshCom f2b3a3496a76f327abec8b7228bce436cafe9606 on 2026-10-16, x86_64 Linux (Fedora 43):
  tests/test-boot-gates.sh --main --controls --slow, all as expected; PlatformIO 6.1.19;
  framework-arduinoespressif32 3.20017.241212 (Arduino-ESP32 2.0.17, ESP-IDF 4.4.7);
  QEMU esp-develop-9.2.2-20260417 + patches/qemu (scripts/build-qemu.sh)
aarch64: not yet run with this layout
```
