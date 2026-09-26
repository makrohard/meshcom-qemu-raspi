#!/usr/bin/env bash
#
# test-apply-overlay.sh — NETWORK-FREE test of scripts/apply-overlay.sh: the `git apply --check`
# error text goes to a private per-run temp file (not the shared /tmp/overlay_apply_err), is still
# shown to the user, and is removed afterwards; a clean patch still applies.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
pass() { echo "  ok:   $1"; }
bad()  { echo "  FAIL: $1" >&2; fail=1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# A throwaway copy of the deliverable with a minimal overlay, so nothing touches the real checkout.
d="$work/deliv"
mkdir -p "$d/scripts" "$d/overlay/variants/qemu-headless" "$d/overlay/src/qemu" "$d/overlay/patches"
cp "$HERE/../scripts/apply-overlay.sh" "$d/scripts/"
echo v > "$d/overlay/variants/qemu-headless/platformio.ini"
echo q > "$d/overlay/src/qemu/qemu_network.cpp"
fw="$d/.work/MeshCom-Firmware"; git init -q "$fw"
mkdir -p "$fw/src" && printf 'one\ntwo\nthree\n' > "$fw/src/a.cpp"
git -C "$fw" add -A && git -C "$fw" -c user.name=t -c user.email=t@t commit -q -m base

# A patch whose context does not exist in the tree: `git apply --check` must fail.
cat > "$d/overlay/patches/meshcom-qemu-headless.patch" <<'EOF'
--- a/src/a.cpp
+++ b/src/a.cpp
@@ -1,3 +1,3 @@
 nothere
-two
+TWO
 three
EOF
shared=/tmp/overlay_apply_err
before="$(stat -c %Y:%s "$shared" 2>/dev/null || echo absent)"
mkdir -p "$work/tmp"
TMPDIR="$work/tmp" bash "$d/scripts/apply-overlay.sh" >"$work/out1" 2>&1; rc=$?
after="$(stat -c %Y:%s "$shared" 2>/dev/null || echo absent)"

[ "$rc" = 4 ] && pass "a patch that does not apply fails with rc 4" || bad "rc $rc (expected 4)"
grep -q '|' "$work/out1" && pass "the git error text is shown to the user" || bad "no error text in the output"
[ "$before" = "$after" ] && pass "the shared $shared is not written" \
	|| bad "$shared was written ($before -> $after)"
[ -z "$(ls -A "$work/tmp")" ] && pass "the private temp file is removed afterwards" \
	|| bad "left behind in TMPDIR: $(ls -A "$work/tmp")"

# A patch that applies: still applied, still no temp file left.
cat > "$d/overlay/patches/meshcom-qemu-headless.patch" <<'EOF'
--- a/src/a.cpp
+++ b/src/a.cpp
@@ -1,3 +1,3 @@
 one
-two
+TWO
 three
EOF
TMPDIR="$work/tmp" bash "$d/scripts/apply-overlay.sh" >"$work/out2" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx TWO "$fw/src/a.cpp" && pass "a clean patch applies" \
	|| { bad "clean patch: rc $rc"; sed 's/^/    /' "$work/out2" >&2; }
[ -z "$(ls -A "$work/tmp")" ] && pass "no temp file left after a clean apply" || bad "temp file left after a clean apply"

exit $fail
