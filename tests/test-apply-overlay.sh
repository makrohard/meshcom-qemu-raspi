#!/usr/bin/env bash
#
# test-apply-overlay.sh — NETWORK-FREE test of scripts/apply-overlay.sh: our files land at their two
# target paths, a re-run is idempotent, a modified tracked MeshCom file is refused (rc 4), missing
# overlay files are refused (rc 1). A throwaway git repository stands in for the firmware tree.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
pass() { echo "  ok:   $1"; }
bad()  { echo "  FAIL: $1" >&2; fail=1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# A throwaway copy of the deliverable with a minimal overlay, so nothing touches the real checkout.
d="$work/deliv"
mkdir -p "$d/scripts" "$d/overlay/variants/qemu-headless" "$d/overlay/src/qemu"
cp "$HERE/../scripts/apply-overlay.sh" "$d/scripts/"
echo v > "$d/overlay/variants/qemu-headless/platformio.ini"
echo q > "$d/overlay/src/qemu/qemu_network.cpp"
fw="$d/.work/MeshCom-Firmware"; git init -q "$fw"
mkdir -p "$fw/src" && printf 'one\ntwo\nthree\n' > "$fw/src/a.cpp"
git -C "$fw" add -A && git -C "$fw" -c user.name=t -c user.email=t@t commit -q -m base

# (a) the copy lands at both target paths; the tree has no modified tracked file.
bash "$d/scripts/apply-overlay.sh" >"$work/out1" 2>&1; rc=$?
[ "$rc" = 0 ] && cmp -s "$d/overlay/variants/qemu-headless/platformio.ini" "$fw/variants/qemu-headless/platformio.ini" \
	&& cmp -s "$d/overlay/src/qemu/qemu_network.cpp" "$fw/src/qemu/qemu_network.cpp" \
	&& pass "(a) our files copied to variants/qemu-headless and src/qemu (rc 0)" \
	|| { bad "(a) copy: rc $rc"; sed 's/^/    /' "$work/out1" >&2; }

# (b) a re-run is idempotent: rc 0, the copies unchanged, still no tracked change.
bash "$d/scripts/apply-overlay.sh" >"$work/out2" 2>&1; rc=$?
[ "$rc" = 0 ] && [ -z "$(git -C "$fw" status --porcelain --untracked-files=no)" ] \
	&& pass "(b) a re-run is idempotent" || bad "(b) re-run: rc $rc"

# (c) a modified tracked MeshCom file is refused with rc 4 and named.
echo patched >> "$fw/src/a.cpp"
bash "$d/scripts/apply-overlay.sh" >"$work/out3" 2>&1; rc=$?
[ "$rc" = 4 ] && grep -q 'src/a.cpp' "$work/out3" \
	&& pass "(c) a modified tracked file fails with rc 4 and is named" || bad "(c) modified file: rc $rc"
git -C "$fw" checkout -q -- src/a.cpp

# (d) a missing overlay directory is refused with rc 1, before anything is copied.
rm -rf "$fw/variants" "$fw/src/qemu" "$d/overlay/src/qemu"
bash "$d/scripts/apply-overlay.sh" >"$work/out4" 2>&1; rc=$?
[ "$rc" = 1 ] && grep -q 'overlay/src/qemu is missing' "$work/out4" && [ ! -e "$fw/variants" ] \
	&& pass "(d) a missing overlay directory fails with rc 1 and copies nothing" || bad "(d) missing overlay: rc $rc"

exit $fail
