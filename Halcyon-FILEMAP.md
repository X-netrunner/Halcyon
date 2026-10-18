# Halcyon file map

What every file and folder does. This is a separate notes file, it is not part of the rice. ★ = new in this round.

## "I want to change ..." quick index

| I want to change | Open |
|---|---|
| A keyboard shortcut (default keys) | `hyprland/keybinds.lua` (+ `quickshell/island/Binds.js` so the cheatsheet shows it) |
| Gaps, rounding, borders, blur, shadows, default apps, key repeat | `variables.lua` |
| What the Settings window contains / its order | `quickshell/island/Settings.qml` (the `groups` list = items, `pages` list = menu) |
| A new on/off or slider setting the island reads | default in `shell.qml` (`property var opt`), entry in `Settings.qml`, use as `root.opt.<key>` |
| The wallpaper picture, blur, moving stars ★ | `Wallpaper.qml`, `DesktopStars.qml` ★ |
| Which corner a box opens from ★ | `DeskSpots.js` ★ (rules), `shell.qml` (utilities + apps boxes), `QuickTerm.qml` (console) |
| The bar | `Home.qml` (island), `NotchBar.qml` (notch), `CustomBar.qml` + `BarLayout.js` (custom) |
| Colours / spacing / fonts / animation speeds | `Pal.qml` |
| Super-tap launcher speed ★ | `shell.qml` (`launchK`, `pageMs`), Settings > Mouse, touchpad & keyboard |
| Notification look | `Notifs.qml`, `NotifSurface.qml`, `NotifLayout.js` |
| What the console / sysmode can do | `sysmode/sysmode`, `quickshell/island/QuickTerm.qml` |
| What install.sh sets up | `install.sh` (update.sh re-runs it) |

---

## Top level (`Halcyon/`)

| File | What it does |
|---|---|
| `hyprland.lua` | The entry point Hyprland loads. Sets the Lua search path and `require`s every file in `hyprland/`, then `hypr-user.lua`. |
| `variables.lua` | One place for the look and behaviour numbers: default apps, gaps, rounding, borders, blur, shadows, touchpad and key repeat. Read by `hyprland/*.lua`. |
| `hypr-user.lua` | Empty on purpose. Your own binds and rules go here so updates never overwrite them. |
| `scheme/default.lua` | The fallback colour scheme (used before a wallpaper palette exists). |
| `install.sh` | The one installer: packages, Rust builds, sysmode, safety check, fish, login without a display manager, resource level. |
| `update.sh` | Checks GitHub for a newer version and, only if there is one, pulls it and re-runs `install.sh` with the same answers. |
| `README.md` | Overview, install options, features, troubleshooting. |
| `changelog.md` | What changed, newest on top. |
| `fixes.md`, `Fixes.md` | The same engineering report twice (one is a duplicate; keep either). |
| `birthdays.txt`, `holidays.txt` | Lists the calendar reads for birthdays and holidays. |
| `LICENSE`, `.gitignore` | Licence; what git should ignore (builds, `bin/*`, `target/`). |
| `bin/` | Where `install.sh` puts the compiled Rust programs (`hx`, `power-manager`, ...). Empty in the source (`.gitkeep`). |

## `hyprland/` (Hyprland config in Lua, each file does one job)

| File | What it does |
|---|---|
| `keybinds.lua` | Every shortcut, including the Super-tap launcher bind (on key release) and your custom shortcuts from the cheatsheet. |
| `general.lua` | Gaps, borders, layout, resize behaviour. |
| `decoration.lua` | Rounding, blur, shadows, dimming of inactive windows. |
| `animations.lua` | Window / workspace animation curves and speeds. |
| `input.lua` | Keyboard layout, repeat rate, pointer, touchpad basics. |
| `inputconf.lua` | Reads what Settings > Touchpad gestures / Mouse buttons saved. |
| `gestures.lua` | Multi-finger touchpad gestures (3 and 4 finger swipes, pinch). |
| `mouse.lua` | Mouse button actions (back / forward / middle, move-resize while held). |
| `rules.lua` | Window rules, layer rules (which island surfaces get frosted blur), special-workspace launch rules. |
| `group.lua` | Window grouping (tabbed groups) behaviour. |
| `misc.lua` | Hyprland misc options (no logo, font, VFR ...). |
| `env.lua` | Environment variables (EDITOR, BROWSER, Wayland / NVIDIA / Qt toggles). |
| `execs.lua` | What starts with the desktop: the island, helpers, polkit, idle, services. |

## `quickshell/island/` (the island: bar, boxes, settings, lock screen, wallpaper)

### The core
| File | What it does |
|---|---|
| `shell.qml` | The root. Owns settings state (`opt`, `settings.json`), the bar window, the utilities box (bottom-right by default), the background-apps box, the wallpaper layer, IPC commands, the Super-tap watcher. The biggest file. |
| `Pal.qml` | Colours from the wallpaper plus every shared size, font and animation duration. |
| `Settings.qml` | The Settings window (tree and pages layouts) and the builder / gallery / startup windows it opens. |
| `Launcher.qml` | The launcher: app search, `.` all apps, `>` commands, `=` calculator. |
| `Routes.js` | Apps the island knows (Spotify, Discord): which special workspace they go to. |
| `Binds.js` | List of every shortcut for the cheatsheet; turns your changes into `binds.lua`. |
| `Tour.qml`, `Tour.js`, `features.json` | The guided tour and "what's new" tour. Edit `features.json` to announce a feature. |
| `scripts/` | Small helpers only the island calls (see below). |
| `pam/password.conf` | PAM service the lock screen checks your password with. |
| `branch.frag` | GPU shader for the tree-view branches (compiled to `.qsb` on first run). |
| `cava.conf`, `cava-light.conf` | Music visualizer settings (full and half frame rate). |

### Desktop widgets (new)
| File | What it does |
|---|---|
| `WidgetData.js` | The list of widget kinds, their layouts and options, the looks, and the rules for editing the layout (`opt.deskWidgets`, `opt.deskStyles`). |
| `DeskWidgets.qml`, `WidgetHost.qml` | Draw all widgets / one widget's frame (box, colours, place, drag handles while editing). |
| `WBase.qml`, `WLbl.qml`, `WIco.qml` | What every widget body shares: colours, fonts, options, a text and an icon. |
| `WClock.qml` (clock, date), `WMonth.qml`, `WMetric.qml` (cpu, ram, temp, gpu, disk, battery, volume, brightness), `WSysmon.qml`, `WNet.qml` (network, uptime), `WMusic.qml`, `WViz.qml`, `WFocus.qml`, `WWorkspaces.qml`, `WToggles.qml` (toggles, shortcuts), `WNotes.qml`, `WWeather.qml`, `WText.qml`, `WConsole.qml` (console), `WBoxes.qml` (utilities box, background apps box; parts `WbLevel.qml`, `WbRow.qml`) | The widget bodies. |
| `WidgetBuilder.qml`, `WidgetBuilderWindow.qml`, `WbText.qml` | The Settings entry, the builder window (one widget at a time) and its text field. |
| `DesktopEditor.qml` | Place the widgets right on the screen; its view bar switches the grid, centre, thirds, safe area and measuring. |
| `DeskGuides.qml`, `DgTag.qml`, `DgGap.qml` | What the editor draws to line things up: grid, centre lines, thirds, safe area, the gaps in px and the size of the picked widget. |
| `cava-desk.conf`, `cava-desk-light.conf` | The visualizer widget's own 48-bar cava. |

### Wallpaper, stars, corner boxes (this round)
| File | What it does |
|---|---|
| `Wallpaper.qml` | The wallpaper layer: circle-reveal change, ★ on / off, ★ blur, ★ plain background, ★ hosts the stars. |
| `DesktopStars.qml` ★ | The moving stars over the desktop (amount, speed, size, direction, colour, shooting star). |
| `DesktopBuilder.qml` ★ | The Settings entry (summary + "Open the desktop builder"). |
| `DesktopBuilderWindow.qml` ★ | The builder window: live screen picture, wallpaper / stars controls, corner picker. |
| `ChipRow.qml` | A label plus a row of option chips that wraps when it does not fit (used by the desktop builder). |
| `DeskSpots.js` ★ | Rules for which corner each box uses (one box per corner, swap on conflict). |
| `Backdrop.qml`, `ModeArt.qml`, `StarData.js` | The constellation art behind boxes (shield, dragon, your profile picture). |
| `BarStars.qml` | The few small stars on the bar. |

### The bar
| File | What it does |
|---|---|
| `Home.qml` | The island bar's content (workspaces, clock, status). |
| `NotchBar.qml`, `NotchShape.qml` | The notch bar style and its shape. |
| `CustomBar.qml`, `BarLayout.js` | The custom bar and the rules / data of its widgets. |
| `BarBuilder.qml`, `BarBuilderWindow.qml` | Settings entry and drag-and-drop builder window. |
| `BbChip.qml`, `BbEmptyZone.qml`, `BbMock.qml`, `BbNumBox.qml`, `BbPlaced.qml` | Parts of the bar builder window. |
| `StatusRing.qml`, `WifiIcon.qml`, `Visualizer.qml` | Combined status icon, Wi-Fi icon looks, music bars. |
| `NotesMenu.qml` | SUPER + N: the new-note panel on the side (type, Enter saves); `>all notes`: the full list. Data: `scripts/halcyon-notes.py`. |
| `ClipMenu.qml` | `>clipboard`: the clipboard history panel (search, click / Enter copies back, delete, clear). Data: `scripts/halcyon-clip.py` over cliphist; no watcher of its own. |
| `ShotMenu.qml` | Super + Ctrl + S, `>screenshot`: Region / Window / Full screen, then Copy / Save / Both. Engine: `scripts/halcyon-shot.py`. |
| `MusicMenu.qml` | Lyrics / Queue chips on the music page, `>lyrics`, `>queue`: the lyrics and queue panel. Data: `scripts/halcyon-music.py` over the `spotify_player` command line; no process of its own, read-only. |
| `MediaPage.qml`, `PerfPage.qml`, `CalPage.qml` | Pages that grow out of the bar: media, performance, calendar. |
| `DropHeader.qml`, `DropArrow.qml`, `NotifCentre.qml` | The "drag the bar down" drop-down mode. |

### Corner boxes and overlays
| File | What it does |
|---|---|
| `Panel.qml` | The utilities box (Wi-Fi, Bluetooth, audio, volume, brightness, power). |
| `BgApps.qml` | The background apps box (tray apps with open / quit). |
| `QuickTerm.qml` | The pop-out console (sysmode commands, one-shot commands). |
| `EdgeGrab.qml` | Hover / click trigger strip for an edge box. |
| `Notifs.qml` | Notification daemon, popups, right-edge notification centre. |
| `Overview.qml` | SUPER+TAB workspace / window tree. |
| `Cheatsheet.qml`, `CmdTree.qml` | SUPER+/ shortcut tree; SUPER+ALT+/ console command tree. |
| `Calendar.qml`, `CalMarks.qml`, `CalStep.qml` | The calendar and its small parts. |
| `PowerMenu.qml`, `DisplayPicker.qml`, `Osd.qml` | Power menu, projector manager, volume / brightness pop-up. |
| `Lock.qml` | Halcyon's own lock screen (real session lock). Optional blurred wallpaper (Settings > Power & lock): drawn only once loaded, plain colour otherwise. |
| `StartupWindow.qml`, `WallpaperGallery.qml`, `ImagePicker.qml`, `AppPicker.qml` | Startup & processes window, wallpaper gallery, image and app pickers. |
| `TrayMenu.qml`, `DeviceMenu.qml` | Tray app menus; Wi-Fi / Bluetooth / audio device lists. |

### Notification box parts
`NotifBuilder.qml` + `NotifBuilderWindow.qml` (builder), `NotifLayout.js` (layout rules), `NotifSurface.qml` (the box), `NotifBox.qml` + `NotifBlock.qml` (its parts), `NotifList.qml`, `NotifRow.qml`, `NotifLine.qml`, `NotifGroup.qml` (the three list looks), `NotifCard.qml` (popup toast), `NotifIcon.qml` (picture).

### Small shared building blocks
`Glass.qml` (frosted surface), `Shadow.qml`, `HaloShadow.qml`, `Chip.qml`, `ActionChip.qml`, `Toggle.qml`, `Slider.qml`, `SegSwitch.qml`, `NbSlider.qml`, `NbCap.qml`, `ActionPick.qml`, `RoundBtn.qml`, `RoundIcon.qml`, `Ring.qml`, `DayTimeline.qml` (last time / today / due day: Backup, Safety check; plain mode, no due date: last wallpaper change, last system update, Focus streak), `NoteStars.qml` (falling stars in the notes), `SpecItem.qml`, `SwatchDots.qml`, `HelpTip.qml`, `HalRow.qml`.

### `quickshell/island/scripts/` (helpers for the island)
| File | What it does |
|---|---|
| `wallpaper.sh` | Prints the wallpaper to show (one pick per boot, `next`, `set`); saves `wallpaper-changed` (epoch) when the picture really changes. |
| `palette.sh` | Wallpaper to colour palette (`~/.cache/island/palette.json`). |
| `portrait.sh` | Profile picture to a constellation (slow awk fallback of `hx portrait`). |
| `stats.sh`, `net.sh`, `gpu.sh` | CPU / memory / battery, network state, GPU load feeds (the Rust `hx` replaces most of these). |
| `audio-set.sh`, `bt-set.sh`, `wifi-connect.sh` | Pick audio device, connect Bluetooth, connect Wi-Fi. |
| `hypr-values.sh` | Current Hyprland values for Settings sliders. |
| `identity.sh`, `pick-image.sh`, `build-shader.sh` | User / host info, file chooser, compile the shader. |
| `gcal.py` | Google Calendar through its private iCal address; reminders. |

## `scripts/` (the rice's own tools, run by keybinds, the island, or by you)

| Group | Files |
|---|---|
| Launch / session | `start-shell.sh` (keeps the island running), `super_tap.sh` (Super tap trigger), `close.sh` (SUPER+Q), `reload.sh`, `lock.sh`, `login-status.sh`, `login-watchdog.sh`, `idle.sh`, `idle-dim.sh` |
| Look / themes | `theme.sh`, `gtk-theme.sh`, `app-themes.sh`, `app-themes-extra.sh`, `term-colors.sh`, `thunar-look.sh`, `greeting-conf.sh`, `avatar.sh` |
| Wallpaper | `wallpapers.sh` (folder + list), `toggle_livewallpaper.sh` |
| Apps / workspaces | `apps.sh` (default apps), `special.sh` (scratch / music / chat workspaces), `ws-nav.sh`, `toggle_layout.sh`, `audio-focus.sh` (one thing plays at a time), `autostart-extras.sh`, `startup-conf.sh`, `startup-view.py` |
| Timelines | `timeline.py conf` (JSON for Settings) / `status` (text): last wallpaper change, last system update (`/var/log/pacman.log`), Focus streak. Read-only; Settings runs it only while open. |
| Safe mode, Profiles | `halcyon-fx.py`: `halcyon safe-mode [back]` and `halcyon profile <name>`; edits `~/.local/state/island/settings.json`, keeps `safe-mode.json` / `profile.json` / optional `profiles.json` beside it. Run from the Settings buttons, Super + Alt + F12, fish, or the `halcyon` shim in `~/.local/bin`. |
| Modes | `gamemode.sh`, `caffeine.sh`, `focus.sh` + `focus.py`, `toggle_nightlight.sh`, `toggle_power.sh`, `power_manager_select.sh`, `gpu-mode.sh`, `halcyon-tune` (root helper) |
| Input / hardware | `input-conf.sh` (gestures + mouse buttons), `toggle_touchpad.sh`, `toggle_gestures.sh`, `numlock.sh`, `brightness.sh`, `backlight.sh`, `kbd-backlight.sh`, `asus-kbd-fix.sh`, `osd-watch.sh`, `refresh-ram.sh` |
| Network / devices | `hotspot.sh`, `toggle_wifi_powersave.sh`, `display-manager.sh`, `printer.sh`, `notif-guard.sh` |
| Backup / safety | `backup-device.sh`, `restore-device.sh`, `remind.sh`, `safety-auto.sh` |
| Diagnostics | `halcyon-doctor.sh` (why does it not work), `halcyon-mem.sh`, `halcyon-mem-where.sh`, `adaptive-advisor.py`, `halcyon-agent.py` (the tools + safety gates that let the local model act, used by `ai` and `advisor "..."`), `halcyon-chat.py`, `tool-state.sh` |
| Clipboard, screenshots | `halcyon-clip.py` (list / copy / delete / clear over cliphist), `clip-store.sh` (what the two `wl-paste --watch` watchers run: `cliphist store` minus password-manager copies), `halcyon-shot.py` (region / window / full, copy / save / both; `screenshot-area.sh` stays for Super + Shift + S) |
| Music panel | `halcyon-music.py` (`lyrics` / `queue` as one line of JSON for the panel or plain text for a terminal, `status`; asks `spotify_player lyrics` and `spotify_player get key queue`, never stores anything) |
| Misc | `emoji.sh`, `screenshot-area.sh`, `cheatsheet.sh`, `user-setup.sh` |

## `src/` (Rust programs, built by `install.sh` into `bin/`)

| Crate | What it does |
|---|---|
| `hx` | The multitool: island data feeds (audio, Bluetooth, Wi-Fi, stats, per-window RAM / CPU), wallpaper palette, profile-picture constellation, focus mode, sysmode status, IDS, attacker dossier. One file per job in `src/hx/src/`. |
| `power-manager` | The Auto power manager (switches profiles by battery / load). |
| `touchpad-gestures` | Live 1:1 gesture tracker and touchpad edge gestures (volume, brightness, track). `classify.rs` decides pinch vs swipe (pure, unit-tested). |
| `hal` | Rust ports of `input-conf.sh`, `ws-nav.sh`, `brightness.sh`, `backlight.sh` (`hal input / wsnav / brightness / backlight`). No dependencies. The scripts call it when built and keep their shell code as the fallback. |
| `birthday-sync` | Google Birthdays calendar to `birthdays.txt`. |
| `safety-check` | One-command update, malware / rootkit scan, firewall and audit check, backup. |
| `recon-deceiver` | Multi-port honeypot daemon (sysmode). |
| `log-analyst` | Real-time IDS that reads the honeypot log. |
| `attacker-dossier` | Summarises attackers from the logs. |
| `setStaticMac` | Static MAC address manager for iwd and NetworkManager. |

## `config/` (copied into `~/.config` by install.sh)

| File | What it does |
|---|---|
| `starship.toml` | The prompt; its bottom block is recoloured from the wallpaper. |
| `fish/halcyon.fish`, `fish/hints.fish` | fish colours + prompt; one-time hints for classic commands. |
| `fish/functions/fish_greeting.fish`, `fish/greeting/logos/*.txt` | The terminal greeting and the logos (arch, blackarch, kali, linux). |
| `fish/functions/halcyon.fish`, `fish/completions/halcyon.fish` | The `halcyon` command and its completions. |
| `fish/functions/hotspot-on.fish`, `hotspot-off.fish` | Start / stop the lab hotspot. |
| `fish/functions/bar-builder.fish`, `notification-builder.fish`, `wallpaper-gallery.fish`, `startup-view.fish`, `advisor.fish` | Open the matching island window or tool from a terminal. |

## `sysmode/`, `systemd/`, `udev/`, `launch/`

| File | What it does |
|---|---|
| `sysmode/sysmode` | The CLI that switches hardening profiles (secure / relaxed / lockdown / stealth) and runs the honeypot lab. Installed to `/usr/local/bin/sysmode`. |
| `sysmode/sysmode.8`, `sysmode.bash-completion`, `sysmode-daemons.service` | Its man page, completion and daemon unit. |
| `systemd/power-manager.service`, `touchpad-gestures.service` | User services for the two Rust daemons. |
| `systemd/halcyon-ram.service` | Saves RAM type / speed (needs root) for the performance page. |
| `systemd/halcyon-remind.service` + `.timer` | Backup / safety-check reminders. |
| `systemd/halcyon-asus-kbd.service` | Clears the ASUS keyboard-backlight lock flag. |
| `udev/90-halcyon-backlight.rules` | Lets your user change screen and keyboard backlight without root. |
| `launch/halcyon.sh` | Starts Hyprland with the Halcyon config (tty, session, `start-halcyon`). |
| `launch/halcyon-login.sh` | Starts Halcyon from tty1 with the lock screen already on (login without a display manager). |
| `launch/halcyon-isolated.sh` | Test run in a throw-away runtime dir. |
