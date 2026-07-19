#!/usr/bin/env bash
#
# test-fetch-qemu.sh — deterministic, NETWORK-FREE tests for scripts/fetch-qemu.sh, including the
# concurrency correction (per-destination flock, atomic backup container, dest-scoped names).
#
# Cases needing a genuinely valid install use a REAL pinned tarball supplied offline via LHPC_QEMU_TARBALL
# (or discovered in the ~/.espressif cache) — they exercise the exact verify -> extract -> version-check ->
# stage -> publish path a network download would, minus wget, and SKIP when no real tarball is available.
# The mismatch / rename-failure / symlink / busy / scoped-cleanup cases always run.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH="$HERE/../scripts/fetch-qemu.sh"
PIN="esp_develop_9.0.0_20240606"
TBNAME="qemu-xtensa-softmmu-${PIN}-aarch64-linux-gnu.tar.xz"

fail=0
pass() { echo "  ok:   $1"; }
bad()  { echo "  FAIL: $1" >&2; fail=1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

REAL="${LHPC_QEMU_TARBALL:-}"
[ -n "$REAL" ] || REAL="$(find "$HOME/.espressif" -name "$TBNAME" 2>/dev/null | head -1)"
have_real=0; [ -n "$REAL" ] && [ -f "$REAL" ] && have_real=1

_provision() { LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$1" >/dev/null 2>&1; }
_valid()     { [ -x "$1/qemu/bin/qemu-system-xtensa" ] && [ -f "$1/.lhpc-qemu-verified" ]; }
_leftovers() {  # count THIS dest's scoped temps/staging/backups (the lock file is intentionally kept)
	local p n; p="$(dirname "$1")"; n="$(basename "$1")"
	find "$p" -maxdepth 1 \( -name ".qemu-tb.$n.*" -o -name ".qemu-stage.$n.*" -o -name ".qemu-backup.$n.*" \) 2>/dev/null | wc -l
}
# a `mv` that FAILS the publish rename (source is a *.qemu-stage.* staging dir), delegating all other mv
# (backup, restore) to the real mv — the controlled seam for "publication rename failure".
_failmv_bin() {
	local d="$1"; mkdir -p "$d"
	cat > "$d/mv" <<'EOS'
#!/usr/bin/env bash
args=(); for a in "$@"; do case "$a" in -*) ;; *) args+=("$a");; esac; done
n=${#args[@]}
if [ "$n" -ge 2 ]; then case "${args[$((n-2))]}" in *.qemu-stage.*) echo "fake mv: publish denied" >&2; exit 1;; esac; fi
exec /usr/bin/mv "$@"
EOS
	chmod +x "$d/mv"
}

if [ "$have_real" = 1 ]; then
	# 1. valid offline publication
	d="$work/pub/x"
	if _provision "$d" && _valid "$d"; then pass "valid offline publication"; else bad "valid offline publication"; fi

	# 2. verified retry -> skip
	if LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d" 2>&1 | grep -q "already provisioned"; then
		pass "verified retry skips"; else bad "verified retry did not skip"; fi

	# 3. partial destination reconstruction (bogus binary, NO marker)
	rm -f "$d/.lhpc-qemu-verified"; echo '#!/bin/sh' > "$d/qemu/bin/qemu-system-xtensa"
	if _provision "$d" && _valid "$d"; then pass "partial destination reconstructed"; else bad "partial not reconstructed"; fi

	# 7. preservation/restoration of an existing verified install when a rebuild's publish fails
	d7="$work/preserve/x"; _provision "$d7"; rm -f "$d7/.lhpc-qemu-verified"
	fb="$work/failbin"; _failmv_bin "$fb"
	PATH="$fb:$PATH" LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d7" >/dev/null 2>&1; rc=$?
	if [ "$rc" -ne 0 ] && [ -x "$d7/qemu/bin/qemu-system-xtensa" ] && [ "$(_leftovers "$d7")" -eq 0 ]; then
		pass "publish-failure preserves/restores prior install, no leftovers (rc $rc)"
	else bad "prior install not preserved (rc $rc, leftovers $(_leftovers "$d7"))"; fi

	# 8. backup LAYOUT + interrupted-transaction recovery: prior install lives at <container>/install
	d8="$work/recover/x"; _provision "$d8"
	c8="$(dirname "$d8")/.qemu-backup.x.crash"; mkdir -p "$c8"; mv "$d8" "$c8/install"   # simulate crash
	if [ ! -e "$d8" ] && _provision "$d8" && _valid "$d8" && [ ! -e "$c8" ] && [ "$(_leftovers "$d8")" -eq 0 ]; then
		pass "interrupted transaction recovered from <container>/install"
	else bad "interrupted transaction not recovered"; fi

	# 9. collision / pre-created object at a backup-like path -> transaction still succeeds, orphan cleaned
	d9="$work/collide/x"; mkdir -p "$(dirname "$d9")"
	mkdir -p "$(dirname "$d9")/.qemu-backup.x.precreated/install"; echo junk > "$(dirname "$d9")/.qemu-backup.x.precreated/install/junk"
	if _provision "$d9" && _valid "$d9" && [ "$(_leftovers "$d9")" -eq 0 ]; then
		pass "pre-created backup object tolerated (atomic mktemp -d), orphan cleaned"
	else bad "pre-created backup object broke the transaction"; fi

	# 10. two CONCURRENT invocations targeting the same destination -> both exit 0, dest valid, no leftovers
	d10="$work/concur/x"; mkdir -p "$(dirname "$d10")"
	LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d10" >/dev/null 2>&1 & p1=$!
	LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d10" >/dev/null 2>&1 & p2=$!
	wait "$p1"; r1=$?; wait "$p2"; r2=$?
	if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && _valid "$d10" && [ "$(_leftovers "$d10")" -eq 0 ]; then
		pass "two concurrent same-dest invocations both succeed (serialized), no leftovers"
	else bad "concurrent invocations raced (r1 $r1, r2 $r2, leftovers $(_leftovers "$d10"))"; fi

	# 11. cleanup NEVER deletes another invocation's live staging (a DIFFERENT dest under the same parent)
	base="$work/multi"; mkdir -p "$base"
	other="$base/.qemu-stage.y.live"; mkdir -p "$other"; echo live > "$other/marker"
	if _provision "$base/x" && _valid "$base/x" && [ -d "$other" ] && [ -f "$other/marker" ]; then
		pass "cleanup is dest-scoped — another dest's live staging untouched"
	else bad "cleanup removed another dest's staging"; fi
else
	echo "  skip: no real pinned tarball (set LHPC_QEMU_TARBALL) — publication/concurrency/recovery skipped"
fi

# 4. SHA mismatch -> exit nonzero, nothing published, no leftovers (always)
badtb="$work/bad.tar.xz"; head -c 4096 /dev/urandom > "$badtb"
d4="$work/m/x"
LHPC_QEMU_TARBALL="$badtb" bash "$FETCH" "$d4" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$d4/qemu/bin/qemu-system-xtensa" ] && [ "$(_leftovers "$d4")" -eq 0 ]; then
	pass "SHA mismatch refuses (exit $rc), nothing published, no leftovers"
else bad "SHA mismatch not fail-closed (exit $rc)"; fi

# 5. publication rename failure on a FRESH dest -> exit nonzero, DEST absent, no leftovers
if [ "$have_real" = 1 ]; then
	d5="$work/renamefail/x"; fb5="$work/failbin5"; _failmv_bin "$fb5"
	PATH="$fb5:$PATH" LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d5" >/dev/null 2>&1; rc=$?
	if [ "$rc" -ne 0 ] && [ ! -e "$d5/qemu/bin/qemu-system-xtensa" ] && [ "$(_leftovers "$d5")" -eq 0 ]; then
		pass "publication rename failure fails closed, no partial dest, no leftovers (rc $rc)"
	else bad "publication rename failure left partial state (rc $rc, leftovers $(_leftovers "$d5"))"; fi
fi

# 6. BUSY: a held per-dest lock + a short wait -> the second invocation returns a typed busy failure (5)
d6="$work/busy/x"; mkdir -p "$(dirname "$d6")"
lock="$(dirname "$d6")/.qemu-lock.$(basename "$d6")"; : > "$lock"
( flock 8; touch "$work/holder-ready"; sleep 3 ) 8>"$lock" &
holder=$!
for _ in $(seq 1 60); do [ -f "$work/holder-ready" ] && break; sleep 0.05; done
LHPC_QEMU_LOCK_WAIT=1 LHPC_QEMU_TARBALL="${REAL:-/dev/null}" bash "$FETCH" "$d6" >/dev/null 2>&1; rc=$?
wait "$holder" 2>/dev/null
if [ "$rc" -eq 5 ]; then pass "held lock -> second invocation returns typed BUSY (exit 5)"; else bad "busy path wrong (exit $rc)"; fi

# 12. symlink destination refusal -> exit 4, the symlink is untouched
d12="$work/sym"; mkdir -p "$d12"; ln -s /nonexistent-target "$d12/x"
LHPC_QEMU_TARBALL="${REAL:-/dev/null}" bash "$FETCH" "$d12/x" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 4 ] && [ -L "$d12/x" ] && [ "$(readlink "$d12/x")" = "/nonexistent-target" ]; then
	pass "symlink destination refused (exit 4), symlink untouched"
else bad "symlink destination not refused safely (rc $rc)"; fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES" >&2; fi
exit "$fail"
