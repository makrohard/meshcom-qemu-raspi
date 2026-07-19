#!/usr/bin/env bash
#
# test-fetch-qemu.sh — deterministic, NETWORK-FREE tests for scripts/fetch-qemu.sh.
#
# Cases that need a genuinely valid install use a REAL pinned tarball supplied offline via
# LHPC_QEMU_TARBALL (or discovered in the ~/.espressif cache) — they exercise the exact
# verify -> extract -> version-check -> stage -> publish path a network download would, minus the wget,
# and SKIP when no real tarball is available. The mismatch / rename-failure / symlink / cleanup cases
# always run (synthesized input + a controlled fake `mv` seam for the publish rename).
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

# A bin dir whose `mv` FAILS the publish rename (source is a *.qemu-stage.* staging dir), delegating
# every other mv (backup, restore) to the real mv — the controlled seam for "publication rename failure".
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

# count our sibling temp/backup leftovers under a dest's PARENT
_leftovers() {
	find "$(dirname "$1")" -maxdepth 1 \( -name '.qemu-tb.*' -o -name '.qemu-stage.*' -o -name '.qemu-backup.*' \) 2>/dev/null | wc -l
}

_provision() { LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$1" >/dev/null 2>&1; }

if [ "$have_real" = 1 ]; then
	# 1. valid offline publication
	d="$work/pub/x"
	if _provision "$d" && [ -x "$d/qemu/bin/qemu-system-xtensa" ] && [ -f "$d/.lhpc-qemu-verified" ]; then
		pass "valid offline publication"
	else bad "valid offline publication"; fi

	# 2. verified retry -> skip
	if LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d" 2>&1 | grep -q "already provisioned"; then
		pass "verified retry skips"
	else bad "verified retry did not skip"; fi

	# 3. partial destination reconstruction (bogus binary, NO marker)
	rm -f "$d/.lhpc-qemu-verified"; echo '#!/bin/sh' > "$d/qemu/bin/qemu-system-xtensa"
	if _provision "$d" && [ -f "$d/.lhpc-qemu-verified" ]; then
		pass "partial destination reconstructed"
	else bad "partial destination not reconstructed"; fi

	# 7. preservation/restoration of an existing verified install when a rebuild's publish fails
	d7="$work/preserve/x"; _provision "$d7"
	before="$(cat "$d7/.lhpc-qemu-verified")"
	rm -f "$d7/.lhpc-qemu-verified"          # invalidate marker so a rebuild is attempted...
	fb="$work/failbin"; _failmv_bin "$fb"
	PATH="$fb:$PATH" LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d7" >/dev/null 2>&1; rc=$?
	if [ "$rc" -ne 0 ] && [ -x "$d7/qemu/bin/qemu-system-xtensa" ] && [ "$(_leftovers "$d7")" -eq 0 ]; then
		pass "publish-failure preserves/restores the prior install, no leftovers (rc $rc)"
	else bad "prior install not preserved on publish failure (rc $rc, leftovers $(_leftovers "$d7"))"; fi

	# 8. interrupted-transaction recovery on the next run (DEST gone, a sibling backup present)
	d8="$work/recover/x"; _provision "$d8"
	mv "$d8" "$(dirname "$d8")/.qemu-backup.x.interrupted"     # simulate crash after backup-move
	if [ ! -e "$d8" ] && _provision "$d8" && [ -x "$d8/qemu/bin/qemu-system-xtensa" ] \
		&& [ "$(_leftovers "$d8")" -eq 0 ]; then
		pass "interrupted transaction recovered on next run"
	else bad "interrupted transaction not recovered"; fi
else
	echo "  skip: no real pinned tarball (set LHPC_QEMU_TARBALL) — publication/retry/preservation/recovery skipped"
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

# 9. symlink destination refusal -> exit 4, the symlink is untouched
d9dir="$work/sym"; mkdir -p "$d9dir"; ln -s /nonexistent-target "$d9dir/x"
LHPC_QEMU_TARBALL="${REAL:-/dev/null}" bash "$FETCH" "$d9dir/x" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 4 ] && [ -L "$d9dir/x" ] && [ "$(readlink "$d9dir/x")" = "/nonexistent-target" ]; then
	pass "symlink destination refused (exit 4), symlink untouched"
else bad "symlink destination not refused safely (rc $rc)"; fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES" >&2; fi
exit "$fail"
