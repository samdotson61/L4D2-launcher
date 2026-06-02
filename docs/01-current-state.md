# Current State & Playability

**As of 2026-06-02.** This describes exactly what works, what doesn't, and the precise configuration currently deployed.

---

## Playability summary

The game **launches, reaches the main menu, and loads into a campaign**, rendering the world, HUD, weapons, survivor bots, and items. On the test map (`c1m1_hotel`) it runs at **~90–130 fps** at native **1512×982** with **max settings** (4× MSAA, multicore, max textures, expensive water, RTT shadows, 16× aniso) and **does not** hit the `0x010c` GPU crash during a ~90 s run.

The **one major visual problem**: **HDR is disabled at the engine level**, so the scene is rendered with LDR lightmaps. Lighting looks flat and overexposed — a dark interior reads as brightly lit as the sunlit exterior, because the HDR luminance range and tonemapping aren't applied. This is the current top priority. See [03-known-issues.md](03-known-issues.md#1-hdr--tonemapping-disabled-).

---

## What works

- **Boot + Steam bridge** — the custom `steam_api.dll` + native `steam_helper` satisfy every Steamworks interface L4D2 requests; real Steam identity (SteamID/persona) is proxied from the macOS Steam client. ~150+ RPCs per run.
- **Main menu** — renders and is interactive.
- **Campaign load** — the world geometry, textures, lighting (LDR), HUD, weapons, and survivor bots all render. Reaches active gameplay (`+map c1m1_hotel` confirmed; bots spawn).
- **Performance** — ~90–130 fps on the test map at full resolution and max settings; well above playable.
- **Max graphics settings** — 4× MSAA + multicore material system + max textures all stable; turning these up does **not** cause the historical crash.
- **GPU stability at current settings** — 0 `0x010c` faults across repeated 90 s test runs.

## What's broken or limited

| Area | State | Detail |
|---|---|---|
| **HDR / tonemapping** | ❌ Off | Engine logs `HDR Disabled`; flat/overexposed lighting. dxlevel-forcing via config did **not** fix it. Leading suspect: DXVK FP16 HDR render-target reporting. |
| **Flashlight shadow** | 🟡 Stopgap | Disabled via `+r_flashlightdepthtexture 0` (the depth-sample-same-frame path faults on the Apple tile GPU). The flashlight itself (light cone) works; it just casts no shadow. |
| **0x010c heavy-frame crash** | 🟡 Marginal | Not triggering at current settings, but it has historically appeared under heavier GPU load (~36 s into a map). Treated as a load-threshold risk, not fully eliminated. |
| **Online / multiplayer** | ❌ Not working | Bridge implements lobby (`ISteamMatchmaking`), server list (`ISteamMatchmakingServers`), P2P (`ISteamNetworking`), and auth-ticket proxies — **but the engine is never put into Steam "online mode"**: firing `SteamServersConnected_t` (id 101) is blacklisted because it currently hangs on follow-on state. Online MP needs that mode. See [Phase 2](08-roadmap.md#phase-2--online-multiplayer-join-official-steam-games). |
| **Real menu→campaign path** | 🟡 Mostly | Verified via `+map`. The clicked menu→campaign path has historically been the area where callback-driven stalls appeared (see #63). |
| **Shadow quality** | 🟡 Tradeoff | DXVK shadow-sampler patch aliases depth-compare to color sampling (software compare), a quality regression accepted to make shaders compile on MoltenVK. |

---

## Exact deployed configuration

### Versions
- **OS / HW:** macOS 26.x, Apple M4 Pro, Rosetta 2 (x86 emulation for the 32-bit game)
- **Wine:** Whisky-Wine 11 (`~/L4D2-launcher/whisky-wine/`), prefix at `~/L4D2-launcher/whisky-prefix/`
- **DXVK:** **1.10.3** (+ `shadow-sampler-workaround.patch`) — deployed `bin/dxvk_d3d9.dll` matches `dxvk-build/dxvk_d3d9.dll` (sha1 `f9a30c6…`). A **2.5.3** build exists but is **stashed** (`dxvk-build/dxvk_d3d9.dll.253-stash`), not deployed.
- **MoltenVK:** **1.4.1** (+ `null-descriptor-fallback.patch`), deployed dylib sha1 `9e8abed1…`
- **Steamworks SDK:** 1.53a (+ ISteamTimeline from 1.60)

### Launch args (`play-l4d2.sh` → `DEFAULT_GAME_ARGS`)
```
-novid -vulkan +r_flashlightdepthtexture 0 +mat_hdr_level 1 +mat_queue_mode -1
+mat_picmip 0 +r_waterforceexpensive 1 +r_shadowrendertotexture 1 +mat_antialias 4 +mat_hdr_level 2
```
⚠️ **`+mat_hdr_level` is logged as `Unknown command` in this retail L4D2 build — those two tokens are no-ops.** They are kept because the playable commit (38dc236) carried them and they're harmless, but they do **not** control HDR. HDR is decided by the engine from hardware caps (see issues doc).

### `video.txt` (`left4dead2/cfg/video.txt`) — **live contents (2026-06-02)**
```
gpu_level 3, cpu_level 2, gpu_mem_level 2, mem_level 2
mat_antialias 4 (4× MSAA), mat_aaquality 0, mat_forceaniso 16
mat_queue_mode -1 (multicore), mat_picmip 0
mat_vsync 1, mat_triplebuffered 1, mat_monitorgamma 2.2
defaultres 1512 × 982, windowed (fullscreen 0), no border (nowindowborder 1)
```
> ✅ **`setting.dxlevel 95` is now asserted on every launch** by `assert_max_settings`
> ([C2](08-roadmap.md#c2-single-source-of-truth-for-settings)) — it isn't in the static listing above
> because the launcher adds it (and re-asserts the rest of the block) at launch time, snapshotting the
> original to `video.txt.orig-pre-launcher` first. dxlevel-forcing alone does **not** enable HDR; making
> the `dxsupport.cfg` edits equally durable is the rest of
> [A2](08-roadmap.md#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8).
>
> ⚠️ **`defaultres 1512×982` is hardcoded to this 14" MacBook** (3024×1964 backing). Portability
> ([plan D2](08-roadmap.md#d2-dynamic-resolution)) detects the target Mac's
> resolution instead.
>
> ✅ **Multicore landmine fixed** ([C1](08-roadmap.md#c1-neutralise-the-multicore-landmine-must-fix) /
> issue #9): `mat_queue_mode -1` is correct here and is re-asserted every launch. The `--wined3d` path no
> longer persists `mat_queue_mode 0` — it scopes serialisation to that one run (reverted on exit by
> `_wined3d_restore`) and writes no `autoexec.cfg`, and the DXVK launch strips any stale one.

### dxsupport (GPU→settings database) — **edited this session**
- `bin/dxsupport.cfg` block `"0"` (the unmatched-GPU default): `maxdxlevel 90→98`, `dxlevel 90→95`. Backup at `bin/dxsupport.cfg.orig-pre-dx95`.
- `left4dead2/dxsupport_override.cfg` block `"3"`: explicit match `vendorid 0x106b` (Apple) → `dxlevel 95 / maxdxlevel 98`.
- **Result:** the engine *still* reports `HDR Disabled` — so dxlevel forcing alone did not enable HDR.

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
  current known-good baseline, on top of `38dc236` ("launcher: full HDR … loads into campaigns").
  Working tree is **clean**; the `docs/` folder and the DXVK/MoltenVK build backups were committed
  in `8cdc8ca`.
- **`DEFAULT_GAME_ARGS`** carries **4× MSAA + multicore** (`mat_queue_mode -1`) + max textures.
- **Stash:** `stash@{0}` (WIP on `38dc236`) holds in-progress launcher edits (clean-quit extended
  to the normal launch path, an `L4D2_FORCE_HDR` video.txt toggle, `L4D2_MVK_MTLHEAP` override,
  updated PREFILL comments).
- **Not in git:** the patched `libMoltenVK.dylib` and `dxvk_d3d9.dll` binaries (rebuildable from
  source via `build-deps.sh` + the tracked `.patch` files); the game-folder config edits.

> **Baseline caveat:** the `8cdc8ca` label is literal — this baseline is **DX8-effective, HDR
> off, no multiplayer**. The forward plan to fix all three at max settings is
> [08-roadmap.md](08-roadmap.md).

> ⚠️ The `dxsupport.cfg` / `dxsupport_override.cfg` / `video.txt` edits live in the **Steam game folder**, not this repo. A Steam "verify integrity of game files" or game update will regenerate `bin/dxsupport.cfg` and silently revert the HDR-forcing edit. The launcher now re-asserts **`video.txt`** (incl. `mat_queue_mode -1` + `dxlevel 95`) on every launch via `assert_max_settings` ([C2](08-roadmap.md#c2-single-source-of-truth-for-settings)); making the **`dxsupport*.cfg`** edits equally durable is the rest of [A2](08-roadmap.md#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8).
