# Building from source

All artifacts are reproducible from pinned upstream tags + the tracked `.patch` files. The binaries themselves are **not** in git.

## One command

```bash
./build-deps.sh            # build dxvk + moltenvk + bridge (skips targets whose output exists)
./build-deps.sh --force    # rebuild everything
./build-deps.sh dxvk       # one target only: dxvk | moltenvk | bridge
BUILD_ROOT=/path ./build-deps.sh   # override scratch clone dir (default /tmp/l4d2-deps-build)
```

## What it builds

### DXVK (`build_dxvk`)
- Clones `doitsujin/dxvk` @ **v1.10.3** (shallow, with submodules).
- Applies `dxvk-build/shadow-sampler-workaround.patch`.
- Meson + Ninja, cross-compiled to **i686/win32** (mingw-w64).
- Output: `dxvk-build/dxvk_d3d9.dll` (only the d3d9 target is used).

### MoltenVK (`build_moltenvk`)
- Clones `KhronosGroup/MoltenVK` @ **v1.4.1**.
- `fetchDependencies --macos` builds SPIRV-Cross/Tools/glslang (slow first time, ~10 min; cached after).
- Applies the **comprehensive session patch** `moltenvk-build/session-patches/moltenvk-all-edits-latest.patch` (regenerated 2026-06-04). This patch carries the **attachment-less-skip `0x010c` HDR fix** — when a render pass has no color/depth/stencil attachment, MoltenVK skips creating the Metal render command encoder, dodging the AGX `0x010c` device-lost that made HDR unplayable (issue #2) — **in addition to** the older null-descriptor fallback and the rest of the MoltenVK edits. It also bundles the diagnostic instrumentation and a command-buffer splitter (see the env vars below).
- `make macos`.
- Output: `moltenvk-build/libMoltenVK.dylib`.

**Runtime env vars baked into this build:**

| Env var | Default | Effect |
|---|---|---|
| `L4D2_MVK_SKIP_NOATT` | **on** | The attachment-less-skip `0x010c` HDR fix. Set `=0` to **disable** it (re-introduces the fault — useful only to reproduce/measure it). |
| `MVK_L4D2_DEBUG` | off | Diagnostics: `[mvk-tiledbg]` per-render-pass attachment-footprint logging (format, samples, bytes/pixel) + per-encoder/userInfo GPU-fault dump. |
| `MVK_L4D2_SYNC` | off | Commits + `waitUntilCompleted` per command buffer to name the exact faulting buffer in lockstep. Very slow; diagnosis only. |
| `L4D2_MVK_MAX_PASSES` | off | Command-buffer splitter — cap render passes per command buffer (e.g. `=1` for one pass each). Used with `MVK_L4D2_SYNC` to isolate the faulting pass. Diagnosis only. |

### Bridge (`build_bridge`)
- `python3 gen_vtables.py` → regenerates `vtables_generated.c` from `bridge/sdk/`.
- `i686-w64-mingw32-gcc` → `bridge/steam_api.dll` (32-bit, no CRT).
- `clang -arch arm64` → `bridge/steam_helper` (native macOS helper).

## Toolchain prerequisites

```bash
brew install meson ninja glslang        # DXVK
# mingw-w64 (i686-w64-mingw32-gcc) for the 32-bit Windows targets
# Xcode + command line tools for MoltenVK (make macos) and the arm64 helper
```
MinGW-w64 14+ needs `<cstdint>` added to many DXVK headers and a struct gated out — the patch + build script handle this.

## Helper build scripts

- **`build-deps-guarded.sh`** — wraps the MoltenVK build with a **stall guard**. Xcode's `SWBBuildService` has deadlocked here (clang stuck at 0% CPU). The guard watches clang CPU-time across two 40 s windows and force-kills a hung build (exit 9). Use this if `make macos` hangs.
- **`build140-clean.sh`** — A/B helper: checks out MoltenVK **v1.4.0** (clean, no patches) reusing the cached `External/` deps from the 1.4.1 build, rebuilds, and deploys to Whisky — for occlusion-subsystem comparison testing. (The 1.4.0 transplant experiment was ultimately refuted; see [04-components.md](04-components.md#moltenvk--moltenvk-build).)

## Deploying a rebuilt MoltenVK (important gotcha)

`play-l4d2.sh`'s `ensure_patched_moltenvk` checks for a **marker string** in the already-installed dylib and may **skip** redeploying a freshly rebuilt one. After rebuilding, deploy manually:

```bash
WL=~/L4D2-launcher/whisky-wine/Libraries   # (Whisky lib dir containing libMoltenVK.dylib)
cp moltenvk-build/libMoltenVK.dylib "<whisky MoltenVK path>"
codesign --force --sign - -i "org.l4d2launcher.moltenvk.$(date +%s)" "<deployed dylib>"
```
The unique `-i` identifier matters — Rosetta's AOT cache keys on the code signature, so a stale signature can serve a stale translation.

## Deploying a rebuilt DXVK

`do_install_bridge` copies `dxvk-build/dxvk_d3d9.dll` into the game's `bin/dxvk_d3d9.dll` (size/content check). To swap the 2.5.3 stash in for testing:
```bash
cp dxvk-build/dxvk_d3d9.dll.253-stash "<game>/bin/dxvk_d3d9.dll"
```
(Back up the current `bin/dxvk_d3d9.dll` first; 2.5.3 may need MAB-off + the feature gating from `#61`.)
