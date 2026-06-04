# Architecture

## Why this exists

The native macOS L4D2 is a **32-bit i386** build — unrunnable since macOS Catalina removed 32-bit support. Rather than fight that dead binary, this project runs the **Windows** L4D2 binaries on macOS. Two hard problems follow, and the architecture is the solution to each:

1. **Steam.** L4D2 expects `steam_api.dll` + a running Steam client. Goldberg's emulator crashes in `DllMain` on this Wine, and Steam-for-Windows crash-loops in CEF on this Wine. → A **custom Steam bridge** that proxies to the *real macOS Steam client*.
2. **Graphics.** The game renders with Direct3D 9, which doesn't exist on macOS. → **DXVK** (D3D9→Vulkan) + **MoltenVK** (Vulkan→Metal), both **patched** for the quirks of an Apple tile GPU under Wine + Rosetta.

## The full pipeline

```
                         ┌─────────────────────────────────────────────┐
                         │  left4dead2.exe  (32-bit Windows, x86)        │
                         │  running under Rosetta 2 inside Wine          │
                         └───────────────┬───────────────┬──────────────┘
            Steamworks API calls         │               │   Direct3D 9 calls
                                         ▼               ▼
                    ┌────────────────────────┐   ┌──────────────────────────────┐
                    │ steam_api.dll          │   │ dxvk_d3d9.dll                 │
                    │ (our 32-bit PE shim)   │   │ DXVK 1.10.3 + patches         │
                    │ • 22 interface vtables │   │ • D3D9 → Vulkan               │
                    │ • runtime binary       │   │ • shadow-sampler workaround   │
                    │   patches to engine/   │   │ • pushConstSize fix           │
                    │   client/matchmaking/  │   │ • feature gating for MoltenVK │
                    │   vgui2 DLLs           │   └───────────────┬──────────────┘
                    └───────────┬────────────┘                   │ Vulkan 1.1
                                │ TCP RPC :54550                  ▼
                                ▼                     ┌──────────────────────────────┐
                    ┌────────────────────────┐        │ libMoltenVK.dylib            │
                    │ steam_helper           │        │ MoltenVK 1.4.1 + patches     │
                    │ (native arm64 binary)  │        │ • Vulkan → Metal             │
                    │ loads real             │        │ • null-descriptor fallback   │
                    │ libsteam_api.dylib     │        │ • isAppleGPU fix (M4 Pro)    │
                    └───────────┬────────────┘        │ • robustImageAccess2         │
                                │                      │ • push-const slot reserve    │
                                ▼                      └───────────────┬──────────────┘
                    ┌────────────────────────┐                        │ Metal
                    │ macOS Steam client     │                        ▼
                    │ (real identity/auth)   │              Apple M4 Pro GPU
                    └────────────────────────┘

  Host runtime:  macOS 26.x  ·  Whisky-Wine 11  ·  Rosetta 2  ·  prefix: ~/L4D2-launcher/whisky-prefix
```

## Layer-by-layer

### 1. Wine (Whisky-Wine 11)
Provides the Win32 environment. Whisky's Wine 11 build is used (not Apple's GPTK Wine 7.7, which lacks Vulkan and has a broken CEF). The 32-bit game runs through Wine's WoW64 + Rosetta 2 for x86→arm64. The prefix at `~/L4D2-launcher/whisky-prefix/` holds the bridge DLL, Steam-for-Windows DLLs, vcrun2010, and the binary-patched game DLLs. (`Game Porting Toolkit.app` is also present as a fallback Wine source.)

### 2. Steam bridge (two processes)
- **`steam_api.dll`** — a hand-written 32-bit PE, no CRT, that L4D2 loads in place of Valve's. It implements the Steamworks API surface (init, interface creation, 22 interface vtables matching SDK 1.53a), and forwards the calls that need real data to the helper over a local TCP socket. It also applies **runtime binary patches** to the game's own DLLs to work around Wine/DRM issues.
- **`steam_helper`** — a native arm64 binary that loads the *real* `libsteam_api.dylib` from the macOS Steam install and answers RPC requests (60+ opcodes) with real Steam data (identity, auth tickets, lobbies, P2P, server lists, callback draining).

This split is the core trick: the Windows game thinks it's talking to Steam; it's actually talking to the real macOS Steam client through a translation layer. See [04-components.md](04-components.md).

### 3. DXVK (D3D9 → Vulkan)
`dxvk_d3d9.dll` (built from DXVK 1.10.3 + `shadow-sampler-workaround.patch`) replaces the game's Direct3D 9. It's patched for MoltenVK's limitations (no geometry shader / cull distance, shadow-sampler aliasing, the pushConstSize bug, robustImageAccess2). The game runs with `-vulkan` so it routes D3D9 through this DLL.

### 4. MoltenVK (Vulkan → Metal)
`libMoltenVK.dylib` (MoltenVK 1.4.1 + the session patch `moltenvk-all-edits-latest.patch`, regenerated 2026-06-04) translates DXVK's Vulkan to Metal for the M4 Pro. The patch fixes Apple-GPU detection on the M4 Pro, provides null-descriptor fallbacks (avoiding deref-of-0 GPU faults), reserves push-constant slots, adds the GPU-fault diagnostics used by `--diag`, and carries the **attachment-less-skip `0x010c` HDR fix** (issue #2, solved 2026-06-04) — it supersedes the older `null-descriptor-fallback.patch`, whose fix it still includes.

### 5. The GPU
Apple M4 Pro. The long-running villain was the `0x010c` command-buffer fault; under HDR it was root-caused (2026-06-04) to an **attachment-less render pass** and **solved** in MoltenVK (skip creating a Metal encoder for a zero-attachment pass), so HDR is now playable end-to-end. See [03-known-issues.md](03-known-issues.md#2-0x010c-device-lost-under-hdr--solved-2026-06-04-was-the-top-blocker-for-hdr-playability--41-62-64).

## Orchestration: `play-l4d2.sh`

One script builds the bridge, installs/patches everything into the prefix and game folder, starts the helper, sets the (large) MoltenVK/DXVK/Wine environment, and launches the game. See [05-usage.md](05-usage.md).
