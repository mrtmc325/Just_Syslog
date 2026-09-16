# Syslog Collector

A lean Windows syslog server. Listens on **UDP/514**, parses RFC 3164 / RFC 5424
(and anything else, best-effort), writes newline-delimited JSON log files, and
serves a clean local web viewer on `http://127.0.0.1:8514/`. Runs as an
auto-start Windows service. Single native `.exe`, no runtime to install.

- **One dependency:** `windows-service` (Windows only). Everything else is the
  Rust standard library. Non-Windows builds have zero external dependencies.
- **Storage:** one JSON-lines file per day (`syslog-YYYYMMDD.jsonl`), rotated by
  size, created only after the first message arrives.
- **Cleanup ("garbage collection"):** automatic retention by age + total-size
  cap, plus a **Run cleanup** button in the UI.

## Requirements

- **To run (end users):** nothing. The installer places a native `.exe`.
- **To build (developer, once):** [Rust](https://rustup.rs) + the MSVC C++ build
  tools (Visual Studio "Desktop development with C++"). For the distributable
  installer, [Inno Setup](https://jrsoftware.org/isdl.php).

## Build (on Windows)

```powershell
# x64 only
.\build.ps1
# x64 + x86 fallback
.\build.ps1 -X86
```

Binaries land in `dist\x64\syslogd.exe` (and `dist\x86\syslogd.exe`).

## Install

**Option A — MSI (single file, recommended).** Build it once with WiX v5
(`dotnet tool install --global wix`), then distribute the one `.msi`:

```powershell
.\installer\build-msi.ps1
```

That produces `SyslogCollector-1.0.0-x64.msi`. Install it (double-click, or):

```powershell
msiexec /i SyslogCollector-1.0.0-x64.msi LOGDIR="D:\SyslogLogs"
```

The MSI natively installs the service, opens the firewall, writes config, and
adds an Add/Remove Programs entry; `msiexec /x` reverses all of it. `LOGDIR` is
optional (defaults to `C:\SyslogCollector\logs`); add `/qn` for a silent install.
One MSI is x64; build a separate x86 MSI only if you need the 32-bit fallback.

**Option B — PowerShell (no build tooling).** Elevated PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File installer\install.ps1 -LogDir "D:\SyslogLogs"
```

**Option C — Inno Setup `.exe` installer.** Compile `installer\syslog-collector.iss`
with Inno Setup (`ISCC.exe installer\syslog-collector.iss`) to get
`SyslogCollector-1.0.0-Setup.exe`, which prompts for the log folder.

All three:

1. Copies `syslogd.exe` to `C:\Program Files\SyslogCollector\`.
2. Registers service **SyslogCollector** (start type *Automatic* — starts at boot).
3. Opens inbound **UDP/514** in Windows Firewall (`profile=any`).
4. Writes config to `%ProgramData%\SyslogCollector\config.txt`.

## Use

- **Viewer:** <http://127.0.0.1:8514/> (loopback only — not exposed to the network).
- **Point devices at** this host's IP, UDP port 514.
- **Manage the service:** `services.msc` → *Syslog Collector*, or
  `sc stop SyslogCollector` / `sc start SyslogCollector`.

### Test it quickly

Foreground run on non-privileged ports (works on any OS, no admin):

```powershell
.\dist\x64\syslogd.exe run --udp-port 5514 --ui-port 8514 --log-dir .\testlogs
```

Send a message (PowerShell):

```powershell
$u = New-Object Net.Sockets.UdpClient
$b = [Text.Encoding]::ASCII.GetBytes("<34>Oct 11 22:14:15 host su: test message")
$u.Send($b, $b.Length, "127.0.0.1", 5514) | Out-Null
```

Then open the viewer and watch it appear.

## Configuration

`%ProgramData%\SyslogCollector\config.txt` (edit, then restart the service):

| Key | Default | Meaning |
|-----|---------|---------|
| `log_dir` | chosen at install | Folder for log files |
| `udp_port` | `514` | Syslog listen port |
| `ui_port` | `8514` | Local viewer port (loopback) |
| `max_file_mb` | `100` | Rotate the active file past this size |
| `retention_days` | `30` | Delete files older than this (`0` = never) |
| `max_total_mb` | `2048` | Trim oldest files once the folder exceeds this (`0` = no cap) |

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File installer\uninstall.ps1
```

(or Add/Remove Programs if installed via Inno Setup). Log files are left in place.

## Security notes

- The viewer binds **127.0.0.1 only**; only UDP/514 is exposed to the network.
  It also validates the `Host` header (only `localhost`/`127.0.0.1` accepted) to
  block DNS-rebinding reads from a malicious web page.
- Log content is untrusted: the viewer renders every field as text (no HTML
  injection), and the message API validates filenames against a strict
  allow-list (no path traversal).
- Runs as *LocalSystem*. To run under a lower-privilege account, change the
  service logon in `services.msc` (the account needs write access to `log_dir`).
- No PHI/PII/CHD assumptions are baked in — this stores whatever devices send, in
  clear-text files. Point `log_dir` at an encrypted volume if collected logs are
  sensitive, and keep it off regulated-data hosts unless in scope and approved.

See `docs/plans/syslog-server-2026-09-15.md` for the full design.
Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
