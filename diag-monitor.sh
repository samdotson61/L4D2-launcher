#!/bin/bash
# $1=label, $2=extra launch args. Uses --diag (writes game-stderr.log with [mvk-*] faults + streams
# gpu-faults.log; no heavy Metal validation). Reliable fault signal = real 0000010c count + TIMING.
LABEL="${1:-test}"
LD="/Users/samdotson/L4D2-launcher"
GD="/Users/samdotson/Library/Application Support/Steam/steamapps/common/Left 4 Dead 2/left4dead2"
OUT=/tmp/diag-result.txt
: > "$OUT"; : > "$LD/game-stderr.log" 2>/dev/null; : > "$LD/gpu-faults.log" 2>/dev/null; : > "$GD/console.log" 2>/dev/null
"$LD/play-l4d2.sh" --diag -- +map c1m1_hotel -condebug ${2:-} > /tmp/diag-launch.log 2>&1 &
LPID=$!
START=$SECONDS; INGAME_AT=0; FAULT_AT=0
while :; do
  el=$((SECONDS-START))
  if [ $INGAME_AT -eq 0 ] && grep -qi "Reserved Wanderers\|NextBot tickrate\|Initiating Reserved" "$GD/console.log" 2>/dev/null; then INGAME_AT=$el; fi
  nf=$(grep -c "0000010c" "$LD/game-stderr.log" 2>/dev/null | tr -d ' \n'); nf=${nf:-0}
  if [ "$nf" -gt 0 ] && [ $FAULT_AT -eq 0 ]; then FAULT_AT=$el; fi
  if [ $FAULT_AT -gt 0 ] && [ $((el-FAULT_AT)) -ge 8 ]; then break; fi
  if ! kill -0 $LPID 2>/dev/null; then break; fi
  if [ $el -ge 90 ]; then break; fi
  sleep 2
done
EL=$((SECONDS-START))
NF=$(grep -c "0000010c" "$LD/game-stderr.log" 2>/dev/null | tr -d ' \n'); NF=${NF:-0}
HDR=$(grep -i "HDR Enabled\|HDR Disabled" "$GD/console.log" 2>/dev/null | tail -1)
{
  echo "=== $LABEL ==="
  echo "elapsed=${EL}s  ingame_at=${INGAME_AT}s  fault_at=${FAULT_AT}s  faults(0000010c)=$NF"
  echo "HDR: ${HDR:-<none>}"
  echo "--- perf (fps) ---"; grep -iE "avg FPS|frame interval" "$LD/game-stderr.log" 2>/dev/null | tail -3
  echo "--- fault context (timing tells null-descriptor[load] vs occlusion[~38s]) ---"
  grep -iE "0000010c|allocated at fault|DummyNull|out of bounds|no encoder" "$LD/game-stderr.log" 2>/dev/null | tail -5
  if [ "$NF" -gt 0 ]; then echo "VERDICT: FAULTS x$NF at ${FAULT_AT}s"; elif [ $INGAME_AT -gt 0 ]; then echo "VERDICT: *** NO FAULTS, reached in-game (${INGAME_AT}s), survived ${EL}s ***"; else echo "VERDICT: no fault but never confirmed in-game"; fi
} | tee -a "$OUT"
# (pkill pattern is the real process name — the old "L4D2.exe" was case-wrong and
#  never matched left4dead2.exe; cleanup silently relied on the launcher's exit trap)
kill $LPID 2>/dev/null; pkill -f "left4dead2.exe" 2>/dev/null; pkill -f "steam_helper" 2>/dev/null; sleep 2
echo "killed" >> "$OUT"
