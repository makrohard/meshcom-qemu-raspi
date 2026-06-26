#!/usr/bin/env bash
#
# setup.sh — fetch the MeshCom firmware source into the local workspace.
#
# By default it checks out a KNOWN-WORKING, PINNED stable release tag
# (DEFAULT_REF below) — this is the version the overlay is verified against.
# The pin is configurable:
#   scripts/setup.sh                 # pinned stable (default, recommended)
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

# Known-working, pinned stable release the overlay is verified against.
# (Configurable: edit this, or override per-run with --dev / --ref.)
DEFAULT_REF="v4.35p.06.16"
REF="$DEFAULT_REF"
# Opt-in: clone the firmware from a LOCAL repository/path instead of upstream.
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
	echo "[setup] using LOCAL firmware source: $SRCURL (ref $REF)"
elif [ "$REF" = "$DEFAULT_REF" ]; then
	echo "[setup] using pinned stable ref: $REF"
else
	echo "[setup] using requested ref: $REF (not the pinned default $DEFAULT_REF)"
fi

# --- prerequisite checks (report, never auto-install) ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'. Install with: $2" >&2; exit 1; }; }
need git "sudo apt-get install -y git"

mkdir -p "$WORK" "$RUN"

if [ -n "$SRCURL" ]; then
	# Local source: clone read-only FROM the given repo (the source is never
	# modified) and check out the requested ref into the workspace.
	echo "[setup] cloning local source $SRCURL ($REF) -> $SRC (fresh)"
	rm -rf "$SRC"
	git clone --branch "$REF" "$SRCURL" "$SRC"
elif [ -d "$SRC/.git" ]; then
	echo "[setup] workspace already present at $SRC; fetching latest"
	git -C "$SRC" remote set-url origin "$UPSTREAM_URL"
	git -C "$SRC" fetch --depth 1 origin "$REF"
	git -C "$SRC" checkout -q FETCH_HEAD
else
	echo "[setup] cloning $UPSTREAM_URL ($REF) -> $SRC"
	git clone --depth 1 --branch "$REF" "$UPSTREAM_URL" "$SRC"
fi

SHA="$(git -C "$SRC" rev-parse HEAD)"
echo "$SHA" > "$RUN/meshcom-source.sha"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$RUN/meshcom-source.timestamp"

# --- fail clearly if the layout the overlay expects is not present ---
for p in platformio.ini src/esp32/esp32_main.cpp src/web_functions/web_functions.cpp \
         src/net_console.cpp src/udp_functions.cpp src/batt_function_old.cpp; do
	[ -e "$SRC/$p" ] || { echo "ERROR: upstream layout changed — missing '$p'. The overlay/patch may need maintenance." >&2; exit 3; }
done
grep -q 'variants/\*/platformio.ini' "$SRC/platformio.ini" || \
	echo "[setup] WARN: top-level platformio.ini no longer globs variants/*; the qemu-headless env may not be picked up."

echo "[setup] MeshCom source ready: ref=$REF sha=$SHA"
