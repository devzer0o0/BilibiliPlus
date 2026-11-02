#!/bin/bash
# Full regression: unit suite + the simulator checks that encode the HDR gate.
#
#   tool/full_regression.sh
#
# Exits non-zero if any stage fails, so it can gate a release.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH=/Users/space/development/fl-3479/flutter/bin:$PATH
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAIL=1; }

echo "== 1. unit suite =="
if ( cd "$ROOT" && flutter test --reporter compact 2>&1 | tail -1 | grep -q 'All tests passed' ); then
  pass "flutter test"
else
  fail "flutter test"
fi

echo "== 2. release constraints =="
APP=$ROOT/build/ios/iphoneos/Runner.app
if [ -d "$APP" ]; then
  if bash "$ROOT/tool/verify_release_constraints.sh" "$APP" >/dev/null 2>&1; then
    pass "bundle id / AV1 ABI / no diagnostics"
  else
    fail "release constraints"
  fi
  # Temporary debug scaffolding used in earlier experiments must never ship.
  DART_APP="$APP/Frameworks/App.framework/App"
  if [ -f "$DART_APP" ]; then
    LEAK=0
    for kw in VPARAM TEMP_FORCE_HDR TEMP_NO_TONEMAP SURFACE_ PLVP_; do
      n=$(strings -a "$DART_APP" 2>/dev/null | grep -c "$kw")
      if [ "$n" != "0" ]; then
        fail "debug marker '$kw' present in release ($n)"
        LEAK=1
      fi
    done
    [ "$LEAK" = "0" ] && pass "no experiment scaffolding in the release binary"
  fi
else
  fail "no release build - run 'flutter build ios --release --no-codesign' first"
fi

echo "== 3. HDR gate in the simulator =="
check_pick() {
  local bvid=$1 qn=$2 tone=$3 expect=$4 label=$5
  local out
  out=$(bash "$ROOT/tool/hdr_pick_check.sh" "$bvid" "$qn" "$tone" 2>/dev/null | grep -o 'picked=[0-9]*' | head -1)
  if [ "$out" = "picked=$expect" ]; then
    pass "$label ($out)"
  else
    fail "$label (got '$out', want picked=$expect)"
  fi
}

check_pick BV1b24y1w73N 125 0 120 "HDR blocked with tone mapping off"
check_pick BV1b24y1w73N 120 0 120 "4K honoured with tone mapping off"

echo
if [ "$FAIL" = "0" ]; then
  echo "REGRESSION PASSED"
else
  echo "REGRESSION FAILED"
fi
exit "$FAIL"
