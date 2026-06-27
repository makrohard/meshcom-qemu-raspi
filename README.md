# MeshCom Firmware on QEMU (classic ESP32, headless)

Run the **MeshCom firmware** headlessly in the official Espressif ESP32 QEMU
on a Raspberry Pi, with OpenCores Ethernet (OpenETH) networking, so the existing
MeshCom **web UI** and **net-console** are reachable from the host — no LoRa
radio, Wi-Fi, BLE, GPS, display, or sensors required.

By default it builds a **known-working, pinned stable release** of MeshCom (the
version this overlay is verified against). The **latest `dev`** branch is also
supported as an option. A small overlay adds a QEMU-only build profile and the
QEMU support code. Opt-in profiles add **external-radio** and **GPS** support
(sections below); the default headless target is unaffected.

## Upstream references
- MeshCom Firmware: https://github.com/icssw-org/MeshCom-Firmware
- Espressif QEMU (ESP-IDF docs): https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/tools/qemu.html
- PlatformIO: https://platformio.org/

## Prerequisites (install once — scripts never auto-install)
```bash
# Debian/Raspberry Pi OS:
sudo apt-get install -y git curl libslirp0
pipx install platformio && pipx ensurepath        # PlatformIO (user-level)
# Official Espressif QEMU (xtensa), via ESP-IDF tooling:
#   python $IDF_PATH/tools/idf_tools.py install qemu-xtensa
# (any install that puts qemu-system-xtensa under ~/.espressif/tools or on PATH works)
```
If a prerequisite is missing, each script stops and prints the exact command to run.

## Reproduce
Run from this directory, in order:
```bash
scripts/setup.sh            # fetch pinned stable MeshCom into .work/ (default)
                            #   --dev for latest dev, or --ref <tag|branch|sha>
scripts/apply-overlay.sh    # add the QEMU-headless overlay (checked patch)
scripts/prepare-openeth.sh  # vendor the matching ESP-IDF OpenETH driver into .work/
scripts/build.sh            # build the qemu-headless firmware + merge a flash image
scripts/run.sh              # boot QEMU (foreground; keep this terminal open)
```
In a second terminal:
```bash
scripts/test.sh             # verify web UI (10x) + net-console + no radio
scripts/status.sh           # quick state check at any time
```

## Browser
Open: **http://127.0.0.1:18083/** — the existing MeshCom web UI.
(The net-console listens on `127.0.0.1:12323`.)

## Verify
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18083/   # -> 200
scripts/status.sh                                                  # RUNNING + GOT_IP + http 200
```

## Stop / clean up
```bash
scripts/stop.sh             # stop only the QEMU instance started by run.sh
scripts/clean.sh            # remove .work/ and .run/ (keeps overlay, scripts, README)
```
## Choosing the MeshCom version
```bash
scripts/setup.sh            # pinned known-working stable (default)
scripts/setup.sh --dev      # latest upstream dev branch
scripts/setup.sh --ref X    # any tag/branch/sha
```
Change the pin via `DEFAULT_REF` in `scripts/setup.sh`. With `--dev`/newer refs the
overlay patch may need maintenance — `apply-overlay.sh` fails clearly if so.
Picking a MeshCom version also fixes the Arduino framework/ESP-IDF (via its
`platformio.ini`); the OpenETH driver is auto-fetched to match.

## QEMU version
QEMU is **never patched or installed by these scripts** — the official
`qemu-system-xtensa` you already have is used as-is and *soft-pinned*: `run.sh`
records the version and warns if it differs from the verified build, but still runs.
```bash
scripts/run.sh --qemu /path/to/qemu-system-xtensa   # override the binary
# exact tested build: idf_tools.py install qemu-xtensa@esp_develop_9.0.0_20240606
```

## Current limitations
- No LoRa/RF, Wi-Fi, BLE, display, sensors, PMU, or battery hardware is emulated;
  those are disabled in the QEMU build. (GPS is available as an opt-in profile via
  injected NMEA — see *GPS (opt-in)*.) `WiFi.status()` is not a valid readiness
  signal (OpenETH is used instead).
- Networking is QEMU user-mode (SLIRP). The guest reaches the host at `10.0.2.2`;
  the host reaches the guest only via the forwarded ports above.
- The overlay patch targets the upstream layout; if upstream changes those files,
  `apply-overlay.sh` fails clearly and the patch needs maintenance.
- On the **default** target there is no radio to drive, so web pages / net-console are
  read-only in practice; the opt-in GPS and external-radio profiles are driven as their
  sections below describe.
- **Spectrum scan** is not available under QEMU. It reads RSSI directly off a local
  SX126x chip (`spectralScanStart`/`spectralScanGetResult`), which the emulated node
  does not have — and the external-radio path carries packets, not a chip-level band
  sweep. The web page shows a clear notice (no error, no wait); use a physical T-Deck
  for real spectrum scans.

## Tested with
```
- MeshCom (default pin):  v4.35p.06.16  (sha bde32f37a376233a283ce6ca75a3ed86303a0a50)
- Also verified against:  upstream/dev  (latest, via --dev)
- PlatformIO:             6.1.19
- Arduino framework:      framework-arduinoespressif32 3.20017.241212 (Arduino-ESP32 2.0.17)
- Bundled ESP-IDF:        4.4.7
- Espressif QEMU:         qemu-xtensa esp_develop_9.0.0_20240606 (QEMU 9.0.0), aarch64
- Host:                   Raspberry Pi (aarch64), Debian GNU/Linux 13 (trixie)
```
Resolved tool versions are auto-detected at run time; this block records what
passed, not a hard requirement.

## GPS (opt-in)
Opt-in profiles add the **real MeshCom GPS path** (TinyGPSPlus), fed line-oriented
NMEA over a virtual UART1 — from the host **gpsd** (live u-blox) or from synthetic
fixtures. The default `qemu-headless` and external-radio targets are unaffected.

- `qemu-headless-gpsd` — GPS only; used by the automated NMEA-fixture suite.
- `qemu-headless-extradio-gpsd` — GPS plus the external-radio path.

```bash
scripts/build.sh --env qemu-headless-gpsd

# Start the relay FIRST: GPS init is one-shot, so NMEA must be flowing when the node
# boots; the relay waits for the socket run.sh creates. Synthetic fix (no receiver) …
python3 scripts/gps-relay.py --mode fixture \
        --fixture fixtures/gps/valid_fix.nmea --uart .run/gps-uart1.sock --rate 5 --loop
# … or the real u-blox via host gpsd:
# python3 scripts/gps-relay.py --mode gpsd --gpsd 127.0.0.1:2947 --uart .run/gps-uart1.sock

# then boot the node (separate terminal):
scripts/run.sh   --env qemu-headless-gpsd        # creates .run/gps-uart1.sock

scripts/test-gps.sh --env qemu-headless-gpsd     # automated fixture suite (valid/no-fix/
                                                 # malformed/stale/short-track; handles ordering)
```

- **Live u-blox via host gpsd** (loopback-only; the guest never touches
  `/dev/ttyACM0`): [docs/gpsd-host-setup.md](docs/gpsd-host-setup.md).
- **Full daemon + bridge + QEMU stack** run guide: [STACK.md](STACK.md).

## External-radio overlay (opt-in)
An optional target boots the **real MeshCom `EXTERNAL_RADIO` firmware** under QEMU
so it connects to a local `meshcom-loraham-bridge` over the guest→host route — used
to validate the native firmware against the bridge/daemon/Pi-HAT/RF path without
flashing hardware. The default `qemu-headless` target is completely unaffected.

How it stays opt-in and out-of-tree:
- It runs a **local MeshCom feature branch** (the external-radio code is not
  upstream). Point the harness at a local checkout WITHOUT modifying that source:
  ```bash
  scripts/setup.sh --src /path/to/MeshCom-Firmware --ref feature/external-radio-tcp-draft
  scripts/apply-overlay.sh
  scripts/prepare-openeth.sh
  ```
- The readiness override lives **only in this overlay**
  (`overlay/src/qemu/qemu_external_radio_ready.cpp`): a strong override of the
  firmware's weak `externalRadioNetworkReady()` seam that returns true ONLY on
  STRICT, event-backed OpenETH IP connectivity (`qemuNetworkReadyEvent()`): true
  after a genuine `IP_EVENT_ETH_GOT_IP`, cleared again on Ethernet loss, and never
  satisfied by the transparent SLIRP static fallback — never unconditionally.
- In this env only, the firmware's Wi-Fi-specific 30s `checkWifiPing` watchdog is
  compiled out (an `EXTERNAL_RADIO`-gated patch hunk). With no Wi-Fi present it would
  otherwise see `WiFi.status() != WL_CONNECTED` forever and churn the web/network
  lifecycle, tripping the XR readiness gate. The default `qemu-headless` target keeps
  the original watchdog and the SLIRP fallback unchanged.
- The bridge endpoint and HMAC password are supplied **locally at build time** via
  environment variables and are **never committed**:
  ```bash
  export XR_HOST=10.0.2.2 XR_PORT=7000 XR_PASSWORD=<secret>
  scripts/build.sh --env qemu-headless-extradio
  scripts/run.sh   --env qemu-headless-extradio
  ```
  (`10.0.2.2` is QEMU's standard SLIRP host route; a bridge bound to host
  `127.0.0.1:<port>` is reachable there. Bind the bridge to loopback + HMAC.)

Native validation workflow (high level): start the LoRaHAM daemon (433) and the
bridge (`--backend loraham`, loopback, `--password-file`), then boot this target.
The firmware obtains an OpenETH IP, connects to the bridge, authenticates (HMAC),
and CONFIGUREs with its MeshCom radio profile; RX from a peer flows into native
MeshCom ingress. Note: set the node's TX power ≤ 20 dBm (`--txpower`, the daemon
caps power). The Wi-Fi-specific keepalive watchdog is suppressed in this env and XR
readiness is event-backed, so the design prevents Wi-Fi-triggered web/network churn
and the false XR PONG timeouts it caused. A live 30-minute idle-stability run is
still required to confirm this and remains outstanding until it has actually passed.

This overlay adds no MeshCom application logic to the bridge or daemon; the bridge
remains byte-transparent and payload-neutral.
