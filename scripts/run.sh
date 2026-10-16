#!/usr/bin/env bash
#
# run.sh — boot the MeshCom QEMU-headless image in the official Espressif QEMU.
#
# Classic ESP32 + OpenCores Ethernet (open_eth) + user-mode networking, with:
#   host 127.0.0.1:18083 -> guest TCP 80   (web UI)
#   host 127.0.0.1:12323 -> guest TCP 2323 (net-console)
# The installed official QEMU binary is used AS-IS (never modified, never patched,
# never installed by this script). QEMU is "soft-pinned": we detect the installed
# version, record it, and warn if it differs from the verified build, but still run
# (forward-compatible). Override the binary with `--qemu <path>` if needed.
# Foreground, and the guest's supervisor: a guest reset ends QEMU (-no-reboot) and this script starts it
# again; a fresh node image is provisioned first (MeshCom's own console commands, then a check of the
# persisted settings). PIDs (run.pid, qemu.pid), the restart count and the UART logs are under .run/;
# stop.sh stops it.
# QEMU runs on a NODE IMAGE, not on the build output: the node writes its settings (NVS) into the image
# it runs on, and a rebuild or update replaces the build output. scripts/node-image.sh prepares the node
# image from the build before every start and carries the settings into a new build
# (--node-image <path>; default .state/node-flash.bin in this repo).
# The node's MAC, and with it MeshCom's node ID, comes from an efuse image that belongs to the node image
# (<node image>.efuse), created once by scripts/node-efuse.sh.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
RUN="$ROOT/.run"; mkdir -p "$RUN"

# Soft pin: the official Espressif QEMU build this overlay is verified against.
# This is documentation + a warning, NOT a hard requirement (no pinning by install).
KNOWN_GOOD_QEMU="QEMU emulator version 9.2.2"

QEMU_OVERRIDE=""
ENV_NAME="qemu-headless"   # opt-in: --env qemu-headless-extradio for the external-radio target
NODE_IMAGE="$ROOT/.state/node-flash.bin"
while [ $# -gt 0 ]; do
	case "$1" in
		--qemu) QEMU_OVERRIDE="${2:?--qemu needs a path}"; shift 2 ;;
		--env) ENV_NAME="${2:?--env needs a value}"; shift 2 ;;
		--node-image) NODE_IMAGE="${2:?--node-image needs a path}"; shift 2 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done
FLASH="$SRC/.pio/build/$ENV_NAME/flash.bin"
NODE_EFUSE="$NODE_IMAGE.efuse"

# GPS profiles (…-gpsd) get a dedicated host-backed virtual UART1 carrying incoming
# NMEA. Everything else is byte-for-byte unchanged.
GPS=0
case "$ENV_NAME" in *gpsd) GPS=1 ;; esac
GPS_SOCK="$RUN/gps-uart1.sock"

# Locate the official Espressif qemu-system-xtensa (override > PATH > idf_tools).
if [ -n "$QEMU_OVERRIDE" ]; then
	QEMU_BIN="$QEMU_OVERRIDE"
elif command -v qemu-system-xtensa >/dev/null 2>&1; then
	QEMU_BIN="$(command -v qemu-system-xtensa)"
else
	QEMU_BIN="$(find "${IDF_TOOLS_PATH:-$HOME/.espressif}/tools/qemu-xtensa" -path '*/qemu/bin/qemu-system-xtensa' 2>/dev/null | head -1)"
fi
if [ -z "${QEMU_BIN:-}" ] || [ ! -x "$QEMU_BIN" ]; then
	echo "ERROR: official Espressif qemu-system-xtensa not found (try --qemu <path>)." >&2
	echo "       Install via ESP-IDF: python \$IDF_PATH/tools/idf_tools.py install qemu-xtensa" >&2
	exit 1
fi

# Soft-pin check: record version, warn if not the verified build, proceed anyway.
QEMU_VER="$("$QEMU_BIN" --version 2>/dev/null | head -1)"
printf '%s\n%s\n' "$QEMU_BIN" "$QEMU_VER" > "$RUN/qemu.version"
if printf '%s' "$QEMU_VER" | grep -q "$KNOWN_GOOD_QEMU"; then
	echo "[run] QEMU: $QEMU_VER  (matches verified build)"
else
	echo "[run] WARN: installed QEMU is: $QEMU_VER" >&2
	echo "[run] WARN: verified build is $KNOWN_GOOD_QEMU — proceeding anyway (forward-compatible)." >&2
	echo "[run] WARN: for the exact tested build: scripts/build-qemu.sh (esp-develop-9.2.2-20260417 + patches/qemu)" >&2
fi
[ -f "$FLASH" ] || { echo "ERROR: $FLASH not found. Run scripts/build.sh first." >&2; exit 1; }
# --- Ownership --------------------------------------------------------------------------------------
# One runner per checkout (.run/ is shared) and one guest per node image: both locks are held for the
# runner's whole life, provisioning and restarts included, and released by the kernel when it exits.
# stop.sh recognises this process by the open run.lock.
exec 8>"$RUN/run.lock"
flock -n 8 || { echo "ERROR: another run.sh already runs in this checkout; stop it first (scripts/stop.sh)." >&2; exit 1; }
mkdir -p "$(dirname "$NODE_IMAGE")"
NODE_IMAGE="$(cd "$(dirname "$NODE_IMAGE")" && pwd)/$(basename "$NODE_IMAGE")"
NODE_EFUSE="$NODE_IMAGE.efuse"
MARKER="$NODE_IMAGE.provisioned"
exec 9>"$NODE_IMAGE.lock"
flock -n 9 || { echo "ERROR: a QEMU guest already runs on $NODE_IMAGE; stop it first (scripts/stop.sh)." >&2; exit 1; }
put() { local tmp="$1.tmp.$$"; printf '%s\n' "$2" > "$tmp"; mv -f "$tmp" "$1"; }
put "$RUN/run.pid" "$$"
# A stale pointer must never stand for this run: it reappears with the first supervised boot.
rm -f "$RUN/uart-latest.log"
"$ROOT/scripts/node-image.sh" "$FLASH" "$NODE_IMAGE"
"$ROOT/scripts/node-efuse.sh" "$NODE_EFUSE"
# libslirp is REQUIRED for the QEMU user-net (open_eth). Prefer the ldconfig cache, but fall back to a
# direct file check: a service manager may run this with a minimal PATH that omits /usr/sbin (where
# ldconfig lives), and an off-PATH ldconfig must NOT be read as "library missing" (live finding — it
# false-failed under lhpc's stack-run environment on a Pi Zero 2W). The library being present on disk is
# authoritative regardless of whether ldconfig is reachable.
slirp=0
{ ldconfig -p 2>/dev/null | grep -q 'libslirp\.so\.0'; } && slirp=1
for f in /lib/*/libslirp.so.0 /usr/lib/*/libslirp.so.0 /usr/lib/libslirp.so.0; do [ -e "$f" ] && slirp=1; done
[ "$slirp" = 1 ] || { echo "ERROR: libslirp.so.0 missing. Install with: sudo apt-get install -y libslirp0" >&2; exit 1; }

# Commas below are intentional inside quoted QEMU option strings.
# shellcheck disable=SC2054
QEMU_CMD=(
	"$QEMU_BIN"
	-nographic
	-no-reboot   # a guest reset exits QEMU (inside qemu-xtensa a reset wedges in the ROM); this script restarts it
	-machine esp32
	-m 4M
	-drive "file=$NODE_IMAGE,if=mtd,format=raw"
	-drive "file=$NODE_EFUSE,if=none,format=raw,id=efuse"
	-global driver=nvram.esp32.efuse,property=drive,value=efuse
	-nic "user,id=net0,model=open_eth,hostfwd=tcp:127.0.0.1:18083-:80,hostfwd=tcp:127.0.0.1:12323-:2323"
	-global driver=timer.esp32.timg,property=wdt_disable,value=true
	# UART0 = the console on stdio. mon:stdio (as -nographic sets by default) keeps the output flowing when
	# stdin is at EOF (a background job's stdin); a plain stdio backend stops there. The monitor socket
	# (for set_link and friends) is a second monitor.
	-serial mon:stdio
	-monitor "unix:$RUN/monitor.sock,server=on,wait=off"
)

if [ "$GPS" = "1" ]; then
	# UART1 is a dedicated host Unix socket carrying incoming NMEA (QEMU is the server so it boots
	# independently; scripts/gps-relay.py is the client). UART2 is explicit null so QEMU does not
	# auto-route it to stdio.
	rm -f "$GPS_SOCK"
	# shellcheck disable=SC2054
	QEMU_CMD+=(
		-chardev "socket,id=gps1,path=$GPS_SOCK,server=on,wait=off"
		-serial chardev:gps1
		-serial null
	)
	# Restrict the UART1 socket (and this run's log) to the owner.
	umask 0077
fi

echo "[run] $(printf '%q ' "${QEMU_CMD[@]}")" > "$RUN/qemu-cmdline.txt"
echo "[run] web UI:      http://127.0.0.1:18083/"
echo "[run] net-console: 127.0.0.1:12323"
[ "$GPS" = "1" ] && echo "[run] GPS UART1:    $GPS_SOCK    (feed: scripts/gps-relay.py --uart $GPS_SOCK …)"

# --- Supervisor -------------------------------------------------------------------------------------
# A guest reset under -no-reboot ends QEMU with rc 0 and no signal: that is a restart. TERM/INT latch
# STOP; QEMU gets TERM, 10 s, then KILL. EXIT CODES: 0 stopped · 1 setup error · 2 usage · 3 provisioning
# failed · 5 QEMU exited with an error · 75 restart limit (3 runs < 60 s in a row, or > 10 restarts/hour).
STOP=0
QPID=""; QSTART=""
# start_of PID: the process's start time (/proc/PID/stat field 22); empty once it is gone.
start_of() {
	local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
	# shellcheck disable=SC2086 # the fields after the command name, split on purpose
	set -- ${s##*) }; printf '%s' "${20}"
}
# is_guest: QPID is still the QEMU launched (the same start time, this run's monitor socket in its argv)
is_guest() {
	[ -n "$QSTART" ] && [ "$(start_of "$QPID")" = "$QSTART" ] \
		&& { tr '\0' ' ' < "/proc/$QPID/cmdline"; } 2>/dev/null | grep -qF "unix:$RUN/monitor.sock,"
}
# stop_qemu: TERM, 10 s, then KILL only while QPID is still that QEMU (a reused PID is never killed).
stop_qemu() {
	[ -n "$QPID" ] || return 0
	kill -TERM "$QPID" 2>/dev/null || true
	for _ in $(seq 1 10); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
	if ! kill -0 "$QPID" 2>/dev/null; then
		wait "$QPID" 2>/dev/null || true
	elif is_guest; then
		kill -KILL "$QPID" 2>/dev/null || true; wait "$QPID" 2>/dev/null || true
	else
		echo "[run] pid $QPID is no longer this run's QEMU; not killed" >&2
	fi
	QPID=""; QSTART=""
}
on_signal() { STOP=1; stop_qemu; rm -f "$RUN/run.pid"; exit 0; }
trap on_signal TERM INT
qemu_alive() { [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; }
# launch LOG [stdin-fd]: start QEMU in the background, its UART0 appended to LOG.
launch() {
	if [ -n "${2:-}" ]; then "${QEMU_CMD[@]}" <&"$2" >> "$1" 2>&1 &
	else "${QEMU_CMD[@]}" >> "$1" 2>&1 & fi
	QPID=$!; QSTART="$(start_of "$QPID")"
	put "$RUN/qemu.pid" "$QPID"
	echo "[run] QEMU pid $QPID, UART log $1"
}
# wait_rc: the exit code of the QEMU just ended.
wait_rc() { local rc=0; wait "$QPID" || rc=$?; QPID=""; QSTART=""; return "$rc"; }

# --- Provisioning (a node image without a matching marker) -----------------------------------------
# The persistent settings come from MeshCom's own console commands, sent over UART0 once. The
# placeholders keep the web server on (stock code turns it off without Wi-Fi credentials and an AP);
# they are inert in Ethernet mode. `--netmode eth` makes the firmware reboot itself 5 s later.
PROVISION_CMDS=("--setssid qemu0" "--setpwd qemu0000" "--webserver on" "--netconsole on" "--mesh off"
	"--gateway off" "--extudp off")
[ "$GPS" = "1" ] && PROVISION_CMDS+=("--gps on")
PROVISION_CMDS+=("--wifiap off" "--netmode eth")
PROVISION_SHA="$(printf '%s\n' "${PROVISION_CMDS[@]}" | sha256sum | cut -d' ' -f1)"
PROVISION_TIMEOUT="${PROVISION_TIMEOUT:-900}"
DEADLINE=0
provision_fail() { echo "[run] provisioning FAILED: $1 (log: $2)" >&2; stop_qemu; exit 3; }

provision() {
	local log fifo="$RUN/uart0.in" c
	log="$RUN/uart-provision-$(date -u +%Y%m%dT%H%M%SZ).log"
	DEADLINE=$(( $(date +%s) + PROVISION_TIMEOUT ))
	echo "[run] provisioning the node (log $log)"
	rm -f "$fifo"; mkfifo -m 600 "$fifo"; exec 7<>"$fifo"; rm -f "$fifo"
	launch "$log" 7
	until grep -aq 'CLIENT STARTED' "$log"; do
		qemu_alive || provision_fail "QEMU ended before the firmware started" "$log"
		[ "$(date +%s)" -lt "$DEADLINE" ] || provision_fail "timeout before the firmware started" "$log"
		sleep 1
	done
	sleep 3
	for c in "${PROVISION_CMDS[@]}"; do printf '%s\r\n' "$c" >&7; sleep 1; done
	while qemu_alive; do
		[ "$(date +%s)" -lt "$DEADLINE" ] || provision_fail "timeout waiting for the firmware's reboot" "$log"
		sleep 1
	done
	local rc=0; wait_rc || rc=$?
	exec 7>&-
	[ "$rc" = 0 ] || provision_fail "QEMU exited rc=$rc" "$log"
	grep -aq '\[CMD\] netmode -> Ethernet' "$log" || provision_fail "no acknowledgement of --netmode eth" "$log"
}

# console_reply CMD: one command on the net console, the reply on stdout (for a variable, never a file)
console_reply() {
	timeout 20 bash -c 'exec 3<>/dev/tcp/127.0.0.1/12323 || exit 1; sleep 2; printf "%s\r\n" "$1" >&3; timeout 8 cat <&3' _ "$1" 2>/dev/null || true
}
# verify_persisted LOG: the first supervised boot shows Ethernet mode and the console, then the console's
# --info (and --pos for a *-gpsd env) and the web page confirm the persisted settings. The replies are held
# in variables only: --info carries a password field, --pos the position; neither is written.
verify_persisted() {
	local log="$1" info pos code
	grep -aq '\[NET\] Ethernet mode' "$log" && grep -aq 'Console started on port 2323' "$log" || return 1
	info="$(console_reply "--info")"
	case "$info" in *"Console"*) ;; *) echo "[run] provisioning check: the console did not answer like MeshCom's (a console password?)" >&2; return 1 ;; esac
	for t in 'NETWORK Mode:ETH' '...MESH off' '...EXTUDP off' 'Gateway off'; do
		case "$info" in *"$t"*) ;; *) echo "[run] provisioning check: '--info' lacks '$t'" >&2; return 1 ;; esac
	done
	if [ "$GPS" = "1" ]; then
		pos="$(console_reply "--pos")"
		case "$pos" in *'...GPS: on'*) ;; *) echo "[run] provisioning check: '--pos' lacks '...GPS: on'" >&2; return 1 ;; esac
	fi
	code="$(timeout 15 bash -c 'exec 4<>/dev/tcp/127.0.0.1/18083 || exit 1; printf "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n" >&4; head -n 1 <&4' 2>/dev/null || true)"
	case "$code" in *" 200"*) return 0 ;; *) echo "[run] provisioning check: web answered '${code%$'\r'}'" >&2; return 1 ;; esac
}

VERIFY=0
if [ "$(cat "$MARKER" 2>/dev/null | cut -d' ' -f2)" != "$PROVISION_SHA" ]; then
	# A marker for another command list is void from here on: a failed or stopped provisioning must not
	# leave it to be trusted again (after a revert of the list) over partly changed settings.
	rm -f "$MARKER"
	provision
	VERIFY=1
fi

# --- The supervised runs ----------------------------------------------------------------------------
# FAST_RUN_S / RESTART_BUDGET: the limits (60 s, 10 per hour); tests/test-run-supervisor.sh lowers them.
FAST_RUN_S="${FAST_RUN_S:-60}"; RESTART_BUDGET="${RESTART_BUDGET:-10}"
fast=0; n=0; recent=()
while :; do
	[ "$STOP" = 0 ] || exit 0
	STAMP="$(date +%Y%m%d-%H%M%S)"
	UARTLOG="$RUN/uart-$STAMP.log"
	ln -sf "uart-$STAMP.log" "$RUN/uart-latest.log"
	t0="$(date +%s)"
	launch "$UARTLOG"
	while qemu_alive; do
		if [ "$VERIFY" = 1 ]; then
			if verify_persisted "$UARTLOG"; then
				[ "$STOP" = 0 ] || break
				put "$MARKER" "$(date -u +%Y-%m-%dT%H:%M:%SZ) $PROVISION_SHA"
				VERIFY=0
				echo "[run] provisioning verified; marker written ($MARKER)"
			elif [ "$(date +%s)" -ge "$DEADLINE" ]; then
				provision_fail "the persisted settings could not be verified" "$UARTLOG"
			fi
		fi
		sleep 1
	done
	rc=0; wait_rc || rc=$?
	[ "$STOP" = 0 ] || exit 0
	[ "$VERIFY" = 0 ] || provision_fail "the first supervised boot ended before the check" "$UARTLOG"
	[ "$rc" = 0 ] || { echo "[run] QEMU exited rc=$rc" >&2; exit 5; }
	now="$(date +%s)"; dur=$(( now - t0 ))
	if [ "$dur" -lt "$FAST_RUN_S" ]; then fast=$((fast+1)); else fast=0; fi
	[ "$fast" -lt 3 ] || { echo "[run] restart limit: 3 runs shorter than $FAST_RUN_S s in a row" >&2; exit 75; }
	keep=(); for t in "${recent[@]}" "$now"; do [ $(( now - t )) -lt 3600 ] && keep+=("$t"); done; recent=("${keep[@]}")
	[ "${#recent[@]}" -le "$RESTART_BUDGET" ] || { echo "[run] restart limit: more than $RESTART_BUDGET restarts within one hour" >&2; exit 75; }
	n=$((n+1))
	echo "[run] guest reset after $dur s -> restart #$n"
	put "$RUN/restarts" "$n $(date -u +%Y-%m-%dT%H:%M:%SZ)"
done
