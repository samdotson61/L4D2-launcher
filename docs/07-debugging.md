# Debugging & Diagnostics

## The diagnostic harness — `diag-monitor.sh`

The reliable way to test a change. It launches the game via `play-l4d2.sh --diag` directly into a map, watches the logs, and prints a verdict.

```bash
./diag-monitor.sh "label for this run"               # default map c1m1_hotel
./diag-monitor.sh "label" "+extra +launch +args"     # $2 is appended to the launch
```

It reports:
- `ingame_at` — seconds until gameplay was confirmed (greps `console.log` for `Reserved Wanderers|NextBot tickrate|Initiating Reserved`).
- `fault_at` + `faults(0000010c)` — first fault time and total `0x010c` count (greps `game-stderr.log`).
- `HDR:` — `HDR Enabled` / `HDR Disabled` / `<none>` (greps `console.log`). **Note:** this line is unreliable as the HDR verdict — the real HDR state is read via a VScript probe (see "Reading GPU/engine state" below). The trustworthy console signal is the **absence** of `Level unlit, setting 'mat_fullbright 1'`.
- FPS — from MoltenVK perf logging.
- `VERDICT` — `FAULTS xN` or `NO FAULTS, reached in-game, survived Ns`.

Stops at: first fault + 8 s, or process death, or 90 s.

### Two hard-won caveats
1. **A frozen game is not a dead process.** A `0x010c` device-loss *freezes* the game; it does not exit. So "process still alive" ≠ "survived". Trust the `0000010c` fault count and the in-game confirmation, not process liveness.
2. **The harness cannot see tonemapping.** It greps for the literal `HDR Enabled/Disabled` log line and counts faults/fps. It cannot judge whether HDR *looks* right. **The user is the visual authority** — never claim HDR/tonemapping works from logs alone.

To force HDR/perf instrumentation manually, prepend env:
```bash
MVK_CONFIG_PERFORMANCE_TRACKING=1 MVK_CONFIG_PERFORMANCE_LOGGING_FRAME_COUNT=120 \
  ./diag-monitor.sh "perf run"
```

## Log files (in `~/L4D2-launcher/`)

| File | Contents |
|---|---|
| `game-stderr.log` | MoltenVK per-encoder GPU-fault dump, DXVK info, MVK perf — **the `0x010c` signal** (written by `--diag`) |
| `gpu-faults.log` | Kernel AGX/IOGPU fault lines — the *real* OS-level reason for a `0x010c` |
| `left4dead2_d3d9.log` | DXVK D3D9 log: adapter ("Apple M4 Pro"), enabled extensions, **device feature list**, swapchain (written when `--diag` enables `DXVK_LOG_LEVEL=info`) |
| `<game>/left4dead2/console.log` | Source engine console (written by `-condebug`): `HDR Enabled/Disabled`, `Unknown command …`, cvar query results, lightmap reloads |
| `helper.log` | `steam_helper` RPC activity |

> The normal (non-`--diag`) launch path does **not** write `game-stderr.log`. Always use `--diag` when you need the fault log — otherwise the fault count reads 0 from a stale/empty file.

## Reading GPU/engine state

Because `mat_dxlevel` / `mat_hdr_level` / `developer` are **`Unknown command`** in this retail build (and `mat_hdr_level` is additionally **runtime-locked** — see below), you can't query the dxlevel/HDR from the console. What *does* work:
- **HDR level (the authoritative read):** a **VScript probe**. Drop a `mapspawn.nut` (or equivalent map script) that prints `Convars.GetFloat("mat_hdr_level")`. **`2` = full HDR (correct); `1` = LDR+bloom (the old pinned-off state).** This is how the 2026-06-03 fix was verified: with the bad `+mat_hdr_level 1` launch arg removed, the probe reads **2** (it read **1** while the arg was present).
- **HDR sanity in the console:** `mat_hdr_level` is **not** logged by `HDR Enabled/Disabled` reliably — instead check that `console.log` does **not** contain `Level unlit, setting 'mat_fullbright 1'` (the fullbright fallback that produced the flat look) and that `mat_fullbright` is not force-set. Both are **absent** in the healthy (HDR-on) state.
- **DX level:** the VScript probe also reads `mat_dxlevel` → **`100`** (full DX9.5) in the current build. The old "DX8-effective" description is **false**.
- **Auto-exposure cvars:** `+mat_dynamic_tonemapping` and `+mat_force_tonemap_scale` (no value) print their values — these are real cvars (marked `cheat`).
- **DXVK device caps:** `left4dead2_d3d9.log` lists the Vulkan feature flags DXVK sees from MoltenVK (FP16/SM3.0-class support is present). **Note:** DXVK caps are *not* the HDR lever — an instrumented `CheckDeviceFormat` probe confirmed DXVK already returns `A16B16G16R16F` as renderable+blendable (`result=0`/D3D_OK) at init. See [03-known-issues #1](03-known-issues.md).
- **Adapter identity:** `left4dead2_d3d9.log` → `Apple M4 Pro` (Vulkan vendor `0x106B`, absent from `dxsupport.cfg`).

> **No runtime HDR toggle.** `mat_hdr_level` is hidden from the console/cfg (`Unknown command`) **and** runtime-locked — VScript `Convars.SetValue("mat_hdr_level","2")` is **refused** in every scope tested (map child scope, console/root scope via `listenserver.cfg`→`script_execute`, with and without `sv_cheats`). Material-system **init** is the only window it takes effect, so the only working lever is the launch args. This is why the fix was *removing* the bad `+mat_hdr_level 1` arg rather than setting a "correct" value anywhere.

## Diagnosing a `0x010c`

1. Reproduce with `./diag-monitor.sh "repro" ` → confirm `faults(0000010c)` > 0 and the `fault_at` time (~36 s = heavy first frame).
2. `game-stderr.log` shows the MoltenVK side: `GPU mem allocated at fault: ~1.8 GB across N allocs`, `no encoder info`. **~1.8 GB ≠ OOM** (18 GB available) → it's an internal command-buffer fault, not memory exhaustion.
3. `gpu-faults.log` shows the kernel AGX/IOGPU lines — the OS-level fault class.
4. Levers to try: `L4D2_MVK_PREFILL=2` (immediate encoding raises the threshold, but ~5 fps), `MVK_L4D2_FORCE_PRIVATE_RT=1` (tile-memory mitigation), or `--diag-gfx` (Metal shader validation names the exact OOB access — heavy, diagnostic only).

## Heavy GPU validation — `--diag-gfx`

Enables `MTL_DEBUG_LAYER`, `MTL_SHADER_VALIDATION`, and full DXVK HUD. This is what *names* an out-of-bounds access (which shader, which resource) instead of just "Internal Error". Big stutter — diagnostic use only.

## Killing a stuck session

```bash
./play-l4d2.sh --kill
```
Wine processes can wedge in uninterruptible sleep; `--kill` does `wineserver -k` then `pkill -9`. If a process resists, `kill -CONT <pid>; kill -KILL <pid>` (may need sudo). Always clear stale `wineserver`/`winedevice`/`left4dead2` before re-running.
