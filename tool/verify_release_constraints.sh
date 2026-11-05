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
# One implementation, shared with both build entry points. It checks the identity
# a signature cannot change - Mach-O UUID, the full exported symbol set, the
# dependent libraries - because a whole-file hash of a *signed* app never matches
# the vendored binary even when the code is identical, and a hardcoded "359"
# would accept a different 359 symbols.
if bash "$ROOT/tool/ios_av1_package.sh" verify "$APP"; then
  note "AV1 VideoToolbox decoder present and identified"
else
  bad "the bundle does not carry a verified AV1 VideoToolbox decoder"
fi
AV="$APP/Frameworks/Avcodec.framework/Avcodec"
if [ -f "$AV" ]; then
  ARCHS=$(lipo -archs "$AV" 2>/dev/null)
  case "$ARCHS" in
    *arm64*) note "architectures: $ARCHS" ;;
    *) bad "unexpected architectures '$ARCHS' (expected arm64 for device)" ;;
  esac
else
  bad "Avcodec.framework missing"
fi

echo "== diagnostic residue =="
DART="$APP/Frameworks/App.framework/App"
if [ -f "$DART" ]; then
  # Includes the experiment scaffolding used in this repo's debugging passes,
  # because leaving any of it in a shipping binary is the same mistake.
  for kw in QA_PICK HDR_PATH 'prefer=' 'picked=' VPARAM TEMP_FORCE_HDR \
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
