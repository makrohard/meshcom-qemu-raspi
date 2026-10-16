# Gate 1, CODE: s5 runner — file B

Part of the packet `gate1-CODE-s5.md`; same request and redaction.

## Diff 2 of 3: tests, .github (`git diff origin/main HEAD -- tests .github`)

```diff
diff --git a/.github/workflows/boot-gates.yml b/.github/workflows/boot-gates.yml
new file mode 100644
index 00000000..2d54a2fe
--- /dev/null
+++ b/.github/workflows/boot-gates.yml
@@ -0,0 +1,94 @@
+# Weekly build and boot gates of stock MeshCom under QEMU (tests/test-boot-gates.sh), on the runner type
+# the LoRaHAM binaries are built and smoke-tested on (aarch64). The schedule tests upstream's moving `dev`
+# tip, as an early warning before a pin move; a dispatch tests any ref (default: setup.sh's DEFAULT_REF).
+# A failure opens one issue, or comments on the open one, naming the upstream commit and the failing gates;
+# a pass is silent. GitHub disables scheduled workflows after 60 days without a commit to the default
+# branch (README, Tests).
+name: boot-gates
+on:
+  schedule:
+    - cron: '41 3 * * 2'
+  workflow_dispatch:
+    inputs:
+      ref:
+        description: "MeshCom ref to test (empty = setup.sh's DEFAULT_REF)"
+        required: false
+        default: ''
+permissions:
+  contents: read
+  issues: write
+env:
+  ISSUE_TITLE: 'boot gates failing'
+  # The commits this job builds against (the controller's link-gate script, the bridge at the manifest pin).
+  LHPC_COMMIT: eb9673a48c1a6c4f7d537f6b319c8ad3c7f6fc6d
+  BRIDGE_COMMIT: 7c86c96aa5ae9c1359aff85c761028910be5cd91
+jobs:
+  gates:
+    runs-on: ubuntu-24.04-arm
+    timeout-minutes: 300
+    steps:
+      - uses: actions/checkout@v4
+      - name: Packages
+        run: |
+          sudo apt-get update -q
+          sudo apt-get install -y -q git curl build-essential cmake ninja-build pkg-config libglib2.0-dev \
+            libpixman-1-dev libslirp-dev libslirp0 zlib1g-dev libgcrypt20-dev libssl-dev shellcheck python3-pip
+          # QEMU 9.2 needs meson >= 1.5 (scripts/build-qemu.sh checks it); the distribution's is older.
+          pip install --user --break-system-packages 'meson>=1.5' platformio==6.1.19
+          echo "$HOME/.local/bin" >> "$GITHUB_PATH"
+      - name: Shellcheck and the quick tests
+        run: |
+          # The scripts this layout added or changed; warnings and errors fail the job.
+          shellcheck -x -S warning scripts/{run,stop,status,apply-overlay,setup,node-image,test}.sh \
+            tests/{test-apply-overlay,test-run-supervisor,test-boot-gates,test-node-image}.sh
+          for t in tests/test-apply-overlay.sh tests/test-run-supervisor.sh tests/test-node-image.sh \
+                   tests/test-node-efuse.sh tests/test-setup-src.sh; do echo "== $t"; bash "$t"; done
+      - name: QEMU (cached by recipe and patch)
+        id: qemu-cache
+        uses: actions/cache@v4
+        with:
+          path: ${{ runner.temp }}/qemu
+          key: qemu-${{ runner.arch }}-${{ hashFiles('scripts/build-qemu.sh', 'scripts/lib-publish.sh', 'patches/qemu/**') }}
+      - name: Build QEMU
+        if: steps.qemu-cache.outputs.cache-hit != 'true'
+        run: |
+          curl -fsSL "https://raw.githubusercontent.com/makrohard/loraham-pi-control/$LHPC_COMMIT/lhpc/data/scripts/meshtastic-link-gate.sh" -o "$RUNNER_TEMP/link-gate.sh"
+          chmod +x "$RUNNER_TEMP/link-gate.sh"
+          scripts/build-qemu.sh "$RUNNER_TEMP/qemu" --link-gate "$RUNNER_TEMP/link-gate.sh"
+      - name: Bridge
+        run: |
+          git clone -q https://github.com/makrohard/meshcom-loraham-bridge "$RUNNER_TEMP/bridge"
+          git -C "$RUNNER_TEMP/bridge" checkout -q "$BRIDGE_COMMIT"
+          cmake -S "$RUNNER_TEMP/bridge" -B "$RUNNER_TEMP/bridge/build" -DCMAKE_BUILD_TYPE=Release
+          cmake --build "$RUNNER_TEMP/bridge/build" --parallel
+      - name: MeshCom at the ref
+        id: ref
+        env:
+          INPUT_REF: ${{ github.event.inputs.ref }}
+        run: |
+          if [ "${{ github.event_name }}" = schedule ]; then
+            ref="$(git ls-remote https://github.com/icssw-org/MeshCom-Firmware.git refs/heads/dev | cut -f1)"
+          else
+            ref="$INPUT_REF"
+          fi
+          if [ -n "$ref" ]; then scripts/setup.sh --ref "$ref"; else scripts/setup.sh; fi
+          echo "sha=$(git -C .work/MeshCom-Firmware rev-parse HEAD)" >> "$GITHUB_OUTPUT"
+          scripts/apply-overlay.sh
+          scripts/prepare-openeth.sh
+      - name: Boot gates
+        run: |
+          BRIDGE="$RUNNER_TEMP/bridge/build/meshcom-loraham-bridge" QEMU_BIN="$RUNNER_TEMP/qemu/qemu/bin/qemu-system-xtensa" \
+            PIO="$HOME/.local/bin/pio" tests/test-boot-gates.sh --main --controls --slow 2>&1 | tee "$RUNNER_TEMP/gates.log"
+          exit "${PIPESTATUS[0]}"
+      - name: Report a failure in one issue
+        if: failure()
+        env:
+          GH_TOKEN: ${{ github.token }}
+          SHA: ${{ steps.ref.outputs.sha }}
+        run: |
+          set -eu
+          fails="$(grep -E '^FAIL' "$RUNNER_TEMP/gates.log" 2>/dev/null || echo "(a step before the boot gates failed; see the run)")"
+          body="$(printf 'Run %s on MeshCom %s (%s):\n\n```\n%s\n```\n' \
+            "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID" "${SHA:-unknown}" "${{ github.event_name }}" "$fails")"
+          n="$(gh issue list --state open --search "\"$ISSUE_TITLE\" in:title" --json number --jq '.[0].number // empty')"
+          if [ -n "$n" ]; then gh issue comment "$n" --body "$body"; else gh issue create --title "$ISSUE_TITLE" --body "$body"; fi
diff --git a/tests/test-apply-overlay.sh b/tests/test-apply-overlay.sh
index dc86ee9a..b7924b93 100755
--- a/tests/test-apply-overlay.sh
+++ b/tests/test-apply-overlay.sh
@@ -1,8 +1,8 @@
 #!/usr/bin/env bash
 #
-# test-apply-overlay.sh — NETWORK-FREE test of scripts/apply-overlay.sh: the `git apply --check`
-# error text goes to a private per-run temp file (not the shared /tmp/overlay_apply_err), is still
-# shown to the user, and is removed afterwards; a clean patch still applies.
+# test-apply-overlay.sh — NETWORK-FREE test of scripts/apply-overlay.sh: our files land at their two
+# target paths, a re-run is idempotent, a modified tracked MeshCom file is refused (rc 4), missing
+# overlay files are refused (rc 1). A throwaway git repository stands in for the firmware tree.
 set -u
 
 HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
@@ -13,78 +13,37 @@ bad()  { echo "  FAIL: $1" >&2; fail=1; }
 work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
 # A throwaway copy of the deliverable with a minimal overlay, so nothing touches the real checkout.
 d="$work/deliv"
-mkdir -p "$d/scripts" "$d/overlay/variants/qemu-headless" "$d/overlay/src/qemu" "$d/overlay/patches"
+mkdir -p "$d/scripts" "$d/overlay/variants/qemu-headless" "$d/overlay/src/qemu"
 cp "$HERE/../scripts/apply-overlay.sh" "$d/scripts/"
 echo v > "$d/overlay/variants/qemu-headless/platformio.ini"
 echo q > "$d/overlay/src/qemu/qemu_network.cpp"
 fw="$d/.work/MeshCom-Firmware"; git init -q "$fw"
 mkdir -p "$fw/src" && printf 'one\ntwo\nthree\n' > "$fw/src/a.cpp"
-# upstream's header, without an include guard; its version letter is the one a bump changes
-printf '#define SOURCE_VERSION "4.35"\n#define SOURCE_VERSION_SUB "t"\n#define SOURCE_VERSION_WEB_SUB "t"\n' > "$fw/src/configuration_global.h"
 git -C "$fw" add -A && git -C "$fw" -c user.name=t -c user.email=t@t commit -q -m base
 
-# A patch whose context does not exist in the tree: `git apply --check` must fail.
-cat > "$d/overlay/patches/meshcom-qemu-headless.patch" <<'EOF'
---- a/src/a.cpp
-+++ b/src/a.cpp
-@@ -1,3 +1,3 @@
- nothere
--two
-+TWO
- three
-EOF
-shared=/tmp/overlay_apply_err
-before="$(stat -c %Y:%s "$shared" 2>/dev/null || echo absent)"
-mkdir -p "$work/tmp"
-TMPDIR="$work/tmp" bash "$d/scripts/apply-overlay.sh" >"$work/out1" 2>&1; rc=$?
-after="$(stat -c %Y:%s "$shared" 2>/dev/null || echo absent)"
+# (a) the copy lands at both target paths; the tree has no modified tracked file.
+bash "$d/scripts/apply-overlay.sh" >"$work/out1" 2>&1; rc=$?
+[ "$rc" = 0 ] && cmp -s "$d/overlay/variants/qemu-headless/platformio.ini" "$fw/variants/qemu-headless/platformio.ini" \
+	&& cmp -s "$d/overlay/src/qemu/qemu_network.cpp" "$fw/src/qemu/qemu_network.cpp" \
+	&& pass "(a) our files copied to variants/qemu-headless and src/qemu (rc 0)" \
+	|| { bad "(a) copy: rc $rc"; sed 's/^/    /' "$work/out1" >&2; }
 
-[ "$rc" = 4 ] && pass "a patch that does not apply fails with rc 4" || bad "rc $rc (expected 4)"
-[ -z "$(git -C "$fw" status --porcelain)" ] && pass "... and leaves the firmware tree untouched (nothing copied, nothing patched)" \
-	|| bad "a rejected patch changed the tree: $(git -C "$fw" status --porcelain | tr '\n' ' ')"
-grep -q '|' "$work/out1" && pass "the git error text is shown to the user" || bad "no error text in the output"
-[ "$before" = "$after" ] && pass "the shared $shared is not written" \
-	|| bad "$shared was written ($before -> $after)"
-[ -z "$(ls -A "$work/tmp")" ] && pass "the private temp file is removed afterwards" \
-	|| bad "left behind in TMPDIR: $(ls -A "$work/tmp")"
+# (b) a re-run is idempotent: rc 0, the copies unchanged, still no tracked change.
+bash "$d/scripts/apply-overlay.sh" >"$work/out2" 2>&1; rc=$?
+[ "$rc" = 0 ] && [ -z "$(git -C "$fw" status --porcelain --untracked-files=no)" ] \
+	&& pass "(b) a re-run is idempotent" || bad "(b) re-run: rc $rc"
 
-# A patch that applies: still applied, still no temp file left.
-cat > "$d/overlay/patches/meshcom-qemu-headless.patch" <<'EOF'
---- a/src/a.cpp
-+++ b/src/a.cpp
-@@ -1,3 +1,3 @@
- one
--two
-+TWO
- three
-EOF
-TMPDIR="$work/tmp" bash "$d/scripts/apply-overlay.sh" >"$work/out2" 2>&1; rc=$?
-[ "$rc" = 0 ] && grep -qx TWO "$fw/src/a.cpp" && pass "a clean patch applies" \
-	|| { bad "clean patch: rc $rc"; sed 's/^/    /' "$work/out2" >&2; }
-[ -z "$(ls -A "$work/tmp")" ] && pass "no temp file left after a clean apply" || bad "temp file left after a clean apply"
-
-# `#pragma once` (M23): (a) a header without it gets exactly one, as line 1, the rest unchanged.
-cg="$fw/src/configuration_global.h"
-[ "$(head -n 1 "$cg")" = "#pragma once" ] && [ "$(grep -c '^#pragma once$' "$cg")" = 1 ] \
-	&& [ "$(tail -n +2 "$cg")" = "$(printf '#define SOURCE_VERSION "4.35"\n#define SOURCE_VERSION_SUB "t"\n#define SOURCE_VERSION_WEB_SUB "t"')" ] \
-	&& pass "(a) #pragma once added once, as line 1, the header otherwise unchanged" || bad "(a) header after apply: $(head -3 "$cg" | tr '\n' '|')"
-# (b) re-running (the patch is already applied) leaves the header byte-identical.
-before_cg="$(sha256sum "$cg")"
+# (c) a modified tracked MeshCom file is refused with rc 4 and named.
+echo patched >> "$fw/src/a.cpp"
 bash "$d/scripts/apply-overlay.sh" >"$work/out3" 2>&1; rc=$?
-[ "$rc" = 0 ] && [ "$(sha256sum "$cg")" = "$before_cg" ] && grep -q "already applied" "$work/out3" \
-	&& pass "(b) a re-run keeps the header byte-identical" || bad "(b) re-run: rc $rc, header changed or no 'already applied'"
-# (c) a version bump ("t" -> "u", as upstream 4.35u) no longer matters: a fresh tree with "u" applies cleanly.
-git -C "$fw" checkout -q -- . && sed -i 's/"t"/"u"/' "$cg" && git -C "$fw" -c user.name=t -c user.email=t@t commit -qam bump
+[ "$rc" = 4 ] && grep -q 'src/a.cpp' "$work/out3" \
+	&& pass "(c) a modified tracked file fails with rc 4 and is named" || bad "(c) modified file: rc $rc"
+git -C "$fw" checkout -q -- src/a.cpp
+
+# (d) a missing overlay directory is refused with rc 1, before anything is copied.
+rm -rf "$fw/variants" "$fw/src/qemu" "$d/overlay/src/qemu"
 bash "$d/scripts/apply-overlay.sh" >"$work/out4" 2>&1; rc=$?
-[ "$rc" = 0 ] && [ "$(head -n 1 "$cg")" = "#pragma once" ] && grep -q 'SOURCE_VERSION_SUB "u"' "$cg" \
-	&& pass "(c) a tree with version \"u\" applies cleanly" || { bad "(c) version bump: rc $rc"; sed 's/^/    /' "$work/out4" >&2; }
-# (d) the header missing: fails clearly (rc 3) BEFORE anything is patched: the patched file stays as committed.
-git -C "$fw" checkout -q -- . && git -C "$fw" clean -fdq && git -C "$fw" rm -q "src/configuration_global.h" \
-	&& git -C "$fw" -c user.name=t -c user.email=t@t commit -qm gone
-bash "$d/scripts/apply-overlay.sh" >"$work/out5" 2>&1; rc=$?
-[ "$rc" = 3 ] && grep -q "missing 'src/configuration_global.h'" "$work/out5" \
-	&& pass "(d) a missing header fails clearly with rc 3" || bad "(d) missing header: rc $rc"
-[ -z "$(git -C "$fw" status --porcelain)" ] && pass "(d) ... and leaves the tree untouched (nothing patched)" \
-	|| bad "(d) the tree was changed: $(git -C "$fw" status --porcelain | tr '\n' ' ')"
+[ "$rc" = 1 ] && grep -q 'overlay/src/qemu is missing' "$work/out4" && [ ! -e "$fw/variants" ] \
+	&& pass "(d) a missing overlay directory fails with rc 1 and copies nothing" || bad "(d) missing overlay: rc $rc"
 
 exit $fail
diff --git a/tests/test-boot-gates.sh b/tests/test-boot-gates.sh
new file mode 100755
index 00000000..40d32efa
--- /dev/null
+++ b/tests/test-boot-gates.sh
@@ -0,0 +1,282 @@
+#!/usr/bin/env bash
+#
+# test-boot-gates.sh — the build and boot gates of the QEMU target, on the real firmware and QEMU.
+# SLOW (tens of minutes); needs a prepared workspace (scripts/setup.sh, apply-overlay.sh,
+# prepare-openeth.sh), PlatformIO, qemu-system-xtensa, the meshcom-loraham-bridge binary and python3.
+#
+#   BRIDGE=<meshcom-loraham-bridge> QEMU_BIN=<qemu-system-xtensa> [PIO=<pio>] tests/test-boot-gates.sh [--main] [--controls] [--slow]
+#
+#   --main      (default) gates a–l on the LHPC env qemu-headless-extradio-gpsd, from a fresh node
+#   --controls  each gate's failing control: the gate's assertion must FAIL on it
+#   --slow      the test builds, several minutes each; also one at a time: --slow-b (b': a flag clear
+#               reaches upstream's initethDHCP), --slow-k (k: OpenETH never starts, a provisioned node),
+#               --slow-k2 (k: the same build, a fresh node), --slow-l (l's control: the old qemu_network.cpp)
+#
+# The slow modes leave their test build in the workspace; --main (or scripts/build.sh) builds it again.
+# Ports 7000/7001 (bridge, tap), 12323/18083 (guest) must be free. The test password is random per run
+# and never printed; the test callsign is a placeholder. EXIT: 0 = every selected gate as expected.
+# Each gate is an eval'd string, so its variables look unexpanded/unused to shellcheck.
+# shellcheck disable=SC2016,SC2034
+set -u
+ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
+FW="$ROOT/.work/MeshCom-Firmware"
+ENV=qemu-headless-extradio-gpsd
+: "${BRIDGE:?BRIDGE=<meshcom-loraham-bridge>}" "${QEMU_BIN:?QEMU_BIN=<qemu-system-xtensa>}"
+PIO="${PIO:-pio}"
+G="$ROOT/.run/gates"
+FAILS=0
+pass() { echo "PASS  $1"; }
+fail() { echo "FAIL  $1"; FAILS=$((FAILS+1)); }
+gate() { if eval "$2" 2>/dev/null; then pass "$1"; else fail "$1"; fi; }
+# expect_fail: a control passes when the gate's assertion is FALSE on it.
+control() { if eval "$2" 2>/dev/null; then fail "control $1 (the assertion still held)"; else pass "control $1 (the assertion failed, as it must)"; fi; }
+MODES=" $* "; [ -z "${*:-}" ] && MODES=" --main "
+[[ "$MODES" == *" --slow "* ]] && MODES="$MODES --slow-b --slow-k --slow-k2 --slow-l "
+# --main starts from nothing; --controls and --slow use the node --main provisioned.
+[[ "$MODES" == *" --main "* ]] && rm -rf "$G"; mkdir -p "$G"
+
+XRPW="$G/xr.pw"; python3 -I -c 'import secrets; print(secrets.token_hex(12), end="")' > "$XRPW"; chmod 600 "$XRPW"
+CALL="XX9TST-1"                        # a placeholder call, accepted by the firmware's syntax check
+
+build() {   # build ENV [extra -D flags]
+	XR_HOST=10.0.2.2 XR_PORT=7000 XR_PASSWORD="$(cat "$XRPW")" PLATFORMIO_BUILD_FLAGS="${2:-}" PIO="$PIO" \
+		"$ROOT/scripts/build.sh" --env "$1" > "$G/build-$1.log" 2>&1
+}
+UARTLOG() { readlink -f "$ROOT/.run/uart-latest.log"; }
+console() { # console CMD [REGEX]: send CMD on the net console; print only REGEX matches (the reply has a password field)
+	python3 -I - "$@" <<'PY'
+import re, socket, sys, time
+try:
+    s = socket.create_connection(("127.0.0.1", 12323), timeout=10); s.settimeout(3)
+    try: s.recv(256)
+    except Exception: pass
+    s.sendall((sys.argv[1] + "\r\n").encode()); time.sleep(4); d = b""
+    try:
+        while True:
+            c = s.recv(8192)
+            if not c: break
+            d += c
+    except Exception: pass
+    if len(sys.argv) > 2: print(" | ".join(re.findall(sys.argv[2], d.decode(errors="replace"))))
+except Exception as e:
+    print("console-error", type(e).__name__)
+PY
+}
+web() { curl -s -m "${2:-15}" -o "${3:-/dev/null}" -w '%{http_code}' "http://127.0.0.1:18083${1:-/}" || true; }
+console_ok() { python3 -I -c 'import socket; s=socket.create_connection(("127.0.0.1",12323),timeout=8); s.settimeout(8); import sys; sys.exit(0 if b"MeshCom Console" in s.recv(128) else 1)' 2>/dev/null; }
+monitor() { python3 -I -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.3); s.recv(4096); s.sendall((sys.argv[2]+"\n").encode()); time.sleep(0.5)' "$ROOT/.run/monitor.sock" "$1"; }
+waitfor() { local i; for i in $(seq 1 "$2"); do eval "$1" 2>/dev/null && return 0; sleep 1; done; return 1; }
+
+BP=""; TP=""; RP=""; GP=""
+start_bridge() {
+	"$BRIDGE" --bind 127.0.0.1 --port 7001 --ping-interval-ms 30000 --pong-timeout-ms 90000 --password-file "$XRPW" > "$G/bridge.log" 2>&1 & BP=$!
+	python3 -I "$ROOT/tests/xr-tap.py" 7000 7001 "$G/tap.log" & TP=$!
+}
+start_node() { # start_node NODE_IMAGE [run.sh]
+	"${2:-$ROOT/scripts/run.sh}" --env "$ENV" --qemu "$QEMU_BIN" --node-image "$1" > "$G/run.log" 2>&1 & RP=$!
+}
+start_relay() {
+	waitfor '[ -S "$ROOT/.run/gps-uart1.sock" ]' 120
+	python3 -I "$ROOT/scripts/gps-relay.py" --mode fixture --fixture "$ROOT/fixtures/gps/valid_fix.nmea" \
+		--uart "$ROOT/.run/gps-uart1.sock" --rate 1 --loop > "$G/relay.log" 2>&1 & GP=$!
+}
+stop_all() {
+	[ -n "$GP" ] && kill "$GP" 2>/dev/null; GP=""
+	"$ROOT/scripts/stop.sh" > /dev/null 2>&1
+	[ -n "$RP" ] && wait "$RP" 2>/dev/null; RP=""
+	[ -n "$TP" ] && kill "$TP" 2>/dev/null; [ -n "$BP" ] && kill "$BP" 2>/dev/null; wait 2>/dev/null; TP=""; BP=""
+}
+trap stop_all EXIT
+# ready_with_address FILE: upstream's [BOOT];ready line (printed after setup() called startNetwork()) shows
+# the address flag set (ip;1), no "[ETH] init" ran (the stand-in path), and the hand-over reported its
+# address with a publish time earlier than that line's.
+ready_with_address() { local p r; p=$(grep -aoE 'ethmode: IP .* reported \([0-9]+ ms\)' "$1" | head -1 | grep -oE '[0-9]+ ms' | grep -oE '[0-9]+'); \
+	r=$(grep -aoE '\[BOOT\];ready;ms;[0-9]+;ip;1' "$1" | head -1 | cut -d';' -f4); \
+	[ -n "$r" ] && ! grep -aq '\[ETH\] init' "$1" && [ -n "$p" ] && [ "$p" -lt "$r" ]; }
+# order L1 L2 FILE: line L1 occurs before L2
+order() { local a b; a=$(grep -anm1 -- "$1" "$3" | cut -d: -f1); b=$(grep -anm1 -- "$2" "$3" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }
+
+if [[ "$MODES" == *" --main "* ]]; then
+	echo "== builds (a)"
+	"$ROOT/scripts/apply-overlay.sh" > "$G/apply.log" 2>&1; arc=$?
+	gate "a  0 tracked MeshCom changes (apply-overlay rc 0)" '[ "$arc" = 0 ] && [ -z "$(git -C "$FW" status --porcelain --untracked-files=no)" ]'
+	for e in qemu-headless qemu-headless-extradio qemu-headless-gpsd "$ENV"; do
+		build "$e"; brc=$?; gate "a  $e builds" '[ "$brc" = 0 ]'
+	done
+
+	echo "== a fresh node (j, b, c, c-xr, d, f, g, h, i, e, l)"
+	NODE="$G/node/node-flash.bin"
+	start_bridge; start_node "$NODE"; start_relay
+	waitfor 'grep -q "provisioning verified" "$G/run.log"' 900
+	gate "j  provisioned and verified (marker written)" '[ -s "$NODE.provisioned" ]'
+	B1="$(UARTLOG)"
+	waitfor 'grep -aq "ethmode: IP .* reported" "$B1"' 60      # the line is written from 5 s of uptime on
+	gate "b  [BOOT];ready with ip;1, no [ETH] init, address published before it (first boot)" 'ready_with_address "$B1"'
+	pre_ap="$(grep -ac 'WIFIAP starting' "$B1")"
+	console "--setcall $CALL" 'Call:\S+ Short:\S+ set' > "$G/setcall.txt"
+	waitfor 'grep -q "restart #1" "$G/run.log"' 180
+	waitfor '[ "$(web)" = 200 ]' 180; jweb=$?          # the emulated web server is slow: one 200 counts
+	B2="$(UARTLOG)"
+	gate "j  --setcall -> one supervised restart, AP flag off, web 200, callsign kept" \
+		'grep -q "Call:" "$G/setcall.txt" && [ "$pre_ap" -ge 1 ] && [ "$(grep -ac "WIFIAP starting" "$B2")" = 0 ] && [ "$jweb" = 0 ] && grep -aq "BLE-Name <.*-${CALL%-*}-" "$B2"'
+	waitfor 'grep -aq "ethmode: IP .* reported" "$B2"' 60
+	gate "b  [BOOT];ready with ip;1, no [ETH] init, address published before it (restart)" 'ready_with_address "$B2"'
+	waitfor '[ "$(web)" = 200 ]' 30; cweb=$?
+	gate "c  web 200, console banner and authenticated" '[ "$cweb" = 0 ] && console_ok && grep -aq "Client authenticated" "$B2"'
+	sleep 45; cp "$G/tap.log" "$G/tap-control.log"
+	console "--sendpos" > /dev/null; sleep 20
+	gate "c-xr  CONFIG_RESULT, and a TX_REQUEST with payload0 0x21 after --sendpos" \
+		'grep -q "bridge>node CONFIG_RESULT" "$G/tap.log" && [ "$(grep -c "TX_REQUEST.*payload0=0x21" "$G/tap.log")" -gt "$(grep -c "TX_REQUEST.*payload0=0x21" "$G/tap-control.log")" ]'
+	gate "c-xr control window: no 0x21 frame before --sendpos" '! grep -q "TX_REQUEST.*payload0=0x21" "$G/tap-control.log"'
+	pos="$(console "--pos" 'SAT: [0-9]+ - (?:fix|nofix)')"; sat="$(printf '%s' "$pos" | grep -oE '[0-9]+' | head -1)"
+	gate "d  Display not found, UBLOX erkannt, --pos SAT > 0 with a fix, one RESET_REASON per boot" \
+		'grep -aq "Display not found" "$B2" && grep -aq "UBLOX erkannt" "$B2" && [ "${sat:-0}" -gt 0 ] && [ "${pos##* }" = fix ] && [ "$(grep -ac "\[BOOT\] RESET_REASON" "$B1")" = 1 ] && [ "$(grep -ac "\[BOOT\] RESET_REASON" "$B2")" = 1 ]'
+	code="$(web / 20 "$G/page.html")"
+	gate "f  [NET];mtu;eth;1280 and a page > 1280 B ending </html>" \
+		'grep -aq "\[NET\];mtu;eth;1280" "$B2" && [ "$code" = 200 ] && [ "$(wc -c < "$G/page.html")" -gt 1280 ] && tail -c 20 "$G/page.html" | grep -q "</html>"'
+	info="$(console "--info" '\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)')"
+	gate "g  --info: MESH off, EXTUDP off, Gateway off" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'
+	t0=$(date +%s); scode="$(web "/?page=spectrum" 60)"; st=$(( $(date +%s) - t0 ))
+	waitfor '[ "$(web)" = 200 ]' 30; hweb=$?
+	gate "h  spectrum page within 60 s, then web 200" '[ "$scode" = 200 ] && [ "$st" -le 60 ] && [ "$hweb" = 0 ]'
+	kill "$GP" 2>/dev/null; GP=""
+	python3 -I - "$ROOT/.run/gps-uart1.sock" "$ROOT/fixtures/gps/valid_fix.nmea" > "$G/blast.txt" 2>&1 <<'PY' &
+import socket, sys, time
+s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(5); data = open(sys.argv[2], "rb").read()
+t0 = time.time(); n = 0
+while time.time() - t0 < 90:
+    try: s.sendall(data); n += len(data)
+    except socket.timeout: pass
+print("bytes %d secs %.1f" % (n, time.time() - t0))
+PY
+	BL=$!; iok=0
+	for k in 1 2 3 4 5 6 7 8; do sleep 10; [ "$(web / 15)" = 200 ] && console_ok && iok=$((iok+1)); done
+	wait "$BL"
+	gate "i  UART1 written unpaced for 90 s: web and console answer at all 8 probes" '[ "$iok" = 8 ]'
+	console "--reboot" > /dev/null
+	waitfor 'grep -q "restart #2" "$G/run.log"' 180
+	waitfor '[ "$(web)" = 200 ]' 180; eweb=$?
+	gate "e  --reboot -> guest reset -> restart #2, web 200" 'grep -q "guest reset after .* restart #2" "$G/run.log" && [ "$eweb" = 0 ]'
+	B3="$(UARTLOG)"; waitfor 'grep -aq "ethmode: IP .* reported" "$B3"' 120
+	monitor "set_link net0 off"; t0=$(date +%s)
+	waitfor 'grep -aq "readiness withdrawn" "$B3"' 10; wt=$(( $(date +%s) - t0 ))
+	down_web="$(web / 5)"
+	gate "l  set_link off: readiness withdrawn within 10 s, web from the host fails" 'grep -aq "readiness withdrawn" "$B3" && [ "$wt" -le 10 ] && [ "$down_web" != 200 ]'
+	n0="$(grep -ac 'ethmode: IP .* reported' "$B3")"
+	monitor "set_link net0 on"; t0=$(date +%s)
+	waitfor '[ "$(grep -ac "ethmode: IP .* reported" "$B3")" -gt "$n0" ]' 30; rt=$(( $(date +%s) - t0 ))
+	gate "l  set_link on: the address reported again within 30 s (${rt} s)" '[ "$(grep -ac "ethmode: IP .* reported" "$B3")" -gt "$n0" ] && [ "$rt" -le 30 ]'
+	t0=$(date +%s); waitfor '[ "$(web / 5)" = 200 ]' 60; lweb=$?; wt2=$(( $(date +%s) - t0 ))
+	gate "l  ... and the web page answers 200 again (${wt2} s after the report)" '[ "$lweb" = 0 ]'
+	cp "$B1" "$G/boot1.log"; cp "$B2" "$G/boot2.log"; cp "$B3" "$G/boot3.log"
+	stop_all
+fi
+
+if [[ "$MODES" == *" --controls "* ]]; then
+	echo "== failing controls"
+	"$ROOT/scripts/apply-overlay.sh" > /dev/null
+	# a: an old patch hunk re-applied (hunk 14 of the former overlay patch, src/loop_functions.cpp)
+	git -C "$ROOT" show c2335d12:overlay/patches/meshcom-qemu-headless.patch > "$G/old.patch" 2>/dev/null
+	git -C "$FW" apply --include=src/loop_functions.cpp "$G/old.patch" 2>/dev/null
+	"$ROOT/scripts/apply-overlay.sh" > "$G/apply-c.log" 2>&1; arc=$?
+	control "a  (a re-applied hunk)" '[ "$arc" = 0 ]'
+	git -C "$FW" checkout -q -- .
+	# b: a build without the hand-over (initVariant and the task; only `neth` kept): the provisioning boot
+	# panics in the Wi-Fi PHY -> no marker
+	printf '#include <configuration.h>\n#include "esp32/esp32_eth.h"\nEspETH neth;\n' > "$FW/src/qemu/qemu_ethmode.cpp"
+	build "$ENV"; cbrc=$?
+	NODE="$G/node-cb/node-flash.bin"; brc=x
+	if [ "$cbrc" = 0 ]; then
+		PROVISION_TIMEOUT=300 start_node "$NODE"
+		waitfor '! kill -0 "$RP" 2>/dev/null' 600; wait "$RP"; brc=$?; RP=""
+	fi
+	control "b  (no hand-over; build rc $cbrc, run.sh rc $brc)" '[ "$cbrc" != 0 ] || [ -s "$NODE.provisioned" ]'
+	"$ROOT/scripts/apply-overlay.sh" > /dev/null; build "$ENV"
+	# d, e, f, g, c on copies of the provisioned node, changed at run time over the console
+	PROV="$G/node/node-flash.bin"; NODE=""
+	copy_node() { mkdir -p "$G/$1"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/$1/"; echo "$G/$1/node-flash.bin"; }
+	[ -s "$PROV.provisioned" ] && NODE="$(copy_node node-c1)" || echo "SKIP  d/e/f/g/c controls: run --main first"
+	if [ -n "$NODE" ]; then
+		start_bridge; start_node "$NODE"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
+		console "--mesh on" > /dev/null; sleep 3
+		info="$(console "--info" '\.\.\.MESH (?:on|off)|\.\.\.EXTUDP (?:on|off)|Gateway (?:on|off)')"
+		control "g  (--mesh on)" '[ "$info" = "...MESH off | ...EXTUDP off | Gateway off" ]'
+		console "--mesh off" > /dev/null
+		pos="$(console "--pos" 'SAT: [0-9]+ - (?:fix|nofix)')"; sat="$(printf '%s' "$pos" | grep -oE '[0-9]+' | head -1)"
+		control "d  (relay off: --pos)" '[ "${sat:-0}" -gt 0 ] && [ "${pos##* }" = fix ]'
+		console "--mtu 1500" > /dev/null; console "--reboot" > /dev/null
+		waitfor 'grep -q "restart #1" "$G/run.log"' 180; waitfor '[ "$(web)" = 200 ]' 180
+		control "f  (--mtu 1500)" 'grep -aq "\[NET\];mtu;eth;1280" "$(UARTLOG)"'
+		stop_all
+		# e: run.sh without -no-reboot: no restart line after --reboot
+		sed '/-no-reboot/d' "$ROOT/scripts/run.sh" > "$ROOT/scripts/.run-noreboot.sh"; chmod +x "$ROOT/scripts/.run-noreboot.sh"
+		start_node "$NODE" "$ROOT/scripts/.run-noreboot.sh"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
+		console "--reboot" > /dev/null; sleep 60
+		control "e  (no -no-reboot)" 'grep -q "restart #1" "$G/run.log"'
+		stop_all; rm -f "$ROOT/scripts/.run-noreboot.sh"
+		# c: the console switched off
+		NODE="$(copy_node node-c2)"; start_node "$NODE"; waitfor '[ "$(web)" = 200 ] && console_ok' 300
+		console "--netconsole off" > /dev/null; sleep 3
+		control "c  (--netconsole off)" 'console_ok'
+		stop_all
+	fi
+fi
+
+if [[ "$MODES" == *" --slow-"* ]]; then
+	echo "== slow cases (test builds)"
+	PROV="$G/node/node-flash.bin"
+	[ -s "$PROV.provisioned" ] || { echo "SKIP  slow cases: run --main first (they need a provisioned node)"; exit 1; }
+fi
+if [[ "$MODES" == *" --slow-b "* ]]; then
+	"$ROOT/scripts/apply-overlay.sh" > /dev/null
+	# b': a flag clear in Ethernet mode reaches upstream's initethDHCP() (the loop's 5-minute path)
+	build "$ENV" "-DQEMU_TEST_CLEAR_FLAG_MS=8000"
+	mkdir -p "$G/node-b2"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-b2/" 2>/dev/null
+	start_node "$G/node-b2/node-flash.bin"; waitfor '[ "$(web)" = 200 ]' 300
+	waitfor 'grep -aq "\[ETH\] DHCP IP" "$(UARTLOG)"' 400
+	waitfor '[ "$(web)" = 200 ]' 30; bweb=$?
+	gate "b' a flag clear -> [ETH] DHCP IP via the stand-in, web 200" 'grep -aq "TEST: node_hasIPaddress cleared" "$(UARTLOG)" && grep -aq "\[ETH\] DHCP IP" "$(UARTLOG)" && [ "$bweb" = 0 ]'
+	stop_all
+	# b' control: without the stand-in headers the build fails
+	mv "$FW/variants/qemu-headless/ETHClass2.h" "$G/"; build "$ENV"; src=$?
+	mv "$G/ETHClass2.h" "$FW/variants/qemu-headless/"
+	control "b' (no ETHClass2.h stand-in)" '[ "$src" = 0 ]'
+fi
+if [[ "$MODES" == *" --slow-k "* ]]; then
+	"$ROOT/scripts/apply-overlay.sh" > /dev/null
+	# k: OpenETH never starts, a node with saved settings: readiness withdrawn, nothing reachable
+	build "$ENV" "-DQEMU_TEST_NO_OPENETH"
+	mkdir -p "$G/node-k"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-k/" 2>/dev/null
+	start_node "$G/node-k/node-flash.bin"; sleep 20
+	K="$(UARTLOG)"; kreach=0
+	for k in $(seq 1 14); do [ "$(web / 5)" = 200 ] && kreach=1; console_ok && kreach=1; sleep 25; done
+	# Upstream retries initethDHCP() only while node_hasIPaddress is false (startNetwork(), the loop's
+	# 5-minute path), so a second "[ETH] DHCP failed" proves the first fallback's `true` did not stand.
+	# (Measured: upstream's ntpHarvestUDP() mirrors hasIPaddress into the flag within a loop pass, before the
+	# hand-over task's own withdrawal; that withdrawal is exercised by gate l.)
+	gate "k  no OpenETH: the fallback's readiness never stands (>= 2 DHCP-failed retries), no panic" \
+		'[ "$(grep -ac "DHCP failed" "$K")" -ge 2 ] && ! grep -aqE "Guru Meditation|assert failed" "$K"'
+	gate "k  no OpenETH: web and console unreachable from the host throughout" '[ "$kreach" = 0 ]'
+	cp "$K" "$G/boot-k.log"; stop_all
+fi
+if [[ "$MODES" == *" --slow-k2 "* ]]; then
+	"$ROOT/scripts/apply-overlay.sh" > /dev/null
+	build "$ENV" "-DQEMU_TEST_NO_OPENETH"
+	mkdir -p "$G/node-k"; cp "$PROV" "$PROV.efuse" "$G/node-k/" 2>/dev/null
+	rm -f "$G/node-k/node-flash.bin.provisioned"; PROVISION_TIMEOUT=120 start_node "$G/node-k/node-flash.bin"
+	waitfor '! kill -0 "$RP" 2>/dev/null' 600; wait "$RP"; krc=$?; RP=""
+	gate "k  a fresh node in this build -> provisioning rc 3, no marker" '[ "$krc" = 3 ] && [ ! -e "$G/node-k/node-flash.bin.provisioned" ]'
+fi
+if [[ "$MODES" == *" --slow-l "* ]]; then
+	"$ROOT/scripts/apply-overlay.sh" > /dev/null
+	# l control: the old qemu_network.cpp (link loss kept readiness)
+	git -C "$ROOT" show c2335d12:overlay/src/qemu/qemu_network.cpp > "$FW/src/qemu/qemu_network.cpp"; build "$ENV"
+	mkdir -p "$G/node-l"; cp "$PROV" "$PROV.efuse" "$PROV.provisioned" "$G/node-l/" 2>/dev/null
+	start_node "$G/node-l/node-flash.bin"; waitfor '[ "$(web)" = 200 ]' 300
+	L="$(UARTLOG)"; monitor "set_link net0 off"; sleep 12
+	control "l  (old qemu_network.cpp)" 'grep -aq "readiness withdrawn" "$L"'
+	monitor "set_link net0 on"; stop_all
+fi
+
+echo "---"
+[ "$FAILS" = 0 ] && { echo "ALL GATES AS EXPECTED"; exit 0; } || { echo "FAILURES: $FAILS"; exit 1; }
diff --git a/tests/test-node-image.sh b/tests/test-node-image.sh
index 908f9774..06bb50c0 100755
--- a/tests/test-node-image.sh
+++ b/tests/test-node-image.sh
@@ -89,6 +89,20 @@ rm -f "$N.build-sha256"; fill "$N" 9 1 'U'; NVS6="$(region "$N" 9 5)"
 "$NI" "$T/build5.bin" "$N" >/dev/null
 check "a missing sidecar carries the node's NVS" '[ "$(region "$N" 9 5)" = "$NVS6" ]'
 
+echo "== the provisioning marker (run.sh) is valid only for an image with settings"
+M="$T/mk/node-flash.bin"; mkdir -p "$T/mk"
+echo "stamp sha" > "$M.provisioned"
+"$NI" "$T/build1.bin" "$M" >/dev/null
+check "a node image created from the build drops the marker" '[ ! -e "$M.provisioned" ]'
+echo "stamp sha" > "$M.provisioned"
+image "$T/build4.bin" 'D' 'Q'      # another partition table: the settings are reset
+"$NI" "$T/build4.bin" "$M" >/dev/null
+check "a partition-table reset drops the marker" '[ ! -e "$M.provisioned" ]'
+echo "stamp sha" > "$M.provisioned"
+image "$T/build5.bin" 'E' 'Q'      # same partition table: the settings are carried
+"$NI" "$T/build5.bin" "$M" >/dev/null
+check "carried settings keep the marker" '[ -e "$M.provisioned" ]'
+
 echo "== run.sh boots the node image, not the build output"
 R="$T/repo"; mkdir -p "$R/scripts" "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless"
 cp "$REPO/scripts/run.sh" "$REPO/scripts/node-image.sh" "$REPO/scripts/node-efuse.sh" "$R/scripts/"
@@ -118,8 +132,11 @@ image "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless/flash.bin" 'Z' 'P'
 check "run.sh refuses while another guest holds the node image" '[ "$rc" -ne 0 ] && grep -q "already runs" "$T/run3.out"'
 check "the refused start leaves the node image untouched" '[ "$(stat -c %Y "$T/lhpc-state/node-flash.bin")" = "$before" ]'
 kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
+rm -f "$QEMU_STUB_ARGS"
 "$R/scripts/run.sh" --qemu "$T/qemu-stub" --node-image "$T/lhpc-state/node-flash.bin" > "$T/run4.out" 2>&1; rc=$?
-check "once the holder is gone the next start runs" '[ "$rc" -eq 0 ]'
+# The stub exits at once, so run.sh reports a failed provisioning (rc 3); what matters here is that the
+# lock no longer refuses and the guest is launched.
+check "once the holder is gone the next start runs" '! grep -q "already runs" "$T/run4.out" && [ -s "$QEMU_STUB_ARGS" ]'
 
 if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
 echo "FAILURES: $FAILS"; exit 1
diff --git a/tests/test-run-supervisor.sh b/tests/test-run-supervisor.sh
new file mode 100644
index 00000000..e9e217b8
--- /dev/null
+++ b/tests/test-run-supervisor.sh
@@ -0,0 +1,196 @@
+#!/usr/bin/env bash
+#
+# test-run-supervisor.sh — tests for scripts/run.sh as the guest's supervisor and provisioner, and for
+# scripts/stop.sh / scripts/status.sh. No QEMU and no network: a stub stands in for qemu-system-xtensa and
+# plays the firmware's part from a plan (one mode per launch), including a console on 127.0.0.1:12323 and
+# a web page on 127.0.0.1:18083 for run.sh's persisted-state check. Needs those two ports free.
+#
+# EXIT CODES: 0 = all cases passed (prints ALL PASS) · 1 = a failure (prints FAILURES).
+# Each check is an eval'd string, so its variables look unexpanded/unused to shellcheck.
+# shellcheck disable=SC2016,SC2034
+set -u
+
+HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
+REPO="$HERE/.."
+T="$(mktemp -d)"
+FAILS=0
+ok()   { echo "  ok   $1"; }
+bad()  { echo "  FAIL $1"; FAILS=$((FAILS + 1)); }
+check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
+
+for p in 12323 18083; do
+	if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "SKIP-REFUSED: port $p is in use (a guest running?)"; exit 1; fi
+done
+
+# A sandbox copy of the deliverable with a dummy build.
+R="$T/repo"; mkdir -p "$R/scripts" "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless-extradio-gpsd"
+cp "$REPO"/scripts/{run.sh,stop.sh,status.sh,node-image.sh,node-efuse.sh} "$R/scripts/"
+head -c $((4 * 1024 * 1024)) /dev/zero > "$R/.work/MeshCom-Firmware/.pio/build/qemu-headless-extradio-gpsd/flash.bin"
+ENV=qemu-headless-extradio-gpsd
+
+# The stub. Modes (one line of $STUB_PLAN per launch, consumed in order):
+#   prov-ok            provisioning: prints CLIENT STARTED, acknowledges --netmode eth, exits 0
+#   prov-noack         provisioning: CLIENT STARTED, exits 0 without the acknowledgement
+#   prov-rc1           provisioning: CLIENT STARTED, exits 1
+#   prov-hang          provisioning: CLIENT STARTED, never ends
+#   boot SECS [INFO]   a boot: Ethernet mode + console lines, a console and a web page; resets (rc 0)
+#                      after SECS (inf = never). INFO replaces the --info reply's settings line.
+#   boot-noterm        a boot that ignores TERM (needs KILL)
+#   exit1              QEMU fails at once (rc 1)
+cat > "$T/qemu-stub" <<'EOF'
+#!/usr/bin/env python3
+import os, signal, socket, sys, threading, time
+if sys.argv[1:2] == ["--version"]:
+    print("QEMU emulator version 9.2.2"); sys.exit(0)
+plan, state = os.environ["STUB_PLAN"], os.environ["STUB_STATE"]
+lines = open(plan).read().splitlines()
+n = int(open(state).read()) if os.path.exists(state) else 0
+open(state, "w").write(str(n + 1))
+mode = (lines[n] if n < len(lines) else "boot inf").split(" ", 2)
+log = os.environ["STUB_LOG"]
+def note(s):
+    with open(log, "a") as f: f.write(s + "\n")
+note("launch %d %s" % (n, mode[0]))
+def out(s): sys.stdout.write(s + "\n"); sys.stdout.flush()
+signal.signal(signal.SIGTERM, lambda *a: (note("TERM %d" % n), sys.exit(0)))
+m = mode[0]
+if m == "exit1": sys.exit(1)
+if m.startswith("prov"):
+    out("CLIENT STARTED")
+    if m == "prov-rc1": time.sleep(0.5); sys.exit(1)
+    if m == "prov-noack": time.sleep(1); sys.exit(0)
+    if m == "prov-hang":
+        while True: time.sleep(1)
+    got = []
+    for raw in sys.stdin:
+        c = raw.strip(); got.append(c)
+        if c == "--netmode eth":
+            out("[CMD] netmode -> Ethernet")
+            with open(os.environ["STUB_STDIN"], "w") as f: f.write("\n".join(got) + "\n")
+            time.sleep(0.5); sys.exit(0)
+    sys.exit(0)
+if m == "boot-noterm":
+    signal.signal(signal.SIGTERM, lambda *a: note("TERM-ignored %d" % n))
+    while True: time.sleep(1)
+secs = float("inf") if mode[1] == "inf" else float(mode[1])
+info = mode[2] if len(mode) > 2 else "...NETWORK Mode:ETH ...MESH off ...EXTUDP off / Gateway off"
+def serve(port, handler):
+    srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
+    srv.bind(("127.0.0.1", port)); srv.listen(4)
+    while True:
+        c, _ = srv.accept(); threading.Thread(target=handler, args=(c,), daemon=True).start()
+def console(c):
+    c.sendall(b"OK\r\nMeshCom Console\r\nType --help for commands\r\n")
+    try:
+        if b"--info" in c.recv(256): c.sendall(("--info\n" + info + "\n...PASSWD <secret>\n").encode())
+        time.sleep(0.2)
+    finally: c.close()
+def web(c):
+    c.recv(1024); c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"); c.close()
+for p, h in ((12323, console), (18083, web)):
+    threading.Thread(target=serve, args=(p, h), daemon=True).start()
+out("[NET] Ethernet mode"); out("[CON ]...Console started on port 2323")
+t0 = time.time()
+while time.time() - t0 < secs: time.sleep(0.2)
+note("reset %d" % n); sys.exit(0)
+EOF
+chmod +x "$T/qemu-stub"
+export STUB_PLAN="$T/plan" STUB_STATE="$T/state" STUB_LOG="$T/stub.log" STUB_STDIN="$T/stdin"
+export FAST_RUN_S=2 RESTART_BUDGET=4 PROVISION_TIMEOUT=30
+NODE="$T/node/node-flash.bin"
+reset_case() {
+	pkill -f "[q]emu-stub" 2>/dev/null || true
+	rm -rf "$R/.run" "$T/node" "$STUB_STATE" "$STUB_LOG" "$STUB_STDIN"; printf '%s\n' "$@" > "$STUB_PLAN"
+}
+start() { "$R/scripts/run.sh" --env "$ENV" --qemu "$T/qemu-stub" --node-image "$NODE" > "$T/run.out" 2>&1 & RP=$!; }
+wait_for() { local i; for i in $(seq 1 "$2"); do eval "$1" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
+finish() { local i; for i in $(seq 1 "${1:-60}"); do kill -0 "$RP" 2>/dev/null || break; sleep 0.5; done; wait "$RP"; RC=$?; }
+
+echo "== provisioning"
+reset_case prov-ok "boot inf"
+start
+wait_for 'grep -q "provisioning verified" "$T/run.out"' 40
+check "a fresh node is provisioned, verified and the marker written" '[ -s "$NODE.provisioned" ]'
+check "the commands reach UART0 in order, --netmode eth last" '[ "$(tail -1 "$STUB_STDIN")" = "--netmode eth" ] && grep -qx -- "--mesh off" "$STUB_STDIN" && grep -qx -- "--gps on" "$STUB_STDIN"'
+check "the marker names the command list's sha256" '[ "$(cut -d" " -f2 "$NODE.provisioned")" = "$(sed "/^$/d" "$STUB_STDIN" | sha256sum | cut -d" " -f1)" ]'
+check "the --info reply is never written (no password field in any log)" '! grep -rq "PASSWD" "$R/.run" "$T/run.out"'
+check "uart-latest.log points at the supervised boot" '[ "$(readlink "$R/.run/uart-latest.log")" != "" ] && ! readlink "$R/.run/uart-latest.log" | grep -q provision'
+"$R/scripts/stop.sh" > "$T/stop.out"; finish
+check "stop.sh stops the runner, which exits 0" '[ "$RC" = 0 ] && grep -q "TERM 1" "$STUB_LOG"'
+printf '%s\n' "boot inf" > "$STUB_PLAN"; rm -f "$STUB_STATE"
+start; wait_for 'grep -q "launch 0 boot" "$STUB_LOG"' 20
+check "a second start with the marker does not provision again" '! grep -q "provisioning the node" "$T/run.out"'
+"$R/scripts/stop.sh" >/dev/null; finish
+echo "stamp other" > "$NODE.provisioned"; printf '%s\n' prov-ok "boot inf" > "$STUB_PLAN"; rm -f "$STUB_STATE"
+start; wait_for 'grep -q "provisioning verified" "$T/run.out"' 40
+check "a marker for another command list provisions again" 'grep -q "provisioning the node" "$T/run.out"'
+"$R/scripts/stop.sh" >/dev/null; finish
+
+for c in "prov-noack|no acknowledgement" "prov-rc1|QEMU exited rc=1" "prov-hang|timeout waiting"; do
+	mode="${c%%|*}"; msg="${c#*|}"
+	reset_case "$mode" "boot inf"
+	PROVISION_TIMEOUT=3 start; finish 40
+	check "$mode -> rc 3, no marker ($msg)" '[ "$RC" = 3 ] && [ ! -e "$NODE.provisioned" ] && grep -q "$msg" "$T/run.out"'
+done
+reset_case prov-ok "boot inf ...NETWORK Mode:ETH ...MESH on ...EXTUDP off / Gateway off"
+PROVISION_TIMEOUT=25 start; finish 80
+cp "$T/run.out" "$T/run-meshon.out"
+check "a persisted state with MESH on -> rc 3, no marker" '[ "$RC" = 3 ] && [ ! -e "$NODE.provisioned" ] && grep -qF "lacks '"'"'...MESH off'"'"'" "$T/run.out"'
+reset_case prov-hang
+start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20; sleep 1
+kill -TERM "$RP"; finish
+check "TERM during provisioning -> rc 0, no marker, the stub stopped" '[ "$RC" = 0 ] && [ ! -e "$NODE.provisioned" ] && grep -q "TERM 0" "$STUB_LOG"'
+reset_case prov-hang; mkdir -p "$R/.run"; echo old > "$R/.run/uart-old.log"; ln -sf uart-old.log "$R/.run/uart-latest.log"
+start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20
+check "an old uart-latest.log is gone while provisioning runs" '[ ! -e "$R/.run/uart-latest.log" ]'
+kill -TERM "$RP"; finish
+
+echo "== supervision (FAST_RUN_S=2, RESTART_BUDGET=4)"
+mark() { mkdir -p "$(dirname "$NODE")"; "$R/scripts/node-image.sh" "$R/.work/MeshCom-Firmware/.pio/build/$ENV/flash.bin" "$NODE" >/dev/null; \
+	printf '%s\n' "--setssid qemu0" "--setpwd qemu0000" "--webserver on" "--netconsole on" "--mesh off" "--gateway off" "--extudp off" "--gps on" "--wifiap off" "--netmode eth" \
+	| sha256sum | cut -d' ' -f1 | sed 's/^/2026-01-01T00:00:00Z /' > "$NODE.provisioned"; }
+reset_case "boot 0.3" "boot 0.3" "boot 0.3" "boot inf"; mark
+start; finish 40
+check "3 runs shorter than FAST_RUN_S in a row -> rc 75" '[ "$RC" = 75 ] && grep -q "3 runs shorter" "$T/run.out"'
+reset_case "boot 2.5" "boot 0.3" "boot 0.3" "boot 2.5" "boot 0.3" "boot inf"; mark
+RESTART_BUDGET=10 start; wait_for 'grep -q "launch 5" "$STUB_LOG"' 60
+check "a run of at least FAST_RUN_S resets the fast count" 'kill -0 "$RP" 2>/dev/null && grep -q "restart #5" "$T/run.out"'
+check "each restart is recorded in .run/restarts" '[ "$(cut -d" " -f1 "$R/.run/restarts")" = 5 ]'
+"$R/scripts/stop.sh" >/dev/null; finish
+reset_case "boot 2.2" "boot 2.2" "boot 2.2" "boot 2.2" "boot 2.2" "boot inf"; mark
+start; finish 80
+check "more than RESTART_BUDGET restarts within an hour -> rc 75" '[ "$RC" = 75 ] && grep -q "more than 4 restarts" "$T/run.out"'
+reset_case exit1; mark
+start; finish 20
+check "QEMU exiting rc 1 -> rc 5" '[ "$RC" = 5 ] && grep -q "QEMU exited rc=1" "$T/run.out"'
+reset_case boot-noterm; mark
+start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20; sleep 1
+t0=$(date +%s); kill -TERM "$RP"; finish 40; dt=$(( $(date +%s) - t0 ))
+check "a guest ignoring TERM is killed after about 10 s, rc 0" '[ "$RC" = 0 ] && grep -q "TERM-ignored 0" "$STUB_LOG" && [ "$dt" -ge 9 ] && ! pgrep -f "[q]emu-stub" >/dev/null'
+reset_case "boot 1"; mark
+start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20
+kill -TERM "$RP"; finish
+sleep 2
+check "a stop between runs launches nothing more" '[ "$RC" = 0 ] && ! grep -q "launch 1" "$STUB_LOG"'
+
+echo "== ownership (stop.sh, a second runner, status.sh)"
+reset_case "boot inf"; mark
+start; wait_for 'grep -q "launch 0" "$STUB_LOG"' 20
+"$R/scripts/run.sh" --env "$ENV" --qemu "$T/qemu-stub" --node-image "$T/other/node.bin" > "$T/run2.out" 2>&1; rc2=$?
+check "a second run.sh in the same checkout is refused" '[ "$rc2" = 1 ] && grep -q "another run.sh" "$T/run2.out"'
+sleep 100 & DECOY=$!
+cp "$R/.run/run.pid" "$T/run.pid.real"; echo "$DECOY" > "$R/.run/run.pid"; echo "$DECOY" > "$R/.run/qemu.pid"
+"$R/scripts/stop.sh" > "$T/stop2.out"; src=$?
+check "stop.sh does not signal a reused pid (rc 0)" '[ "$src" = 0 ] && kill -0 "$DECOY" 2>/dev/null && grep -q "not this checkout" "$T/stop2.out"'
+kill "$DECOY"; cp "$T/run.pid.real" "$R/.run/run.pid"
+"$R/scripts/status.sh" > "$T/status.out"; ssrc=$?
+check "status.sh shows a running guest, rc 0" '[ "$ssrc" = 0 ]'
+"$R/scripts/stop.sh" >/dev/null; finish
+"$R/scripts/stop.sh" > "$T/stop3.out"; s3=$?
+"$R/scripts/status.sh" > "$T/status2.out"; s4=$?
+check "stop.sh and status.sh return 0 with nothing running" '[ "$s3" = 0 ] && [ "$s4" = 0 ] && grep -q "nothing was running" "$T/stop3.out"'
+
+pkill -f "[q]emu-stub" 2>/dev/null || true
+[ "$FAILS" -eq 0 ] && rm -rf "$T" || echo "(kept: $T)"
+if [ "$FAILS" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
+echo "FAILURES: $FAILS"; exit 1
diff --git a/tests/xr-tap.py b/tests/xr-tap.py
new file mode 100755
index 00000000..13e5badf
--- /dev/null
+++ b/tests/xr-tap.py
@@ -0,0 +1,39 @@
+#!/usr/bin/env python3
+#
+# xr-tap.py LISTEN_PORT BRIDGE_PORT LOG — forward one external-radio (XR) TCP connection at a time and
+# log every frame: direction, type, length and, for TX_REQUEST, payload byte 0 (0x21 = a position).
+# The XR header is magic "XR", version, type, length (big-endian), seq (lib/external_radio_protocol).
+import socket, sys, threading
+NAMES = {1:"HELLO",2:"HELLO_ACK",3:"AUTH_CHALLENGE",4:"AUTH_RESPONSE",5:"AUTH_RESULT",6:"CONFIGURE",7:"CONFIG_RESULT",
+         8:"RX_PACKET",9:"TX_REQUEST",10:"TX_RESULT",11:"PING",12:"PONG",13:"ERROR"}
+lport, bport, logp = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
+log = open(logp, "a", buffering=1)
+def pump(src, dst, tag):
+    buf = b""
+    while True:
+        try:
+            d = src.recv(4096)
+        except OSError:          # the other direction closed both sockets
+            return
+        if not d:
+            for s in (src, dst):
+                try: s.close()
+                except OSError: pass
+            return
+        try:
+            dst.sendall(d)
+        except OSError:
+            return
+        buf += d
+        while len(buf) >= 8:
+            if buf[0:2] != b"XR":
+                log.write(f"{tag} BADMAGIC\n"); buf = b""; break
+            n = int.from_bytes(buf[4:6], "big")
+            if len(buf) < 8 + n: break
+            extra = (" payload0=0x%02x" % buf[8]) if buf[3] == 9 and n > 0 else ""
+            log.write(f"{tag} {NAMES.get(buf[3], hex(buf[3]))} len={n}{extra}\n"); buf = buf[8 + n:]
+srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("127.0.0.1", lport)); srv.listen(1)
+while True:
+    c, _ = srv.accept(); b = socket.create_connection(("127.0.0.1", bport))
+    threading.Thread(target=pump, args=(c, b, "node>bridge"), daemon=True).start()
+    threading.Thread(target=pump, args=(b, c, "bridge>node"), daemon=True).start()
```
