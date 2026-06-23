#!/usr/bin/env bash
#
# apply-overlay.sh — add the QEMU-headless support to the fresh MeshCom workspace.
#
# Two parts:
#   1) copy the new, self-contained files (private PlatformIO target + QEMU
#      network module) into the workspace;
#   2) apply one small patch that adds QEMU_HEADLESS-guarded branches to a few
#      existing MeshCom source files (network readiness, hardware suppression,
#      and the ADC battery guard).
#
# The patch is checked with `git apply --check` first and applied only if it is
# clean, so a drifted upstream fails loudly instead of applying partially.
# Nothing outside .work/MeshCom-Firmware is modified.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
OVERLAY="$ROOT/overlay"
PATCH="$OVERLAY/patches/meshcom-qemu-headless.patch"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'. Install with: $2" >&2; exit 1; }; }
need git "sudo apt-get install -y git"

# Guard: only ever operate inside the workspace clone.
[ -d "$SRC/.git" ] || { echo "ERROR: $SRC not found. Run scripts/setup.sh first." >&2; exit 1; }
[ -f "$PATCH" ] || { echo "ERROR: patch not found: $PATCH" >&2; exit 1; }

# 1) new files (idempotent copy).
echo "[overlay] copying new files (variants/qemu-headless, src/qemu)"
mkdir -p "$SRC/variants/qemu-headless" "$SRC/src/qemu"
cp -f "$OVERLAY"/variants/qemu-headless/* "$SRC/variants/qemu-headless/"
cp -f "$OVERLAY"/src/qemu/* "$SRC/src/qemu/"

# 2) patch existing files (check, then apply). Tolerate re-running.
cd "$SRC"
if git apply --reverse --check "$PATCH" >/dev/null 2>&1; then
	echo "[overlay] patch already applied; nothing to do."
	exit 0
fi
if ! git apply --check "$PATCH" 2>/tmp/overlay_apply_err; then
	echo "ERROR: patch does not apply to this upstream revision." >&2
	echo "       Upstream may have drifted; the overlay patch needs maintenance." >&2
	sed 's/^/       | /' /tmp/overlay_apply_err >&2 || true
	exit 4
fi
git apply "$PATCH"
echo "[overlay] applied $(basename "$PATCH") (QEMU_HEADLESS-guarded changes)."
