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

# Pinned builder image (specific rustc minor, not the floating rust:1 tag) and a
# pinned, checksum-verified nfpm — reproducible builds, no unverified downloads.
docker run --rm --platform "$PLATFORM" -e ARCH="$ARCH" \
    -v "$ROOT":/work -w /work rust:1.94-bookworm bash -c '
        set -e
        NFPM_VERSION=2.47.0
        case "$(uname -m)" in
            x86_64)  NFPM_ARCH=x86_64; NFPM_SHA=0660ca602b2d2d2ae4781a06c692b3eeb9d437ffea05b831d76e41f4a3188783 ;;
            aarch64) NFPM_ARCH=arm64;  NFPM_SHA=1c0f5f2999b9a974bfb04fdb0cc3306096de530ac5dbb25d739cc5f5219c919c ;;
            *) echo "unexpected arch $(uname -m)"; exit 1 ;;
        esac
        echo "nfpm $NFPM_VERSION ($NFPM_ARCH)"
        curl -sSL -o /tmp/nfpm.tgz "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_Linux_${NFPM_ARCH}.tar.gz"
        echo "${NFPM_SHA}  /tmp/nfpm.tgz" | sha256sum -c -
        tar -xzf /tmp/nfpm.tgz -C /usr/local/bin nfpm
        sh packaging/linux/build-linux-packages.sh
    '

echo ""
echo "Built in $ROOT:"
ls -1 "$ROOT"/just-syslog*.deb "$ROOT"/just-syslog*.rpm 2>/dev/null
