#!/usr/bin/env bash
#
# build-qemu.sh — build a HEADLESS qemu-system-xtensa FROM SOURCE (SDL/GTK/VNC/OpenGL/audio-free) at the
# pinned Espressif commit and publish it transactionally into a target directory. Managed provisioning
# step: lhpc calls it with an in-root {root}/build/tool-cache/... dest and the link-gate asset path.
#
#   build-qemu.sh <destination> --link-gate <path-to-meshtastic-link-gate.sh>
#
# WHY from source: the prebuilt Espressif tarball (fetch-qemu.sh) hard-links libSDL2; on a headless box
# it cannot load, and satisfying libSDL2 drags in a ~35-package graphics/audio cascade. A source build
# configured with the display/audio back-ends disabled has NO such dependency, and the LINK GATE proves
# it on the FINAL STRIPPED binary before the install is ever marked valid.
#
# Layout produced: <dest>/qemu/bin/qemu-system-xtensa (matches run.sh's PATH/-qemu default). Completion
# marker: <dest>/.lhpc-qemu-built (schema + source commit + config hash + final-binary hash). This marker
# is DISTINCT from fetch-qemu.sh's .lhpc-qemu-verified, and this script recomputes the hashes, so a
# FETCHED install can never be mistaken for a source-built one (and vice-versa).
#
# The transaction (lock / staging / backup / atomic-rename / rollback / startup-recovery) is the shared
# scripts/lib-publish.sh, so the trickiest code lives in ONE tested place. The publish order here differs
# from fetch's: the completion marker is written AFTER the staged tree is renamed into place and the
# FINAL-PATH binary passes a bounded smoke launch — which opens a post-rename/pre-marker crash window
# that pub_startup_recovery handles on the next run.
#
# Exit codes: 2 usage · 3 missing prerequisite · 4 symlink/non-regular path refusal · 5 busy · 1 other.
set -eu

# ---- pinned source (immutable) ----------------------------------------------------------------------
QEMU_TAG="esp-develop-9.0.0-20240606"
QEMU_COMMIT="abb5ce24386972e048b401f9eca10e90b8427a20"   # peeled commit of refs/tags/$QEMU_TAG
QEMU_REMOTE="https://github.com/espressif/qemu.git"
TARGET_LIST="xtensa-softmmu"
EXPECT_MACHINE="esp32"
EXPECT_NIC="open_eth"

# Feature-affecting configure arguments ONLY (NO prefix / DESTDIR / paths / job count) — these plus the
# pinned commit and the target/machine/NIC/strip policy define the canonical config contract hashed into
# the marker. We do NOT use --without-default-features: it disables QEMU's crypto backend, and the esp32
# machine ABORTS at init on a "missing object type 'misc.esp32.rsa'" (the ESP32 RSA accelerator needs
# QEMU crypto) — proven live. Instead we keep QEMU's normal auto-detected feature set and EXPLICITLY
# disable only the display + audio back-ends; the link gate on the final stripped binary is the
# authoritative proof that no SDL/X11/Wayland/Mesa/GL/PulseAudio/ALSA library linked. slirp + pixman are
# --enabled (fail-loud) because the emulator + meshcom's user-net require them. QEMU 9.0 fetches a few
# pinned meson subprojects (keycodemapdb + berkeley softfloat/testfloat) by git from QEMU's own mirror
# at in-tree-pinned revisions — controlled + reproducible, NOT the PyPI danger. The genuine danger (QEMU
# bootstrapping meson from PyPI when the SYSTEM meson is too old) is refused up front by the system-meson
# version gate below: with a new-enough system meson QEMU's mkvenv "operates offline and does not check
# PyPI".
CONFIGURE_FEATURE_ARGS=(
	"--target-list=${TARGET_LIST}"
	"--disable-sdl"
	"--disable-gtk"
	"--disable-vnc"
	"--disable-opengl"
	"--disable-curses"
	"--disable-alsa"
	"--disable-oss"
	"--disable-pa"
	"--disable-jack"
	"--audio-drv-list="
	"--disable-debug-info"
	"--disable-tools"
	"--disable-docs"
	# A PINNED older QEMU (9.0, 2024) built with a NEWER distro compiler (Trixie's gcc) trips QEMU's
	# default -Werror on compiler-version warnings (e.g. -Wformat-truncation / -Warray-bounds in the net
	# code) that are toolchain noise, not real defects in the pinned source. Disable -Werror so the pin
	# compiles on the target's current gcc; correctness is unaffected and the link gate + smoke still
	# prove the produced binary.
	"--disable-werror"
	"--enable-slirp"
	"--enable-pixman"
	# REQUIRED for the ESP32 machine: the fork gates its RSA/AES accelerator devices (hw/misc/esp32_rsa.c,
	# which calls libgcrypt's gcry_mpi_*) on `if gcrypt.found()`. Without libgcrypt the esp32 machine
	# ABORTS at init on "missing object type 'misc.esp32.rsa'" (proven live). --enable-gcrypt makes a
	# missing libgcrypt a HARD configure failure instead of a silently-broken emulator.
	"--enable-gcrypt"
)
# QEMU 9.0 needs meson >= 1.1.0; a system meson at least this new keeps mkvenv OFFLINE (no PyPI meson).
MIN_MESON="1.1.0"

BIN_REL="qemu/bin/qemu-system-xtensa"
MARKER_REL=".lhpc-qemu-built"
TAG="build-qemu"

# ---- args -------------------------------------------------------------------------------------------
DEST="${1:-}"
[ -n "$DEST" ] || { echo "usage: build-qemu.sh <destination> --link-gate <path>" >&2; exit 2; }
shift
LINK_GATE=""
while [ $# -gt 0 ]; do
	case "$1" in
		--link-gate) LINK_GATE="${2:?--link-gate needs a path}"; shift 2 ;;
		*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done
[ -n "$LINK_GATE" ] || { echo "ERROR: --link-gate <path> is required" >&2; exit 2; }

HERE="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib-publish.sh
. "$HERE/lib-publish.sh"

# ---- prerequisites ----------------------------------------------------------------------------------
PUB_TAG="$TAG"                         # so pub_need's messages are attributed correctly
for c in git gcc python3 ninja meson pkg-config strip readelf sha256sum timeout flock mktemp; do
	pub_need "$c"
done
# ldd is used by the link gate; prove it here too so the gate can never pass "silently".
command -v ldd >/dev/null 2>&1 || { echo "ERROR: $TAG needs 'ldd' on PATH (link gate closure)" >&2; exit 3; }

# System-meson version gate: QEMU 9.0 requires meson >= $MIN_MESON, AND a system meson at least this new
# is what keeps QEMU's mkvenv offline (no PyPI meson bootstrap — the real reproducibility danger). A
# too-old system meson is a HARD failure here; the fix is a newer SYSTEM meson, never enabling a PyPI
# install. (FAKE builds skip the compile, so the gate is only enforced for a real build.)
if [ -z "${LHPC_QEMU_FAKE_BUILD:-}" ]; then
	_mver="$(meson --version 2>/dev/null | head -1)"
	# pure-shell version compare: lowest of (found, MIN) must equal MIN.
	_low="$(printf '%s\n%s\n' "$_mver" "$MIN_MESON" | sort -V | head -1)"
	if [ -z "$_mver" ] || [ "$_low" != "$MIN_MESON" ]; then
		echo "ERROR: $TAG needs system meson >= $MIN_MESON (found '${_mver:-none}'). Install a newer" >&2
		echo "       SYSTEM meson (e.g. Debian Trixie's) — do NOT let QEMU pip-install one from PyPI." >&2
		exit 3
	fi
fi

# The link gate must be a readable file BEFORE we spend an hour building. It is invoked via `bash`
# (like the manifest's meshtastic call), so an execute bit that packaging may drop is not required.
[ -f "$LINK_GATE" ] && [ -r "$LINK_GATE" ] || {
	echo "ERROR: link-gate not a readable file: $LINK_GATE" >&2; exit 3; }

# pkg-config capabilities the headless xtensa-softmmu target actually links. Refined empirically on the
# Pi 5; each is a real per-capability probe (mirrors the manifest 'requires').
for cap in glib-2.0 pixman-1 slirp zlib libgcrypt; do
	pkg-config --exists "$cap" 2>/dev/null || {
		echo "ERROR: $TAG needs pkg-config capability '$cap' (install its -dev package)" >&2; exit 3; }
done

# ---- FAKE-BUILD test seam ---------------------------------------------------------------------------
# LHPC_QEMU_FAKE_BUILD=<dir> substitutes a pre-populated install tree (a real ELF stub at
# qemu/bin/qemu-system-xtensa) for the clone+configure+compile, so the transaction / RPATH check / strip
# / link gate / marker / smoke logic can be exercised for real in seconds. Test-only; never set in prod.
FAKE="${LHPC_QEMU_FAKE_BUILD:-}"

# ---- canonical config contract + hash ---------------------------------------------------------------
# Newline-delimited, path-free, order-stable. NO temp paths, detected deps, CPU/job count, or log text.
config_contract() {
	printf 'contract-schema=1\n'
	printf 'qemu_source_commit=%s\n' "$QEMU_COMMIT"
	printf 'target_list=%s\n' "$TARGET_LIST"
	printf 'expected_machine=%s\n' "$EXPECT_MACHINE"
	printf 'expected_nic=%s\n' "$EXPECT_NIC"
	printf 'strip=yes\n'
	printf 'debug_info=disabled\n'
	printf 'configure_arg=%s\n' "${CONFIGURE_FEATURE_ARGS[@]}"
}
CONFIG_SHA="$(config_contract | sha256sum | awk '{print $1}')"
[ -n "$CONFIG_SHA" ] || { echo "ERROR: could not compute config hash" >&2; exit 1; }

# A directory is a VALID source-built install iff it holds the exact build marker (schema, matching
# source commit + config hash) and a non-symlink executable binary whose sha256 matches the marker.
_valid_install() {
	local m="$1/$MARKER_REL" b="$1/$BIN_REL" got
	[ -f "$m" ] && [ ! -L "$m" ] || return 1
	grep -qxF "schema=1" "$m" || return 1
	grep -qxF "source_commit=${QEMU_COMMIT}" "$m" || return 1
	grep -qxF "config_sha256=${CONFIG_SHA}" "$m" || return 1
	[ -f "$b" ] && [ ! -L "$b" ] && [ -x "$b" ] || return 1
	got="$(sha256sum "$b" 2>/dev/null | awk '{print $1}')"
	grep -qxF "binary_sha256=${got}" "$m"
}

# ---- serialize + recover + idempotent skip ----------------------------------------------------------
if [ -L "$DEST" ]; then echo "[$TAG] destination path is a symlink — refusing: $DEST" >&2; exit 4; fi
pub_init "$DEST" "${LHPC_QEMU_LOCK_WAIT:-120}" "$TAG"
pub_startup_recovery _valid_install
if pub_skip_if_valid _valid_install; then
	pub_sweep_orphans
	echo "[$TAG] already source-built + verified: $DEST/$BIN_REL"
	exit 0
fi

# ---- preflight: space + inodes + same-filesystem staging --------------------------------------------
free_bytes() { df -PB1  "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
free_inodes(){ df -Pi   "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
if [ -n "$FAKE" ]; then MIN_BYTES=$((64*1024*1024)); MIN_INODES=2000
else MIN_BYTES="${LHPC_QEMU_MIN_FREE_BYTES:-$((6*1024*1024*1024))}"; MIN_INODES="${LHPC_QEMU_MIN_FREE_INODES:-200000}"; fi
fb="$(free_bytes "$PUB_PARENT")"; fi_="$(free_inodes "$PUB_PARENT")"
[ -n "$fb" ] && [ "$fb" -ge "$MIN_BYTES" ] || { echo "ERROR: $TAG needs >= $MIN_BYTES free bytes under $PUB_PARENT (have ${fb:-0})" >&2; exit 1; }
[ -n "$fi_" ] && [ "$fi_" -ge "$MIN_INODES" ] || { echo "ERROR: $TAG needs >= $MIN_INODES free inodes under $PUB_PARENT (have ${fi_:-0})" >&2; exit 1; }

# ---- staging (all temps scoped to the dest, under the SAME filesystem as the dest) ------------------
WORK=""; STAGEROOT=""
cleanup() {
	[ -n "${WORK:-}" ] && [ ! -L "$WORK" ] && rm -rf -- "$WORK" 2>/dev/null || true
	[ -n "${STAGEROOT:-}" ] && [ ! -L "$STAGEROOT" ] && rm -rf -- "$STAGEROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT
WORK="$(mktemp -d "${PUB_PARENT}/.qemu-work.${PUB_DNAME}.XXXXXX")"     # clone + build scratch
STAGEROOT="$(mktemp -d "${PUB_PARENT}/${PUB_STAGE_PREFIX}XXXXXX")"     # DESTDIR root (same fs as dest)
# same-filesystem assertion (guaranteed by construction; checked so a surprising mount is caught early)
[ "$(stat -c %d "$STAGEROOT")" = "$(stat -c %d "$PUB_PARENT")" ] || { echo "ERROR: staging not on the destination filesystem" >&2; exit 1; }

PREFIX="$DEST/qemu"                    # FINAL configured prefix (so the binary embeds no temp path)
STAGED="${STAGEROOT}${DEST}"           # DESTDIR install lands here (DEST is absolute)
STAGED_BIN="${STAGED}/${BIN_REL}"

# ---- build (or fake) --------------------------------------------------------------------------------
if [ -n "$FAKE" ]; then
	echo "[$TAG] FAKE build seam active — staging pre-built tree from $FAKE"
	[ -d "$FAKE" ] && [ -f "$FAKE/$BIN_REL" ] || { echo "ERROR: fake build dir missing $BIN_REL" >&2; exit 1; }
	mkdir -p "$(dirname -- "$STAGED")"
	cp -a "$FAKE" "$STAGED"
else
	SRC="$WORK/qemu"
	# Shallow clone of the EXACT pinned tag, pinned by full-SHA assertion below. We deliberately do NOT
	# `--recurse-submodules`: QEMU's git submodules are the roms/* firmware-blob trees (edk2, SLOF,
	# u-boot, skiboot, …) needed only to REBUILD pc-bios blobs for OTHER architectures — hundreds of MB,
	# irrelevant to a xtensa-softmmu emulator build and a disk risk on a Zero 2W. The emulator binary
	# builds from the in-tree sources plus SYSTEM libraries (glib/pixman/slirp/zlib/gcrypt). QEMU's own
	# pinned meson subprojects (keycodemapdb, berkeley softfloat/testfloat) are fetched by git at build
	# time. If a future feature needs a git submodule, initialize just that one — never the whole tree.
	echo "[$TAG] cloning $QEMU_REMOTE @ $QEMU_TAG (shallow, no submodules)"
	git clone --depth 1 --branch "$QEMU_TAG" "$QEMU_REMOTE" "$SRC"
	got_head="$(git -C "$SRC" rev-parse HEAD)"
	if [ "$got_head" != "$QEMU_COMMIT" ]; then
		echo "ERROR: cloned HEAD $got_head != pinned $QEMU_COMMIT — refusing" >&2; exit 1
	fi
	echo "[$TAG] resolved QEMU HEAD: $got_head (matches pin)"
	# No submodule is initialized (by design), so none can be modified/conflicted. Log the recorded
	# submodule pins for the record; a '+' (modified) or 'U' (conflicted) leaf — impossible on a fresh
	# clone — would still be refused.
	subst="$(git -C "$SRC" submodule status 2>&1 || true)"
	printf '%s\n' "$subst" | sed 's/^/[submodule] /' | head -n 40
	if printf '%s\n' "$subst" | grep -Eq '^[[:space:]]*[+U]'; then
		echo "ERROR: a submodule is modified/conflicted — refusing" >&2; exit 1
	fi

	# memory-aware -j = min(nproc, max(1, floor(MemTotal_GB)))  (EXACT build.sh formula)
	_ncpu="$(nproc 2>/dev/null || echo 1)"
	_memkb="$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
	_memgb=$(( _memkb / 1024 / 1024 )); [ "$_memgb" -lt 1 ] && _memgb=1
	if [ "$_ncpu" -lt "$_memgb" ]; then JOBS="$_ncpu"; else JOBS="$_memgb"; fi
	[ "$JOBS" -lt 1 ] && JOBS=1
	echo "[$TAG] building -j$JOBS (nproc=$_ncpu, memGB=$_memgb)"

	BUILD="$WORK/build"; mkdir -p "$BUILD"

	# libgcrypt detection compat shim. QEMU 9.0's meson finds libgcrypt via the legacy `libgcrypt-config`
	# tool, which Debian TRIXIE's libgcrypt20-dev no longer ships (libgcrypt 1.11 moved to pkg-config).
	# On Bookworm the tool exists and this is a no-op; on Trixie we synthesize a shim that answers the
	# `libgcrypt-config` interface from pkg-config, so `--enable-gcrypt` (REQUIRED for the esp32 machine)
	# succeeds without touching the pinned QEMU source. Only created when the tool is truly absent AND
	# pkg-config knows libgcrypt.
	if ! command -v libgcrypt-config >/dev/null 2>&1 && pkg-config --exists libgcrypt 2>/dev/null; then
		SHIMBIN="$WORK/shim-bin"; mkdir -p "$SHIMBIN"
		cat > "$SHIMBIN/libgcrypt-config" <<'SHIM'
#!/bin/sh
# compat shim: translate the legacy libgcrypt-config interface to pkg-config (libgcrypt 1.11 dropped it)
case "$1" in
	--version)     pkg-config --modversion libgcrypt ;;
	--cflags)      pkg-config --cflags libgcrypt ;;
	--libs)        pkg-config --libs libgcrypt ;;
	--prefix)      pkg-config --variable=prefix libgcrypt ;;
	--exec-prefix) pkg-config --variable=exec_prefix libgcrypt ;;
	--algorithms)  echo "" ;;
	*)             echo "" ;;
esac
SHIM
		chmod +x "$SHIMBIN/libgcrypt-config"
		PATH="$SHIMBIN:$PATH"
		echo "[$TAG] libgcrypt-config absent — using a pkg-config compat shim (libgcrypt $(pkg-config --modversion libgcrypt))"
	fi

	CFG_LOG="$WORK/configure.log"
	echo "[$TAG] configure --prefix=$PREFIX ${CONFIGURE_FEATURE_ARGS[*]}"
	( cd "$BUILD" && PATH="$PATH" "$SRC/configure" --prefix="$PREFIX" "${CONFIGURE_FEATURE_ARGS[@]}" ) >"$CFG_LOG" 2>&1 || {
		echo "ERROR: configure failed — tail:" >&2; tail -n 40 "$CFG_LOG" >&2; exit 1; }

	# NO PyPI bootstrap of the build system: the real reproducibility danger is QEMU's mkvenv pip-
	# installing meson (or ninja) from PyPI when the SYSTEM tool is too old. The version gate above
	# prevents it; assert it here too. QEMU's OWN pinned subproject wraps (keycodemapdb, berkeley
	# softfloat/testfloat), fetched by git from QEMU's mirror at in-tree-pinned revisions, are expected
	# and are NOT a PyPI download.
	if grep -Eiq 'mkvenv.*(installing|checking) .*PyPI|pip[[:space:]]+install.*(meson|ninja)|Installing collected packages.*meson|from pypi\.org' "$CFG_LOG"; then
		echo "ERROR: configure bootstrapped a build tool from PyPI — refusing (ensure a new-enough system meson)" >&2
		grep -Ein 'PyPI|pip install|Installing collected' "$CFG_LOG" >&2 | head -n 20
		exit 1
	fi
	# Positive proof that meson stayed offline (mkvenv reports it explicitly). Absence is not fatal on
	# its own — the negative guard above is authoritative — but log it for the record.
	grep -qiF 'did not check PyPI' "$CFG_LOG" && echo "[$TAG] meson/mkvenv operated offline (no PyPI)"
	# Configure summary must prove the xtensa-softmmu target.
	if ! grep -Eq "xtensa-softmmu" "$CFG_LOG"; then
		echo "ERROR: configure summary does not list the xtensa-softmmu target — refusing" >&2; exit 1; fi

	# Build ONLY the emulator target (not the default `all`, which also compiles the qtest suite): far
	# less work — critical on a Zero 2 W. `ninja install` then builds only remaining installables (the
	# emulator is done; data files like keymaps/pc-bios are copied) — tests are never installed. Capture
	# to a log and check the exit status explicitly: `ninja | tail` would MASK a build failure (the pipe
	# exit is tail's) under `set -eu` (no pipefail).
	echo "[$TAG] ninja build (qemu-system-xtensa only)"
	BLD_LOG="$WORK/ninja-build.log"
	if ! ( cd "$BUILD" && ninja -j "$JOBS" qemu-system-xtensa ) >"$BLD_LOG" 2>&1; then
		echo "ERROR: ninja build failed — tail:" >&2; tail -n 30 "$BLD_LOG" >&2; exit 1; fi
	tail -n 3 "$BLD_LOG"
	echo "[$TAG] install (DESTDIR staging with FINAL prefix $PREFIX)"
	( cd "$BUILD" && DESTDIR="$STAGEROOT" ninja install ) >/dev/null 2>&1 || {
		echo "ERROR: staged install failed" >&2; exit 1; }
fi

# ---- verify + strip the STAGED install --------------------------------------------------------------
[ -f "$STAGED_BIN" ] && [ ! -L "$STAGED_BIN" ] || { echo "ERROR: staged binary missing/symlink: $STAGED_BIN" >&2; exit 1; }
chmod u+w "$STAGED_BIN" 2>/dev/null || true
strip "$STAGED_BIN" 2>/dev/null || { echo "ERROR: strip failed on $STAGED_BIN" >&2; exit 1; }

# ELF RPATH/RUNPATH must not reference the temp source/build/staging dirs (a leaked temp path would
# break the published binary). Check the binary's dynamic RPATH/RUNPATH entries ONLY — NOT every string
# in the tree (harmless debug/metadata strings would false-fail; the final-path smoke catches real
# breakage).
rpaths="$(readelf -d "$STAGED_BIN" 2>/dev/null | sed -n 's/.*(R\(UN\)\{0,1\}PATH).*\[\(.*\)\]$/\2/p' || true)"
if [ -n "$rpaths" ]; then
	echo "[$TAG] RPATH/RUNPATH: $rpaths"
	case "$rpaths" in
		*"$WORK"*|*"$STAGEROOT"*|*"$STAGED"*)
			echo "ERROR: staged binary RPATH references a temp build/staging dir — refusing" >&2; exit 1 ;;
	esac
fi

# --version + machine list on the staged binary.
if ! "$STAGED_BIN" --version 2>&1 | grep -qi "QEMU emulator version"; then
	echo "ERROR: staged binary --version did not identify as QEMU — refusing" >&2; exit 1; fi
if ! "$STAGED_BIN" -machine help 2>&1 | grep -Eq "(^|[^[:alnum:]_])${EXPECT_MACHINE}([^[:alnum:]_]|$)"; then
	echo "ERROR: staged binary does not list the '${EXPECT_MACHINE}' machine — refusing" >&2; exit 1; fi

# LINK GATE on the STRIPPED staged binary (authoritative headless proof) — before publishing.
if ! bash "$LINK_GATE" "$STAGED_BIN" "qemu-system-xtensa (headless source build)"; then
	echo "ERROR: link gate FAILED on the staged binary — refusing to publish" >&2; exit 1; fi

BIN_SHA="$(sha256sum "$STAGED_BIN" | awk '{print $1}')"
[ -n "$BIN_SHA" ] || { echo "ERROR: could not hash staged binary" >&2; exit 1; }

# ---- publish: backup -> rename -> FINAL-PATH smoke -> marker -> drop backup --------------------------
pub_backup                                   # moves any existing dest into a backup container
if ! pub_rename "$STAGED"; then
	echo "ERROR: publish rename failed for $DEST" >&2
	pub_restore_backup || true
	exit 1
fi
STAGED=""                                    # published — the trap must not remove it
DEST_BIN="$DEST/$BIN_REL"

# Bounded SMOKE on the FINAL-PATH binary: launching -machine esp32 with an open_eth user-net NIC and a
# blank 4 MB MTD image proves the machine model, the NIC and the user-net backend are all accepted and
# the loader/dynamic linker are satisfied on the PUBLISHED path. A blank image cannot boot firmware, so
# success = the process survives a short init window with no loader/machine/NIC/network error (the
# timeout terminates it); the real MeshCom endpoint + TX tests are the authoritative runtime proof.
SMOKE_IMG="$(mktemp "${PUB_PARENT}/.qemu-smoke.${PUB_DNAME}.XXXXXX")"
dd if=/dev/zero of="$SMOKE_IMG" bs=1M count=4 status=none 2>/dev/null || : > "$SMOKE_IMG"
SMOKE_LOG="$(mktemp "${PUB_PARENT}/.qemu-smokelog.${PUB_DNAME}.XXXXXX")"
smoke_rc=0
timeout "${LHPC_QEMU_SMOKE_SECS:-8}" "$DEST_BIN" \
	-nographic -serial null -monitor none \
	-machine "$EXPECT_MACHINE" -m 4M \
	-drive "file=$SMOKE_IMG,if=mtd,format=raw" \
	-nic "user,model=${EXPECT_NIC}" \
	>"$SMOKE_LOG" 2>&1 || smoke_rc=$?
smoke_fatal="$(grep -Ei 'cannot load|could not|no machine|unknown (machine|device|option)|missing object type|does not exist|not a valid|invalid (option|accelerator)|property .* not found|network backend|failed to|Segmentation|core dumped|assertion|abort' "$SMOKE_LOG" | head -n 5 || true)"
rm -f -- "$SMOKE_IMG"
if [ -n "$smoke_fatal" ]; then
	echo "ERROR: smoke launch reported a fatal error on the published binary:" >&2
	printf '  %s\n' "$smoke_fatal" >&2
	rm -f -- "$SMOKE_LOG"
	pub_restore_backup || true
	exit 1
fi
# A HEALTHY smoke either completes (0) or is terminated by the timeout (124) after surviving the init
# window. ANY other exit is a failure: a crash signal (134 SIGABRT — e.g. a machine device missing from
# the build; 139 SIGSEGV) or a config/parse error exit. Be strict — 0 or 124 pass, everything else fails.
if [ "$smoke_rc" != "0" ] && [ "$smoke_rc" != "124" ]; then
	echo "ERROR: smoke launch exited $smoke_rc (crash/error before timeout) on the published binary:" >&2
	printf '  %s\n' "$(tail -n 4 "$SMOKE_LOG")" >&2
	rm -f -- "$SMOKE_LOG"
	pub_restore_backup || true
	exit 1
fi
rm -f -- "$SMOKE_LOG"
echo "[$TAG] smoke OK (rc=$smoke_rc): esp32 + ${EXPECT_NIC} user-net accepted on the published binary"

# ---- atomically write the completion marker, THEN drop the backup -----------------------------------
MTMP="$DEST/.lhpc-qemu-built.tmp.$$"
{
	printf 'schema=1\n'
	printf 'source_commit=%s\n' "$QEMU_COMMIT"
	printf 'config_sha256=%s\n' "$CONFIG_SHA"
	printf 'binary_sha256=%s\n' "$BIN_SHA"
} > "$MTMP"
sync -f "$MTMP" 2>/dev/null || sync
mv -- "$MTMP" "$DEST/$MARKER_REL"
pub_drop_backup
pub_sweep_orphans
echo "[$TAG] provisioned + verified (source build) $DEST_BIN"
echo "[$TAG]   source_commit=$QEMU_COMMIT config_sha256=$CONFIG_SHA binary_sha256=$BIN_SHA"
