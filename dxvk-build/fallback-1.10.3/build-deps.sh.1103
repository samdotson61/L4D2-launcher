#!/usr/bin/env bash
# build-deps.sh — reproducibly build the two patched upstream dependencies
# (DXVK 1.10.3 and MoltenVK 1.4.1) from their pinned tags + our saved patches.
#
# The launcher (play-l4d2.sh) consumes the *output* binaries:
#     dxvk-build/dxvk_d3d9.dll
#     moltenvk-build/libMoltenVK.dylib
# but those are git-ignored build artifacts.  This script regenerates them
# from the tracked .patch files so a fresh checkout (or a cleared /tmp) can
# rebuild everything without hand-archaeology.
#
# Usage:
#     ./build-deps.sh            # build both (skips a dep if its artifact exists)
#     ./build-deps.sh --force    # rebuild both even if artifacts exist
#     ./build-deps.sh dxvk       # build only DXVK
#     ./build-deps.sh moltenvk   # build only MoltenVK
#     ./build-deps.sh bridge     # build only the steam_api bridge + helper
#     BUILD_ROOT=/path ./build-deps.sh   # override the scratch clone dir
#
# Pinned versions (must match what the patches were authored against):
#     DXVK     v1.10.3   https://github.com/doitsujin/dxvk
#     MoltenVK v1.4.1     https://github.com/KhronosGroup/MoltenVK
set -euo pipefail

LAUNCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/tmp/l4d2-deps-build}"

DXVK_TAG="v1.10.3"
DXVK_URL="https://github.com/doitsujin/dxvk.git"
DXVK_PATCH="$LAUNCHER_DIR/dxvk-build/shadow-sampler-workaround.patch"
DXVK_OUT="$LAUNCHER_DIR/dxvk-build/dxvk_d3d9.dll"

MVK_TAG="v1.4.1"
MVK_URL="https://github.com/KhronosGroup/MoltenVK.git"
MVK_PATCH="$LAUNCHER_DIR/moltenvk-build/null-descriptor-fallback.patch"
MVK_OUT="$LAUNCHER_DIR/moltenvk-build/libMoltenVK.dylib"

# ─── pretty output ────────────────────────────────────────────────────────────
say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$*"; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# ─── toolchain checks ─────────────────────────────────────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1 ($2)"; }

check_dxvk_tools() {
  need git    "brew install git"
  need meson  "brew install meson"
  need ninja  "brew install ninja"
  need i686-w64-mingw32-gcc "brew install mingw-w64"
}
check_mvk_tools() {
  need git        "brew install git"
  need xcodebuild "install Xcode (not just CLI tools) for the MoltenVK scheme build"
}
check_bridge_tools() {
  need i686-w64-mingw32-gcc "brew install mingw-w64"
  need clang   "install Xcode command-line tools"
  need python3 "brew install python3"
}

# ─── DXVK ──────────────────────────────────────────────────────────────────────
# L4D2.exe → dxvk_d3d9.dll → Vulkan.  We build only the d3d9 DLL (the d3d10/
# d3d11/dxgi targets also build but are unused by L4D2).
#
# The patch (shadow-sampler-workaround.patch) does two things:
#   1. Software depth-compare shadow sampling (MoltenVK can't bind a separate
#      depth-compare sampler at the same Metal texture slot as the color one).
#   2. mingw-w64 14.0+ header-conflict fixes (_D3DDEVINFO_RESOURCEMANAGER,
#      ID3D10StateBlock UUID, missing <cstdint> includes) so it compiles on
#      a current toolchain.
build_dxvk() {
  check_dxvk_tools
  [[ -f "$DXVK_PATCH" ]] || die "missing DXVK patch: $DXVK_PATCH"

  local src="$BUILD_ROOT/dxvk"
  if [[ ! -d "$src/.git" ]]; then
    say "Cloning DXVK $DXVK_TAG…"
    rm -rf "$src"
    git clone --branch "$DXVK_TAG" --depth 1 --recurse-submodules "$DXVK_URL" "$src" \
      || die "DXVK clone failed"
  else
    say "Reusing DXVK clone at $src"
  fi

  say "Resetting DXVK tree to pristine $DXVK_TAG…"
  git -C "$src" checkout -- . 2>/dev/null || true
  git -C "$src" clean -fdx src/ 2>/dev/null || true

  say "Applying shadow-sampler-workaround.patch…"
  git -C "$src" apply --verbose "$DXVK_PATCH" || die "DXVK patch failed to apply (tag drift?)"

  say "Configuring DXVK (meson, win32 cross)…"
  rm -rf "$src/build-32"
  ( cd "$src" && meson setup --cross-file build-win32.txt --buildtype release \
      --strip --prefix "$src/install" build-32 ) || die "meson setup failed"

  say "Building DXVK d3d9 target…"
  ( cd "$src" && ninja -C build-32 src/d3d9/d3d9.dll ) || die "ninja build failed"

  mkdir -p "$(dirname "$DXVK_OUT")"
  cp "$src/build-32/src/d3d9/d3d9.dll" "$DXVK_OUT"
  ok "DXVK built → $DXVK_OUT ($(du -h "$DXVK_OUT" | cut -f1))"
}

# ─── MoltenVK ──────────────────────────────────────────────────────────────────
# Vulkan → Metal.  The patch (null-descriptor-fallback.patch) carries every
# Apple-Silicon fix we found:
#   - null-descriptor fallback buffer/texture/sampler (unbound slots → zeros
#     instead of nil, so the GPU doesn't fault)
#   - isAppleGPU detection fixed for M-series (was gated on Apple1 family)
#   - robustImageAccess2 advertised on Apple GPUs
#   - MVKPipelineLayout always reserves a push-constant buffer slot per stage
#     (THE fix for the buffer(0) collision that dropped most fragment shaders)
#   - always-on encoder execution-status capture for GPU-fault diagnosis
#   - transient/lazily-allocated attachments use Private (real VRAM) storage
#     instead of Memoryless — Memoryless lives in the tiny tile-memory pool
#     allocated at pass EXECUTION, and L4D2's first full-scene frame overflows
#     it: kernel "IOGPUSysMemory::withOptions failed" → cmd-buffer abort 0x010c
#     → device lost → renders one frame then freezes.  MVK_L4D2_FORCE_PRIVATE_RT=0
#     reverts to stock memoryless for A/B testing.
#   - on a 0x010c with no encoder info, dump the full NSError userInfo +
#     NSUnderlyingError (domain/code) — names allocation/OOM aborts
build_moltenvk() {
  check_mvk_tools
  [[ -f "$MVK_PATCH" ]] || die "missing MoltenVK patch: $MVK_PATCH"

  local src="$BUILD_ROOT/MoltenVK"
  if [[ ! -d "$src/.git" ]]; then
    say "Cloning MoltenVK $MVK_TAG…"
    rm -rf "$src"
    git clone --branch "$MVK_TAG" --depth 1 "$MVK_URL" "$src" || die "MoltenVK clone failed"
  else
    say "Reusing MoltenVK clone at $src"
  fi

  say "Resetting MoltenVK tree to pristine $MVK_TAG…"
  git -C "$src" checkout -- . 2>/dev/null || true

  # fetchDependencies builds SPIRV-Cross / SPIRV-Tools / glslang etc.  It's
  # expensive (~10 min first time) so skip if the External tree is populated.
  if [[ ! -d "$src/External/build/Release" ]]; then
    say "Fetching + building MoltenVK external dependencies (slow, ~10 min)…"
    ( cd "$src" && ./fetchDependencies --macos ) || die "fetchDependencies failed"
  else
    say "Reusing MoltenVK external dependencies"
  fi

  say "Applying null-descriptor-fallback.patch…"
  git -C "$src" apply --verbose "$MVK_PATCH" || die "MoltenVK patch failed to apply (tag drift?)"

  say "Building MoltenVK (make macos)…"
  ( cd "$src" && make macos ) || die "make macos failed"

  local built="$src/Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
  [[ -f "$built" ]] || die "MoltenVK build produced no dylib at $built"
  mkdir -p "$(dirname "$MVK_OUT")"
  cp "$built" "$MVK_OUT"
  ok "MoltenVK built → $MVK_OUT ($(du -h "$MVK_OUT" | cut -f1))"
}

# ─── Bridge (steam_api.dll + steam_helper) ────────────────────────────────────
# Thin wrapper around the same commands play-l4d2.sh uses, exposed here so
# `build-deps.sh bridge` rebuilds the whole dependency set in one place.
build_bridge() {
  check_bridge_tools
  local b="$LAUNCHER_DIR/bridge"

  say "Generating vtables from SDK headers…"
  ( cd "$b" && python3 gen_vtables.py > vtables_generated.c 2>err.log ) \
    || die "gen_vtables.py failed (see $b/err.log)"

  say "Compiling steam_api.dll (i686 mingw, no-CRT)…"
  ( cd "$b" && i686-w64-mingw32-gcc -shared -m32 -O2 \
        -nostdlib -nodefaultlibs -Wno-attributes -fno-stack-protector \
        -Wl,--enable-stdcall-fixup -Wl,--kill-at \
        -o steam_api.dll steam_api_wine.c steam_api.def \
        -lkernel32 -luser32 -lws2_32 ) || die "DLL build failed"

  say "Compiling native helper (arm64)…"
  ( cd "$b" && clang -arch arm64 -O2 -Wall -o steam_helper steam_helper.c ) \
    || die "helper build failed"

  ok "Bridge built → $b/steam_api.dll + $b/steam_helper"
}

# ─── driver ────────────────────────────────────────────────────────────────────
FORCE=0
TARGETS=()
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    dxvk|moltenvk|bridge) TARGETS+=("$arg") ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $arg (try --help)" ;;
  esac
done
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(dxvk moltenvk bridge)

mkdir -p "$BUILD_ROOT"
say "Build root: $BUILD_ROOT"
say "Targets: ${TARGETS[*]}${FORCE:+ (force)}"

for t in "${TARGETS[@]}"; do
  case "$t" in
    dxvk)
      if [[ $FORCE -eq 0 && -f "$DXVK_OUT" ]]; then ok "DXVK artifact exists, skipping (use --force)"; else build_dxvk; fi ;;
    moltenvk)
      if [[ $FORCE -eq 0 && -f "$MVK_OUT" ]]; then ok "MoltenVK artifact exists, skipping (use --force)"; else build_moltenvk; fi ;;
    bridge)
      build_bridge ;;  # always rebuilds; it's fast
  esac
done

say "Done. Install into the game with:  ./play-l4d2.sh --install-bridge"
