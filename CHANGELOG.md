# Changelog

All notable changes are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions follow
[SemVer](https://semver.org).

## [1.0.2] — 2026-09-17

### Security
- Fixed an unauthenticated remote denial-of-service: a single crafted RFC 5424
  datagram (a structured-data block ending in a lone `\`) drove the parser's
  skip index past the buffer and panicked, killing the UDP receiver thread while
  the process kept running — silently stopping all collection. The parser now
  bounds the index, and the receive loop wraps parsing in `catch_unwind` so any
  future parser fault drops one datagram instead of the receiver. Regression test
  added.
- Web viewer server hardening (from the security review): request and header
  lines are read with a byte cap (no unbounded buffering), concurrent viewer
  connections are capped, the state-changing `POST /api/cleanup` now rejects
  cross-origin requests (CSRF defense-in-depth on top of the existing Host/DNS-
  rebinding check), and the CSP is tightened — `script-src 'self'` (the viewer
  JS moved to a served `app.js`, no inline script) plus `object-src`/`base-uri`/
  `frame-ancestors 'none'`.
- Web viewer: CSV export now neutralizes spreadsheet formula injection (a cell of
  attacker-controlled syslog starting with `=`/`+`/`-`/`@` is quoted as text).
- **macOS menu bar app:** closed a root command-injection path — config values
  (log dir, ports) are now validated at the boundary and shell-quoted before they
  reach the privileged `osascript` command, so a crafted `log_dir` can no longer
  inject a root shell command.
- **macOS:** the collected-logs directory is created `0750` (was `0755`) so local
  users can't read captured syslog; the pkg `preinstall` process-kill patterns are
  anchored to the start of the command line so they can't match an unrelated
  process.
- **macOS privilege drop:** the daemon now binds UDP/514 as root and then drops to
  a dedicated `_syslogcollector` account (created by the installer), so the
  network-facing parser no longer runs as root. It self-gates (stays root, still
  collecting, if the account/log-dir aren't set up) and fails closed if a drop
  leaves root regainable. Adds one dependency, `libc = "=0.2.189"` (Unix only;
  advisory-clean 2026-09-18); SBOM regenerated. Linux already runs as a dedicated
  user via systemd, so it's unaffected.
- **Linux:** the systemd unit adds substantial sandboxing (`ProtectSystem=full`,
  `SystemCallFilter=@system-service`, `RestrictAddressFamilies`, `PrivateDevices`,
  `MemoryDenyWriteExecute`, `UMask=0027`, and more), keeping a custom `log_dir`
  writable.
- **Linux:** fixed the RPM upgrade path — `preremove` now guards on `$1` so an
  `rpm`/`dnf` upgrade no longer stops and disables the service it just started.
- **Build supply chain:** the Linux Docker build now pins the builder image
  (`rust:1.94-bookworm`) and a specific `nfpm` version, and verifies the nfpm
  download against a known SHA-256 before running it. `nfpm` package license
  metadata corrected to MIT.
- Added CI security gates (GitHub Actions): build + test on every push/PR, a
  dependency-advisory scan (`cargo audit`, also run weekly to catch newly
  disclosed advisories), and a secret scan (`gitleaks`). Advisory scan is clean
  as of 2026-09-18 (7 dependencies, no advisories).
- **Windows:** the installer's default log directory moved from the drive root
  `C:\SyslogCollector\logs` — which a standard user can pre-create and hijack (a
  local privilege-escalation risk for the SYSTEM service, and world-readable
  logs) — to `%ProgramData%\SyslogCollector\logs`, matching the binary's own
  default. Existing installs keep their configured path.
- **Windows tray:** closed an elevated-command-injection path — config values are
  validated at the boundary (log dir must be a local path, ports 1–65535, sizes
  positive) and single quotes are escaped before any value reaches the
  UAC-elevated command; `Clear Logs` fails closed on an invalid saved path.
- **Windows:** the tray process-kill match (MSI custom action + install/uninstall
  scripts) is narrowed to the installed `\tray\SyslogTray.ps1` path so it can't
  terminate an unrelated PowerShell process.
- **Windows build:** `cargo build --locked` for reproducible builds.

### Fixed
- Installers now stop a running instance **before** upgrading, so an upgrade
  never races a live process holding UDP/514 or leaves a stale tray/menu bar
  icon:
  - **macOS:** a new pkg `preinstall` boots out the LaunchDaemon and menu bar
    LaunchAgent and hard-kills any lingering daemon or menu bar process
    (including a pre-rebrand `Syslog Collector.app`).
  - **Windows:** the MSI stops the service synchronously (`Stop-Service`, and
    `ServiceControl` now waits) and kills the tray controller process before the
    old payload is removed (removal is scheduled `afterInstallInitialize` so this
    runs elevated first); `install.ps1` kills the tray before overwriting files.

### Changed
- Renamed the product to **Just Syslog** across the UI, installers, menu bar /
  tray apps, shortcuts, service display name, and the release artifacts
  (`JustSyslog-*.msi` / `.pkg`, `just-syslog` `.deb` / `.rpm`). The Linux package
  declares Replaces/Conflicts/Provides on `syslog-collector` so it supersedes the
  old package on upgrade. Runtime identifiers are unchanged — Windows service
  `SyslogCollector`, systemd unit `syslog-collector.service`, install paths, and
  bundle IDs — so existing services and configs keep working.

### Added
- Web viewer: **severity summary bar** — per-level counts, click a chip to filter.
- Web viewer: **source quick-filter** — filter by sender IP (with counts).
- Web viewer: **CSV export** of the currently filtered view.
- Web viewer: header now shows the **collector version** and a live
  **"last message N s ago"** indicator; a **"showing X of Y"** row count; and a
  **Copy** button on the message-detail view.
- Web viewer: **dark theme** — follows the OS (`prefers-color-scheme`) with a
  session-only toggle (no preference is stored client-side).
- Web viewer: **filter-match highlighting** in the message column; a
  **"collector not responding"** banner when the local API is unreachable; a
  **flash** on rows that arrive during auto-refresh; press **`/`** to jump to the
  filter box; and a **2s / 5s / 10s auto-refresh interval** selector. All
  client-side only — nothing is stored in the browser.

## [1.0.1] — 2026-09-16

### Added
- Community health files: Code of Conduct, Contributing guide, Security policy,
  issue/PR templates; GitHub private vulnerability reporting enabled.

_No software changes — binaries identical to 1.0.0._

## [1.0.0] — 2026-09-16

Initial release.

### Added
- Cross-platform syslog collector (Windows, macOS, Linux) on **UDP/514**;
  RFC 3164 / RFC 5424 parsing with a best-effort fallback.
- JSON-lines storage — one file per day, size rotation, retention by age and
  total size.
- Local web viewer at `http://127.0.0.1:8514/` with per-message detail.
- **Windows:** MSI + PowerShell installers, auto-start service, firewall rule,
  system tray controller, Start Menu / Desktop shortcuts.
- **macOS:** `.pkg` (launchd) + menu bar controller app.
- **Linux:** `.deb` + `.rpm` (systemd).
- MIT licensed.

[1.0.2]: https://github.com/mrtmc325/Just_Syslog/releases/tag/v1.0.2
[1.0.1]: https://github.com/mrtmc325/Just_Syslog/releases/tag/v1.0.1
[1.0.0]: https://github.com/mrtmc325/Just_Syslog/releases/tag/v1.0.0
