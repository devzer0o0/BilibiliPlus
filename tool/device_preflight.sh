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
json_devices() {
  xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null
}

attempt=0
while [ "$attempt" -lt "$RETRIES" ]; do
  attempt=$((attempt + 1))
  NOW=$(date +%s)
  [ $((NOW - START)) -ge "$DEADLINE" ] && \
    state BLOCKED_DEVICE_UNAVAILABLE "deadline ${DEADLINE}s exceeded after $attempt attempt(s)" 5

  LIST=$(json_devices)
  REACH=""
  LOCKED=""
  if [ -n "$LIST" ] && command -v python3 >/dev/null; then
    read -r REACH LOCKED <<<"$(printf '%s' "$LIST" | python3 - "$UDID" <<'PY'
import json, sys
udid = sys.argv[1]
try:
    doc = json.load(sys.stdin)
except Exception:
    print("parse-error unknown"); raise SystemExit(0)
devices = doc.get("result", {}).get("devices", [])
for d in devices:
    ident = (d.get("hardwareProperties") or {}).get("udid", "")
    if ident != udid:
        continue
    conn = (d.get("connectionProperties") or {}).get("tunnelState", "")
    paired = (d.get("connectionProperties") or {}).get("pairingState", "")
    boot = (d.get("deviceProperties") or {}).get("bootState", "")
    print(f"{conn or paired or boot or 'unknown'} {boot or 'unknown'}")
    raise SystemExit(0)
print("missing unknown")
PY
)"
  fi

  case "${REACH:-}" in
    connected|available|paired)
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
    missing)
      sleep 5
      ;;
    "")
      sleep 5
      ;;
    *)
      sleep 5
      ;;
  esac
done
state BLOCKED_DEVICE_UNAVAILABLE "device $UDID not reachable after $RETRIES attempts" 5
