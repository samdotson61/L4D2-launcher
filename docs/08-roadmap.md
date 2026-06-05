# Roadmap — Online-Enabled, Max-Settings, Portable L4D2

**Created:** 2026-06-02 · Organized by **delivery phase**. The goal: take the current
single-player-only build to a **fully online-enabled** L4D2 with **proper HDR/DX9 shading**, with
**maximum settings as the default** (the build is tuned for it) while **letting players change graphics
settings and have them persist**, and make the whole wrapper **portable to any Apple Silicon Mac** by
plugging in the real Steam values from that Mac's Steam app.

> **Binding constraints for every phase:**
> 1. **Max settings is the DEFAULT, not a cage** *(revised 2026-06-04)* — 4× MSAA, `mat_queue_mode -1`
>    (multicore), `mat_picmip 0`, `gpu_level 3`, expensive water, RTT shadows, 16× aniso, DX9.5 is the
>    **recommended baseline the launcher seeds on first run** and the config the build is tuned for. But
>    the **player is in control**: any graphics setting changed in-game **takes effect and persists across
>    restarts**, so the wrapper adapts to different Macs/displays. Two rules still hold: **never lower a
>    setting to "fix" a bug — fix the cause** (max must remain fully playable), and **never force a
>    player's chosen setting back to max** either. `--max-settings` re-applies the baseline on demand. See
>    [C2](#c2-single-source-of-truth-for-settings) and [05-usage.md](05-usage.md#game-graphics-settings).
> 2. **Docs in lockstep** — every code/config change updates the relevant doc in this folder, and
>    the two READMEs stay identical + current, in the same step. No silent drift.

---

## Where we are (ground truth, 2026-06-02; shading row updated 2026-06-04)

Reconciled against `git HEAD` and the live game folder. **Update 2026-06-04:** the long-standing "HDR off /
flat lighting" bug is **fully SOLVED** — rendering was fixed 2026-06-03 (the launcher's own `+mat_hdr_level 1`
arg, now removed, not DXVK or dxlevel), and **playability was fixed 2026-06-04** (the `0x010c` device-lost,
issue #2, root-caused to an **attachment-less render pass** and patched in MoltenVK). **HDR is now playable
end-to-end at max settings** — the user played through campaign level 1 and into level 2 with no freeze/crash.
The shading row below reflects this; see the [Phase 1](#phase-1--proper-shading-hdr--dx95-at-max-settings) box,
[A0](#a0-fix-0x010c-device-lost-under-hdr--done-2026-06-04), and
[03-known-issues #1](03-known-issues.md):

| Reality check | State |
|---|---|
| `git HEAD` | `619cbd5` — *"docs and settings persistence update"* (2026-06-04; player settings now persist — see [C2](#c2-single-source-of-truth-for-settings)). Run `git log --oneline` for the live tip; full milestone lineage is in [01-current-state.md](01-current-state.md). |
| In-game shading | **Full DX9.5 (`mat_dxlevel 100`), HDR playable (`mat_hdr_level 2`)** — proper HDR shading at max settings, **playable end-to-end** *(rendering fixed 2026-06-03, playability fixed 2026-06-04 — the `0x010c` device-lost is solved, see [Phase 1](#phase-1--proper-shading-hdr--dx95-at-max-settings) + [A0](#a0-fix-0x010c-device-lost-under-hdr--done-2026-06-04))* |
| Multiplayer | **Not working** — bridge plumbing exists, but the engine is never put into Steam "online mode" |
| `video.txt` dxlevel | Launcher **seeds** `setting.dxlevel 95` as the first-run default (C2, revised 2026-06-04); a player may change it (HDR needs ≥ DX9). `dxsupport.cfg` durability still pending — see [A2](#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8) |
| Multicore | `mat_queue_mode -1` (**on by default**), seeded in `video.txt`; **player-changeable + persists** (revised 2026-06-04). The `--wined3d` landmine is fixed (now self-heals via a sidecar) — see [C1](#c1-neutralise-the-multicore-landmine-must-fix) |
| DXVK | **1.10.3** deployed (working). **2.5.3** explored 2026-06-02 (allocator angle) but **ruled out as the HDR lever** — a fully-patched 2.5.3 renders identically to 1.10.3; HDR was never a DXVK problem (see [A1, SUPERSEDED](#a1-swap-to-dxvk-253-and-confirm-the-hdr-format--superseded)) |
| Stack | Whisky-Wine 11 · MoltenVK 1.4.1 + patch · Rosetta 2 · macOS 26.x · M4 Pro |

---

# Phase 1 — Proper shading: HDR + DX9.5 at max settings

> **DONE 2026-06-04 — RENDERING *and* PLAYABILITY ACHIEVED.** Proper HDR/DX9.5 shading now **renders and is playable end-to-end** **at max settings (4× MSAA + multicore both ON)**. The `0x010c` device-lost that previously blocked playability is **solved** (see A0 below). The user played through campaign level 1 and into level 2 with no freeze/crash; automated runs log 0 `0x010c` faults over repeated 150 s HDR sessions. The Phase 1 milestone is **met**.
>
> **Real root cause (of the flat lighting):** the launcher's own `DEFAULT_GAME_ARGS` passed `+mat_hdr_level 1` (and `+mat_hdr_level 2`). The engine logs `Unknown command "mat_hdr_level"` for these — but it is **not** a no-op: the engine **queues** the unknown convar and applies it the instant `mat_hdr_level` registers during material-system init, **pinning HDR to level 1 (LDR+bloom)** every launch. At level 1 on L4D2's HDR-only maps, the engine reads the empty LDR lighting lump, logs `Level unlit, setting 'mat_fullbright 1'`, and renders fullbright — the exact flat/over-bright/no-baked-shadow symptom.
>
> **The fix (for rendering):** **delete** both `+mat_hdr_level` tokens from `DEFAULT_GAME_ARGS`. There was nothing to *add* — the fix is the **absence** of the bad token. The engine's true hardware-derived default (level 2, full HDR) then stands. `DEFAULT_GAME_ARGS` is now `-novid -vulkan +r_flashlightdepthtexture 1 +mat_queue_mode -1 +mat_antialias 4` (the `+mat_picmip` / `+r_waterforceexpensive` / `+r_shadowrendertotexture` quality pins were later removed 2026-06-04 — see [C2](#c2-single-source-of-truth-for-settings)).
>
> **Verified:** a VScript probe (`Convars.GetFloat`) reads `mat_hdr_level=2` after removal (was `1` with the args); `Level unlit` is gone; `mat_fullbright` is no longer force-set; `mat_dxlevel` reads `100` (full DX9.5). Full HDR renders and **coexists** with 4× MSAA and `mat_queue_mode -1`.
>
> **The playability fix (`0x010c`, 2026-06-04):** the device-lost was **not** an FP16 tile-memory overflow as first theorized — it was an **attachment-less render pass**. On the first full-scene HDR frame DXVK emits a 16384×16384 render pass with **zero attachments**, and creating a Metal render command encoder with no attachments **hard-aborts the AGX GPU with `0x010c`** (surfacing as `VK_ERROR_DEVICE_LOST`; not an OOM — ~1.8 GB of 18 GB). Patched MoltenVK now **skips creating the encoder for an attachment-less pass**, eliminating the fault. Every historical "playable" build was secretly **HDR-off** (even commit 38dc236's "full HDR" title carried the same `+mat_hdr_level 1` pin), so this is the **first build that is HDR-on _and_ playable**.
>
> **Bonus:** dynamic flashlight shadows are now ON via `+r_flashlightdepthtexture 1` (was the old `0` stopgap) — same queued-arg mechanism, confirmed working.
>
> Full write-up: [03-known-issues #1](03-known-issues.md) (rendering) · [#2](03-known-issues.md) (playability — SOLVED).

**Milestone — MET 2026-06-04:** HDR/DX9 shading renders correctly (interiors read dark, walls shaded
correctly) and is **playable end-to-end** at **every setting maxed (incl. multicore)** — HDR-on survives the
full-scene frame and a level-1→2 playthrough with no `0x010c` device-lost. Closed by
[A0](#a0-fix-0x010c-device-lost-under-hdr--done-2026-06-04). The only residual is an occasional stutter (a
perf nit, issue #5), not a blocker.

### A0. Fix `0x010c` device-lost under HDR — DONE 2026-06-04
> **DONE — the Phase 1 playability blocker is closed.** Turning HDR on used to re-trigger the `0x010c`
> device-lost (`VK_ERROR_DEVICE_LOST`) ~30 s into play (issue #2); HDR is now **playable end-to-end at max
> settings** (user played levels 1→2, 0 faults in automated 150 s runs).
- **Root cause (found, not theorized):** an **attachment-less render pass**. On the first full-scene HDR
  frame DXVK emits a 16384×16384 render pass with **no color/depth/stencil attachment**; creating a Metal
  `MTLRenderCommandEncoder` with no attachments hard-aborts the AGX GPU with Internal Error `0x010c` — by
  itself, even with no draws. **Not** a tile-memory overflow (the earlier theory): the heaviest pass is only
  36 B/px and the main scene is BGRA8_sRGB, not FP16.
- **The fix:** in MoltenVK's `MVKCommandEncoder::beginMetalRenderPass`, when the render-pass descriptor has
  no attachment, **skip creating the render encoder and return early** (`_mtlRenderEncoder` is already nil,
  so draws into that pass are safe no-ops). Default on; `L4D2_MVK_SKIP_NOATT=0` disables. Ships in
  `moltenvk-build/session-patches/moltenvk-all-edits-latest.patch`.
- **How it was pinpointed (the fault is opaque):** the kernel log gives no faulting address, Metal's encoder
  status returns "no encoder info", and the Metal validation layer no-ops under Rosetta/Wine — so attribution
  came from custom MoltenVK instrumentation: `[mvk-tiledbg]` attachment-footprint logging (which **refuted**
  the tile-budget theory), `MVK_L4D2_SYNC` per-buffer commit+wait, and a command-buffer splitter
  (`L4D2_MVK_MAX_PASSES`) that at N=1 isolated the lone attachment-less pass. Full analysis:
  [03-known-issues #2](03-known-issues.md).

> **SUPERSEDED 2026-06-03 — original "Why HDR is off" hypothesis was wrong.** The text below blamed DXVK
> `CheckDeviceFormat` / dxlevel-forcing. That was a **red herring**: an instrumented probe confirmed DXVK
> already returns `D3DFMT_A16B16G16R16F` as renderable+blendable (`result=0`/D3D_OK) at init, and the engine
> runs `mat_dxlevel 100` regardless. HDR was pinned off by the launcher's own `+mat_hdr_level 1` arg (above),
> not by any DXVK/dxlevel cap. Kept for history:
>
> > ~~**Why HDR is off.** Source enables HDR only when D3D9 `CheckDeviceFormat` reports an FP16-renderable,
> > *blendable* HDR render target (`D3DFMT_A16B16G16R16F`). That capability comes from DXVK. Deployed DXVK
> > 1.10.3 doesn't surface it the way Source needs, so the engine logs `HDR Disabled` and falls back to LDR
> > lightmaps. dxlevel-forcing alone is proven insufficient (already tried via `video.txt` + `dxsupport.cfg`
> > + `dxsupport_override.cfg`).~~

### A1. Swap to DXVK 2.5.3 and confirm the HDR format — SUPERSEDED
> **MOOT / SUPERSEDED 2026-06-03.** This entire subsection chased the **debunked** premise that HDR was off
> because DXVK 1.10.3 didn't surface the FP16 blendable RT, so swapping to DXVK 2.5.3 (or patching
> `CheckDeviceFormat`) would "turn HDR on." **DXVK was never the HDR lever.** The real cause was the
> launcher's own `+mat_hdr_level 1` arg (see the Phase 1 box above and [03-known-issues #1](03-known-issues.md)),
> and the actual A1 work had *already concluded* "DXVK is NOT the HDR lever" — that conclusion was correct,
> only the follow-on ("so pivot to why the engine stays DX8-level") was wrong: the engine was at full DX9.5
> (`mat_dxlevel 100`) the whole time.
>
> **Historical record (do not delete — it was genuinely explored and ruled out):** A 2.5.3 swap was tried over
> 2026-06-02. The stock stash black-screened (missing our shadow-sampler patch); a hand-ported, rebuilt 2.5.3
> cleared the pipeline-compile failures and `#61` device-creation gating, but DXVK 2.x **unconditionally requires
> `robustBufferAccess2`** (which Metal/MoltenVK can't provide), causing a flaky `vkCreateDevice` hang/fail. Faking
> that feature in MoltenVK made 2.5.3 **render** `c1m1_hotel` — but **visually identical to 1.10.3 (HDR still off)**
> and with ~1800 per-frame `0x010c` faults. Conclusion at the time: two very different DXVK builds both rendered
> HDR-off → **DXVK is not the HDR variable.** (Now fully explained: both inherited the bad `+mat_hdr_level 1` arg.)
> Work preserved for any future DXVK-2.x *allocator* effort: `dxvk-build/shadow-sampler-workaround-2.5.3.patch`,
> built `dxvk-build/dxvk_d3d9.dll.253-patched`, faked `moltenvk-build/libMoltenVK.dylib.rba2true`. Stable deployed:
> 1.10.3 + `libMoltenVK.dylib.stable-rba2false`.
>
> The "next moves" once listed here — `forceSamplerTypeSpecConstants`, rebasing/rebuilding 2.5.3, faking MoltenVK
> `robustBufferAccess2`, and the fallback "targeted `CheckDeviceFormat` patch to advertise `A16B16G16R16F`" — are
> **all moot for HDR**. None of them was the lever; the fix was removing one launch arg.

### A2. Re-assert DX9.5 everywhere (and make it durable — fixes issue #8)
> **Note 2026-06-03:** DX9.5 is **confirmed already in effect** (`mat_dxlevel 100`, read via VScript probe) — it
> was never the HDR gate (HDR was pinned off by `+mat_hdr_level 1`, since fixed; see Phase 1 box). A2 remains a
> valid **durability** task: keep the max-settings/`dxlevel 95` block from being silently reverted by a Steam
> "verify integrity"/update. It is **not** an HDR-enablement task.
- `bin/dxsupport.cfg` block `"0"`: `maxdxlevel 98` / `dxlevel 95` (already applied).
- `left4dead2/dxsupport_override.cfg` block `"3"`: `vendorid 0x106b` → `dxlevel 95 / maxdxlevel 98`.
- `video.txt`: seed `setting.dxlevel 95` — **done via [C2](#c2-single-source-of-truth-for-settings)**
  (`assert_max_settings` seeds it on first run / `--max-settings`). (`maxdxlevel`/`mindxlevel` are
  `dxsupport.cfg` keys, not VideoConfig settings, so they don't belong in `video.txt`.)
- **Durability is now opt-in (revised 2026-06-04):** since the launcher no longer force-re-asserts settings
  every launch (that would clobber player choices — see [C2](#c2-single-source-of-truth-for-settings)), a Steam
  "verify integrity"/update that regenerates `video.txt`/`dxsupport*.cfg` is recovered by running
  **`./play-l4d2.sh --max-settings`** (re-applies the `video.txt` baseline) rather than silently every launch.
  This is lower-stakes than once thought: HDR does **not** depend on the `dxsupport.cfg` dxlevel edits (the
  engine runs `mat_dxlevel 100` regardless; HDR was gated by a launch arg, since removed), so a reverted
  `dxsupport.cfg` no longer re-breaks HDR. Making the two `dxsupport*.cfg` edits re-appliable via the same
  `--max-settings`/re-apply step is the remaining A2 scope.

### A3. Tonemapping without the M4 AGX auto-exposure crash
> **Update 2026-06-03:** HDR is now fully ON by default (the `+mat_hdr_level 1` arg that forced fullbright is
> gone), so this is **no longer about enabling HDR** — only about exposure quality. The exposure/tonemap
> convars (`mat_dynamic_tonemapping`, `mat_force_tonemap_scale`) were **never** the cause of the flat look;
> they simply had nothing to tonemap while the level rendered fullbright.

The one HDR feature that faults M4 AGX is **auto-exposure** (`mat_dynamic_tonemapping`), which drives a
per-frame GPU occlusion-query luminance histogram. If adaptive exposure proves unstable on M4 AGX, the
`listenserver.playable.bak` recipe — **`mat_dynamic_tonemapping 0` (fixed exposure)** with a sane
`mat_force_tonemap_scale` — is a fallback; full adaptive exposure is the A5 stretch goal (`#68`).

### A4. Verify HDR at MAX settings — DONE 2026-06-04 (rendering AND playability)
Verified (rendering, 2026-06-03): VScript probe reads `mat_hdr_level=2` and `mat_dxlevel=100`; `Level
unlit`/forced `mat_fullbright` absent from `console.log`; user confirmed the visual — HDR renders correctly
**with HDR-on + 4× MSAA + multicore all active**. **Playability now verified too (2026-06-04):** with the
attachment-less-skip `0x010c` fix ([A0](#a0-fix-0x010c-device-lost-under-hdr--done-2026-06-04)), the user
**played through campaign level 1 and into level 2 with no freeze and no crash** at max settings (HDR on);
automated runs log **0 `0x010c` faults** over repeated 150 s sessions and skip 13,000+ attachment-less passes
with no visual regression. The earlier "stayed up over a 78-second run" read covered only the rendering/probe
window; this is sustained active play. (Note: the diag harness's `HDR Enabled` grep is *not* the authoritative
read — the VScript probe and the absence of `Level unlit` are; the harness still **cannot** judge tonemapping,
so the user remains the visual authority.) Residual: an occasional stutter (perf nit, issue #5), not a blocker.

### A5. Stretch quality (not blockers)
- `#68` — reimplement D3D9 occlusion queries in DXVK → true auto-exposure at full speed.
- ~~`#3` — remove the `+r_flashlightdepthtexture 0` stopgap so the flashlight casts shadows again.~~
  **DONE 2026-06-03** — `DEFAULT_GAME_ARGS` now passes `+r_flashlightdepthtexture 1` (dynamic flashlight
  shadows on via the same queued-arg mechanism, confirmed working by the user). No memoryless-store-action
  patch was needed.

## Settings hardening (max-settings guarantee — part of Phase 1)

### C1. Neutralise the multicore landmine (MUST-FIX)
**DONE (2026-06-02).** `play-l4d2.sh`'s `--wined3d` path used to rewrite `video.txt` `mat_queue_mode → 0`
**and** write a **persistent `autoexec.cfg`** containing `mat_queue_mode 0`, which the engine then exec'd on
**every** launch (including the DXVK path) — silently killing multicore. Implemented:
- The `--wined3d` path **no longer writes `autoexec.cfg`**; serialisation is scoped to that run only — the
  `+mat_queue_mode 0` launch arg plus a `video.txt` flip. It first saves the pre-run `mat_queue_mode` to a
  `.wined3d-mqm-restore` sidecar; `_wined3d_restore` (an `EXIT` trap) restores **that exact value** on exit
  (not a hardcoded `-1`), so a player's single-core *or* multicore preference survives a wined3d run.
- **Update 2026-06-04 (settings now persist):** `assert_max_settings` no longer force-re-asserts
  `mat_queue_mode -1` every launch — that would clobber a player's choice (see [C2](#c2-single-source-of-truth-for-settings)).
  The landmine guarantee is preserved differently: if a hard-killed `--wined3d` run left the sidecar behind, the
  next launch's `assert_max_settings` **self-heals** `mat_queue_mode` from it and deletes the sidecar; it also
  still removes any launcher-written `mat_queue_mode 0` `autoexec.cfg`.

### C2. Single source of truth for settings
**DONE (2026-06-02) · REVISED to seed-not-enforce (2026-06-04).** `assert_max_settings` manages the
VideoConfig half of the max baseline in `video.txt` — `gpu_level 3`, `mat_antialias 4` (4× MSAA),
`mat_forceaniso 16`, `mat_queue_mode -1`, **`dxlevel 95`**, plus this Mac's detected `defaultres`/
`defaultresheight` (D2) — and snapshots the original to `video.txt.orig-pre-launcher`.
> **Policy change 2026-06-04 — it no longer force-overwrites these every launch.** The old behaviour
> (re-write the whole block from `detect_resolution` on every launch) was exactly why **saved resolution
> didn't persist** — and would equally clobber any in-game MSAA/aniso/detail/multicore change. New behaviour:
> **WRITE the full baseline only on the first launcher run** (no `video.txt.orig-pre-launcher` snapshot yet)
> **or on explicit `--max-settings`** (`FORCE_MAX=1`); on **every later run, SEED-IF-ABSENT only** — fill in a
> max default for a key the player/engine hasn't written, but **never overwrite a value already present**.
> `video.txt` latches at material-system init and overrides launch args, so a player's saved value beats the
> (now inert) `+mat_antialias`/`+mat_queue_mode` args in `DEFAULT_GAME_ARGS` — those settings persist. `L4D2_RES`
> stays an explicit per-launch resolution override. The seeded baseline includes the detail levels that drive
> texture/water/shadow quality (`gpu_level 3`, `gpu_mem_level 2`, `cpu_level 2`, `mem_level 2` — L4D2's "very
> high"). The three ConVar-only quality pins (`mat_picmip 0` / `r_waterforceexpensive 1` /
> `r_shadowrendertotexture 1`) were **removed from `DEFAULT_GAME_ARGS` 2026-06-04** — they duplicated those
> levels and, lacking a `video.txt` key, both overrode the player's menu choices and couldn't persist (not
> `FCVAR_ARCHIVE`); quality now follows the persisted detail levels. See
> [05-usage.md](05-usage.md#game-graphics-settings).

The ConVar-only settings (picmip 0, expensive water, RTT shadows) ride in `DEFAULT_GAME_ARGS`. The stale
launcher comments and the old "MSAA off / queue 0 was the verified-clean set" claim are gone.
**Correction 2026-06-03:** an earlier rewrite called `mat_hdr_level`
"a no-op in this retail build" — that was *wrong*. The engine logs `Unknown command` but **queues** the convar
and applies it at material-system init, so `+mat_hdr_level 1` actively **pinned HDR off**. Both `+mat_hdr_level`
tokens have since been **removed** from `DEFAULT_GAME_ARGS`, letting the hardware default (level 2, full HDR)
stand — see Phase 1 box and [03-known-issues #1](03-known-issues.md).
> Note: seeding `dxlevel 95` into `video.txt` also lands the **`video.txt` portion of [A2](#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8)** (re-appliable via `--max-settings`). A2's remaining scope is making the `dxsupport.cfg` / `dxsupport_override.cfg` edits equally re-appliable across a Steam file-verify.

### C3. Verify max survives HDR-on + online mode
**Max + HDR-on: confirmed (2026-06-04).** The `0x010c` crash stays away at max settings with HDR on — the
attachment-less-skip fix ([A0](#a0-fix-0x010c-device-lost-under-hdr--done-2026-06-04)) holds across a
level-1→2 playthrough and repeated 150 s runs (0 faults). **Still open (rolls into Phase 3):** re-confirm this
once the engine is in **online mode**, and handle the `FCVAR_CHEAT` gating of auto-exposure in online play
(`#67`) if/when A5 lands.

---

# Phase 2 — Portability to any Apple Silicon Mac

> **Status: CODE-COMPLETE (2026-06-04) — only hardware validation remains.** All six per-machine items
> (D1–D6) are implemented; the only open work is a clean-Mac `build-deps.sh` run (D4) and a non-M4 Apple
> Silicon test (D5), both of which need different hardware.

**Milestone:** a clean checkout + `./play-l4d2.sh` on a *different* Apple Silicon Mac builds, detects that
Mac's Steam + resolution, and launches into online-capable, properly-shaded, max-settings L4D2. (Issue #10.)

The wrapper already reads **real SteamID / persona / auth live from the running Mac Steam client** — there
is **no hardcoded SteamID** (verified). `vendorid 0x106b` + MoltenVK `isAppleGPU` (Apple1–Apple10) cover
M1–M4+. Patched MoltenVK/DXVK rebuild from pinned tags + tracked `.patch` files via `build-deps.sh`.

### D1. De-hardcode the Steam dylib path (MUST-FIX)
> **DONE 2026-06-04.** The hardcoded `DYLIB_PATH` at `bridge/steam_helper.c:33` is gone — replaced by a
> `resolve_dylib_path()` that resolves at startup: **`$L4D2_STEAM_DYLIB`** (explicit override, used verbatim)
> → **`$L4D2_GAME_DIR/bin/libsteam_api.dylib`** → **`$HOME` + the default macOS Steam library**
> (`…/steamapps/common/Left 4 Dead 2/bin/libsteam_api.dylib`); first existing wins, and a total miss still
> dlopens the `$HOME` default so the error names a sensible path. `play-l4d2.sh` hands the helper its
> already-resolved path (`L4D2_STEAM_DYLIB="$GAME_DIR/bin/libsteam_api.dylib"`, which honors `L4D2_GAME_DIR`)
> at launch, so the normal path always lands correctly; the in-helper chain is the standalone-run safety net.
> Helper rebuilt clean (`clang -arch arm64 -O2 -Wall`); the override and game-dir tiers were both verified to
> resolve and to name their path on a dlopen miss. No more per-user path.

### D2. Dynamic resolution
> **DONE 2026-06-04 · persistence-aware.** `video.txt`'s resolution is no longer pinned to 1512×982.
> `play-l4d2.sh` gained `detect_resolution()`, and `assert_max_settings` seeds `defaultres`/`defaultresheight`
> from it (in-place update, no duplication; windowed-borderless `fullscreen 0` / `nowindowborder 1` left
> untouched) — but **only on the first launcher run, on `--max-settings`, when the key is missing, or when
> `L4D2_RES` is set**; a player's in-game resolution change otherwise **persists** (it used to be overwritten
> every launch — see [C2](#c2-single-source-of-truth-for-settings)). Order: **`L4D2_RES="WxH"`** override →
> **AppKit `NSScreen.mainScreen.frame`** via in-process
> `osascript` (no Finder-automation prompt) → **`system_profiler`** (native ÷2 for a Retina panel). It writes
> the **logical** (point) resolution, *not* the 3024×1964 backing — 1512×982 is the proven-playable value,
> the borderless window is sized in points, and writing backing pixels would 4× the GPU load on a freshly-
> stabilised build. (The original "native/backing" wording is satisfied by logical res; the two differ only
> by the Retina scale factor.) Verified across override / NSScreen / malformed-env cases and a dry-run
> `video.txt` rewrite (1512×982 → 1920×1080, in place); on detection failure the launcher leaves `defaultres`
> as-is rather than guess.

### D3. "Plug in real Steam values"
> **DONE 2026-06-04.** `play-l4d2.sh` gained a Mac-Steam preflight (`mac_steam_preflight`), run on every
> launch (in `do_launch`) and exposed standalone as **`--steam-check`**. It (a) checks the real macOS Steam
> client (`steam_osx`) is running, (b) verifies `libsteam_api.dylib` exists — the path D1 resolves — and
> **dies with guidance** if missing, and (c) parses the Mac client's `loginusers.vdf` to surface the
> **PersonaName + AccountName + SteamID64** of the MostRecent account, so the user confirms the bridge will
> authenticate as the right account before going online. Library override = `L4D2_GAME_DIR` /
> `L4D2_STEAM_DYLIB`; the Steam dir is overridable via `L4D2_MAC_STEAM_DIR`. (Steam itself decides the active
> *account*, so there's no account-override knob — the preflight surfaces it for confirmation instead.)
> Verified live: reads the real persona + login + SteamID. This is also the **Mac-Steam identity hook that
> Phase 3 online mode leans on** — confirming the live account is exactly what reliable online play needs.

### D4. Path / case / reproducibility hygiene
> **DONE 2026-06-04 (code + case caveat; clean-Mac build verify still pending).** `LAUNCHER_DIR` is no longer
> the hardcoded `~/L4D2-launcher` — it's computed from the script's own location
> (`cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P`), overridable via `L4D2_LAUNCHER_DIR`, so the launcher runs
> from any clone path and on a case-sensitive volume. **Case caveat (now understood + documented):** the
> repo's real on-disk name is **`L4D2-launcher`** (capital); it's often referred to as `l4d2-launcher`, and
> macOS's case-insensitive default FS makes both resolve to the same directory — which is *exactly why* the
> old hardcode happened to work here. `pwd -P` canonicalises to the real case. **Still open:** an actual
> clean-Mac `build-deps.sh` run on fresh hardware to confirm reproducibility (needs another machine).

### D5. Generalise Apple-GPU matching
> **DONE 2026-06-04 (detection + surfacing; cross-chip validation pending hardware).** Added `gpu_preflight`
> (run in `do_launch`): it reads `system_profiler SPDisplaysDataType`, logs the detected GPU (e.g. "Apple M4
> Pro"), and confirms the **Metal vendor id `0x106b`** — the value `dxsupport_override.cfg` + MoltenVK
> `isAppleGPU` key on (covers Apple1–Apple10 = M1–M4+). If a Mac reports a non-Apple vendor it now **warns**
> that the `0x106b` dxsupport match may not apply, so another chip surfaces clearly in the logs instead of
> failing silently. **Still open (needs hardware):** run on a non-M4 Apple Silicon Mac and widen the family
> match if a newer chip reports differently.

### D6. First-run UX
> **DONE 2026-06-04 (sequence wired + prereqs documented).** A no-arg `./play-l4d2.sh` runs the full
> first-run pipeline: preflight (macOS/arm64/Rosetta/GPU) → `ensure_gptk` (auto-fetches the Whisky-Wine
> bundle if absent) → `ensure_patched_moltenvk` → `ensure_prefix` (wineboot) → Mac-Steam preflight (D3) →
> bridge build/install + helper → `assert_max_settings` (first run: seeds max defaults + detects resolution, C2/D2) → launch. Exact toolchain
> prereqs (Xcode CLT, `brew install meson ninja glslang`, mingw-w64) live in
> [06-building.md](06-building.md#toolchain-prerequisites). **Caveat:** on a truly fresh clone run
> `build-deps.sh` first — the patched MoltenVK/DXVK binaries aren't in git (the launcher auto-builds the
> *bridge* but not those two).

---

# Phase 3 — Online multiplayer: join official Steam games

> **Status: IN PROGRESS — lobbies WORK; dedicated-server browse + join FIELD-CONFIRMED 2026-06-05 on non-VAC
> servers; match-filter forwarding (B5.1) IMPLEMENTED, re-test pending. Official servers are the VAC gate
> (B7).** Phases 1 (shading) and 2 (portability) are complete. Progress via `--diag-online` captures:
> - **B1–B4 (lobby path) — proven 2026-06-04.** Online mode is reached (`BLoggedOn()=1`,
>   `GetConnectedUniverse()=1`), `RequestLobbyList` returns 50 real lobbies, and once the earlier rate-limit
>   cleared (it was **transient** — from repeated testing), **`CreateLobby` returns `result=1` with a real
>   lobby and lobby joins return `resp=1` (Success)**. Local/online server creation from the menu works.
>   `SteamServersConnected_t` (101) was never even needed.
> - **B5 (dedicated servers) — root cause found 2026-06-04; fix IMPLEMENTED + FIELD-CONFIRMED 2026-06-05.**
>   The server browser was empty because the helper's `ISteamMatchmakingServerListResponse` was a **no-op**:
>   real Steam finds servers (`helper.log`: `noop_ServerResponded iServer=0..22+`) but the events were dropped,
>   and the L4D2 engine **waits on those callbacks** — it never calls `GetServerCount`/`GetServerDetails`. The
>   fix now **forwards** `ServerResponded`/`ServerFailedToRespond`/`RefreshComplete` to the game's response
>   object — the helper queues each (mutex-guarded; Steam fires them off-thread) → ships a `0xFFFFFFFD` drain
>   envelope → the bridge re-dispatches into the game's vtable via a new 2-arg `__thiscall` trampoline
>   (`thiscall_run2`) — **and converts `gameserveritem_t` pack(4)→pack(8)** in `GetServerDetails` (the second
>   bug). **Field test 2026-06-05:** browser populated (1600+ rows re-dispatched, `op=0x0707 GetServerDetails`
>   now called), and a non-VAC dedicated join started a game. Open: **filters are dropped** so the browser is
>   unfiltered (B5.1), and **official = VAC** (B7). **Approach validated against Proton's `lsteamclient`
>   (deep-research 2026-06-04)** — it does exactly
>   this (`CALL_IFACE_VTABLE_0_SERVER_RESPONDED`). Both binaries build clean; `thiscall_run2` was verified
>   under Wine (correct args + balanced stack), the `gameserveritem_t` offsets confirmed by compiling the SDK
>   header (372/`m_steamID`@364 macOS → 376/@368 Windows), and the drain envelope verified by round-trip test.
>   Remaining: a live field test (`connect <ip>` + browser populates with a friend / real servers). See B5.

**Milestone:** first end-to-end proof = listen-server + friend-join; then join official servers via the
browser/lobby. (Issues #6, #7.)

**Good news:** L4D2 asks for the **legacy** interfaces (`SteamUser021`, `SteamFriends017`,
`SteamMatchMaking009`, `SteamMatchMakingServers002`, `SteamNetworking006`) — classic Steam P2P, **not**
the modern SDR/NetworkingSockets stack. The bridge **already** proxies all of them to the real Mac Steam
client: lobby browse/create/join, lobby data/members/owner/game-server, P2P send/read/session, the server
browser, auth tickets, and **synthetic host-side validation** (`ValidateAuthTicketResponse_t` +
`GSClientApprove_t`).

**The real blocker (refined 2026-06-04 by a code read):** entering "Steam online mode" leaves the engine
**blocking on follow-on state the bridge doesn't fully deliver** (permanent loading screen); single-player
works because that state is never required. **Correction 2026-06-04:** the earlier roadmap said the bridge
*blacklists* `SteamServersConnected_t` (id 101) — that is **stale**. 101 was **un-blacklisted 2026-05-26**
and is delivered whenever real Mac Steam emits it (the live blacklist is only 304 `PersonaStateChange_t` +
1101 `UserStatsReceived_t`, and 101 is never synthesized). So the real unknowns are upstream — **does real
Steam even emit 101 in our flow, is it dropped because the engine hasn't registered its handler yet, and
what state (`BLoggedOn`, connected universe, friends list) does the engine poll afterward** — exactly what
B1 instruments. **Online MP requires online mode** — genuine R&D, the highest-risk phase.

**Update — the B1 capture (2026-06-04) answered this:** online mode IS reached and matchmaking works
(`BLoggedOn`/universe healthy, `RequestLobbyList` → 50 real lobbies, callbacks deliver); 101 wasn't even
needed. The actual blocker is Steam **rate-limiting** lobby create (`LimitExceeded`/25) and join
(`RatelimitExceeded`/15). See the Status box above and B1 below.

## Implementation steps

Ordered by execution. **B1–B4 are the critical path to the first milestone** (a working listen-server game
a friend can join); **B5–B6** then extend to joining other people's games; **B7** is a cross-cutting safety
gate that must be cleared before any VAC-secured server. Each step assumes the previous one is verified,
except B7, which applies throughout. *(This re-segments the project's earlier online-MP notes into
execution order: the "fire 101" diagnosis stays first, listen-server hosting moves up to become the first
milestone, and the VAC check becomes an explicit gate at the end.)*

### B1. Diagnose the online-mode dependency chain
> **CAPTURED 2026-06-04 — the dependency chain is already satisfied; the blocker is elsewhere.** First
> `--diag-online` run (`/tmp/bridge.log`): `BLoggedOn()=1`, `GetConnectedUniverse()=1` (public), matchmaking
> gate open, `RequestLobbyList` → 50 real lobbies, and `LobbyEnter`/`LobbyCreated`/`LobbyMatchList`/
> `LobbyChatUpdate` callbacks all delivered to engine handlers — **no missing online state, and 101 was never
> delivered yet online still proceeded.** The ONLY failures: `CreateLobby` → `result=25`
> (`k_EResultLimitExceeded`) and joins → `resp=15` (`k_EChatRoomEnterResponseRatelimitExceeded`) — **Steam is
> rate-limiting this account's lobby create/join.** CreateLobby params (type+max) forward correctly, so it's
> not a bad-params bug. **Conclusion:** there is no online-mode/callback hang to fix; the work is to stop
> tripping — and recover from — Steam's lobby rate limit (this reframes B2–B7). Enable with
> `./play-l4d2.sh --diag-online`; grep guide in [07-debugging.md](07-debugging.md#online-mode-phase-3--b1-diagnostics).

**Do this first — everything below depends on knowing exactly what online mode triggers.** 101 is *not*
blacklisted (it's delivered whenever real Mac Steam emits it), so B1 **observes** rather than forces.
Capture: (a) whether/when real Steam emits 101 (`[helper] real cb id=101`); (b) whether the engine has
registered a 101 handler by then or the callback is dropped (`cb_fire id=101 -> 0 delivered`); (c) what the
engine polls afterward — `BLoggedOn()`, `GetConnectedUniverse()`, `GetAuthSessionTicketResponse_t` (id 163,
already drained), `SteamServerConnectFailure_t` / `SteamServersDisconnected_t`, and `PersonaStateChange_t`
(id 304, the friends-list walk we currently suppress). If 101 never arrives naturally, the follow-up is to
**synthesize it post-menu** (rolls into B2). **Output:** a concrete list of post-101 state the bridge must
satisfy in B2–B3.

### B2. Enter online mode without hanging — fire 101 + satisfy the immediate state machine
Turn B1's diagnosis into a bridge that *survives* online mode instead of suppressing it:
- **101 is already un-blacklisted** (since 2026-05-26), so the work is timing, not un-gating: ensure the
  engine registers its 101 handler before the callback fires (else it's dropped), and if real Steam doesn't
  emit 101 in our flow, **synthesize it gated to after the menu** (avoid the early-init hang).
- Return real `BLoggedOn`/connected-universe so the post-101 state machine completes.
- **Populate the friends list** from real Mac Steam via the helper so the **304** (`PersonaStateChange_t`)
  handler succeeds instead of walking an empty list.
- Handle `SteamServerConnectFailure_t` / `SteamServersDisconnected_t` so a failure path resolves cleanly
  rather than wedging the loading screen.

**Exit criterion:** the engine reaches an interactive online main menu and stays there (no permanent
loading screen) with 101 fired.

### B3. Deliver lobby callbacks at the right time
With online mode stable, complete the lobby state machine: deliver `LobbyEnter_t`, `LobbyChatUpdate_t`, and
`LobbyGameCreated_t` at the right moments. Mistimed/missing lobby callbacks are the likely cause of issue
#6's loading↔menu flicker. **Exit criterion:** creating/entering a lobby transitions the UI correctly with
no flicker.

### B4. First end-to-end proof — listen-server hosting + friend join (FIRST MILESTONE)
> **Lobby half PROVEN 2026-06-04** (once the rate-limit cleared): `CreateLobby` → `result=1` with a real
> lobby (`01860000:77ff3caa`), and lobby joins → `resp=1` (Success). Local/online server creation from the
> menu works. Remaining for full proof: a second machine actually connecting + play proceeding (needs a
> friend / 2nd Steam account).

The lowest-risk, most controllable end-to-end multiplayer test, and the **first** MP milestone. Host-side
synthetic `GSClientApprove` already exists; verify a friend can **join a locally hosted listen-server game**
(NAT-punched P2P via real Steam). Keep this on **non-VAC/community** footing per B7. **Exit criterion:** a
friend connects to a game you host and play proceeds.

### B5. Join an official dedicated server via the server browser
> **FIELD-TESTED 2026-06-05 — the server browser populates and joins succeed on non-VAC servers.** A live run
> confirmed the full path end to end: `helper.log` logged `shipped N server-response envelope(s)` repeatedly,
> the bridge re-dispatched 1600+ rows (`mms_resp: fake=1 type=0 iServer=…1672`), and — the decisive proof — the
> engine then called `GetServerDetails` (`op=0x0707`), which it **never did before**. The user **joined an
> unofficial dedicated server and started a game.** Two findings:
> - **Official / VAC-secured servers fail to join — this is the [B7](#b7-auth--vac-safety-gate-clear-before-any-secured-server--applies-throughout) gate, not a B5 bug.** Official L4D2 servers run
>   `sv_secure 1`; community servers commonly run `sv_secure 0`. The "non-VAC works / official fails" split is
>   exactly the VAC boundary. **Do not pursue secured Valve servers without explicit sign-off (ban risk).**
> - **Match filters were dropped, so the browser was unfiltered.** `mms_RequestInternetServerList` discarded the
>   game's `ppchFilters`/`nFilters` and the helper queried `NULL,0`, so a campaign-mode request listed/joined
>   **any-mode** servers — the user hit a community server that didn't allow campaign mode. **Fixed in
>   [B5.1](#b51-forward-the-server-list-match-filters)** (2026-06-05): the filters are now serialized and
>   forwarded; `[bridge] … filter[i]: key=val` and `[helper] MMS filter[N]: key=val` show what's sent (re-test pending).
>
> One cleanup from the test: the per-dispatch `detect_ret_clean` **WARN was a false positive** (its 64-byte scan
> misreads a stray `0xc3` as `ret 0`) — `ret 8` is proven by the Wine test + 1600+ crash-free live dispatches, so
> the misleading WARN was removed.
>
> **IMPLEMENTED 2026-06-05 — builds clean, unit/Wine-verified.** The three-part fix landed in
> `bridge/steam_helper.c` + `bridge/steam_api_wine.c`: the helper's response-object callbacks **queue** events
> (mutex-guarded) and ship them as `0xFFFFFFFD` drain envelopes, the bridge **re-dispatches** each into the
> game's vtable via the new 2-arg `__thiscall` trampoline `thiscall_run2`, and `GetServerDetails` **repacks
> `gameserveritem_t` pack(4)→pack(8)**. Pre-field-test verification: `thiscall_run2` under real Wine (correct
> `this`/args + balanced stack), the `gameserveritem_t` offsets by compiling the SDK header (macOS
> 372/`m_steamID`@364 → Windows 376/@368), and the drain envelope by a write→read round-trip test.
>
> **ROOT CAUSE FOUND 2026-06-04; fix designed + validated against Proton's `lsteamclient`.** A `--diag-online`
> capture proved it: real Steam **does** find servers (`helper.log`: `noop_ServerResponded iServer=0,1,2,…22+`),
> but the helper's `ISteamMatchmakingServerListResponse` is a **no-op** that drops every event, and the L4D2
> engine **waits on those callbacks** — it never polls `GetServerCount`/`GetServerDetails` (RPC trace: `0x0700`
> RequestInternetServerList fired, zero `0x070B`/`0x0707`). So the browser is fed nothing.
>
> **Validation (deep-research 2026-06-04).** Proton's `lsteamclient` — the Linux analog of this entire bridge
> (the game's own `steam_api.dll` runs in Wine and loads `lsteamclient`, which proxies to the native Steam
> client) — solves this exact case. Its callback pump `execute_pending_callbacks()` (run around
> `Steam_BGetCallback`) pulls native callbacks, converts each native→Windows struct, and **re-dispatches into
> the game's callback object via its vtable**; for the server browser it has a dedicated case
> `CALL_IFACE_VTABLE_0_SERVER_RESPONDED` that calls **vtable slot 0** of the Windows
> `ISteamMatchmakingServerListResponse`. That is exactly the drain → re-dispatch design below, so the plan is
> confirmed correct (the "pass the response object straight through to native Steam" alternative was explicitly
> **refuted**, 0-3). These server-browser callbacks are in Proton's `MANUAL_METHODS` — i.e. even Proton
> hand-wires this, so it's the expected approach, not a hack. Refs: Proton `lsteamclient/steamclient_main.c` +
> `gen_wrapper.py` (proton_9.0); Goldberg `steam_matchmaking_servers.cpp`.
>
> **The fix (implemented 2026-06-05) — forward the three response callbacks AND convert the row struct:**
> 1. **Helper** — replace the no-op `ServerResponded`/`ServerFailedToRespond`/`RefreshComplete` with versions
>    that **queue** `{hReq, iServer, type}` (**mutex-guarded** — Steam may fire these from its own thread), and
>    drain the queue into `OP_DRAIN_CALLBACKS` as a new `0xFFFFFFFD` envelope.
> 2. **Bridge DLL** — store the game's `pResponse` per request handle (currently discarded in
>    `mms_RequestInternetServerList`); on draining a `0xFFFFFFFD` event, map the real `hReq` → fake handle and
>    invoke `pResponse->vtable[type](pResponse, fakeHandle, iServer)` via a new 2-arg `__thiscall` trampoline
>    (`thiscall_run2`, mirroring `thiscall_run0` but `ret 8`). For L4D2 the response is the modern
>    `ServerResponded(hRequest, iServer)` form (confirmed — `helper.log` prints `iServer`), so no struct is
>    passed here; `type` picks the vtable slot (0=Responded, 1=FailedToRespond, 2=RefreshComplete).
> 3. **Convert `gameserveritem_t` in `GetServerDetails` — SECOND BUG, surfaced by the research.** Steamworks
>    structs are **pack(8) on Windows but pack(4) on macOS**, yet `mms_GetServerDetails` returned the 400-byte
>    row **raw**. So even once the list populates, the game would misread each row — notably the trailing
>    `CSteamID m_steamID` (the value used to connect). **Confirmed by compiling the SDK header:** it shifts by
>    exactly 4 bytes (macOS `m_steamID`@364, `sizeof` 372 → Windows @368, `sizeof` 376 — the pack(4) leaks in
>    via `steamclientpublic.h`'s `#pragma pack(push,4)` even though `gameserveritem_t` isn't a callback struct).
>    Added `repack_gameserveritem_pack4_to_pack8` (helper-side, like `repack_pack4_to_pack8`): copy the
>    byte-identical first 364 B, insert a 4-byte pad, move the 8-byte SteamID, ship a zero-padded 400-byte frame
>    so the bridge's fixed `g_mms_server_details_buf` still matches. Proton never hard-codes packing — it derives
>    per-struct alignment from the compiler AST; our per-callback repack table is the manual equivalent, and
>    `gameserveritem_t` was simply missing from it.
>
> Blast radius is contained — this path only runs during server browsing, so it can't regress the working
> lobby path. One safety change does touch the shared drain: the bridge's `g_drain_buf` was enlarged 32 KB →
> 256 KB to match the helper, since `rpc_call` **discards** any over-size drain whole — an undersized buffer
> would have dropped lobby callbacks too once server-browser events shared a drain. *(vtable note: MSVC swaps
> the first two virtuals of `CCallbackBase`'s two `Run` overloads — irrelevant here since `ServerResponded`
> isn't overloaded, but a known trap for the `CCallback` path.)*

`RequestInternetServerList` now forwards real server rows into the game's `ISteamMatchmakingServerListResponse`
— the helper's former **no-op** `ServerResponded` vtable now queues and delivers real results (via the
`0xFFFFFFFD` envelope path above), **field-confirmed 2026-06-05** (browse populates, join works on non-VAC).
Joining a **secured** server is **gated by B7** (VAC).

### B5.1 Forward the server-list match filters
The 2026-06-05 field test surfaced this: `mms_RequestInternetServerList` had **dropped** the game's
`ppchFilters` / `nFilters` (the helper queried real Steam with `NULL, 0`), so the server browser was
**unfiltered** — a campaign-mode request could list and join an any-mode server (what bit the user). Now
forwarded end to end:
- **Bridge DLL** — serializes the game's filters into the `OP_MMS_REQUESTINTERNETSERVERLIST` arg: `u32 appid` +
  `u32 nFilters` + `nFilters × {key\0 value\0}`. Plain `char`, so no pack(4)/pack(8) concern.
- **Helper** — the per-op arg buffer grew 256 B → 4 KB; it rebuilds a native `MatchMakingKeyValuePair_t[]` + a
  `MatchMakingKeyValuePair_t*[]` pointer array (capped at 16) and passes `(ptrs, nFilters)` to
  `p_MMS_RequestInternetServerList` instead of `NULL, 0`.

> **ABI CORRECTION (first field test, 2026-06-05).** The initial cut read `ppchFilters` as an **array of
> pointers** (`fp[i]`, the Goldberg/Proton form). `helper.log` proved that wrong: `filter[0]=gamedir=left4dead2`
> was right but `[1..5]` were heap/code garbage — and that garbage went **out to Steam**, which silently broke
> the query (joining regressed to "can't join any" while the mode mismatch persisted). The truth: L4D2/Source
> passes `&pFilters` where `pFilters` → a **single contiguous array** of `nFilters` structs (element 0 only
> *looked* right because `*ppchFilters` IS the base). **Fixed:** deref `ppchFilters` once to get the base, then
> index `base + i*512`; each struct read is `IsBadReadPtr`-guarded and **every key is validated as non-empty
> printable ASCII** so a future misread can never ship garbage filters again (worst case it forwards only the
> valid ones, e.g. `gamedir`, = pre-B5.1 behaviour). A native contiguous-read unit test passes (3 real filters +
> a garbage one correctly skipped).

**Verification:** builds clean; serialize→parse and contiguous-read unit tests pass. **Remaining:** re-test in
game — `helper.log` should now show `MMS filter[1]=gametype=…` etc. as **clean** keys (not garbage), and a
campaign browse should list **only** campaign-capable servers. (Friends/Favorites/History/Spectator lists stay
filterless — Internet is L4D2's campaign path.)

### B6. Join a friend's game — lobby / "Join Game"
Test the Steam-overlay/friends **Join Game** flow and the in-game lobby browser (`RequestLobbyList` →
`JoinLobby` → P2P to host). The pack(4)→pack(8) callback repack and the matchmaking callback gate are
already in place; verify timing end-to-end.

### B7. Auth / VAC safety gate (clear before any secured server — applies throughout)
**Cross-cutting, not a final step.** The bridge uses the host's **real** auth ticket and **real SteamID**
from the Mac Steam client, so the player authenticates as their genuine account. **However, running under
Wine + a custom `steam_api.dll` on a VAC-secured official server carries a real (if small) VAC-ban risk.**
Plan: do all first-time MP (B4–B6) on **listen-server + friend-join** and **non-VAC/community** servers;
**get explicit user sign-off before joining secured Valve official servers.**

---

## Risks / unknowns (call these out loud)
- ~~**HDR via DXVK 2.5.3 is the leading hypothesis but untested.**~~ **RESOLVED 2026-06-03 (for rendering)** —
  DXVK was never the HDR lever; HDR was pinned off by the launcher's own `+mat_hdr_level 1` arg, now removed.
  HDR *rendering* is no longer a risk.
- ~~**`0x010c` device-lost under HDR (NEW, OPEN)**~~ **RESOLVED 2026-06-04** — root-caused to an
  **attachment-less render pass** (a 16384×16384 pass with zero attachments hard-aborts the AGX GPU), **not**
  a tile-memory overflow as first theorized; patched MoltenVK skips creating an encoder for it (issue #2 /
  [A0](#a0-fix-0x010c-device-lost-under-hdr--done-2026-06-04)). HDR is playable end-to-end at max settings.
  No longer a Phase 1 risk.
- **Online mode (firing 101) historically hangs** — Phase 3 is real engineering, the highest-risk part of
  this roadmap, not a setting. **This is now the leading live risk.**
- **VAC risk** on secured official servers under Wine — must be flagged before connecting.
- ~~**Memory/docs conflict** ("HDR worked" in an earlier note vs. `HDR Disabled` in git/docs).~~ Moot as of
  2026-06-04: HDR genuinely **renders and is playable** now (`mat_hdr_level 2`, playable end-to-end at max
  settings after the `0x010c` fix, issue #2 / A0), so the "HDR works" position is the correct one.
