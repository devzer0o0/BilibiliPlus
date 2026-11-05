#!/usr/bin/env bash
# Put the AV1 VideoToolbox Avcodec into an app bundle, or check that it is there.
#
#   tool/ios_av1_package.sh install <Runner.app>   # replace + verify, no signing
#   tool/ios_av1_package.sh verify  <Runner.app>   # read-only, exit 1 when absent
#
# Why a separate step with one implementation: three entry points used to inject
# the same binary in three slightly different ways (tool/ios_build.sh,
# tool/build_ios_av1.sh, .github/workflows/ios.yml), and one of them treated a
# failed injection as a note and shipped the app anyway. The app then reported
# `hwdec=no` for every AV1 frame on a device whose VideoToolbox answers "yes",
# which reads exactly like "this phone cannot decode AV1" and is the single most
# expensive misdiagnosis this branch has produced.
#
# Identity is checked the way the binary is built, not by whole-file hash: any
# re-sign changes the file, so the file hash of a signed app never matches the
# vendored copy even when the code is byte-identical. What re-signing cannot
# change is the Mach-O UUID, the load commands and the exported symbol set, and
# those are what this compares.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDORED="$ROOT/ios/av1/Avcodec"
MODE="${1:-}"
APP="${2:-}"

usage() {
  echo "usage: ios_av1_package.sh <install|verify> <Runner.app>" >&2
  exit 2
}

fail() { echo "AV1_PACKAGE_FAILED: $1" >&2; exit 1; }

[ -n "$MODE" ] && [ -n "$APP" ] || usage
[ -d "$APP" ] || usage
[ -f "$VENDORED" ] || fail "vendored ios/av1/Avcodec is missing; the AV1 decoder cannot be shipped"

FRAMEWORK="$APP/Frameworks/Avcodec.framework"
TARGET="$FRAMEWORK/Avcodec"
[ -d "$FRAMEWORK" ] || fail "no Avcodec.framework in $APP (is this an iOS device build?)"

# The vendored binary is a device slice. Injecting it into a simulator bundle
# produces an app that installs and then fails to launch, so refuse by name.
ARCHS="$(lipo -archs "$VENDORED" 2>/dev/null || true)"
case "$ARCHS" in
  *arm64*) ;;
  *) fail "vendored Avcodec has no arm64 slice (archs: $ARCHS)" ;;
esac
case "$APP" in
  *iphonesimulator*) fail "refusing to inject a device slice into a simulator bundle" ;;
esac

if [ "$MODE" = "install" ]; then
  cp "$VENDORED" "$TARGET"
  chmod 755 "$TARGET"
  # The pod's Avcodec declares a higher deployment target than this build's.
  plutil -replace MinimumOSVersion -string 15.0 "$FRAMEWORK/Info.plist" 2>/dev/null || true
fi

[ -f "$TARGET" ] || fail "no Avcodec binary in the bundle"

# 1. Identity: the UUID of our build. The pod's Avcodec has a different one, and
#    a UUID is content-derived, so this separates "our build" from "some build".
want_uuid() {
  xcrun dwarfdump --uuid "$1" 2>/dev/null | awk '{print $2}' | head -1
}
WANT="$(want_uuid "$VENDORED")"
GOT="$(want_uuid "$TARGET")"
[ -n "$WANT" ] || fail "cannot read the vendored UUID"
if [ "$WANT" != "$GOT" ]; then
  fail "bundle Avcodec UUID $GOT is not the vendored $WANT (the stock pod binary was shipped)"
fi

# 2. Capability: the hwaccel this whole task exists for.
if ! strings -a "$TARGET" | grep -q 'av1_videotoolbox'; then
  fail "bundle Avcodec does not carry av1_videotoolbox"
fi

# 3. ABI surface: the full export set, not a count. A build that keeps 359
#    symbols but exports a different 359 links against the same Mpv and then
#    fails at the first call.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
nm -gU "$VENDORED" 2>/dev/null | awk '{print $3}' | sort > "$TMP/want.syms"
nm -gU "$TARGET" 2>/dev/null | awk '{print $3}' | sort > "$TMP/got.syms"
if ! diff -q "$TMP/want.syms" "$TMP/got.syms" >/dev/null; then
  echo "  exports differ from the vendored Avcodec:" >&2
  diff "$TMP/want.syms" "$TMP/got.syms" | head -20 >&2
  fail "exported symbol set changed"
fi

# 4. Dependencies: the same frameworks, so the ABI the rest of the app was built
#    against is the ABI this binary expects.
otool -L "$VENDORED" | tail -n +2 | awk '{print $1}' | sort > "$TMP/want.deps"
otool -L "$TARGET" | tail -n +2 | awk '{print $1}' | sort > "$TMP/got.deps"
diff -q "$TMP/want.deps" "$TMP/got.deps" >/dev/null \
  || fail "dependent libraries differ from the vendored Avcodec"

# 5. It must still be a valid, signed framework when it ships. Unsigned is only
#    acceptable before the caller signs (install mode runs before that step).
TEAM="$(codesign -dv "$TARGET" 2>&1 | awk -F= '/^TeamIdentifier/{print $2; exit}' || true)"
CDHASH="$(codesign -dv --verbose=4 "$TARGET" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}' || true)"

# The signature is only required of a bundle that is itself signed.
#
# A `--no-codesign` release build is a legitimate intermediate: CI builds it,
# replaces the framework, then signs. Demanding a signature there failed a bundle
# that was correct, so the check follows the bundle: if the app carries a
# signature, the framework inside it must verify and name the same team.
APP_TEAM="$(codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier/{print $2; exit}' || true)"
if [ "$MODE" = "verify" ] && [ -n "$APP_TEAM" ]; then
  codesign --verify --strict "$TARGET" 2>/dev/null \
    || fail "the app is signed but its Avcodec does not verify against its own signature"
  [ -n "$TEAM" ] || fail "the app is signed but its Avcodec carries no TeamIdentifier"
  [ "$TEAM" = "$APP_TEAM" ] \
    || fail "Avcodec is signed by team $TEAM, the app by $APP_TEAM"
fi

echo "AV1_PACKAGE_OK uuid=$GOT exports=$(wc -l < "$TMP/got.syms" | tr -d ' ') team=${TEAM:-<none yet>} cdhash=${CDHASH:-<none yet>}"
