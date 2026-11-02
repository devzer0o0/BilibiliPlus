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
APP="$ROOT/build/ios/iphoneos/Runner.app"
if [ -d "$APP" ]; then
  expect_exit 0 "the real release bundle passes" \
    bash "$ROOT/tool/verify_release_constraints.sh" "$APP"
else
  printf '  SKIP  no release bundle built\n'
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "SELFTEST PASSED"
else
  echo "SELFTEST FAILED"
fi
exit "$FAIL"
