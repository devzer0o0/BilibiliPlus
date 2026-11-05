#!/usr/bin/env bash
set -euo pipefail

# Replace Avcodec in an already Xcode-signed Runner.app with the AV1 VideoToolbox
# build, then re-sign the framework and the app.
#
# The replacement and its identity checks live in tool/ios_av1_package.sh, which
# every entry point shares: doing it in each caller is how one of them ended up
# treating a failed injection as a note and shipping an app without AV1.
#
# Required environment:
#   IOS_SIGN_IDENTITY      e.g. 63F1AB35... (security find-identity -v -p codesigning)
#   IOS_PROVISIONING_PROFILE  path to the matching .mobileprovision
app="${1:?usage: $0 /path/to/Runner.app}"
identity="${IOS_SIGN_IDENTITY:?set IOS_SIGN_IDENTITY}"
profile="${IOS_PROVISIONING_PROFILE:?set IOS_PROVISIONING_PROFILE}"
root="$(cd "$(dirname "$0")/.." && pwd)"

bash "$root/tool/ios_av1_package.sh" install "$app"

cp "$profile" "$app/embedded.mobileprovision"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
security cms -D -i "$profile" > "$tmp/profile.plist"
plutil -extract Entitlements xml1 -o "$tmp/entitlements.plist" "$tmp/profile.plist"

codesign --force --sign "$identity" --timestamp=none \
  "$app/Frameworks/Avcodec.framework"
codesign --force --sign "$identity" --entitlements "$tmp/entitlements.plist" \
  --timestamp=none --generate-entitlement-der "$app"
codesign --verify --deep --strict "$app"

# Verified once more after signing: the binary that ships is the binary that was
# checked, now inside a signature.
bash "$root/tool/ios_av1_package.sh" verify "$app"
echo "Injected AV1 VideoToolbox Avcodec into: $app"
