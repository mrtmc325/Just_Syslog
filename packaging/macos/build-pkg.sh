#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
#
# Build the macOS installer (.pkg) with pkgbuild (ships with macOS - no extra
# tooling). Host arch by default; pass -universal for a fat arm64+x86_64 binary
# (needs rustup with both apple-darwin targets).
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
VERSION=1.0.0

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

STAGE=$(mktemp -d)
mkdir -p "$STAGE/usr/local/bin" "$STAGE/Library/LaunchDaemons" "$STAGE/etc/syslog-collector"
install -m 0755 "$BIN" "$STAGE/usr/local/bin/syslog-collector"
install -m 0644 packaging/launchd/house.conner.syslog-collector.plist "$STAGE/Library/LaunchDaemons/"
install -m 0644 packaging/config.sample.txt "$STAGE/etc/syslog-collector/config.txt"

chmod +x packaging/macos/scripts/postinstall
OUT="$ROOT/SyslogCollector-${VERSION}-macos.pkg"
pkgbuild \
    --root "$STAGE" \
    --scripts packaging/macos/scripts \
    --identifier house.conner.syslog-collector \
    --version "$VERSION" \
    --install-location / \
    "$OUT"

rm -rf "$STAGE"
echo "Built: $OUT"
echo "Install:   sudo installer -pkg \"$OUT\" -target /"
echo "Uninstall: see packaging/README.md"
