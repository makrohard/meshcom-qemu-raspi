#!/usr/bin/env bash
#
# fetch-qemu.sh — TRANSACTIONALLY provision the pinned Espressif qemu-system-xtensa into a target
# directory, sha256-VERIFIED and FAIL-CLOSED. This is the MANAGED provisioning step (lhpc calls it with
# an in-root {root}/build/tool-cache/... dest). run.sh keeps its own --qemu > PATH > IDF_TOOLS_PATH
# fallbacks for standalone dev.
#
#   fetch-qemu.sh <dest-dir> [--from-file <tarball>]
#
# TRANSACTIONAL:
#   * download/copy the archive into a UNIQUE temp file;
#   * verify the pinned SHA-256 BEFORE any extraction (fail closed);
#   * extract into a temp directory, verify the expected binary AND the pinned version;
#   * atomically PUBLISH the completed directory, then write a version/hash MARKER — only after the
#     whole install succeeds.
#   * Re-runs SKIP only when the MARKER and the binary both prove the correct pin; a bare pre-existing
#     executable is NOT trusted. A destination without a valid marker is treated as incomplete and safely
#     rebuilt. Temp files are cleaned on EVERY failure; a previously verified install is preserved.
#   * Offline: LHPC_QEMU_TARBALL (or --from-file) — the quoted local path is hash-verified identically.
#   * The aarch64 prebuild is correct for BOTH a Pi Zero 2W and a Pi 5.
set -eu

PIN="esp_develop_9.0.0_20240606"
TB="qemu-xtensa-softmmu-${PIN}-aarch64-linux-gnu.tar.xz"
SHA="43552f32b303a6820d0d9551903e54fc221aca98ccbd04e5cbccbca881548008"
URL="https://github.com/espressif/qemu/releases/download/esp-develop-9.0.0-20240606/${TB}"

DEST="${1:-}"
[ -n "$DEST" ] || { echo "usage: fetch-qemu.sh <dest-dir> [--from-file <tarball>]" >&2; exit 2; }
shift
FROM_FILE="${LHPC_QEMU_TARBALL:-}"
while [ $# -gt 0 ]; do
	case "$1" in
		--from-file) FROM_FILE="${2:?--from-file needs a path}"; shift 2 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: fetch-qemu needs '$1' on PATH" >&2; exit 3; }; }
need sha256sum
need tar

BIN_REL="qemu/bin/qemu-system-xtensa"
BIN="$DEST/$BIN_REL"
MARKER="$DEST/.lhpc-qemu-verified"

# 1) SKIP only when a completion MARKER proves the correct pin+sha AND the expected binary is present.
if [ -f "$MARKER" ] && [ -x "$BIN" ] \
	&& grep -qxF "pin=${PIN}" "$MARKER" && grep -qxF "sha256=${SHA}" "$MARKER"; then
	echo "[fetch-qemu] already provisioned + verified: $BIN"
	exit 0
fi

# Stage everything in temp siblings of DEST (same filesystem -> atomic publish); a failure never touches
# a previously verified install, and temps are removed on ANY exit.
parent="$(dirname -- "$DEST")"
mkdir -p "$parent"
tmp_tb=""; tmp_dir=""
cleanup() {
	[ -n "$tmp_tb" ] && rm -f -- "$tmp_tb"
	[ -n "$tmp_dir" ] && rm -rf -- "$tmp_dir"
	return 0
}
trap cleanup EXIT
tmp_tb="$(mktemp "${parent}/.qemu-tb.XXXXXX")"
tmp_dir="$(mktemp -d "${parent}/.qemu-stage.XXXXXX")"

# 2) Fetch into the unique temp file (quoted throughout).
if [ -n "$FROM_FILE" ]; then
	echo "[fetch-qemu] using local tarball: $FROM_FILE"
	[ -f "$FROM_FILE" ] || { echo "ERROR: --from-file/LHPC_QEMU_TARBALL not found: $FROM_FILE" >&2; exit 1; }
	cp -- "$FROM_FILE" "$tmp_tb"
else
	need wget
	echo "[fetch-qemu] downloading $URL"
	wget -O "$tmp_tb" "$URL"
fi

# 3) Verify the pinned SHA-256 BEFORE extraction (fail-closed).
if ! printf '%s  %s\n' "$SHA" "$tmp_tb" | sha256sum -c - >/dev/null 2>&1; then
	echo "[fetch-qemu] sha256 MISMATCH — refusing (source: ${FROM_FILE:-$URL})" >&2
	exit 1
fi

# 4) Extract into the temp dir; verify the expected binary AND that it is the pinned version.
tar -xJf "$tmp_tb" -C "$tmp_dir"
staged_bin="$tmp_dir/$BIN_REL"
[ -x "$staged_bin" ] || { echo "[fetch-qemu] expected binary missing after unpack: $BIN_REL" >&2; exit 1; }
if ! "$staged_bin" --version 2>/dev/null | grep -qF "$PIN"; then
	echo "[fetch-qemu] extracted qemu is not the pinned build ${PIN} — refusing" >&2
	exit 1
fi

# 5) PUBLISH atomically (replace any incomplete/unverified dest with the verified staged tree), THEN
#    write the completion marker — only after the whole install has succeeded.
rm -rf -- "$DEST"
mv -- "$tmp_dir" "$DEST"
tmp_dir=""                                   # published -> cleanup must not remove it
rm -f -- "$tmp_tb"; tmp_tb=""
printf 'pin=%s\nsha256=%s\n' "$PIN" "$SHA" > "$MARKER"
echo "[fetch-qemu] provisioned + verified $BIN"
