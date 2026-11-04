#!/bin/bash
# Record what a build actually is, so a regression run cannot score a stale one.
#
#   tool/identity.sh <Runner.app>
#
# `full_regression` used to accept any Runner.app found under build/ as "the
# build", which is how a result could be attributed to code that was never
# compiled. Everything printed here is checkable against the source tree.
set -uo pipefail
APP="${1:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  echo "usage: identity.sh <Runner.app>" >&2
  exit 2
fi

sha() { git -C "$ROOT" rev-parse HEAD; }
dirty() {
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then echo "yes"; else echo "no"; fi
}

echo "== build identity =="
echo "  source_sha    $(sha)"
echo "  dirty_tree    $(dirty)"
echo "  app_path      $APP"
echo "  app_mtime     $(date -r "$APP" '+%Y-%m-%dT%H:%M:%S%z')"
echo "  build_time    $(date '+%Y-%m-%dT%H:%M:%S%z')"
echo "  bundle_id     $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist" 2>/dev/null || echo unknown)"
echo "  bundle_ver    $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist" 2>/dev/null || echo unknown)"

DART="$APP/Frameworks/App.framework/App"
if [ -f "$DART" ]; then
  echo "  dart_binary   $(shasum -a 256 "$DART" | cut -d' ' -f1)"
  # A debug bundle keeps Dart in kernel_blob.bin; its presence is the marker.
else
  echo "  dart_binary   <absent>"
fi
if [ -f "$APP/Frameworks/App.framework/flutter_assets/kernel_blob.bin" ]; then
  echo "  build_mode    debug (kernel snapshot present)"
else
  echo "  build_mode    aot (no kernel snapshot)"
fi
RUNNER="$APP/Runner"
[ -f "$RUNNER" ] && echo "  runner_sha    $(shasum -a 256 "$RUNNER" | cut -d' ' -f1)"

echo "  flutter       $(/Users/space/development/fl-3479/flutter/bin/flutter --version 2>/dev/null | head -1 || echo unknown)"
echo "  xcode         $(xcodebuild -version 2>/dev/null | head -1 || echo unknown)"
echo "  sdk           $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo unknown)"

SIG="$(codesign -dv "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier)' | head -3 | tr '\n' ';' )"
echo "  signature     ${SIG:-unsigned}"
