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
| Command (C) | Search bar that opens the launcher, five switches (the four above plus light / dark theme), a "Go to" list (Terminal, Clipboard, Cheat sheet, Security center, Settings), next event and now playing. | untested | `DashCommand.qml`, `DashBtn.qml` |

Wiring: `shell.qml` (option defaults, `RailPages` props and handlers), `RailPages.qml` (style, switch state, Left / Right only in Tabs, Enter opens the launcher in Command), `Settings.qml` (two rows).

Known limits (honest list):
- Command's search bar is a button: it opens the launcher; typing happens there. Up / Down selection in the "Go to" list is not done.
- The mock-ups showed the notch bar; in the code this box belongs to the Rail bar. Offering the same three styles on the notch and the island means reworking the pages `shell.qml` draws (open).
- Bento / Command do not show the Performance page; Performance stays in Tabs.
- The size of the box jumps (no animation) when the style is switched.

## Surface 2: the launcher (app menu)

Two styles, **Settings > Keyboard & launcher > Launcher style** (`opt.launcherStyle`, default `classic`).

| Style | What it is | Status | Files |
|---|---|---|---|
| Classic | The present grid of app icons. | unchanged | `Launcher.qml` |
| Spotlight | One list under the search pill, "Best match" on the first row, Up / Down and Enter, up to six rows. | untested | `Launcher.qml`, `shell.qml`, `Settings.qml` |

Console and background apps: kept as they are (decided; the mock-ups are not built).

## Surface 3: the Settings window

Pages layout (already the default): left menu regrouped under Start / Look and feel / Shell / Tools / System, 11 pages (AI is in Productivity, Backup in System). **untested** on screen. Open: calmer groups inside the long pages, search-first header.

Round 3 on Settings: the Tree layout and the Interface Legacy / Classic choices are removed; a greyed Disabled box (bar off) sits at the bottom of the Bar page; a Debug page holds the doctor, self-test, memory, log and safe mode. **untested** on screen.

Round 4: the Debug page became **Debug / Advanced** and holds every advanced row (one box per original group); the per-group fold and the header chip are gone. **untested** on screen.

Round 5: choice rows with 4+ buttons became drop-downs (36 rows plus the six app pickers); sounds and previews moved to Debug / Advanced. **untested** on screen.

Round 6: one **Builders** page for the Bar / Desktop / Widget / Notification builders; rows they duplicate (bar shape, edge, padding, notification style) moved to Debug / Advanced. **untested** on screen. Open: merging the Desktop and Widget builder windows.

## Next surfaces (open)

| Surface | Idea | Status |
|---|---|---|
| Security center / Game center | Tidier navigation, less text | open |
| Lock screen and notifications | Match the chosen dashboard style | open |

## Checks run

- `node tests/qml-types.test.js`, `settings-groups.test.js`, `settings-drop.test.js`: pass.
- `qmllint` on every touched file: no syntax errors (only "unqualified access" notes, the same pattern the existing tabs use).
- On screen: **not done** (no Quickshell here). Check each style, the Settings switch, the quick switches, and the stat strip opening and closing with the tab.

## Log

- 2026-10-31: Builders page, duplicate rows to Debug / Advanced (round 6). Files: `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Drop-downs for long button rows, app pickers as drop-downs, previews and sounds to Debug / Advanced (round 5). Files: `Settings.qml`, `SetApps.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Debug / Advanced page collects all advanced rows (round 4). Files: `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Settings slimmed: Tree layout and Interface Legacy / Classic removed, Disabled box for bar-only rows, Debug page (round 3). Files: `Settings.qml`, `shell.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Launcher style Classic / Spotlight and the Settings left menu under headings (round 2). Files: `Launcher.qml`, `shell.qml`, `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
- 2026-10-31: Dashboard styles Tabs / Bento / Command added with a Settings picker and the stat-strip switch (round 1). Files: `Dashboard.qml`, `DashStrip.qml`, `DashBento.qml`, `DashCommand.qml`, `DashBtn.qml`, `RailPages.qml`, `shell.qml`, `Settings.qml`, `UIUX-REWORK.md`, `changelog.md`.
