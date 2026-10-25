# Halcyon: notes from past passes

Older "what changed" sections, moved out of the README. The full history is in [changelog.md](../changelog.md); engineering notes on past optimisation passes are in [fixes.md](fixes.md).

## Settings added later: default apps, sleep & lock, notification count
- **Default apps** (Settings > Default apps): terminal, browser, file manager. Only installed ones are listed. The choice is saved by `scripts/apps.sh` in `~/.local/state/island/apps.env` and applies at once: SUPER+T / W / E, the console's "open in a real terminal", the system monitor and the music fallback all go through it. A browser or file manager you pick also becomes the xdg default for links and folders. To offer another app, add a line to the tables at the top of `scripts/apps.sh`.
- **Sleep & lock** (Settings > Sleep & lock): lock the screen after 2-30 min idle (or never), sleep after 15 min - 4 h (or never). `scripts/idle.sh` writes its own hypridle config (`~/.local/state/island/hypridle.conf`) and runs hypridle with it, so your own `~/.config/hypr/hypridle.conf` is no longer used. Caffeine still stops both.
- **Notifications** (Settings > Notifications): how many the centre keeps (10-100, default 30).
- **Performance page**: the power-mode chips and the mode line were removed (power mode lives in the bottom-right panel).

## Added in the third round
- **Constellations grow** (Settings > Constellations): the island counts the minutes it runs (saved in `settings.json`). Dragon: two wings unfold from the shoulders (near wing first). Shield: second rim, hexagon crest, four rays, crown star. Profile picture (or name sky): 4 levels, 70 to about 220 stars, so it looks more like the picture. Full growth = 72 h of use. Drag the bar to preview any stage, "Start over" resets, "Growing: off" shows the plain ones. Data: `StarData.js` (`[x, y, size, birth, startX, startY]`), drawing: `ModeArt.qml`.
- **Compact special workspaces** now also changes the real window size on special workspaces (0.84 of the screen when on, full size when off). Sizes: `specialScaleCompact` / `specialScaleFull` in `variables.lua` (and the same 0.84 in `shell.qml`).
- **Terminal colours follow the wallpaper**: `scripts/term-colors.sh` makes a 16-colour scheme from the island palette, writes the include files and repaints open terminals live; the island runs it on every wallpaper change.
- **RAM details**: boot service `halcyon-ram.service` saves `dmidecode` output to `/var/lib/halcyon/dmi-memory.txt`; `hx specs` reads it (and `~/.cache/island/dmi-memory.txt`). Settings > Tools > Detect RAM details asks for a password once.
- **Settings**: Constellations, Tools (night light, touchpad, gestures, terminal colours, detect RAM), compact special workspaces, app routing, 12/24 hour clock, popups on screen, and no label is cut off any more.
- The performance page shows the active power mode again (read-only).

## Added in the last pass
- **Light / dark theme** (Settings > Look, `>theme`, SUPER+SHIFT+T): `Pal.qml` has a `light` switch; the wallpaper palette is kept as `raw*` values and the light colours are derived from the same hues, so the island, panels, tree, lock screen, console and notifications all flip together. Status colours (`good`/`warn`/`bad`, `modeColor`) are in `Pal.qml` too. Hyprland window/group borders follow (pushed live), and `scripts/theme.sh` sets the GTK/portal `color-scheme` so apps follow.
- **Wallpaper** (Settings > Wallpaper): shows the folder (`~/Pictures/Wallpapers` by default), Open folder, Add wallpapers… (zenity / kdialog / yad picker, else it opens the folder), Change folder…, thumbnails you can click. `scripts/wallpapers.sh`; the choice is remembered for the boot like Random wallpaper.
- **Scroll sensitivity** (Settings): touchpad and mouse-wheel speed (Hyprland `scroll_factor`, pushed live), and how long a swipe on the bar has to be to change page.
- **Edit config** now uses the **Code editor** from Settings > Default apps (falls back to the file manager / `xdg-open`, with a notification if nothing is installed). SUPER+C uses the same choice.
- **More default apps**: code editor, music player (SUPER+M), chat (SUPER+D) next to terminal / browser / files. Missing one? Add a line to `~/.config/Halcyon/apps.custom` (format at the top of `scripts/apps.sh`).
- **Keep workspaces compact** (Settings > Behaviour): on workspace 3 with no windows on 1 or 2, the windows of 3 move to workspace 1. An empty workspace you walked to stays; special workspaces and the tree are ignored.
- **Bar hover** (Settings > Bar): nothing / live stats (CPU, RAM, temp slide out in the bar) / performance page / media page.

## Wallpaper colours, portrait sky, lock-screen login (latest changes)
- **Colours**: `quickshell/island/scripts/palette.sh <image>` (ImageMagick + awk, no Rust needed) takes the wallpaper's own dominant hue and saturation for the accent, and a second hue for `accent2`; grey wallpapers get a neutral accent. The island (bar, panels, notifications, tree, launcher, lock screen) and the terminals all read `~/.cache/island/palette.json`. `hx palette` is only the fallback.
- **Terminals**: `scripts/term-colors.sh` runs on every wallpaper change; blue and magenta are the wallpaper's two accents, the other ANSI colours are pulled 30-40% toward it. foot / kitty / alacritty / ghostty files are rewritten and open terminals are repainted live.
- **Portrait constellation**: `quickshell/island/scripts/portrait.sh <image>` makes a high-detail sky (up to ~900 stars) from the profile picture. Stars sit where the picture has edges and contrast (eyes, brows, hair line, outline), and each carries a birth time, so it grows with use and ends as the picture. Falls back to the old `hx stars` levels, then to a sky made from your name.
- **Lock screen**: every key press sends a ring out of the profile picture, fired by the same `kick()` that flares the constellation; wrong password = bigger red ring.
- **Lock screen as login screen**: with no login manager, `install.sh` can set up auto-login on tty1; `launch/halcyon-login.sh` starts Halcyon already locked (the island locks first thing, `scripts/login-watchdog.sh` makes sure). Undo: `./install.sh --remove-lock-login`; skip one boot: `touch ~/.cache/island/no-autostart`; another console (Ctrl+Alt+F2) stays a normal text login.
- **Avatar picker**: Browse in the tree's profile editor now opens `ImagePicker.qml` inside the island, over the tree, instead of a zenity window on a workspace.
- **Tap Super fix**: the old tap detector could get stuck on "used" and swallow the next tap (and ignored right Super and mouse use). It now resets on every Super press. Debug: `touch ~/.cache/island/super-debug`, tap Super, read `~/.cache/island/super-debug.log`.
- **New settings**: Look > Colour intensity (with a swatch of the current palette), Behaviour > Tap Super to open the launcher, Behaviour > Terminals follow the wallpaper colours.

## Super tap, power manager, gaming mode, bar padding, battery estimate
- **Super tap**: tapping Super opens the launcher. The release bind writes a trigger file the island watches (a few ms) instead of starting a new `quickshell ipc` process every time (that was the lag); IPC stays as a fallback and a 350ms debounce stops double triggers
- **Power manager** (Settings): Halcyon Auto / power-profiles-daemon / TLP / auto-cpufreq / Tuned. Only one runs at a time (`scripts/halcyon-tune pm`), the chosen one is remembered across logins. Install the one you pick first (`pacman -S tlp`, ...)
- **Gaming mode**: now also sets CPU governor + EPP + turbo, platform profile, GPU clocks (AMD/Intel/NVIDIA), swappiness, Wi-Fi power save off, starts `gamemoded`; Caffeine and Do not disturb are switched on and, afterwards, put back to what they were before. The root part is `scripts/halcyon-tune`, installed with a narrow sudoers rule by `install.sh`
- **Bar padding**: Low / Normal / High changes the island's height, distance from the top and side padding
- **Battery estimate**: shown next to the battery percentage and on the performance page, smoothed over a few seconds
- **Workspace switch**: one highlight slides between workspace numbers

## Settings as a tree, colour cycling, workspace navigation (latest pass)

**Settings is now a tree** (same look as the shortcut tree): Halcyon at the root, one branch per area (Look, Colours,
Workspaces, Motion, Bar, Panels & notifications, Mouse / touchpad / keyboard, Tools, Wallpaper, Sleep & lock, Default apps,
Constellations, Rice). Click a branch title to fold it, type in the search box to find any setting, *Collapse all* /
*Expand all* at the top. Switches slide and flash a ring when you click them; buttons light up with a tick for a moment
(`Toggle.qml`, `ActionChip.qml`). The **Tools** switches (night light, touchpad, edge gestures) read the real state from
`scripts/tool-state.sh` every 3 s, so they always show what is actually on, also when you used the key or a terminal.
Sliders for window / input values start at what Hyprland has *right now* (`quickshell/island/scripts/hypr-values.sh`), and
only the values you change are pushed; **Look > Back to the config files** forgets them again.

**Next / previous workspace** (`scripts/ws-nav.sh`, used by the 3 / 4 finger swipes and SUPER+CTRL+Right / Left):
with workspaces 1 and 2, *next* from 2 opens a new workspace 3 (never from an empty one, never above the limit);
*previous* from 1 jumps to the last workspace. Settings > Workspaces can change each of these (open new / go back to 1 /
stay, wrap / stay, highest workspace number).

**Accent colour cycling**: Settings > Colours > *Cycle through the wallpaper*. `palette.sh` now also writes `swatches`
(up to 6 real hues of the picture, strongest first). The accent glides through them on the colour wheel (red, purple,
orange ...), resting a moment on each; *Time per colour* sets the speed. *Terminal colours > Spectrum* gives every ANSI
colour its own wallpaper hue (a red + purple wallpaper gives a red red and a purple magenta, not red everything);
*Open terminals cycle too* repaints cursor / blue / magenta every 5 s along with the accent. Gaming mode pauses the cycle.

**More controls**: accent mode and speed, terminal colour mode, workspace rules, clock seconds / date, popup length,
volume bar length, wallpaper slideshow (every 5 min ... 1 h), night light warmth, border width, unfocused opacity, blur
strength / passes, dimming, natural scroll, tap to click, pointer speed / acceleration, focus follows pointer, key repeat,
tiling layout switch.

## Changes in this version

- **Install**: verbose by default (`-q` for quiet), `--no-apps` skips thunar / foot / discord (the music player is its own question: `--music spotify,spotify-player` or `./install.sh --choose`, several are fine), sysmode is installed and checked (`sysmode doctor`) but no mode is switched on for you. The tty1 lock-screen login is opt-in (`--lock-login`).
- **Why Hyprland used to start with defaults**: `HYPRLAND_CONFIG` has to point to the *file* `hyprland.lua`, not the folder. `launch/halcyon.sh` now fixes that, and the install verifies the config (`Hyprland --verify-config`) before it enables anything.
- **Quickshell** is started by `scripts/start-shell.sh` (waits for Wayland, restarts on crash). Logs: `~/.cache/island/quickshell-island.log`.
- **Diagnostics**: `scripts/halcyon-doctor.sh` (Hyprland config, quickshell, GPU / NVIDIA / Intel, keyboard light, gaming mode).
- **Drivers**: NVIDIA (open / legacy / nouveau by GPU generation, PRIME for hybrids), Intel, AMD, keyboard backlight vendors. Per-machine GPU env goes in `~/.config/Halcyon/gpu.lua`.
- **Notifications** show your profile picture (app icon as a badge): Settings > Panels & notifications > "Notification picture".
- **App themes** (`scripts/app-themes.sh`, installed by `install.sh`, re-run on every wallpaper change; `--now` forces it, `echo off > ~/.local/state/island/app-follow` stops the automatic runs): the same wallpaper colours in
  - **Starship**: `config/starship.toml` becomes `~/.config/starship.toml` (your old one is kept as `.before-halcyon`); the `HALCYON PALETTE` block at its bottom is rewritten, everything above it is yours. The right side of the prompt shows `◈ halcyon` (the rice name, `[custom.halcyon]`) next to the sysmode tag and the other stats.
  - **fish**: `~/.config/fish/conf.d/halcyon.fish` (colours by the terminal's ANSI names, so they follow the wallpaper by themselves; starts Starship unless your `config.fish` already does).
  - **fish greeting** (`config/fish/functions/fish_greeting.fish`): the logo, system info and a shortcut tip in every new terminal. Choose the logo in **Settings > Terminal greeting** (or `scripts/greeting-conf.sh set LOGO <name>`): **Adaptive** (default: the logo of the system you are on, read from `/etc/os-release`; Arch family shows Arch, BlackArch and Kali their own, any other system a Linux penguin, always with its real name on the `distro` line), **Arch**, **BlackArch**, **Kali**, **Linux**, **Custom**, **Info only** (no logo) or **Off**. Custom is your own ASCII art: *Paste from clipboard* in Settings (or `greeting-conf.sh paste` / `import FILE`) saves what you copied, *Edit file* opens `~/.config/Halcyon/greeting-custom.txt`. In art, `@C1@` switches to the accent colour and `@C2@` to grey; colour codes already in the text (from `chafa`, `ascii-image-converter` ...) work too, other escape codes are dropped on paste. Up to 40 rows; the info lines centre themselves next to any size. Logos are plain text files in `config/fish/greeting/logos/`, so adding one is adding a file. The BlackArch logo is a stylised drawing, not the official artwork: put the official one in the Custom file if you prefer it.
  - **btop** (`color_theme = "halcyon"`), **micro** (`"colorscheme": "halcyon"`, no background colour so the terminal's blur / opacity shows through; restart micro to pick up a new wallpaper), **yazi** (flavor `halcyon`), **foot** and the other terminals (`term-colors.sh`), **Thunar** (`gtk-theme.sh`).
  - **Spotify**: spicetify theme `halcyon` (`spicetify-cli` from the AUR). A theme only shows after `spicetify apply`, which the island does after a wallpaper change while Spotify is closed (`--now` does it right away; a Spotify update needs `--now` once, and the first time Spotify must have been started once).
  - **Discord**: stock Discord cannot be themed, so the installer adds **Vesktop** (AUR) and writes + enables `halcyon.theme.css` there (Vencord too, if you have it). Vesktop is also the default chat app when you have not chosen one. Discord renames its CSS variables now and then: if a part stays unthemed, tell me which.
  - **spotify-player** (terminal Spotify): theme `halcyon` in `~/.config/spotify-player/theme.toml` (your own themes in that file are kept) and `theme = "halcyon"` in `app.toml`; it follows the wallpaper and is read each time it starts. First run: `spotify_player authenticate`. Pick it as the music app in Settings > Default apps to open it on SUPER+M.
  Spotify and Discord always use the dark palette.
- **GTK apps (Thunar, file dialogs)**: `scripts/gtk-theme.sh` writes `~/.config/gtk-3.0/gtk.css` and `gtk-4.0/gtk.css` (between `halcyon` markers, the rest of those files is untouched) from the island palette, and re-runs on every wallpaper and dark / light change. Reopen Thunar (`thunar -q`) to see it. `gtk-theme.sh --remove` takes it out; `echo off > ~/.local/state/island/gtk-follow` stops the automatic runs.
- **Invert workspace scrolling**: Settings > Workspaces. Applies to the wheel over the workspace numbers in the bar and the 3 / 4 finger swipes.


