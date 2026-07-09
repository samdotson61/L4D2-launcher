# Usage

The single entry point is **`~/L4D2-launcher/play-l4d2.sh`**.

```bash
./play-l4d2.sh            # first run: build + install everything, then launch
./play-l4d2.sh            # later runs: re-applies patches, starts helper, launches
```

## Commands / flags

| Flag | Does |
|---|---|
| *(none)* | Full pipeline → launch the game |
| `--setup` | Install prerequisites + prefix, don't launch |
| `--reset` | Delete and re-create the Wine prefix |
| `--kill` | Force-kill stuck `left4dead2` / `wine` / `steam_helper` (wineserver -k, then `pkill -9`) |
| `--bridge` | Build + install bridge + start helper (no launch) |
| `--build-bridge` | Compile `steam_api.dll` + `steam_helper` only |
| `--install-bridge` | Install bridge DLL + apply on-disk binary patches + copy `steam.dll`/`GameOverlayRenderer.dll` |
| `--steam-check` | Verify the macOS Steam client is running + signed in, and show the persona/SteamID the bridge will authenticate as (D3) |
| `--max-settings` | Re-apply the recommended **max graphics baseline** to `video.txt` (resolution, 4× MSAA, multicore, 16× aniso, `gpu_level 3`, `dxlevel 95`) **and the dxsupport DX9.5 edits** (`bin/dxsupport.cfg` block "0" + the Apple `0x106b` override — these two also self-heal on every normal launch, since no in-game menu writes them). Normal launches **respect your saved settings**; use this to reset `video.txt` to max (e.g. after a Steam "verify integrity" regenerates these files). |
| `--install-goldberg` / `--uninstall-goldberg` | Swap in/out the Goldberg shim (alternative to our bridge) |
| `--install-steam` / `--steam` | Install / launch Steam-for-Windows in the prefix |
| `--link-game` | Symlink an existing L4D2 install into the prefix's Steam library (avoid re-download) |
| `--winecfg` | Open `winecfg` against the prefix |
| `--shell` | Subshell with `wine64` in PATH + `WINEPREFIX` set |
| `--hud` | Metal/D3DMetal perf HUD (`MTL_HUD_ENABLED=1`) |
| `--debug` | Verbose Wine logging to stderr |
| `--diag` | **Light** diagnostics → `game-stderr.log` (per-encoder GPU-fault log + DXVK info; playable) |
| `--diag-gfx` | **Heavy** DXVK+MoltenVK+Metal validation (names OOB faults; big stutter; diagnostic only) |
| `--diag-online` | **Steam-bridge / online-mode trace** (Phase 3 / B1) → `helper.log` + `/tmp/bridge.log`: which Steam callbacks (esp. 101 `SteamServersConnected_t`) and RPC ops the engine makes, plus `BLoggedOn`/`GetConnectedUniverse` values; playable, logging only |
| `--wined3d` | Bypass DXVK; use Wine's native d3d9 → wined3d → MoltenVK (set `WINED3D_RENDERER=gl` for the GL backend). Serialises D3D9 (`mat_queue_mode 0`) for **that run only** — your pre-run `mat_queue_mode` is saved to a sidecar and restored on exit (and self-heals on the next launch if the run is hard-killed); no `autoexec.cfg` is persisted ([issue #9](03-known-issues.md), resolved in C1). |
| `--help` | Usage |
| `-- <args>` | Forward the rest to `left4dead2.exe`, e.g. `-- +map c1m1_hotel -windowed` |

## Launch pipeline (what a plain run does, in order)

`preflight` (macOS/arm64/Rosetta/game checks) → `ensure_gptk` (Whisky Wine 11) → `ensure_patched_moltenvk` (install + sign dylib) → `ensure_prefix` (wineboot) → `ensure_appid` (steam_appid.txt) → `mac_steam_preflight` + `gpu_preflight` (D3/D5 — Mac-Steam account + Apple-GPU checks) → `do_install_bridge` (DLL + patches + dxvk.conf) → `do_start_helper` (helper on :54550) → `do_launch` (env + wine + game).

## User-overridable environment variables

| Var | Effect |
|---|---|
| `L4D2_GAME_DIR` | Override the L4D2 install path |
| `L4D2_PREFIX` | Override the Wine prefix path |
| `L4D2_STEAM_DYLIB` | Override the `libsteam_api.dylib` path the native helper loads (default: `$L4D2_GAME_DIR/bin/libsteam_api.dylib`) — D1 |
| `L4D2_RES` | Force the in-game resolution as `WxH`, e.g. `1920x1080` (default: the main display's detected logical resolution) — D2 |
| `L4D2_LAUNCHER_DIR` | Override the launcher/repo directory (default: auto-detected from the script's own location) — D4 |
| `L4D2_MAC_STEAM_DIR` | Override the macOS Steam client dir for the D3 account check (default: `~/Library/Application Support/Steam`) — D3 |
| `L4D2_MVK_MAB` | Metal Argument Buffers: `0`/`1`/`2`(auto) — default 0 |
| `L4D2_MVK_RESUME` | `MVK_CONFIG_RESUME_LOST_DEVICE` 0/1 — default 0 (halt on real fault) |
| `L4D2_MVK_PREFILL` | Command-buffer encoding: `0` deferred (fast, default) … `2`/`3` immediate (raises crash threshold, slow) |
| `L4D2_MVK_MTLHEAP` | `MVK_CONFIG_USE_MTLHEAP` 0/1 — default 1 (heaps; `0` = per-resource, a diagnostic knob) |
| ~~`L4D2_FORCE_HDR`~~ | **REMOVED 2026-06-03.** Re-asserted `dxlevel 95` in video.txt on launch — based on the debunked "dxlevel/DXVK gates HDR" theory. HDR was never gated by dxlevel (engine already runs `mat_dxlevel 100`); it was pinned off by a launch arg, since fixed. See [03-known-issues #1](03-known-issues.md). |
| `L4D2_WINEDEBUG` | Override Wine debug flags |
| `WINED3D_RENDERER` | `vulkan` / `gl` for the `--wined3d` path |
| `MVK_L4D2_DEBUG` | `1` = verbose MoltenVK fault/allocation diagnostics (set by `--diag`) |
| `MVK_L4D2_FORCE_PRIVATE_RT` | `1` = back transient attachments in Private memory (tile-budget mitigation) |

## Default launch args

```
-novid -vulkan +r_flashlightdepthtexture 1 +mat_queue_mode -1 +mat_antialias 4
```
- `-vulkan` routes D3D9 through DXVK (without it the game exits in seconds).
- `+r_flashlightdepthtexture 1` — dynamic flashlight shadows **on** (was the old `0` stopgap; confirmed working — issue #3).
- `+mat_queue_mode -1` (multicore) and `+mat_antialias 4` (4× MSAA) are **inert defaults** — `video.txt` latches over them, so the player's saved values win and persist. They're kept only as a fallback if `video.txt` lacks those keys.
- **Removed 2026-06-04:** `+mat_picmip 0` / `+r_waterforceexpensive 1` / `+r_shadowrendertotexture 1`. They duplicated `gpu_level 3` / `gpu_mem_level 2` (L4D2's "very high" preset carries none of them) and, having no `video.txt` key, *overrode* the player's menu detail choices while being unable to persist (not `FCVAR_ARCHIVE`). Dropping them lets the persisted `video.txt` detail levels drive texture/water/shadow quality — see the boundary note below.
- **No `+mat_hdr_level` token.** Both `+mat_hdr_level 1` and `+mat_hdr_level 2` were **removed 2026-06-03**. They were *not* harmless no-ops: although the engine logs `Unknown command "mat_hdr_level"`, it **queues** the unknown convar and applies it the instant `mat_hdr_level` registers during material-system init — pinning HDR to level 1 (LDR+bloom) every launch, which forced the flat/fullbright look. With the token gone, the engine's true hardware-derived default (level 2, full HDR) stands. See [03-known-issues #1](03-known-issues.md).

## Game graphics settings

Live in `left4dead2/cfg/video.txt` (resolution, MSAA, aniso, multicore, gpu_level, dxlevel) and the dxsupport files. **Max settings is the DEFAULT, and the player is in control** *(policy revised 2026-06-04)*: the launcher seeds the recommended max baseline (**4× MSAA + multicore + max textures + DX9.5** + this Mac's detected resolution) on the **first run**, and any setting you then change in the in-game **Options → Video** menu **takes effect and persists across restarts** — so you can adapt to a different Mac/display. `assert_max_settings` enforces this with **seed-not-overwrite**: it writes the full baseline only on the first launcher run (no `video.txt.orig-pre-launcher` snapshot yet) or on explicit **`--max-settings`**, and otherwise only fills in a default for a key you haven't set — it **never** overwrites a value already present. (`video.txt` latches at material-system init and overrides launch args, so your saved values win over the `+mat_antialias` / `+mat_queue_mode` launch args — those persist.) `L4D2_RES` remains an explicit per-launch resolution override. See [Phase 1 / C2](08-roadmap.md#c2-single-source-of-truth-for-settings) and the binding constraint in [08-roadmap.md](08-roadmap.md).

> **All Options → Video settings persist** *(boundary closed 2026-06-04)*. Resolution, MSAA, anisotropic filtering, detail/effect/shader/texture levels (`gpu_level` / `gpu_mem_level` / `cpu_level` / `mem_level`), multicore, and vsync all live in `video.txt` and persist across restarts. The three ConVar-only quality pins that used to override texture/water/shadow quality (`mat_picmip` / `r_waterforceexpensive` / `r_shadowrendertotexture`) were **removed** from `DEFAULT_GAME_ARGS` — they duplicated the detail levels and couldn't persist anyway (not `FCVAR_ARCHIVE`), so those aspects now follow the persisted `gpu_level` / `gpu_mem_level`. The seeded baseline matches L4D2's own "very high" preset (the launcher seeds 4× MSAA rather than the preset's 8× — bump it in-menu and it persists).

The `--wined3d` path serialises D3D9 for its own run only and no longer leaks `mat_queue_mode 0` into the DXVK path ([issue #9](03-known-issues.md), resolved in C1).

## Signing in to Steam

`./sign-in.sh` provides a CLI fallback (the CEF GUI is broken on this Wine): prompts user/pass, runs Steam-for-Windows with `-login`, writes a persistent `loginusers.vdf`, then launches. The bridge's identity comes from the **real macOS Steam client**, which must be running and logged in.
