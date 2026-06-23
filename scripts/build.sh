#!/usr/bin/env bash
#
# build.sh — build the QEMU-headless MeshCom firmware and merge a flash image.
#
# Produces a single 4 MB flash image (bootloader + partition table + boot_app0 +
# application) that the official Espressif QEMU can run with `-drive if=mtd`.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
ENV_NAME="qemu-headless"
BUILD="$SRC/.pio/build/$ENV_NAME"
export PATH="$HOME/.local/bin:$PATH"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'. Install with: $2" >&2; exit 1; }; }
need pio "pipx install platformio   (then: pipx ensurepath)"
[ -d "$SRC/.git" ] || { echo "ERROR: workspace missing. Run setup.sh, apply-overlay.sh, prepare-openeth.sh first." >&2; exit 1; }
[ -f "$SRC/lib/openeth_compat/src/esp_eth_mac_openeth.c" ] || { echo "ERROR: OpenETH component missing. Run scripts/prepare-openeth.sh first." >&2; exit 1; }

echo "[build] pio run -e $ENV_NAME (first build downloads the toolchain; be patient)"
( cd "$SRC" && pio run -e "$ENV_NAME" )

for f in bootloader.bin partitions.bin firmware.bin; do
	[ -f "$BUILD/$f" ] || { echo "ERROR: $BUILD/$f not produced." >&2; exit 1; }
done

# Merge the flash image using PlatformIO's own esptool/python.
BOOT_APP0="$(find "$HOME/.platformio/packages/framework-arduinoespressif32" -path '*tools/partitions/boot_app0.bin' | head -1)"
ESPTOOL_PY="$(find "$HOME/.platformio/packages/tool-esptoolpy" -maxdepth 1 -name 'esptool.py' | head -1)"
PIO_PYTHON="$(sed -n '1s/^#!//p' "$(command -v pio)")"; [ -x "$PIO_PYTHON" ] || PIO_PYTHON="python3"
if [ -z "$BOOT_APP0" ] || [ -z "$ESPTOOL_PY" ]; then echo "ERROR: esptool/boot_app0 not found in framework." >&2; exit 1; fi

"$PIO_PYTHON" "$ESPTOOL_PY" --chip esp32 merge_bin --fill-flash-size 4MB -o "$BUILD/flash.bin" \
	0x1000 "$BUILD/bootloader.bin" \
	0x8000 "$BUILD/partitions.bin" \
	0xe000 "$BOOT_APP0" \
	0x10000 "$BUILD/firmware.bin"

echo "[build] OK -> $BUILD/flash.bin"
sha256sum "$BUILD/firmware.bin" "$BUILD/flash.bin"
