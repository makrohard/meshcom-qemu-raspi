#!/usr/bin/env bash
#
# clean.sh — remove all generated/runtime data; keep only the deliverable sources.
#
# Removes the workspace (.work/, incl. the cloned MeshCom tree, .pio build output,
# and the generated lib/openeth_compat) and runtime data (.run/). Never touches
# overlay/, scripts/, README.md, or .gitignore.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Stop a running guest first, if any.
if [ -f "$ROOT/.run/qemu.pid" ]; then
	bash "$ROOT/scripts/stop.sh" || true
fi

for d in "$ROOT/.work" "$ROOT/.run"; do
	[ -e "$d" ] && { echo "[clean] removing $d"; rm -rf "$d"; }
done
echo "[clean] done. Deliverable sources retained:"
( cd "$ROOT" && ls -1 )
