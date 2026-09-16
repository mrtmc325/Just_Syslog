#!/bin/sh
# Copyright (c) 2026 Tristan Conner <tristan@conner.house>
# SPDX-License-Identifier: MIT
# deb/rpm post-install: create the service user, log dir, and enable the service.
set -e

# Dedicated system user/group (useradd/groupadd exist on Debian and RHEL).
getent group syslog-collector >/dev/null 2>&1 || groupadd --system syslog-collector
id -u syslog-collector >/dev/null 2>&1 || \
    useradd --system --no-create-home --shell /usr/sbin/nologin \
            --gid syslog-collector syslog-collector

mkdir -p /var/log/syslog-collector
chown syslog-collector:syslog-collector /var/log/syslog-collector
chmod 0750 /var/log/syslog-collector

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable --now syslog-collector.service || true
fi

exit 0
