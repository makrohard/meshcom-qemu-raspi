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
# upstream's header, without an include guard; its version letter is the one a bump changes
printf '#define SOURCE_VERSION "4.35"\n#define SOURCE_VERSION_SUB "t"\n#define SOURCE_VERSION_WEB_SUB "t"\n' > "$fw/src/configuration_global.h"
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
[ -z "$(git -C "$fw" status --porcelain)" ] && pass "... and leaves the firmware tree untouched (nothing copied, nothing patched)" \
	|| bad "a rejected patch changed the tree: $(git -C "$fw" status --porcelain | tr '\n' ' ')"
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

# `#pragma once` (M23): (a) a header without it gets exactly one, as line 1, the rest unchanged.
cg="$fw/src/configuration_global.h"
[ "$(head -n 1 "$cg")" = "#pragma once" ] && [ "$(grep -c '^#pragma once$' "$cg")" = 1 ] \
	&& [ "$(tail -n +2 "$cg")" = "$(printf '#define SOURCE_VERSION "4.35"\n#define SOURCE_VERSION_SUB "t"\n#define SOURCE_VERSION_WEB_SUB "t"')" ] \
	&& pass "(a) #pragma once added once, as line 1, the header otherwise unchanged" || bad "(a) header after apply: $(head -3 "$cg" | tr '\n' '|')"
# (b) re-running (the patch is already applied) leaves the header byte-identical.
before_cg="$(sha256sum "$cg")"
bash "$d/scripts/apply-overlay.sh" >"$work/out3" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sha256sum "$cg")" = "$before_cg" ] && grep -q "already applied" "$work/out3" \
	&& pass "(b) a re-run keeps the header byte-identical" || bad "(b) re-run: rc $rc, header changed or no 'already applied'"
# (c) a version bump ("t" -> "u", as upstream 4.35u) no longer matters: a fresh tree with "u" applies cleanly.
git -C "$fw" checkout -q -- . && sed -i 's/"t"/"u"/' "$cg" && git -C "$fw" -c user.name=t -c user.email=t@t commit -qam bump
bash "$d/scripts/apply-overlay.sh" >"$work/out4" 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(head -n 1 "$cg")" = "#pragma once" ] && grep -q 'SOURCE_VERSION_SUB "u"' "$cg" \
	&& pass "(c) a tree with version \"u\" applies cleanly" || { bad "(c) version bump: rc $rc"; sed 's/^/    /' "$work/out4" >&2; }
# (d) the header missing: fails clearly (rc 3) BEFORE anything is patched: the patched file stays as committed.
git -C "$fw" checkout -q -- . && git -C "$fw" clean -fdq && git -C "$fw" rm -q "src/configuration_global.h" \
	&& git -C "$fw" -c user.name=t -c user.email=t@t commit -qm gone
bash "$d/scripts/apply-overlay.sh" >"$work/out5" 2>&1; rc=$?
[ "$rc" = 3 ] && grep -q "missing 'src/configuration_global.h'" "$work/out5" \
	&& pass "(d) a missing header fails clearly with rc 3" || bad "(d) missing header: rc $rc"
[ -z "$(git -C "$fw" status --porcelain)" ] && pass "(d) ... and leaves the tree untouched (nothing patched)" \
	|| bad "(d) the tree was changed: $(git -C "$fw" status --porcelain | tr '\n' ' ')"

exit $fail
