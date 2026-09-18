# Changelog

All notable changes are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com); versions follow
[SemVer](https://semver.org).

## [1.0.2] — 2026-09-17

### Changed
- Renamed the product to **Just Syslog** across the UI, installers, menu bar /
  tray apps, shortcuts, and service display name. Underlying identifiers are
  unchanged (service name `SyslogCollector` / `syslog-collector`, install paths,
  bundle IDs), so upgrades keep working.

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
