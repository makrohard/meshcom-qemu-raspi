#!/usr/bin/env bash
#
# stop.sh — stop the runner (scripts/run.sh) and its QEMU guest.
#
# A PID file is trusted only for a process that still is what it names: run.pid only if that process
# holds this checkout's .run/run.lock open, qemu.pid only if that process is qemu-system-xtensa on a node
# image with this checkout's monitor socket. A stale or reused PID is never signalled; its file is removed.
# The check is repeated before a SIGKILL (stop_pid).
# EXIT CODE: 0, also when nothing runs.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/.run"

is_runner() { [ -n "$1" ] && find "/proc/$1/fd" -maxdepth 1 -lname "$RUN/run.lock" 2>/dev/null | grep -q .; }
# A guest of THIS runner: qemu-system-xtensa with an MTD node image and this checkout's monitor socket
# (run.sh passes -monitor unix:$RUN/monitor.sock); another runner's guest has its own socket.
is_qemu() {
	local c; c="$( { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null)" || return 1
	printf '%s' "$c" | grep -q 'qemu-system-xtensa .*-drive file=.*\.bin,if=mtd' && printf '%s' "$c" | grep -qF "unix:$RUN/monitor.sock,"
}
# start_of PID: the process's start time (/proc/PID/stat field 22); empty once it is gone.
start_of() {
	local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
	# shellcheck disable=SC2086 # the fields after the command name, split on purpose
	set -- ${s##*) }; printf '%s' "${20}"
}
# stop_pid PID CHECK: TERM, up to 15 s, then KILL only while PID is still the process CHECK accepted (the
# same start time and CHECK still true). A PID that ended and was reused, or a process that became
# something else, is not killed.
stop_pid() {
	local st; st="$(start_of "$1")"
	kill -TERM "$1" 2>/dev/null || true
	for _ in $(seq 1 15); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
	if [ -n "$st" ] && [ "$(start_of "$1")" = "$st" ] && "$2" "$1"; then
		echo "[stop] pid $1 still alive; SIGKILL"; kill -KILL "$1" 2>/dev/null || true
	else
		echo "[stop] pid $1 is no longer the process that was checked; not killed"
	fi
}

stopped=0
RPID="$(cat "$RUN/run.pid" 2>/dev/null || true)"
if is_runner "$RPID"; then
	echo "[stop] SIGTERM to the runner, pid $RPID (it stops its QEMU)"
	stop_pid "$RPID" is_runner; stopped=1
elif [ -n "$RPID" ]; then
	echo "[stop] run.pid $RPID is not this checkout's runner; not signalled"
fi
rm -f "$RUN/run.pid"

QPID="$(cat "$RUN/qemu.pid" 2>/dev/null || true)"
if is_qemu "$QPID"; then
	echo "[stop] SIGTERM to qemu pid $QPID"
	stop_pid "$QPID" is_qemu; stopped=1
elif [ -n "$QPID" ] && [ "$stopped" = 0 ]; then
	echo "[stop] qemu.pid $QPID is not a running guest; not signalled"
fi
rm -f "$RUN/qemu.pid" "$RUN/gps-uart1.sock"
[ "$stopped" = 1 ] && echo "[stop] stopped." || echo "[stop] nothing was running."
exit 0
