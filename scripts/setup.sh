#!/usr/bin/env bash
#
# setup.sh — fetch the MeshCom firmware source into the local workspace.
#
# By default it checks out a KNOWN-WORKING, PINNED MeshCom commit
# (DEFAULT_REF below), the commit our files are validated against.
# The pin is configurable:
#   scripts/setup.sh                 # pinned (default, recommended)
#   scripts/setup.sh --dev           # latest upstream dev branch (moving target)
#   scripts/setup.sh --ref <tag|branch|sha>   # any specific revision
# To change the default permanently, edit DEFAULT_REF.
#
# Everything lands under the ignored workspace `.work/`; nothing outside this
# deliverable is touched, and no system packages are installed.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.work"
SRC="$WORK/MeshCom-Firmware"
RUN="$ROOT/.run"

# Official upstream MeshCom firmware repository.
UPSTREAM_URL="https://github.com/icssw-org/MeshCom-Firmware.git"

# Pinned by commit; upstream moves tags (v4.40a.hbserver moved on 2026-10-13), so a tag is only a label.
# (Configurable: edit this, or override per-run with --dev / --ref.)
DEFAULT_REF="f2b3a3496a76f327abec8b7228bce436cafe9606"   # icssw-org dev f2b3a349 (2026-10-13; tag v4.40a.hbserver at the time)
REF="$DEFAULT_REF"
# Opt-in: fetch the firmware from another repository (a local path or a fork URL) instead of upstream.
# Used by the external-radio validation to run a local feature branch WITHOUT
# modifying that source. Default (empty) keeps the normal upstream behavior.
SRCURL=""

while [ $# -gt 0 ]; do
	case "$1" in
		--dev) REF="dev"; shift ;;
		--stable) REF="$DEFAULT_REF"; shift ;;
		--ref) REF="${2:?--ref needs a value}"; shift 2 ;;
		--src) SRCURL="${2:?--src needs a path/URL}"; shift 2 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done

# --src implies a non-default ref must usually be given (e.g. a feature branch).
if [ -n "$SRCURL" ]; then
	echo "[setup] using firmware source: $SRCURL (ref $REF)"
elif [ "$REF" = "$DEFAULT_REF" ]; then
	echo "[setup] using pinned ref: $REF"
else
	echo "[setup] using requested ref: $REF (not the pinned default $DEFAULT_REF)"
fi

# --- prerequisite checks (report, never auto-install) ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'. Install with: $2" >&2; exit 1; }; }
need git "sudo apt-get install -y git"

mkdir -p "$WORK" "$RUN"

if [ -n "$SRCURL" ]; then
	# Another source (a local repository or a fork): fetched read-only by ref into a fresh
	# workspace, like upstream below, so a commit SHA works as well as a branch or tag.
	echo "[setup] cloning $SRCURL ($REF) -> $SRC (fresh)"
	rm -rf "$SRC"
	git init -q "$SRC"
	git -C "$SRC" remote add origin "$SRCURL"
	git -C "$SRC" fetch --depth 1 origin "$REF"
	git -C "$SRC" checkout -q FETCH_HEAD
elif [ -d "$SRC/.git" ]; then
	echo "[setup] workspace already present at $SRC; fetching latest"
	git -C "$SRC" remote set-url origin "$UPSTREAM_URL"
	git -C "$SRC" fetch --depth 1 origin "$REF"
	# -f: the workspace belongs to these scripts; a tracked file left modified (by an older runner that
	# patched MeshCom) is reset to the stock file, which apply-overlay.sh then requires.
	git -C "$SRC" checkout -q -f FETCH_HEAD
else
	# fetch-by-ref, not `clone --branch`: a pinned commit SHA is a valid ref here (the
	# lhpc manifest passes one), and `--branch` accepts only branch and tag names.
	echo "[setup] cloning $UPSTREAM_URL ($REF) -> $SRC"
	rm -rf "$SRC"
	git init -q "$SRC"
	git -C "$SRC" remote add origin "$UPSTREAM_URL"
	git -C "$SRC" fetch --depth 1 origin "$REF"
	git -C "$SRC" checkout -q FETCH_HEAD
fi

SHA="$(git -C "$SRC" rev-parse HEAD)"
echo "$SHA" > "$RUN/meshcom-source.sha"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$RUN/meshcom-source.timestamp"

# --- fail clearly if a file our code builds against is missing ---
for p in platformio.ini src/configuration_global.h src/udp_functions.cpp src/esp32/esp32_eth.cpp \
         src/esp32/esp32_eth.h src/esp32/esp32_flash.h src/esp32/external_radio_glue.cpp; do
	[ -e "$SRC/$p" ] || { echo "ERROR: upstream layout changed — missing '$p'. Our files need maintenance." >&2; exit 3; }
done
grep -q 'variants/\*/platformio.ini' "$SRC/platformio.ini" || \
	echo "[setup] WARN: top-level platformio.ini no longer globs variants/*; the qemu-headless env may not be picked up."

echo "[setup] MeshCom source ready: ref=$REF sha=$SHA"
