# Changelog

## The local AI can now manage the system, not only suggest; Add-a-widget button no longer leaks

- Fixed: **"Add a widget" overflowed its pill in the Widget builder** (`WidgetBuilderWindow.qml`, `ActionChip.qml`). The left column is ~222 px wide; "Add a widget", "Copy" and "Remove" on one line squeezed the first button to ~46 px and its label spilled out. "Add a widget" now has its own full-width line and Copy / Remove share the next. `ActionChip` also clips and elides its label when it is made narrower than its text, so no chip can spill again anywhere.
- New: **the AI is now an agent** (`scripts/halcyon-agent.py`, used by `ai` and `advisor "<question>"`). It calls tools, reads what came back, and carries on until it can answer.
  - *Read* tools run at once and change nothing: system status, failed services (with diagnosis), service status, journal, top processes, disks, network, Hyprland state, Quickshell log, pacman updates / orphans, read a file (secrets refused).
  - *Action* tools show the exact command and wait: `y` / `N` / `a` (yes for the rest of the session). Restart / start / stop / enable / disable / mask / reset-failed a unit, kill a process, trim RAM, volume, brightness, Halcyon desktop modes, clean the package cache, and `run_shell` as a last resort. Risky ones (kill, stop / disable / mask, cache clean, shell) ask every time; `--yes` / `/yes` only pre-approve the low-risk ones.
  - After an action the tool re-checks the result and the model is given the new state plus the journal if it failed, so it reports what really happened and finds the cause instead of repeating the command.
  - Guard rails: protected units (dbus, logind, journald, network, display manager ...) cannot be stopped; `run_shell` refuses `rm -rf /`, disk formatting, `dd` onto devices, `curl | sh`, reboot / poweroff, sudoers / account edits and removing core packages.
  - Works with tool-capable models (`qwen2.5:7b`, `llama3.1:8b`: `advisor model switch 7b`), also with models that write the call as JSON text. A model without tool support falls back to chat and each ```bash block it writes is offered for approval. `llama3.2:1b` is too small to use tools reliably, and says so.
  - In `ai`: `/tools` lists everything, `/yes` pre-approves low-risk actions, `/agent` turns tool use off.
- Fixed: **the advisor told you to restart units that cannot be restarted.** `systemd-pcr*` and `systemd-tpm2-setup*` fail when Linux has no usable TPM2 (often fTPM / PTT off in the BIOS), so `systemctl restart` fails again, and the old score dropped 28 points for it. They are now recognised as harmless (LOW), the advice is `reset-failed` (clear the flag) or `mask`, and they no longer cost health score. Any other failed unit gets its status / journal shown, and when a restart fails the reason is printed right there.
- Fixed: sudo-needing fixes now say `sudo` and have time to type the password (they had 15 s and no `sudo`); the doubled space in `systemctl  restart` is gone.
- Fixed: zombie processes were "reaped" with `kill -9`, which does nothing to a dead process; the parent is now sent SIGCHLD.
- Fixed: the Quickshell log check always reported 0 errors (a variable typo that an exception swallowed).
- Changed: `advisor "what is dnd?"` is a question and goes to the model; `advisor "gaming mode"` is still a command and runs at once. A question no longer prints a stale dashboard under the answer.
- Files: `scripts/halcyon-agent.py` (new), `scripts/adaptive-advisor.py`, `scripts/halcyon-chat.py`, `quickshell/island/ActionChip.qml`, `quickshell/island/WidgetBuilderWindow.qml`. Copy over the ones in `~/.config/Halcyon/`, restart the island, open a new terminal.

## Smoother tour, tour updated for the widgets

- Fixed: **the tour was laggy and not smooth** (`Tour.qml`).
  - The spotlight hole was re-read 30 times a second and each read restarted five 70 ms animations, so on the bar it trailed behind and moved in steps. The bar and its pages are now read on every frame and the hole sits exactly on them; a new step still glides to its place, once.
  - The card was aimed at the *animating* hole, so its own animation was re-targeted on every frame of the glide and ended with a jump. It is now placed from where the target is, and glides once, on the same curve as the hole.
  - The input mask (the pointer-through hole) followed the glide too, so the compositor was told a new input region on every frame. It now changes once per step.
  - The pulsing light changed the colour of four rings on every frame, forever. It is now one opacity value on a group, off when Motion is low, and the faintest ring (about 5 % strong) is gone.
- Changed: the closing step "That's it" is now last. On a fresh install it used to show as step 13 of 21, with eight more steps after it.
- New tour steps (shown once to existing users as "What's new"): **Desktop widgets** (`>widget builder`), **Place widgets with the mouse** (`>place widgets on the desktop`), **Desktop builder**, **Top bar on or off**, **Password manager**. The Settings step also points at `>widget builder`.
- Files: `quickshell/island/Tour.qml`, `quickshell/island/features.json`. Copy both over the ones in `~/.config/Halcyon/quickshell/island/` and restart the island; `>tour` replays it.

## Bigger desktop builder preview, curl installer, update.sh options

- Changed: the **Desktop builder** picture is much bigger (the card grew to 1560 x 900 and the picture takes about two thirds of it) and has a **Widgets / Boxes** switch above it. In *Widgets* mode only the widgets can be dragged and the four corner boxes are drawn faint and ignore the mouse; in *Boxes* mode only the corner boxes react (click one, then the corner) and the widgets are faint. They no longer sit on top of each other, so dragging a widget onto a corner works.
- New: **`get.sh`**, the one-line installer: `curl -fsSL https://raw.githubusercontent.com/X-netrunner/Halcyon/HEAD/get.sh | bash` (options after `bash -s --`). Clones into `~/.config/Halcyon`, runs `install.sh` with the terminal for its questions, records the version for `update.sh`; hands over to `update.sh` when Halcyon is already there.
- Changed: `update.sh` passes every install option on to `install.sh` (`--browser`, `--files`, `--editor`, `--music`, `--resources`, `--resource-offset`, `--no-apps`, `--no-tune`, `--no-drivers`, `--no-aur`, `--sysmode`, `--lock-login`, `--no-lock-login`, `--tty-autostart`), values after a space or `=`; `--help` lists them; the log keeps the options you typed.

## Desktop widgets, top bar off, roomier console command list

- New: **Widget builder** (`widget-builder`, Settings > Appearance > Widget builder). 23 kinds of desktop widgets: clock (digital, big, stacked, analog, minimal), date, month calendar, CPU, memory, temperature, GPU, disk, battery, volume, brightness, system usage (bars, rings, list, compact), network, uptime, now playing, audio visualizer (bars, mirror, wave, dots, circle), Focus timer with a day **streak**, workspaces, quick toggles (Wi-Fi, Bluetooth, DND, Caffeine, Gaming, Num Lock, theme, night light, lock, power), your own app shortcuts, notes and agenda, weather, text and greeting. Each has several layouts and options, and a look (box, opacity, corners, colours, font, text size). Save looks of your own and reuse them on any widget.
- New: **Place the widgets on the desktop** (`desktop-edit`): drag, resize (corner dot or wheel), add and remove them right on the screen; they snap to the middle and the edges.
- Changed: the **Desktop builder** is now the overview: a picture of where every widget sits (drag them there too), the top bar switch, and the activation zone (screen corner) of each box. The old notes / calendar choice became a Notes widget by itself.
- New: **top bar Off** (Settings > Bar style > Style > Off, or `halcyon bar`). The launcher, the pages and every box still open from the top edge.
- New: the Focus streak counts the minutes of every work phase (`scripts/focus-log.sh`, `~/.local/state/island/focus-days.json`).
- Changed: the console command tree (SUPER+ALT+/) has taller rows, a fixed-width command column and wrapped descriptions, and more space between groups.
- New files: `WidgetData.js`, `WidgetHost.qml`, `DeskWidgets.qml`, `DesktopEditor.qml`, `WidgetBuilder.qml`, `WidgetBuilderWindow.qml`, `WbText.qml`, `WBase.qml`, `WLbl.qml`, `WIco.qml`, `WClock.qml`, `WMetric.qml`, `WSysmon.qml`, `WNet.qml`, `WMusic.qml`, `WViz.qml`, `WFocus.qml`, `WWorkspaces.qml`, `WToggles.qml`, `WNotes.qml`, `WMonth.qml`, `WWeather.qml`, `WText.qml`, `cava-desk.conf`, `cava-desk-light.conf`, `scripts/focus-log.sh`, fish `widget-builder`, `desktop-edit`. Removed: `DesktopNotesWidget.qml`.
- Nothing is read for a widget that is not on the desktop (cava, volume, disk, GPU and the weather request only start when a widget needs them).

## Latest
- Console: `ai`, `advisor`, `notes` and `passman` now run in the island console (they were fish functions, the console runs bash: "command not found"). The installer also puts real commands in ~/.local/bin.
- passman: `passman browser` sets up a Brave / Chromium extension that asks "Save password for <site>?" after a login (Save / Not now / Never); `passman import <csv>` brings in a Brave / Chrome export.
- Desktop builder: the four corner buttons of each box sit on one line.
- App menu ">" commands: grouped (System, Desktop, Tools, Power) in a fixed order; the description moved behind an (i) button that opens a popup under the list.
- Fix: ChipRow set a read-only property on Flow ("implicitHeight is a read-only property").

- **Password manager (`scripts/halcyon-pass.py`, `passman`)**
  - **Cause of lost passwords:** when the key file was missing or did not match, every command treated the vault as empty and the next `passman add` saved a new vault over the old one (a test vault of 62 entries became 1). Now an unreadable vault stops the command with a clear message and is never overwritten; the key is only created when there is no vault yet; the last good vault is kept as `vault.enc.bak`; a new vault is checked by decrypting it before it replaces the old one; writes are locked so two `passman` calls cannot collide.
  - The passphrase now goes to openssl through its own pipe instead of sharing stdin with the data (old vaults still open: same format).
  - Fixed the broken colour code in the auto-generated password message, `passman get` with no name crashing, the documented but missing `passman search`, and the password showing up in the process list while copying (wl-copy now reads it from stdin; the 30-second clear compares a hash).
  - New: `passman edit`, `passman backup`, `passman status`, `add ... -g 32` (length), `add ... --stdin`; a replaced password's previous version is kept (last 3); `add` and `del` ask before replacing / deleting in a terminal.
- **Desktop builder**
  - The corner rows ("Top-left / Top-right / Bottom-left / Bottom-right"), Direction, Colour, Background, Desktop view and Notif trigger rows ran out of the panel; they are now `ChipRow.qml` rows that wrap.
  - The desktop notes / calendar widget showed empty bullets (it read `summary`, the calendar calls it `title`) and listed the first cached events instead of today's. It now shows today's unfinished events with their time, pinned notes first, and updates at once when you change the Desktop view.
  - The live picture now shows the widget and keeps the screen's shape on small windows.
  - Slider drags (blur, stars) are throttled: they rewrote every shared option on every pixel.
  - "Reset the desktop" in Settings and in the window now reset the same things (the widget and the star details were left behind) and the Settings button greys out correctly.
  - Wallpaper paths with `#`, `?` or `%` now show in the preview.
- **Screen & audio recording (`scripts/screen-record.sh`, Settings > Desktop > Screen & audio recording)**: record **desktop sound, microphone or both** with the screen, or **audio only** (.m4a). Buttons to start / stop, play the latest recording and open the folder. Sound is recorded by ffmpeg beside the video and joined when you stop, so it works with wf-recorder, wl-screenrec and gpu-screen-recorder. If sound cannot start, the screen is still recorded and a notification says why.
- New: `quickshell/island/ChipRow.qml`. Changed: `halcyon-pass.py`, `screen-record.sh`, `DesktopBuilderWindow.qml`, `DesktopBuilder.qml`, `DesktopNotesWidget.qml`, `DeskSpots.js`, `Settings.qml`, `shell.qml`, `Launcher.qml`.

## Notification box closed itself about a second after opening
- **Cause:** `shell.qml` counted `notifs.centerOpen` as an "overlay", so opening the box scheduled `notifs.raise()` (260 ms later). `raise()` un-maps the notification window for 60 ms; the edge strip reported "pointer left", `closeT` (700 ms) started, and because the pointer had not moved no new "enter" came to cancel it.
- **Fix:** `notifs.centerOpen` is no longer part of `anyOverlay` (`shell.qml`), and `Notifs.setHover(false)` is ignored while the window is being re-mapped (`cycling`). Raising for toasts and for other overlays is unchanged.
- Changed: `quickshell/island/shell.qml`, `quickshell/island/Notifs.qml`.

## Desktop builder, corner boxes and a quicker launcher
- **Settings > Appearance > Desktop builder** (also `>desktop builder` in the launcher): one window with a small live picture of the screen. **Wallpaper on / off** (off = a plain theme-colour, black or gradient background; no picture is decoded, so it also saves RAM; the colours still follow the last wallpaper), **wallpaper blur**, and **moving stars** over the wallpaper or over the plain background (amount, speed, size, direction, colours, twinkle, an occasional shooting star; they stand still in Gaming mode).
- **Where the boxes open**: the utilities box, the background apps box and the console can each open from the top-left, bottom-left or bottom-right corner (click a box in the picture, then a corner; a taken corner swaps). The top-right corner stays with the notifications, whose trigger can be the right edge or that corner.
- **Settings > Mouse, touchpad & keyboard > Launcher speed** (Normal / Quick / Instant, default Quick): the launcher grows out of the bar in about half the time. It still opens when Super is *released* (a lone tap cannot be told from the start of Super+T until then); `scripts/super_tap.sh` now runs under plain `sh`, a few ms faster.
- New files: `DesktopBuilder.qml`, `DesktopBuilderWindow.qml`, `DesktopStars.qml`, `DeskSpots.js`. Changed: `Wallpaper.qml`, `shell.qml`, `QuickTerm.qml`, `Settings.qml`, `Launcher.qml`, `scripts/super_tap.sh`.

## Installer: pick how much of the machine Halcyon may use

- **install.sh** now asks (once, remembered for update.sh) how much of the computer Halcyon may use: **Low / Medium / High / Adaptive**, each with a rough estimate of the RAM and CPU all of Halcyon needs (shown with a +/- offset range) and a **headroom** choice (Tight 10 % / Balanced 15 % / Relaxed 25 %). The pre-selected answer follows your hardware (low-end = Low, mid-range = Medium, strong = High).
- The answer becomes the default of **Settings > Performance > Resource use** and of the RAM / CPU limits in **Startup & processes > Health**: limit = estimate + headroom. **Adaptive** starts as Medium with limits learned from your own use.
- The numbers are planning estimates, not measurements of your machine. See the real ones in Settings > Performance > Memory.
- Options: `--resources low|medium|high|adaptive`, `--resource-offset N`. Applied once at the first start after the install (resource-seed.json, then deleted), so later changes in Settings are never overwritten.

# Halcyon Optimization & Bugfix Changelog

This changelog documents the complete audit, optimizations, bug fixes, and reliability improvements implemented across the Halcyon repository.

---

## 2026-10-14: Google Birthdays sync (`birthday-sync`)

- New Rust helper `src/birthday-sync`: reads the built-in Google Birthdays calendar (no iCal address exists for it) through the Calendar API with a read-only login, and rewrites only the block between the two "Google Calendar" marker lines in `birthdays.txt`. Lines you typed and the contacts-import block are left alone; people already listed elsewhere are skipped.
- `install.sh` builds it with the other helpers and installs it to `~/.config/Halcyon/bin/birthday-sync` (no root).
- `Calendar.qml`: **Connect Google Birthdays** (picks up `client_secret_*.json` from Downloads, logs in in the browser, syncs) and **Sync Google Birthdays** buttons next to Import Contacts.
- Not run against the real Google API yet: only the offline merge/parse tests were run.

---

## Audit 2026-10-13: security, bugs and reliability fixes

Line-by-line read of the installer, updater, launchers, the root-run parts of `sysmode`, the backup / restore scripts and the calendar helper, targeted searches across the rest (QML, Rust, scripts), plus
syntax checks on everything (all `*.sh`, `sysmode`, `halcyon-tune`, `*.py`, `*.json`, `*.js`, the Rust sources) and a
`install.sh --dry-run` run. Nothing here changes how Halcyon looks or what its features do.

### Summary

| # | Severity | Area | Problem | Fixed in |
|---|----------|------|---------|----------|
| 1 | **High** | Security | `sysmode` (root) could run helper programs from your **home folder**: any program running as you could swap one and become root the next time you ran `sudo sysmode ...` | `sysmode/sysmode` |
| 2 | **High** | Security | Backup / restore disk picker ran `eval` on `lsblk` output: a USB stick whose **label** contains `$(...)` or backticks ran that command as you | `scripts/backup-device.sh`, `scripts/restore-device.sh` |
| 3 | **High** | Install | Installer **aborted in the middle of step 11** on any machine without a DMI table (Raspberry Pi, some VMs / containers) | `install.sh` |
| 4 | Medium | Security | `sysmode` ran `xhost +local:` (opens the X server to every local account and process) | `sysmode/sysmode` |
| 5 | Medium | Security | Calendar's secret address was written **world-readable** first and `chmod`-ed afterwards; plain `http://` and unlimited downloads were accepted | `quickshell/island/scripts/gcal.py` |
| 6 | Medium | Bug | `update.sh --rollback` could pop the **wrong git stash** (your clashing edit from an earlier update) over the rolled-back tree | `update.sh` |
| 7 | Medium | Bug | After `pkill quickshell; start-shell.sh island` the new supervisor often found the old one's lock still held, said "already running" and quit: **no island at all** | `scripts/start-shell.sh`, `update.sh` |
| 8 | Medium | Bug | Island forced the Mesa EGL driver on **every** machine: on a desktop with only an NVIDIA card Quickshell lost its GPU driver | `scripts/start-shell.sh` |
| 9 | Medium | Repo | Author's machine state was committed: `gpu-mode` (`dgpu`), `gpu.lua` (hybrid laptop) and `scheme/current.lua`; a fresh install on an NVIDIA PC started in "dGPU" mode | removed + `.gitignore` |
| 10 | Low | Bug | Settings > Backup > "Safety check" never marked itself done (shell quoting: the reminder script path had literal `"` characters) | `quickshell/island/shell.qml` |
| 11 | Low | Bug | Touchpad toggle fell back to the author's own touchpad name, reported "Disabled" when nothing happened | `scripts/toggle_touchpad.sh` |
| 12 | Low | Security | Text from a log line / attacker request that starts with `-` was passed to `notify-send` as an **option** | `src/log-analyst`, `src/recon-deceiver`, `src/hx/src/ids.rs` |
| 13 | Low | Safety | `--yes` could say yes to the one question that must default to no (`confirm_no`) | `install.sh` |
| 14 | Low | Safety | `pkill -f recon-deceiver` / `log-analyst` also killed anything with those words in its command line (an editor, `tail -f`) | `sysmode/sysmode` |
| 15 | Low | Optimisation | The four sysmode-only Rust helpers were built (minutes of compile time) even with `--no-sysmode`, and then reported as "missing" | `install.sh` |
| 16 | Low | Bug | `user-setup.sh` autostart removal left the tty1 line in `.bash_profile` / `.zprofile` and returned an error | `scripts/user-setup.sh` |
| 17 | Low | Bug | `gpu-mode.sh status` exited 1 when Hyprland was not running | `scripts/gpu-mode.sh` |

### Details

#### 1. `sysmode` only runs root-owned helpers
- **Before:** `sysmode` fell back to `~/.config/Halcyon/bin/*` and `~/CustomHyprScripts/...` for `attacker-dossier`, `recon-deceiver` and `log-analyst`, and `python3` scripts from `SCRIPTS_DIR`. Those files are writable by your user, but `sysmode` runs as root.
- **Now:** new `trusted_file` / `trusted_bin` helpers accept a file only when root owns it, it is not writable by group / others, and every folder above it is the same. The user-home fallbacks are gone. The normal install is not affected: `install.sh` already copies the helpers to `/usr/local/lib/halcyon/sysmode` and `/usr/local/bin`.
- Checked: `/usr/bin/ls` accepted; a user-owned binary refused; a root-owned helper accepted; the same file at mode 777 refused.

#### 2. No `eval` on `lsblk` output
- **Before:** `eval "$line"` on `lsblk -P` lines in both disk pickers.
- **Now:** `parse_pairs` reads `KEY="value"` as plain text (only the nine known keys are accepted, `|` in labels is replaced). A label of ``$(touch /tmp/PWNED)`id` `` stays text (tested; nothing ran). The `rm=$RM` variable (shadowed a command name) became `isrm`.

#### 3. Installer no longer dies without `/sys/class/dmi`
- `tr ... < /sys/class/dmi/id/sys_vendor` failed on machines with no DMI table; with `set -e` that ended the whole install in `setup_asus_extras`. It now reads with `cat ... 2>/dev/null | tr ... || true`. `./install.sh --dry-run --no-packages --yes --user NAME` now runs to the end (it stopped at step 11 before).

#### 4. `xhost`
- `xhost +local:` became `xhost +SI:localuser:<your user>`: only you, not every local account.

#### 5. Calendar (`gcal.py`)
- `config.json` (the secret iCal address) is **created** with mode `0600`, its folder with `0700`.
- Only `https://` / `webcal://` addresses are accepted, in `add-url` and again in `fetch` (so `file://`, `ftp://` and plain `http://` are refused).
- A feed is read up to 25 MB, not without limit.

#### 6. Rollback
- `git stash push` exits 0 when there is nothing to stash; the old code then ran `stash pop` on whatever stash was newest. It now compares `refs/stash` before and after and pops only a stash it just made.

#### 7. Restarting the island
- `start-shell.sh` waits up to 6 s for the supervisor lock (`flock -w 6`) instead of giving up at once. `update.sh` also matches the short `qs` binary name when it restarts the island.

#### 8. Island GPU environment
- `__EGL_VENDOR_LIBRARY_FILENAMES` (Mesa) is set only when a non-NVIDIA GPU is really present; `VK_DRIVER_FILES` (radeon) only when an AMD GPU is present. Hybrid laptops keep exactly the old behaviour.

#### 9. Per-machine files out of the repo
- Removed `gpu-mode`, `gpu.lua`, `scheme/current.lua` (identical to `default.lua`) and added them (plus `special.conf`, `apps.custom`, `autostart.conf`, `gamemode.conf`) to `.gitignore`. `hyprland.lua` recreates `scheme/current.lua` from `default.lua`; `install.sh` and `update.sh` already keep your copies.
- **Existing git checkouts:** run once `git rm --cached gpu-mode gpu.lua scheme/current.lua` before pulling this, so git does not delete your own copies.

#### 10-15. Smaller fixes
- **10:** in `shell.qml` the "safety check done" command had `\\\"` where `\"` was meant.
- **11:** `toggle_touchpad.sh` now finds the touchpad by name only, says "No touchpad found" otherwise, and only reports / remembers the new state if `hyprctl` accepted it. It also no longer depends on `$XDG_RUNTIME_DIR` being set.
- **12:** a `--` now ends the options before the title and message of `notify-send` in the three Rust helpers.
- **13:** `confirm_no` returns "no" with `--yes`.
- **14:** daemons are matched with `pkill -x NAME` (and the exact `python3 .../NAME.py` form for the Python fallbacks); the duplicate `source /etc/sysmode.conf` was removed.
- **15:** `recon-deceiver`, `log-analyst`, `attacker-dossier` and `setStaticMac` are built, installed and checked only when sysmode is chosen.

#### 16-17. Found in the dry-run pass
- **16:** `login_remove` now strips the whole snippet (and the older single-line form) from `~/.bash_profile` and `~/.zprofile`, and always returns 0.
- **17:** `gpu-mode.sh status` ends with `true`, so reading the status outside a Hyprland session is no longer an error.

### Checked and fine (not changed)
- The AWS keys, passwords and private-key text in `src/recon-deceiver` are **decoys** for the honeypot, not real secrets. A pattern search for tokens, keys and personal paths found no real ones.
- No `curl | sh`, no `rm -rf` on an unguarded variable, no predictable files in `/tmp` (the installer log dir uses `mktemp -d`), no QML timer set below 500 ms.
- Notification history and toast lists are trimmed and dismissed properly (`Notifs.qml`): no leak found.

### Known, left alone on purpose
- `sysmode` appends the daemons' output to files in `~/logs` as root. If you do not trust other programs running as your user, point `LOGS_DIR` at a root-owned folder.
- `setStaticMac` builds `sh -c` strings from `nmcli` output (connection UUID, interface name); only root can set those names. Worth moving to `Command::arg` the next time the crate is touched.
- `gcal.py add-url URL` takes the secret address as an argument, so it shows in `ps` for a moment.

### How this was checked
- `bash -n` on every shell script (installer, updater, launchers, `sysmode`, `halcyon-tune`, all `scripts/`), `py_compile` on every Python file, JSON parsed, JS files parsed with Node, QML braces counted, the Rust files that were changed parsed with `rustfmt`.
- Run: hostile-label test of `parse_pairs`, `trusted_bin` against four cases, the stash before/after logic in a scratch repo, `gcal.py` file modes and scheme refusal, and `install.sh --dry-run`.
- Dry-run pass: every `install.sh` flag combination; NVIDIA / Intel / AMD / hybrid paths with fake `pacman` / `lspci`; every `user-setup.sh` subcommand; `start-shell.sh` crash loop and restart; `update.sh` check / update / rollback against a local git origin; `sysmode help|status|doctor`; all 18 Lua files parsed and `hyprland.lua` run against a mock `hl` API; every `hl.*` call, config key and window-rule field compared with current Hyprland master.
- QML heuristic scan: the repeated `id: slot` / `id: ld` in `CustomBar.qml` sit in separate delegates (valid) and the unfamiliar type names are components defined in the same file. No problem found.
- **Not run:** a Rust build (crates.io is not reachable here), Quickshell / QML loading, a real Arch install. Please run `./install.sh` (or `update.sh`) and `scripts/halcyon-doctor.sh` on your machine and send the output if anything differs.

---
## Calendar on Super + R, from the clock, tasks that nag

- **The calendar page from the clock now stays open.** In the notch style the bar is another window, so the pointer on the clock did not count as being on the page and it folded away after 600 ms. Now it stays until the pointer has been on it and has left, or until you click the time again.
- **Wi-Fi power saving now survives a reconnect and a reboot.** It used to change only the live card (`iw ... set power_save`). `halcyon-tune wifi-ps` now also writes `/etc/NetworkManager/conf.d/zz-halcyon-wifi-powersave.conf` (`wifi.powersave` 2 = off, 3 = on; the name sorts last so it beats a distro `default-wifi-powersave-on.conf`) when NetworkManager is there, and the toggle remembers the choice and puts it back at login (`toggle_wifi_powersave.sh apply`, for setups without NetworkManager). Run `./install.sh` (or `./update.sh`) once so the root copy of `halcyon-tune` in `/usr/local/bin` gets the change.
- **Super + R opens the Halcyon calendar** (the same window as `>calendar`). The Todoist special workspace and its `todoCmd` variable are gone; the shortcut keeps its `todo` id, so changed keys and gestures still work. A window still sitting in the old workspace keeps its bar icon until you close it.
- **Click the bar clock** and the calendar drops out of the bar as a page of it, so it is the pill in the island style and the notch in the notch style (the same container as the media and performance pages). Click the time again, or move the pointer away, to close it.
- **Settings > Desktop > Calendar**: master switch, clock click, reminder notifications, what counts as a task (events you mark / every event), auto Focus mode, keep reminding until done (every 2 to 30 min, give up after 1 h to 3 days).
- **Tasks**: each event row has a Task button and, for tasks, a round check. A task is nagged (an urgent notification with a Done button, each one replacing the last) and can start Focus mode for its length. Done is stored on this computer only (`~/.local/state/island/calendar/`), nothing is sent to Google. Google Tasks are not part of the iCal feed.
- **Fix: the shell did not load** ("Calendar unavailable ... Step is not a type"). `Step` is now its own file (`CalStep.qml`) and the function named `goto`, a reserved word that Qt 6.8 to 6.10 reject, is `gotoDay`.


## Calendar (`>calendar`) and notifications on top of everything

- **`>calendar`** (or `halcyon calendar`): your Google Calendar as a month plus the selected day's agenda and a "Next up" card. Arrows move the day, PageUp / PageDown the month, T = today, R = refresh, Esc closes.
- **Connecting**: no Google login. The **Open Google Calendar** button opens the settings in your browser and steps aside; copy the calendar's *Secret address in iCal format* (your calendar > Integrate calendar) and the island sees it on the clipboard, connects, and comes back. (It looks at the clipboard every 1.5 s for at most 6 minutes after you press the button, and only acts on a calendar.google.com iCal link.) The connect page is a numbered timeline (same look as the Timeline notifications) with the buttons inside the steps; **Paste from clipboard** and a text box are fallbacks. If every event says "Busy" (the public free/busy address), a banner offers **Fix it**, and the public address is refused up front. `gcal.py inspect` shows what a feed really contains. It is read-only, stored in `~/.local/state/island/calendar/config.json` (readable only by you), and any other calendar that offers an iCal link works too. Repeating events, time zones, all-day, moved and cancelled events are handled. Google *Tasks* (the to-do list) is not part of that address, only calendar events.
- **Reminders** arrive as ordinary notifications (app "Calendar"): 10 minutes before and at the start by default, changeable in the calendar's settings page; all-day events notify at 08:00. Synced every 15 minutes; `scripts/gcal.py` does the work.
- **Notifications now show above every window**, the tree view, Settings, the shortcuts tree and the rest included: while a toast or the centre is showing, the notification window moves to the Overlay layer, and is put back on top when another big window opens at the same time.

## Guided tour and "what's new" (first start and after updates)

- **First start**: the screen dims except for a light-ringed hole around the part being explained, with a card in the island's glass style (what it does, what can happen, key caps). Steps: island, search bar and `>` commands, performance and media pages, quick settings, notification centre, console, shortcuts tree, sysmode commands tree, tree view, settings. The island opens each thing for its step, and the highlighted part can be used. **Esc skips**, Right / Enter / Space = next, Left = back.
- The light follows the real size of the bar (it grows into pages, shrinks, slides), and the notch / auto-hide styles.
- **The only file to edit when a feature ships is `quickshell/island/features.json`.** After an update the island compares it with the copy the user saw last (`~/.local/state/island/features.seen.json`) and shows only entries that are new, or whose `rev` went up, as "What's new". Skipping counts as seen.
- Replay everything with `>tour` or `halcyon tour`. New files: `Tour.qml`, `Tour.js`, `features.json`.

## Choose the fish greeting's logo (adaptive, BlackArch, your own ASCII art)

- The greeting used to be hard-wired: the Kali dragon inside a Kali container, the Arch logo everywhere else. **Settings > Terminal greeting** now has **Logo in new terminals**: Adaptive (default), Arch, BlackArch, Kali, Linux, Custom, Info only, Off. `scripts/greeting-conf.sh` does the same from a terminal (`list`, `set LOGO <name>`, `paste`, `import FILE`, `edit`, `preview`); the choice is in `~/.config/Halcyon/greeting.conf`.
- **Adaptive** reads `/etc/os-release`: Arch, CachyOS, EndeavourOS, Manjaro, Garuda, Artix and ArcoLinux (and anything else that says it is Arch-like) show the Arch logo, BlackArch and Kali show their own, every other system shows a small Linux penguin. The `distro` line now shows the system's real name (`PRETTY_NAME`), so CachyOS no longer says "Arch Linux".
- **Custom**: your own ASCII art. In Settings, *Paste from clipboard* saves what you copied (needs `wl-clipboard`, which the clipboard history already uses) and switches to Custom; *Edit file* opens `~/.config/Halcyon/greeting-custom.txt` (starting from the penguin if it is new); *Preview* shows the greeting in a terminal. `@C1@` / `@C2@` in the text switch to the accent / grey colour, ready-made colour codes are kept, every other escape code is dropped when pasting, and at most 40 rows are shown. A missing or empty custom file quietly falls back to Adaptive.
- The logos moved out of the function into plain files (`config/fish/greeting/logos/arch.txt`, `kali.txt`, `blackarch.txt`, `linux.txt`), and the info block now centres itself next to whatever logo is shown (before, each logo had its row numbers typed in). The Arch layout is unchanged; the Kali info now sits in the middle of the dragon instead of at its head. The Kali and BlackArch logos keep their own colours; the others follow the wallpaper. The BlackArch logo is a stylised drawing, not the official artwork.
- `greeting.conf` and `greeting-custom.txt` are yours: git ignores them and `install.sh` never overwrites them.

## Commands tree: SUPER + ALT + /

- New `CmdTree.qml`: every console command as a tree, same look as the SUPER+/ shortcuts tree. Branches: Sysmode (secure, stealth, relaxed, lockdown, status, verify, logs, dossier, doctor; the ones that ask for your password are marked `sudo`), Hotspot, Halcyon windows, and the console's own words. Type to search, click a command to put it in the console (it is not run, you press Enter there), Esc or Super+Q closes it.
- Only set up with sysmode: `hyprland/keybinds.lua` binds `SUPER + ALT + slash` only when `/usr/local/bin/sysmode` exists, the island's `cmdlist` call does nothing without it, and the shortcut is hidden in the SUPER+/ tree (and not counted) until sysmode is installed. Like the other shortcuts it can be changed in the SUPER+/ tree.
- The console's `help` mentions it.

## Console takes the keyboard when it pops out; hotspot commands work in the console

- The top-left console now takes the keyboard by itself about 150 ms after it pops out (touching the corner, or clicking it in click mode), so typing goes straight into it even with a terminal open beside it. Brushing past the corner steals nothing. While the pointer is over the console it holds the keyboard exclusively (Hyprland's `follow_mouse` could otherwise hand it back to the terminal beside it); when the pointer leaves it is on-demand again, so clicking another window just works. A new window still makes it let go.
- `hotspot-on` / `hotspot-off` did nothing in the console and were missing from Tab completion: they were fish functions, and the console runs bash. The work moved to `scripts/hotspot.sh on | off | status` (fish functions now just call it), and the console knows both commands itself. The same goes for `halcyon <command>`, `bar-builder`, `notification-builder`, `wallpaper-gallery` and `startup-view`, which also complete with Tab (`halcyon` completes its sub-commands).
- `hotspot-off` no longer assumes the adapter is called `wlan0`: it finds the Wi-Fi adapter, stops only its own connection (`Halcyon-Hotspot`, so the decoy hotspot of `sysmode stealth --hotspot` is left alone), and puts the adapter back on normal Wi-Fi. The hotspot no longer starts by itself at boot. The hint now says `sudo sysmode relaxed`.
- Colour codes in command output are removed in the console (they used to show as stray characters).

## Autocomplete in the top-left console

- **Tab** completes the word under the cursor: commands (and the console's own words: `help`, `clear`, `cd`, `sm`, `sysmode`, the mode names) at the start of a command, also after `;`, `|`, `&` and after `sudo`; folders after `cd`; the sysmode actions after `sysmode` / `sm`; files and folders everywhere else (`~` works, folders get a `/`, spaces are escaped). One match completes it; several complete their common start and list up to 8 above the input line.
- Tab again goes through the matches (**Shift+Tab** back), **Esc** closes the list, typing anything else closes it too.
- A grey suggestion from your earlier commands follows what you type: **Right arrow** or **End** takes it.
- Completion runs in the background (`bash` `compgen`), only when you press Tab; nothing runs while you type.

## Fish commands, and the notification box slides when you move its parts

- install.sh / update.sh now install fish commands (`scripts/user-setup.sh fish-commands`, only when fish is installed): `bar-builder`, `notification-builder`, `wallpaper-gallery`, `startup-view`, and `halcyon <command>` for everything else (`halcyon --help` lists them: launcher, settings, notifications, dnd, cheatsheet, power-menu, quick-terminal, overview, gaming-mode, caffeine, lock, theme, reload ...), with tab completion. They use the island's IPC; two new IPC functions: `barbuilder`, `notifbuilder`.
- The notification box and its builder no longer use inline QML components (new files `NotifBlock.qml`, `NbCap.qml`): some Qt versions refuse them with "X is not a type".
- The fish step also installs `hotspot-on` / `hotspot-off` and the one-time command hints (`hints.fish`, in conf.d; for interactive shells only). `fish_greeting` was already shipped and is unchanged.
- Moving a part of the notification box with the arrows now animates: in the builder's list of parts and in the box itself (real and preview) the parts slide to their new places, and a part that is switched on or off fades while the others slide to fill or open the gap. It also slides when a notification arrives above another part.

## Notification box builder

- Settings > Panels & notifications > **Notification box builder** > "Open the notification box builder": its own window with a live copy of the real box (sample notifications; the buttons and the ✕ work, nothing real is touched). Everything saves and shows on the real box at once.
- **Parts**: the constellation band, the title and buttons, and the list can each be switched on or off and moved up or down.
- **Constellations and stars**: the drawing in the band on or off, the band's height, the drifting dots, the constellation behind the whole box, the flying stars (0 to 20) and the stars in popups.
- **Spacing and shape**: padding, space between the parts, space between notifications, corner roundness, width.
- **Place**: Top, Middle or Bottom of the right edge, with a distance from the edge, and a small picture of the screen. It still opens from the right edge of the screen.
- Also from the app menu: type `>` and then "notification box builder" (or "notif", "stars", "padding").
- A constellation band with nothing to draw (the drawing off and no dots, or no constellation available) takes no room instead of leaving a gap. "Distance from edge" can now go negative, and "Line up with the popups" puts the box at the same height as the popups; the box never goes nearer than 8 px to the screen edge.
- Fix: the ▲ ▼ and Shown / Hidden buttons for the parts did nothing once the layout had been saved (the saved list of parts was read back wrongly and the default order came back).
- The constellation band only takes room while there is a constellation to draw in it; the drifting dots now sit behind the whole box and take no room, so hiding the band (or having no constellation) lets the title and the notifications move up.
- SUPER+Q closes the notification box builder first, like the other builders, instead of the window under it.
- "Reset the box" goes back to the old look. New files: `NotifLayout.js`, `NotifBox.qml`, `NotifSurface.qml`, `NotifBuilder.qml`, `NotifBuilderWindow.qml`, `NbSlider.qml`. `Notifs.qml` now draws its panel with `NotifSurface`.

## Notification style: Stack, Timeline or Grouped by app, with the drifting stars

- Settings > Panels & notifications > **Notification style**: **Stack** (a card per notification, the default), **Timeline** (a thin rail with a dot per notification, under Just now / Earlier today / Yesterday / Older, no cards) or **Grouped by app** (one card per app with a count, its notifications inside, and a remove-all button on hover). Works in the right-edge panel and in the bar's drop-down page. New files: `NotifList.qml`, `NotifLine.qml`, `NotifGroup.qml`.
- The small stars that drift across the bar now also drift behind the notification panel and behind each popup. They follow Settings > Constellations (the notifications switch) and stop in Gaming mode like the other boxes.

## Notification box redesign, every message kept, smoother constellations

- Notification rows: an accent edge and a soft wash on the left (urgent ones in red), the app name in the accent colour with the time beside it, a round remove button on hover, a slightly bigger picture and title. A new notification lights its edge for a moment and slides in from the right; rows slide into place when others go. The header says "3 notifications" (or "You are all caught up") instead of "3 of 30 kept".
- Fix: only one `notify-send` message was shown. Messages from `notify-send` with the same title replaced each other. Now only Halcyon's own status messages (`-a Halcyon`) replace an earlier one with the same title; everything else, `notify-send` included, is kept unless it is an exact repeat (same title and text).
- Constellations: the breathing / sway / twinkle clocks no longer restart from 0 every time the art comes into view (that made the whole sky jump at the start); they keep their place. The motion eases in over about 1.6 s, the drawing fades in instead of popping into place, and the drifting dots carry on from where they were.

## Adaptive RAM / CPU limits

- Settings > Performance & memory > **Limits**: Manual (the two sliders, as before, still the default) or **Adaptive**. In Adaptive the island takes one reading of Halcyon's own RAM and CPU every 5 minutes (`startup-view.py adapt-sample`, kept in `~/.local/state/island/adaptive.tsv`, 14 days at most). Nothing is sampled while Adaptive is off or Gaming mode is on.
- After 3 days and 150 readings the limits are set from your own use: the busy 5 % of the time (95th percentile) plus headroom (RAM x1.25 rounded up to 50 MB, CPU x1.5 + 1 point), inside the same range as the sliders (300-1500 MB, 3-30 %). They keep adjusting over the last 14 days. Until then the manual limits apply.
- The Health tab shows the limits in use and how far the learning is. "Forget what it learned" in Settings (or `startup-view.py adapt-reset`) starts over; `startup-view.py adapt-status` prints the state as JSON.
- Like the manual limits, they only measure and advise: nothing is changed or stopped by itself.

## Adaptive RAM / CPU limits

- Settings > Performance & memory > **Limits**: Manual (the two sliders, as before, still the default) or **Adaptive**. In Adaptive the island takes one reading of Halcyon's own RAM and CPU every 5 minutes (`startup-view.py adapt-sample`, kept in `~/.local/state/island/adaptive.tsv`, 14 days at most). Nothing is sampled while Adaptive is off or Gaming mode is on.
- After 3 days and 150 readings the limits are set from your own use: the busy 5 % of the time (95th percentile) plus headroom (RAM x1.25 rounded up to 50 MB, CPU x1.5 + 1 point), inside the same range as the sliders (300-1500 MB, 3-30 %). They keep adjusting over the last 14 days. Until then the manual limits apply.
- The Health tab shows the limits in use and how far the learning is. "Forget what it learned" in Settings (or `startup-view.py adapt-reset`) starts over; `startup-view.py adapt-status` prints the state as JSON.
- Like the manual limits, they only measure and advise: nothing is changed or stopped by itself.

## Startup window: hover explanations, Health tab with limits

- The explanation line at the bottom of the Startup & processes window is gone. Every column title (ITEM, STARTED BY, MEMORY, CPU, PROCS), every caption of the memory bar, the filter row and the Suggestions tab now has a small round **?**: hover it and one bubble explains that word. The bubble lives on the card, so no list or row can cut it off (new `HelpTip.qml`). The bottom line only shows the answer to what you just did (for example "applies the next time you log in") and clears itself after a few seconds.
- New **Health** tab. It adds up all of Halcyon (Hyprland, the island with its helpers, the daemons) and compares it with two limits: RAM (default 600 MB) and CPU (default 10 % of the whole processor). Both are sliders in Settings > Performance & memory ("Halcyon RAM limit", "Halcyon CPU limit"). Over a limit, the tab lists the parts that cause it, the likely causes worked out from your own settings (resource preset, frame rate, moving stars, music bars, line drawing, background refresh, wallpaper size, how long the island has been running ...) and what to do, with buttons where one click is safe (switch to Low / Medium resource use, turn off a tray applet, End a program that is eating the machine). CPU is only flagged after two readings in a row (about 10 s), so a short burst raises no alarm. When the whole machine is short of memory it also says which other programs hold it.
- A "Halcyon is over its limit: see why" button and a "!" on the Health tab appear while a limit is exceeded. It only measures and advises; nothing is changed by itself, and nothing runs while the window is closed.
- Fix: the reader (`startup-view.py`) runs under the island, so its own process and the helpers it starts were counted as the island's load while the window was open. They are left out now.

---

## Notification centre: constellations above the text

- The constellations (dots, your profile constellation, the lockdown / stealth art) used to be drawn behind the whole panel, so notification text ran over their lines. They now have a band of their own at the top of the panel (about 150 px, smaller on short screens), and the title, DND / Clear and the notifications sit underneath, so the box is taller. The list is capped so the panel still fits on small screens. Settings > Constellations switches the band off (the panel is then as short as before).

---

## Settings: no more lag when searching

- The gesture and mouse-button editors built every hidden action list (about 45 chips and an app menu per row, up to six rows) as soon as they appeared, and each app menu listed all installed apps. A search that brought them up made typing stutter. The lists and the app menu are now created only while a row is open, and the editors read their data at most every 2 s.

---

## Startup window: Suggestions, honest CPU numbers

- **Suggestions tab** (and a "N suggestions" chip on the Startup tab): startup items that are running and can be turned off, each with the reason, the memory it would free, *Turn off* and *Keep* (Keep hides it for good, `~/.local/state/island/startup-keep`). It flags things that do nothing on this machine (touchpad gestures service without a touchpad, blueman without a Bluetooth adapter), things Halcyon already covers (nm-applet, the screen-sharing portal, which starts by itself when needed), file indexers / Evolution helpers, and chat / sync apps or heavy autostart entries (Steam, Discord ...) that can be opened by hand. Audio, portals, polkit, the keyring and the desktop itself are never suggested. Nothing is switched off without the button.
- **CPU** now shows the share of the whole processor (matches your overall usage) with the share of one core under it. Values are averaged over the last refreshes, so a short burst (power-manager starting `nvidia-smi` / `powerprofilesctl` during the 0.4 s snapshot read 116 %) fades instead of reading as a steady load.
- *PROC* is now *PROCS* (how many processes the item runs) with a wider column.
- micro: the current line was the colour of the text (micro paints it with the foreground colour of `cursor-line`); it is now a dark tint of the accent, text colours stay as they are.

---

## micro follows the wallpaper, and is transparent

- `scripts/app-themes.sh` writes `~/.config/micro/colorschemes/halcyon.micro` and selects it (`"colorscheme": "halcyon"` in micro's `settings.json`; your old file is kept once as `settings.json.before-halcyon`). The scheme gives the text, status bar, tabs and gutter no background, so micro shows the terminal's own translucent background (the grey blob was micro's built-in scheme painting over it). Syntax colours are the wallpaper's bright colours so they stay readable over it; only the current line, the selection and search hits have a background.
- Regenerated on every wallpaper change like btop and yazi; an open micro keeps the old colours until you restart it. `halcyon-doctor.sh` checks it.

---

## Startup & processes window, in the builder's and gallery's look

- Same header as the wallpaper gallery (icon, title, search box, segmented *Startup / Processes* switch, round refresh and close buttons) and the same few stars drifting over the card (follows Settings > Look > Moving stars).
- The three number cards are one memory bar: startup items, the rest of your session, everything else, free. Filters and sorting are segmented switches too.
- Rows light up on hover, memory has a small bar under the number, and the lists are updated in place every 5 s instead of rebuilt, so nothing flashes or jumps while you read. `/` searches, Esc clears the search first, then closes.

---

## Editable touchpad gestures and mouse buttons

- **Settings > Touchpad gestures**: 3 or 4 fingers, swipe left / right / up / down and pinch in / out, each set from a grouped list of actions (workspaces, windows, island panels, lock / sleep / screenshot, media, volume / brightness, terminal / browser / files, *Open an app* from the same app menu as the shortcut editor, *Run a command*). The defaults are what Halcyon always did. A gesture left on *Nothing* is not registered, so apps still receive it; pinch in and out set to the same thing is registered as one gesture. *Restore defaults* is there too.
- **Settings > Mouse buttons**: looks for connected mice (touchpads and virtual devices are not counted; checked every 4 s while the section is open) and, when there is one, offers back, forward and middle click, plus three extra buttons for gaming mice. Actions are the same as for gestures, plus *Move / Resize a window while held*. Left and right click are never rebound.
- How it works: `scripts/input-conf.sh` (`conf`, `set`, `reset`, `run`, no jq needed) keeps `~/.local/state/island/gestures.conf`; `hyprland/inputconf.lua` reads it for `hyprland/gestures.lua` and the new `hyprland/mouse.lua`; each gesture or button runs `input-conf.sh run ID`. Settings asks the island for a batched Hyprland reload after a change (new action `hypr-reload`).
- The old Workspaces > *4-finger swipe* option is gone: set 4-finger left / right to next / previous in the new section (an old "right = next" choice is carried over as the default).

---

## Settings regrouped, notifications that stay, a safer update.sh

- **Settings**: 24 groups became 16 (Mouse + Touchpad + Keyboard, Power + Sleep, Bar style + Bar, Motion + Shadows + Blur, Night light into Colours, Panels into Notifications, Rice into Apps). Long descriptions show one line with a "?" for the rest. Each group has an **Advanced** row for the rarely used settings (a search, or the header switch, shows them all). The two Backup / Safety-check reminder blocks are built by one helper.
- **Two Settings layouts, both kept.** The branching **Tree** (default) and new **Pages**: a trunk of 7 pages on the left (Appearance, Bar, Desktop, Input, Power & lock, System, Backup), one page of flat cards on the right, a short branch only where a row depends on the one above, Advanced inside each card. Switch with the chip in the Settings header or Settings > Look > Settings layout; same settings, same saving, the choice is remembered (`opt.settingsStyle`).
- **Notifications now stay in the centre.** An app that withdrew its own notification (read in the chat, tab focused ...) used to remove it from the centre too, and transient ones were never stored. Both are kept until you remove them.
- **Urgent popups no longer wait for a click for ever.** Browsers send "requires interaction" as critical. They hide after 30 s (Settings > Notifications > Urgent popups: 15 s / 30 s / 1 min / wait for a click); the notification stays in the centre. The cross on a popup is a real button now (removes it without opening the app).
- **update.sh**: runs inside one function (replacing itself mid-run is safe), one run at a time, network steps time out, a log in `~/.local/state/halcyon/update.log`, `--changes`, `--rollback`, `--notify`, `-q`, exit code 10 from `--check` when an update exists. An edit of yours that clashes with the update is saved in a git stash instead of leaving conflict markers in the file. After the reload it reads the island's log and reports a QML error at once, and runs a syntax check over the scripts and halcyon-doctor.

---

## Terminal music player routing, blurred lock screen, focus mode in Rust

- **spotify-player (and other terminal music players) now go to the music workspace.** The island only recognised the Spotify *app* by its window class; a terminal player has the terminal's class (`foot`, `kitty` ...), so it was never moved. `scripts/apps.sh run music` now starts a terminal music player with the window class `halcyon-music` (foot / kitty / alacritty / ghostty / wezterm / xterm / gnome-terminal) and `Routes.js` sends that class to SUPER+M. (konsole has no class option, so it keeps its own.)
- **Lock screen background option** (Settings > Sleep & lock): *Solid colour* (as before) or *Blurred wallpaper*, with **Lock screen blur** and **Lock screen tint** sliders. The tint is the opacity of the theme colour over the wallpaper (0 % = wallpaper as it is). The wallpaper is only decoded while the screen is locked; the blur is drawn once into a layer, not every frame.
- **Settings read Hyprland on/off options correctly**: `hypr-values.sh` also understands `"bool": true|false` (newer Hyprland), so switches like *Pause while typing* show what Hyprland really has.
- **Focus mode helper is native**: `hx focus ...` (`src/hx/src/focus.rs`) replaces `focus.py`; same files, same JSON. A running session no longer keeps a Python interpreter in RAM. `scripts/focus.sh` uses `hx focus` when the installed `hx` has it and falls back to `focus.py` otherwise.

---

## spotify-player in the rice, and a much shorter Settings

- **spotify-player** (the terminal Spotify client) is a choice in the installer: `./install.sh --choose` now asks "Music player" (Spotify, spotify-player, None; **several can be picked**, the first is SUPER+M), or `--music spotify,spotify-player`; the answer is remembered for update.sh. It is themed like btop / yazi: `app-themes.sh` writes a `halcyon` theme to `~/.config/spotify-player/theme.toml` from the wallpaper colours (your own themes in that file are kept, the terminal's background and blur show through) and sets `theme = "halcyon"` in `app.toml` (the old file is saved as `app.toml.before-halcyon`). It is read each time spotify-player starts. First run: `spotify_player authenticate`. It is also a choice in Settings > Default apps > Music (opens in your terminal on SUPER+M), and `halcyon-doctor.sh` checks it.
- **Settings is shorter: 152 rows became 123, and 26 groups became 24**, with nothing removed:
  - **Backup & safety** reads as one flow: **Backup** (Whole system / Home folder only), **Restore** (From a backup / Home folder only), **Remind me to back up** (Off / Day / Week / Month / 3 months / Custom in one row; the day count only shows for Custom), then the safety check, its reminder and the automatic run. Before: 14 rows in the order backup, backup home, restore, restore home, safety check, then six reminder rows.
  - Two new row kinds do most of it: **several buttons in one row** (Backup, Restore, Memory report + Detect RAM, Edit config + Shortcuts + Reload) and **several switches in one row** (what the bar shows, the clock, the constellation boxes, touchpad behaviour, focus options, workspace behaviour, Do not disturb + Wi-Fi errors only).
  - Options that only matter while another is on now hide until it is: time per colour (colour cycling), terminal colour options (terminals follow the wallpaper), blur strength / quality (blur), the page-close speed (hover opens a page), how long the volume bar stays (volume bar on), the constellation boxes (constellations on).
  - **Colours** now includes the terminal colours, and **Workspaces & windows** includes switching workspaces.
- **Your own command for every special workspace.** Settings > Workspaces & windows > Special workspace commands: a command per workspace (scratch, music, communication, system monitor, todo), started whenever it is opened with no window in it. Empty = the default. Scratch (SUPER+S), system monitor and todo now start through `special.sh --run`, so a change applies at once with no Hyprland reload.

---

## SUPER+D is yours: WhatsApp and any website

- **Settings > Default apps > Chat** now also lists websites that open in your browser as their own window: WhatsApp, Telegram (web), Messenger, Google Messages, Discord (web), Teams (web). They show whenever a browser is installed. SUPER+D still opens whatever is picked, on the communication workspace.
- **Add website**: type a name and an address (`web.whatsapp.com`) and it is added and chosen at once; the **×** next to one you added removes it. Same from a terminal: `apps.sh add-web <Name> <url>` / `apps.sh remove-web <id>`. Chromium-family browsers (Chromium, Chrome, Brave, Vivaldi) open it with `--app` (no tabs or address bar); other browsers open a new window.
- A website is never picked for you: with no chat app installed, SUPER+D starts nothing until you choose one. Windows of the built-in sites are moved to the communication workspace like Discord and Telegram are.
- Fixed: the bar builder failed to load (`Slot is not a type`); its inline components are renamed.

---

## Bar builder: Island or Notch, the real bar as the editor, padding you can type

- **Shape.** Style = Custom can now be a **Notch** (hangs from the top edge, flared corners, as before) or an **Island** (a floating rounded pill a little below the edge). Pick it in Settings > Bar style > Bar builder, or at the top of the builder window. Saved in `opt.barLayout.shape`; layouts saved before this stay Notch.
- **The bar is the editor.** The builder window now draws the bar itself, with the same widgets, sizes and spacing as the real one (samples for the time, battery, Wi-Fi ...), at the chosen shape. Drag a widget along it to reorder, onto another place to move it, onto the shelf to take it off. Widgets that only show sometimes (Caffeine, Focus, Bg apps) are always shown there so they can be placed.
- **Symmetry help.** While you drag, a line marks the exact centre of the screen and the drop shows what Left / Right would come to ("✓ the sides match" or "N px apart"). When the sides differ, the builder suggests the one move that evens them out, with a button to apply it. The middle is always centred.
- **Padding.** Type px (or use - / +, or leave "auto") for the edge padding, the gap between widgets and the clearance around the middle. Click a widget on the bar to give just that one its own padding. Saved in `opt.barLayout` (`edge`, `gap`, `clear`, `pads`); `null` = the automatic spacing, so nothing changes until you type a number.

## Yes by default, backup / safety-check reminders, automatic safety check, pitch-black boxes

- **Starship badge really fixed.** Starship ran the badge command in fish (your login shell) and it was POSIX `sh`, so it printed nothing. The table now has `shell = ["sh"]`; `app-themes.sh` repairs an installed starship.toml that has either earlier version of the badge (a copy is kept as `starship.toml.before-sysmode-fix`).
- **Questions default to yes** ([Y/n], Enter = yes): the installer's confirmations (including adding the safety check, which is now on by default; `--no-safety-check` skips it), and `backup-device.sh` (start the backup, eject the disk). The one exception is setting up the lock-screen login, which stays [y/N]: it was deliberately made opt-in after it left a machine booting into a broken desktop. With no terminal to ask on, `confirm` still answers no, so a piped install never goes ahead by itself.
- **Settings > Backup > Remind me**: a toggle for backups and one for the safety check, each with Day / Week / Month / 3 months / Custom (1-365 days). `scripts/remind.sh`, a user timer (`halcyon-remind.timer`) that only runs while a reminder is on, one notification when it is due. "Done" is noted by `backup-device.sh` and by the Settings safety-check button.
- **Settings > Backup > Safety check > Run it automatically**: a root timer (`scripts/safety-auto.sh`) with the same schedule choices. Switching it on, changing how often and switching it off all need your sudo password (`sudo -k -S`: a password you typed a minute ago does not count). Everything that runs as root is root-owned (`/usr/local/bin/safety-check`, a small wrapper written to `/usr/local/bin`, the unit files), nothing in your home folder. New `safety-check --auto`: never updates the system, never asks, never formats; the backup step only runs when the known backup disk is plugged in; waits for AC power. Needs the safety-check binary rebuilt (`./update.sh`).
- **Settings > Look > Box background**: Wallpaper tint (as before) / Matte black / Pitch black. Matte and black make every box, the bar and the Settings window solid. The drifting dots and constellations keep the accent colour and get brighter so they still show on black. Dark theme only.
- `halcyon-doctor.sh` now also checks the installed sysmode, the mode file, the starship badge and the reminders.

---

## Performance, Memory Leak, CPU Usage & Daemon Optimization Audit (October 2026)

### 1. Root Cause Analysis: Unusually High CPU & RAM Usage
- **Root Cause Identified:** A runaway `gvfsd-metadata` daemon process (PID 24128) was trapped in an infinite spin loop, consuming **96.8% CPU (104+ minutes of cumulative CPU time) and 1.2 GB RSS / 1.3 GB VmPeak RAM**.
- **Underlying Cause:** `scripts/backup-device.sh` executed `rsync` recursively across `$HOME` (`HOME_ONLY=1`) without excluding volatile lockfiles and internal socket structures, notably `~/.local/share/gvfs-metadata`. When rsync accessed active metadata journals while file operations were occurring, GVFS metadata journals corrupted, causing `gvfsd-metadata` to endlessly spin attempting to parse corrupted journal structures.
- **Resolution:**
  - Terminated the hung `gvfsd-metadata` process and cleaned invalid journal locks; system RAM usage dropped from 4.3 GiB to 2.8 GiB, and CPU utilization normalized to near zero.
  - Updated `scripts/backup-device.sh` to explicitly exclude `--exclude=.local/share/gvfs-metadata` and `--exclude=*.sock`.

---

### 2. Fork Storm & CPU Optimization in `src/hx/src/ctl.rs`
- **Issue:** The main control loop in `hx ctl` runs every 60ms to deliver instant slider feedback. In `bright(&bl)`, when `/sys/class/backlight` is unavailable (e.g. desktop systems, external monitors, or unexposed GPU backlights), the function fell back to executing `util::run("brightnessctl", &["-m"], 2)`. This resulted in **16 subprocess forks every second**, causing continuous CPU thrashing and process churn.
- **Resolution:** Introduced cached state tracking with an `Instant` rate limiter. If sysfs is unavailable, `brightnessctl` is now queried at most once every 1,500ms, returning the cached brightness value between checks.

---

### 3. Memory Spike & Allocation Optimization in `src/hx/src/status.rs`
- **Issue:** `hx status` read entire log files (`fs::read(format!("{}/recon-attempts.log", logs))` and `ids-alerts.log`) into memory buffers on every status poll, converting whole files into lossy UTF-8 strings before splitting into lines. As attack and IDS logs accumulate tens or hundreds of megabytes, this triggered periodic multimegabyte heap allocations and memory spikes.
- **Resolution:** Replaced full-file reads with `std::io::BufReader` line streaming. Lines are now processed sequentially with fixed memory footprint ($O(1)$ RAM buffer of ~8 KB) regardless of file size.

---

### 4. Power Manager Daemon (`src/power-manager/src/main.rs`) Optimizations & Bug Fixes
- **Eliminated Synchronous 500ms Thread Sleep:**
  - *Issue:* `get_cpu_usage()` previously called `thread::sleep(Duration::from_millis(500))` inside the polling loop to measure CPU usage deltas. This blocked the daemon thread for half a second on every poll tick.
  - *Fix:* Extended `LoadState` to track previous `/proc/stat` CPU snapshots across normal 15-second loop iterations, computing deltas asynchronously with zero sleep.
- **Fixed evdev Input Polling & File Descriptor Thrashing:**
  - *Issue:* `has_input_activity()` previously iterated `/dev/input`, opened every `event*` device, ran `poll(timeout = 0)`, and immediately closed them. Because newly opened evdev file descriptors have empty kernel buffers, this almost never detected real user activity and generated dozens of wasteful syscalls per poll.
  - *Fix:* `LoadState` now retains open `Device` handles across poll ticks, allowing the kernel to buffer input events over the 15-second interval. It drains events non-blockingly each tick and gracefully re-enumerates on device disconnects. In addition, it checks `/dev/shm/halcyon-dim` to immediately detect hypridle dim states.
- **Fixed Game Mode Detection:**
  - *Issue:* `is_gaming_mode()` invoked `qs -c caelestia ipc call gameMode isEnabled`, which always failed because Halcyon uses the Island shell rather than Caelestia, spawning a failed subprocess every 15s. It also failed to check Halcyon's active gamemode indicator.
  - *Fix:* Added an instant check for `/dev/shm/halcyon-gamemode` before falling back to `gamemoded -s`, and removed the defunct Caelestia command.
- **Fixed PPM Binary Image Parsing in `get_dominant_color_from_video()`:**
  - *Issue:* Attempted to parse binary PPM (`P6`) frames from ffmpeg by converting raw stdout into UTF-8 strings and splitting on `\n`. Binary pixel bytes containing `0x0A` were misinterpreted as newlines, corrupting color calculations.
  - *Fix:* Replaced UTF-8 splitting with a robust binary PPM header parser operating directly on raw byte slices.

---

### 5. Memory & Process Leaks in Security Daemons
- **`src/recon-deceiver/src/main.rs`:**
  - *Socket Panic / Resource Fix:* Replaced redundant `s.try_clone().unwrap()` on accepted TCP sockets by directly moving `s` into connection handler threads, eliminating file descriptor duplication and panics on abrupt client disconnects.
  - *Zombie Process Leak:* Spawning `notify-send` previously dropped child process handles without waiting for exit, leaking zombie processes. Wrapped child process invocations with asynchronous waiter threads.
- **`src/log-analyst/src/main.rs`:**
  - *Zombie Process Leak:* Reaped `notify-send` child processes via background helper threads to prevent zombie process leaks.
  - *Log Rotation Truncation:* Added file size inspection to reset seek position to beginning of file if log files are rotated or truncated.

---

### 6. Shell Script Reliability Fixes
- **`scripts/osd-watch.sh`:**
  - Guarded against bash division-by-zero crashes when brightness or keyboard backlight maximum values are reported as 0 (`[ "$bmax" -gt 0 ]` and `[ "$kmax" -gt 0 ]`).
  - Added fallback sleep (`|| sleep 0.25`) to prevent tight CPU spin in case `inotifywait` fails or is interrupted.
- **`scripts/halcyon-doctor.sh`:**
  - Added new automated **"System & Process Health"** diagnostics section checking for runaway `gvfsd-metadata` processes, zombie processes, and low available memory.

---

### 7. Quickshell & QML UI Bug Fixes
- **`quickshell/island/NotchBar.qml`:**
  - Fixed Qt Quick runtime warning: `Cannot anchor to an item that isn't a parent or sibling` by replacing invalid cross-hierarchy `anchors.fill: rightMain` with bound geometry coordinates (`x`, `y`, `width`, `height`).
- **`quickshell/island/Cheatsheet.qml`:**
  - Fixed recurring `ReferenceError: search is not defined` runtime exceptions (triggered whenever the cheatsheet was opened or closed) by relocating the focus `Timer` and `Connections` inside `TextInput { id: search }` where `search` is in scope.

---

## Drag the bar down: utilities box and notifications inside the bar, launcher arrow keys

- **Settings > Bar style > Drag the bar down** (Off / Two steps / Side by side; default Off). Pull the bar down (island or notch) and the utilities box drops out of it as a page, the same box as the bottom-right corner one (Wi-Fi, Bluetooth, audio, sliders, power mode, Focus, Settings, power). **Two steps**: drag down again for the notifications, drag up to go back. **Side by side**: the notifications sit next to the utilities box. The corner box and the right-edge notification centre keep working as before.
  - The page has a small handle at the bottom: drag it down / up or tap it to move between the bar, the utilities box and the notifications. It folds back by itself when the pointer leaves (like the media and performance pages), and with Esc / SUPER+Q.
  - New `NotifCentre.qml` (same header and rows as the notification centre, no window of its own). Looking at the notifications here marks them read and hides the popups. The Wi-Fi password field works in the page (it asks for the keyboard like the corner box does); the volume OSD stays quiet while the box is open, like with the corner box.
  - Scrolling over the bar no longer changes pages while one of these two pages is open (it would have fired while moving a slider).
- **Launcher: the arrow keys walk through the apps once you have typed something.** Up / Down move a row, Left / Right one app. With the box empty (or while paging through old searches) Up / Down still step through search history as before; Shift / Alt / Ctrl + Left / Right still move the text cursor.

---

## Clock centring: island and notch

- **Notch: the clock is now always dead centre of the screen.** Before, it only was with Bar spacing "Spacious" or the "Keep the clock centred" switch; by default the bar was just as wide as its content, so the clock sat wherever the content put it. `centerClock` in `NotchBar.qml` is now always on (the shorter side keeps empty space) and the "Keep the clock centred" switch is gone from Settings > Bar style.
- **The ":" of the clock is on the screen's centre line (both bars).** The whole text "05:57 PM" was centred, so the colon sat a few pixels left of the middle (over a centre webcam it looked off). The clock is pushed right by exactly the distance between the middle of the text and the colon, measured from the real font (`colonShift` in `Home.qml` and `NotchBar.qml`); the bar stays centred, the left side gets the extra room.
- **Settings > Clock: "Centre the" (Colon / Whole text) and "Nudge the clock" (4 left ... 6 right).** The colon alignment is on by default; "Whole text" gives the old behaviour, and the nudge adds pixels on top for a screen or webcam that sits a little off. Both bars follow it.
- **Clock shortcuts in the bar (both styles):** right-click the time = 12 / 24 hour, middle-click = seconds.
- **Settings cleanup:** the dead `notchCenter` option is dropped from the defaults and ignored when an old `settings.json` still has it.
- **Island: the time stays centred when one side is empty and while the hover stats slide out.** `Home.qml` used to size the two slots equally only when both had content, and grew only the right slot on hover (which pushed the time left). Both slots now always share one width.

---

## sysmode "mixed" badge fixed, lighter prompt and greeting

- **`[mx]` / "CUSTOM / MIXED" instead of relaxed is fixed.** `sysmode`'s `detect_mode` returned `/etc/sysmode.mode` as written, so a file that still said `cyber` (or `hacking`) matched no mode and was shown as mixed. It now reads `cyber` as `relaxed` and `hacking` as `stealth`, like `stats.sh` and `hx status` already did. Needs the new `sysmode` installed to `/usr/local/bin` (`./update.sh`).
- **Starship no longer runs `sysmode status` on every prompt.** That call ran ~15 commands (systemctl x4, docker inspect, auditctl, pgrep, sysctl ...) before each prompt. The badge now reads `/etc/sysmode.mode` in one small `sh` (`[rx]` relaxed, `[se]` secure, `[st]` stealth, `[ld]` lockdown, `[mx]` anything else), and only asks `sysmode status` when the file does not exist yet. The old badge command also had an escape-code regex that never matched; that is gone with it.
- **`app-themes.sh` fixes an installed `~/.config/starship.toml`** too (the file is yours and is never replaced): only its old `[custom.sysmode]` table is swapped for the new one, once, with a copy kept as `starship.toml.before-sysmode-fix`.
- **The `halcyon` badge is plain text in the prompt format**, so it no longer starts a shell per prompt just to print a constant.
- **fish greeting**: reads the mode file directly (same names and colours as `sysmode status`), uses `$version` and `$USER` instead of `fish --version` / `id -un`, and one `free` call instead of two.

---

## App picker menus (Focus block list, shortcuts) and "cyber" is now "relaxed"

- **New `AppPicker.qml`**: a searchable, scrollable list of every installed app (the launcher's own list, from the desktop entries). Click one and it hands back the app's name, a window class guess, its program name and a ready-to-run command (terminal apps are wrapped so they open in your terminal; arguments are quoted).
- **Settings > Focus > Blocked apps**: "Pick from all your installed apps" blocks an app that is not open right now. It adds the class from the app's launcher entry plus its program name in one write (`focus.sh block CLASS [CLASS...]` now takes several classes). The open-windows chips and the typed class box are still there; if a picked app still opens, click it under "Open right now" while it runs to get its exact class.
- **Shortcuts (SUPER+/) > Your shortcuts**: both the "+ Add a shortcut" form and the editor of a shortcut you added have a **Pick an app instead of typing** button. Choosing an app fills the command (and the name, unless you typed your own); you can still edit the command afterwards.
- **sysmode: the `cyber` mode is now `relaxed`** (`sudo sysmode relaxed`). `cyber` still works as an alias, and an old `/etc/sysmode.mode` that says `cyber` is read as `relaxed` until the next switch. Renamed in the CLI, `sysmode status` (shows RELAXED), the man page, bash completion, the Performance page colour, the quick terminal (`relaxed`, `cyber` still typed as a one-word command), the shortcut tree, the installer text, the README and the Starship prompt badge (`[rx]`, was `[cy]`).

---

## Optional safety check in install.sh and Settings, install.sh shows SUPER+/

- **install.sh now says SUPER + / (not SUPER + Alt + /)** for the shortcut tree in the "First keys" list at the end; the comment in `scripts/cheatsheet.sh` matches. (The binding itself was already SUPER+/ in `keybinds.lua` and `Binds.js`.)
- **Safety check** (new, optional): the `safety-check` program (`src/safety-check`, Rust) runs a system update, a ClamAV malware scan, an rkhunter rootkit check, a firewall check, a Lynis audit, an AIDE integrity check (every 30 days) and a backup to an external disk, with a log in `~/logs/safety_check/`.
  - `./install.sh` asks "Add the safety check?" (default **no**; answer remembered as `SAFETY_CHECK` in `install-choices.env`, so `update.sh` does not ask again). Command line: `--safety-check` / `--no-safety-check` (`update.sh` passes both on); `--choose` asks again.
  - Yes: installs `clamav rkhunter lynis aide ufw rsync libnotify`, builds the crate with the other helpers and installs it **root-owned** as `/usr/local/bin/safety-check` (it runs as root through sudo, so nothing running as you may be able to change it).
  - No: nothing is installed, and a binary left from an earlier "yes" is removed.
  - **Settings > Backup > Safety check** starts it in a terminal (asks for your password). When it is not installed the entry is **greyed out and disabled** and says how to add it (`startup-conf.sh list` reports `has.safety`; `ActionChip` has a new `disabled` state; any Settings item can use `needs: "<has key>"` for the same effect).

---

## Focus mode, corner-box flicker fix, one copy of every duplicated setting

- **Focus mode** (new): utilities box > FOCUS, SUPER+ALT+F, `scripts/focus.sh` + `scripts/focus.py`. Timer (25 / 50 / 90 min, optional Pomodoro with short / long breaks), Do not disturb + Caffeine for the session (restored to what they were afterwards), a block list of window classes that are closed when they open, Pause / +5 min / Skip / Stop, the time left in both bars. Options and the list are in Settings > Focus mode. The "Blocked apps" button in the box opens that group directly (`Settings.show("focus")`).
- **Bottom-right (and bottom-left) box no longer flickers when the pointer rests in the corner.** The layer surface used to grow from a 48 px tab to the full box and shrink back, and every resize made the compositor re-pick the pointer focus: leave, close, shrink, enter, open, again. The surface now keeps one size (the input region still limits what it catches), and a box that has just closed ignores enter events for 600 ms. Costs about the 1.5 MB buffer the old code saved while the box was closed.
- **Settings: duplicates merged, options placed where you look for them.**
  - Bar style had every option twice (island and notch). Each is now ONE entry that writes both (`pair:` keys in `Settings.qml`): workspaces, capsules shown, special icons, music bars, combined status icon, Wi-Fi / look, Bluetooth, battery, battery %, Caffeine icon.
  - The time and the day / date moved from Bar style into **Clock** (the notch's separate "Show the day and date" is gone: one switch for both bars). "Bar spacing" moved into **Bar** next to "Bar size and padding".
  - "Show the background apps count" (notch only) is gone: Bar > Background apps count already decides it.
  - **Edge gestures** existed twice (Touchpad, a temporary mute; Startup, start at login). Now one switch in **Touchpad** (starts / stops the helper and is remembered across logins). SUPER+ALT+G still mutes them for a moment.
  - "Music bars in the bar" (quality Full / Light / Off) moved from Performance to Bar style, right under the Music bars switch, and is called "Music bars quality".
  - The notch's "Accent colour" is now "Notch accent colour" (it had the same name as Colours > Accent colour).

---

## Smart special icons, SUPER+/ cheatsheet, Enter saves, SUPER+Q closes overlays

- **Notch bar: special workspace icons pick a side** (`NotchBar.qml`, Settings > Bar style > Special icons side: Auto / Left / Right). Auto with the clock centred puts them on whichever side does not widen the bar.
- **Island bar: Compact / Spacious (Settings > Bar style) and a truly centred time.** Left and right halves are equal, so the time is dead centre; the music bar floats between the workspaces and the time, the day / date between the time and the status icons.
- **Bar spacing: Compact / Spacious** (Settings > Bar style); spacious keeps the time dead centre with roomier gaps and the music bar floating between the workspaces and the time.
- **Cheatsheet is now SUPER+/** (was SUPER+ALT+/), in `keybinds.lua` and `Binds.js`. Enter saves a shortcut you are adding / editing.
- **SUPER+Q closes the top island overlay first** (power menu, settings, shortcuts, tree view, quick console, notification centre, launcher / perf / media page) and only closes the focused window when none is open (`scripts/close.sh`, IPC `closeTop`).

---

## Mouse move / resize, click-to-reveal auto-hide, combined status icon

- **SUPER + right button drag moves a window, SUPER + left button drag resizes it** (`hyprland/keybinds.lua`, buttons in `variables.lua` as `kbMouseMove` / `kbMouseResize`; listed in the cheatsheet under Windows).
- **Auto-hide now respects Settings > Edge boxes = Click** (island and notch). The hot strip along the top edge used to reveal the bar on hover whatever that setting said; in Click mode it now needs a click, and the bar hides again once the pointer has left it (or after 2.5 s if it never reached it). Hover mode is unchanged.
- **Combined status icon** (`island/StatusRing.qml`, Settings > Bar style > Combined status icon, on by default for both bar styles): Wi-Fi in the centre, the battery as a ring around it, Bluetooth devices as dots closing the ring's gap. `net.sh` now also reports `btn`, the number of connected Bluetooth devices. "Wi-Fi look" is hidden while the combined icon is on. `Settings.qml` `when:` conditions can now be joined with `&`.

---

## Options to use less RAM and CPU (Settings > Performance & memory, Startup & background)

- **Background refresh** (Normal / Relaxed / Slow): `stats.sh` (CPU, battery, sysmode) and `net.sh` (Wi-Fi / Bluetooth state) look again every 2 s / 4 s normally, 5 s / 10 s relaxed, 10 s / 20 s slow. The performance page and the bar's CPU / RAM / TEMP hover row keep the normal pace, and connecting to Wi-Fi or Bluetooth updates the bar label at once. Both scripts wait on a pipe in `$XDG_RUNTIME_DIR` that the island pokes when a flag changes.
- **Music bars** (Full / Light / Off): Light runs `cava` at 15 fps (`cava-light.conf`), Off does not start it. Low / Medium / High now set both options above too.
- **Clipboard history**, **Touchpad edge gestures** and **Screen-sharing helper** (at login / on demand) can be switched off in Startup & background. They used to be fixed lines in `hyprland/execs.lua`; `scripts/autostart-extras.sh` starts them from `~/.config/Halcyon/autostart.conf` now (new keys `CLIPBOARD`, `GESTURES`, `PORTAL`; defaults keep today's behaviour).
- **Fewer process starts**: `net.sh` goes from about 16 program launches per tick to 5; `net.sh`, `stats.sh`, `gpu.sh` and `osd-watch.sh` no longer start a `sleep` per tick (`osd-watch.sh` did it 4 times a second).
- The lock-screen picture and the music cover are decoded at their shown size (2x) instead of the file's own size.
- **Wi-Fi & Bluetooth: only tell me about errors** (Settings > Notifications): skips the "Connected" / "Disconnected" notifications and keeps the failures.

---

## Smaller Thunar icons and a lighter stats loop

- **Thunar icons** (`scripts/thunar-look.sh`): every preset is one step smaller. Medium (default) is now side bar 22, lists 24 px, icon view 48 px (was 24 / 36 / 72). Small and Large moved down the same way. The sizes are re-applied once on the next login for everyone who already had the old ones; a size you set by hand afterwards is left alone.
- **`stats.sh`** (runs every 2 s): `upower` is now found once and read at most every 15 s with a single call, instead of up to five process starts per tick on laptops without sysfs battery estimates. `fmt` is defined once instead of on every tick.
- **`power-manager` and `touchpad-gestures`** now build with the same release profile as the other crates (LTO, one codegen unit, stripped, panic = abort): smaller, faster binaries.
- Removed `scripts/app-themes.sh.bak`, an older copy of `app-themes.sh`.

## Backup this device, btop --force-utf

- **Settings > System > Backup** (new): "Backup this device" and "Backup my home folder only". They open a terminal running `scripts/backup-device.sh`: it lists the external disks that are plugged in (never the system disk), mounts the one you pick, and copies with rsync into `<disk>/Halcyon-backup/<host>/<date>/` (hard-linked to the last run, `latest` link, nothing is erased or formatted). `--dry-run` shows what would be copied.
- CTRL+SHIFT+ESC system monitor now starts `btop --force-utf` (`sysmonCmd` in `variables.lua`).

## Settings, notification spot and Thunar icons

- **Settings tree**: groups and items regrouped by topic (Look, Colours, Wallpaper, Transparency/blur/dimming, Motion, Night light, Workspaces & windows, Bar, Notifications, Panels & on-screen display, Input, Power, Performance & memory, Startup, Default apps, Constellations, Rice). Searching with few hits no longer draws the empty second column's tree line.
- **Notification trigger spot**: new Settings option, right edge (default) or top-right corner.
- **Thunar / GTK icons**: `gtk-theme.sh` uses Papirus-Dark / Papirus-Light when installed (`papirus-icon-theme`, now installed with Thunar; `~/.local/state/island/gtk-icons = off` keeps your own), no washed-out selection effect on icons, higher-contrast toolbar / sidebar / menu icons.

---


## 1. QuickShell Island: Idle High CPU & Memory Leak Resolution

### Problem & Diagnostic
During idle desktop usage, `/usr/bin/quickshell -p ~/.config/Halcyon/quickshell/island` consumed **40% to 63% continuous CPU** on a dedicated core and maintained an elevated RSS memory footprint (~485 MB).

Profiling revealed:
- Six backdrop instances (`Settings`, `PowerMenu`, `Cheatsheet`, `QuickTerm`, `Lock`, `Notifs`) were instantiated at shell startup.
- In each instance, `Backdrop.qml` continuously executed an unthrottled 60 FPS `NumberAnimation on tt` calculating trigonometric coordinates (`Math.sin`, `Math.cos`) across 35 floating dust particles.
- Each `Backdrop.qml` also embedded `ModeArt.qml`, which ran two infinite 60 FPS animation loops (`ph` and `cyc`), a shooting star timer, and trigonometric property bindings for over 160 star particles and traveling light beams—**even when the parent popups and overlay windows were completely closed and hidden**.
- In `Ring.qml`, four 4x MSAA Canvas elements in the performance monitor were animated offscreen on every 2-second polling update from `stats.sh`.
- Continuous QML runtime exceptions (`TypeError: Cannot read property 'indexOf' of undefined` in `Settings.qml` line 261, and `TypeError: Cannot read property '...' of null` in `NotifRow.qml`/`NotifCard.qml`) flooded logs and triggered costly JS exception handler overhead.

### Changes & Fixes
- **`quickshell/island/Backdrop.qml`**:
  - Added a reactive `live` property: `readonly property bool live: visible && opacity > 0.01 && (pal ? pal.motion > 0.3 : true)`.
  - Bound the infinite trigonometric time-loop `NumberAnimation on tt` to `root.live` instead of `root.visible`.
  - Bound the dust particles repeater model to `root.live ? root.dots : 0` to unmount particle delegates when hidden.
  - Forwarded `alive: root.live` to child `ModeArt`.
- **`quickshell/island/ModeArt.qml`**:
  - Bound the star particle repeater model to `root.visible` so offscreen star meshes are not retained in active rendering graphs.
  - Required `opacity > 0.01` in the `live` property to halt traveling beams and shooting star timers during fade transitions.
- **`quickshell/island/Settings.qml`**:
  - Bound `Backdrop` visibility to `root.open && root.opt.stars !== false && root.opt.starsSettings !== false`.
  - Added strict parameter guard to `function get(key)` (line 261) ensuring `key` is a non-null string before calling `.indexOf('/')`, eliminating recurring runtime TypeErrors.
- **`quickshell/island/PowerMenu.qml`**: Bound `Backdrop` visibility to `(root.open || fade.opacity > 0.01) && root.stars`.
- **`quickshell/island/Cheatsheet.qml`**: Bound `Backdrop` visibility to `root.open && root.stars`.
- **`quickshell/island/QuickTerm.qml`**: Bound `Backdrop` visibility to `root.shown && root.stars`.
- **`quickshell/island/Lock.qml`**: Bound `Backdrop` visibility to `root.locked && root.stars`.
- **`quickshell/island/Notifs.qml`**: Bound `Backdrop` visibility to `panel.visible && root.stars`.
- **`quickshell/island/Ring.qml`**: Added `enabled: root.visible` to `Behavior on shown` to suspend offscreen Canvas geometry redraws during periodic stats polls.
- **`quickshell/island/NotifRow.qml` & `quickshell/island/NotifCard.qml`**: Added null/undefined checks for `notif` and `notif.actions` in urgency evaluation, timeout calculations, default action triggers, and text bindings to eliminate TypeError exceptions during notification dismissal and delegate recycling.

### Outcome
Idle CPU usage of the Quickshell island dropped from **~60% to 0.0%**. System temperature, fan noise, and battery drain are substantially reduced.

---

## 2. Installer: Step 10 `user_systemctl` Execution Failure

### Problem
Running `./install.sh` failed at Step 10 (Services) with:
```
env: ‘user_systemctl’: No such file or directory
[ FAIL ] 'Reloading the user systemd' failed (exit code 127)
```

### Root Cause
`install.sh` defines `user_systemctl()` as an internal bash shell function that wraps `run_as_user env "DBUS_SESSION_BUS_ADDRESS=..." systemctl --user "$@"`. Lines 940, 943, and 945 invoked `run_as_user_cmd "..." user_systemctl ...`. `run_as_user_cmd` dispatches via `env`, which searches `PATH` for an external binary named `user_systemctl`. Because `user_systemctl` was a shell function, `env` returned exit code 127.

### Changes & Fixes
- **`install.sh`**:
  - Replaced `run_as_user_cmd` with `run_cmd` for all three calls in Step 10:
    ```bash
    try run_cmd "Reloading the user systemd" user_systemctl daemon-reload
    try run_cmd "Starting touchpad gestures" user_systemctl start touchpad-gestures.service
    [[ "$PACKAGES" == "true" ]] && try run_cmd "Enabling PipeWire for the user" user_systemctl enable --now pipewire pipewire-pulse wireplumber
    ```
  - `user_systemctl` already handles user privilege dropping and session D-Bus routing internally.

---

## 3. Power Manager Daemon: Hardware Compatibility & State Corruption Fixes

### Problems
1. **False Battery Mode**: `ac_online()` strictly looked for `/sys/class/power_supply/AC0/online`. On HP Victus and systems with `/sys/class/power_supply/ACAD/` or `/sys/class/power_supply/ADP1/`, `ac_online()` always returned `false`. This forced the daemon into battery power-saving mode permanently even when connected to wall power, reducing monitor refresh rate, disabling the dGPU, and halting live wallpapers.
2. **Broken AMD Thermal Throttling**: `get_cpu_temp()` checked only for `/sys/class/thermal/thermal_zone*/type == "x86_pkg_temp"`, an Intel-specific sysfs interface. On AMD Ryzen systems (where CPU temperature is exposed via `k10temp` in hwmon or `acpitz`/`Tctl` in thermal zones), it returned `None`, disabling thermal throttling.
3. **Hardcoded 16:10 Aspect Ratio & Monitor Output**: Screen modes were hardcoded to `1920x1200@144` and `1920x1200@60` targeting `eDP-1`. On 16:9 displays (1920x1080) and custom resolutions, sending these commands caused mode mismatches and display failure.
4. **Scheme Lua File Corruption**: `update_scheme_primary` used `content.replace("    primary = \"", &new_primary)` which replaced the prefix but preserved existing trailing characters, resulting in malformed syntax such as `primary = "abcdef",\n123456",`. Furthermore, it only modified `~/.config/hypr/scheme/` and ignored `~/.config/Halcyon/scheme/`.
5. **Hardcoded User Paths**: Fallback home directories hardcoded `/home/netrunner`.

### Changes & Fixes
- **`src/power-manager/src/main.rs`**:
  - **Dynamic AC Supply Scanner**: Rewrote `ac_online()` to scan `/sys/class/power_supply/*`, checking for `type == "Mains"` or supply names prefixed with `AC` or `ADP`, returning `true` if any online indicator equals `1`.
  - **Dual-Layer AMD & Intel CPU Thermal Sensing**: Implemented multi-source sensor discovery:
    1. First inspects `/sys/class/hwmon/` for `k10temp` (AMD Ryzen) and `coretemp` (Intel), reading `temp1_input` or `temp2_input`.
    2. Falls back to `/sys/class/thermal/thermal_zone*` for `x86_pkg_temp`, `k10temp`, `Tctl`, and `acpitz`.
  - **Dynamic Hyprland Display Detection**: Added `get_monitor_config(&mut HyprlandConnection)` querying `j/monitors` over the Hyprland IPC socket to detect the primary display name (`eDP-*`), native resolution (`<width>x<height>`), and peak available refresh rate (e.g., 144Hz vs 60Hz).
  - **Scheme Lua File Integrity**: Rewrote `update_scheme_primary` to parse lines cleanly, replace the entire `primary = "#<hex>",` line, and synchronize both `~/.config/Halcyon/scheme/current.lua` and `~/.config/hypr/scheme/current.lua`.
  - **Dynamic Home Resolution**: Added `get_user_home()` reading `/etc/sysmode.conf` (`SYS_HOME`) with fallback to the active user environment instead of hardcoded paths.

---

## 4. Touchpad Toggle Script: Dynamic Device Discovery

### Problem
`scripts/toggle_touchpad.sh` hardcoded `DEVICE="ascf1201:00-2808:0231-touchpad"` (ASUS ROG Zephyrus). On any other laptop (e.g., HP Victus `elan07fb:00-04f3:321a-touchpad`), toggling the touchpad via shortcut or script did nothing.

### Changes & Fixes
- **`scripts/toggle_touchpad.sh`**:
  - Added dynamic touchpad device discovery using `hyprctl devices -j`:
    ```bash
    DEVICE=$(hyprctl devices -j 2>/dev/null | grep -i '"name":' | grep -i 'touchpad' | head -1 | sed -E 's/.*"name": *"([^"]+)".*/\1/')
    [ -n "$DEVICE" ] || DEVICE="elan07fb:00-04f3:321a-touchpad"
    ```

---

## 5. Sysmode Daemons: Log Path Disconnect

### Problem
`recon-deceiver` and `log-analyst` run as root via systemd (`sysmode-daemons.service`) or `sudo sysmode stealth`. They determined the log output directory via `std::env::var("HOME")`, which resolved to `/root/logs/`. However, `hx status` and user UI widgets read logs from `/home/<user>/logs/` based on `/etc/sysmode.conf`. As a result, honeypot attack metrics and IDS alerts never populated in the desktop interface.

### Changes & Fixes
- **`src/recon-deceiver/src/main.rs`**: Added `/etc/sysmode.conf` parsing (`SYS_USER` and `SYS_HOME`) to `sys_user()` and added `sys_home()`. Set `logs_dir` to `format!("{}/logs", sys_home())`.
- **`src/log-analyst/src/main.rs`**: Added `/etc/sysmode.conf` parsing to `sys_user()` and added `sys_home()`. Set log input and alert output paths to `sys_home()`.
- **`src/attacker-dossier/src/main.rs`**: Updated `logs_dir()` to check `/etc/sysmode.conf` for `SYS_HOME` before falling back to `$HOME`.

---

## 6. Rust Helper Daemons: Compiler Warnings & Algorithmic Optimizations

### Changes & Fixes
- **`src/hx/src/util.rs`**: Added `#[allow(dead_code)]` to unused utility functions `epoch()` and `hostname()` to produce clean compiler output.
- **`src/hx/src/status.rs`**: Replaced $O(N)$ linear scans in a `Vec<String>` for unique attacker IP collection with an $O(1)$ `std::collections::HashSet<String>`, significantly speeding up `hx status` execution when `recon-attempts.log` contains large volumes of events.
- **Binaries Recompiled & Deployed**:
  - Built optimized release binaries for `hx`, `power-manager`, `recon-deceiver`, `log-analyst`, and `attacker-dossier`.
  - Installed binaries into both `/home/sushanth/.config/Halcyon/bin/` and `/usr/local/bin/` / `/usr/local/lib/halcyon/sysmode/`.

---

---

## 7. Quickshell Island: RAM Footprint Reduction (750 MB → ~250 MB)

### Problem & Diagnostic
During desktop usage, `/usr/bin/quickshell -p ~/.config/Halcyon/quickshell/island` consumed **700 MB to 750 MB RSS**.

Deep memory mapping inspection via `/proc/<pid>/smaps` and `/proc/<pid>/smaps_rollup` revealed the root causes:
1. **Font TTC Cache Duplication (~196 MB)**: `Pal.qml` prioritized `"Inter"` in `uiFonts`, which matched `/usr/share/fonts/inter/Inter.ttc` (a 13 MB TrueType Collection). Because Qt Quick creates independent font engines and glyph caches per window and render thread, `Inter.ttc` was mmapped 16 times in memory, consuming nearly 200 MB of page cache RSS.
2. **Unnecessary NVIDIA Driver Blob Loading (~60 MB)**: On hybrid graphics laptops (AMD HawkPoint integrated GPU + NVIDIA RTX 3050 Laptop GPU), Quickshell draws the Wayland desktop entirely on the integrated AMD GPU. However, unconstrained Vulkan and EGL ICD enumeration caused `libvulkan` and `libglvnd` to probe the NVIDIA driver, dlopening `/usr/lib/libnvidia-gpucomp.so` (56 MB) and `/usr/lib/libnvidia-eglcore.so` (4 MB).
3. **Jemalloc Arena & Dirty Page Retention (~100+ MB)**: Quickshell is linked against `libjemalloc.so.2`. On a 16-thread CPU, jemalloc defaults to allocating 64 arenas and retains freed heap memory in thread caches and dirty page lists for extended periods.
4. **Persistent Window Buffers**: Heavy overlay windows (`Settings`, `Cheatsheet`, `PowerMenu`, `Overview`, `Lock`) were created in the scene graph at startup, each maintaining its own Wayland layer surface buffers, QSG render contexts, and texture caches even when closed.
5. **Process Forking in Polling Loops**: `stats.sh` forked ~15 subprocesses (`awk`, `cat`, `sed`, `sort`, `tail`, `pgrep`) every 2 seconds, causing continuous CPU wakeups and memory churn.

### Changes & Fixes
- **`quickshell/island/Pal.qml`**:
  - Placed `"Inter Variable"` before `"Inter"` in `uiFonts`. This loads `/usr/share/fonts/inter/InterVariable.ttf` (860 KB) instead of the 13 MB `Inter.ttc` collection, slashing font mapping RSS from 196 MB down to 9.6 MB (**saving ~187 MB**).
- **`scripts/start-shell.sh`**:
  - **Hybrid GPU Isolation**: Set `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json` and `VK_DRIVER_FILES`/`VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json` to keep Quickshell on the integrated AMD GPU, preventing the 60 MB NVIDIA compiler blob from loading (**saving 60 MB**).
  - **Jemalloc Tuning**: Configured `MALLOC_CONF="narenas:2,dirty_decay_ms:0,muzzy_decay_ms:0,background_thread:true"`, restricting jemalloc to 2 arenas and immediately purging freed memory back to the kernel via `madvise(MADV_DONTNEED)` (**saving ~100+ MB**).
  - **Locale Compose Fix**: Added automatic UTF-8 locale fallback for `xkbcommon`, eliminating `No Compose file for locale` warnings.
- **Window Lazy Loading**: Wrapped `Settings.qml`, `Cheatsheet.qml`, `PowerMenu.qml`, `Overview` (in `shell.qml`), and `Lock.qml` in Quickshell native `LazyLoader` components so they are only allocated when opened, releasing GPU buffers when closed.
- **`quickshell/island/scripts/stats.sh`**: Rewrote `/proc/meminfo`, `/proc/net/dev`, thermal sensor, battery, and AC detection to use pure bash built-ins (zero subprocess forks), dropping execution time from 25ms to <1ms.
- **Reduced Polling Frequency**: Increased periodic fallback heartbeat intervals for `gamingProc` and `caffeineProc` in `shell.qml` from 5s to 15s.

### Outcome
Quickshell island RSS dropped from **~750 MB down to ~218 MB - 250 MB** (a **~500 MB / ~70% memory reduction**), with shared clean memory dropping from 365 MB to 105 MB and anonymous heap memory dropping from 300 MB to 82 MB.

---

## 8. Desktop Shell UX & Stability Fixes

### Changes & Fixes
- **Overview (Super+Tab) Live Tree**:
  - Exposed `readonly property var palObj: pal` on root in `shell.qml` and passed `pal: root.palObj` to `Overview`, resolving scope ambiguity inside `LazyLoader` and eliminating recurring `TypeError: Cannot read property 'surface'/'uiFont' of undefined` exceptions.
  - Provided safe default fallback objects for `pal` in `Overview.qml` and `ImagePicker.qml`.
  - Restored the missing `plural(n, w)` helper function in `Overview.qml`.
- **Launcher & Overview Icon Fallback**:
  - Added strict guards for empty icon strings in `Launcher.qml` (`iconFor`) and `Overview.qml` (`iconFor`), preventing `Quickshell.iconPath("", ...)` from querying invalid `?fallback=application-x-executable` icon requests.
- **Desktop Entry Warning**:
  - Removed stray trailing tab on line 9 of `~/.local/share/applications/valve-vrmonitor.desktop`, eliminating repeated `quickshell.desktopentry: Encountered invalid line in desktop entry (no =)` warnings on startup.
- **Settings & Cheatsheet Layout Stability**:
  - Added safety checks in `Settings.qml` and `Cheatsheet.qml` preventing `ReferenceError: card is not defined` and `TypeError: Cannot call method 'push' of undefined` during search filtering and column layout.

---

## Verification & Status Summary

| Component | Previous State | New State | Verification |
|---|---|---|---|
| **Quickshell Island RAM** | 700 MB – 750 MB RSS | **~218 MB – 250 MB RSS** | Verified via `ps`, `smaps_rollup` (~70% reduction) |
| **Quickshell Island CPU** | 40%–63% continuous CPU | **0.0% idle CPU usage** | Verified via `top` / `ps aux` |
| **Font Mappings** | 16x `Inter.ttc` (196 MB) | **`InterVariable.ttf` (9.6 MB)** | Verified via `/proc/<pid>/maps` |
| **GPU Isolation** | 60 MB NVIDIA blob loaded | **Integrated AMD only (0 MB NVIDIA)** | Verified via `/proc/<pid>/maps` |
| **Installer (`install.sh`)** | Step 10 failed (`exit code 127`) | **Clean execution** | Verified `user_systemctl` invocation |
| **Power Manager** | Stuck on `Battery` (AC0 missing) | **`AC BALANCED` active** | Verified in `power-manager.state` & service journal |
| **CPU Temp Sensing** | `None` on AMD Ryzen HawkPoint | **Active reading via `hwmon` / `k10temp`** | Verified temperature reads correctly |
| **Touchpad Toggle** | Hardcoded ASUS ID | **Dynamic detection (`elan07fb`)** | Tested `hyprctl devices -j` parsing |
| **Sysmode Logs** | Split between `/root/logs` and user home | **Unified to `SYS_HOME/logs`** | Verified config resolution in daemons |
| **Overview (Super+Tab)** | Threw TypeErrors on node render | **Zero errors, smooth rendering** | Tested via Quickshell IPC |
| **Launcher / Desktop Entries** | Missing icon & invalid line warnings | **Zero warnings in log** | Verified in `quickshell-island.log` |


---

## Memory pass: one Quickshell instead of two

- **Wallpaper merged into the island** (`quickshell/island/Wallpaper.qml`, `quickshell/wallpaper/` removed): one Qt/QML/GL stack less. IPC target `wallpaper` now lives in the island instance; `keybinds.lua`, `sysmode`, `shell.qml` and `halcyon-doctor.sh` updated, `execs.lua` no longer starts a second shell.
- **Wallpaper decode size**: `sourceSize` = screen width x height (was up to 2.4x screen width), so each decoded wallpaper is ~9 MB instead of ~21 MB at 1920x1200; the reveal holds two at once.
- **Incoming wallpaper released** after the reveal (it used to keep a second decoded copy + GPU texture alive until the next change).
- **Hyprland process**: `MALLOC_ARENA_MAX=2` + `MALLOC_TRIM_THRESHOLD_=131072` in `launch/halcyon.sh` (opt out: `HALCYON_NO_MALLOC_TUNE=1`).
- New `scripts/halcyon-mem.sh` prints RSS and PSS per Halcyon process for before/after comparisons.
- Trade-off: the wallpaper now restarts together with the island (reload / crash), instead of staying up on its own.

## GPU mode (dgpu / igpu)
`~/.config/Halcyon/gpu-mode` (default shipped: `dgpu`) picks the GPU that draws the desktop. `launch/halcyon.sh` sets `AQ_DRM_DEVICES` (NVIDIA first) and the NVIDIA GBM/GLX/VA-API variables, `start-shell.sh` stops forcing Mesa/radeon for the island, and `power-manager` keeps the NVIDIA GPU powered. Switch with `scripts/gpu-mode.sh igpu|dgpu|status`, then log out and in.

## Lean autostart + small closed edge windows
- `scripts/autostart-extras.sh` (settings: `~/.config/Halcyon/autostart.conf`): polkit agent = lightest installed one (hyprpolkitagent, then polkit-gnome, then polkit-kde); `nm-applet` and `blueman-applet` are off by default (island has its own Wi-Fi / Bluetooth lists; the two applets cost ~60-100 MB). Set `NM_APPLET=1` / `BLUEMAN=1` to get them back (blueman is needed to pair NEW Bluetooth devices from a GUI).
- Utilities box (bottom-right) and background-apps box (bottom-left): the layer surface is a 48x48 tab while closed and grows to the full size only while open / fading, so ~450x900 and ~450x700 buffers are not held all day.

---

## Settings: startup choices and Low / Medium / High resource use

- **Settings > Startup & background** (new): switches for nm-applet and blueman-applet (start / stop at once), a polkit agent picker (Auto, Hyprland, GNOME, KDE, None; next login), the desktop graphics card (Integrated / NVIDIA; next login) and a "Show what uses my RAM" button (runs `scripts/halcyon-mem.sh`). Backed by `scripts/startup-conf.sh`, which edits `~/.config/Halcyon/autostart.conf` and `gpu-mode`.
- **Settings > Performance > Resource use** (new): Low / Medium / High presets. They set blur, shadows, window animations, island animation speed, tree/constellation quality and frame rate, constellations, and the notification list sizes in one go. Every option can still be changed afterwards. Startup items and the GPU are not part of the presets.
- `install.sh` / `update.sh` now keep `gpu-mode` and `autostart.conf`, so a reinstall no longer resets your GPU mode or applet choices.

- **Lock-screen login now works with fish** (`./install.sh --lock-login`): it writes `~/.config/fish/conf.d/halcyon-login.fish`. `--remove-lock-login` deletes it again. bash and zsh work as before.

---

## Choose your apps, and theme them

- **`install.sh`**: new menu (and `--browser`, `--files`, `--editor`, `--sysmode`, `--choose` options) for the web browser, file manager(s), code editor(s) and sysmode. The answers are saved in `~/.local/state/island/install-choices.env` and reused by `update.sh`. Thunar is no longer forced on everybody and Yazi is installed only when chosen. Nothing is installed or made the system default without a choice; `--yes` keeps the old behaviour (keep your browser or Firefox, Thunar, sysmode).
- **`scripts/user-setup.sh`**: `default-apps browser= files= editor=` applies what you picked (and replaces an older choice); `save-choices` writes the saved answers.
- **`scripts/apps.sh`**: Yazi gets its desktop file (so it can be the default for folders); a GUI code editor becomes the default for text and source files.
- **`scripts/app-themes-extra.sh`** (new, sourced by `app-themes.sh`): wallpaper-following themes for VSCodium / Code - OSS / VS Code / Cursor, Zed, Firefox-family browsers (Firefox, Zen, LibreWolf, Floorp, Waterfox) and Qt apps (qt6ct + Kvantum). Existing settings files are backed up once (`*.before-halcyon`); only marked blocks of Halcyon are rewritten.

- **Spotify (spicetify)**: `user.css` now has a Halcyon block (floating rounded panels, card hover with accent border, pill buttons, themed menus and scrollbars); your own CSS below it is kept.
- **Vesktop / Discord**: shape rules on top of the colours (rounded sidebar, input box, menus, modals, code blocks, hover and mention highlights, thin scrollbars) and a themed loading splash. Stock Discord cannot be themed: use Vesktop.
- **Thunar and GTK 3 file managers**: flat toolbar, pill-shaped path bar, rounded side-pane rows with an accent marker, card-style icon view, rubber-band selection, status bar and tabs.

---

## Settings sorted into sections, and clearer Thunar icons

- **Settings are now in a fixed, logical order** with four sections: **Appearance** (Look, Colours, Terminal colours, Wallpaper, Transparency / blur / dimming, Motion, Night light, Constellations), **Desktop** (Bar, Clock, Workspaces & windows, Switching workspaces, Notifications, Panels & on-screen display), **Input & power** (Mouse & pointer, Touchpad, Keyboard, Power, Sleep & lock) and **System** (Performance & memory, Startup & background, Default apps, Rice). Big groups were split (clock out of Bar, workspace switching out of Workspaces, terminal colours out of Colours, touchpad / keyboard / mouse apart, sleep & lock apart from the power manager).
- **Section tabs** under the search box (All / Appearance / Desktop / Input & power / System) show one section at a time; searching still looks through everything.
- The two columns now **keep that order** (top to bottom, then the next column) instead of being balanced by height, which used to shuffle the groups. Each group shows its section next to the title.
- **Thunar icons**: new `scripts/thunar-look.sh` and **Settings > Default apps > File manager icons** (Small / Medium / Large) set Thunar's own sizes: side bar, folder tree, list / compact / icon view zoom and toolbar. Medium is applied once automatically; after that only your choice changes it. `gtk-theme.sh` adds roomier side bar and list rows, 22 px toolbar icons and bigger, bolder file names under icons. Papirus (dark / light) is still the icon theme.

