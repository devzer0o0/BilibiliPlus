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

echo "== 0. script self-checks =="
if bash "$ROOT/tool/selftest.sh" >/dev/null 2>&1; then
  pass "verification scripts fail correctly"
else
  fail "verification script self-checks"
fi

echo "== 0b. native parser tests =="
# The DASH index, the playlist and the box patcher are pure Swift; they are
# exercised through SwiftPM so they gate a release without a device.
if [ -f "$ROOT/tool/swift_parser_tests.sh" ] && bash "$ROOT/tool/swift_parser_tests.sh" >/dev/null 2>&1; then
  pass "swift parser/index/playlist tests"
else
  fail "swift parser tests"
fi

echo "== 1. unit suite =="
if ( cd "$ROOT" && flutter test --reporter compact 2>&1 | tail -1 | grep -q 'All tests passed' ); then
  pass "flutter test"
else
  fail "flutter test"
fi

echo "== 2. release constraints =="
# The bundle is only "the build" if it is newer than the newest source file and
# was produced after the current commit. A Runner.app left over from an earlier
# pass used to be scored as if it were the code under test.
APP=${PILIPLUS_APP:-$ROOT/build/ios/iphoneos/Runner.app}
if [ -d "$APP" ]; then
  NEWEST_SRC=$(find "$ROOT/lib" "$ROOT/ios/Runner" -newer "$APP" -type f \
    \( -name '*.dart' -o -name '*.swift' \) -print -quit 2>/dev/null)
  if [ -n "$NEWEST_SRC" ]; then
    fail "the bundle is older than $(basename "$NEWEST_SRC") - rebuild, it is not this code"
  else
    pass "bundle is newer than every Dart/Swift source file"
  fi
  bash "$ROOT/tool/identity.sh" "$APP" | sed 's/^/  /'
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

echo "== 3. rendition selection (simulator logic, not device decode) =="
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

# On iOS the HDR ladder is handed to AVPlayerLayer, which composites extended
# range for real, so 125 is served whether or not the tone-mapping fallback is
# enabled. The gate that used to matter was the 8-bit texture path; it no longer
# applies, and asserting 120 here would be asserting the old behaviour.
# A pick here means "the selection function chose this id". It is NOT evidence
# that HDR was presented, that 4K decoded, or that frames were rendered - those
# are device checks (tool/device_preflight.sh + the D1/D2 records).
check_pick BV1b24y1w73N 125 0 125 "selection: HDR rung reachable (not a render proof)"
check_pick BV1b24y1w73N 125 1 125 "selection: HDR rung reachable with tone mapping on"
check_pick BV1b24y1w73N 120 0 120 "selection: 4K rung honoured, no HDR drift"

echo
if [ "$FAIL" = "0" ]; then
  echo "REGRESSION PASSED"
else
  echo "REGRESSION FAILED"
fi
exit "$FAIL"
