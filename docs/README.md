<!--
  This README is kept BYTE-IDENTICAL in two places:
     • /README.md            (the GitHub front page)
     • /docs/README.md       (the documentation index)
  Edit BOTH together, every time. Internal links are absolute GitHub URLs so the
  same file renders correctly from the repo root and from docs/.
  See the docs-in-lockstep rule in docs/08-roadmap.md.
-->

# L4D2 wrapper for Apple Silicon macOS 26

Runs **Left 4 Dead 2** (the 32-bit Windows build) on Apple Silicon, signed in to your real Steam
account. **Single-player is playable today, and HDR is now playable at max settings** — the GPU device-lost fault that used to make HDR-on freeze is fixed (2026-06-04; see [issue #2](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/03-known-issues.md)). **Online multiplayer** and
**portability to any Apple Silicon Mac** are the remaining active work — see the **[Roadmap](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/08-roadmap.md)**.

Left 4 Dead 2's native macOS build is 32-bit (i386). macOS dropped 32-bit support at Catalina, and
Rosetta 2 only translates 64-bit x86 — so the Mac binaries are dead and Valve isn't updating them.
Steam still ships the *Windows* binaries (`left4dead2.exe` + DLLs) into the same install folder, so this
wrapper runs **those** through a translation stack instead. This is a research/hobby project, not a
turnkey installer.

## Status at a glance

Current baseline: `git HEAD 9a5dedf` (*"working and playable my boy"*, committed 2026-06-04) — the **2026-06-03 HDR-rendering fix** and the **2026-06-04 HDR-playability fix** are now committed; HDR renders **and is playable** at max settings (see the HDR row).

| Aspect | State |
|---|---|
| Launches to main menu | Working |
| Loads into a campaign (renders, HUD, weapons, bots) | Working (single-player) |
| Framerate (native res, max settings) | ~90–130 fps on the test map |
| Max settings (4× MSAA + multicore + max textures) | **Default, not forced** — the launcher seeds the max baseline on first run; in-game Options → Video changes then persist across restarts (`--max-settings` re-applies max). *(policy revised 2026-06-04, C2)* |
| **HDR / tonemapping + DX9 shading** | **Playable** — rendering fixed 2026-06-03 (was our own `+mat_hdr_level 1` pin; removed → engine default = full HDR, at DX9.5 `mat_dxlevel 100`); **playability fixed 2026-06-04** — the `0x010c` device-lost was an **attachment-less render pass** (a 16384×16384 pass with zero attachments hard-aborts the AGX GPU), now skipped in patched MoltenVK. User played levels 1→2 with no freeze/crash; 0 faults in 150 s runs. Only residual: an occasional stutter ([issue #5](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/03-known-issues.md)). ([issue #2](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/03-known-issues.md)) |
| Flashlight shadow | On (`r_flashlightdepthtexture 1`) — dynamic shadows render |
| **Online / multiplayer** | **Not working** — bridge plumbing present, but the engine is never put into Steam "online mode" → [Phase 2](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/08-roadmap.md) |
| **Portability (any Apple Silicon Mac)** | Goal — **all six per-machine items (D1–D6) are code-complete** (dylib path, dynamic resolution, Mac-Steam + GPU preflight, computed launcher dir; 2026-06-04). Only **validation** remains: a clean-Mac build + a non-M4 Apple Silicon test → [Phase 3](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/08-roadmap.md) |

## The stack

```
  left4dead2.exe  (32-bit PE, Source engine build 9477)
        │
        ├── steam_api.dll ──────────►  steam_helper            ──►  Mac Steam
        │   our bridge (PE32 i386)     our native arm64 proxy       (signed in,
        │   TCP localhost:54550 ───────────────────────────────►    steam_osx)
        │
        ├── dxvk_d3d9.dll   (DXVK 1.10.3 + our patches)   D3D9 → Vulkan
        │        │
        │        └── winevulkan → libMoltenVK.dylib       Vulkan → Metal
        │            (MoltenVK 1.4.1 + our patches)
        │
        └── engine.dll / client.dll / matchmaking.dll     in-place byte patches

        all running under Whisky-Wine 11 (Wine 11.0, x86_64 host / i386 guest) + Rosetta 2
```

## Documentation

Full docs live in [`docs/`](https://github.com/samdotson61/L4D2-launcher/tree/main/docs). **This README and
[`docs/README.md`](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/README.md) are kept
byte-identical** — edit both together.

| Doc | Contents |
|---|---|
| [01 — Current state](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/01-current-state.md) | Playability, what works/doesn't, exact deployed config, repo state |
| [02 — Architecture](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/02-architecture.md) | How the whole stack fits together; why each layer exists |
| [03 — Known issues](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/03-known-issues.md) | Every open/known issue: symptom, cause, workaround, status |
| [04 — Components](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/04-components.md) | The Steam bridge, DXVK build + patch, MoltenVK build + patch, binary patches |
| [05 — Usage](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/05-usage.md) | `play-l4d2.sh` commands, env-var overrides, game configs |
| [06 — Building](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/06-building.md) | Building DXVK / MoltenVK / the bridge from source |
| [07 — Debugging](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/07-debugging.md) | The diagnostic harness, log files, reading dxlevel/HDR/fault state |
| **[08 — Roadmap](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/08-roadmap.md)** | **The phased plan** → online + HDR/DX9 + any-Mac port, at max settings |

---

## Architecture

This is **not** Game Porting Toolkit / D3DMetal (that was an earlier dead end — see [History](#history)).
The real stack is four independently-patched layers plus an orchestration script. See
[02 — Architecture](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/02-architecture.md) for the
layer-by-layer detail.

### Why a custom Steam bridge?

L4D2's DRM (`SteamAPI_Init`) needs a *real* signed-in Steam, and the Windows Steam client doesn't run well
in the prefix. Instead:

- **`bridge/steam_api_wine.c`** → compiled to a PE32 i386 `steam_api.dll` that the game loads. It
  implements the Steamworks flat API and the COM-style interface vtables, forwarding every call over TCP
  to…
- **`bridge/steam_helper.c`** → a native arm64 mach-O process that loads the real `libsteam_api.dylib` and
  talks to the running, signed-in **Mac Steam**. Real SteamID / persona / auth are read **live** from that
  Mac's Steam client — nothing about the account is hardcoded, which is what makes "plug in the real Steam
  values from this Mac's Steam app" work.

The vtables are **generated** (`bridge/gen_vtables.py`) straight from the Steamworks SDK 1.53a headers in
`bridge/sdk/`, so every method gets the correct `__thiscall` arg count (`ret N` cleans the stack exactly the
way the engine expects). This is the load-bearing trick — hand-writing 300+ stubs with the right stack
cleanup would be hopeless.

Key things the bridge gets right (each was a debugging saga):
- pack(4)→pack(8) callback-struct repacking (macOS Steam packs callbacks differently than the Windows game
  reads them — this broke lobby creation)
- synthetic `ValidateAuthTicketResponse_t` + `GSClientApprove_t` so the listen server accepts the host's own
  auth ticket ("STEAM validation rejected" fix)
- `ISteamMatchmakingServers` proxied to real Steam for the server browser
- callback delivery via manual dispatch, with ABI-defensive `__thiscall` trampolines and adaptive
  `ret`-cleanup detection

---

## Repository layout

Tracked source (this is the source of truth):

| Path | What |
| --- | --- |
| `play-l4d2.sh` | the launcher / orchestrator (setup, build, patch, run) |
| `build-deps.sh` | reproducibly builds patched DXVK + MoltenVK from the `.patch` files |
| `bridge/steam_api_wine.c` | Wine-side `steam_api.dll` bridge (PE32 i386) |
| `bridge/steam_helper.c` | native arm64 Steam proxy |
| `bridge/gen_vtables.py` | generates ABI-correct vtables from the SDK headers |
| `bridge/steam_api.def` | DLL export list |
| `bridge/sdk/` | Steamworks SDK 1.53a headers (vtable-generation input) |
| `dxvk-build/shadow-sampler-workaround.patch` | our DXVK source patch |
| `moltenvk-build/session-patches/moltenvk-all-edits-latest.patch` | our MoltenVK source patch (incl. the attachment-less-skip `0x010c` HDR fix) |
| `docs/` | the documentation in this index (kept in lockstep with the code) |
| `sign-in.sh` | one-shot Steam sign-in helper |

Git-ignored (regenerated by the scripts, or multi-GB runtime state): `prefix/`, `whisky-prefix/`,
`whisky-wine/`, `Game Porting Toolkit.app/`, the built binaries (`steam_api.dll`, `steam_helper`,
`dxvk_d3d9.dll`, `libMoltenVK.dylib`, `vtables_generated.c`), `dxvk-shaders/`, `*.log`, and the superseded
`bridge/steam_api_wine.cpp` / `bridge/sdk_old/`.

---

## Build

The two upstream dependencies (DXVK, MoltenVK) are patched from source. Their build trees are scratch dirs;
only the resulting binaries land in the tracked `dxvk-build/` and `moltenvk-build/` dirs (and are
git-ignored). Regenerate everything from the tracked `.patch` files with:

```sh
./build-deps.sh            # build DXVK + MoltenVK + bridge (skips deps whose
                           # artifact already exists; use --force to rebuild)
./build-deps.sh bridge     # just the steam_api.dll + steam_helper (fast)
./build-deps.sh dxvk       # just DXVK
./build-deps.sh moltenvk   # just MoltenVK (slow: fetchDependencies ~10 min)
```

Toolchain (Homebrew unless noted):

- `mingw-w64` — i686 cross-compiler for the PE32 `steam_api.dll`
- `meson` + `ninja` — DXVK build
- Xcode (full, not just CLT) — MoltenVK build (`make macos`)
- `clang` (CLT) + `python3` — helper + vtable generation

Pinned upstream versions (the patches are authored against these — bumping the tag may require re-rolling the
patch):

- **DXVK** `v1.10.3` — <https://github.com/doitsujin/dxvk>
- **MoltenVK** `v1.4.1` — <https://github.com/KhronosGroup/MoltenVK>

---

## First-time setup

```sh
./play-l4d2.sh --setup           # Whisky-Wine bundle + patched MoltenVK + prefix
./build-deps.sh                  # build the bridge + patched DXVK/MoltenVK
./play-l4d2.sh --install-bridge  # install bridge DLL + apply game byte-patches
# make sure Mac Steam is running and signed in (this is what the bridge proxies)
./play-l4d2.sh --steam-check     # verify Mac Steam + show the account the bridge will use (D3)
./play-l4d2.sh                   # play
```

`--install-bridge` also starts the `steam_helper` and applies the in-place game-DLL byte patches (below).
`play-l4d2.sh` with no args runs the full idempotent path (install bridge → start helper → launch), so
day-to-day you just run it bare.

---

## Patch inventory

### Bridge (full source — `bridge/`)
Rebuilt by `build-deps.sh bridge`. No upstream; it's ours.

### DXVK 1.10.3 — `dxvk-build/shadow-sampler-workaround.patch`
- **Software depth-compare shadow sampling.** MoltenVK can't bind a separate depth-compare sampler at the
  same Metal texture slot as the color sampler (SPIRV-Cross emits two `[[texture(N)]]` decls at one slot,
  Metal rejects). We emit a regular sample then do `(sampled.r >= ref) ? 1 : 0` in SPIR-V.
- **pushConstSize fix** — stock DXVK assigned the push-constant *size* from the *offset* (copy-paste bug) →
  too-small range → per-frame Metal device fault.
- mingw-w64 14.0+ build fixes (`_D3DDEVINFO_RESOURCEMANAGER`, `ID3D10StateBlock` UUID redefinition, missing
  `<cstdint>`).

### MoltenVK 1.4.1 — `moltenvk-build/session-patches/moltenvk-all-edits-latest.patch`
- **Attachment-less render-pass skip — the HDR `0x010c` playability fix (2026-06-04).** On the first
  full-scene HDR frame DXVK emits a 16384×16384 render pass with **zero attachments**; creating a Metal render
  command encoder with no attachments hard-aborts the AGX GPU with Internal Error `0x010c` (surfacing as
  `VK_ERROR_DEVICE_LOST` — not a true OOM). The patch makes `MVKCommandEncoder::beginMetalRenderPass` **skip
  creating the encoder** when the pass has no color/depth/stencil attachment, so draws into it become safe
  no-ops. This is what makes HDR playable end-to-end. Default on; `L4D2_MVK_SKIP_NOATT=0` disables it. Also
  bundles the instrumentation that pinpointed the fault (`[mvk-tiledbg]` attachment-footprint logging,
  `MVK_L4D2_SYNC`, the `L4D2_MVK_MAX_PASSES` command-buffer splitter — all off by default).
- **Null-descriptor fallback**: unbound descriptor slots point at a zero-filled 64 KB buffer / 1×1 texture /
  sampler instead of nil, so the GPU reads zeros instead of faulting (VK_EXT_robustness2 `nullDescriptor`).
- **`isAppleGPU` detection** fixed for M-series (was gated on `Apple1` family, which modern chips don't
  report — broke a dozen Apple-GPU code paths). Covers Apple1–Apple10 (M1–M4+).
- **`robustImageAccess2`** advertised on Apple GPUs.
- **`MVKPipelineLayout` always reserves a push-constant buffer slot per stage** — *the* fix for the
  `cannot reserve 'buffer' resource location at index 0` MSL collision that was silently dropping most
  fragment-shader pipelines (missing walls, X-ray geometry).
- Encoder-execution-status capture for GPU-fault diagnosis (gated behind `MVK_L4D2_DEBUG=1`).

### Game DLLs — in-place byte patches (applied by `--install-bridge`)
**Valid for Source engine build 9477 only.** Each guards on the exact original bytes and no-ops if they
don't match, so a game update fails safe (but then the game may crash with no obvious cause — check these
first after any L4D2 update). Originals are backed up as `*.original`.

| File | Offset | What |
| --- | --- | --- |
| `client.dll` | `+0x12CE0F` | NOP a HUD-iteration vtable[47] call with a bad subject ptr |
| `engine.dll` | `+0x18F680` | force a CRT-pointer-deref fn to return false |
| `engine.dll` | `+0x284150` | memmove count sanity check (garbage-arg guard) |
| `matchmaking.dll` | `+0xC070` | callback iterator → no-op |
| `dxvk_d3d9.dll` | (binary) | fallback geometryShader/shaderCullDistance disable |

---

## Useful flags

| Flag | What it does |
| --- | --- |
| `--setup` | Whisky-Wine bundle + patched MoltenVK + prefix; don't launch |
| `--install-bridge` | install bridge DLL, apply byte patches, start helper |
| `--build-bridge` | compile `steam_api.dll` + `steam_helper` only |
| `--bridge` | build + install + start helper, then stop |
| `--diag` | light, playable diagnostics → `game-stderr.log` (per-encoder GPU-fault log) |
| `--wined3d` | render via Wine's native d3d9 → wined3d instead of DXVK (slower; `WINED3D_RENDERER=gl\|vulkan`). Serialises D3D9 (`mat_queue_mode 0`) for **that run only** — multicore (`-1`) is reverted on exit and no `autoexec.cfg` is persisted (C1) |
| `--diag-gfx` | verbose DXVK + MoltenVK logging to `game-stderr.log` |
| `--hud` | Metal HUD overlay (`MTL_HUD_ENABLED`) |
| `--debug` | noisy Wine logs to stderr |
| `--reset` | wipe and re-init the Wine prefix |
| `--kill` | force-kill a stuck game/wine/helper |
| `--winecfg` / `--shell` | winecfg / subshell against the prefix |
| `-- <args>` | everything after `--` is forwarded to `left4dead2.exe` |

### Debug logging

All three of our components keep their verbose traces off by default and gate them behind env vars (so
shipping runs are quiet and fast):

| Env var | Enables |
| --- | --- |
| `L4D2_BRIDGE_DEBUG=1` | `steam_api.dll` trace → `Z:\tmp\bridge.log` |
| `L4D2_HELPER_DEBUG=1` | `steam_helper` per-op/callback trace → stderr |
| `MVK_L4D2_DEBUG=1` | MoltenVK per-encoder GPU-fault diagnosis → stderr |

`--diag-gfx` sets these plus DXVK's own logging and captures everything to `game-stderr.log`. See
[07 — Debugging](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/07-debugging.md).

### Env overrides

```sh
L4D2_GAME_DIR=/path/to/install    # non-default L4D2 location
L4D2_PREFIX=/path/to/wineprefix   # prefix on an external disk, etc.
WINED3D_RENDERER=gl               # with --wined3d: force GL backend
```

---

## Known issues

Full list with cause/workaround/status: [03 — Known issues](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/03-known-issues.md). The big ones:

- **HDR — SOLVED (rendering 2026-06-03, playability 2026-06-04).** The flat, over-bright, no-shadow
  lighting was caused by the launcher's own `+mat_hdr_level 1` token: the engine logs it as `Unknown command`
  but **queues and applies** it at material-system init, pinning HDR to LDR+bloom. L4D2's maps are HDR-only, so
  that read the empty LDR lighting lump → `Level unlit` → fullbright. **Removing the token** lets the engine
  default (full HDR, level 2) stand — `mat_hdr_level` reads 2, the engine is at DX9.5 (`mat_dxlevel 100`), and
  maps light correctly at max settings. **Playability was then blocked by the `0x010c` device-lost** (issue #2),
  which turned out to be an **attachment-less render pass**: on the first full-scene HDR frame DXVK emits a
  16384×16384 render pass with **zero attachments**, and creating a Metal render encoder with no attachments
  hard-aborts the AGX GPU with `0x010c` (it surfaces as `VK_ERROR_DEVICE_LOST` but is **not** an OOM). Patched
  MoltenVK now **skips creating the encoder for an attachment-less pass**, so HDR is **playable end-to-end at
  max settings** — the user played campaign levels 1→2 with no freeze/crash; automated runs log 0 `0x010c`
  faults. (DXVK version, DX8/dxlevel, MSAA, multicore, FP16 targets, and the tile-memory budget were all
  confirmed **red herrings**.) The only residual is an occasional stutter (a perf nit). Details:
  [issue #1](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/03-known-issues.md) ·
  [issue #2](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/03-known-issues.md).
- **Online multiplayer doesn't work yet.** The bridge proxies lobbies, P2P, the server browser, and auth to
  real Mac Steam, but the engine is never put into Steam "online mode" (`SteamServersConnected_t` is
  blacklisted because firing it currently hangs). This is **Phase 2**.
- **Player settings persist (policy revised 2026-06-04).** Max settings is the **first-run default**, not a
  per-launch override: the launcher *seeds* the max baseline into `video.txt`, then **never overwrites a value
  the player changed** in-game — resolution, MSAA, aniso, detail/texture levels (`gpu_level`/`gpu_mem_level`),
  multicore, vsync all persist across restarts (run `--max-settings` to deliberately reset to max). The three
  ConVar-only quality pins (`mat_picmip` / `r_waterforceexpensive` / `r_shadowrendertotexture`) that used to
  override texture/water/shadow quality were **removed** — they duplicated the detail levels and couldn't
  persist anyway, so all Options → Video settings now persist. See
  [05-usage.md](https://github.com/samdotson61/L4D2-launcher/blob/main/docs/05-usage.md#game-graphics-settings).
- **Multicore landmine — fixed (Phase 1 / C1+C2).** The `--wined3d` path used to persist `mat_queue_mode 0`
  (via `autoexec.cfg` + a `video.txt` rewrite) into the DXVK path. Now it scopes serialisation to that one
  run, saving the pre-run `mat_queue_mode` to a sidecar and restoring **that** value on exit (self-healing on
  the next launch if hard-killed); it writes no `autoexec.cfg`. (It no longer re-asserts `-1` every launch —
  that would clobber a player's choice.)
- **`bridge/steam_helper.c` no longer hardcodes the Steam dylib path** (D1, 2026-06-04) — `resolve_dylib_path()`
  derives it from `$L4D2_STEAM_DYLIB` → `$L4D2_GAME_DIR/bin/libsteam_api.dylib` → the `$HOME` default Steam
  library, and the launcher passes the resolved path to the helper.
- **`--wined3d` renders cleaner but crashes after a few minutes** (access violation in the Apple OpenGL →
  Metal layer) and is slower. DXVK is the primary path.
- **The game-DLL byte patches are build-9477-specific** and will silently stop applying on any L4D2 update
  (see the patch-inventory note).

---

## History

The first approach used Apple's **Game Porting Toolkit (D3DMetal)** + a Steam-for-Windows install inside the
prefix. That's recorded in the git history but fully superseded: D3DMetal is D3D11/12-focused and didn't
handle L4D2's D3D9 path well, and Steam-for-Windows in-prefix was flaky. The current stack (Whisky-Wine +
DXVK + patched MoltenVK + the native Steam bridge) replaced all of it. The `Game Porting Toolkit.app/` may
still be present from an old `--setup` but isn't used by the current launch path.

## References

- Apple Gaming Wiki — [Left 4 Dead 2](https://www.applegamingwiki.com/wiki/Left_4_Dead_2)
- [DXVK](https://github.com/doitsujin/dxvk) · [MoltenVK](https://github.com/KhronosGroup/MoltenVK) · [Whisky](https://github.com/Whisky-App/Whisky)
- [Goldberg Steam Emulator](https://github.com/Detanup01/gbe_fork) — reference for the Steam-callback behavior the bridge emulates
