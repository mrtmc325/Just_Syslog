# Just Syslog

**Syslog on the fly.** When the network or a system is going sideways, stand this
up on any host, point the failing gear at it (UDP/514), and read the logs
immediately in a clean local viewer. Fast to deploy, fast to read, easy to tear
down — a disposable syslog sink for the moment you actually need the logs.

- Listens on **UDP/514**; parses RFC 3164 / RFC 5424 (and anything else,
  best-effort); writes newline-delimited JSON, one file per day.
- **Single native binary**, no runtime. Auto-start service (Windows service /
  launchd / systemd).
- **Local web viewer** at `http://127.0.0.1:8514/` (loopback only) — click any
  row for full message detail.
- **Tray / menu bar controller** (Windows + macOS): start/stop, edit config,
  clear logs, open the viewer.
- Automatic log retention by age and total size, plus a **Run cleanup** button.
- One dependency (`windows-service`, Windows only); standard library elsewhere.

## Install — Windows

Build the MSI once (needs [WiX v5](https://wixtoolset.org)
`dotnet tool install --global wix`, plus Rust + the MSVC build tools), then ship
the single `.msi`:

```powershell
.\installer\build-msi.ps1
```
```powershell
msiexec /i JustSyslog-1.0.2-x64.msi LOGDIR="D:\Logs"
```

Installs the service (auto-start), opens **UDP/514** in the firewall, drops a
**tray icon** with **Start Menu / Desktop shortcuts**, and registers in Add/Remove
Programs. `LOGDIR` is optional (default `C:\SyslogCollector\logs`); add `/qn` for
silent; `msiexec /x` reverses everything.

No build tooling? `installer\install.ps1 -LogDir "D:\Logs"` (elevated) does the
same without WiX.

**Tray controller** — right-click the icon to Start/Stop the service, edit
**Configuration**, **Clear Logs**, or **Open Viewer**; **Quit** stops the service
and exits. Status shows in the tooltip; service actions prompt for UAC.

## Install — macOS / Linux

```bash
./packaging/macos/build-pkg.sh          # macOS -> .pkg (launchd + menu bar app)
./packaging/linux/build-in-docker.sh    # Linux -> .deb + .rpm (from any Docker host)
```
```bash
sudo installer -pkg JustSyslog-1.0.2-macos.pkg -target /
sudo apt install ./just-syslog_1.0.2_amd64.deb            # Debian/Ubuntu
sudo dnf install ./just-syslog-1.0.2-1.x86_64.rpm         # RHEL/Fedora
```

macOS gets the same controller as the Windows tray, in the **menu bar**. Config at
`/etc/syslog-collector/config.txt`, logs at `/var/log/syslog-collector`. Details
and uninstall: [`packaging/README.md`](packaging/README.md).

## Use

1. **Point devices** at this host's IP, UDP **514** (open it on any firewall in
   between — the installer opens the local one).
2. **Open the viewer** — tray → *Open Viewer*, or <http://127.0.0.1:8514/>. The
   first message creates today's log file.

## Configuration

`%ProgramData%\SyslogCollector\config.txt` (Windows) or
`/etc/syslog-collector/config.txt`. Edit from the tray / menu bar, or by hand and
restart the service.

| Key | Default | Meaning |
|-----|---------|---------|
| `log_dir` | set at install | Folder for log files |
| `udp_port` | `514` | Syslog listen port |
| `ui_port` | `8514` | Local viewer port (loopback) |
| `max_file_mb` | `100` | Rotate the active file past this size |
| `retention_days` | `30` | Delete files older than this (`0` = keep) |
| `max_total_mb` | `2048` | Trim oldest files past this total (`0` = no cap) |

## Uninstall

Windows: **Add/Remove Programs**, or `installer\uninstall.ps1` (elevated).
macOS / Linux: see [`packaging/README.md`](packaging/README.md). Logs are left in place.

## Build from source

```powershell
.\build.ps1 -X86        # Windows: x64 (+ x86); binaries in dist\
```
```bash
cargo build --release   # macOS / Linux -> target/release/syslogd
```

Try it without installing (any OS, non-privileged ports):

```bash
syslogd run --udp-port 5514 --ui-port 8514 --log-dir ./logs
```

## Notes

- The viewer binds **127.0.0.1 only** (and validates `Host`, so a web page can't
  DNS-rebind to it); only UDP/514 faces the network. Log fields render as text
  (no HTML injection); the file API is allow-listed (no path traversal).
- Logs are **clear-text** files holding whatever devices send. Point `log_dir` at
  an encrypted volume for sensitive data, and keep it off regulated-data hosts
  unless in scope and approved.

Copyright (c) 2026 Tristan Conner <tristan@conner.house> — [MIT License](LICENSE).
