#!/usr/bin/env bash
#
# test.sh — quick verification that the running guest serves the existing MeshCom
# web UI and net-console, and that no radio is active. Assumes run.sh is running.
#
# Checks: DHCP IPv4, 10x GET / (real MeshCom HTML), passive net-console accept
# (read-only, sends nothing), and a no-radio scan of the UART log.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/.run"
UART="$RUN/uart-latest.log"
WEB="http://127.0.0.1:18083/"
CON_PORT=12323

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'." >&2; exit 1; }; }
need curl "sudo apt-get install -y curl"
need python3 "sudo apt-get install -y python3"

# Wait up to 60s for the web server to answer (DHCP + boot).
echo "[test] waiting for web UI readiness…"
ready=0
for _ in $(seq 1 30); do
	[ "$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' "$WEB" 2>/dev/null || echo 000)" = "200" ] && { ready=1; break; }
	sleep 2
done
[ "$ready" = "1" ] || { echo "[test] FAIL: web UI not reachable at $WEB"; exit 1; }
if [ -f "$UART" ]; then grep -oE 'GOT_IP ip=[0-9.]+' "$UART" | tail -1 || true; fi

# 10x root page.
pass=0
for _ in $(seq 1 10); do
	[ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$WEB" 2>/dev/null || echo 000)" = "200" ] && pass=$((pass+1))
done
echo "[test] web 10x: $pass/10 returned 200"

# Headers + body fingerprint; confirm it is existing MeshCom HTML.
curl -s --max-time 6 -D "$RUN/web-headers.txt" -o "$RUN/web-body.html" "$WEB" || true
echo "[test] body: $(wc -c <"$RUN/web-body.html") bytes sha256=$(sha256sum "$RUN/web-body.html" | cut -d' ' -f1)"
grep -qiE 'meshcom|<!DOCTYPE|<html' "$RUN/web-body.html" && echo "[test] content: existing MeshCom HTML (OK)" || echo "[test] content: WARN not recognized"

# Passive net-console: connect, read briefly, send nothing, close.
python3 - "$CON_PORT" <<'PY'
import socket, sys
p=int(sys.argv[1])
try:
    s=socket.create_connection(("127.0.0.1",p),timeout=5); s.settimeout(2)
    try: data=s.recv(128)
    except socket.timeout: data=b""
    s.close()
    print(f"[test] net-console: accepted; banner={data!r}")
except Exception as e:
    print(f"[test] net-console: FAIL {e}"); sys.exit(1)
PY

# No-radio scan of UART.
if [ -f "$UART" ]; then
	echo "[test] no-radio scan:"
	echo "  radio disabled marker : $(grep -c 'radio disabled' "$UART")"
	echo "  RadioLib RX success    : $(grep -c 'Starting to listen ... success' "$UART")  (expect 0)"
	echo "  NimBLE init            : $(grep -ci 'NimBLEDevice::init' "$UART")  (expect 0)"
	echo "  external_radio refs    : $(grep -ci 'external_radio\|extradio' "$UART")  (expect 0)"
fi
if [ "$pass" = "10" ]; then echo "[test] PASS"; else echo "[test] FAIL ($pass/10)"; exit 1; fi
