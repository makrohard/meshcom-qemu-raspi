#!/usr/bin/env bash
#
# s5-provision.sh — PROTOTYPE: provision the node's persistent settings with stock MeshCom console
# commands over UART0 (no firmware change). Run once after run.sh has prepared the node image and
# recorded .run/qemu-cmdline.txt. The firmware's own auto-reboot after `--netmode eth` ends QEMU
# (-no-reboot), so a clean exit is the expected end.
#
#   --setssid/--setpwd   placeholders: stock esp32setup() turns the web server off when no Wi-Fi
#                        credentials are stored and the AP is off; Ethernet mode never uses them
#   --webserver on, --netconsole on, --gps on, --wifiap off, --netmode eth
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/.run"
CMDLINE="$RUN/qemu-cmdline.txt"
[ -f "$CMDLINE" ] || { echo "ERROR: run scripts/run.sh once first (no $CMDLINE)." >&2; exit 1; }
if [ $# -gt 0 ]; then CMDS=("$@"); else
	CMDS=("--setssid qemu0" "--setpwd qemu0000" "--webserver on" "--netconsole on" "--gps on" "--wifiap off" "--netmode eth")
fi
eval "set -- $(sed 's/^\[run\] //' "$CMDLINE")"
LOG="$RUN/uart-provision-$(date -u +%Y%m%dT%H%M%SZ).log"
: > "$LOG"
feed() {
	local i=0
	until grep -aq 'CLIENT STARTED' "$LOG"; do sleep 1; i=$((i+1)); [ $i -lt 90 ] || return 0; done
	sleep 3
	for c in "${CMDS[@]}"; do
		printf '%s\r\n' "$c"; sleep 1
	done
	sleep 40
}
set +e
feed | timeout 120 "$@" >> "$LOG" 2>&1
rc=${PIPESTATUS[1]}
set -e
echo "[s5] provisioning QEMU exit=$rc (0 = the guest reset ended QEMU; 124 = timeout) log=$LOG"
