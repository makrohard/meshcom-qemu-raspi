# Code report s5 (A2) v4: stock MeshCom in QEMU, our files only

**v4 delta** (gate 2, Work round W2: RED, six findings; all fixed in fe9b051a):

| finding | v3 | v4 |
|---|---|---|
| F1 kill escalation | stop.sh `stop_pid` and run.sh `stop_qemu` sent SIGKILL to the bare PID after the grace wait | the PID is revalidated immediately before the SIGKILL: the same start time (`/proc/PID/stat` field 22) and the same predicate (stop.sh: `is_runner`/`is_qemu`; run.sh: its own monitor socket in the argv); otherwise "not killed". Tests: a runner that drops run.lock and becomes another program during stop.sh's wait survives; a guest whose TERM turns it into another program survives run.sh's stop. Red-before: both FAIL on d1b73c84 (it was killed) |
| F2 stale marker | a marker for another command list stayed during provisioning; a failure or TERM left it | removed before provisioning starts. Tests: an existing image with another list's marker, then a provisioning failure (rc 3) and a TERM (rc 0): no marker. Red-before: both FAIL on d1b73c84 |
| F3 controls passing on a failed fixture | readiness and console reads were not checked; a failed read satisfied a negative assertion | `setup()`: a control is judged only after its preparation held, otherwise FAIL. Readiness for every control node; g: baseline MESH off, then `--info` reads MESH on; d: `--pos` answered with a SAT line; f: restart #1 + web 200, then `--info` reads MTU 1500; e: the runner still runs after `--reboot`; c: web 200 with the console off; a and slow l: the history extraction (and apply/build); b: build rc 0, run.sh rc 3; slow b′/k/k2: their builds; b′ control: the build log names ETHClass2.h; l control: web fails with the link down |
| F4 gate i without load | the writer's exit ignored; probes could run past the 90 s load | `uart_load`: writer rc 0, bytes > 0, the writer still running after the last probe (8 probes, 8 s apart), 8 answers. New control i: a failed writer (no such socket) → the gate's assertion fails |
| F5 k2 not fresh | a copy of the provisioned image minus its marker | an absent image: node-image.sh creates it from the test build ("created from the build" asserted) |
| F6 shallow checkout | `actions/checkout` depth 1; the controls read c2335d12 | `fetch-depth: 0`; a missing historical file is a setup FAIL. First arm dispatch: not possible before the merge (GitHub: "workflow boot-gates.yml not found on the default branch", HTTP 404 on the dispatch at fe9b051a); it runs as the first dispatch after the merge |
| README | "aarch64: not yet run" | the Pi 5 `--main` result; README 103 lines |
| b/k/l wording | the plan said web 200 within 30 s | the plan now says what the code does: reported again within 30 s, then web 200 within a further 60 s |
| v4.2 wording (gate 2, auditor 2c round 1, F1) | comments said a reused PID is "never killed" | "revalidated immediately before the SIGKILL"; a reuse observed at that revalidation is not killed; the revalidation and the numeric kill stay two steps (comments and this report; no code) |


**v3 delta** (gate 1, auditor 2b round 1: two findings):

| finding | v2 | v3 |
|---|---|---|
| F1 `scripts/stop.sh` `is_qemu()` | any qemu-system-xtensa with an MTD `.bin` drive passed, so a stale `qemu.pid` naming another runner's guest got TERM/KILL | it must also carry this checkout's `-monitor unix:$RUN/monitor.sock` (b486e34a) |
| F2 the reused-pid test | a `sleep 100` decoy only; the report claimed more | a decoy whose cmdline passes the generic predicate (asserted) but names another monitor socket must survive `stop.sh`; red-before 1 FAIL on the parent, 29/29 after; x86 `--main` 21/21 on b486e34a |
| note | "no alignment needed" | narrowed (Controller integration) |

**v2 delta** (after the second read, decided by the handler):

| point | v1 | v2 |
|---|---|---|
| 1 GPS setting unverified | the persisted-state check covered Ethernet mode, mesh, extudp, gateway, web | for a `*-gpsd` env it also reads `--pos` and requires `...GPS: on` (6f5531f0); reply held in memory only; test: GPS off → rc 3, no marker; red-before 1 FAIL on the parent |
| 2 aarch64 provisioning time | not measured | 53 s on the Pi 5 (first start: provisioning + check), 46 s on x86; LHPC's `readiness_timeout` for meshcom-qemu is 600 s: no alignment needed |
| 3 torn read | in the plan's R1 only | stated as a residual below, no synchronisation code |
| aarch64 | not run | Pi 5 (Debian trixie, aarch64): `--main` 21/21, `--controls` 7/7 on 63bd8d60 |

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
| 63bd8d60 | report and packet v1 | — | — |
| 6f5531f0 | the persisted-state check requires `--gps on` for `*-gpsd` (via `--pos`); test finish() bounded | quick: GPS off → rc 3, no marker; position never written | the new test on the parent's run.sh: 1 FAIL |
| 386c056b | report and packet v2 | — | — |
| b486e34a | stop.sh signals a QEMU only with this checkout's monitor socket | quick: a QEMU-like decoy with another monitor socket survives stop.sh | the new case on the parent's stop.sh: 1 FAIL (the decoy was signalled) |
| fe9b051a | gate-2 findings F1–F6 (v4 delta above) | quick: 4 new supervisor cases; slow: setup() for every control, gate i via uart_load, control i, k2 from an absent image | the supervisor file on d1b73c84's scripts: 4 FAIL |

## Evidence of record, v4 (fe9b051a, 2026-10-16)
- x86: `--main` 21/21 (357 s); `--controls` 8/8 with every setup held (283 s); `--slow-k2 --slow-l` 2/2 (82 s); `--slow-b` 2/2; `--slow-k` 2/2 (574 s).
- Pi 5 aarch64: `--main` 21/21 (04:23–04:36Z) on the v4 working tree before its controls-only edits (F3, the f evidence). Compared with fe9b051a: run.sh, stop.sh, node-image.sh, node-efuse.sh byte-identical; test-boot-gates.sh's `--main` section identical; the only other difference before it is the `setup()` helper, which `--main` does not call. Gate i: writer rc 0, 52992 B, all 8 probes inside the load (x86: the same figures). First start: provisioning + check 73 s. Heat 47.2–60.4 °C, `throttled=0x0`.
- Quick: test-run-supervisor 33/33; test-apply-overlay, test-node-image, test-node-efuse, test-setup-src pass; shellcheck `-S warning` clean on the CI file list.
- Red-before (the v4 test file against d1b73c84's scripts): 4 FAIL (the two F2 cases, the two F1 cases), 29 ok.

## Evidence of record, v1-v3 (HEAD 6e49bcb1)
- `--main` 21/21 as expected (392 s): a, j, b ×2, c, c-xr ×2, d, f, g, h, i, e, l ×3.
- `--controls --slow-l --slow-k2` 9/9 (390 s): controls a b c d e f g l, k2.
- `--slow-b` 2/2 (333 s), `--slow-k` 2/2 (574 s).
- Quick: test-apply-overlay 4/4, test-run-supervisor 25/25 (176 s; 27/27 on 6f5531f0), test-node-image 29 ok, test-node-efuse and test-setup-src pass.
- On 6f5531f0 (x86): `--main` 21/21 again (370 s). On b486e34a (x86): `--main` 21/21 (361 s); test-run-supervisor 29/29.
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
| f | `--mtu 1500` → no `[NET];mtu;eth;1280` line (upstream prints it only on a change; lwIP's default is 1500); v4: `--info` reads MTU 1500 first |
| g | `--mesh on` → `--info` reads `MESH on` |
| k | none natural (see "Found"); k2: a fresh node in that build → rc 3 |
| l | the old `qemu_network.cpp` → no withdrawal within 12 s |
| i | v4: a failed writer → the assertion fails |
| h | none natural (stated in the plan) |

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

## aarch64 (Pi 5, lhpc-0ae1, Debian trixie), on 63bd8d60, 2026-10-16 01:47–02:10Z
- The box's managed QEMU (marker: source 40edccac, patch sha256 c1e223db) and bridge (7c86c96); PlatformIO 6.1.19 in a scratch venv.
- `--main` 21/21 as expected: four env builds of about 2 min each; first-start provisioning and the persisted-state check took 53 s (provisioning log 01:57:48Z → marker 01:58:41Z); gate l recovery reported 0 s after `set_link on`, web 200 1 s later.
- `--controls` 7/7 as expected. The slow modes were not run on aarch64.
- Heat: 47.2–60.9 °C, `throttled=0x0` throughout. Exit state: the scratch directory removed, the box's meshcom stack stopped as found.

## Controller integration
- First start on aarch64 (Pi 5) 53 s (v4 run: 73 s), on x86 46 s, against the controller's readiness timeout of 600 s for meshcom-qemu: no alignment needed on the Pi 5 and x86. The Pi Zero 2W (the slowest box) is measured in the 0.12.10 live row. `PROVISION_TIMEOUT` (900 s) still exceeds the controller's 600 s.

## Residual risks
- **Torn read (with R5):** the hand-over task writes `node_ip`/`node_gw`/`node_subnet` from its own task while the main loop may read them for a display or a web page; a page could show a half-written address during a re-report. Cosmetic: no decision path reads these strings; no synchronisation is added.

## Not covered yet
- aarch64 slow modes (b′, k, k2, l control) and the lhpc-binaries smoke on the candidate controller commit (the pin-move qualification).
- The weekly workflow has never run: GitHub dispatches a workflow only from the default branch, so its first arm run is the first dispatch after the merge.
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
   - stop.sh signals only this checkout's runner (the process holding `.run/run.lock`) and this checkout's guest (a qemu-system-xtensa with an MTD node image and `unix:$RUN/monitor.sock`); a pid whose process fails the check, including another runner's QEMU, is not signalled (test-run-supervisor, two decoys); the check before a SIGKILL detects a reuse observed at that revalidation, and the revalidation and the numeric kill stay two steps (no pidfd);
   - provisioning only with verified persisted state (supervisor tests "MESH on → 3" and "GPS off → 3", gate j).
3. **Failure classes:**
   - a signal during provisioning; a guest ignoring TERM (KILL after 10 s, only while it is still that guest);
   - a PID that becomes another program during a grace wait (not killed, v4); a marker for another list during a failed or stopped provisioning (removed, v4);
   - a reused pid (a plain process, and another runner's QEMU), a second runner, a stale `uart-latest.log`, a changed command list, rc 0 without the ack, a provisioning timeout (all in test-run-supervisor);
   - a driver that never starts (gate k); a link loss (gate l); an unpaced UART (gate i).
   - The stubs model a process lifetime (TERM notes, ports served while alive).
4. **Test rules:** red-before per fix commit (table); every gate asserts a token, a code or an rc, never a sentence; no unconditional pass; three gates without a natural control are named.
5. **Runs:** all quick tests and all gate modes above, in the foreground; shellcheck 0.11.0 `-S warning` clean on the changed scripts.
6. **Adversarial self-review:** see "Found" and the harness list; the re-read also scoped CI shellcheck to the changed files, and fixed the gate test's `$?`-through-a-function, wipe-on-every-mode and node-sharing defects before its first run. Absolute words were checked: "zero MeshCom lines" is enforced by apply-overlay.sh; "never stands" is limited to what gates k/l measure; the residual ≤ 100 ms internal window is stated in the plan (R5).

## Numbers, measured
| figure | command | output |
|---|---|---|
| diff | `git diff --stat c2335d12..fe9b051a \| tail -1` (code-review/ included) | 31 files, +5187/−1058 |
| v4 diff | `git diff --stat d1b73c84..fe9b051a \| tail -1` | 7 files, +181/−64 |
| removed patch | `git show origin/main:overlay/patches/meshcom-qemu-headless.patch \| wc -l` | 469 |
| run.sh before/after | `wc -l` at c2335d12 / fe9b051a | 137 / 295 |
| stop.sh before/after | same | 25 / 60 |
| apply-overlay.sh before/after | same | 82 / 35 |
| new C++ | `wc -l overlay/src/qemu/qemu_ethmode.cpp qemu_eth_standin.cpp` | 104, 35 |
| stand-in headers | `wc -l ETHClass2.h EthernetUdp.h` | 29, 9 |
| tests | `wc -l tests/test-run-supervisor.sh tests/test-boot-gates.sh tests/xr-tap.py` at fe9b051a | 244, 333, 39 |
| README | `wc -l README.md` at fe9b051a | 103 |
| gate results v4 | `grep -cE '^PASS'`: x86 main, controls, k2+l, b, k; Pi 5 main | 21, 8, 2, 2, 2; 21 |
| quick results v4 | test-run-supervisor `ok` lines | 33 |
| tracked MeshCom changes | gate a | 0 |
