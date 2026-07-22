#!/usr/bin/env bash
#
# lib-publish.sh — SHARED, CONCURRENCY-SAFE, TRANSACTIONAL destination-publication state machine.
#
# Sourced (never executed). Provides the lock / staging-parent / backup-container / atomic-rename /
# rollback / startup-recovery primitives that a provisioner composes to swap a verified install into a
# live destination without a torn state. Modelled byte-for-byte on the live-proven fetch-qemu.sh
# transaction; factored out so the build path (scripts/build-qemu.sh) and any future provisioner share
# ONE copy of the repo's trickiest code instead of two that would drift.
#
# The caller supplies:
#   * a destination directory (an install tree; the marker lives INSIDE it),
#   * a `_valid_install <root>` predicate (returns 0 iff <root> is a complete, verified install),
#   * a staged tree it has already built + verified under $PUB_PARENT using $PUB_STAGE_PREFIX.
#
# Exit-code convention (callers `exit` with these): 2 usage · 3 missing prerequisite · 4 symlink/
# non-regular path refusal · 5 busy (lock contended) · 1 any other failure.
#
# CONTRACT (what every consumer and the shared tests rely on):
#   pub_init             acquires a per-destination flock; refuses a symlink/non-regular dest or lock
#                        WITHOUT modifying it; exports PUB_PARENT / PUB_DNAME / PUB_STAGE_PREFIX /
#                        PUB_BACKUP_PREFIX; a contended lock returns busy (5) after LHPC_*_LOCK_WAIT s.
#   pub_startup_recovery recovers an interrupted publish: dest ABSENT + a backup container holds a
#                        _valid_install → restore it; dest PRESENT but NOT _valid_install while a backup
#                        holds a _valid_install (the post-rename/pre-marker crash window) → discard the
#                        un-verified dest and restore the known-good backup. Never sweeps, never blind-
#                        rebuilds, never drops a backup until the destination is a _valid_install.
#   pub_skip_if_valid    returns 0 iff the dest is already a _valid_install (caller then exits 0).
#   pub_backup           moves any existing dest into a fresh backup container (PUB_BACKUP set); refuses
#                        a symlink dest. No dest -> PUB_BACKUP="" (nothing to restore).
#   pub_rename <staged>  atomically renames the staged tree onto the dest; the backup (if any) is left
#                        intact for the caller to drop AFTER post-publish verification.
#   pub_restore_backup   removes a non-symlink dest if present, restores PUB_BACKUP/install -> dest, and
#                        drops the now-empty container ONLY when the restore is proven; on an unprovable
#                        restore the verified backup is RETAINED for a later run to recover.
#   pub_drop_backup      removes the backup container after the publish is fully verified.
#   pub_sweep_orphans    bounded cleanup of THIS destination's orphaned staging/backup dirs (lock held).

# ---- guard: this file is a library ------------------------------------------------------------------
if [ "${LIB_PUBLISH_SOURCED:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi
LIB_PUBLISH_SOURCED=1

pub_die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }
pub_need() { command -v "$1" >/dev/null 2>&1 || pub_die 3 "ERROR: ${PUB_TAG:-lib-publish} needs '$1' on PATH"; }

# pub_init <dest> [lock-wait-seconds] [tag]
# Sets: PUB_DEST PUB_PARENT PUB_DNAME PUB_STAGE_PREFIX PUB_BACKUP_PREFIX PUB_LOCK PUB_TAG
# Acquires a per-destination flock on fd 9. Refuses (without following/modifying) a symlink or
# non-regular dest/lock path.
pub_init() {
	PUB_DEST="${1:?pub_init needs a destination}"
	local wait="${2:-120}"
	PUB_TAG="${3:-lib-publish}"
	pub_need flock
	PUB_PARENT="$(dirname -- "$PUB_DEST")"
	PUB_DNAME="$(basename -- "$PUB_DEST")"
	PUB_STAGE_PREFIX=".pub-stage.${PUB_DNAME}."
	PUB_BACKUP_PREFIX=".pub-backup.${PUB_DNAME}."
	PUB_LOCK="${PUB_PARENT}/.pub-lock.${PUB_DNAME}"
	PUB_BACKUP=""

	if [ -L "$PUB_DEST" ]; then
		pub_die 4 "[$PUB_TAG] destination path is a symlink — refusing: $PUB_DEST"
	fi
	mkdir -p "$PUB_PARENT"

	# A planted lock leaf must not be followed or truncated: `> "$LOCK"` would follow a symlink and try
	# to truncate a non-regular object. Refuse a pre-existing symlink or non-regular lock WITHOUT
	# touching it; an absent path or a regular file is fine.
	if [ -L "$PUB_LOCK" ]; then
		pub_die 4 "[$PUB_TAG] lock path is a symlink — refusing (target untouched): $PUB_LOCK"
	fi
	if [ -e "$PUB_LOCK" ] && [ ! -f "$PUB_LOCK" ]; then
		pub_die 4 "[$PUB_TAG] lock path exists but is not a regular file — refusing: $PUB_LOCK"
	fi
	exec 9>"$PUB_LOCK" || pub_die 1 "[$PUB_TAG] cannot open lock $PUB_LOCK"
	if ! flock -w "$wait" 9; then
		pub_die 5 "[$PUB_TAG] another provisioning of $PUB_DEST is in progress — busy (waited ${wait}s)"
	fi
}

# pub_sweep_orphans — remove THIS destination's orphaned staging/backup dirs. Safe: the dest lock is
# held, so no concurrent same-dest invocation exists; other destinations use a different (dname-scoped)
# prefix. Never follows/removes a symlink at a glob head.
pub_sweep_orphans() {
	local g
	for g in "$PUB_PARENT/${PUB_STAGE_PREFIX}"* "$PUB_PARENT/${PUB_BACKUP_PREFIX}"*; do
		[ -e "$g" ] || [ -L "$g" ] || continue
		[ -L "$g" ] && continue
		rm -rf -- "$g"
	done
}

# pub_startup_recovery <valid_install_fn> — recover an interrupted publish before any new work.
pub_startup_recovery() {
	local valid="$1" _c
	if [ ! -e "$PUB_DEST" ]; then
		# dest absent: a backup container with a valid install is a pre-/mid-rename interruption.
		for _c in "$PUB_PARENT/${PUB_BACKUP_PREFIX}"*; do
			[ -d "$_c" ] && [ ! -L "$_c" ] || continue
			if [ -d "$_c/install" ] && [ ! -L "$_c/install" ] && "$valid" "$_c/install"; then
				if mv -- "$_c/install" "$PUB_DEST"; then rmdir -- "$_c" 2>/dev/null || true; return 0; fi
			fi
		done
		return 0
	fi
	# dest present. If it is already valid there is nothing to recover (skip handled by the caller).
	if [ ! -L "$PUB_DEST" ] && "$valid" "$PUB_DEST"; then return 0; fi
	# dest present but NOT valid (marker absent/invalid) — the post-rename/pre-marker crash window. If a
	# backup holds a valid install, DISCARD the un-verified dest and restore the known-good backup;
	# otherwise leave the dest for the caller's normal (idempotent) rebuild path.
	for _c in "$PUB_PARENT/${PUB_BACKUP_PREFIX}"*; do
		[ -d "$_c" ] && [ ! -L "$_c" ] || continue
		if [ -d "$_c/install" ] && [ ! -L "$_c/install" ] && "$valid" "$_c/install"; then
			if [ ! -L "$PUB_DEST" ]; then rm -rf -- "$PUB_DEST"; fi
			if [ ! -e "$PUB_DEST" ] && mv -- "$_c/install" "$PUB_DEST"; then
				rmdir -- "$_c" 2>/dev/null || true
				echo "[$PUB_TAG] recovered: discarded an un-verified destination and restored the prior verified install" >&2
				return 0
			fi
		fi
	done
	return 0
}

# pub_skip_if_valid <valid_install_fn> — 0 iff the dest is already a valid install.
pub_skip_if_valid() {
	local valid="$1"
	[ ! -L "$PUB_DEST" ] && "$valid" "$PUB_DEST"
}

# pub_backup — move any existing dest into a fresh backup container; sets PUB_BACKUP ("" if none).
pub_backup() {
	PUB_BACKUP=""
	[ -e "$PUB_DEST" ] || return 0
	if [ -L "$PUB_DEST" ]; then pub_die 4 "[$PUB_TAG] destination is a symlink — refusing: $PUB_DEST"; fi
	PUB_BACKUP="$(mktemp -d "${PUB_PARENT}/${PUB_BACKUP_PREFIX}XXXXXX")"
	if ! mv -- "$PUB_DEST" "$PUB_BACKUP/install"; then
		rmdir -- "$PUB_BACKUP" 2>/dev/null || true
		PUB_BACKUP=""
		pub_die 1 "[$PUB_TAG] could not back up the existing install — refusing (prior install intact)"
	fi
}

# pub_rename <staged> — atomically publish the staged tree onto the dest. The backup is NOT dropped
# here; the caller drops it after post-publish verification. Returns nonzero on rename failure (dest
# stays absent; caller restores the backup).
pub_rename() {
	local staged="$1"
	mv -- "$staged" "$PUB_DEST"
}

# pub_restore_backup — remove a non-symlink dest if present, restore PUB_BACKUP/install -> dest, and
# drop the now-empty container ONLY when the restore is proven. On an unprovable restore the verified
# backup is RETAINED (intact) for a later run to recover, and the function returns nonzero.
pub_restore_backup() {
	[ -n "$PUB_BACKUP" ] || return 0
	if [ -e "$PUB_DEST" ] && [ ! -L "$PUB_DEST" ]; then rm -rf -- "$PUB_DEST"; fi
	if [ -d "$PUB_BACKUP/install" ] && [ ! -L "$PUB_BACKUP/install" ] && [ ! -e "$PUB_DEST" ] \
			&& mv -- "$PUB_BACKUP/install" "$PUB_DEST"; then
		rmdir -- "$PUB_BACKUP" 2>/dev/null || true
		PUB_BACKUP=""
		echo "[$PUB_TAG] prior install RESTORED to $PUB_DEST" >&2
		return 0
	fi
	echo "[$PUB_TAG] RESTORE FAILED — the prior verified installation is RETAINED (intact) at:" >&2
	echo "[$PUB_TAG]   ${PUB_BACKUP}/install" >&2
	echo "[$PUB_TAG]   re-run the provisioner for ${PUB_DEST} to recover it." >&2
	return 1
}

# pub_drop_backup — remove the backup container after a fully-verified publish.
pub_drop_backup() {
	[ -n "$PUB_BACKUP" ] || return 0
	rm -rf -- "$PUB_BACKUP"
	PUB_BACKUP=""
}
