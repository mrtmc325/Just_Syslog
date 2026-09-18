# Contributing

Thanks for your interest in Just Syslog! This is a small, deliberately lean
project — the best contributions keep it that way.

## Ground rules

- Be kind and constructive — see the [Code of Conduct](CODE_OF_CONDUCT.md).
- For anything beyond a small fix, **open an issue first** so we can agree on the
  approach before you write code.
- Found a security issue? Please **don't** open a public issue — see the
  [Security Policy](SECURITY.md).

## Development setup

You need [Rust](https://rustup.rs) (stable, 1.71+). The portable core is
standard-library only, so most of it builds and tests on any OS:

```bash
cargo build
cargo test
```

Run it locally without installing (any OS, non-privileged ports):

```bash
cargo run -- run --udp-port 5514 --ui-port 8514 --log-dir ./logs
```

Packaging (optional, per platform): see [`packaging/README.md`](packaging/README.md)
for macOS `.pkg` / Linux `.deb`+`.rpm`, and `installer/` for the Windows MSI and
tray app.

## Making a change

1. Fork and create a branch from `main` (`git switch -c fix/short-description`).
2. Keep the change focused and the diff small.
3. Add or update a test when you change non-trivial logic (`cargo test` must pass).
4. Match the surrounding style; don't reformat unrelated code.
5. Update docs (README / `packaging/README.md`) if behavior or an interface changes.
6. Open a pull request against `main` and fill in the template.

## Style & scope

- **Stay lean.** Prefer the standard library; a new dependency needs a good
  reason (the only runtime dependency today is `windows-service`, Windows-only).
- Keep the Windows-only code behind `#[cfg(windows)]` so the core stays portable.
- Security and correctness at trust boundaries (network input, the local HTTP
  API, file paths) come before brevity — don't simplify those away.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
