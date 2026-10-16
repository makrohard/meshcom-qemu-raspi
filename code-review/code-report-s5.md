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
