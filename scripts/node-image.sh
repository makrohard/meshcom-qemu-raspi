#!/usr/bin/env bash
#
# node-image.sh BUILD NODE — prepare the flash image QEMU runs on, so the node keeps its settings.
#
# QEMU writes the node's settings (NVS: every MeshCom setting, the message-id counter, the saved clock)
# into the flash image it runs on. Running on the build output (BUILD) lost all of that at every rebuild
# or update. run.sh therefore runs on NODE, a copy kept outside the build tree, prepared here:
#
#   * no NODE              -> NODE = a copy of BUILD;
#   * BUILD unchanged      -> NODE is used as it is (the sidecar NODE.build-sha256 names the build it
#                             was made from);
#   * BUILD changed        -> NODE = the new BUILD with the old NODE's NVS range (0x9000-0xDFFF) carried
#                             in, when the partition-table sector at 0x8000 is byte-identical in both;
#                             otherwise the new BUILD alone (the settings are reset, one log line).
#
# Bootloader, partition table, otadata and firmware always come from BUILD. Writes never leave a moment
# without a NODE: the old NODE is copied to NODE.prev first (exactly one previous image is kept), the new
# NODE is written to a temp file, synced and renamed over the old one, and only then is the sidecar
# updated. A crash before the sidecar leaves a new NODE with the old sidecar; the next start carries
# again from that NODE, which gives the same image.
#
# Call only while QEMU is not running on NODE (run.sh calls it right before starting QEMU).
set -eu
umask 077   # the node image holds the node's settings, credentials included: owner only

BUILD="${1:?usage: node-image.sh BUILD NODE}"
NODE="${2:?usage: node-image.sh BUILD NODE}"
SIDE="$NODE.build-sha256"
PREV="$NODE.prev"

SECTOR=4096
PT_BLOCK=8      # 0x8000: partition table
NVS_BLOCK=9     # 0x9000
NVS_BLOCKS=5    # 0x9000-0xDFFF (partitions-qemu.csv: nvs 0x9000 size 0x5000)

[ -f "$BUILD" ] || { echo "ERROR: build image not found: $BUILD" >&2; exit 1; }
mkdir -p "$(dirname "$NODE")"

durable() { sync -- "$1"; sync -- "$(dirname "$1")"; }
# Write $2 over $1 atomically: temp file in the same directory, synced, renamed.
install_file() {
	local dest="$1" src="$2" tmp="$1.tmp.$$"
	cp -- "$src" "$tmp"; sync -- "$tmp"; mv -f -- "$tmp" "$dest"; durable "$dest"
}
write_sidecar() {
	local tmp="$SIDE.tmp.$$"
	printf '%s\n' "$1" > "$tmp"; sync -- "$tmp"; mv -f -- "$tmp" "$SIDE"; durable "$SIDE"
}
block() { dd if="$1" bs="$SECTOR" skip="$2" count="$3" status=none; }

BSHA="$(sha256sum -- "$BUILD" | cut -d' ' -f1)"

if [ ! -f "$NODE" ]; then
	install_file "$NODE" "$BUILD"
	write_sidecar "$BSHA"
	echo "[run] node image: created from the build ($NODE)"
	exit 0
fi

if [ -f "$SIDE" ] && [ "$(cat -- "$SIDE")" = "$BSHA" ]; then
	echo "[run] node image: unchanged build, node settings kept ($NODE)"
	exit 0
fi

# The build changed (or the sidecar is missing): keep the old node, then build the new one.
install_file "$PREV" "$NODE"
NEW="$NODE.new.$$"
cp -- "$BUILD" "$NEW"
if cmp -s <(block "$NODE" "$PT_BLOCK" 1) <(block "$BUILD" "$PT_BLOCK" 1); then
	dd if="$NODE" of="$NEW" bs="$SECTOR" skip="$NVS_BLOCK" seek="$NVS_BLOCK" count="$NVS_BLOCKS" \
		conv=notrunc status=none
	msg="new build, node settings carried over"
else
	msg="new build with a different partition table, node settings RESET"
fi
sync -- "$NEW"; mv -f -- "$NEW" "$NODE"; durable "$NODE"
write_sidecar "$BSHA"
echo "[run] node image: $msg ($NODE; previous image kept as $PREV)"
