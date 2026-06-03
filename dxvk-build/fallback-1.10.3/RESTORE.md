# Fallback: known-good DXVK 1.10.3 stack (backed up 2026-06-02)

This is the **proven-stable** rendering stack — single-player playable at max settings,
0 `0x010c` faults. Archived before experimenting with DXVK 2.5.3 (Phase 1 / A1 options 2 & 3),
so the working build can always be restored.

## Contents
- `dxvk_d3d9.dll` — the source-built **DXVK 1.10.3** (sha1 `f9a30c601f54acc28be206c49df0643780781f3f`,
  `v1.10.3+`). Carries the shadow-sampler workaround + pushConstSize fix.
- `shadow-sampler-workaround.patch` — the DXVK 1.10.3 source patch that produces the DLL above
  (software depth-compare shadow sampling, pushConstSize fix, geometryShader/cullDistance gating,
  robustImageAccess2, mingw build fixes).
- `null-descriptor-fallback.patch` — the **MoltenVK 1.4.1** patch (unchanged by the 2.5.3 work, kept
  here for a complete snapshot). The patched `libMoltenVK.dylib` itself rebuilds from this via
  `build-deps.sh moltenvk`.
- `build-deps.sh.1103` — the build script pinned to `DXVK_TAG="v1.10.3"` (option 3 edits the live
  `build-deps.sh` to target 2.5.3; this is the original).

## Restore the working build
```sh
cd ~/l4d2-launcher
cp dxvk-build/fallback-1.10.3/dxvk_d3d9.dll dxvk-build/dxvk_d3d9.dll   # restore deploy-source
./play-l4d2.sh --install-bridge                                        # redeploy into the game's bin/
# (or copy straight into the game folder:)
# cp dxvk-build/dxvk_d3d9.dll "$HOME/Library/Application Support/Steam/steamapps/common/Left 4 Dead 2/bin/dxvk_d3d9.dll"
```
If `build-deps.sh` was changed to build 2.5.3, also: `cp dxvk-build/fallback-1.10.3/build-deps.sh.1103 build-deps.sh`.

There are also loose 1.10.3 copies at `dxvk-build/dxvk_d3d9.dll.{1103-backup,pre-a1,hdrlog-orig}` (all `f9a30c6…`).
