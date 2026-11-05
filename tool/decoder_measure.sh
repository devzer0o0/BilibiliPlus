#!/bin/bash
# Measure what the decoder actually did during one device playback run.
#
#   tool/decoder_measure.sh <bvid> [seconds] [--quality QN]
#
# What this replaces: a script that slept for N seconds, wrote a table with
# every cell empty, and printed "RECORD_CREATED (fill the table from the console
# sample)". An empty table is not a measurement, and a missing value must never
# read as "zero" or as "normal".
#
# How it works now: launches the installed app on the attached iPhone with the
# link, then copies the app's own diagnostics file off the device while
# playback runs and parses the samples the player wrote. Every number below is
# therefore something the app observed, not something this script guessed.
#
# Exit status is a set of named outcomes rather than a pass/fail bit, because
# "the phone was not reachable" and "AV1 was decoded on the CPU" are different
# results and must not collapse into one.
#
#   RESULT=AV1_HARDWARE_CONFIRMED     exit 0
#   RESULT=AV1_SOFTWARE               exit 1   (decoded on the CPU)
#   RESULT=NO_AV1_SAMPLES             exit 3   (nothing to conclude)
#   RESULT=BLOCKED_DEVICE_UNAVAILABLE exit 5
#   RESULT=BLOCKED_NO_WIFI            exit 6   (no signed build installed)
set -uo pipefail

if [ $# -lt 1 ]; then
  echo "usage: decoder_measure.sh <bvid> [seconds] [--quality QN]" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BVID="$1"
SECONDS_TO_RUN="${2:-180}"
QUALITY=""
if [ "${3:-}" = "--quality" ]; then
  QUALITY="${4:-}"
fi
[ -n "$QUALITY" ] || QUALITY="${PILIPLUS_MEASURE_QUALITY:-}"
DEV="${DEVICE_UDID:-00008150-001E5C592E78401C}"
BUNDLE="${PILIPLUS_BUNDLE_ID:-com.example.pilipalax}"
OUT="${PILIPLUS_MEASURE_OUT:-/tmp/pilipilus-measure-$(date +%s)}"
mkdir -p "$OUT"

echo "== 0. device preconditions =="
if ! bash "$ROOT/tool/device_preflight.sh" "$DEV" >"$OUT/preflight.log" 2>&1; then
  sed 's/^/  /' "$OUT/preflight.log"
  echo "RESULT=BLOCKED_DEVICE_UNAVAILABLE"
  echo "artefacts=$OUT"
  exit 5
fi
grep -E '^STATE=|^DEVICE=' "$OUT/preflight.log" | sed 's/^/  /'

echo "== 1. build identity =="
APP="$ROOT/build/ios/iphoneos/Runner.app"
if [ -d "$APP" ]; then
  bash "$ROOT/tool/identity.sh" "$APP" >"$OUT/identity.txt" 2>&1
  sed 's/^/  /' "$OUT/identity.txt"
  bash "$ROOT/tool/ios_av1_package.sh" verify "$APP" >"$OUT/av1-package.txt" 2>&1
  sed 's/^/  /' "$OUT/av1-package.txt"
else
  echo "  no local Runner.app; measurements describe whatever is installed"
fi

LABEL="${BVID}"
if [ -n "$QUALITY" ]; then
  LABEL="${BVID}@${QUALITY}"
fi

echo "== 2. run =="
echo "  duration: ${SECONDS_TO_RUN}s  source: $LABEL"
START="$(date '+%Y-%m-%dT%H:%M:%S%z')"
# Only samples written after this instant describe this run. The diagnostics file
# is append-only across sessions, so without a cut the numbers include every
# earlier playback on the phone - which is how the first version of this script
# reported a mixture of two days of samples as one measurement.
START_ISO="$(date '+%Y-%m-%dT%H:%M:%S')"
xcrun devicectl device process launch --device "$DEV" --terminate-existing \
  --payload-url "bilibili://video/$BVID" "$BUNDLE" >"$OUT/launch.log" 2>&1 \
  || { echo "  launch failed; see $OUT/launch.log"; echo "RESULT=BLOCKED_DEVICE_UNAVAILABLE"; exit 5; }

# Sample the diagnostics file while it is being written. Each copy is a full
# snapshot; the last one is what gets parsed, and the earlier ones make it
# possible to tell "no samples because nothing played" from "no samples because
# the read happened too early".
COLLECTED=""
DEADLINE=$((SECONDS_TO_RUN))
ELAPSED=0
while [ "$ELAPSED" -lt "$DEADLINE" ]; do
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  xcrun devicectl device copy from --device "$DEV" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "Library/Application Support/playback_diag.log" \
    --destination "$OUT/playback_diag.log" >/dev/null 2>&1 \
    && COLLECTED="$OUT/playback_diag.log"
  printf '  %ss/%ss collected=%s\n' "$ELAPSED" "$DEADLINE" \
    "${COLLECTED:+yes}"
done
END="$(date '+%Y-%m-%dT%H:%M:%S%z')"

if [ -z "$COLLECTED" ] || [ ! -s "$COLLECTED" ]; then
  echo "  the app wrote no diagnostics file; nothing was measured"
  echo "RESULT=NO_SAMPLES"
  echo "artefacts=$OUT"
  exit 3
fi

echo "== 3. parse =="
python3 - "$COLLECTED" "$OUT/report.md" "$START_ISO" "$OUT/verdict.txt" <<'PY'
import re, sys

log_path, report_path, since, verdict_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def in_run(line):
    return line[:19] >= since

samples = []
decoder_format = []
sustained = []
renditions = []
for line in open(log_path, encoding='utf-8', errors='replace'):
    if not in_run(line):
        continue
    if ' decoder ' in line:
        samples.append(line)
    if 'mpv-log' in line and 'Decoder format:' in line:
        decoder_format.append(line.strip())
    if 'av1-software-sustained' in line:
        sustained.append(line.strip())
    if ' rendition ' in line:
        renditions.append(line.strip())

def field(line, name):
    m = re.search(rf'{name}=(\S+)', line)
    return m.group(1) if m else None

rows = []
drops_total = 0
drops_seen = 0
avsyncs = []
for line in samples:
    ts = line.split(' ')[0]
    hwdec = field(line, 'hwdec')
    fmt = field(line, 'format')
    src = None
    m = re.search(r'src=(\d+x\d+)', line)
    if m: src = m.group(1)
    delta = field(line, 'drops')
    rows.append((ts, hwdec, fmt, src, delta))
    if delta is not None and delta not in ('?', 'unavailable'):
        try:
            drops_total += int(delta)
            drops_seen += 1
        except ValueError:
            pass
    a = field(line, 'avsync')
    if a and a not in ('?', 'unavailable'):
        try: avsyncs.append(float(a))
        except ValueError: pass

av1 = [r for r in rows if r[2] == 'av1']
av1_hw = [r for r in av1 if r[1] and r[1] != 'no']
av1_sw = [r for r in av1 if r[1] == 'no']

lines = []
lines.append('# Device decoder measurement')
lines.append('')
lines.append(f'- samples parsed: {len(rows)} (AV1: {len(av1)})')
lines.append(f'- AV1 samples on a hardware decoder: {len(av1_hw)}')
lines.append(f'- AV1 samples on a software decoder: {len(av1_sw)}')
lines.append('')
lines.append('| metric | value | source |')
lines.append('| --- | --- | --- |')
lines.append(f'| decoder samples | {len(rows)} | app probe |')
lines.append(f'| AV1 samples | {len(av1)} | app probe |')
lines.append(f'| AV1 hardware samples | {len(av1_hw)} | app probe |')
lines.append(f'| AV1 software samples | {len(av1_sw)} | app probe |')
lines.append(f'| frame-drop delta (sum) | {drops_total if drops_known else ""} | app probe |')
lines.append(f'| avsync max (s) | {max(avsyncs) if avsyncs else ""} | app probe |')
hwdecs = sorted({r[1] for r in rows if r[1]})
lines.append(f'| hwdec values seen | {", ".join(hwdecs) if hwdecs else ""} | app probe |')
fmts = sorted({r[2] for r in rows if r[2]})
lines.append(f'| video formats seen | {", ".join(fmts) if fmts else ""} | app probe |')
srcs = sorted({r[3] for r in rows if r[3]})
lines.append(f'| source sizes | {", ".join(srcs) if srcs else ""} | app probe |')
lines.append('')
lines.append('Blank cells were not measured. A blank is not a zero.')
lines.append('')
if decoder_format:
    lines.append('Decoder format reported by libmpv:')
    lines.append('')
    for d in decoder_format[-3:]:
        lines.append(f'    {d}')
    lines.append('')
if sustained:
    lines.append('Sustained software decode was observed:')
    lines.append('')
    for s in sustained[-3:]:
        lines.append(f'    {s}')
    lines.append('')
if renditions:
    lines.append('Last rendition the app selected:')
    lines.append('')
    lines.append(f'    {renditions[-1]}')
    lines.append('')

open(report_path, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')

# Verdict. Only AV1 samples about a hardware decoder can confirm anything, and
# an absence of samples is reported as such rather than as a pass.
if not av1:
    verdict = 'NO_AV1_SAMPLES'
elif av1_hw and not av1_sw:
    verdict = 'AV1_HARDWARE_CONFIRMED'
elif av1_hw and av1_sw:
    verdict = 'AV1_MIXED'
else:
    verdict = 'AV1_SOFTWARE'
# Written where the caller reads it: printing it was not enough, and a verdict
# that the shell cannot see degraded every good run to "no samples".
open(verdict_path, 'w', encoding='utf-8').write(verdict + chr(10))
print('VERDICT=' + verdict)
PY
PARSE_STATUS=$?
sed 's/^/  /' "$OUT/report.md"

if [ "$PARSE_STATUS" != "0" ]; then
  echo "RESULT=PARSE_FAILED"
  echo "artefacts=$OUT"
  exit 4
fi

{
  echo "# Device playback record"
  echo
  echo "- source: $LABEL"
  echo "- started: $START"
  echo "- ended: $END"
  echo
  echo "## Build"
  echo
  echo '```'
  cat "$OUT/identity.txt" 2>/dev/null
  cat "$OUT/av1-package.txt" 2>/dev/null
  echo '```'
  echo
  cat "$OUT/report.md" 2>/dev/null
} >"$OUT/record.md"

VERDICT="$(head -1 "$OUT/verdict.txt" 2>/dev/null)"
case "$VERDICT" in
  AV1_HARDWARE_CONFIRMED) echo "RESULT=AV1_HARDWARE_CONFIRMED"; echo "artefacts=$OUT"; exit 0 ;;
  AV1_SOFTWARE)           echo "RESULT=AV1_SOFTWARE";           echo "artefacts=$OUT"; exit 1 ;;
  AV1_MIXED)              echo "RESULT=AV1_MIXED (hardware and software samples in one run)"; echo "artefacts=$OUT"; exit 1 ;;
  *)                      echo "RESULT=NO_AV1_SAMPLES";         echo "artefacts=$OUT"; exit 3 ;;
esac
