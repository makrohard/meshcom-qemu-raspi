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
# The exact PID and UART log are written under .run/. Foreground; stop.sh stops it.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
RUN="$ROOT/.run"; mkdir -p "$RUN"

# Soft pin: the official Espressif QEMU build this overlay is verified against.
# This is documentation + a warning, NOT a hard requirement (no pinning by install).
KNOWN_GOOD_QEMU="esp_develop_9.0.0_20240606"

QEMU_OVERRIDE=""
ENV_NAME="qemu-headless"   # opt-in: --env qemu-headless-extradio for the external-radio target
while [ $# -gt 0 ]; do
	case "$1" in
		--qemu) QEMU_OVERRIDE="${2:?--qemu needs a path}"; shift 2 ;;
		--env) ENV_NAME="${2:?--env needs a value}"; shift 2 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done
FLASH="$SRC/.pio/build/$ENV_NAME/flash.bin"

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
	QEMU_BIN="$(find "$HOME/.espressif/tools/qemu-xtensa" -path '*/qemu/bin/qemu-system-xtensa' 2>/dev/null | head -1)"
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
	echo "[run] WARN: for the exact tested build: python \$IDF_PATH/tools/idf_tools.py install qemu-xtensa@$KNOWN_GOOD_QEMU" >&2
fi
[ -f "$FLASH" ] || { echo "ERROR: $FLASH not found. Run scripts/build.sh first." >&2; exit 1; }
ldconfig -p 2>/dev/null | grep -q 'libslirp\.so\.0' || {
	echo "ERROR: libslirp.so.0 missing. Install with: sudo apt-get install -y libslirp0" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
UARTLOG="$RUN/uart-$STAMP.log"
ln -sf "uart-$STAMP.log" "$RUN/uart-latest.log"

# Commas below are intentional inside quoted QEMU option strings.
# shellcheck disable=SC2054
QEMU_CMD=(
	"$QEMU_BIN"
	-nographic
	-machine esp32
	-m 4M
	-drive "file=$FLASH,if=mtd,format=raw"
	-nic "user,model=open_eth,hostfwd=tcp:127.0.0.1:18083-:80,hostfwd=tcp:127.0.0.1:12323-:2323"
	-global driver=timer.esp32.timg,property=wdt_disable,value=true
)

if [ "$GPS" = "1" ]; then
	# UART0 stays the console: mon:stdio mux's the monitor + serial0 onto stdio,
	# exactly as -nographic does by default, so the existing UART log is unchanged.
	# UART1 is a dedicated host Unix socket carrying incoming NMEA (QEMU is the
	# server so it boots independently; scripts/gps-relay.py is the client). UART2
	# is explicit null so QEMU does not auto-route it to stdio.
	rm -f "$GPS_SOCK"
	# shellcheck disable=SC2054
	QEMU_CMD+=(
		-serial mon:stdio
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
echo "[run] UART log:    $UARTLOG    (stop: scripts/stop.sh)"

"${QEMU_CMD[@]}" >> "$UARTLOG" 2>&1 &
QPID=$!
echo "$QPID" > "$RUN/qemu.pid"
echo "[run] QEMU pid $QPID"
wait "$QPID"
