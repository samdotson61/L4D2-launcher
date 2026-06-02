#!/bin/bash
# Run build-deps.sh moltenvk (re-clone + re-fetch deps + build v1.4.1 + our patch) with a hang-guard
# (Xcode SWBBuildService deadlocked pre-reboot; this aborts if it wedges again instead of stalling).
LD=/Users/samdotson/L4D2-launcher
cd "$LD" || exit 1
bash build-deps.sh moltenvk --force > /tmp/builddeps.log 2>&1 &
BPID=$!
clang_cpu() { ps -axo time,comm 2>/dev/null | grep -iE "clang|swift-frontend|cc1" | grep -v grep | awk -F: '{s+=$1*60+$2} END{print s+0}'; }
stall=0
while kill -0 $BPID 2>/dev/null; do
  c1=$(clang_cpu); sleep 40; c2=$(clang_cpu)
  if pgrep -f "xcodebuild" >/dev/null 2>&1 && awk "BEGIN{exit !(${c2:-0} <= ${c1:-0} + 1)}"; then
    stall=$((stall+1))
    if [ $stall -ge 2 ]; then
      echo "HUNG: xcodebuild active but compiler CPU-time stalled (${c1}->${c2}s x2 windows)."
      kill -9 $BPID 2>/dev/null; pkill -9 -f xcodebuild 2>/dev/null; pkill -9 -f SWBBuildService 2>/dev/null
      exit 9
    fi
  else stall=0; fi
done
wait $BPID; rc=$?
echo "=== build-deps rc=$rc ==="; tail -6 /tmp/builddeps.log
[ $rc -eq 0 ] && echo "MVK v1.4.1+patches REBUILT (deps cached for the 1.4.0 step)"
