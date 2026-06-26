#!/usr/bin/env bash
#
# test-gps.sh — automated QEMU GPS fixture suite for the …-gpsd profiles.
#
# Boots the GPS-enabled QEMU target, feeds the synthetic NMEA fixtures into the
# guest's virtual UART1 via scripts/gps-relay.py (fixture mode — NO gpsd, NO real
# receiver), and asserts the firmware's GPS state from the transition-only
# [GPSTEST] markers in the UART log (status only; never coordinates).
#
# It manages the QEMU lifecycle itself (run.sh in the background, stop.sh on exit)
# and reuses test.sh idioms (uart-latest.log anchor, 30x2s web readiness poll).
# It requires a built image: scripts/build.sh --env <env> first.
#
# Fixture order matters and is deliberate: a relay streams NMEA from boot so the
# firmware's one-shot GPS init detects a live stream (gpsDetected). The NEGATIVE
# fixtures run first (no prior valid fix can leak into them via TinyGPSPlus state),
# then valid -> stale -> short-track.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/.run"
UART="$RUN/uart-latest.log"
SOCK="$RUN/gps-uart1.sock"
WEB="http://127.0.0.1:18083/"
RELAY="$ROOT/scripts/gps-relay.py"
FIX="$ROOT/fixtures/gps"
ENV_NAME="qemu-headless-gpsd"
RATE=5

while [ $# -gt 0 ]; do
	case "$1" in
		--env) ENV_NAME="${2:?--env needs a value}"; shift 2 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done
case "$ENV_NAME" in *gpsd) ;; *) echo "ERROR: --env must be a …-gpsd profile (got '$ENV_NAME')." >&2; exit 2 ;; esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'." >&2; exit 1; }; }
need python3; need curl
FLASH="$ROOT/.work/MeshCom-Firmware/.pio/build/$ENV_NAME/flash.bin"
[ -f "$FLASH" ] || { echo "ERROR: $FLASH not found. Build first: scripts/build.sh --env $ENV_NAME" >&2; exit 1; }

RELAY_PID=""
kill_relay() { [ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null || true; RELAY_PID=""; }
cleanup() { kill_relay; bash "$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

start_relay() { # $1=fixture
	kill_relay
	python3 "$RELAY" --mode fixture --fixture "$FIX/$1" --uart "$SOCK" --rate "$RATE" --loop \
		>"$RUN/gps-relay-$1.log" 2>&1 &
	RELAY_PID=$!
}

offset() { [ -f "$UART" ] && wc -c <"$UART" || echo 0; }
slice()  { tail -c "+$(( ${1:-0} + 1 ))" "$UART" 2>/dev/null || true; }
crash_count() { grep -ciE 'Guru Meditation|abort\(\)|rst:0x|CPU_RESET' "$UART" 2>/dev/null || echo 0; }

FAILS=0
ok()   { echo "[test-gps] PASS: $1"; }
bad()  { echo "[test-gps] FAIL: $1"; FAILS=$((FAILS+1)); }

# --- boot QEMU with UART1 socket, start the negative fixture from boot ---
echo "[test-gps] booting $ENV_NAME …"
bash "$ROOT/scripts/run.sh" --env "$ENV_NAME" >/dev/null 2>&1 &
start_relay no_fix.nmea     # stream from boot so the one-shot GPS init sees a live stream

echo "[test-gps] waiting for web UI readiness …"
ready=0
for _ in $(seq 1 30); do
	[ "$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' "$WEB" 2>/dev/null || echo 000)" = "200" ] && { ready=1; break; }
	sleep 2
done
[ "$ready" = "1" ] || { echo "[test-gps] FAIL: web UI not reachable"; exit 1; }
base_crash="$(crash_count)"
grep -q 'QEMU virtual GPS on UART1' "$UART" && ok "GPS source initialized on UART1" || bad "GPS init marker not seen"
grep -q 'QEMU NMEA presence:.*detected' "$UART" && ok "live NMEA detected (gpsDetected)" || bad "gpsDetected not established (relay/boot timing?)"

# --- 1) no-fix: must NEVER reach a usable fix ---
o="$(offset)"; sleep 8
slice "$o" | grep -q '\[GPSTEST\] fix=1' && bad "no_fix produced a fix" || ok "no_fix never reached fix"

# --- 2) malformed/bad-checksum: no crash, no false fix ---
o="$(offset)"; start_relay bad_checksum.nmea; sleep 8
slice "$o" | grep -q '\[GPSTEST\] fix=1' && bad "bad_checksum produced a fix" || ok "bad_checksum never reached fix"
[ "$(crash_count)" = "$base_crash" ] && ok "bad_checksum: no crash/reset" || bad "crash/reset markers appeared"

# --- 3) valid fixed position: must reach a usable fix with the expected quality ---
o="$(offset)"; start_relay valid_fix.nmea; sleep 10
if slice "$o" | grep -q '\[GPSTEST\] fix=1 sats=7 hdop=1.2'; then ok "valid_fix reached fix (sats=7 hdop=1.2)"
else bad "valid_fix did not reach expected fix"; slice "$o" | grep '\[GPSTEST\]' | tail -3; fi

# --- 4) stale: stop feeding; usable fix must age out (live age >= 5s) ---
o="$(offset)"; kill_relay; sleep 9
slice "$o" | grep -q '\[GPSTEST\] fix=0' && ok "stale input aged out (fix=0)" || bad "stale fix did not age out"

# --- 5) short track: fix re-established AND position updates (>=2 distinct points) ---
o="$(offset)"; start_relay short_track.nmea; sleep 12
slice "$o" | grep -q '\[GPSTEST\] fix=1' && ok "short_track re-reached fix" || bad "short_track did not reach fix"
moves="$(slice "$o" | grep -c '\[GPSTEST\] moved' || true)"
[ "${moves:-0}" -ge 2 ] && ok "short_track updated position ($moves distinct points)" || bad "short_track did not update position (moves=$moves)"

# --- guest health: web still serving, no crash across the whole run ---
[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$WEB" 2>/dev/null || echo 000)" = "200" ] && ok "web UI still reachable" || bad "web UI not reachable at end"
[ "$(crash_count)" = "$base_crash" ] && ok "no panic/reset/reboot across run" || bad "panic/reset markers across run"

echo "[test-gps] ---------------------------------------------"
if [ "$FAILS" = "0" ]; then echo "[test-gps] ALL PASS"; else echo "[test-gps] $FAILS check(s) FAILED"; exit 1; fi
