#!/usr/bin/env bash
#
# apply-overlay.sh — lay our files over the stock MeshCom workspace (.work/MeshCom-Firmware).
#
# Our files are new files only: the QEMU variant (overlay/variants/qemu-headless/, loaded by upstream's
# `extra_configs = variants/*/platformio.ini`) and the QEMU network code (overlay/src/qemu/). No MeshCom
# file is changed. After the copy the tree must have no modified tracked file; anything else means the
# workspace is not stock MeshCom and the build is refused.
#
# EXIT CODES: 0 = copied, tree stock · 1 = workspace or overlay files missing · 4 = a tracked MeshCom
# file is modified (listed).
# Nothing outside .work/MeshCom-Firmware is modified.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
OVERLAY="$ROOT/overlay"

[ -d "$SRC/.git" ] || { echo "ERROR: $SRC not found. Run scripts/setup.sh first." >&2; exit 1; }
for d in variants/qemu-headless src/qemu; do
	[ -n "$(ls -A "$OVERLAY/$d" 2>/dev/null)" ] || { echo "ERROR: overlay/$d is missing or empty." >&2; exit 1; }
done

echo "[overlay] copying our files (variants/qemu-headless, src/qemu)"
mkdir -p "$SRC/variants/qemu-headless" "$SRC/src/qemu"
cp -f "$OVERLAY"/variants/qemu-headless/* "$SRC/variants/qemu-headless/"
cp -f "$OVERLAY"/src/qemu/* "$SRC/src/qemu/"

changed="$(git -C "$SRC" status --porcelain --untracked-files=no)"
if [ -n "$changed" ]; then
	echo "ERROR: the MeshCom workspace has modified tracked files; it must be stock MeshCom:" >&2
	printf '%s\n' "$changed" | sed 's/^/       | /' >&2
	exit 4
fi
echo "[overlay] done; tracked MeshCom files modified: 0"
