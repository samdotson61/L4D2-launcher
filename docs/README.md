# L4D2 on Apple Silicon — Project Documentation

Running **32-bit Windows Left 4 Dead 2** on **macOS 26.x / Apple Silicon (M4 Pro)** via Wine + a custom Steam-API bridge + a patched D3D9→Vulkan→Metal graphics stack.

> The native Mac L4D2 build is 32-bit i386 Mach-O and has been unrunnable since macOS Catalina dropped 32-bit support. This project instead runs the **Windows** binaries through Wine, with a hand-built Steam bridge and GPU-translation patches that make them work on Apple Silicon.

**Last updated:** 2026-06-02

---

## Status at a glance

| Aspect | State |
|---|---|
| Launches to main menu | ✅ Working |
| Loads into a campaign (renders, HUD, weapons, bots) | ✅ Working |
| Framerate (native 1512×982, max settings) | ✅ ~90–130 fps on the test map |
| Max settings (4× MSAA + multicore + max textures) | ✅ Stable |
| Heavy-scene `0x010c` GPU crash | 🟡 Not triggering at current settings, but historically marginal |
| **HDR / tonemapping (proper light/shadow range)** | ❌ **OFF — engine reports "HDR Disabled"** (the current top issue) |
| Flashlight shadow | 🟡 Disabled as a stopgap (`r_flashlightdepthtexture 0`) |
| Online / matchmaking | 🟡 Bridge plumbing present (lobby + P2P proxies); not fully verified end-to-end |
| Clean quit (reap helper + wineserver) | 🟡 Present in `--diag` path; normal launch uses `exec` (extension stashed) |

**Bottom line:** the game is **playable** — it loads a campaign and runs fast at max settings — but **HDR tonemapping is currently not engaging**, so lighting looks flat/overexposed (interiors are as bright as sunlit exteriors). See [03-known-issues.md](03-known-issues.md#1-hdr--tonemapping-disabled-).

---

## The stack

```
Left 4 Dead 2 (32-bit Windows .exe)
   │  Steamworks API calls                     D3D9 calls
   ▼                                              ▼
custom steam_api.dll (32-bit PE)            dxvk_d3d9.dll  (DXVK 1.10.3 + patches)
   │  TCP RPC :54550                              ▼  Vulkan
   ▼                                          libMoltenVK.dylib (1.4.1 + patches)
steam_helper (native arm64) ── real macOS Steam     ▼  Metal
                                              Apple M4 Pro GPU
        all running under  Whisky-Wine 11  +  Rosetta 2  on  macOS 26.x
```

---

## Documentation index

| Doc | Contents |
|---|---|
| [01-current-state.md](01-current-state.md) | Playability, what works/doesn't, the exact deployed configuration, repo state |
| [02-architecture.md](02-architecture.md) | How the whole stack fits together; why each layer exists |
| [03-known-issues.md](03-known-issues.md) | Every open/known issue with symptom, cause, workaround, status |
| [04-components.md](04-components.md) | The Steam bridge, DXVK build + patch, MoltenVK build + patch, binary patches |
| [05-usage.md](05-usage.md) | `play-l4d2.sh` commands, env-var overrides, game configs |
| [06-building.md](06-building.md) | Building DXVK / MoltenVK / the bridge from source |
| [07-debugging.md](07-debugging.md) | The diagnostic harness, log files, how to read dxlevel/HDR/fault state |

## Quick start

```bash
~/L4D2-launcher/play-l4d2.sh          # build + install everything (first run) and launch
~/L4D2-launcher/play-l4d2.sh --kill   # force-kill a stuck game/wine/helper
```

See [05-usage.md](05-usage.md) for the full command list.
