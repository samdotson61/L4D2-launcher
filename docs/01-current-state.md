# Current State & Playability

**As of 2026-06-05.** This describes exactly what works, what doesn't, and the precise configuration currently deployed.

---

## Playability summary

The game **launches, reaches the main menu, and loads into a campaign**, rendering the world, HUD, weapons, survivor bots, and items. On the test map (`c1m1_hotel`) it runs at **~90–130 fps** at **1512×982** (this Mac's logical resolution; now auto-detected per-Mac — D2) with **max settings** (4× MSAA, multicore, max textures, expensive water, RTT shadows, 16× aniso) and **does not** hit the `0x010c` GPU crash during a ~90 s run.

**HDR is now PLAYABLE end-to-end at max settings** (issue #2 fixed 2026-06-04) — this is the **first truly playable HDR build**. HDR *rendering* was solved 2026-06-03 (the long "flat / over-bright / no baked shadows" problem was **our own launcher**: `DEFAULT_GAME_ARGS` passed `+mat_hdr_level 1`, which the engine logs as `Unknown command` but *queues and applies* at material-system init — pinning HDR to level 1 (LDR+bloom) every launch; on L4D2's HDR-only maps, level 1 reads the empty LDR lighting lump → `Level unlit, setting 'mat_fullbright 1'` → fullbright. **Removing that one token** lets the engine's true default — level 2, full HDR — stand). See [03-known-issues.md #1](03-known-issues.md#1-hdr--solved-2026-06-03).

**The `0x010c` device-lost under HDR is now SOLVED** (issue #2, 2026-06-04). HDR-on used to re-trigger the fault ~30 s into active play and freeze the game. The real cause turned out to be an **attachment-less render pass**: on the first full-scene HDR frame, DXVK emits a 16384×16384 render pass with **zero attachments**, and creating a Metal render command encoder with no attachments hard-aborts the AGX GPU with `0x010c` (it surfaces as `VK_ERROR_DEVICE_LOST`, but is **not** an OOM — ~1.8 GB of 18 GB). The patched MoltenVK now **skips creating the encoder for an attachment-less pass**, and HDR is playable: the user **completed campaign level 1 and entered level 2 with no freeze and no crash** at 4× MSAA + multicore + native res (`mat_hdr_level 2`, `mat_fullbright 0`, `mat_dxlevel 100`); automated runs log **0 `0x010c` faults** over repeated 150 s sessions. An occasional stutter remains (a minor perf nit, issue #5), not a blocker. Every historical "playable" build was secretly **HDR-off** (even commit 38dc236's "full HDR" title carried the same `+mat_hdr_level 1` pin), so this is the first build that is HDR-on **and** playable. See [03-known-issues.md #2](03-known-issues.md#2-0x010c-device-lost-under-hdr--solved-2026-06-04-was-the-top-blocker-for-hdr-playability--41-62-64).

---

## What works

- **Boot + Steam bridge** — the custom `steam_api.dll` + native `steam_helper` satisfy every Steamworks interface L4D2 requests; real Steam identity (SteamID/persona) is proxied from the macOS Steam client. ~150+ RPCs per run.
- **Main menu** — renders and is interactive.
- **Campaign load** — the world geometry, textures, **HDR lighting**, HUD, weapons, and survivor bots all render. Reaches active gameplay (`+map c1m1_hotel` confirmed; bots spawn).
- **Performance** — ~90–130 fps on the test map at full resolution and max settings; well above playable.
- **Max graphics settings** — 4× MSAA + multicore material system + max textures all stable; turning these up does **not** cause the historical crash.
- **GPU stability at max settings, HDR on** — 0 `0x010c` faults across repeated 150 s test runs with HDR enabled (the device-lost fault is fixed, issue #2); a campaign playthrough of levels 1→2 ran with no freeze/crash.

## What's broken or limited

| Area | State | Detail |
|---|---|---|
| **HDR / tonemapping** | Working (HDR playable) | **Rendering fixed** 2026-06-03 by deleting the launcher's `+mat_hdr_level 1` token (it queued-then-applied despite "Unknown command", pinning HDR off): `mat_hdr_level` now reads 2, `Level unlit` gone, maps light correctly at max settings; engine is at `mat_dxlevel 100` (full DX9.5) — the "DX8-effective" claim was **false**; DXVK/MSAA/multicore were all red herrings. **Playability fixed 2026-06-04**: the `0x010c` device-lost (issue #2) is solved — it was an **attachment-less render pass** (a 16384×16384 pass with zero attachments hard-aborts the AGX GPU), now skipped in patched MoltenVK. User played levels 1→2 with no freeze/crash at max settings; 0 `0x010c` faults in automated 150 s runs. Only residual: an occasional stutter (issue #5). See [#1](03-known-issues.md#1-hdr--solved-2026-06-03) and [#2](03-known-issues.md#2-0x010c-device-lost-under-hdr--solved-2026-06-04-was-the-top-blocker-for-hdr-playability--41-62-64). |
| **Flashlight shadow** | On | `+r_flashlightdepthtexture 1` — dynamic flashlight shadows render (confirmed working). The old `0` stopgap is gone. |
| **0x010c heavy-frame crash** | Fixed (2026-06-04) | The HDR `0x010c` device-lost is **solved** — root-caused to an attachment-less render pass (16384×16384, zero attachments) that hard-aborts the AGX GPU; patched MoltenVK skips creating an encoder for it. 0 faults over repeated 150 s HDR runs; user played levels 1→2 with no freeze. See [#2](03-known-issues.md#2-0x010c-device-lost-under-hdr--solved-2026-06-04-was-the-top-blocker-for-hdr-playability--41-62-64). |
| **Online / multiplayer** | **Self-HOST works** (lobby create + now lands on the correct-gamemode server, B5.1); **JOINING does NOT** — dedicated-browser join (B5) **and** in-game lobby-browser join (B6) **fail on non-VAC** servers (re-test 2026-06-05; *not* the B7/VAC gate); official = VAC (B7) | Online plumbing works: the engine reaches online mode (`BLoggedOn=1`, `GetConnectedUniverse=1`) and **`CreateLobby` → `result=1`** (the transient rate-limit cleared). The dedicated-server browser now **populates**: the helper **queues + forwards** the `ServerResponded` events it used to drop (`0xFFFFFFFD` drain envelope) and the bridge **re-dispatches** into the game's `ISteamMatchmakingServerListResponse` via `thiscall_run2`, plus a `gameserveritem_t` pack(4)→pack(8) fix in `GetServerDetails` (a live run re-dispatched 1600+ rows and the engine called `GetServerDetails`). **B5.1 CONFIRMED (2026-06-05):** match filters (`gamedir`/`gametype`/…) are now forwarded, so **self-hosting picks a server matching the selected gamemode** (the earlier mode-mismatch is gone). **But the JOIN step is the top open blocker (re-test 2026-06-05):** selecting a browsed **non-VAC** dedicated server fails to connect, and the in-game **lobby-browser join also fails** — so the earlier same-day "non-VAC join started a game" note is **superseded** (treat B5 join as OPEN). **Root cause diagnosed (`--diag-online`, 2026-06-05): the P2P game-handshake is inbound-dead** — `JoinLobby` → `LobbyEnter_t bFailed=0` (lobby join works), then the engine's `ISteamNetworking` P2P connection goes one way only (**470 SendP2PPacket out, 0 ReadP2PPacket in**, no `1202`/`1203`); the host never replies. The receive proxy + `gameserveritem_t` repack are both correct, so this is the common blocker for both join types. **Re-test #1 (2026-06-05):** relay did **not** fix it, but the instrumentation localized the fault precisely — the **send path is correct** (742 sends accepted to the **real** lobby host, matching `GetLobbyOwner`), yet inbound is still 0 and Steam now returns **`P2PSessionConnectFail_t` (1203)**. **ROOT CAUSE FOUND (2026-06-05, re-test #3): the SDR relay backend was never bootstrapped.** A LAN test in **both directions** failed with **"Session is no longer available"** + **`P2PSessionConnectFail err=4` (Timeout)** + zero inbound — and a LAN timeout to a reachable peer rules out NAT/legacy-relay, leaving the structural cause: modern Steam runs even legacy `ISteamNetworking` P2P on the **SteamNetworkingSockets/SDR** backend, which must be started with **`SteamNetworkingUtils()->InitRelayNetworkAccess()`** — the helper never called it (only the unrelated old `AllowP2PPacketRelay`). **Fix applied + VALIDATED (re-test #4):** the helper now calls `InitRelayNetworkAccess()` at init; `RelayNetworkStatus` reached **100 (Current/ready)** — the SDR backend initializes correctly. **But relay was necessary-not-sufficient (re-test #5):** with relay confirmed ready, the LAN join **still** fails — `P2PSessionConnectFail err=4 (Timeout)`, **0 inbound** — so the structural inbound-receive gap is real and not explained by the SDR backend. (A host-side member-join crash also appears intermittently.) **Research + fix (2026-06-05):** a Proton `lsteamclient` / Goldberg / Steamworks-docs deep-dive found the root cause — legacy P2P **drops all inbound until the receiver calls `AcceptP2PSessionWithUser`** in response to `P2PSessionRequest_t` (1202), which never reaches this bridge. **Fix applied + built:** the helper now **proactively `AcceptP2PSessionWithUser(peer)`** (deduped) for every peer it learns of (SendP2PPacket targets, lobby owner, lobby members) — Goldberg's auto-accept workaround. **Re-test #6 (LAN join) pending.** **Official/VAC = B7 gate** (separate, expected). See [Phase 3](08-roadmap.md#phase-3--online-multiplayer-join-official-steam-games) · [07-debugging.md](07-debugging.md#p2p-join-handshake-phase-3--b6-diagnostics). |
| **Real menu→campaign path** | Mostly | Verified via `+map`. The clicked menu→campaign path has historically been the area where callback-driven stalls appeared (see #63). |
| **Shadow quality** | Tradeoff | DXVK shadow-sampler patch aliases depth-compare to color sampling (software compare), a quality regression accepted to make shaders compile on MoltenVK. |

---

## Exact deployed configuration

### Versions
- **OS / HW:** macOS 26.x, Apple M4 Pro, Rosetta 2 (x86 emulation for the 32-bit game)
- **Wine:** Whisky-Wine 11 (`~/L4D2-launcher/whisky-wine/`), prefix at `~/L4D2-launcher/whisky-prefix/`
- **DXVK:** **1.10.3** (+ `shadow-sampler-workaround.patch`) — deployed `bin/dxvk_d3d9.dll` matches `dxvk-build/dxvk_d3d9.dll` (sha1 `f9a30c6…`). A **2.5.3** build exists but is **stashed** (`dxvk-build/dxvk_d3d9.dll.253-stash`), not deployed. *(Explored 2026-06-02: a hand-patched 2.5.3 rendered but looked identical to 1.10.3 — correctly establishing **DXVK is not the HDR lever**. The actual HDR cause was the launcher's `+mat_hdr_level 1` arg, found 2026-06-03; DXVK already reports `A16B16G16R16F` blendable=OK at init. See [#1](03-known-issues.md#1-hdr--solved-2026-06-03).)*
- **MoltenVK:** **1.4.1** (+ the comprehensive session patch `moltenvk-build/session-patches/moltenvk-all-edits-latest.patch`, regenerated 2026-06-04). The deployed dylib now carries the **attachment-less-skip `0x010c` HDR fix** (issue #2 — skip creating a Metal render encoder for a render pass with no attachments; default on, `L4D2_MVK_SKIP_NOATT=0` disables) **plus the diagnostic instrumentation** (`[mvk-tiledbg]` attachment-footprint logging, `MVK_L4D2_SYNC` per-buffer sync, the `L4D2_MVK_MAX_PASSES` command-buffer splitter — all off by default) — superseding the older `null-descriptor-fallback.patch`, whose null-descriptor fix it still includes.
- **Steamworks SDK:** 1.53a (+ ISteamTimeline from 1.60)

### Launch args (`play-l4d2.sh` → `DEFAULT_GAME_ARGS`)
```
-novid -vulkan +r_flashlightdepthtexture 1 +mat_queue_mode -1 +mat_antialias 4
```
**The `+mat_hdr_level 1` / `+mat_hdr_level 2` tokens were REMOVED 2026-06-03 — they were the HDR bug.** Despite logging `Unknown command`, the engine *queues* `+mat_hdr_level 1` and applies it once the convar registers at material-system init, pinning HDR to level 1 (LDR+bloom) → fullbright on HDR-only maps. Their **absence** is what enables HDR (engine default = level 2). `+r_flashlightdepthtexture 1` (was `0`) restores dynamic flashlight shadows. **The `+mat_picmip 0` / `+r_waterforceexpensive 1` / `+r_shadowrendertotexture 1` quality pins were REMOVED 2026-06-04** — they duplicated `gpu_level 3` / `gpu_mem_level 2` (now seeded in `video.txt`) and, lacking a `video.txt` key, overrode the player's menu detail choices while being unable to persist (not `FCVAR_ARCHIVE`); texture/water/shadow quality now follows the persisted detail levels. `+mat_queue_mode -1` / `+mat_antialias 4` remain only as inert fallbacks (`video.txt` latches over them).

### `video.txt` (`left4dead2/cfg/video.txt`) — **live contents (2026-06-02)**
```
gpu_level 3, cpu_level 2, gpu_mem_level 2, mem_level 2
mat_antialias 4 (4× MSAA), mat_aaquality 0, mat_forceaniso 16
mat_queue_mode -1 (multicore)
mat_vsync 1, mat_triplebuffered 1, mat_monitorgamma 2.2
defaultres 1512 × 982, windowed (fullscreen 0), no border (nowindowborder 1)
```
> **These are the SEEDED max-settings DEFAULTS, and players may change them** *(policy revised 2026-06-04)*.
> The launcher writes this baseline only on the **first run** (or on `--max-settings`); after that any in-game
> Options → Video change **persists** and the live file may differ from the listing above. `assert_max_settings`
> uses **seed-not-overwrite** — see [C2](08-roadmap.md#c2-single-source-of-truth-for-settings). (This replaced
> the old "re-assert the whole block every launch" behaviour — which was exactly why **saved resolution didn't
> persist**.)
>
> **`setting.dxlevel 95`** is part of the seeded baseline (not in the static listing above because the launcher
> adds it on first run / `--max-settings`, snapshotting the original to `video.txt.orig-pre-launcher` first).
> dxlevel-forcing alone does **not** enable HDR; making the `dxsupport.cfg` edits re-appliable is the rest of
> [A2](08-roadmap.md#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8).
>
> **`defaultres`/`defaultresheight` are auto-detected per-Mac (D2, DONE 2026-06-04)** — no longer pinned to this
> 14" MacBook's 1512×982. `detect_resolution()` (`L4D2_RES` override → AppKit `NSScreen` → `system_profiler`)
> feeds the **seed**; 1512×982 is just this panel's logical value (3024×1964 backing). Windowed-borderless is the
> default but is player-changeable too (the live file may read `fullscreen 1` if the player set it). See
> [plan D2](08-roadmap.md#d2-dynamic-resolution).
>
> **Multicore landmine fixed** ([C1](08-roadmap.md#c1-neutralise-the-multicore-landmine-must-fix) / issue #9):
> `mat_queue_mode -1` is the seeded default; a player may change it and it persists. The `--wined3d` path no
> longer persists `mat_queue_mode 0` — it scopes serialisation to that one run (saving the pre-run value to a
> sidecar that `_wined3d_restore` restores on exit, and that self-heals on the next launch if hard-killed) and
> writes no `autoexec.cfg`.

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

- **Branch:** `main`. The HDR work (rendering fix 2026-06-03 + the `0x010c`/attachment-less-skip playability
  fix 2026-06-04) and the **D1–D6 portability work** (2026-06-04) are committed on `main` — run
  `git log --oneline` for exact hashes and `git status` for any in-progress tree. *(This doc deliberately no
  longer pins a HEAD hash or clean/dirty state — that went stale on every commit, and git already tracks
  both.)* Milestone lineage, oldest→newest: `38dc236` ("launcher: full HDR … loads into campaigns") →
  `8cdc8ca` ("working dx8 …") → `5e29d8d` ("A0") → `458f9ff` ("flashlight shadows") → `a540195` ("HDR
  rendering fix + `0x010c` diagnosis") → `9a5dedf` ("working and playable my boy") → the D-level portability
  commits. The patched `libMoltenVK.dylib`'s attachment-less-skip fix rides in the tracked session patch (the
  built dylib stays out of git — see below).
- **`DEFAULT_GAME_ARGS`** carries **4× MSAA + multicore** (`mat_queue_mode -1`) + max textures.
- **Stash:** `stash@{0}` (WIP on `38dc236`) still holds in-progress launcher edits (clean-quit extended
  to the normal launch path, an `L4D2_FORCE_HDR` video.txt toggle, `L4D2_MVK_MTLHEAP` override,
  updated PREFILL comments) — not yet applied.
- **Not in git:** the patched `libMoltenVK.dylib` and `dxvk_d3d9.dll` binaries (rebuildable from
  source via `build-deps.sh` + the tracked `.patch` files); the game-folder config edits.

> **Baseline note:** HDR **renders and is playable** end-to-end at max settings and the engine runs **DX9.5**
> (`mat_dxlevel 100`) — the old `8cdc8ca` "working dx8 no tonemapping" label is long superseded. What remains
> is **online multiplayer** (Phase 3) and **cross-Mac validation** of the now-code-complete portability work
> (Phase 2 — D4 clean-Mac build, D5 non-M4 test) — see [08-roadmap.md](08-roadmap.md).

> The `dxsupport.cfg` / `dxsupport_override.cfg` / `video.txt` edits live in the **Steam game folder**, not this repo. A Steam "verify integrity of game files" or game update will regenerate `bin/dxsupport.cfg` (and `video.txt`). Note HDR no longer depends on these edits — the engine runs `mat_dxlevel 100` regardless and HDR is gated by a launch arg (since removed) — so a revert won't re-break HDR. Since the launcher now **seeds** `video.txt` rather than re-asserting it every launch (so player settings persist — [C2](08-roadmap.md#c2-single-source-of-truth-for-settings)), recover the max baseline after a Steam file-verify by running **`./play-l4d2.sh --max-settings`**; making the **`dxsupport*.cfg`** edits re-appliable the same way is the rest of [A2](08-roadmap.md#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8).
