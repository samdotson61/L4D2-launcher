# Components

Detailed reference for each part of the stack. Paths are under `~/L4D2-launcher/`.

---

## Steam bridge — `bridge/`

A dual-process Steam-API proxy. The Windows game talks to our shim; the shim talks to a native helper; the helper talks to the real macOS Steam client.

### `steam_helper.c` → `steam_helper` (native arm64)
Loads the real `libsteam_api.dylib` and serves a binary RPC protocol on **TCP 127.0.0.1:54550**.
Real Steam identity/auth (SteamID, persona, auth tickets) is read **live from the running macOS
Steam client** — nothing about the account is hardcoded, which is what makes "plug in the real
Steam values from this Mac's Steam app" work on any machine.

> **Portability (D1 — DONE 2026-06-04):** the dylib path is **no longer hardcoded**. `resolve_dylib_path()`
> resolves it at startup from `$L4D2_STEAM_DYLIB` → `$L4D2_GAME_DIR/bin/libsteam_api.dylib` → the `$HOME`
> default Steam library, and `play-l4d2.sh` passes the resolved path to the helper at launch. See
> [issue #10](03-known-issues.md#10-portability-blockers-per-machine-hardcoding--69-70--porting-goal)
> / [plan D1](08-roadmap.md#d1-de-hardcode-the-steam-dylib-path-must-fix).

> **Preflight (D3 — DONE 2026-06-04):** `play-l4d2.sh` (on every launch, and standalone via `--steam-check`)
> verifies the Mac Steam client is running, that this dylib exists, and surfaces the **PersonaName + SteamID**
> of the signed-in account (parsed from the Mac client's `loginusers.vdf`) so the user confirms the bridge
> will authenticate as the right account — the same live identity Phase-3 online mode relies on.
Wire format: `[u32 op][u32 arg_len][args] → [u32 status][u32 ret_len][return]`.

Opcode groups (60+ total):
- **Core** `0x001x` — PING, INIT, IS_STEAM_RUNNING, GET_HSTEAMUSER/PIPE, SHUTDOWN
- **ISteamUser** `0x010x` — GETSTEAMID, BLOGGEDON, GETAUTHSESSIONTICKET, BEGIN/END/CANCEL auth session, GS (game-server) auth variants
- **ISteamApps** `0x020x` — BISSUBSCRIBED, BISSUBSCRIBEDAPP, GETCURRENTGAMELANG, GETAPPBUILDID
- **ISteamUtils** `0x030x` — GETAPPID, GETSTEAMUILANG, ISAPICALLCOMPLETED, GETAPICALLRESULT (these two break the DRM blocking-call loop), CHECKFILESIGNATURE, ISOVERLAYENABLED
- **ISteamFriends** `0x040x` — GETPERSONANAME, GETFRIENDPERSONANAME/STATE, REQUESTUSERINFO
- **ISteamMatchmaking** `0x05xx` — lobby list/create/join/leave, members, lobby data, owner, game-server, filters
- **ISteamNetworking** `0x060x` — P2P send/read/availability, accept/close session, session state
- **ISteamMatchmakingServers** `0x070x` — internet/LAN/friends/favorites/history/spectator server lists, details, refresh
- **Callbacks** `0xD000` — `OP_DRAIN_CALLBACKS`: pull pending callbacks from the real Steam queue for delivery into the game

### `steam_api_wine.c` → `steam_api.dll` (32-bit PE, no CRT)
Exports 31 functions (see `steam_api.def`): `SteamAPI_Init/Shutdown/RunCallbacks/RegisterCallback/RegisterCallResult`, `SteamInternal_ContextInit/CreateInterface/FindOrCreateUserInterface`, the `SteamGameServer_*` set, etc.

- **Interface vtables** — 22 interfaces built to match SDK 1.53a. Each method either points to a real RPC-backed impl (`REAL_IMPLS`) or a `stub_N` that returns a dummy and cleans `N*4` bytes of stack (correct `__thiscall` ABI). The `CSteamID`-by-value return ABI (hidden return pointer, `ret 4`) is handled explicitly.
- **Callback dispatch** — `RunCallbacks` drains via RPC and dispatches each event to registered handlers with adaptive `ret N` stack-cleanup detection. A blacklist filters known-bad early-init callbacks (101 SteamServersConnected, 304 PersonaStateChange, 1101 UserStatsReceived) that otherwise flip the engine into a bad state.

### Runtime binary patches (applied by `steam_api.dll` at `SteamAPI_Init`)
The shim patches the game's own DLLs in memory (VirtualProtect + write), and a **background watcher thread** re-applies the engine RunCallbacks patch if DRM zeroes it.

| DLL | What | Why |
|---|---|---|
| `vgui2.dll` | Fill 11 encoded CRT function-pointer slots (real Wine `Fls*` for 4, no-op for the rest) | Wine doesn't run the init path that populates them → `call *eax` on NULL |
| `engine.dll` | Fill 9 CRT slots; **hot-patch RunCallbacks call sites** (IAT→direct call); **BitBuffer LUT** init; a CRT-deref function forced to return false; **memmove sanity-check** (abort if count > ~268 MB) | Bypass IAT-zeroing DRM; avoid uninitialized-static crashes during level load |
| `client.dll` | Fill 9 CRT slots; NOP a HUD-init vtable[47] call | Uninitialized object → crash |
| `matchmaking.dll` | Fill 8 CRT slots; NOP the callback-iterator (`xor eax,eax; ret 4`) | Iterates a callback vtable that's been freed/corrupted → execute-AV |

> Exact offsets drift between game builds — see `steam_api_wine.c` for the authoritative list and signatures. `play-l4d2.sh --install-bridge` re-applies the on-disk DLL patches; the in-memory CRT/IAT patches happen at runtime.
>
> **On-disk patches are now signature-anchored (2026-07-22).** The four `do_install_bridge` byte patches (`client.dll` HUD-vtable NOP, `engine.dll` CRT-deref-false + memmove-sanity, `matchmaking.dll` callback-iterator no-op) no longer use hardcoded file offsets. `_sigpatch` **scans** each DLL for a long unique byte signature and writes only on an exact single match, so a Valve recompile that shifts offsets self-relocates instead of breaking, and a too-generic match fails safe (WARN + skip, never mis-apply). `_snapshot_clean` refreshes each `*.original` backup only from confirmed-clean stock (pristine signature present), fixing the stale-backup-after-update hazard. See [03-known-issues #11](03-known-issues.md#11-valve-game-update-broke-the-build-specific-byte-patches--handled-2026-07-22).

### Codegen
- `gen_vtables.py` parses `bridge/sdk/` (Steamworks **1.53a**, + ISteamTimeline from 1.60) and emits `vtables_generated.c` (110 KB) with correct per-method arg-byte counts. Never hand-edit the generated file. `sdk_old/` is archived reference only.

---

## DXVK — `dxvk-build/`

D3D9 → Vulkan. Built from **DXVK v1.10.3** + `shadow-sampler-workaround.patch`.

| File | What |
|---|---|
| `dxvk_d3d9.dll` | **Active** build (v1.10.3+), deployed to the game's `bin/` (sha matches) |
| `dxvk_d3d9.dll.1103-backup` | Identical 1.10.3 recovery copy |
| `dxvk_d3d9.dll.253-stash` | **DXVK 2.5.3** build, **not deployed** — kept for the (now-closed) 32-bit-allocator / HDR investigation; see note below |
| `dxvk_d3d9.dll.hdrlog-orig` | 1.10.3 checkpoint before HDR-logging instrumentation |
| `shadow-sampler-workaround.patch` | The DXVK patch (below) |

**`shadow-sampler-workaround.patch`** fixes, in one patch:
1. MinGW-w64 14+ build compatibility (duplicate UUIDs, missing `<cstdint>`).
2. Gate `geometryShader` request (MoltenVK doesn't expose it → device-create fail).
3. Gate `shaderCullDistance` request (same).
4. Enable `robustImageAccess2` (Metal clamps OOB image reads on Apple GPUs → kills a per-frame `0x010c`).
5. **pushConstSize bug fix** — stock DXVK assigned the push-constant *size* from the *offset* (copy-paste bug) → too-small range → shader reads past it → Metal device fault every frame.
6. **Shadow-sampler aliasing** — alias depth-compare sampler to the color sampler (software compare) so the VertexLitGeneric shadow shaders compile on MoltenVK.

> A 2.5.3 build exists because DXVK 2.5.3's modern memory allocator addressed 32-bit address-space exhaustion at load (`#57`/`#60`); it needed MAB-off + feature gating to create a device on MoltenVK (`#61`). It is currently **stashed**, not deployed.
>
> **SUPERSEDED 2026-06-03:** this build was once "the prime candidate to test for the HDR issue." DXVK was *never* the HDR lever — the real cause was the launcher's own `+mat_hdr_level 1` launch arg, which pinned HDR to LDR every boot (see [03-known-issues #1](03-known-issues.md)). A patched 2.5.3 was confirmed to render identically to 1.10.3, and DXVK already returns `A16B16G16R16F` as a renderable+blendable HDR RT at init (verified with an instrumented `CheckDeviceFormat` probe, `result=0`/D3D_OK). The 2.5.3 build remains stashed only for the 32-bit-allocator angle, not for HDR.

---

## MoltenVK — `moltenvk-build/`

Vulkan → Metal. Built from **MoltenVK v1.4.1** + the comprehensive session patch `session-patches/moltenvk-all-edits-latest.patch` (regenerated 2026-06-04; supersedes the older `null-descriptor-fallback.patch`, whose fixes it still includes).

| File | What |
|---|---|
| `libMoltenVK.dylib` | **Active/deployed** — built from the 2026-06-04 session patch (carries the attachment-less-skip `0x010c` HDR fix) |
| `libMoltenVK.dylib.pre-tracked-bak` | Identical recovery copy |
| `libMoltenVK.dylib.v141patched.bak` | Identical (1.4.1 + patch checkpoint) |
| `libMoltenVK.dylib.transplant` | **Different** build — an experiment that transplanted 1.4.0's occlusion subsystem into 1.4.1; **refuted** (still faulted), not deployed |
| `session-patches/moltenvk-all-edits-latest.patch` | The MoltenVK patch (below) |

**`moltenvk-all-edits-latest.patch`** does:
1. **Attachment-less render-pass skip — the HDR playability fix (`0x010c`, issue #2, SOLVED 2026-06-04).** In `MVKCommandEncoder::beginMetalRenderPass`, when the render-pass descriptor has **no color/depth/stencil attachment**, skip creating the Metal `MTLRenderCommandEncoder` and return early. On the first full-scene HDR frame DXVK emits a 16384×16384 render pass with **zero attachments**; creating a render encoder with no attachments **hard-aborts the AGX GPU with Internal Error `0x010c`** (it is not a true OOM). `_mtlRenderEncoder` is already nil, so draws into that pass become safe no-ops and the next real pass re-establishes encoder state. **Default on**; `L4D2_MVK_SKIP_NOATT=0` disables it. This is what makes HDR playable end-to-end at max settings.
2. **Null-descriptor fallback** — bind zero-filled dummy buffer/texture/sampler for unbound (nil) descriptors instead of letting Metal deref address 0 (which faults `0x010c`). Matches `VK_EXT_robustness2` "reads return zero" semantics.
3. **isAppleGPU fix** — the M4 Pro doesn't report `MTLGPUFamilyApple1` in some Metal versions; check any Apple family (Apple1–Apple10) so Apple-GPU code paths (incl. robustImageAccess2) actually engage.
4. **robustness2 advertisement tuning** — `robustBufferAccess2=false` (Metal does NOT clamp OOB buffer access), `robustImageAccess2=isAppleGPU` (Metal DOES clamp images), `nullDescriptor=true`.
5. **MVKPipelineLayout always reserves a push-constant buffer slot per stage** — fixes the `cbuffer_t` + push-const both-at-MSL-buffer-0 collision (`#36`, "the rendering bug").
6. **Transient attachment storage** — optional `MVK_L4D2_FORCE_PRIVATE_RT` to back transient/memoryless attachments in Private (device) memory instead of tile memory (`#56`). *(Ruled out as the `0x010c` fix — made it worse — kept only as a lever.)*
7. **Instrumentation that pinpointed the `0x010c` fault** (all off by default): `[mvk-tiledbg]` logs every render pass's attachment footprint (format, samples, bytes/pixel) — this **refuted** the tile-memory-budget theory (heaviest pass is only 36 B/px, main scene is BGRA8_sRGB not FP16); `MVK_L4D2_SYNC` commits + `waitUntilCompleted` per command buffer to name the faulting buffer in lockstep; and a **command-buffer splitter** (`L4D2_MVK_MAX_PASSES`) which at N=1 + sync isolated the lone attachment-less pass as the culprit.
8. **GPU-fault diagnostics** — running allocation tally + per-encoder/userInfo fault dump under `MVK_L4D2_DEBUG=1` (this is what `--diag` reads to distinguish a true OOM from a `0x010c` internal error).

> Deploy note: `ensure_patched_moltenvk` checks for a marker string in the installed dylib and may **skip** redeploying a rebuilt dylib. If you rebuild, manually `cp` it into the Whisky lib dir and `codesign --force --sign - -i org.l4d2launcher.moltenvk.$(date +%s)` it (Rosetta AOT cache keys on the signature).

---

## Configs written into the game folder

- `dxvk.conf` (game root **and** `bin/`) — DXVK searches the CWD, so the root copy is the effective one. Minimal by design; the real Apple-Silicon fixes are compiled into the DLL.
- `steam_appid.txt` = `550` (L4D2) for the DRM check.
- `cfg/video.txt` — resolution + graphics settings (see [01-current-state.md](01-current-state.md#videotxt-left4dead2cfgvideotxt)). `assert_max_settings` **seeds** the max baseline here — `gpu_level 3`, `mat_antialias 4` (4× MSAA), `mat_forceaniso 16`, `mat_queue_mode -1` (multicore), `dxlevel 95`, detected resolution — **only on the first launcher run or `--max-settings`**, and otherwise only fills in missing keys; it **never overwrites a value the player has set**, so in-game changes persist *(policy revised 2026-06-04 — see [C2](08-roadmap.md#c2-single-source-of-truth-for-settings))*. It backs the original up once to `video.txt.orig-pre-launcher` and removes any launcher-written `cfg/autoexec.cfg` a `--wined3d` run left behind (the multicore landmine).
- `bin/dxsupport.cfg` + `left4dead2/dxsupport_override.cfg` — GPU→dxlevel database, edited to force DX9.5 for the M4 Pro. `dxlevel 95` is also seeded into `video.txt` by the launcher (see above); since 2026-07-09, **`assert_dxsupport` re-applies these two files' edits idempotently on every launch and on `--max-settings`** (snapshots: `dxsupport.cfg.orig-pre-dx95`, `dxsupport_override.cfg.orig-pre-launcher`), making them durable across a Steam file-verify — [Phase 1 / A2, DONE](08-roadmap.md#a2-re-assert-dx95-everywhere-and-make-it-durable--fixes-issue-8). The engine in fact reads `mat_dxlevel 100` (full DX9.5) at runtime. (Historical note: these edits were originally part of an "HDR investigation"; HDR was *not* gated by dxlevel — it was pinned off by the launcher's own `+mat_hdr_level 1` arg, since fixed — see [03-known-issues #1](03-known-issues.md).)
