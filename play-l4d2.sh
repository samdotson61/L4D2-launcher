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
# `+toggleconsole` would auto-open it (which was rendering as an overlay
# on top of the main menu).
DEFAULT_GAME_ARGS=(-novid -vulkan)

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
  play-l4d2.sh --diag-gfx          Verbose DXVK + MoltenVK shader/descriptor
                                   logging (writes dxvk_*.log alongside game.log)
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
    --diag-gfx)
      # Verbose DXVK + MoltenVK diagnostics for investigating black-world
      # / shader / descriptor binding bugs.  Logs to game.log; DXVK HUD
      # overlay shows pipeline + compiler stats top-left in-game.
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

do_launch() {
  ensure_prefix
  ensure_appid

  # Make sure the bridge + binary patches + helper are in place. Each step
  # is idempotent so re-running just no-ops if everything's already set up.
  do_install_bridge
  do_start_helper

  cd "$GAME_DIR"

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
    # L4D2-launcher: Metal Argument Buffers are default-on in MoltenVK 1.2.11+
    # but cause confirmed visual + perf regressions in DXVK D3D9 (MoltenVK#2530,
    # #2146; id-Tech doom3-bfg also disables them on macOS).  Setting 0 forces
    # the discrete-descriptor binding path which is what Source's HDR
    # composite expects.
    "MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0"
    "MVK_ALLOW_METAL_FENCES=1"
    "MVK_CONFIG_RESUME_LOST_DEVICE=1"
    "MVK_CONFIG_USE_MTLHEAP=1"
    "MVK_CONFIG_PREALLOCATE_DESCRIPTORS=1"
    "MVK_CONFIG_USE_COMMAND_POOLING=1"
    "MVK_CONFIG_LOG_LEVEL=3"
    "MVK_CONFIG_DEBUG=0"
    # Disable shader fast-math: Source's tonemap exposure curves can hit
    # NaN/Inf paths that AGX faults on under fast-math.
    "MVK_CONFIG_FAST_MATH_ENABLED=0"
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
    exec env ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} \
      ${dyld_env[@]+"${dyld_env[@]}"} \
      "${mvk_env[@]}" \
      ${dxvk_env[@]+"${dxvk_env[@]}"} \
      WINEPREFIX="$PREFIX_DIR" \
      WINEESYNC=1 \
      WINEDEBUG=-all \
      "$WINE64" "$WIN_EXE" "${DEFAULT_GAME_ARGS[@]}" ${GAME_ARGS[@]+"${GAME_ARGS[@]}"} \
      2>>"$LAUNCHER_DIR/game-stderr.log"
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

  # dxvk_d3d9.dll: replace L4D2's bundled DXVK 1.9.1a with our patched
  # DXVK 1.10.3 build (./dxvk-build/dxvk_d3d9.dll). Two problems with the
  # stock DXVK on Apple Silicon, both solved by the build's source patches:
  #
  # 1) DXVK requests geometryShader + shaderCullDistance VkPhysicalDevice
  #    features that MoltenVK on Apple Silicon doesn't expose. Patched DXVK
  #    skips these flags so vkCreateDevice succeeds.
  # 2) DXVK's DXSO compiler binds the depth-comparison sampler variant to
  #    the same descriptor slot as the regular sampler. MoltenVK's
  #    SPIRV-Cross then emits two MSL declarations at the same [[texture]]
  #    slot which Metal rejects. The patch in
  #    dxvk-build/shadow-sampler-workaround.patch makes the depth variant
  #    alias the color variant (same SPIR-V variable) and rewrites the
  #    depth code path to sample as color — no MSL collision, no shadow
  #    comparison (game just gets a regular sample on shadow shaders).
  #
  # We also keep the byte-signature patch path as a fallback for stock DXVK.
  local dxvk="$bin/dxvk_d3d9.dll"
  local prebuilt_dxvk="$LAUNCHER_DIR/dxvk-build/dxvk_d3d9.dll"
  if [[ -f "$prebuilt_dxvk" ]]; then
    [[ -f "$dxvk.original" ]] || cp "$dxvk" "$dxvk.original"
    # Check if installed DXVK is already our build (by size)
    local prebuilt_size=$(stat -f %z "$prebuilt_dxvk" 2>/dev/null)
    local installed_size=$(stat -f %z "$dxvk" 2>/dev/null || echo 0)
    if [[ "$prebuilt_size" != "$installed_size" ]]; then
      cp "$prebuilt_dxvk" "$dxvk"
      ok "Installed patched DXVK 1.10.3 (shadow-sampler + feature workarounds)"
    fi
  fi
  if [[ -f "$dxvk" ]]; then
    [[ -f "$dxvk.original" ]] || cp "$dxvk" "$dxvk.original"
    python3 - <<EOF
import struct
path = r'''$dxvk'''
with open(path, 'rb') as f:
    data = bytearray(f.read())

# Heuristic: scan for both patch signatures, patch wherever they appear.
geo_sig = b'\xc7\x42\x18\x01\x00\x00\x00'   # movl \$0x1, 0x18(%edx)
mvq_sig = b'\x66\x0f\xd6\x82\x9c\x00\x00\x00'  # movq %xmm0, 0x9c(%edx)
geo_done = False
mvq_done = False
i = 0
while i < len(data) - 8:
    if not geo_done and data[i:i+7] == geo_sig:
        data[i:i+7] = b'\x90' * 7
        print(f'  [dxvk] NOPed geometryShader=1 write at file +0x{i:X}')
        geo_done = True
        i += 7
        continue
    if not mvq_done and data[i:i+8] == mvq_sig:
        data[i+2] = 0x7e  # movq -> movd; writes only low dword
        print(f'  [dxvk] movq->movd at file +0x{i+2:X} (shaderCullDistance disabled)')
        mvq_done = True
        i += 8
        continue
    i += 1
if not geo_done: print('  [dxvk] geometryShader site already patched or not present')
if not mvq_done: print('  [dxvk] movq site already patched or not present')
with open(path, 'wb') as f:
    f.write(data)
EOF
    ok "Patched dxvk_d3d9.dll (geometryShader + shaderCullDistance disabled)"
  fi

  # dxvk.conf: configure DXVK for L4D2. d3d9.forceSamplerTypeSpecConstants
  # encodes the sampler type as a SPIR-V spec constant, which can help
  # MoltenVK's SPIR-V→MSL conversion avoid the "two textures at the same
  # binding" error when the same texture is used as both regular and shadow.
  cat > "$bin/dxvk.conf" <<'DXVK_CONF'
# DXVK config — see https://github.com/doitsujin/dxvk/blob/master/dxvk.conf
# Tuned for L4D2 on Whisky-Wine 11 + patched DXVK 1.10.3 + patched MoltenVK 1.4.1.
# NOTE: this file is the source of truth — play-l4d2.sh regenerates the
# game-dir dxvk.conf from this heredoc on every --install-bridge, so edit
# HERE, not the copy in the game's bin/.

# Sampler type as SPIR-V spec constant → MoltenVK avoids the "two
# textures at the same binding" error when one is used as shadow.
d3d9.forceSamplerTypeSpecConstants = True
# Source shaders rely on pow(0, 0) == 0 etc.
d3d9.strictPow = False

# ── Per-frame MTLCommandBufferErrorInternal (0x010c) mitigations ───────────
# Symptom: every vkQueueSubmit for the MAIN 3D scene faults with Internal
# Error 0x010c; HUD/glow/overlay passes don't.  MVK_CONFIG_RESUME_LOST_DEVICE
# recovers each frame → the world flickers black (and the callback backlog
# starves matchmaking → "Searching for Games" hangs).
#
# Leading cause: Source self-samples render targets (water/refraction/
# _rt_FullFrameFB); DXVK auto-enables generalHazards on non-NVIDIA GPUs and
# inserts an attachment-feedback-loop barrier MoltenVK can't express on Apple
# GPUs → only the self-sampling 3D submit faults.  Skip that barrier:
d3d9.generalHazards = False
# Promote near-full partial clears to full loadOp=CLEAR (AGX dislikes
# in-renderpass vkCmdClearAttachments; helps the viewmodel depth-clear pass).
d3d9.lenientClear = True
# Create VkSurface on first Present — sidesteps swapchain/RT setup faults.
d3d9.deferSurfaceCreation = True

# ── Pipeline cache / latency ─────────────────────────────────────────────
dxvk.maxChunkSize = 0
dxvk.numCompilerThreads = 0
dxvk.enableStateCache = True
# At most 1 in-flight frame so a faulting cmdbuf can't overlap/cascade.
d3d9.maxFrameLatency = 1
d3d9.invariantPosition = False
d3d9.allowDirectBufferMapping = True
DXVK_CONF
  ok "Wrote dxvk.conf"

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
  # Stash L4D2's bundled DXVK so Wine's d3d9.dll wins the lookup.  The
  # game's loader specifically searches for dxvk_d3d9.dll first; renaming
  # forces it to fall back to system d3d9.dll → wined3d.  Restored when
  # this script's shell exits via the trap below.
  if [[ -f "$dxvk" ]]; then
    mv "$dxvk" "$stashed"
    say "Stashed dxvk_d3d9.dll → forcing wined3d path"
    trap "[[ -f '$stashed' ]] && mv '$stashed' '$dxvk'; ok 'Restored dxvk_d3d9.dll'" EXIT
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
    WINEDEBUG=+seh,err+all,warn+wined3d \
    WINEDLLOVERRIDES="d3d9=b" \
    "$WINE64" "$WIN_EXE" -novid -console ${GAME_ARGS[@]+"${GAME_ARGS[@]}"} \
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
