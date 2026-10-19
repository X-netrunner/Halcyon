# Halcyon — Engineering Fixes & Optimization Report (`fixes.md`)

This document details every fix and optimization applied in-place across the **Halcyon** desktop environment, organized by the three core areas requested:
1. **Frictionless Google Calendar & Google Contacts Birthdays Integration**
2. **High-Degree Memory & CPU Optimization (Quickshell 504 MB Creep & Hyprland 204 MB Footprint)**
3. **Smooth 1:1 Finger-Following 3-Finger & 4-Finger Touchpad Gestures**

For every change, you will find **What** was fixed, **Why** the issue existed, **How** it was engineered, and **Where** (exact file paths, functions, and line ranges).

---

## Summary Table of Modified Files

| Area | File Path | What Changed |
| :--- | :--- | :--- |
| **1. Calendar & Birthdays** | `quickshell/island/scripts/gcal.py` | Added multi-format Google Contacts importer (`.csv`, `.vcf`, `.ics`, `.zip`), zero-click `~/Downloads` `auto-grab` for Calendar exports & Contacts exports, `list-birthdays` / `remove-birthday` CRUD, and fixed `(0th)` birthday age bug on `.ics` imports. |
| **1. Calendar & Birthdays** | `src/birthday-sync/src/main.rs` | Added Google People API (`contacts.readonly`) sync (`fetch_people_contacts`) alongside Google Calendar (`calendar.readonly`), added `--json` output support to `cmd_auth` for `Calendar.qml`, and preserved contact birth years (`YYYY`). |
| **1. Calendar & Birthdays** | `quickshell/island/Calendar.qml` | Added dedicated **🎂 Birthdays** modal in the header, 2-click **Google Contacts Auto-Import** & **1-Click Google Calendar Export** workflows with live `~/Downloads` + clipboard watching, inline Quick Add / Remove Birthday UI, and removed misleading "Public address" instructions. |
| **1. Calendar & Birthdays** | `quickshell/island/CalPage.qml` | Added a **🎂 Birthdays** quick-launch button in the bar drop-down calendar footer that opens the full Calendar directly into the Birthdays manager. |
| **2. Memory & CPU** | `quickshell/island/shell.qml` | Dynamically shrank `win` (`island`), `corner` (`island-panel`), and `appsWin` (`island-apps`) Wayland layer surfaces when idle/closed (~87% surface reduction), gated `cava` process when bar is hidden/switched, and wired `gc()` after overlay teardown. |
| **2. Memory & CPU** | `quickshell/island/Wallpaper.qml` | Set `cache: false` on `cur` and `inc` wallpaper `Image` nodes and added `gc()` in `releaseIncoming()` so old full-screen textures are freed instead of accumulating in `QQuickPixmapCache`. |
| **2. Memory & CPU** | `quickshell/island/WallpaperGallery.qml` | Set `cache: false` on all gallery preview `Image`s, gated `carousel` `Repeater` model on `gal.viewMode === "carousel"`, and restricted carousel image decoding to visible neighbors (`Math.abs(rel) <= 4`). |
| **2. Memory & CPU** | `quickshell/island/Launcher.qml` | Set `cache: false` and reduced `sourceSize` from `84x84` to `64x64` on app grid icons so scrolling through installed apps does not permanently bloat `QQuickPixmapCache`. |
| **2. Memory & CPU** | `quickshell/island/Notifs.qml` | Dynamically shrank `island-notifs` `PanelWindow` from `444x1080` to `28x280` (or `28x32`) when closed with no active toasts, and added `gc()` on drawer close. |
| **2. Memory & CPU** | `quickshell/island/QuickTerm.qml` | Dynamically shrank `island-term` `PanelWindow` from `580x560` to `32x32` when closed, freeing its blurred layer surface when idle. |
| **2. Memory & CPU** | `quickshell/island/Overview.qml` | Wrapped `ImagePicker` in an on-demand `Loader` (`pickerLoader`) so `FolderListModel` is not instantiated unless the user clicks Browse in the profile editor. |
| **2. Memory & CPU** | `quickshell/island/CalStep.qml` | Gated infinite glow `SequentialAnimation` on `st.visible && st.current && st.live` so it does not tick in the background when the Connect view is hidden. |
| **2. Memory & CPU** | `scripts/start-shell.sh` | Exported `MALLOC_TRIM_THRESHOLD_=65536`, `MALLOC_MMAP_THRESHOLD_=65536`, `MALLOC_ARENA_MAX=2`, `QV4_GC_MAX_ALLOC=16777216`, and `QSG_ATLAS_WIDTH/HEIGHT=1024` alongside jemalloc `MALLOC_CONF` so freed pages return to the OS kernel immediately. |
| **2. Memory & CPU** | `variables.lua`, `hyprland/rules.lua`, `hyprland/general.lua` | Lowered default `blurPasses` from `3` to `2` (`blurSize = 6`, `shadowRange = 22`), set `blurSpecialWs = false`, disabled redundant Kawase layer blur on 6 full-screen overlay namespaces, and enabled `render.direct_scanout = 1`. |
| **3. Smooth Gestures** | `src/touchpad-gestures/src/main.rs` | Added real-time 3-finger and 4-finger multitouch centroid `(dx, dy)` and radial pinch `scale` tracking via `evdev` on every `SYN_REPORT`, streaming live state to `$XDG_RUNTIME_DIR/halcyon-gesture.json` at 60fps. |
| **3. Smooth Gestures** | `hyprland/gestures.lua` | Enabled Hyprland's native continuous 1:1 finger-following `workspace_swipe` and horizontal `workspace` gesture binding when `g3-left/right` or `g4-left/right` are set to `ws-next`/`ws-prev`. |
| **3. Smooth Gestures** | `quickshell/island/shell.qml` & `Overview.qml` | Added `FileView` watcher on `$XDG_RUNTIME_DIR/halcyon-gesture.json` driving live 1:1 finger-following opacity, scale, and translation on `Overview` and island bar pages during 3-finger and 4-finger gestures. |

---

## 1. Frictionless Google Calendar & Google Contacts Birthdays Integration

### 1.1 Why Google Calendar & Birthdays Were Previously Painful and Broken
1. **Why Google Calendar Events Showed "Busy" or Required Too Many Clicks**:
   - In `quickshell/island/Calendar.qml` (line 819), Step 3 previously told users: *"For holidays, birthdays, or subscriptions, copy the 'Public address in iCal format'"*. Users naturally made their calendar public or copied the Public iCal URL, which causes Google Calendar to mask all personal event titles as `"Busy"`!
   - Furthermore, users had to navigate through 4 manual steps for each individual calendar instead of being able to export all calendars in 1 click or auto-import from `~/Downloads`.
2. **Why Google Contacts Birthdays Were Messy & Failed to Sync**:
   - **Google Calendar vs. Google Contacts Architectural Split**: Google Calendar's built-in Birthdays calendar (`addressbook#contacts@group.v.calendar.google.com`) **has no Secret iCal address** in Google Calendar Settings, and under Google's linked-services settings, Google Calendar often does **not** sync birthdays from Google Contacts (or strips out the birth year `YYYY`).
   - **Missing Google People API (`contacts.readonly`) in `birthday-sync`**:
     - `src/birthday-sync/src/main.rs` only requested `calendar.readonly` and queried `addressbook#contacts@group.v.calendar.google.com`, never querying the Google Contacts People API (`https://people.googleapis.com/v1/people/me/connections?personFields=names,birthdays`).
     - In addition, `cmd_auth()` printed plain text to stdout even when `Calendar.qml` invoked `"$B" auth --json`.
   - **Missing Google Contacts CSV Support in `gcal.py`**:
     - When a user exports contacts at `contacts.google.com`, Google's default selected export format is **Google CSV** (`contacts.csv`), followed by **Outlook CSV** and **vCard** (`contacts.vcf`). Previously, `find_contacts_vcf()` in `gcal.py` only looked for `*.vcf` files and completely ignored `contacts.csv`!
   - **`(0th)` Birthday Age Bug on `.ics` Imports**:
     - In `quickshell/island/scripts/gcal.py` (line 1082), importing birthdays from a `VCALENDAR` `.ics` file parsed `DTSTART` (e.g. `20261020`) and stored `2026` as the person's `year` of birth. Then `load_birthday_events()` (line 510) evaluated `if birth_year and birth_year <= y: age = y - birth_year` (`2026 - 2026 = 0`), displaying `"Name's Birthday (0th)"`!

### 1.2 How & Where It Was Fixed
- **`quickshell/island/scripts/gcal.py`**:
  - **Multi-Format Google Contacts Importer (`parse_bday_date_any`, `parse_contacts_csv`, `find_contacts_vcf`, `cmd_import_birthdays`, lines 648–765 & 1140–1230)**:
    - Parses **Google CSV** (`contacts.csv`), **Outlook CSV**, **vCard 2.1/3.0/4.0** (`contacts.vcf`), **iCal** (`.ics`), and **Google Calendar / Contacts Export archives** (`.zip`).
    - Supports all birthday date formats (`YYYY-MM-DD`, `--MM-DD`, `MM/DD/YYYY`, `DD/MM/YYYY`, `Oct 14, 1998`, `14 October`) and preserves birth years (`year`) when present while setting `year: None` on yearless `.ics` recurrence dates.
  - **Zero-Click `~/Downloads` Auto-Grabber (`cmd_auto_grab`, lines 1315–1435)**:
    - Automatically detects newly downloaded Google Contacts exports (`contacts.vcf`, `contacts.csv`) or Google Calendar exports (`*.ics`, `*@gmail.com.ical.zip` from `calendar.google.com/calendar/u/0/r/settings/export`), extracts all calendars and birthdays (including `addressbook#contacts@group.v.calendar.google.com.ics` inside Google Calendar export zips!), and syncs them with zero user file-picking.
  - **Direct Birthday CRUD (`cmd_list_birthdays`, `cmd_add_birthday`, `cmd_remove_birthday`, lines 1235–1312)**:
    - Lists all saved birthdays with calculated `daysUntil` and `ageNext`, and allows adding or removing birthdays directly from the Calendar UI.
  - **Fixed `(0th)` Birthday Bug (`load_birthday_events`, line 515)**:
    - Changed `if birth_year and birth_year <= y:` to `if birth_year and 1900 <= birth_year < y:` and set `year: None` for `.ics` event imports so yearless birthdays never display `(0th)`.
- **`src/birthday-sync/src/main.rs`**:
  - **Added Google People API (`contacts.readonly`) (`SCOPE` at line 25, `fetch_people_contacts` at lines 302–346, `collect` at line 350)**:
    - Queries `https://people.googleapis.com/v1/people/me/connections?personFields=names,birthdays&pageSize=1000` in addition to Google Calendar's birthday feed, capturing exact birth years (`YYYY`) and contacts that Google Calendar's Birthdays calendar misses.
  - **Added `--json` Support in `cmd_auth` (lines 136–205)**:
    - Ensures `birthday-sync auth --json` outputs clean JSON when called from `Calendar.qml`.
- **`quickshell/island/Calendar.qml` & `quickshell/island/CalPage.qml`**:
  - **Dedicated `🎂 Birthdays` Modal (`Calendar.qml` lines 555–570 & 1295–1518, `CalPage.qml` lines 195–210)**:
    - Added a **🎂 Birthdays** pill button in the Calendar header (and in the bar drop-down `CalPage.qml` footer) that opens a dedicated Birthdays & Google Contacts manager.
    - Includes **1. Open Google Contacts & Auto-Import** (`openGoogleContacts()`, lines 272–279), **Quick Add Birthday** (`MM-DD` or `YYYY-MM-DD` + Name), and an interactive list of upcoming birthdays with countdowns (`Today!`, `in 12d · turns 28`) and 1-click removal.
  - **2-Click Google Calendar Export & Live Watcher (`openGoogleExport()`, lines 280–287, `autoGrabProc` & watcher `Timer`, lines 325–455)**:
    - Added **1-Click Export All Calendars** alongside **Live Sync (Secret iCal Link)**. While the user is in the browser, Halcyon watches both the clipboard and `~/Downloads` every 1.5s and automatically connects and pops back up the instant they copy an iCal link or click Export.

---

## 2. High-Degree Memory & CPU Optimization (Quickshell & Hyprland)

### 2.1 Why Quickshell Crept Up to 504 MB and Hyprland Used 204 MB
1. **Unbounded `QQuickPixmapCache` Retention Across Wallpaper Changes & Gallery Views**:
   - In `quickshell/island/Wallpaper.qml` (lines 38 & 56), `cur` and `inc` had `cache: true`. Every wallpaper change (or slideshow tick) left a decoded `1920x1080`–`3840x2160` RGBA texture (~9–33 MB each) inside Qt's global `QQuickPixmapCache` forever.
   - In `quickshell/island/WallpaperGallery.qml` (lines 471, 592, 652, 754), all three view modes (`cascade`, `carousel`, `grid`) had `cache: true`, and `carousel`'s `Repeater` decoded a `640x360` texture for **every wallpaper in the directory simultaneously** even when `viewMode` was `"cascade"` or `"grid"`. Closing the gallery left 150–300 MB of preview textures pinned in `QQuickPixmapCache`.
   - In `quickshell/island/Launcher.qml` (line 550), app grid icons decoded at `84x84` with `cache: true`.
2. **Oversized Always-Mapped Wayland `PanelWindow` Surfaces with Multi-Pass Kawase Blur**:
   - `win` (`island` in `shell.qml` line 1795) was permanently `1920x620` even when `page === "home"` (where the bar is only ~46px tall).
   - `corner` (`island-panel` in `shell.qml` line 2480) was permanently `444x1000` even when closed.
   - `appsWin` (`island-apps` in `shell.qml` line 2603) was permanently `444x700` even when closed.
   - `Notifs.qml` (`island-notifs` line 249) was permanently `444x1080` even when closed with zero toasts.
   - `QuickTerm.qml` (`island-term` line 427) was permanently `580x560` even when closed.
   - Because `hyprland/rules.lua` enabled `blur = true` (`blurPasses = 3`, `blurSize = 7`) on all 12 `island-*` layer namespaces, both Quickshell (Wayland triple-buffered RHI surfaces) and Hyprland (multi-pass Kawase blur FBOs) allocated tens of megabytes of GPU/RAM buffers for giant transparent regions that were completely empty 99% of the time!
3. **glibc Heap Arena Retention & Uncapped V4 QML JS Heap**:
   - Without `MALLOC_TRIM_THRESHOLD_` and `QV4_GC_MAX_ALLOC`, glibc malloc (used by Qt/drivers alongside jemalloc) and Qt's V4 JS engine retain fragmented heap arenas after QML `LazyLoader` overlays (`Overview`, `Settings`, `WallpaperGallery`) close, causing RSS to ratchet upward over hours.

### 2.2 How & Where It Was Fixed
- **Dynamic Wayland Layer Surface Sizing (`shell.qml`, `Notifs.qml`, `QuickTerm.qml`)**:
  - `quickshell/island/shell.qml` (lines 1865–1882): Added `winLinger` settle timer (`480ms`). When `page === "home" && !winLinger && !gestureActive`, `win.implicitHeight` shrinks from `620` to `notchStyle ? (notchBarH + 36) : (padSet.top + padSet.h + 36)` (~80px, an **87% reduction** in top-bar surface area).
  - `quickshell/island/shell.qml` (lines 2565–2575 & 2695–2705): Added 900ms post-close settle timers (`cornerLingerT`, `appsLingerT`) that shrink `corner` (`444x1000` → `32x32`) and `appsWin` (`444x700` → `32x32`) after their close animations and hover-block windows complete, avoiding any pointer-focus flicker while eliminating 99% of their idle surface area.
  - `quickshell/island/Notifs.qml` (lines 244–266): Added `needFullSurface` (`centerOpen || surfaceLinger || toasts.length > 0`) so when idle, `island-notifs` shrinks from `444x1080` to `28x280` (or `28x32` in corner mode).
  - `quickshell/island/QuickTerm.qml` (lines 423–438): Added `termLinger` so when closed, `island-term` shrinks from `580x560` to `32x32`.
- **Eliminated `QQuickPixmapCache` Retention & Off-Screen Decoding**:
  - `quickshell/island/Wallpaper.qml` (lines 38, 56, 163): Set `cache: false` on `cur` and `inc` and called `gc()` inside `releaseIncoming()`.
  - `quickshell/island/WallpaperGallery.qml` (lines 471, 592, 616, 652, 754): Set `cache: false` on all preview images, gated `carousel` `Repeater` model on `gal.viewMode === "carousel"`, and only loaded `carImg.source` when `Math.abs(carCard.rel) <= 4`.
  - `quickshell/island/Launcher.qml` (line 550): Set `cache: false` and `sourceSize: Qt.size(64, 64)`.
  - `quickshell/island/Overview.qml` (lines 591–597 & 1438–1451): Wrapped `ImagePicker` in `Loader { id: pickerLoader; active: false }` so its `FolderListModel` is only created if the user clicks Browse.
- **Stopped Hidden Background Animations & Unnecessary Process Wakeups**:
  - `quickshell/island/shell.qml` (line 1667): Gated `cava` `Process` so it only runs when the bar is shown and `page` is `"home"` or `"media"`.
  - `quickshell/island/CalStep.qml` (line 22): Added `st.visible` to `SequentialAnimation on glow` (`running: st.visible && st.current && st.live`).
- **Allocator & QML GC Tuning (`scripts/start-shell.sh`, lines 66–74)**:
  - Exported `MALLOC_TRIM_THRESHOLD_=65536`, `MALLOC_MMAP_THRESHOLD_=65536`, `MALLOC_ARENA_MAX=2`, `QV4_GC_MAX_ALLOC=16777216`, and `QSG_ATLAS_WIDTH=1024` / `QSG_ATLAS_HEIGHT=1024` alongside jemalloc `MALLOC_CONF`.
- **Hyprland Compositor VRAM & Blur Optimizations (`variables.lua`, `hyprland/rules.lua`, `hyprland/general.lua`)**:
  - `variables.lua` (lines 48–59): Set `blurSize = 6`, `blurPasses = 2`, `blurSpecialWs = false`, and `shadowRange = 22`.
  - `hyprland/rules.lua` (lines 16–27): Disabled multi-pass Kawase blur on the 6 full-screen overlay namespaces (`island-overview`, `island-power`, `island-settings`, `island-barbuilder`, `island-gallery`, `island-startup`) that already draw their own dimmed backdrops, keeping `blur = true` only on compact floating panels (`island`, `island-notch`, `island-panel`, `island-notifs`, `island-term`, `island-apps`).
  - `hyprland/general.lua` (lines 16–19): Added `render = { direct_scanout = 1 }`.

---

## 3. Smooth 1:1 Finger-Following 3-Finger & 4-Finger Touchpad Gestures

### 3.1 Why Gestures Previously Only Activated After Gesture End
1. **Discrete `exec_cmd` Bindings in `hyprland/gestures.lua`**:
   - Previously, `hyprland/gestures.lua` registered discrete `left` and `right` `exec_cmd(ic.run(id))` gestures even when `g3-left/right` or `g4-left/right` were set to `"ws-next"` / `"ws-prev"`.
   - In Hyprland, an `exec_cmd` gesture action **only fires after the swipe finishes and the user lifts their fingers**.
2. **`touchpad-gestures` Ignored Multi-Finger Events**:
   - `src/touchpad-gestures/src/main.rs` read raw `/dev/input/event*` multitouch slots via `evdev`, but when `active_slots.len() > 1`, it simply set `multi_finger_detected = true` and ignored all 3-finger and 4-finger movements.

### 3.2 How & Where It Was Fixed
- **Native 1:1 Continuous Workspace Sliding (`hyprland/gestures.lua`, lines 11–52)**:
  - When `g3-left/right` or `g4-left/right` are set to `"ws-next"` / `"ws-prev"`, `hyprland/gestures.lua` now enables Hyprland's native continuous workspace swipe engine (`gestures.workspace_swipe = true`, `workspace_swipe_fingers`, `workspace_swipe_distance = 230`, `workspace_swipe_min_speed_to_force = 10`, `workspace_swipe_cancel_ratio = 0.22`, `workspace_swipe_create_new = true`, `workspace_swipe_forever = true`) and registers `hl.gesture({ fingers = fingers, direction = "horizontal", action = "workspace" })`. Workspaces now slide 1:1 with your fingers in real time across the screen.
- **Real-Time 3-Finger & 4-Finger Multitouch Centroid & Pinch Tracker (`src/touchpad-gestures/src/main.rs`, lines 78–124 & 332–409)**:
  - Uses the existing `evdev` crate (`EventType::SYNCHRONIZATION`, `SYN_REPORT`) to track all active multitouch slots (`active_slots`).
  - Reads `~/.local/state/island/gestures.conf` and `ws-swipe4` to resolve the user's configured actions for `g3-*` and `g4-*`.
  - When 3 or 4 fingers are on the touchpad, computes the normalized centroid displacement `(dx, dy)` and radial pinch spread `scale` (`spread / mf_start_spread`) on every touch frame and streams live JSON updates (`{"phase":"begin|update|end","fingers":3|4,"dx":...,"dy":...,"scale":...,"dir":...,"action":...}`) atomically to `$XDG_RUNTIME_DIR/halcyon-gesture.json` at up to 60 Hz (`16ms` throttle).
- **Live Finger-Following Quickshell Overlays (`quickshell/island/shell.qml` lines 1788–1863 & 2525, `quickshell/island/Overview.qml` lines 20–24 & 600–607)**:
  - `shell.qml` watches `$XDG_RUNTIME_DIR/halcyon-gesture.json` via `FileView { watchChanges: true }` (zero polling).
  - Performing a 3-finger pinch or overview gesture immediately opens `Overview.qml` with `gestureActive = true`, binding `Overview.opacity` and `Overview.scale` directly to your live finger pinch/swipe progress (`gestureProgress`, `gestureScale`) and snapping smoothly on release.
  - Performing a 3-finger or 4-finger swipe mapped to `launcher`, `todo` (Calendar), or `notifcenter` immediately morphs the top island pill in real time with your fingers.

---

## 4. 3-Finger Pinch (Tree View) Fix & Rust Ports of Four Scripts

### 4.1 The pinch
- **Double toggle (`quickshell/island/shell.qml`)**: a 3-finger pinch could be handled twice: once by the live tracker (`touchpad-gestures` opens / closes the tree view as the fingers move) and once by Hyprland's own gesture, which runs `input-conf.sh run g3-pinch*` -> `ipc overview` when the fingers lift. `overview` is a TOGGLE, so the second call undid the first. The IPC `overview()` now ignores that call while a live overview gesture is running and for 900 ms after it (`overviewGestureEndAt`). With the tracker not running nothing is ignored, so Hyprland's call still works as the fallback. Only relevant when Hyprland reports a 3-finger pinch at all: see 4.3.
- **Pinch vs swipe (`src/touchpad-gestures/src/classify.rs`, new)**: the old rule locked onto whichever threshold was crossed first. The new rule calls it a pinch whenever the fingers moved against each other by at least half as much as the hand moved (`HALCYON_PINCH_BIAS`). In a replay with noisy synthetic data the old rule dropped to ~4 % correct pinches at a hand drift of 0.15 of the pad, the new one stayed at ~98 %; a clean pinch worked with both, and real swipes were never read as pinches. 60 ms after the last finger lands are ignored (`SETTLE_MS`) so touch-down jitter does not count as movement.
- Tuning without rebuilding: `HALCYON_PINCH_MIN`, `HALCYON_SWIPE_MIN`, `HALCYON_PINCH_BIAS`, and `HALCYON_GESTURE_DEBUG=1` (see the comments in `systemd/touchpad-gestures.service`).

### 4.2 `hal`: Rust ports (new crate `src/hal`, no dependencies)
| Shell script | Now | Fallback |
|---|---|---|
| `scripts/input-conf.sh` | `hal input conf / mice / set / reset / run` | the original shell code, still in the script |
| `scripts/ws-nav.sh` | `hal wsnav next / prev / gesture-* / wheel-*` | same |
| `scripts/brightness.sh` | `hal brightness up / down [percent]` | same |
| `scripts/backlight.sh` | `hal backlight set / best-screen / kbd` | same |

Each script runs `hal` when `bin/hal` exists and otherwise carries on with its own shell code, so nothing changes until `install.sh` has built the crate. `hal` is a separate crate on purpose: if it ever fails to build, `hx` and the rest are not affected.

### 4.3 Is Hyprland firing the pinch at all?
`tail -f ~/.cache/island/gesture-run.log` while you pinch (written by `input-conf.sh run`, shell or `hal`). A line means Hyprland fired it; no line means only the live tracker handled it (or nothing did: check `journalctl --user -u touchpad-gestures -e`; the daemon needs the `input` group).

## Review round: bugs and CPU/RAM fixes

| File | What changed |
| :--- | :--- |
| `quickshell/island/Calendar.qml` | `auto-grab` only starts Python when `~/Downloads` changed since the last scan (stamp file `~/.cache/island/.grabstamp`); the watcher ticks every 5 s instead of 1.5 s when only the setup / Birthdays window is open (1.5 s stays while waiting for the copied calendar address). |
| `src/power-manager/src/main.rs` | Gaming mode saves the animation / blur / shadow settings you had and restores exactly those (it used to force all three on). On startup the daemon resumes any apps a crashed run left stopped (SIGCONT) and restores the saved effects. New test `getoption_int_parses`. |
| `quickshell/island/shell.qml` | Gesture watchdog: if no gesture update arrives for 600 ms the gesture ends, so a dead gesture daemon or a lost `end` cannot leave the bar or tree view stuck on stale finger positions. |
| `src/touchpad-gestures/src/main.rs` | `dir` / `action` are JSON-escaped in `halcyon-gesture.json`, so a quote or backslash in `gestures.conf` no longer produces unreadable state. |
| `scripts/start-shell.sh` | jemalloc decay 0 ms -> 1000 ms (dirty) / 3000 ms (muzzy), overridable with `HALCYON_JE_DIRTY_MS` / `HALCYON_JE_MUZZY_MS`; removed `MALLOC_MMAP_THRESHOLD_` (forced an mmap for every allocation over 64 KB) and `QV4_GC_MAX_ALLOC` (not a Qt variable); `MALLOC_TRIM_THRESHOLD_` now matches `hyprland/execs.lua`. |

### Review round, part 2

| File | What changed |
| :--- | :--- |
| `quickshell/island/scripts/gcal.py`, `quickshell/island/Calendar.qml` | Reminders are scheduled instead of polled: `gcal.py notify --next` prints when it next has anything to do (reminder, nag, auto Focus start / end) and the island sleeps until then. The 60 s tick only compares two numbers. A change to events, done / task marks or the reminder settings runs the worker again at the next tick, and a 15 minute ceiling covers everything else (also a clock that jumped after suspend). Without `--next` the script behaves as before (the systemd timers are unaffected). |
| `scripts/term-colors.sh` | Accent-drift ticks stop at once when no terminal is open (no forks), and no longer rewrite the five terminal colour files every few seconds. The normal run still writes them. |
| `quickshell/island/shell.qml`, `quickshell/island/Settings.qml`, `quickshell/island/scripts/hypr-values.sh` | New Settings > Look option "Animate window resizing" (Hyprland `misc:animate_manual_resizes`). The Low resource preset turns it off, Medium and High turn it on. Default is unchanged. |
| `src/power-manager/src/main.rs` | The gaming-mode snapshot also understands Hyprland builds that report on / off options as `"bool"`. |

### Review round, part 3 (bar Off)

| File | What changed |
| :--- | :--- |
| `quickshell/island/shell.qml` | The `cava` visualizer feed (line ~1868) no longer runs on the home page when `barStyle` is `off`. `notchStyle` is also true for Off and `win.shown` is true whenever auto-hide is off, so the feed ran for a bar that does not exist. With Off it now runs only on the media page; Island, Notch and Custom use the same condition as before. |
| `src/recon-deceiver/src/main.rs` | New `prune_dir()`: before an FTP-decoy upload is saved, `attacker-uploads/` is trimmed to at most 99 files / 190 MB (oldest first), so with the new file it stays under 100 captures / about 200 MB. Before, every capture (up to 10 MB) was kept forever. Log files are left alone: `log-analyst` and `hx ids` tail `recon-attempts.log`. |
| `src/hx/src/sysfeeds.rs` | The battery reader no longer falls back to `upower -i` when the kernel status is "Not charging" (plugged in at a charge limit). That state never has an estimate, so the call only started a process every 15 s. |
| `install.sh`, `update.sh` | `holidays.txt` is added to the list of files that are never overwritten (`KEEP_FILES` / `KEEP`). Before, only `birthdays.txt` was kept, so every install or update replaced your own holidays with the stock template. `update.sh` also keeps `notes.conf` now (`install.sh` already did). |
Checked and left alone (already gated or already fine): `power-manager` (event driven: one `poll(2)`, cached sensors; no leak found), the `hx` stats / net / states feeds, every infinite animation in the island, the always-on timers and processes in `shell.qml` (all one-shot or event driven), image decoding (every `Image` has a `sourceSize`), the touchpad daemon loop (blocking reads, 16 ms write throttle), `osd-watch.sh` (timed reads, backs off to 1 s), and the systemd units. `bash -n` on every shell script, `py_compile` on every Python file and `node --check` on every `.js` pass.

---

## Security & reliability pass (login path, honeypot, gestures)

| File | What changed |
| :--- | :--- |
| `quickshell/island/shell.qml` | `lock-on-start` is only *read* at startup; it is removed once `lockScreen.locked` is true. Before, the island deleted it first, so if the lock never engaged `login-watchdog.sh` saw the flag gone, stopped watching, and the auto-logged-in desktop stayed open. Now an unlocked session is still ended after ~20 s. |
| `quickshell/island/Lock.qml` | Wrong-password backoff: 3 misses free of delay, then 2 s, 4 s, 8 s ... capped at 60 s ("Too many attempts. Wait N s"). The counter survives lock/unlock cycles and resets only on a correct password. PAM errors do not count as misses. |
| `sysmode/sysmode` | `write_deceiver_unit` generates a sandboxed `recon-deceiver.service` (ProtectSystem=strict, write access only to ufw state, `/run`, `/var/log` and your logs folder, capability bounding set, syscall deny-list, address-family limit). If it does not stay up, sysmode stops it and falls back to the old direct start. Opt out: `DECEIVER_SANDBOX=0` in `/etc/sysmode.conf`. |
| `sysmode/sysmode`, `.8`, bash-completion | New `sysmode counterscan [on\|off\|status] [--yes]`. |
| `src/recon-deceiver/src/main.rs` | nmap counter-scan is **off by default**; enabled by `COUNTER_SCAN=on` in `/etc/recon-deceiver.conf` (or `RECON_COUNTER_SCAN=1`). Read on every attacker, so no restart is needed. State is logged at daemon start. |
| `systemd/touchpad-gestures.service`, `src/touchpad-gestures/src/main.rs` | `Restart=on-failure` (was `always`), at most 5 starts per minute, and exit status 78 ("not in the `input` group") is in `RestartPreventExitStatus` so a missing group no longer loops forever. |

Not changed: the ~20 s window before the lock appears, and the nmap target rules (gateway, DNS servers, this machine and `/etc/recon-deceiver.allow` are still never scanned).
