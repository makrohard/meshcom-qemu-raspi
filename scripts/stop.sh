#!/usr/bin/env bash
#
# stop.sh — stop ONLY the QEMU instance started by run.sh (exact recorded PID).
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="$ROOT/.run/qemu.pid"

[ -f "$PIDFILE" ] || { echo "[stop] no $PIDFILE (nothing recorded to stop)."; exit 0; }
PID="$(cat "$PIDFILE")"
[ -n "$PID" ] || { echo "[stop] empty pid file."; exit 0; }

if ! kill -0 "$PID" 2>/dev/null; then
	echo "[stop] pid $PID not running."
	rm -f "$PIDFILE"; exit 0
fi

echo "[stop] SIGTERM to qemu pid $PID"
kill -TERM "$PID" 2>/dev/null || true
for _ in $(seq 1 10); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$PID" 2>/dev/null; then echo "[stop] still alive; SIGKILL"; kill -KILL "$PID" 2>/dev/null || true; fi
rm -f "$PIDFILE"
echo "[stop] stopped."
