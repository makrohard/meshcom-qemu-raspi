#!/usr/bin/env bash
#
# test-node-efuse.sh — deterministic tests for scripts/node-efuse.sh and run.sh's use of it (P2.1: every emulated
# node had MAC 0 and node ID 0, so all nodes numbered their messages in one range). No QEMU, no network: the file
# layout is checked against fixed vectors (the two images booted in the local QEMU prototype, 2026-09-27), and
# run.sh is exercised with a stub QEMU that records its arguments.
#
# EXIT CODES: 0 = all cases passed (prints ALL PASS) · 1 = a failure (prints FAILURES).
# Each check is an eval'd string, so its variables look unexpanded/unused to shellcheck.
# shellcheck disable=SC2016,SC2034,SC2329
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
NE="$REPO/scripts/node-efuse.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hex()  { od -An -tx1 -v "$1" | tr -d ' \n'; }
zeros() { printf '%0*d' "$1" 0; }

echo "== layout: fixed MACs give the booted prototype images byte for byte"
# 124 bytes; word 1 = mac[5..2], word 2 = mac[1] mac[0] crc8 0; everything else zero.
NODE_EFUSE_MAC=1a:64:34:f3:0e:79 "$NE" "$T/e1.bin" >/dev/null
NODE_EFUSE_MAC=3e:cc:10:e4:13:23 "$NE" "$T/e2.bin" >/dev/null
check "E1 (crc 0x0d, node ID 34F30E79 in QEMU)" '[ "$(hex "$T/e1.bin")" = "00000000790ef334641a0d00$(zeros 224)" ]'
check "E2 (crc 0xe4, node ID 10E41323 in QEMU)" '[ "$(hex "$T/e2.bin")" = "000000002313e410cc3ee400$(zeros 224)" ]'

echo "== a random file"
"$NE" "$T/n/node-efuse.bin" > "$T/out1"
H="$(hex "$T/n/node-efuse.bin")"
check "is 124 bytes" '[ "$(stat -c %s "$T/n/node-efuse.bin")" = 124 ]'
check "is owner-only (0600)" '[ "$(stat -c %a "$T/n/node-efuse.bin")" = 600 ]'
check "is zero outside the MAC and its CRC (bytes 0-3, 11-123)" '[ "${H:0:8}" = 00000000 ] && [ "${H:22}" = "$(zeros 226)" ]'
m0=$(( 16#${H:18:2} ))
check "has a locally administered, unicast MAC" '[ $(( m0 & 3 )) = 2 ]'
crc8() { local c=0 b _; for b in "$@"; do c=$(( c ^ b )); for _ in 1 2 3 4 5 6 7 8; do if (( c & 1 )); then c=$(( (c >> 1) ^ 0x8C )); else c=$(( c >> 1 )); fi; done; done; echo "$c"; }
mac=( $(( 16#${H:18:2} )) $(( 16#${H:16:2} )) $(( 16#${H:14:2} )) $(( 16#${H:12:2} )) $(( 16#${H:10:2} )) $(( 16#${H:8:2} )) )
check "carries the right CRC8 for its MAC" '[ "$(crc8 "${mac[@]}")" = $(( 16#${H:20:2} )) ]'
check "says it was created" 'grep -q "node efuse: created" "$T/out1"'
"$NE" "$T/n2/node-efuse.bin" >/dev/null
check "two nodes get different MACs" '[ "$(hex "$T/n/node-efuse.bin")" != "$(hex "$T/n2/node-efuse.bin")" ]'

echo "== an existing file is kept; a wrong one is refused, not replaced"
before="$(sha256sum < "$T/n/node-efuse.bin")"
"$NE" "$T/n/node-efuse.bin" > "$T/out2"
check "a present file is used as it is" '[ "$(sha256sum < "$T/n/node-efuse.bin")" = "$before" ] && grep -q "node efuse: kept" "$T/out2"'
head -c 100 /dev/zero > "$T/bad.bin"
"$NE" "$T/bad.bin" > "$T/out3" 2>&1; rc=$?
check "a file of the wrong size fails" '[ "$rc" != 0 ] && grep -q "expected 124" "$T/out3"'
check "and is left untouched" '[ "$(stat -c %s "$T/bad.bin")" = 100 ]'
cp "$T/e1.bin" "$T/badcrc.bin"; printf '\xf2' | dd of="$T/badcrc.bin" bs=1 seek=10 conv=notrunc status=none
bc="$(sha256sum < "$T/badcrc.bin")"
"$NE" "$T/badcrc.bin" > "$T/out4" 2>&1; rc=$?
check "a file with a wrong MAC CRC fails, untouched" '[ "$rc" != 0 ] && grep -q "wrong MAC CRC" "$T/out4" && [ "$(sha256sum < "$T/badcrc.bin")" = "$bc" ]'
head -c 124 /dev/zero > "$T/zero.bin"
"$NE" "$T/zero.bin" > "$T/out5" 2>&1; rc=$?
check "an all-zero file (valid CRC 0, prefix 0 = the old ID 0) fails" '[ "$rc" != 0 ] && grep -q "prefix 0" "$T/out5"'
cp "$T/e1.bin" "$T/ro.bin"; chmod 0400 "$T/ro.bin"; rs="$(sha256sum < "$T/ro.bin")"
"$NE" "$T/ro.bin" > "$T/out7" 2>&1; rc=$?
check "a read-only file fails (QEMU needs to write it), untouched" '[ "$rc" != 0 ] && grep -q "readable and writable" "$T/out7" && [ "$(sha256sum < "$T/ro.bin")" = "$rs" ] && [ "$(stat -c %a "$T/ro.bin")" = 400 ]'
NODE_EFUSE_MAC=02:00:00:c0:00:00 "$NE" "$T/zp.bin" > "$T/out6" 2>&1; rc=$?
check "a MAC whose 22-bit id prefix is 0 is refused (only mac[3] bits 7-6 set)" '[ "$rc" != 0 ] && [ ! -e "$T/zp.bin" ]'
rm -rf "$T/n"; "$NE" "$T/n/node-efuse.bin" >/dev/null
check "a deleted node state gives a new MAC (purge)" '[ "$(sha256sum < "$T/n/node-efuse.bin")" != "$before" ]'

echo "== run.sh attaches the file"
R="$T/repo"; mkdir -p "$R/scripts" "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless"
cp "$REPO/scripts/run.sh" "$REPO/scripts/node-image.sh" "$NE" "$R/scripts/"
head -c $((4 * 1024 * 1024)) /dev/zero > "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless/flash.bin"
cat > "$T/qemu-stub" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "QEMU emulator version 9.2.2"; exit 0; }
printf '%s\n' "$@" > "$QEMU_STUB_ARGS"
STUB
chmod +x "$T/qemu-stub"
export QEMU_STUB_ARGS="$T/qemu-args"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/lhpc/node-flash.bin" > "$T/run1.out" 2>&1
for _ in $(seq 50); do [ -s "$QEMU_STUB_ARGS" ] && break; sleep 0.1; done
check "the node image's efuse (<image>.efuse) is created" '[ -s "$T/lhpc/node-flash.bin.efuse" ]'
check "attached as QEMU's efuse drive" 'grep -qx "file=$T/lhpc/node-flash.bin.efuse,if=none,format=raw,id=efuse" "$QEMU_STUB_ARGS" && grep -qx "driver=nvram.esp32.efuse,property=drive,value=efuse" "$QEMU_STUB_ARGS"'
check "exactly one efuse -drive and one efuse -global" '[ "$(grep -c ",id=efuse$" "$QEMU_STUB_ARGS")" = 1 ] && [ "$(grep -c "^driver=nvram.esp32.efuse," "$QEMU_STUB_ARGS")" = 1 ]'
rm -f "$QEMU_STUB_ARGS"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/lhpc/other-node.bin" > "$T/run2.out" 2>&1
for _ in $(seq 50); do [ -s "$QEMU_STUB_ARGS" ] && break; sleep 0.1; done
check "a second node image in the same directory gets its own efuse" 'grep -qx "file=$T/lhpc/other-node.bin.efuse,if=none,format=raw,id=efuse" "$QEMU_STUB_ARGS" && [ "$(sha256sum < "$T/lhpc/other-node.bin.efuse")" != "$(sha256sum < "$T/lhpc/node-flash.bin.efuse")" ]'
rm -f "$QEMU_STUB_ARGS"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/lhpc/node-flash.bin" --node-efuse "$T/x.bin" > "$T/run3.out" 2>&1; rc=$?
check "there is no --node-efuse option (LHPC passes only --node-image)" '[ "$rc" = 2 ] && grep -q "unknown argument: --node-efuse" "$T/run3.out"'

if [ "$FAILS" = 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $FAILS"; exit 1; fi
