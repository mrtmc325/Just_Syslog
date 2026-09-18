#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
#
# Build .deb and .rpm on Linux. Requires Rust and nfpm
# (https://nfpm.goreleaser.com/install/). Build on the target arch (default
# amd64); cross-building needs the matching linker toolchain.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

ARCH="${ARCH:-amd64}"          # amd64 | arm64  (deb naming; nfpm maps rpm to x86_64/aarch64)
case "$ARCH" in
    amd64) TARGET=x86_64-unknown-linux-gnu ;;
    arm64) TARGET=aarch64-unknown-linux-gnu ;;
    *) echo "Unknown ARCH=$ARCH (use amd64 or arm64)"; exit 1 ;;
esac

command -v nfpm >/dev/null 2>&1 || { echo "nfpm not found - install: https://nfpm.goreleaser.com/install/"; exit 1; }

rustup target add "$TARGET" >/dev/null 2>&1 || true
cargo build --release --target "$TARGET"

BIN="$ROOT/target/$TARGET/release/syslogd"
[ -f "$BIN" ] || { echo "binary not found: $BIN"; exit 1; }

# Render the nfpm template with concrete values (sed, so it never depends on
# nfpm's own env-var expansion). Placeholders are regex-safe.
RENDERED="$ROOT/target/nfpm.rendered.yaml"
sed -e "s|@@ARCH@@|$ARCH|g" -e "s|@@BIN@@|$BIN|g" packaging/nfpm.yaml > "$RENDERED"

nfpm package -f "$RENDERED" -p deb
nfpm package -f "$RENDERED" -p rpm
rm -f "$RENDERED"

echo "Built in $ROOT:"
ls -1 just-syslog*.deb just-syslog*.rpm 2>/dev/null
