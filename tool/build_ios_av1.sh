#!/usr/bin/env bash
set -euo pipefail

# Build a signed iOS Release with the AV1 VideoToolbox Avcodec.
# Usage:
#   IOS_SIGN_IDENTITY='...' IOS_PROVISIONING_PROFILE='/path/profile.mobileprovision' \
#     tool/build_ios_av1.sh <version> <build-number>
# FLUTTER must point at the Flutter 3.47.9 SDK root, or its bin must be on PATH.

version="${1:?usage: $0 <version> <build-number>}"
build_number="${2:?usage: $0 <version> <build-number>}"
identity="${IOS_SIGN_IDENTITY:?set IOS_SIGN_IDENTITY}"
profile="${IOS_PROVISIONING_PROFILE:?set IOS_PROVISIONING_PROFILE}"
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/ios/iphoneos/Runner.app"

if [[ -n "${FLUTTER:-}" ]]; then
  export PATH="$FLUTTER/bin:$PATH"
fi

git_hash="$(git -C "$root" rev-parse HEAD)"
build_time="$(date +%s)"

cd "$root"
flutter pub get
flutter build ios --release --no-codesign --no-pub \
  --build-name "$version" \
  --build-number "$build_number" \
  --dart-define="pili.name=$version" \
  --dart-define="pili.code=$build_number" \
  --dart-define="pili.hash=$git_hash" \
  --dart-define="pili.time=$build_time"

# Replace, then verify identity/exports/dependencies before signing. A failure
# here stops the build: an app whose AV1 decoder silently reverted to the pod's
# copy decodes 4K on the CPU and looks, from the device, like unsupported
# hardware.
bash "$root/tool/ios_av1_package.sh" install "$app"
cp "$profile" "$app/embedded.mobileprovision"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
security cms -D -i "$profile" > "$tmp/profile.plist"
plutil -extract Entitlements xml1 -o "$tmp/entitlements.plist" "$tmp/profile.plist"

find "$app/Frameworks" -maxdepth 1 -type d -name '*.framework' -print0 |
  while IFS= read -r -d '' framework; do
    codesign --force --sign "$identity" --timestamp=none "$framework"
  done
codesign --force --sign "$identity" --entitlements "$tmp/entitlements.plist" \
  --timestamp=none --generate-entitlement-der "$app"
codesign --verify --deep --strict --verbose=2 "$app"
bash "$root/tool/ios_av1_package.sh" verify "$app"

echo "Built signed app: $app"
echo "Install with:"
echo "  xcrun devicectl device install app --device <UDID> '$app'"
