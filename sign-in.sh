#!/usr/bin/env bash
# sign-in.sh — interactive CLI login to Steam-for-Windows (no UI needed)
#
# The Steam client's CEF/Chromium-based UI crashes on Wine 7.7 (which is
# what GPTK 3.0-3 ships). The GUI is unrecoverable in this prefix, but the
# command-line `-login` flag bypasses the UI entirely. After a successful
# login the prefix gets a `loginusers.vdf` with a persistent "remember me"
# token, and subsequent silent starts auto-login.
#
# Your password is read with `read -s` (no echo) and passed to Steam via a
# spawned process. It is NOT written to your shell history or to any file.
set -euo pipefail

WINE64="$HOME/L4D2-launcher/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
PREFIX="$HOME/L4D2-launcher/prefix"
STEAM_EXE="$PREFIX/drive_c/Program Files (x86)/Steam/steam.exe"

# Kill any leftover Steam
pkill -9 -f "L4D2-launcher.*steam.exe" 2>/dev/null || true
sleep 2

printf '\033[34m==>\033[0m Steam-for-Windows CLI sign-in\n'
printf 'Steam username: '
read -r STEAM_USER
[[ -z "$STEAM_USER" ]] && { echo "no username given, aborting" >&2; exit 1; }
printf 'Steam password (hidden): '
read -rs STEAM_PASS
printf '\n'
[[ -z "$STEAM_PASS" ]] && { echo "no password given, aborting" >&2; exit 1; }

printf '\033[34m==>\033[0m Signing in… (Steam may prompt for a 2FA code, watch this terminal)\n'

# Start Steam with -login. Steam will:
#  - Authenticate
#  - Prompt for Steam Guard 2FA code on stdin if needed
#  - Write loginusers.vdf
#  - Keep running in the background (signals OK)
WINEPREFIX="$PREFIX" WINEESYNC=1 \
  "$WINE64" "$STEAM_EXE" -login "$STEAM_USER" "$STEAM_PASS" -silent -no-cef-sandbox \
  >"$HOME/L4D2-launcher/steam-login.log" 2>&1 &
STEAM_PID=$!
disown 2>/dev/null || true

# Clear the password from this script's memory ASAP
STEAM_PASS=""

LOGINUSERS="$PREFIX/drive_c/Program Files (x86)/Steam/config/loginusers.vdf"
printf 'Waiting up to 90s for loginusers.vdf to appear…\n'
for i in $(seq 1 90); do
  if [[ -f "$LOGINUSERS" ]]; then
    printf '\033[32m ok\033[0m Signed in as %s\n' "$STEAM_USER"
    printf '\033[34m==>\033[0m Giving Steam 5s to finish setting up its IPC pipe…\n'
    sleep 5
    printf '\033[34m==>\033[0m Launching Left 4 Dead 2.\n\n'
    exec "$HOME/L4D2-launcher/play-l4d2.sh"
  fi
  sleep 1
done

printf '\033[33m !!\033[0m Sign-in timed out. Check the log:\n  tail -40 ~/L4D2-launcher/steam-login.log\n'
printf '   Common causes: wrong password, Steam Guard 2FA code needed,\n'
printf '   or Steam is still booting. Look at the log to see what Steam wants.\n'
exit 1
