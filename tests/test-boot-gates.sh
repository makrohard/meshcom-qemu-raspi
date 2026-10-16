#!/usr/bin/env bash
#
# test-boot-gates.sh — the build and boot gates of the QEMU target, on the real firmware and QEMU.
# SLOW (tens of minutes); needs a prepared workspace (scripts/setup.sh, apply-overlay.sh,
# prepare-openeth.sh), PlatformIO, qemu-system-xtensa, the meshcom-loraham-bridge binary and python3.
#
#   BRIDGE=<meshcom-loraham-bridge> QEMU_BIN=<qemu-system-xtensa> [PIO=<pio>] tests/test-boot-gates.sh [--main] [--controls] [--slow]
#
#   --main      (default) gates a–l on the LHPC env qemu-headless-extradio-gpsd, from a fresh node
#   --controls  each gate's failing control: the gate's assertion must FAIL on it
#   --slow      the test builds, several minutes each; also one at a time: --slow-b (b': a flag clear
#               reaches upstream's initethDHCP), --slow-k (k: OpenETH never starts, a provisioned node),
#               --slow-k2 (k: the same build, a fresh node), --slow-l (l's control: the old qemu_network.cpp)
#
# The slow modes leave their test build in the workspace; --main (or scripts/build.sh) builds it again.
# Ports 7000/7001 (bridge, tap), 12323/18083 (guest) must be free. The test password is random per run
# and never printed; the test callsign is a placeholder. EXIT: 0 = every selected gate as expected.
# Each gate is an eval'd string, so its variables look unexpanded/unused to shellcheck.
# shellcheck disable=SC2016,SC2034
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$ROOT/.work/MeshCom-Firmware"
ENV=qemu-headless-extradio-gpsd
: "${BRIDGE:?BRIDGE=<meshcom-loraham-bridge>}" "${QEMU_BIN:?QEMU_BIN=<qemu-system-xtensa>}"
PIO="${PIO:-pio}"
G="$ROOT/.run/gates"
FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
gate() { if eval "$2" 2>/dev/null; then pass "$1"; else fail "$1"; fi; }
# expect_fail: a control passes when the gate's assertion is FALSE on it.
control() { if eval "$2" 2>/dev/null; then fail "control $1 (the assertion still held)"; else pass "control $1 (the assertion failed, as it must)"; fi; }
MODES=" $* "; [ -z "${*:-}" ] && MODES=" --main "
[[ "$MODES" == *" --slow "* ]] && MODES="$MODES --slow-b --slow-k --slow-k2 --slow-l "
# --main starts from nothing; --controls and --slow use the node --main provisioned.
[[ "$MODES" == *" --main "* ]] && rm -rf "$G"; mkdir -p "$G"

XRPW="$G/xr.pw"; python3 -I -c 'import secrets; print(secrets.token_hex(12), end="")' > "$XRPW"; chmod 600 "$XRPW"
CALL="XX9TST-1"                        # a placeholder call, accepted by the firmware's syntax check

build() {   # build ENV [extra -D flags]
	XR_HOST=10.0.2.2 XR_PORT=7000 XR_PASSWORD="$(cat "$XRPW")" PLATFORMIO_BUILD_FLAGS="${2:-}" PIO="$PIO" \
		"$ROOT/scripts/build.sh" --env "$1" > "$G/build-$1.log" 2>&1
}
UARTLOG() { readlink -f "$ROOT/.run/uart-latest.log"; }
console() { # console CMD [REGEX]: send CMD on the net console; print only REGEX matches (the reply has a password field)
	python3 -I - "$@" <<'PY'
import re, socket, sys, time
try:
    s = socket.create_connection(("127.0.0.1", 12323), timeout=10); s.settimeout(3)
    try: s.recv(256)
    except Exception: pass
    s.sendall((sys.argv[1] + "\r\n").encode()); time.sleep(4); d = b""
    try:
        while True:
            c = s.recv(8192)
            if not c: break
            d += c
    except Exception: pass
    if len(sys.argv) > 2: print(" | ".join(re.findall(sys.argv[2], d.decode(errors="replace"))))
except Exception as e:
    print("console-error", type(e).__name__)
PY
}
web() { curl -s -m "${2:-15}" -o "${3:-/dev/null}" -w '%{http_code}' "http://127.0.0.1:18083${1:-/}" || true; }
console_ok() { python3 -I -c 'import socket; s=socket.create_connection(("127.0.0.1",12323),timeout=8); s.settimeout(8); import sys; sys.exit(0 if b"MeshCom Console" in s.recv(128) else 1)' 2>/dev/null; }
monitor() { python3 -I -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.3); s.recv(4096); s.sendall((sys.argv[2]+"\n").encode()); time.sleep(0.5)' "$ROOT/.run/monitor.sock" "$1"; }
waitfor() { local i; for i in $(seq 1 "$2"); do eval "$1" 2>/dev/null && return 0; sleep 1; done; return 1; }

BP=""; TP=""; RP=""; GP=""
start_bridge() {
	"$BRIDGE" --bind 127.0.0.1 --port 7001 --ping-interval-ms 30000 --pong-timeout-ms 90000 --password-file "$XRPW" > "$G/bridge.log" 2>&1 & BP=$!
	python3 -I "$ROOT/tests/xr-tap.py" 7000 7001 "$G/tap.log" & TP=$!
}
start_node() { # start_node NODE_IMAGE [run.sh]
	"${2:-$ROOT/scripts/run.sh}" --env "$ENV" --qemu "$QEMU_BIN" --node-image "$1" > "$G/run.log" 2>&1 & RP=$!
}
start_relay() {
	waitfor '[ -S "$ROOT/.run/gps-uart1.sock" ]' 120
	python3 -I "$ROOT/scripts/gps-relay.py" --mode fixture --fixture "$ROOT/fixtures/gps/valid_fix.nmea" \
		--uart "$ROOT/.run/gps-uart1.sock" --rate 1 --loop > "$G/relay.log" 2>&1 & GP=$!
}
stop_all() {
	[ -n "$GP" ] && kill "$GP" 2>/dev/null; GP=""
	"$ROOT/scripts/stop.sh" > /dev/null 2>&1
	[ -n "$RP" ] && wait "$RP" 2>/dev/null; RP=""
	[ -n "$TP" ] && kill "$TP" 2>/dev/null; [ -n "$BP" ] && kill "$BP" 2>/dev/null; wait 2>/dev/null; TP=""; BP=""
}
trap stop_all EXIT
# ready_with_address FILE: upstream's [BOOT];ready line (printed after setup() called startNetwork()) shows
# the address flag set (ip;1), no "[ETH] init" ran (the stand-in path), and the hand-over reported its
# address with a publish time earlier than that line's.
ready_with_address() { local p r; p=$(grep -aoE 'ethmode: IP .* reported \([0-9]+ ms\)' "$1" | head -1 | grep -oE '[0-9]+ ms' | grep -oE '[0-9]+'); \
	r=$(grep -aoE '\[BOOT\];ready;ms;[0-9]+;ip;1' "$1" | head -1 | cut -d';' -f4); \
	[ -n "$r" ] && ! grep -aq '\[ETH\] init' "$1" && [ -n "$p" ] && [ "$p" -lt "$r" ]; }
# order L1 L2 FILE: line L1 occurs before L2
order() { local a b; a=$(grep -anm1 -- "$1" "$3" | cut -d: -f1); b=$(grep -anm1 -- "$2" "$3" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }

if [[ "$MODES" == *" --main "* ]]; then
	echo "== builds (a)"
	"$ROOT/scripts/apply-overlay.sh" > "$G/apply.log" 2>&1; arc=$?
	gate "a  0 tracked MeshCom changes (apply-overlay rc 0)" '[ "$arc" = 0 ] && [ -z "$(git -C "$FW" status --porcelain --untracked-files=no)" ]'
	for e in qemu-headless qemu-headless-extradio qemu-headless-gpsd "$ENV"; do
		build "$e"; brc=$?; gate "a  $e builds" '[ "$brc" = 0 ]'
	done

	echo "== a fresh node (j, b, c, c-xr, d, f, g, h, i, e, l)"
	NODE="$G/node/node-flash.bin"
	start_bridge; start_node "$NODE"; start_relay
	waitfor 'grep -q "provisioning verified" "$G/run.log"' 900
	gate "j  provisioned and verified (marker written)" '[ -s "$NODE.provisioned" ]'
	B1="$(UARTLOG)"
	gate "b  [BOOT];ready with ip;1, no [ETH] init, address published before it (first boot)" 'ready_with_address "$B1"'
	pre_ap="$(grep -ac 'WIFIAP starting' "$B1")"
	console "--setcall $CALL" 'Call:\S+ Short:\S+ set' > "$G/setcall.txt"
	waitfor 'grep -q "restart #1" "$G/run.log"' 180
	waitfor '[ "$(web)" = 200 ]' 180
	B2="$(UARTLOG)"
	gate "j  --setcall -> one supervised restart, AP flag off, web 200, callsign kept" \
		'grep -q "Call:" "$G/setcall.txt" && [ "$pre_ap" -ge 1 ] && [ "$(grep -ac "WIFIAP starting" "$B2")" = 0 ] && [ "$(web)" = 200 ] && grep -aq "BLE-Name <.*-${CALL%-*}-" "$B2"'
	gate "b  [BOOT];ready with ip;1, no [ETH] init, address published before it (restart)" 'ready_with_address "$B2"'
	gate "c  web 200, console banner and authenticated" '[ "$(web)" = 200 ] && console_ok && grep -aq "Client authenticated" "$B2"'
	sleep 45; cp "$G/tap.log" "$G/tap-control.log"
	console "--sendpos" > /dev/null; sleep 20
	gate "c-xr  CONFIG_RESULT, and a TX_REQUEST with payload0 0x21 after --sendpos" \
		'grep -q "bridge>node CONFIG_RESULT" "$G/tap.log" && [ "$(grep -c "TX_REQUEST.*payload0=0x21" "$G/tap.log")" -gt "$(grep -c "TX_REQUEST.*payload0=0x21" "$G/tap-control.log")" ]'
	gate "c-xr control window: no 0x21 frame before --sendpos" '! grep -q "TX_REQUEST.*payload0=0x21" "$G/tap-control.log"'
	pos="$(console "--pos" 'SAT: [0-9]+ - (?:fix|nofix)')"; sat="$(printf '%s' "$pos" | grep -oE '[0-9]+' | head -1)"
	gate "d  Display not found, UBLOX erkannt, --pos SAT > 0 with a fix, one RESET_REASON per boot" \
		'grep -aq "Display not found" "$B2" && grep -aq "UBLOX erkannt" "$B2" && [ "${sat:-0}" -gt 0 ] && [ "${pos##* }" = fix ] && [ "$(grep -ac "\[BOOT\] RESET_REASON" "$B1")" = 1 ] && [ "$(grep -ac "\[BOOT\] RESET_REASON" "$B2")" = 1 ]'
	code="$(web / 20 "$G/page.html")"
	gate "f  [NET];mtu;eth;1280 and a page > 1280 B ending </html>" \
		'grep -aq "\[NET\];mtu;eth;1280" "$B2" && [ "$code" = 200 ] && [ "$(wc -c < "$G/page.html")" -gt 1280 ] && tail -c 20 "$G/page.html" | grep -q "</html>"'
	info="$(console "--info" '\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)')"
	gate "g  --info: MESH off, EXTUDP off, Gateway off" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'
	t0=$(date +%s); scode="$(web "/?page=spectrum" 60)"; st=$(( $(date +%s) - t0 ))
	gate "h  spectrum page within 60 s, then web 200" '[ "$scode" = 200 ] && [ "$st" -le 60 ] && [ "$(web)" = 200 ]'
	kill "$GP" 2>/dev/null; GP=""
	python3 -I - "$ROOT/.run/gps-uart1.sock" "$ROOT/fixtures/gps/valid_fix.nmea" > "$G/blast.txt" 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(5); data = open(sys.argv[2], "rb").read()
t0 = time.time(); n = 0
while time.time() - t0 < 90:
    try: s.sendall(data); n += len(data)
    except socket.timeout: pass
print("bytes %d secs %.1f" % (n, time.time() - t0))
PY
	BL=$!; iok=0
	for k in 1 2 3 4 5 6 7 8; do sleep 10; [ "$(web / 15)" = 200 ] && console_ok && iok=$((iok+1)); done
	wait "$BL"
	gate "i  UART1 written unpaced for 90 s: web and console answer at all 8 probes" '[ "$iok" = 8 ]'
	console "--reboot" > /dev/null
	waitfor 'grep -q "restart #2" "$G/run.log"' 180
	waitfor '[ "$(web)" = 200 ]' 180
	gate "e  --reboot -> guest reset -> restart #2, web 200" 'grep -q "guest reset after .* restart #2" "$G/run.log" && [ "$(web)" = 200 ]'
	B3="$(UARTLOG)"; waitfor 'grep -aq "ethmode: IP .* reported" "$B3"' 120
	monitor "set_link net0 off"; t0=$(date +%s)
	waitfor 'grep -aq "readiness withdrawn" "$B3"' 10; wt=$(( $(date +%s) - t0 ))
	down_web="$(web / 5)"
	gate "l  set_link off: readiness withdrawn within 10 s, web from the host fails" 'grep -aq "readiness withdrawn" "$B3" && [ "$wt" -le 10 ] && [ "$down_web" != 200 ]'
	n0="$(grep -ac 'ethmode: IP .* reported' "$B3")"
	monitor "set_link net0 on"
	waitfor '[ "$(grep -ac "ethmode: IP .* reported" "$B3")" -gt "$n0" ] && [ "$(web)" = 200 ]' 30
	gate "l  set_link on: reported again and web 200 within 30 s" '[ "$(grep -ac "ethmode: IP .* reported" "$B3")" -gt "$n0" ] && [ "$(web)" = 200 ]'
	cp "$B1" "$G/boot1.log"; cp "$B2" "$G/boot2.log"; cp "$B3" "$G/boot3.log"
	stop_all
fi

if [[ "$MODES" == *" --controls "* ]]; then
	echo "== failing controls"
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	# a: an old patch hunk re-applied (hunk 14 of the former overlay patch, src/loop_functions.cpp)
	git -C "$ROOT" show c2335d12:overlay/patches/meshcom-qemu-headless.patch > "$G/old.patch" 2>/dev/null
	git -C "$FW" apply --include=src/loop_functions.cpp "$G/old.patch" 2>/dev/null
	"$ROOT/scripts/apply-overlay.sh" > "$G/apply-c.log" 2>&1; arc=$?
	control "a  (a re-applied hunk)" '[ "$arc" = 0 ]'
	git -C "$FW" checkout -q -- .
	# b: a build without the hand-over (initVariant and the task; only `neth` kept): the provisioning boot
	# panics in the Wi-Fi PHY -> no marker
	printf '#include <configuration.h>\n#include "esp32/esp32_eth.h"\nEspETH neth;\n' > "$FW/src/qemu/qemu_ethmode.cpp"
	build "$ENV"; cbrc=$?
	NODE="$G/node-cb/node-flash.bin"; brc=x
	if [ "$cbrc" = 0 ]; then
		PROVISION_TIMEOUT=300 start_node "$NODE"
		waitfor '! kill -0 "$RP" 2>/dev/null' 600; wait "$RP"; brc=$?; RP=""
	fi
	control "b  (no hand-over; build rc $cbrc, run.sh rc $brc)" '[ "$cbrc" != 0 ] || [ -s "$NODE.provisioned" ]'
	"$ROOT/scripts/apply-overlay.sh" > /dev/null; build "$ENV"
	# d, e, f, g, c on copies of the provisioned node, changed at run time over the console
	PROV="$G/node/node-flash.bin"; NODE=""
	copy_node() { mkdir -p "$G/$1"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/$1/"; echo "$G/$1/node-flash.bin"; }
	[ -s "$PROV.provisioned" ] && NODE="$(copy_node node-c1)" || echo "SKIP  d/e/f/g/c controls: run --main first"
	if [ -n "$NODE" ]; then
		start_bridge; start_node "$NODE"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
		console "--mesh on" > /dev/null; sleep 3
		info="$(console "--info" '\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)')"
		control "g  (--mesh on)" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'
		console "--mesh off" > /dev/null
		pos="$(console "--pos" 'SAT: [0-9]+ - (?:fix|nofix)')"; sat="$(printf '%s' "$pos" | grep -oE '[0-9]+' | head -1)"
		control "d  (relay off: --pos)" '[ "${sat:-0}" -gt 0 ] && [ "${pos##* }" = fix ]'
		console "--mtu 1500" > /dev/null; console "--reboot" > /dev/null
		waitfor 'grep -q "restart #1" "$G/run.log"' 180; waitfor '[ "$(web)" = 200 ]' 180
		control "f  (--mtu 1500)" 'grep -aq "\[NET\];mtu;eth;1280" "$(UARTLOG)"'
		stop_all
		# e: run.sh without -no-reboot: no restart line after --reboot
		sed '/-no-reboot/d' "$ROOT/scripts/run.sh" > "$ROOT/scripts/.run-noreboot.sh"; chmod +x "$ROOT/scripts/.run-noreboot.sh"
		start_node "$NODE" "$ROOT/scripts/.run-noreboot.sh"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
		console "--reboot" > /dev/null; sleep 60
		control "e  (no -no-reboot)" 'grep -q "restart #1" "$G/run.log"'
		stop_all; rm -f "$ROOT/scripts/.run-noreboot.sh"
		# c: the console switched off
		NODE="$(copy_node node-c2)"; start_node "$NODE"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
		console "--netconsole off" > /dev/null; sleep 3
		control "c  (--netconsole off)" 'console_ok'
		stop_all
	fi
fi

if [[ "$MODES" == *" --slow-"* ]]; then
	echo "== slow cases (test builds)"
	PROV="$G/node/node-flash.bin"
	[ -s "$PROV.provisioned" ] || { echo "SKIP  slow cases: run --main first (they need a provisioned node)"; exit 1; }
fi
if [[ "$MODES" == *" --slow-b "* ]]; then
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	# b': a flag clear in Ethernet mode reaches upstream's initethDHCP() (the loop's 5-minute path)
	build "$ENV" "-DQEMU_TEST_CLEAR_FLAG_MS=8000"
	mkdir -p "$G/node-b2"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-b2/" 2>/dev/null
	start_node "$G/node-b2/node-flash.bin"; waitfor '[ "$(web)" = 200 ]' 300
	waitfor 'grep -aq "\[ETH\] DHCP IP" "$(UARTLOG)"' 400
	gate "b' a flag clear -> [ETH] DHCP IP via the stand-in, web 200" 'grep -aq "TEST: node_hasIPaddress cleared" "$(UARTLOG)" && grep -aq "\[ETH\] DHCP IP" "$(UARTLOG)" && [ "$(web)" = 200 ]'
	stop_all
	# b' control: without the stand-in headers the build fails
	mv "$FW/variants/qemu-headless/ETHClass2.h" "$G/"; build "$ENV"; src=$?
	mv "$G/ETHClass2.h" "$FW/variants/qemu-headless/"
	control "b' (no ETHClass2.h stand-in)" '[ "$src" = 0 ]'
fi
if [[ "$MODES" == *" --slow-k "* ]]; then
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	# k: OpenETH never starts, a node with saved settings: readiness withdrawn, nothing reachable
	build "$ENV" "-DQEMU_TEST_NO_OPENETH"
	mkdir -p "$G/node-k"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-k/" 2>/dev/null
	start_node "$G/node-k/node-flash.bin"; sleep 20
	K="$(UARTLOG)"; kreach=0
	for k in $(seq 1 14); do [ "$(web / 5)" = 200 ] && kreach=1; console_ok && kreach=1; sleep 25; done
	# Upstream retries initethDHCP() only while node_hasIPaddress is false (startNetwork(), the loop's
	# 5-minute path), so a second "[ETH] DHCP failed" proves the first fallback's `true` did not stand.
	# (Measured: upstream's ntpHarvestUDP() mirrors hasIPaddress into the flag within a loop pass, before the
	# hand-over task's own withdrawal; that withdrawal is exercised by gate l.)
	gate "k  no OpenETH: the fallback's readiness never stands (>= 2 DHCP-failed retries), no panic" \
		'[ "$(grep -ac "DHCP failed" "$K")" -ge 2 ] && ! grep -aqE "Guru Meditation|assert failed" "$K"'
	gate "k  no OpenETH: web and console unreachable from the host throughout" '[ "$kreach" = 0 ]'
	cp "$K" "$G/boot-k.log"; stop_all
fi
if [[ "$MODES" == *" --slow-k2 "* ]]; then
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	build "$ENV" "-DQEMU_TEST_NO_OPENETH"
	mkdir -p "$G/node-k"; cp "$PROV" "$PROV.efuse" "$G/node-k/" 2>/dev/null
	rm -f "$G/node-k/node-flash.bin.provisioned"; PROVISION_TIMEOUT=120 start_node "$G/node-k/node-flash.bin"
	waitfor '! kill -0 "$RP" 2>/dev/null' 600; wait "$RP"; krc=$?; RP=""
	gate "k  a fresh node in this build -> provisioning rc 3, no marker" '[ "$krc" = 3 ] && [ ! -e "$G/node-k/node-flash.bin.provisioned" ]'
fi
if [[ "$MODES" == *" --slow-l "* ]]; then
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	# l control: the old qemu_network.cpp (link loss kept readiness)
	git -C "$ROOT" show c2335d12:overlay/src/qemu/qemu_network.cpp > "$FW/src/qemu/qemu_network.cpp"; build "$ENV"
	mkdir -p "$G/node-l"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-l/" 2>/dev/null
	start_node "$G/node-l/node-flash.bin"; waitfor '[ "$(web)" = 200 ]' 300
	L="$(UARTLOG)"; monitor "set_link net0 off"; sleep 12
	control "l  (old qemu_network.cpp)" 'grep -aq "readiness withdrawn" "$L"'
	monitor "set_link net0 on"; stop_all
fi

echo "---"
[ "$FAILS" = 0 ] && { echo "ALL GATES AS EXPECTED"; exit 0; } || { echo "FAILURES: $FAILS"; exit 1; }
