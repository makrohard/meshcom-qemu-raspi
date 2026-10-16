#!/usr/bin/env bash
#
# test-run-supervisor.sh — tests for scripts/run.sh as the guest's supervisor and provisioner, and for
# scripts/stop.sh / scripts/status.sh. No QEMU and no network: a stub stands in for qemu-system-xtensa and
# plays the firmware's part from a plan (one mode per launch), including a console on 127.0.0.1:12323 and
# a web page on 127.0.0.1:18083 for run.sh's persisted-state check. Needs those two ports free.
#
# EXIT CODES: 0 = all cases passed (prints ALL PASS) · 1 = a failure (prints FAILURES).
# Each check is an eval'd string, so its variables look unexpanded/unused to shellcheck.
# shellcheck disable=SC2016,SC2034
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
T="$(mktemp -d)"
FAILS=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

for p in 12323 18083; do
	if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "SKIP-REFUSED: port $p is in use (a guest running?)"; exit 1; fi
done

# A sandbox copy of the deliverable with a dummy build.
R="$T/repo"; mkdir -p "$R/scripts" "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless-extradio-gpsd"
cp "$REPO"/scripts/{run.sh,stop.sh,status.sh,node-image.sh,node-efuse.sh} "$R/scripts/"
head -c $((4 * 1024 * 1024)) /dev/zero > "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless-extradio-gpsd/flash.bin"
ENV=qemu-headless-extradio-gpsd

# The stub. Modes (one line of $STUB_PLAN per launch, consumed in order):
#   prov-ok            provisioning: prints CLIENT STARTED, acknowledges --netmode eth, exits 0
#   prov-noack         provisioning: CLIENT STARTED, exits 0 without the acknowledgement
#   prov-rc1           provisioning: CLIENT STARTED, exits 1
#   prov-hang          provisioning: CLIENT STARTED, never ends
#   boot SECS [INFO]   a boot: Ethernet mode + console lines, a console and a web page; resets (rc 0)
#                      after SECS (inf = never). INFO replaces the --info reply's settings line.
#   boot-noterm        a boot that ignores TERM (needs KILL)
#   exit1              QEMU fails at once (rc 1)
cat > "$T/qemu-stub" <<'EOF'
#!/usr/bin/env python3
import os, signal, socket, sys, threading, time
if sys.argv[1:2] == ["--version"]:
    print("QEMU emulator version 9.2.2"); sys.exit(0)
plan, state = os.environ["STUB_PLAN"], os.environ["STUB_STATE"]
lines = open(plan).read().splitlines()
n = int(open(state).read()) if os.path.exists(state) else 0
open(state, "w").write(str(n + 1))
mode = (lines[n] if n < len(lines) else "boot inf").split(" ", 2)
log = os.environ["STUB_LOG"]
def note(s):
    with open(log, "a") as f: f.write(s + "\n")
note("launch %d %s" % (n, mode[0]))
def out(s): sys.stdout.write(s + "\n"); sys.stdout.flush()
signal.signal(signal.SIGTERM, lambda *a: (note("TERM %d" % n), sys.exit(0)))
m = mode[0]
if m == "exit1": sys.exit(1)
if m.startswith("prov"):
    out("CLIENT STARTED")
    if m == "prov-rc1": time.sleep(0.5); sys.exit(1)
    if m == "prov-noack": time.sleep(1); sys.exit(0)
    if m == "prov-hang":
        while True: time.sleep(1)
    got = []
    for raw in sys.stdin:
        c = raw.strip(); got.append(c)
        if c == "--netmode eth":
            out("[CMD] netmode -> Ethernet")
            with open(os.environ["STUB_STDIN"], "w") as f: f.write("\n".join(got) + "\n")
            time.sleep(0.5); sys.exit(0)
    sys.exit(0)
if m == "boot-noterm":
    signal.signal(signal.SIGTERM, lambda *a: note("TERM-ignored %d" % n))
    while True: time.sleep(1)
secs = float("inf") if mode[1] == "inf" else float(mode[1])
info = mode[2] if len(mode) > 2 else "...NETWORK Mode:ETH ...MESH off ...EXTUDP off / Gateway off"
def serve(port, handler):
    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port)); srv.listen(4)
    while True:
        c, _ = srv.accept(); threading.Thread(target=handler, args=(c,), daemon=True).start()
def console(c):
    c.sendall(b"OK\r\nMeshCom Console\r\nType --help for commands\r\n")
    try:
        req = c.recv(256)
        if b"--info" in req: c.sendall(("--info\n" + info + "\n...PASSWD <secret>\n").encode())
        if b"--pos" in req: c.sendall(("--pos\n...LAT: 48.0000 N\n" + os.environ.get("STUB_POS", "...GPS: on") + "\n").encode())
        time.sleep(0.2)
    finally: c.close()
def web(c):
    c.recv(1024); c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"); c.close()
for p, h in ((12323, console), (18083, web)):
    threading.Thread(target=serve, args=(p, h), daemon=True).start()
out("[NET] Ethernet mode"); out("[CON ]...Console started on port 2323")
t0 = time.time()
while time.time() - t0 < secs: time.sleep(0.2)
note("reset %d" % n); sys.exit(0)
EOF
chmod +x "$T/qemu-stub"
export STUB_PLAN="$T/plan" STUB_STATE="$T/state" STUB_LOG="$T/stub.log" STUB_STDIN="$T/stdin"
export FAST_RUN_S=2 RESTART_BUDGET=4 PROVISION_TIMEOUT=30
NODE="$T/node/node-flash.bin"
reset_case() {
	pkill -f "[q]emu-stub" 2>/dev/null || true
	rm -rf "$R/.run" "$T/node" "$STUB_STATE" "$STUB_LOG" "$STUB_STDIN"; printf '%s\n' "$@" > "$STUB_PLAN"
}
start() { "$R/scripts/run.sh" --env "$ENV" --qemu "$T/qemu-stub" --node-image "$NODE" > "$T/run.out" 2>&1 & RP=$!; }
wait_for() { local i; for i in $(seq 1 "$2"); do eval "$1" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
# finish [N]: wait up to N/2 s for run.sh; one still running then is stopped and reported as rc 124
finish() { local i; for i in $(seq 1 "${1:-60}"); do kill -0 "$RP" 2>/dev/null || break; sleep 0.5; done
	if kill -0 "$RP" 2>/dev/null; then kill -TERM "$RP"; wait "$RP"; RC=124; else wait "$RP"; RC=$?; fi; }

echo "== provisioning"
reset_case prov-ok "boot inf"
start
wait_for 'grep -q "provisioning verified" "$T/run.out"' 40
check "a fresh node is provisioned, verified and the marker written" '[ -s "$NODE.provisioned" ]'
check "the commands reach UART0 in order, --netmode eth last" '[ "$(tail -1 "$STUB_STDIN")" = "--netmode eth" ] && grep -qx -- "--mesh off" "$STUB_STDIN" && grep -qx -- "--gps on" "$STUB_STDIN"'
check "the marker names the command list's sha256" '[ "$(cut -d" " -f2 "$NODE.provisioned")" = "$(sed "/^$/d" "$STUB_STDIN" | sha256sum | cut -d" " -f1)" ]'
check "the --info reply is never written (no password field in any log)" '! grep -rq "PASSWD" "$R/.run" "$T/run.out"'
check "uart-latest.log points at the supervised boot" '[ "$(readlink "$R/.run/uart-latest.log")" != "" ] && ! readlink "$R/.run/uart-latest.log" | grep -q provision'
"$R/scripts/stop.sh" > "$T/stop.out"; finish
check "stop.sh stops the runner, which exits 0" '[ "$RC" = 0 ] && grep -q "TERM 1" "$STUB_LOG"'
printf '%s\n' "boot inf" > "$STUB_PLAN"; rm -f "$STUB_STATE"
start; wait_for 'grep -q "launch 0 boot" "$STUB_LOG"' 20
check "a second start with the marker does not provision again" '! grep -q "provisioning the node" "$T/run.out"'
"$R/scripts/stop.sh" >/dev/null; finish
echo "stamp other" > "$NODE.provisioned"; printf '%s\n' prov-ok "boot inf" > "$STUB_PLAN"; rm -f "$STUB_STATE"
start; wait_for 'grep -q "provisioning verified" "$T/run.out"' 40
check "a marker for another command list provisions again" 'grep -q "provisioning the node" "$T/run.out"'
"$R/scripts/stop.sh" >/dev/null; finish

for c in "prov-noack|no acknowledgement" "prov-rc1|QEMU exited rc=1" "prov-hang|timeout waiting"; do
	mode="${c%%|*}"; msg="${c#*|}"
	reset_case "$mode" "boot inf"
	PROVISION_TIMEOUT=3 start; finish 40
	check "$mode -> rc 3, no marker ($msg)" '[ "$RC" = 3 ] && [ ! -e "$NODE.provisioned" ] && grep -q "$msg" "$T/run.out"'
done
reset_case prov-ok "boot inf ...NETWORK Mode:ETH ...MESH on ...EXTUDP off / Gateway off"
PROVISION_TIMEOUT=25 start; finish 80
cp "$T/run.out" "$T/run-meshon.out"
check "a persisted state with MESH on -> rc 3, no marker" '[ "$RC" = 3 ] && [ ! -e "$NODE.provisioned" ] && grep -qF "lacks '"'"'...MESH off'"'"'" "$T/run.out"'
reset_case prov-ok "boot inf"
STUB_POS="...GPS: off" PROVISION_TIMEOUT=25 start; finish 80
check "a *-gpsd node whose --pos reads GPS: off -> rc 3, no marker" '[ "$RC" = 3 ] && [ ! -e "$NODE.provisioned" ] && grep -qF "lacks '"'"'...GPS: on'"'"'" "$T/run.out"'
check "the --pos reply is never written (no position in any log)" '! grep -rq "LAT: 48" "$R/.run" "$T/run.out"'
reset_case prov-hang
start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20; sleep 1
kill -TERM "$RP"; finish
check "TERM during provisioning -> rc 0, no marker, the stub stopped" '[ "$RC" = 0 ] && [ ! -e "$NODE.provisioned" ] && grep -q "TERM 0" "$STUB_LOG"'
reset_case prov-hang; mkdir -p "$R/.run"; echo old > "$R/.run/uart-old.log"; ln -sf uart-old.log "$R/.run/uart-latest.log"
start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20
check "an old uart-latest.log is gone while provisioning runs" '[ ! -e "$R/.run/uart-latest.log" ]'
kill -TERM "$RP"; finish

echo "== supervision (FAST_RUN_S=2, RESTART_BUDGET=4)"
mark() { mkdir -p "$(dirname "$NODE")"; "$R/scripts/node-image.sh" "$R/.work/MeshCom-Firmware/.pio/build/$ENV/flash.bin" "$NODE" >/dev/null; \
	printf '%s\n' "--setssid qemu0" "--setpwd qemu0000" "--webserver on" "--netconsole on" "--mesh off" "--gateway off" "--extudp off" "--gps on" "--wifiap off" "--netmode eth" \
	| sha256sum | cut -d' ' -f1 | sed 's/^/2026-01-01T00:00:00Z /' > "$NODE.provisioned"; }
reset_case "boot 0.3" "boot 0.3" "boot 0.3" "boot inf"; mark
start; finish 40
check "3 runs shorter than FAST_RUN_S in a row -> rc 75" '[ "$RC" = 75 ] && grep -q "3 runs shorter" "$T/run.out"'
reset_case "boot 2.5" "boot 0.3" "boot 0.3" "boot 2.5" "boot 0.3" "boot inf"; mark
RESTART_BUDGET=10 start; wait_for 'grep -q "launch 5" "$STUB_LOG"' 60
check "a run of at least FAST_RUN_S resets the fast count" 'kill -0 "$RP" 2>/dev/null && grep -q "restart #5" "$T/run.out"'
check "each restart is recorded in .run/restarts" '[ "$(cut -d" " -f1 "$R/.run/restarts")" = 5 ]'
"$R/scripts/stop.sh" >/dev/null; finish
reset_case "boot 2.2" "boot 2.2" "boot 2.2" "boot 2.2" "boot 2.2" "boot inf"; mark
start; finish 80
check "more than RESTART_BUDGET restarts within an hour -> rc 75" '[ "$RC" = 75 ] && grep -q "more than 4 restarts" "$T/run.out"'
reset_case exit1; mark
start; finish 20
check "QEMU exiting rc 1 -> rc 5" '[ "$RC" = 5 ] && grep -q "QEMU exited rc=1" "$T/run.out"'
reset_case boot-noterm; mark
start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20; sleep 1
t0=$(date +%s); kill -TERM "$RP"; finish 40; dt=$(( $(date +%s) - t0 ))
check "a guest ignoring TERM is killed after about 10 s, rc 0" '[ "$RC" = 0 ] && grep -q "TERM-ignored 0" "$STUB_LOG" && [ "$dt" -ge 9 ] && ! pgrep -f "[q]emu-stub" >/dev/null'
reset_case "boot 1"; mark
start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20
kill -TERM "$RP"; finish
sleep 2
check "a stop between runs launches nothing more" '[ "$RC" = 0 ] && ! grep -q "launch 1" "$STUB_LOG"'

echo "== ownership (stop.sh, a second runner, status.sh)"
reset_case "boot inf"; mark
start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20
"$R/scripts/run.sh" --env "$ENV" --qemu "$T/qemu-stub" --node-image "$T/other/node.bin" > "$T/run2.out" 2>&1; rc2=$?
check "a second run.sh in the same checkout is refused" '[ "$rc2" = 1 ] && grep -q "another run.sh" "$T/run2.out"'
sleep 100 & DECOY=$!
cp "$R/.run/run.pid" "$T/run.pid.real"; echo "$DECOY" > "$R/.run/run.pid"; echo "$DECOY" > "$R/.run/qemu.pid"
"$R/scripts/stop.sh" > "$T/stop2.out"; src=$?
check "stop.sh does not signal a reused pid (rc 0)" '[ "$src" = 0 ] && kill -0 "$DECOY" 2>/dev/null && grep -q "not this checkout" "$T/stop2.out"'
kill "$DECOY"; cp "$T/run.pid.real" "$R/.run/run.pid"
"$R/scripts/status.sh" > "$T/status.out"; ssrc=$?
check "status.sh shows a running guest, rc 0" '[ "$ssrc" = 0 ]'
"$R/scripts/stop.sh" >/dev/null; finish
"$R/scripts/stop.sh" > "$T/stop3.out"; s3=$?
"$R/scripts/status.sh" > "$T/status2.out"; s4=$?
check "stop.sh and status.sh return 0 with nothing running" '[ "$s3" = 0 ] && [ "$s4" = 0 ] && grep -q "nothing was running" "$T/stop3.out"'

pkill -f "[q]emu-stub" 2>/dev/null || true
[ "$FAILS" -eq 0 ] && rm -rf "$T" || echo "(kept: $T)"
if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "FAILURES: $FAILS"; exit 1
