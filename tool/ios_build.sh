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
LOG="$(mktemp -t pilipilus-ios-build)"
( cd "$ROOT" && flutter build ios --"$MODE" \
    --build-name="${PILIPLUS_BUILD_NAME:-0.0.1}" \
    DEVELOPMENT_TEAM="$TEAM" ) 2>&1 | tee "$LOG"
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

echo "== 3. artefact identity =="
tool/identity.sh "$APP" 2>/dev/null || bash "$ROOT/tool/identity.sh" "$APP"

echo
echo "SIGNED_APP=$APP"
echo "log: $LOG"
