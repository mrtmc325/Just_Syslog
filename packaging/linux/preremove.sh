#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
# deb/rpm pre-remove: stop and disable the service. Logs/config/user are kept.
set -e

if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now syslog-collector.service || true
fi

exit 0
