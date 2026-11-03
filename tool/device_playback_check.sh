#!/bin/bash
# Run a playback check on the attached physical iPhone.
#
# Everything in here was learned the hard way:
#   - a --no-codesign bundle will not install (ApplicationVerificationFailed);
#     a plain release/profile build is signed automatically and does install.
#   - debug builds install but refuse to launch from the home screen, so this
#     uses profile.
#   - idb is simulator-only and devicectl has no file push, so a video is opened
#     by passing the URL with --payload-url.
#   - "the screenshot has a picture in it" proves nothing: a locked phone still
#     returns a screenshot. The lock state is checked first, and playback is
#     judged by consecutive frames differing.
#
#   tool/device_playback_check.sh <bvid-or-url> [tonemap:0|1]
#
# Requires the phone to be unlocked and to stay unlocked for the whole run.
set -uo pipefail
if [ $# -lt 1 ]; then
  echo "usage: device_playback_check.sh <bvid-or-url> [tonemap:0|1]" >&2
  exit 2
fi
URL_ARG="$1"
TONEMAP="${2:-0}"
case "$TONEMAP" in
  0|1) ;;
  *) echo "tonemap must be 0 or 1" >&2; exit 2 ;;
esac

DEV="${DEVICE_UDID:-00008150-001E5C592E78401C}"
BUNDLE=com.example.pilipalax
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH=/Users/space/development/fl-3479/flutter/bin:$PATH
OUT="/tmp/device_check_$(date +%s)"
mkdir -p "$OUT"

# Accept a bare BV id as well as a full URL.
case "$URL_ARG" in
  http*) URL="$URL_ARG" ;;
  BV*)   URL="https://www.bilibili.com/video/$URL_ARG" ;;
  *)     echo "expected a URL or a BV id, got '$URL_ARG'" >&2; exit 2 ;;
esac

echo "== 0. the phone must be unlocked =="
if xcrun devicectl device process launch --device "$DEV" "$BUNDLE" 2>&1 \
     | grep -q 'Locked'; then
  echo "  FAIL  device is locked; unlock it and rerun" >&2
  exit 1
fi
echo "  PASS  device accepts launches"

echo "== 1. build (profile: debug will not start from the home screen) =="
BUILD_ARGS=(--profile)
if [ "$TONEMAP" = "1" ]; then
  # There is no CLI way to toggle an app preference on a physical device, so the
  # default is compiled in for this run.
  BUILD_ARGS+=(--dart-define=TEMP_HDR_DEFAULT_ON=true)
fi
( cd "$ROOT" && flutter build ios "${BUILD_ARGS[@]}" >"$OUT/build.log" 2>&1 ) || {
  echo "  FAIL  build; see $OUT/build.log" >&2; exit 1; }
echo "  PASS  built"

echo "== 2. install =="
xcrun devicectl device install app --device "$DEV" \
  "$ROOT/build/ios/iphoneos/Runner.app" >"$OUT/install.log" 2>&1 || {
  echo "  FAIL  install; see $OUT/install.log" >&2; exit 1; }
echo "  PASS  installed"

echo "== 3. open the video and let it buffer =="
xcrun devicectl device process launch --device "$DEV" \
  --payload-url "$URL" "$BUNDLE" >"$OUT/launch.log" 2>&1 || {
  echo "  FAIL  launch (did the phone lock again?); see $OUT/launch.log" >&2
  exit 1; }
sleep 20

echo "== 4. capture consecutive frames =="
for i in 1 2 3; do
  xcrun devicectl device capture screenshot --device "$DEV" \
    --destination "$OUT/f$i.png" >/dev/null 2>&1
  sleep 3
done
for i in 1 2 3; do
  [ -f "$OUT/f$i.png" ] || { echo "  FAIL  no screenshot $i" >&2; exit 1; }
done
echo "  PASS  three frames captured"

echo "== 5. is it actually playing? =="
KEEP=0
for i in 1 2 3; do
  sips -c 500 1260 --cropOffset 210 0 "$OUT/f$i.png" \
    --out "$OUT/c$i.png" >/dev/null 2>&1
  h=$(md5 -q "$OUT/c$i.png" 2>/dev/null | cut -c1-16)
  echo "  frame $i: $h"
  [ -n "$h" ] && echo "$h" >> "$OUT/hashes"
done
KEEP=$(sort -u "$OUT/hashes" 2>/dev/null | wc -l | tr -d ' ')
if [ "$KEEP" -ge 2 ]; then
  echo "  PASS  frames differ ($KEEP distinct) - playing"
else
  echo "  FAIL  all frames identical - not playing, or the phone is locked" >&2
  exit 1
fi

echo "== 6. colour =="
python3 "$ROOT/tool/check_player_frame.py" "$OUT"/f*.png

echo
echo "artefacts: $OUT"
