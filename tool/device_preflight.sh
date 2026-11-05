#!/bin/bash
# Device preconditions, and only that.
#
#   tool/device_preflight.sh [udid]
#
# The old check piped `devicectl launch` through `grep Locked` and called it a
# PASS when that string was absent - but a missing device, an untrusted host or
# a signing problem all produce different text, so "no Locked" meant nothing.
# Every outcome here is one explicit state:
#
#   BLOCKED_TOOLING             xcodebuild/devicectl missing
#   BLOCKED_DEVICE_UNAVAILABLE  no device, or not reachable/paired
#   BLOCKED_LOCKED             device present but locked
#   BLOCKED_SIGNING             build or install cannot be signed for this device
#   READY                       installable and launchable
#
# Bounded: at most RETRIES attempts with a total deadline. It never unlocks the
# phone, reboots it, or changes security settings - an install that needs the
# device unlocked is an environment precondition, not a test result.
set -uo pipefail

UDID="${1:-${DEVICE_UDID:-00008150-001E5C592E78401C}}"
RETRIES="${DEVICE_PREFLIGHT_RETRIES:-3}"
DEADLINE="${DEVICE_PREFLIGHT_DEADLINE:-120}"
BUNDLE=com.example.pilipalax
START=$(date +%s)

say()  { printf '%s\n' "$1"; }
state() { say "STATE=$1"; say "REASON=$2"; exit "$3"; }

command -v xcrun >/dev/null || state BLOCKED_TOOLING "xcrun not found" 4
xcrun devicectl --help >/dev/null 2>&1 || state BLOCKED_TOOLING "devicectl unavailable" 4
xcrun devicectl --version >/dev/null 2>&1 || state BLOCKED_TOOLING "devicectl broken" 4

# devicectl prints a human table by default. Ask for JSON, and fall back only
# when this build of the tool does not offer it.
# (removed: writing JSON to stdout while python read its program from a heredoc
#  discarded the data; the device list is written to a temp file instead.)

attempt=0
while [ "$attempt" -lt "$RETRIES" ]; do
  attempt=$((attempt + 1))
  NOW=$(date +%s)
  [ $((NOW - START)) -ge "$DEADLINE" ] && \
    state BLOCKED_DEVICE_UNAVAILABLE "deadline ${DEADLINE}s exceeded after $attempt attempt(s)" 5

  # The JSON must arrive as a file, not on stdin: python reads its program from
  # the heredoc, and a pipe on the same line is silently discarded. That made
  # every parse fail, which this script then reported as "device not reachable"
  # - a false BLOCKED on a phone that was connected the whole time.
  LIST_FILE=$(mktemp -t pilipilus-devs)
  xcrun devicectl list devices --json-output "$LIST_FILE" >/dev/null 2>&1
  REACH=""
  LOCKED=""
  if [ -s "$LIST_FILE" ] && command -v python3 >/dev/null; then
    read -r REACH LOCKED <<<"$(python3 - "$LIST_FILE" "$UDID" <<'PY'
import json, sys
udid = sys.argv[2]
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("parse-error unknown"); raise SystemExit(0)
devices = doc.get("result", {}).get("devices", [])
for d in devices:
    # CoreDevice moved these into a per-device properties dictionary
    # (connection/hardware/software/state). Reading only the deprecated
    # hardwareProperties/connectionProperties shape reported a connected
    # phone as missing - the one answer this script must never get wrong.
    props = d.get("properties") or {}
    hw = props.get("hardware") or d.get("hardwareProperties") or {}
    conn_props = props.get("connection") or d.get("connectionProperties") or {}
    dev_props = props.get("deviceProperties") or d.get("deviceProperties") or {}
    if hw.get("udid", "") != udid:
        continue
    state = props.get("state") or ""
    conn = (conn_props.get("tunnelState")
            or conn_props.get("transportType") or "")
    paired = conn_props.get("pairingState") or ""
    boot = dev_props.get("bootState") or ""
    reach = conn or state or paired or boot or "unknown"
    print(f"{reach} {boot or 'unknown'}")
    raise SystemExit(0)
print("missing unknown")
PY
)"
  fi
  rm -f "$LIST_FILE"

  # A device that a launch can reach is reachable, whatever the transport
  # field says.
  #
  # The connection dictionary reports `state: disconnected` for a phone on the
  # local network that is perfectly usable - it describes the *tunnel*, which is
  # only established on demand. Gating on that word reported
  # BLOCKED_DEVICE_UNAVAILABLE for a device that accepted launches the whole
  # time, which then made every measurement script refuse to run. The launch is
  # the capability; this list only rejects the states that cannot be.
  case "${REACH:-}" in
    missing|"")
      sleep 5
      ;;
    *)
      LOCKED_CHECK=$(xcrun devicectl device info details --device "$UDID" 2>&1 | head -40)
      if printf '%s' "$LOCKED_CHECK" | grep -qi locked; then
        state BLOCKED_LOCKED "device $UDID reports locked; unlock it and rerun" 6
      fi
      # A launch failure that is not about the lock is either signing or the
      # device refusing to talk; distinguish them by the tool's own message.
      OUT=$(xcrun devicectl device process launch --device "$UDID" "$BUNDLE" 2>&1)
      RC=$?
      if [ "$RC" = "0" ]; then
        say "STATE=READY"
        say "DEVICE=$UDID"
        say "ATTEMPTS=$attempt"
        exit 0
      fi
      case "$OUT" in
        *Locked*)     state BLOCKED_LOCKED "device is locked" 6 ;;
        *"not connected"*|*"unavailable"*|*"timed out"*|*"No device"*)
                      ;; # retryable
        *"ApplicationVerificationFailed"*|*"not signed"*|*"no valid"*|*"provisioning"*)
                      state BLOCKED_SIGNING "$(printf '%s' "$OUT" | head -2 | tr '\n' ' ')" 7 ;;
        *)            say "launch output: $(printf '%s' "$OUT" | head -3 | tr '\n' ' ')"
                      state BLOCKED_DEVICE_UNAVAILABLE "launch refused for an unrecognised reason" 5 ;;
      esac
      ;;
  esac
done
state BLOCKED_DEVICE_UNAVAILABLE "device $UDID not reachable after $RETRIES attempts" 5
