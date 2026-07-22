#!/usr/bin/env bash
#
# test-build-qemu.sh — deterministic, NETWORK-FREE, COMPILE-FREE tests for scripts/build-qemu.sh and the
# shared scripts/lib-publish.sh transaction (lock / staging / backup / atomic-rename / rollback /
# startup-recovery). The QEMU clone+configure+compile is bypassed via the LHPC_QEMU_FAKE_BUILD seam,
# which stages a pre-populated install tree whose qemu-system-xtensa is a REAL compiled ELF stub — so
# the strip, ELF-RPATH check, link gate, marker hashing and bounded smoke all run for real against a
# genuine dynamic executable (only libc), in seconds.
#
# These are the SAME locking/publication/rollback/recovery CONTRACT cases that test-fetch-qemu.sh runs
# against fetch-qemu.sh's (independently-tested, unchanged) transaction — here exercising the shared
# lib-publish.sh that build-qemu.sh composes. Tools not invoked in FAKE mode (git clone / ninja / meson)
# are satisfied with PATH stubs; the real strip/readelf/ldd/sha256sum/timeout/flock are used.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$HERE/../scripts/build-qemu.sh"
GATE_CANDIDATES=(
	"$HERE/../../loraham-pi-control/lhpc/data/scripts/meshtastic-link-gate.sh"
	"${LHPC_LINK_GATE:-}"
)
GATE=""
for g in "${GATE_CANDIDATES[@]}"; do [ -n "$g" ] && [ -f "$g" ] && GATE="$g" && break; done

COMMIT="abb5ce24386972e048b401f9eca10e90b8427a20"
fail=0
pass() { echo "  ok:   $1"; }
bad()  { echo "  FAIL: $1" >&2; fail=1; }

if ! command -v gcc >/dev/null 2>&1; then
	echo "  skip: no gcc — build-qemu tests need a compiled ELF stub"; echo "ALL PASS"; exit 0; fi
if [ -z "$GATE" ]; then
	echo "  skip: link gate not found (set LHPC_LINK_GATE) — build-qemu tests skipped"; echo "ALL PASS"; exit 0; fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# ---- PATH stubs for tools not invoked in FAKE mode + a permissive pkg-config -------------------------
fb="$work/fakebin"; mkdir -p "$fb"
for t in ninja meson; do printf '#!/bin/sh\nexit 0\n' > "$fb/$t"; chmod +x "$fb/$t"; done
printf '#!/bin/sh\ncase "$1" in --exists) exit 0;; *) echo 1.0;; esac\n' > "$fb/pkg-config"; chmod +x "$fb/pkg-config"
export PATH="$fb:$PATH"

# ---- compiled ELF stubs standing in for qemu-system-xtensa ------------------------------------------
# GOOD: identifies as QEMU, lists the esp32 machine, and on the smoke launch sleeps so the outer timeout
# terminates it (a healthy long init). BADSMOKE: same identity, but the smoke launch prints a fatal
# loader line and exits nonzero (drives the smoke-failure -> restore-backup branch).
_mkstub() {  # $1=out  $2=smoke-mode(good|bad)
	local out="$1" mode="$2"
	cat > "$work/stub.c" <<EOF
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv){
  for(int i=1;i<argc;i++){
    if(!strcmp(argv[i],"--version")){printf("QEMU emulator version 9.0.0 (esp-develop-9.0.0-20240606)\\n");return 0;}
    if(!strcmp(argv[i],"-machine")&&i+1<argc&&!strcmp(argv[i+1],"help")){
      printf("Supported machines are:\\nnone\\nesp32                Espressif ESP32\\n");return 0;}
  }
  ${mode:+/* smoke */}
EOF
	if [ "$mode" = bad ]; then
		printf '  fprintf(stderr,"qemu-system-xtensa: cannot load machine\\n");return 1;\n}\n' >> "$work/stub.c"
	else
		printf '  sleep(60);return 0;\n}\n' >> "$work/stub.c"
	fi
	gcc "$work/stub.c" -o "$out"
}
GOODBIN="$work/qemu-good"; _mkstub "$GOODBIN" good
BADBIN="$work/qemu-bad";  _mkstub "$BADBIN"  bad

_mkfake() {  # $1=dir  $2=binsrc -> pre-populated install tree
	local d="$1"; mkdir -p "$d/qemu/bin" "$d/qemu/share"
	cp "$2" "$d/qemu/bin/qemu-system-xtensa"; echo data > "$d/qemu/share/x.dat"
}
FAKE_GOOD="$work/fake-good"; _mkfake "$FAKE_GOOD" "$GOODBIN"
FAKE_BAD="$work/fake-bad";   _mkfake "$FAKE_BAD"  "$BADBIN"

_bq() {  # $1=dest ; extra env passed by caller
	LHPC_QEMU_SMOKE_SECS="${LHPC_QEMU_SMOKE_SECS:-3}" \
	bash "$BUILD" "$1" --link-gate "$GATE" >"$work/out.log" 2>&1
}
_provision() { LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" _bq "$1"; }
_valid() { [ -x "$1/qemu/bin/qemu-system-xtensa" ] && [ -f "$1/.lhpc-qemu-built" ] \
	&& grep -qxF "source_commit=$COMMIT" "$1/.lhpc-qemu-built"; }
_leftovers() {  # THIS dest's scoped temps/staging/backups/work/smoke (the lock file is kept by design)
	local p n; p="$(dirname "$1")"; n="$(basename "$1")"
	find "$p" -maxdepth 1 \( -name ".pub-stage.$n.*" -o -name ".pub-backup.$n.*" \
		-o -name ".qemu-work.$n.*" -o -name ".qemu-smoke.$n.*" -o -name ".qemu-smokelog.$n.*" \) 2>/dev/null | wc -l
}

# 1. valid FAKE source-build publication
d="$work/pub/x"
if _provision "$d" && _valid "$d" && [ "$(_leftovers "$d")" -eq 0 ]; then
	pass "valid source-build publication (stripped ELF, gate, smoke, marker), no leftovers"
else bad "valid publication failed"; cat "$work/out.log" >&2; fi

# 2. verified retry -> idempotent skip
if _provision "$d" && grep -q "already source-built" "$work/out.log"; then
	pass "verified retry skips (idempotent)"; else bad "verified retry did not skip"; fi

# 3. changed binary -> rebuild (recomputed binary_sha mismatch)
echo "// tamper" >> "$d/qemu/bin/qemu-system-xtensa"
if _provision "$d" && _valid "$d" && [ "$(_leftovers "$d")" -eq 0 ]; then
	pass "changed binary triggers rebuild"; else bad "changed binary not rebuilt"; fi

# 4. changed config hash in the marker -> rebuild (marker no longer matches the canonical contract)
sed -i 's/^config_sha256=.*/config_sha256=deadbeef/' "$d/.lhpc-qemu-built"
if _provision "$d" && _valid "$d"; then
	pass "tampered config hash triggers rebuild"; else bad "tampered config hash not rebuilt"; fi

# 5. link-gate FAILURE -> refuse before publishing, no marker, prior (invalid) dest untouched, no leftovers
d5="$work/gatefail/x"; _mkfake "$d5" "$GOODBIN"; echo "sentinel" > "$d5/SENTINEL"   # present but NOT valid
gatestub="$work/gate-fail.sh"; printf '#!/bin/sh\necho "ERROR: forbidden" >&2\nexit 3\n' > "$gatestub"
LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" LHPC_QEMU_SMOKE_SECS=3 \
	bash "$BUILD" "$d5" --link-gate "$gatestub" >"$work/out.log" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && [ ! -f "$d5/.lhpc-qemu-built" ] && [ -f "$d5/SENTINEL" ] && [ "$(_leftovers "$d5")" -eq 0 ]; then
	pass "link-gate failure refuses (rc $rc), no marker, prior dest untouched, no leftovers"
else bad "link-gate failure not fail-closed (rc $rc, leftovers $(_leftovers "$d5"))"; fi

# 6. SMOKE failure on the published binary -> restore the prior install, no marker, no leftovers
d6="$work/smokefail/x"; _provision "$d6"           # a VALID prior install exists...
sed -i 's/^source_commit=.*/source_commit=stale/' "$d6/.lhpc-qemu-built"   # ...invalidated so no skip
echo "PRIOR" > "$d6/qemu/PRIOR"                     # tag the prior tree to prove restoration
LHPC_QEMU_FAKE_BUILD="$FAKE_BAD" LHPC_QEMU_SMOKE_SECS=3 \
	bash "$BUILD" "$d6" --link-gate "$GATE" >"$work/out.log" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q "fatal error on the published binary" "$work/out.log" \
		&& [ -f "$d6/qemu/PRIOR" ] && [ "$(_leftovers "$d6")" -eq 0 ]; then
	pass "smoke failure restores the prior install (rc $rc), no leftovers"
else bad "smoke-failure restore wrong (rc $rc, PRIOR present=$( [ -f "$d6/qemu/PRIOR" ] && echo y||echo n ))"; cat "$work/out.log" >&2; fi

# 7. interrupted-transaction recovery: dest ABSENT + a backup container holds a VALID install
d7="$work/recover/x"; _provision "$d7"
c7="$(dirname "$d7")/.pub-backup.x.crash"; mkdir -p "$c7"; mv "$d7" "$c7/install"    # simulate crash
if [ ! -e "$d7" ] && _provision "$d7" && _valid "$d7" && [ ! -e "$c7" ] && [ "$(_leftovers "$d7")" -eq 0 ]; then
	pass "interrupted transaction recovered from <container>/install"
else bad "interrupted transaction not recovered"; fi

# 8. POST-RENAME/PRE-MARKER crash: dest PRESENT but marker invalid + backup holds a VALID install ->
#    discard the un-verified dest and restore the known-good backup, then skip.
d8="$work/postrename/x"; _provision "$d8"
c8="$(dirname "$d8")/.pub-backup.x.win"; mkdir -p "$c8"; cp -a "$d8" "$c8/install"   # backup = the good install
rm -f "$d8/.lhpc-qemu-built"; echo "UNVERIFIED" > "$d8/UNVERIFIED"                    # dest present, not valid
if _provision "$d8" && _valid "$d8" && [ ! -f "$d8/UNVERIFIED" ] && [ ! -e "$c8" ] && [ "$(_leftovers "$d8")" -eq 0 ]; then
	pass "post-rename/pre-marker crash: un-verified dest discarded, backup restored"
else bad "post-rename recovery wrong (valid=$(_valid "$d8" && echo y||echo n))"; fi

# 9. two CONCURRENT invocations for the same dest -> both exit 0, dest valid, serialized, no leftovers
d9="$work/concur/x"; mkdir -p "$(dirname "$d9")"
LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" LHPC_QEMU_SMOKE_SECS=3 bash "$BUILD" "$d9" --link-gate "$GATE" >/dev/null 2>&1 & p1=$!
LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" LHPC_QEMU_SMOKE_SECS=3 bash "$BUILD" "$d9" --link-gate "$GATE" >/dev/null 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ] && _valid "$d9" && [ "$(_leftovers "$d9")" -eq 0 ]; then
	pass "two concurrent same-dest invocations both succeed (serialized), no leftovers"
else bad "concurrent invocations raced (r1 $r1, r2 $r2, leftovers $(_leftovers "$d9"))"; fi

# 10. BUSY: a held per-dest lock + a short wait -> the second invocation returns a typed busy failure (5)
d10="$work/busy/x"; mkdir -p "$(dirname "$d10")"
lock="$(dirname "$d10")/.pub-lock.$(basename "$d10")"; : > "$lock"
( flock 8; touch "$work/holder-ready"; sleep 3 ) 8>"$lock" & holder=$!
for _ in $(seq 1 60); do [ -f "$work/holder-ready" ] && break; sleep 0.05; done
LHPC_QEMU_LOCK_WAIT=1 LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" bash "$BUILD" "$d10" --link-gate "$GATE" >/dev/null 2>&1; rc=$?
wait "$holder" 2>/dev/null
if [ "$rc" -eq 5 ]; then pass "held lock -> second invocation returns typed BUSY (exit 5)"; else bad "busy path wrong (exit $rc)"; fi

# 11. symlink DESTINATION refused (exit 4), symlink untouched
d11="$work/sym"; mkdir -p "$d11"; ln -s /nonexistent-target "$d11/x"
LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" bash "$BUILD" "$d11/x" --link-gate "$GATE" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 4 ] && [ -L "$d11/x" ] && [ "$(readlink "$d11/x")" = "/nonexistent-target" ]; then
	pass "symlink destination refused (exit 4), symlink untouched"
else bad "symlink destination not refused safely (rc $rc)"; fi

# 12. symlink LOCK leaf refused (exit 4) WITHOUT modifying its target
d12="$work/locksym/x"; mkdir -p "$(dirname "$d12")"
tgt="$work/lock-target"; echo original > "$tgt"
ln -s "$tgt" "$(dirname "$d12")/.pub-lock.$(basename "$d12")"
LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" bash "$BUILD" "$d12" --link-gate "$GATE" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 4 ] && [ -L "$(dirname "$d12")/.pub-lock.$(basename "$d12")" ] && [ "$(cat "$tgt")" = "original" ]; then
	pass "symlink lock leaf refused (exit 4), target untouched"
else bad "symlink lock leaf not refused safely (rc $rc)"; fi

# 13. non-regular (directory) lock leaf refused (exit 4)
d13="$work/lockdir/x"; mkdir -p "$(dirname "$d13")/.pub-lock.$(basename "$d13")"
LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" bash "$BUILD" "$d13" --link-gate "$GATE" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 4 ]; then pass "non-regular (directory) lock leaf refused (exit 4)"; else bad "non-regular lock leaf not refused (rc $rc)"; fi

# 14. missing prerequisite (pkg-config capability) -> typed exit 3, nothing published
d14="$work/prereq/x"
pcfail="$work/pcfail"; mkdir -p "$pcfail"
printf '#!/bin/sh\ncase "$1" in --exists) exit 1;; *) echo 1.0;; esac\n' > "$pcfail/pkg-config"; chmod +x "$pcfail/pkg-config"
PATH="$pcfail:$PATH" LHPC_QEMU_FAKE_BUILD="$FAKE_GOOD" bash "$BUILD" "$d14" --link-gate "$GATE" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 3 ] && [ ! -e "$d14" ]; then pass "missing pkg-config capability -> typed exit 3, nothing published"; else bad "missing-prereq not typed (rc $rc)"; fi

# 15. cleanup is dest-scoped — another dest's live staging under the same parent is untouched
base="$work/multi"; mkdir -p "$base"
other="$base/.pub-stage.y.live"; mkdir -p "$other"; echo live > "$other/marker"
if _provision "$base/x" && _valid "$base/x" && [ -d "$other" ] && [ -f "$other/marker" ]; then
	pass "cleanup is dest-scoped — another dest's live staging untouched"
else bad "cleanup removed another dest's staging"; fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "FAILURES" >&2; fi
exit "$fail"
