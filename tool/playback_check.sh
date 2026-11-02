#!/bin/bash
# Play a title with a given quality + tone-mapping state, then classify frames.
#
#   tool/playback_check.sh <bvid> <quality> <tonemap> <autoplay>
set -uo pipefail
BVID="${1:?usage: playback_check.sh <bvid> <quality> <tonemap> <autoplay>}"
QUALITY="${2:-127}"
TONEMAP="${3:-0}"
AUTOPLAY="${4:-1}"
SIM="${SIM_UDID:-3D5AE91D-601D-4D37-85A1-C8F200A83FEE}"
BUNDLE=com.example.pilipalax
IDB=/tmp/idbenv/bin/idb
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/playback_$(date +%s)"
LOG="$OUT.log"
export PATH=/Users/space/development/fl-3479/flutter/bin:$PATH
mkdir -p "$OUT"

xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1
sleep 1
CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
( cd "$ROOT" && SEED_CONTAINER="$CONTAINER" \
    SEED_COOKIES=/tmp/acc/cookies.json SEED_NAV=/tmp/acc/nav.json \
    SEED_DEFAULT_QUALITY="$QUALITY" SEED_TONEMAP_HDR="$TONEMAP" \
    SEED_AUTOPLAY="$AUTOPLAY" \
    flutter test tool/tests/seed_account_test.dart --reporter compact >/dev/null 2>&1 )

xcrun simctl spawn "$SIM" log stream --level debug \
  --predicate 'processImagePath CONTAINS "Runner"' --style compact > "$LOG" 2>&1 &
LOGPID=$!
sleep 2
xcrun simctl launch "$SIM" "$BUNDLE" >/dev/null 2>&1
sleep 15
"$IDB" connect "$SIM" >/dev/null 2>&1
"$IDB" open --udid "$SIM" "bilibili://video/$BVID" >/dev/null 2>&1
sleep 5
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
sleep 20

echo "== frames =="
for i in 0 1 2; do
  xcrun simctl io "$SIM" screenshot "$OUT/f$i.png" >/dev/null 2>&1
  sleep 4
done
python3 "$ROOT/tool/check_player_frame.py" "$OUT"/f*.png

echo "== distinctness (different hashes = playing) =="
for i in 0 1 2; do
  sips -c 500 1260 --cropOffset 210 0 "$OUT/f$i.png" --out "$OUT/c$i.png" >/dev/null 2>&1
  echo "  f$i: $(md5 -q "$OUT/c$i.png" 2>/dev/null | cut -c1-16)"
done

kill $LOGPID 2>/dev/null
echo "== QA_PICK =="
grep -o 'QA_PICK[^"]*' "$LOG" | tail -1 || echo "  (none)"
echo "frames: $OUT"
