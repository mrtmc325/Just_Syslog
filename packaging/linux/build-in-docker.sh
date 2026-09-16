#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
#
# Build the Linux .deb and .rpm from any host with Docker (e.g. macOS): cross-
# builds the binary in a Linux container and packages it with nfpm. No host Rust
# or nfpm needed. Default amd64; ARCH=arm64 for aarch64. Artifacts land in the
# repo root.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ARCH="${ARCH:-amd64}"
case "$ARCH" in
    amd64) PLATFORM=linux/amd64 ;;
    arm64) PLATFORM=linux/arm64 ;;
    *) echo "Unknown ARCH=$ARCH (use amd64 or arm64)"; exit 1 ;;
esac

command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }

docker run --rm --platform "$PLATFORM" -e ARCH="$ARCH" \
    -v "$ROOT":/work -w /work rust:1-bookworm bash -c '
        set -e
        case "$(uname -m)" in
            x86_64)  NFPM_ARCH=x86_64 ;;
            aarch64) NFPM_ARCH=arm64 ;;
            *) echo "unexpected arch $(uname -m)"; exit 1 ;;
        esac
        curl -sSL -o /tmp/nfpm-latest.json https://api.github.com/repos/goreleaser/nfpm/releases/latest
        VER=$(grep -m1 "\"tag_name\"" /tmp/nfpm-latest.json | cut -d"\"" -f4)
        echo "nfpm $VER ($NFPM_ARCH)"
        curl -sSL -o /tmp/nfpm.tgz "https://github.com/goreleaser/nfpm/releases/download/${VER}/nfpm_${VER#v}_Linux_${NFPM_ARCH}.tar.gz"
        tar -xzf /tmp/nfpm.tgz -C /usr/local/bin nfpm
        sh packaging/linux/build-linux-packages.sh
    '

echo ""
echo "Built in $ROOT:"
ls -1 "$ROOT"/syslog-collector*.deb "$ROOT"/syslog-collector*.rpm 2>/dev/null
