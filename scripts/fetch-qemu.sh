#!/usr/bin/env bash
#
# fetch-qemu.sh — CONCURRENCY-SAFE, TRANSACTIONAL provisioning of the pinned Espressif qemu-system-xtensa
# into a target directory, sha256-VERIFIED and FAIL-CLOSED. Managed provisioning step (lhpc calls it with
# an in-root {root}/build/tool-cache/... dest). run.sh keeps --qemu > PATH > IDF_TOOLS_PATH for standalone.
#
#   fetch-qemu.sh <dest-dir> [--from-file <tarball>]
#
# A PER-DESTINATION flock serializes the ENTIRE transaction (recovery, validation, staging, publication,
# rollback, cleanup), so concurrent invocations for the same dest never race. A second invocation waits up
# to LHPC_QEMU_LOCK_WAIT seconds (default 120), then returns a typed BUSY failure (exit 5). Every temp,
# staging, backup and lock name is SCOPED TO THE DESTINATION, so cleanup never removes a path owned by
# another destination or another live invocation.
#
# Transaction: fetch to a unique temp file -> verify the pinned SHA-256 BEFORE extraction -> extract to a
# temp dir -> verify the expected binary AND the pinned version -> write the completion MARKER into the
# staged tree -> ATOMICALLY reserve a unique backup CONTAINER (`mktemp -d`) and move any existing install
# to its fixed child `<container>/install` -> atomic-rename the staged tree into place -> on any publish
# failure RESTORE `<container>/install` -> drop the backup only after full success. A later run RECOVERS an
# interruption (DEST absent but a backup container holds a VALID `<container>/install`). dest/staging/backup
# are inspected lstat-style; a symlink supplied in their place is refused, never followed or removed.
# Offline: LHPC_QEMU_TARBALL / --from-file, hash-verified. aarch64 prebuild is correct for a Zero 2W AND Pi 5.
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
need flock

BIN_REL="qemu/bin/qemu-system-xtensa"
BIN="$DEST/$BIN_REL"
MARKER_REL=".lhpc-qemu-verified"
MARKER="$DEST/$MARKER_REL"
parent="$(dirname -- "$DEST")"
dname="$(basename -- "$DEST")"
TB_PREFIX=".qemu-tb.${dname}."
STAGE_PREFIX=".qemu-stage.${dname}."
BACKUP_PREFIX=".qemu-backup.${dname}."
LOCK="${parent}/.qemu-lock.${dname}"

# Fast pre-lock refusal of a symlinked destination (never followed/removed); re-checked under the lock.
if [ -L "$DEST" ]; then
	echo "[fetch-qemu] destination path is a symlink — refusing: $DEST" >&2
	exit 4
fi
mkdir -p "$parent"

# ---- PER-DESTINATION SERIALIZATION (covers recovery, validation, staging, publish, rollback, cleanup) --
# Fail closed on a planted lock leaf: `> "$LOCK"` would FOLLOW a symlink (redirecting the lock elsewhere)
# and would try to truncate a non-regular object. Refuse a pre-existing symlink or non-regular lock path
# WITHOUT modifying it; a regular file or an absent path is fine (flock serialization is unchanged).
if [ -L "$LOCK" ]; then
	echo "[fetch-qemu] lock path is a symlink — refusing (target untouched): $LOCK" >&2
	exit 4
fi
if [ -e "$LOCK" ] && [ ! -f "$LOCK" ]; then
	echo "[fetch-qemu] lock path exists but is not a regular file — refusing: $LOCK" >&2
	exit 4
fi
exec 9>"$LOCK" || { echo "[fetch-qemu] cannot open lock $LOCK" >&2; exit 1; }
LOCK_WAIT="${LHPC_QEMU_LOCK_WAIT:-120}"
if ! flock -w "$LOCK_WAIT" 9; then
	echo "[fetch-qemu] another provisioning of $DEST is in progress — busy (waited ${LOCK_WAIT}s)" >&2
	exit 5
fi

# A directory is a VALID install iff it holds the exact pin+sha marker and a non-symlink executable binary.
_valid_install() {
	local root="$1"
	[ -f "$root/$MARKER_REL" ] && [ ! -L "$root/$MARKER_REL" ] || return 1
	grep -qxF "pin=${PIN}" "$root/$MARKER_REL" && grep -qxF "sha256=${SHA}" "$root/$MARKER_REL" || return 1
	[ -f "$root/$BIN_REL" ] && [ ! -L "$root/$BIN_REL" ] && [ -x "$root/$BIN_REL" ]
}

# Bounded cleanup of THIS destination's orphaned temps/staging/backups. Safe: the dest lock is held, so no
# concurrent same-dest invocation exists; other destinations use a different (dname-scoped) prefix. Never a
# symlink.
sweep_orphans() {
	local g
	for g in "$parent/${TB_PREFIX}"* "$parent/${STAGE_PREFIX}"* "$parent/${BACKUP_PREFIX}"*; do
		if [ ! -e "$g" ] && [ ! -L "$g" ]; then continue; fi
		if [ -L "$g" ]; then continue; fi
		rm -rf -- "$g"
	done
}

# RECOVER an interrupted transaction: DEST absent but a backup container holds a VALID install.
if [ ! -e "$DEST" ]; then
	for _c in "$parent/${BACKUP_PREFIX}"*; do
		if [ ! -d "$_c" ] || [ -L "$_c" ]; then continue; fi
		if [ -d "$_c/install" ] && [ ! -L "$_c/install" ] && _valid_install "$_c/install"; then
			if mv -- "$_c/install" "$DEST"; then rmdir -- "$_c" 2>/dev/null || true; break; fi
		fi
	done
fi

# SKIP when DEST is already a valid install.
if [ ! -L "$DEST" ] && _valid_install "$DEST"; then
	sweep_orphans
	echo "[fetch-qemu] already provisioned + verified: $BIN"
	exit 0
fi

# ---- STAGE (temp tarball + temp dir, both scoped to the dest) ----
tmp_tb=""; tmp_dir=""
cleanup() {
	if [ -n "${tmp_tb:-}" ] && [ ! -L "$tmp_tb" ]; then rm -f -- "$tmp_tb"; fi
	if [ -n "${tmp_dir:-}" ] && [ ! -L "$tmp_dir" ]; then rm -rf -- "$tmp_dir"; fi
	return 0
}
trap cleanup EXIT
tmp_tb="$(mktemp "${parent}/${TB_PREFIX}XXXXXX")"
tmp_dir="$(mktemp -d "${parent}/${STAGE_PREFIX}XXXXXX")"

if [ -n "$FROM_FILE" ]; then
	echo "[fetch-qemu] using local tarball: $FROM_FILE"
	[ -f "$FROM_FILE" ] || { echo "ERROR: --from-file/LHPC_QEMU_TARBALL not found: $FROM_FILE" >&2; exit 1; }
	cp -- "$FROM_FILE" "$tmp_tb"
else
	need wget
	echo "[fetch-qemu] downloading $URL"
	wget -O "$tmp_tb" "$URL"
fi

if ! printf '%s  %s\n' "$SHA" "$tmp_tb" | sha256sum -c - >/dev/null 2>&1; then
	echo "[fetch-qemu] sha256 MISMATCH — refusing (source: ${FROM_FILE:-$URL})" >&2
	exit 1
fi

tar -xJf "$tmp_tb" -C "$tmp_dir"
staged_bin="$tmp_dir/$BIN_REL"
if [ ! -f "$staged_bin" ] || [ -L "$staged_bin" ] || [ ! -x "$staged_bin" ]; then
	echo "[fetch-qemu] expected binary missing/invalid after unpack: $BIN_REL" >&2
	exit 1
fi
# Prove the extracted binary actually RUNS and is the pinned build. The failure text must be HONEST:
# the sha256 already matched above, so a `--version` failure here is almost always a MISSING SHARED
# LIBRARY on a headless box (the prebuilt Espressif binary hard-links libSDL2), NOT a wrong build.
# Capture the loader error (do NOT discard stderr) and, if the loader named an unresolved library,
# report THAT — a misleading "not the pinned build" sent operators hunting a non-existent pin mismatch.
ver_out="$("$staged_bin" --version 2>&1)" || ver_rc=$?
ver_rc="${ver_rc:-0}"
if ! printf '%s' "$ver_out" | grep -qF "$PIN"; then
	missing=""
	# Loader message: "error while loading shared libraries: libFOO.so: cannot open shared object file"
	missing="$(printf '%s\n' "$ver_out" | sed -n 's/.*loading shared libraries: \([^:]*\):.*/\1/p' | head -1)"
	if [ -z "$missing" ] && command -v ldd >/dev/null 2>&1; then
		missing="$(ldd "$staged_bin" 2>/dev/null | awk '/=> not found/{print $1}' | tr '\n' ' ')"
	fi
	if [ -n "$missing" ]; then
		echo "[fetch-qemu] the sha256-verified prebuilt qemu cannot load shared libraries: ${missing}" >&2
		echo "[fetch-qemu] this prebuilt binary links a display/audio stack absent on a headless box." >&2
		echo "[fetch-qemu] use the source-built emulator (scripts/build-qemu.sh) instead of this tarball." >&2
	else
		echo "[fetch-qemu] extracted qemu did not report the pinned build ${PIN} (rc=${ver_rc}); output:" >&2
		printf '%s\n' "$ver_out" | sed 's/^/  /' >&2
	fi
	exit 1
fi
printf 'pin=%s\nsha256=%s\n' "$PIN" "$SHA" > "$tmp_dir/$MARKER_REL"

# ---- PUBLISH: atomically reserve a backup CONTAINER, move any existing install to <container>/install,
#      atomic-rename the staged tree into place, restore on failure, drop the backup only after success. --
backup=""
if [ -e "$DEST" ]; then
	if [ -L "$DEST" ]; then echo "[fetch-qemu] destination is a symlink — refusing" >&2; exit 4; fi
	backup="$(mktemp -d "${parent}/${BACKUP_PREFIX}XXXXXX")"
	if ! mv -- "$DEST" "$backup/install"; then
		echo "[fetch-qemu] could not back up the existing install — refusing (prior install intact)" >&2
		rmdir -- "$backup" 2>/dev/null || true
		exit 1
	fi
fi
if ! mv -- "$tmp_dir" "$DEST"; then
	echo "[fetch-qemu] publish rename FAILED for $DEST" >&2
	if [ -n "$backup" ]; then
		# Restore the prior install and CHECK the result EXPLICITLY (never suppress with `|| true`). The
		# backup container is removed ONLY when restoration is proven — otherwise the verified install is
		# RETAINED at <container>/install for a later run to recover.
		if [ -d "$backup/install" ] && [ ! -L "$backup/install" ] && [ ! -e "$DEST" ] \
				&& mv -- "$backup/install" "$DEST"; then
			echo "[fetch-qemu] prior install RESTORED to $DEST" >&2
			rmdir -- "$backup" 2>/dev/null || true      # remove ONLY the now-empty container
		else
			echo "[fetch-qemu] RESTORE FAILED — the prior verified installation is RETAINED (intact) at:" >&2
			echo "[fetch-qemu]   ${backup}/install" >&2
			echo "[fetch-qemu]   re-run this script for ${DEST} to recover it." >&2
			exit 1
		fi
	fi
	exit 1
fi
tmp_dir=""                                   # published -> the trap must not remove it
if [ -n "$backup" ]; then rm -rf -- "$backup"; fi
if [ -n "${tmp_tb:-}" ]; then rm -f -- "$tmp_tb"; tmp_tb=""; fi
sweep_orphans
echo "[fetch-qemu] provisioned + verified $BIN"
