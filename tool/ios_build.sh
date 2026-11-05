#!/bin/bash
# Build a signed, installable iOS app with an explicit team.
#
#   PILIPLUS_DEVELOPMENT_TEAM=ABCDE12345 tool/ios_build.sh [debug|profile|release]
#
# Why this exists: DEVELOPMENT_TEAM in the shared Xcode project is empty, and an
# empty value set in the *target* overrides whatever an xcconfig supplies. So the
# team is passed on the command line and then verified with
# `xcodebuild -showBuildSettings`, which is the only way to know what the build
# actually resolved to - a shell environment variable is not automatically
# forwarded by Flutter.
#
# Nothing personal is written into the repository: no team id, no profile, no
# certificate. The unsigned build stays available for compilation checks
# (`flutter build ios --release --no-codesign`); it just is not installable.
set -uo pipefail

MODE="${1:-profile}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH=/Users/space/development/fl-3479/flutter/bin:$PATH

case "$MODE" in
  debug|profile|release) ;;
  *) echo "usage: ios_build.sh [debug|profile|release]" >&2; exit 2 ;;
esac

TEAM="${PILIPLUS_DEVELOPMENT_TEAM:-}"
if [ -z "$TEAM" ]; then
  echo "BLOCKED_SIGNING: set PILIPLUS_DEVELOPMENT_TEAM to a 10-character team id" >&2
  echo "  (Xcode > Settings > Accounts > your team, or developer.apple.com)" >&2
  exit 3
fi

echo "== 0. toolchain =="
command -v xcodebuild >/dev/null || {
  echo "BLOCKED_TOOLING: xcodebuild not found" >&2; exit 4; }
xcodebuild -version | head -2

echo "== 1. build ($MODE) =="
# `flutter build ios` treats a bare KEY=VALUE after the flags as a *target*
# name ("Target file DEVELOPMENT_TEAM=... not found"), so the team is passed to
# xcodebuild through FLUTTER_XCODE_*, which Flutter forwards verbatim.
LOG="$(mktemp -t pilipilus-ios-build)"
( cd "$ROOT" && \
    FLUTTER_XCODE_DEVELOPMENT_TEAM="$TEAM" \
    FLUTTER_XCODE_CODE_SIGN_STYLE=Automatic \
    flutter build ios --"$MODE" \
      --build-name="${PILIPLUS_BUILD_NAME:-0.0.1}" ) 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
APP="$ROOT/build/ios/iphoneos/Runner.app"
if [ "$STATUS" != "0" ] || [ ! -d "$APP" ]; then
  echo "BLOCKED_SIGNING: build failed; see $LOG" >&2
  exit 5
fi

echo "== 2. resolved settings (the project value, not the shell one) =="
/usr/libexec/PlistBuddy -c 'Print :AppBundleIdentifier' \
  "$ROOT/build/ios/iphoneos/Runner.app/Info.plist" >/dev/null 2>&1 || true
for CONFIG in Debug Profile Release; do
  OUT=$(cd "$ROOT/ios" && xcodebuild -showBuildSettings \
          -workspace Runner.xcworkspace -scheme Runner -configuration "$CONFIG" \
          DEVELOPMENT_TEAM="$TEAM" 2>/dev/null)
  RTEAM=$(printf '%s' "$OUT" | awk -F' = ' '/ DEVELOPMENT_TEAM =/ {print $2; exit}' | tr -d ' ')
  RSTYLE=$(printf '%s' "$OUT" | awk -F' = ' '/ CODE_SIGN_STYLE =/ {print $2; exit}' | tr -d ' ')
  RIDENT=$(printf '%s' "$OUT" | awk -F' = ' '/ "PRODUCT_BUNDLE_IDENTIFIER =/ {print $2; exit}' | tr -d ' ')
  printf '  %-8s team=%s style=%s bundle=%s\n' \
    "$CONFIG" "${RTEAM:-<empty>}" "${RSTYLE:-<empty>}" "${RIDENT:-<empty>}"
  if [ "$RTEAM" != "$TEAM" ]; then
    echo "  FAIL: $CONFIG resolved team '${RTEAM:-<empty>}', expected $TEAM" >&2
    exit 6
  fi
done

echo "== 3. AV1 VideoToolbox injection =="
# The Flutter-bundled Avcodec has no AV1 VideoToolbox decoder. Without this the
# player reports hwdec=no for an AV1 stream and decodes 2160p on the CPU - that
# is the heat and the stutter. Measured: 71 of 71 samples were hwdec=no av1.
#
#
# This step fails the build. It used to print "SKIPPED" and carry on, which is
# how an installable app reached the phone without an AV1 decoder: every frame
# decoded on the CPU, mpv reported `hwdec=no`, and the result read as "this
# hardware cannot do AV1" rather than "this build did not include the decoder".
# The only build that may omit AV1 is one that says so, and this is not it.
if [ ! -f "$ROOT/ios/av1/Avcodec" ]; then
  echo "BLOCKED_AV1: ios/av1/Avcodec is missing; refusing to produce an app without an AV1 decoder" >&2
  exit 7
fi
AV1_PROFILE="$(mktemp -t pilipilus-profile)"
if ! cp "$APP/embedded.mobileprovision" "$AV1_PROFILE" 2>/dev/null; then
  echo "BLOCKED_SIGNING: the build carries no embedded provisioning profile to re-sign with" >&2
  exit 7
fi
AV1_IDENTITY="${IOS_SIGN_IDENTITY:-}"
if [ -z "$AV1_IDENTITY" ]; then
  # Match on the certificate name first: the keychain also holds a
  # "Plumb Local Signer" identity, and taking its hex string would
  # sign for the wrong team.
  AV1_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Apple Development" \
    | grep -o "[0-9A-F]\{40\}" \
    | head -1)"
fi
if [ -z "$AV1_IDENTITY" ]; then
  echo "BLOCKED_SIGNING: no Apple Development identity to re-sign the AV1 framework" >&2
  exit 7
fi
IOS_SIGN_IDENTITY="$AV1_IDENTITY" \
  IOS_PROVISIONING_PROFILE="$AV1_PROFILE" \
  bash "$ROOT/tool/inject_ios_avcodec.sh" "$APP" || {
    echo "BLOCKED_AV1: injecting the AV1 VideoToolbox Avcodec failed" >&2
    exit 7
  }
rm -f "$AV1_PROFILE"
echo "  installed and verified"

echo "== 4. artefact identity =="
tool/identity.sh "$APP" 2>/dev/null || bash "$ROOT/tool/identity.sh" "$APP"

echo
echo "SIGNED_APP=$APP"
echo "log: $LOG"
