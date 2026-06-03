# Known Issues

Each issue lists **symptom → cause → workaround/status**. Task numbers (e.g. `#66`) reference the project task tracker.

> Issue #1 (HDR/DX9 shading) is **SOLVED** (2026-06-03 — see below). The forward plan that closes
> the rest (#6 online multiplayer + #9, #10 portability, all at max settings) is **[08-roadmap.md](08-roadmap.md)**.

---

## 1. HDR rendering — SOLVED 2026-06-03 · *playability* blocked by #2 below (`#66`)

**Symptom (now fixed).** The scene rendered flat and over-bright with no baked shadows — a dark interior read as brightly lit as the sunlit exterior. The console showed `Level unlit, setting 'mat_fullbright 1'`.

**Root cause — our own launcher.** `DEFAULT_GAME_ARGS` in `play-l4d2.sh` passed `+mat_hdr_level 1` (and `+mat_hdr_level 2`). The engine logs `Unknown command "mat_hdr_level"` for these — but that is **not** a no-op: the engine **queues the unknown convar command and applies it** the instant `mat_hdr_level` registers during material-system init, pinning HDR to level 1 (LDR+bloom) every launch. L4D2's maps are **HDR-only** (compiled without LDR lightmaps), so at level 1 the engine reads the empty LDR lighting lump, declares the level unlit, and force-sets `mat_fullbright 1` → fullbright. That single pin is the entire flat / over-bright / no-baked-shadow symptom.

**The fix.** Delete both `+mat_hdr_level` tokens from `DEFAULT_GAME_ARGS`. With them gone, the engine's true hardware-derived default — **level 2, full HDR** — stands. The fix is the *absence* of the bad token; there is nothing to add.

**Verification (this session).**
- A VScript probe (`mapspawn.nut` printing `Convars.GetFloat("mat_hdr_level")`) reads **2** after removal (read **1** with the args present).
- `Level unlit` no longer appears; `mat_fullbright` is no longer force-set; `sv_skyname` loads the HDR sky (`sky_l4d_c1_1_hdr`).
- Stable over a 78-second run: `0x010c` faults plateaued at 4 (load-time noise, **not** a per-frame storm). Game stayed up. Full HDR coexists with 4× MSAA + multicore.
- `mat_dxlevel` reads **100** (full DX9.5).

**Why there is no runtime toggle.** `mat_hdr_level` is **hidden** from the console/cfg (logs "Unknown command") **and runtime-locked** — `Convars.SetValue("mat_hdr_level","2")` is refused in every scope tested (map child scope; console/root scope via `listenserver.cfg` → `script_execute`; with and without `sv_cheats`, as string and as int). Init is the only window to set it, so removing the bad launch arg is the only working lever.

**Confirmed RED HERRINGS — do not chase these again:**
- **DXVK version** (1.10.3 vs 2.5.3): a patched, rendering 2.5.3 looks identical. An instrumented `CheckDeviceFormat` probe shows DXVK already returns `A16B16G16R16F` as renderable **+ blendable** (`result=0`/D3D_OK) **at init** — the FP16 HDR RT was never missing. DXVK/MoltenVK were never the lever.
- **DX8 / dxlevel:** the engine is at `mat_dxlevel 100`. The "DX8-effective / HDR Disabled" diagnosis was **false**.
- **MSAA / multicore:** do not break HDR (the old "force MSAA off + single-thread so HDR survives" recipe was wrong).
- **Exposure convars** (`mat_dynamic_tonemapping`, `mat_force_tonemap_scale`): not the cause — they had nothing to tonemap while the level was fullbright.
- **dxsupport.cfg / dxsupport_override.cfg dxlevel edits:** did not and could not enable HDR.

**HDR renders, but is not yet *playable*.** Logs prove the engine is in HDR mode (`mat_hdr_level 2`, no `Level unlit`) and the scene renders in HDR. **But turning HDR on re-triggers the `0x010c` device-lost fault** (issue #2) at the first full-scene frame (~25–40 s) → freeze. So the flat-lighting **root cause is solved and HDR *rendering* works**; HDR **playability** is blocked by #2. Don't claim HDR "works" end-to-end until #2 is fixed.

---

## 2. `0x010c` device-lost under HDR (TOP BLOCKER for HDR playability — `#41`, `#62`, `#64`)

**Symptom.** With **HDR on**, ~25–40 s into a map — at the **first full-scene gameplay frame** — the GPU aborts the command buffer with `MTLCommandBufferError Internal Error 0000010c` (`IOGPUCommandQueueErrorDomain 268`), surfaced by MoltenVK as `VK_ERROR_DEVICE_LOST` / `VK_ERROR_OUT_OF_DEVICE_MEMORY` ("Lost VkDevice after vkQueueSubmit"). The game freezes. It is **not** a true OOM (~1.8 GB used, gigabytes free).

**This is now the top blocker.** Enabling HDR (2026-06-03, issue #1) made this fault — previously *latent* with HDR off — fire **every run**. The FP16 HDR render targets are the extra GPU pressure that tips the marginal AGX threshold at the first heavy frame. HDR *renders correctly*; it just can't survive past the first full-scene frame.

**Ruled out this session (2026-06-03) — do not re-chase:**
- **MSAA / multicore:** NOT the trigger. HDR-on faults identically with 4× MSAA + multicore **or** `mat_antialias 1` + `mat_queue_mode 0`. (Confirms the long-standing user call that these are red herrings — proven from both directions.)
- **Specific scene features:** NOT a removable feature. Disabling expensive water (`r_waterforceexpensive 0` + `r_WaterDrawReflection/Refraction 0`) still faulted → it's the **core HDR pass** (main scene → FP16 + bloom/tonemap), not water/shadows/an effect.
- **Resolution:** 1280×720 still faulted (~41 s). Not (solely) a resolution overflow.
- **`MVK_L4D2_FORCE_PRIVATE_RT=1`** (force transient RTs to Private/device memory): did NOT help — faulted *earlier* (~25 s). The patch post-mortem found the same: Private just adds resident memory and trips the limit sooner. Wired in the launcher (default 0), but **not the fix**.
- **`MVK_CONFIG_RESUME_LOST_DEVICE=1`** (`L4D2_MVK_RESUME=1`): doesn't freeze, but falls into a **per-frame fault storm** (~180 `0x010c`/s, 13 000+ device re-creations in 60 s) — the "perf/glitch disaster" the patch warns about. Not playable.
- **`PREFILL` (immediate encoding):** per the launcher notes, only *raises* the threshold and still faults at native res; much slower under Rosetta. Not a fix.

**Root-cause understanding (MoltenVK patch post-mortem + this session).** `MTLStorageModeMemoryless` backs transient attachments in **tile memory** — a small pool allocated at render-pass *execution*, separate from device memory. When a pass's combined memoryless footprint exceeds the Apple tile budget, the kernel fails the lazy allocation (`IOGPUSysMemory::withOptions failed`) and aborts as `0x010c` — even with 18 GB free. But forcing Private (off-tile) made it *worse*, so it's better framed as **GPU resource/allocation pressure at the heavy HDR frame**, not a pure tile-budget number. The fault is **opaque** — `Internal Error`, *no encoder, no resource attribution* (`[mvk-l4d2-patch] … has no encoder info`, 2 userInfo keys, only `NSLocalizedDescription = Internal Error`) — so it can't be pinned to a draw/resource from logs. **That opacity is the core difficulty;** the predecessor hit the same wall.

**Undocumented fault.** No public cause/fix for `0x010c` / `IOGPUCommandQueueErrorDomain 268` exists. Apple's [WWDC20 "Debug GPU-side errors in Metal"](https://developer.apple.com/videos/play/wwdc2020/10616/) is the only relevant reference; its encoder-attribution path returns "no encoder info" here.

**Untried direction (the next real attempt).** A **pooled-scratch render-target spill** in MoltenVK: when a memoryless attachment would overflow, spill it to a single *reused* device buffer — avoiding both the tile overflow AND the per-resource resident-memory increase that doomed the naive Private attempt. Requires re-cloning MoltenVK + a non-trivial patch + slow rebuild cycles (~10-min dep build per shot), with genuinely uncertain odds. Real fault *attribution* would need Metal frame-capture tooling a Wine game can't easily provide.

**Interim mitigations in the patches** (these address *other* fault classes, not the HDR one above):
- DXVK `pushConstSize` bug fix. `#42`  ·  `robustImageAccess2` on Apple GPUs. `#54`  ·  Null-descriptor fallback.  ·  `MVK_CONFIG_RESUME_LOST_DEVICE=0` so a genuine fault halts cleanly.

**Practical status.** HDR-off is playable (every historical build was secretly HDR-off — see #1). HDR-on freezes at the first heavy frame. **Until this is solved, it's HDR *or* playable, not both.**

---

## 3. Flashlight shadow — ON (`#53`)

**Status (2026-06-03).** `DEFAULT_GAME_ARGS` now carries `+r_flashlightdepthtexture 1` and dynamic flashlight shadows render correctly (user-confirmed). The old `0` stopgap is gone.

**History.** `r_flashlightdepthtexture 1` makes the engine sample a depth texture in the same frame it renders it; that store/sample-same-frame path used to fault on the Apple tile GPU (related to the `0x010c` class), so it was stopgap-disabled with `+r_flashlightdepthtexture 0` (light cone but no shadow). With the current MoltenVK patches (null-descriptor fallback + `robustImageAccess2`) that path no longer faults, so the shadow is back on at max settings.

---

## 4. Shadow-sampler quality regression (`#30`)

**Symptom.** Shadow-comparison sampling is approximate (software compare), a minor quality regression on shadow edges.

**Cause.** DXVK emits SPIR-V where one binding is used as both `sampler2D` and `sampler2DShadow`; MoltenVK's SPIRV-Cross then declares two MSL textures at the same slot, which Metal rejects ("cannot reserve 'texture' resource location at index 0"). 

**Workaround (the `shadow-sampler-workaround.patch`).** Alias the depth-compare sampler to the color sampler and do the depth compare in software. Lets virtually every model shader (VertexLitGeneric) compile. Accepted quality tradeoff.

---

## 5. 60 fps target not guaranteed (`#59`)

**Symptom.** Framerate is high on the test map (~90–130 fps) but real, busier gameplay (hordes, effects) may dip, and everything runs under Rosetta 2 x86 emulation.

**Status.** Open performance goal. The deferred-encoding path (`PREFILL=0`) is the performant one; the immediate-encoding paths that raise the crash threshold are far too slow (~5 fps).

---

## 6. Campaign join / spawn stall (`#63`)

**Symptom (historical).** Via the clicked menu→campaign path, the player could fail to spawn into the level / the loading screen ↔ menu could flicker, tied to Steam callbacks the engine expects (lobby-enter, etc.) that the bridge may not deliver at the right time.

**Status.** `+map` direct load works. The bridge now forwards real callbacks (`OP_DRAIN_CALLBACKS`) with a blacklist for known-bad early-init callbacks. End-to-end clicked-campaign flow not re-verified in the current state.

---

## 7. Online HDR auto-exposure without sv_cheats (`#67`, `#68`)

**Context.** HDR auto-exposure (`mat_dynamic_tonemapping`) is driven by a per-frame GPU occlusion-query luminance histogram. Some of those controls are `FCVAR_CHEAT` (can't be set in online play without `sv_cheats`), and the occlusion-query path has been suspected in the `0x010c` class. `#67` (an engine cheat-flag patch to toggle auto-exposure offline-style online) and `#68` (a moonshot to reimplement D3D9 occlusion queries in DXVK so auto-exposure works at full speed) are open ideas. **Only relevant once issue #1 — HDR rendering itself — is enabled.**

---

## 8. Durability: game-folder edits get reverted 

**Symptom.** HDR-forcing config (`dxsupport.cfg`, `dxsupport_override.cfg`, `video.txt`) lives in the Steam game folder. A Steam "verify integrity of game files" or a game update regenerates `bin/dxsupport.cfg` and silently reverts the edit, which would re-break HDR (once it's working).

**Fix (partial — C2 done).** `play-l4d2.sh`'s `assert_max_settings` now re-asserts the **`video.txt`** block (incl. `dxlevel 95`) on every launch, joining the bridge-DLL/binary-patch re-apply step, and snapshots the original to `video.txt.orig-pre-launcher`. Still **TODO ([A2](08-roadmap.md#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8))**: re-assert the **`dxsupport.cfg` / `dxsupport_override.cfg`** edits the same way, since a Steam verify regenerates those.

---

## 9. Multicore silently forced off by the `--wined3d` path RESOLVED (Phase 1 / C1+C2)

**Symptom (historical).** Multicore rendering (`mat_queue_mode -1`) could silently revert to single-core (`0`) — a **violation of the hard "max settings always, including multicore" constraint** — without any setting being changed by hand.

**Cause (historical).** `play-l4d2.sh`'s `--wined3d` launch path did two **persistent** things: it `perl -pi` rewrote `video.txt`'s `setting.mat_queue_mode` to `0`, **and** it wrote a `left4dead2/cfg/autoexec.cfg` containing `mat_queue_mode 0`. `autoexec.cfg` is exec'd by the engine on **every** launch (including the normal DXVK path), so once `--wined3d` had run, multicore stayed off everywhere until something put it back. (The serialisation rationale is real — wined3d crashes under Source's multi-threaded D3D9 submission — but the *persistence* leaked into the DXVK path.)

**Fix (done — [C1](08-roadmap.md#c1-neutralise-the-multicore-landmine-must-fix) + [C2](08-roadmap.md#c2-single-source-of-truth-for-settings), 2026-06-02).** Serialisation is now scoped to the `--wined3d` run only:
> - That path flips `video.txt`'s `mat_queue_mode` to `0` for the run and reverts it to `-1` on exit (`_wined3d_restore`, an `EXIT` trap), and **no longer writes `autoexec.cfg`** at all (the `+mat_queue_mode 0` launch arg covers that single run).
> - Every DXVK launch runs `assert_max_settings`, which re-asserts `mat_queue_mode -1` (plus the rest of the max block) in `video.txt` and **strips any stale landmine `autoexec.cfg`** — so even a hard-killed `--wined3d` run self-heals on the next launch.

**Also fixed (C2).** The launcher comment block at `play-l4d2.sh` ~74–93 was **stale/contradictory** — it claimed "MSAA off / queue 0 was the verified-clean set" and pushed the debunked `mat_hdr_level 1→2` HDR theory while `DEFAULT_GAME_ARGS` actually sets MSAA 4 + queue −1. The comments now describe the real args (`mat_hdr_level` is a documented no-op in this retail build; HDR is decided by hardware caps, not these args).

---

## 10. Portability blockers (per-machine hardcoding) (`#69`, `#70` — porting goal)

**Goal.** Port this wrapper to **any Apple Silicon Mac** and play L4D2 + join official Steam multiplayer by plugging in the real Steam values from that Mac's Steam app. See [Phase 3](08-roadmap.md#phase-3--portability-to-any-apple-silicon-mac).

**Blockers found:**
- **Hardcoded Steam dylib path.** `bridge/steam_helper.c:33` →
  `DYLIB_PATH "/Users/samdotson/Library/.../Left 4 Dead 2/bin/libsteam_api.dylib"`. Must resolve
  from `$L4D2_STEAM_DYLIB` / `$L4D2_GAME_DIR` / a search of common Steam locations, then rebuild
  the helper. ([D1](08-roadmap.md#d1-de-hardcode-the-steam-dylib-path-must-fix))
- **Hardcoded resolution.** `video.txt` pins `defaultres 1512×982` (this 14" MacBook). Detect the
  target Mac's resolution at launch. ([D2](08-roadmap.md#d2-dynamic-resolution))

**Already portable (good):** the bridge pulls **real SteamID / persona / auth live from the running
Mac Steam client** — no hardcoded SteamID. `vendorid 0x106b` + MoltenVK `isAppleGPU` (Apple1–10)
cover M1–M4+. The only host requirements are Steam installed + logged in + owning L4D2 (appid 550).
([D3](08-roadmap.md#d3-plug-in-real-steam-values))

---

## Resolved (for reference)

These were real blockers, now fixed — useful history if a regression appears:

- **EIP=0 crash after window create** → fixed by `-vulkan` + the full bridge + Timeline interface + engine/client/matchmaking binary patches.
- **DXVK device-create failure on MoltenVK** → gate `geometryShader`/`shaderCullDistance` to supported features. `#45`
- **Constant-buffer slot collision** (`cbuffer_t` + push-const both at MSL buffer 0) → MVKPipelineLayout always reserves a push-constant slot per stage. `#36`
- **32-bit address-space exhaustion at load** → DXVK memory-allocator handling (the reason 2.5.3 was explored). `#57`, `#60`
- **Matchmaking pipe wedge / FreeLastCallback leak** → helper fix. `#43`
- **Steam DRM blocking-call loop** → `IsAPICallCompleted` + `GetAPICallResult` proxied through real Steam. `#5`
