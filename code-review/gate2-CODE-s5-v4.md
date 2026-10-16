# Gate 2 (delta round): the QEMU runner v4 (meshcom-qemu-raspi), the six W2 findings

**Request.** The W2 Work round judged runner v3 RED with six findings (F1–F6, verbatim below) and OK on the rest. Judge whether v4 removes each finding, adds nothing the findings did not ask for, and whether each new test can fail for what it names. One table (finding → OK / FINDING, file:line, smallest fix), then one line: GREEN / GREEN WITH NOTES / RED.

This file is your whole input together with the v3 packets the W2 round read (gate1-CODE-s5-v3.md, -B, -C). No repository access is needed. The diff below is git's text verbatim (`git diff d1b73c84 fe9b051a`). Redaction: none needed (no host name, address or call sign in it).

| item | value |
|---|---|
| repo / branch | makrohard/meshcom-qemu-raspi `cons/s5-r1` |
| v3 (judged in W2) | d1b73c8449f766e8a473b6ec1f5ef82ef00a964d |
| v4 (this round) | fe9b051ac8bc71aefb471904768c68ed1e5b9f48 (one commit on v3) |
| size | 7 files changed, 181 insertions(+), 64 deletions(-) |

## The W2 findings (verbatim from the W2 answer)
| F1 — Ownership is not retained through escalation | FINDING | **`scripts/stop.sh:24`**, also **`scripts/run.sh:155`:** SIGKILL uses the numeric PID after waiting, without binding it to the originally checked process. If that process exits and its PID is reused during the grace period, escalation can target the replacement. **Smallest fix:** revalidate captured process identity/start time before escalation; a genuinely absolute “never signals a reused PID” guarantee needs a stable PID handle. Add a replacement-during-wait control. |
| F2 — Failed reprovisioning retains an old success marker | FINDING | **`scripts/run.sh:234`:** a mismatching existing marker triggers provisioning without first removing it; failure and signal paths leave it behind. It remains invalid for the current hash, but can become trusted again after reverting the command list despite partially changed settings. **Smallest fix:** invalidate the marker before provisioning begins; test failure and TERM starting with an existing mismatching marker. |
| F3 — Negative controls can pass because their fixture failed | FINDING | **`tests/test-boot-gates.sh:200`, `:203`, `:206`, `:220`:** readiness failures are ignored, and failed console reads satisfy negative assertions. Using the attached predicates, an unreachable guest produced **PASS for controls g, d and c**. **Smallest fix:** make preparation/readiness failures fatal and require a valid baseline plus evidence of the intended altered state—for example, an actual `MESH on` reply. Apply this to unchecked build/setup operations in the slow controls too. |
| F4 — Gate i can pass without UART load | FINDING | **`tests/test-boot-gates.sh:154`:** the writer’s exit status is ignored; **`:155`** checks only eight successful service probes. A failed writer therefore passes against an idle guest. Probe durations can also carry probes beyond the 90-second load interval. **Smallest fix:** require writer success and positive transferred bytes, and establish that the probes occurred during the load. A failed-writer control must fail the gate. |
| F5 — k2 is not a fresh-node test | FINDING | **`tests/test-boot-gates.sh:265`:** k2 copies the already provisioned node image and removes only its marker. Its persisted Ethernet settings survive. This proves reprovisioning failure, not failure from fresh defaults. **Smallest fix:** start k2 with a genuinely absent node image so `node-image.sh` creates it from the build; retain the present case under its accurate name if useful. |
| F6 — Weekly job lacks history required by its controls | FINDING | **`.github/workflows/boot-gates.yml:30`:** default shallow checkout does not supply the historical base read by **`tests/test-boot-gates.sh:179` and `:273`**. The weekly job cannot reproduce those controls from a clean checkout. **Smallest fix:** fetch the required history, simplest with `fetch-depth: 0`, and fail immediately if a historical fixture cannot be extracted. Then run the stated first arm dispatch. |
| Gates b, k and l: scope | OK | The revised b assertion checks upstream readiness and publication time. k supports the narrowed upstream-retry claim, not the original 200 ms withdrawal assertion. l exercises withdrawal and recovery. Keep these narrower claims; the code allows **30 seconds for re-reporting plus a further 60 seconds for web recovery**, rather than the design’s combined 30-second wording. |
| Qualification and maintainability | OK | The report distinguishes x86 results, the earlier Pi 5 run, unrun weekly/arm slow modes, and pending candidate/Zero integration proofs. Those pending proofs remain promotion prerequisites. The short layout is reasonable. Refresh README’s stale “aarch64: not yet run” statement and the v3 line counts; the controller-oriented checker is correctly disclosed as not validating these shell tests. |

## What v4 does, per finding
| finding | fix | where | test (red-before on d1b73c84's scripts) |
|---|---|---|---|
| F1 | before the SIGKILL, the PID must still be the checked process: the same start time (`/proc/PID/stat` field 22, read when the check passed) and the predicate still true (stop.sh `is_runner`/`is_qemu`, run.sh `is_guest`: its own `unix:$RUN/monitor.sock,` in the argv). Otherwise "not killed". A start-time comparison closes reuse by a new process; the predicate closes a process that became another program (same PID, same start time). A stable PID handle (pidfd) is not used: bash has none | scripts/stop.sh `start_of`, `stop_pid`; scripts/run.sh `start_of`, `is_guest`, `stop_qemu`, `launch` (QSTART) | supervisor: "stop.sh does not SIGKILL a runner PID that became another program during the wait" (a runner holding run.lock whose TERM trap closes the lock and execs `sleep`); "a guest PID that became another program while TERM was pending is not killed" (stub mode boot-exec-term: TERM → execv sleep). Both FAIL on d1b73c84 (the process was killed) |
| F2 | `rm -f "$MARKER"` when the marker does not name the current list, before `provision` | scripts/run.sh, the marker block | supervisor: an existing node image with another list's marker, then (a) a provisioning failure → rc 3, no marker; (b) TERM during provisioning → rc 0, no marker. Both FAIL on d1b73c84 |
| F3 | `setup NAME CHECK`: a control is judged only when its preparation held; a failed setup is a FAIL. Each control now requires its baseline and the altered state: readiness (web 200 + console banner) for every control node; g: baseline `--info` = MESH off/EXTUDP off/Gateway off, then `--info` contains `...MESH on`; d: `--pos` returned a SAT line; f: restart #1 and web 200, then `--info` reads MTU 1500 (upstream prints `[NET];mtu` only when it changes the netif's MTU, and lwIP's default is 1500, so no log line can show it); e: the runner still runs after `--reboot`; c: web 200 after `--netconsole off`; a: the old patch extracted from c2335d12 and its hunk applied; b: build rc 0 and run.sh rc 3; slow b′/k/k2/l: their builds; b′ control: the failing build log names ETHClass2.h; l control: web fails with the link down | tests/test-boot-gates.sh | x86 `--controls` on v4: 8/8 with every setup held. One setup failed on the first v4 run (f: an MTU log line was the wrong evidence, see above); fixed before the result of record |
| F4 | `uart_load SOCK`: writer and 8 probes 8 s apart; gate i holds only if the writer's rc is 0, it wrote > 0 bytes, it was still running after the last probe (so every probe fell inside the 90 s load), and all 8 probes answered. New control i: a failed writer (a socket that does not exist) | tests/test-boot-gates.sh `uart_load`, `uart_load_held`, gate i, control i | control i PASS (the assertion failed). Gate i on v4: writer rc 0, 52992 B, all probes inside the load (x86 and Pi 5) |
| F5 | k2 starts from an absent node image; node-image.sh creates it from the test build; the gate also asserts run.sh's "node image: created from the build" | tests/test-boot-gates.sh --slow-k2 | x86 k2 PASS |
| F6 | `fetch-depth: 0`; a missing historical file is a setup FAIL (F3) | .github/workflows/boot-gates.yml | the first arm dispatch cannot run before the merge: `gh workflow run boot-gates.yml --ref cons/s5-r1` answers HTTP 404 "workflow boot-gates.yml not found on the default branch". It is the first dispatch after the merge |
| b/k/l wording | the plan now states what the code does: re-reported within 30 s, then web 200 within a further 60 s (code unchanged) | plans/PLAN-s5-runner.md, gate l row | — |
| README | the aarch64 line: Pi 5 `--main` all as expected; `--controls`/`--slow` x86 only so far | README.md | — |

## Runs on v4 (2026-10-16)
- x86_64 (Fedora 43), MeshCom f2b3a349, QEMU esp-develop-9.2.2-20260417 + patches/qemu, bridge 7c86c96: `--main` 21/21 (357 s); `--controls` 8/8 (283 s); `--slow-k2 --slow-l` 2/2; `--slow-b` 2/2; `--slow-k` 2/2 (574 s).
- aarch64 Raspberry Pi 5: `--main` 21/21 (04:23–04:36Z), on the v4 working tree before the controls-only edits. Compared with fe9b051a: run.sh, stop.sh, node-image.sh and node-efuse.sh are byte-identical, and the `--main` section of test-boot-gates.sh is identical; the only other earlier difference is the `setup()` helper, which `--main` never calls. First start (provisioning + check): 73 s. Heat 47.2–60.4 °C, throttled 0x0.
- Quick: test-run-supervisor 33/33; the v4 test file against d1b73c84's scripts: 4 FAIL, 29 ok. test-apply-overlay, test-node-image, test-node-efuse, test-setup-src pass. shellcheck 0.11.0 `-S warning`: clean on the CI file list. The workflow YAML parses.

## Not proven here, stated
- A PID reused by an unrelated process during the wait cannot be produced in a test; the start-time comparison covers it by construction. The tests cover the same-PID replacement (exec), which the start time alone cannot catch.
- The weekly job's first arm run (F6) waits for the merge (above).

## The diff (`git diff d1b73c84 fe9b051a`, verbatim)
```diff
diff --git a/.github/workflows/boot-gates.yml b/.github/workflows/boot-gates.yml
index 2d54a2fe..b29c8ae3 100644
--- a/.github/workflows/boot-gates.yml
+++ b/.github/workflows/boot-gates.yml
@@ -28,6 +28,8 @@ jobs:
     timeout-minutes: 300
     steps:
       - uses: actions/checkout@v4
+        with:
+          fetch-depth: 0   # the controls read c2335d12's files (tests/test-boot-gates.sh); a missing one is a FAIL
       - name: Packages
         run: |
           sudo apt-get update -q
diff --git a/README.md b/README.md
index 8aaa6a95..ca00b849 100644
--- a/README.md
+++ b/README.md
@@ -98,5 +98,6 @@ validated against MeshCom f2b3a3496a76f327abec8b7228bce436cafe9606 on 2026-10-16
   tests/test-boot-gates.sh --main --controls --slow, all as expected; PlatformIO 6.1.19;
   framework-arduinoespressif32 3.20017.241212 (Arduino-ESP32 2.0.17, ESP-IDF 4.4.7);
   QEMU esp-develop-9.2.2-20260417 + patches/qemu (scripts/build-qemu.sh)
-aarch64: not yet run with this layout
+validated against the same commit on 2026-10-16, aarch64 Raspberry Pi 5:
+  tests/test-boot-gates.sh --main, all as expected (--controls and --slow: x86 only so far)
 ```
diff --git a/plans/PLAN-s5-runner.md b/plans/PLAN-s5-runner.md
index 185d6819..4717981b 100644
--- a/plans/PLAN-s5-runner.md
+++ b/plans/PLAN-s5-runner.md
@@ -135,7 +135,7 @@ Each restart prints `[run] guest reset after <s> s -> restart #<n>` and writes `
 | h | spectrum page ≤ 60 s, then web 200 | none natural (stated) |
 | i | UART1 written unpaced for 90 s; web and console answer every 10 s | none natural (stated) |
 | j | fresh node → `--setcall` → one supervised restart → no `WIFIAP starting` in that boot, web 200, callsign kept | without the supervisor run.sh ends |
-| l | acquire, then QEMU monitor `set_link <nic> off` (run.sh adds `-monitor unix:.run/monitor.sock,server=on,wait=off`; the model reports it to the guest PHY, `hw/net/opencores_eth.c:338-345`): `readiness withdrawn` within 10 s; web and console from the host fail; `set_link on` → `reported` again and web 200 within 30 s | the same run without the `qemu_network.cpp` change: no withdrawal line, the flag stays true |
+| l | acquire, then QEMU monitor `set_link <nic> off` (run.sh adds `-monitor unix:.run/monitor.sock,server=on,wait=off`; the model reports it to the guest PHY, `hw/net/opencores_eth.c:338-345`): `readiness withdrawn` within 10 s; web and console from the host fail; `set_link on` → `reported` again within 30 s, then web 200 within a further 60 s (v4: aligned with the code) | the same run without the `qemu_network.cpp` change: no withdrawal line, the flag stays true |
 | k | a test build that never starts OpenETH (`QEMU_TEST_NO_OPENETH`), Ethernet mode, a persisted flag true: `readiness withdrawn` within 200 ms of boot and of every `[ETH] DHCP failed` line; web and console unreachable from the host for 7 min; a fresh node in this build → provisioning exit 3, no marker | the same run with the invariant removed: the flag stays true after `DHCP failed` (`--info` cannot be read either way, so the control reads the UART) |
 
 **Where:**
diff --git a/scripts/run.sh b/scripts/run.sh
index 22942a61..349659aa 100755
--- a/scripts/run.sh
+++ b/scripts/run.sh
@@ -147,14 +147,31 @@ echo "[run] net-console: 127.0.0.1:12323"
 # STOP; QEMU gets TERM, 10 s, then KILL. EXIT CODES: 0 stopped · 1 setup error · 2 usage · 3 provisioning
 # failed · 5 QEMU exited with an error · 75 restart limit (3 runs < 60 s in a row, or > 10 restarts/hour).
 STOP=0
-QPID=""
+QPID=""; QSTART=""
+# start_of PID: the process's start time (/proc/PID/stat field 22); empty once it is gone.
+start_of() {
+	local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
+	# shellcheck disable=SC2086 # the fields after the command name, split on purpose
+	set -- ${s##*) }; printf '%s' "${20}"
+}
+# is_guest: QPID is still the QEMU launched (the same start time, this run's monitor socket in its argv)
+is_guest() {
+	[ -n "$QSTART" ] && [ "$(start_of "$QPID")" = "$QSTART" ] \
+		&& { tr '\0' ' ' < "/proc/$QPID/cmdline"; } 2>/dev/null | grep -qF "unix:$RUN/monitor.sock,"
+}
+# stop_qemu: TERM, 10 s, then KILL only while QPID is still that QEMU (a reused PID is never killed).
 stop_qemu() {
 	[ -n "$QPID" ] || return 0
 	kill -TERM "$QPID" 2>/dev/null || true
 	for _ in $(seq 1 10); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
-	kill -KILL "$QPID" 2>/dev/null || true
-	wait "$QPID" 2>/dev/null || true
-	QPID=""
+	if ! kill -0 "$QPID" 2>/dev/null; then
+		wait "$QPID" 2>/dev/null || true
+	elif is_guest; then
+		kill -KILL "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
+	else
+		echo "[run] pid $QPID is no longer this run's QEMU; not killed" >&2
+	fi
+	QPID=""; QSTART=""
 }
 on_signal() { STOP=1; stop_qemu; rm -f "$RUN/run.pid"; exit 0; }
 trap on_signal TERM INT
@@ -163,12 +180,12 @@ qemu_alive() { [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; }
 launch() {
 	if [ -n "${2:-}" ]; then "${QEMU_CMD[@]}" <&"$2" >> "$1" 2>&1 &
 	else "${QEMU_CMD[@]}" >> "$1" 2>&1 & fi
-	QPID=$!
+	QPID=$!; QSTART="$(start_of "$QPID")"
 	put "$RUN/qemu.pid" "$QPID"
 	echo "[run] QEMU pid $QPID, UART log $1"
 }
 # wait_rc: the exit code of the QEMU just ended.
-wait_rc() { local rc=0; wait "$QPID" || rc=$?; QPID=""; return "$rc"; }
+wait_rc() { local rc=0; wait "$QPID" || rc=$?; QPID=""; QSTART=""; return "$rc"; }
 
 # --- Provisioning (a node image without a matching marker) -----------------------------------------
 # The persistent settings come from MeshCom's own console commands, sent over UART0 once. The
@@ -232,6 +249,9 @@ verify_persisted() {
 
 VERIFY=0
 if [ "$(cat "$MARKER" 2>/dev/null | cut -d' ' -f2)" != "$PROVISION_SHA" ]; then
+	# A marker for another command list is void from here on: a failed or stopped provisioning must not
+	# leave it to be trusted again (after a revert of the list) over partly changed settings.
+	rm -f "$MARKER"
 	provision
 	VERIFY=1
 fi
diff --git a/scripts/stop.sh b/scripts/stop.sh
index 231aea67..cbef4f73 100755
--- a/scripts/stop.sh
+++ b/scripts/stop.sh
@@ -5,6 +5,7 @@
 # A PID file is trusted only for a process that still is what it names: run.pid only if that process
 # holds this checkout's .run/run.lock open, qemu.pid only if that process is qemu-system-xtensa on a node
 # image with this checkout's monitor socket. A stale or reused PID is never signalled; its file is removed.
+# The check is repeated before a SIGKILL (stop_pid).
 # EXIT CODE: 0, also when nothing runs.
 set -eu
 ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
@@ -17,18 +18,31 @@ is_qemu() {
 	local c; c="$( { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null)" || return 1
 	printf '%s' "$c" | grep -q 'qemu-system-xtensa .*-drive file=.*\.bin,if=mtd' && printf '%s' "$c" | grep -qF "unix:$RUN/monitor.sock,"
 }
-# stop_pid PID: TERM, up to 15 s, then KILL.
+# start_of PID: the process's start time (/proc/PID/stat field 22); empty once it is gone.
+start_of() {
+	local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
+	# shellcheck disable=SC2086 # the fields after the command name, split on purpose
+	set -- ${s##*) }; printf '%s' "${20}"
+}
+# stop_pid PID CHECK: TERM, up to 15 s, then KILL only while PID is still the process CHECK accepted (the
+# same start time and CHECK still true). A PID that ended and was reused, or a process that became
+# something else, is not killed.
 stop_pid() {
+	local st; st="$(start_of "$1")"
 	kill -TERM "$1" 2>/dev/null || true
 	for _ in $(seq 1 15); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
-	echo "[stop] pid $1 still alive; SIGKILL"; kill -KILL "$1" 2>/dev/null || true
+	if [ -n "$st" ] && [ "$(start_of "$1")" = "$st" ] && "$2" "$1"; then
+		echo "[stop] pid $1 still alive; SIGKILL"; kill -KILL "$1" 2>/dev/null || true
+	else
+		echo "[stop] pid $1 is no longer the process that was checked; not killed"
+	fi
 }
 
 stopped=0
 RPID="$(cat "$RUN/run.pid" 2>/dev/null || true)"
 if is_runner "$RPID"; then
 	echo "[stop] SIGTERM to the runner, pid $RPID (it stops its QEMU)"
-	stop_pid "$RPID"; stopped=1
+	stop_pid "$RPID" is_runner; stopped=1
 elif [ -n "$RPID" ]; then
 	echo "[stop] run.pid $RPID is not this checkout's runner; not signalled"
 fi
@@ -37,7 +51,7 @@ rm -f "$RUN/run.pid"
 QPID="$(cat "$RUN/qemu.pid" 2>/dev/null || true)"
 if is_qemu "$QPID"; then
 	echo "[stop] SIGTERM to qemu pid $QPID"
-	stop_pid "$QPID"; stopped=1
+	stop_pid "$QPID" is_qemu; stopped=1
 elif [ -n "$QPID" ] && [ "$stopped" = 0 ]; then
 	echo "[stop] qemu.pid $QPID is not a running guest; not signalled"
 fi
diff --git a/tests/test-boot-gates.sh b/tests/test-boot-gates.sh
index 40d32efa..8f6141b0 100755
--- a/tests/test-boot-gates.sh
+++ b/tests/test-boot-gates.sh
@@ -28,6 +28,9 @@ FAILS=0
 pass() { echo "PASS  $1"; }
 fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
 gate() { if eval "$2" 2>/dev/null; then pass "$1"; else fail "$1"; fi; }
+# setup NAME CHECK: a control's preparation; when it does not hold, that is a FAIL and the control is not
+# judged (a control must never pass because its fixture failed). Returns CHECK's result.
+setup() { if eval "$2" 2>/dev/null; then return 0; fi; fail "setup $1"; return 1; }
 # expect_fail: a control passes when the gate's assertion is FALSE on it.
 control() { if eval "$2" 2>/dev/null; then fail "control $1 (the assertion still held)"; else pass "control $1 (the assertion failed, as it must)"; fi; }
 MODES=" $* "; [ -z "${*:-}" ] && MODES=" --main "
@@ -96,6 +99,27 @@ ready_with_address() { local p r; p=$(grep -aoE 'ethmode: IP .* reported \([0-9]
 # order L1 L2 FILE: line L1 occurs before L2
 order() { local a b; a=$(grep -anm1 -- "$1" "$3" | cut -d: -f1); b=$(grep -anm1 -- "$2" "$3" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
 
+# uart_load SOCK: write the NMEA fixture to SOCK unpaced for 90 s while 8 probes (web 200 + console banner)
+# run. Sets bl_rc (the writer's exit), bl_bytes (bytes written), inload (1 = the writer still ran after the
+# last probe, so every probe fell inside the load) and iok (probes answered). uart_load_held is gate i.
+uart_load() {
+	python3 -I - "$1" "$ROOT/fixtures/gps/valid_fix.nmea" > "$G/blast.txt" 2>&1 <<'PY' &
+import socket, sys, time
+s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(5); data = open(sys.argv[2], "rb").read()
+t0 = time.time(); n = 0
+while time.time() - t0 < 90:
+    try: s.sendall(data); n += len(data)
+    except socket.timeout: pass
+print("bytes %d secs %.1f" % (n, time.time() - t0))
+PY
+	local bl=$! k; iok=0; inload=0
+	for k in 1 2 3 4 5 6 7 8; do sleep 8; [ "$(web / 15)" = 200 ] && console_ok && iok=$((iok+1)); done
+	kill -0 "$bl" 2>/dev/null && inload=1
+	bl_rc=0; wait "$bl" || bl_rc=$?
+	bl_bytes="$(grep -oE '^bytes [0-9]+' "$G/blast.txt" | grep -oE '[0-9]+' || echo 0)"
+}
+uart_load_held() { [ "$bl_rc" = 0 ] && [ "${bl_bytes:-0}" -gt 0 ] && [ "$inload" = 1 ] && [ "$iok" = 8 ]; }
+
 if [[ "$MODES" == *" --main "* ]]; then
 	echo "== builds (a)"
 	"$ROOT/scripts/apply-overlay.sh" > "$G/apply.log" 2>&1; arc=$?
@@ -140,19 +164,9 @@ if [[ "$MODES" == *" --main "* ]]; then
 	waitfor '[ "$(web)" = 200 ]' 30; hweb=$?
 	gate "h  spectrum page within 60 s, then web 200" '[ "$scode" = 200 ] && [ "$st" -le 60 ] && [ "$hweb" = 0 ]'
 	kill "$GP" 2>/dev/null; GP=""
-	python3 -I - "$ROOT/.run/gps-uart1.sock" "$ROOT/fixtures/gps/valid_fix.nmea" > "$G/blast.txt" 2>&1 <<'PY' &
-import socket, sys, time
-s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(5); data = open(sys.argv[2], "rb").read()
-t0 = time.time(); n = 0
-while time.time() - t0 < 90:
-    try: s.sendall(data); n += len(data)
-    except socket.timeout: pass
-print("bytes %d secs %.1f" % (n, time.time() - t0))
-PY
-	BL=$!; iok=0
-	for k in 1 2 3 4 5 6 7 8; do sleep 10; [ "$(web / 15)" = 200 ] && console_ok && iok=$((iok+1)); done
-	wait "$BL"
-	gate "i  UART1 written unpaced for 90 s: web and console answer at all 8 probes" '[ "$iok" = 8 ]'
+	uart_load "$ROOT/.run/gps-uart1.sock"
+	gate "i  UART1 written unpaced for 90 s (writer rc $bl_rc, $bl_bytes B): web and console answer at all 8 probes, all inside the load" \
+		'uart_load_held'
 	console "--reboot" > /dev/null
 	waitfor 'grep -q "restart #2" "$G/run.log"' 180
 	waitfor '[ "$(web)" = 200 ]' 180; eweb=$?
@@ -176,48 +190,77 @@ if [[ "$MODES" == *" --controls "* ]]; then
 	echo "== failing controls"
 	"$ROOT/scripts/apply-overlay.sh" > /dev/null
 	# a: an old patch hunk re-applied (hunk 14 of the former overlay patch, src/loop_functions.cpp)
-	git -C "$ROOT" show c2335d12:overlay/patches/meshcom-qemu-headless.patch > "$G/old.patch" 2>/dev/null
-	git -C "$FW" apply --include=src/loop_functions.cpp "$G/old.patch" 2>/dev/null
-	"$ROOT/scripts/apply-overlay.sh" > "$G/apply-c.log" 2>&1; arc=$?
-	control "a  (a re-applied hunk)" '[ "$arc" = 0 ]'
+	if setup "a: the old patch extracted from history (c2335d12) and its hunk applied" \
+		'git -C "$ROOT" show c2335d12:overlay/patches/meshcom-qemu-headless.patch > "$G/old.patch" && git -C "$FW" apply --include=src/loop_functions.cpp "$G/old.patch"'; then
+		"$ROOT/scripts/apply-overlay.sh" > "$G/apply-c.log" 2>&1; arc=$?
+		control "a  (a re-applied hunk)" '[ "$arc" = 0 ]'
+	fi
 	git -C "$FW" checkout -q -- .
 	# b: a build without the hand-over (initVariant and the task; only `neth` kept): the provisioning boot
 	# panics in the Wi-Fi PHY -> no marker
 	printf '#include <configuration.h>\n#include "esp32/esp32_eth.h"\nEspETH neth;\n' > "$FW/src/qemu/qemu_ethmode.cpp"
 	build "$ENV"; cbrc=$?
 	NODE="$G/node-cb/node-flash.bin"; brc=x
-	if [ "$cbrc" = 0 ]; then
+	if setup "b: the build without the hand-over (rc $cbrc)" '[ "$cbrc" = 0 ]'; then
 		PROVISION_TIMEOUT=300 start_node "$NODE"
 		waitfor '! kill -0 "$RP" 2>/dev/null' 600; wait "$RP"; brc=$?; RP=""
+		setup "b: run.sh ended in a provisioning failure (rc $brc, want 3)" '[ "$brc" = 3 ]' \
+			&& control "b  (no hand-over; run.sh rc $brc)" '[ -s "$NODE.provisioned" ]'
 	fi
-	control "b  (no hand-over; build rc $cbrc, run.sh rc $brc)" '[ "$cbrc" != 0 ] || [ -s "$NODE.provisioned" ]'
-	"$ROOT/scripts/apply-overlay.sh" > /dev/null; build "$ENV"
+	"$ROOT/scripts/apply-overlay.sh" > /dev/null
+	setup "the normal build again" 'build "$ENV"' || { echo "---"; echo "FAILURES: $FAILS"; exit 1; }
 	# d, e, f, g, c on copies of the provisioned node, changed at run time over the console
 	PROV="$G/node/node-flash.bin"; NODE=""
 	copy_node() { mkdir -p "$G/$1"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/$1/"; echo "$G/$1/node-flash.bin"; }
 	[ -s "$PROV.provisioned" ] && NODE="$(copy_node node-c1)" || echo "SKIP  d/e/f/g/c controls: run --main first"
 	if [ -n "$NODE" ]; then
-		start_bridge; start_node "$NODE"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
-		console "--mesh on" > /dev/null; sleep 3
-		info="$(console "--info" '\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)')"
-		control "g  (--mesh on)" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'
-		console "--mesh off" > /dev/null
-		pos="$(console "--pos" 'SAT: [0-9]+ - (?:fix|nofix)')"; sat="$(printf '%s' "$pos" | grep -oE '[0-9]+' | head -1)"
-		control "d  (relay off: --pos)" '[ "${sat:-0}" -gt 0 ] && [ "${pos##* }" = fix ]'
-		console "--mtu 1500" > /dev/null; console "--reboot" > /dev/null
-		waitfor 'grep -q "restart #1" "$G/run.log"' 180; waitfor '[ "$(web)" = 200 ]' 180
-		control "f  (--mtu 1500)" 'grep -aq "\[NET\];mtu;eth;1280" "$(UARTLOG)"'
+		start_bridge; start_node "$NODE"
+		if setup "the controls' node answers (web 200, console banner)" 'waitfor '"'"'[ "$(web)" = 200 ] && console_ok'"'"' 300'; then
+			ire='\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)'
+			info="$(console "--info" "$ire")"
+			if setup "g: the baseline --info reads MESH off, EXTUDP off, Gateway off" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'; then
+				console "--mesh on" > /dev/null; sleep 3
+				info="$(console "--info" "$ire")"
+				setup "g: --info now reads MESH on ($info)" 'printf "%s" "$info" | grep -qF "...MESH on"' \
+					&& control "g  (--mesh on)" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'
+				console "--mesh off" > /dev/null
+			fi
+			pos="$(console "--pos" 'SAT: [0-9]+ - (?:fix|nofix)')"; sat="$(printf '%s' "$pos" | grep -oE '[0-9]+' | head -1)"
+			setup "d: --pos answered with a SAT line ($pos)" '[ -n "$pos" ] && [ "$pos" != "console-error" ]' \
+				&& control "d  (relay off: --pos)" '[ "${sat:-0}" -gt 0 ] && [ "${pos##* }" = fix ]'
+			console "--mtu 1500" > /dev/null; console "--reboot" > /dev/null
+			if setup "f: --reboot -> restart #1 and web 200" 'waitfor '"'"'grep -q "restart #1" "$G/run.log"'"'"' 180 && waitfor '"'"'[ "$(web)" = 200 ]'"'"' 180'; then
+				# upstream prints [NET];mtu only when it changes the netif's MTU, and lwIP's default is 1500,
+				# so the altered state is read from --info
+				mtu="$(console "--info" 'MTU\s*:\s*[0-9]+')"
+				setup "f: --info after the restart reads MTU 1500 ($mtu)" 'printf "%s" "$mtu" | grep -qE ":\s*1500$"' \
+					&& control "f  (--mtu 1500)" 'grep -aq "\[NET\];mtu;eth;1280" "$(UARTLOG)"'
+			fi
+		fi
 		stop_all
 		# e: run.sh without -no-reboot: no restart line after --reboot
 		sed '/-no-reboot/d' "$ROOT/scripts/run.sh" > "$ROOT/scripts/.run-noreboot.sh"; chmod +x "$ROOT/scripts/.run-noreboot.sh"
-		start_node "$NODE" "$ROOT/scripts/.run-noreboot.sh"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
-		console "--reboot" > /dev/null; sleep 60
-		control "e  (no -no-reboot)" 'grep -q "restart #1" "$G/run.log"'
+		start_node "$NODE" "$ROOT/scripts/.run-noreboot.sh"
+		if setup "e: the node without -no-reboot answers" 'waitfor '"'"'[ "$(web)" = 200 ] && console_ok'"'"' 300'; then
+			console "--reboot" > /dev/null; sleep 60
+			setup "e: the runner still runs after --reboot (QEMU reset in place)" 'kill -0 "$RP"' \
+				&& control "e  (no -no-reboot)" 'grep -q "restart #1" "$G/run.log"'
+		fi
 		stop_all; rm -f "$ROOT/scripts/.run-noreboot.sh"
+		# i: the writer fails (no such socket): gate i must not hold on an idle guest
+		NODE="$(copy_node node-c3)"; start_node "$NODE"
+		if setup "i: the node answers (web 200, console banner)" 'waitfor '"'"'[ "$(web)" = 200 ] && console_ok'"'"' 300'; then
+			uart_load "$G/no-such.sock"
+			setup "i: the writer failed (rc $bl_rc)" '[ "$bl_rc" != 0 ]' && control "i  (a failed writer)" 'uart_load_held'
+		fi
+		stop_all
 		# c: the console switched off
-		NODE="$(copy_node node-c2)"; start_node "$NODE"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
-		console "--netconsole off" > /dev/null; sleep 3
-		control "c  (--netconsole off)" 'console_ok'
+		NODE="$(copy_node node-c2)"; start_node "$NODE"
+		if setup "c: the node answers (web 200, console banner)" 'waitfor '"'"'[ "$(web)" = 200 ] && console_ok'"'"' 300'; then
+			console "--netconsole off" > /dev/null; sleep 3
+			setup "c: the guest still serves its web page (only the console is off)" 'waitfor '"'"'[ "$(web)" = 200 ]'"'"' 60' \
+				&& control "c  (--netconsole off)" 'console_ok'
+		fi
 		stop_all
 	fi
 fi
@@ -230,9 +273,9 @@ fi
 if [[ "$MODES" == *" --slow-b "* ]]; then
 	"$ROOT/scripts/apply-overlay.sh" > /dev/null
 	# b': a flag clear in Ethernet mode reaches upstream's initethDHCP() (the loop's 5-minute path)
-	build "$ENV" "-DQEMU_TEST_CLEAR_FLAG_MS=8000"
-	mkdir -p "$G/node-b2"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-b2/" 2>/dev/null
-	start_node "$G/node-b2/node-flash.bin"; waitfor '[ "$(web)" = 200 ]' 300
+	setup "b': the test build" 'build "$ENV" "-DQEMU_TEST_CLEAR_FLAG_MS=8000"'
+	mkdir -p "$G/node-b2"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-b2/"
+	start_node "$G/node-b2/node-flash.bin"; setup "b': the node answers" 'waitfor '"'"'[ "$(web)" = 200 ]'"'"' 300'
 	waitfor 'grep -aq "\[ETH\] DHCP IP" "$(UARTLOG)"' 400
 	waitfor '[ "$(web)" = 200 ]' 30; bweb=$?
 	gate "b' a flag clear -> [ETH] DHCP IP via the stand-in, web 200" 'grep -aq "TEST: node_hasIPaddress cleared" "$(UARTLOG)" && grep -aq "\[ETH\] DHCP IP" "$(UARTLOG)" && [ "$bweb" = 0 ]'
@@ -240,13 +283,14 @@ if [[ "$MODES" == *" --slow-b "* ]]; then
 	# b' control: without the stand-in headers the build fails
 	mv "$FW/variants/qemu-headless/ETHClass2.h" "$G/"; build "$ENV"; src=$?
 	mv "$G/ETHClass2.h" "$FW/variants/qemu-headless/"
-	control "b' (no ETHClass2.h stand-in)" '[ "$src" = 0 ]'
+	setup "b': the build log names the missing ETHClass2.h" '[ "$src" = 0 ] || grep -q "ETHClass2.h" "$G/build-$ENV.log"' \
+		&& control "b' (no ETHClass2.h stand-in)" '[ "$src" = 0 ]'
 fi
 if [[ "$MODES" == *" --slow-k "* ]]; then
 	"$ROOT/scripts/apply-overlay.sh" > /dev/null
 	# k: OpenETH never starts, a node with saved settings: readiness withdrawn, nothing reachable
-	build "$ENV" "-DQEMU_TEST_NO_OPENETH"
-	mkdir -p "$G/node-k"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-k/" 2>/dev/null
+	setup "k: the test build" 'build "$ENV" "-DQEMU_TEST_NO_OPENETH"'
+	mkdir -p "$G/node-k"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-k/"
 	start_node "$G/node-k/node-flash.bin"; sleep 20
 	K="$(UARTLOG)"; kreach=0
 	for k in $(seq 1 14); do [ "$(web / 5)" = 200 ] && kreach=1; console_ok && kreach=1; sleep 25; done
@@ -261,21 +305,28 @@ if [[ "$MODES" == *" --slow-k "* ]]; then
 fi
 if [[ "$MODES" == *" --slow-k2 "* ]]; then
 	"$ROOT/scripts/apply-overlay.sh" > /dev/null
-	build "$ENV" "-DQEMU_TEST_NO_OPENETH"
-	mkdir -p "$G/node-k"; cp "$PROV" "$PROV.efuse" "$G/node-k/" 2>/dev/null
-	rm -f "$G/node-k/node-flash.bin.provisioned"; PROVISION_TIMEOUT=120 start_node "$G/node-k/node-flash.bin"
+	setup "k2: the test build" 'build "$ENV" "-DQEMU_TEST_NO_OPENETH"'
+	# A fresh node: no image yet, so node-image.sh creates it from this build (the stock defaults).
+	rm -rf "$G/node-k2"; PROVISION_TIMEOUT=120 start_node "$G/node-k2/node-flash.bin"
 	waitfor '! kill -0 "$RP" 2>/dev/null' 600; wait "$RP"; krc=$?; RP=""
-	gate "k  a fresh node in this build -> provisioning rc 3, no marker" '[ "$krc" = 3 ] && [ ! -e "$G/node-k/node-flash.bin.provisioned" ]'
+	gate "k  a fresh node (image created from this build) -> provisioning rc 3, no marker" \
+		'grep -q "node image: created from the build" "$G/run.log" && [ "$krc" = 3 ] && [ ! -e "$G/node-k2/node-flash.bin.provisioned" ]'
 fi
 if [[ "$MODES" == *" --slow-l "* ]]; then
 	"$ROOT/scripts/apply-overlay.sh" > /dev/null
 	# l control: the old qemu_network.cpp (link loss kept readiness)
-	git -C "$ROOT" show c2335d12:overlay/src/qemu/qemu_network.cpp > "$FW/src/qemu/qemu_network.cpp"; build "$ENV"
-	mkdir -p "$G/node-l"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-l/" 2>/dev/null
-	start_node "$G/node-l/node-flash.bin"; waitfor '[ "$(web)" = 200 ]' 300
-	L="$(UARTLOG)"; monitor "set_link net0 off"; sleep 12
-	control "l  (old qemu_network.cpp)" 'grep -aq "readiness withdrawn" "$L"'
-	monitor "set_link net0 on"; stop_all
+	if setup "l: the old qemu_network.cpp extracted from history (c2335d12) and built" \
+		'git -C "$ROOT" show c2335d12:overlay/src/qemu/qemu_network.cpp > "$FW/src/qemu/qemu_network.cpp" && build "$ENV"'; then
+		mkdir -p "$G/node-l"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-l/"
+		start_node "$G/node-l/node-flash.bin"
+		if setup "l: the node answers" 'waitfor '"'"'[ "$(web)" = 200 ]'"'"' 300'; then
+			L="$(UARTLOG)"; monitor "set_link net0 off"; sleep 12
+			setup "l: the link is down (web from the host fails)" '[ "$(web / 5)" != 200 ]' \
+				&& control "l  (old qemu_network.cpp)" 'grep -aq "readiness withdrawn" "$L"'
+			monitor "set_link net0 on"
+		fi
+		stop_all
+	fi
 fi
 
 echo "---"
diff --git a/tests/test-run-supervisor.sh b/tests/test-run-supervisor.sh
index 80b87934..6c59c3f2 100644
--- a/tests/test-run-supervisor.sh
+++ b/tests/test-run-supervisor.sh
@@ -36,6 +36,7 @@ ENV=qemu-headless-extradio-gpsd
 #   boot SECS [INFO]   a boot: Ethernet mode + console lines, a console and a web page; resets (rc 0)
 #                      after SECS (inf = never). INFO replaces the --info reply's settings line.
 #   boot-noterm        a boot that ignores TERM (needs KILL)
+#   boot-exec-term     a boot whose TERM turns the process into another program (same PID, no guest)
 #   exit1              QEMU fails at once (rc 1)
 cat > "$T/qemu-stub" <<'EOF'
 #!/usr/bin/env python3
@@ -69,6 +70,9 @@ if m.startswith("prov"):
             with open(os.environ["STUB_STDIN"], "w") as f: f.write("\n".join(got) + "\n")
             time.sleep(0.5); sys.exit(0)
     sys.exit(0)
+if m == "boot-exec-term":
+    signal.signal(signal.SIGTERM, lambda *a: (note("TERM-exec %d" % n), os.execv("/bin/sleep", ["sleep", "61"])))
+    while True: time.sleep(0.2)
 if m == "boot-noterm":
     signal.signal(signal.SIGTERM, lambda *a: note("TERM-ignored %d" % n))
     while True: time.sleep(1)
@@ -136,6 +140,17 @@ for c in "prov-noack|no acknowledgement" "prov-rc1|QEMU exited rc=1" "prov-hang|
 	PROVISION_TIMEOUT=3 start; finish 40
 	check "$mode -> rc 3, no marker ($msg)" '[ "$RC" = 3 ] && [ ! -e "$NODE.provisioned" ] && grep -q "$msg" "$T/run.out"'
 done
+# A node image that exists, with a marker for another command list (node-image.sh keeps the marker of an
+# existing image; it removes one only when it creates or resets the image).
+other_marker() { mkdir -p "$(dirname "$NODE")"; "$R/scripts/node-image.sh" "$R/.work/MeshCom-Firmware/.pio/build/$ENV/flash.bin" "$NODE" >/dev/null
+	echo "2026-01-01T00:00:00Z other" > "$NODE.provisioned"; }
+reset_case prov-noack "boot inf"; other_marker
+PROVISION_TIMEOUT=3 start; finish 40
+check "a marker for another list, provisioning fails -> rc 3, the marker removed" '[ "$RC" = 3 ] && [ ! -e "$NODE.provisioned" ]'
+reset_case prov-hang; other_marker
+start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20; sleep 1
+kill -TERM "$RP"; finish
+check "a marker for another list, TERM during provisioning -> rc 0, the marker removed" '[ "$RC" = 0 ] && [ ! -e "$NODE.provisioned" ]'
 reset_case prov-ok "boot inf ...NETWORK Mode:ETH ...MESH on ...EXTUDP off / Gateway off"
 PROVISION_TIMEOUT=25 start; finish 80
 cp "$T/run.out" "$T/run-meshon.out"
@@ -175,6 +190,12 @@ reset_case boot-noterm; mark
 start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20; sleep 1
 t0=$(date +%s); kill -TERM "$RP"; finish 40; dt=$(( $(date +%s) - t0 ))
 check "a guest ignoring TERM is killed after about 10 s, rc 0" '[ "$RC" = 0 ] && grep -q "TERM-ignored 0" "$STUB_LOG" && [ "$dt" -ge 9 ] && ! pgrep -f "[q]emu-stub" >/dev/null'
+reset_case boot-exec-term; mark
+start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20; sleep 1
+kill -TERM "$RP"; finish 40
+check "a guest PID that became another program while TERM was pending is not killed, rc 0" \
+	'[ "$RC" = 0 ] && grep -q "TERM-exec 0" "$STUB_LOG" && pgrep -x -f "sleep 61" >/dev/null && grep -q "no longer this run" "$T/run.out"'
+pkill -x -f "sleep 61" 2>/dev/null || true
 reset_case "boot 1"; mark
 start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20
 kill -TERM "$RP"; finish
@@ -201,6 +222,14 @@ echo "$OTHERQ" > "$R/.run/qemu.pid"; echo 99999999 > "$R/.run/run.pid"
 "$R/scripts/stop.sh" > "$T/stop4.out"; src4=$?
 check "stop.sh does not signal another runner's QEMU named by a stale qemu.pid (rc 0)" '[ "$src4" = 0 ] && kill -0 "$OTHERQ" 2>/dev/null && grep -q "not a running guest" "$T/stop4.out"'
 kill "$OTHERQ" 2>/dev/null; wait "$OTHERQ" 2>/dev/null
+# A runner PID that stops being the runner during stop.sh's wait (it drops run.lock and becomes another
+# program, same PID): the SIGKILL after the wait must not reach it.
+bash -c 'exec 8>"$1"; trap "exec 8>&-; exec sleep 62" TERM; while :; do sleep 0.2; done' _ "$R/.run/run.lock" & FR=$!
+sleep 0.5; echo "$FR" > "$R/.run/run.pid"; echo 99999999 > "$R/.run/qemu.pid"
+"$R/scripts/stop.sh" > "$T/stop5.out"; src5=$?
+check "stop.sh does not SIGKILL a runner PID that became another program during the wait (rc 0)" \
+	'[ "$src5" = 0 ] && kill -0 "$FR" 2>/dev/null && grep -q "no longer the process that was checked" "$T/stop5.out"'
+kill "$FR" 2>/dev/null; wait "$FR" 2>/dev/null
 cp "$T/run.pid.real" "$R/.run/run.pid"; echo "$(pgrep -f "[q]emu-stub" | head -1)" > "$R/.run/qemu.pid"
 "$R/scripts/status.sh" > "$T/status.out"; ssrc=$?
 check "status.sh shows a running guest, rc 0" '[ "$ssrc" = 0 ]'
```
