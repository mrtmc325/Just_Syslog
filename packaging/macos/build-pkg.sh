#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
#
# Build the macOS installer (.pkg) with pkgbuild (ships with macOS - no extra
# tooling). Host arch by default; pass -universal for a fat arm64+x86_64 binary
# (needs rustup with both apple-darwin targets).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
VERSION=1.0.2

if [ "$1" = "-universal" ]; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin
    cargo build --release --target aarch64-apple-darwin
    cargo build --release --target x86_64-apple-darwin
    BIN=$(mktemp)
    lipo -create -output "$BIN" \
        target/aarch64-apple-darwin/release/syslogd \
        target/x86_64-apple-darwin/release/syslogd
else
    cargo build --release
    BIN="$ROOT/target/release/syslogd"
fi

# Menu bar controller app (-> /Applications).
APPDIR=$(mktemp -d)
sh packaging/macos/menubar-app/build-app.sh "$APPDIR/Syslog Collector.app" >/dev/null

STAGE=$(mktemp -d)
mkdir -p "$STAGE/usr/local/bin" "$STAGE/Library/LaunchDaemons" "$STAGE/Library/LaunchAgents" \
         "$STAGE/etc/syslog-collector" "$STAGE/Applications"
install -m 0755 "$BIN" "$STAGE/usr/local/bin/syslog-collector"
install -m 0644 packaging/launchd/house.conner.syslog-collector.plist "$STAGE/Library/LaunchDaemons/"
install -m 0644 packaging/launchd/house.conner.syslog-collector.menubar.plist "$STAGE/Library/LaunchAgents/"
install -m 0644 packaging/config.sample.txt "$STAGE/etc/syslog-collector/config.txt"
cp -R "$APPDIR/Syslog Collector.app" "$STAGE/Applications/"

chmod +x packaging/macos/scripts/postinstall

# Force the app to install at /Applications rather than being relocated to any
# existing copy the installer discovers (pkgbuild defaults bundles to relocatable).
COMPONENT="$APPDIR/component.plist"
pkgbuild --analyze --root "$STAGE" "$COMPONENT" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT" 2>/dev/null \
    || plutil -replace 0.BundleIsRelocatable -bool false "$COMPONENT"

OUT="$ROOT/SyslogCollector-${VERSION}-macos.pkg"
pkgbuild \
    --root "$STAGE" \
    --component-plist "$COMPONENT" \
    --scripts packaging/macos/scripts \
    --identifier house.conner.syslog-collector \
    --version "$VERSION" \
    --install-location / \
    "$OUT"

rm -rf "$STAGE" "$APPDIR"
echo "Built: $OUT"
echo "  Installs: launchd service + /Applications/Syslog Collector.app (menu bar control)"
echo "Install:   sudo installer -pkg \"$OUT\" -target /"
echo "Uninstall: see packaging/README.md"
