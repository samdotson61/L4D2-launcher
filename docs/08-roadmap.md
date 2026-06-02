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

## Where we are (ground truth, 2026-06-02)

Reconciled against `git HEAD` and the live game folder — supersedes any earlier "HDR works" notes:

| Reality check | State |
|---|---|
| `git HEAD` | `8cdc8ca` — *"working dx8 no tonemapping no multiplayer"* |
| In-game shading | **DX8-effective, HDR Disabled** — flat/overexposed lighting (no proper DX9 shading) |
| Multiplayer | **Not working** — bridge plumbing exists, but the engine is never put into Steam "online mode" |
| `video.txt` dxlevel | Launcher now asserts `setting.dxlevel 95` on every launch (C2 ✅); `dxsupport.cfg` durability still pending — see [A2](#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8) |
| Multicore | `mat_queue_mode -1` (**on**), now re-asserted in `video.txt` every launch; the `--wined3d` landmine is fixed — see [C1](#c1-neutralise-the-multicore-landmine-must-fix) ✅ |
| DXVK | **1.10.3** deployed; **2.5.3** stashed (`dxvk-build/dxvk_d3d9.dll.253-stash`) |
| Stack | Whisky-Wine 11 · MoltenVK 1.4.1 + patch · Rosetta 2 · macOS 26.x · M4 Pro |

---

# Phase 1 — Proper shading: HDR + DX9.5 at max settings

**Milestone:** the user confirms proper HDR/DX9 shading (interiors read dark, walls shaded
correctly), 0 `0x010c` faults, with **every setting maxed (incl. multicore)**.

**Why HDR is off.** Source enables HDR only when D3D9 `CheckDeviceFormat` reports an FP16-renderable,
*blendable* HDR render target (`D3DFMT_A16B16G16R16F`). That capability comes from **DXVK**. Deployed
DXVK **1.10.3** doesn't surface it the way Source needs, so the engine logs `HDR Disabled` and falls
back to LDR lightmaps. **dxlevel-forcing alone is proven insufficient** (already tried via `video.txt`
+ `dxsupport.cfg` + `dxsupport_override.cfg`).

### A1. Swap to DXVK 2.5.3 and confirm the HDR format
- Back up deployed `bin/dxvk_d3d9.dll` (1.10.3), drop in `dxvk-build/dxvk_d3d9.dll.253-stash`.
- 2.5.3 needs **MAB-off** + geometry-shader/cull-distance feature gating to create a device on
  MoltenVK (`#61`) — re-apply / re-verify.
- The shadow-sampler + pushConstSize source patches were authored against 1.10.3 offsets — for 2.5.3
  they must be **rebased onto 2.5.3 source and rebuilt** (don't assume the 1.10.3 byte signatures
  match). Confirm whether the stashed 2.5.3 DLL already carries them.
- Boot with `DXVK_LOG_LEVEL=info`; grep `left4dead2_d3d9.log` for `A16B16G16R16F` as a
  renderable+blendable format, and `console.log` for **`HDR Enabled`**.

**Fallback if 2.5.3 regresses** (reintroduces `0x010c`, breaks max settings, or trades against HDR):
stay on 1.10.3 and write a **targeted DXVK patch** to advertise `D3DFMT_A16B16G16R16F` as a blendable
RT in `CheckDeviceFormat` — solve the exact cap Source checks, without the whole-version jump.

### A2. Re-assert DX9.5 everywhere (and make it durable — fixes issue #8)
- `bin/dxsupport.cfg` block `"0"`: `maxdxlevel 98` / `dxlevel 95` (already applied).
- `left4dead2/dxsupport_override.cfg` block `"3"`: `vendorid 0x106b` → `dxlevel 95 / maxdxlevel 98`.
- `video.txt`: add `setting.dxlevel 95` — **✅ done via [C2](#c2-single-source-of-truth-for-settings)**
  (`assert_max_settings` asserts it every launch). (`maxdxlevel`/`mindxlevel` are `dxsupport.cfg` keys, not
  VideoConfig settings, so they don't belong in `video.txt`.)
- **Launcher re-asserts on every launch** so a Steam "verify integrity"/update can't silently revert HDR.
  **Partly done:** C2 re-asserts `video.txt` (incl. `dxlevel 95`); the two `dxsupport*.cfg` files still need
  the same treatment, joined to the existing bridge-DLL/binary-patch re-apply step.

### A3. Tonemapping without the M4 AGX auto-exposure crash
The one HDR feature that faults M4 AGX is **auto-exposure** (`mat_dynamic_tonemapping`), which drives a
per-frame GPU occlusion-query luminance histogram. Adopt the proven `listenserver.playable.bak` recipe:
**HDR fully ON, `mat_dynamic_tonemapping 0` (fixed exposure)** with a sane `mat_force_tonemap_scale`.
Interiors read dark from HDR lightmaps + fixed exposure; full adaptive exposure is the A5 stretch goal.

### A4. Verify at MAX settings
User confirms the *visual* (the diag harness reads the `HDR Enabled` log line + fault/fps, but
**cannot** judge tonemapping). Confirm `0x010c` does not return with HDR-on + 4× MSAA + multicore.

### A5. Stretch quality (not blockers)
- `#68` — reimplement D3D9 occlusion queries in DXVK → true auto-exposure at full speed.
- `#3` — force a Store (non-memoryless) store-action on the flashlight depth target so the flashlight
  casts shadows again (remove the `+r_flashlightdepthtexture 0` stopgap).

## Settings hardening (max-settings guarantee — part of Phase 1)

### C1. Neutralise the multicore landmine (MUST-FIX)
**✅ DONE (2026-06-02).** `play-l4d2.sh`'s `--wined3d` path used to rewrite `video.txt` `mat_queue_mode → 0`
**and** write a **persistent `autoexec.cfg`** containing `mat_queue_mode 0`, which the engine then exec'd on
**every** launch (including the DXVK path) — silently killing multicore. Implemented:
- The `--wined3d` path **no longer writes `autoexec.cfg`**; serialisation is scoped to that run only — the
  `+mat_queue_mode 0` launch arg plus a `video.txt` flip that `_wined3d_restore` (an `EXIT` trap) reverts to
  `-1` on exit.
- Every DXVK launch runs `assert_max_settings`, which **re-asserts `mat_queue_mode -1`** in `video.txt` and
  **removes any stale `mat_queue_mode 0` `autoexec.cfg`** — so even a hard-killed `--wined3d` run self-heals.

### C2. Single source of truth for settings
**✅ DONE (2026-06-02).** `assert_max_settings` idempotently asserts the VideoConfig half of the
max-settings block into `video.txt` on every launch — `gpu_level 3`, `mat_antialias 4` (4× MSAA),
`mat_forceaniso 16`, `mat_queue_mode -1`, **`dxlevel 95`** — and snapshots the original to
`video.txt.orig-pre-launcher`. The ConVar-only settings (picmip 0, expensive water, RTT shadows) ride in
`DEFAULT_GAME_ARGS`, which agrees with this block. The stale launcher comments (lines ~74–93) are rewritten:
the debunked `mat_hdr_level 1→2` theory and the "MSAA off / queue 0 was the verified-clean set" claim are
gone, replaced with the truth (`mat_hdr_level` is a no-op in this retail build; HDR is decided by hardware
caps).
> Note: asserting `dxlevel 95` in `video.txt` also lands the **`video.txt` portion of [A2](#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8)** early. A2's remaining scope is making the `dxsupport.cfg` / `dxsupport_override.cfg` edits equally durable across a Steam file-verify.

### C3. Verify max survives HDR-on + online mode
Re-confirm the `0x010c` crash stays away at max+HDR, and handle the `FCVAR_CHEAT` gating of auto-exposure
in online play (`#67`) if/when A5 lands.

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
- **HDR via DXVK 2.5.3 is the leading hypothesis but untested**; 2.5.3 needs MAB-off + gating and may
  reintroduce `0x010c` or trade against HDR. Phase 1's A1 targeted-patch fallback exists.
- **Online mode (firing 101) historically hangs** — Phase 2 is real engineering, the highest-risk part of
  this roadmap, not a setting.
- **VAC risk** on secured official servers under Wine — must be flagged before connecting.
- **Memory/docs conflict** ("HDR worked" in an earlier note vs. `HDR Disabled` in git/docs) — resolved in
  favour of git/docs; memory corrected 2026-06-02.
