# Contributing to Halcyon

Thanks for wanting to help! Halcyon is my first rice, and feedback of any kind is welcome.

## Reporting a bug
Open an [issue](https://github.com/X-netrunner/Halcyon/issues/new/choose) with the bug template. Please include the output of
`~/.config/Halcyon/scripts/halcyon-doctor.sh` and the end of `~/.cache/island/quickshell-island.log`. It usually shows the cause.

## Ideas and questions
Feature ideas go in an issue with the feature template. Questions, and screenshots of your setup, go in
[Discussions](https://github.com/X-netrunner/Halcyon/discussions).

## Pull requests
1. Fork the repo and make your change on a branch.
2. Run the checks: `scripts/halcyon-selftest.sh --quick .` (QML lint, shell and Python syntax, JSON). For Rust changes also run `cargo build` and `cargo clippy`.
3. Try it live: `./install.sh --link` symlinks your checkout into `~/.config/Halcyon`, and the island reloads when a file changes.
4. Keep a pull request to one change, and say what it fixes and how you tested it.

How the pieces fit together is in [docs/how-it-works.md](docs/how-it-works.md) and [docs/architecture.md](docs/architecture.md).

## Security
If you find a security problem (sysmode, the root helpers, the installer), please don't open a public issue.
Use [a private security advisory](https://github.com/X-netrunner/Halcyon/security/advisories/new) instead.
