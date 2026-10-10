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
- **Safety check** (default no): a one-command system update, malware / rootkit scan, firewall + audit check and backup (`src/safety-check`). Yes installs clamav, rkhunter, lynis, aide, ufw and rsync plus a root-owned `/usr/local/bin/safety-check`, and **Settings > Backup > Safety check** starts it. No leaves that Settings entry greyed out and disabled. `--safety-check` / `--no-safety-check` skip the question

No questions: `--browser zen --files yazi,thunar --editor codium,zeditor --no-sysmode --no-safety-check` (see `./install.sh --help`). `--yes` uses the saved choice or the default (keep your browser or Firefox, Thunar, no extra editor, sysmode). `./install.sh --choose` asks again. What you pick also becomes the default in Settings > Default apps (and the system default for links, folders and text files).

## Themed apps
Everything follows the wallpaper colours (`scripts/app-themes.sh`, run by the island after every wallpaper change; `app-follow = off` in `~/.local/state/island` stops it):
- terminals, fish, Starship, btop, Yazi, Spotify (spicetify), Discord (Vesktop), Thunar / Nautilus / Nemo / GTK file dialogs
- **VSCodium / Code - OSS / VS Code / Cursor**: a "Halcyon" colour theme (installed once as a tiny extension; after a wallpaper change use *Reload Window*)
- **Zed**: `~/.config/zed/themes/halcyon.json`, reloads live
- **Firefox / Zen / LibreWolf / Floorp**: toolbar, tabs, address bar, new tab page and about: pages (`userChrome.css` + `userContent.css`, the browser must have been started once and needs one restart). Chromium-based browsers cannot be themed from a file: they only get dark mode
- **Dolphin, Kate and other Qt apps**: a qt6ct palette and a Kvantum theme "Halcyon"

## Key features
- Minimal, rounded UI with smooth fast animations
- Quickshell "island" bar (see below) instead of waybar
- Wallpaper changes with a circular reveal from the screen centre (new wallpaper grows over the old one)
- Wallpaper is picked once per boot (stays the same across quickshell reloads); "Random wallpaper" in the drawer / panel changes it on demand
- Special workspaces that overlay the current one: SUPER+S scratch (SUPER+ALT+S sends the focused window there), SUPER+M music, CTRL+SHIFT+ESC system monitor, SUPER+D communication (Discord / Vesktop), SUPER+R tasks (Todoist). Music and communication start their apps from `scripts/special.sh` (see below); `todoCmd` is in `variables.lua`
- Mouse: hold SUPER and drag with the **right** button to move a window, with the **left** button to resize it (`kbMouseMove` / `kbMouseResize` in `variables.lua`, bound in `hyprland/keybinds.lua`; swap the two to get Hyprland's stock layout)
- Gestures: handled by Hyprland (`hyprland/gestures.lua`): 3 fingers right/left = next/previous workspace, 4 fingers left/right = next/previous (flip in Settings > Workspaces > "4-finger swipe"), 3 fingers up or down = toggle the scratch special workspace, 4 fingers down = sleep, 3-finger pinch = workspace tree. The single-finger edge gestures come from the `touchpad-gestures` service: right edge up/down = volume up/down, top edge right/left = brightness up/down, left edge up/down = next/previous track
- Notifications: the island is the notification daemon (`quickshell/island/Notifs.qml`, `NotifCard.qml`, `NotifRow.qml`). **No bell button any more**: touch the **right edge** of the screen (upper part) and the notification centre slides out; leave it and it slides back (hover mode, see **Edge boxes** below). Swipe any notification (popup or in the centre) sideways and let go past half its width to dismiss it; the ✕ still works. Empty state is a tree-style node ("All caught up" / "Do not disturb"). A thin bar on that edge glows (and breathes) while something is unread, and goes grey while do-not-disturb is on. Keyboard: SUPER+SHIFT+N toggles it (closes by itself a few seconds after the pointer is off it), SUPER+SHIFT+D toggles do-not-disturb (also the DND chip in the panel), CTRL+ALT+C clears everything. **Popups** stack top-right, at most `notifMax` (5, top of `shell.qml`); a popup timing out only hides the popup, hover pauses the timer, click dismisses, right-click hides all popups, critical ones stay until dismissed. The centre keeps the latest `notifHistoryMax` (30). Apps in `coalesceApps` (`notify-send` by default) replace the earlier one with the same title, every other app only replaces an exact repeat. Click a row to run its action and remove it, `x` removes only it, `Clear` empties the list. No dunst/mako needed (only one daemon can own the D-Bus name, so stop it if it is running)
- **Quick terminal** (`quickshell/island/QuickTerm.qml`): touch the **top-left corner** (or SUPER+SHIFT+Enter, or `>quick terminal`) for a plain console box with a command line, so one-shot commands do not need a full terminal. While the input is empty and nothing has run it shows the **status of sysmode and the honeypot** as console lines (`>ids hit : 0`, `>alerts : 1 today · 3 total`, honeypot / ids / cowrie / decoy wifi, from `hx status`); the moment you start typing that fades away and your command and its streaming output take over. `sudo ...` and root sysmode actions ask for your password in the input line (masked, fed to `sudo -S`, never stored). If another window opens, the console lets go of the keyboard; click it (or SUPER+SHIFT+Enter) to type again. Enter runs, Up/Down history, Ctrl+C stops, Ctrl+L or `clear` clears, Esc closes, `cd` is remembered. `secure` / `stealth` / `cyber` / `lockdown` (or `sysmode ...`, or `sm ...`) switch sysmode (root actions use the in-console sudo prompt). vim / htop / ssh / less and friends open in a real `foot` window instead
- Performance page: CPU, RAM, TEMP and GPU rings. GPU shows "off" while the dGPU is asleep and never wakes it (`scripts/gpu.sh`, polled only while the page is open). Below the rings, a hardware card: processor (model, cores/threads), graphics (iGPU + dGPU names, read from sysfs + `pci.ids` so a sleeping dGPU is never woken), memory (size, type, speed and channels, e.g. `DDR5 · dual-channel`) and storage (drive model + used/total per mount, `scripts/disk.py`, refreshed while the page is open). RAM type/speed/channels come from `dmidecode`, which needs root: `install.sh` saves its output once to `~/.cache/island/dmi-memory.txt` (re-run it after changing RAM). Without that file you still get the size. Channels are inferred from the slot names, so treat them as a good guess
- Cheatsheet: SUPER+/ (or `>shortcuts` in the launcher, or Settings > Shortcuts) opens a **tree** of every bind, gesture and `sysmode` command (`island/Cheatsheet.qml`, data in `island/Binds.js`). Type to search. **Click a shortcut to change it** (pick modifiers, click the key box, press the key, Enter or Save; Default / Turn off are there too) and use **+ Add a shortcut** under "Your shortcuts" for your own key -> command. Changes go to `~/.local/state/island/binds.json` + `binds.lua`, which `hyprland/keybinds.lua` reads, and Hyprland is reloaded. If you add a bind to `keybinds.lua`, give it an id with `bind(id, keys, action)` and add the same id + default keys to `Binds.js`
- Extras: SUPER+ALT+T layout dwindle/scrolling (saved in `general.lua`), SUPER+ALT+N nightlight (`hyprsunset`), SUPER+PERIOD emoji picker (`bemoji`), SUPER+SHIFT+S frozen area screenshot (`wayfreeze`, `grim`, `slurp`; saved and copied)

## Look & feel (design pass)
Goal: calm, clear, spacious, pleasant. Not stripped-down minimal: depth and texture are intentional.
- **One place to tune Hyprland's look**: the `LOOK` block in `variables.lua` (gaps, corner radius + squircle power, hairline borders, dim, blur, grain, shadow). `general.lua` and `decoration.lua` just read it
- **Depth**: soft wide shadows, frosted glass (blur + fine grain + a little vibrancy) behind the bar, panels, notifications and overlays, neutral 1px hairlines that suit any wallpaper, a faint top sheen on every surface (`island/Glass.qml`, `island/Shadow.qml`)
- **Tokens** live in `island/Pal.qml`: radii (`rSm`..`rXl`), a 4px spacing scale (`s1`..`s6`), a type scale (`tCap`..`tDisplay`), motion (`dFast/dMed/dSlow` + one signature curve). Change them there and everything follows
- **Type**: Inter for all text, the Nerd Font only for icons
- **Colour**: `scripts/palette.py` now makes low-saturation surfaces, a pastel accent and soft-white text (saturation capped), so colourful wallpapers stay gentle. `glass` / `glassBar` / `glassBarOpen` in `Pal.qml` set how see-through the surfaces are (bar 0.58 at rest, 0.74 when expanded, panel/cards 0.80-0.88). If you change them, keep each layer's `ignore_alpha` in `hyprland/rules.lua` below that opacity
- **Motion**: one easeOutQuint curve everywhere, no bounce. Hyprland: windows ease in from 90%, workspaces slide a short way while fading, special workspaces slide vertically. Speeds are in `hyprland/animations.lua` (100ms units; lower by 1 if it feels slow)

## Launch
Halcyon lives in `~/.config/Halcyon`. From a TTY:
```bash
~/.config/Halcyon/launch/halcyon.sh
```
For a throw-away test session (separate runtime dir): `launch/halcyon-isolated.sh`. Or directly:
```bash
HYPRLAND_CONFIG=~/.config/Halcyon Hyprland
```

## Island (quickshell/island)
- Pill bar: workspace numbers (SUPER+N), icons for the special workspaces (scratch / music / performance, lit while open), time/day/date, cava visualizer while music plays, wifi/bt/battery (one round **combined status icon** by default, see below)
- **Combined status icon** (`island/StatusRing.qml`; Settings > Bar style > "Combined status icon", per bar style, on by default): Wi-Fi in the middle (a dot and three arcs, lit by the signal; a plug for a cable), the battery as a ring around it (horseshoe open at the bottom, fills clockwise, red when low, green while charging), and up to three dots under it that close the ring's gap, one per connected Bluetooth device (`btn` in `net.sh`; with Bluetooth = Always, dim dots show it is on). "Show battery percentage" puts the number next to it. Turn the switch off for the three separate icons
- Hold and drag the bar sideways (or scroll / two-finger swipe): drag left = performance page, drag right = media page
- Auto-hide: toggle in the bottom-right panel (Rice > Auto-hide) or `> auto-hide`. When on, the bar slides away and stops reserving space; touch the top edge of the screen to bring it back. With Settings > Edge boxes = **Click** nothing happens on a touch: **click** the top edge to bring the bar back (it hides again once the pointer has left it)
- **SUPER+TAB: live tree overview.** Laptop (hostname, your name + avatar) -> every workspace -> the windows on it, special workspaces (scratch / music / sysmon) included. Nodes drift gently and a pulse runs along each branch. Click a node to jump to it. **Drag a window (leaf) node: its branch is cut, and when it gets close to a workspace a tether reaches out and joins; let go while joined and the window moves there (special workspaces too, or the "+ New workspace" pill). Let go anywhere else and the leaf swings back and its branch regrows**; Esc cancels a drag. Snap distances: `reachR` / `connectR` at the top of the drag block in `Overview.qml` `S` (or the toggle top-right) switches compact / full-size special workspaces, `E` or a click on the laptop node edits your display name and avatar (saved in settings.json), Esc closes Every workspace and window node also shows its live CPU and memory use (`scripts/wsres.py`, polled only while the tree is open), and the header shows the total.
- Tap SUPER: the bar grows into one search bar
  - type to search apps (ranked by usage; clutter like qv4l2 / avahi / Qt tools is hidden, list is `hiddenPatterns` in `island/Launcher.qml`)
  - `.` lists every installed app A-Z (`.fire` filters that list)
  - `>` lists commands: random wallpaper, calculator, settings, power options, power mode, wifi/bt, lock/sleep/log out/restart/shut down
  - `=` is a calculator, e.g. `=2*(3+4)`, Enter copies the result
- Bottom-right corner: hover it for Wi-Fi, Bluetooth, volume, brightness, power mode, rice options and power/session buttons. Wi-Fi, Bluetooth and Sound chips open a drawn list: click a network / paired device / output or input device to switch to it (Wi-Fi asks for a password when needed), right-click a chip for the quick action (radio on/off, mute). Needs `nmcli`, `bluetoothctl`, `pactl`; the lists come from `scripts/wifi.py`, `bt.py`, `audio.py`
- **Focus mode** (utilities box > FOCUS, or SUPER+ALT+F, `scripts/focus.sh`): an advanced do-not-disturb for studying or work. Pick 25 / 50 / 90 minutes (or Pomodoro: work, short break, work ... a long break after the last round) and press *Start focus*. While it runs: Do not disturb is on (urgent notifications and the break reminders still show, everything else waits in the notification centre), Caffeine is on (no dim / lock / sleep), and every window whose class is in the **block list** is closed the moment it opens (and the ones already open when the session starts). It is a normal close request, never a kill, so an app can still ask about unsaved work. The countdown shows in the bar next to the Caffeine icon; the card in the utilities box has Pause (lifts the block), +5 min, Skip / Done and Stop. When it ends, Do not disturb and Caffeine go back to what they were before (ones you switched on yourself stay on). Block list and options: Settings > Focus mode (click an open app to block it, or type its window class; `*` is a wildcard), stored in `~/.config/Halcyon/focus-apps.conf` and `focus.conf`. A tiny background process (`halcyon-focus.service`, a transient user unit) runs only while a session is on and listens to Hyprland's window events; it needs `python3`. CLI: `focus.sh start [min] [pomo]`, `stop`, `pause`, `resume`, `add N`, `skip`, `status`, `block CLASS`, `unblock CLASS`
- Power mode: Auto / Saver / Balanced / Perf. **Auto is the `power-manager` daemon** (`custom/power-manager`, user service `power-manager.service`): battery vs AC, CPU/GPU load, heavy apps, idle, game mode and a thermal guard with hysteresis, plus 144/60 Hz switching. Picking Saver / Balanced / Perf by hand stops the daemon; Auto (or SUPER+ALT+P) starts it again. The performance page always shows the profile that is actually active, and in Auto it adds why (`· auto (on battery)`, `(heavy load)`, `(thermal hold)`, ...)
- Performance page also shows the active **sysmode** (`/etc/sysmode.mode`: secure / stealth / cyber / lockdown, coloured like `sysmode status`). Read-only: change it with the `sysmode` CLI
- `./install.sh` builds `power-manager`, `touchpad-gestures` and `hx` (sources in `src/`), installs them to `~/.config/Halcyon/bin` with their user services, and installs the `sysmode` CLI (`sysmode/`) to `/usr/local/bin` (needs cargo, sudo for sysmode, and the `input` group). Nothing outside this folder is needed any more
- Settings (auto-hide, whether Auto power was on, compact specials, profile) are saved in `~/.local/state/island/settings.json`
- Colours follow the wallpaper (quickshell/island/scripts/palette.py, needs imagemagick)
- Needs Qt >= 6.6 (MultiEffect masks, curve renderer). Text font: first installed of Inter / Noto Sans / ... (`uiFonts` in `island/Pal.qml`; `pacman -S inter-font`)
- Deps: quickshell cava imagemagick networkmanager bluez-utils power-profiles-daemon brightnessctl wireplumber (wpctl) wl-clipboard playerctl-compatible MPRIS player

## No Python in the island and sysmode
Every helper the island and sysmode used to run through `python3` is now written natively in Rust:
- **`hx`** (`~/.config/Halcyon/bin/hx`): `hx audio | bt | wifi | disk | specs | wsres | palette <img>` (island feeds), `hx status` (sysmode + honeypot status for the quick terminal), `hx dossier [ip]` and `hx ids`.
- **`recon-deceiver`** (`~/.config/Halcyon/bin/recon-deceiver`): High-performance multi-port honeypot daemon (replaces `recon-deceiver.py`).
- **`log-analyst`** (`~/.config/Halcyon/bin/log-analyst`): Real-time IDS signature log analyst daemon (replaces `log-analyst.py`).
- **`attacker-dossier`** (`~/.config/Halcyon/bin/attacker-dossier`): Attacker log summarizer and intelligence dossier (replaces `attacker-dossier.py`).
- **`setStaticMac`** (`~/.config/Halcyon/bin/setStaticMac`): Static MAC address manager for iwd and NetworkManager (replaces `setStaticMac.py`).
- **`power-manager`** and **`touchpad-gestures`**: Native Rust desktop background services.
All former `.py` scripts have been replaced by native Rust binaries, with legacy scripts archived to `.bak`.

## Touchpad edge gestures not working?
`journalctl --user -u touchpad-gestures -e` says why. Usual causes: not in the `input` group (`sudo usermod -aG input $USER`, then log in again), an old binary still installed (re-run `./install.sh`; an old build called `qs -c caelestia ... brightness`, which does nothing without caelestia), or `brightnessctl` / `playerctl` / `wpctl` missing. Left edge up/down = next/previous track (SUPER+ALT+G disables it), right edge up/down = volume, top edge right/left = brightness.

## Edge boxes: hover or click
The three edge boxes (notifications on the right edge, console top-left, utilities bottom-right) share one toggle: **Edge: Hover / Click** in Settings, `>edge boxes` in the launcher, or `quickshell ipc ... call island edgemode`.
- **hover**: touch the edge/corner to open, move away to close. Corner and box share one hover zone, so nothing flickers when the box slides in under a resting pointer.
- **click**: click the edge/corner (a faint tab marks it) to open, click it again to close; Esc closes the console too.
- **Auto-hide on**: in both modes every box closes as soon as the pointer leaves it (the console waits while you have text typed or a password prompt open).

## Settings (gear) and power button
The utilities panel is now: wifi / bluetooth / audio chips, sliders for **volume, microphone (click the icon to mute) and brightness**, power mode, and one row with **Settings**, **Gaming** and a round **power button**.
- **Settings** (`SUPER+F11`, `>settings`): a centred window in the tree style: wallpaper, transparency, corner rounding, gaps, blur, shadows, island and window animations, auto-hide, do-not-disturb, edge mode, profile constellation, gaming mode, edit config, cheatsheet, reload Hyprland. Values are remembered in settings.json; the Hyprland ones are pushed with `hyprctl eval` and re-applied at island start (only once you have changed one, otherwise your Lua config rules).
- **Power button** (`>power options`): blurs everything and shows Lock / Sleep / Log out / Restart / Shut down in the middle of the screen (L S O R P keys, Esc cancels, destructive ones ask "Sure?").
- **Gaming mode** (`SUPER+F10`, `scripts/gamemode.sh on|off`): performance power profile (Auto power paused), Hyprland animations / blur / shadows / gaps / rounding off, island animations instant, visualizer off, and the helpers listed in `~/.config/Halcyon/gamemode.conf` stopped (default: cava, baloo, tracker). Off restores the profile, Auto power and reloads Hyprland. Sysmode / honeypot / IDS are never touched.
- The performance page no longer has the wifi / bluetooth chips (they live in the utilities panel).

## Flagship sysmode art
Constellations in the wallpaper accent colour (twinkling stars joined by hairlines, `ModeArt.qml`, layouts in `StarData.js`): `lockdown` is a shield, `stealth` a coiled dragon (original), behind the SUPER+TAB tree, the notification centre, the console, settings and the power menu. In any other mode the tree shows **your profile picture as a constellation** (`hx stars <image>`: stars land on the outline and bright features, each joined to its two nearest neighbours; switch it off in Settings).

## Slider lag
`hx ctl` replaces the 2-second `ctl.sh` poll: brightness is read from sysfs every 60 ms and volume is event-driven (`pactl subscribe`), so the utilities sliders follow touchpad gestures and media keys immediately.

## Lock screen (our own)
`quickshell/island/Lock.qml` is a real Wayland session lock (`ext-session-lock`) with PAM login (`island/pam/password.conf`, your own password): constellation backdrop (shield / dragon for lockdown / stealth, your profile picture otherwise), big clock, your picture and name, one password pill that shakes on a wrong password. Open it with SUPER+L, power menu > Lock, `>lock`, or `scripts/lock.sh` (falls back to hyprlock if the island is not running). For idle locking set hypridle's `lock_cmd = ~/.config/Halcyon/scripts/lock.sh`. If the island ever crashes while locked the screen stays locked by design (`loginctl unlock-session` from a TTY).

## Profile constellation everywhere
In `secure` and `cyber` (any mode that is not lockdown / stealth) the profile picture constellation (`hx stars`) now shows behind the tree, notification centre, console, settings, power menu and lock screen. `shell.qml` makes it once and hands it to every surface. Switch it off in Settings > profile constellation.

## Edge box sizes
The utilities panel and the notification centre share `boxW`, `boxPad`, `boxEdge` in `island/Pal.qml` (width 392, inner padding 18, 22px from the screen edge), so they always line up.

## Input fixes (utilities box, console, constellation)
- **Utilities box**: its panel and its hover zone are siblings, and chips / sliders take hover away from a sibling zone, so hovering a chip used to close the box 450 ms later. The panel now tracks its own hover too (`zoneHover` / `panelHover` in `shell.qml`).
- **Console**: the prompt and the output list swallowed clicks, so nothing asked Wayland for the keyboard. Clicking them now does, and in hover mode resting the pointer on the box for 250 ms is enough to type. Leaving with an empty prompt closes it and hands the keyboard back.
- **Gaming chip**: the island re-reads `/dev/shm/halcyon-gamemode` after each click (and every 5 s), so the chip always matches the script.
- **Constellation**: `scripts/avatar.sh` finds the picture (chosen path, `~/.face`, `~/.face.icon`, AccountsService, `~/.config/Halcyon/avatar.*`). With no picture, or one that gives almost no stars, a sky made from your name is shown instead (`Stars.fromName` in `StarData.js`).

## Caffeine
Keeps the screen awake: no dimming, no hypridle lock, no idle sleep, until you turn it off. **SUPER+ALT+C**, the **Caffeine** chip in the bottom-right panel (right-click = on for one hour), or `>caffeine` in the launcher. A small cup shows in the bar while it is on. It is a `systemd-inhibit` lock held by a transient user unit (`halcyon-caffeine.service`, `scripts/caffeine.sh on [minutes] | off | toggle | status`), so it vanishes on log out and never survives a reboot. hypridle honours it as long as `ignore_systemd_inhibit` is not true in `hypridle.conf`. (A manual `systemctl suspend` and the lid switch are not blocked on purpose.)

## Music and communication workspaces, app routing
- **SUPER+M** / **SUPER+D** run `scripts/special.sh`: if the special workspace has no window it starts the app (music: `spotify`, else `spotify-launcher`, else `ncmpcpp` in foot; communication: `vesktop`, else `discord`), otherwise it just toggles the workspace. Change the apps in `~/.config/Halcyon/special.conf` (`MUSIC_CMD=...`, `COMM_CMD=...`) or at the top of the script.
- **Auto-routing**: when a window of a known app opens (Spotify, Discord, Vesktop, Telegram, Signal, Slack; the list is `quickshell/island/Routes.js`) the island moves it to its special workspace (music / communication) and shows it. It leaves alone what was already open when the island started, a window you move yourself, and the first 45 s of a session (autostarted apps do not pop up over your work; they are still moved). Turn it off with `>app routing`.

## Background apps box (bottom-left corner)
Hover (or click, see Edge boxes) the **bottom-left corner**, press **SUPER+SHIFT+A**, use the **Background apps** chip in the bottom-right panel, or `>background apps`. It lists the apps from `Routes.js` that are running, says whether each still has a window or only lives in the background, and has **Open** (brings its window up in its workspace, starting the app's window if there is none) and **Quit** (`pkill -f` on its process pattern). Apps that are not running appear as **Start** chips. While the box is closed a small count on the corner shows how many are alive. To list another app, copy a line in `Routes.js` (id, name, workspace, window class, a regex for its process, start command).

## Lock screen motion
Every key press pops a dot into the pill (with a small overshoot), sends a ring out of the pill and makes the constellation flare; while PAM checks the password the dots ripple; a wrong password turns them red, shakes the pill and flares the sky; the whole screen eases in when it locks and a slow ripple leaves the profile picture.

## Alive constellations
`ModeArt.qml`: the sky breathes and sways a little, every star flickers on its own rhythm, lights travel along the lines, a shooting star crosses every 8-18 s, and near / far layers drift against each other with the pointer. All of it stops when Gaming mode is on (island motion below 0.3) or the art is hidden.

## Brightness gesture (top edge)
The gesture runs `scripts/brightness.sh`, which tries `brightnessctl`, then a direct sysfs write, then logind, and prints why it failed in `journalctl --user -u touchpad-gestures -e`. The usual cause is not being in the `video` group (the service is outside your login session, so logind cannot vouch for it): `sudo usermod -aG video $USER`, log in again. The top strip is now 10 % of the pad (it was 4 %) and one slide step is 4 % of the pad width. Rebuild with `./install.sh` after pulling this change.

## sysmode stealth: why the honeypot / IDS did not start
Two causes, both fixed in `sysmode/sysmode`: (1) `start_cowrie` returns 1 when Docker is missing or its daemon is stopped, and `set -e` ended the whole stealth switch right there, before the recon-deceiver, the IDS and the MAC logger were launched (the mode file already said `stealth`, but the final "Mode changed to: STEALTH" line never appeared). It is now `start_cowrie || true`. (2) `SYS_USER` / `SYS_HOME` defaulted to a user called `netrunner`, so on any other account the scripts directory did not exist and the fallback hid the error behind `>/dev/null`. The user now comes from `/etc/sysmode.conf`, else sudo's caller, else the login user. The daemons start with `setsid nohup`, their output goes to `~/logs/<name>.out`, and a daemon that dies on start is reported with its last lines. After `./install.sh` run `sudo sysmode stealth` again; `sysmode status` should show the honeypot and IDS as Active.

## Settings added later: default apps, sleep & lock, notification count
- **Default apps** (Settings > Default apps): terminal, browser, file manager. Only installed ones are listed. The choice is saved by `scripts/apps.sh` in `~/.local/state/island/apps.env` and applies at once: SUPER+T / W / E, the console's "open in a real terminal", the system monitor and the music fallback all go through it. A browser or file manager you pick also becomes the xdg default for links and folders. To offer another app, add a line to the tables at the top of `scripts/apps.sh`.
- **Sleep & lock** (Settings > Sleep & lock): lock the screen after 2-30 min idle (or never), sleep after 15 min - 4 h (or never). `scripts/idle.sh` writes its own hypridle config (`~/.local/state/island/hypridle.conf`) and runs hypridle with it, so your own `~/.config/hypr/hypridle.conf` is no longer used. Caffeine still stops both.
- **Notifications** (Settings > Notifications): how many the centre keeps (10-100, default 30).
- **Performance page**: the power-mode chips and the mode line were removed (power mode lives in the bottom-right panel).

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

## Idle dim, keyboard light, volume / brightness bar
- **Dim when idle** (Settings > Sleep & lock, default 3 min): the screen fades to its lowest brightness and the keyboard light goes off; any key or mouse move puts both back exactly as they were. `scripts/idle-dim.sh` (called by hypridle through `scripts/idle.sh`, which now writes a third listener). The saved levels live in `/dev/shm/halcyon-dim`, so a reboot can never leave you in the dark. Caffeine stops it like it stops lock and sleep.
- **Keyboard backlight**: `scripts/kbd-backlight.sh status | up | down | set PCT | toggle | doctor [--load]`, bound to XF86KbdBrightnessUp / Down / LightOnOff. `scripts/backlight.sh` writes screen and keyboard light with three fallbacks (brightnessctl, sysfs, logind). The kernel driver itself (asus-wmi, thinkpad_acpi, dell-laptop, applesmc, system76-acpi, ... or tuxedo-drivers / msi-ec from the AUR) creates the `/sys/class/leds/*kbd_backlight` device; `doctor` tells you which one your laptop needs and `--load` loads it and keeps it across boots. `udev/90-halcyon-backlight.rules` (installed by `install.sh`) lets your user write both without root (groups `video` and `input`).
- **Volume / brightness / keyboard-light bar** (`Osd.qml`): slides up from the bottom edge on every change and goes away by itself, no matter what changed it (keys, touchpad edge gestures, the panel sliders, other apps). Brightness and keyboard light are watched by `scripts/osd-watch.sh`, volume through `pactl subscribe`. It stays quiet while the panel sliders are open and during the idle dim. Settings > Volume & brightness bar turns it off.

## Updating
`~/.config/Halcyon/update.sh` asks GitHub (X-netrunner/Halcyon) for the newest version. **Nothing new = nothing is touched.** If there is something new it is pulled (`git pull --rebase --autostash` when `~/.config/Halcyon` is a git checkout, so your own edits stay; otherwise the latest is cloned and installed over it, keeping `hypr-user.lua`, `scheme/current.lua`, `gamemode.conf`), `install.sh --yes` sets it up, and the island + Hyprland reload. `--check` only reports, `--force` re-runs the setup, `--no-packages` / `--no-sysmode` go to `install.sh`.

## Reload, quick keys
- Settings > **Reload Hyprland** now reloads Hyprland's config (Lua modules are re-read, not served from cache), repaints terminal colours and reloads the island (`quickshell ipc ... call island reload` does the same).
- Launcher: **Up / Down** = earlier / later searches (kept in `~/.local/state/island/launcher-history.log`), **Left / Right** move the text cursor, **Tab / Shift+Tab** (or Ctrl+N / Ctrl+P) pick the next / previous result, **Ctrl+Up / Ctrl+Down** move a row. In the `>` command list Up / Down still move the selection.
- Workspaces slide horizontally in the direction you travel (`hyprland/animations.lua`).
- Profile editor in the tree (E): **Browse** opens a file dialog (zenity, kdialog or yad).

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

- **Install**: verbose by default (`-q` for quiet), `--no-apps` skips thunar / foot / spotify / discord, sysmode is installed and checked (`sysmode doctor`) but no mode is switched on for you. The tty1 lock-screen login is opt-in (`--lock-login`).
- **Why Hyprland used to start with defaults**: `HYPRLAND_CONFIG` has to point to the *file* `hyprland.lua`, not the folder. `launch/halcyon.sh` now fixes that, and the install verifies the config (`Hyprland --verify-config`) before it enables anything.
- **Quickshell** is started by `scripts/start-shell.sh` (waits for Wayland, restarts on crash). Logs: `~/.cache/island/quickshell-island.log`.
- **Diagnostics**: `scripts/halcyon-doctor.sh` (Hyprland config, quickshell, GPU / NVIDIA / Intel, keyboard light, gaming mode).
- **Drivers**: NVIDIA (open / legacy / nouveau by GPU generation, PRIME for hybrids), Intel, AMD, keyboard backlight vendors. Per-machine GPU env goes in `~/.config/Halcyon/gpu.lua`.
- **Notifications** show your profile picture (app icon as a badge): Settings > Panels & notifications > "Notification picture".
- **App themes** (`scripts/app-themes.sh`, installed by `install.sh`, re-run on every wallpaper change; `--now` forces it, `echo off > ~/.local/state/island/app-follow` stops the automatic runs): the same wallpaper colours in
  - **Starship**: `config/starship.toml` becomes `~/.config/starship.toml` (your old one is kept as `.before-halcyon`); the `HALCYON PALETTE` block at its bottom is rewritten, everything above it is yours. The right side of the prompt shows `◈ halcyon` (the rice name, `[custom.halcyon]`) next to the sysmode tag and the other stats.
  - **fish**: `~/.config/fish/conf.d/halcyon.fish` (colours by the terminal's ANSI names, so they follow the wallpaper by themselves; starts Starship unless your `config.fish` already does).
  - **btop** (`color_theme = "halcyon"`), **yazi** (flavor `halcyon`), **foot** and the other terminals (`term-colors.sh`), **Thunar** (`gtk-theme.sh`).
  - **Spotify**: spicetify theme `halcyon` (`spicetify-cli` from the AUR). A theme only shows after `spicetify apply`, which the island does after a wallpaper change while Spotify is closed (`--now` does it right away; a Spotify update needs `--now` once, and the first time Spotify must have been started once).
  - **Discord**: stock Discord cannot be themed, so the installer adds **Vesktop** (AUR) and writes + enables `halcyon.theme.css` there (Vencord too, if you have it). Vesktop is also the default chat app when you have not chosen one. Discord renames its CSS variables now and then: if a part stays unthemed, tell me which.
  Spotify and Discord always use the dark palette.
- **GTK apps (Thunar, file dialogs)**: `scripts/gtk-theme.sh` writes `~/.config/gtk-3.0/gtk.css` and `gtk-4.0/gtk.css` (between `halcyon` markers, the rest of those files is untouched) from the island palette, and re-runs on every wallpaper and dark / light change. Reopen Thunar (`thunar -q`) to see it. `gtk-theme.sh --remove` takes it out; `echo off > ~/.local/state/island/gtk-follow` stops the automatic runs.
- **Invert workspace scrolling**: Settings > Workspaces. Applies to the wheel over the workspace numbers in the bar and the 3 / 4 finger swipes.


## Memory footprint (one Quickshell process)
The wallpaper layer used to be a second Quickshell instance (`quickshell/wallpaper`), i.e. a whole extra Qt + QML + GL stack just to show a picture. It is now `quickshell/island/Wallpaper.qml`, a window inside the island shell, so the autostart starts one Quickshell, not two. `SUPER+SHIFT+W`, `sysmode` and the island itself all reach it through `quickshell ipc -p ~/.config/Halcyon/quickshell/island call wallpaper next` (or `set <path>`). The picture is decoded at the screen size (not 2.4x the width) and the "incoming" copy is released after every reveal. `launch/halcyon.sh` gives Hyprland fewer malloc arenas (`HALCYON_NO_MALLOC_TUNE=1` turns that off). Measure with `scripts/halcyon-mem.sh` (PSS is the number that counts).
