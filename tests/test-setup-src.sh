#!/usr/bin/env bash
#
# test-setup-src.sh — NETWORK-FREE test of scripts/setup.sh --src: the workspace is fetched from
# another repository at a COMMIT SHA (what lhpc passes for a fork pin) and at a branch name.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
pass() { echo "  ok:   $1"; }
bad()  { echo "  FAIL: $1" >&2; fail=1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# A throwaway copy of the deliverable, so .work/.run land in the temp dir, not the real checkout.
mkdir -p "$work/deliv/scripts" && cp "$HERE/../scripts/setup.sh" "$work/deliv/scripts/"
# A firmware repository with the layout setup.sh checks, two commits on branch `speed`.
fw="$work/fw"; git init -q -b speed "$fw"
for p in platformio.ini src/esp32/esp32_main.cpp src/web_functions/web_functions.cpp \
         src/net_console.cpp src/udp_functions.cpp src/batt_function_old.cpp; do
	mkdir -p "$fw/$(dirname "$p")"; echo "x" > "$fw/$p"; done
echo 'extra_configs = variants/*/platformio.ini' > "$fw/platformio.ini"
git -C "$fw" add -A && git -C "$fw" -c user.name=t -c user.email=t@t commit -q -m one
first="$(git -C "$fw" rev-parse HEAD)"
echo two > "$fw/marker" && git -C "$fw" add -A && git -C "$fw" -c user.name=t -c user.email=t@t commit -q -m two
tip="$(git -C "$fw" rev-parse HEAD)"

src_head() { git -C "$work/deliv/.work/MeshCom-Firmware" rev-parse HEAD 2>/dev/null; }

bash "$work/deliv/scripts/setup.sh" --src "$fw" --ref "$first" >"$work/out1" 2>&1
[ "$(src_head)" = "$first" ] && pass "--src with a commit SHA checks out that commit" \
	|| { bad "--src with a commit SHA (got '$(src_head)')"; sed 's/^/    /' "$work/out1" >&2; }
bash "$work/deliv/scripts/setup.sh" --src "$fw" --ref speed >"$work/out2" 2>&1
[ "$(src_head)" = "$tip" ] && pass "--src with a branch name checks out its tip" \
	|| { bad "--src with a branch name (got '$(src_head)')"; sed 's/^/    /' "$work/out2" >&2; }
[ "$(cat "$work/deliv/.run/meshcom-source.sha" 2>/dev/null)" = "$tip" ] && pass "the recorded source sha is the checkout" \
	|| bad "meshcom-source.sha does not match the checkout"

exit $fail
