#!/bin/bash
# Prove which rendition the player actually selects, via the QA_PICK log line.
#   tool/hdr_pick_check.sh <bvid> <quality> <tonemap>
set -uo pipefail
BVID="${1:?usage: hdr_pick_check.sh <bvid> <quality> <tonemap>}"
QUALITY="${2:-127}"
TONEMAP="${3:-0}"
SIM="${SIM_UDID:-3D5AE91D-601D-4D37-85A1-C8F200A83FEE}"
BUNDLE=com.example.pilipalax
IDB=/tmp/idbenv/bin/idb
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="/tmp/pick_$(date +%s).log"
export PATH=/Users/space/development/fl-3479/flutter/bin:$PATH

xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1
sleep 1
CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
( cd "$ROOT" && SEED_CONTAINER="$CONTAINER" \
    SEED_COOKIES=/tmp/acc/cookies.json SEED_NAV=/tmp/acc/nav.json \
    SEED_DEFAULT_QUALITY="$QUALITY" SEED_TONEMAP_HDR="$TONEMAP" \
    flutter test tool/tests/seed_account_test.dart --reporter compact >/dev/null 2>&1 )

xcrun simctl spawn "$SIM" log stream --predicate 'processImagePath CONTAINS "Runner"' \
  --style compact > "$LOG" 2>&1 &
LOGPID=$!
sleep 2
xcrun simctl launch "$SIM" "$BUNDLE" >/dev/null 2>&1
sleep 14
"$IDB" connect "$SIM" >/dev/null 2>&1
"$IDB" open --udid "$SIM" "bilibili://video/$BVID" >/dev/null 2>&1
sleep 6
python3 - "$SIM" <<'PY'
import json, subprocess, sys, time
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
sleep 18
kill $LOGPID 2>/dev/null
echo "quality=$QUALITY tonemap=$TONEMAP"
grep -o 'QA_PICK[^"]*' "$LOG" | tail -2 || echo "  (no QA_PICK captured)"
