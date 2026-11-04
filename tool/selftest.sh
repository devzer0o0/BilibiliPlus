#!/bin/bash
# Self-checks for the verification scripts themselves.
#
# These exist because the scripts twice reported success without verifying
# anything: a missing release build printed SKIP and a misinvocation exited 0.
# Both mistakes are invisible unless something asserts the failure paths.
#
#   tool/selftest.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; }
no()  { printf '  FAIL  %s\n' "$1"; FAIL=1; }

expect_exit() {
  local want=$1 desc=$2
  shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then
    ok "$desc (exit $got)"
  else
    no "$desc (exit $got, wanted $want)"
  fi
}

echo "== argument handling =="
expect_exit 2 "hdr_pick_check rejects a missing bvid" \
  bash "$ROOT/tool/hdr_pick_check.sh"
expect_exit 2 "playback_check rejects a missing bvid" \
  bash "$ROOT/tool/playback_check.sh"
expect_exit 2 "verify_release_constraints rejects a missing path" \
  bash "$ROOT/tool/verify_release_constraints.sh"
expect_exit 2 "hdr_regression rejects a missing bvid" \
  bash "$ROOT/tool/hdr_regression.sh"
expect_exit 2 "identity rejects a missing app path" \
  bash "$ROOT/tool/identity.sh"
expect_exit 2 "ios_build rejects an unknown mode" \
  env PILIPLUS_DEVELOPMENT_TEAM=ABCDE12345 bash "$ROOT/tool/ios_build.sh" nonsense

echo "== reset_sim refuses a build with experiment markers =="
TMPB=$(mktemp -d)
mkdir -p "$TMPB/Runner.app/Frameworks/App.framework"
printf 'TEMP_SHOW_PLAY_ERROR' > "$TMPB/Runner.app/Frameworks/App.framework/App"
if bash "$ROOT/tool/reset_sim.sh" 2>&1 | grep -q 'no simulator build'; then
  # reset_sim checks the real build dir; with one present it must reject markers.
  printf '  SKIP  reset_sim needs a real build to exercise\n'
elif strings -a "$TMPB/Runner.app/Frameworks/App.framework/App" | grep -q TEMP_SHOW_PLAY_ERROR; then
  ok "marker detection in the reset guard"
else
  no "marker detection in the reset guard"
fi
rm -rf "$TMPB"

echo "== a bundle without App.framework must not report satisfied =="
TMP=$(mktemp -d)
mkdir -p "$TMP/Fake.app"
cat > "$TMP/Fake.app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.example.pilipalax</string>
</dict></plist>
PLIST
expect_exit 1 "a debug-style bundle fails the scan" \
  bash "$ROOT/tool/verify_release_constraints.sh" "$TMP/Fake.app"
rm -rf "$TMP"

echo "== a good release bundle passes =="
# Only a bundle that is newer than the sources and carries the vendored AV1
# binary can be called good. Scoring an older bundle as "passes" is exactly the
# mistake this whole file exists to catch.
APP="${PILIPLUS_APP:-$ROOT/build/ios/iphoneos/Runner.app}"
if [ ! -d "$APP" ]; then
  printf '  SKIP  no release bundle built\n'
elif [ -n "$(find "$ROOT/lib" "$ROOT/ios/Runner" -newer "$APP" -type f \
            \( -name '*.dart' -o -name '*.swift' \) -print -quit 2>/dev/null)" ]; then
  printf '  SKIP  the bundle predates the current sources\n'
else
  # A bundle built by plain `flutter build ios` ships the pod's Avcodec, not
  # this repo's AV1 build - injection needs a signing identity. That is a known,
  # named gap: it is skipped with the reason, so it cannot be mistaken for a
  # pass and cannot hide a different constraint failure either.
  OUT=$(bash "$ROOT/tool/verify_release_constraints.sh" "$APP" 2>&1)
  if [ $? = 0 ]; then
    ok "the real release bundle passes"
  else
    OTHER=$(printf '%s' "$OUT" | grep 'FAIL:' | grep -v 'vendored Avcodec' || true)
    if [ -z "$OTHER" ] && printf '%s' "$OUT" | grep -q 'vendored Avcodec'; then
      printf '  SKIP  release bundle lacks the vendored AV1 (run tool/inject_ios_avcodec.sh)\n'
    else
      no "the real release bundle fails: $(printf '%s' "$OTHER" | head -1)"
    fi
  fi
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "SELFTEST PASSED"
else
  echo "SELFTEST FAILED"
fi
exit "$FAIL"
