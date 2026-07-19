#!/usr/bin/env bash
#
# fetch-qemu.sh — TRANSACTIONALLY provision the pinned Espressif qemu-system-xtensa into a target
# directory, sha256-VERIFIED and FAIL-CLOSED. Managed provisioning step (lhpc calls it with an in-root
# {root}/build/tool-cache/... dest). run.sh keeps --qemu > PATH > IDF_TOOLS_PATH for standalone dev.
#
#   fetch-qemu.sh <dest-dir> [--from-file <tarball>]
#
# RETRY-SAFE same-filesystem transaction (a prior verified install is NEVER destroyed before the
# replacement is safely published):
#   * download/copy the archive to a UNIQUE temp file; verify the pinned SHA-256 BEFORE extraction;
#   * extract to a temp dir; verify the expected binary AND the pinned version;
#   * write the completion MARKER INTO the staged tree (visible only WITH a completed install);
#   * move an existing destination aside to a UNIQUE sibling BACKUP (never deleted up front);
#   * PUBLISH the staged tree with an atomic rename; on any publish failure RESTORE the backup;
#   * remove the backup only AFTER the replacement is fully published.
#   A later run RECOVERS from an interruption (DEST gone but a sibling backup present -> restore it).
#   Re-runs SKIP only when the marker + binary prove the pin (a bare executable is never trusted); an
#   incomplete / wrong-version / malformed install is rebuilt. dest / staging / backup are inspected with
#   lstat semantics and a symlink supplied in their place is REFUSED — never followed or removed.
#   Cleanup is bounded to explicitly-constructed sibling paths. Offline: LHPC_QEMU_TARBALL / --from-file
#   (hash-verified). aarch64 prebuild is correct for BOTH a Pi Zero 2W and a Pi 5.
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
MARKER_REL=".lhpc-qemu-verified"
MARKER="$DEST/$MARKER_REL"
parent="$(dirname -- "$DEST")"
dname="$(basename -- "$DEST")"
BACKUP_PREFIX=".qemu-backup.${dname}."

# A symlink supplied in place of the destination directory is refused outright (never followed/removed).
if [ -L "$DEST" ]; then
	echo "[fetch-qemu] destination path is a symlink — refusing: $DEST" >&2
	exit 4
fi
mkdir -p "$parent"

# RECOVER an interrupted transaction: DEST absent but a sibling backup of THIS dest present (a crash
# between the backup-move and the publish) -> restore the first non-symlink backup directory.
if [ ! -e "$DEST" ]; then
	for _b in "$parent/${BACKUP_PREFIX}"*; do
		if [ ! -e "$_b" ]; then continue; fi
		if [ -L "$_b" ]; then continue; fi
		if [ ! -d "$_b" ]; then continue; fi
		if mv -- "$_b" "$DEST"; then break; fi
	done
fi

# Remove OUR bounded sibling leftovers (stale temps + surplus backups); never touch a symlink.
sweep_siblings() {
	local g
	for g in "$parent/.qemu-tb."* "$parent/.qemu-stage."* "$parent/${BACKUP_PREFIX}"*; do
		if [ ! -e "$g" ] && [ ! -L "$g" ]; then continue; fi
		if [ -L "$g" ]; then continue; fi
		rm -rf -- "$g"
	done
}

# SKIP only when a completion MARKER (regular, non-symlink) proves the pin+sha AND the expected binary
# (regular, non-symlink, executable) is present.
if [ -f "$MARKER" ] && [ ! -L "$MARKER" ] && [ -f "$BIN" ] && [ ! -L "$BIN" ] && [ -x "$BIN" ] \
	&& grep -qxF "pin=${PIN}" "$MARKER" && grep -qxF "sha256=${SHA}" "$MARKER"; then
	sweep_siblings
	echo "[fetch-qemu] already provisioned + verified: $BIN"
	exit 0
fi

# Stage in temp siblings (same filesystem). The trap cleans ONLY the temp tarball + staging dir — NEVER
# a backup (a backup IS the prior install; an interrupted publish is recovered on the next run).
tmp_tb=""; tmp_dir=""
cleanup() {
	if [ -n "${tmp_tb:-}" ] && [ ! -L "$tmp_tb" ]; then rm -f -- "$tmp_tb"; fi
	if [ -n "${tmp_dir:-}" ] && [ ! -L "$tmp_dir" ]; then rm -rf -- "$tmp_dir"; fi
	return 0
}
trap cleanup EXIT
tmp_tb="$(mktemp "${parent}/.qemu-tb.XXXXXX")"
tmp_dir="$(mktemp -d "${parent}/.qemu-stage.XXXXXX")"

# Fetch into the unique temp file (quoted throughout).
if [ -n "$FROM_FILE" ]; then
	echo "[fetch-qemu] using local tarball: $FROM_FILE"
	[ -f "$FROM_FILE" ] || { echo "ERROR: --from-file/LHPC_QEMU_TARBALL not found: $FROM_FILE" >&2; exit 1; }
	cp -- "$FROM_FILE" "$tmp_tb"
else
	need wget
	echo "[fetch-qemu] downloading $URL"
	wget -O "$tmp_tb" "$URL"
fi

# Verify the pinned SHA-256 BEFORE extraction (fail-closed).
if ! printf '%s  %s\n' "$SHA" "$tmp_tb" | sha256sum -c - >/dev/null 2>&1; then
	echo "[fetch-qemu] sha256 MISMATCH — refusing (source: ${FROM_FILE:-$URL})" >&2
	exit 1
fi

# Extract; verify the expected binary AND that it is the pinned version.
tar -xJf "$tmp_tb" -C "$tmp_dir"
staged_bin="$tmp_dir/$BIN_REL"
if [ ! -f "$staged_bin" ] || [ -L "$staged_bin" ] || [ ! -x "$staged_bin" ]; then
	echo "[fetch-qemu] expected binary missing/invalid after unpack: $BIN_REL" >&2
	exit 1
fi
if ! "$staged_bin" --version 2>/dev/null | grep -qF "$PIN"; then
	echo "[fetch-qemu] extracted qemu is not the pinned build ${PIN} — refusing" >&2
	exit 1
fi

# Make the completion marker part of the VERIFIED staged tree — it becomes visible only WITH the
# completed installation via the atomic publish below (never a separate post-publish write to fail).
printf 'pin=%s\nsha256=%s\n' "$PIN" "$SHA" > "$tmp_dir/$MARKER_REL"

# PUBLISH transaction. Back up an existing dest (never deleted up front), atomic-rename the staged tree
# into place, restore the backup on any publish failure, and drop the backup ONLY after full success.
backup=""
if [ -e "$DEST" ]; then
	if [ -L "$DEST" ]; then echo "[fetch-qemu] destination is a symlink — refusing" >&2; exit 4; fi
	backup="$(mktemp -u "${parent}/${BACKUP_PREFIX}XXXXXX")"
	if ! mv -- "$DEST" "$backup"; then
		echo "[fetch-qemu] could not back up the existing install — refusing (prior install intact)" >&2
		exit 1
	fi
fi
if ! mv -- "$tmp_dir" "$DEST"; then
	echo "[fetch-qemu] publish rename FAILED — restoring the prior install" >&2
	if [ -n "$backup" ] && [ -d "$backup" ] && [ ! -L "$backup" ] && [ ! -e "$DEST" ]; then
		mv -- "$backup" "$DEST" || true
	fi
	exit 1
fi
tmp_dir=""                                   # published -> the trap must not remove it
if [ -n "$backup" ] && [ -e "$backup" ] && [ ! -L "$backup" ]; then rm -rf -- "$backup"; fi
if [ -n "${tmp_tb:-}" ]; then rm -f -- "$tmp_tb"; tmp_tb=""; fi
echo "[fetch-qemu] provisioned + verified $BIN"
