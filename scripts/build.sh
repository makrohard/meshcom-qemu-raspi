#!/usr/bin/env bash
#
# build.sh — build the QEMU-headless MeshCom firmware and merge a flash image.
#
# Produces a single 4 MB flash image (bootloader + partition table + boot_app0 +
# application) that the official Espressif QEMU can run with `-drive if=mtd`.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
ENV_NAME="qemu-headless"   # opt-in: --env qemu-headless-extradio for the external-radio target
JOBS=""                    # --jobs N; empty -> memory-aware default computed below
while [ $# -gt 0 ]; do
	case "$1" in
		--env)  ENV_NAME="${2:?--env needs a value}"; shift 2 ;;
		--jobs) JOBS="${2:?--jobs needs a value}"; shift 2 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done
BUILD="$SRC/.pio/build/$ENV_NAME"
export PATH="$HOME/.local/bin:$PATH"
# The PlatformIO package store may be redirected (PLATFORMIO_CORE_DIR); honor it so the
# managed/self-contained install and a plain ~/.platformio dev setup both resolve.
PIO_STORE="${PLATFORMIO_CORE_DIR:-$HOME/.platformio}"
# The MANAGED lhpc build passes PIO=<{root}/build/tools/platformio/.venv/bin/pio> (absolute path);
# standalone dev leaves it unset and falls back to `pio` on PATH (pipx).
PIO="${PIO:-pio}"

# Memory-aware parallelism: min(nproc, max(1, floor(MemTotal_GB))). A 512 MB Zero 2W gets -j1
# (verified: -j4 OOM-kills cc1plus; -j1 completes), a multi-GB Pi 5 gets full parallelism. An
# explicit --jobs N always wins.
if [ -z "$JOBS" ]; then
	_ncpu="$(nproc 2>/dev/null || echo 1)"
	_memkb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
	_memgb=$(( _memkb / 1024 / 1024 ))
	if [ "$_memgb" -lt 1 ]; then _memgb=1; fi
	if [ "$_ncpu" -lt "$_memgb" ]; then JOBS="$_ncpu"; else JOBS="$_memgb"; fi
	if [ "$JOBS" -lt 1 ]; then JOBS=1; fi
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'. Install with: $2" >&2; exit 1; }; }
need "$PIO" "pipx install platformio   (then: pipx ensurepath)   — or let lhpc provision a managed venv"
[ -d "$SRC/.git" ] || { echo "ERROR: workspace missing. Run setup.sh, apply-overlay.sh, prepare-openeth.sh first." >&2; exit 1; }
[ -f "$SRC/lib/openeth_compat/src/esp_eth_mac_openeth.c" ] || { echo "ERROR: OpenETH component missing. Run scripts/prepare-openeth.sh first." >&2; exit 1; }

echo "[build] $PIO run -e $ENV_NAME -j $JOBS (first build downloads the toolchain; be patient)"
( cd "$SRC" && "$PIO" run -e "$ENV_NAME" -j "$JOBS" )

for f in bootloader.bin partitions.bin firmware.bin; do
	[ -f "$BUILD/$f" ] || { echo "ERROR: $BUILD/$f not produced." >&2; exit 1; }
done

# Merge the flash image using PlatformIO's own esptool/python.
BOOT_APP0="$(find "$PIO_STORE/packages/framework-arduinoespressif32" -path '*tools/partitions/boot_app0.bin' | head -1)"
ESPTOOL_PY="$(find "$PIO_STORE/packages/tool-esptoolpy" -maxdepth 1 -name 'esptool.py' | head -1)"
PIO_PYTHON="$(sed -n '1s/^#!//p' "$(command -v "$PIO")")"; [ -x "$PIO_PYTHON" ] || PIO_PYTHON="python3"
if [ -z "$BOOT_APP0" ] || [ -z "$ESPTOOL_PY" ]; then echo "ERROR: esptool/boot_app0 not found in framework." >&2; exit 1; fi

"$PIO_PYTHON" "$ESPTOOL_PY" --chip esp32 merge_bin --fill-flash-size 4MB -o "$BUILD/flash.bin" \
	0x1000 "$BUILD/bootloader.bin" \
	0x8000 "$BUILD/partitions.bin" \
	0xe000 "$BOOT_APP0" \
	0x10000 "$BUILD/firmware.bin"

echo "[build] OK -> $BUILD/flash.bin"
sha256sum "$BUILD/firmware.bin" "$BUILD/flash.bin"
