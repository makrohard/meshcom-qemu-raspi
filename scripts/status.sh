#!/usr/bin/env bash
#
# status.sh — show whether the QEMU guest is running and its current network/UI state.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/.run"
PIDFILE="$RUN/qemu.pid"

echo "== meshcore-qemu-raspi status =="
[ -f "$RUN/meshcom-source.sha" ] && echo "source : $(cat "$RUN/meshcom-source.sha") ($(cat "$RUN/meshcom-source.timestamp" 2>/dev/null))"
[ -f "$RUN/qemu.version" ] && echo "qemu-v : $(tail -1 "$RUN/qemu.version")"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
	echo "qemu   : RUNNING (pid $(cat "$PIDFILE"))"
else
	echo "qemu   : not running"
fi
UART="$RUN/uart-latest.log"
if [ -f "$UART" ]; then
	echo "net    : $(grep -oE 'GOT_IP ip=[0-9.]+' "$UART" | tail -1 || echo 'no IP yet')"
	echo "web    : $(grep -c 'WEBServer started' "$UART" 2>/dev/null || echo 0)x 'WEBServer started'; net-console: $(grep -c 'Console started on port' "$UART" 2>/dev/null || echo 0)x"
fi
if command -v curl >/dev/null 2>&1; then
	code="$(curl -s --max-time 4 -o /dev/null -w '%{http_code}' http://127.0.0.1:18083/ 2>/dev/null || echo 000)"
	echo "http   : GET http://127.0.0.1:18083/ -> $code"
fi
