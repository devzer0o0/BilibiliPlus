#!/usr/bin/env bash
set -euo pipefail

# Replace Avcodec in an already Xcode-signed Runner.app, then re-sign the
# framework and the app. The app's other frameworks must already be valid.
#
# Required environment:
#   IOS_SIGN_IDENTITY      e.g. 63F1AB35... (security find-identity -v -p codesigning)
#   IOS_PROVISIONING_PROFILE  path to the matching .mobileprovision
app="${1:?usage: $0 /path/to/Runner.app}"
identity="${IOS_SIGN_IDENTITY:?set IOS_SIGN_IDENTITY}"
profile="${IOS_PROVISIONING_PROFILE:?set IOS_PROVISIONING_PROFILE}"
root="$(cd "$(dirname "$0")/.." && pwd)"
framework="$app/Frameworks/Avcodec.framework"

[[ -d "$framework" ]] || { echo "missing $framework" >&2; exit 1; }
cp "$root/ios/av1/Avcodec" "$framework/Avcodec"
chmod 755 "$framework/Avcodec"
plutil -replace MinimumOSVersion -string 15.0 "$framework/Info.plist"
cp "$profile" "$app/embedded.mobileprovision"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
security cms -D -i "$profile" > "$tmp/profile.plist"
plutil -extract Entitlements xml1 -o "$tmp/entitlements.plist" "$tmp/profile.plist"
codesign --force --sign "$identity" --timestamp=none "$framework"
codesign --force --sign "$identity" --entitlements "$tmp/entitlements.plist" \
  --timestamp=none --generate-entitlement-der "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "Injected AV1 VideoToolbox Avcodec into: $app"
