#!/usr/bin/env bash
#
# play-l4d2.sh — run Left 4 Dead 2 on Apple Silicon macOS 26+
#
# Why this exists: Valve's native macOS L4D2 build is 32-bit (i386) Mach-O.
# macOS dropped 32-bit support at Catalina (10.15); Rosetta 2 only translates
# 64-bit x86. So `hl2_osx` and every dylib in `bin/` are unloadable on macOS 11+.
# Steam ships the *Windows* binaries (left4dead2.exe + .dlls) in the same
# install folder, and we run those through Apple's Game Porting Toolkit
# (wine64 + D3DMetal). Steam DRM is satisfied by dropping a `steam_appid.txt`
# alongside the exe — the standard Source-engine workaround.
#
# We install GPTK from the Gcenx prebuilt tarball (a self-contained .app),
# NOT via Homebrew — the gcenx/apple tap is stale and pins openssl@1.1
# which Homebrew has disabled.
#
# References:
#   https://www.applegamingwiki.com/wiki/Left_4_Dead_2
#   https://github.com/Gcenx/game-porting-toolkit/releases

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
GAME_DIR="${L4D2_GAME_DIR:-$HOME/Library/Application Support/Steam/steamapps/common/Left 4 Dead 2}"
LAUNCHER_DIR="$HOME/L4D2-launcher"
GPTK_APP="$LAUNCHER_DIR/Game Porting Toolkit.app"
GPTK_URL="https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-3.0-3/game-porting-toolkit-3.0-3.tar.xz"
# Whisky's bundled Wine 11 + DXVK + MoltenVK — pulled from the community
# fork by frankea (the GetWhisky CDN went down with the project's shutdown).
# This is what the launcher uses by default; GPTK is kept as a fallback for
# the prefix and binary helpers it provides.
WHISKY_LIB="$LAUNCHER_DIR/whisky-wine/Libraries"
WHISKY_URL="https://github.com/frankea/Whisky/releases/download/v3.0.0/Libraries.tar.gz"
# Per-runtime prefix so Wine 7 and Wine 11 don't fight over the same registry.
if [[ -d "$WHISKY_LIB" ]]; then
  PREFIX_DIR="${L4D2_PREFIX:-$LAUNCHER_DIR/whisky-prefix}"
  WINE64="$WHISKY_LIB/Wine/bin/wine64"
  WINE_DYLD="$WHISKY_LIB/Wine/lib:$WHISKY_LIB"
else
  PREFIX_DIR="${L4D2_PREFIX:-$LAUNCHER_DIR/prefix}"
  WINE64="$GPTK_APP/Contents/Resources/wine/bin/wine64"
  WINE_DYLD=""
fi
STEAM_APPID=550
WIN_EXE="left4dead2.exe"
STEAM_EXE_PATH='/drive_c/Program Files (x86)/Steam/steam.exe'

# -no-cef-sandbox: Steam's UI is rendered by CEF (Chromium). On Wine, CEF's
# sandbox process hits a NOTREACHED assertion and crash-loops — so the login
# window never paints. Disabling the sandbox is the long-known workaround.
STEAM_ARGS=(-no-cef-sandbox)

# Default Source-engine launch args. -novid skips the Valve/Bink intro videos
# which assert-fail in wine's memory allocator. -vulkan routes through the
# game's bundled shaderapivk.dll → DXVK → Wine 11's winevulkan → MoltenVK
# → Metal; without it the game silently drops out after a few seconds.
# Launch args — `+command value` runs the console-command at the point in
# startup where ConVars are processed.
#
# `-vulkan` activates L4D2's bundled DXVK (dxvk_d3d9.dll in the game's bin
# dir).  Path: L4D2.exe → dxvk_d3d9.dll → Vulkan → MoltenVK → Metal.
# `-novid` skips the Valve intro video.
# Console is not auto-opened — toggle with the ~ key in-game when needed.
#
# +r_flashlightdepthtexture 0 : TEMPORARY.  L4D2's projected-flashlight
#   shadow renders a depth texture then samples it the same frame; on Apple
#   Silicon's tile GPU that render-to-depth-then-sample faults the command
#   buffer (MoltenVK #832/#490) → the whole frame blacks out whenever a
#   survivor is in the flashlight frustum.  Disabling the flashlight SHADOW
#   (the flashlight itself still lights) sidesteps the fault.  This is the
#   confirmation/stopgap; the real fix is forcing Store (non-memoryless)
#   store-action on that depth target — tracked separately.
#
# Max-settings render args — the ConVar half of the max-settings guarantee.
#   The VideoConfig half (4× MSAA, multicore, aniso, gpu_level, dxlevel) lives in
#   video.txt and is re-asserted every launch by assert_max_settings (C2); these
#   two must agree, and do.  What's actually maxed here: full textures
#   (mat_picmip 0), expensive water (r_waterforceexpensive 1), render-to-texture
#   shadows (r_shadowrendertotexture 1), 4× MSAA (mat_antialias 4) and multicore
#   (mat_queue_mode -1) — all at native 1512x982.
#
#   *** HDR "flat / blown-out / no baked shadows": RENDERING SOLVED 2026-06-03 ***
#   The cause was THIS launcher.  A `+mat_hdr_level 1` token used to live in this
#   array.  The engine logs "Unknown command mat_hdr_level" for it — but it is NOT
#   a no-op: the command is QUEUED and applied the instant mat_hdr_level registers
#   during material-system init, pinning HDR to level 1 (LDR+bloom) every launch.
#   On L4D2's HDR-only maps, level 1 reads the (empty) LDR lighting lump, so the
#   engine logs "Level unlit, setting 'mat_fullbright 1'" and renders fullbright —
#   the exact flat / over-bright / no-baked-shadow symptom.  Deleting the token
#   lets the engine's true hardware-derived default stand: level 2 (full HDR).
#   Verified via VScript probe: mat_hdr_level reads 2, "Level unlit" is gone,
#   mat_fullbright is no longer forced, the maps light correctly.
#   mat_hdr_level is HIDDEN from console/cfg AND runtime-locked (VScript SetValue
#   is refused in EVERY scope on this build — child, root, listenserver.cfg), so
#   init is the only window and "absence of the bad token" IS the fix; there is
#   nothing to add.  Confirmed RED HERRINGS, do not chase again: DXVK version
#   (1.10.3 vs 2.5.3), DX8/dxlevel (engine is at mat_dxlevel 100), MSAA, multicore,
#   exposure/tonemap convars, the FP16 CheckDeviceFormat report (DXVK already
#   returns A16B16G16R16F blendable=OK at init).  See docs/03-known-issues.md #1.
#
#   NOTE — HDR RENDERS BUT IS NOT YET PLAYABLE.  Turning HDR on (this fix) re-triggers
#   the 0x010c device-lost GPU fault ~25-40s into active play: the FP16 HDR render
#   targets exhaust the M4 AGX tile-memory budget at the first full-scene frame →
#   VK_ERROR_DEVICE_LOST → freeze.  Separate open blocker (docs/03-known-issues.md
#   #2).  Every historical "playable" build was secretly HDR-OFF.  FORCE_PRIVATE_RT
#   / L4D2_MVK_RESUME / PREFILL / lower-res all fail; next attempt is a pooled-
#   scratch RT spill in MoltenVK.  So: HDR _or_ playable, not both, for now.
#
#   mat_queue_mode -1 keeps multicore ON.  Only the --wined3d path forces it to 0,
#   and only for that single run (see do_launch_wined3d + _wined3d_restore / C1);
#   it is never persisted to autoexec.cfg/video.txt any more.
#   +r_flashlightdepthtexture 1: dynamic flashlight shadows ON (same queued-arg
#   mechanism; confirmed working).  Replaced the old `0` stopgap.
DEFAULT_GAME_ARGS=(-novid -vulkan +r_flashlightdepthtexture 1 +mat_queue_mode -1 +mat_picmip 0 +r_waterforceexpensive 1 +r_shadowrendertotexture 1 +mat_antialias 4)

# ─── Pretty output ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; N=$'\033[0m'
else
  R=; G=; Y=; B=; N=
fi
say()  { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s !!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s xx%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Force-kill stuck L4D2 / wine / helper processes — e.g. a hung game that
# ignores Ctrl-C (a wine process wedged in an exception loop won't take SIGINT).
# Clean wineserver shutdown first, then SIGKILL any survivors. Safe to run
# anytime, including from a second terminal while a launch is stuck.
do_kill() {
  say "Killing stuck L4D2 / wine / helper processes…"
  local ws; ws="$(dirname "$WINE64")/wineserver"
  if [[ -x "$ws" ]]; then
    ${WINE_DYLD:+DYLD_FALLBACK_LIBRARY_PATH="$WINE_DYLD"} WINEPREFIX="$PREFIX_DIR" "$ws" -k 2>/dev/null || true
    sleep 1
  fi
  pkill -9 -f "left4dead2.exe"             2>/dev/null || true
  pkill -9 -f "whisky-wine/Libraries/Wine" 2>/dev/null || true
  pkill -9 -f "$PREFIX_DIR"                2>/dev/null || true
  pkill -9 -f "steam_helper"               2>/dev/null || true
  pkill -9 -f "log stream"                 2>/dev/null || true
  sleep 1
  if ps -axo command 2>/dev/null | grep -v grep | grep -qiE "left4dead2|whisky-wine/Libraries/Wine|steam_helper"; then
    warn "Some processes may still be alive — run '$0 --kill' again or: ps -ax | grep -i wine"
  else
    ok "All L4D2/wine/helper processes cleared."
  fi
}

usage() {
  cat <<'EOF'
play-l4d2.sh — run Left 4 Dead 2 on Apple Silicon macOS

Usage:
  play-l4d2.sh                       Launch L4D2 (auto-sets-up on first run)
  play-l4d2.sh --setup               Install prerequisites + prefix; don't launch
  play-l4d2.sh --reset               Delete and re-create the Wine prefix
  play-l4d2.sh --install-goldberg    Install Goldberg steam_api.dll shim
                                     (RECOMMENDED — Steam-for-Windows is broken
                                      on the Wine version GPTK ships)
  play-l4d2.sh --uninstall-goldberg  Restore original steam_api.dll from backup
  play-l4d2.sh --install-steam       Try Steam-for-Windows in the prefix (broken)
  play-l4d2.sh --steam               Launch Steam-for-Windows visibly (broken)
  play-l4d2.sh --link-game           Symlink your existing L4D2 install into the
                                     prefix's Steam library
  play-l4d2.sh --winecfg           Open winecfg against the prefix
  play-l4d2.sh --shell             Subshell with wine64 in PATH + WINEPREFIX set
  play-l4d2.sh --build-bridge      Compile bridge/steam_api.dll + steam_helper
  play-l4d2.sh --install-bridge    Install bridge steam_api.dll + patch
                                   matchmaking.dll/client.dll (originals backed up)
  play-l4d2.sh --bridge            Full bridge pipeline: build, install, start helper
  play-l4d2.sh --hud               Enable Metal/D3DMetal performance HUD
  play-l4d2.sh --debug             Verbose Wine logging to stderr
  play-l4d2.sh --diag              LIGHT, playable diagnostics → game-stderr.log
                                   (MoltenVK encoder-fault log + DXVK info;
                                   no heavy Metal GPU validation)
  play-l4d2.sh --diag-gfx          HEAVY DXVK + MoltenVK + Metal GPU validation
                                   (names OOB faults; big stutter, diag only)
  play-l4d2.sh --wined3d           Bypass DXVK; render via Wine's native
                                   d3d9 → wined3d → MoltenVK path
                                   (set WINED3D_RENDERER=gl to use OpenGL
                                   backend instead of Vulkan — slower but
                                   matches the path that rendered flawlessly
                                   prior to the heap-region access violation)
  play-l4d2.sh --help              Show this help
  play-l4d2.sh -- <args…>          Forward any remaining args to left4dead2.exe
                                   (e.g. -- -windowed -w 1920 -h 1080 -novid)

Env overrides:
  L4D2_GAME_DIR   Path to the L4D2 install folder
                  (default: ~/Library/Application Support/Steam/steamapps/common/Left 4 Dead 2)
  L4D2_PREFIX     Path to the Wine prefix
                  (default: ~/L4D2-launcher/prefix)
EOF
}

# ─── Arg parsing ──────────────────────────────────────────────────────────────
ACTION=launch
EXTRA_ENV=()
GAME_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup)              ACTION=setup ;;
    --reset)              ACTION=reset ;;
    --kill)               ACTION=kill ;;
    --install-goldberg)   ACTION=install-goldberg ;;
    --uninstall-goldberg) ACTION=uninstall-goldberg ;;
    --install-steam)      ACTION=install-steam ;;
    --steam)              ACTION=steam ;;
    --link-game)          ACTION=link-game ;;
    --winecfg)            ACTION=winecfg ;;
    --shell)              ACTION=shell ;;
    --build-bridge)       ACTION=build-bridge ;;
    --install-bridge)     ACTION=install-bridge ;;
    --bridge)             ACTION=bridge ;;
    --hud)            EXTRA_ENV+=("MTL_HUD_ENABLED=1") ;;
    --debug)          EXTRA_ENV+=("WINEDEBUG=warn+all,fixme-all") ;;
    --diag)
      # LIGHT diagnostics — playable.  Our MoltenVK per-encoder GPU-fault log
      # (names the faulting Metal encoder / Source pass on any 0x010c) plus
      # DXVK info, captured to game-stderr.log.  Crucially does NOT enable
      # MTL_SHADER_VALIDATION / MTL_DEBUG_LAYER (those are correct but ~5-10x
      # slower and distort the very stutter/flicker we're trying to observe).
      # Use this to tell a command-buffer FAULT from a compositing/hazard
      # issue; escalate to --diag-gfx only when you need the OOB reason.
      EXTRA_ENV+=(
        "DXVK_LOG_LEVEL=info"
        "DXVK_LOG_PATH=$LAUNCHER_DIR"
        "MVK_L4D2_DEBUG=1"
        "MVK_CONFIG_DEBUG=1"
      )
      ;;
    --diag-gfx)
      # Verbose DXVK + MoltenVK diagnostics for investigating black-world
      # / shader / descriptor binding bugs.  Logs to game.log; DXVK HUD
      # overlay shows pipeline + compiler stats top-left in-game.
      # HEAVY (Metal GPU validation) — expect big stutter; diagnostic only.
      EXTRA_ENV+=(
        "DXVK_HUD=fps,frametimes,api,compiler,memory,version,pipelines,samplers,descriptors"
        "DXVK_LOG_LEVEL=info"
        "DXVK_LOG_PATH=$LAUNCHER_DIR"
        "MVK_CONFIG_LOG_LEVEL=4"
        "MVK_CONFIG_DEBUG=1"
        "MVK_CONFIG_PERFORMANCE_TRACKING=1"
        # Our patched MoltenVK gates its per-encoder GPU-fault logging behind
        # this var (set it so command-buffer failures name the faulting Metal
        # encoder / Source render pass).
        "MVK_L4D2_DEBUG=1"
        # Metal-level validation — turns the opaque "Internal Error (0x010c)"
        # into the actual GPU fault reason (OOB read, feedback loop, bad
        # store action, …) printed to stderr.  Latched at MTLDevice creation,
        # so these must be in the launch env (they are).  Heavy; diagnostic
        # runs only.
        "MTL_DEBUG_LAYER=1"
        "MTL_DEBUG_LAYER_ERROR_MODE=nslog"
        "MTL_DEBUG_LAYER_WARNING_MODE=nslog"
        "MTL_SHADER_VALIDATION=1"
        "MTL_SHADER_VALIDATION_REPORT_TO_STDERR=1"
      )
      ;;
    --wined3d)
      # Bypass DXVK entirely.  Wine 11's bundled d3d9 → vkd3d-shader →
      # MoltenVK is more conservative than DXVK's d3d9 (no shadow-sampler
      # workaround needed, simpler descriptor model), at the cost of
      # missing some DXVK optimizations.  Forces L4D2 to load Wine's
      # d3d9.dll instead of its bundled dxvk_d3d9.dll by renaming the
      # latter for this run only (restored on exit).
      ACTION=wined3d ;;
    --help|-h)        usage; exit 0 ;;
    --)               shift; GAME_ARGS+=("$@"); break ;;
    *)                GAME_ARGS+=("$1") ;;
  esac
  shift
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
# Convert /Users/foo/bar.exe → Z:\Users\foo\bar.exe (Wine's default Z: drive maps /)
unix_to_winpath() {
  local p="Z:$1"
  printf '%s' "${p//\//\\}"
}

run_wine() {
  WINEPREFIX="$PREFIX_DIR" WINEESYNC=1 "$WINE64" "$@"
}

# ─── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  [[ "$(uname -s)" == "Darwin" ]] || die "macOS only — got $(uname -s)"
  [[ "$(uname -m)" == "arm64"  ]] || die "Apple Silicon required — got $(uname -m)"

  say "macOS $(sw_vers -productVersion) on $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo CPU)"

  if ! arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    warn "Rosetta 2 missing — installing (will prompt for your password)…"
    sudo /usr/sbin/softwareupdate --install-rosetta --agree-to-license
  fi
  ok "Rosetta 2 ready"

  [[ -d "$GAME_DIR" ]] \
    || die "L4D2 not found at: $GAME_DIR
   Set L4D2_GAME_DIR if installed elsewhere."
  [[ -f "$GAME_DIR/$WIN_EXE" ]] \
    || die "Windows binary missing: $GAME_DIR/$WIN_EXE
   Steam ships both Mac and Windows bins side-by-side.
   In Steam → L4D2 → Properties → Installed Files → 'Verify integrity of game files'."
  ok "L4D2 install at $GAME_DIR"
}

# ─── Patched MoltenVK install ────────────────────────────────────────────────
# Whisky-Wine ships MoltenVK 1.4.1 (x86_64, runs through Rosetta). Stock 1.4.1
# hard-codes robustness2 nullDescriptor = false and its setNullBuffer encoders
# write gpuAddress = 0 / setBuffer:nil into the argument buffer. When a shader
# references a slot the application left unbound (which DXVK leaves NULL when
# the D3D9 source shader doesn't bind that slot), the GPU dereferences address
# 0 and the command buffer faults with "Internal Error (0000010c)". MoltenVK
# then recovers via MVK_CONFIG_RESUME_LOST_DEVICE, which produces a black-frame
# gap. L4D2's character/skinning shaders trip this on virtually every frame.
#
# Our patched MoltenVK (./moltenvk-build/libMoltenVK.dylib, source patch
# alongside) allocates a 64KB zero-filled fallback buffer on the device and
# binds it to every otherwise-null descriptor slot. Shaders read zeros (same
# semantics as VK_EXT_robustness2 nullDescriptor) and the GPU never faults.
ensure_patched_moltenvk() {
  local target="$WHISKY_LIB/Wine/lib/libMoltenVK.dylib"
  local backup="$target.original"
  local patched="$LAUNCHER_DIR/moltenvk-build/libMoltenVK.dylib"
  [[ -f "$patched" ]] || { warn "Patched MoltenVK missing at $patched"; return 0; }
  [[ -f "$target"  ]] || { warn "Whisky MoltenVK missing at $target"; return 0; }

  # Idempotency: check for our patch's unique label string.
  if strings "$target" 2>/dev/null | grep -q '^MVKDummyNullDescriptorBuffer$'; then
    ok "Patched MoltenVK already installed"
    return 0
  fi

  [[ -f "$backup" ]] || cp "$target" "$backup"
  cp "$patched" "$target"
  # Re-sign in place with a UNIQUE code-signing identifier on every real
  # (re)install. Rosetta caches its x86_64 AOT translation keyed by the dylib's
  # cdhash (which includes the signing identifier) and binds it to the on-disk
  # file via a "signature supplement". Replacing the file under an unchanged
  # cdhash leaves the old AOT's supplement bound to a file that no longer exists,
  # producing the FATAL "rosetta error: Attachment of code signature supplement
  # failed" — which aborts the MoltenVK load and wedges wine in an ntdll
  # exception loop before Vulkan ever initialises (looks just like a render
  # hang). A fresh identifier => fresh cdhash => Rosetta builds a brand-new AOT
  # with no stale supplement. This branch only runs on a genuine (re)install
  # (the marker check above skips it otherwise), so there's no per-launch churn.
  codesign --force --sign - -i "org.l4d2launcher.moltenvk.$(date +%s)" "$target" 2>/dev/null \
    || warn "codesign of patched MoltenVK failed — Rosetta AOT may be stale (game may hang on load)"
  ok "Installed patched MoltenVK (original backed up to $(basename "$backup"))"
}

# ─── GPTK install (prebuilt .app, no Homebrew) ───────────────────────────────
ensure_gptk() {
  # If Whisky-Wine is available, prefer it (Wine 11 + DXVK + MoltenVK), and
  # only fall back to GPTK if needed. Downloads the Wine bundle from the
  # frankea/Whisky community fork — no sudo, just a tarball under
  # ~/L4D2-launcher/whisky-wine/.
  if [[ ! -d "$WHISKY_LIB" ]]; then
    say "Downloading Whisky Wine bundle (Wine 11 + DXVK + MoltenVK, ~300 MB)…"
    mkdir -p "$LAUNCHER_DIR/whisky-wine"
    local tarball="$LAUNCHER_DIR/.whisky-wine.tar.gz"
    if curl -fL --progress-bar -o "$tarball" "$WHISKY_URL"; then
      tar -xzf "$tarball" -C "$LAUNCHER_DIR/whisky-wine"
      rm -f "$tarball"
      # Re-derive WINE64 / WINE_DYLD now that the bundle exists.
      WINE64="$WHISKY_LIB/Wine/bin/wine64"
      WINE_DYLD="$WHISKY_LIB/Wine/lib:$WHISKY_LIB"
      PREFIX_DIR="${L4D2_PREFIX:-$LAUNCHER_DIR/whisky-prefix}"
      ok "Whisky Wine installed ($("$WINE64" --version 2>&1 | head -1))"
    else
      warn "Whisky download failed; falling back to GPTK."
    fi
  fi

  if [[ -x "$WINE64" ]]; then
    local ver
    ver=$("$WINE64" --version 2>&1 | head -1)
    ok "Wine ready ($ver)"
    return 0
  fi

  say "Downloading Game Porting Toolkit (.app, ~228 MB) from Gcenx releases…"
  mkdir -p "$LAUNCHER_DIR"
  local tarball="$LAUNCHER_DIR/.gptk.tar.xz"
  curl -fL --progress-bar -o "$tarball" "$GPTK_URL" \
    || die "Download failed. Check connectivity and retry."

  say "Extracting into $LAUNCHER_DIR…"
  tar -xJf "$tarball" -C "$LAUNCHER_DIR"
  rm -f "$tarball"

  [[ -x "$WINE64" ]] || die "Extracted but wine64 missing at:
   $WINE64"
  ok "Game Porting Toolkit installed ($("$WINE64" --version 2>&1 | head -1))"
}

# ─── Wine prefix ──────────────────────────────────────────────────────────────
ensure_prefix() {
  if [[ -d "$PREFIX_DIR/drive_c" ]]; then
    ok "Wine prefix at $PREFIX_DIR"
    return 0
  fi
  say "Initialising Wine prefix at $PREFIX_DIR…"
  mkdir -p "$(dirname "$PREFIX_DIR")"
  WINEPREFIX="$PREFIX_DIR" "$WINE64" wineboot --init >/dev/null 2>&1
  # Source engine targets DX9; behave like Windows 10 to avoid quirks.
  WINEPREFIX="$PREFIX_DIR" "$WINE64" reg add \
    'HKCU\Software\Wine' /v Version /d win10 /f >/dev/null 2>&1 || true
  ok "Prefix initialised"
}

# ─── Steam DRM workaround ─────────────────────────────────────────────────────
# steam_appid.txt covers the DRM check for many Source games, but L4D2 also
# calls SteamAPI_Init() which needs a real Steam process. We keep the file
# (cheap), and additionally start Steam-for-Windows in the prefix.
ensure_appid() {
  local f="$GAME_DIR/steam_appid.txt"
  if [[ -f "$f" ]] && grep -q "^$STEAM_APPID" "$f"; then return 0; fi
  printf '%s\n' "$STEAM_APPID" > "$f"
  ok "Wrote $f"
}

steam_exe_unix() { printf '%s' "$PREFIX_DIR$STEAM_EXE_PATH"; }
steam_installed() { [[ -f "$(steam_exe_unix)" ]]; }
steam_loginusers() { printf '%s' "$PREFIX_DIR/drive_c/Program Files (x86)/Steam/config/loginusers.vdf"; }
steam_signed_in() { [[ -f "$(steam_loginusers)" ]]; }

steam_is_running() {
  # Look for a wine64 process whose args reference steam.exe in our prefix.
  pgrep -fl "$(steam_exe_unix)" >/dev/null 2>&1
}

# Kill any background -silent Steam so a fresh visible one can start cleanly.
steam_kill_silent() {
  local pids
  pids=$(pgrep -f "$(steam_exe_unix) -silent" 2>/dev/null || true)
  [[ -z "$pids" ]] && return 0
  say "Stopping background Steam process(es): $pids"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  sleep 2
}

# Start Steam-for-Windows in the background if not already running, and wait
# until it has booted enough to satisfy SteamAPI_Init() from a child process.
ensure_steam_running() {
  if ! steam_installed; then
    warn "Steam-for-Windows not installed in prefix. L4D2 will refuse to start."
    warn "Run: $0 --install-steam"
    return 1
  fi
  if steam_is_running; then
    ok "Steam-for-Windows already running"
    return 0
  fi

  say "Starting Steam-for-Windows in the background…"
  (
    WINEPREFIX="$PREFIX_DIR" WINEESYNC=1 \
      "$WINE64" "$(steam_exe_unix)" "${STEAM_ARGS[@]}" -silent >/dev/null 2>&1
  ) &
  disown 2>/dev/null || true

  # Poll for the Steam process to appear, then give it a few seconds to set up
  # its IPC pipe before launching the game.
  local i
  for i in $(seq 1 30); do
    sleep 1
    if steam_is_running; then
      sleep 5
      ok "Steam-for-Windows ready"
      return 0
    fi
  done
  warn "Steam didn't appear within 30s — proceeding anyway."
  return 0
}

# ─── Actions ──────────────────────────────────────────────────────────────────
do_reset() {
  if [[ -d "$PREFIX_DIR" ]]; then
    say "Removing prefix $PREFIX_DIR"
    rm -rf "$PREFIX_DIR"
  fi
  ensure_prefix
  ok "Reset done"
}

do_install_steam() {
  ensure_prefix
  if steam_installed; then
    ok "Steam-for-Windows already installed in prefix."
    return 0
  fi
  local installer="$HOME/Downloads/SteamSetup.exe"
  if [[ ! -f "$installer" ]]; then
    say "Downloading Steam-for-Windows installer → $installer"
    curl -fL --progress-bar -o "$installer" \
      https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe
  fi
  say "Running Steam installer inside the prefix (click through the dialog)…"
  run_wine "$installer" || true
  if ! steam_installed; then
    die "Installer exited but steam.exe not found at $(steam_exe_unix)"
  fi
  cat <<EOF

Next steps:
  1. $0 --steam        # opens Steam-for-Windows so you can sign in
                         (check "Remember password", then close the window)
  2. $0 --link-game    # bridges your existing L4D2 install into the prefix's
                         steamapps (saves a ~10 GB redownload)
  3. $0                # play

EOF
  ok "Steam install complete"
}

do_steam() {
  ensure_prefix
  steam_installed \
    || die "Steam-for-Windows not installed yet. Run: $0 --install-steam"
  steam_kill_silent
  cat <<'EOF'

Launching Steam-for-Windows with -no-cef-sandbox (works around the
crash-loop in steamwebhelper). When the login screen appears:
  1. CHECK "Remember my password" (otherwise sign-in won't persist)
  2. Sign in with your Steam account
  3. Wait until you see the Steam library
  4. Close the Steam window — this returns control to the shell

If the window never appears, hit Ctrl+C here and try the CLI fallback:
  $0 --shell
  wine64 'C:\Program Files (x86)\Steam\steam.exe' -login YOUR_USERNAME YOUR_PASSWORD

EOF
  run_wine "$(steam_exe_unix)" "${STEAM_ARGS[@]}"
  if steam_signed_in; then
    ok "Sign-in detected — you're set."
  else
    warn "loginusers.vdf still missing. Did you actually sign in?"
    warn "Re-run: $0 --steam"
  fi
}

# Bridge the existing macOS L4D2 install into the prefix's Steam library by
# symlinking the game folder and copying the appmanifest. Avoids re-downloading.
do_link_game() {
  ensure_prefix
  steam_installed \
    || die "Steam-for-Windows not installed. Run: $0 --install-steam first."

  local mac_steamapps="$HOME/Library/Application Support/Steam/steamapps"
  local prefix_steamapps="$PREFIX_DIR/drive_c/Program Files (x86)/Steam/steamapps"
  local manifest="appmanifest_${STEAM_APPID}.acf"

  [[ -f "$mac_steamapps/$manifest" ]] \
    || die "Manifest missing: $mac_steamapps/$manifest
   Open Steam (Mac), let it verify L4D2, then retry."

  mkdir -p "$prefix_steamapps/common"

  # Symlink the game folder (existing install reused).
  local link="$prefix_steamapps/common/Left 4 Dead 2"
  if [[ -L "$link" || -e "$link" ]]; then
    rm -rf "$link"
  fi
  ln -s "$GAME_DIR" "$link"
  ok "Linked $GAME_DIR → $link"

  # Copy the manifest (Steam updates this file in place, don't symlink it).
  cp "$mac_steamapps/$manifest" "$prefix_steamapps/$manifest"
  ok "Copied $manifest into prefix"

  ok "Link done. Steam-for-Windows will see L4D2 as already installed."
}

do_winecfg() { ensure_prefix; run_wine winecfg; }

do_shell() {
  ensure_prefix
  say "Subshell — WINEPREFIX set, wine64 in PATH. Exit with 'exit'."
  WINEPREFIX="$PREFIX_DIR" WINEESYNC=1 \
    PATH="$GPTK_APP/Contents/Resources/wine/bin:$PATH" \
    exec "${SHELL:-/bin/zsh}"
}

# C2 — single source of truth for graphics settings.  Idempotently re-assert the
# max-settings VideoConfig block into video.txt on every launch so nothing (a
# Steam update / "verify integrity", the in-game options menu, or a prior
# --wined3d run) can silently downgrade it.  video.txt LATCHES at material-system
# init and overrides config.cfg / autoexec / launch args, so this is THE place the
# guarantee must live; the ConVar-only settings (picmip / expensive water / RTT
# shadows) ride in DEFAULT_GAME_ARGS, which agrees with this block.
#
# Also performs the C1 cleanup: removes any leftover "multicore landmine"
# autoexec.cfg (mat_queue_mode 0) that a --wined3d run might have stranded.
assert_max_settings() {
  local vid="$GAME_DIR/left4dead2/cfg/video.txt"
  local autoexec="$GAME_DIR/left4dead2/cfg/autoexec.cfg"

  if [[ -f "$vid" ]]; then
    # One-time snapshot of the pre-launcher video.txt (parallels dxsupport.cfg.orig-*).
    [[ -f "$vid.orig-pre-launcher" ]] || cp "$vid" "$vid.orig-pre-launcher"
    # VideoConfig keys we guarantee.  dxlevel 95 keeps the engine ≥ DX9 so HDR
    # isn't silently disabled.
    #
    # HDR is ON at full max settings.  The old L4D2_HDR=1 toggle that forced MSAA
    # off + single-thread "so HDR could survive" is GONE: that MSAA/multicore-
    # breaks-HDR trade-off was a DEBUNKED RED HERRING.  HDR was never disabled by
    # MSAA or multicore — it was disabled by a stray +mat_hdr_level 1 launch arg
    # (removed; see the DEFAULT_GAME_ARGS note).  Full HDR now coexists with 4×
    # MSAA + multicore — exactly the "most successful build" config.
    local mode="max settings (4× MSAA · multicore · HDR on)"
    local -a keys=(gpu_level mat_antialias mat_forceaniso mat_queue_mode dxlevel)
    local -a vals=(3         4             16             -1             95)
    local i k v
    for i in "${!keys[@]}"; do
      k="${keys[$i]}"; v="${vals[$i]}"
      if grep -q "\"setting\.${k}\"" "$vid"; then
        # Update the existing value in place.
        L4D2_K="$k" L4D2_V="$v" perl -i -pe 's/("setting\.$ENV{L4D2_K}"\s+)"[^"]*"/$1"$ENV{L4D2_V}"/' "$vid"
      else
        # Insert before the closing brace, matching the file's tab style.
        L4D2_K="$k" L4D2_V="$v" perl -i -pe 'print "\t\"setting.$ENV{L4D2_K}\"\t\t\"$ENV{L4D2_V}\"\n" if /^\}/' "$vid"
      fi
    done
    ok "Asserted video.txt: $mode · 16× aniso · gpu_level 3 · dxlevel 95"
  else
    warn "video.txt not found ($vid) — skipping max-settings assertion"
  fi

  # C1 — kill any persistent multicore-landmine autoexec.cfg.  A launcher-written
  # one (carries our marker) is removed whole; a user's own autoexec keeps its
  # other lines and loses only the mat_queue_mode override.
  if [[ -f "$autoexec" ]]; then
    if grep -q "L4D2-launcher: serialize D3D9" "$autoexec"; then
      rm -f "$autoexec"
      warn "Removed launcher-written autoexec.cfg (the --wined3d multicore landmine)"
    elif grep -qi "mat_queue_mode" "$autoexec"; then
      perl -i -ne 'print unless /^\s*mat_queue_mode\b/' "$autoexec"
      warn "Stripped mat_queue_mode from your autoexec.cfg (kept the rest)"
    fi
  fi
}

do_launch() {
  ensure_prefix
  ensure_appid

  # Make sure the bridge + binary patches + helper are in place. Each step
  # is idempotent so re-running just no-ops if everything's already set up.
  do_install_bridge
  do_start_helper

  cd "$GAME_DIR"

  # C2/C1: guarantee max settings (and clear any stale multicore landmine) before
  # every launch, so the DXVK path is never silently downgraded.
  assert_max_settings

  say "Launching L4D2 — close the game window to return here."
  # If using Whisky's bundled Wine, set DYLD_FALLBACK_LIBRARY_PATH so its
  # libraries (MoltenVK, SDL2, …) load.
  local dyld_env=()
  [[ -n "$WINE_DYLD" ]] && dyld_env=("DYLD_FALLBACK_LIBRARY_PATH=$WINE_DYLD")
  # MoltenVK configuration. With our patched MoltenVK (see
  # ensure_patched_moltenvk above) the descriptor-fallback bug is fixed at the
  # source — unbound slots point at a 64KB zero-filled buffer instead of
  # nil/0. No more GPU panics on shader access, so no more device-lost-resume
  # cycle, so no more black flashes. Drop the diagnostic+recovery env vars
  # that were band-aids for that bug:
  #   - MTL_DEBUG_LAYER / MTL_SHADER_VALIDATION: turn off — they exist to
  #     trigger panics, which we no longer want
  #   - MVK_CONFIG_RESUME_LOST_DEVICE: keep as safety net (no perf cost when
  #     no device loss occurs)
  #   - MVK_CONFIG_MAX_ACTIVE_METAL_COMMAND_BUFFERS_PER_QUEUE: remove cap —
  #     it was only there to shrink the recovery window
  local mvk_env=(
    # NOTE: bufferDeviceAddress (required by DXVK 2.x) was reported unsupported
    # because MoltenVK reads the OS version via NSProcessInfo, which macOS clamps
    # to 10.16 inside the wine process (wine64's pre-11 deployment target) — so
    # MoltenVK thought the OS was 10.16 < 13.  Fixed INSIDE our patched MoltenVK
    # (mvkSupportsBufferDeviceAddress forced true), NOT via SYSTEM_VERSION_COMPAT=0:
    # that env var flips the process OS context and triggers a fatal Rosetta AOT
    # re-translation of libMoltenVK.dylib ("code signature supplement failed").
    # Metal Argument Buffers OFF (default 0).  DECISIVE FINDING (2026-05-31):
    # with MAB=1 MoltenVK's argument-buffer setup DEADLOCKS inside vkCreateDevice
    # under Rosetta — the game hangs right after "Process set as DPI aware" with
    # the wine exception dispatcher in an infinite fault loop (unkillable via
    # Ctrl-C).  With MAB=0 vkCreateDevice completes.  D3D9 does not need argument
    # buffers (it fits Metal's legacy per-stage descriptor limits: ≤16 samplers,
    # few UBOs), and DXVK 1.10.3 already ran this game fine with MAB off.
    # Overridable via L4D2_MVK_MAB (0=off, 1=on, 2=auto).
    "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=${L4D2_MVK_MAB:-0}"
    "MVK_ALLOW_METAL_FENCES=1"
    # ── THE HDR 0x010c FIX (2026-06-04) ──────────────────────────────────────────
    # The heavy-HDR-frame device-lost (Internal Error 0x010c / IOGPUCommandQueue-
    # ErrorDomain 268) is FIXED in our patched MoltenVK by SKIPPING attachment-less
    # render passes.  Root cause: DXVK emits a 16384x16384 render pass with ZERO
    # attachments (no color/depth/stencil) on the first full-scene HDR frame, and
    # creating a Metal render command encoder with no attachments hard-aborts the
    # Apple GPU (AGX) with 0x010c — by itself, even with no draws.  It's HDR-only,
    # which is why HDR was never stably playable before.  Pinpointed via N=1-render-
    # pass-per-command-buffer + synchronous submission; MVKCommandEncoder::begin-
    # MetalRenderPass now early-returns (no encoder) for such passes.  HDR is now
    # playable end-to-end at max settings (4x MSAA + multicore + native res).
    # Full write-up: docs/03-known-issues.md #2.
    # Default ON in the patched dylib; passed explicitly here for visibility.
    # Set L4D2_MVK_SKIP_NOATT=0 to disable (reproduces the original fault).
    "L4D2_MVK_SKIP_NOATT=${L4D2_MVK_SKIP_NOATT:-1}"
    # NOTE: the MVK_CONFIG_* / MVK_L4D2_* levers below (RESUME, PREFILL, MTLHEAP,
    # FORCE_PRIVATE_RT, MTL_DEBUG) are LEGACY pre-fix diagnostics/levers from the
    # 0x010c hunt — kept for reference and future debugging; none is the fix above.
    # Deeper diagnostics (off by default): MVK_L4D2_DEBUG=1 -> [mvk-tiledbg] per-pass
    # attachment footprint + fault logs; MVK_L4D2_SYNC=1 -> synchronous per-buffer
    # commit to pinpoint a faulting buffer; L4D2_MVK_MAX_PASSES=N -> split the Metal
    # command buffer after N render passes.
    # RESUME default 0.  The level-load "freeze" is a GPU command-buffer fault
    # (Internal Error 0x010c / IOGPUCommandQueueErrorDomain 268), NOT memory
    # (vmmap shows ~2.1 GB of 32-bit space free at peak).  RESUME=1 lets MoltenVK
    # recreate the device after each fault so the load limps through — but the
    # fault is pervasive under heavy load (~thousands/min), so that "recovery" is
    # itself a perf/glitch disaster, not a real fix.  Keep 0 so a genuine fault
    # hard-stops cleanly and the real perf-preserving 0x010c fix can be validated.
    # Override with L4D2_MVK_RESUME=1 if needed.
    "MVK_CONFIG_RESUME_LOST_DEVICE=${L4D2_MVK_RESUME:-0}"
    # PREFILL = 0 (DEFAULT / deferred encoding) = the PERFORMANT path (what the
    # good pre-git build used).  NOTE: PREFILL is NOT a real fix for the level-load
    # 0x010c GPU fault.  Immediate encoding (2/3) only RAISES the crash threshold —
    # it survived a 1280×720 test but still faults at fullscreen (~1512×982), and
    # 2/3 are also slower.  So we keep 0 for speed; the real fix for the heavy-scene
    # 0x010c lives elsewhere (Apple-GPU tile memory / transient render-target
    # storage — see MVK_L4D2_FORCE_PRIVATE_RT).  Overridable via L4D2_MVK_PREFILL.
    "MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=${L4D2_MVK_PREFILL:-0}"
    # Overridable via L4D2_MVK_MTLHEAP (1=heaps default, 0=per-resource, 2=force).
    # Heaps are made resident as a whole unit, so they can over-reserve GPU
    # residency — a lever on the heavy-HDR-frame resource-pressure 0x010c.
    "MVK_CONFIG_USE_MTLHEAP=${L4D2_MVK_MTLHEAP:-1}"
    "MVK_CONFIG_PREALLOCATE_DESCRIPTORS=1"
    "MVK_CONFIG_USE_COMMAND_POOLING=1"
    "MVK_CONFIG_LOG_LEVEL=3"
    "MVK_CONFIG_DEBUG=0"
    # Disable shader fast-math: Source's tonemap exposure curves can hit
    # NaN/Inf paths that AGX faults on under fast-math.
    "MVK_CONFIG_FAST_MATH_ENABLED=0"
    # 0x010c lever (heavy-frame device-lost): force transient render targets —
    # including the HDR FP16 targets — to Private storage instead of memoryless
    # tile memory.  Default 0; set L4D2_MVK_FORCE_PRIVATE_RT=1 to try it (HDR
    # raised tile-memory pressure and re-triggered the fault under active play).
    "MVK_L4D2_FORCE_PRIVATE_RT=${L4D2_MVK_FORCE_PRIVATE_RT:-0}"
    # Diagnostics for the opaque 0x010c fault: Apple Metal GPU-side validation.
    # Default off (heavy); L4D2_MTL_DEBUG=1 + L4D2_MTL_SHADER_VAL=1 to attribute a
    # faulting shader / OOB access.
    "MTL_DEBUG_LAYER=${L4D2_MTL_DEBUG:-0}"
    "MTL_SHADER_VALIDATION=${L4D2_MTL_SHADER_VAL:-0}"
  )
  # DXVK diagnostics — set DXVK_HUD to overlay info in top-left; set
  # DXVK_LOG_LEVEL to "info" or "debug" for stderr logs.  Both
  # commented by default; enable when investigating render bugs.
  local dxvk_env=(
    # "DXVK_HUD=fps,frametimes,api,compiler,memory,version,pipelines"
    # "DXVK_LOG_LEVEL=info"
    # "DXVK_LOG_PATH=$LAUNCHER_DIR"
  )
  # When --diag-gfx was passed, capture wine + MoltenVK stderr to a log
  # file so the SPIR-V/MSL shader dumps and MVK error stream are saved.
  # Detected via the MVK_CONFIG_DEBUG=1 entry in EXTRA_ENV.
  local capture_stderr=0
  for v in ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}; do
    if [[ "$v" == MVK_CONFIG_DEBUG=1 ]]; then
      capture_stderr=1
      say "Capturing wine + MoltenVK stderr to $LAUNCHER_DIR/game-stderr.log"
      : > "$LAUNCHER_DIR/game-stderr.log"
      break
    fi
  done

  # The "${arr[@]+"${arr[@]}"}" pattern survives `set -u` when the array is empty.
  if (( capture_stderr )); then
    # ── Diagnostic run (--diag / --diag-gfx) ───────────────────────────────
    # MoltenVK reports command-buffer faults as the opaque "Internal Error
    # (0x010c)" with no encoder info — Metal discards the encoder attribution
    # on a hard GPU memory fault.  The REAL reason (faulting address, engine,
    # "Submissions Ignored" cascade) is logged by the AGX / IOGPU driver to
    # the macOS unified log, but ONLY by those subsystems and it rolls off
    # within hours.  Stream just those subsystems to gpu-faults.log for the
    # life of this run so the fault can be named after the game exits.
    #
    # Unlike the normal path we do NOT exec here: this shell must survive the
    # game to stop the stream and summarize.  Everything is "|| true"-guarded
    # so a non-zero game exit (quit, crash, device-lost) still harvests logs.
    local gpu_log="$LAUNCHER_DIR/gpu-faults.log"
    : > "$gpu_log"
    say "Streaming kernel GPU/Metal faults → $gpu_log (stops when the game exits)"
    log stream --level info --style compact \
      --predicate '(eventMessage CONTAINS[c] "fault" OR eventMessage CONTAINS[c] "0000010c" OR eventMessage CONTAINS[c] "IOGPU" OR eventMessage CONTAINS[c] "AGX" OR eventMessage CONTAINS[c] "Submissions" OR eventMessage CONTAINS[c] "GPU restart" OR eventMessage CONTAINS[c] "Hang" OR eventMessage CONTAINS[c] "Discarded" OR eventMessage CONTAINS[c] "page fault") OR senderImagePath CONTAINS[c] "AGX" OR senderImagePath CONTAINS[c] "IOGPU"' \
      >> "$gpu_log" 2>&1 &
    local _gpulog_pid=$!
    say "Launching game (diagnostic; stderr → game-stderr.log)…  [Ctrl-C aborts]"
    # Background the game + wait, so Ctrl-C reaches the trap. A hung wine child
    # in the FOREGROUND swallows SIGINT and never returns (that's why Ctrl-C did
    # nothing on the exception-loop hang). On interrupt, force-kill the whole
    # wine tree via do_kill instead of leaving zombies.
    env ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
      ${dyld_env[@]+"${dyld_env[@]}"} \
      "${mvk_env[@]}" \
      ${dxvk_env[@]+"${dxvk_env[@]}"} \
      WINEPREFIX="$PREFIX_DIR" \
      WINEESYNC=1 \
      WINEDEBUG="${L4D2_WINEDEBUG:--all}" \
      "$WINE64" "$WIN_EXE" "${DEFAULT_GAME_ARGS[@]}" ${GAME_ARGS[@]+"${GAME_ARGS[@]}"} \
      2>>"$LAUNCHER_DIR/game-stderr.log" &
    local _game_pid=$!
    trap 'echo; warn "Interrupted — force-killing the wine tree…"; [[ -n "${_gpulog_pid:-}" ]] && kill "${_gpulog_pid}" 2>/dev/null; do_kill; exit 130' INT TERM
    wait "$_game_pid" 2>/dev/null || warn "game process exited non-zero"
    sleep 1   # let the streamer flush trailing fault lines
    [[ -n "${_gpulog_pid:-}" ]] && kill "${_gpulog_pid}" 2>/dev/null || true
    trap - INT TERM
    local _nf; _nf="$(grep -c . "$gpu_log" 2>/dev/null || true)"; _nf="${_nf:-0}"
    ok "Diagnostic logs saved:"
    ok "  • game-stderr.log  — MoltenVK encoder faults, DXVK info, MTL validation"
    ok "  • gpu-faults.log   — ${_nf} kernel AGX/IOGPU fault lines (the real 0x010c reason)"
    exit 0
  fi
  exec env ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    ${dyld_env[@]+"${dyld_env[@]}"} \
    "${mvk_env[@]}" \
    ${dxvk_env[@]+"${dxvk_env[@]}"} \
    WINEPREFIX="$PREFIX_DIR" \
    WINEESYNC=1 \
    WINEDEBUG=-all \
    "$WINE64" "$WIN_EXE" "${DEFAULT_GAME_ARGS[@]}" ${GAME_ARGS[@]+"${GAME_ARGS[@]}"}
}

# ─── Goldberg Steam emulator install ──────────────────────────────────────────
do_install_goldberg() {
  local bin="$GAME_DIR/bin"
  local backup="$bin/steam_api.dll.original"
  local settings="$bin/steam_settings"

  if [[ -f "$backup" ]]; then
    ok "Goldberg already installed (backup at $backup). Re-run --uninstall-goldberg to revert."
    return 0
  fi

  command -v unzip >/dev/null 2>&1 || die "unzip not found"

  say "Downloading Goldberg v0.2.5 (Mr_Goldberg, ~4.8 MB)…"
  local zip="$LAUNCHER_DIR/.goldberg.zip"
  curl -fL --progress-bar -o "$zip" \
    "https://gitlab.com/Mr_Goldberg/goldberg_emulator/uploads/2524331e488ec6399c396cf48bbe9903/Goldberg_Lan_Steam_Emu_v0.2.5.zip"

  say "Backing up original steam_api.dll → $backup"
  cp "$bin/steam_api.dll" "$backup"

  say "Installing Goldberg steam_api.dll"
  unzip -j -o "$zip" 'steam_api.dll' -d "$bin" >/dev/null
  rm -f "$zip"

  mkdir -p "$settings"
  printf '%s\n' "$STEAM_APPID" > "$settings/steam_appid.txt"
  cat > "$settings/configs.user.ini" <<'EOF'
[user::general]
account_name=Sam
language=english
ip_country=US
EOF
  ok "Goldberg installed. Run $0 to play."
}

do_uninstall_goldberg() {
  local bin="$GAME_DIR/bin"
  local backup="$bin/steam_api.dll.original"
  if [[ ! -f "$backup" ]]; then
    ok "Goldberg not installed; nothing to revert."
    return 0
  fi
  mv "$backup" "$bin/steam_api.dll"
  rm -rf "$bin/steam_settings"
  ok "Original steam_api.dll restored."
}

# ─── Custom bridge build ────────────────────────────────────────────────────
# When Goldberg-on-Wine fails (DllMain crash) we fall back to our own
# steam_api.dll that proxies the running native macOS Steam process via a
# small helper. See $LAUNCHER_DIR/bridge/ for sources.
do_build_bridge() {
  local b="$LAUNCHER_DIR/bridge"
  command -v i686-w64-mingw32-gcc >/dev/null 2>&1 \
    || die "Missing mingw-w64 i686 toolchain. brew install mingw-w64"
  command -v python3 >/dev/null 2>&1 \
    || die "Missing python3 (needed to regenerate vtables)"
  command -v clang >/dev/null 2>&1 \
    || die "Missing clang (needed to build the native helper)"

  say "Generating vtables…"
  ( cd "$b" && python3 gen_vtables.py > vtables_generated.c 2>err.log ) || die "gen_vtables.py failed"

  say "Compiling steam_api.dll (i686 mingw, no-CRT)…"
  ( cd "$b" && i686-w64-mingw32-gcc -shared -m32 -O2 \
        -nostdlib -nodefaultlibs -Wno-attributes -fno-stack-protector \
        -Wl,--enable-stdcall-fixup -Wl,--kill-at \
        -o steam_api.dll steam_api_wine.c steam_api.def \
        -lkernel32 -luser32 -lws2_32 ) || die "DLL build failed"

  say "Compiling native helper (arm64)…"
  ( cd "$b" && clang -arch arm64 -O2 -Wall -o steam_helper steam_helper.c ) \
      || die "Helper build failed"

  ok "Bridge built: $b/steam_api.dll  +  $b/steam_helper"
}

# Apply binary patches to game DLLs so the bridge can carry the game past the
# spots where our Steam stubs can't fully replicate real Mac Steam state.
do_install_bridge() {
  local b="$LAUNCHER_DIR/bridge"
  [[ -f "$b/steam_api.dll" && -f "$b/steam_helper" ]] || do_build_bridge

  local bin="$GAME_DIR/bin"
  local mm="$GAME_DIR/left4dead2/bin/matchmaking.dll"
  local cl="$GAME_DIR/left4dead2/bin/client.dll"

  # Back up the originals once, then replace steam_api.dll with our bridge.
  [[ -f "$bin/steam_api.dll.original" ]] || cp "$bin/steam_api.dll" "$bin/steam_api.dll.original"
  cp "$b/steam_api.dll" "$bin/steam_api.dll"
  ok "Installed bridge steam_api.dll (original backed up)"

  # matchmaking.dll: no longer patched. With SDK-1.53a headers in
  # bridge/sdk/ (the rev L4D2 was actually built against) the matchmaking
  # static instances initialise correctly and the +0x70C2 NULL-vptr crash
  # no longer triggers. Leave .original intact in case we need to revert.
  [[ -f "$mm.original" ]] || cp "$mm" "$mm.original"

  # client.dll +0x12CE0F: NOP out a HUD-iteration vtable[47] call whose
  # subject pointer (edi) ends up 2 instead of a real object. Bypassing
  # this lets the per-HUD init loop continue past one specific element.
  [[ -f "$cl.original" ]] || cp "$cl" "$cl.original"
  python3 - <<EOF
with open(r'''$cl''', 'r+b') as f:
    f.seek(0x12ce0f)
    cur = f.read(12)
    if cur != b'\x8b\x17\x8b\x82\xbc\x00\x00\x00\x8b\xcf\xff\xd0':
        pass
    else:
        f.seek(0x12ce0f); f.write(b'\x90' * 12)
EOF
  ok "Patched client.dll +0x12CE0F"

  # engine.dll +0x18F680: force this CRT-pointer-derefing function to
  # return false (xor al,al; ret). Its only callers handle a false return
  # gracefully; left alone it crashes the moment some thread reads an
  # un-decoded encoded pointer slot.
  local en="$bin/engine.dll"
  [[ -f "$en.original" ]] || cp "$en" "$en.original"
  python3 - <<EOF
with open(r'''$en''', 'r+b') as f:
    f.seek(0x18ea80)
    cur = f.read(3)
    if cur == b'\x55\x8b\xec':
        f.seek(0x18ea80); f.write(b'\x32\xc0\xc3')
EOF
  ok "Patched engine.dll +0x18F680"

  # engine.dll +0x284150: memmove thunk. The engine's level-load path calls
  # memmove with ABSURD argument values (count ~1 GB, source ptr in the 0xFE
  # range — both garbage from an uninitialized data structure that real Steam
  # would have populated). The memmove tries to `rep movsd` ~1 GB through
  # unmapped memory → SEGV in the reverse-copy tail.
  # We add a sanity check at the thunk: if count's high byte > 0x10
  # (count > ~268 MB), return 0 without copying. memmove's return value is
  # "dst" per spec but most callers don't check it; the caller's data is
  # left uninitialized but the engine continues.
  # Patch (16 bytes, fits exactly into the thunk's slot before the next thunk
  # at +0x284160). rel32 in the jmp is RVA-relative (target_RVA - next_RIP_RVA
  # = 0x30FCD0 - 0x28415C = 0x8BB74), which is preserved across Wine's PE
  # relocation since it's PC-relative.
  #   80 7c 24 0f 10   cmp byte [esp+0xf], 0x10  ; high byte of count arg
  #   77 05            ja  +5  (to early_ret)
  #   e9 74 bb 08 00   jmp engine+0x30FCD0       ; real memmove
  #   33 c0            xor eax, eax              ; early_ret: return 0
  #   c3               ret
  #   cc               int3 (pad)
  python3 - <<EOF
with open(r'''$en''', 'r+b') as f:
    f.seek(0x283550)
    cur = f.read(16)
    # Accept either original thunk or our bad first patch attempt (0x10 in jmp byte 4)
    is_orig = cur == b'\x55\x8b\xec\x5d\xe9\x77\xbb\x08\x00\xcc\xcc\xcc\xcc\xcc\xcc\xcc'
    is_bad  = cur == b'\x80\x7c\x24\x0f\x10\x77\x05\xe9\x74\xbb\x08\x10\x33\xc0\xc3\xcc'
    if is_orig or is_bad:
        f.seek(0x283550)
        f.write(b'\x80\x7c\x24\x0f\x10\x77\x05\xe9\x74\xbb\x08\x00\x33\xc0\xc3\xcc')
EOF
  ok "Patched engine.dll +0x284150 (memmove count sanity check)"

  # NOTE: tried patching engine.dll +0x1CC780 (the only caller of the
  # memmove that crashes during level load with garbage src=0xFEE95A3F) to
  # `xor eax, eax; ret`. That caused the engine to show a 329×114 error
  # dialog instead of reaching the menu — the function's return value IS
  # actually used by downstream code. Not patching it; instead leaving the
  # memmove crash as the next problem to solve in a more surgical way.
  python3 - <<EOF
with open(r'''$en''', 'r+b') as f:
    f.seek(0x1cbb80)
    cur = f.read(3)
    if cur == b'\x33\xc0\xc3':
        # restore original push ebp; mov ebp, esp
        f.seek(0x1cbb80); f.write(b'\x55\x8b\xec')
EOF

  # matchmaking.dll +0xC070: iteration loop that walks registered Steam
  # callbacks and calls each one's vtable[0] (the Run() method). For
  # callback objects whose memory has been freed/corrupted (which happens
  # in our bridge-Steam-stubs world since we don't deliver real Steam
  # callbacks), vtable[0] ends up pointing to a heap address and the call
  # crashes with EXECUTE access violation. Forcing this iterator to return
  # false skips the dispatch entirely — the game's matchmaking still
  # initializes and main menu still renders, we just don't fire
  # SteamCallback handlers from this loop.
  local mm="$GAME_DIR/left4dead2/bin/matchmaking.dll"
  [[ -f "$mm.original" ]] || cp "$mm" "$mm.original"
  python3 - <<EOF
with open(r'''$mm''', 'r+b') as f:
    f.seek(0xB470)
    cur = f.read(5)
    if cur == b'\x55\x8b\xec\x83\x79':
        f.seek(0xB470); f.write(b'\x32\xc0\xc2\x04\x00')
    # else already patched or unknown
EOF
  ok "Patched matchmaking.dll +0xC070 (callback iterator → no-op)"

  # dxvk_d3d9.dll: install our source-patched DXVK 1.10.3 build
  # (./dxvk-build/dxvk_d3d9.dll) CLEAN.  All Apple-Silicon fixes live in the
  # source (dxvk-build/shadow-sampler-workaround.patch): software depth-
  # compare shadow sampling + the pushConstSize fix + mingw build fixes.
  # geometryShader / shaderCullDistance need no handling here — our patched
  # MoltenVK advertises them as unavailable, so DXVK never requests them and
  # vkCreateDevice succeeds.
  #
  # IMPORTANT: do NOT byte-patch this DLL.  The old blind-signature patch
  # (NOP `movl $1,0x18(%edx)` + `movq`→`movd`) was written for L4D2's bundled
  # DXVK 1.9.1a.  On our source-built 1.10.3 those generic instruction
  # patterns recur throughout the 14 MB binary, so the scan matched and
  # corrupted unrelated code at arbitrary offsets — reintroducing per-frame
  # MTLCommandBufferErrorInternal (0x010c) GPU faults.  We build DXVK from
  # source now, so install it verbatim and unconditionally (idempotent).
  local dxvk="$bin/dxvk_d3d9.dll"
  local prebuilt_dxvk="$LAUNCHER_DIR/dxvk-build/dxvk_d3d9.dll"
  if [[ -f "$prebuilt_dxvk" ]]; then
    [[ -f "$dxvk.original" ]] || cp "$dxvk" "$dxvk.original"
    cp "$prebuilt_dxvk" "$dxvk"
    ok "Installed source-built DXVK 1.10.3 (verbatim, no byte-patch)"
  fi

  # dxvk.conf: configure DXVK for L4D2. d3d9.forceSamplerTypeSpecConstants
  # encodes the sampler type as a SPIR-V spec constant, which can help
  # MoltenVK's SPIR-V→MSL conversion avoid the "two textures at the same
  # binding" error when the same texture is used as both regular and shadow.
  # CRITICAL: DXVK searches for dxvk.conf in the process's CURRENT WORKING
  # DIRECTORY (the game ROOT, where left4dead2.exe runs), NOT in bin/ where the
  # DLL lives.  We launch with `cd "$GAME_DIR"`, so the config MUST be written
  # to the game root or DXVK silently ignores it — which it did for the entire
  # project history (the DXVK log never printed "Found config file:" and every
  # option ran on stock defaults, including the host-visible memory options that
  # keep a 32-bit game under its address-space limit).  Write to the root; also
  # drop a copy in bin/ for reference.
  cat > "$GAME_DIR/dxvk.conf" <<'DXVK_CONF'
# DXVK 1.10.3 config for L4D2 — MINIMAL BY DESIGN (pure DXVK defaults).
#
# PERFORMANCE LESSON (2026-05-31): L4D2 runs great on Apple Silicon on pure
# defaults — that's how the good pre-git build behaved, and it's how the macOS
# community runs Source games.  Every Apple-Silicon RENDER fix is compiled into
# our dxvk-build/ DLL, NOT set here.  A previous pass added five non-standard
# memory options (allowDirectBufferMapping=False, deviceLocalConstantBuffers,
# evictManagedOnUnlock, maxAvailableMemory, maxChunkSize) to chase a "32-bit
# memory wall" that proved to be a MISDIAGNOSIS — vmmap showed ~2.1 GB of the
# 32-bit space FREE at the load fault; the real cause is a GPU command-buffer
# fault (0x010c), not address-space exhaustion.  Those options tanked perf and
# stability, so they are REMOVED.
#
# This file is read from the game ROOT (the process CWD), so anything set here
# REALLY applies — unlike the 1.x-era bin/ copy that DXVK silently ignored.
#
# NOTE (2026-06-02): forceSamplerTypeSpecConstants = True was tried here and
# broke 493 graphics pipelines on this 1.10.3 build (incompatible with the
# shadow-sampler patch) — do NOT re-add it.  generalHazards is already DXVK's
# default on non-NVIDIA (Apple), so the flashlight shadow-depth barrier is on
# without setting it.  Keep this file at pure defaults.
DXVK_CONF
  cp -f "$GAME_DIR/dxvk.conf" "$bin/dxvk.conf" 2>/dev/null || true
  ok "Wrote dxvk.conf to game root (DXVK CWD search) + bin/ (reference)"

  # Source engine looks for steam.dll and GameOverlayRenderer.dll alongside
  # left4dead2.exe — without them the engine silently degrades. Copy from the
  # Steam-for-Windows install in the wine prefix if available.
  local prefix_steam="$PREFIX_DIR/drive_c/Program Files (x86)/Steam"
  if [[ -f "$prefix_steam/Steam.dll" && ! -f "$bin/steam.dll" ]]; then
    cp "$prefix_steam/Steam.dll" "$bin/steam.dll" && ok "Copied steam.dll"
  fi
  if [[ -f "$prefix_steam/GameOverlayRenderer.dll" && ! -f "$bin/GameOverlayRenderer.dll" ]]; then
    cp "$prefix_steam/GameOverlayRenderer.dll" "$bin/" && ok "Copied GameOverlayRenderer.dll"
  fi
}

# Start the native helper (binds to 127.0.0.1:54550 and proxies to the
# running native Mac Steam dylib). Idempotent.
do_start_helper() {
  local b="$LAUNCHER_DIR/bridge"
  if pgrep -f "$b/steam_helper" >/dev/null 2>&1; then
    ok "Helper already running"
    return 0
  fi
  [[ -x "$b/steam_helper" ]] || die "Helper missing — run --build-bridge first"
  pgrep -fl 'steam_osx|Steam.AppBundle' >/dev/null 2>&1 \
    || warn "Native Steam isn't running. Sign in to Steam.app first or RPCs will fail."
  # If a helper is already listening on the RPC port, reuse it.
  if lsof -nP -iTCP:54550 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
    ok "Helper already listening on 127.0.0.1:54550"
    return 0
  fi
  # Try up to ~5 seconds for the helper's socket to come up. SO_REUSEADDR
  # is set, but the previous instance's TIME_WAIT can still briefly block.
  (cd "$b" && ./steam_helper > "$LAUNCHER_DIR/helper.log" 2>&1 &)
  local tries=0
  while (( tries < 10 )); do
    if lsof -nP -iTCP:54550 -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
      ok "Helper started (pid $(pgrep -f $b/steam_helper | head -1))"
      return 0
    fi
    sleep 0.5; tries=$(( tries + 1 ))
  done
  die "Helper failed to start — check $LAUNCHER_DIR/helper.log"
}

do_bridge() {
  do_build_bridge
  do_install_bridge
  do_start_helper
  ok "Bridge ready. Run $0 (no args) to launch."
}

# Restore state mutated by a --wined3d run (registered as its EXIT trap): un-stash
# L4D2's bundled DXVK and put video.txt's mat_queue_mode back to -1 (multicore).
# C1: this is what keeps a wined3d run's serialised-D3D9 state from leaking onto
# the normal DXVK path.  (do_launch's assert_max_settings also re-asserts -1
# defensively, in case a wined3d run is hard-killed before this trap fires.)
_wined3d_restore() {
  local dxvk="$GAME_DIR/bin/dxvk_d3d9.dll"
  local stashed="$GAME_DIR/bin/dxvk_d3d9.dll.disabled-for-wined3d"
  local vid="$GAME_DIR/left4dead2/cfg/video.txt"
  [[ -f "$stashed" ]] && mv "$stashed" "$dxvk" && ok "Restored dxvk_d3d9.dll"
  [[ -f "$vid" ]] && \
    perl -i -pe 's/("setting\.mat_queue_mode"\s+)"-?\d+"/${1}"-1"/' "$vid" && \
    ok "Restored video.txt mat_queue_mode -1 (multicore)"
  return 0
}

# Launch via Wine's native D3D9 instead of L4D2's bundled DXVK.
#
# Path: L4D2.exe → Wine's d3d9.dll (wined3d) → either OpenGL → macOS
# OpenGL → Metal, OR (Wine 9+) Vulkan → MoltenVK → Metal.  This bypasses
# the shadow-sampler-workaround DXVK patch entirely — if the black-world
# bug is in that interaction with MoltenVK's null-descriptor fallback,
# this path renders correctly.  If wined3d itself has the same issue,
# we'll know the bug is downstream in MoltenVK.
do_launch_wined3d() {
  ensure_prefix
  ensure_appid
  do_install_bridge
  do_start_helper

  local dxvk="$GAME_DIR/bin/dxvk_d3d9.dll"
  local stashed="$GAME_DIR/bin/dxvk_d3d9.dll.disabled-for-wined3d"
  local l4d2_cfg="$GAME_DIR/left4dead2/cfg"

  # C1 — serialisation for wined3d is scoped to THIS run only.  Restore-on-exit
  # un-stashes DXVK and puts video.txt's mat_queue_mode back to -1 (multicore),
  # so a wined3d run never persists its serialised-D3D9 state onto the normal
  # DXVK path.  Registered BEFORE we mutate anything, so even a mid-setup Ctrl-C
  # reverts.  (See _wined3d_restore above.)
  trap _wined3d_restore EXIT

  # Stash L4D2's bundled DXVK so Wine's d3d9.dll wins the lookup.  The game's
  # loader specifically searches for dxvk_d3d9.dll first; renaming forces it to
  # fall back to system d3d9.dll → wined3d.  Un-stashed by the trap on exit.
  if [[ -f "$dxvk" ]]; then
    mv "$dxvk" "$stashed"
    say "Stashed dxvk_d3d9.dll → forcing wined3d path"
  fi

  # Force the synchronous material system FOR THIS RUN ONLY. Source's multicore
  # renderer (mat_queue_mode -1 → threaded on a many-core M4) fires D3D9 calls
  # from multiple threads; wined3d crashes under that concurrency (access
  # violations in wined3d.dll across threads → tier0 0xc0000417 fatal).
  # video.txt's "setting.mat_queue_mode" LATCHES at material-system init and
  # overrides config.cfg / autoexec / launch-arg, so it must read 0 during a
  # wined3d run — we flip it to 0 here and the trap reverts it to -1 on exit.
  # We deliberately do NOT write a persistent autoexec.cfg: that file
  # (mat_queue_mode 0) was the C1 "multicore landmine" — the engine exec'd it on
  # EVERY launch, including DXVK, silently killing multicore.  The
  # +mat_queue_mode 0 launch arg below already covers this single run.
  if [[ -d "$l4d2_cfg" ]]; then
    [[ -f "$l4d2_cfg/video.txt" ]] && \
      perl -i -pe 's/("setting\.mat_queue_mode"\s+)"-?\d+"/${1}"0"/' "$l4d2_cfg/video.txt"
    # Belt-and-suspenders: clear any stale landmine autoexec.cfg from older runs.
    [[ -f "$l4d2_cfg/autoexec.cfg" ]] && \
      grep -q "L4D2-launcher: serialize D3D9" "$l4d2_cfg/autoexec.cfg" && \
      rm -f "$l4d2_cfg/autoexec.cfg"
  fi

  cd "$GAME_DIR"
  say "Launching L4D2 via wined3d (no DXVK, no -vulkan)…"
  local dyld_env=()
  [[ -n "$WINE_DYLD" ]] && dyld_env=("DYLD_FALLBACK_LIBRARY_PATH=$WINE_DYLD")
  local mvk_env=(
    "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1"
    "MVK_ALLOW_METAL_FENCES=1"
    "MVK_CONFIG_RESUME_LOST_DEVICE=1"
    "MVK_CONFIG_USE_MTLHEAP=1"
    "MVK_CONFIG_PREALLOCATE_DESCRIPTORS=1"
    "MVK_CONFIG_USE_COMMAND_POOLING=1"
    "MVK_CONFIG_LOG_LEVEL=1"
  )
  # Set the wined3d renderer backend via the registry.  Wine 11 supports
  # "vulkan" (translates D3D9 → Vulkan → MoltenVK → Metal — newer, more
  # stable on Apple Silicon since it bypasses the deprecated Apple GL
  # stack) or "gl" (legacy, more compatible but uses Apple OpenGL which
  # has been the source of post-load crashes after ~minutes of play).
  local wined3d_renderer="${WINED3D_RENDERER:-vulkan}"
  say "wined3d renderer: $wined3d_renderer"
  # CRITICAL: this MUST set WINEPREFIX to the game's prefix.  Without it the
  # reg add lands in the default ~/.wine, the game (which runs in $PREFIX_DIR)
  # never sees renderer=vulkan, and wined3d silently falls back to the OpenGL
  # backend — Apple's deprecated GL 4.1, which is missing extensions Source's
  # shaders need (GL_EXT_texture_array, GL_ARB_uniform_buffer_object,
  # GL_ARB_draw_instanced) → broken shaders + the c0000005/tier0 crash on the
  # c1m1 intro.  The Vulkan backend (wined3d → vkd3d-shader → MoltenVK) has
  # those features and avoids Apple GL entirely.
  WINEPREFIX="$PREFIX_DIR" ${WINE_DYLD:+DYLD_FALLBACK_LIBRARY_PATH="$WINE_DYLD"} \
    "$WINE64" reg add "HKEY_CURRENT_USER\\Software\\Wine\\Direct3D" \
    /v renderer /t REG_SZ /d "$wined3d_renderer" /f 2>/dev/null || true

  # Capture crash dumps + SEH activity so we get a real stack trace if the
  # game crashes (the empty backtrace.txt was due to no SEH logging being
  # active when the AV fired).
  : > "$LAUNCHER_DIR/wined3d-stderr.log"

  # WINEDLLOVERRIDES=d3d9=b → use Wine's built-in d3d9 (wined3d), not native.
  env ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
    ${dyld_env[@]+"${dyld_env[@]}"} \
    "${mvk_env[@]}" \
    WINEPREFIX="$PREFIX_DIR" \
    WINEESYNC=1 \
    WINEDEBUG="${WINEDEBUG:-fixme-all,err+all}" \
    WINEDLLOVERRIDES="d3d9=b;gameoverlayrenderer=" \
    "$WINE64" "$WIN_EXE" -novid -condebug +mat_queue_mode 0 +cl_showfps 1 ${GAME_ARGS[@]+"${GAME_ARGS[@]}"} \
    2>>"$LAUNCHER_DIR/wined3d-stderr.log"
  # Trap restores dxvk_d3d9.dll on exit.
}

# ─── Main ─────────────────────────────────────────────────────────────────────
preflight
ensure_gptk
ensure_patched_moltenvk

case "$ACTION" in
  setup)               ensure_prefix; ok "Setup complete — run again with no args to play." ;;
  reset)               do_reset ;;
  kill)                do_kill ;;
  install-goldberg)    do_install_goldberg ;;
  uninstall-goldberg)  do_uninstall_goldberg ;;
  install-steam)       do_install_steam ;;
  steam)               do_steam ;;
  link-game)           do_link_game ;;
  winecfg)             do_winecfg ;;
  shell)               do_shell ;;
  build-bridge)        do_build_bridge ;;
  install-bridge)      do_install_bridge ;;
  wined3d)             do_launch_wined3d ;;
  bridge)              do_bridge ;;
  launch)              do_launch ;;
  *)                   die "Unknown action: $ACTION" ;;
esac
