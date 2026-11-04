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

if [ $# -lt 1 ]; then
  echo "usage: verify_release_constraints.sh <Runner.app>" >&2
  exit 2
fi
APP="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
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
  # Read the ABI off the framework itself. Runner does not link Avcodec
  # directly - libmpv loads it - so grepping Runner's load commands always came
  # back empty and reported a failure for a bundle that was in fact correct.
  ABI=$(otool -l "$AV" 2>/dev/null | grep -A2 LC_BUILD_VERSION \
    | grep -o 'current version [0-9.]*' | head -1)
  if [ -z "$ABI" ]; then
    # Fall back to the dylib's own compatibility/current version line.
    ABI=$(otool -D "$AV" 2>/dev/null | tail -1)
  fi
  ID=$(otool -l "$AV" 2>/dev/null | grep -A4 LC_ID_DYLIB \
    | grep -o 'current version [0-9.]*' | head -1)
  note "framework id: ${ID:-unknown}"
  if [ -n "$ID" ]; then
    case "$ID" in
      *"61.3.100"*) note "ABI 61.3.100 as vendored" ;;
      *) bad "unexpected ABI in '$ID'" ;;
    esac
  else
    bad "could not read the framework ABI"
  fi
  EXPORTS=$(nm -gU "$AV" 2>/dev/null | wc -l | tr -d ' ')
  [ "$EXPORTS" = "359" ] \
    && note "exports = $EXPORTS" \
    || bad "exports = $EXPORTS, expected 359"

  ARCHS=$(lipo -archs "$AV" 2>/dev/null)
  case "$ARCHS" in
    *arm64*) note "architectures: $ARCHS" ;;
    *) bad "unexpected architectures '$ARCHS' (expected arm64 for device)" ;;
  esac

  # The binary must be the vendored one, not a rebuild with the same ABI and
  # symbol count. `nm` counting is a shape check; the hash is an identity check.
  VENDORED="$ROOT/ios/av1/Avcodec"
  if [ -f "$VENDORED" ]; then
    A=$(shasum -a 256 "$AV" | cut -d' ' -f1)
    B=$(shasum -a 256 "$VENDORED" | cut -d' ' -f1)
    if [ "$A" = "$B" ]; then
      note "binary matches vendored ios/av1/Avcodec ($A)"
    else
      # A plain `flutter build ios` ships the pod's copy. Only
      # tool/inject_ios_avcodec.sh puts the vendored AV1 build in place, so this
      # is either a build that skipped injection or a different binary entirely.
      bad "binary differs from the vendored Avcodec (app=$A vendored=$B) - run tool/inject_ios_avcodec.sh"
    fi
  else
    bad "vendored ios/av1/Avcodec missing - cannot verify binary identity"
  fi
else
  bad "Avcodec.framework missing"
fi

echo "== diagnostic residue =="
DART="$APP/Frameworks/App.framework/App"
if [ -f "$DART" ]; then
  # Includes the experiment scaffolding used in this repo's debugging passes,
  # because leaving any of it in a shipping binary is the same mistake.
  for kw in QA_PICK 'prefer=' 'picked=' VPARAM TEMP_FORCE_HDR \
            TEMP_NO_TONEMAP SURFACE_ PLVP_; do
    n=$(strings -a "$DART" 2>/dev/null | grep -c "$kw")
    [ "$n" = "0" ] && note "'$kw' absent" || bad "'$kw' appears $n time(s)"
  done
  # The native side is compiled into Runner, not App.framework, so it needs its
  # own scan: a diagnostic that writes files or traces is just as unacceptable
  # there as in Dart.
  RUNNER="$APP/Runner"
  if [ -f "$RUNNER" ]; then
    for kw in hdr_state.log TEMP_FORCE_HDR VPARAM; do
      n=$(strings -a "$RUNNER" 2>/dev/null | grep -c "$kw")
      [ "$n" = "0" ] && note "native '$kw' absent" || bad "native '$kw' appears $n time(s)"
    done
    # The trace hook must be compiled out of a shipping build, not merely
    # env-gated: an environment variable is still settable on a release binary.
    # Both trace entry points live behind PILIPLUS_DIAGNOSTICS, so their marker
    # strings must be absent - a single occurrence means the call survived.
    for kw in PILIPLUS_HLS_TRACE PILIPLUS_HDR_TRACE PILIPLUS_DIAGNOSTICS; do
      n=$(strings -a "$RUNNER" 2>/dev/null | grep -c "$kw")
      [ "$n" = "0" ] && note "trace marker '$kw' compiled out" \
        || bad "trace marker '$kw' present $n time(s) - diagnostics leaked"
    done
  else
    bad "no Runner binary - cannot scan native diagnostics"
  fi
else
  # A debug bundle keeps Dart code in kernel_blob.bin, so this check cannot run.
  # Reporting "satisfied" without having looked would be worse than failing.
  bad "no App.framework - cannot scan for diagnostics (is this a debug build?)"
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "all constraints satisfied"
else
  echo "constraint check FAILED"
fi
exit "$FAIL"
