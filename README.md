# Halcyon - Minimal Custom Hyprland Config

Lightweight, minimal, smooth and fast Hyprland setup in Lua, independent of caelestia dots.

## Layout
- `hyprland/`, `variables.lua`, `scheme/`: Hyprland config (Lua)
- `quickshell/`: island bar; the wallpaper layer (`island/Wallpaper.qml`) runs inside the same Quickshell process
- `launch/`: start scripts (`halcyon.sh`, `halcyon-isolated.sh`)
- `scripts/`: app themes (`app-themes.sh`, `app-themes-extra.sh`), cheatsheet, emoji picker, area screenshot, and the toggles (layout, nightlight, touchpad, gestures, power manager, live wallpaper)
- `src/`: Rust sources for `power-manager` (Auto power), `touchpad-gestures` and `hx` (island data feeds, sysmode status / IDS / dossier); `systemd/`: their user services
- `sysmode/`: the `sysmode` hardening/decoy-lab CLI plus the honeypot and IDS scripts it launches

## Choose your apps (install.sh)
`./install.sh` asks five short questions the first time (Enter takes the marked choice), and remembers the answers per user in `~/.local/state/island/install-choices.env`, so `update.sh` installs the same things again without asking:
- **Web browser**: Firefox, Zen, LibreWolf, Floorp, Chromium, Brave, Vivaldi, Google Chrome, qutebrowser (or keep the one you have)
- **File manager** (several allowed, the first one opens folders with SUPER+E): Thunar, Yazi, Dolphin, Nautilus, Nemo, PCManFM
- **Code editor** (several allowed, the first one is SUPER+C): VSCodium, Zed, Neovim
- **sysmode**: the hardening / honeypot lab and its ~10 security tools, or skip it
- **Safety check** (default yes): a one-command system update, malware / rootkit scan, firewall + audit check and backup (`src/safety-check`). Yes installs clamav, rkhunter, lynis, aide, ufw and rsync plus a root-owned `/usr/local/bin/safety-check`, and **Settings > Backup > Safety check** starts it. No leaves that Settings entry greyed out and disabled. `--safety-check` / `--no-safety-check` skip the question

No questions: `--browser zen --files yazi,thunar --editor codium,zeditor --no-sysmode --no-safety-check` (see `./install.sh --help`). `--yes` uses the saved choice or the default (keep your browser or Firefox, Thunar, no extra editor, sysmode). `./install.sh --choose` asks again (the first install on a machine asks everything once by itself). What you pick also becomes the default in Settings > Default apps (and the system default for links, folders and text files).

**Your shell prompt.** When the installer finds another prompt setup (your own `~/.config/starship.toml`, Starship started from your shell config, the CachyOS fish prompt, oh-my-posh, powerlevel10k) it asks once: *Keep mine* (Halcyon touches nothing), *My layout, Halcyon colours*, or *Halcyon's prompt* (`--prompt keep|colours|halcyon`). It is remembered, `./install.sh --choose` changes it, and whatever a switch replaces is saved as `starship.toml.before-halcyon` / `starship.toml.halcyon`. The sysmode badge of Halcyon's prompt switches itself off while sysmode is not installed.

## Launch
Halcyon lives in `~/.config/Halcyon`. From a TTY:
```bash
~/.config/Halcyon/launch/halcyon.sh
```
For a throw-away test session (separate runtime dir): `launch/halcyon-isolated.sh`. Or directly:
```bash
HYPRLAND_CONFIG=~/.config/Halcyon Hyprland
```

## Rust helpers (the island feeds and sysmode run without Python)
The helpers the island and sysmode run all the time are written natively in Rust:
- **`hx`** (`~/.config/Halcyon/bin/hx`): `hx audio | bt | wifi | disk | specs | wsres | palette <img>` (island feeds), `hx status` (sysmode + honeypot status for the quick terminal), `hx dossier [ip]` and `hx ids`.
- **`recon-deceiver`** (`~/.config/Halcyon/bin/recon-deceiver`): High-performance multi-port honeypot daemon (replaces `recon-deceiver.py`). **It never bans or counter-scans your own side**: the default gateway, your DNS servers and this machine's own addresses are protected automatically (read from the system, refreshed every minute), and `/etc/recon-deceiver.allow` (one address per line, `#` for comments) adds your own, e.g. a NAS or a second laptop. DNS decoy queries arrive over UDP, where the sender address can be forged, so they are answered (at most 50 a second) and logged but never lead to a ban or an nmap scan; only a real TCP connection to a decoy port does. Limits: 256 decoy connections, 3 counter-scans and 256 ufw bans at once; bans are lifted by one timer thread after 10 minutes, and any `recon-deceiver-ban` ufw rule left over from a crash is removed when the daemon starts.
- **`log-analyst`** (`~/.config/Halcyon/bin/log-analyst`): Real-time IDS signature log analyst daemon (replaces `log-analyst.py`).
- **`attacker-dossier`** (`~/.config/Halcyon/bin/attacker-dossier`): Attacker log summarizer and intelligence dossier (replaces `attacker-dossier.py`).
- **`birthday-sync`** (`~/.config/Halcyon/bin/birthday-sync`): reads your Google Birthdays calendar through the Calendar API (read-only login, nothing is written to Google) and fills the "Google Calendar" block of `birthdays.txt`. In the Calendar's setup page press **Connect Google Birthdays** once (needs an OAuth *Desktop app* client JSON saved in `~/Downloads`, with the consent screen set to *In production*), then **Sync Google Birthdays** whenever you add someone.
- **`setStaticMac`** (`~/.config/Halcyon/bin/setStaticMac`): Static MAC address manager for iwd and NetworkManager (replaces `setStaticMac.py`).
- **`power-manager`** and **`touchpad-gestures`**: Native Rust desktop background services.
Python 3 is still used, on purpose, for features that only run when you use them: Notes (`halcyon-notes.py`), the local AI (`halcyon-chat.py`, `adaptive-advisor.py`, `ai-models.py`, `halcyon-agent.py`), calendar import (`gcal.py`), lyrics (`halcyon-music.py`), the clipboard and screenshot panels (`halcyon-clip.py`, `halcyon-shot.py`), Focus mode (`focus.py`), the startup window (`startup-view.py`), timelines (`timeline.py`), safe mode and profiles (`halcyon-fx.py`) and the leak checks (`halcyon-leaks.py`). The island feeds, sysmode and its daemons do not need it.

## Touchpad edge gestures not working?
`journalctl --user -u touchpad-gestures -e` says why. Usual causes: not in the `input` group (`sudo usermod -aG input $USER`, then log in again), an old binary still installed (re-run `./install.sh`; an old build called `qs -c caelestia ... brightness`, which does nothing without caelestia), or `brightnessctl` / `playerctl` / `wpctl` missing. Left edge up/down = next/previous track (SUPER+ALT+G disables it), right edge up/down = volume, top edge right/left = brightness.

## Install in one line (curl)
```bash
curl -fsSL https://raw.githubusercontent.com/X-netrunner/Halcyon/HEAD/get.sh | bash
```

This installs the newest tagged release (`HALCYON_REF=HEAD` for the unreleased newest, `HALCYON_REF=v1.2.3` to pin). Each release also lists `get.sh` and `install.sh` in `SHA256SUMS`, so you can download and check them first.
`get.sh` downloads Halcyon with git into `~/.config/Halcyon` (a git checkout, so `update.sh` updates it in place later) and runs `install.sh`; your answers are asked on the terminal even though the script comes through a pipe, and with no terminal at all it runs `--yes`. Options go after `-s --` and reach `install.sh` unchanged: `curl -fsSL <url>/get.sh | bash -s -- --yes --no-sysmode --browser zen`. `--dry-run` downloads to `~/.cache/halcyon-get` and only shows what it would do. If Halcyon is already a git checkout there, `get.sh` hands over to `update.sh`; if it is a plain copy, the newest version is installed over it (the old copy is saved in `~/.config/Halcyon-backups`, your own files are kept). `HALCYON_REPO` / `HALCYON_DIR` point it at a fork / another folder. Run as your normal user, never root.

## Install (one script)
`./install.sh` is the only installer (the separate `glinstall.sh` of the fixed zip is merged into it). Run it as your normal user from the Halcyon folder; it asks for sudo only where needed. Safe to run again.

```
./install.sh                 asks before the important things
./install.sh --yes           no questions (fresh machine; update.sh uses this)
./install.sh --dry-run       show every step, change nothing
```

What it does, in order: checks the machine / user / sudo, installs packages (official repos, the AUR only for the few that need it; an AUR helper is built only if one is really needed), detects GPU drivers and CPU microcode, sets up audio / Bluetooth / network / power services and the `input` + `video` groups, installs Hyprland, Quickshell and the desktop, makes sure a Rust toolchain exists, copies the rice to `~/.config/Halcyon` (the old copy is saved in `~/.config/Halcyon-backups`; your `hypr-user.lua`, `scheme/current.lua` and `gamemode.conf` are never overwritten), builds `hx` / `power-manager` / `touchpad-gestures`, makes `~/.config/hypr/hyprland.lua` load Halcyon, adds a "Halcyon" session to the login screen (or, with no login manager, offers the lock screen as login screen), installs the user services and the boot service for RAM details, installs the root helpers, makes colours from your wallpaper and includes the colour files in your terminals, then checks the result.

Options: `--yes`, `--dry-run`, `--no-packages` (also skips drivers), `--no-drivers`, `--no-aur`, `--upgrade` (a full `pacman -Syu` first; **not** done by default, because it can update the kernel under a running desktop and `update.sh` runs this installer), `--no-sysmode`, `--no-tune`, `--link` (symlink instead of copy, for development: the folder must be writable by you), `--user NAME` (when run as root), `--tty-autostart`, `--lock-login` / `--no-lock-login` / `--remove-lock-login`, `-v`.

**Security notes** (what runs as root, and why it can be trusted):
- `halcyon-tune` (Gaming mode CPU/GPU boost, power-manager switch, Wi-Fi power saving) is copied to `/usr/local/bin` as a **root-owned** file and the sudoers rule names exactly that file and nothing else. It accepts only fixed words (`game-on`, `game-off`, `wifi-ps on|off`, `pm <known manager>`), never a path or free text, and never `source`s a file. Skip it with `--no-tune`.
- The sudoers rule is written to a root-owned temporary file, validated with `visudo -cf`, and only then moved into place; a rule that fails validation is never installed.
- `sysmode` runs as root, so the Python scripts it launches are installed as **root-owned** copies in `/usr/local/lib/halcyon/sysmode` (`SCRIPTS_DIR` in `/etc/sysmode.conf`). Before, it ran them from `~/.config/Halcyon/sysmode`, a folder any program running as you could edit. Re-run `./install.sh` after changing those scripts.
- When run as root, AUR builds get a temporary sudo rule that allows only `/usr/bin/pacman`, removed again when the installer exits.
- Everything is logged to a private temporary folder (the path is printed at the start and end).

## Prebuilt helpers (no Rust needed)
When you install a tagged release (`git checkout v1.2.3`, or `HALCYON_REF=v1.2.3` with `get.sh`), `install.sh` downloads the helper binaries from that release's GitHub page, checks each against the release's `SHA256SUMS` (and that no library is missing), and installs them: no Rust toolchain, no compile wait. Anything that cannot be downloaded is compiled as before. The checksum list comes from the same release, so it protects against a broken download, not a compromised release: use `./install.sh --build-from-source` (or `HALCYON_PREBUILT=0`) to run only code you compiled yourself. Maintainers: `git tag v1.2.3 && git push --tags` builds and attaches the binaries (`.github/workflows/release.yml`).

## Updating
`~/.config/Halcyon/update.sh` asks GitHub (X-netrunner/Halcyon) for the newest version. **Nothing new = nothing is touched.** If there is something new it is pulled (`git pull --rebase --autostash` when `~/.config/Halcyon` is a git checkout, so your own edits stay; otherwise the latest is cloned and installed over it, keeping `hypr-user.lua`, `scheme/current.lua`, `gamemode.conf`), `install.sh --yes` sets it up, and the island + Hyprland reload. `--check` only reports, `--force` re-runs the setup, `--no-packages` / `--no-sysmode` go to `install.sh`. `--changes` lists what is new, the install options of `install.sh` (`--browser`, `--files`, `--editor`, `--music`, `--resources`, `--resource-offset`, `--no-apps`, `--no-tune`, `--no-drivers`, `--no-aur`, `--lock-login` ...) are passed on too, with a value after a space or an `=`, `--rollback` goes back to the version before the last update (git checkouts), `--notify` sends a desktop notification with the result, and `--check` exits with 10 when an update exists. The run is logged in `~/.local/state/halcyon/update.log`, and after the reload the island's log is checked so a QML error shows up straight away.

## Reload, quick keys
- Settings > **Reload Hyprland** now reloads Hyprland's config (Lua modules are re-read, not served from cache), repaints terminal colours and reloads the island (`quickshell ipc ... call island reload` does the same).
- Launcher: **Up / Down** = earlier / later searches (kept in `~/.local/state/island/launcher-history.log`), **Left / Right** move the text cursor, **Tab / Shift+Tab** (or Ctrl+N / Ctrl+P) pick the next / previous result, **Ctrl+Up / Ctrl+Down** move a row. In the `>` command list Up / Down still move the selection.
- Workspaces slide horizontally in the direction you travel (`hyprland/animations.lua`).
- Profile editor in the tree (E): **Browse** opens a file dialog (zenity, kdialog or yad).


## More
- [Features and settings](docs/features.md): island, widgets, lock screen, gestures, sysmode, clipboard, constellations
- [How it fits together, and why](docs/architecture.md)
- [Notes from past passes](docs/changes.md)
- Move your setup to another computer: `scripts/halcyon-settings.sh export` / `import`
- [Full changelog](changelog.md)
- Something not working? Run `scripts/halcyon-doctor.sh`

