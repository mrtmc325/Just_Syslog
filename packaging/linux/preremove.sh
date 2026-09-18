#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
# deb/rpm pre-remove: stop and disable the service. Logs/config/user are kept.
set -e

# Only stop/disable on real removal, never on upgrade. deb passes "remove"/
# "purge"; rpm passes "0" on final erase (and "1" during an upgrade, which we
# must skip — otherwise rpm's "new %post then old %preun" ordering would disable
# the service the upgrade just started).
case "$1" in
    0 | remove | purge)
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable --now syslog-collector.service || true
        fi
        ;;
esac

exit 0
