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
#   --self-test the shared predicates on fixed inputs only (seconds; no QEMU, BRIDGE or QEMU_BIN needed)
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
PIO="${PIO:-pio}"
G="$ROOT/.run/gates"
PROV="$G/node/node-flash.bin"          # the node --main provisions; --controls and --slow copy it
FAILS=0
pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
gate() { if eval "$2" 2>/dev/null; then pass "$1"; else fail "$1"; fi; }
# setup NAME CHECK: a control's preparation; when it does not hold, that is a FAIL and the control is not
# judged (a control must never pass because its fixture failed). Returns CHECK's result.
setup() { if eval "$2" 2>/dev/null; then return 0; fi; fail "setup $1"; return 1; }
# expect_fail: a control passes when the gate's assertion is FALSE on it.
control() { if eval "$2" 2>/dev/null; then fail "control $1 (the assertion still held)"; else pass "control $1 (the assertion failed, as it must)"; fi; }
# sat_reply POS: POS is the console's complete --pos answer (one or more "SAT: n - fix|nofix"), never a
# failed read ("console-error <type>") or a partial line.
sat_reply() { [[ "$1" =~ ^SAT:\ [0-9]+\ -\ (fix|nofix)(\ \|\ SAT:\ [0-9]+\ -\ (fix|nofix))*$ ]]; }
# within LIMIT RC SECS: a waitfor that succeeded (RC 0) within LIMIT measured seconds. waitfor counts
# attempts, and one attempt can take longer than a second, so its own bound is not a time.
within() { [ "$2" = 0 ] && [ "$3" -le "$1" ]; }
# prov_copy NAME: copy the node --main provisioned into $G/NAME and print its image path; fails when
# there is no provisioned node or the copy fails.
prov_copy() { [ -s "$PROV.provisioned" ] && mkdir -p "$G/$1" && cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/$1/" \
	&& echo "$G/$1/node-flash.bin"; }
# --self-test: the predicates above on fixed inputs (failed reads, a late recovery, a missing node); no QEMU.
if [ "${1:-}" = --self-test ]; then
	gate "sat_reply: one SAT line" 'sat_reply "SAT: 7 - fix"'
	gate "sat_reply: no fix" 'sat_reply "SAT: 0 - nofix"'
	gate "sat_reply: two SAT lines" 'sat_reply "SAT: 7 - fix | SAT: 8 - fix"'
	gate "sat_reply rejects an empty read" '! sat_reply ""'
	gate "sat_reply rejects a refused connection" '! sat_reply "console-error ConnectionRefusedError"'
	gate "sat_reply rejects a timeout" '! sat_reply "console-error timeout"'
	gate "sat_reply rejects a partial line" '! sat_reply "SAT: 7"'
	gate "within: 60 s of 60" 'within 60 0 60'
	gate "within rejects a recovery after 77 s" '! within 60 0 77'
	gate "within rejects a waitfor that gave up" '! within 60 1 30'
	G="$(mktemp -d)"; PROV="$G/node/node-flash.bin"
	gate "prov_copy fails without a provisioned node" '! prov_copy x > /dev/null'
	mkdir -p "$G/node"; echo f > "$PROV"; echo e > "$PROV.efuse"; echo m > "$PROV.provisioned"
	gate "prov_copy copies the provisioned node" '[ "$(prov_copy y)" = "$G/y/node-flash.bin" ] && [ -s "$G/y/node-flash.bin.provisioned" ]'
	rm -rf "$G"
	echo "---"; [ "$FAILS" = 0 ] && { echo "SELF-TEST OK"; exit 0; } || { echo "FAILURES: $FAILS"; exit 1; }
fi
: "${BRIDGE:?BRIDGE=<meshcom-loraham-bridge>}" "${QEMU_BIN:?QEMU_BIN=<qemu-system-xtensa>}"
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

# uart_load SOCK: write the NMEA fixture to SOCK unpaced for 90 s while 8 probes (web 200 + console banner)
# run. Sets bl_rc (the writer's exit), bl_bytes (bytes written), inload (1 = the writer still ran after the
# last probe, so every probe fell inside the load) and iok (probes answered). uart_load_held is gate i.
uart_load() {
	python3 -I - "$1" "$ROOT/fixtures/gps/valid_fix.nmea" > "$G/blast.txt" 2>&1 <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(5); data = open(sys.argv[2], "rb").read()
t0 = time.time(); n = 0
while time.time() - t0 < 90:
    try: s.sendall(data); n += len(data)
    except socket.timeout: pass
print("bytes %d secs %.1f" % (n, time.time() - t0))
PY
	local bl=$! k; iok=0; inload=0
	for k in 1 2 3 4 5 6 7 8; do sleep 8; [ "$(web / 15)" = 200 ] && console_ok && iok=$((iok+1)); done
	kill -0 "$bl" 2>/dev/null && inload=1
	bl_rc=0; wait "$bl" || bl_rc=$?
	bl_bytes="$(grep -oE '^bytes [0-9]+' "$G/blast.txt" | grep -oE '[0-9]+' || echo 0)"
}
uart_load_held() { [ "$bl_rc" = 0 ] && [ "${bl_bytes:-0}" -gt 0 ] && [ "$inload" = 1 ] && [ "$iok" = 8 ]; }

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
	waitfor 'grep -aq "ethmode: IP .* reported" "$B1"' 60      # the line is written from 5 s of uptime on
	gate "b  [BOOT];ready with ip;1, no [ETH] init, address published before it (first boot)" 'ready_with_address "$B1"'
	pre_ap="$(grep -ac 'WIFIAP starting' "$B1")"
	console "--setcall $CALL" 'Call:\S+ Short:\S+ set' > "$G/setcall.txt"
	waitfor 'grep -q "restart #1" "$G/run.log"' 180
	waitfor '[ "$(web)" = 200 ]' 180; jweb=$?          # the emulated web server is slow: one 200 counts
	B2="$(UARTLOG)"
	gate "j  --setcall -> one supervised restart, AP flag off, web 200, callsign kept" \
		'grep -q "Call:" "$G/setcall.txt" && [ "$pre_ap" -ge 1 ] && [ "$(grep -ac "WIFIAP starting" "$B2")" = 0 ] && [ "$jweb" = 0 ] && grep -aq "BLE-Name <.*-${CALL%-*}-" "$B2"'
	waitfor 'grep -aq "ethmode: IP .* reported" "$B2"' 60
	gate "b  [BOOT];ready with ip;1, no [ETH] init, address published before it (restart)" 'ready_with_address "$B2"'
	waitfor '[ "$(web)" = 200 ]' 30; cweb=$?
	gate "c  web 200, console banner and authenticated" '[ "$cweb" = 0 ] && console_ok && grep -aq "Client authenticated" "$B2"'
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
	waitfor '[ "$(web)" = 200 ]' 30; hweb=$?
	gate "h  spectrum page within 60 s, then web 200" '[ "$scode" = 200 ] && [ "$st" -le 60 ] && [ "$hweb" = 0 ]'
	kill "$GP" 2>/dev/null; GP=""
	uart_load "$ROOT/.run/gps-uart1.sock"
	gate "i  UART1 written unpaced for 90 s (writer rc $bl_rc, $bl_bytes B): web and console answer at all 8 probes, all inside the load" \
		'uart_load_held'
	console "--reboot" > /dev/null
	waitfor 'grep -q "restart #2" "$G/run.log"' 180
	waitfor '[ "$(web)" = 200 ]' 180; eweb=$?
	gate "e  --reboot -> guest reset -> restart #2, web 200" 'grep -q "guest reset after .* restart #2" "$G/run.log" && [ "$eweb" = 0 ]'
	B3="$(UARTLOG)"; waitfor 'grep -aq "ethmode: IP .* reported" "$B3"' 120
	monitor "set_link net0 off"; t0=$(date +%s)
	waitfor 'grep -aq "readiness withdrawn" "$B3"' 10; wt=$(( $(date +%s) - t0 ))
	down_web="$(web / 5)"
	gate "l  set_link off: readiness withdrawn within 10 s, web from the host fails" 'grep -aq "readiness withdrawn" "$B3" && [ "$wt" -le 10 ] && [ "$down_web" != 200 ]'
	n0="$(grep -ac 'ethmode: IP .* reported' "$B3")"
	monitor "set_link net0 on"; t0=$(date +%s)
	waitfor '[ "$(grep -ac "ethmode: IP .* reported" "$B3")" -gt "$n0" ]' 30; rt=$(( $(date +%s) - t0 ))
	gate "l  set_link on: the address reported again within 30 s (${rt} s)" '[ "$(grep -ac "ethmode: IP .* reported" "$B3")" -gt "$n0" ] && [ "$rt" -le 30 ]'
	t0=$(date +%s); waitfor '[ "$(web / 5)" = 200 ]' 60; lweb=$?; wt2=$(( $(date +%s) - t0 ))
	gate "l  ... and the web page answers 200 again within 60 s (${wt2} s after the report)" 'within 60 "$lweb" "$wt2"'
	cp "$B1" "$G/boot1.log"; cp "$B2" "$G/boot2.log"; cp "$B3" "$G/boot3.log"
	stop_all
fi

if [[ "$MODES" == *" --controls "* ]]; then
	echo "== failing controls"
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	# a: an old patch hunk re-applied (hunk 14 of the former overlay patch, src/loop_functions.cpp)
	if setup "a: the old patch extracted from history (c2335d12) and its hunk applied" \
		'git -C "$ROOT" show c2335d12:overlay/patches/meshcom-qemu-headless.patch > "$G/old.patch" && git -C "$FW" apply --include=src/loop_functions.cpp "$G/old.patch"'; then
		"$ROOT/scripts/apply-overlay.sh" > "$G/apply-c.log" 2>&1; arc=$?
		control "a  (a re-applied hunk)" '[ "$arc" = 0 ]'
	fi
	git -C "$FW" checkout -q -- .
	# b: a build without the hand-over (initVariant and the task; only `neth` kept): the provisioning boot
	# panics in the Wi-Fi PHY -> no marker
	printf '#include <configuration.h>\n#include "esp32/esp32_eth.h"\nEspETH neth;\n' > "$FW/src/qemu/qemu_ethmode.cpp"
	build "$ENV"; cbrc=$?
	NODE="$G/node-cb/node-flash.bin"; brc=x
	if setup "b: the build without the hand-over (rc $cbrc)" '[ "$cbrc" = 0 ]'; then
		PROVISION_TIMEOUT=300 start_node "$NODE"
		waitfor '! kill -0 "$RP" 2>/dev/null' 600; wait "$RP"; brc=$?; RP=""
		setup "b: run.sh ended in a provisioning failure (rc $brc, want 3)" '[ "$brc" = 3 ]' \
			&& control "b  (no hand-over; run.sh rc $brc)" '[ -s "$NODE.provisioned" ]'
	fi
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	setup "the normal build again" 'build "$ENV"' || { echo "---"; echo "FAILURES: $FAILS"; exit 1; }
	# d, e, f, g, c on copies of the provisioned node, changed at run time over the console
	if setup "d/e/f/g: a copy of the node --main provisioned" 'NODE="$(prov_copy node-c1)"'; then
		start_bridge; start_node "$NODE"
		if setup "the controls' node answers (web 200, console banner)" 'waitfor '"'"'[ "$(web)" = 200 ] && console_ok'"'"' 300'; then
			ire='\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)'
			info="$(console "--info" "$ire")"
			if setup "g: the baseline --info reads MESH off, EXTUDP off, Gateway off" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'; then
				console "--mesh on" > /dev/null; sleep 3
				info="$(console "--info" "$ire")"
				setup "g: --info now reads MESH on ($info)" 'printf "%s" "$info" | grep -qF "...MESH on"' \
					&& control "g  (--mesh on)" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'
				console "--mesh off" > /dev/null
			fi
			pos="$(console "--pos" 'SAT: [0-9]+ - (?:fix|nofix)')"; sat="$(printf '%s' "$pos" | grep -oE '[0-9]+' | head -1)"
			setup "d: --pos answered with a complete SAT reply ($pos)" 'sat_reply "$pos"' \
				&& control "d  (relay off: --pos)" '[ "${sat:-0}" -gt 0 ] && [ "${pos##* }" = fix ]'
			console "--mtu 1500" > /dev/null; console "--reboot" > /dev/null
			if setup "f: --reboot -> restart #1 and web 200" 'waitfor '"'"'grep -q "restart #1" "$G/run.log"'"'"' 180 && waitfor '"'"'[ "$(web)" = 200 ]'"'"' 180'; then
				# upstream prints [NET];mtu only when it changes the netif's MTU, and lwIP's default is 1500,
				# so the altered state is read from --info
				mtu="$(console "--info" 'MTU\s*:\s*[0-9]+')"
				setup "f: --info after the restart reads MTU 1500 ($mtu)" 'printf "%s" "$mtu" | grep -qE ":\s*1500$"' \
					&& control "f  (--mtu 1500)" 'grep -aq "\[NET\];mtu;eth;1280" "$(UARTLOG)"'
			fi
		fi
		stop_all
		# e: run.sh without -no-reboot: no restart line after --reboot
		sed '/-no-reboot/d' "$ROOT/scripts/run.sh" > "$ROOT/scripts/.run-noreboot.sh"; chmod +x "$ROOT/scripts/.run-noreboot.sh"
		start_node "$NODE" "$ROOT/scripts/.run-noreboot.sh"
		if setup "e: the node without -no-reboot answers" 'waitfor '"'"'[ "$(web)" = 200 ] && console_ok'"'"' 300'; then
			console "--reboot" > /dev/null; sleep 60
			# Without -no-reboot the reset stays inside QEMU and wedges in the ROM: its ROM line is the evidence
			# that --reboot reached the guest (upstream's [BOOT] RESET_REASON line never comes after it).
			setup "e: the copy has no -no-reboot, the runner still runs, the guest reset (rst:0xc in its UART log)" \
				'! grep -q -- -no-reboot "$ROOT/scripts/.run-noreboot.sh" && kill -0 "$RP" && grep -aq "rst:0xc (SW_CPU_RESET)" "$(UARTLOG)"' \
				&& control "e  (no -no-reboot)" 'grep -q "restart #1" "$G/run.log"'
		fi
		stop_all; rm -f "$ROOT/scripts/.run-noreboot.sh"
		# i: the writer fails (no such socket): gate i must not hold on an idle guest
		if setup "i: a copy of the provisioned node" 'NODE="$(prov_copy node-c3)"'; then
			start_node "$NODE"
			if setup "i: the node answers (web 200, console banner)" 'waitfor '"'"'[ "$(web)" = 200 ] && console_ok'"'"' 300'; then
				uart_load "$G/no-such.sock"
				setup "i: the writer failed (rc $bl_rc)" '[ "$bl_rc" != 0 ]' && control "i  (a failed writer)" 'uart_load_held'
			fi
			stop_all
		fi
		# c: the console switched off
		if setup "c: a copy of the provisioned node" 'NODE="$(prov_copy node-c2)"'; then
			start_node "$NODE"
			if setup "c: the node answers (web 200, console banner)" 'waitfor '"'"'[ "$(web)" = 200 ] && console_ok'"'"' 300'; then
				console "--netconsole off" > /dev/null; sleep 3
				setup "c: the guest still serves its web page (only the console is off)" 'waitfor '"'"'[ "$(web)" = 200 ]'"'"' 60' \
					&& control "c  (--netconsole off)" 'console_ok'
			fi
			stop_all
		fi
	fi
fi

if [[ "$MODES" == *" --slow-"* ]]; then
	echo "== slow cases (test builds)"
	setup "slow cases: the node --main provisioned" '[ -s "$PROV.provisioned" ]' || { echo "---"; echo "FAILURES: $FAILS"; exit 1; }
fi
if [[ "$MODES" == *" --slow-b "* ]]; then
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	# b': a flag clear in Ethernet mode reaches upstream's initethDHCP() (the loop's 5-minute path)
	setup "b': the test build" 'build "$ENV" "-DQEMU_TEST_CLEAR_FLAG_MS=8000"'
	setup "b': a copy of the provisioned node" 'prov_copy node-b2 > /dev/null'
	start_node "$G/node-b2/node-flash.bin"; setup "b': the node answers" 'waitfor '"'"'[ "$(web)" = 200 ]'"'"' 300'
	waitfor 'grep -aq "\[ETH\] DHCP IP" "$(UARTLOG)"' 400
	waitfor '[ "$(web)" = 200 ]' 30; bweb=$?
	gate "b' a flag clear -> [ETH] DHCP IP via the stand-in, web 200" 'grep -aq "TEST: node_hasIPaddress cleared" "$(UARTLOG)" && grep -aq "\[ETH\] DHCP IP" "$(UARTLOG)" && [ "$bweb" = 0 ]'
	stop_all
	# b' control: without the stand-in headers the build fails
	mv "$FW/variants/qemu-headless/ETHClass2.h" "$G/"; build "$ENV"; src=$?
	mv "$G/ETHClass2.h" "$FW/variants/qemu-headless/"
	setup "b': the build log names the missing ETHClass2.h" '[ "$src" = 0 ] || grep -q "ETHClass2.h" "$G/build-$ENV.log"' \
		&& control "b' (no ETHClass2.h stand-in)" '[ "$src" = 0 ]'
fi
if [[ "$MODES" == *" --slow-k "* ]]; then
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	# k: OpenETH never starts, a node with saved settings: readiness withdrawn, nothing reachable
	setup "k: the test build" 'build "$ENV" "-DQEMU_TEST_NO_OPENETH"'
	setup "k: a copy of the provisioned node" 'prov_copy node-k > /dev/null'
	start_node "$G/node-k/node-flash.bin"; sleep 20
	setup "k: the runner runs the node" 'kill -0 "$RP"'
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
	setup "k2: the test build" 'build "$ENV" "-DQEMU_TEST_NO_OPENETH"'
	# A fresh node: no image yet, so node-image.sh creates it from this build (the stock defaults).
	rm -rf "$G/node-k2"; PROVISION_TIMEOUT=120 start_node "$G/node-k2/node-flash.bin"
	waitfor '! kill -0 "$RP" 2>/dev/null' 600; wait "$RP"; krc=$?; RP=""
	# rc 3 alone also comes from a guest that never booted: the firmware's own boot line must be in the
	# provisioning UART log that run.sh's failure line names.
	klog="$(sed -n 's/.*provisioning FAILED: .* (log: \(.*\))$/\1/p' "$G/run.log" | tail -1)"
	setup "k2: the guest booted the firmware ([BOOT] RESET_REASON in ${klog:-no provisioning log named})" \
		'[ -n "$klog" ] && grep -aq "\[BOOT\] RESET_REASON" "$klog"' \
		&& gate "k  a fresh node (image created from this build) -> provisioning rc 3, no marker" \
			'grep -q "node image: created from the build" "$G/run.log" && [ "$krc" = 3 ] && [ ! -e "$G/node-k2/node-flash.bin.provisioned" ]'
fi
if [[ "$MODES" == *" --slow-l "* ]]; then
	"$ROOT/scripts/apply-overlay.sh" > /dev/null
	# l control: the old qemu_network.cpp (link loss kept readiness)
	if setup "l: the old qemu_network.cpp extracted from history (c2335d12) and built" \
		'git -C "$ROOT" show c2335d12:overlay/src/qemu/qemu_network.cpp > "$FW/src/qemu/qemu_network.cpp" && build "$ENV"'; then
		if setup "l: a copy of the provisioned node" 'prov_copy node-l > /dev/null' \
			&& start_node "$G/node-l/node-flash.bin" && setup "l: the node answers" 'waitfor '"'"'[ "$(web)" = 200 ]'"'"' 300'; then
			L="$(UARTLOG)"; monitor "set_link net0 off"; sleep 12
			setup "l: the link is down (web from the host fails)" '[ "$(web / 5)" != 200 ]' \
				&& control "l  (old qemu_network.cpp)" 'grep -aq "readiness withdrawn" "$L"'
			monitor "set_link net0 on"
		fi
		stop_all
	fi
fi

echo "---"
[ "$FAILS" = 0 ] && { echo "ALL GATES AS EXPECTED"; exit 0; } || { echo "FAILURES: $FAILS"; exit 1; }
