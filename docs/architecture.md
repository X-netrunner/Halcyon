# How Halcyon fits together

A short map, and the reasons behind choices that look odd until you know them. Back to the [README](../README.md).

## The pieces

| Piece | Where | What it does |
|---|---|---|
| The island and widgets | `quickshell/island/` | The Quickshell UI. `shell.qml` holds state and timers, `Settings.qml` is built by a `LazyLoader` only while Settings is open, `Pal.qml` carries the look and the performance knobs (`motion`, `artFps`, `lowPower`). |
| Helper binaries (Rust) | `src/<crate>/`, installed to `~/.config/Halcyon/bin` | `hx` (system feeds: stats, net, states; focus), `hal`, `hgl` (game launcher engine, docs/games.md), `power-manager`, `touchpad-gestures`, `birthday-sync`. Sysmode only: `recon-deceiver`, `log-analyst`, `attacker-dossier`, `setStaticMac` (symlinked into `sysmode/`). Optional: `safety-check`. |
| Scripts | `scripts/`, `quickshell/island/scripts/` | Shell and Python glue. The Python that is left (notes, local AI, calendar import, lyrics, clipboard) only runs when its feature is opened. |
| Config | `hyprland.lua`, `variables.lua`, `hypr-user.lua`, `scheme/` | Hyprland (Lua). `hypr-user.lua` is yours and is never overwritten. |
| Your state | `~/.local/state/island/settings.json`, `~/.local/state/halcyon/` | Settings and run logs. `scripts/halcyon-settings.sh` exports and imports the important files. |
| systemd units | `systemd/` | Small user units (reminders, notes, power manager, gestures) plus two root ones (RAM info, ASUS keyboard fix). |

## Data feeds
The island polls system state (CPU, RAM, network, battery) through `hx`, which reads `/proc` and `/sys` directly. The older `stats.sh` and `net.sh` remain as a fallback for when `hx` is missing or fails. When all the helpers have been stable for a release or two, the fallbacks can be deleted.

## Install, update, roll back
- `install.sh` sets everything up. For the Rust helpers it first tries the prebuilt binaries of the release tag you are on (checksum-verified), and compiles only what it could not download, into one shared `CARGO_TARGET_DIR`. `--build-from-source` always compiles.
- `update.sh` pulls (or clones) the newest version, runs `install.sh`, reloads the island, reads its log for QML errors, and offers `update.sh --rollback`.
- `.github/workflows/ci.yml` runs `bash -n`, shellcheck, `cargo build` / `test` / `clippy` on the whole workspace, qmllint (fails on "X is not a type"), `luac -p` on the Hyprland Lua, `systemd-analyze verify` and an `install.sh --dry-run` on Arch and Debian containers. `release.yml` builds the binaries when a `v*` tag is pushed.

## Backups
`scripts/backup-device.sh` writes `<disk>/Halcyon-backup/<host>/<date-time>/`, hard-linking unchanged files to the previous run, with `latest` pointing at the newest. It never formats a disk. `--verify` re-compares by checksum, `--keep N` removes older dated folders (only ones carrying our `.halcyon-backup` marker).

## Why things are the way they are
- **Prebuilt binaries are checksum-verified but not signed.** The checksum list is on the same release page as the binaries, so it catches corruption, not a compromised release. People who want to run only code they compiled use `--build-from-source`.
- **Hard-linked backups, not a database or tar files.** Every backup is a plain folder you can browse and copy back with `rsync`; unchanged files cost no space.
- **The backup finds `CACHEDIR.TAG` / `.nobackup` folders itself.** rsync has no `--exclude-if-present` option (it fails with "unknown option"), so the script scans for the markers and passes the folders as `--exclude-from`.
- **Only some systemd units are sandboxed.** `power-manager` calls `sudo` for its tuning helper and `touchpad-gestures` runs tools such as `brightnessctl`; `NoNewPrivileges` could break both, so they are left alone until tested on real hardware.
- **Python stays for on-demand features.** Rewriting code that only runs when you open a feature saves almost nothing; the always-running parts are the ones that moved to Rust.
- **Settings are lazy.** The Settings window and the heavy pages are created when needed (`LazyLoader`, `Loader`); every repeating timer in `Settings.qml` is gated on the window being open.
- **rsync errors go to a log, and `-X` can be dropped.** Some rsync builds fail on extended attributes with `gen_entry_copy_xattrs ... secure open ... failed`. The backup keeps rsync's error lines in `~/.local/state/halcyon/backup-last.log`, prints a short summary, and offers to retry without `-X` (or run with `--no-xattrs`).

## If the keys do nothing after a login

While the lock screen is coming up at login, `scripts/login-watchdog.sh` switches Hyprland to an empty submap (`halcyon-locking`) so no shortcut works on the unlocked desktop. It puts the keys back by itself. If that process is ever killed hard and they stay dead, press Ctrl+Alt+F2, log in, and run `hyprctl dispatch 'hl.dsp.submap("reset")'` (or just log out and in again).
