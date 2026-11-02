#!/bin/bash
# Repeatable HDR playback check in the iOS simulator.
#
# Seeds a logged-in account with a pinned quality / tone-mapping state, opens a
# title, captures frames and classifies them as black / green / ok.
#
#   tool/hdr_regression.sh <bvid> [quality] [tonemap]
#
# quality: bilibili quality id (127 = 8K default, 125 = HDR, 126 = Dolby Vision)
# tonemap: 1 = HDR tone mapping on, 0 = off
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: hdr_regression.sh <bvid> [quality] [tonemap]" >&2
  exit 2
fi
BVID="$1"
QUALITY="${2:-127}"
TONEMAP="${3:-0}"

SIM="${SIM_UDID:-3D5AE91D-601D-4D37-85A1-C8F200A83FEE}"
BUNDLE=com.example.pilipalax
IDB=/tmp/idbenv/bin/idb
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="/tmp/hdr_regress_$(date +%s)"

export PATH=/Users/space/development/fl-3479/flutter/bin:$PATH
mkdir -p "$OUT"

echo "== seeding quality=$QUALITY tonemap=$TONEMAP =="
xcrun simctl terminate "$SIM" "$BUNDLE" >/dev/null 2>&1
sleep 2
CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
( cd "$ROOT" && SEED_CONTAINER="$CONTAINER" \
    SEED_COOKIES=/tmp/acc/cookies.json SEED_NAV=/tmp/acc/nav.json \
    SEED_DEFAULT_QUALITY="$QUALITY" SEED_TONEMAP_HDR="$TONEMAP" \
    flutter test tool/tests/seed_account_test.dart --reporter compact 2>&1 \
  | grep -E 'seeded|failed' | tail -1 )

echo "== launching =="
xcrun simctl launch "$SIM" "$BUNDLE" >/dev/null 2>&1
sleep 15
"$IDB" connect "$SIM" >/dev/null 2>&1
sleep 2

echo "== opening $BVID =="
"$IDB" open --udid "$SIM" "bilibili://video/$BVID" >/dev/null 2>&1
sleep 3
# confirm the "open in app" system dialog if it appears
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
        time.sleep(15)
        break
PY

echo "== capturing =="
for i in 0 1 2 3; do
  xcrun simctl io "$SIM" screenshot "$OUT/f$i.png" >/dev/null 2>&1
  sleep 3
done

# Reveal the player chrome and report the quality it says it is on. Without
# this the frame check alone cannot tell a 360p capture from an HDR one.
echo "== reported quality =="
python3 - "$SIM" <<'PY'
import json, subprocess, sys, time
sim = sys.argv[1]
idb = "/tmp/idbenv/bin/idb"
for attempt in range(3):
    subprocess.run([idb, "ui", "tap", "--udid", sim, "210", "180"],
                   capture_output=True, timeout=60)
    time.sleep(2)
    raw = subprocess.run([idb, "ui", "describe-all", "--udid", sim],
                         capture_output=True, text=True, timeout=90).stdout
    try:
        nodes = json.loads(raw)
    except Exception:
        nodes = []
    labels = [(n.get("AXLabel") or "").replace("\n", "/") for n in nodes]
    hits = [l for l in labels if "当前画质" in l or "正在播放" in l]
    if hits:
        for h in hits[:3]:
            print("  ", h[:70])
        break
else:
    print("   (player chrome not reachable)")
PY

echo "== classifying =="
python3 "$ROOT/tool/check_player_frame.py" "$OUT"/f*.png
echo "frames kept in $OUT"
