#!/usr/bin/env bash
#
# test.sh — verify the MeshCom QEMU guest actually BOOTS (firmware reaches its
# "client started" / net-console-up marker in the UART log). SELF-SUFFICIENT:
# when no guest is running it boots the newest built flash.bin env via run.sh and
# stops exactly that instance afterwards — so it runs standalone, e.g. from lhpc's
# install-all test phase right after the build. A guest that was already running is
# probed and never stopped.
#
# PASS = the firmware boots (a FRESH boot marker in THIS run's UART log). The web UI
# (:18083) and net-console (:12323) are read as DIAGNOSTICS only — the emulated
# MeshCom web server is heap-starved/sluggish and a slow/unreachable web read must
# NOT fail the node (RX/TX are independent of the web UI). Readiness keys off the
# recorded run state (.run/qemu.pid + the .run/uart-latest.log symlink target) so a
# stale older UART log can never produce a false pass.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/.run"
mkdir -p "$RUN"          # own the runtime dir — the self-boot redirect (> $RUN/test-boot.log)
                        # must not depend on setup.sh/run.sh having created it (fresh-clone safe)
UART="$RUN/uart-latest.log"
PIDFILE="$RUN/qemu.pid"
WEB="http://127.0.0.1:18083/"
CON_PORT=12323
# Firmware boot-complete markers (present on every boot, independent of the web UI
# and of whether the bridge is up).
MARKER='CLIENT STARTED|Console started on port 2323'

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'." >&2; exit 1; }; }
need curl "sudo apt-get install -y curl"
need python3 "sudo apt-get install -y python3"

pid_alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null || echo 0)" 2>/dev/null; }
uart_target() { local t; t="$(readlink "$UART" 2>/dev/null || echo "")"; [ -n "$t" ] && echo "$RUN/$t" || echo "$UART"; }

# --- Establish which guest we test, and its THIS-run UART log --------------------------------
BOOT_LOG=""
self_booted=0
if pid_alive; then
	echo "[test] guest already running (pid $(cat "$PIDFILE")) — probing it, leaving it alone"
	BOOT_LOG="$(uart_target)"
else
	# Self-host: boot the newest BUILT env. run.sh repoints uart-latest.log to a FRESH
	# uart-<stamp>.log and records the pid; require the marker in THAT fresh file so an old
	# UART log can't yield a false pass. stop.sh (exact recorded pid) tears down only ours.
	FLASH="$(ls -t "$ROOT"/.work/MeshCom-Firmware/.pio/build/*/flash.bin 2>/dev/null | head -1)"
	[ -n "$FLASH" ] || { echo "[test] FAIL: no guest running and no built flash.bin (run build.sh first)"; exit 1; }
	ENV_NAME="$(basename "$(dirname "$FLASH")")"
	prev_uart="$(readlink "$UART" 2>/dev/null || echo "")"
	echo "[test] no running guest — booting $ENV_NAME for a self-contained test"
	"$ROOT/scripts/run.sh" --env "$ENV_NAME" > "$RUN/test-boot.log" 2>&1 &
	trap '"$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true' EXIT
	self_booted=1
	# Wait until run.sh has BOTH recorded the pid AND repointed uart-latest.log to a NEW file.
	for _ in $(seq 1 60); do
		cur="$(readlink "$UART" 2>/dev/null || echo "")"
		if [ -n "$cur" ] && [ "$cur" != "$prev_uart" ] && [ -f "$PIDFILE" ]; then
			BOOT_LOG="$RUN/$cur"; break
		fi
		sleep 1
	done
	[ -n "$BOOT_LOG" ] || { echo "[test] FAIL: guest did not start (no fresh UART log / pid recorded)"; exit 1; }
fi

# --- Readiness: the firmware reached its boot marker in THIS run's UART log ------------------
echo "[test] waiting for firmware boot marker in $(basename "$BOOT_LOG")…"
booted=0
for _ in $(seq 1 60); do        # up to ~120s
	grep -qE "$MARKER" "$BOOT_LOG" 2>/dev/null && { booted=1; break; }
	# a self-booted QEMU that dies before booting is a real failure (e.g. bad image)
	[ "$self_booted" = "1" ] && ! pid_alive && { echo "[test] FAIL: QEMU exited before the firmware booted (see $RUN/test-boot.log)"; exit 1; }
	sleep 2
done
[ "$booted" = "1" ] || { echo "[test] FAIL: firmware did not reach its boot marker within the timeout"; exit 1; }
echo "[test] boot marker seen — MeshCom node is up"
UART="$BOOT_LOG"                 # scans below use this run's log

# --- Diagnostics only (NEVER fatal): web UI, body, net-console ------------------------------
grep -oE 'GOT_IP ip=[0-9.]+' "$UART" 2>/dev/null | tail -1 || true

pass=0
for _ in $(seq 1 10); do
	[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$WEB" 2>/dev/null || echo 000)" = "200" ] && pass=$((pass+1))
done
echo "[test] web 10x: $pass/10 returned 200 (diagnostic; heap-starved web UI is often slow)"
[ "$pass" -lt 10 ] && echo "[test] WARN: web UI sluggish/unreachable — not fatal (RX/TX are independent of it)" || true

curl -s --max-time 6 -D "$RUN/web-headers.txt" -o "$RUN/web-body.html" "$WEB" 2>/dev/null || true
if [ -s "$RUN/web-body.html" ]; then
	echo "[test] body: $(wc -c <"$RUN/web-body.html") bytes sha256=$(sha256sum "$RUN/web-body.html" | cut -d' ' -f1)"
	grep -qiE 'meshcom|<!DOCTYPE|<html' "$RUN/web-body.html" && echo "[test] content: existing MeshCom HTML (OK)" || echo "[test] content: WARN not recognized"
fi

# Passive net-console (read-only, sends nothing). Diagnostic — a failed connect is a WARN.
python3 - "$CON_PORT" <<'PY' || echo "[test] net-console: WARN probe failed (diagnostic, not fatal)"
import socket, sys
p = int(sys.argv[1])
try:
    s = socket.create_connection(("127.0.0.1", p), timeout=5); s.settimeout(2)
    try: data = s.recv(128)
    except socket.timeout: data = b""
    s.close()
    print(f"[test] net-console: accepted; banner={data!r}")
except Exception as e:
    print(f"[test] net-console: WARN {e}"); sys.exit(1)
PY

# No-radio scan of UART (informational).
if [ -f "$UART" ]; then
	echo "[test] no-radio scan:"
	echo "  radio disabled marker : $(grep -c 'radio disabled' "$UART" || true)"
	echo "  RadioLib RX success    : $(grep -c 'Starting to listen ... success' "$UART" || true)  (expect 0)"
	echo "  NimBLE init            : $(grep -ci 'NimBLEDevice::init' "$UART" || true)  (expect 0)"
	echo "  external_radio refs    : $(grep -ci 'external_radio\|extradio' "$UART" || true)  (0 on default builds; >0 on extradio)"
fi

echo "[test] PASS (firmware booted; web/net-console diagnostics above)"
exit 0
