# Packaging (macOS / Linux)

Same collector as Windows — UDP/514 receiver, JSON-lines storage, local web
viewer on `http://127.0.0.1:8514/`, age/size retention — supervised by the
platform init system instead of the Windows SCM. The binary is installed as
**`syslog-collector`** on Unix (to avoid clashing with the traditional
`syslogd`). Paths:

| | macOS / Linux |
|---|---|
| Binary | `/usr/local/bin` (macOS) · `/usr/bin` (Linux) |
| Config | `/etc/syslog-collector/config.txt` |
| Logs   | `/var/log/syslog-collector` (set `log_dir` in config to change) |
| Service | launchd `house.conner.syslog-collector` · systemd `syslog-collector.service` |

## macOS `.pkg`

Build (needs Rust + Xcode Command Line Tools; `pkgbuild` ships with macOS):

```bash
./packaging/macos/build-pkg.sh            # host arch
./packaging/macos/build-pkg.sh -universal # arm64 + x86_64 (needs rustup targets)
```

Install / uninstall:

```bash
sudo installer -pkg SyslogCollector-1.0.0-macos.pkg -target /
# uninstall:
sudo launchctl bootout system /Library/LaunchDaemons/house.conner.syslog-collector.plist
sudo rm /Library/LaunchDaemons/house.conner.syslog-collector.plist /usr/local/bin/syslog-collector
sudo rm -rf "/Applications/Syslog Collector.app"
# (logs under /var/log/syslog-collector are left in place)
```

The daemon runs as **root** (needed to bind port 514), starts at boot
(`RunAtLoad`), and restarts on crash (`KeepAlive`).

### Menu bar app

The pkg also installs **`/Applications/Syslog Collector.app`** — a menu bar
controller (AppKit, no dependencies). Open it from Applications (add it to
**System Settings → General → Login Items** to have it start automatically). Its
menu bar icon shows service status (polled from the loopback API) and lets you:

- **Configuration…** — edit `log_dir`, ports, and retention, then Save & Restart.
- **Start / Stop Service** — controls the launchd daemon.
- **Clear Logs…** — delete all `.jsonl` files and restart the collector.
- **Open Viewer** — open `http://127.0.0.1:8514/`.

Service control and config writes touch root-owned paths, so each prompts once
for admin credentials (macOS caches them briefly). Status polling needs no
privilege.

## Linux `.deb` + `.rpm`

Build on the target arch (needs Rust + [nfpm](https://nfpm.goreleaser.com/install/)):

```bash
./packaging/linux/build-linux-packages.sh          # amd64
ARCH=arm64 ./packaging/linux/build-linux-packages.sh
```

Install:

```bash
sudo apt install ./syslog-collector_1.0.0_amd64.deb     # Debian/Ubuntu
sudo dnf install ./syslog-collector-1.0.0.x86_64.rpm    # RHEL/Fedora
```

The package creates a dedicated `syslog-collector` system user, enables the
systemd service (auto-start at boot), and grants it `CAP_NET_BIND_SERVICE` so
it binds 514 without running as root. Manage it with
`systemctl status|restart|stop syslog-collector`.

## Firewall

Not opened automatically (Linux firewalls vary; auto-editing them is risky).
Allow inbound UDP/514 as your setup requires, e.g.:

```bash
sudo ufw allow 514/udp                                  # ufw
sudo firewall-cmd --permanent --add-port=514/udp && sudo firewall-cmd --reload   # firewalld
```

macOS: the application firewall is per-app; allow `syslog-collector` if prompted.

## Notes

- The web viewer binds loopback only; only UDP/514 is network-facing.
- Set the log folder by editing `log_dir` in `/etc/syslog-collector/config.txt`,
  then restart the service.
- No runtime dependencies — a single static-ish native binary, zero external
  crates on Unix.
