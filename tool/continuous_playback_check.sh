#!/bin/bash
# Sample the player area over time and report whether the picture keeps moving.
#
#   tool/continuous_playback_check.sh <bvid> [quality] [seconds]
#
# Why this exists: three frames taken three seconds apart can all differ while
# playback is stalling and catching up. A stall shows up as *repeated* identical
# samples over a longer window, which is what this counts. It measures presence
# of motion, not smoothness - frame timing needs the in-app probe.
set -uo pipefail
if [ $# -lt 1 ]; then
  echo "usage: continuous_playback_check.sh <bvid> [quality] [seconds]" >&2
  exit 2
fi
BVID="$1"
QUALITY="${2:-120}"
DURATION="${3:-60}"
SIM="${SIM_UDID:-3D5AE91D-601D-4D37-85A1-C8F200A83FEE}"
BUNDLE=com.example.pilipalax
IDB=/tmp/idbenv/bin/idb
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/contplay_$(date +%s)"
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
    SEED_DEFAULT_QUALITY="$QUALITY" SEED_TONEMAP_HDR=0 SEED_AUTOPLAY=1 \
    flutter test tool/tests/seed_account_test.dart --reporter compact >/dev/null 2>&1 )

xcrun simctl spawn "$SIM" log stream --level debug \
  --predicate 'processImagePath CONTAINS "Runner"' --style compact > "$OUT/run.log" 2>&1 &
LOGPID=$!
sleep 2
xcrun simctl launch "$SIM" "$BUNDLE" >/dev/null 2>&1
sleep 15
"$IDB" connect "$SIM" >/dev/null 2>&1
"$IDB" open --udid "$SIM" "bilibili://video/$BVID" >/dev/null 2>&1
sleep 6
python3 - "$SIM" <<'PY'
import json, subprocess, sys
sim = sys.argv[1]
idb = "/tmp/idbenv/bin/idb"
raw = subprocess.run([idb, "ui", "describe-all", "--udid", sim],
                     capture_output=True, text=True, timeout=90).stdout
try:
    nodes = json.loads(raw)
except Exception:
    nodes = []
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

echo "== sampling for ${DURATION}s =="
SAMPLES=$(( DURATION / 5 ))
PREV=""
MOVES=0
REPEATS=0
for i in $(seq 1 "$SAMPLES"); do
  xcrun simctl io "$SIM" screenshot "$OUT/s$i.png" >/dev/null 2>&1
  sips -c 500 1260 --cropOffset 210 0 "$OUT/s$i.png" --out "$OUT/c$i.png" >/dev/null 2>&1
  H=$(md5 -q "$OUT/c$i.png" 2>/dev/null | cut -c1-16)
  if [ -n "$PREV" ]; then
    if [ "$H" = "$PREV" ]; then
      REPEATS=$((REPEATS + 1))
      printf '  %2d: %s  SAME\n' "$i" "$H"
    else
      MOVES=$((MOVES + 1))
      printf '  %2d: %s  moved\n' "$i" "$H"
    fi
  else
    printf '  %2d: %s  (first)\n' "$i" "$H"
  fi
  PREV="$H"
  sleep 4
done

kill $LOGPID 2>/dev/null
echo
echo "distinct transitions: $MOVES, repeated samples: $REPEATS"
python3 "$ROOT/tool/check_player_frame.py" "$OUT"/s*.png 2>/dev/null | tail -3
echo "pick: $(grep -oE 'QA_PICK[^"]*' "$OUT/run.log" | tail -1)"
echo "hdr path: $(grep -oE 'HDR_PATH.{0,100}' "$OUT/run.log" | head -1)"
echo "artefacts: $OUT"
if [ "$MOVES" -eq 0 ]; then
  echo "RESULT=STALLED (no frame changed)"
  exit 1
fi
if [ "$REPEATS" -gt $((SAMPLES / 3)) ]; then
  echo "RESULT=UNSTABLE ($REPEATS of $SAMPLES samples repeated)"
  exit 1
fi
echo "RESULT=MOTION_CONTINUOUS"
