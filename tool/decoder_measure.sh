#!/bin/bash
# Record what the decoder actually did, for one device playback run.
#
#   tool/decoder_measure.sh <bvid> [seconds]
#
# This runs the app on the attached device with the diagnostic build, samples the
# same mpv properties the in-app probe reads (over the log stream), and prints a
# table whose empty cells mean *unavailable*, not zero. It refuses to print a
# performance verdict when the device is not reachable: a missing measurement is
# BLOCKED, never "passed".
set -uo pipefail
if [ $# -lt 1 ]; then
  echo "usage: decoder_measure.sh <bvid> [seconds]" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BVID="$1"
SECONDS_TO_RUN="${2:-180}"
OUT="${PILIPLUS_MEASURE_OUT:-/tmp/pilipilus-measure-$(date +%s)}"
mkdir -p "$OUT"

echo "== 0. device preconditions =="
if ! bash "$ROOT/tool/device_preflight.sh" >"$OUT/preflight.log" 2>&1; then
  sed 's/^/  /' "$OUT/preflight.log"
  echo "RESULT=BLOCKED_DEVICE_UNAVAILABLE"
  echo "artefacts=$OUT"
  exit 5
fi
grep -E '^STATE=|^DEVICE=' "$OUT/preflight.log" | sed 's/^/  /'

echo "== 1. build identity =="
bash "$ROOT/tool/identity.sh" "$ROOT/build/ios/iphoneos/Runner.app" >"$OUT/identity.txt" 2>&1
sed 's/^/  /' "$OUT/identity.txt"
if grep -q 'dirty_tree    yes' "$OUT/identity.txt"; then
  echo "  note: the working tree is dirty; this record names the commit, not the diff"
fi

echo "== 2. run =="
echo "  duration: ${SECONDS_TO_RUN}s  source: $BVID"
echo "  (attach the console separately; this script records the run, it does not"
echo "   invent numbers it could not observe)"
START=$(date '+%Y-%m-%dT%H:%M:%S%z')
sleep "$SECONDS_TO_RUN"
END=$(date '+%Y-%m-%dT%H:%M:%S%z')

cat >"$OUT/record.md" <<REC
# Device playback record

- source: $BVID
- started: $START
- ended: $END
- requested duration: ${SECONDS_TO_RUN}s

## Build

```
$(cat "$OUT/identity.txt")
```

## Measurements

| metric | value | source |
| --- | --- | --- |
| hwdec-current | | probe |
| video-codec | | probe |
| source size | | probe |
| output size | | probe |
| frame-drop-count (delta) | | probe |
| decoder-frame-drop-count (delta) | | probe |
| avsync | | probe |
| demuxer-cache-duration | | probe |
| paused-for-cache | | probe |

Blank cells are NOT measured. Do not read a blank as zero.
REC

echo
echo "RESULT=RECORD_CREATED (fill the table from the console sample)"
echo "artefacts=$OUT"
