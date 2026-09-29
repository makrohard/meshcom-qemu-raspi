#!/usr/bin/env bash
#
# apply-overlay.sh — add the QEMU-headless support to the fresh MeshCom workspace.
#
# Three parts:
#   1) copy the new, self-contained files (private PlatformIO target + QEMU
#      network module) into the workspace;
#   2) apply one small patch that adds QEMU_HEADLESS-guarded branches to a few
#      existing MeshCom source files (network readiness, hardware suppression,
#      and the ADC battery guard);
#   3) make `#pragma once` line 1 of src/configuration_global.h (a script step, so
#      upstream version bumps do not break the patch).
#
# Nothing is written until the patch state is known: the header check, then the patch's reverse check
# (already applied) or `git apply --check` (applies cleanly). Only then are files copied and the patch
# applied, so a drifted upstream fails loudly and leaves the firmware tree untouched.
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
# Part 3 needs this upstream header. Check it here, before anything is copied or patched, so a missing header
# fails with nothing changed.
CG="$SRC/src/configuration_global.h"
[ -f "$CG" ] || { echo "ERROR: upstream layout changed — missing 'src/configuration_global.h'. The overlay needs maintenance." >&2; exit 3; }

# 3) `#pragma once` as line 1 of src/configuration_global.h (defined here, called last). Upstream's header
#    has no include guard, and the extradio profiles include it twice in one translation unit
#    (external_radio_glue.cpp: "redefinition of FLASH_STRUCT_LEGACY / flashLayoutCompatible / …"). A script
#    step instead of a patch hunk: the hunk's only context were the version lines, so every upstream version
#    bump broke the patch. Idempotent (it looks at line 1 only).
ensure_pragma_once() {
	local tmp="$CG.tmp.$$"
	if [ "$(head -n 1 "$CG")" != "#pragma once" ]; then
		{ echo "#pragma once"; cat "$CG"; } > "$tmp" || { rm -f "$tmp"; echo "ERROR: could not write $tmp" >&2; exit 3; }
		mv -f "$tmp" "$CG"
		echo "[overlay] added #pragma once to src/configuration_global.h"
	fi
}

# The patch state, before anything is written: already applied (a re-run), or it applies cleanly.
cd "$SRC"
already=0
if git apply --reverse --check "$PATCH" >/dev/null 2>&1; then
	already=1
else
	# The check's error text goes to a private per-run file, not a fixed /tmp path that two
	# concurrent runs (or another user) would share.
	ERRF="$(mktemp)"
	trap 'rm -f "$ERRF"' EXIT
	if ! git apply --check "$PATCH" 2>"$ERRF"; then
		echo "ERROR: patch does not apply to this upstream revision." >&2
		echo "       Upstream may have drifted; the overlay patch needs maintenance." >&2
		sed 's/^/       | /' "$ERRF" >&2 || true
		exit 4
	fi
fi

# 1) new files (idempotent copy; also on a re-run, which refreshes them).
echo "[overlay] copying new files (variants/qemu-headless, src/qemu)"
mkdir -p "$SRC/variants/qemu-headless" "$SRC/src/qemu"
cp -f "$OVERLAY"/variants/qemu-headless/* "$SRC/variants/qemu-headless/"
cp -f "$OVERLAY"/src/qemu/* "$SRC/src/qemu/"

# 2) patch existing files (already checked above).
if [ "$already" = 1 ]; then
	echo "[overlay] patch already applied; nothing to do."
else
	git apply "$PATCH"
	echo "[overlay] applied $(basename "$PATCH") (QEMU_HEADLESS-guarded changes)."
fi

ensure_pragma_once
