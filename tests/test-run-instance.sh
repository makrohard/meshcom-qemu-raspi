#!/usr/bin/env bash
#
# test-run-instance.sh — a second guest on one host (the test lab's two-node MeshCom row): run.sh's
# --instance <n> moves the two host ports, the run directory and the persisted-state check to that
# instance; n = 0 (the default) is exactly the single-guest QEMU argv (the whole vector is pinned);
# --xr-redirect adds the guestfwd that sends the firmware's compiled-in bridge address to the
# instance's own bridge. A stub stands in for qemu-system-xtensa: it provisions, then serves a console
# and a web page on the ports run.sh gave it.
# No QEMU, no network. Needs ports 12323/18083 and 12333/18093 free: never run it in parallel with
# tests/test-run-supervisor.sh (same ports, same stub name); boot-gates.yml runs them one after another.
#
# EXIT CODES: 0 = all cases passed (prints ALL PASS) · 1 = a failure (prints FAILURES).
# shellcheck disable=SC2016
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

R="$T/repo"; mkdir -p "$R/scripts" "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless"
cp "$REPO"/scripts/{run.sh,stop.sh,node-image.sh,node-efuse.sh} "$R/scripts/"
head -c $((4 * 1024 * 1024)) /dev/zero > "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless/flash.bin"

# The stub: first launch = provisioning (acknowledges --netmode eth), later launches = a boot that serves
# --info on the console port and 200 on the web port, both read from its own -nic argument.
cat > "$T/qemu-stub" <<'EOF'
#!/usr/bin/env python3
import os, re, socket, sys, threading, time
if sys.argv[1:2] == ["--version"]:
    print("QEMU emulator version 9.2.2"); sys.exit(0)
open(os.environ["STUB_ARGS"], "a").write("\n".join(sys.argv[1:]) + "\n--\n")
nic = next(a for a in sys.argv if a.startswith("user,"))
web, con = (int(p) for p in re.findall(r"hostfwd=tcp:127\.0\.0\.1:(\d+)-", nic))
state = os.environ["STUB_STATE"]
first = not os.path.exists(state); open(state, "w").write("1")
def out(s): sys.stdout.write(s + "\n"); sys.stdout.flush()
if first:
    out("CLIENT STARTED")
    for raw in sys.stdin:
        if raw.strip() == "--netmode eth":
            out("[CMD] netmode -> Ethernet"); time.sleep(0.3); sys.exit(0)
    sys.exit(0)
def serve(port, reply):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(4)
    while True:
        c, _ = s.accept(); time.sleep(0.2); c.sendall(reply); c.close()
info = b"MeshCom Console\r\n...NETWORK Mode:ETH ...MESH off ...EXTUDP off / Gateway off\r\n"
threading.Thread(target=serve, args=(con, info), daemon=True).start()
threading.Thread(target=serve, args=(web, b"HTTP/1.0 200 OK\r\n\r\n"), daemon=True).start()
out("[NET] Ethernet mode"); out("Console started on port 2323")
while True: time.sleep(1)
EOF
chmod +x "$T/qemu-stub"
export STUB_ARGS="$T/args" STUB_STATE="$T/state"
NIC1="user,id=net0,model=open_eth,hostfwd=tcp:127.0.0.1:18093-:80,hostfwd=tcp:127.0.0.1:12333-:2323,guestfwd=tcp:10.0.2.2:7000-tcp:127.0.0.1:7001"

echo "== a second instance, provisioned and verified on its own ports"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/b/node.bin" --instance 1 \
	--xr-redirect 7000:7001 > "$T/run1.out" 2>&1 &
RUNNER=$!
for _ in $(seq 1 60); do [ -f "$T/b/node.bin.provisioned" ] && break; sleep 1; done
check "--instance 1: every launch uses the moved ports and the redirect" \
	'grep -qx "$NIC1" "$STUB_ARGS" && ! grep -q "18083\|12323" "$STUB_ARGS"'
check "--instance 1: the persisted-state check reads its own ports (marker written)" '[ -f "$T/b/node.bin.provisioned" ]'
check "--instance 1: its pid files are in .run/1/" '[ -f "$R/.run/1/run.pid" ] && [ -f "$R/.run/1/qemu.pid" ]'
check "--instance 1: it announces its own web port" 'grep -q "127.0.0.1:18093/" "$T/run1.out"'
"$R/scripts/stop.sh" --instance 1 > "$T/stop1.out" 2>&1
wait "$RUNNER" 2>/dev/null
check "stop.sh --instance 1 stops that runner" '! kill -0 "$RUNNER" 2>/dev/null && grep -q "SIGTERM to the runner" "$T/stop1.out"'

echo "== the default is the single-guest layout"
rm -f "$STUB_STATE"; : > "$STUB_ARGS"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/a/node.bin" > "$T/run0.out" 2>&1 &
RUNNER=$!
for _ in $(seq 1 60); do [ -f "$T/a/node.bin.provisioned" ] && break; sleep 1; done
# One complete default QEMU invocation, captured with this stub from run.sh at d1b73c84 (before
# --instance); $T stands for the temp root. Every launch without the flag must be exactly this vector.
cat > "$T/argv0.expected" <<'ARGV'
-nographic
-no-reboot
-machine
esp32
-m
4M
-drive
file=$T/a/node.bin,if=mtd,format=raw
-drive
file=$T/a/node.bin.efuse,if=none,format=raw,id=efuse
-global
driver=nvram.esp32.efuse,property=drive,value=efuse
-nic
user,id=net0,model=open_eth,hostfwd=tcp:127.0.0.1:18083-:80,hostfwd=tcp:127.0.0.1:12323-:2323
-global
driver=timer.esp32.timg,property=wdt_disable,value=true
-serial
mon:stdio
-monitor
unix:$T/repo/.run/monitor.sock,server=on,wait=off
--
ARGV
argv0_same() {
	local blocks; blocks="$(grep -cx -- "--" "$STUB_ARGS")"
	[ "$blocks" -ge 1 ] || return 1
	for _ in $(seq 1 "$blocks"); do cat "$T/argv0.expected"; done | diff -q - <(sed "s|$T|\$T|g" "$STUB_ARGS") > /dev/null
}
check "no flag: every launch's whole QEMU argv is the pre-instance one" \
	'[ -f "$T/a/node.bin.provisioned" ] && argv0_same'
check "no flag: the pid files are in .run/" '[ -f "$R/.run/run.pid" ]'
"$R/scripts/stop.sh" > /dev/null 2>&1; wait "$RUNNER" 2>/dev/null

echo "== stopping one instance leaves the other running"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/a/node.bin" > "$T/r0.out" 2>&1 &
R0=$!
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/b/node.bin" --instance 1 > "$T/r1.out" 2>&1 &
R1=$!
for _ in $(seq 1 40); do [ -f "$R/.run/qemu.pid" ] && [ -f "$R/.run/1/qemu.pid" ] && break; sleep 0.5; done
Q0="$(cat "$R/.run/qemu.pid")"; Q1="$(cat "$R/.run/1/qemu.pid")"
"$R/scripts/stop.sh" --instance 1 > /dev/null 2>&1; wait "$R1" 2>/dev/null
check "stop.sh --instance 1 leaves instance 0's runner and guest running" \
	'kill -0 "$R0" 2>/dev/null && kill -0 "$Q0" 2>/dev/null && ! kill -0 "$Q1" 2>/dev/null'
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/b/node.bin" --instance 1 > "$T/r1b.out" 2>&1 &
R1=$!
for _ in $(seq 1 40); do [ "$(cat "$R/.run/1/qemu.pid" 2>/dev/null)" != "$Q1" ] && [ -f "$R/.run/1/qemu.pid" ] && break; sleep 0.5; done
Q1="$(cat "$R/.run/1/qemu.pid")"
"$R/scripts/stop.sh" > /dev/null 2>&1; wait "$R0" 2>/dev/null
check "plain stop.sh leaves instance 1's runner and guest running" \
	'kill -0 "$R1" 2>/dev/null && kill -0 "$Q1" 2>/dev/null && ! kill -0 "$Q0" 2>/dev/null'
"$R/scripts/stop.sh" --instance 1 > /dev/null 2>&1; wait "$R1" 2>/dev/null

echo "== refusals"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --instance x > "$T/bad.out" 2>&1; rc=$?
check "a non-digit instance is refused" '[ "$rc" = 2 ] && grep -q "instance must be" "$T/bad.out"'
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --xr-redirect 7000 > "$T/bad2.out" 2>&1; rc=$?
check "a redirect without a host port is refused" '[ "$rc" = 2 ] && grep -q "xr-redirect must be" "$T/bad2.out"'
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --xr-redirect "7000:7001,hostfwd=tcp::2222-:22" > "$T/bad3.out" 2>&1; rc=$?
check "a redirect with trailing text is refused (nothing reaches -nic)" '[ "$rc" = 2 ] && grep -q "xr-redirect must be" "$T/bad3.out"'
"$R/scripts/stop.sh" --instance x > "$T/bad4.out" 2>&1; rc=$?
check "stop.sh refuses an invalid --instance with 2" '[ "$rc" = 2 ]'

if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "FAILURES: $FAILS"; exit 1
