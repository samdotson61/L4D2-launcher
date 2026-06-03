# Current State & Playability

**As of 2026-06-03.** This describes exactly what works, what doesn't, and the precise configuration currently deployed.

---

## Playability summary

The game **launches, reaches the main menu, and loads into a campaign**, rendering the world, HUD, weapons, survivor bots, and items. On the test map (`c1m1_hotel`) it runs at **~90–130 fps** at native **1512×982** with **max settings** (4× MSAA, multicore, max textures, expensive water, RTT shadows, 16× aniso) and **does not** hit the `0x010c` GPU crash during a ~90 s run.

**HDR rendering is now solved** (2026-06-03) — though HDR-on is **not yet playable** (see below). The long "flat / over-bright / no baked shadows" problem was **our own launcher**: `DEFAULT_GAME_ARGS` passed `+mat_hdr_level 1`, which the engine logs as `Unknown command` but *queues and applies* at material-system init — pinning HDR to level 1 (LDR+bloom) every launch. On L4D2's HDR-only maps, level 1 reads the empty LDR lighting lump → `Level unlit, setting 'mat_fullbright 1'` → fullbright. **Removing that one token** lets the engine's true default (level 2, full HDR) stand: `mat_hdr_level` reads 2, `Level unlit` is gone, `mat_fullbright` is no longer forced, and the maps light correctly — at full max settings (4× MSAA + multicore). See [03-known-issues.md](03-known-issues.md#1-hdr--solved-2026-06-03).

**But HDR-on re-triggers the `0x010c` device-lost** (issue #2): ~30 s into active play, at the first full-scene frame, the extra FP16 HDR render-target pressure tips the marginal M4 AGX threshold → `VK_ERROR_DEVICE_LOST` → freeze. So HDR **renders** correctly but isn't yet **playable**. Note that every historical "playable" build was secretly **HDR-off** (even commit 38dc236's "full HDR" title carried the same `+mat_hdr_level 1` pin), so HDR was never stably on before — this `0x010c`-under-HDR coupling is **new ground**, uncovered only by finally enabling HDR. Until #2 is fixed it's **HDR _or_ playable, not both**. See [03-known-issues.md #2](03-known-issues.md#2-0x010c-device-lost-under-hdr--top-blocker-for-hdr-playability--41-62-64).

---

## What works

- **Boot + Steam bridge** — the custom `steam_api.dll` + native `steam_helper` satisfy every Steamworks interface L4D2 requests; real Steam identity (SteamID/persona) is proxied from the macOS Steam client. ~150+ RPCs per run.
- **Main menu** — renders and is interactive.
- **Campaign load** — the world geometry, textures, **HDR lighting**, HUD, weapons, and survivor bots all render. Reaches active gameplay (`+map c1m1_hotel` confirmed; bots spawn).
- **Performance** — ~90–130 fps on the test map at full resolution and max settings; well above playable.
- **Max graphics settings** — 4× MSAA + multicore material system + max textures all stable; turning these up does **not** cause the historical crash.
- **GPU stability at current settings** — 0 `0x010c` faults across repeated 90 s test runs.

## What's broken or limited

| Area | State | Detail |
|---|---|---|
| **HDR / tonemapping** | Renders, not playable yet | **Rendering fixed** 2026-06-03 by deleting the launcher's `+mat_hdr_level 1` token (it queued-then-applied despite "Unknown command", pinning HDR off): `mat_hdr_level` now reads 2, `Level unlit` gone, maps light correctly at max settings; engine is at `mat_dxlevel 100` (full DX9.5) — the "DX8-effective" claim was **false**; DXVK/MSAA/multicore were all red herrings. **But HDR-on freezes ~30 s into play via the `0x010c` device-lost** (issue #2) — the FP16 HDR render targets tip the marginal AGX threshold. Rendering is fixed; **playability is blocked**. See [#1](03-known-issues.md#1-hdr--solved-2026-06-03) and [#2](03-known-issues.md#2-0x010c-device-lost-under-hdr--top-blocker-for-hdr-playability--41-62-64). |
| **Flashlight shadow** | On | `+r_flashlightdepthtexture 1` — dynamic flashlight shadows render (confirmed working). The old `0` stopgap is gone. |
| **0x010c heavy-frame crash** | Marginal | Not triggering at current settings, but it has historically appeared under heavier GPU load (~36 s into a map). Treated as a load-threshold risk, not fully eliminated. |
| **Online / multiplayer** | Not working | Bridge implements lobby (`ISteamMatchmaking`), server list (`ISteamMatchmakingServers`), P2P (`ISteamNetworking`), and auth-ticket proxies — **but the engine is never put into Steam "online mode"**: firing `SteamServersConnected_t` (id 101) is blacklisted because it currently hangs on follow-on state. Online MP needs that mode. See [Phase 2](08-roadmap.md#phase-2--online-multiplayer-join-official-steam-games). |
| **Real menu→campaign path** | Mostly | Verified via `+map`. The clicked menu→campaign path has historically been the area where callback-driven stalls appeared (see #63). |
| **Shadow quality** | Tradeoff | DXVK shadow-sampler patch aliases depth-compare to color sampling (software compare), a quality regression accepted to make shaders compile on MoltenVK. |

---

## Exact deployed configuration

### Versions
- **OS / HW:** macOS 26.x, Apple M4 Pro, Rosetta 2 (x86 emulation for the 32-bit game)
- **Wine:** Whisky-Wine 11 (`~/L4D2-launcher/whisky-wine/`), prefix at `~/L4D2-launcher/whisky-prefix/`
- **DXVK:** **1.10.3** (+ `shadow-sampler-workaround.patch`) — deployed `bin/dxvk_d3d9.dll` matches `dxvk-build/dxvk_d3d9.dll` (sha1 `f9a30c6…`). A **2.5.3** build exists but is **stashed** (`dxvk-build/dxvk_d3d9.dll.253-stash`), not deployed. *(Explored 2026-06-02: a hand-patched 2.5.3 rendered but looked identical to 1.10.3 — correctly establishing **DXVK is not the HDR lever**. The actual HDR cause was the launcher's `+mat_hdr_level 1` arg, found 2026-06-03; DXVK already reports `A16B16G16R16F` blendable=OK at init. See [#1](03-known-issues.md#1-hdr--solved-2026-06-03).)*
- **MoltenVK:** **1.4.1** (+ `null-descriptor-fallback.patch`), deployed dylib sha1 `9e8abed1…`
- **Steamworks SDK:** 1.53a (+ ISteamTimeline from 1.60)

### Launch args (`play-l4d2.sh` → `DEFAULT_GAME_ARGS`)
```
-novid -vulkan +r_flashlightdepthtexture 1 +mat_queue_mode -1
+mat_picmip 0 +r_waterforceexpensive 1 +r_shadowrendertotexture 1 +mat_antialias 4
```
**The `+mat_hdr_level 1` / `+mat_hdr_level 2` tokens were REMOVED 2026-06-03 — they were the HDR bug.** Despite logging `Unknown command`, the engine *queues* `+mat_hdr_level 1` and applies it once the convar registers at material-system init, pinning HDR to level 1 (LDR+bloom) → fullbright on HDR-only maps. Their **absence** is what enables HDR (engine default = level 2). `+r_flashlightdepthtexture 1` (was `0`) restores dynamic flashlight shadows.

### `video.txt` (`left4dead2/cfg/video.txt`) — **live contents (2026-06-02)**
```
gpu_level 3, cpu_level 2, gpu_mem_level 2, mem_level 2
mat_antialias 4 (4× MSAA), mat_aaquality 0, mat_forceaniso 16
mat_queue_mode -1 (multicore), mat_picmip 0
mat_vsync 1, mat_triplebuffered 1, mat_monitorgamma 2.2
defaultres 1512 × 982, windowed (fullscreen 0), no border (nowindowborder 1)
```
> **`setting.dxlevel 95` is now asserted on every launch** by `assert_max_settings`
> ([C2](08-roadmap.md#c2-single-source-of-truth-for-settings)) — it isn't in the static listing above
> because the launcher adds it (and re-asserts the rest of the block) at launch time, snapshotting the
> original to `video.txt.orig-pre-launcher` first. dxlevel-forcing alone does **not** enable HDR; making
> the `dxsupport.cfg` edits equally durable is the rest of
> [A2](08-roadmap.md#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8).
>
> **`defaultres 1512×982` is hardcoded to this 14" MacBook** (3024×1964 backing). Portability
> ([plan D2](08-roadmap.md#d2-dynamic-resolution)) detects the target Mac's
> resolution instead.
>
> **Multicore landmine fixed** ([C1](08-roadmap.md#c1-neutralise-the-multicore-landmine-must-fix) /
> issue #9): `mat_queue_mode -1` is correct here and is re-asserted every launch. The `--wined3d` path no
> longer persists `mat_queue_mode 0` — it scopes serialisation to that one run (reverted on exit by
> `_wined3d_restore`) and writes no `autoexec.cfg`, and the DXVK launch strips any stale one.

### dxsupport (GPU→settings database) — **edited this session**
- `bin/dxsupport.cfg` block `"0"` (the unmatched-GPU default): `maxdxlevel 90→98`, `dxlevel 90→95`. Backup at `bin/dxsupport.cfg.orig-pre-dx95`.
- `left4dead2/dxsupport_override.cfg` block `"3"`: explicit match `vendorid 0x106b` (Apple) → `dxlevel 95 / maxdxlevel 98`.
- **Result:** these dxlevel edits did **not** enable HDR (and weren't needed) — the engine is already at `mat_dxlevel 100`. HDR was off because of the launcher's `+mat_hdr_level 1` arg, now removed (see [#1](03-known-issues.md#1-hdr--solved-2026-06-03)). The edits are harmless but **moot** for HDR.

### Key MoltenVK env (set by the launcher; overridable)
```
MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0   (MAB on deadlocks vkCreateDevice under Rosetta)
MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=0 (deferred = performant; 2/3 are slow)
MVK_CONFIG_RESUME_LOST_DEVICE=0           (halt cleanly on a real GPU fault)
MVK_CONFIG_USE_MTLHEAP=1, PREALLOCATE_DESCRIPTORS=1, USE_COMMAND_POOLING=1
MVK_CONFIG_FAST_MATH_ENABLED=0            (fast-math NaN/Inf in tonemap faults AGX)
```

---

## Repository state (git)

- **Branch:** `main`, **HEAD:** `8cdc8ca` (*"working dx8 no tonemapping no multiplayer"*) — the
  prior baseline, on top of `38dc236` ("launcher: full HDR … loads into campaigns").
  **Working tree carries the uncommitted 2026-06-03 HDR fix** (the one-line `DEFAULT_GAME_ARGS`
  change + `L4D2_HDR`-toggle removal + these doc updates), not yet committed.
- **`DEFAULT_GAME_ARGS`** carries **4× MSAA + multicore** (`mat_queue_mode -1`) + max textures.
- **Stash:** `stash@{0}` (WIP on `38dc236`) holds in-progress launcher edits (clean-quit extended
  to the normal launch path, an `L4D2_FORCE_HDR` video.txt toggle, `L4D2_MVK_MTLHEAP` override,
  updated PREFILL comments).
- **Not in git:** the patched `libMoltenVK.dylib` and `dxvk_d3d9.dll` binaries (rebuildable from
  source via `build-deps.sh` + the tracked `.patch` files); the game-folder config edits.

> **Baseline caveat:** the `8cdc8ca` commit *label* ("working dx8 no tonemapping") is now stale —
> with the 2026-06-03 HDR fix (in the working tree), HDR **renders** and the engine runs **DX9.5**
> (`mat_dxlevel 100`). What remains is making HDR **playable** (HDR-on re-triggers the `0x010c`
> device-lost ~30 s in, issue #2) and **online multiplayer** — see [08-roadmap.md](08-roadmap.md).

> The `dxsupport.cfg` / `dxsupport_override.cfg` / `video.txt` edits live in the **Steam game folder**, not this repo. A Steam "verify integrity of game files" or game update will regenerate `bin/dxsupport.cfg` and silently revert the HDR-forcing edit. The launcher now re-asserts **`video.txt`** (incl. `mat_queue_mode -1` + `dxlevel 95`) on every launch via `assert_max_settings` ([C2](08-roadmap.md#c2-single-source-of-truth-for-settings)); making the **`dxsupport*.cfg`** edits equally durable is the rest of [A2](08-roadmap.md#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8).
