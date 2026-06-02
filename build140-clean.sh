#!/bin/bash
# Build clean v1.4.0 (no patches) on the now-cached deps, deploy, for fast occlusion-fix validation.
SRC=/tmp/l4d2-deps-build/MoltenVK; LD=/Users/samdotson/L4D2-launcher
cd "$SRC" || exit 1
git reset --hard 2>/dev/null | tail -1
git fetch --depth 1 origin refs/tags/v1.4.0:refs/tags/v1.4.0 2>&1 | tail -1
git checkout v1.4.0 2>&1 | tail -1
echo "HEAD: $(git describe --tags 2>/dev/null)  deps: $(ls External/build/Release/*.xcframework 2>/dev/null | wc -l | tr -d ' ')"
make macos > /tmp/mvk140c.log 2>&1 &
MKPID=$!
clang_cpu(){ ps -axo time,comm 2>/dev/null|grep -iE "clang|swift-frontend|cc1"|grep -v grep|awk -F: '{s+=$1*60+$2}END{print s+0}'; }
stall=0
while kill -0 $MKPID 2>/dev/null; do
  a=$(clang_cpu); sleep 35; b=$(clang_cpu)
  if pgrep -f xcodebuild >/dev/null 2>&1 && awk "BEGIN{exit !(${b:-0}<=${a:-0}+1)}"; then
    stall=$((stall+1)); [ $stall -ge 2 ] && { echo "HUNG"; kill -9 $MKPID 2>/dev/null; pkill -9 -f xcodebuild 2>/dev/null; pkill -9 -f SWBBuildService 2>/dev/null; exit 9; }
  else stall=0; fi
done
wait $MKPID; rc=$?
[ $rc -eq 0 ] || { echo "BUILD FAIL rc=$rc"; tail -12 /tmp/mvk140c.log; exit 1; }
BUILT="Package/Release/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
[ -f "$BUILT" ] || { echo "no dylib"; exit 1; }
WL="$LD/whisky-wine/Libraries/Wine/lib/libMoltenVK.dylib"
cp "$BUILT" "$LD/moltenvk-build/libMoltenVK.dylib.140clean"; cp "$BUILT" "$WL"
codesign --force --sign - -i "org.l4d2launcher.mvk.$(date +%s)" "$WL" 2>/dev/null
echo "DEPLOYED clean v1.4.0: $(shasum "$BUILT" | cut -c1-12)"
