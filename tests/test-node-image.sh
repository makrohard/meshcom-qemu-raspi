#!/usr/bin/env bash
#
# test-node-image.sh — deterministic tests for scripts/node-image.sh and run.sh's use of it (finding R21:
# every rebuild or update replaced the flash image QEMU ran on, so the node lost all its settings and its
# message-id counter). Synthetic 4 MB images, no QEMU, no network. run.sh is exercised with a stub QEMU
# that records its arguments.
#
# EXIT CODES: 0 = all cases passed (prints ALL PASS) · 1 = a failure (prints FAILURES).
# Each check is an eval'd string, so its variables look unexpanded/unused to shellcheck.
# shellcheck disable=SC2016,SC2034
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."
NI="$REPO/scripts/node-image.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
FAILS=0
ok()   { echo "  ok   $1"; }
bad()  { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SECTOR=4096
# region FILE BLOCK COUNT -> sha256 of that range
region() { dd if="$1" bs=$SECTOR skip="$2" count="$3" status=none | sha256sum | cut -d' ' -f1; }
# fill FILE BLOCK COUNT BYTE -> overwrite that range with one byte value
fill() { head -c $(( $3 * SECTOR )) /dev/zero | tr '\0' "$4" | dd of="$1" bs=$SECTOR seek="$2" conv=notrunc status=none; }
# image FILE APPBYTE PTBYTE -> 4 MB image: partition table sector (block 8) = PTBYTE, NVS (9-13) = 0xFF
# (erased), app region (block 16..) = APPBYTE.
image() {
	head -c $((4 * 1024 * 1024)) /dev/zero > "$1"
	fill "$1" 8 1 "$3"; fill "$1" 9 5 '\377'; fill "$1" 16 16 "$2"
}

echo "== node-image.sh"

# 1. first start: no node image -> a copy of the build, sidecar written.
image "$T/build1.bin" 'A' 'P'
N="$T/state/node-flash.bin"
out="$("$NI" "$T/build1.bin" "$N")"
check "first start creates the node image as a copy of the build" 'cmp -s "$T/build1.bin" "$N"'
check "first start writes the sidecar" '[ "$(cat "$N.build-sha256")" = "$(sha256sum "$T/build1.bin" | cut -d" " -f1)" ]'
check "first start logs it" 'printf "%s" "$out" | grep -q "created from the build"'
chmod 644 "$T/build1.bin"
check "the node image is readable by its owner only" '[ "$(stat -c %a "$N")" = 600 ]'

# The node runs: its settings (NVS) change.
fill "$N" 9 2 'S'
NODE_NVS="$(region "$N" 9 5)"

# 2. unchanged build: the node image is left as it is (settings survive, no rewrite).
before="$(sha256sum "$N" | cut -d' ' -f1)"
out="$("$NI" "$T/build1.bin" "$N")"
check "unchanged build leaves the node image byte-identical" '[ "$(sha256sum "$N" | cut -d" " -f1)" = "$before" ]'
check "unchanged build keeps no previous image" '[ ! -e "$N.prev" ]'
check "unchanged build logs it" 'printf "%s" "$out" | grep -q "unchanged build"'

# 3. changed build, same partition table: new firmware + the old NVS.
image "$T/build2.bin" 'B' 'P'
OLD_NODE="$(sha256sum "$N" | cut -d' ' -f1)"
out="$("$NI" "$T/build2.bin" "$N")"
check "changed build carries the node's NVS (0x9000-0xDFFF)" '[ "$(region "$N" 9 5)" = "$NODE_NVS" ]'
check "changed build takes the firmware from the new build" '[ "$(region "$N" 16 16)" = "$(region "$T/build2.bin" 16 16)" ]'
check "changed build takes the partition table from the new build" '[ "$(region "$N" 8 1)" = "$(region "$T/build2.bin" 8 1)" ]'
check "changed build keeps the previous node image as .prev" '[ "$(sha256sum "$N.prev" | cut -d" " -f1)" = "$OLD_NODE" ]'
check "changed build updates the sidecar" '[ "$(cat "$N.build-sha256")" = "$(sha256sum "$T/build2.bin" | cut -d" " -f1)" ]'
check "changed build logs the carry" 'printf "%s" "$out" | grep -q "settings carried over"'
check "no temp files are left" '[ -z "$(ls "$T/state" | grep -E "\.(tmp|new)\.")" ]'

# 4. crash after the image, before the sidecar: new image + old sidecar -> the next start carries again
#    from that image and gives the same image (idempotent).
fill "$N" 10 1 'T'                                    # the node ran on after the carry
image "$T/build3.bin" 'C' 'P'
"$NI" "$T/build3.bin" "$N" >/dev/null
AFTER_CARRY="$(sha256sum "$N" | cut -d' ' -f1)"
printf '%s\n' "$(sha256sum "$T/build2.bin" | cut -d' ' -f1)" > "$N.build-sha256"   # simulate the crash
"$NI" "$T/build3.bin" "$N" >/dev/null
check "a crash before the sidecar: the next start carries again to the same image" '[ "$(sha256sum "$N" | cut -d" " -f1)" = "$AFTER_CARRY" ]'
check "exactly one previous image is kept" '[ "$(ls "$T/state" | grep -c "\.prev")" = 1 ]'

# 5. different partition table: the new build alone, settings reset, said once.
image "$T/build4.bin" 'D' 'Q'
out="$("$NI" "$T/build4.bin" "$N")"
check "a different partition table gives the new build alone" 'cmp -s "$T/build4.bin" "$N"'
check "a different partition table is logged as a reset" 'printf "%s" "$out" | grep -q "settings RESET"'

# 6. a node image without a sidecar (e.g. made by hand) is treated as changed and carried.
image "$T/build5.bin" 'E' 'Q'
rm -f "$N.build-sha256"; fill "$N" 9 1 'U'; NVS6="$(region "$N" 9 5)"
"$NI" "$T/build5.bin" "$N" >/dev/null
check "a missing sidecar carries the node's NVS" '[ "$(region "$N" 9 5)" = "$NVS6" ]'

echo "== run.sh boots the node image, not the build output"
R="$T/repo"; mkdir -p "$R/scripts" "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless"
cp "$REPO/scripts/run.sh" "$REPO/scripts/node-image.sh" "$REPO/scripts/node-efuse.sh" "$R/scripts/"
image "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless/flash.bin" 'A' 'P'
cat > "$T/qemu-stub" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "QEMU emulator version 9.2.2"; exit 0; }
printf '%s\n' "$@" > "$QEMU_STUB_ARGS"
EOF
chmod +x "$T/qemu-stub"
export QEMU_STUB_ARGS="$T/qemu-args"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/lhpc-state/node-flash.bin" > "$T/run.out" 2>&1
check "run.sh with --node-image boots that image" 'grep -qx "file=$T/lhpc-state/node-flash.bin,if=mtd,format=raw" "$QEMU_STUB_ARGS"'
check "run.sh never boots the build output" '[ -s "$QEMU_STUB_ARGS" ] && ! grep -q "/.pio/build/" "$QEMU_STUB_ARGS"'
check "run.sh prepared the node image" '[ -f "$T/lhpc-state/node-flash.bin" ] && [ -f "$T/lhpc-state/node-flash.bin.build-sha256" ]'
rm -f "$QEMU_STUB_ARGS"
"$R/scripts/run.sh" --qemu "$T/qemu-stub" > "$T/run2.out" 2>&1
check "run.sh without --node-image uses the repo's .state/node-flash.bin" 'grep -qx "file=$R/.state/node-flash.bin,if=mtd,format=raw" "$QEMU_STUB_ARGS"'

# A second run.sh while a guest holds the node image must refuse, before touching the image.
python3 -c 'import fcntl, sys, time; f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(30)' \
	"$T/lhpc-state/node-flash.bin.lock" & HOLDER=$!                     # one process: kill releases the lock
sleep 0.5
touch -d '2000-01-01' "$T/lhpc-state/node-flash.bin"; before="$(stat -c %Y "$T/lhpc-state/node-flash.bin")"
image "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless/flash.bin" 'Z' 'P'      # the build changed
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/lhpc-state/node-flash.bin" > "$T/run3.out" 2>&1; rc=$?
check "run.sh refuses while another guest holds the node image" '[ "$rc" -ne 0 ] && grep -q "already runs" "$T/run3.out"'
check "the refused start leaves the node image untouched" '[ "$(stat -c %Y "$T/lhpc-state/node-flash.bin")" = "$before" ]'
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
"$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/lhpc-state/node-flash.bin" > "$T/run4.out" 2>&1; rc=$?
check "once the holder is gone the next start runs" '[ "$rc" -eq 0 ]'

if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "FAILURES: $FAILS"; exit 1
