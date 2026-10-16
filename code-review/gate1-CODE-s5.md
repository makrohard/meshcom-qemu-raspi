# Gate 1, CODE: s5 runner (stock MeshCom in QEMU, our files only)

**Request.** Please review the code of branch `cons/s5-r1` (commits below, base `main` c2335d12) against its plan `plans/PLAN-s5-runner.md` (design v5, reviewed in five gate-1 rounds and one gate-2 round; its text is in file C as part of the diff). Judge per commit: correctness, fail-closed behaviour (provisioning, the supervisor, readiness), whether each test can fail and proves what it claims (the red-before and the failing controls), the deviations from the plan (report section), and whether docs and comments describe exactly the code. A FINDING needs the file:line and the smallest fix.

This file and its two companions, `gate1-CODE-s5.md` (this file), `gate1-CODE-s5-B.md` (diff of tests/ and .github/) and `gate1-CODE-s5-C.md` (diff of the docs, the plan and the removed patch), are your whole input: you have no repository access; use no connector, tool or web lookup.

**Answer form:** `| commit | verdict (OK / FINDING) | what |`, one row per commit, then the findings, then a final line GREEN / GREEN WITH NOTES / RED.

**Redaction:** two upstream call signs inside the removed patch (an upstream splash-credit string) are written `XX1XXX`. Nothing else is altered; the diffs are `git diff` output verbatim. `10.0.2.x` are QEMU's internal user-network addresses, `127.0.0.1` is loopback, `XX9TST-1` is a placeholder callsign.

---

## The commits (full messages)

### 9e732c6be543b017a0e9093cd10522615054ab52

s5: plan of record (design v5, gate 1 GREEN WITH NOTES, note applied)

The design reviewed in five gate-1 rounds and one gate-2 round, with the round-5 note applied: qemu_network.cpp is not unchanged, it gains the link-loss handling of section 1.1.

### 06aa48cd3936afe2a47c1bb4b710958437b7b24c

s5: stock MeshCom with our files only, no patch

The firmware patch goes: MeshCom f2b3a349 builds unmodified, and the QEMU target is new files only.
- variant: HAS_ETHERNET (upstream's Ethernet mode), placeholder W5500 pins, ENABLE_GPS in all four envs
  (src/loop_functions.cpp does not compile without one of its GPS guards), QEMU_GPS/GPSTEST removed,
  every env names variants/qemu-headless on its include path; comments rewritten to stock behaviour.
- ETHClass2.h / EthernetUdp.h: stand-ins for the two W5500 libraries upstream's Ethernet path calls;
  they report the OpenETH netif, so neth.initethDHCP() works under QEMU. The library downloads go.
- qemu_ethmode.cpp: a strong initVariant() starts OpenETH before setup(); a task publishes the address
  only with an open UDP socket (LOCAL_PORT, as before) and withdraws readiness whenever the netif is not
  ready. qemu_network.cpp: a link loss, a driver stop or a lost lease now clears readiness.
- apply-overlay.sh copies our files and refuses a tree with a modified tracked file (rc 4); the
  #pragma once step goes (upstream has it since 6966c52).
- setup.sh: DEFAULT_REF f2b3a349; an existing workspace is checked out with -f; the layout check names
  the files our code builds against.
- scripts/test-gps.sh goes: it read [GPSTEST] markers that only the patch printed.

Red-before: tests/test-apply-overlay.sh against the parent's apply-overlay.sh fails 4 of 4 cases
("patch not found"); against this commit it passes 4 of 4. All four envs build on f2b3a349 (x86_64).

### 98acdd3303bc12fbe283013aac41549cc5afc1e9

s5: run.sh supervises the guest and provisions a fresh node

- -no-reboot: a guest reset ends QEMU with rc 0; run.sh starts it again. TERM/INT latch a stop (QEMU
  gets TERM, 10 s, then KILL). Exit codes: 0 stopped, 1 setup, 2 usage, 3 provisioning failed, 5 QEMU
  error, 75 restart limit (3 runs shorter than 60 s in a row, or more than 10 restarts in an hour).
  Each restart is printed and recorded in .run/restarts; status.sh shows it.
- Ownership: run.sh holds .run/run.lock and the node-image lock for its whole life and writes run.pid
  and qemu.pid atomically. stop.sh signals run.pid only for the process holding that lock and qemu.pid
  only for a qemu-system-xtensa on a node image, and stops the runner first; it returns 0.
- Provisioning, when the node image has no marker for the current command list: MeshCom's own console
  commands over UART0 (placeholder Wi-Fi credentials, web server, console, mesh/gateway/extudp off, GPS
  on for *-gpsd, AP off, Ethernet mode). It counts only with the firmware's acknowledgement of
  --netmode eth and its rc-0 reboot; the marker is written only after the first supervised boot shows
  Ethernet mode and the console, its --info (held in memory, never written) shows Ethernet mode with
  mesh, extudp and gateway off, and the web page answers 200. Otherwise exit 3, no marker.
  node-image.sh deletes the marker before it writes an image without carried settings.
- uart-latest.log is removed at start and points only at supervised boots; provisioning logs to
  uart-provision-<UTC>.log.
- UART0 is -serial mon:stdio in every env (it was the -nographic default, and the GPS envs' explicit
  value): with a second monitor on .run/monitor.sock, -nographic no longer supplies it, and a plain
  stdio backend stops writing at stdin EOF.
- test.sh waits for the first supervised boot within the provisioning budget and scans the S5 lines.

Measured (x86_64, stock f2b3a349, a fresh node): provisioned and verified after 46 s; --setcall ->
restart #1, web 200, no AP line in that boot; stop.sh -> run.sh rc 0, no QEMU left. An earlier run of
this code with a plain stdio UART0 lost the console output; the check then never passed and run.sh
ended with rc 3 and no marker (fail-closed, as designed).

### 37ad374f354159f7dea7ba3d66907ba26e57b383

s5: tests for the supervisor, provisioning and the provisioning marker

tests/test-run-supervisor.sh (new, 25 cases, no QEMU, no network): a stub plays the firmware from a
plan per launch and serves a console and a web page for the persisted-state check. Provisioning:
verified marker, command order, marker sha, the --info reply never written, uart-latest points at the
supervised boot, no re-provisioning with the marker, re-provisioning for another command list; no ack,
rc 1, timeout and a persisted MESH on each -> rc 3 without a marker; TERM during provisioning -> rc 0;
an old uart-latest.log removed. Supervision: 3 fast runs -> 75, a long run resets the count, restarts
recorded, the hourly budget -> 75, QEMU rc 1 -> 5, a guest ignoring TERM killed after ~10 s, no launch
after a stop. Ownership: a second runner refused, a reused pid not signalled, stop.sh/status.sh rc 0.
run.sh reads FAST_RUN_S and RESTART_BUDGET (defaults 60 and 10) so the test runs in minutes.

tests/test-node-image.sh: the marker is dropped for an image created from the build and for a
partition-table reset, and kept when settings are carried; the lock-holder case now asserts that the
start is no longer refused (the stub's instant exit is a failed provisioning, rc 3).

Red-before: test-run-supervisor.sh against the parent's scripts: 7 FAIL, 3 ok, then the 580 s timeout
(the parent's run.sh never returns while a guest runs); here 25/25 pass in 176 s. The marker cases in
test-node-image.sh against the parent's node-image.sh: 2 of 3 FAIL; here ALL PASS.

### fa858d68ec41d3b95d552fc8201d4755b12aad88

s5: OpenETH static fallback only at start-up and only with the link up

The 8 s user-network static address (qemuMaybeApplyStatic) was applied whenever readiness was false and
8 s had passed since the driver start. After a link loss (readiness now false) that claimed an address
while the link was down; after the reconnect it raced DHCP and stopped the DHCP client. It now applies
only while the link is up and only if no DHCP lease arrived in this boot; a reconnect waits for GOT_IP.
The QEMU_TEST_NO_OPENETH test hook moves after esp_netif_init(): a driver that fails to start leaves the
TCP/IP stack up (before, upstream's sockets asserted on the uninitialised stack).

Red-before: boot gate (l), "set_link on: reported again and web 200 within 30 s", failed on the parent
(UART: "readiness withdrawn" at 6434 ms, then "applied SLIRP static" and "reported" at 8479 ms with the
link still down); with this commit the sequence is disconnected -> withdrawn -> connected -> GOT_IP ->
reported, and the gate passes.

### 8903f76f9a41e2948b9c6664f135e00cf4cb0b66

s5: build and boot gates on the real firmware, with a failing control per gate

tests/test-boot-gates.sh (slow; real PlatformIO, QEMU and bridge):
--main: (a) zero tracked MeshCom changes, four envs build; on a fresh node: (j) provisioned and
verified, --setcall gives one supervised restart with the AP flag off and the callsign kept; (b) the
address is reported before CLIENT SETUP, no W5500 init; (c) web 200 and an authenticated console;
(c-xr) CONFIG_RESULT and a position TX_REQUEST (payload byte 0 0x21) only after --sendpos, read off a
frame tap; (d) display probe returns, UBLOX detected, --pos shows a fix, one reset per boot; (f) MTU
1280 and a page over 1280 B arrives whole; (g) mesh/extudp/gateway off; (h) the spectrum page answers
within 60 s; (i) web and console answer while UART1 is written unpaced for 90 s; (e) --reboot gives a
supervised restart; (l) set_link off withdraws readiness within 10 s, set_link on restores it.
--controls: each gate's assertion fails on its control (a re-applied old hunk, no hand-over, --mesh on,
the relay off, --mtu 1500, run.sh without -no-reboot, --netconsole off).
--slow-b/-k/-k2/-l: a flag clear reaches upstream's initethDHCP() on the stand-in (and fails to build
without it); with OpenETH never starting the fallback's readiness never stands, nothing is reachable,
and a fresh node fails provisioning (rc 3); the old qemu_network.cpp fails gate l.
tests/xr-tap.py forwards the XR connection and logs each frame's direction, type and payload byte 0.

Measured on x86_64 (stock f2b3a349): --main 20/20, --controls 7/7, --slow-b 2/2, --slow-k 2/2,
--slow-k2 1/1, --slow-l 1/1 as expected. Gate k's evidence is upstream's own retry: initethDHCP() runs
again only while node_hasIPaddress is false, and upstream's ntpHarvestUDP() withdraws the fallback's
flag within a loop pass (before the hand-over task's withdrawal, which gate l exercises).

### 6f06c0a910533b355bb85f673db345d729371852

s5: README and STACK.md describe the stock-firmware runner

README rewritten (102 lines): what it is, a one-command run, the house rules (pin by commit, tag as a
label; our files only; the temporary QEMU speed patch and its exit; no secrets), how stock MeshCom runs
under QEMU (Ethernet mode with the stand-ins, -no-reboot and the supervisor with its exit codes,
provisioning and its check, the callsign), the four profiles, the tests and the weekly workflow (with
GitHub's 60-day pause), the pin move in five commands with how a break shows, the limitations, and the
verified block. STACK.md: the firmware is upstream at the pinned commit (the external radio is upstream
since PR #1072), setup.sh without the old fork branch, provisioning on the first start, the marker in the
reset note. fixtures/gps/README.md no longer names the removed scripts/test-gps.sh.

### 8397485210711573cfbc890c578de62da617ff1d

s5: weekly boot-gates workflow; the changed scripts pass shellcheck

.github/workflows/boot-gates.yml: weekly (Tuesday 03:41 UTC) and on dispatch, on ubuntu-24.04-arm (the
runner type the LoRaHAM binaries are built and smoke-tested on). It shellchecks the scripts this layout
added or changed (warning level), runs the quick tests, builds QEMU with scripts/build-qemu.sh (cached by
recipe and patch), builds the bridge at the controller's manifest pin, sets up MeshCom at upstream's dev
tip (schedule) or a given ref (dispatch; default DEFAULT_REF), and runs tests/test-boot-gates.sh --main
--controls --slow. A failure opens one issue titled "boot gates failing", or comments on the open one,
with the upstream commit and the FAIL lines; a pass is silent.

shellcheck 0.11.0 (-S warning) is clean on run.sh, stop.sh, status.sh, apply-overlay.sh, setup.sh,
node-image.sh, test.sh and the four changed tests: run.sh's libslirp check uses a glob loop instead of
ls | grep (same result), a local is declared before its assignment, and test-boot-gates.sh disables
SC2016/SC2034 for its eval'd gates as test-node-image.sh does. Not run in CI yet (no push).

### 041aa290f522f1a897846bc43b6c02d8c7639781

s5: the hand-over's log line after setup(); gate b reads upstream's ready line

The hand-over task's "[QEMU]...ethmode: IP <a> reported (<ms>)" line was missing in some boots while
the address was published (web, console and the XR link worked): a line written while setup()'s
Serial.begin() reinstalls the UART driver can be lost. The address is still published at once; the line
(with the publish time) and a new one-time "UDP port 1990 open failed" line are written from 5 s of
uptime on (the measured boots reach [BOOT];ready at 2-4 s).
Gate b now rests on upstream's own [BOOT];ready line, printed after setup() called startNetwork(): it
must show ip;1, no "[ETH] init" may have run, and the reported publish time must be earlier.

Measured: in two --main runs on the previous commit the line was absent once in the first boot and once
in the restart boot (gate b FAIL), with [BOOT];ready ...;ip;1 in both. The corrected check passes the
three boots of the latest run and fails a synthetic log with an [ETH] init and a later publish time.

### f7454a78993af02cf497718092b142e7c1d40b75

s5: gate b waits for the hand-over's line before it reads the boot log

The line is written from 5 s of uptime on, and the restart's gate ran as soon as the web page answered. Measured: a --main run on 041aa290 failed gate b on the restart boot, whose saved log shows the line (published at 360 ms, [BOOT];ready at 1942 ms with ip;1, no [ETH] line).

### 6e49bcb16a2fc342f476d2c94f79632d25a5f081

s5: the gates count one web 200 within a wait, not a second probe

The emulated web server is slow and drops some requests (scripts/test.sh treats it as a diagnostic for the same reason). Gates c, e, h, j, l and b' re-probed the page after a wait had already seen 200 and failed on the second probe. Measured: a --main run on f7454a78 failed gate l's web step although the wait loop had seen 200 nine seconds after the address returned (the re-report came 2 s after set_link on).

---

## The report (code-review/code-report-s5.md, verbatim)

# Code report s5 (A2): stock MeshCom in QEMU, our files only

Branch `cons/s5-r1`, base `main` c2335d12, plan `plans/PLAN-s5-runner.md` (design v5, gate 1 GREEN WITH NOTES, note applied).
All runs on an x86_64 Linux host (Fedora 43), MeshCom f2b3a349, QEMU esp-develop-9.2.2-20260417 + `patches/qemu` (a `build-qemu.sh` build: binary sha256 15eb3620…, patch sha256 c1e223db…), bridge at the controller's pin 7c86c96, PlatformIO 6.1.19.

## Commits
| commit | what | tests (layer: what is asserted) | red-before |
|---|---|---|---|
| 9e732c6b | plan of record, round-5 note applied (`qemu_network.cpp` is not unchanged) | — | — |
| 06aa48cd | our files only, no patch: variant (HAS_ETHERNET, ENABLE_GPS ×4, include path), ETHClass2/EthernetUDP stand-ins, `qemu_ethmode.cpp` (initVariant + hand-over + readiness withdrawal), `qemu_network.cpp` link loss, apply-overlay copy + check, setup.sh DEFAULT_REF/-f/layout list, test-gps.sh removed | quick: `test-apply-overlay.sh` 4 cases (copy targets, idempotence, rc 4 on a modified tracked file, rc 1 on missing files) | parent's apply-overlay.sh: 4/4 FAIL ("patch not found") |
| 98acdd33 | run.sh supervisor (-no-reboot, restarts, limits, exit codes, locks, pid files), provisioning with the persisted-state check, mon:stdio UART0, stop.sh identity checks, status.sh restarts, node-image.sh marker, test.sh wait | measured lifecycle (below); tests in the next commit | — (new behaviour; the next commit's tests are red on this commit's parent) |
| 37ad374f | quick tests: `test-run-supervisor.sh` (new, 25 cases), `test-node-image.sh` (+3 marker cases, lock case adjusted); run.sh FAST_RUN_S/RESTART_BUDGET knobs | quick: rc, marker present/absent, stub stdin, stub TERM/KILL notes, restart lines, pid not signalled | test-run-supervisor.sh on the parent's scripts: 7 FAIL, 3 ok, then the 580 s timeout; marker cases on the parent's node-image.sh: 2 of 3 FAIL |
| fa858d68 | OpenETH static fallback only at start-up and only with the link up; test hook moved after esp_netif_init() | slow gate l | gate l FAIL on the parent: "applied SLIRP static" + "reported" with the link down |
| 8903f76f | `tests/test-boot-gates.sh` (--main, --controls, --slow-b/-k/-k2/-l), `tests/xr-tap.py` | slow gates a–l + controls | each gate has a control that must fail (table below) |
| 6f06c0a9 | README (102 lines), STACK.md, fixtures/gps/README.md | — | — |
| 83974852 | weekly `boot-gates.yml` (ubuntu-24.04-arm); shellcheck-clean changed scripts (libslirp glob loop, local split, SC2016/SC2034 disable in the gate test) | quick tests rerun green | — |
| 041aa290 | the hand-over's log line from 5 s of uptime (publish time kept), a one-time UDP-open-failure line; gate b reads upstream's `[BOOT];ready;…;ip;1` | gate b | two --main runs: the line absent once per run (first boot / restart) with `ip;1` present |
| f7454a78 | gate b waits for the line | gate b | a --main run failed b on the restart; its saved log shows the line |
| 6e49bcb1 | gates count one web 200 within a wait (c, e, h, j, l, b′) | gates | a --main run failed l's web step after the wait had seen 200 |

## Evidence of record (HEAD 6e49bcb1)
- `--main` 21/21 as expected (392 s): a, j, b ×2, c, c-xr ×2, d, f, g, h, i, e, l ×3.
- `--controls --slow-l --slow-k2` 9/9 (390 s): controls a b c d e f g l, k2.
- `--slow-b` 2/2 (333 s), `--slow-k` 2/2 (574 s).
- Quick: test-apply-overlay 4/4, test-run-supervisor 25/25 (176 s), test-node-image 29 ok, test-node-efuse and test-setup-src pass.
- Lifecycle on a fresh node (98acdd33): verified after 46 s; `--setcall` → restart #1, web 200, no `WIFIAP starting`; stop.sh → run.sh rc 0, no QEMU left.

| gate | its failing control (measured: the assertion failed) |
|---|---|
| a | old hunk 14 re-applied → apply-overlay rc 4 |
| b | a build without the hand-over → the provisioning boot panics (Guru Meditation, Wi-Fi PHY) → rc 3, no marker |
| b′ | no ETHClass2.h → the build fails |
| c | `--netconsole off` → no console banner |
| c-xr | the 45 s window before `--sendpos`: no 0x21 frame (`0x40` frames and PING/PONG only) |
| d | relay off → `--pos` shows no fix |
| e | run.sh without `-no-reboot` → no restart line within 60 s |
| f | `--mtu 1500` → no `[NET];mtu;eth;1280` line (upstream prints it only on a change; lwIP's default is 1500) |
| g | `--mesh on` → `--info` reads `MESH on` |
| k | none natural (see "Found"); k2: a fresh node in that build → rc 3 |
| l | the old `qemu_network.cpp` → no withdrawal within 12 s |
| h, i | none natural (stated in the plan) |

## Found by the gates, fixed in this branch
1. **Static fallback with the link down** (fa858d68). After `set_link off`, `qemuNetworkReady()` applied the 8 s static address and reported the node ready while the link was down; after the reconnect it raced DHCP. Red-before: gate l's recovery step failed with that UART sequence.
2. **Lost log line** (041aa290). The hand-over line was missing in some boots although the address was published; a line written while `Serial.begin()` reinstalls the UART driver can be lost. Red-before: gate b failed in two runs with `ip;1` present.
3. **UART0 output lost with a second monitor** (98acdd33). With `-monitor unix:…`, `-nographic` no longer supplies `mon:stdio`, and a plain stdio UART stopped writing at stdin EOF. The first lifecycle run failed closed (rc 3, no marker). UART0 is `-serial mon:stdio` in every env.
Harness defects found and fixed while writing the tests: a field index in gate b, RESET_REASON counted in `--info` echoes (now `[BOOT] RESET_REASON`), SAT read from `--info` (it is `--pos`), the k hook placed before `esp_netif_init()`, slow modes building a stale copy (each now runs apply-overlay), a budget too small for one supervisor case, the tap's close race.

## Deviations from the plan (each with the reason)
- `scripts/test-gps.sh` removed: it asserted only `[GPSTEST]` markers that the patch printed; gate d replaces it. The other fixtures stay for manual runs.
- `qemu_network.h`: one comment rewritten (its readiness sentence became untrue). No code change.
- Gate k's evidence: upstream's own `ntpHarvestUDP()` mirrors `hasIPaddress` into `node_hasIPaddress` within a loop pass and withdraws the fallback's `true` before the hand-over task does. Gate k therefore asserts upstream's retry (at least two `[ETH] DHCP failed`; each retry needs the flag false), no panic and nothing reachable; the planned control "invariant removed" cannot fail on this path. The task's own withdrawal is exercised by gate l.
- Gate b's evidence: upstream's `[BOOT];ready;…;ip;1` (printed after `setup()` called `startNetwork()`), no `[ETH] init`, and the publish time before that line, instead of line order before `CLIENT SETUP`.
- The c control switches the console off at run time (no provisioning knob); d, f, g likewise at run time.
- run.sh test knobs `FAST_RUN_S`, `RESTART_BUDGET` (defaults 60, 10).
- run.sh adds `-monitor unix:.run/monitor.sock` (gate l) and names the NIC `net0`.
- setup.sh: an existing workspace is checked out with `-f`; the layout check names the files our code builds against.
- The slow cases are split into four modes so that each fits one foreground run.
- shellcheck in CI covers the files this branch added or changed (warning level). The untouched scripts have pre-existing findings (fetch-qemu.sh, lib-publish.sh, test-build-qemu.sh, test-setup-src.sh).

## Not covered yet
- aarch64: not run (the Pi 5 run and the lhpc-binaries smoke on the candidate are the next step).
- The weekly workflow has never run (the branch was not pushed before this report).
- The loraham backend with RX into the node, a live gpsd feed, the controller's post-step window on a Pi: the 0.12.10 live row.
- The other three envs are built, not booted.

## HOUSE RULES KEPT (checker output, verbatim)
```
HOUSE RULES KEPT  origin/main..HEAD
changelog    +0 bullets (limit 2, each ≤ 3 lines; longest 0), top section 0 lines   OK
docs         1 files, +94 lines; fact "f2b3a3496a76f327abec8b7228bce436cafe9606" -> README.md   OK
tests        0 new tests; layers -; red-before 0/0   OK
patterns     getsource 0 assert-True 0 source-read 0 sleep 0 startswith 0 network 0   OK
markers      0 without slow   OK
attribution  authors makrohard; trailers 0; words 0   OK
modules      N/A (budget table absent)   OK
VERDICT      PASS  (hard 0, warn 0)
```
The checker is built for the controller repository. Here: no CHANGELOG exists (N/A); its test lines count Python tests only, while the tests here are shell (red-before stated per commit above); the budget table is N/A.

## Six points
1. **Contracts:**
   - run.sh exit codes 0/1/2/3/5/75 (`scripts/run.sh:146-148`); the provisioning list `scripts/run.sh:177`; the marker `<UTC> <sha256>`;
   - apply-overlay rc 0/1/4 (`scripts/apply-overlay.sh:10-11`); stop.sh/status.sh rc 0;
   - `.run/{run.pid,qemu.pid,run.lock,restarts,monitor.sock,uart-latest.log,uart-provision-*.log}`.
2. **Invariants:**
   - zero MeshCom lines (gate a + control);
   - readiness never stands without the netif (gates l, k; control l);
   - no W5500 call at boot (gate b);
   - stop ≠ restart, no marker after a failed or signalled provisioning (test-run-supervisor);
   - provisioning only with verified persisted state (supervisor test "MESH on → 3", gate j).
3. **Failure classes:**
   - a signal during provisioning; a guest ignoring TERM (KILL after 10 s);
   - a reused pid, a second runner, a stale `uart-latest.log`, a changed command list, rc 0 without the ack, a provisioning timeout (all in test-run-supervisor);
   - a driver that never starts (gate k); a link loss (gate l); an unpaced UART (gate i).
   - The stubs model a process lifetime (TERM notes, ports served while alive).
4. **Test rules:** red-before per fix commit (table); every gate asserts a token, a code or an rc, never a sentence; no unconditional pass; three gates without a natural control are named.
5. **Runs:** all quick tests and all gate modes above, in the foreground; shellcheck 0.11.0 `-S warning` clean on the changed scripts.
6. **Adversarial self-review:** see "Found" and the harness list; the re-read also scoped CI shellcheck to the changed files, and fixed the gate test's `$?`-through-a-function, wipe-on-every-mode and node-sharing defects before its first run. Absolute words were checked: "zero MeshCom lines" is enforced by apply-overlay.sh; "never stands" is limited to what gates k/l measure; the residual ≤ 100 ms internal window is stated in the plan (R5).

## Numbers, measured
| figure | command | output |
|---|---|---|
| diff | `git diff --stat origin/main..HEAD \| tail -1` | 27 files, +1435/−1058 |
| removed patch | `git show origin/main:overlay/patches/meshcom-qemu-headless.patch \| wc -l` | 469 |
| run.sh before/after | `wc -l` at origin/main / HEAD | 137 / 267 |
| stop.sh before/after | same | 25 / 41 |
| apply-overlay.sh before/after | same | 82 / 35 |
| new C++ | `wc -l overlay/src/qemu/qemu_ethmode.cpp qemu_eth_standin.cpp` | 104, 35 |
| stand-in headers | `wc -l ETHClass2.h EthernetUdp.h` | 29, 9 |
| tests | `wc -l tests/test-run-supervisor.sh tests/test-boot-gates.sh tests/xr-tap.py` | 196, 282, 39 |
| README | `wc -l README.md` | 102 |
| gate results | `grep -cE '^PASS'` in the four final outputs | 21, 9, 2, 2 |
| quick results | test outputs | 4, 25, 29 ok |
| tracked MeshCom changes | gate a | 0 |

---

## Diff 1 of 3: overlay/src, overlay/variants, scripts (`git diff origin/main HEAD -- overlay/src overlay/variants scripts`)

```diff
diff --git a/overlay/src/qemu/qemu_eth_standin.cpp b/overlay/src/qemu/qemu_eth_standin.cpp
new file mode 100644
index 00000000..b45f7830
--- /dev/null
+++ b/overlay/src/qemu/qemu_eth_standin.cpp
@@ -0,0 +1,35 @@
+/*
+ * qemu_eth_standin.cpp — the ETHClass2 stand-in (variants/qemu-headless/ETHClass2.h) on top of
+ * qemu_network.cpp. QEMU_HEADLESS only.
+ */
+#ifdef QEMU_HEADLESS
+
+#include "qemu/qemu_network.h"
+#include <ETHClass2.h>
+
+ETHClass2 ETH;
+
+bool ETHClass2::begin(eth_phy_type_t, int32_t, int, int, int, spi_host_device_t, int, int, int) { return qemuNetworkStart(); }
+bool ETHClass2::begin() { return qemuNetworkStart(); }
+bool ETHClass2::linkUp() { return qemuNetworkReady(); }
+
+bool ETHClass2::config(IPAddress, IPAddress, IPAddress, IPAddress)
+{
+    Serial.println("[QEMU]...static IP not supported; the address comes from DHCP");
+    return false;
+}
+
+static IPAddress part(int which)
+{
+    IPAddress ip, gw, mask;
+    if (!qemuNetworkGetIp(ip, gw, mask))
+        return IPAddress();
+    return which == 0 ? ip : which == 1 ? gw : mask;
+}
+
+IPAddress ETHClass2::localIP() { return part(0); }
+IPAddress ETHClass2::gatewayIP() { return part(1); }
+IPAddress ETHClass2::subnetMask() { return part(2); }
+IPAddress ETHClass2::dnsIP() { return part(1); }   // QEMU user networking forwards DNS through the gateway side
+
+#endif // QEMU_HEADLESS
diff --git a/overlay/src/qemu/qemu_ethmode.cpp b/overlay/src/qemu/qemu_ethmode.cpp
new file mode 100644
index 00000000..a3a0bc80
--- /dev/null
+++ b/overlay/src/qemu/qemu_ethmode.cpp
@@ -0,0 +1,104 @@
+/*
+ * qemu_ethmode.cpp — QEMU-only: start OpenETH before setup() and report its address to MeshCom.
+ *
+ * Arduino-ESP32 calls the weak initVariant() before setup(); upstream does not define it, so this strong
+ * definition starts the OpenETH driver (qemu_network.cpp) without any change to a MeshCom file.
+ *
+ * The task below publishes the address the way upstream's own paths do. node_hasIPaddress must be true
+ * before setup() reaches startNetwork(): with it false, stock code in Wi-Fi mode (a fresh node, before
+ * provisioning) starts the Wi-Fi PHY, which QEMU does not emulate (a panic in register_chipv7_phy).
+ * The address is published only once the shared UDP socket is open.
+ *
+ * Readiness never outlives the netif: whenever node_hasIPaddress is true while qemuNetworkReady() is
+ * false (a link loss, an expired lease, a flag carried over in the saved settings, or upstream's
+ * DHCP-failure fallback in neth.initethDHCP(), which sets it after ETH.config() whatever that returns),
+ * the task withdraws it. In Ethernet mode the main loop then calls neth.initethDHCP() again, which runs
+ * against the ETHClass2 stand-in in the variant and retries the driver start.
+ */
+#ifdef QEMU_HEADLESS
+
+#include <Arduino.h>
+#include <WiFi.h>
+#include <WiFiUdp.h>
+#include <configuration.h>
+#include <esp32/esp32_flash.h>   // meshcom_settings
+#include "esp32/esp32_eth.h"
+#include "qemu/qemu_network.h"
+
+// startNetwork() names `neth` under HAS_ETHERNET; upstream defines it only for its two Ethernet boards.
+// Declared in the variant's configuration.h.
+EspETH neth;
+
+#define QEMU_LOG_AFTER_MS 5000UL
+
+extern WiFiUDP Udp;          // udp_functions.cpp
+extern bool hasIPaddress;    // udp_functions.cpp
+
+static void qemuEthModeTask(void *)
+{
+    // The address is published at once; its log line waits until setup() has run (5 s of uptime; the measured
+    // boots reach [BOOT];ready at 2-4 s), since a line written while Serial.begin() reinstalls the UART
+    // driver can be lost. The line carries the publish time.
+    bool reported = false;
+    unsigned long published_ms = 0;
+    char reported_ip[16] = "";
+    for (;;) {
+        IPAddress ip, gw, mask;
+        if (qemuNetworkReady() && qemuNetworkGetIp(ip, gw, mask)) {
+            if (!hasIPaddress) {
+                static bool udp_fail_logged = false;
+                if (Udp.begin(LOCAL_PORT)) {
+                    hasIPaddress = true;
+                } else if (!udp_fail_logged && millis() >= QEMU_LOG_AFTER_MS) {
+                    Serial.printf("[QEMU]...ethmode: UDP port %d open failed; retrying, address not published\n", LOCAL_PORT);
+                    udp_fail_logged = true;
+                }
+            }
+            if (hasIPaddress) {
+                char ip_s[16];
+                snprintf(ip_s, sizeof(ip_s), "%u.%u.%u.%u", ip[0], ip[1], ip[2], ip[3]);
+                if (!meshcom_settings.node_hasIPaddress || strcmp(meshcom_settings.node_ip, ip_s) != 0) {
+                    snprintf(meshcom_settings.node_ip, sizeof(meshcom_settings.node_ip), "%s", ip_s);
+                    snprintf(meshcom_settings.node_gw, sizeof(meshcom_settings.node_gw), "%u.%u.%u.%u", gw[0], gw[1], gw[2], gw[3]);
+                    snprintf(meshcom_settings.node_subnet, sizeof(meshcom_settings.node_subnet), "%u.%u.%u.%u", mask[0], mask[1], mask[2], mask[3]);
+                    meshcom_settings.node_hasIPaddress = true;
+                }
+                if (!published_ms) {
+                    published_ms = millis();
+                    snprintf(reported_ip, sizeof(reported_ip), "%s", ip_s);
+                }
+                if (!reported && millis() >= QEMU_LOG_AFTER_MS) {
+                    Serial.printf("[QEMU]...ethmode: IP %s reported (%lu ms)\n", reported_ip, published_ms);
+                    reported = true;
+                }
+            }
+        } else if (meshcom_settings.node_hasIPaddress || hasIPaddress) {
+            // ntpHarvestUDP() copies hasIPaddress into node_hasIPaddress, so both go.
+            meshcom_settings.node_hasIPaddress = false;
+            hasIPaddress = false;
+            reported = false;
+            published_ms = 0;
+            Serial.printf("[QEMU]...ethmode: no address; readiness withdrawn (%lu ms)\n", (unsigned long)millis());
+        }
+#ifdef QEMU_TEST_CLEAR_FLAG_MS
+        // Test build only (tests/test-boot-gates.sh, gate b'): clear the flag once and leave the
+        // hand-over to upstream's initethDHCP() path.
+        static bool cleared = false;
+        if (!cleared && millis() > QEMU_TEST_CLEAR_FLAG_MS) {
+            cleared = true;
+            meshcom_settings.node_hasIPaddress = false;
+            Serial.printf("[QEMU]...TEST: node_hasIPaddress cleared (%lu ms)\n", (unsigned long)millis());
+            vTaskSuspend(nullptr);
+        }
+#endif
+        vTaskDelay(pdMS_TO_TICKS(100));
+    }
+}
+
+void initVariant(void)
+{
+    qemuNetworkStart();
+    xTaskCreatePinnedToCore(qemuEthModeTask, "qemu_ethmode", 3072, nullptr, 1, nullptr, 1);
+}
+
+#endif // QEMU_HEADLESS
diff --git a/overlay/src/qemu/qemu_network.cpp b/overlay/src/qemu/qemu_network.cpp
index f35b5dac..125b9209 100644
--- a/overlay/src/qemu/qemu_network.cpp
+++ b/overlay/src/qemu/qemu_network.cpp
@@ -26,6 +26,8 @@ static volatile bool s_got_ip = false;
 // connectivity only. The default qemu-headless paths keep using s_got_ip/qemuNetworkReady().
 static volatile bool s_got_ip_event = false;
 static bool s_started = false;
+static volatile bool s_link_up = false;   // between ETHERNET_EVENT_CONNECTED and DISCONNECTED/STOP
+static volatile bool s_dhcp_seen = false; // a GOT_IP happened in this boot: the static fallback is start-up only
 static uint32_t s_start_ms = 0;
 static bool s_static_applied = false;
 static esp_eth_handle_t s_eth_handle = nullptr;
@@ -38,6 +40,7 @@ static void eth_event_handler(void *, esp_event_base_t, int32_t event_id, void *
     switch (event_id) {
     case ETHERNET_EVENT_CONNECTED:
         Serial.println("[QEMU]...OpenETH link connected");
+        s_link_up = true;
         // Belt-and-suspenders: ensure the DHCP client is running on the eth netif,
         // in case the glue auto-start did not run in this (non-Wi-Fi) Arduino context.
         if (s_eth_netif) {
@@ -45,11 +48,17 @@ static void eth_event_handler(void *, esp_event_base_t, int32_t event_id, void *
             Serial.printf("[QEMU]...dhcpc_start -> 0x%x (0=started, 0x%x=already-running)\n",
                           (int)de, ESP_ERR_ESP_NETIF_DHCP_ALREADY_STARTED);
         }
+        // The static user-network address (qemuMaybeApplyStatic) is not followed by a GOT_IP event,
+        // so a reconnect restores its readiness here; a DHCP address returns with GOT_IP.
+        if (s_static_applied)
+            s_got_ip = true;
         break;
     case ETHERNET_EVENT_DISCONNECTED:
         Serial.println("[QEMU]...OpenETH link disconnected");
-        // Genuine link loss: clear the strict event-readiness so the external-radio
-        // transport's gate drops and it stops safely (recovers on the next GOT_IP).
+        s_link_up = false;
+        // Link loss: neither readiness survives it. qemuNetworkGetIp() returns false while s_got_ip is
+        // false, so the stored address is not exposed until the link and an address return.
+        s_got_ip = false;
         s_got_ip_event = false;
         break;
     case ETHERNET_EVENT_START:
@@ -57,6 +66,8 @@ static void eth_event_handler(void *, esp_event_base_t, int32_t event_id, void *
         break;
     case ETHERNET_EVENT_STOP:
         Serial.println("[QEMU]...OpenETH driver stopped");
+        s_link_up = false;
+        s_got_ip = false;
         s_got_ip_event = false;
         break;
     default:
@@ -71,15 +82,16 @@ static void got_ip_event_handler(void *, esp_event_base_t, int32_t, void *event_
     Serial.printf("[QEMU]...OpenETH GOT_IP ip=" IPSTR " mask=" IPSTR " gw=" IPSTR "\n",
                   IP2STR(&s_ip_info.ip), IP2STR(&s_ip_info.netmask), IP2STR(&s_ip_info.gw));
     s_got_ip = true;
+    s_dhcp_seen = true;
     // Genuine IP event: this is the ONLY place strict event-readiness becomes true.
     s_got_ip_event = true;
 }
 
-// Genuine loss of a usable IPv4 lease (DHCP lease lost / link down). Clears strict
-// event-readiness; the external-radio transport gate drops and recovers on the next GOT_IP.
+// Loss of the IPv4 lease: both readiness flags go; they return with the next GOT_IP.
 static void lost_ip_event_handler(void *, esp_event_base_t, int32_t, void *)
 {
     Serial.println("[QEMU]...OpenETH LOST_IP (usable IPv4 lease lost)");
+    s_got_ip = false;
     s_got_ip_event = false;
 }
 
@@ -98,6 +110,10 @@ bool qemuNetworkStart()
         Serial.printf("[QEMU]...esp_event_loop_create_default failed: %d\n", (int)e);
         return false;
     }
+#ifdef QEMU_TEST_NO_OPENETH
+    // Test build only (tests/test-boot-gates.sh, gate k): the TCP/IP stack is up, the driver never starts.
+    return false;
+#endif
 
     esp_netif_inherent_config_t base_cfg = ESP_NETIF_INHERENT_DEFAULT_ETH();
     esp_netif_config_t netif_cfg = { &base_cfg, nullptr, ESP_NETIF_NETSTACK_DEFAULT_ETH };
@@ -154,7 +170,9 @@ bool qemuNetworkStart()
 #define QEMU_DHCP_TIMEOUT_MS 8000
 static void qemuMaybeApplyStatic()
 {
-    if (s_got_ip || s_static_applied || !s_started || !s_eth_netif)
+    // Start-up only (never after a DHCP lease in this boot: a reconnect gets its lease again), and only
+    // while the link is up: without it the address would claim a network that is not there.
+    if (s_got_ip || s_static_applied || s_dhcp_seen || !s_started || !s_eth_netif || !s_link_up)
         return;
     if (millis() - s_start_ms < QEMU_DHCP_TIMEOUT_MS)
         return;
diff --git a/overlay/src/qemu/qemu_network.h b/overlay/src/qemu/qemu_network.h
index 4fd674f2..7ef460ba 100644
--- a/overlay/src/qemu/qemu_network.h
+++ b/overlay/src/qemu/qemu_network.h
@@ -22,9 +22,9 @@
 // the driver; readiness is signalled later via qemuNetworkReady().
 bool qemuNetworkStart();
 
-// True once the QEMU PoC network is usable: after IP_EVENT_ETH_GOT_IP, OR after the
-// transparent SLIRP static fallback (see qemuMaybeApplyStatic). Used by the default
-// qemu-headless services (web UI / net-console / udp) in both environments.
+// True while the network is usable: after IP_EVENT_ETH_GOT_IP or the transparent SLIRP static
+// fallback (see qemuMaybeApplyStatic), and false again after a link loss, a driver stop or a lost
+// lease. Read by the address hand-over (qemu_ethmode.cpp) and the ETHClass2 stand-in.
 bool qemuNetworkReady();
 
 // STRICT, event-backed readiness: true ONLY after a genuine IP_EVENT_ETH_GOT_IP and
diff --git a/overlay/variants/qemu-headless/ETHClass2.h b/overlay/variants/qemu-headless/ETHClass2.h
new file mode 100644
index 00000000..8c09edb6
--- /dev/null
+++ b/overlay/variants/qemu-headless/ETHClass2.h
@@ -0,0 +1,29 @@
+/*
+ * ETHClass2.h — QEMU stand-in for the W5500 driver library that upstream's Ethernet mode calls
+ * (src/esp32/esp32_eth.cpp, EspETH::initethDHCP / initethfixIP). It keeps the names and maps them to
+ * the OpenETH netif that src/qemu/qemu_network.cpp brings up, so upstream's own hand-over code runs
+ * against the emulated network: no SPI, no W5500. Found first on the include path (-I variants/…).
+ */
+#pragma once
+
+#include <Arduino.h>
+#include <IPAddress.h>
+#include <driver/spi_common.h>   // spi_host_device_t / SPI3_HOST, as the real library provides
+
+typedef enum { ETH_PHY_W5500 } eth_phy_type_t;
+
+class ETHClass2 {
+public:
+    // The W5500 signature (phy, addr, cs, irq, rst, spi host, sck, miso, mosi); the pins are ignored.
+    bool begin(eth_phy_type_t type, int32_t phy_addr, int cs, int irq, int rst, spi_host_device_t spi_host, int sck, int miso, int mosi);
+    bool begin();
+    bool linkUp();
+    // A static address is not supported under QEMU: user networking assigns the guest address by DHCP.
+    bool config(IPAddress local_ip, IPAddress gateway, IPAddress subnet, IPAddress dns1 = IPAddress());
+    IPAddress localIP();
+    IPAddress gatewayIP();
+    IPAddress subnetMask();
+    IPAddress dnsIP();
+};
+
+extern ETHClass2 ETH;
diff --git a/overlay/variants/qemu-headless/EthernetUdp.h b/overlay/variants/qemu-headless/EthernetUdp.h
new file mode 100644
index 00000000..acbc1525
--- /dev/null
+++ b/overlay/variants/qemu-headless/EthernetUdp.h
@@ -0,0 +1,9 @@
+/*
+ * EthernetUdp.h — QEMU stand-in: upstream's Ethernet code keeps its own EthernetUDP socket
+ * (src/esp32/esp32_eth.h). Under QEMU that socket is an ordinary lwIP socket on the OpenETH netif.
+ */
+#pragma once
+
+#include <WiFiUdp.h>
+
+class EthernetUDP : public WiFiUDP {};
diff --git a/overlay/variants/qemu-headless/configuration.h b/overlay/variants/qemu-headless/configuration.h
index 3eb82807..cf524e0f 100644
--- a/overlay/variants/qemu-headless/configuration.h
+++ b/overlay/variants/qemu-headless/configuration.h
@@ -1,26 +1,23 @@
 /*
  * QEMU-headless variant configuration.
  *
- * A minimal CLASSIC-ESP32 application profile used ONLY for running MeshCom in
- * official ESP32 QEMU. It keeps just enough radio plumbing for the firmware to
- * COMPILE (SX126x chip selection + LoRa control pins), but deliberately enables
- * NO sensors, NO GPS, NO display, NO PMU. At runtime, QEMU_HEADLESS guards in
- * esp32_main.cpp prevent radio/BLE/display/battery/PMU/button initialisation, so
- * none of this hardware is actually driven (there is no such hardware in QEMU).
+ * A classic-ESP32 profile for running stock MeshCom in Espressif's QEMU. It defines what a variant
+ * must define for the firmware to compile and boot; no MeshCom file is changed. Under QEMU no radio
+ * chip, display, PMU, battery divider or BLE controller exists: with EXTERNAL_RADIO the firmware does
+ * not begin a local radio (upstream's own branch); without it radio.begin() finds no chip and the boot
+ * continues; the display probe finds nothing on I2C and the firmware runs without one; the PMU code is
+ * compiled only for XPOWERS chips, which this variant does not name; DISABLE_BATTERY/DISABLE_BLE below
+ * are upstream's opt-outs.
  *
- * Radio pin definitions are taken from the classic E22 (az-delivery-devkit-v4)
- * application profile so the RadioLib SX1268 module object constructs cleanly;
- * the radio is never brought up under QEMU.
- *
- * This file does NOT change any real board: it only applies to the private
- * qemu-headless target.
+ * Radio pin definitions are the classic E22 (az-delivery-devkit-v4) profile's, so the RadioLib SX1268
+ * module object constructs.
  */
 #pragma once
 
 #include <Arduino.h>
 #include <configuration_global.h>
 
-// --- Radio chip selection (compile-time only; radio.begin() is skipped in QEMU) ---
+// --- Radio chip selection (compile time; no chip exists under QEMU) ---
 #define MODUL_HARDWARE EBYTE_E22
 #define RF_FREQUENCY 433.175000
 #define LORA_APRS_FREQUENCY 433.775000
@@ -40,7 +37,7 @@
 #define SX1268_RST  LORA_RST
 #define SX1268_GPIO LORA_DIO0
 
-// LoRa parameters (used only for settings defaults; no RF in QEMU)
+// LoRa parameters (the settings defaults; with EXTERNAL_RADIO they configure the bridge's radio)
 #define LORA_PREAMBLE_LENGTH DEFAULT_PREAMPLE_LENGTH
 #define LORA_CR 6
 #define LORA_BANDWIDTH 250
@@ -51,14 +48,14 @@
 // antenna is on. (Until daemon 1.0.0 the range was 0..20 and this was 20; a firmware
 // built at 20 cannot configure an SX127x daemon at all.) The node's power (--txpower,
 // stored in NVS; this value by default) goes to the bridge at every XR connect and on a
-// change. Irrelevant to non-XR QEMU profiles (radio is disabled there).
+// change. Without the external radio no chip answers, so the value is unused.
 #define TX_POWER_MAX 17
 #define TX_POWER_MIN 2
 #define TX_OUTPUT_POWER 17
 #define CURRENT_LIMIT 140
 #define WAIT_TX 5
 
-// I2C pins (bus is initialised but no I2C peripherals are present/queried in QEMU)
+// I2C pins (the display probe runs on them and finds nothing under QEMU)
 #define I2C_SDA 21
 #define I2C_SCL 22
 
@@ -77,7 +74,23 @@
 #define LORA_SNR_STABLE_MIN_DB (-16)
 #endif
 
-// NOTE: intentionally NOT defined for the headless QEMU profile:
-//   ENABLE_GPS, ENABLE_BMX280, ENABLE_BMP390, ENABLE_AHT20, ENABLE_SHT21,
-//   ENABLE_BMX680, ENABLE_MCP23017, ENABLE_INA226, ENABLE_MC811, ENABLE_RTC,
-//   USE_BATT, HAS_TFT, OLED/display defines, XPOWERS_CHIP_* (PMU).
+// Upstream's Ethernet mode (node_netmode == 1) opens the web, net-console and startNetwork() paths without
+// Wi-Fi. Its W5500 calls reach ETHClass2.h in this directory, which reports the OpenETH netif; the pins
+// are placeholders.
+#define HAS_ETHERNET
+#define ETH_CS_PIN    15
+#define ETH_INT_PIN   4
+#define ETH_RST_PIN   25
+#define ETH_SCLK_PIN  18
+#define ETH_MISO_PIN  19
+#define ETH_MOSI_PIN  23
+// startNetwork() (src/udp_functions.cpp) names `neth` under HAS_ETHERNET; upstream declares and defines
+// it only for its two Ethernet boards. Declared here, defined in src/qemu/qemu_ethmode.cpp.
+#ifdef __cplusplus
+#include "esp32/esp32_eth.h"
+extern EspETH neth;
+#endif
+
+// Not defined for this profile: ENABLE_BMX280, ENABLE_BMP390, ENABLE_AHT20, ENABLE_SHT21,
+// ENABLE_BMX680, ENABLE_MCP23017, ENABLE_INA226, ENABLE_MC811, ENABLE_RTC, USE_BATT, HAS_TFT,
+// OLED/display defines, XPOWERS_CHIP_* (PMU). ENABLE_GPS comes from platformio.ini.
diff --git a/overlay/variants/qemu-headless/platformio.ini b/overlay/variants/qemu-headless/platformio.ini
index 18fe2dc3..68d6cd8d 100644
--- a/overlay/variants/qemu-headless/platformio.ini
+++ b/overlay/variants/qemu-headless/platformio.ini
@@ -1,14 +1,14 @@
-; Private QEMU-only headless target for running MeshCom under classic-ESP32 QEMU.
-; Classic ESP32 (esp32dev), the normal MeshCom application platform/framework
-; (inherited from [esp32]). NOT SafeBoot.
+; QEMU target for running stock MeshCom under classic-ESP32 QEMU (Espressif's qemu-system-xtensa).
+; Classic ESP32 (esp32dev), the normal MeshCom application platform/framework (inherited from [esp32]).
+; Not SafeBoot. Loaded by upstream's platformio.ini (extra_configs = variants/*/platformio.ini).
 ;
-; The ONLY behavioural change vs a normal classic build is gated on the
-; compile-time marker QEMU_HEADLESS (radio/BLE/display/battery/PMU/button runtime
-; init suppressed; networking via the project-local OpenETH driver instead of
-; Wi-Fi). No other target is affected by this file.
+; No MeshCom source file is changed. The target uses upstream's own switches: Ethernet mode
+; (HAS_ETHERNET + the persisted node_netmode = 1), DISABLE_BATTERY/DISABLE_BLE (configuration.h), the
+; external radio (EXTERNAL_RADIO), GPS (ENABLE_GPS). QEMU emulates the OpenCores Ethernet MAC instead of
+; a W5500, so ETHClass2.h/EthernetUdp.h in this directory stand in for the two W5500 libraries and
+; src/qemu/ brings up the OpenETH netif (scripts/apply-overlay.sh copies both into the stock tree).
 ;
-; The main MeshCom web UI uses CommonWebServer (WiFiServer over lwIP), so no
-; AsyncTCP/ESPAsyncWebServer dependency is required here.
+; The web UI uses CommonWebServer (WiFiServer over lwIP); no AsyncTCP dependency is needed.
 
 [env:qemu-headless]
 extends = esp32
@@ -18,12 +18,15 @@ monitor_speed = 115200
 ; Single-application layout so the app boots directly under QEMU (no SafeBoot).
 board_build.partitions = variants/qemu-headless/partitions-qemu.csv
 
+; ETHClass2 and Ethernet are the W5500 libraries; the headers in this directory replace them.
 lib_ignore =
 	AceButton
 	Adafruit TCA8418
 	epdiy
 	es7210
 	ESP32-audioI2S
+	ETHClass2
+	Ethernet
 	GxEPD2
 	lvgl
 	SensorLibTDECKpro
@@ -34,88 +37,50 @@ lib_ignore =
 lib_deps =
 	${libs.lib_deps}
 	${esp32libs.lib_deps}
-	; Display library is pulled by the common build; display init is skipped at runtime.
+	; The display library is pulled by the common build; at boot the display probe finds nothing.
 	olikraus/U8g2@^2.36.5
 
+; ENABLE_GPS in every env: upstream variants get it from src/configuration_default.h, which this
+; variant does not include, and src/loop_functions.cpp does not compile without it. GPS stays off at run
+; time unless provisioned (`--gps on`, the *-gpsd envs). GPS_RX_PIN/GPS_TX_PIN are UART1's pins; no
+; receiver is attached (the *-gpsd envs feed UART1 from scripts/gps-relay.py).
 build_flags =
 	${esp32.build_flags}
 	${common.build_flags}
 	-D BOARD_E22="qemu-headless"
 	-D QEMU_HEADLESS=1
-	-I variants/${this.__env__}
+	-D ENABLE_GPS
+	-D ENABLE_UBLOX
+	-D GPS_RX_PIN=16
+	-D GPS_TX_PIN=17
+	-D GPS_BAUDRATE_SETFIX=9600
+	-I variants/qemu-headless
 
-; --- Opt-in QEMU external-radio target (M13b) -------------------------------
-; The qemu-headless target (OpenETH networking; no radio/Wi-Fi/BLE/display/PMU)
-; PLUS the firmware's EXTERNAL_RADIO TCP transport, so the REAL MeshCom firmware
-; connects to a meshcom-loraham-bridge over the QEMU guest->host route (10.0.2.2).
-; The default [env:qemu-headless] target above is completely unaffected.
-;
-; The bridge endpoint and HMAC password are supplied LOCALLY at build time via
-; environment variables (NEVER committed):
-;     export XR_HOST=10.0.2.2 XR_PORT=7000 XR_PASSWORD=<secret>
+; --- External radio --------------------------------------------------------------------------------
+; Upstream's EXTERNAL_RADIO TCP transport connects the firmware to a meshcom-loraham-bridge over the QEMU
+; guest-to-host route. The bridge address and password come from the environment at build time and are
+; never committed:
+;     export XR_HOST=<host address> XR_PORT=7000 XR_PASSWORD=<secret>
 ;     scripts/build.sh --env qemu-headless-extradio
-; With XR_HOST/XR_PORT unset the firmware's transport stays idle; with no
-; XR_PASSWORD it runs open (the bridge requires HMAC, so set one).
-;
-; Network readiness uses the STRONG override in
-; src/qemu/qemu_external_radio_ready.cpp, which gates the connection on STRICT,
-; event-backed OpenETH IP connectivity (qemuNetworkReadyEvent()): true only after a
-; genuine IP_EVENT_ETH_GOT_IP and cleared on Ethernet loss — never true unconditionally
-; and never satisfied by the transparent SLIRP static fallback. The firmware's
-; Wi-Fi-specific 30s checkWifiPing watchdog is compiled out in EVERY qemu-headless env
-; (QEMU_HEADLESS-gated patch hunk): there is no Wi-Fi under QEMU, so it could only churn
-; the web/network lifecycle, close the shared UDP socket and trip the XR readiness gate.
-; The default [env:qemu-headless] keeps its SLIRP fallback.
+; An empty XR_PASSWORD still defines the macro, so the firmware runs password authentication with an
+; empty password; set one that matches the bridge.
+; Network readiness for the transport comes from src/qemu/qemu_external_radio_ready.cpp, a strong
+; definition of upstream's weak externalRadioNetworkReady(): true only after a genuine DHCP lease on the
+; OpenETH netif, false again on link loss.
 [env:qemu-headless-extradio]
 extends = env:qemu-headless
 build_flags =
 	${env:qemu-headless.build_flags}
-	-I variants/qemu-headless
 	-D EXTERNAL_RADIO=1
 	-D EXTERNAL_RADIO_HOST=\"${sysenv.XR_HOST}\"
 	-D EXTERNAL_RADIO_PORT=${sysenv.XR_PORT}
 	-D EXTERNAL_RADIO_PASSWORD=\"${sysenv.XR_PASSWORD}\"
 
-; --- Opt-in QEMU virtual-GPS targets (P2) ----------------------------------
-; Enable the REAL MeshCom GPS path (gps_functions.cpp / TinyGPSPlus), fed
-; line-oriented NMEA over the emulated UART1 (a Unix socket wired by run.sh; fed
-; by scripts/gps-relay.py from host gpsd or a synthetic fixture). The default
-; [env:qemu-headless] and [env:qemu-headless-extradio] targets are unaffected.
-;
-; Flags (GPS exists only where these are set; TinyGPSPlus is already inherited):
-;   QEMU_GPS            QEMU-only init branch in gps_functions.cpp: bypasses the
-;                       hardware bring-up (reset GPIO, baud auto-detect, UBX/PCAS
-;                       writes) and enables bGPSON, leaving the byte-by-byte
-;                       receive loop and fix/HDOP/sat/age logic unchanged.
-;   MESHCOM_QEMU_GPSTEST transition-only [GPSTEST] diagnostic (no coordinates) for
-;                       scripts/test-gps.sh; never in default/physical/extradio.
-;   GPS_RX_PIN/TX_PIN   SYNTHETIC, non-physical pins (16/17 free on esp32dev);
-;                       GPSSerial.begin() just needs args — no GPS HW in QEMU.
-;   GPS_BAUDRATE_SETFIX cosmetic over a socket UART (QEMU has no baud).
+; --- GPS fed over UART1 ----------------------------------------------------------------------------------
+; The same build as above; the name tells scripts/run.sh to wire UART1 to a host socket for
+; scripts/gps-relay.py and provisioning to send `--gps on`.
 [env:qemu-headless-gpsd]
 extends = env:qemu-headless
-build_flags =
-	${env:qemu-headless.build_flags}
-	-I variants/qemu-headless
-	-D ENABLE_GPS
-	-D ENABLE_UBLOX
-	-D QEMU_GPS=1
-	-D MESHCOM_QEMU_GPSTEST=1
-	-D GPS_RX_PIN=16
-	-D GPS_TX_PIN=17
-	-D GPS_BAUDRATE_SETFIX=9600
 
-; The integrated GPS + external-radio profile intentionally OMITS
-; MESHCOM_QEMU_GPSTEST: the [GPSTEST] diagnostics belong only to the test profile
-; above (qemu-headless-gpsd), keeping this XR-capable profile clean.
 [env:qemu-headless-extradio-gpsd]
 extends = env:qemu-headless-extradio
-build_flags =
-	${env:qemu-headless-extradio.build_flags}
-	-I variants/qemu-headless
-	-D ENABLE_GPS
-	-D ENABLE_UBLOX
-	-D QEMU_GPS=1
-	-D GPS_RX_PIN=16
-	-D GPS_TX_PIN=17
-	-D GPS_BAUDRATE_SETFIX=9600
diff --git a/scripts/apply-overlay.sh b/scripts/apply-overlay.sh
index c887c352..5e7ff12e 100755
--- a/scripts/apply-overlay.sh
+++ b/scripts/apply-overlay.sh
@@ -1,82 +1,35 @@
 #!/usr/bin/env bash
 #
-# apply-overlay.sh — add the QEMU-headless support to the fresh MeshCom workspace.
+# apply-overlay.sh — lay our files over the stock MeshCom workspace (.work/MeshCom-Firmware).
 #
-# Three parts:
-#   1) copy the new, self-contained files (private PlatformIO target + QEMU
-#      network module) into the workspace;
-#   2) apply one small patch that adds QEMU_HEADLESS-guarded branches to a few
-#      existing MeshCom source files (network readiness, hardware suppression,
-#      and the ADC battery guard);
-#   3) make `#pragma once` line 1 of src/configuration_global.h (a script step, so
-#      upstream version bumps do not break the patch).
+# Our files are new files only: the QEMU variant (overlay/variants/qemu-headless/, loaded by upstream's
+# `extra_configs = variants/*/platformio.ini`) and the QEMU network code (overlay/src/qemu/). No MeshCom
+# file is changed. After the copy the tree must have no modified tracked file; anything else means the
+# workspace is not stock MeshCom and the build is refused.
 #
-# Nothing is written until the patch state is known: the header check, then the patch's reverse check
-# (already applied) or `git apply --check` (applies cleanly). Only then are files copied and the patch
-# applied, so a drifted upstream fails loudly and leaves the firmware tree untouched.
+# EXIT CODES: 0 = copied, tree stock · 1 = workspace or overlay files missing · 4 = a tracked MeshCom
+# file is modified (listed).
 # Nothing outside .work/MeshCom-Firmware is modified.
 set -eu
 
 ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
 SRC="$ROOT/.work/MeshCom-Firmware"
 OVERLAY="$ROOT/overlay"
-PATCH="$OVERLAY/patches/meshcom-qemu-headless.patch"
 
-need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'. Install with: $2" >&2; exit 1; }; }
-need git "sudo apt-get install -y git"
-
-# Guard: only ever operate inside the workspace clone.
 [ -d "$SRC/.git" ] || { echo "ERROR: $SRC not found. Run scripts/setup.sh first." >&2; exit 1; }
-[ -f "$PATCH" ] || { echo "ERROR: patch not found: $PATCH" >&2; exit 1; }
-# Part 3 needs this upstream header. Check it here, before anything is copied or patched, so a missing header
-# fails with nothing changed.
-CG="$SRC/src/configuration_global.h"
-[ -f "$CG" ] || { echo "ERROR: upstream layout changed — missing 'src/configuration_global.h'. The overlay needs maintenance." >&2; exit 3; }
-
-# 3) `#pragma once` as line 1 of src/configuration_global.h (defined here, called last). Upstream's header
-#    has no include guard, and the extradio profiles include it twice in one translation unit
-#    (external_radio_glue.cpp: "redefinition of FLASH_STRUCT_LEGACY / flashLayoutCompatible / …"). A script
-#    step instead of a patch hunk: the hunk's only context were the version lines, so every upstream version
-#    bump broke the patch. Idempotent (it looks at line 1 only).
-ensure_pragma_once() {
-	local tmp="$CG.tmp.$$"
-	if [ "$(head -n 1 "$CG")" != "#pragma once" ]; then
-		{ echo "#pragma once"; cat "$CG"; } > "$tmp" || { rm -f "$tmp"; echo "ERROR: could not write $tmp" >&2; exit 3; }
-		mv -f "$tmp" "$CG"
-		echo "[overlay] added #pragma once to src/configuration_global.h"
-	fi
-}
+for d in variants/qemu-headless src/qemu; do
+	[ -n "$(ls -A "$OVERLAY/$d" 2>/dev/null)" ] || { echo "ERROR: overlay/$d is missing or empty." >&2; exit 1; }
+done
 
-# The patch state, before anything is written: already applied (a re-run), or it applies cleanly.
-cd "$SRC"
-already=0
-if git apply --reverse --check "$PATCH" >/dev/null 2>&1; then
-	already=1
-else
-	# The check's error text goes to a private per-run file, not a fixed /tmp path that two
-	# concurrent runs (or another user) would share.
-	ERRF="$(mktemp)"
-	trap 'rm -f "$ERRF"' EXIT
-	if ! git apply --check "$PATCH" 2>"$ERRF"; then
-		echo "ERROR: patch does not apply to this upstream revision." >&2
-		echo "       Upstream may have drifted; the overlay patch needs maintenance." >&2
-		sed 's/^/       | /' "$ERRF" >&2 || true
-		exit 4
-	fi
-fi
-
-# 1) new files (idempotent copy; also on a re-run, which refreshes them).
-echo "[overlay] copying new files (variants/qemu-headless, src/qemu)"
+echo "[overlay] copying our files (variants/qemu-headless, src/qemu)"
 mkdir -p "$SRC/variants/qemu-headless" "$SRC/src/qemu"
 cp -f "$OVERLAY"/variants/qemu-headless/* "$SRC/variants/qemu-headless/"
 cp -f "$OVERLAY"/src/qemu/* "$SRC/src/qemu/"
 
-# 2) patch existing files (already checked above).
-if [ "$already" = 1 ]; then
-	echo "[overlay] patch already applied; nothing to do."
-else
-	git apply "$PATCH"
-	echo "[overlay] applied $(basename "$PATCH") (QEMU_HEADLESS-guarded changes)."
+changed="$(git -C "$SRC" status --porcelain --untracked-files=no)"
+if [ -n "$changed" ]; then
+	echo "ERROR: the MeshCom workspace has modified tracked files; it must be stock MeshCom:" >&2
+	printf '%s\n' "$changed" | sed 's/^/       | /' >&2
+	exit 4
 fi
-
-ensure_pragma_once
+echo "[overlay] done; tracked MeshCom files modified: 0"
diff --git a/scripts/node-image.sh b/scripts/node-image.sh
index fae6f542..77da9550 100755
--- a/scripts/node-image.sh
+++ b/scripts/node-image.sh
@@ -26,6 +26,7 @@ umask 077   # the node image holds the node's settings, credentials included: ow
 BUILD="${1:?usage: node-image.sh BUILD NODE}"
 NODE="${2:?usage: node-image.sh BUILD NODE}"
 SIDE="$NODE.build-sha256"
+MARKER="$NODE.provisioned"   # run.sh's provisioning marker: only valid for an image with settings
 PREV="$NODE.prev"
 
 SECTOR=4096
@@ -51,6 +52,7 @@ block() { dd if="$1" bs="$SECTOR" skip="$2" count="$3" status=none; }
 BSHA="$(sha256sum -- "$BUILD" | cut -d' ' -f1)"
 
 if [ ! -f "$NODE" ]; then
+	rm -f -- "$MARKER"
 	install_file "$NODE" "$BUILD"
 	write_sidecar "$BSHA"
 	echo "[run] node image: created from the build ($NODE)"
@@ -72,6 +74,7 @@ if cmp -s <(block "$NODE" "$PT_BLOCK" 1) <(block "$BUILD" "$PT_BLOCK" 1); then
 	msg="new build, node settings carried over"
 else
 	msg="new build with a different partition table, node settings RESET"
+	rm -f -- "$MARKER"   # before the new image is published: a crash in between leaves no stale marker
 fi
 sync -- "$NEW"; mv -f -- "$NEW" "$NODE"; durable "$NODE"
 write_sidecar "$BSHA"
diff --git a/scripts/run.sh b/scripts/run.sh
index 26d8e8bb..37f49561 100755
--- a/scripts/run.sh
+++ b/scripts/run.sh
@@ -9,7 +9,10 @@
 # never installed by this script). QEMU is "soft-pinned": we detect the installed
 # version, record it, and warn if it differs from the verified build, but still run
 # (forward-compatible). Override the binary with `--qemu <path>` if needed.
-# The exact PID and UART log are written under .run/. Foreground; stop.sh stops it.
+# Foreground, and the guest's supervisor: a guest reset ends QEMU (-no-reboot) and this script starts it
+# again; a fresh node image is provisioned first (MeshCom's own console commands, then a check of the
+# persisted settings). PIDs (run.pid, qemu.pid), the restart count and the UART logs are under .run/;
+# stop.sh stops it.
 # QEMU runs on a NODE IMAGE, not on the build output: the node writes its settings (NVS) into the image
 # it runs on, and a rebuild or update replaces the build output. scripts/node-image.sh prepares the node
 # image from the build before every start and carries the settings into a new build
@@ -71,12 +74,22 @@ else
 	echo "[run] WARN: for the exact tested build: scripts/build-qemu.sh (esp-develop-9.2.2-20260417 + patches/qemu)" >&2
 fi
 [ -f "$FLASH" ] || { echo "ERROR: $FLASH not found. Run scripts/build.sh first." >&2; exit 1; }
-# One guest per node image: node-image.sh must never rewrite the image under a running QEMU. The lock is
-# held on fd 9 for QEMU's whole life (QEMU inherits the descriptor) and is released by the kernel when it
-# exits, so a crash leaves nothing stale behind.
+# --- Ownership --------------------------------------------------------------------------------------
+# One runner per checkout (.run/ is shared) and one guest per node image: both locks are held for the
+# runner's whole life, provisioning and restarts included, and released by the kernel when it exits.
+# stop.sh recognises this process by the open run.lock.
+exec 8>"$RUN/run.lock"
+flock -n 8 || { echo "ERROR: another run.sh already runs in this checkout; stop it first (scripts/stop.sh)." >&2; exit 1; }
 mkdir -p "$(dirname "$NODE_IMAGE")"
+NODE_IMAGE="$(cd "$(dirname "$NODE_IMAGE")" && pwd)/$(basename "$NODE_IMAGE")"
+NODE_EFUSE="$NODE_IMAGE.efuse"
+MARKER="$NODE_IMAGE.provisioned"
 exec 9>"$NODE_IMAGE.lock"
 flock -n 9 || { echo "ERROR: a QEMU guest already runs on $NODE_IMAGE; stop it first (scripts/stop.sh)." >&2; exit 1; }
+put() { local tmp="$1.tmp.$$"; printf '%s\n' "$2" > "$tmp"; mv -f "$tmp" "$1"; }
+put "$RUN/run.pid" "$$"
+# A stale pointer must never stand for this run: it reappears with the first supervised boot.
+rm -f "$RUN/uart-latest.log"
 "$ROOT/scripts/node-image.sh" "$FLASH" "$NODE_IMAGE"
 "$ROOT/scripts/node-efuse.sh" "$NODE_EFUSE"
 # libslirp is REQUIRED for the QEMU user-net (open_eth). Prefer the ldconfig cache, but fall back to a
@@ -84,38 +97,38 @@ flock -n 9 || { echo "ERROR: a QEMU guest already runs on $NODE_IMAGE; stop it f
 # ldconfig lives), and an off-PATH ldconfig must NOT be read as "library missing" (live finding — it
 # false-failed under lhpc's stack-run environment on a Pi Zero 2W). The library being present on disk is
 # authoritative regardless of whether ldconfig is reachable.
-{ ldconfig -p 2>/dev/null | grep -q 'libslirp\.so\.0'; } \
-	|| ls /lib/*/libslirp.so.0 /usr/lib/*/libslirp.so.0 /usr/lib/libslirp.so.0 2>/dev/null | grep -q libslirp || {
-	echo "ERROR: libslirp.so.0 missing. Install with: sudo apt-get install -y libslirp0" >&2; exit 1; }
-
-STAMP="$(date +%Y%m%d-%H%M%S)"
-UARTLOG="$RUN/uart-$STAMP.log"
-ln -sf "uart-$STAMP.log" "$RUN/uart-latest.log"
+slirp=0
+{ ldconfig -p 2>/dev/null | grep -q 'libslirp\.so\.0'; } && slirp=1
+for f in /lib/*/libslirp.so.0 /usr/lib/*/libslirp.so.0 /usr/lib/libslirp.so.0; do [ -e "$f" ] && slirp=1; done
+[ "$slirp" = 1 ] || { echo "ERROR: libslirp.so.0 missing. Install with: sudo apt-get install -y libslirp0" >&2; exit 1; }
 
 # Commas below are intentional inside quoted QEMU option strings.
 # shellcheck disable=SC2054
 QEMU_CMD=(
 	"$QEMU_BIN"
 	-nographic
+	-no-reboot   # a guest reset exits QEMU (inside qemu-xtensa a reset wedges in the ROM); this script restarts it
 	-machine esp32
 	-m 4M
 	-drive "file=$NODE_IMAGE,if=mtd,format=raw"
 	-drive "file=$NODE_EFUSE,if=none,format=raw,id=efuse"
 	-global driver=nvram.esp32.efuse,property=drive,value=efuse
-	-nic "user,model=open_eth,hostfwd=tcp:127.0.0.1:18083-:80,hostfwd=tcp:127.0.0.1:12323-:2323"
+	-nic "user,id=net0,model=open_eth,hostfwd=tcp:127.0.0.1:18083-:80,hostfwd=tcp:127.0.0.1:12323-:2323"
 	-global driver=timer.esp32.timg,property=wdt_disable,value=true
+	# UART0 = the console on stdio. mon:stdio (as -nographic sets by default) keeps the output flowing when
+	# stdin is at EOF (a background job's stdin); a plain stdio backend stops there. The monitor socket
+	# (for set_link and friends) is a second monitor.
+	-serial mon:stdio
+	-monitor "unix:$RUN/monitor.sock,server=on,wait=off"
 )
 
 if [ "$GPS" = "1" ]; then
-	# UART0 stays the console: mon:stdio mux's the monitor + serial0 onto stdio,
-	# exactly as -nographic does by default, so the existing UART log is unchanged.
-	# UART1 is a dedicated host Unix socket carrying incoming NMEA (QEMU is the
-	# server so it boots independently; scripts/gps-relay.py is the client). UART2
-	# is explicit null so QEMU does not auto-route it to stdio.
+	# UART1 is a dedicated host Unix socket carrying incoming NMEA (QEMU is the server so it boots
+	# independently; scripts/gps-relay.py is the client). UART2 is explicit null so QEMU does not
+	# auto-route it to stdio.
 	rm -f "$GPS_SOCK"
 	# shellcheck disable=SC2054
 	QEMU_CMD+=(
-		-serial mon:stdio
 		-chardev "socket,id=gps1,path=$GPS_SOCK,server=on,wait=off"
 		-serial chardev:gps1
 		-serial null
@@ -128,10 +141,127 @@ echo "[run] $(printf '%q ' "${QEMU_CMD[@]}")" > "$RUN/qemu-cmdline.txt"
 echo "[run] web UI:      http://127.0.0.1:18083/"
 echo "[run] net-console: 127.0.0.1:12323"
 [ "$GPS" = "1" ] && echo "[run] GPS UART1:    $GPS_SOCK    (feed: scripts/gps-relay.py --uart $GPS_SOCK …)"
-echo "[run] UART log:    $UARTLOG    (stop: scripts/stop.sh)"
 
-"${QEMU_CMD[@]}" >> "$UARTLOG" 2>&1 &
-QPID=$!
-echo "$QPID" > "$RUN/qemu.pid"
-echo "[run] QEMU pid $QPID"
-wait "$QPID"
+# --- Supervisor -------------------------------------------------------------------------------------
+# A guest reset under -no-reboot ends QEMU with rc 0 and no signal: that is a restart. TERM/INT latch
+# STOP; QEMU gets TERM, 10 s, then KILL. EXIT CODES: 0 stopped · 1 setup error · 2 usage · 3 provisioning
+# failed · 5 QEMU exited with an error · 75 restart limit (3 runs < 60 s in a row, or > 10 restarts/hour).
+STOP=0
+QPID=""
+stop_qemu() {
+	[ -n "$QPID" ] || return 0
+	kill -TERM "$QPID" 2>/dev/null || true
+	for _ in $(seq 1 10); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
+	kill -KILL "$QPID" 2>/dev/null || true
+	wait "$QPID" 2>/dev/null || true
+	QPID=""
+}
+on_signal() { STOP=1; stop_qemu; rm -f "$RUN/run.pid"; exit 0; }
+trap on_signal TERM INT
+qemu_alive() { [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; }
+# launch LOG [stdin-fd]: start QEMU in the background, its UART0 appended to LOG.
+launch() {
+	if [ -n "${2:-}" ]; then "${QEMU_CMD[@]}" <&"$2" >> "$1" 2>&1 &
+	else "${QEMU_CMD[@]}" >> "$1" 2>&1 & fi
+	QPID=$!
+	put "$RUN/qemu.pid" "$QPID"
+	echo "[run] QEMU pid $QPID, UART log $1"
+}
+# wait_rc: the exit code of the QEMU just ended.
+wait_rc() { local rc=0; wait "$QPID" || rc=$?; QPID=""; return "$rc"; }
+
+# --- Provisioning (a node image without a matching marker) -----------------------------------------
+# The persistent settings come from MeshCom's own console commands, sent over UART0 once. The
+# placeholders keep the web server on (stock code turns it off without Wi-Fi credentials and an AP);
+# they are inert in Ethernet mode. `--netmode eth` makes the firmware reboot itself 5 s later.
+PROVISION_CMDS=("--setssid qemu0" "--setpwd qemu0000" "--webserver on" "--netconsole on" "--mesh off"
+	"--gateway off" "--extudp off")
+[ "$GPS" = "1" ] && PROVISION_CMDS+=("--gps on")
+PROVISION_CMDS+=("--wifiap off" "--netmode eth")
+PROVISION_SHA="$(printf '%s\n' "${PROVISION_CMDS[@]}" | sha256sum | cut -d' ' -f1)"
+PROVISION_TIMEOUT="${PROVISION_TIMEOUT:-900}"
+DEADLINE=0
+provision_fail() { echo "[run] provisioning FAILED: $1 (log: $2)" >&2; stop_qemu; exit 3; }
+
+provision() {
+	local log fifo="$RUN/uart0.in" c
+	log="$RUN/uart-provision-$(date -u +%Y%m%dT%H%M%SZ).log"
+	DEADLINE=$(( $(date +%s) + PROVISION_TIMEOUT ))
+	echo "[run] provisioning the node (log $log)"
+	rm -f "$fifo"; mkfifo -m 600 "$fifo"; exec 7<>"$fifo"; rm -f "$fifo"
+	launch "$log" 7
+	until grep -aq 'CLIENT STARTED' "$log"; do
+		qemu_alive || provision_fail "QEMU ended before the firmware started" "$log"
+		[ "$(date +%s)" -lt "$DEADLINE" ] || provision_fail "timeout before the firmware started" "$log"
+		sleep 1
+	done
+	sleep 3
+	for c in "${PROVISION_CMDS[@]}"; do printf '%s\r\n' "$c" >&7; sleep 1; done
+	while qemu_alive; do
+		[ "$(date +%s)" -lt "$DEADLINE" ] || provision_fail "timeout waiting for the firmware's reboot" "$log"
+		sleep 1
+	done
+	local rc=0; wait_rc || rc=$?
+	exec 7>&-
+	[ "$rc" = 0 ] || provision_fail "QEMU exited rc=$rc" "$log"
+	grep -aq '\[CMD\] netmode -> Ethernet' "$log" || provision_fail "no acknowledgement of --netmode eth" "$log"
+}
+
+# verify_persisted LOG: the first supervised boot shows Ethernet mode and the console, then the console's
+# --info and the web page confirm the persisted settings. The --info reply is held in a variable only:
+# it carries a password field and is never written.
+verify_persisted() {
+	local log="$1" info code
+	grep -aq '\[NET\] Ethernet mode' "$log" && grep -aq 'Console started on port 2323' "$log" || return 1
+	info="$(timeout 20 bash -c 'exec 3<>/dev/tcp/127.0.0.1/12323 || exit 1; sleep 2; printf "%s\r\n" "--info" >&3; timeout 8 cat <&3' 2>/dev/null || true)"
+	case "$info" in *"Console"*) ;; *) echo "[run] provisioning check: the console did not answer like MeshCom's (a console password?)" >&2; return 1 ;; esac
+	for t in 'NETWORK Mode:ETH' '...MESH off' '...EXTUDP off' 'Gateway off'; do
+		case "$info" in *"$t"*) ;; *) echo "[run] provisioning check: '--info' lacks '$t'" >&2; return 1 ;; esac
+	done
+	code="$(timeout 15 bash -c 'exec 4<>/dev/tcp/127.0.0.1/18083 || exit 1; printf "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n" >&4; head -n 1 <&4' 2>/dev/null || true)"
+	case "$code" in *" 200"*) return 0 ;; *) echo "[run] provisioning check: web answered '${code%$'\r'}'" >&2; return 1 ;; esac
+}
+
+VERIFY=0
+if [ "$(cat "$MARKER" 2>/dev/null | cut -d' ' -f2)" != "$PROVISION_SHA" ]; then
+	provision
+	VERIFY=1
+fi
+
+# --- The supervised runs ----------------------------------------------------------------------------
+# FAST_RUN_S / RESTART_BUDGET: the limits (60 s, 10 per hour); tests/test-run-supervisor.sh lowers them.
+FAST_RUN_S="${FAST_RUN_S:-60}"; RESTART_BUDGET="${RESTART_BUDGET:-10}"
+fast=0; n=0; recent=()
+while :; do
+	[ "$STOP" = 0 ] || exit 0
+	STAMP="$(date +%Y%m%d-%H%M%S)"
+	UARTLOG="$RUN/uart-$STAMP.log"
+	ln -sf "uart-$STAMP.log" "$RUN/uart-latest.log"
+	t0="$(date +%s)"
+	launch "$UARTLOG"
+	while qemu_alive; do
+		if [ "$VERIFY" = 1 ]; then
+			if verify_persisted "$UARTLOG"; then
+				[ "$STOP" = 0 ] || break
+				put "$MARKER" "$(date -u +%Y-%m-%dT%H:%M:%SZ) $PROVISION_SHA"
+				VERIFY=0
+				echo "[run] provisioning verified; marker written ($MARKER)"
+			elif [ "$(date +%s)" -ge "$DEADLINE" ]; then
+				provision_fail "the persisted settings could not be verified" "$UARTLOG"
+			fi
+		fi
+		sleep 1
+	done
+	rc=0; wait_rc || rc=$?
+	[ "$STOP" = 0 ] || exit 0
+	[ "$VERIFY" = 0 ] || provision_fail "the first supervised boot ended before the check" "$UARTLOG"
+	[ "$rc" = 0 ] || { echo "[run] QEMU exited rc=$rc" >&2; exit 5; }
+	now="$(date +%s)"; dur=$(( now - t0 ))
+	if [ "$dur" -lt "$FAST_RUN_S" ]; then fast=$((fast+1)); else fast=0; fi
+	[ "$fast" -lt 3 ] || { echo "[run] restart limit: 3 runs shorter than $FAST_RUN_S s in a row" >&2; exit 75; }
+	keep=(); for t in "${recent[@]}" "$now"; do [ $(( now - t )) -lt 3600 ] && keep+=("$t"); done; recent=("${keep[@]}")
+	[ "${#recent[@]}" -le "$RESTART_BUDGET" ] || { echo "[run] restart limit: more than $RESTART_BUDGET restarts within one hour" >&2; exit 75; }
+	n=$((n+1))
+	echo "[run] guest reset after $dur s -> restart #$n"
+	put "$RUN/restarts" "$n $(date -u +%Y-%m-%dT%H:%M:%SZ)"
+done
diff --git a/scripts/setup.sh b/scripts/setup.sh
index 2d26a7ba..aa14be2a 100755
--- a/scripts/setup.sh
+++ b/scripts/setup.sh
@@ -3,7 +3,7 @@
 # setup.sh — fetch the MeshCom firmware source into the local workspace.
 #
 # By default it checks out a KNOWN-WORKING, PINNED MeshCom commit
-# (DEFAULT_REF below) — the overlay patch applies to it.
+# (DEFAULT_REF below), the commit our files are validated against.
 # The pin is configurable:
 #   scripts/setup.sh                 # pinned (default, recommended)
 #   scripts/setup.sh --dev           # latest upstream dev branch (moving target)
@@ -22,9 +22,9 @@ RUN="$ROOT/.run"
 # Official upstream MeshCom firmware repository.
 UPSTREAM_URL="https://github.com/icssw-org/MeshCom-Firmware.git"
 
-# Pinned commit; the overlay patch applies to it.
+# Pinned by commit; upstream moves tags (v4.40a.hbserver moved on 2026-10-13), so a tag is only a label.
 # (Configurable: edit this, or override per-run with --dev / --ref.)
-DEFAULT_REF="ad36784f8d93d93d9569de9334e089ec3cfed5b5"   # icssw-org dev ad36784f (2026-09-28, with PR #1164/#1165/#1166) — the overlay applies to it
+DEFAULT_REF="f2b3a3496a76f327abec8b7228bce436cafe9606"   # icssw-org dev f2b3a349 (2026-10-13; tag v4.40a.hbserver at the time)
 REF="$DEFAULT_REF"
 # Opt-in: fetch the firmware from another repository (a local path or a fork URL) instead of upstream.
 # Used by the external-radio validation to run a local feature branch WITHOUT
@@ -69,7 +69,9 @@ elif [ -d "$SRC/.git" ]; then
 	echo "[setup] workspace already present at $SRC; fetching latest"
 	git -C "$SRC" remote set-url origin "$UPSTREAM_URL"
 	git -C "$SRC" fetch --depth 1 origin "$REF"
-	git -C "$SRC" checkout -q FETCH_HEAD
+	# -f: the workspace belongs to these scripts; a tracked file left modified (by an older runner that
+	# patched MeshCom) is reset to the stock file, which apply-overlay.sh then requires.
+	git -C "$SRC" checkout -q -f FETCH_HEAD
 else
 	# fetch-by-ref, not `clone --branch`: a pinned commit SHA is a valid ref here (the
 	# lhpc manifest passes one), and `--branch` accepts only branch and tag names.
@@ -85,10 +87,10 @@ SHA="$(git -C "$SRC" rev-parse HEAD)"
 echo "$SHA" > "$RUN/meshcom-source.sha"
 date -u +"%Y-%m-%dT%H:%M:%SZ" > "$RUN/meshcom-source.timestamp"
 
-# --- fail clearly if the layout the overlay expects is not present ---
-for p in platformio.ini src/esp32/esp32_main.cpp src/web_functions/web_functions.cpp \
-         src/net_console.cpp src/udp_functions.cpp src/batt_function_old.cpp; do
-	[ -e "$SRC/$p" ] || { echo "ERROR: upstream layout changed — missing '$p'. The overlay/patch may need maintenance." >&2; exit 3; }
+# --- fail clearly if a file our code builds against is missing ---
+for p in platformio.ini src/configuration_global.h src/udp_functions.cpp src/esp32/esp32_eth.cpp \
+         src/esp32/esp32_eth.h src/esp32/esp32_flash.h src/esp32/external_radio_glue.cpp; do
+	[ -e "$SRC/$p" ] || { echo "ERROR: upstream layout changed — missing '$p'. Our files need maintenance." >&2; exit 3; }
 done
 grep -q 'variants/\*/platformio.ini' "$SRC/platformio.ini" || \
 	echo "[setup] WARN: top-level platformio.ini no longer globs variants/*; the qemu-headless env may not be picked up."
diff --git a/scripts/status.sh b/scripts/status.sh
index 33872b20..ae4c2993 100755
--- a/scripts/status.sh
+++ b/scripts/status.sh
@@ -15,6 +15,7 @@ if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
 else
 	echo "qemu   : not running"
 fi
+[ -f "$RUN/restarts" ] && echo "resets : $(cut -d' ' -f1 "$RUN/restarts") guest restart(s), last at $(cut -d' ' -f2 "$RUN/restarts")" || true
 UART="$RUN/uart-latest.log"
 if [ -f "$UART" ]; then
 	echo "net    : $(grep -oE 'GOT_IP ip=[0-9.]+' "$UART" | tail -1 || echo 'no IP yet')"
@@ -24,3 +25,4 @@ if command -v curl >/dev/null 2>&1; then
 	code="$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' http://127.0.0.1:18083/ 2>/dev/null || echo 000)"
 	echo "http   : GET http://127.0.0.1:18083/ -> $code"
 fi
+exit 0
diff --git a/scripts/stop.sh b/scripts/stop.sh
index 05428d77..e503425e 100755
--- a/scripts/stop.sh
+++ b/scripts/stop.sh
@@ -1,25 +1,41 @@
 #!/usr/bin/env bash
 #
-# stop.sh — stop ONLY the QEMU instance started by run.sh (exact recorded PID).
+# stop.sh — stop the runner (scripts/run.sh) and its QEMU guest.
+#
+# A PID file is trusted only for a process that still is what it names: run.pid only if that process
+# holds this checkout's .run/run.lock open, qemu.pid only if that process is qemu-system-xtensa using a
+# node image of this runner. A stale or reused PID is never signalled; its file is removed.
+# EXIT CODE: 0, also when nothing runs.
 set -eu
-
 ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
-PIDFILE="$ROOT/.run/qemu.pid"
+RUN="$ROOT/.run"
 
-[ -f "$PIDFILE" ] || { echo "[stop] no $PIDFILE (nothing recorded to stop)."; exit 0; }
-PID="$(cat "$PIDFILE")"
-[ -n "$PID" ] || { echo "[stop] empty pid file."; exit 0; }
+is_runner() { [ -n "$1" ] && find "/proc/$1/fd" -maxdepth 1 -lname "$RUN/run.lock" 2>/dev/null | grep -q .; }
+is_qemu() { [ -n "$1" ] && { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null | grep -q 'qemu-system-xtensa .*-drive file=.*\.bin,if=mtd'; }
+# stop_pid PID: TERM, up to 15 s, then KILL.
+stop_pid() {
+	kill -TERM "$1" 2>/dev/null || true
+	for _ in $(seq 1 15); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
+	echo "[stop] pid $1 still alive; SIGKILL"; kill -KILL "$1" 2>/dev/null || true
+}
 
-if ! kill -0 "$PID" 2>/dev/null; then
-	echo "[stop] pid $PID not running."
-	rm -f "$PIDFILE"; exit 0
+stopped=0
+RPID="$(cat "$RUN/run.pid" 2>/dev/null || true)"
+if is_runner "$RPID"; then
+	echo "[stop] SIGTERM to the runner, pid $RPID (it stops its QEMU)"
+	stop_pid "$RPID"; stopped=1
+elif [ -n "$RPID" ]; then
+	echo "[stop] run.pid $RPID is not this checkout's runner; not signalled"
 fi
+rm -f "$RUN/run.pid"
 
-echo "[stop] SIGTERM to qemu pid $PID"
-kill -TERM "$PID" 2>/dev/null || true
-for _ in $(seq 1 10); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
-if kill -0 "$PID" 2>/dev/null; then echo "[stop] still alive; SIGKILL"; kill -KILL "$PID" 2>/dev/null || true; fi
-rm -f "$PIDFILE"
-# QEMU removes its own server socket on a clean exit; remove any leftover after a kill.
-rm -f "$ROOT/.run/gps-uart1.sock"
-echo "[stop] stopped."
+QPID="$(cat "$RUN/qemu.pid" 2>/dev/null || true)"
+if is_qemu "$QPID"; then
+	echo "[stop] SIGTERM to qemu pid $QPID"
+	stop_pid "$QPID"; stopped=1
+elif [ -n "$QPID" ] && [ "$stopped" = 0 ]; then
+	echo "[stop] qemu.pid $QPID is not a running guest; not signalled"
+fi
+rm -f "$RUN/qemu.pid" "$RUN/gps-uart1.sock"
+[ "$stopped" = 1 ] && echo "[stop] stopped." || echo "[stop] nothing was running."
+exit 0
diff --git a/scripts/test-gps.sh b/scripts/test-gps.sh
deleted file mode 100755
index 025075a2..00000000
--- a/scripts/test-gps.sh
+++ /dev/null
@@ -1,108 +0,0 @@
-#!/usr/bin/env bash
-#
-# test-gps.sh — automated QEMU GPS fixture suite for the …-gpsd profiles.
-#
-# Boots the GPS-enabled QEMU target, feeds the synthetic NMEA fixtures into the
-# guest's virtual UART1 via scripts/gps-relay.py (fixture mode — NO gpsd, NO real
-# receiver), and asserts the firmware's GPS state from the transition-only
-# [GPSTEST] markers in the UART log (status only; never coordinates).
-#
-# It manages the QEMU lifecycle itself (run.sh in the background, stop.sh on exit)
-# and reuses test.sh idioms (uart-latest.log anchor, 30x2s web readiness poll).
-# It requires a built image: scripts/build.sh --env <env> first.
-#
-# Fixture order matters and is deliberate: a relay streams NMEA from boot so the
-# firmware's one-shot GPS init detects a live stream (gpsDetected). The NEGATIVE
-# fixtures run first (no prior valid fix can leak into them via TinyGPSPlus state),
-# then valid -> stale -> short-track.
-set -eu
-
-ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
-RUN="$ROOT/.run"
-UART="$RUN/uart-latest.log"
-SOCK="$RUN/gps-uart1.sock"
-WEB="http://127.0.0.1:18083/"
-RELAY="$ROOT/scripts/gps-relay.py"
-FIX="$ROOT/fixtures/gps"
-ENV_NAME="qemu-headless-gpsd"
-RATE=5
-
-while [ $# -gt 0 ]; do
-	case "$1" in
-		--env) ENV_NAME="${2:?--env needs a value}"; shift 2 ;;
-		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
-	esac
-done
-case "$ENV_NAME" in *gpsd) ;; *) echo "ERROR: --env must be a …-gpsd profile (got '$ENV_NAME')." >&2; exit 2 ;; esac
-
-need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'." >&2; exit 1; }; }
-need python3; need curl
-FLASH="$ROOT/.work/MeshCom-Firmware/.pio/build/$ENV_NAME/flash.bin"
-[ -f "$FLASH" ] || { echo "ERROR: $FLASH not found. Build first: scripts/build.sh --env $ENV_NAME" >&2; exit 1; }
-
-RELAY_PID=""
-kill_relay() { [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true; RELAY_PID=""; }
-cleanup() { kill_relay; bash "$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true; }
-trap cleanup EXIT INT TERM
-
-start_relay() { # $1=fixture
-	kill_relay
-	python3 "$RELAY" --mode fixture --fixture "$FIX/$1" --uart "$SOCK" --rate "$RATE" --loop \
-		>"$RUN/gps-relay-$1.log" 2>&1 &
-	RELAY_PID=$!
-}
-
-offset() { [ -f "$UART" ] && wc -c <"$UART" || echo 0; }
-slice()  { tail -c "+$(( ${1:-0} + 1 ))" "$UART" 2>/dev/null || true; }
-crash_count() { grep -ciE 'Guru Meditation|abort\(\)|rst:0x|CPU_RESET' "$UART" 2>/dev/null || echo 0; }
-
-FAILS=0
-ok()   { echo "[test-gps] PASS: $1"; }
-bad()  { echo "[test-gps] FAIL: $1"; FAILS=$((FAILS+1)); }
-
-# --- boot QEMU with UART1 socket, start the negative fixture from boot ---
-echo "[test-gps] booting $ENV_NAME …"
-bash "$ROOT/scripts/run.sh" --env "$ENV_NAME" >/dev/null 2>&1 &
-start_relay no_fix.nmea     # stream from boot so the one-shot GPS init sees a live stream
-
-echo "[test-gps] waiting for web UI readiness …"
-ready=0
-for _ in $(seq 1 30); do
-	[ "$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' "$WEB" 2>/dev/null || echo 000)" = "200" ] && { ready=1; break; }
-	sleep 2
-done
-[ "$ready" = "1" ] || { echo "[test-gps] FAIL: web UI not reachable"; exit 1; }
-base_crash="$(crash_count)"
-grep -q 'QEMU virtual GPS on UART1' "$UART" && ok "GPS source initialized on UART1" || bad "GPS init marker not seen"
-grep -q 'QEMU NMEA presence:.*detected' "$UART" && ok "live NMEA detected (gpsDetected)" || bad "gpsDetected not established (relay/boot timing?)"
-
-# --- 1) no-fix: must NEVER reach a usable fix ---
-o="$(offset)"; sleep 8
-slice "$o" | grep -q '\[GPSTEST\] fix=1' && bad "no_fix produced a fix" || ok "no_fix never reached fix"
-
-# --- 2) malformed/bad-checksum: no crash, no false fix ---
-o="$(offset)"; start_relay bad_checksum.nmea; sleep 8
-slice "$o" | grep -q '\[GPSTEST\] fix=1' && bad "bad_checksum produced a fix" || ok "bad_checksum never reached fix"
-[ "$(crash_count)" = "$base_crash" ] && ok "bad_checksum: no crash/reset" || bad "crash/reset markers appeared"
-
-# --- 3) valid fixed position: must reach a usable fix with the expected quality ---
-o="$(offset)"; start_relay valid_fix.nmea; sleep 10
-if slice "$o" | grep -q '\[GPSTEST\] fix=1 sats=7 hdop=1.2'; then ok "valid_fix reached fix (sats=7 hdop=1.2)"
-else bad "valid_fix did not reach expected fix"; slice "$o" | grep '\[GPSTEST\]' | tail -3; fi
-
-# --- 4) stale: stop feeding; usable fix must age out (live age >= 5s) ---
-o="$(offset)"; kill_relay; sleep 9
-slice "$o" | grep -q '\[GPSTEST\] fix=0' && ok "stale input aged out (fix=0)" || bad "stale fix did not age out"
-
-# --- 5) short track: fix re-established AND position updates (>=2 distinct points) ---
-o="$(offset)"; start_relay short_track.nmea; sleep 12
-slice "$o" | grep -q '\[GPSTEST\] fix=1' && ok "short_track re-reached fix" || bad "short_track did not reach fix"
-moves="$(slice "$o" | grep -c '\[GPSTEST\] moved' || true)"
-[ "${moves:-0}" -ge 2 ] && ok "short_track updated position ($moves distinct points)" || bad "short_track did not update position (moves=$moves)"
-
-# --- guest health: web still serving, no crash across the whole run ---
-[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$WEB" 2>/dev/null || echo 000)" = "200" ] && ok "web UI still reachable" || bad "web UI not reachable at end"
-[ "$(crash_count)" = "$base_crash" ] && ok "no panic/reset/reboot across run" || bad "panic/reset markers across run"
-
-echo "[test-gps] ---------------------------------------------"
-if [ "$FAILS" = "0" ]; then echo "[test-gps] ALL PASS"; else echo "[test-gps] $FAILS check(s) FAILED"; exit 1; fi
diff --git a/scripts/test.sh b/scripts/test.sh
index 228701e8..62fb9ea8 100755
--- a/scripts/test.sh
+++ b/scripts/test.sh
@@ -66,14 +66,17 @@ else
 	TEST_NODE="$RUN/test-node-flash.bin"
 	rm -f "$TEST_NODE" "$TEST_NODE".*
 	"$ROOT/scripts/run.sh" --env "$ENV_NAME" --node-image "$TEST_NODE" ${QEMU_FWD[@]+"${QEMU_FWD[@]}"} > "$RUN/test-boot.log" 2>&1 &
+	RUNPID=$!
 	trap '"$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true' EXIT
 	self_booted=1
-	# Wait until run.sh has BOTH recorded the pid AND repointed uart-latest.log to a NEW file.
-	for _ in $(seq 1 60); do
+	# Wait until run.sh has provisioned the fresh node and repointed uart-latest.log to the first
+	# supervised boot's NEW file (within its provisioning budget); a run.sh that ends first is a failure.
+	for _ in $(seq 1 "${PROVISION_TIMEOUT:-900}"); do
 		cur="$(readlink "$UART" 2>/dev/null || echo "")"
 		if [ -n "$cur" ] && [ "$cur" != "$prev_uart" ] && [ -f "$PIDFILE" ]; then
 			BOOT_LOG="$RUN/$cur"; break
 		fi
+		kill -0 "$RUNPID" 2>/dev/null || { echo "[test] FAIL: run.sh ended before the first boot (see $RUN/test-boot.log)"; exit 1; }
 		sleep 1
 	done
 	[ -n "$BOOT_LOG" ] || { echo "[test] FAIL: guest did not start (no fresh UART log / pid recorded)"; exit 1; }
@@ -125,7 +128,8 @@ PY
 # No-radio scan of UART (informational).
 if [ -f "$UART" ]; then
 	echo "[test] no-radio scan:"
-	echo "  radio disabled marker : $(grep -c 'radio disabled' "$UART" || true)"
+	echo "  address reported      : $(grep -c 'ethmode: IP .* reported' "$UART" || true)  (expect 1)"
+	echo "  W5500 path ([ETH])    : $(grep -c '\[ETH\]' "$UART" || true)  (expect 0 at boot)"
 	echo "  RadioLib RX success    : $(grep -c 'Starting to listen ... success' "$UART" || true)  (expect 0)"
 	echo "  NimBLE init            : $(grep -ci 'NimBLEDevice::init' "$UART" || true)  (expect 0)"
 	echo "  external_radio refs    : $(grep -ci 'external_radio\|extradio' "$UART" || true)  (0 on default builds; >0 on extradio)"
```
