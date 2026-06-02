# Known Issues

Each issue lists **symptom → cause → workaround/status**. Task numbers (e.g. `#66`) reference the project task tracker.

---

## 1. HDR / tonemapping disabled ❌ (TOP PRIORITY — `#66`)

**Symptom.** The scene renders flat and overexposed. A dark interior room reads as brightly lit as the sunlit exterior — there is no HDR luminance range and no tonemapping/auto-exposure adaptation. Walls look washed out. (User-confirmed: "the inside should be dark but it's perfectly lit.")

**What the engine reports.** `console.log` contains `HDR Disabled`. The engine is rendering with **LDR lightmaps**, which is why interiors aren't dark.

**Key facts established:**
- `mat_hdr_level`, `mat_dxlevel`, and `developer` are all **`Unknown command`** in this retail L4D2 build — HDR is **not** user-settable via console or launch args. The engine decides HDR on/off from hardware capabilities.
- `mat_dynamic_tonemapping = 1` and `mat_force_tonemap_scale = 0.0` — auto-exposure is correctly armed. The problem is upstream: HDR *rendering* is off, so there is nothing to tonemap.
- The map has HDR assets (`sv_skyname "sky_l4d_c1_1_hdr"` loads), so the content supports HDR.

**What was tried and did NOT fix it:**
- `setting.dxlevel 95` + `maxdxlevel 95` in `video.txt`.
- Raising `bin/dxsupport.cfg` default block to `maxdxlevel 98 / dxlevel 95`.
- Adding an explicit `vendorid 0x106b` (Apple) → dxlevel 95 entry to `dxsupport_override.cfg`.
- Result: engine **still** logs `HDR Disabled`. So dxlevel-forcing via config is not sufficient.

**Leading hypothesis (next step, not yet tested).** Source enables HDR only when it detects an FP16-renderable HDR format (`D3DFMT_A16B16G16R16F` as a render target with blending) via D3D9 `CheckDeviceFormat`. That detection comes from **DXVK**. The deployed DXVK is **1.10.3**; a **2.5.3** build is stashed (`dxvk-build/dxvk_d3d9.dll.253-stash`). The next diagnostic is to test whether DXVK 2.5.3 reports the HDR render-target formats Source needs (and whether it stays crash-free + keeps max settings). DXVK 2.5.3 previously needed MAB-off + feature gating to create the device on MoltenVK (`#61`).

**Important caveat for whoever picks this up.** The diagnostic harness (`diag-monitor.sh`) can detect crashes/fps and grep `console.log` for the literal `HDR Enabled`/`HDR Disabled` line, but it **cannot judge visual tonemapping**. The user is the authority on whether shading looks correct. Do not claim HDR works from logs alone.

**Note on prior confusion.** The 38dc236 commit message claims a `mat_hdr_level 1→2` launch-arg sequence "fixes" the HDR-RT layout. Since `mat_hdr_level` is `Unknown command`, that claim is unverifiable and almost certainly wrong; HDR enablement is hardware/DXVK-driven, not arg-driven.

---

## 2. Heavy-scene `0x010c` GPU fault 🟡 (`#41`, `#62`, `#64`)

**Symptom (historical).** ~34–36 s into a map, the first heavy gameplay frame triggers a `MTLCommandBufferError Internal Error 0000010c` (`IOGPUCommandQueueErrorDomain 268`), surfaced by MoltenVK as `VK_ERROR_DEVICE_LOST` / `VK_ERROR_OUT_OF_DEVICE_MEMORY` ("Lost VkDevice after vkQueueSubmit"). The game freezes (device lost), it is **not** a true OOM (~1.8 GB used of 18 GB).

**Cause (best understanding).** A marginal GPU-command-buffer load threshold on the M4 AGX GPU, hit at the first heavy frame. It is **invariant to MSAA and threading** (proven by head-to-head tests: MSAA-off/single-thread crashed identically to MSAA-4×/multicore when other conditions matched). Multiple contributing patches exist (see below); none is a single definitive root cause.

**Status.** Currently **not triggering** at the deployed settings on the test map (0 faults over repeated 90 s runs). Treated as a latent risk, not eliminated.

**Mitigations already in place (in the DXVK + MoltenVK patches):**
- DXVK `pushConstSize` bug fix (a stock 1.10.3 copy-paste bug that produced a too-small push-constant range → per-frame OOB device read → fault). `#42`
- `robustImageAccess2` enabled on Apple GPUs (Metal clamps OOB image reads). `#54`
- Null-descriptor fallback (bind zero-filled dummy buffer/texture/sampler instead of nil → no deref-of-0 fault). 
- Transient/memoryless attachments can be forced to Private storage to avoid tile-memory exhaustion (`MVK_L4D2_FORCE_PRIVATE_RT`, default off). `#56`
- `MVK_CONFIG_RESUME_LOST_DEVICE=0` so a genuine fault halts cleanly rather than spiraling.

**Levers if it recurs:** `L4D2_MVK_PREFILL=2` (immediate command-buffer encoding — raises the threshold but is much slower under Rosetta, ~5 fps; not a real fix), or `MVK_L4D2_FORCE_PRIVATE_RT=1`.

---

## 3. Flashlight casts no shadow 🟡 (`#53`)

**Symptom.** The flashlight light cone works, but it casts no shadows.

**Cause.** `r_flashlightdepthtexture 1` (the default) makes the engine sample a depth texture in the same frame it renders it; that store/sample-same-frame path faults on the Apple tile GPU (related to the `0x010c` class).

**Workaround.** `+r_flashlightdepthtexture 0` in `DEFAULT_GAME_ARGS` disables flashlight shadow depth. **Real fix (pending):** force a Store (non-memoryless) store-action on that depth target so it can be sampled safely.

---

## 4. Shadow-sampler quality regression 🟡 (`#30`)

**Symptom.** Shadow-comparison sampling is approximate (software compare), a minor quality regression on shadow edges.

**Cause.** DXVK emits SPIR-V where one binding is used as both `sampler2D` and `sampler2DShadow`; MoltenVK's SPIRV-Cross then declares two MSL textures at the same slot, which Metal rejects ("cannot reserve 'texture' resource location at index 0"). 

**Workaround (the `shadow-sampler-workaround.patch`).** Alias the depth-compare sampler to the color sampler and do the depth compare in software. Lets virtually every model shader (VertexLitGeneric) compile. Accepted quality tradeoff.

---

## 5. 60 fps target not guaranteed 🟡 (`#59`)

**Symptom.** Framerate is high on the test map (~90–130 fps) but real, busier gameplay (hordes, effects) may dip, and everything runs under Rosetta 2 x86 emulation.

**Status.** Open performance goal. The deferred-encoding path (`PREFILL=0`) is the performant one; the immediate-encoding paths that raise the crash threshold are far too slow (~5 fps).

---

## 6. Campaign join / spawn stall 🟡 (`#63`)

**Symptom (historical).** Via the clicked menu→campaign path, the player could fail to spawn into the level / the loading screen ↔ menu could flicker, tied to Steam callbacks the engine expects (lobby-enter, etc.) that the bridge may not deliver at the right time.

**Status.** `+map` direct load works. The bridge now forwards real callbacks (`OP_DRAIN_CALLBACKS`) with a blacklist for known-bad early-init callbacks. End-to-end clicked-campaign flow not re-verified in the current state.

---

## 7. Online HDR auto-exposure without sv_cheats 🟡 (`#67`, `#68`)

**Context.** HDR auto-exposure (`mat_dynamic_tonemapping`) is driven by a per-frame GPU occlusion-query luminance histogram. Some of those controls are `FCVAR_CHEAT` (can't be set in online play without `sv_cheats`), and the occlusion-query path has been suspected in the `0x010c` class. `#67` (an engine cheat-flag patch to toggle auto-exposure offline-style online) and `#68` (a moonshot to reimplement D3D9 occlusion queries in DXVK so auto-exposure works at full speed) are open ideas. **Only relevant once issue #1 — HDR rendering itself — is enabled.**

---

## 8. Durability: game-folder edits get reverted 🟡

**Symptom.** HDR-forcing config (`dxsupport.cfg`, `dxsupport_override.cfg`, `video.txt`) lives in the Steam game folder. A Steam "verify integrity of game files" or a game update regenerates `bin/dxsupport.cfg` and silently reverts the edit, which would re-break HDR (once it's working).

**Fix (TODO).** Have `play-l4d2.sh` re-assert these edits on every launch (it already re-applies the bridge DLL + binary patches; the dxsupport/video.txt edits should join that list).

---

## Resolved (for reference)

These were real blockers, now fixed — useful history if a regression appears:

- **EIP=0 crash after window create** → fixed by `-vulkan` + the full bridge + Timeline interface + engine/client/matchmaking binary patches.
- **DXVK device-create failure on MoltenVK** → gate `geometryShader`/`shaderCullDistance` to supported features. `#45`
- **Constant-buffer slot collision** (`cbuffer_t` + push-const both at MSL buffer 0) → MVKPipelineLayout always reserves a push-constant slot per stage. `#36`
- **32-bit address-space exhaustion at load** → DXVK memory-allocator handling (the reason 2.5.3 was explored). `#57`, `#60`
- **Matchmaking pipe wedge / FreeLastCallback leak** → helper fix. `#43`
- **Steam DRM blocking-call loop** → `IsAPICallCompleted` + `GetAPICallResult` proxied through real Steam. `#5`
