# Halcyon

**A complete, highly customizable Hyprland desktop for Arch, built around one floating "island".** It's your bar, launcher, notifications, music, settings and
game launcher all in one place, with calm, smooth animations. Hyprland is configured in Lua, the island is written in Quickshell, and the
always-on helpers are written in Rust.

![Halcyon out of the box, with the live Halcyon sky wallpaper](docs/screenshots/desktop.webp)

https://github.com/user-attachments/assets/6951fca1-d9d2-4b6d-9731-57c10fa497c4

## What you get

Everything below is how Halcyon looks right after installing, before you change anything.

| | |
|---|---|
| ![Launcher](docs/screenshots/launcher.webp) | **One search bar for everything.** Tap <kbd>Super</kbd> and use the arrow keys straight away, or start typing. Type `>` for commands (`>settings`, `>gaming`, a game's name), `=` for a calculator, `.` to see every app. |
| ![Game Center](docs/screenshots/gamecenter.webp) | **Game Center.** Steam games and your own Windows `.exe` games in one library with cover art. It manages Proton versions, checks your system for problems, and switches on gaming mode while you play. The first start shows a download screen with a progress bar. |
| ![Study Center](docs/screenshots/study.webp) | **Study Center.** Add your PDFs, slides and notes, then ask questions about them or make summaries, quizzes and flashcards, all with a local AI model on your own machine. |
| ![Calendar](docs/screenshots/calendar.webp) | **Calendar and notes.** Your month, your day's notes and reminders, plus birthdays and holidays. |
| ![Settings](docs/screenshots/settings.webp) | **Settings that explain themselves.** Every option is searchable. Most of them have a short explanation, and there is a guided tour that shows you around step by step. |
| ![Overview](docs/screenshots/tree.webp) | **Overview.** <kbd>Super</kbd> + <kbd>Tab</kbd> shows every workspace and window as one constellation: click one to go there, drag a window onto another workspace. Halcyon's own CPU and memory use sit in the corner. |
| ![Shortcuts](docs/screenshots/shortcuts.webp) | **Every shortcut in one place.** <kbd>Super</kbd> + <kbd>/</kbd> opens a searchable map of all the key binds, gestures and commands. |

There's more: clipboard history, screenshots, notifications and music in the island, a lock screen with widgets, live wallpapers,
touchpad gestures, focus mode and backups. [Full feature list](docs/features.md).

## Make it yours

Every part has a builder with a live preview, so you can see a change before you keep it.

| | |
|---|---|
| ![Bar builder](docs/screenshots/builder-bar.webp) | **Bar builder.** Choose what the island shows and in what order, its size and its style. You can also turn the bar off. |
| ![Desktop builder](docs/screenshots/builder-desktop.webp) | **Desktop builder.** The wallpaper (a picture, the live sky or a video), the blur and the moving stars. |
| ![Widget builder](docs/screenshots/builder-widget.webp) | **Widget builder.** Clock, agenda, system stats, now playing, notes and more. Each one has several layouts, and you can save looks of your own. |
| ![Lock screen builder](docs/screenshots/builder-lock.webp) | **Lock screen builder.** The same idea for the lock screen. |
| ![Notification builder](docs/screenshots/builder-notif.webp) | **Notification builder.** How notifications look and where they go. |

Here's the same desktop after some changes: widgets on the desktop, and the bar turned off.

![A customised Halcyon desktop](docs/screenshots/custom-desktop.webp)

| ![Your own widgets in the builder](docs/screenshots/custom-builder-widget.webp) | ![Widgets placed on the desktop](docs/screenshots/custom-builder-desktop.webp) |
|---|---|

## Light on resources

The bar, launcher, notifications, wallpaper (including the live sky), lock screen, widgets and every window you see above run in
**one Quickshell process**. The always-on helpers (system stats, power, gestures) are small Rust programs, and the Python parts only run while
you use them.

Measured on a 16 GB laptop:

| | |
|---|---|
| The island (the whole Quickshell UI), after boot | about **255 MB** |
| The island after a long session with many windows opened | about **400 MB** |
| Its CPU at idle (live sky on, nothing playing) | about **1%** of one core |
| Its CPU with music playing and the live sky animating | about **4%** of one core |
| The whole system after boot | about **1.7 GB** used |

**At the lowest settings** (Resource use: Low, Update speed: Low, constellations and tree view effects off, island animations off,
no live wallpaper or moving stars), the island's idle CPU drops to about **0.5%** of one core. Its memory stays about the same
(250–330 MB), because these settings cut animation and polling, not what gets loaded.

All of these are in Settings > Performance & memory and Settings > Appearance.

## Install

**Requirements:** Hyprland 0.56 or newer (the config is written in
Lua). Arch-based distros (Arch, CachyOS, EndeavourOS, Manjaro...) are the reference: developed and tested on Arch with Hyprland 0.56.2. Other systems (less tested): [Debian testing / sid and Ubuntu 26.10+](docs/install-debian.md), [Fedora 44+](docs/install-fedora.md), and [NixOS through the flake](docs/install-nix.md).

As your normal user:

```bash
curl -fsSLO https://github.com/X-netrunner/Halcyon/releases/latest/download/get.sh && bash get.sh
```

It asks a few short questions (browser, file manager, editor, whether you want the optional extras) and asks for your password only when a
step needs it. If you already have a Halcyon folder, the old copy is backed up to `~/.config/Halcyon-backups` first. Then pick the **Halcyon** session on your login screen. Prefer to read it first? Run `git clone` and `./install.sh --dry-run`.
The dry run shows every step and changes nothing.

**Optional extras you choose at install time:**
- **sysmode**: a security lab with a honeypot, an intrusion detection system (IDS) and hardening. It's off unless you say yes.
- **Safety check**: a one-click system update, malware scan and backup.

Both run as root. [How it works](docs/how-it-works.md#install-one-script) says exactly what is installed and why it can be trusted.

## First steps

| Key | Does |
|---|---|
| <kbd>Super</kbd> | Open the launcher |
| <kbd>Super</kbd> + <kbd>/</kbd> | All shortcuts |
| <kbd>Super</kbd> + <kbd>T</kbd> / <kbd>W</kbd> / <kbd>E</kbd> / <kbd>C</kbd> | Terminal / browser / files / code editor |
| <kbd>Super</kbd> + <kbd>Q</kbd> | Close a window |
| <kbd>Super</kbd> + <kbd>1</kbd>...<kbd>9</kbd> | Go to a workspace |
| <kbd>Super</kbd> + <kbd>L</kbd> | Lock |

New here? Open Settings and press **Start** next to *Guided tour*.

## Updating

```bash
~/.config/Halcyon/update.sh
```

If there is nothing new, nothing is touched. Your own changes are kept. If something goes wrong, `update.sh --rollback` goes back to the
previous version.

## Something not working?

Run `~/.config/Halcyon/scripts/halcyon-doctor.sh` and it tells you what's wrong. Games have their own check in Game Center > Doctor.
Please open an [issue](https://github.com/X-netrunner/Halcyon/issues/new/choose) with what it says. Questions and screenshots of
your setup are welcome in [Discussions](https://github.com/X-netrunner/Halcyon/discussions). Want to help? See [CONTRIBUTING.md](CONTRIBUTING.md).

## Learn more

- **[How Halcyon works](docs/how-it-works.md)**: the folders, the Rust helpers, everything the installer does, security notes and updates
- [Why it's built this way](docs/architecture.md) · [Games](docs/games.md) · [Features and settings](docs/features.md) · [Changelog](changelog.md)

## Who made it

Halcyon is written by Srijan ([netrunner](https://github.com/X-netrunner)). I also used [Claude Code](https://claude.com/claude-code)
to help with optimizations and features along the way.

MIT licensed. See [LICENSE](LICENSE).
