#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
#
# Compile the menu bar app into a .app bundle (AppKit; no third-party deps).
# Requires the Xcode Command Line Tools (swiftc). Usage: build-app.sh [OUT.app]
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT="${1:-$DIR/Syslog Collector.app}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$DIR/Info.plist" "$OUT/Contents/Info.plist"

swiftc -O "$DIR/main.swift" \
    -o "$OUT/Contents/MacOS/SyslogCollector" \
    -framework AppKit -framework Foundation

# Ad-hoc code signature so Gatekeeper doesn't flag it as damaged on this machine.
# (For wide distribution, sign with a Developer ID and notarize instead.)
codesign --force --deep --sign - "$OUT" 2>/dev/null || true

echo "Built: $OUT"
