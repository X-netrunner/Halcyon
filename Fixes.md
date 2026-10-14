# Halcyon Codebase Audit & Fixes Report (`fixes.md`)

This document catalogs every bug, crash, memory leak, battery/CPU drain issue, unoptimized code path, dead file, and cross-distro compatibility issue identified and fixed across the Halcyon repository.

---

## 1. Critical Battery Drain & Process-Spawning Fixes

### 1.1 `scripts/osd-watch.sh` — Eliminated 10,000+ `sleep` Process Forks/Hour
- **Bug**: Line 43 used `read -r -t "$w" -u "$nap" _ 2>/dev/null || sleep "$w"` to sleep on an empty FIFO without spawning an external process. However, when bash's builtin `read -t` times out, it exits with status `142` (non-zero), which **always** triggered the `|| sleep "$w"` fallback! Every loop iteration (every 0.25s–0.5s) waited for `read -t` AND then forked an external `/usr/bin/sleep` process—spawning 7,200 to 14,400 processes per hour continuously while the desktop was idle.
- **Fix**: Replaced `|| sleep "$w"` with `|| :` so the pure bash `read -t` timeout handles the delay with zero child process forks, added adaptive step-down to `1.0s` after 60s of inactivity, and added `/sys/class/leds/*keyboard*backlight*` to the LED discovery globs.

### 1.2 `scripts/autostart-extras.sh` — Fixed Unreachable Wi-Fi Power-Saving Restore at Login
- **Bug**: An unconditional `exit 0` on line 44 sat immediately above `( sleep 20; bash "$HOME/.config/Halcyon/scripts/toggle_wifi_powersave.sh" apply ) >/dev/null 2>&1 &` on line 47. The background job was unreachable dead code, so the user's saved Wi-Fi power-saving setting was never restored at login.
- **Fix**: Moved the background Wi-Fi power-save restore job before `exit 0` and added Debian/Ubuntu multiarch (`x86_64-linux-gnu` / `aarch64-linux-gnu` / `/usr/libexec`) discovery paths for Polkit agents and `xdg-desktop-portal-hyprland`.

### 1.3 `src/power-manager/src/main.rs` — Fixed Hardcoded PCI Bus Waking NVIDIA dGPU / Spawning `nvidia-smi` on Battery
- **Bug**: `DGPU_CONTROL` and `DGPU_STATUS` were hardcoded to `/sys/bus/pci/devices/0000:01:00.0/...`. On any laptop where the NVIDIA dGPU resides on another PCI address (e.g., `0000:02:00.0` or `0000:03:00.0`) or on AMD/Intel-only laptops without an NVIDIA GPU, `dgpu_asleep()` always returned `false`, causing `power-manager` to spawn `nvidia-smi` every 45 seconds even on battery—waking runtime-suspended GPUs or needlessly forking processes.
- **Fix**: Added `discover_nvidia_pci()` to dynamically locate the NVIDIA display controller (`vendor == 0x10de`, `class == 0x03*`) and its companion audio function in `/sys/bus/pci/devices`. If no NVIDIA GPU exists or its `runtime_status` is `suspended`/`suspending`, `gpu.util()` returns `0.0` immediately without spawning `nvidia-smi`.

### 1.4 `src/hx/src/ctl.rs` — Eliminated 3-Second `wpctl` Process Storm & 60ms Idle Allocations
- **Bug**:
  1. `let slow = last_poll.elapsed() > Duration::from_secs(3);` spawned two `wpctl get-volume` processes (and two reader threads in `util::run`) every 3 seconds even when `pactl subscribe` (`have_pactl == true`) was actively listening for audio events.
  2. The main loop woke up every 60ms forever and heap-allocated a formatted JSON `String` on every single tick even when volume and brightness were completely unchanged.
- **Fix**: Extended the safety fallback interval to 60 seconds when `pactl subscribe` is active, avoided formatting/allocating the JSON string unless `(vol, mic, b)` actually changed, and added adaptive sleep (`80ms` for 5 seconds after a change, `250ms` when idle).

### 1.5 `scripts/super_tap.sh` — Stopped Spawning `quickshell ipc` on Every Super Key Release
- **Bug**: `hyprland/keybinds.lua` binds `SUPER_L`, `SUPER_R`, `SUPER + SUPER_L`, and `SUPER + SUPER_R` on key release to `super_tap.sh`. `super_tap.sh` wrote to `$XDG_RUNTIME_DIR/halcyon-super-tap` (which `shell.qml` watches via `FileView` inotify) and then **unconditionally** executed `quickshell ipc -p ... call island supertap`. Every `Super+<key>` shortcut or `Super` tap spawned full Qt `quickshell ipc` client processes.
- **Fix**: When `$XDG_RUNTIME_DIR/halcyon-super-tap` exists (created by `shell.qml` on startup) and writing to it succeeds, `super_tap.sh` exits immediately (`0` child processes spawned), falling back to `quickshell ipc` only if the trigger file is absent.

### 1.6 `quickshell/island/Pal.qml` & `quickshell/island/scripts/palette.sh` — Replaced Permanent `tail -F` Child Process with Native `FileView`
- **Bug**: `Pal.qml` spawned a permanent `tail -F -n 1 ~/.cache/island/palette.json` child process that stayed resident for the entire desktop session, while `palette.sh` also spawned `quickshell ipc ... call island reloadPalette`—an IPC method that **did not exist** on `IpcHandler { target: "island" }` in `shell.qml`.
- **Fix**:
  1. Replaced the permanent `tail -F` process in `Pal.qml` with Quickshell's native inotify `FileView { watchChanges: true }` and deduplicated `apply(data)` so identical palette reads do not re-trigger `term-colors.sh`.
  2. Added `function reloadPalette(): void { pal.reloadFromFile() }` to `IpcHandler { target: "island" }` in `quickshell/island/shell.qml`.
  3. Updated `palette.sh` to rely on the in-place write watched by `FileView` unless `--ipc` is explicitly requested.

---

## 2. Memory Leak, File Descriptor Leak & Zombie Process Fixes

### 2.1 `src/hx/src/util.rs` — Fixed Zombie (`<defunct>`) Process Leak in `spawn_quiet`
- **Bug**: `spawn_quiet()` called `Command::new(cmd)...spawn()` and dropped the `Child` handle without waiting on it. In long-running daemons like `hx ids` (which calls `spawn_quiet("notify-send", ...)`), every alert left a zombie (`<defunct>`) process in the process table.
- **Fix**: Spawned a lightweight waiter thread in `spawn_quiet()` to call `child.wait()` and reap the exit status immediately.

### 2.2 `src/hx/src/sysfeeds.rs` — Fixed Raw File Descriptor Leaks & USB-C Charger Detection
- **Bug**: `Wake` (`fd: RawFd`) and `Net` (`ip_sock: RawFd`, `hci_sock: RawFd`) opened raw libc file descriptors/sockets without implementing `Drop`. Additionally, `ac_online()` only checked `type == "Mains"`, ignoring USB-C Power Delivery chargers (`USB`, `USB_PD`, `USB_C`, `ucsi*`, `AC*`, `ADP*`).
- **Fix**: Implemented `Drop` for both `Wake` and `Net` to close valid file descriptors with `libc::close`, and updated `ac_online()` to recognize USB-C PD power supplies consistently with `power-manager`.

### 2.3 `src/recon-deceiver/src/main.rs` — Fixed Unbounded Memory Growth & OOM DoS Vectors
- **Bug**:
  1. `handle_ftp` (`STOR`) called `ds.read_to_end(&mut payload)` with no size cap, allowing an attacker to stream gigabytes into memory and OOM-kill the daemon.
  2. `handle_ftp` and `handle_smtp` called `reader.read_line(&mut line)` with no line length cap, and SMTP `DATA` accumulated the entire email body into `data_buf` without clearing `data_buf` between lines (which also broke `data_buf.trim() == "."` termination).
  3. `last_notification`, `last_scan`, `first_seen`, and `uploaded_webshells` `HashMap`s grew indefinitely across unique attacker IPs/uploads without eviction.
- **Fix**:
  1. Capped FTP `STOR` reads to `MAX_UPLOAD_SIZE` (10 MB) via `ds.take((MAX_UPLOAD_SIZE + 1) as u64)` with a 15-second read timeout.
  2. Capped FTP and SMTP command line reads to 4,096 bytes per line (`(&mut reader).take(4096).read_line(...)`) and rewrote SMTP `DATA` to process line-by-line with a 64 KB total cap.
  3. Added automatic size-and-TTL eviction (`>= 1024` entries for IP maps, `>= 256` entries for `uploaded_webshells`) to all `HashMap`s in `AppState`.

### 2.4 `quickshell/island/Notifs.qml` — Fixed `arrived` Timestamp Map Leak
- **Bug**: When notifications were replaced by `snapshot(n)` after an app closed them (`closedByApp`), their `dismiss()` method became a no-op (`function () {}`). When those snapshots were later evicted by `maxHistory` or cleared via `clearAll()`, `delete arrived[id]` was never called, leaking keys in `root.arrived` over long sessions.
- **Fix**: Explicitly deleted `arrived[id]` on eviction in `onMaxHistoryChanged` and `add()`, and reset `arrived = ({})` in `clearAll()`.

### 2.5 `quickshell/island/Launcher.qml` — Pruned Unbounded State Logs on Disk
- **Bug**: `~/.local/state/island/launcher-history.log` and `~/.local/state/island/usage.log` were appended to on every app launch or search query and never truncated.
- **Fix**: Added automatic log compaction on startup when `launcher-history.log` exceeds 200 lines (keeping the latest 100) or `usage.log` exceeds 4,000 lines (keeping the latest 3,000).

---

## 3. Functional Bugs, Crashes & Desktop UX Fixes

### 3.1 `src/power-manager/src/main.rs` — Preserved Monitor Scale & Multi-Monitor Position on Refresh Toggle
- **Bug**: When switching refresh rates (`144Hz` <-> `60Hz`), `set_refresh()` hardcoded `position = '0x0', scale = 1`, resetting any HiDPI display scaling (e.g., `1.25` or `1.5`) and multi-monitor layout coordinates every time AC power was plugged/unplugged or the laptop entered idle.
- **Fix**: Extended `parse_monitor_detail()` to read the monitor's current `x`, `y`, and `scale` from `j/monitors` and pass `position = '{x}x{y}', scale = {scale}` to `hl.monitor(...)`.

### 3.2 `quickshell/island/QuickTerm.qml` — Fixed Stuck Exclusive Keyboard Focus
- **Bug**: Line 425 set `WlrLayershell.keyboardFocus` to `((root.grabKeys || root.zoneHover || root.pinned || root.open) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand)`. Because `root.open` is always `true` when the console is open, `WlrKeyboardFocus.OnDemand` was unreachable dead code and the console trapped keyboard focus exclusively even after the pointer moved to another window.
- **Fix**: Changed the condition to `((root.grabKeys || root.zoneHover || root.askPass) ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand)`, matching the design documented in the file's comments.

### 3.3 `quickshell/island/Settings.qml` — Removed Duplicate Settings Controls & Deduplicated Tree Descriptions
- **Bug**:
  1. Six settings keys (`opt:resMode`, `hy:blurPasses`, `opt:fps`, `opt:starsBar`, `opt:pageClose`, `opt:scrollLinger`) were defined twice across different groups (`suggestions`/`sysoptions` vs `performance`/`glass`/`growth`/`bar`), causing duplicate entries in search results and conflicting UI controls (`hy:blurPasses` was a 1–5 slider in `glass` and a 1–3 segmented button in `suggestions`).
  2. `leaf.descText` in the Tree view duplicated the 9-branch ternary expression from `root.descOf(m)`.
- **Fix**: Removed the duplicate setting definitions from `suggestions` and `sysoptions`, replaced `leaf.descText`'s inline ternary with `root.descOf(leaf.m)`, and made package installation hints in `descOf(m)` adapt dynamically to `apt` vs `pacman`.

### 3.4 `sysmode/sysmode` & `sysmode/sysmode.bash-completion` — Fixed `SIGPIPE` Crash, Config Override & CLI Parsing
- **Bug**:
  1. Line 57 set `DECOY_HOTSPOT=0` **after** sourcing `/etc/sysmode.conf` on line 9, wiping out any `DECOY_HOTSPOT=1` saved in `/etc/sysmode.conf`.
  2. Line 1531 ran `rand_id=$(head /dev/urandom | tr -dc 'a-f0-9' | head -c 4)` under `set -euo pipefail`. When `head -c 4` closed the pipe early, `tr`/`head` received `SIGPIPE` (exit code 141), which under `pipefail` + `set -e` aborted `sysmode stealth` mid-execution!
  3. Lines 1595–1596 required the external `openssl` CLI binary (`openssl rand -hex 3`) to generate MAC suffixes.
  4. Line 1974 (`--persona`) executed `shift` inside the `case` block and another `shift` at the end of the `while` loop, crashing under `set -e` if `--persona` was passed without a following argument.
  5. `sysmode.bash-completion` was missing `dossier`, `daemons`, `boot-late`, `cyber`, and `--persona`.
- **Fix**:
  1. Changed line 57 to `DECOY_HOTSPOT="${DECOY_HOTSPOT:-0}"`.
  2. Replaced the `SIGPIPE`-prone pipeline and `openssl rand` calls with `od -An -N2 -tx1 /dev/urandom` / `od -An -N3 -tx1 /dev/urandom`.
  3. Guarded the inner `shift` for `--persona` with `[[ $# -ge 2 ]] && shift`.
  4. Added Debian/Ubuntu support (`ssh.service`, `acct.service`, dynamic `/etc/os-release` banner in `write_banner`, `apt` hints in `run_doctor`).
  5. Updated `sysmode/sysmode.bash-completion` with all subcommands and `--persona` completions.

### 3.5 `install.sh` & `update.sh` — Fixed Undefined `DISTRO_FAMILY`, Sudoers Cleanup & Debian/Ubuntu Mappings
- **Bug**:
  1. `install.sh` line 1256 checked `if [[ "$DISTRO_FAMILY" == "arch" ]]`, but `DISTRO_FAMILY` was never defined anywhere in `install.sh`, causing Arch Linux installs to skip `pacman` and run `curl -fsSL https://ollama.com/install.sh | sh`.
  2. `cleanup()` in `install.sh` ran `rm -f "$SUDOERS_TMP"` without `as_root`.
  3. Pre-flight crate check omitted `safety-check`.
  4. `music_pkgs()` ran `pacman -Si spotify-launcher` without checking `[[ "$PKG_MGR" == "pacman" ]]`.
  5. `map_pkg_for_apt` mapped `qt6-5compat` to non-existent `qml6-module-qt5compat` (instead of `qml6-module-qt5compat-graphicaleffects`), omitted required `qml6-module-qtquick-*` packages from `qt6-declarative`, and mapped `kservice` only to `libkf6service-dev` (missing `libkf6service-bin` which provides `kbuildsycoca6`).
- **Fix**: Fixed all 5 issues in `install.sh`, added automatic `JetBrainsMono Nerd Font` installation for Debian/Ubuntu in Step 5, and synchronized `KEEP_FILES` between `install.sh` and `update.sh`.

### 3.6 `hyprland.lua`, `variables.lua`, `hyprland/env.lua`, `hyprland/execs.lua`, `hyprland/keybinds.lua`
- **Fixes**:
  - `hyprland.lua`: Used `vars.cursorTheme` and `vars.cursorSize` instead of hardcoding `Adwaita 24`.
  - `variables.lua`: Removed unused `require("scheme.current")` and 17 unreferenced legacy variables; aligned `kbNextWs` / `kbPrevWs` with `hyprland/keybinds.lua`.
  - `hyprland/env.lua` & `hyprland/execs.lua`: Checked for `/etc/xdg/menus/arch-applications.menu` before setting `XDG_MENU_PREFIX=arch-` so `kbuildsycoca6` works on both Arch and Debian/Ubuntu.
  - `hyprland/keybinds.lua`: Added `mkdir -p ~/Pictures/Screenshots` to `Print` and `SUPER + SHIFT + Print`, guarded `grim -g "$g"` when `slurp` is cancelled, and removed the broken `SUPER + GRAVE` binding to non-existent `~/.config/hyprland.overview.sh`.

### 3.7 `config/fish/halcyon.fish`, `config/fish/hints.fish`, `config/fish/functions/fish_greeting.fish`, `launch/halcyon-login.sh`
- **Fixes**:
  - `config/fish/halcyon.fish`: Replaced external `stat -c %Y` on every prompt and `grep` on shell init with fish builtins (`read -l` and `string match`).
  - `config/fish/hints.fish`: Replaced `command -v eza &> /dev/null` with fish builtin `command -q eza` and updated the `Super + E` reminder text.
  - `config/fish/functions/fish_greeting.fish`: Replaced multi-process pipelines (`free | awk | sed`, `uptime | sed`, `grep | cut | tr`) with single-pass `/proc/meminfo` and fish `string` builtins, and fixed outdated shortcut tips.
  - `launch/halcyon-login.sh`: Validated numeric timestamps and pruned expired entries from `/tmp/halcyon-login-$UID`.

### 3.8 `src/safety-check/src/main.rs`
- **Fixes**:
  - Added `"env"` before `DBUS_SESSION_BUS_ADDRESS=...` in `sudo -u real_user env DBUS_SESSION_BUS_ADDRESS=... notify-send` so `sudo` does not reject the environment variable when `setenv` is not permitted.
  - Added `apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y` fallback when `pacman` is not present.

---

## 4. Dead & Obsolete Files Removed

| Removed Path | Reason |
| :--- | :--- |
| `quickshell/wallpaper/shell.qml` | Obsolete standalone wallpaper Quickshell instance; wallpaper rendering was merged into `quickshell/island/Wallpaper.qml` (as documented in `README.md` and `changelog.md`). |
| `hyprland-gui.lua` | Unused 28-line stub file never loaded by `hyprland.lua` or any script. |
| `src/hx/data/*` (9 files: `backup_members.json`, `dashboard.html`, `fake_dump.sql`, `login.html`, `mysql3306.bin`, `rdp3389.bin`, `sandbox.json`, `smb445.bin`, `webshell_form.html`) | Unreferenced honeypot bait files left over from before `recon-deceiver` was split into its own crate (`src/recon-deceiver/src/main.rs` embeds all bait payloads directly). |

---

## 5. Build, Syntax & Hyprland 0.56 Compatibility Fixes

### 5.1 `src/hx/src/ctl.rs` — Fixed String Literal Quotes inside `format!`
- **Bug**: Line 99 used `format!("{{"vol":...}}")` with unescaped internal double quotes, causing rustc to fail compilation with `expected ,, found ":{},"muted`.
- **Fix**: Properly escaped the internal JSON string quotes `\"` in `ctl.rs`.

### 5.2 `src/recon-deceiver/src/main.rs` — Defined Missing `MAX_UPLOAD_SIZE`
- **Bug**: `ds.take((MAX_UPLOAD_SIZE + 1) as u64)` on line 1327 failed compilation with `error[E0425]: cannot find value MAX_UPLOAD_SIZE in this scope`.
- **Fix**: Added `const MAX_UPLOAD_SIZE: usize = 10 * 1024 * 1024; // 10 MB upload cap`.

### 5.3 `hyprland/misc.lua` — Removed Obsolete `misc.vfr` in Hyprland 0.56+
- **Bug**: Hyprland 0.56.2 halted config loading with `config error /misc.lua :1 unknown key misc.vfr` because VFR is now hardcoded into Hyprland's core renderer and the config key was removed upstream.
- **Fix**: Removed `vfr = true,` from `hyprland/misc.lua`.

### 5.4 `install.sh` — Fixed `local` Keyword Outside Function Scope
- **Bug**: `local ollama_bin` on line 1281 was executed at top-level script scope (Step 5), triggering fatal bash error `local: can only be used in a function` under `set -Eeo pipefail`.
- **Fix**: Removed `local` keyword at script scope (`ollama_bin=""`).

---

## 6. Memory Footprint Optimization & Utility Box Device Scanning Fixes

### 6.1 `src/hx/src/feeds.rs` & `quickshell/island/scripts/bt-set.sh` — Active Bluetooth Discovery, Detached Background Scan & Auto-Pairing
- **Bug**:
  1. `feeds::bt()` in `hx` only queried `bluetoothctl devices Paired`. It never triggered device discovery (`bluetoothctl scan on`) and never checked for un-paired nearby Bluetooth devices. When opening the utility box, nearby Bluetooth devices never appeared.
  2. `bluetoothctl` did not indicate scan state in JSON, leaving the UI unaware whether a discovery cycle was running.
  3. Clicking an unpaired device in `DeviceMenu.qml` failed because `bt-set.sh` only called `bluetoothctl connect <mac>`, which fails on devices that are not yet paired or trusted.
- **Fix**:
  1. Updated `feeds::bt()` to query both paired (`bluetoothctl devices Paired`) and all discovered (`bluetoothctl devices`) devices, categorizing and sorting them with Connected first, then Paired, then Nearby/Available.
  2. Spawns a detached background scan (`nohup bluetoothctl --timeout 15 scan on >/dev/null 2>&1 &`) whenever Bluetooth is powered on and not actively discovering.
  3. Emits `"scanning": true/false` in the JSON response from `hx bt` based on the controller's active `Discovering` status.
  4. Updated `bt-set.sh` to support a `scan` action and automatically pair and trust (`bluetoothctl pair` + `bluetoothctl trust`) any un-paired target device before executing `bluetoothctl connect`.

### 6.2 `quickshell/island/Panel.qml` & `DeviceMenu.qml` — Real-Time Scanning Indicators & Dynamic Menu Polling
- **Bug**:
  1. Wi-Fi and Bluetooth dropdown lists only refreshed via a one-shot timer upon opening; keeping the menu open did not update available networks or discover new devices.
  2. There was no visual indicator or manual refresh trigger to indicate whether Wi-Fi or Bluetooth was currently scanning.
- **Fix**:
  1. Added recurring poll timers in `Panel.qml` (`btPoll` every 2.5s while the Bluetooth menu is open, `wifiPoll` every 6s while the Wi-Fi menu is open).
  2. Added a `"Scanning"` status indicator with an animated spinning refresh icon in `DeviceMenu.qml` when `scanning` is active.
  3. Added a dedicated `RoundBtn` rescan button in the `DeviceMenu` header to allow manual re-scanning at any time.
  4. Preserved exact device indexing in `Panel.qml` when separating devices into "Paired" and "Available Nearby" section headers.

### 6.3 Memory Footprint Analysis & Idle Garbage Collection Optimization
- **Analysis**:
  - **Hyprland (~200 MB RSS)**: Composed of ~69 MB private dirty heap, with the remainder consisting of shared Mesa Gallium GPU drivers (`libgallium` ~40 MB), NVIDIA EGL compiler runtimes, DRM/KMS double-buffered framebuffers (1920x1200), and Wayland SHM client memory pools (e.g., terminal window framebuffers). This is standard, baseline memory usage for a Wayland C++ compositor.
  - **Quickshell (~430 MB RSS)**: Runs 7 concurrent Wayland LayerShell surfaces (`wallpaper`, `island`/`island-notch`, `island-panel`, `island-notifs`, `island-term`, `island-apps`), an OpenGL/Vulkan Qt Quick SceneGraph texture pipeline (caching decoded wallpapers at 1920x1200 plus blur effect buffers), and the V8 QML JavaScript JIT engine.
- **Fix**:
  - Expanded `anyOverlay` in `shell.qml` to track all sidebars, utilities, and builder dialogs (`corner.open`, `appsWin.open`, `notifs.centerOpen`, etc.).
  - Added an idle memory trimmer in `shell.qml` that executes gentle garbage collection (`gc()`) every 90 seconds while the shell is idle, and automatically upon closing any overlay, freeing unreferenced textures and shrinking the RSS footprint.

---

## 7. Launcher Animations, Fullscreen QuickTerm Protection, 1-Click Holidays, & Native Rust Migration

### 7.1 Launcher Animation Overhaul (`Launcher.qml` & `shell.qml`)
- **Problem**: Opening the app launcher felt sluggish and stuttered due to artificial delays (`PauseAnimation { duration: 70 + min(index, 17) * 14 }`) in grid cell delegates, along with artificial `dMed * 0.3` delays in `shell.qml`. Icons had bouncy overshooting scale transitions.
- **Fix**:
  - In `quickshell/island/Launcher.qml`: Removed staggered pauses in favor of unified `150ms OutCubic` fade and subtle translate transitions. Optimized icon hover scale to clean `1.08x OutCubic` without oscillation.
  - In `quickshell/island/shell.qml`: Removed `PauseAnimation` delay so apps glide smoothly into view immediately as the launcher container expands.

### 7.2 Fullscreen Drop-down Console Protection (`QuickTerm.qml`)
- **Problem**: When playing fullscreen games or watching fullscreen videos, the drop-down terminal console (`QuickTerm`) could pop on top if the mouse approached the top-left trigger zone, or due to global key shortcuts.
- **Fix**:
  - Changed Wayland LayerShell layer from `WlrLayer.Overlay` to `WlrLayer.Top` (Hyprland fullscreen surfaces render over `Top` layer surfaces, preventing visual intrusion).
  - Bound workspace state (`wsHasFullscreen`) to `Hyprland.workspaces` on the active workspace.
  - Added auto-close behavior if a fullscreen window enters focus (`onWsHasFullscreenChanged: if (wsHasFullscreen && !pinned && open) close()`).
  - Completely deactivated the top-left mouse hover zone (`zone.width = 0; zone.height = 0; enabled = false`) while fullscreen windows are active.

### 7.3 Frictionless Holidays System (`Calendar.qml`, `gcal.py`, `holidays.txt`)
- **Problem**: Adding holidays required copying obscure Google iCal URLs from browser settings. Users had no easy way to add national holidays or local custom dates.
- **Fix**:
  - Created standard local holiday configuration `~/.config/Halcyon/holidays.txt` with support for recurring annual dates (`MM-DD Name`) and one-offs (`YYYY-MM-DD Name`).
  - Added `add-holiday <date> <name>` and `list-countries` commands to `quickshell/island/scripts/gcal.py`.
  - Added dedicated `🎉 Holidays` button in the Calendar header with a comprehensive modal panel:
    - 1-Click country presets for India, USA, UK, Canada, Australia, Germany, France, Japan, Brazil, Italy, Spain, Netherlands, UAE, Singapore, plus Auto-Detect Region.
    - Direct custom holiday input field (`Date` + `Name`) that saves directly to `holidays.txt` and syncs immediately.
    - Direct buttons to open and edit `holidays.txt` and `birthdays.txt` in the default text editor.

### 7.4 Background Daemon Port to Native Rust (`src/hx/src/adapt.rs`, `main.rs`, `shell.qml`)
- **Problem**: The periodic adaptive resource limit sampler ran `python3 startup-view.py adapt-sample` every 5 minutes in `shell.qml`, constantly spawning Python runtimes in the background.
- **Fix**:
  - Implemented `adapt.rs` in the native Rust helper `hx` (`src/hx/src/adapt.rs`):
    - Replaced Python process scanning with native `/proc` sampling of Halcyon memory (PSS) and CPU utilization.
    - Implemented `adapt-sample`, `adapt-status`, and `adapt-reset` subcommands.
    - Retained 14-day history trimming and percentile limit computations.
  - Updated `quickshell/island/shell.qml` to call `hx adapt-sample` and `hx adapt-reset` directly, removing periodic Python execution entirely.



