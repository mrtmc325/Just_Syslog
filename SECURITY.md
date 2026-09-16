# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 1.0.x   | ✅        |
| < 1.0   | ❌        |

Fixes land on `main` and ship in the next release.

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately, either way:

- **GitHub** — open a private advisory via the repository's **Security → Report a
  vulnerability** tab (GitHub Private Vulnerability Reporting), or
- **Email** — **tristan@conner.house** with the details.

Please include:

- what the issue is and its impact,
- steps to reproduce (a minimal case if possible),
- affected version / platform.

You'll get an acknowledgement, typically within a few days. Once a fix is ready
we'll coordinate a release and credit you in the notes if you'd like.

## Scope & design notes

A few things are intentional, not bugs:

- The **web viewer binds `127.0.0.1` only** and validates the `Host` header;
  only **UDP/514** faces the network.
- The collector runs as a **privileged service** (LocalSystem / root) because it
  binds port 514.
- **Log files are clear text** — they hold whatever devices send. Point
  `log_dir` at an encrypted volume for sensitive data, and keep the collector off
  regulated-data hosts unless that's been approved.
- Reports about **downloaded or self-built binaries not being code-signed /
  notarized** are known — sign them yourself for wider distribution.

Vulnerabilities in the parsing/HTTP/storage paths, privilege handling, or the
installers are in scope and very welcome.
