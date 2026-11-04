#!/bin/bash
# Enter/exit and source-switch repetition on the simulator.
#
#   tool/churn_check.sh [rounds] [bvid]
#
# Reports, per round, whether a picture appears and whether the process stayed
# alive. It deliberately does not claim to measure memory: RSS on a simulator
# says little about a device, and a number invented here would be worse than none.
set -uo pipefail
ROUNDS="${1:-10}"
BVID="${2:-BV1b24y1w73N}"
SIM="${SIM_UDID:-3D5AE91D-601D-4D37-85A1-C8F200A83FEE}"
BUNDLE=com.example.pilipalax
IDB=/tmp/idbenv/bin/idb
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/churn_$(date +%s)"
export PATH=/Users/space/development/fl-3479/flutter/bin:$PATH
mkdir -p "$OUT"

APP="$ROOT/build/ios/iphonesimulator/Runner.app"
[ -d "$APP" ] || { echo "no simulator build" >&2; exit 1; }
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1
xcrun simctl uninstall "$SIM" "$BUNDLE" >/dev/null 2>&1
xcrun simctl install "$SIM" "$APP" || { echo "install failed" >&2; exit 1; }
CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
( cd "$ROOT" && SEED_CONTAINER="$CONTAINER" \
    SEED_COOKIES=/tmp/acc/cookies.json SEED_NAV=/tmp/acc/nav.json \
    SEED_DEFAULT_QUALITY=120 SEED_TONEMAP_HDR=0 SEED_AUTOPLAY=1 \
    flutter test tool/tests/seed_account_test.dart --reporter compact >/dev/null 2>&1 )
xcrun simctl launch "$SIM" "$BUNDLE" >/dev/null 2>&1
sleep 12
"$IDB" connect "$SIM" >/dev/null 2>&1

open_video() {
  "$IDB" open --udid "$SIM" "bilibili://video/$BVID" >/dev/null 2>&1
  sleep 10
  python3 - "$SIM" <<'PY'
import json, subprocess, sys
sim = sys.argv[1]; idb = "/tmp/idbenv/bin/idb"
raw = subprocess.run([idb, "ui", "describe-all", "--udid", sim],
                     capture_output=True, text=True, timeout=90).stdout
try: nodes = json.loads(raw)
except Exception: nodes = []
for n in nodes:
    if (n.get("AXLabel") or "").strip() == "打开":
        f = n["frame"]
        subprocess.run([idb, "ui", "tap", "--udid", sim,
                        str(int(f["x"] + f["width"] / 2)),
                        str(int(f["y"] + f["height"] / 2))],
                       capture_output=True, timeout=60)
        break
PY
  sleep 12
}

go_home() {
  "$IDB" ui swipe --udid "$SIM" 200 700 200 40 2>/dev/null
  sleep 2
  "$IDB" ui swipe --udid "$SIM" 200 700 200 40 2>/dev/null
  sleep 3
}

FAIL=0
for i in $(seq 1 "$ROUNDS"); do
  open_video
  xcrun simctl io "$SIM" screenshot "$OUT/r$i-a.png" >/dev/null 2>&1
  sleep 4
  xcrun simctl io "$SIM" screenshot "$OUT/r$i-b.png" >/dev/null 2>&1
  A=$(md5 -q "$OUT/r$i-a.png" 2>/dev/null | cut -c1-12)
  B=$(md5 -q "$OUT/r$i-b.png" 2>/dev/null | cut -c1-12)
  CLASS=$(python3 "$ROOT/tool/check_player_frame.py" "$OUT/r$i-b.png" 2>/dev/null | tail -1)
  ALIVE=$(xcrun simctl spawn "$SIM" launchctl list 2>/dev/null | grep -c "$BUNDLE")
  if [ "$A" = "$B" ]; then
    STATUS="STATIC"
  else
    STATUS="MOVING"
  fi
  printf '  round %2d: %-7s alive=%s  %s\n' "$i" "$STATUS" "$ALIVE" "${CLASS##*-> }"
  [ "$ALIVE" -ge 1 ] || { echo "  round $i: process died" >&2; FAIL=1; }
  go_home
done

echo
echo "artefacts: $OUT"
[ "$FAIL" = "0" ] && echo "RESULT=NO_CRASH_OBSERVED" || { echo "RESULT=CRASH_OBSERVED"; exit 1; }
