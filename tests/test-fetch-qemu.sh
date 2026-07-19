#!/usr/bin/env bash
#
# test-fetch-qemu.sh — deterministic, NETWORK-FREE tests for scripts/fetch-qemu.sh.
#
# The valid / verified-retry / partial-destination cases use a REAL pinned tarball supplied offline via
# LHPC_QEMU_TARBALL (or discovered in the ~/.espressif cache) — they exercise the exact verify → extract
# → version-check → publish → marker path that a network download would, minus the wget. They SKIP when
# no real tarball is available. The hash-mismatch and temp-cleanup cases always run (synthesized input).
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

if [ -n "$REAL" ] && [ -f "$REAL" ]; then
	d="$work/v/x"
	# valid (offline) input -> provisions + writes the completion marker
	if LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d" >/dev/null 2>&1 \
		&& [ -x "$d/qemu/bin/qemu-system-xtensa" ] && [ -f "$d/.lhpc-qemu-verified" ]; then
		pass "valid offline input provisions + writes marker"
	else
		bad "valid offline input"
	fi
	# valid verified retry -> SKIP (marker proves the pin)
	if LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d" 2>&1 | grep -q "already provisioned"; then
		pass "valid verified retry skips"
	else
		bad "valid verified retry did not skip"
	fi
	# partial pre-existing destination (bogus binary, NO marker) -> safely rebuilt
	rm -f "$d/.lhpc-qemu-verified"; echo '#!/bin/sh' > "$d/qemu/bin/qemu-system-xtensa"
	if LHPC_QEMU_TARBALL="$REAL" bash "$FETCH" "$d" >/dev/null 2>&1 && [ -f "$d/.lhpc-qemu-verified" ]; then
		pass "partial destination (no marker) is rebuilt"
	else
		bad "partial destination not rebuilt"
	fi
else
	echo "  skip: no real pinned tarball (set LHPC_QEMU_TARBALL) — valid/retry/partial cases skipped"
fi

# hash mismatch (synthesized) -> exit nonzero, nothing published
badtb="$work/bad.tar.xz"; head -c 4096 /dev/urandom > "$badtb"
d2="$work/m/x"
LHPC_QEMU_TARBALL="$badtb" bash "$FETCH" "$d2" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -e "$d2/qemu/bin/qemu-system-xtensa" ]; then
	pass "hash mismatch refuses (exit $rc), nothing published"
else
	bad "hash mismatch not fail-closed (exit $rc)"
fi
# no temp leftovers after a failed run
if [ "$(find "$work/m" \( -name '.qemu-tb.*' -o -name '.qemu-stage.*' \) 2>/dev/null | wc -l)" -eq 0 ]; then
	pass "no temp leftovers after failure"
else
	bad "temp leftovers after failure"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES" >&2; fi
exit "$fail"
