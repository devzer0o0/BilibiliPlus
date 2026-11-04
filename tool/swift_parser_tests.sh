#!/bin/bash
# Runs the pure-Swift playback parsers against their fixtures.
#
#   tool/swift_parser_tests.sh
#
# The DASH index reader, the HLS playlist builder and the ISO-BMFF sample-entry
# patcher have no UIKit or AVFoundation dependency, so they can be exercised on
# the host without a device or a simulator. The sources are the ones in
# ios/Runner: the harness copies them, it does not fork them.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/Sources/Parser" "$WORK/Tests/ParserTests"
cp "$ROOT/ios/Runner/DashIndex.swift" \
   "$ROOT/ios/Runner/HlsBridge.swift" \
   "$ROOT/ios/Runner/Mp4BoxPatcher.swift" \
   "$ROOT/ios/Runner/HdrCapability.swift" \
   "$ROOT/ios/Runner/ColorDescription.swift" \
   "$WORK/Sources/Parser/"
cp "$ROOT"/ios/RunnerTests/*.swift "$WORK/Tests/ParserTests/"

# HlsBridge imports Network; the tests import the module, not the app.
sed -i.bak 's/^import Foundation$/import Foundation\nimport Network/' \
  "$WORK/Sources/Parser/HlsBridge.swift"
sed -i.bak 's/^import XCTest$/import XCTest\n@testable import Parser/' \
  "$WORK"/Tests/ParserTests/*.swift
find "$WORK" -name '*.bak' -delete

cat > "$WORK/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "Parser",
  platforms: [.macOS(.v12)],
  targets: [
    .target(name: "Parser"),
    .testTarget(name: "ParserTests", dependencies: ["Parser"]),
  ]
)
EOF

cd "$WORK" && swift test 2>&1 | tail -20
exit "${PIPESTATUS[0]}"
