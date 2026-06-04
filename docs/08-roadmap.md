# Roadmap — Online-Enabled, Max-Settings, Portable L4D2

**Created:** 2026-06-02 · Organized by **delivery phase**. The goal: take the current
single-player-only build to a **fully online-enabled** L4D2 with **proper HDR/DX9 shading**, kept
at **maximum settings throughout (including multicore rendering)**, and make the whole wrapper
**portable to any Apple Silicon Mac** by plugging in the real Steam values from that Mac's Steam app.

> **Binding constraints for every phase (non-negotiable):**
> 1. **Max settings always** — 4× MSAA, `mat_queue_mode -1` (multicore), `mat_picmip 0`,
>    `gpu_level 3`, expensive water, RTT shadows, 16× aniso, DX9.5. **Never lower a setting to
>    "fix" a bug — fix the cause.** Multicore rendering specifically stays on.
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
| `git HEAD` | `8cdc8ca` — *"working dx8 no tonemapping no multiplayer"* |
| In-game shading | **Full DX9.5 (`mat_dxlevel 100`), HDR playable (`mat_hdr_level 2`)** — proper HDR shading at max settings, **playable end-to-end** *(rendering fixed 2026-06-03, playability fixed 2026-06-04 — the `0x010c` device-lost is solved, see [Phase 1](#phase-1--proper-shading-hdr--dx95-at-max-settings) + [A0](#a0-fix-0x010c-device-lost-under-hdr--done-2026-06-04))* |
| Multiplayer | **Not working** — bridge plumbing exists, but the engine is never put into Steam "online mode" |
| `video.txt` dxlevel | Launcher now asserts `setting.dxlevel 95` on every launch (C2 ); `dxsupport.cfg` durability still pending — see [A2](#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8) |
| Multicore | `mat_queue_mode -1` (**on**), now re-asserted in `video.txt` every launch; the `--wined3d` landmine is fixed — see [C1](#c1-neutralise-the-multicore-landmine-must-fix) |
| DXVK | **1.10.3** deployed (working). **2.5.3** explored 2026-06-02 (allocator angle) but **ruled out as the HDR lever** — a fully-patched 2.5.3 renders identically to 1.10.3; HDR was never a DXVK problem (see [A1, SUPERSEDED](#a1-swap-to-dxvk-253-and-confirm-the-hdr-format--superseded)) |
| Stack | Whisky-Wine 11 · MoltenVK 1.4.1 + patch · Rosetta 2 · macOS 26.x · M4 Pro |

---

# Phase 1 — Proper shading: HDR + DX9.5 at max settings

> **DONE 2026-06-04 — RENDERING *and* PLAYABILITY ACHIEVED.** Proper HDR/DX9.5 shading now **renders and is playable end-to-end** **at max settings (4× MSAA + multicore both ON)**. The `0x010c` device-lost that previously blocked playability is **solved** (see A0 below). The user played through campaign level 1 and into level 2 with no freeze/crash; automated runs log 0 `0x010c` faults over repeated 150 s HDR sessions. The Phase 1 milestone is **met**.
>
> **Real root cause (of the flat lighting):** the launcher's own `DEFAULT_GAME_ARGS` passed `+mat_hdr_level 1` (and `+mat_hdr_level 2`). The engine logs `Unknown command "mat_hdr_level"` for these — but it is **not** a no-op: the engine **queues** the unknown convar and applies it the instant `mat_hdr_level` registers during material-system init, **pinning HDR to level 1 (LDR+bloom)** every launch. At level 1 on L4D2's HDR-only maps, the engine reads the empty LDR lighting lump, logs `Level unlit, setting 'mat_fullbright 1'`, and renders fullbright — the exact flat/over-bright/no-baked-shadow symptom.
>
> **The fix (for rendering):** **delete** both `+mat_hdr_level` tokens from `DEFAULT_GAME_ARGS`. There was nothing to *add* — the fix is the **absence** of the bad token. The engine's true hardware-derived default (level 2, full HDR) then stands. `DEFAULT_GAME_ARGS` is now `-novid -vulkan +r_flashlightdepthtexture 1 +mat_queue_mode -1 +mat_picmip 0 +r_waterforceexpensive 1 +r_shadowrendertotexture 1 +mat_antialias 4`.
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
- `video.txt`: add `setting.dxlevel 95` — **done via [C2](#c2-single-source-of-truth-for-settings)**
  (`assert_max_settings` asserts it every launch). (`maxdxlevel`/`mindxlevel` are `dxsupport.cfg` keys, not
  VideoConfig settings, so they don't belong in `video.txt`.)
- **Launcher re-asserts on every launch** so a Steam "verify integrity"/update can't silently revert the
  max-settings/`dxlevel 95` block. **Partly done:** C2 re-asserts `video.txt` (incl. `dxlevel 95`); the two
  `dxsupport*.cfg` files still need the same treatment, joined to the existing bridge-DLL/binary-patch re-apply step.

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
  `+mat_queue_mode 0` launch arg plus a `video.txt` flip that `_wined3d_restore` (an `EXIT` trap) reverts to
  `-1` on exit.
- Every DXVK launch runs `assert_max_settings`, which **re-asserts `mat_queue_mode -1`** in `video.txt` and
  **removes any stale `mat_queue_mode 0` `autoexec.cfg`** — so even a hard-killed `--wined3d` run self-heals.

### C2. Single source of truth for settings
**DONE (2026-06-02).** `assert_max_settings` idempotently asserts the VideoConfig half of the
max-settings block into `video.txt` on every launch — `gpu_level 3`, `mat_antialias 4` (4× MSAA),
`mat_forceaniso 16`, `mat_queue_mode -1`, **`dxlevel 95`** — and snapshots the original to
`video.txt.orig-pre-launcher`. The ConVar-only settings (picmip 0, expensive water, RTT shadows) ride in
`DEFAULT_GAME_ARGS`, which agrees with this block. The stale launcher comments and the old "MSAA off / queue 0
was the verified-clean set" claim are gone. **Correction 2026-06-03:** an earlier rewrite called `mat_hdr_level`
"a no-op in this retail build" — that was *wrong*. The engine logs `Unknown command` but **queues** the convar
and applies it at material-system init, so `+mat_hdr_level 1` actively **pinned HDR off**. Both `+mat_hdr_level`
tokens have since been **removed** from `DEFAULT_GAME_ARGS`, letting the hardware default (level 2, full HDR)
stand — see Phase 1 box and [03-known-issues #1](03-known-issues.md).
> Note: asserting `dxlevel 95` in `video.txt` also lands the **`video.txt` portion of [A2](#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8)** early. A2's remaining scope is making the `dxsupport.cfg` / `dxsupport_override.cfg` edits equally durable across a Steam file-verify.

### C3. Verify max survives HDR-on + online mode
**Max + HDR-on: confirmed (2026-06-04).** The `0x010c` crash stays away at max settings with HDR on — the
attachment-less-skip fix ([A0](#a0-fix-0x010c-device-lost-under-hdr--done-2026-06-04)) holds across a
level-1→2 playthrough and repeated 150 s runs (0 faults). **Still open (rolls into Phase 2):** re-confirm this
once the engine is in **online mode**, and handle the `FCVAR_CHEAT` gating of auto-exposure in online play
(`#67`) if/when A5 lands.

---

# Phase 2 — Online multiplayer: join official Steam games

**Milestone:** first end-to-end proof = listen-server + friend-join; then join official servers via the
browser/lobby. (Issues #6, #7.)

**Good news:** L4D2 asks for the **legacy** interfaces (`SteamUser021`, `SteamFriends017`,
`SteamMatchMaking009`, `SteamMatchMakingServers002`, `SteamNetworking006`) — classic Steam P2P, **not**
the modern SDR/NetworkingSockets stack. The bridge **already** proxies all of them to the real Mac Steam
client: lobby browse/create/join, lobby data/members/owner/game-server, P2P send/read/session, the server
browser, auth tickets, and **synthetic host-side validation** (`ValidateAuthTicketResponse_t` +
`GSClientApprove_t`).

**The real blocker:** the bridge **blacklists** `SteamServersConnected_t` (id 101) because firing it flips
the engine into "Steam online mode," after which the engine **blocks on follow-on state the bridge
doesn't yet deliver** (permanent loading screen). Single-player survives *because* we suppress online
mode. **Online MP requires online mode** — so Phase 2 is genuine R&D, not a config flip, and the
highest-risk phase.

### B1. Map the online-mode dependency chain
With a debug helper, **fire 101 after the main menu is reached** and capture exactly what the engine then
polls/waits on. Expected dependents: `BLoggedOn() == true`, connected universe (`ISteamUtils`),
`GetAuthSessionTicketResponse_t` (id 163, already drained), `SteamServerConnectFailure_t` /
`SteamServersDisconnected_t` handling, and `PersonaStateChange_t` (id 304) where the engine walks a
friends list we don't populate.

### B2. Replace "blacklist to survive" with "populate real data"
- Un-blacklist **101**, but **gate it until after the menu** (avoid the early-init hang).
- **Populate the friends list** from real Mac Steam via the helper so the **304** handler succeeds.
- Return real `BLoggedOn`/connected-universe so the post-101 state machine completes.
- Deliver lobby callbacks at the right time — `LobbyEnter_t`, `LobbyChatUpdate_t`, `LobbyGameCreated_t`
  — the likely cause of issue #6's loading↔menu flicker.

### B3. Server browser → join an official dedicated server
Verify `RequestInternetServerList` actually forwards real server rows into the game's
`ISteamMatchmakingServersResponse` (the helper currently has a **no-op** `ServerResponded` vtable — wire
it to deliver real results). Then test `connect <ip>` to an official server.

### B4. Lobby / friends "Join Game"
Test the Steam-overlay/friends **Join Game** flow and the in-game lobby browser (`RequestLobbyList` →
`JoinLobby` → P2P to host). The pack(4)→pack(8) callback repack and the matchmaking callback gate are
already in place; verify timing end-to-end.

### B5. Auth / VAC reality check (flag to user before connecting)
The bridge uses the host's **real** auth ticket and **real SteamID** from the Mac Steam client, so the
player authenticates as their genuine account. **However, running under Wine + a custom `steam_api.dll`
on a VAC-secured official server carries a real (if small) VAC-ban risk.** Plan: do first end-to-end MP on
**listen-server + friend-join** and **non-VAC/community** servers; **get explicit user sign-off before
joining secured Valve official servers.**

### B6. Listen-server hosting (most controllable first proof)
Host-side synthetic `GSClientApprove` already exists. Verify a friend can join a locally hosted game
(NAT-punched P2P via real Steam). This is the lowest-risk end-to-end multiplayer test and should be the
**first** MP milestone.

---

# Phase 3 — Portability to any Apple Silicon Mac

**Milestone:** a clean checkout + `./play-l4d2.sh` on a *different* Apple Silicon Mac builds, detects that
Mac's Steam + resolution, and launches into online-capable, properly-shaded, max-settings L4D2. (Issue #10.)

The wrapper already reads **real SteamID / persona / auth live from the running Mac Steam client** — there
is **no hardcoded SteamID** (verified). `vendorid 0x106b` + MoltenVK `isAppleGPU` (Apple1–Apple10) cover
M1–M4+. Patched MoltenVK/DXVK rebuild from pinned tags + tracked `.patch` files via `build-deps.sh`.

### D1. De-hardcode the Steam dylib path (MUST-FIX)
`bridge/steam_helper.c:33` hardcodes
`DYLIB_PATH "/Users/samdotson/Library/.../Left 4 Dead 2/bin/libsteam_api.dylib"`. Resolve in order:
`$L4D2_STEAM_DYLIB` env → `${L4D2_GAME_DIR:-default}/bin/libsteam_api.dylib` → search common Steam library
locations. Rebuild the helper.

### D2. Dynamic resolution
`video.txt` hardcodes **1512×982** (this 14" MacBook's logical res; the panel is 3024×1964 backing).
Detect the target Mac's native/backing resolution at launch and write `defaultres`/`defaultresheight`
accordingly. Keep windowed-borderless.

### D3. "Plug in real Steam values"
The bridge already pulls **real SteamID / persona / auth** live from the running Mac Steam client. For a
clean port the only host requirements are: Steam **installed + logged in + owns L4D2 (appid 550)**. Add a
preflight that (a) verifies the Mac Steam client is running and logged in, (b) verifies `libsteam_api.dylib`
exists, and (c) surfaces the **detected SteamID + persona** so the user confirms the right account. Optional
explicit account/library override.

### D4. Path / case / reproducibility hygiene
Standardise on the computed `LAUNCHER_DIR`; document the `L4D2-launcher` vs `l4d2-launcher`
case-insensitivity caveat. Verify a clean-Mac build of the patched binaries via `build-deps.sh`.

### D5. Generalise Apple-GPU matching
`vendorid 0x106b` + MoltenVK `isAppleGPU` (Apple1–Apple10) already cover M1–M4+. Validate on at least one
other M-series chip; widen the family check if a newer chip reports differently.

### D6. First-run UX
A single `./play-l4d2.sh` on a fresh Mac should: build deps → populate prefix → detect Steam + resolution →
launch. Document exact prereqs (Xcode CLT, `brew install meson ninja glslang`, mingw-w64, Whisky-Wine fetch).

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
- **Online mode (firing 101) historically hangs** — Phase 2 is real engineering, the highest-risk part of
  this roadmap, not a setting. **This is now the leading live risk.**
- **VAC risk** on secured official servers under Wine — must be flagged before connecting.
- ~~**Memory/docs conflict** ("HDR worked" in an earlier note vs. `HDR Disabled` in git/docs).~~ Moot as of
  2026-06-04: HDR genuinely **renders and is playable** now (`mat_hdr_level 2`, playable end-to-end at max
  settings after the `0x010c` fix, issue #2 / A0), so the "HDR works" position is the correct one.
