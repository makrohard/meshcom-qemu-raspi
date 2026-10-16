# Gate 1, CODE: s5 runner — file C

Part of the packet `gate1-CODE-s5.md`; same request and redaction. The plan is the added file `plans/PLAN-s5-runner.md` below.

## Diff 3 of 3: docs, plan, the removed patch (`git diff origin/main HEAD -- README.md STACK.md fixtures plans overlay/patches`)

```diff
diff --git a/README.md b/README.md
index 429534ab..8aaa6a95 100644
--- a/README.md
+++ b/README.md
@@ -1,198 +1,102 @@
 # MeshCom Firmware on QEMU (classic ESP32, headless)
 
-Run the **MeshCom firmware** headlessly in the official Espressif ESP32 QEMU
-on a Raspberry Pi, with OpenCores Ethernet (OpenETH) networking, so the existing
-MeshCom **web UI** and **net-console** are reachable from the host — no LoRa
-radio, Wi-Fi, BLE, GPS, display, or sensors required.
-
-By default it builds a **pinned MeshCom `dev` commit** (the overlay patch applies
-to it). The moving **`dev`** branch can be selected with `--dev`; newer upstream revisions may need an overlay refresh. A small overlay adds a QEMU-only build profile and the
-QEMU support code. Opt-in profiles add **external-radio** and **GPS** support
-(sections below); the default headless target is unaffected.
-
-## Upstream references
-- MeshCom Firmware: https://github.com/icssw-org/MeshCom-Firmware
-- Firmware line: upstream icssw-org `dev` again (since the overlay at b99e6ee3; the earlier pins used the fork branch `lhpc-speed`)
-- Espressif QEMU (ESP-IDF docs): https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/tools/qemu.html
-- PlatformIO: https://platformio.org/
-
-## Prerequisites (install once — scripts never auto-install)
+Runs the **stock MeshCom firmware** ([icssw-org/MeshCom-Firmware](https://github.com/icssw-org/MeshCom-Firmware))
+headless in Espressif's ESP32 QEMU, with emulated Ethernet, so the MeshCom web UI (`http://127.0.0.1:18083/`)
+and net console (`127.0.0.1:12323`) are reachable from the host. With the external-radio profile the firmware
+talks to a `meshcom-loraham-bridge`, and through it to a real radio. Used by LoRaHAM Pi Control; usable by
+firmware developers to boot MeshCom without hardware.
+
+## Run
+Prerequisites: `git curl libslirp0`, PlatformIO (`pipx install platformio`), and a `qemu-system-xtensa`
+(`scripts/build-qemu.sh <dir> --link-gate <script>` builds the verified one; any on `PATH` is used otherwise).
 ```bash
-# Debian/Raspberry Pi OS:
-sudo apt-get install -y git curl libslirp0
-pipx install platformio && pipx ensurepath        # PlatformIO (user-level)
-# Official Espressif QEMU (xtensa), via ESP-IDF tooling:
-#   python $IDF_PATH/tools/idf_tools.py install qemu-xtensa
-# (any install that puts qemu-system-xtensa under ~/.espressif/tools or on PATH works)
+scripts/setup.sh && scripts/apply-overlay.sh && scripts/prepare-openeth.sh && scripts/build.sh && scripts/run.sh
 ```
-If a prerequisite is missing, each script stops and prints the exact command to run.
-
-## Reproduce
-Run from this directory, in order:
+`run.sh` runs in the foreground; a first start provisions the node (below). `scripts/stop.sh` stops it,
+`scripts/status.sh` shows its state, `scripts/clean.sh` removes `.work/` and `.run/`.
+
+## House rules
+- **Pinned by commit.** `scripts/setup.sh` checks out `DEFAULT_REF`, a MeshCom commit; a tag is a label
+  only (upstream moves tags: `v4.40a.hbserver` moved on 2026-10-13). `--ref <sha|branch|tag>` and
+  `--src <path|URL>` select another revision or repository.
+- **Our files only.** No MeshCom file is changed. `apply-overlay.sh` copies `overlay/variants/qemu-headless/`
+  and `overlay/src/qemu/` into the stock tree and refuses (rc 4) a tree with a modified tracked file.
+- **The QEMU speed patch is temporary.** `patches/qemu/` is submitted as espressif/qemu#183 and goes once an
+  Espressif release tag contains it (`patches/qemu/README.md`; issue #1 here tracks it).
+- **No secrets in the tree.** The bridge password comes from `XR_PASSWORD` at build time.
+
+## How the stock firmware runs under QEMU
+- **Network:** QEMU emulates the OpenCores Ethernet MAC. A strong `initVariant()` (`src/qemu/qemu_ethmode.cpp`)
+  starts it before `setup()` and reports its address to MeshCom's Ethernet mode (`HAS_ETHERNET`,
+  `node_netmode` 1). `ETHClass2.h`/`EthernetUdp.h` in the variant stand in for the W5500 libraries that
+  mode calls, so its code reports the emulated network. Readiness is withdrawn when the link or the address
+  goes away, and returns with them.
+- **No hardware:** with the external radio the firmware does not begin a local radio; without it
+  `radio.begin()` finds no chip and the boot continues. The display probe finds nothing; BLE and the battery
+  are off (`DISABLE_BLE`, `DISABLE_BATTERY`).
+- **Reboots:** QEMU runs with `-no-reboot`, so a guest reset ends QEMU (inside qemu-xtensa a reset wedges in
+  the ROM), and `run.sh` starts it again: `[run] guest reset after <s> s -> restart #<n>`, also counted in
+  `.run/restarts`. Settings that make MeshCom reboot itself (`--setcall`, `--netmode`, …) therefore cost one
+  restart. Exit codes: 0 stopped · 1 setup error · 2 usage · 3 provisioning failed · 5 QEMU error ·
+  75 restart limit (3 runs shorter than 60 s in a row, or more than 10 restarts within an hour).
+- **Provisioning:** on a node image without a matching `<image>.provisioned` marker, `run.sh` first boots once
+  and sends MeshCom's own console commands over UART0: placeholder Wi-Fi credentials (stock code turns the
+  web server off without them; Ethernet mode never uses them), `--webserver on`, `--netconsole on`,
+  `--mesh off`, `--gateway off`, `--extudp off`, `--gps on` (`*-gpsd`), `--wifiap off`, `--netmode eth`.
+  The marker is written only after the next boot's `--info` shows Ethernet mode with mesh, extudp and gateway
+  off and the web page answers; otherwise exit 3. Then set the node's callsign: `--setcall <call>` on the
+  console (LoRaHAM Pi Control sends it after each start). Until a callsign is set, MeshCom forces its AP flag
+  on and refuses to transmit.
+- **The node image** (`.state/node-flash.bin`, or `--node-image`) keeps the settings across rebuilds
+  (`scripts/node-image.sh`); `<image>.efuse` gives the node its MAC and so its MeshCom node ID.
+
+## Profiles
+| env | adds |
+|---|---|
+| `qemu-headless` | web UI and console over the emulated Ethernet |
+| `qemu-headless-extradio` | the external radio: `XR_HOST=10.0.2.2 XR_PORT=<port> XR_PASSWORD=<secret> scripts/build.sh --env qemu-headless-extradio`; an empty password still builds password authentication |
+| `qemu-headless-gpsd`, `qemu-headless-extradio-gpsd` | UART1 on `.run/gps-uart1.sock`, fed by `scripts/gps-relay.py` (`--mode fixture` from `fixtures/gps/`, or `--mode gpsd`, [docs/gpsd-host-setup.md](docs/gpsd-host-setup.md)); start the relay before the node |
+
+Pass the same `--env` to `build.sh` and `run.sh`. `10.0.2.2` is QEMU's address for the host; a bridge bound
+to `127.0.0.1` is reachable there. The full daemon + bridge + QEMU stack: [STACK.md](STACK.md).
+
+## Tests
+- Quick, no QEMU: `tests/test-apply-overlay.sh`, `tests/test-run-supervisor.sh`, `tests/test-node-image.sh`,
+  `tests/test-node-efuse.sh`, `tests/test-setup-src.sh`, `tests/test-build-qemu.sh`, `tests/test-fetch-qemu.sh`.
+- Slow, the real firmware: `BRIDGE=<meshcom-loraham-bridge> QEMU_BIN=<qemu-system-xtensa> tests/test-boot-gates.sh
+  --main --controls --slow` builds the four envs, provisions a fresh node and checks the network, console,
+  web, external radio, GPS, MTU, settings, restarts and link loss; `--controls` proves each check can fail.
+- `scripts/test.sh` is the host test LoRaHAM Pi Control runs after a build (boot marker plus diagnostics).
+- The weekly workflow `.github/workflows/boot-gates.yml` runs the slow test against upstream `dev`; a failure
+  opens or updates one issue naming the upstream commit and the failing gate. GitHub pauses scheduled
+  workflows after 60 days without a commit to the default branch; re-enable it in the Actions tab.
+
+## Maintenance: moving the MeshCom pin
 ```bash
-scripts/setup.sh            # fetch the pinned MeshCom into .work/ (default)
-                            #   --dev for the moving dev branch, or --ref <tag|branch|sha>
-scripts/apply-overlay.sh    # add the QEMU-headless overlay (checked patch)
-scripts/prepare-openeth.sh  # vendor the matching ESP-IDF OpenETH driver into .work/
-scripts/build.sh            # build the qemu-headless firmware + merge a flash image
-scripts/run.sh              # boot QEMU (foreground; keep this terminal open)
+scripts/setup.sh --ref <sha>
+scripts/apply-overlay.sh
+scripts/prepare-openeth.sh
+for e in qemu-headless qemu-headless-extradio qemu-headless-gpsd qemu-headless-extradio-gpsd; do scripts/build.sh --env $e; done
+BRIDGE=… QEMU_BIN=… tests/test-boot-gates.sh --main --controls --slow
 ```
-In a second terminal:
-```bash
-scripts/test.sh             # verify web UI (10x) + net-console + no radio
-scripts/status.sh           # quick state check at any time
+Then set `DEFAULT_REF` and the verified block below. How a break shows, as a guide:
+- **a compile error** in `src/qemu/` or the variant: upstream renamed something our files use (the settings
+  struct, `EspETH`, the W5500 calls in `src/esp32/esp32_eth.cpp`, `initVariant`, `externalRadioNetworkReady`);
+- **a failing boot gate**: an upstream change in start-up order, Ethernet-mode gates or console commands;
+- **a failing XR gate**: the external-radio protocol or the bridge.
+A change to a `platformio.ini` makes PlatformIO clean every env's build, so build all four again.
+
+## Limitations
+- No radio without the external-radio profile; no Wi-Fi, BLE, display, sensors, PMU or battery.
+- QEMU user-mode networking: the host reaches the guest only through the forwarded ports.
+- The spectrum page is the stock one: with no local chip it answers after about 10 s without a scan.
+- mDNS runs as on an Ethernet board and is not tested.
+
+## Verified
 ```
-
-## Browser
-Open: **http://127.0.0.1:18083/** — the existing MeshCom web UI.
-(The net-console listens on `127.0.0.1:12323`.)
-
-## Verify
-```bash
-curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18083/   # -> 200
-scripts/status.sh                                                  # RUNNING + GOT_IP + http 200
+validated against MeshCom f2b3a3496a76f327abec8b7228bce436cafe9606 on 2026-10-16, x86_64 Linux (Fedora 43):
+  tests/test-boot-gates.sh --main --controls --slow, all as expected; PlatformIO 6.1.19;
+  framework-arduinoespressif32 3.20017.241212 (Arduino-ESP32 2.0.17, ESP-IDF 4.4.7);
+  QEMU esp-develop-9.2.2-20260417 + patches/qemu (scripts/build-qemu.sh)
+aarch64: not yet run with this layout
 ```
-
-## Stop / clean up
-```bash
-scripts/stop.sh             # stop only the QEMU instance started by run.sh
-scripts/clean.sh            # remove .work/ and .run/ (keeps overlay, scripts, README)
-```
-## Choosing the MeshCom version
-```bash
-scripts/setup.sh            # pinned, verified dev commit (default)
-scripts/setup.sh --dev      # the moving upstream dev branch
-scripts/setup.sh --ref X    # any tag/branch/sha
-```
-`--src <path|URL>` builds from another repository, e.g. a fork carrying unmerged
-changes (`--src <the fork's URL> --ref <its branch or commit>`).
-Change the pin via `DEFAULT_REF` in `scripts/setup.sh`. With `--dev`/newer refs the
-overlay patch may need maintenance — `apply-overlay.sh` fails clearly if so.
-Picking a MeshCom version also fixes the Arduino framework/ESP-IDF (via its
-`platformio.ini`); the OpenETH driver is auto-fetched to match.
-
-## QEMU version
-Standalone, the `qemu-system-xtensa` you already have is used as-is and *soft-pinned*:
-`run.sh` records the version and warns if it differs from the verified build, but still runs.
-```bash
-scripts/run.sh --qemu /path/to/qemu-system-xtensa   # override the binary
-scripts/run.sh --node-image /path/node-flash.bin    # the node's image (settings) and <image>.efuse (MAC = MeshCom node ID); default .state/
-```
-`scripts/build-qemu.sh` (used by LoRaHAM Pi Control) builds a headless QEMU from Espressif's tag
-`esp-develop-9.2.2-20260417` **plus a temporary patch** in `patches/qemu/`: without it every flash
-write under QEMU rebuilds the memory map, which froze the node for about 55 s per settings save on a
-Pi Zero 2W. It is submitted upstream as espressif/qemu#183 and is removed once an Espressif release
-tag contains it: issue #1 here tracks that, and the weekly `qemu-patch-exit-check` workflow comments
-there when it happens (it runs from `main`; GitHub pauses it after 60 days without commits); the
-steps are in `patches/qemu/README.md`. The build installs QEMU's licence
-texts and a `SOURCE` note (tag, commit, patch sha256) in `qemu/share/doc/qemu/`.
-Espressif's prebuilt QEMU (`idf_tools.py`, `scripts/fetch-qemu.sh`) does not contain the patch.
-
-## Current limitations
-- No LoRa/RF, Wi-Fi, BLE, display, sensors, PMU, or battery hardware is emulated;
-  those are disabled in the QEMU build. (GPS is available as an opt-in profile via
-  injected NMEA — see *GPS (opt-in)*.) `WiFi.status()` is not a valid readiness
-  signal (OpenETH is used instead).
-- Networking is QEMU user-mode (SLIRP). The guest reaches the host at `10.0.2.2`;
-  the host reaches the guest only via the forwarded ports above.
-- The overlay patch targets the upstream layout; if upstream changes those files,
-  `apply-overlay.sh` fails clearly and the patch needs maintenance.
-- On the **default** target there is no radio to drive, so web pages / net-console are
-  read-only in practice; the opt-in GPS and external-radio profiles are driven as their
-  sections below describe.
-- **Spectrum scan** is not available under QEMU. It reads RSSI directly off a local
-  SX126x chip (`spectralScanStart`/`spectralScanGetResult`), which the emulated node
-  does not have — and the external-radio path carries packets, not a chip-level band
-  sweep. The web page shows a clear notice (no error, no wait); use a physical T-Deck
-  for real spectrum scans.
-
-## Tested with
-```
-- MeshCom (default pin):  icssw-org dev ad36784f (2026-09-28, with PR #1164/#1165/#1166): the overlay patch and its `#pragma once` step apply (checked 2026-09-29); lhpc passes its own pin as `--ref` and `--src`
-- M21 validation snapshot: lhpc-speed ba289816 merged with dev 6e62fb2c: all four QEMU profiles build; runtime exercised on qemu-headless-extradio-gpsd (x86_64 Linux host)
-- PlatformIO:             6.1.19
-- Arduino framework:      framework-arduinoespressif32 3.20017.241212 (Arduino-ESP32 2.0.17)
-- Bundled ESP-IDF:        4.4.7
-- Espressif QEMU:         esp-develop-9.2.2-20260417 + patches/qemu (QEMU 9.2.2, scripts/build-qemu.sh)
-- Previously verified:    Raspberry Pi (aarch64), Debian GNU/Linux 13 (trixie), with the earlier pin; not rerun for this upstream refresh
-```
-Resolved tool versions are auto-detected at run time; this block records what
-passed, not a hard requirement.
-
-## GPS (opt-in)
-Opt-in profiles add the **real MeshCom GPS path** (TinyGPSPlus), fed line-oriented
-NMEA over a virtual UART1 — from the host **gpsd** (live u-blox) or from synthetic
-fixtures. The default `qemu-headless` and external-radio targets are unaffected.
-
-- `qemu-headless-gpsd` — GPS only; used by the automated NMEA-fixture suite.
-- `qemu-headless-extradio-gpsd` — GPS plus the external-radio path.
-
-```bash
-scripts/build.sh --env qemu-headless-gpsd
-
-# Start the relay FIRST: GPS init is one-shot, so NMEA must be flowing when the node
-# boots; the relay waits for the socket run.sh creates. Synthetic fix (no receiver) …
-python3 scripts/gps-relay.py --mode fixture \
-        --fixture fixtures/gps/valid_fix.nmea --uart .run/gps-uart1.sock --rate 5 --loop
-# … or the real u-blox via host gpsd:
-# python3 scripts/gps-relay.py --mode gpsd --gpsd 127.0.0.1:2947 --uart .run/gps-uart1.sock
-
-# then boot the node (separate terminal):
-scripts/run.sh   --env qemu-headless-gpsd        # creates .run/gps-uart1.sock
-
-scripts/test-gps.sh --env qemu-headless-gpsd     # automated fixture suite (valid/no-fix/
-                                                 # malformed/stale/short-track; handles ordering)
-```
-
-- **Live u-blox via host gpsd** (loopback-only; the guest never touches
-  `/dev/ttyACM0`): [docs/gpsd-host-setup.md](docs/gpsd-host-setup.md).
-- **Full daemon + bridge + QEMU stack** run guide: [STACK.md](STACK.md).
-
-## External-radio overlay (opt-in)
-An optional target boots the **real MeshCom `EXTERNAL_RADIO` firmware** under QEMU
-so it connects to a local `meshcom-loraham-bridge` over the guest→host route — used
-to validate the native firmware against the bridge/daemon/Pi-HAT/RF path without
-flashing hardware. The default `qemu-headless` target is completely unaffected.
-
-How it stays opt-in and out-of-tree:
-- It runs a **local MeshCom feature branch** (the external-radio code is not
-  upstream). Point the harness at a local checkout WITHOUT modifying that source:
-  ```bash
-  scripts/setup.sh --src /path/to/MeshCom-Firmware --ref feature/external-radio-tcp-draft
-  scripts/apply-overlay.sh
-  scripts/prepare-openeth.sh
-  ```
-- The readiness override lives **only in this overlay**
-  (`overlay/src/qemu/qemu_external_radio_ready.cpp`): a strong override of the
-  firmware's weak `externalRadioNetworkReady()` seam that returns true ONLY on
-  STRICT, event-backed OpenETH IP connectivity (`qemuNetworkReadyEvent()`): true
-  after a genuine `IP_EVENT_ETH_GOT_IP`, cleared again on Ethernet loss, and never
-  satisfied by the transparent SLIRP static fallback — never unconditionally.
-- The firmware's Wi-Fi-specific 30s `checkWifiPing` watchdog is compiled out in every
-  `qemu-headless` target (a `QEMU_HEADLESS`-gated patch hunk). With no Wi-Fi present it
-  would otherwise see no Wi-Fi station forever and churn the web/network lifecycle,
-  close the shared UDP socket and trip the XR readiness gate. The default
-  `qemu-headless` target keeps the SLIRP fallback unchanged.
-- The bridge endpoint and HMAC password are supplied **locally at build time** via
-  environment variables and are **never committed**:
-  ```bash
-  export XR_HOST=10.0.2.2 XR_PORT=7000 XR_PASSWORD=<secret>
-  scripts/build.sh --env qemu-headless-extradio
-  scripts/run.sh   --env qemu-headless-extradio
-  ```
-  (`10.0.2.2` is QEMU's standard SLIRP host route; a bridge bound to host
-  `127.0.0.1:<port>` is reachable there. Bind the bridge to loopback + HMAC.)
-
-Native validation workflow (high level): start the LoRaHAM daemon (433) and the
-bridge (`--backend loraham`, loopback, `--password-file`), then boot this target.
-The firmware obtains an OpenETH IP, connects to the bridge, authenticates (HMAC),
-and CONFIGUREs with its MeshCom radio profile; RX from a peer flows into native
-MeshCom ingress. Note: on SX127x boards the daemon accepts 2..17 dBm only; the node's
-stored TX power is sent at XR connect and re-synced after a runtime `--txpower` change.
-The Wi-Fi-specific keepalive watchdog is suppressed in every QEMU target and XR
-readiness is event-backed, so the design prevents Wi-Fi-triggered web/network churn
-and the false XR PONG timeouts it caused. A live 30-minute idle-stability run is
-still required to confirm this and remains outstanding until it has actually passed.
-
-This overlay adds no MeshCom application logic to the bridge or daemon; the bridge
-remains byte-transparent and payload-neutral.
diff --git a/STACK.md b/STACK.md
index 7c04438a..a49559bf 100644
--- a/STACK.md
+++ b/STACK.md
@@ -16,8 +16,8 @@ TX/RX against a physical T-Deck, via the bridge and daemon.
 
 | Component | Local path | Repo |
 |---|---|---|
-| QEMU overlay (this) | `meshcom-qemu-raspi` | https://github.com/makrohard/meshcom-qemu-raspi |
-| MeshCom firmware (XR branch) | `MeshCom-Firmware` @ `feature/external-radio-tcp-draft` | https://github.com/makrohard/MeshCom-Firmware/tree/feature/external-radio-tcp-draft · upstream https://github.com/icssw-org/MeshCom-Firmware |
+| QEMU runner (this) | `meshcom-qemu-raspi` | https://github.com/makrohard/meshcom-qemu-raspi |
+| MeshCom firmware | fetched by `scripts/setup.sh` into `.work/` at the pinned commit (`DEFAULT_REF`) | https://github.com/icssw-org/MeshCom-Firmware (the external radio is upstream since PR #1072) |
 | Bridge | `meshcom-loraham-bridge` | https://github.com/makrohard/meshcom-loraham-bridge |
 | LoRaHAM daemon (v111) | `loraham-daemon-hardening/loraham_daemon` | https://github.com/LoRaHAM/LoRaHAM_Daemon (branch `hardening/daemon-tests`, PR #8) |
 
@@ -38,7 +38,7 @@ GPS-only target with a synthetic fix. No daemon, bridge, gpsd, or radio needed.
 
 ```bash
 cd ~/src/meshcom-qemu-raspi
-scripts/setup.sh --src ~/src/MeshCom-Firmware --ref feature/external-radio-tcp-draft
+scripts/setup.sh
 scripts/apply-overlay.sh
 scripts/prepare-openeth.sh
 scripts/build.sh --env qemu-headless-gpsd
@@ -52,9 +52,8 @@ python3 scripts/gps-relay.py --mode fixture \
 scripts/run.sh --env qemu-headless-gpsd
 ```
 
-Open **http://127.0.0.1:18083/** (net-console on `127.0.0.1:12323`). Stop with
-`scripts/stop.sh`. The automated fixture suite (`scripts/test-gps.sh --env qemu-headless-gpsd`)
-handles the relay/node ordering itself.
+A first start provisions the node and restarts it once (README, *Provisioning*). Open
+**http://127.0.0.1:18083/** (net-console on `127.0.0.1:12323`). Stop with `scripts/stop.sh`.
 
 ---
 
@@ -76,7 +75,7 @@ printf '%s' "$(openssl rand -hex 16)" > /tmp/xr_pw
 ```bash
 # 3) Build the GPS + external-radio firmware, bound to the bridge endpoint + secret
 cd ~/src/meshcom-qemu-raspi
-scripts/setup.sh --src ~/src/MeshCom-Firmware --ref feature/external-radio-tcp-draft
+scripts/setup.sh
 scripts/apply-overlay.sh
 scripts/prepare-openeth.sh
 XR_HOST=10.0.2.2 XR_PORT=7000 XR_PASSWORD="$(cat /tmp/xr_pw)" \
@@ -141,7 +140,8 @@ Settings are stored in flash (NVS) and **survive restarts and rebuilds**: `run.s
 image (`.state/node-flash.bin`, or `--node-image <path>`), not on the build output, and carries the node's
 NVS into a new build when its partition table is unchanged (`scripts/node-image.sh`). A build with a
 different partition table starts from defaults, and says so. The node's MAC, and with it its MeshCom node ID, is
-`<node image>.efuse` (created once, `scripts/node-efuse.sh`). Delete both to reset the node.
+`<node image>.efuse` (created once, `scripts/node-efuse.sh`). Delete the image, its `.efuse` and its
+`.provisioned` marker to reset the node.
 
 > The web UI's **Save** does not round-trip under QEMU: the value usually *is* applied
 > and saved server-side, but the page can't show it (the HTTP response is lost under
diff --git a/fixtures/gps/README.md b/fixtures/gps/README.md
index 23a89563..3f85a658 100644
--- a/fixtures/gps/README.md
+++ b/fixtures/gps/README.md
@@ -1,7 +1,7 @@
 # Synthetic GPS NMEA fixtures
 
-These files are **synthetic test vectors** for the QEMU GPS fixture tests
-(`scripts/test-gps.sh`, fed via `scripts/gps-relay.py --mode fixture`). They contain
+These files are **synthetic test vectors** for the QEMU GPS path (`tests/test-boot-gates.sh` feeds
+`valid_fix.nmea` via `scripts/gps-relay.py --mode fixture`; the others are for manual runs). They contain
 **deliberately fictional coordinates** — a round point at **48°00.0000′N 012°00.0000′E**
 — and are **not** captured from any real receiver. No live position is stored here.
 
diff --git a/overlay/patches/meshcom-qemu-headless.patch b/overlay/patches/meshcom-qemu-headless.patch
deleted file mode 100644
index ecd86c99..00000000
--- a/overlay/patches/meshcom-qemu-headless.patch
+++ /dev/null
@@ -1,469 +0,0 @@
-diff --git a/src/esp32/esp32_main.cpp b/src/esp32/esp32_main.cpp
-index feb8caab..7e105034 100644
---- a/src/esp32/esp32_main.cpp
-+++ b/src/esp32/esp32_main.cpp
-@@ -1023,7 +1023,30 @@ void esp32setup()
-         if(!bWIFIAP)
-             bWEBSERVER=false;
-     }
--       
-+
-+    #ifdef QEMU_HEADLESS
-+        // QEMU-only safe defaults (runtime overrides, NOT persisted): the target
-+        // must start the web UI and net-console over OpenETH without any Wi-Fi
-+        // configuration, AP, or Internet gateway/UDP traffic.
-+        bWIFIAP        = false;   // no Wi-Fi AP / no Wi-Fi emulation
-+        bWEBSERVER     = true;    // existing MeshCom web UI enabled
-+        bNETCONSOLE    = true;    // existing MeshCom net-console enabled
-+        bGATEWAY       = false;   // no Internet gateway
-+        bGATEWAY_NOPOS = false;
-+        bEXTUDP        = false;   // no external UDP
-+        bMESH          = false;   // no mesh radio activity (radio is disabled in QEMU)
-+        printlndeb("[QEMU]...headless defaults: web+console ON, wifiAP/gateway/extudp OFF");
-+        #ifdef QEMU_GPS
-+        // QEMU virtual GPS profiles: enable the "GPS on" user setting so the real
-+        // MeshCom GPS receive path runs under emulation (NMEA arrives on UART1). This
-+        // is configuration (the bGPSON flag), NOT a fabricated fix — the fix/position
-+        // still come only from parsed NMEA. Compiled in ONLY for the …-gpsd targets.
-+        bGPSON = true;
-+        printlndeb("[QEMU]...virtual GPS enabled (bGPSON=true); NMEA expected on UART1");
-+        #endif
-+    #endif
-+
-+
-     if(bBMPON)
-     {
-         bBMEON=false;
-@@ -1180,8 +1203,10 @@ void esp32setup()
-     #else
- 
-         #if !defined(BOARD_T_DECK_PRO) && !defined(BOARD_T5_EPAPER)
-+        #ifndef QEMU_HEADLESS
-             setupPMU();
-         #endif
-+        #endif
- 
-     #endif
- 
-@@ -1244,7 +1269,9 @@ void esp32setup()
-     }
-     #endif
- 
-+    #ifndef QEMU_HEADLESS
-     init_onebutton();
-+    #endif
- 
-     printfdeb("[INIT].._GW_ID: %08X\n", _GW_ID);
- 
-@@ -1285,7 +1312,9 @@ void esp32setup()
-     #elif defined(HAS_TFT)
-         initTFT();
-     #else
-+        #ifndef QEMU_HEADLESS
-         initDisplay();
-+        #endif
-     #endif
- 
-     #if defined(BOARD_HELTEC_V3) || defined(BOARD_STICK_V3)
-@@ -1302,7 +1331,9 @@ void esp32setup()
-         String  version = cvers;
-         displayTFT("MeshCom 4.0", version, "@BY ICSSW.ORG", "XX1XXX, XX1XXX",  "...starting now", 5000);
-     #else
-+        #ifndef QEMU_HEADLESS
-         startDisplay((char*)"...starting now", (char*)"@BY ICSSW.ORG", (char*)"XX1XXX, XX1XXX");
-+        #endif
-     #endif
- 
-     //LORA CHIP present
-@@ -1411,6 +1442,13 @@ void esp32setup()
-         int state = radio.begin(433.175);
-         radio.setDio2AsRfSwitch(true);
-         radio.setTCXO(1.8);
-+        #elif defined(QEMU_HEADLESS)
-+        // QEMU headless: no LoRa hardware. Do NOT initialise RadioLib/SPI; force
-+        // "no backend" so bRadio stays false and the entire radio bring-up and the
-+        // radio TX/RX loop blocks (all guarded by if(bRadio)) are skipped. No RF.
-+        int state = RADIOLIB_ERR_CHIP_NOT_FOUND;
-+        (void)state;
-+        printlndeb("[QEMU]...LoRa radio disabled (no backend); RadioLib/SPI init skipped");
-         #else
-         int state = radio.begin(433.175);
-         #endif
-@@ -1867,7 +1905,7 @@ void esp32setup()
-     #else
-     pAdvertising->start();
-     #endif
-- 
-+
-     printfdeb("[BLE ]...Waiting a client connection to notify...\n");
-     #else
-     printfdeb("[BLE ]...disabled (DISABLE_BLE)\n");
-@@ -2977,6 +3015,17 @@ void esp32loop()
-     }
-     #endif
- 
-+    #if defined(QEMU_HEADLESS)
-+    // QEMU (every qemu-headless profile, M13b stabilization): there is no Wi-Fi here.
-+    // The 30s checkWifiPing watchdog below would see no Wi-Fi station forever, then
-+    // Udp.stop()/WiFi.disconnect(), clear node_hasIPaddress and
-+    // stopWebserver()+startNetwork() -- churning the network lifecycle, closing the shared
-+    // UDP socket and (with the external radio) dropping the transport's readiness gate.
-+    // OpenETH readiness here is event-backed (qemuNetworkReady/qemuNetworkReadyEvent) and the
-+    // XR transport keeps its own connectivity/error handling, so this Wi-Fi-specific
-+    // watchdog is suppressed in every QEMU build. All real boards keep the original block
-+    // (the #else branch below) unchanged.
-+    #else
-     // check WiFI connected with Ping every 30 sec
-     if(meshcom_settings.node_netmode == 0 && (uint32_t)(millis() - wifi_active_timer) >= 30000)
-     {
-@@ -3007,6 +3056,7 @@ void esp32loop()
-             wifi_active_timer = millis();
-         }
-     }
-+    #endif
- 
-     // SOFTSER
-     #if defined(ENABLE_SOFTSER)
-@@ -3572,7 +3622,13 @@ void esp32loop()
-         {
-             rebootAuto = 0;
- 
--            #ifdef ESP32
-+            #if defined(QEMU_HEADLESS)
-+                // QEMU: a guest SW reset wedges qemu-xtensa in the ROM bootloader (the
-+                // machine never re-enters the app). Settings are already saved to
-+                // NVS/flash — skip the restart and keep running; restart the stack for
-+                // anything that truly needs a boot.
-+                printlndeb("[QEMU]...auto-reboot suppressed (guest reset wedges QEMU); settings saved");
-+            #elif defined(ESP32)
-                 ESP.restart();
-             #endif
-         }
-diff --git a/src/gps_functions.cpp b/src/gps_functions.cpp
-index 3bb05432..a0e1a321 100644
---- a/src/gps_functions.cpp
-+++ b/src/gps_functions.cpp
-@@ -894,6 +894,54 @@ void WZ_GPS_Init()
-   if(gpsInitDone)
-       return;
- 
-+#if defined(QEMU_GPS)
-+  // QEMU virtual GPS: line-oriented NMEA arrives on UART1 from a host source
-+  // (scripts/gps-relay.py, fed by host gpsd or a synthetic fixture). Bypass ALL
-+  // hardware bring-up: no WZ_GPS_Reset (reset GPIO), no detectBaudrate (8-baud
-+  // sweep), no GPSprobe/SetupUBLOX/SetupL76K (UBX/PCAS config writes to a receiver).
-+  // The normal byte-by-byte TinyGPSPlus receive loop and the HDOP/satellite/age fix
-+  // logic in WZ_GPS_Loop() are left COMPLETELY unchanged. GPS_RX_PIN/GPS_TX_PIN are
-+  // synthetic, non-physical pin numbers (no GPS hardware exists under QEMU); the
-+  // socket-backed UART ignores baud.
-+  gpsInitDone = true;
-+
-+  // GPS-03: Neue Sitzung, neuer Schaetzer (mirrors the hardware path below).
-+  altFilterReset(&s_alt);
-+  s_altConvergedOnce = false;
-+  s_altLastMs = 0;
-+
-+  GPSSerial.begin(GPS_BAUDRATE_SETFIX, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
-+  Serial.printf("[GPS ]...QEMU virtual GPS on UART1 (synthetic RX=%d TX=%d @ %d baud; no hardware)\n",
-+                GPS_RX_PIN, GPS_TX_PIN, GPS_BAUDRATE_SETFIX);
-+
-+  // Honest presence detection: a bounded, single-pass count of NMEA-like characters
-+  // that ACTUALLY arrive on the virtual UART. gpsDetected is derived from real bytes,
-+  // never forced true; with no host feed it stays false and WZ_GPS_Loop() is skipped.
-+  gpsDetected = false;
-+  {
-+    uint32_t qstart = millis();
-+    int qchars = 0;
-+    while((millis() - qstart) < (uint32_t)WAIT_DURATION)
-+    {
-+      // Bounded like the outer loop: a host feed faster than the emulated CPU drains it
-+      // must not keep this inner loop, and so the boot, from ever returning (R22).
-+      while(GPSSerial.available() && qchars <= 10 && (millis() - qstart) < (uint32_t)WAIT_DURATION)
-+      {
-+        char qc = char(GPSSerial.read());
-+        if((qc >= 'A' && qc <= 'Z') || (qc >= '0' && qc <= '9') ||
-+           qc == '$' || qc == '*' || qc == ',' || qc == 0x0A || qc == 0x0D)
-+          qchars++;
-+      }
-+      if(qchars > 10) break;
-+    }
-+    gpsDetected = (qchars > 10);
-+    on_UBLOX = gpsDetected;   // virtual module type; no hardware probe was performed
-+    Serial.printf("[GPS ]...QEMU NMEA presence: %d chars -> %s\n",
-+                  qchars, gpsDetected ? "detected" : "no data yet");
-+  }
-+  return;
-+#else
-+
-   WZ_GPS_Reset();
- 
-   gpsInitDone = true;
-@@ -951,6 +999,7 @@ void WZ_GPS_Init()
-     Serial.println("[GPS_ERR] Erkennung fehlgeschlagen (Timeout oder kein Signal)");
-     gpsDetected = false;
-   }
-+#endif
- }
- 
- 
-@@ -971,11 +1020,70 @@ void WZ_GPS_Feed()
-         return;
- 
-     // Alle verfuegbaren Bytes lesen (non-blocking)
-+#ifdef MESHCOM_QEMU_GPSTEST
-+    {
-+        // QEMU-test-only observability (compiled in ONLY for the …-gpsd test profiles,
-+        // never in default/physical/ordinary external-radio builds). Transition-based,
-+        // STATUS ONLY — never prints latitude/longitude/time/altitude. It does NOT alter
-+        // any firmware logic: pure reads + a Serial line on change.
-+        //
-+        // "usable" mirrors MeshCom's fix gate (valid location + HDOP/satellite quality)
-+        // but uses the LIVE TinyGPSPlus location age so the test can deterministically
-+        // observe input going stale. We ALSO print hasfix = WZ_GPS_HasFix(), the firmware's
-+        // own API, which uses the snapshot gpsData.age_ms and therefore does NOT age out
-+        // when input stops (documented behaviour).
-+        static int s_prevUsable = -1;
-+        static double s_lat = 1e9, s_lon = 1e9;
-+        static int s_moves = 0;
-+        bool quality = (fposinfo_hdop < 6.0) && (posinfo_satcount > 5);  // mirrors the firmware fix gate
-+        int usable = (gpsInitDone && gps.location.isValid() &&
-+                      gps.location.age() < 5000 && quality) ? 1 : 0;
-+        // Coordinate-free movement counter: count DISTINCT committed positions, proving
-+        // the parser updates position rather than locking the first point. We compare the
-+        // current committed lat/lon against the previous ones (in memory only — coordinates
-+        // are NEVER logged, only the running count). isUpdated() is not used: the main loop
-+        // below consumes that flag, so we diff the values directly each pass.
-+        if(usable)
-+        {
-+            double la = gps.location.lat(), lo = gps.location.lng();
-+            if(s_lat < 1e8)   // we already have a previous real position to compare against
-+            {
-+                double dla = (la > s_lat) ? (la - s_lat) : (s_lat - la);
-+                double dlo = (lo > s_lon) ? (lo - s_lon) : (s_lon - lo);
-+                if(dla > 0.00005 || dlo > 0.00005)
-+                {
-+                    s_moves++;
-+                    Serial.printf("[GPSTEST] moved n=%d\n", s_moves);
-+                }
-+            }
-+            s_lat = la; s_lon = lo;
-+        }
-+        if(usable != s_prevUsable)
-+        {
-+            // NOTE: fposinfo_hdop is the firmware's float HDOP; it is passed as double
-+            // for %.1f so the varargs line up (the old int posinfo_hdop no longer exists).
-+            Serial.printf("[GPSTEST] fix=%d sats=%u hdop=%.1f hasfix=%d src=%s\n",
-+                          usable, posinfo_satcount, (double)fposinfo_hdop,
-+                          WZ_GPS_HasFix() ? 1 : 0, cTimeSource);
-+            s_prevUsable = usable;
-+        }
-+    }
-+#endif
-+
-     #if defined(USE_HELTEC_T114) or defined(BOARD_T_ECHO)
-     while (Serial1.available())
-     #else
-+    #if defined(QEMU_GPS)
-+    // QEMU: the socket-backed virtual UART has no baud pacing, so a live NMEA feed can keep
-+    // this per-loop drain busy for minutes and starve loop() (the net-console goes deaf).
-+    // Bound the bytes taken per pass to about what 9600 baud delivers in 250 ms; the rest
-+    // waits for the next pass. Hardware keeps the unbounded drain.
-+    int qemu_gps_budget = 256;
-+    while (GPSSerial.available() && qemu_gps_budget-- > 0)
-+    #else
-     while (GPSSerial.available())
-     #endif
-+    #endif
-     {
-         #if defined(USE_HELTEC_T114) or defined(BOARD_T_ECHO)
-         int ic = Serial1.read();
-diff --git a/src/loop_functions.cpp b/src/loop_functions.cpp
-index d6303522..59793688 100644
---- a/src/loop_functions.cpp
-+++ b/src/loop_functions.cpp
-@@ -66,7 +66,7 @@ bool gpsInitDone = false;
- // gps (TinyGPSPlus) wird in gps_functions.cpp unbedingt instanziiert und hier nur fuer
- // reine Distanz-/Kursberechnungen (distanceBetween/courseTo) genutzt - kein GPS-Modul noetig.
- // Daher auch fuer Wireless Paper (ohne ENABLE_GPS) sichtbar machen.
--#if defined(ENABLE_GPS) || defined(ENABLE_RAK_GPS) || defined(WP_DISP)
-+#if defined(QEMU_HEADLESS) || defined(ENABLE_GPS) || defined(ENABLE_RAK_GPS) || defined(WP_DISP)   // QEMU: gps is used unconditionally below
- extern TinyGPSPlus gps;
- #endif
- 
-diff --git a/src/net_console.cpp b/src/net_console.cpp
-index e4758e43..6bc1f356 100644
---- a/src/net_console.cpp
-+++ b/src/net_console.cpp
-@@ -25,6 +25,7 @@
- // HardwareSerial reference before #define Serial MSerial takes effect.
- #include <Arduino.h>
- #include <WiFi.h>
-+#include "qemu/qemu_network.h"   // QEMU_HEADLESS only (self-guarded)
- #include <netinet/in.h>
- #include <freertos/FreeRTOS.h>
- #include <freertos/semphr.h>
-@@ -356,6 +357,10 @@ void loopNetConsole()
-     networkReady = networkReady ||
-                    (meshcom_settings.node_netmode == 1 && meshcom_settings.node_hasIPaddress);
-     #endif
-+    #ifdef QEMU_HEADLESS
-+    // QEMU headless: neither WiFi nor HAS_ETHERNET; the lwIP/TCP stack is ready once OpenETH has an IPv4 address.
-+    networkReady = networkReady || qemuNetworkReady();
-+    #endif
- 
-     if (!networkReady)
-         return;
-diff --git a/src/udp_functions.cpp b/src/udp_functions.cpp
-index 8634f113..f1e00ee5 100644
---- a/src/udp_functions.cpp
-+++ b/src/udp_functions.cpp
-@@ -5,4 +5,6 @@
- #include <Arduino.h>
- 
-+#include "qemu/qemu_network.h"   // QEMU_HEADLESS only (self-guarded)
-+
- #include <udp_functions.h>
- #include <extudp_functions.h>
-@@ -1114,8 +1116,58 @@ void wifiDnsPoll()
-   }
- }
- 
-+#ifdef QEMU_HEADLESS
-+// QEMU-only: copy the OpenETH IPv4 state into meshcom_settings (mirrors what the
-+// Wi-Fi/Ethernet path does), using the event-driven readiness from qemu_network.
-+// The shared UDP socket is (re)opened whenever the IP state is (re)established, as
-+// startMeshComUDP() does on Wi-Fi (the QEMU path skips that function). Every path that
-+// stops the socket also clears hasIPaddress, so !hasIPaddress means "no valid socket".
-+// Without one, ntpHarvestUDP() polls a closed descriptor on every loop pass and the core
-+// logs an EBADF line each time, which stalls the emulated loop for seconds. The IP state
-+// is reported up only once the socket is open; a failed open is retried by the loop.
-+static bool qemuApplyNetState()
-+{
-+  IPAddress ip, gw, mask;
-+  if(!qemuNetworkReady() || !qemuNetworkGetIp(ip, gw, mask))
-+    return false;
-+  if(!hasIPaddress)
-+  {
-+    static bool s_udpFailLogged = false;
-+    if(!Udp.begin(LOCAL_PORT))
-+    {
-+      if(!s_udpFailLogged)
-+        printfdeb("[QEMU]...UDP port %d open FAILED, retrying\n", LOCAL_PORT);
-+      s_udpFailLogged = true;
-+      return false;   // IP state stays down; the loop calls this again
-+    }
-+    s_udpFailLogged = false;
-+    printfdeb("[QEMU]...UDP port %d open\n", LOCAL_PORT);
-+  }
-+  snprintf(meshcom_settings.node_ip, sizeof(meshcom_settings.node_ip), "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);
-+  snprintf(meshcom_settings.node_gw, sizeof(meshcom_settings.node_gw), "%u.%u.%u.%u", gw[0], gw[1], gw[2], gw[3]);
-+  snprintf(meshcom_settings.node_subnet, sizeof(meshcom_settings.node_subnet), "%u.%u.%u.%u", mask[0], mask[1], mask[2], mask[3]);
-+  hasIPaddress = true;
-+  meshcom_settings.node_hasIPaddress = true;
-+  iWlanWait = 0;
-+  return true;
-+}
-+#endif
-+
-  bool startNetwork()
-  {
-+  #ifdef QEMU_HEADLESS
-+    // QEMU headless: bring up OpenETH instead of Wi-Fi. Non-blocking: start the
-+    // driver and let the existing loop poll doWiFiConnect() until GOT_IP.
-+    qemuNetworkStart();
-+    if(qemuApplyNetState())
-+    {
-+      printlndeb("[QEMU]...OpenETH ready; node IP assigned, network up");
-+      return true;
-+    }
-+    iWlanWait = 1;   // not ready yet -> loop calls doWiFiConnect() (non-blocking)
-+    return false;
-+  #endif
-+
-   #if defined(HAS_ETHERNET)
- 
-       if(meshcom_settings.node_netmode == 1)
-@@ -1285,6 +1337,17 @@ bool wifiHarvestGotIp()
- 
- bool doWiFiConnect()
- {
-+  #ifdef QEMU_HEADLESS
-+    // QEMU headless: non-blocking. Report OpenETH readiness; never touch Wi-Fi or
-+    // startMeshComUDP(). No blocking poll loop.
-+    if(qemuApplyNetState())
-+    {
-+      printlndeb("[QEMU]...OpenETH connect OK");
-+      return true;
-+    }
-+    return false;
-+  #endif
-+
-   if(s_wifiScanPending)
-   {
-     int n = WiFi.scanComplete();
-diff --git a/src/web_functions/web_functions.cpp b/src/web_functions/web_functions.cpp
-index 0b60381e..33b61321 100644
---- a/src/web_functions/web_functions.cpp
-+++ b/src/web_functions/web_functions.cpp
-@@ -5,4 +5,6 @@
- #include <Arduino.h>
- 
-+#include "qemu/qemu_network.h"   // QEMU_HEADLESS only (self-guarded)
-+
- #include <configuration.h>
- #include <debugconf.h>
-@@ -114,20 +116,29 @@ void startWebserver()
-     bool ethernet_mode = false;
-     #endif
- 
--    if (!is_connected && !is_ap_active && !ethernet_mode)
-+    #ifdef QEMU_HEADLESS
-+    bool qemu_ready = qemuNetworkReady();
-+    #else
-+    bool qemu_ready = false;
-+    #endif
-+
-+    if (!is_connected && !is_ap_active && !ethernet_mode && !qemu_ready)
-     {
-         return;
-     }
- 
-     web_server.stop();
- 
-+    #ifndef QEMU_HEADLESS
-     MDNS.end();
-+    #endif
- 
-     // Set up mDNS responder:
-     // - first argument is the domain name, in this example
-     //   the fully-qualified domain name is "esp32.local"
-     // - second argument is the IP address to advertise
-     //   we send our IP address on the WiFi network
-+    #ifndef QEMU_HEADLESS
-     if(bMDNSOK)
-     {
-         if (!MDNS.begin(meshcom_settings.node_call))
-@@ -150,6 +161,7 @@ void startWebserver()
-             }
-         }
-     }
-+    #endif
- 
-     web_server.begin();
- 
-@@ -2002,6 +2014,15 @@ void sub_page_spectrum()
- {
-     _create_meshcom_subheader("Spectrum Scan");
-     web_client.println("<div id=\"content_inner\">");
-+#ifdef QEMU_HEADLESS
-+    // QEMU: no local SX126x radio (radio disabled; the real radio lives on the LoRaHAM
-+    // daemon/Pi-HAT and the external-radio path cannot carry a chip-level scan). Return
-+    // a clear message immediately instead of probing a non-existent chip — this avoids
-+    // both the "unable to initialize spectrum scan" error and the long wait it caused.
-+    web_client.println("<p>Spectrum scan is not available under QEMU. It needs direct access to a local SX126x radio chip to sweep the band, which the emulated node does not have. Run spectrum scan on a physical T-Deck.</p>");
-+    web_client.println("</div>");
-+    return;
-+#endif
- #if defined(SX1262X) || defined(SX126X) || defined(SX1262_V3) || defined(SX1262_E290) || defined(USING_SX1262)
- 
-     meshcom_settings.node_specstart = 432.0;
diff --git a/plans/PLAN-s5-runner.md b/plans/PLAN-s5-runner.md
new file mode 100644
index 00000000..185d6819
--- /dev/null
+++ b/plans/PLAN-s5-runner.md
@@ -0,0 +1,180 @@
+# PLAN s5-runner (A2) v5: stock MeshCom in QEMU, our files only
+
+**v5:** answers gate-1 round 4 (F1 the scope of the persisted-state check, F2 readiness on link loss); v4 answered round 3, v3 round 2 and W1, v2 the second read. Change tables: top of the gate packet.
+
+Base: this repository's `main` c2335d12.
+
+Proof: the prototype `cons/s5-proto` (f6a39c04, b1babc7f, **6641a6f5** = this design's network part). It ran stock MeshCom f2b3a349 with 0 tracked MeshCom files changed (x86_64 Linux host, 2026-10-15). Measured for the design (Appendix B):
+- **(M1) without old hunk 14 the two non-GPS envs fail to compile** (`'gps' was not declared`, `src/loop_functions.cpp:3015`, `:5971`); with `ENABLE_GPS` they compile.
+- **(M2) with no radio chip,** stock `radio.begin()` → `failed, code -2`, then `CLIENT STARTED`.
+- **(M3) a fresh node in Wi-Fi mode** with `node_hasIPaddress` false at `startNetwork()` makes stock code start the Wi-Fi PHY, which panics under QEMU (`register_chipv7_phy`).
+- **(M4) a flag clear in Ethernet mode** reaches upstream's `neth.initethDHCP()` through the loop's 5-minute path; with the stand-in it reports the OpenETH address, and web stayed 200 throughout (6.5 min).
+- **(M5) unpaced UART1 input** is backpressured by QEMU to 671 B/s; web answered 200 in 0.28–0.43 s and the console at every 10 s probe (80 s).
+- **(M6) the fresh-node path:** provisioning → before a callsign, the AP flag is forced on but inert (web 200, read-back mesh/extudp/gateway off) → `--setcall` acknowledged → the stock reboot ends QEMU rc 0 13 s later → the restart has no AP, keeps the callsign and the settings.
+
+**Rule:** zero lines changed in any MeshCom file; MeshCom pinned by **commit**, a tag is a label (upstream moved `v4.40a.hbserver` from 8770f9b5 to f2b3a349 on 2026-10-13).
+
+## 1. Target layout
+**Removed:** `overlay/patches/` (the 469-line patch); the patch check and the `#pragma once` step in `apply-overlay.sh` (upstream has it at `src/configuration_global.h:5`); the old `tests/test-apply-overlay.sh`; the `ETHClass2` and `Ethernet` library downloads.
+
+**Same names** (§5): `scripts/apply-overlay.sh` = copy our files, then `git -C .work/MeshCom-Firmware status --porcelain --untracked-files=no` must be empty, else rc 4. A missing file is rc 1.
+
+**Our files** (`overlay/` → the stock tree; the variant is loaded by upstream `platformio.ini:13-14`, `extra_configs = variants/*/platformio.ini`):
+- **`variants/qemu-headless/`:**
+  - `platformio.ini`: four envs, each with `ENABLE_GPS` + `ENABLE_UBLOX` + GPS pins (M1; upstream variants get `ENABLE_GPS` from `src/configuration_default.h:123-124`, which ours does not include); `lib_ignore` adds `ETHClass2`, `Ethernet`;
+  - `configuration.h`: `HAS_ETHERNET`, placeholder W5500 pins, the `neth` declaration;
+  - `partitions-qemu.csv`;
+  - **new `ETHClass2.h` (29 lines) + `EthernetUdp.h` (9): stand-ins** for the two W5500 libraries upstream's Ethernet path uses (`esp32/esp32_eth.h:5-6`, `:26`). `ETHClass2` maps `begin/linkUp/localIP/gatewayIP/subnetMask/dnsIP` to the OpenETH netif and refuses a static `config()`; `EthernetUDP` is an lwIP `WiFiUDP`. They are found first because the variant directory is on the include path.
+- **`src/qemu/`:**
+  - `qemu_network.h` and `qemu_external_radio_ready.cpp`, unchanged; `qemu_network.cpp` changes as §1.1 (link loss clears readiness);
+  - `qemu_eth_standin.cpp` (35, the stand-in bodies);
+  - `qemu_ethmode.cpp` (64): a strong `initVariant()` starts OpenETH before `setup()` and starts the hand-over task (§1.1); it defines `neth`.
+- **Comments:** every comment in these files describes stock behaviour; the hunk-guard, `QEMU_GPS`/GPSTEST and "absent password = open" sentences are rewritten (auditor F7).
+
+**`setup.sh`:** `DEFAULT_REF` = f2b3a3496a76f327abec8b7228bce436cafe9606 (the tag in the comment as a label).
+
+### 1.1 Address hand-over (W1 F4)
+- **The task** (every 100 ms):
+  - once OpenETH has an address, it opens `Udp` on **LOCAL_PORT 1990**, as the overlay did, and sets `hasIPaddress` only if `Udp.begin()` succeeded; a failure retries at the next pass with nothing published;
+  - only then it writes `node_ip/gw/subnet` and `node_hasIPaddress = true` when they differ;
+  - it prints `[QEMU]...ethmode: IP <a> reported (<ms>)` once per boot;
+  - **fail-closed invariant (round 3 F2):** `node_hasIPaddress` true ⇒ the OpenETH netif is ready. When the flag is true and `qemuNetworkReady()` is false, the task sets it false and prints `[QEMU]...ethmode: no address; readiness withdrawn` (once per occurrence). This covers upstream's DHCP-failure fallback, which sets the flag true unconditionally after `ETH.config()` (`esp32_eth.cpp:103-113`; the stand-in's `config()` returns false), the static-address path (`:37-58`), and a flag persisted from an earlier boot. **`qemu_network.cpp` change (round 4 F2):** today a link loss clears only the strict `s_got_ip_event` (`:49-53`, `:58-60`, `:80-83`) while `qemuNetworkReady()` reads `s_got_ip` (`:179-181`), so a lost link stayed ready. A2 clears `s_got_ip` and the stored address on DISCONNECTED, STOP and LOST_IP. On CONNECTED it restores `s_got_ip` only when the static user-network address was applied (`:154-175`; no DHCP event follows it); otherwise GOT_IP restores it. So `qemuNetworkReady()` is false before a start, after a link loss and after a lost lease (Appendix C). With the flag withdrawn, the loop's 5-minute path calls `initethDHCP()` again, whose `ETH.begin()` retries the driver start.
+- **Why it is needed:** M3. Before provisioning (Wi-Fi mode) the flag must be true at `setup()`'s `startNetwork()` (`esp32_main.cpp:2036-2040`), or stock code takes the Wi-Fi path. In the measured boots the address was reported at 220–1993 ms, before `CLIENT SETUP`.
+- **Residual:** an address later than `startNetwork()` on the provisioning boot panics → reboot → QEMU rc 0 without the provisioning ack → exit 3, no marker (fail-closed), retried at the next start.
+- **In Ethernet mode a later clear of the flag** (stock: `esp32/udp_drain_esp32.cpp:110-111`) is handled by upstream's own `initethDHCP()` on the stand-in (M4). It waits up to 50 × 200 ms for the address (`esp32_eth.cpp:69-77`), in loop context; no W5500 code exists in the build.
+- **Concurrency (R1):** the task writes the same `meshcom_settings` fields `initethDHCP()` writes, from a second task. A torn string read by a display or web page is possible and was not observed; no decision path reads `node_ip`.
+
+### 1.2 run.sh (same arguments): `-no-reboot`, supervisor, provisioning
+**Ownership (W1 F3):**
+- run.sh takes `flock` on `.run/run.lock` (one runner per checkout) and keeps the node-image lock for its lifetime, provisioning and restarts included;
+- it writes `.run/run.pid` (itself) and `.run/qemu.pid` (the current QEMU) atomically;
+- `stop.sh` signals a pid only if `/proc/<pid>/cmdline` names `scripts/run.sh` or `qemu-system-xtensa` with this checkout's paths; a stale or reused pid file is removed without a signal.
+
+**Stop:** TERM/INT latches STOP; STOP is checked before every QEMU launch and before the marker write. TERM to QEMU, wait 10 s, then KILL; exit 0.
+
+**After a QEMU exit:**
+- STOP → exit 0;
+- rc 0 without a signal (a guest reset under `-no-reboot`) → restart;
+- rc ≠ 0 → `[run] QEMU exited rc=<n>`, exit 5.
+
+**Restart limits (auditor F2):**
+- **fast reboot-loop guard:** 3 consecutive supervised runs shorter than 60 s → exit 75; a run of at least 60 s resets the count; provisioning is not counted;
+- **rolling budget:** more than 10 restarts within one hour → exit 75.
+
+Each restart prints `[run] guest reset after <s> s -> restart #<n>` and writes `.run/restarts` (`<n> <UTC>`).
+
+**Exit codes:** 0 stopped · 1 setup error (unchanged) · 2 usage · 3 provisioning failed · 5 QEMU error · 75 restart limit. `stop.sh` and `status.sh` stay rc 0, also when nothing runs and when `.run/restarts` is absent.
+
+**Logs (auditor F8):** run.sh deletes `.run/uart-latest.log` first; each supervised boot gets its own `uart-<UTC>.log` and the link moves to it at launch; provisioning writes only `uart-provision-<UTC>.log`.
+
+**Provisioning** (when `<node>.provisioned` is missing or names another command list):
+- QEMU runs in the foreground; after `CLIENT STARTED`, UART0 gets the stock commands `--setssid qemu0`, `--setpwd qemu0000` (placeholders; stock turns the web server off without credentials, `esp32_main.cpp:1153-1159`), `--webserver on`, `--netconsole on`, `--mesh off`, `--gateway off`, `--extudp off`, `--gps on` (`*gpsd` only), `--wifiap off`, `--netmode eth`;
+- **completion (fail-closed, auditor F1, W1 F1):**
+  - the run counts only if its UART shows the acknowledgement `[CMD] netmode -> Ethernet` (`command_functions.cpp:3738`; `save_settings()` follows at `:3741`, the 5 s reboot at `:3743`) **and** QEMU then exits rc 0;
+  - an rc 0 before that ack (an early reset, as M3) fails the run;
+  - **persisted-state check (round 3 F1):** the marker (`<UTC> <sha256 of the list>`, written to a temp file, then renamed) is committed only when the first supervised boot shows `[NET] Ethernet mode` and `Console started on port 2323`, **and** run.sh then:
+    - reads `--info` over the console (`/dev/tcp/127.0.0.1/12323`, the reply held in a shell variable, never written: it carries a password field) and finds `NETWORK Mode:ETH`, `...MESH off`, `...EXTUDP off` and `Gateway off`;
+    - gets HTTP 200 from `/` (`/dev/tcp/127.0.0.1/18083`);
+    - all within `PROVISION_TIMEOUT` (900 s); a mismatch or an unreachable console → exit 3, no marker.
+  - **Scope of the check (round 4 F1):** Ethernet mode, mesh, extudp, gateway, console, web server. Outside it: `--wifiap off` cannot be observed before the callsign (stock forces the AP flag on while the call is unset, `esp32_main.cpp:1124-1128`), so gate (j) verifies AP off and web 200 after the `--setcall` reboot. `--setssid`/`--setpwd` are inert in Ethernet mode (`startNetwork()` returns in its Ethernet branch before any Wi-Fi code, `udp_functions.cpp:601-611`); their one effect, keeping the web server on (`esp32_main.cpp:1153-1159`), is covered by the web check. `--gps on` has no `--info` token and is proven by test (d) only.
+  - The console needs no password on a fresh node, and the controller sets none. A node whose console asks for one cannot be verified → exit 3, with the message saying so.
+- `--info` is never sent over UART: the UART log is written to disk.
+- **`bGATEWAY_NOPOS`** (old hunk 1) is not provisioned: its only functional reader is `handleUdpFrame_esp32` (`udp_frame_esp32.cpp:269`), reached only through `getMeshComUDP()` under `bGATEWAY` (`gateway_service_esp32.cpp:20`).
+- **Before a callsign (W1 F2):** stock forces the AP flag on while the call is unset (`esp32_main.cpp:1124-1128`). In Ethernet mode that flag is inert and only keeps the web server on (M6). The controller's post-step sends `--setcall`; its stock reboot is one supervised restart, after which the AP flag is off (M6).
+- **Crash-safe marker:** `node-image.sh` deletes the marker before it renames a NODE that carries no settings.
+- **Migration:** an overlay-era node is provisioned once; only the listed settings change (a stored SSID becomes the inert placeholder); NVS is carried because the partition table is unchanged.
+
+## 2. Hunk → destination (bodies: packet Appendix A; excerpts: Appendix D)
+| # | old purpose | destination | covered by (f2b3a349) |
+|---|---|---|---|
+| 1 | runtime defaults | provisioning | the commands above (`command_functions.cpp:420-426`, 483, 2475, 2591, 3734, 3811); `bGATEWAY_NOPOS` inert (§1.2) |
+| 2 | skip `setupPMU()` | dropped | `esp32_pmu.cpp:26` opens it; 27–51 a comment; the body 52–338 under `#if defined(XPOWERS_CHIP_AXP192) \|\| defined(XPOWERS_CHIP_AXP2101)` |
+| 3 | skip button init | dropped | `[OBUT]...One Button GPIO(12) not activated` (11/11 boots) |
+| 4–5 | skip display init/splash | dropped | `[INIT]...Display not found` (11/11) |
+| 6 | radio "no backend" | dropped | XR: `esp32_main.cpp:1543-1548`; non-XR: M2 |
+| 7 | whitespace | dropped | unclassified |
+| 8–9 | Wi-Fi ping watchdog | dropped | `node_netmode == 0` only (`esp32_main.cpp:3199`) |
+| 10 | no `ESP.restart()` | run.sh | `-no-reboot` + supervisor (G4, M6) |
+| 11–12 | QEMU GPS init | dropped | `GPSprobe()` returns under `ENABLE_UBLOX` (`gps_functions.cpp:746-760`); 1500 ms per baud step (`:272-282`) |
+| 13 | GPSTEST + 256 B/loop bound | dropped | QEMU backpressures UART1 to the guest's read rate (M5); gate (i) |
+| 14 | declare `gps` | dropped | `ENABLE_GPS` in every env (M1) |
+| 15–16 | console readiness | dropped | `net_console.cpp:352-357` + §1.1 |
+| 17–19 | OpenETH network + socket | dropped → §1.1 | `udp_functions.cpp:601-611`; `Udp` stays on LOCAL_PORT. Readers with gateway off: `ntpHarvestUDP()` (`gateway_service_esp32.cpp:78-85` → `udp_functions.cpp:226-235`); NTP is inactive in both builds (`TimeClient no update possible`, 11/13 S5, 4/6 overlay logs) |
+| 20–22 | web start, no mDNS | dropped | `web_functions.cpp:215-222`; mDNS untested |
+| 23 | spectrum notice | dropped | stock page 200 (571 B, 10.2 s), web 200 afterwards |
+| — | `#pragma once` step | dropped | upstream line 5 since 6966c52 |
+
+**Tally:** 21 of 23 hunks dropped, hunk 1 → provisioning, hunk 10 → run.sh, the pragma step dropped. No QEMU device model.
+
+## 3. Tests (each gate with its failing control: W1 F6)
+**Quick (stubs, no QEMU, network-free):**
+- **`test-apply-overlay.sh`:** copy targets, idempotence, a modified tracked file → 4, a missing variant → 1.
+- **`test-run-supervisor.sh`** (stub QEMU recording argv/stdin; a stub pid process):
+  - rc 0 → restart; 3 fast → 75; a run ≥ 60 s resets the count; 11 restarts in an hour → 75; rc 1 → 5;
+  - TERM → stub TERMed, no restart; a stub ignoring TERM → KILL after 10 s; STOP between two runs → no launch;
+  - stale or reused `run.pid`/`qemu.pid` (a live unrelated process) → not signalled;
+  - a second run.sh on the same checkout → refused;
+  - provisioning: list on stdin, marker only after ack + rc 0 + the supervised lines; rc 0 without ack → 3; a stub console answering `MESH on` (or no answer) → 3, no marker; TERM during → no marker; timeout → 3;
+  - an old `uart-latest.log` is removed before provisioning;
+  - `stop.sh`/`status.sh` rc 0 with nothing running.
+- `test-node-image.sh`: adjusted; the marker is deleted before a fresh NODE is renamed.
+
+**Slow: `tests/test-boot-gates.sh`** (from `scripts/s5-gates.sh`; four builds; a fresh node; the bridge `--backend fake` with a test password behind `tests/xr-tap.py`, a frame tap logging direction, type and payload byte 0):
+
+| gate | asserts | failing control |
+|---|---|---|
+| a | 0 tracked MeshCom changes | one old hunk re-applied |
+| b | `ethmode: IP … reported` before `CLIENT SETUP` each boot; no `[ETH] init` outside (b′) | a build without `qemu_ethmode.cpp` (M3: the provisioning boot panics) |
+| b′ | slow case, a test build that clears the flag once: `[ETH] DHCP IP` follows, web 200 (M4) | the same build with the stand-in headers removed fails to compile |
+| c | web 200; console banner + `Client authenticated` | provisioning without `--netconsole on` |
+| c-xr | a node→bridge `TX_REQUEST` with payload byte 0 = `0x21` (position) after `--sendpos`; `CONFIG_RESULT` seen | the 45 s window before `--sendpos`: only `0x40` frames, PING/PONG (measured) |
+| d | `Display not found`; `UBLOX erkannt`; the fixture's fix seen (`--info` `SAT:` > 0); one `RESET_REASON` per boot | relay off → `SAT:` 0 |
+| e | `--reboot` → `[run] guest reset … restart #1`, web 200 | run.sh without `-no-reboot`: no restart line (the wedge itself is the old hunk 10's statement, not re-measured) |
+| f | `[NET];mtu;eth;1280`; a page > 1280 B ends `</html>` | provisioned `--mtu 1500` fails the 1280 line; the page check has no natural failing control (stated) |
+| g | `--info` extract `MESH off`, `EXTUDP off`, `Gateway off` (only those tokens kept) | provisioning without `--mesh off` (stock default ON, measured) |
+| h | spectrum page ≤ 60 s, then web 200 | none natural (stated) |
+| i | UART1 written unpaced for 90 s; web and console answer every 10 s | none natural (stated) |
+| j | fresh node → `--setcall` → one supervised restart → no `WIFIAP starting` in that boot, web 200, callsign kept | without the supervisor run.sh ends |
+| l | acquire, then QEMU monitor `set_link <nic> off` (run.sh adds `-monitor unix:.run/monitor.sock,server=on,wait=off`; the model reports it to the guest PHY, `hw/net/opencores_eth.c:338-345`): `readiness withdrawn` within 10 s; web and console from the host fail; `set_link on` → `reported` again and web 200 within 30 s | the same run without the `qemu_network.cpp` change: no withdrawal line, the flag stays true |
+| k | a test build that never starts OpenETH (`QEMU_TEST_NO_OPENETH`), Ethernet mode, a persisted flag true: `readiness withdrawn` within 200 ms of boot and of every `[ETH] DHCP failed` line; web and console unreachable from the host for 7 min; a fresh node in this build → provisioning exit 3, no marker | the same run with the invariant removed: the flag stays true after `DHCP failed` (`--info` cannot be read either way, so the control reads the UART) |
+
+**Where:**
+- x86_64 here: all.
+- **Exact-candidate aarch64 qualification (W1 F8):** before a pin promotion, lhpc-binaries build-binary meshcom on the candidate controller commit with `smoke_test=true` (`ubuntu-24.04-arm`) is the qualification run. `builders/smoke.sh:90-109` enforces the combined deadline: provisioning + the first supervised boot must reach the marker within 150 × 4 s, then web within 30 × (≤ 3 s + 2 s). If it fails, the window is changed in lhpc-binaries and qualified there before promotion.
+- `PROVISION_TIMEOUT` stays 900 s: lowering it is neither necessary nor sufficient (W1 note).
+- **The weekly job** (schedule + dispatch; one issue on failure naming the upstream sha and the gate; silent on pass; the README notes GitHub's 60-day pause) runs the slow test on `ubuntu-24.04-arm` against upstream `dev`. It is early warning, not qualification.
+
+## 4. Documentation
+**README** (≤ 120 lines):
+- what it is; one-command run;
+- **house rules:** pin by commit; our files only, zero MeshCom lines (enforced by apply-overlay.sh); the speed patch until espressif/qemu #183 is merged; no secrets in the tree; an empty `XR_PASSWORD` still builds `auth=password`;
+- **maintenance:** the five-command pin move (`setup.sh --ref`, `apply-overlay.sh`, `prepare-openeth.sh`, `build.sh` ×4, `tests/test-boot-gates.sh`); how failures show (compile, boot gate, bridge gate; a guide, not exclusive causes); a PlatformIO config change cleans every env's build; the weekly job and its pause;
+- "validated against <sha> on <date>, <host>".
+
+**STACK.md:** stale branch refs → the pinned commit.
+
+## 5. Interfaces (unchanged unless stated)
+| interface | used by | after A2 |
+|---|---|---|
+| manifest build steps `:1904` `setup.sh --src <url> --ref {pin}`, `:1905` `apply-overlay.sh`, `:1906` `prepare-openeth.sh`, `:1907` `build.sh --env qemu-headless-extradio-gpsd` | `lhpc build`; lhpc-binaries runs these steps | same; apply-overlay rc 0/1/4 |
+| `run.sh --env --qemu --node-image` (manifest `:1918`) | lhpc, smoke, test.sh | same arguments; §1.2 behaviour and codes |
+| `stop.sh`, `status.sh`, `test.sh --qemu` (manifest `:1928`) | smoke, operators | same CLI, rc 0 as today; status adds restarts; test.sh scans the S5 lines |
+| `.run/qemu.pid`, `.run/uart-latest.log` | smoke, test.sh | the current supervised QEMU / boot |
+| new: `.run/run.pid`, `.run/run.lock`, `.run/restarts`, `uart-provision-*.log`, `<node>.provisioned`, the restart line | status, operators | new |
+| `.pio/build/<env>/flash.bin` + `.lhpc-build-complete`, env names, node image + `.efuse`, `XR_*` env | manifest, artifact | unchanged |
+| host 127.0.0.1:12323 → guest 2323, 18083 → 80 (`run.sh:105`) | post-step `--setcall` (manifest `:1959-1962`, ≈ 13 min window), smoke | unchanged; a changed call = one supervised restart |
+
+**Controller pin move** (Track D, one commit): `src/meshcom-qemu-raspi` (`manifest.example.toml:1838`, `:2079`) → the A2 merge, and `src/MeshCom-Firmware` (`:2138`) → f2b3a349; then the aarch64 qualification above.
+
+## 6. Not covered → where
+The 0.12.10 live row: the loraham backend, RX into the node, live gpsd, the controller's first-console window on a Pi. The other three envs are built in the slow test; only the LHPC env boots.
+
+## 7. Risks, six points, guardrails
+**Risks:** R1 concurrency (§1.1); R2 a restart per auto-reboot setting; R3 an upstream command renamed or rejected → the persisted-state check fails → exit 3 for the settings in its scope; `--wifiap off` only by gate (j), `--gps on` only by test (d), the credentials inert; R4 an upstream gate change → the weekly job; R5 the stand-ins must keep the W5500 API upstream calls (a compile failure at the next pin move) **and** its semantics: upstream treats a returned `config()` as success. The invariant (§1.1) closes that, but an internal window of ≤ 100 ms between upstream's write and the withdrawal remains. In the no-netif case (gate k) it cannot be seen from the host, since nothing is reachable. After a link loss (gate l) the bound is the PHY poll plus 100 ms, and the host cannot reach the guest during the loss either; R6 the aarch64 window → the qualification run.
+
+**Six points:** (1) contracts §1.2/§5; (2) invariants (a), (b), the supervisor tests; (3) failure classes: the §3 quick list; (4) red-before per gate (§3 table; three gates have no natural control, stated); (5) `tests/*.sh` + shellcheck; (6) self-review: v3 folds 17 findings, four measured anew (M3–M6).
+
+**Guardrails:** no framework; the supervisor is a loop, provisioning one function, the stand-ins 73 lines in all. Lines that track upstream text: 469 → 0. Compile coupling instead: `meshcom_settings` fields, `hasIPaddress`, `Udp`, `LOCAL_PORT`, `EspETH`, the W5500 call signatures in `esp32_eth.cpp`, `initVariant`, `externalRadioNetworkReady`.
+
+## 8. Numbers, measured
+Table in the packet (Appendix B, with the command for each figure).
```
