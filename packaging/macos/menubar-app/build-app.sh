#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
#
# Compile the menu bar app into a .app bundle (AppKit; no third-party deps).
# Requires the Xcode Command Line Tools (swiftc). Usage: build-app.sh [OUT.app]
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
OUT="${1:-$DIR/Just Syslog.app}"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$DIR/Info.plist" "$OUT/Contents/Info.plist"

swiftc -O "$DIR/main.swift" \
    -o "$OUT/Contents/MacOS/SyslogCollector" \
    -framework AppKit -framework Foundation

# App icon (best-effort; the app still builds if generation fails). Must land
# before codesign, which seals Contents/Resources.
ICONWORK=$(mktemp -d)
if swiftc -O "$DIR/make-icon.swift" -o "$ICONWORK/makeicon" -framework AppKit 2>/dev/null \
   && "$ICONWORK/makeicon" "$ICONWORK/icon-1024.png" >/dev/null 2>&1; then
    ISET="$ICONWORK/AppIcon.iconset"; mkdir -p "$ISET"
    for s in 16 32 128 256 512; do
        sips -z "$s" "$s" "$ICONWORK/icon-1024.png" --out "$ISET/icon_${s}x${s}.png" >/dev/null 2>&1
        d=$((s * 2))
        sips -z "$d" "$d" "$ICONWORK/icon-1024.png" --out "$ISET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ISET" -o "$OUT/Contents/Resources/AppIcon.icns" 2>/dev/null \
        || echo "  (icon: iconutil failed)"
else
    echo "  (icon: generation skipped)"
fi
rm -rf "$ICONWORK"

# Ad-hoc code signature so Gatekeeper doesn't flag it as damaged on this machine.
# (For wide distribution, sign with a Developer ID and notarize instead.)
codesign --force --deep --sign - "$OUT" 2>/dev/null || true

echo "Built: $OUT"
