#!/bin/bash
# Reset the simulator to a known-good state for a playback test.
#
# Reinstalling alone is not enough: a previous run can leave a stale binary
# (with debug hooks compiled in) or stale Hive state, and the symptom is a
# normal video reporting "视频不存在或已被删除" - which looks exactly like a
# product bug. This wasted a debugging round, so it is scripted.
#
#   tool/reset_sim.sh [quality] [tonemap] [autoplay]
set -uo pipefail
QUALITY="${1:-127}"
TONEMAP="${2:-0}"
AUTOPLAY="${3:-1}"
SIM="${SIM_UDID:-3D5AE91D-601D-4D37-85A1-C8F200A83FEE}"
BUNDLE=com.example.pilipalax
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH=/Users/space/development/fl-3479/flutter/bin:$PATH

APP="$ROOT/build/ios/iphonesimulator/Runner.app"
if [ ! -d "$APP" ]; then
  echo "no simulator build; run: flutter build ios --simulator --debug" >&2
  exit 1
fi

# A build made with experiment flags carries leftover markers. Refuse silently
# broken state rather than testing it.
DART="$APP/Frameworks/App.framework/App"
if [ -f "$DART" ]; then
  for kw in TEMP_SHOW_PLAY_ERROR TEMP_FORCE_HDR VPARAM; do
    n=$(strings -a "$DART" 2>/dev/null | grep -c "$kw")
    if [ "$n" != "0" ]; then
      echo "installed build still contains '$kw'; rebuild before testing" >&2
      exit 1
    fi
  done
fi

xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1
# Uninstall, not just install: stale Hive state survives an upgrade.
xcrun simctl uninstall "$SIM" "$BUNDLE" >/dev/null 2>&1
xcrun simctl install "$SIM" "$APP" >/dev/null 2>&1 || {
  echo "install failed" >&2; exit 1; }

CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
if [ -z "$CONTAINER" ]; then
  echo "no data container after install" >&2
  exit 1
fi

( cd "$ROOT" && SEED_CONTAINER="$CONTAINER" \
    SEED_COOKIES=/tmp/acc/cookies.json SEED_NAV=/tmp/acc/nav.json \
    SEED_DEFAULT_QUALITY="$QUALITY" SEED_TONEMAP_HDR="$TONEMAP" \
    SEED_AUTOPLAY="$AUTOPLAY" \
    flutter test tool/tests/seed_account_test.dart --reporter compact 2>&1 ) \
  | grep -E 'seeded|failed' || true

echo "reset: quality=$QUALITY tonemap=$TONEMAP autoplay=$AUTOPLAY"
