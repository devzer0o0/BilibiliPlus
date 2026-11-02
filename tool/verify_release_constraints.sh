#!/bin/bash
# Check the hard constraints on a built app bundle.
#
#   tool/verify_release_constraints.sh <path-to-Runner.app>
#
# Asserts:
#   1. the bundle id is com.example.pilipalax
#   2. the AV1 VideoToolbox framework is present with ABI 61.3.100 and 359 exports
#   3. no temporary diagnostic markers from this repo survived the build
set -uo pipefail

APP="${1:?usage: verify_release_constraints.sh <Runner.app>}"
FAIL=0
note() { printf '  %s\n' "$1"; }
bad()  { printf '  FAIL: %s\n' "$1"; FAIL=1; }

echo "== bundle identity =="
BID=$(plutil -extract CFBundleIdentifier raw "$APP/Info.plist" 2>/dev/null)
[ "$BID" = "com.example.pilipalax" ] \
  && note "CFBundleIdentifier = $BID" \
  || bad "CFBundleIdentifier is '$BID', expected com.example.pilipalax"

echo "== AV1 framework =="
AV="$APP/Frameworks/Avcodec.framework/Avcodec"
if [ -f "$AV" ]; then
  ABI=$(otool -L "$APP/Runner" 2>/dev/null | grep -o 'Avcodec.framework/Avcodec (compatibility version [0-9.]*, current version [0-9.]*)' | head -1)
  note "linked: $ABI"
  case "$ABI" in
    *"current version 61.3.100"*) note "ABI 61.3.100 as vendored" ;;
    *) bad "unexpected ABI in '$ABI'" ;;
  esac
  EXPORTS=$(nm -gU "$AV" 2>/dev/null | wc -l | tr -d ' ')
  [ "$EXPORTS" = "359" ] \
    && note "exports = $EXPORTS" \
    || bad "exports = $EXPORTS, expected 359"
else
  bad "Avcodec.framework missing"
fi

echo "== diagnostic residue =="
DART="$APP/Frameworks/App.framework/App"
if [ -f "$DART" ]; then
  for kw in QA_PICK 'prefer=' 'picked='; do
    n=$(strings -a "$DART" 2>/dev/null | grep -c "$kw")
    [ "$n" = "0" ] && note "'$kw' absent" || bad "'$kw' appears $n time(s)"
  done
else
  note "(no App.framework - skipping, debug builds keep Dart code in kernel)"
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "all constraints satisfied"
else
  echo "constraint check FAILED"
fi
exit "$FAIL"
