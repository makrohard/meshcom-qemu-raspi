#!/usr/bin/env bash
#
# s5-dropin.sh — PROTOTYPE: copy the QEMU variant and src/qemu/ into the stock MeshCom workspace.
# No MeshCom file is patched; the files are new files only.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
[ -d "$SRC/.git" ] || { echo "ERROR: $SRC not found. Run scripts/setup.sh first." >&2; exit 1; }
mkdir -p "$SRC/variants/qemu-headless" "$SRC/src/qemu"
cp -f "$ROOT"/overlay/variants/qemu-headless/* "$SRC/variants/qemu-headless/"
cp -f "$ROOT"/overlay/src/qemu/* "$SRC/src/qemu/"
echo "[s5] drop-in files copied; tracked MeshCom files changed: $(git -C "$SRC" status --porcelain --untracked-files=no | wc -l)"
