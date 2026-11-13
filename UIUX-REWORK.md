# UI / UX rework

The running list of the Halcyon UI / UX rework: what was decided, what is done, what is still open.
Update it in every round (newest entry on top of the log, one line per change, name the files).

Legend: **done** = written and checked here, **untested** = no Quickshell here, please look at it on screen, **open** = not started.

## How it works

Every new look is a **style the user picks in Settings**, never a replacement: the present look stays one of the choices.
Options live in `opt.*` (`shell.qml`), rows in `Settings.qml`, the pages in their own small QML files.

## Surface 1: the dashboard (the box that drops from the top middle)

Three styles, picked in **Settings > Bar > Dashboard style** (`opt.dashStyle`, default `tabs`).
The row is listed only while a **Rail** bar is on, because that is the only bar that uses this box (the island and the notch draw their own Media / Performance pages in `shell.qml`).

| Style | What it is | Status | Files |
|---|---|---|---|
| Tabs (A) | The present Media / Calendar / Performance tabs, plus a stat strip under the Calendar page (CPU, RAM, GPU, temperature, what is playing). Strip has its own switch, `opt.dashStrip`, default on. | untested | `Dashboard.qml`, `DashStrip.qml`, `DashBtn.qml` |
| Bento (B) | No tabs. Today's agenda, what is playing with controls, CPU ring and RAM, four quick switches (Wi-Fi, Bluetooth, Do not disturb, Caffeine). | untested | `DashBento.qml`, `DashBtn.qml` |
| Command (C) | Search bar that opens the launcher, nine switches (the four above, light / dark theme, Airplane, Mute, Gaming, Extra dim), a "Go to" list (Terminal, Clipboard, Cheat sheet, Security center, Settings), next event and now playing. | untested | `DashCommand.qml`, `DashBtn.qml` |

Wiring: `shell.qml` (option defaults, `RailPages` props and handlers), `RailPages.qml` (style, switch state, Left / Right only in Tabs, Enter opens the launcher in Command), `Settings.qml` (two rows).

Known limits (honest list):
- Command's search bar is a button: it opens the launcher; typing happens there. Up / Down / Enter in the "Go to" list: written, **untested** on screen.
- The mock-ups showed the notch bar; in the code this box belongs to the Rail bar. Offering the same three styles on the notch and the island means reworking the pages `shell.qml` draws (open).
- Bento / Command do not show the Performance page; Performance stays in Tabs.
- The size of the box now glides when the style is switched (**untested** on screen).

## Surface 2: the launcher (app menu)

Two styles, **Settings > Keyboard & launcher > Launcher style** (`opt.launcherStyle`, default `classic`).

| Style | What it is | Status | Files |
|---|---|---|---|
| Classic | The present grid of app icons. | unchanged | `Launcher.qml` |
| Spotlight | One list under the search pill, "Best match" on the first row, Up / Down and Enter, up to six rows. | untested | `Launcher.qml`, `shell.qml`, `Settings.qml` |

Console and background apps: kept as they are (decided; the mock-ups are not built).

## Surface 3: the Settings window

Pages layout (already the default): left menu regrouped under Start / Look and feel / Shell / Tools / System, 10 pages (see round 7) (AI is in Productivity, Backup in System). **untested** on screen. Open: calmer groups inside the long pages, search-first header.

Round 3 on Settings: the Tree layout and the Interface Legacy / Classic choices are removed; a greyed Disabled box (bar off) sits at the bottom of the Bar page; a Debug page holds the doctor, self-test, memory, log and safe mode. **untested** on screen.

Round 4: the Debug page became **Debug / Advanced** and holds every advanced row (one box per original group); the per-group fold and the header chip are gone. **untested** on screen.

Round 5: choice rows with 4+ buttons became drop-downs (36 rows plus the six app pickers); sounds and previews moved to Debug / Advanced. **untested** on screen.

Round 6: one **Builders** page for the Bar / Desktop / Widget / Notification builders; rows they duplicate (bar shape, edge, padding, notification style) moved to Debug / Advanced. **untested** on screen. Open: merging the Desktop and Widget builder windows.

Round 7: Settings slimmed from 16 pages / 177 default rows to 10 pages / 125 rows: duplicates removed, rows moved behind Debug / Advanced, groups merged (Stars, Splash, Clock, AI, gestures, Timeouts), a Timer preset and an audio drop-down. **untested** on screen. Open: one real "Performance mode" control (Profile and Low preset on battery are only hidden), one Stars master switch, shorter descriptions (many are still 4 to 9 lines).

Round 8 (readability, not a new style): the Tiles utilities box names every control. The four power modes and the four quick actions (caffeine, record, focus, gaming) are icon-over-label tiles with a "Power mode" / "Quick actions" caption instead of eight unexplained glyphs; the charge tile says "Limit 80%" so it cannot be read as the charge level; Power is a quiet chip that turns red only under the pointer. Spotlight launcher: a 3 px selection rail and one line of context under each search result (its generic name, else its comment; the first row says "Best match"). Settings: the two bare "Style" rows are "Bar style" and "Notification style", so "Often used" (where explanations are folded behind the `?`) no longer shows an unexplained "Style: Off". **done**, screenshotted in the live session through a second, throw-away island instance. Split keeps its own block and the classic style is unchanged.

## Round 9: one calm face for the centres, a capture menu, and a recording line (2026-11-04)

The centres were three different shapes (a browser shell, a left menu, a plain column) with text buttons in every corner. This round gives them one quiet grammar and moves the explaining out of the way.

Shared pieces (new): `CalmHeader.qml` (one glyph, the name and one short line, all centred; its right side takes icon buttons and never moves the middle), `CalmNav.qml` (a floating pill of icon-only pages with a small caption for the open one and an optional dot), `CalmIconBtn.qml` (38 px icon button, name in a tooltip, `active` / `primary` / `danger` states). Every centre now uses these; nothing opens a text-only row of buttons.

| Surface | What changed | Status |
|---|---|---|
| Security | Centred shield header with the live posture under it; the six pages are icons in the middle (caption + alert dots); overview is "what needs you" rows (the whole row is the action, a chevron instead of a button) and two module tiles; the lock banner is one sentence with Unlock, Repair, and icon-only Console / Retry / Diagnose, the raw path and os error folded behind Details; page actions (Log, AI review, scans, firewall test / doctor / dashboard, ClamAV, defaults) are icon buttons with tooltips; Alerts / Held back are soft tabs | done, on screen |
| Version | Centred "Version Center" header with one status line; Daily check, Check now, Update all and Close are icon buttons; the window is a little wider and fully opaque; the Halcyon name is 22-28 px instead of a poster, and the loading line is one short line | done, on screen (header / empty state) |
| Study | The left column lost its "Learn from the files" label, rows are 46 px and have no accent outline in the calm style; the title screen is one glyph badge, "Ask your files", one line and three short starters; the status is one line; the composer says "Ask about this file…" | done, on screen |
| Game | Centred gamepad header with refresh / pop out / close icons; Library / Stores / Proton / Doctor are icons in the middle; the add and filter controls are icons; the drawer lost its paragraphs and the spec block is one short line; Advanced stays a disclosure | done, on screen |
| Luna | Centred robot header ("local · N chats · model"); Pop out / Settings / Close are icons; New chat is a round +; session rows are one title line + one quiet age line; the answer actions (tools, reasoning, read aloud, copy, save note) are icon buttons; the composer is softer | done, on screen |

### Super + S: one small capture menu

`CaptureMenu.qml` (mounted in `shell.qml`, bound in `hyprland/keybinds.lua`, listed in `Binds.js` and the launcher as `>capture`): four tiles, Region / Window / Screen / Record. `S` / `W` / `F` / `R` and Escape work; the menu leaves before the capture starts, so it is never in the picture. Region recording is new in `scripts/screen-record.sh`: `region` freezes the screen, takes a slurp rectangle and passes it to wf-recorder (`-g`), wl-screenrec (`--geometry`) or gpu-screen-recorder (`-region`), saves `region_<date>.mp4`, and the same command stops it. The full panel (Super + Ctrl + S) is untouched.

### The recording line

`RecIndicator.qml`: while a recording runs, a 2 px red line breathes around every screen and one pill (red dot, REC, time, stop glyph) sits top-left. The pill is the only part that takes a click (stop); the line lets everything through. The shell now watches `record.pid` / `record.apid` (and looks every 8 s while idle) so a recording started from a terminal, the panel or Super + S shows the line at once.

### Security center: the schema-4 lock

The screenshot's "database schema version 4 is newer than the supported version 3" happens when a newer ai-antivirus upgraded the database and an older engine was installed afterwards: no password can read it. `scripts/antivirus-db-repair.sh` (run from the new **Repair history** button, password asked once in the window) stops the three services, copies the database to `backups/ai-antivirus.db.unreadable-<date>`, moves it aside, lets `ai-antivirus db-init` create a database the installed engine understands, restores ownership to the service user, starts the services again and says where the old history is. If anything fails it puts the old database back. The bare os error is no longer the banner: Details holds it.

## Round 10: the head of the Game Center, the Halcyon card's star, a second capture key, icon-only utilities and the builders (2026-11-04)

| Ask | What changed | Status |
|---|---|---|
| Game Center: the empty band above the search | The search field (and the store filter) moved up into the head, on the left of the centred "Games"; the separate search row is gone. Add + refresh joined the head's icon actions, so the grid starts ~50 px higher. | done, on screen |
| Version Center: the Halcyon star stops the card's animation / the card has no opening animation | The star now sits **above** the card's Flickable (it used to be inside the scrolling content, so a press could start a flick and drop the tilt); the actions pill moved up under the badges, where it is visible, and it now grows with a small scale pop as well as the height / opacity animation the companion cards already had. The star still turns. | done, on screen (shot with the menu held open) |
| Super + Shift + S should open the capture menu | `shotarea` (Super + Shift + S) now calls the same `capture` IPC as Super + S. The cheatsheet (`Binds.js`) and the launcher copy say so; the old instant region drag is still `halcyon screenshot-area` from the command line. | done, config (Hyprland reload needed) |
| Utilities box without the words | New `opt.utilWords` (Settings > Utilities box > Words in the utilities box), plus a small **Aa** button on the "Quick actions" line of the box. Off: every tile keeps only its glyph; Wi-Fi shows its signal stars, Bluetooth its battery stars, the hotspot its devices; the volume / charge figures and the tile names stay in the hover bubbles. Settings and Power also become icons. | done, on screen both states |
| Builders | `WinHeader` gained a small glyph mark and a one-line status; Bar builder (dock icon + "Rail · top edge · 9 widgets", icon reset), Desktop / Lock screen builder (monitor or lock glyph, widget count, icon Widget builder / Place / Reset), Widget builder (widget glyph, count, icon Place, **Content / Place / Look / Styles as icon pages**, Add / Copy / Remove as icons) and Notification box builder (bell glyph, "Grouped · 392 px", icon restore / reset, look chips with icons). | done, on screen |

## Next surfaces (open)

| Surface | Idea | Status |
|---|---|---|
| Lock screen and notifications | Match the chosen dashboard style | open |
| Builders | The four windows now share the head and icon actions; the long right-hand panels can still be grouped further | open |
| Luna / Game / Study | A second look on a real monitor with real data (the layout was checked in previews) | open |

## Checks run

- `node tests/qml-types.test.js`, `settings-groups.test.js`, `settings-drop.test.js`, `notif-settings.test.js`: pass (the notification test was updated for the renamed row).
- `tests/versions.test.js` fails one check ("with nothing chosen the extras are not-chosen") in a clean worktree of HEAD too; it is not from this round.
- `scripts/halcyon-selftest.sh --quick .`: 5 / 5.
- `qmllint` on every touched file: no syntax errors (only "unqualified access" notes, the same pattern the existing tabs use).
- On screen: **done** in the live session through a second, throw-away island instance on a private runtime dir (the installed config was not touched): the utilities box empty and open, the Spotlight launcher with no query and with `ste` typed, and Settings > Discover.
- Round 9 on screen (same throw-away instance): Security overview, Antivirus (locked banner) and Firewall, Study, Version Center (header / empty state), the Super + S menu, and the recording line forced on. Game and Luna passed `qmllint` and were checked in previews after the last edit.
- The earlier rounds' styles (Bento / Command / Spotlight, the builders) still need a look on a real monitor with real windows.

## Log

- 2026-11-12: Motion back to the calmer h5 timing (**untested** on screen): tokens 200 / 400 / 600 ms (close 420), the per-element durations of commit `7e3bd42` undone, music app on its own 120 / 220 / 420 ms scale. Files: `design/tokens.toml`, `scripts/gen-tokens.py`, `Tokens.js`, `tokens.rs`, `Pal.qml`, 25 island files, music `animation.rs` / `art.rs` / `theme.rs` / `main.rs`. See `changelog.md`.

- 2026-11-11 (later): Notes all-notes window and quick panel on the calm grammar (**untested** on screen). All notes: `CalmHeader` (glyph, "Notes", counts) with Organise / Clear completed / New note / Close as icon buttons; search is a pill; the footer chip row is gone (one quiet hint line). Quick panel (Super + N): `CalmHeader` ("Saved" / errors in its line), taller soft text box with Voice and Save as icons inside it, "All notes" as a small link on the Latest row, one short hint line. File: `NotesMenu.qml`.
- 2026-11-11: Notes list rework (**untested**): stable id model so a tick no longer scrolls to the top or closes open rows, instant tick, floating hover action bar, AI row only when open, lighter filter chips, section hairlines, round checkbox, empty state, "New note" button (`NotesMenu.qml`). Moving stars rewritten with depth, halo, glint, shooting star (`BarStars.qml`). Screenshot / recording menus open at the pointer (`CursorSpot.qml`, `ShotMenu.qml`, `CaptureMenu.qml`, `shell.qml`, `Settings.qml`). Widgets can no longer stay stuck as "covered" (`shell.qml`). Parallel builds (`install.sh`).

- 2026-11-04: Round 10: Game Center search in the head; Halcyon card star above the Flickable and a pop for its actions; Super + Shift + S opens the capture menu; utilities words switch (Settings + Aa); builders' headers and icon actions. Files: `GameCenter.qml`, `VersionHero.qml`, `VersionActions.qml`, `hyprland/keybinds.lua`, `Binds.js`, `Launcher.qml`, `shell.qml`, `Panel.qml`, `UTile.qml`, `Settings.qml`, `WinHeader.qml`, `BarBuilderWindow.qml`, `DesktopBuilderWindow.qml`, `WidgetBuilderWindow.qml`, `NotifBuilderWindow.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-11-04: Round 9: CalmHeader / CalmNav / CalmIconBtn and the five centres rebuilt on them; Super + S capture menu with region recording; RecIndicator (red line + REC pill); antivirus schema-4 repair. Files: `CalmHeader.qml`, `CalmNav.qml`, `CalmIconBtn.qml`, `CaptureMenu.qml`, `RecIndicator.qml`, `SecurityCenter.qml`, `VersionCenter.qml`, `VersionHero.qml`, `StudyCenter.qml`, `CenterShell.qml`, `GameCenter.qml`, `LunaCenter.qml`, `shell.qml`, `Launcher.qml`, `Binds.js`, `hyprland/keybinds.lua`, `scripts/screen-record.sh`, `scripts/antivirus-db-repair.sh`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-11-04: Round 8 readability pass: named power-mode / quick-action tiles and their captions in the utilities box, "Limit 80%" on the charge tile, a quiet Power chip with a red hover; Spotlight launcher selection rail and result context lines; "Bar style" / "Notification style" labels. Checked on screen through a second throw-away island instance. Files: `Panel.qml`, `Chip.qml`, `Launcher.qml`, `Settings.qml`, `tests/notif-settings.test.js`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-11-03: Unslop pass over every surface (type weights, sentence case, no overshoot, 10 px controls, copy, 4 px spacing) plus the Antigravity review fixes (drop-down stays open, Study tab hint, cheat sheet width, calendar header, Version Center buttons). Checked in a sandboxed nested Hyprland with screenshots. Files: see `changelog.md`.
- 2026-11-03: Settings left menu: dim headings and pages, the open page and its heading a step brighter, a soft accent pill under the open page. Files: `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-11-03: Settings 16 pages to 10, 177 rows to 125 (round 7). Files: `Settings.qml`, `shell.qml`, `tests/notif-settings.test.js`, `tests/test_ai_master.py`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-11-02: Command dashboard: Airplane, Mute, Gaming and Extra dim switches added. Files: `DashCommand.qml`, `Dashboard.qml`, `RailPages.qml`, `shell.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-11-02: Command dashboard keyboard (Up / Down / Enter) and size glide on style switch. Files: `DashCommand.qml`, `Dashboard.qml`, `RailPages.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Builders page, duplicate rows to Debug / Advanced (round 6). Files: `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Drop-downs for long button rows, app pickers as drop-downs, previews and sounds to Debug / Advanced (round 5). Files: `Settings.qml`, `SetApps.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Debug / Advanced page collects all advanced rows (round 4). Files: `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Settings slimmed: Tree layout and Interface Legacy / Classic removed, Disabled box for bar-only rows, Debug page (round 3). Files: `Settings.qml`, `shell.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Launcher style Classic / Spotlight and the Settings left menu under headings (round 2). Files: `Launcher.qml`, `shell.qml`, `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Dashboard styles Tabs / Bento / Command added with a Settings picker and the stat-strip switch (round 1). Files: `Dashboard.qml`, `DashStrip.qml`, `DashBento.qml`, `DashCommand.qml`, `DashBtn.qml`, `RailPages.qml`, `shell.qml`, `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
