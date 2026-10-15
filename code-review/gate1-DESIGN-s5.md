# Gate 1 round 5, DESIGN v5: s5 runner (stock MeshCom in QEMU, no firmware patch)

**Request.** Please judge design v5. It changes only the two points of your round-4 verdict (change table v4 → v5 first; the earlier tables are kept for reference): the stated scope of the persisted-state check and gate (j) (§1.2, §3), and readiness on link loss with gate (l) (§1.1, §3, `qemu_network.cpp` in Appendix C, the QEMU model excerpt in Appendix D). Check that both close their finding and that nothing else regressed. A FINDING needs the plan line and the smallest fix.

This file and its second file `gate1-DESIGN-s5-appendix-C.md` are your whole input: you have no repository access; use no connector, tool or web lookup.

**Answer form:** `| item | verdict (OK / FINDING) | what |`: one row per change-table line, one per plan section, one per §2 row; then the findings; then GREEN / GREEN WITH NOTES / RED.

**Redaction classes (only these, to the exact tokens, in prose, logs and code):**
- QEMU user-network addresses → `<guest-addr>`/`<host-addr>` (loopback kept);
- upstream credit call signs → `XX1XXX`;
- the test callsign and its short form → `<testcall>`/`<short>`, and the frame-tap payload shown as byte 0 only (the rest carries the test callsign);
- the checkout path → `<checkout>`;
- `qemu0`/`qemu0000` are placeholders; the test password appears nowhere.

**Change table v4 → v5.** Gate 1 round 4: two findings; nothing else changed.

| finding | v4 problem | v5 answer | where |
|---|---|---|---|
| R4-F1 | the marker check claimed fail-closed coverage it did not have (AP off, credentials) | the scope is stated: Ethernet mode, mesh, extudp, gateway, console, web. `--wifiap off` is verified by gate (j) after the `--setcall` reboot (no `WIFIAP starting`, web 200); the credentials are inert in Ethernet mode (reason + line) and covered only through the web check; `--gps on` by test (d); R3 narrowed | §1.2; gate (j); §7 R3 |
| R4-F2 | "flag ⇒ OpenETH ready" not enforced: a link loss cleared only `s_got_ip_event` | `qemu_network.cpp` clears `s_got_ip` + the stored address on DISCONNECTED/STOP/LOST_IP and restores it on CONNECTED only for the static address (otherwise via GOT_IP); new gate (l): QEMU monitor `set_link off/on` (the model reports it to the guest PHY), withdrawal ≤ 10 s, host access fails, recovery ≤ 30 s; R5's "not visible from the host" limited to the no-netif case | §1.1; §3 gate (l); §7 R5 |

**Change table v3 → v4.** Gate 1 round 3: two findings; nothing else changed.

| finding | v3 problem | v4 answer | where |
|---|---|---|---|
| R3-F1 | only the final command acknowledged; earlier commands unverified | before the marker, run.sh reads `--info` over the console of the first supervised boot (held in memory, never written) and requires `NETWORK Mode:ETH`, `MESH off`, `EXTUDP off`, `Gateway off`, plus web 200; mismatch or no console → exit 3, no marker; `--gps on` only by test (d); R3 narrowed | §1.2; quick test; §7 R3 |
| R3-F2 | upstream's DHCP-failure fallback sets the flag true after the stand-in's `config()` fails | invariant in the hand-over task: flag true ⇒ OpenETH ready, else withdrawn and logged; the loop's 5-min path retries the driver start; gate (k) with OpenETH withheld; R5 names the semantic coupling and the ≤ 100 ms internal window | §1.1; §3 gate k; §7 R5 |

**Change table v2 → v3.** Gate 1 round 2 (auditor 2: F1–F9) and gate 2 (W1: F1–F8). Overlaps are folded.

| finding | v2 problem | v3 answer | where |
|---|---|---|---|
| A-F1 / W-F1 | marker on QEMU rc 0 alone | ack `[CMD] netmode -> Ethernet` + rc 0, then the supervised boot's lines before the marker; an early rc 0 fails; atomic marker; deleted before a fresh NODE | §1.2; test list |
| A-F2 | only fast resets bounded | named a fast reboot-loop guard (reset after ≥ 60 s, provisioning excluded) + a rolling budget (> 10/h) | §1.2 |
| A-F3 / W-F2 (NOPOS) | `bGATEWAY_NOPOS` unmatched | inert with gateway off: sole functional reader `udp_frame_esp32.cpp:269`, reached only under `bGATEWAY` | §1.2; App. D |
| A-F4 / W-F7 (PMU) | guard not quoted | `esp32_pmu.cpp:26`, the comment 27–51, the body 52–338 under the XPOWERS `#if`, quoted | §2; App. D |
| A-F5 / W-F5 | GPS bound dropped untested | M5: unpaced UART1 input is backpressured to 671 B/s, web/console responsive; gate (i) | §2; App. B |
| A-F6 / W-F7 (reader) | port change, "only reader" | port KEPT at LOCAL_PORT; reader inventory incl. `ntpHarvestUDP()`; NTP inactive in both builds | §1.1; §2 row 17–19 |
| A-F7 | stale source comments | comment rewrite in A2 scope | §1 |
| A-F8 / W-F3 (log) | stale `uart-latest.log` | deleted first; linked per supervised boot; provisioning logs separately | §1.2 |
| A-F9 | web "≤ 60 s" | real contract: 30 × (≤ 3 s + 2 s) ≤ 150 s | §3 |
| W-F2 | pre-callsign AP state | defined + measured end to end (M6) | §1.2; gate (j) |
| W-F3 | ownership, races, shutdown | `.run/run.lock`, identity-checked pids, latched STOP, TERM → 10 s → KILL, rc 0 for stop/status stated | §1.2; tests |
| W-F4 | hand-over invariant | flag only after `Udp.begin()` succeeds; a W5500-path entry runs upstream's `initethDHCP()` on the ETHClass2/EthernetUDP stand-ins (M4); why the task stays (M3); residual stated | §1.1 |
| W-F6 | no red-before per gate; XR ambiguous | a failing control per gate (three stated as none natural); XR = a frame tap: TX_REQUEST payload byte 0 `0x21` after `--sendpos`, none in the control window | §3 |
| W-F8 | weekly arm ≠ qualification | the exact-candidate lhpc-binaries smoke run on aarch64 is the qualification, with smoke's combined deadline | §3 |
| W notes | stop/status rc; 900 vs 600 s | rc 0 stated; 900 s kept, qualification end to end | §1.2; §3 |

**Design change in v3 (measured):** two stand-in headers replace the external `ETHClass2`/`Ethernet` libraries (prototype 6641a6f5). The hand-over task stays, with fixed semantics.

---

## The plan (verbatim)

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
  - `qemu_network.{cpp,h}` and `qemu_external_radio_ready.cpp`, unchanged;
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
| l | acquire, then QEMU monitor `set_link <nic> off` (run.sh adds `-monitor unix:.run/monitor.sock,server=on,wait=off`; the model reports it to the guest PHY, `hw/net/opencores_eth.c:338-345`): `readiness withdrawn` within 10 s; web and console from the host fail; `set_link on` → `reported` again and web 200 within 30 s | the same run without the `qemu_network.cpp` change: no withdrawal line, the flag stays true |
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

---

## Appendix A — the 23 old hunks (`overlay/patches/meshcom-qemu-headless.patch` at main c2335d12)

Verbatim check (run while building this file): the concatenation of the 23 hunks equals the patch minus its `diff --git`/`index`/`---`/`+++` lines. Result: identical, then the redaction above.

### Hunk 1 — `src/esp32/esp32_main.cpp`

```diff
@@ -1023,7 +1023,30 @@ void esp32setup()
         if(!bWIFIAP)
             bWEBSERVER=false;
     }
-       
+
+    #ifdef QEMU_HEADLESS
+        // QEMU-only safe defaults (runtime overrides, NOT persisted): the target
+        // must start the web UI and net-console over OpenETH without any Wi-Fi
+        // configuration, AP, or Internet gateway/UDP traffic.
+        bWIFIAP        = false;   // no Wi-Fi AP / no Wi-Fi emulation
+        bWEBSERVER     = true;    // existing MeshCom web UI enabled
+        bNETCONSOLE    = true;    // existing MeshCom net-console enabled
+        bGATEWAY       = false;   // no Internet gateway
+        bGATEWAY_NOPOS = false;
+        bEXTUDP        = false;   // no external UDP
+        bMESH          = false;   // no mesh radio activity (radio is disabled in QEMU)
+        printlndeb("[QEMU]...headless defaults: web+console ON, wifiAP/gateway/extudp OFF");
+        #ifdef QEMU_GPS
+        // QEMU virtual GPS profiles: enable the "GPS on" user setting so the real
+        // MeshCom GPS receive path runs under emulation (NMEA arrives on UART1). This
+        // is configuration (the bGPSON flag), NOT a fabricated fix — the fix/position
+        // still come only from parsed NMEA. Compiled in ONLY for the …-gpsd targets.
+        bGPSON = true;
+        printlndeb("[QEMU]...virtual GPS enabled (bGPSON=true); NMEA expected on UART1");
+        #endif
+    #endif
+
+
     if(bBMPON)
     {
         bBMEON=false;
```

### Hunk 2 — `src/esp32/esp32_main.cpp`

```diff
@@ -1180,8 +1203,10 @@ void esp32setup()
     #else
 
         #if !defined(BOARD_T_DECK_PRO) && !defined(BOARD_T5_EPAPER)
+        #ifndef QEMU_HEADLESS
             setupPMU();
         #endif
+        #endif
 
     #endif
 
```

### Hunk 3 — `src/esp32/esp32_main.cpp`

```diff
@@ -1244,7 +1269,9 @@ void esp32setup()
     }
     #endif
 
+    #ifndef QEMU_HEADLESS
     init_onebutton();
+    #endif
 
     printfdeb("[INIT].._GW_ID: %08X\n", _GW_ID);
 
```

### Hunk 4 — `src/esp32/esp32_main.cpp`

```diff
@@ -1285,7 +1312,9 @@ void esp32setup()
     #elif defined(HAS_TFT)
         initTFT();
     #else
+        #ifndef QEMU_HEADLESS
         initDisplay();
+        #endif
     #endif
 
     #if defined(BOARD_HELTEC_V3) || defined(BOARD_STICK_V3)
```

### Hunk 5 — `src/esp32/esp32_main.cpp`

```diff
@@ -1302,7 +1331,9 @@ void esp32setup()
         String  version = cvers;
         displayTFT("MeshCom 4.0", version, "@BY ICSSW.ORG", "XX1XXX, XX1XXX",  "...starting now", 5000);
     #else
+        #ifndef QEMU_HEADLESS
         startDisplay((char*)"...starting now", (char*)"@BY ICSSW.ORG", (char*)"XX1XXX, XX1XXX");
+        #endif
     #endif
 
     //LORA CHIP present
```

### Hunk 6 — `src/esp32/esp32_main.cpp`

```diff
@@ -1411,6 +1442,13 @@ void esp32setup()
         int state = radio.begin(433.175);
         radio.setDio2AsRfSwitch(true);
         radio.setTCXO(1.8);
+        #elif defined(QEMU_HEADLESS)
+        // QEMU headless: no LoRa hardware. Do NOT initialise RadioLib/SPI; force
+        // "no backend" so bRadio stays false and the entire radio bring-up and the
+        // radio TX/RX loop blocks (all guarded by if(bRadio)) are skipped. No RF.
+        int state = RADIOLIB_ERR_CHIP_NOT_FOUND;
+        (void)state;
+        printlndeb("[QEMU]...LoRa radio disabled (no backend); RadioLib/SPI init skipped");
         #else
         int state = radio.begin(433.175);
         #endif
```

### Hunk 7 — `src/esp32/esp32_main.cpp`

```diff
@@ -1867,7 +1905,7 @@ void esp32setup()
     #else
     pAdvertising->start();
     #endif
- 
+
     printfdeb("[BLE ]...Waiting a client connection to notify...\n");
     #else
     printfdeb("[BLE ]...disabled (DISABLE_BLE)\n");
```

### Hunk 8 — `src/esp32/esp32_main.cpp`

```diff
@@ -2977,6 +3015,17 @@ void esp32loop()
     }
     #endif
 
+    #if defined(QEMU_HEADLESS)
+    // QEMU (every qemu-headless profile, M13b stabilization): there is no Wi-Fi here.
+    // The 30s checkWifiPing watchdog below would see no Wi-Fi station forever, then
+    // Udp.stop()/WiFi.disconnect(), clear node_hasIPaddress and
+    // stopWebserver()+startNetwork() -- churning the network lifecycle, closing the shared
+    // UDP socket and (with the external radio) dropping the transport's readiness gate.
+    // OpenETH readiness here is event-backed (qemuNetworkReady/qemuNetworkReadyEvent) and the
+    // XR transport keeps its own connectivity/error handling, so this Wi-Fi-specific
+    // watchdog is suppressed in every QEMU build. All real boards keep the original block
+    // (the #else branch below) unchanged.
+    #else
     // check WiFI connected with Ping every 30 sec
     if(meshcom_settings.node_netmode == 0 && (uint32_t)(millis() - wifi_active_timer) >= 30000)
     {
```

### Hunk 9 — `src/esp32/esp32_main.cpp`

```diff
@@ -3007,6 +3056,7 @@ void esp32loop()
             wifi_active_timer = millis();
         }
     }
+    #endif
 
     // SOFTSER
     #if defined(ENABLE_SOFTSER)
```

### Hunk 10 — `src/esp32/esp32_main.cpp`

```diff
@@ -3572,7 +3622,13 @@ void esp32loop()
         {
             rebootAuto = 0;
 
-            #ifdef ESP32
+            #if defined(QEMU_HEADLESS)
+                // QEMU: a guest SW reset wedges qemu-xtensa in the ROM bootloader (the
+                // machine never re-enters the app). Settings are already saved to
+                // NVS/flash — skip the restart and keep running; restart the stack for
+                // anything that truly needs a boot.
+                printlndeb("[QEMU]...auto-reboot suppressed (guest reset wedges QEMU); settings saved");
+            #elif defined(ESP32)
                 ESP.restart();
             #endif
         }
```

### Hunk 11 — `src/gps_functions.cpp`

```diff
@@ -894,6 +894,54 @@ void WZ_GPS_Init()
   if(gpsInitDone)
       return;
 
+#if defined(QEMU_GPS)
+  // QEMU virtual GPS: line-oriented NMEA arrives on UART1 from a host source
+  // (scripts/gps-relay.py, fed by host gpsd or a synthetic fixture). Bypass ALL
+  // hardware bring-up: no WZ_GPS_Reset (reset GPIO), no detectBaudrate (8-baud
+  // sweep), no GPSprobe/SetupUBLOX/SetupL76K (UBX/PCAS config writes to a receiver).
+  // The normal byte-by-byte TinyGPSPlus receive loop and the HDOP/satellite/age fix
+  // logic in WZ_GPS_Loop() are left COMPLETELY unchanged. GPS_RX_PIN/GPS_TX_PIN are
+  // synthetic, non-physical pin numbers (no GPS hardware exists under QEMU); the
+  // socket-backed UART ignores baud.
+  gpsInitDone = true;
+
+  // GPS-03: Neue Sitzung, neuer Schaetzer (mirrors the hardware path below).
+  altFilterReset(&s_alt);
+  s_altConvergedOnce = false;
+  s_altLastMs = 0;
+
+  GPSSerial.begin(GPS_BAUDRATE_SETFIX, SERIAL_8N1, GPS_RX_PIN, GPS_TX_PIN);
+  Serial.printf("[GPS ]...QEMU virtual GPS on UART1 (synthetic RX=%d TX=%d @ %d baud; no hardware)\n",
+                GPS_RX_PIN, GPS_TX_PIN, GPS_BAUDRATE_SETFIX);
+
+  // Honest presence detection: a bounded, single-pass count of NMEA-like characters
+  // that ACTUALLY arrive on the virtual UART. gpsDetected is derived from real bytes,
+  // never forced true; with no host feed it stays false and WZ_GPS_Loop() is skipped.
+  gpsDetected = false;
+  {
+    uint32_t qstart = millis();
+    int qchars = 0;
+    while((millis() - qstart) < (uint32_t)WAIT_DURATION)
+    {
+      // Bounded like the outer loop: a host feed faster than the emulated CPU drains it
+      // must not keep this inner loop, and so the boot, from ever returning (R22).
+      while(GPSSerial.available() && qchars <= 10 && (millis() - qstart) < (uint32_t)WAIT_DURATION)
+      {
+        char qc = char(GPSSerial.read());
+        if((qc >= 'A' && qc <= 'Z') || (qc >= '0' && qc <= '9') ||
+           qc == '$' || qc == '*' || qc == ',' || qc == 0x0A || qc == 0x0D)
+          qchars++;
+      }
+      if(qchars > 10) break;
+    }
+    gpsDetected = (qchars > 10);
+    on_UBLOX = gpsDetected;   // virtual module type; no hardware probe was performed
+    Serial.printf("[GPS ]...QEMU NMEA presence: %d chars -> %s\n",
+                  qchars, gpsDetected ? "detected" : "no data yet");
+  }
+  return;
+#else
+
   WZ_GPS_Reset();
 
   gpsInitDone = true;
```

### Hunk 12 — `src/gps_functions.cpp`

```diff
@@ -951,6 +999,7 @@ void WZ_GPS_Init()
     Serial.println("[GPS_ERR] Erkennung fehlgeschlagen (Timeout oder kein Signal)");
     gpsDetected = false;
   }
+#endif
 }
 
 
```

### Hunk 13 — `src/gps_functions.cpp`

```diff
@@ -971,11 +1020,70 @@ void WZ_GPS_Feed()
         return;
 
     // Alle verfuegbaren Bytes lesen (non-blocking)
+#ifdef MESHCOM_QEMU_GPSTEST
+    {
+        // QEMU-test-only observability (compiled in ONLY for the …-gpsd test profiles,
+        // never in default/physical/ordinary external-radio builds). Transition-based,
+        // STATUS ONLY — never prints latitude/longitude/time/altitude. It does NOT alter
+        // any firmware logic: pure reads + a Serial line on change.
+        //
+        // "usable" mirrors MeshCom's fix gate (valid location + HDOP/satellite quality)
+        // but uses the LIVE TinyGPSPlus location age so the test can deterministically
+        // observe input going stale. We ALSO print hasfix = WZ_GPS_HasFix(), the firmware's
+        // own API, which uses the snapshot gpsData.age_ms and therefore does NOT age out
+        // when input stops (documented behaviour).
+        static int s_prevUsable = -1;
+        static double s_lat = 1e9, s_lon = 1e9;
+        static int s_moves = 0;
+        bool quality = (fposinfo_hdop < 6.0) && (posinfo_satcount > 5);  // mirrors the firmware fix gate
+        int usable = (gpsInitDone && gps.location.isValid() &&
+                      gps.location.age() < 5000 && quality) ? 1 : 0;
+        // Coordinate-free movement counter: count DISTINCT committed positions, proving
+        // the parser updates position rather than locking the first point. We compare the
+        // current committed lat/lon against the previous ones (in memory only — coordinates
+        // are NEVER logged, only the running count). isUpdated() is not used: the main loop
+        // below consumes that flag, so we diff the values directly each pass.
+        if(usable)
+        {
+            double la = gps.location.lat(), lo = gps.location.lng();
+            if(s_lat < 1e8)   // we already have a previous real position to compare against
+            {
+                double dla = (la > s_lat) ? (la - s_lat) : (s_lat - la);
+                double dlo = (lo > s_lon) ? (lo - s_lon) : (s_lon - lo);
+                if(dla > 0.00005 || dlo > 0.00005)
+                {
+                    s_moves++;
+                    Serial.printf("[GPSTEST] moved n=%d\n", s_moves);
+                }
+            }
+            s_lat = la; s_lon = lo;
+        }
+        if(usable != s_prevUsable)
+        {
+            // NOTE: fposinfo_hdop is the firmware's float HDOP; it is passed as double
+            // for %.1f so the varargs line up (the old int posinfo_hdop no longer exists).
+            Serial.printf("[GPSTEST] fix=%d sats=%u hdop=%.1f hasfix=%d src=%s\n",
+                          usable, posinfo_satcount, (double)fposinfo_hdop,
+                          WZ_GPS_HasFix() ? 1 : 0, cTimeSource);
+            s_prevUsable = usable;
+        }
+    }
+#endif
+
     #if defined(USE_HELTEC_T114) or defined(BOARD_T_ECHO)
     while (Serial1.available())
     #else
+    #if defined(QEMU_GPS)
+    // QEMU: the socket-backed virtual UART has no baud pacing, so a live NMEA feed can keep
+    // this per-loop drain busy for minutes and starve loop() (the net-console goes deaf).
+    // Bound the bytes taken per pass to about what 9600 baud delivers in 250 ms; the rest
+    // waits for the next pass. Hardware keeps the unbounded drain.
+    int qemu_gps_budget = 256;
+    while (GPSSerial.available() && qemu_gps_budget-- > 0)
+    #else
     while (GPSSerial.available())
     #endif
+    #endif
     {
         #if defined(USE_HELTEC_T114) or defined(BOARD_T_ECHO)
         int ic = Serial1.read();
```

### Hunk 14 — `src/loop_functions.cpp`

```diff
@@ -66,7 +66,7 @@ bool gpsInitDone = false;
 // gps (TinyGPSPlus) wird in gps_functions.cpp unbedingt instanziiert und hier nur fuer
 // reine Distanz-/Kursberechnungen (distanceBetween/courseTo) genutzt - kein GPS-Modul noetig.
 // Daher auch fuer Wireless Paper (ohne ENABLE_GPS) sichtbar machen.
-#if defined(ENABLE_GPS) || defined(ENABLE_RAK_GPS) || defined(WP_DISP)
+#if defined(QEMU_HEADLESS) || defined(ENABLE_GPS) || defined(ENABLE_RAK_GPS) || defined(WP_DISP)   // QEMU: gps is used unconditionally below
 extern TinyGPSPlus gps;
 #endif
 
```

### Hunk 15 — `src/net_console.cpp`

```diff
@@ -25,6 +25,7 @@
 // HardwareSerial reference before #define Serial MSerial takes effect.
 #include <Arduino.h>
 #include <WiFi.h>
+#include "qemu/qemu_network.h"   // QEMU_HEADLESS only (self-guarded)
 #include <netinet/in.h>
 #include <freertos/FreeRTOS.h>
 #include <freertos/semphr.h>
```

### Hunk 16 — `src/net_console.cpp`

```diff
@@ -356,6 +357,10 @@ void loopNetConsole()
     networkReady = networkReady ||
                    (meshcom_settings.node_netmode == 1 && meshcom_settings.node_hasIPaddress);
     #endif
+    #ifdef QEMU_HEADLESS
+    // QEMU headless: neither WiFi nor HAS_ETHERNET; the lwIP/TCP stack is ready once OpenETH has an IPv4 address.
+    networkReady = networkReady || qemuNetworkReady();
+    #endif
 
     if (!networkReady)
         return;
```

### Hunk 17 — `src/udp_functions.cpp`

```diff
@@ -5,4 +5,6 @@
 #include <Arduino.h>
 
+#include "qemu/qemu_network.h"   // QEMU_HEADLESS only (self-guarded)
+
 #include <udp_functions.h>
 #include <extudp_functions.h>
```

### Hunk 18 — `src/udp_functions.cpp`

```diff
@@ -1114,8 +1116,58 @@ void wifiDnsPoll()
   }
 }
 
+#ifdef QEMU_HEADLESS
+// QEMU-only: copy the OpenETH IPv4 state into meshcom_settings (mirrors what the
+// Wi-Fi/Ethernet path does), using the event-driven readiness from qemu_network.
+// The shared UDP socket is (re)opened whenever the IP state is (re)established, as
+// startMeshComUDP() does on Wi-Fi (the QEMU path skips that function). Every path that
+// stops the socket also clears hasIPaddress, so !hasIPaddress means "no valid socket".
+// Without one, ntpHarvestUDP() polls a closed descriptor on every loop pass and the core
+// logs an EBADF line each time, which stalls the emulated loop for seconds. The IP state
+// is reported up only once the socket is open; a failed open is retried by the loop.
+static bool qemuApplyNetState()
+{
+  IPAddress ip, gw, mask;
+  if(!qemuNetworkReady() || !qemuNetworkGetIp(ip, gw, mask))
+    return false;
+  if(!hasIPaddress)
+  {
+    static bool s_udpFailLogged = false;
+    if(!Udp.begin(LOCAL_PORT))
+    {
+      if(!s_udpFailLogged)
+        printfdeb("[QEMU]...UDP port %d open FAILED, retrying\n", LOCAL_PORT);
+      s_udpFailLogged = true;
+      return false;   // IP state stays down; the loop calls this again
+    }
+    s_udpFailLogged = false;
+    printfdeb("[QEMU]...UDP port %d open\n", LOCAL_PORT);
+  }
+  snprintf(meshcom_settings.node_ip, sizeof(meshcom_settings.node_ip), "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);
+  snprintf(meshcom_settings.node_gw, sizeof(meshcom_settings.node_gw), "%u.%u.%u.%u", gw[0], gw[1], gw[2], gw[3]);
+  snprintf(meshcom_settings.node_subnet, sizeof(meshcom_settings.node_subnet), "%u.%u.%u.%u", mask[0], mask[1], mask[2], mask[3]);
+  hasIPaddress = true;
+  meshcom_settings.node_hasIPaddress = true;
+  iWlanWait = 0;
+  return true;
+}
+#endif
+
  bool startNetwork()
  {
+  #ifdef QEMU_HEADLESS
+    // QEMU headless: bring up OpenETH instead of Wi-Fi. Non-blocking: start the
+    // driver and let the existing loop poll doWiFiConnect() until GOT_IP.
+    qemuNetworkStart();
+    if(qemuApplyNetState())
+    {
+      printlndeb("[QEMU]...OpenETH ready; node IP assigned, network up");
+      return true;
+    }
+    iWlanWait = 1;   // not ready yet -> loop calls doWiFiConnect() (non-blocking)
+    return false;
+  #endif
+
   #if defined(HAS_ETHERNET)
 
       if(meshcom_settings.node_netmode == 1)
```

### Hunk 19 — `src/udp_functions.cpp`

```diff
@@ -1285,6 +1337,17 @@ bool wifiHarvestGotIp()
 
 bool doWiFiConnect()
 {
+  #ifdef QEMU_HEADLESS
+    // QEMU headless: non-blocking. Report OpenETH readiness; never touch Wi-Fi or
+    // startMeshComUDP(). No blocking poll loop.
+    if(qemuApplyNetState())
+    {
+      printlndeb("[QEMU]...OpenETH connect OK");
+      return true;
+    }
+    return false;
+  #endif
+
   if(s_wifiScanPending)
   {
     int n = WiFi.scanComplete();
```

### Hunk 20 — `src/web_functions/web_functions.cpp`

```diff
@@ -5,4 +5,6 @@
 #include <Arduino.h>
 
+#include "qemu/qemu_network.h"   // QEMU_HEADLESS only (self-guarded)
+
 #include <configuration.h>
 #include <debugconf.h>
```

### Hunk 21 — `src/web_functions/web_functions.cpp`

```diff
@@ -114,20 +116,29 @@ void startWebserver()
     bool ethernet_mode = false;
     #endif
 
-    if (!is_connected && !is_ap_active && !ethernet_mode)
+    #ifdef QEMU_HEADLESS
+    bool qemu_ready = qemuNetworkReady();
+    #else
+    bool qemu_ready = false;
+    #endif
+
+    if (!is_connected && !is_ap_active && !ethernet_mode && !qemu_ready)
     {
         return;
     }
 
     web_server.stop();
 
+    #ifndef QEMU_HEADLESS
     MDNS.end();
+    #endif
 
     // Set up mDNS responder:
     // - first argument is the domain name, in this example
     //   the fully-qualified domain name is "esp32.local"
     // - second argument is the IP address to advertise
     //   we send our IP address on the WiFi network
+    #ifndef QEMU_HEADLESS
     if(bMDNSOK)
     {
         if (!MDNS.begin(meshcom_settings.node_call))
```

### Hunk 22 — `src/web_functions/web_functions.cpp`

```diff
@@ -150,6 +161,7 @@ void startWebserver()
             }
         }
     }
+    #endif
 
     web_server.begin();
 
```

### Hunk 23 — `src/web_functions/web_functions.cpp`

```diff
@@ -2002,6 +2014,15 @@ void sub_page_spectrum()
 {
     _create_meshcom_subheader("Spectrum Scan");
     web_client.println("<div id=\"content_inner\">");
+#ifdef QEMU_HEADLESS
+    // QEMU: no local SX126x radio (radio disabled; the real radio lives on the LoRaHAM
+    // daemon/Pi-HAT and the external-radio path cannot carry a chip-level scan). Return
+    // a clear message immediately instead of probing a non-existent chip — this avoids
+    // both the "unable to initialize spectrum scan" error and the long wait it caused.
+    web_client.println("<p>Spectrum scan is not available under QEMU. It needs direct access to a local SX126x radio chip to sweep the band, which the emulated node does not have. Run spectrum scan on a physical T-Deck.</p>");
+    web_client.println("</div>");
+    return;
+#endif
 #if defined(SX1262X) || defined(SX126X) || defined(SX1262_V3) || defined(SX1262_E290) || defined(USING_SX1262)
 
     meshcom_settings.node_specstart = 432.0;
```

## Appendix B — evidence (prototype cons/s5-proto 6641a6f5 unless stated; stock MeshCom f2b3a349; overlay control = c871ae4e on 8770f9b5)

**B1. Provisioning run on a fresh node, v3 command list (UART lines; QEMU then exited rc 0):**

```
--setssid qemu0
Auto. Reboot after 15 sec.
--setpwd qemu0000
Auto. Reboot after 15 sec.
--webserver on
--netconsole on
...net console on (<guest-addr> port 2323)
--mesh off
--gateway off
--extudp off
--gps on
[GPS ]...Init GPIO RX=16 TX=17
--wifiap off
--netmode eth
[CMD] netmode -> Ethernet[NET];mtu;eth;1280
```

**B2. Then `--setcall`, the restart, and the full gate run (host probe stdout, saved file):**

```
[s5] provisioning QEMU exit=0 (0 = the guest reset ended QEMU; 124 = timeout) log=<checkout>/.run/uart-provision-20261015T213345Z.log
extract: Call:<testcall>-1 Short:<short> set
setcall boot ended rc=0 after 13s
client-started after 2s
web / code=200 bytes=42799
web /info code=200 bytes=42799
web /setup code=200 bytes=42799
console accepted; first bytes: 47 b'OK\r\nMeshCom Console\r\nType --help for commands\r\n'
xr before: bytes_sent:85 bytes_received:119
sendpos:
reply: b'--sendpos\n'
xr after:  bytes_sent:94 bytes_received:181
page tail: html>

info:
reply-extract: ...MESH off | ...EXTUDP off | Gateway off
spectrum code=200 bytes=571 secs=10.204317
web after spectrum code=200
after sendpos: qemu alive
reboot:
reply: b'--reboot\n'
G4: run.sh/QEMU ended by itself rc=0 after 1s
restart web code=200 bytes=42799
[QEMU]...ethmode: IP <guest-addr> reported (331 ms)
[BOOT] RESET_REASON=1 POWERON
[NET] Ethernet mode
bridge estab sockets: 2
stopped; qemu left: 0
```

**B3. XR frame tap (`xr-tap.py`, Appendix C), same build. Frame counts by direction, type and payload byte 0:**

Control window (45 s after boot, no `--sendpos`):
```
      1 bridge>node AUTH_CHALLENGE len=16
      1 bridge>node AUTH_RESULT len=1
      1 bridge>node CONFIG_RESULT len=18
      1 bridge>node HELLO_ACK len=1
      1 bridge>node PING len=0
      1 bridge>node TX_RESULT len=1
      1 node>bridge AUTH_RESPONSE len=32
      1 node>bridge CONFIGURE len=17
      1 node>bridge HELLO len=1
      1 node>bridge PONG len=0
      1 node>bridge TX_REQUEST len=29 payload[0]=0x40
```
Whole run (then `--sendpos`, +20 s):
```
      1 bridge>node AUTH_CHALLENGE len=16
      1 bridge>node AUTH_RESULT len=1
      1 bridge>node CONFIG_RESULT len=18
      1 bridge>node HELLO_ACK len=1
      2 bridge>node PING len=0
      3 bridge>node TX_RESULT len=1
      1 node>bridge AUTH_RESPONSE len=32
      1 node>bridge CONFIGURE len=17
      1 node>bridge HELLO len=1
      2 node>bridge PONG len=0
      2 node>bridge TX_REQUEST len=29 payload[0]=0x40
      1 node>bridge TX_REQUEST len=54 payload[0]=0x21
```

**B4. M3–M6 (terminal output of the measuring runs, transcribed verbatim; the M3 build had no hand-over task, the M4 build a test hook clearing the flag once, M5 ran on the f6a39c04 build):**

```
=== M3: fresh node, a build without the hand-over task (stand-ins only); provisioning run, UART tail ===
CLIENT STARTED
Guru Meditation Error: Core  0 panic'ed (LoadStorePIFAddrError). Exception was unhandled.
EXCVADDR: 0x60033c00
Rebooting...
[s5] provisioning QEMU exit=0 (0 = the guest reset ended QEMU; 124 = timeout)   (after 8 s; no command had been sent)
addr2line of the backtrace (firmware.elf of that build):
0x401a92ab: register_chipv7_phy at .../phy/phy_chip_v7.c:3782
0x4017496a: esp_phy_load_cal_and_init at .../esp_phy/src/phy_init.c:741
0x401749ed: esp_phy_enable at .../esp_phy/src/phy_init.c:241
0x4013d497: esp_phy_enable_wrapper at .../esp_wifi/esp32/esp_adapter.c:724
0x4018c9c6: wifi_hw_start at ??:?
0x4018d1d5: wifi_start_process at ??:?
=== M4: test build clearing node_hasIPaddress once at 8 s (task suspended after the clear); probe every 55 s ===
t+55s web=200 eth_lines=0 alive=1
t+110s web=200 eth_lines=0 alive=1
t+165s web=200 eth_lines=0 alive=1
t+220s web=200 eth_lines=0 alive=1
t+275s web=200 eth_lines=0 alive=1
t+330s web=200 eth_lines=4 alive=1
t+385s web=200 eth_lines=4 alive=1
UART:
[QEMU]...TEST: node_hasIPaddress cleared (8021 ms)
[NET] Ethernet mode
[ETH] init
[ETH] LINK UP
[ETH] DHCP mode
[ETH] DHCP IP: 251789322        (upstream prints the IPAddress as uint32: 0x0F02000A = <guest-addr>)
=== M5: unpaced host write into UART1 for 90 s (python sendall loop on the chardev socket); probes every 10 s ===
t+10s web=200 0.331370 console_bytes=47
t+20s web=200 0.374478 console_bytes=47
t+30s web=200 0.301022 console_bytes=47
t+40s web=200 0.303716 console_bytes=47
t+50s web=200 0.309629 console_bytes=47
t+60s web=200 0.430030 console_bytes=47
t+70s web=200 0.275303 console_bytes=47
t+80s web=200 0.321882 console_bytes=47
blast: 60828 bytes in 90.7 s = 671 B/s
=== M6: fresh node, provisioned, no callsign; then --setcall; then the restart ===
boot1 console after 6s
pre-call web=200
extract: ...MESH off | ...EXTUDP off | Gateway off
pre-call WIFIAP-starting lines: 1
extract: Call:<testcall>-1 Short:<short> set
after setcall: run.sh/QEMU ended rc=0 after 13s
boot2 console after 6s
post-call web=200
post-call WIFIAP-starting lines: 0
BLE-Name <MC-xxxx-<testcall>-1>
extract: ...MESH off | ...EXTUDP off | Gateway off
```

**B5. M2, the plain env (no chip):**
```
[LoRa]...SX1268 chip Initializing ... failed, code -2
CLIENT STARTED
```
`CLIENT STARTED` at the 14th 1-s poll.

**B6. M1:** `build.sh --env qemu-headless` on stock: `src/loop_functions.cpp:3015:16: error: 'gps' was not declared in this scope` (and `:5971`); with `-D ENABLE_GPS -D ENABLE_UBLOX` + the GPS pins: `qemu-headless build rc=0 errors=0 redef=0`, likewise `-extradio`.

**B7. Numbers, measured:**

| figure | command | output |
|---|---|---|
| patch / apply / its test | `git show origin/main:<f> \| wc -l` | 469 / 82 / 90 |
| stand-ins, ethmode | `wc -l` at 6641a6f5 | ETHClass2.h 29, EthernetUdp.h 9, qemu_eth_standin.cpp 35, qemu_ethmode.cpp 64 |
| tracked MeshCom changes | `git -C .work/MeshCom-Firmware status --porcelain --untracked-files=no \| wc -l` | 0 |
| 11 prototype boots (f6a39c04) | `grep -lE <pattern>` over the 11 UART logs | RESET_REASON 11, Display not found 11, OBUT 11, `[ETH]` 0, mDNS 0, panic 0, EBADF 0 |
| NTP state | `grep -l "TimeClient no update possible"` | S5 11 of 13 logs, overlay 4 of 6 |
| stock GPS default | `grep -l configuration_default.h variants/*/configuration.h \| wc -l` | 31 |
| run.sh exits today | `grep -nE "exit [0-9]+" scripts/run.sh` | 1 at four sites, 2 for usage |
| report time of the address | the `ethmode … reported` / hand-over lines | 220 ms to 1993 ms, each before `CLIENT SETUP` |

## Appendix C — in the second file `gate1-DESIGN-s5-appendix-C.md`

## Appendix D — upstream excerpts (MeshCom f2b3a349; line numbers left)

**`platformio.ini:13-14`**
```
   13  extra_configs = 
   14  	variants/*/platformio.ini
```

**`src/configuration_global.h:1-6`**
```
    1  // Kein Include-Guard bis 2026-09-16: jede Uebersetzungseinheit, die diesen
    2  // Header zweimal sah, brach mit "redefinition of 'isNodeUnconfigured'" ab.
    3  // Sichtbar wurde das nur in env:esp32-external-radio, weil dort zwei Pfade
    4  // ihn einziehen; die uebrigen Envs kamen mit genau einem Include davon.
    5  #pragma once
    6  
```

**`src/configuration_default.h:123-124`**
```
  123  #if !defined(ENABLE_GPS) && !defined(ENABLE_GPS_DISABLED)
  124  #define ENABLE_GPS                              // 28 of 31 variants
```

**`src/loop_functions.cpp:77-80`**
```
   77  // TinyGPS
   78  // gps (TinyGPSPlus) wird in gps_functions.cpp unbedingt instanziiert und hier nur fuer
   79  // reine Distanz-/Kursberechnungen (distanceBetween/courseTo) genutzt - kein GPS-Modul noetig.
   80  // Daher auch fuer Wireless Paper (ohne ENABLE_GPS) sichtbar machen.
```

**`src/loop_functions.cpp:3014-3016`**
```
 3014      float d_dir_to = 0;
 3015      d_dir_to = gps.courseTo(meshcom_settings.node_lat, meshcom_settings.node_lon, lat, lon);
 3016      dir_to = d_dir_to;
```

**`src/esp32/esp32_main.cpp:1124-1128`**
```
 1124      if(isNodeUnconfigured(meshcom_settings.node_call))
 1125      {
 1126          bWIFIAP = true;
 1127          printlndeb("[INIT]...WIFIAP starting...");
 1128      }
```

**`src/esp32/esp32_main.cpp:1153-1160`**
```
 1153      // keine WIFI Connection
 1154      if(strlen(meshcom_settings.node_pwd) == 0 && strlen(meshcom_settings.node_ssid) == 0)
 1155      {
 1156          bGATEWAY=false;
 1157  
 1158          if(!bWIFIAP)
 1159              bWEBSERVER=false;
 1160      }
```

**`src/esp32/esp32_main.cpp:1543-1556`**
```
 1543          #if defined(EXTERNAL_RADIO)
 1544          // External radio: the bridge owns the RF chip. Do NOT initialize/begin the
 1545          // local RadioLib transceiver. bRadio is forced false below so no local
 1546          // RX/CAD/TX path runs.
 1547          int state = RADIOLIB_ERR_NONE;
 1548          (void)state;
 1549          #elif defined(BOARD_T_ETH_ELITE)
 1550          int state = radio.begin(433.175);
 1551          radio.setDio2AsRfSwitch(true);
 1552          radio.setTCXO(1.8);
 1553          #else
 1554          int state = radio.begin(433.175);
 1555          #endif
 1556  
```

**`src/esp32/esp32_main.cpp:2034-2041`**
```
 2034      ///////////////////////////////////////////////////////
 2035      // WIFI
 2036      if(bGATEWAY || bEXTUDP || bWEBSERVER || bNETCONSOLE)
 2037      {
 2038          bAllStarted=false;
 2039  
 2040          if(!startNetwork())
 2041          {
```

**`src/esp32/esp32_main.cpp:3198-3200`**
```
 3198  
 3199      // check WiFI connected with Ping every 30 sec
 3200      if(meshcom_settings.node_netmode == 0 && (uint32_t)(millis() - wifi_active_timer) >= 30000)
```

**`src/esp32/esp32_pmu.cpp:26-27`**
```
   26  void setupPMU()
   27  {
```

**`src/esp32/esp32_pmu.cpp:50-53`**
```
   50  |            |                   |                   |                   |                                        |
   51  */
   52      #if defined(XPOWERS_CHIP_AXP192) || defined(XPOWERS_CHIP_AXP2101)
   53  
```

**`src/esp32/esp32_pmu.cpp:336-339`**
```
  336      delay(100);
  337  
  338      #endif
  339  }
```

**`src/command_functions.cpp:420-426`**
```
  420      { "--gateway off",        &bGATEWAY,             &meshcom_settings.node_sset,     0xFFFFEFFF,   0x00000000,   tg_post_gateway,               TG_DIRTY_NODE,   TG_SAVE | TG_BRETURN },
  421      { "--ackinfo on",         &bAckInfo,             nullptr,                         0xFFFFFFFF,   0x00000000,   nullptr,                       TG_DIRTY_NONE,   TG_FLAG_TRUE | TG_BLE_ECHO },
  422      { "--ackinfo off",        &bAckInfo,             nullptr,                         0xFFFFFFFF,   0x00000000,   nullptr,                       TG_DIRTY_NONE,   TG_BLE_ECHO },
  423      { "--webserver off",      &bWEBSERVER,           &meshcom_settings.node_sset2,    0xFFFFFFBF,   0x00000000,   nullptr,                       TG_DIRTY_NODE,   TG_SAVE | TG_BRETURN },
  424      { "--mesh on",            &bMESH,                &meshcom_settings.node_sset2,    0xFFFFFFDF,   0x00000000,   nullptr,                       TG_DIRTY_NODE,   TG_SAVE | TG_BRETURN | TG_FLAG_TRUE },
  425      { "--mesh off",           &bMESH,                &meshcom_settings.node_sset2,    0xFFFFFFFF,   0x0020,       nullptr,                       TG_DIRTY_NODE,   TG_SAVE | TG_BRETURN },
  426      { "--extudp off",         &bEXTUDP,              &meshcom_settings.node_sset,     0xFFFFDFFF,   0x00000000,   tg_post_extudp_off,            TG_DIRTY_WIFI,   TG_SAVE | TG_BRETURN },
```

**`src/command_functions.cpp:483-483`**
```
  483      { "--gps on",             &bGPSON,               &meshcom_settings.node_sset,     0xFFFFFFFF,   0x0040,       tg_post_gps_on,                TG_DIRTY_NODE,   TG_SAVE | TG_BRETURN | TG_FLAG_TRUE | TG_POST_FIRST },
```

**`src/command_functions.cpp:2475-2478`**
```
 2475      if(commandCheck(msg_text+2, (char*)"netconsole on") == 0)
 2476      {
 2477          bNETCONSOLE=true;
 2478          meshcom_settings.node_sset2 |= 0x1000;
```

**`src/command_functions.cpp:2591-2596`**
```
 2591      if(commandCheck(msg_text+2, (char*)"webserver on") == 0)
 2592      {
 2593          #ifndef BOARD_RAK4630
 2594          if(meshcom_settings.node_netmode == 0 && strlen(meshcom_settings.node_ssid) < 3)
 2595          {
 2596              printfdeb("Please set SSID first");
```

**`src/command_functions.cpp:3734-3745`**
```
 3734          if(commandCheck(msg_text+2, (char*)"netmode eth") == 0)
 3735          {
 3736              meshcom_settings.node_netmode = 1;
 3737  
 3738              printfdeb("[CMD] netmode -> Ethernet");
 3739              //printfdeb("node_netmode=%d\n", meshcom_settings.node_netmode); // solo per debug
 3740  
 3741              save_settings();
 3742  
 3743              rebootAuto = millis() + 5000;
 3744  
 3745              bReturn = true;
```

**`src/command_functions.cpp:3811-3820`**
```
 3811      if(commandCheck(msg_text+2, (char*)"wifiap off") == 0)
 3812      {
 3813          bWIFIAP=false;
 3814          meshcom_settings.node_sset2 &= ~0x0080;    // mask 0x0080
 3815  
 3816          if(ble)
 3817          {
 3818              bWifiSetting = true;
 3819          }
 3820  
```

**`src/gps_functions.cpp:272-282`**
```
  272          // Liegt einer vor, endet das Fenster sofort -- es gibt nichts mehr
  273          // zu entscheiden.
  274          while ((millis() - start < 1500) && !bFrameOK)
  275          {
  276              // Die innere Schleife war unbegrenzt: bei einem dauerhaft
  277              // sendenden Modul bleibt available() beliebig lange wahr. Sie
  278              // erbt jetzt dasselbe 1500-ms-Fenster wie die äußere.
  279              #if defined(USE_HELTEC_T114) or defined(BOARD_T_ECHO)
  280              while (Serial1.available() && (millis() - start < 1500) && !bFrameOK)
  281              #else
  282              while (GPSSerial.available() && (millis() - start < 1500) && !bFrameOK)
```

**`src/gps_functions.cpp:746-760`**
```
  746  bool GPSprobe() {
  747  
  748    on_L76K = false;
  749    on_UBLOX = false;
  750  
  751    #if defined(ENABLE_L76K)
  752      on_L76K = true;
  753      Serial.printf("[GPS ]...set fix to L76K\n");
  754      return true;
  755    #elif defined(ENABLE_UBLOX)
  756      on_UBLOX = true;
  757      Serial.printf("[GPS ]...set fix to UBLOX\n");
  758      return true;
  759    #else
  760  
```

**`src/net_console.cpp:345-357`**
```
  345  {
  346      // Die Netconsole ist eine TCP/IP-Konsole und benoetigt zwingend eine aktive WiFi-/IP-
  347      // Verbindung. Ohne verbundenes WiFi ist der lwIP-TCP/IP-Stack nicht bereit -> der folgende
  348      // ::socket()-Aufruf loest dann einen Assert aus (tcpip_send_msg_wait_sem -> __assert_func)
  349      // und damit einen Panic/Reboot. Daher hier frueh aussteigen, solange kein WiFi verbunden
  350      // ist. s_server_pending bleibt erhalten, sodass der Listening-Socket geoeffnet wird, sobald
  351      // die WiFi-Verbindung steht. (Ohne IP kann die Netconsole ohnehin nicht arbeiten.)
  352      bool networkReady = (WiFi.status() == WL_CONNECTED);
  353  
  354      #if defined(HAS_ETHERNET)
  355      // Ethernet mode: WiFi never connects, the IP comes from the Ethernet interface.
  356      networkReady = networkReady ||
  357                     (meshcom_settings.node_netmode == 1 && meshcom_settings.node_hasIPaddress);
```

**`src/udp_functions.cpp:75-81`**
```
   75  bool hasIPaddress = false;
   76  
   77  extern bool hasExternIPaddress;
   78  
   79  WiFiUDP Udp;
   80  
   81  NtpAsync timeClient(Udp);   // TM-35: non-blocking, reply harvested in getMeshComUDP()
```

**`src/udp_functions.cpp:226-235`**
```
  226  void ntpHarvestUDP()
  227  {
  228    if(bWIFIAP)
  229      return;
  230  
  231    meshcom_settings.node_hasIPaddress = hasIPaddress;
  232  
  233    if(!hasIPaddress)
  234      return;
  235  
```

**`src/udp_functions.cpp:599-640`**
```
  599   bool startNetwork()
  600   {
  601    #if defined(HAS_ETHERNET)
  602  
  603        if(meshcom_settings.node_netmode == 1)
  604        {
  605            printlndeb("[NET] Ethernet mode");
  606            
  607            if(!meshcom_settings.node_hasIPaddress)
  608                neth.initethDHCP();
  609  
  610            return meshcom_settings.node_hasIPaddress;
  611        }
  612  
  613    #endif
  614  
  615    #if defined(BOARD_T_DECK) || defined(BOARD_T_DECK_PLUS)
  616    {
  617      if (!meshcom_settings.node_wifion)
  618      {
  619        printlndeb("[WIFI]...disabled by Settings (node_wifion=false)");
  620        return false;
  621      }
  622  
  623      printlndeb("[WIFI]...enabled by Settings (node_wifion=true)");
  624    }
  625    #endif
  626  
  627    if(meshcom_settings.node_netmode == 0 && meshcom_settings.node_hasIPaddress)
  628    {
  629      if (bDEBUG)
  630          printlndeb("[WIFI]...meshcom_settings.node_hasIPaddress=true");
  631  
  632      return false;
  633    }
  634  
  635    if(wifiSsidMissingBlocksStart(bWIFIAP, meshcom_settings.node_ssid))
  636    {
  637      return false;
  638    }
  639  
  640    wifiInitOnce();
```

**`src/udp_functions.cpp:1071-1074`**
```
 1071    if(!bWIFIAP)
 1072    {
 1073      Udp.begin(LOCAL_PORT);
 1074  
```

**`src/esp32/esp32_eth.h:1-27`**
```
    1  #pragma once
    2  
    3  #include <Arduino.h>
    4  #include <configuration.h>
    5  #include <ETHClass2.h>
    6  #include <EthernetUdp.h>
    7  
    8  class EspETH {
    9  
   10  public:
   11  
   12      void initethDHCP();
   13      void initethfixIP();
   14  
   15      bool sendUDP(uint8_t *buffer, uint16_t rx_buf_size);
   16      int checkUDP();
   17  
   18      // Ethernet IP state is managed by meshcom_settings.node_hasIPaddress
   19      bool hasETHHardware = true;
   20  
   21      IPAddress udp_dest_addr;
   22  
   23  private:
   24  
   25      ETHClass2 ETH;
   26      EthernetUDP Udp;
   27  
```

**`src/esp32/esp32_eth.cpp:11-30`**
```
   11  void EspETH::initethDHCP()
   12  {
   13      printlndeb("[ETH] init");
   14  
   15      ETH.begin(
   16          ETH_PHY_W5500,
   17          1,
   18          ETH_CS_PIN,
   19          ETH_INT_PIN,
   20          ETH_RST_PIN,
   21          SPI3_HOST,
   22          ETH_SCLK_PIN,
   23          ETH_MISO_PIN,
   24          ETH_MOSI_PIN
   25      );
   26  
   27      delay(1000);
   28  
   29      printlndeb(ETH.linkUp() ? "[ETH] LINK UP" : "[ETH] LINK DOWN");
   30  
```

**`src/esp32/esp32_eth.cpp:31-59`**
```
   31      IPAddress cfg_ip;
   32      cfg_ip.fromString(meshcom_settings.node_ownip);
   33  
   34      // -----------------------------
   35      // STATIC CONFIGURATION
   36      // -----------------------------
   37      if(cfg_ip != IPAddress(0,0,0,0))
   38      {
   39          IPAddress gw;
   40          IPAddress mask;
   41          IPAddress dns;
   42  
   43          gw.fromString(meshcom_settings.node_owngw);
   44          mask.fromString(meshcom_settings.node_ownms);
   45          dns.fromString(meshcom_settings.node_owndns);
   46  
   47          ETH.config(cfg_ip, gw, mask, dns);
   48  
   49          printdeb("[ETH] STATIC IP: ");
   50          printlndeb(cfg_ip);
   51  
   52          snprintf(meshcom_settings.node_ip, sizeof(meshcom_settings.node_ip), "%s", meshcom_settings.node_ownip);
   53          snprintf(meshcom_settings.node_gw, sizeof(meshcom_settings.node_gw), "%s", meshcom_settings.node_owngw);
   54          snprintf(meshcom_settings.node_dns, sizeof(meshcom_settings.node_dns), "%s", meshcom_settings.node_owndns);
   55          snprintf(meshcom_settings.node_subnet, sizeof(meshcom_settings.node_subnet), "%s", meshcom_settings.node_ownms);
   56  
   57          meshcom_settings.node_hasIPaddress = true;
   58          printfdeb("[ETH] node_hasIPaddress=%d\n", meshcom_settings.node_hasIPaddress);
   59      }
```
**`src/esp32/esp32_eth.cpp:60-118`**
```
   60      else
   61      {
   62          // -----------------------------
   63          // DHCP MODE
   64          // -----------------------------
   65          printlndeb("[ETH] DHCP mode");
   66  
   67          IPAddress ip;
   68  
   69          for(int i=0;i<50;i++)
   70          {
   71              ip = ETH.localIP();
   72  
   73              if(ip[0] != 0)
   74                  break;
   75  
   76              delay(200);
   77          }
   78  
   79          if(ip[0] != 0)
   80          {
   81              printdeb("[ETH] DHCP IP: ");
   82              printlndeb(ip);
   83  
   84              meshcom_settings.node_hasIPaddress = true;
   85  
   86              snprintf(meshcom_settings.node_ip, sizeof(meshcom_settings.node_ip),
   87                  "%i.%i.%i.%i", ip[0], ip[1], ip[2], ip[3]);
   88  
   89              IPAddress gw = ETH.gatewayIP();
   90              IPAddress dns = ETH.dnsIP();
   91              IPAddress mask = ETH.subnetMask();
   92  
   93              snprintf(meshcom_settings.node_gw, sizeof(meshcom_settings.node_gw),
   94                  "%i.%i.%i.%i", gw[0], gw[1], gw[2], gw[3]);
   95  
   96              snprintf(meshcom_settings.node_dns, sizeof(meshcom_settings.node_dns),
   97                  "%i.%i.%i.%i", dns[0], dns[1], dns[2], dns[3]);
   98  
   99              snprintf(meshcom_settings.node_subnet, sizeof(meshcom_settings.node_subnet),
  100                  "%i.%i.%i.%i", mask[0], mask[1], mask[2], mask[3]);
  101          }
  102          else
  103          {
  104              printlndeb("[ETH] DHCP failed -> fallback 192.168.4.1");
  105  
  106              IPAddress ip(192,168,4,1);
  107              IPAddress gw(192,168,4,1);
  108              IPAddress mask(255,255,255,0);
  109  
  110              ETH.config(ip, gw, mask);
  111  
  112              meshcom_settings.node_hasIPaddress = true;
  113          }
  114      }
  115  
  116      netif_mtu::applyConfiguredMtu(meshcom_settings.node_ethmtu);
  117  
  118      Udp.begin(EXTERN_PORT);
```

**`src/esp32/esp32_eth.cpp:143-145`**
```
  143      netif_mtu::applyConfiguredMtu(meshcom_settings.node_ethmtu);
  144  
  145      Udp.begin(EXTERN_PORT);
```

**`src/esp32/udp_drain_esp32.cpp:105-112`**
```
  105                  if (err_cnt_udp_tx >= MAX_ERR_UDP_TX)
  106                  {
  107                      printfdeb("[WIFI-DBG] UDP TX error limit (%d) reached, calling resetMeshComUDP\n", MAX_ERR_UDP_TX);
  108  
  109                      // avoid TX and UDP
  110                      hasIPaddress = false;
  111                      meshcom_settings.node_hasIPaddress = hasIPaddress;
  112                      //cmd_counter = 50;
```

**`src/esp32/gateway_service_esp32.cpp:19-22`**
```
   19  // WIFI Gateway functions
   20  if(bGATEWAY && meshcom_settings.node_hasIPaddress)
   21  {
   22      { INSTR_SECTION("udp"); getMeshComUDP(); sendMeshComUDP(); }
```

**`src/esp32/gateway_service_esp32.cpp:75-86`**
```
   75  
   76      meshcom_settings.node_last_upd_timer = hb_timer;
   77  
   78  }
   79  else if(meshcom_settings.node_hasIPaddress)
   80  {
   81      // TM-45: bGATEWAY is off, so the block above never runs and never
   82      // reads the socket -- do only the NTP-reply harvest instead, not
   83      // the full gateway receive path (no double read: exactly one of
   84      // the two branches runs per loop pass).
   85      INSTR_SECTION("udp"); ntpHarvestUDP();
   86  }
```

**`src/esp32/udp_frame_esp32.cpp:265-272`**
```
  265              // add rcvMsg to forward to LoRa TX
  266              addLoraRxBuffer(aprsmsg.msg_id, true);
  267              stat_newid.fetch_add(1); // S2: server-injected ids occupy dedup-ring slots too
  268  
  269              if(bGATEWAY_NOPOS)
  270                bUDPtoLoraSend=false;
  271            }
  272            
```

**`src/web_functions/web_functions.cpp:213-224`**
```
  213      bool is_ap_active = (WiFi.getMode() == WIFI_MODE_AP) || (WiFi.getMode() == WIFI_MODE_APSTA);
  214  
  215      #ifdef HAS_ETHERNET
  216      bool ethernet_mode = (meshcom_settings.node_netmode == 1);
  217      #else
  218      bool ethernet_mode = false;
  219      #endif
  220  
  221      if (!is_connected && !is_ap_active && !ethernet_mode)
  222      {
  223          return;
  224      }
```

**`src/esp32/external_radio_glue.cpp:194-200`**
```
  194  // Declared weak (matching the repo's user-hook style, e.g. src/nrf52/WisBlock-API.h)
  195  // so an out-of-tree platform overlay can override this symbol at link time with a
  196  // different IP-network readiness check WITHOUT modifying any tracked source. It is
  197  // fully generic: it only answers "is this node's IP network usable right now?".
  198  bool __attribute__((weak)) externalRadioNetworkReady(void* /*ctx*/) {
  199      return WiFi.status() == WL_CONNECTED;
  200  }
```

**`lib/external_radio_protocol/external_radio_protocol.h:41-75`**
```
   41  // ---------------------------------------------------------------------------
   42  
   43  // Generic 2-byte magic ("XR" = eXternal Radio). Carries no vendor/daemon identity.
   44  static constexpr uint8_t  kMagic0      = 0x58;  // 'X'
   45  static constexpr uint8_t  kMagic1      = 0x52;  // 'R'
   46  static constexpr uint8_t  kVersion     = 0x01;
   47  
   48  // Header: magic[2] | version[1] | type[1] | length[2 BE] | seq[2 BE]
   49  static constexpr size_t   kHeaderSize  = 8;
   50  
   51  // Largest raw MeshCom packet handed to/from the radio (mirrors UDP_TX_BUF_SIZE).
   52  static constexpr uint16_t kMaxLoraPayload = 255;
   53  
   54  // Upper bound for any frame payload, derived from the largest message
   55  // (RX_PACKET = rssi[2]+snr[2]+len[2]+data[<=255] = 261; CONFIG_RESULT echo = 18).
   56  // Bounded with headroom; never exceeded by a legal frame.
   57  static constexpr uint16_t kMaxPayload  = 300;
   58  static constexpr size_t   kMaxFrame    = kHeaderSize + kMaxPayload;
   59  
   60  // ---------------------------------------------------------------------------
   61  // Message types (v1). Contiguous 0x01..0x0D.
   62  // ---------------------------------------------------------------------------
   63  enum MsgType : uint8_t {
   64      MSG_HELLO          = 0x01,
   65      MSG_HELLO_ACK      = 0x02,
   66      MSG_AUTH_CHALLENGE = 0x03,
   67      MSG_AUTH_RESPONSE  = 0x04,
   68      MSG_AUTH_RESULT    = 0x05,
   69      MSG_CONFIGURE      = 0x06,
   70      MSG_CONFIG_RESULT  = 0x07,
   71      MSG_RX_PACKET      = 0x08,
   72      MSG_TX_REQUEST     = 0x09,
   73      MSG_TX_RESULT      = 0x0A,
   74      MSG_PING           = 0x0B,
   75      MSG_PONG           = 0x0C,
```

**Espressif QEMU `hw/net/opencores_eth.c` at the pinned commit 40edccac (`:338-346`, `:504-507`)**
```
  338  static void open_eth_set_link_status(NetClientState *nc)
  339  {
  340      OpenEthState *s = qemu_get_nic_opaque(nc);
  341  
  342      if (GET_REGBIT(s, MIICOMMAND, SCANSTAT)) {
  343          SET_REGFIELD(s, MIISTATUS, LINKFAIL, nc->link_down);
  344      }
  345      mii_set_link(&s->mii, !nc->link_down);
  346  }
  504      .can_receive = open_eth_can_receive,
  505      .receive = open_eth_receive,
  506      .link_status_changed = open_eth_set_link_status,
  507  };
```

## Appendix E — the controller manifest and the lhpc-binaries smoke (excerpts)

**`lhpc/data/manifest.example.toml` (loraham-pi-control main)**
```
 1904      { argv = ["scripts/setup.sh", "--src", "https://github.com/icssw-org/MeshCom-Firmware.git", "--ref", "{pin:src/MeshCom-Firmware}"], announce = "[clone] MeshCom-Firmware at the manifest pin (the meshcom-firmware component's pin_commit) into the .work/ workspace — git is quiet off-TTY; progress: watch {source}/.work grow" },
 1905      { argv = ["scripts/apply-overlay.sh"], attributable = true },
 1906      { argv = ["scripts/prepare-openeth.sh"], env = { PIO = "{runtime}/build/tools/platformio/.venv/bin/pio", PLATFORMIO_CORE_DIR = "{runtime}/build/tools/platformio/core" }, announce = "[resolve] ESP32 platform + toolchain — large download, output is quiet; progress: watch {runtime}/build/tools/platformio/core grow" },
 1907      { argv = ["scripts/build.sh", "--env", "qemu-headless-extradio-gpsd"], env = { PIO = "{runtime}/build/tools/platformio/.venv/bin/pio", PLATFORMIO_CORE_DIR = "{runtime}/build/tools/platformio/core", XR_HOST = "<host-addr>", XR_PORT = "7000", XR_PASSWORD = "@file?:{runtime}/config/secrets/xr_pw" }, attributable = true },
 1918    run = "scripts/run.sh {env} {qemu} --node-image {runtime}/state/meshcom/node-flash.bin"
 1928    test = "scripts/test.sh --qemu {runtime}/build/tool-cache/qemu-xtensa/esp_develop_9.2.2_20260417_cache_iommu/qemu/bin/qemu-system-xtensa"
 1959      # ZERO-2W COLD-BOOT WINDOW: a QEMU/TCG cold boot on a Pi Zero 2W brings the console up only
 1960      # after MINUTES. The stepped `schedule` keeps an 8 s cadence for the first minute (Pi 4/5,
 1961      # warm boots), then 15 s, then a 30 s cap: a ~13 min window, which is a clock — a slow probe
 1962      # uses it up and no attempt starts after it. `lhpc stack poststart meshcom` re-runs this
```

**`builders/smoke.sh` (lhpc-binaries main), `smoke_meshcom`:**
```
   84      cd "$qpath"
   85      mkdir -p .run
   86      scripts/run.sh --qemu "$qemu_bin" --env qemu-headless-extradio-gpsd >.run/smoke-run.log 2>&1 &
   87      RUNPID=$!
   88      MARK='CLIENT STARTED|Console started on port 2323'
   89      booted=0
   90      for _ in $(seq 1 150); do
   91        UART="$(readlink -f .run/uart-latest.log 2>/dev/null || true)"
   92        if [ -n "$UART" ] && [ -f "$UART" ] && grep -qE "$MARK" "$UART"; then booted=1; break; fi
   93        if ! kill -0 "$RUNPID" 2>/dev/null; then echo "run.sh exited early"; break; fi
   94        sleep 4
   95      done
   96      if [ "$booted" != "1" ]; then
   97        echo "=== UART tail ==="; tail -60 "${UART:-/dev/null}" 2>/dev/null || true
   98        echo "=== run log ==="; tail -20 .run/smoke-run.log 2>/dev/null || true
   99        scripts/stop.sh >/dev/null 2>&1 || true
  100        echo "FAIL: firmware did not reach the boot marker" >&2; exit 7
  101      fi
  102      echo "SMOKE: boot marker seen"
  103      web=0
  104      for _ in $(seq 1 30); do
  105        code="$(curl -s -o .run/web.html -w '%{http_code}' --max-time 3 http://127.0.0.1:18083/ 2>/dev/null || true)"
  106        if [ "$code" = "200" ] && grep -qiE 'meshcom|<html|<!doctype' .run/web.html; then
  107          web=1; echo "web GUI 200 ($(wc -c <.run/web.html) bytes)"; break
  108        fi
  109        sleep 2
  110      done
  111      scripts/stop.sh >/dev/null 2>&1 || true
  112      if [ "$web" != "1" ]; then echo "FAIL: meshcom web GUI not reachable on :18083" >&2; exit 8; fi
  113      echo "SMOKE: PASS (meshcom boots + web GUI reachable on :18083)"
  114    )
  115  
  116    # --- bridge: exec + STARTUP path (the packaged bridge was only existence+ldd checked before) ---
```
