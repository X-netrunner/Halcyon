# Halcyon - Minimal Custom Hyprland Config

Lightweight, minimal, smooth and fast Hyprland setup in Lua, independent of caelestia dots.

## Layout
- `hyprland/`, `variables.lua`, `scheme/`: Hyprland config (Lua)
- `quickshell/`: island bar, wallpaper layer
- `launch/`: start scripts (`halcyon.sh`, `halcyon-isolated.sh`)
- `scripts/`: cheatsheet, emoji picker, area screenshot, and the toggles (layout, nightlight, touchpad, gestures, power manager, live wallpaper)
- `src/`: Rust sources for `power-manager` (Auto power), `touchpad-gestures` and `hx` (island data feeds, sysmode status / IDS / dossier); `systemd/`: their user services
- `sysmode/`: the `sysmode` hardening/decoy-lab CLI plus the honeypot and IDS scripts it launches

## Key features
- Minimal, rounded UI with smooth fast animations
- Quickshell "island" bar (see below) instead of waybar
- Wallpaper changes with a circular reveal from the screen centre (new wallpaper grows over the old one)
- Wallpaper is picked once per boot (stays the same across quickshell reloads); "Random wallpaper" in the drawer / panel changes it on demand
- Special workspaces that overlay the current one: SUPER+S scratch (SUPER+ALT+S sends the focused window there), SUPER+M music, CTRL+SHIFT+ESC system monitor, SUPER+D communication (Discord / Vesktop), SUPER+R tasks (Todoist). Commands are `communicationCmd` / `todoCmd` in `variables.lua`
- Gestures: handled by Hyprland (`hyprland/gestures.lua`): 3/4 fingers right/left = next/previous workspace, 3 fingers up or down = toggle the scratch special workspace, 4 fingers down = sleep, 2-finger pinch = workspace tree. The single-finger edge gestures come from the `touchpad-gestures` service: right edge up/down = volume up/down, top edge right/left = brightness up/down, left edge up/down = next/previous track
- Notifications: the island is the notification daemon (`quickshell/island/Notifs.qml`, `NotifCard.qml`, `NotifRow.qml`). **No bell button any more**: touch the **right edge** of the screen (upper part) and the notification centre slides out; leave it and it slides back (hover mode, see **Edge boxes** below). Swipe any notification (popup or in the centre) sideways and let go past half its width to dismiss it; the ✕ still works. Empty state is a tree-style node ("All caught up" / "Do not disturb"). A thin bar on that edge glows (and breathes) while something is unread, and goes grey while do-not-disturb is on. Keyboard: SUPER+SHIFT+N toggles it (closes by itself a few seconds after the pointer is off it), SUPER+SHIFT+D toggles do-not-disturb (also the DND chip in the panel), CTRL+ALT+C clears everything. **Popups** stack top-right, at most `notifMax` (5, top of `shell.qml`); a popup timing out only hides the popup, hover pauses the timer, click dismisses, right-click hides all popups, critical ones stay until dismissed. The centre keeps the latest `notifHistoryMax` (30). Apps in `coalesceApps` (`notify-send` by default) replace the earlier one with the same title, every other app only replaces an exact repeat. Click a row to run its action and remove it, `x` removes only it, `Clear` empties the list. No dunst/mako needed (only one daemon can own the D-Bus name, so stop it if it is running)
- **Quick terminal** (`quickshell/island/QuickTerm.qml`): touch the **top-left corner** (or SUPER+SHIFT+Enter, or `>quick terminal`) for a plain console box with a command line, so one-shot commands do not need a full terminal. While the input is empty and nothing has run it shows the **status of sysmode and the honeypot** as console lines (`>ids hit : 0`, `>alerts : 1 today · 3 total`, honeypot / ids / cowrie / decoy wifi, from `hx status`); the moment you start typing that fades away and your command and its streaming output take over. `sudo ...` and root sysmode actions ask for your password in the input line (masked, fed to `sudo -S`, never stored). If another window opens, the console lets go of the keyboard; click it (or SUPER+SHIFT+Enter) to type again. Enter runs, Up/Down history, Ctrl+C stops, Ctrl+L or `clear` clears, Esc closes, `cd` is remembered. `secure` / `stealth` / `cyber` / `lockdown` (or `sysmode ...`, or `sm ...`) switch sysmode (root actions use the in-console sudo prompt). vim / htop / ssh / less and friends open in a real `foot` window instead
- Performance page: CPU, RAM, TEMP and GPU rings. GPU shows "off" while the dGPU is asleep and never wakes it (`scripts/gpu.sh`, polled only while the page is open). Below the rings, a hardware card: processor (model, cores/threads), graphics (iGPU + dGPU names, read from sysfs + `pci.ids` so a sleeping dGPU is never woken), memory (size, type, speed and channels, e.g. `DDR5 · dual-channel`) and storage (drive model + used/total per mount, `scripts/disk.py`, refreshed while the page is open). RAM type/speed/channels come from `dmidecode`, which needs root: `install.sh` saves its output once to `~/.cache/island/dmi-memory.txt` (re-run it after changing RAM). Without that file you still get the size. Channels are inferred from the slot names, so treat them as a good guess
- Cheatsheet: SUPER+ALT+/ (or `>keybinds` in the launcher) opens a searchable list of every bind, gesture and `sysmode` command (`scripts/cheatsheet.sh`; edit it when you change a bind)
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
- Pill bar: workspace numbers (SUPER+N), icons for the special workspaces (scratch / music / performance, lit while open), time/day/date, cava visualizer while music plays, wifi/bt/battery
- Hold and drag the bar sideways (or scroll / two-finger swipe): drag left = performance page, drag right = media page
- Auto-hide: toggle in the bottom-right panel (Rice > Auto-hide) or `> auto-hide`. When on, the bar slides away and stops reserving space; touch the top edge of the screen to bring it back
- **SUPER+TAB: live tree overview.** Laptop (hostname, your name + avatar) -> every workspace -> the windows on it, special workspaces (scratch / music / sysmon) included. Nodes drift gently and a pulse runs along each branch. Click a node to jump to it. **Drag a window (leaf) node: its branch is cut, and when it gets close to a workspace a tether reaches out and joins; let go while joined and the window moves there (special workspaces too, or the "+ New workspace" pill). Let go anywhere else and the leaf swings back and its branch regrows**; Esc cancels a drag. Snap distances: `reachR` / `connectR` at the top of the drag block in `Overview.qml` `S` (or the toggle top-right) switches compact / full-size special workspaces, `E` or a click on the laptop node edits your display name and avatar (saved in settings.json), Esc closes Every workspace and window node also shows its live CPU and memory use (`scripts/wsres.py`, polled only while the tree is open), and the header shows the total.
- Tap SUPER (or SUPER+Space): the bar grows into one search bar
  - type to search apps (ranked by usage; clutter like qv4l2 / avahi / Qt tools is hidden, list is `hiddenPatterns` in `island/Launcher.qml`)
  - `.` lists every installed app A-Z (`.fire` filters that list)
  - `>` lists commands: random wallpaper, calculator, settings, power options, power mode, wifi/bt, lock/sleep/log out/restart/shut down
  - `=` is a calculator, e.g. `=2*(3+4)`, Enter copies the result
- Bottom-right corner: hover it for Wi-Fi, Bluetooth, volume, brightness, power mode, rice options and power/session buttons. Wi-Fi, Bluetooth and Sound chips open a drawn list: click a network / paired device / output or input device to switch to it (Wi-Fi asks for a password when needed), right-click a chip for the quick action (radio on/off, mute). Needs `nmcli`, `bluetoothctl`, `pactl`; the lists come from `scripts/wifi.py`, `bt.py`, `audio.py`
- Power mode: Auto / Saver / Balanced / Perf. **Auto is the `power-manager` daemon** (`custom/power-manager`, user service `power-manager.service`): battery vs AC, CPU/GPU load, heavy apps, idle, game mode and a thermal guard with hysteresis, plus 144/60 Hz switching. Picking Saver / Balanced / Perf by hand stops the daemon; Auto (or SUPER+ALT+P) starts it again. The performance page always shows the profile that is actually active, and in Auto it adds why (`· auto (on battery)`, `(heavy load)`, `(thermal hold)`, ...)
- Performance page also shows the active **sysmode** (`/etc/sysmode.mode`: secure / stealth / cyber / lockdown, coloured like `sysmode status`). Read-only: change it with the `sysmode` CLI
- `./install.sh` builds `power-manager`, `touchpad-gestures` and `hx` (sources in `src/`), installs them to `~/.config/Halcyon/bin` with their user services, and installs the `sysmode` CLI (`sysmode/`) to `/usr/local/bin` (needs cargo, sudo for sysmode, and the `input` group). Nothing outside this folder is needed any more
- Settings (auto-hide, whether Auto power was on, compact specials, profile) are saved in `~/.local/state/island/settings.json`
- Colours follow the wallpaper (quickshell/island/scripts/palette.py, needs imagemagick)
- Needs Qt >= 6.6 (MultiEffect masks, curve renderer). Text font: first installed of Inter / Noto Sans / ... (`uiFonts` in `island/Pal.qml`; `pacman -S inter-font`)
- Deps: quickshell cava imagemagick networkmanager bluez-utils power-profiles-daemon brightnessctl wireplumber (wpctl) wl-clipboard playerctl-compatible MPRIS player

## No Python in the island
Every helper the island used to run through `python3` is now a subcommand of the Rust `hx` binary (`~/.config/Halcyon/bin/hx`): `hx audio | bt | wifi | disk | specs | wsres | palette <img>` (island feeds), `hx status` (sysmode + honeypot status for the quick terminal), `hx dossier [ip]` and `hx ids` (replace `attacker-dossier.py` and `log-analyst.py`; `sysmode` prefers `hx` and falls back to the .py files). `install.sh` also copies `hx` to `/usr/local/bin` for `sysmode`. The one Python piece left is the `recon-deceiver.py` honeypot daemon itself.

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
