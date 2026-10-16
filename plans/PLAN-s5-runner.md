# PLAN s5-runner (A2) v5: stock MeshCom in QEMU, our files only

**v5:** answers gate-1 round 4 (F1 the scope of the persisted-state check, F2 readiness on link loss); v4 answered round 3, v3 round 2 and W1, v2 the second read. Change tables: top of the gate packet.

Base: this repository's `main` c2335d12.

Proof: the prototype `cons/s5-proto` (f6a39c04, b1babc7f, **6641a6f5** = this design's network part). It ran stock MeshCom f2b3a349 with 0 tracked MeshCom files changed (x86_64 Linux host, 2026-10-15). Measured for the design (Appendix B):
- **(M1) without old hunk 14 the two non-GPS envs fail to compile** (`'gps' was not declared`, `src/loop_functions.cpp:3015`, `:5971`); with `ENABLE_GPS` they compile.
- **(M2) with no radio chip,** stock `radio.begin()` → `failed, code -2`, then `CLIENT STARTED`.
- **(M3) a fresh node in Wi-Fi mode** with `node_hasIPaddress` false at `startNetwork()` makes stock code start the Wi-Fi PHY, which panics under QEMU (`register_chipv7_phy`).
- **(M4) a flag clear in Ethernet mode** reaches upstream's `neth.initethDHCP()` through the loop's 5-minute path; with the stand-in it reports the OpenETH address, and web stayed 200 throughout (6.5 min).
- **(M5) unpaced UART1 input** is backpressured by QEMU to 671 B/s; web answered 200 in 0.28–0.43 s and the console at every 10 s probe (80 s).
- **(M6) the fresh-node path:** provisioning → before a callsign, the AP flag is forced on but inert (web 200, read-back mesh/extudp/gateway off) → `--setcall` acknowledged → the stock reboot ends QEMU rc 0 13 s later → the restart has no AP, keeps the callsign and the settings.

**Rule:** zero lines changed in any MeshCom file; MeshCom pinned by **commit**, a tag is a label (upstream moved `v4.40a.hbserver` from 8770f9b5 to f2b3a349 on 2026-10-13).

## 1. Target layout
**Removed:** `overlay/patches/` (the 469-line patch); the patch check and the `#pragma once` step in `apply-overlay.sh` (upstream has it at `src/configuration_global.h:5`); the old `tests/test-apply-overlay.sh`; the `ETHClass2` and `Ethernet` library downloads.

**Same names** (§5): `scripts/apply-overlay.sh` = copy our files, then `git -C .work/MeshCom-Firmware status --porcelain --untracked-files=no` must be empty, else rc 4. A missing file is rc 1.

**Our files** (`overlay/` → the stock tree; the variant is loaded by upstream `platformio.ini:13-14`, `extra_configs = variants/*/platformio.ini`):
- **`variants/qemu-headless/`:**
  - `platformio.ini`: four envs, each with `ENABLE_GPS` + `ENABLE_UBLOX` + GPS pins (M1; upstream variants get `ENABLE_GPS` from `src/configuration_default.h:123-124`, which ours does not include); `lib_ignore` adds `ETHClass2`, `Ethernet`;
  - `configuration.h`: `HAS_ETHERNET`, placeholder W5500 pins, the `neth` declaration;
  - `partitions-qemu.csv`;
  - **new `ETHClass2.h` (29 lines) + `EthernetUdp.h` (9): stand-ins** for the two W5500 libraries upstream's Ethernet path uses (`esp32/esp32_eth.h:5-6`, `:26`). `ETHClass2` maps `begin/linkUp/localIP/gatewayIP/subnetMask/dnsIP` to the OpenETH netif and refuses a static `config()`; `EthernetUDP` is an lwIP `WiFiUDP`. They are found first because the variant directory is on the include path.
- **`src/qemu/`:**
  - `qemu_network.h` and `qemu_external_radio_ready.cpp`, unchanged; `qemu_network.cpp` changes as §1.1 (link loss clears readiness);
  - `qemu_eth_standin.cpp` (35, the stand-in bodies);
  - `qemu_ethmode.cpp` (64): a strong `initVariant()` starts OpenETH before `setup()` and starts the hand-over task (§1.1); it defines `neth`.
- **Comments:** every comment in these files describes stock behaviour; the hunk-guard, `QEMU_GPS`/GPSTEST and "absent password = open" sentences are rewritten (auditor F7).

**`setup.sh`:** `DEFAULT_REF` = f2b3a3496a76f327abec8b7228bce436cafe9606 (the tag in the comment as a label).

### 1.1 Address hand-over (W1 F4)
- **The task** (every 100 ms):
  - once OpenETH has an address, it opens `Udp` on **LOCAL_PORT 1990**, as the overlay did, and sets `hasIPaddress` only if `Udp.begin()` succeeded; a failure retries at the next pass with nothing published;
  - only then it writes `node_ip/gw/subnet` and `node_hasIPaddress = true` when they differ;
  - it prints `[QEMU]...ethmode: IP <a> reported (<ms>)` once per boot;
  - **fail-closed invariant (round 3 F2):** `node_hasIPaddress` true ⇒ the OpenETH netif is ready. When the flag is true and `qemuNetworkReady()` is false, the task sets it false and prints `[QEMU]...ethmode: no address; readiness withdrawn` (once per occurrence). This covers upstream's DHCP-failure fallback, which sets the flag true unconditionally after `ETH.config()` (`esp32_eth.cpp:103-113`; the stand-in's `config()` returns false), the static-address path (`:37-58`), and a flag persisted from an earlier boot. **`qemu_network.cpp` change (round 4 F2):** today a link loss clears only the strict `s_got_ip_event` (`:49-53`, `:58-60`, `:80-83`) while `qemuNetworkReady()` reads `s_got_ip` (`:179-181`), so a lost link stayed ready. A2 clears `s_got_ip` and the stored address on DISCONNECTED, STOP and LOST_IP. On CONNECTED it restores `s_got_ip` only when the static user-network address was applied (`:154-175`; no DHCP event follows it); otherwise GOT_IP restores it. So `qemuNetworkReady()` is false before a start, after a link loss and after a lost lease (Appendix C). With the flag withdrawn, the loop's 5-minute path calls `initethDHCP()` again, whose `ETH.begin()` retries the driver start.
- **Why it is needed:** M3. Before provisioning (Wi-Fi mode) the flag must be true at `setup()`'s `startNetwork()` (`esp32_main.cpp:2036-2040`), or stock code takes the Wi-Fi path. In the measured boots the address was reported at 220–1993 ms, before `CLIENT SETUP`.
- **Residual:** an address later than `startNetwork()` on the provisioning boot panics → reboot → QEMU rc 0 without the provisioning ack → exit 3, no marker (fail-closed), retried at the next start.
- **In Ethernet mode a later clear of the flag** (stock: `esp32/udp_drain_esp32.cpp:110-111`) is handled by upstream's own `initethDHCP()` on the stand-in (M4). It waits up to 50 × 200 ms for the address (`esp32_eth.cpp:69-77`), in loop context; no W5500 code exists in the build.
- **Concurrency (R1):** the task writes the same `meshcom_settings` fields `initethDHCP()` writes, from a second task. A torn string read by a display or web page is possible and was not observed; no decision path reads `node_ip`.

### 1.2 run.sh (same arguments): `-no-reboot`, supervisor, provisioning
**Ownership (W1 F3):**
- run.sh takes `flock` on `.run/run.lock` (one runner per checkout) and keeps the node-image lock for its lifetime, provisioning and restarts included;
- it writes `.run/run.pid` (itself) and `.run/qemu.pid` (the current QEMU) atomically;
- `stop.sh` signals a pid only if `/proc/<pid>/cmdline` names `scripts/run.sh` or `qemu-system-xtensa` with this checkout's paths; a stale or reused pid file is removed without a signal.

**Stop:** TERM/INT latches STOP; STOP is checked before every QEMU launch and before the marker write. TERM to QEMU, wait 10 s, then KILL; exit 0.

**After a QEMU exit:**
- STOP → exit 0;
- rc 0 without a signal (a guest reset under `-no-reboot`) → restart;
- rc ≠ 0 → `[run] QEMU exited rc=<n>`, exit 5.

**Restart limits (auditor F2):**
- **fast reboot-loop guard:** 3 consecutive supervised runs shorter than 60 s → exit 75; a run of at least 60 s resets the count; provisioning is not counted;
- **rolling budget:** more than 10 restarts within one hour → exit 75.

Each restart prints `[run] guest reset after <s> s -> restart #<n>` and writes `.run/restarts` (`<n> <UTC>`).

**Exit codes:** 0 stopped · 1 setup error (unchanged) · 2 usage · 3 provisioning failed · 5 QEMU error · 75 restart limit. `stop.sh` and `status.sh` stay rc 0, also when nothing runs and when `.run/restarts` is absent.

**Logs (auditor F8):** run.sh deletes `.run/uart-latest.log` first; each supervised boot gets its own `uart-<UTC>.log` and the link moves to it at launch; provisioning writes only `uart-provision-<UTC>.log`.

**Provisioning** (when `<node>.provisioned` is missing or names another command list):
- QEMU runs in the foreground; after `CLIENT STARTED`, UART0 gets the stock commands `--setssid qemu0`, `--setpwd qemu0000` (placeholders; stock turns the web server off without credentials, `esp32_main.cpp:1153-1159`), `--webserver on`, `--netconsole on`, `--mesh off`, `--gateway off`, `--extudp off`, `--gps on` (`*gpsd` only), `--wifiap off`, `--netmode eth`;
- **completion (fail-closed, auditor F1, W1 F1):**
  - the run counts only if its UART shows the acknowledgement `[CMD] netmode -> Ethernet` (`command_functions.cpp:3738`; `save_settings()` follows at `:3741`, the 5 s reboot at `:3743`) **and** QEMU then exits rc 0;
  - an rc 0 before that ack (an early reset, as M3) fails the run;
  - **persisted-state check (round 3 F1):** the marker (`<UTC> <sha256 of the list>`, written to a temp file, then renamed) is committed only when the first supervised boot shows `[NET] Ethernet mode` and `Console started on port 2323`, **and** run.sh then:
    - reads `--info` over the console (`/dev/tcp/127.0.0.1/12323`, the reply held in a shell variable, never written: it carries a password field) and finds `NETWORK Mode:ETH`, `...MESH off`, `...EXTUDP off` and `Gateway off`;
    - gets HTTP 200 from `/` (`/dev/tcp/127.0.0.1/18083`);
    - all within `PROVISION_TIMEOUT` (900 s); a mismatch or an unreachable console → exit 3, no marker.
  - **Scope of the check (round 4 F1):** Ethernet mode, mesh, extudp, gateway, console, web server. Outside it: `--wifiap off` cannot be observed before the callsign (stock forces the AP flag on while the call is unset, `esp32_main.cpp:1124-1128`), so gate (j) verifies AP off and web 200 after the `--setcall` reboot. `--setssid`/`--setpwd` are inert in Ethernet mode (`startNetwork()` returns in its Ethernet branch before any Wi-Fi code, `udp_functions.cpp:601-611`); their one effect, keeping the web server on (`esp32_main.cpp:1153-1159`), is covered by the web check. `--gps on` has no `--info` token and is proven by test (d) only.
  - The console needs no password on a fresh node, and the controller sets none. A node whose console asks for one cannot be verified → exit 3, with the message saying so.
- `--info` is never sent over UART: the UART log is written to disk.
- **`bGATEWAY_NOPOS`** (old hunk 1) is not provisioned: its only functional reader is `handleUdpFrame_esp32` (`udp_frame_esp32.cpp:269`), reached only through `getMeshComUDP()` under `bGATEWAY` (`gateway_service_esp32.cpp:20`).
- **Before a callsign (W1 F2):** stock forces the AP flag on while the call is unset (`esp32_main.cpp:1124-1128`). In Ethernet mode that flag is inert and only keeps the web server on (M6). The controller's post-step sends `--setcall`; its stock reboot is one supervised restart, after which the AP flag is off (M6).
- **Crash-safe marker:** `node-image.sh` deletes the marker before it renames a NODE that carries no settings.
- **Migration:** an overlay-era node is provisioned once; only the listed settings change (a stored SSID becomes the inert placeholder); NVS is carried because the partition table is unchanged.

## 2. Hunk → destination (bodies: packet Appendix A; excerpts: Appendix D)
| # | old purpose | destination | covered by (f2b3a349) |
|---|---|---|---|
| 1 | runtime defaults | provisioning | the commands above (`command_functions.cpp:420-426`, 483, 2475, 2591, 3734, 3811); `bGATEWAY_NOPOS` inert (§1.2) |
| 2 | skip `setupPMU()` | dropped | `esp32_pmu.cpp:26` opens it; 27–51 a comment; the body 52–338 under `#if defined(XPOWERS_CHIP_AXP192) \|\| defined(XPOWERS_CHIP_AXP2101)` |
| 3 | skip button init | dropped | `[OBUT]...One Button GPIO(12) not activated` (11/11 boots) |
| 4–5 | skip display init/splash | dropped | `[INIT]...Display not found` (11/11) |
| 6 | radio "no backend" | dropped | XR: `esp32_main.cpp:1543-1548`; non-XR: M2 |
| 7 | whitespace | dropped | unclassified |
| 8–9 | Wi-Fi ping watchdog | dropped | `node_netmode == 0` only (`esp32_main.cpp:3199`) |
| 10 | no `ESP.restart()` | run.sh | `-no-reboot` + supervisor (G4, M6) |
| 11–12 | QEMU GPS init | dropped | `GPSprobe()` returns under `ENABLE_UBLOX` (`gps_functions.cpp:746-760`); 1500 ms per baud step (`:272-282`) |
| 13 | GPSTEST + 256 B/loop bound | dropped | QEMU backpressures UART1 to the guest's read rate (M5); gate (i) |
| 14 | declare `gps` | dropped | `ENABLE_GPS` in every env (M1) |
| 15–16 | console readiness | dropped | `net_console.cpp:352-357` + §1.1 |
| 17–19 | OpenETH network + socket | dropped → §1.1 | `udp_functions.cpp:601-611`; `Udp` stays on LOCAL_PORT. Readers with gateway off: `ntpHarvestUDP()` (`gateway_service_esp32.cpp:78-85` → `udp_functions.cpp:226-235`); NTP is inactive in both builds (`TimeClient no update possible`, 11/13 S5, 4/6 overlay logs) |
| 20–22 | web start, no mDNS | dropped | `web_functions.cpp:215-222`; mDNS untested |
| 23 | spectrum notice | dropped | stock page 200 (571 B, 10.2 s), web 200 afterwards |
| — | `#pragma once` step | dropped | upstream line 5 since 6966c52 |

**Tally:** 21 of 23 hunks dropped, hunk 1 → provisioning, hunk 10 → run.sh, the pragma step dropped. No QEMU device model.

## 3. Tests (each gate with its failing control: W1 F6)
**Quick (stubs, no QEMU, network-free):**
- **`test-apply-overlay.sh`:** copy targets, idempotence, a modified tracked file → 4, a missing variant → 1.
- **`test-run-supervisor.sh`** (stub QEMU recording argv/stdin; a stub pid process):
  - rc 0 → restart; 3 fast → 75; a run ≥ 60 s resets the count; 11 restarts in an hour → 75; rc 1 → 5;
  - TERM → stub TERMed, no restart; a stub ignoring TERM → KILL after 10 s; STOP between two runs → no launch;
  - stale or reused `run.pid`/`qemu.pid` (a live unrelated process) → not signalled;
  - a second run.sh on the same checkout → refused;
  - provisioning: list on stdin, marker only after ack + rc 0 + the supervised lines; rc 0 without ack → 3; a stub console answering `MESH on` (or no answer) → 3, no marker; TERM during → no marker; timeout → 3;
  - an old `uart-latest.log` is removed before provisioning;
  - `stop.sh`/`status.sh` rc 0 with nothing running.
- `test-node-image.sh`: adjusted; the marker is deleted before a fresh NODE is renamed.

**Slow: `tests/test-boot-gates.sh`** (from `scripts/s5-gates.sh`; four builds; a fresh node; the bridge `--backend fake` with a test password behind `tests/xr-tap.py`, a frame tap logging direction, type and payload byte 0):

| gate | asserts | failing control |
|---|---|---|
| a | 0 tracked MeshCom changes | one old hunk re-applied |
| b | `ethmode: IP … reported` before `CLIENT SETUP` each boot; no `[ETH] init` outside (b′) | a build without `qemu_ethmode.cpp` (M3: the provisioning boot panics) |
| b′ | slow case, a test build that clears the flag once: `[ETH] DHCP IP` follows, web 200 (M4) | the same build with the stand-in headers removed fails to compile |
| c | web 200; console banner + `Client authenticated` | provisioning without `--netconsole on` |
| c-xr | a node→bridge `TX_REQUEST` with payload byte 0 = `0x21` (position) after `--sendpos`; `CONFIG_RESULT` seen | the 45 s window before `--sendpos`: only `0x40` frames, PING/PONG (measured) |
| d | `Display not found`; `UBLOX erkannt`; the fixture's fix seen (`--info` `SAT:` > 0); one `RESET_REASON` per boot | relay off → `SAT:` 0 |
| e | `--reboot` → `[run] guest reset … restart #1`, web 200 | run.sh without `-no-reboot`: no restart line (the wedge itself is the old hunk 10's statement, not re-measured) |
| f | `[NET];mtu;eth;1280`; a page > 1280 B ends `</html>` | provisioned `--mtu 1500` fails the 1280 line; the page check has no natural failing control (stated) |
| g | `--info` extract `MESH off`, `EXTUDP off`, `Gateway off` (only those tokens kept) | provisioning without `--mesh off` (stock default ON, measured) |
| h | spectrum page ≤ 60 s, then web 200 | none natural (stated) |
| i | UART1 written unpaced for 90 s; web and console answer every 10 s | none natural (stated) |
| j | fresh node → `--setcall` → one supervised restart → no `WIFIAP starting` in that boot, web 200, callsign kept | without the supervisor run.sh ends |
| l | acquire, then QEMU monitor `set_link <nic> off` (run.sh adds `-monitor unix:.run/monitor.sock,server=on,wait=off`; the model reports it to the guest PHY, `hw/net/opencores_eth.c:338-345`): `readiness withdrawn` within 10 s; web and console from the host fail; `set_link on` → `reported` again within 30 s, then web 200 within a further 60 s (v4: aligned with the code) | the same run without the `qemu_network.cpp` change: no withdrawal line, the flag stays true |
| k | a test build that never starts OpenETH (`QEMU_TEST_NO_OPENETH`), Ethernet mode, a persisted flag true: `readiness withdrawn` within 200 ms of boot and of every `[ETH] DHCP failed` line; web and console unreachable from the host for 7 min; a fresh node in this build → provisioning exit 3, no marker | the same run with the invariant removed: the flag stays true after `DHCP failed` (`--info` cannot be read either way, so the control reads the UART) |

**Where:**
- x86_64 here: all.
- **Exact-candidate aarch64 qualification (W1 F8):** before a pin promotion, lhpc-binaries build-binary meshcom on the candidate controller commit with `smoke_test=true` (`ubuntu-24.04-arm`) is the qualification run. `builders/smoke.sh:90-109` enforces the combined deadline: provisioning + the first supervised boot must reach the marker within 150 × 4 s, then web within 30 × (≤ 3 s + 2 s). If it fails, the window is changed in lhpc-binaries and qualified there before promotion.
- `PROVISION_TIMEOUT` stays 900 s: lowering it is neither necessary nor sufficient (W1 note).
- **The weekly job** (schedule + dispatch; one issue on failure naming the upstream sha and the gate; silent on pass; the README notes GitHub's 60-day pause) runs the slow test on `ubuntu-24.04-arm` against upstream `dev`. It is early warning, not qualification.

## 4. Documentation
**README** (≤ 120 lines):
- what it is; one-command run;
- **house rules:** pin by commit; our files only, zero MeshCom lines (enforced by apply-overlay.sh); the speed patch until espressif/qemu #183 is merged; no secrets in the tree; an empty `XR_PASSWORD` still builds `auth=password`;
- **maintenance:** the five-command pin move (`setup.sh --ref`, `apply-overlay.sh`, `prepare-openeth.sh`, `build.sh` ×4, `tests/test-boot-gates.sh`); how failures show (compile, boot gate, bridge gate; a guide, not exclusive causes); a PlatformIO config change cleans every env's build; the weekly job and its pause;
- "validated against <sha> on <date>, <host>".

**STACK.md:** stale branch refs → the pinned commit.

## 5. Interfaces (unchanged unless stated)
| interface | used by | after A2 |
|---|---|---|
| manifest build steps `:1904` `setup.sh --src <url> --ref {pin}`, `:1905` `apply-overlay.sh`, `:1906` `prepare-openeth.sh`, `:1907` `build.sh --env qemu-headless-extradio-gpsd` | `lhpc build`; lhpc-binaries runs these steps | same; apply-overlay rc 0/1/4 |
| `run.sh --env --qemu --node-image` (manifest `:1918`) | lhpc, smoke, test.sh | same arguments; §1.2 behaviour and codes |
| `stop.sh`, `status.sh`, `test.sh --qemu` (manifest `:1928`) | smoke, operators | same CLI, rc 0 as today; status adds restarts; test.sh scans the S5 lines |
| `.run/qemu.pid`, `.run/uart-latest.log` | smoke, test.sh | the current supervised QEMU / boot |
| new: `.run/run.pid`, `.run/run.lock`, `.run/restarts`, `uart-provision-*.log`, `<node>.provisioned`, the restart line | status, operators | new |
| `.pio/build/<env>/flash.bin` + `.lhpc-build-complete`, env names, node image + `.efuse`, `XR_*` env | manifest, artifact | unchanged |
| host 127.0.0.1:12323 → guest 2323, 18083 → 80 (`run.sh:105`) | post-step `--setcall` (manifest `:1959-1962`, ≈ 13 min window), smoke | unchanged; a changed call = one supervised restart |

**Controller pin move** (Track D, one commit): `src/meshcom-qemu-raspi` (`manifest.example.toml:1838`, `:2079`) → the A2 merge, and `src/MeshCom-Firmware` (`:2138`) → f2b3a349; then the aarch64 qualification above.

## 6. Not covered → where
The 0.12.10 live row: the loraham backend, RX into the node, live gpsd, the controller's first-console window on a Pi. The other three envs are built in the slow test; only the LHPC env boots.

## 7. Risks, six points, guardrails
**Risks:** R1 concurrency (§1.1); R2 a restart per auto-reboot setting; R3 an upstream command renamed or rejected → the persisted-state check fails → exit 3 for the settings in its scope; `--wifiap off` only by gate (j), `--gps on` only by test (d), the credentials inert; R4 an upstream gate change → the weekly job; R5 the stand-ins must keep the W5500 API upstream calls (a compile failure at the next pin move) **and** its semantics: upstream treats a returned `config()` as success. The invariant (§1.1) closes that, but an internal window of ≤ 100 ms between upstream's write and the withdrawal remains. In the no-netif case (gate k) it cannot be seen from the host, since nothing is reachable. After a link loss (gate l) the bound is the PHY poll plus 100 ms, and the host cannot reach the guest during the loss either; R6 the aarch64 window → the qualification run.

**Six points:** (1) contracts §1.2/§5; (2) invariants (a), (b), the supervisor tests; (3) failure classes: the §3 quick list; (4) red-before per gate (§3 table; three gates have no natural control, stated); (5) `tests/*.sh` + shellcheck; (6) self-review: v3 folds 17 findings, four measured anew (M3–M6).

**Guardrails:** no framework; the supervisor is a loop, provisioning one function, the stand-ins 73 lines in all. Lines that track upstream text: 469 → 0. Compile coupling instead: `meshcom_settings` fields, `hasIPaddress`, `Udp`, `LOCAL_PORT`, `EspETH`, the W5500 call signatures in `esp32_eth.cpp`, `initVariant`, `externalRadioNetworkReady`.

## 8. Numbers, measured
Table in the packet (Appendix B, with the command for each figure).
