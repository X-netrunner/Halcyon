# Halcyon Optimization & Bugfix Changelog

This changelog documents the complete audit, optimizations, bug fixes, and reliability improvements implemented across the Halcyon repository.

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
