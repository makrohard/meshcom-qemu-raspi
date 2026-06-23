#!/usr/bin/env bash
#
# prepare-openeth.sh — create the project-local OpenCores Ethernet (OpenETH)
# compatibility component that matches whatever ESP-IDF version the resolved
# Arduino framework bundles.
#
# The Arduino framework ships a precompiled ESP-IDF whose libesp_eth.a omits the
# OpenETH MAC object (CONFIG_ETH_USE_OPENETH is off). We therefore vendor the
# *exact-version* upstream OpenETH driver source into lib/openeth_compat so it
# links against the framework. The version is detected at runtime — NOT hard-coded
# — so this stays usable as the framework moves forward.
#
# Output lives only under .work/MeshCom-Firmware/lib/openeth_compat and is removed
# by clean.sh. Apache-2.0 provenance/license are preserved.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/.work/MeshCom-Firmware"
LIB="$SRC/lib/openeth_compat"
export PATH="$HOME/.local/bin:$PATH"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing '$1'. Install with: $2" >&2; exit 1; }; }
need pio   "pipx install platformio   (then: pipx ensurepath)"
need curl  "sudo apt-get install -y curl"
need find  "sudo apt-get install -y findutils"
[ -d "$SRC/.git" ] || { echo "ERROR: workspace missing. Run setup.sh + apply-overlay.sh first." >&2; exit 1; }

# 1) Ensure the Arduino framework for the QEMU env is installed/resolved.
echo "[openeth] resolving Arduino framework (pio pkg install -e qemu-headless)…"
( cd "$SRC" && pio pkg install -e qemu-headless >/dev/null )

# 2) Detect the bundled ESP-IDF version from the installed framework headers.
VER_H="$(find "$HOME/.platformio/packages/framework-arduinoespressif32" \
         -path '*esp_common/include/esp_idf_version.h' 2>/dev/null | head -1)"
[ -n "$VER_H" ] || { echo "ERROR: esp_idf_version.h not found in resolved framework." >&2; exit 5; }
MAJ=$(grep -E 'ESP_IDF_VERSION_MAJOR' "$VER_H" | grep -oE '[0-9]+' | head -1)
MIN=$(grep -E 'ESP_IDF_VERSION_MINOR' "$VER_H" | grep -oE '[0-9]+' | head -1)
PAT=$(grep -E 'ESP_IDF_VERSION_PATCH' "$VER_H" | grep -oE '[0-9]+' | head -1)
if [ -z "$MAJ" ] || [ -z "$MIN" ] || [ -z "$PAT" ]; then echo "ERROR: could not parse ESP-IDF version." >&2; exit 5; fi
TAG="v${MAJ}.${MIN}.${PAT}"
echo "[openeth] framework bundles ESP-IDF ${MAJ}.${MIN}.${PAT} -> upstream tag ${TAG}"

# 3) Verify the framework declares the OpenETH MAC constructor (the API the driver
#    relies on). Fail clearly if the API changed.
ETH_MAC_H="$(find "$HOME/.platformio/packages/framework-arduinoespressif32" -name esp_eth_mac.h | head -1)"
if [ -z "$ETH_MAC_H" ] || ! grep -q 'esp_eth_mac_new_openeth' "$ETH_MAC_H"; then
	echo "ERROR: framework esp_eth_mac.h has no esp_eth_mac_new_openeth declaration — OpenETH API changed." >&2
	exit 6
fi

# 4) Fetch the exact-version driver source + header from upstream ESP-IDF.
BASE="https://raw.githubusercontent.com/espressif/esp-idf/${TAG}/components/esp_eth/src"
mkdir -p "$LIB/include" "$LIB/src"
echo "[openeth] fetching OpenETH driver source for ${TAG}…"
curl -fsSL "$BASE/esp_eth_mac_openeth.c" -o "$LIB/src/esp_eth_mac_openeth.c" \
	|| { echo "ERROR: cannot fetch esp_eth_mac_openeth.c for ${TAG} (network or tag missing)." >&2; exit 7; }
curl -fsSL "$BASE/openeth.h"            -o "$LIB/include/openeth.h" \
	|| { echo "ERROR: cannot fetch openeth.h for ${TAG}." >&2; exit 7; }
grep -q 'esp_eth_mac_new_openeth' "$LIB/src/esp_eth_mac_openeth.c" \
	|| { echo "ERROR: fetched driver does not define esp_eth_mac_new_openeth — layout changed for ${TAG}." >&2; exit 7; }

# 5) Project-owned compatibility prototype (so the app can call the constructor
#    without enabling CONFIG_ETH_USE_OPENETH globally).
cat > "$LIB/include/openeth_compat.h" <<'EOF'
/* openeth_compat.h — project-owned prototype for the OpenETH MAC constructor.
 * The framework declares it only under #if CONFIG_ETH_USE_OPENETH; we provide an
 * unconditional prototype so the QEMU app links against the vendored driver. */
#pragma once
#include "esp_eth_mac.h"
#ifdef __cplusplus
extern "C" {
#endif
esp_eth_mac_t *esp_eth_mac_new_openeth(const eth_mac_config_t *config);
#ifdef __cplusplus
}
#endif
EOF

# 6) Library descriptor: scope the OpenETH DMA descriptor-count macros to this
#    component only (the driver needs them; they are not in the Arduino sdkconfig).
cat > "$LIB/library.json" <<EOF
{
  "name": "openeth_compat",
  "version": "${MAJ}.${MIN}.${PAT}-local",
  "description": "Project-local OpenCores Ethernet MAC driver (verbatim upstream ESP-IDF ${TAG}) for running MeshCom under QEMU. See UPSTREAM.md.",
  "license": "Apache-2.0",
  "frameworks": "arduino",
  "platforms": "espressif32",
  "build": {
    "flags": ["-DCONFIG_ETH_OPENETH_DMA_RX_BUFFER_NUM=4", "-DCONFIG_ETH_OPENETH_DMA_TX_BUFFER_NUM=1"],
    "srcDir": "src", "includeDir": "include"
  }
}
EOF

# Apache-2.0 license text + provenance.
curl -fsSL "https://www.apache.org/licenses/LICENSE-2.0.txt" -o "$LIB/LICENSE" 2>/dev/null || true
cat > "$LIB/UPSTREAM.md" <<EOF
# Vendored OpenETH driver provenance
- Upstream: https://github.com/espressif/esp-idf  tag ${TAG}
- Files (verbatim, Apache-2.0): components/esp_eth/src/esp_eth_mac_openeth.c, openeth.h
- Fetched: $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Reason: the Arduino framework's precompiled libesp_eth.a omits the OpenETH MAC
  object; this exact-version source supplies only that object. Generated locally
  by scripts/prepare-openeth.sh; not stored in the deliverable.
- sha256:
$(sha256sum "$LIB/src/esp_eth_mac_openeth.c" "$LIB/include/openeth.h" | sed 's/^/    /')
EOF

echo "[openeth] lib/openeth_compat ready for ESP-IDF ${TAG}."
