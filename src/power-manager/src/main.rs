use serde::Deserialize;
use std::fs;
use std::process::Command;
use std::thread;
use std::time::Duration;
use chrono::Local;
use std::os::unix::net::{UnixStream, UnixListener};
use std::io::{Write, Read};
use std::sync::mpsc;
use evdev::Device;
use rand::seq::SliceRandom;

const MONITOR: &str = "eDP-1";
const RES_HIGH: &str = "1920x1200@144";
const RES_LOW: &str = "1920x1200@60";


const THERMAL_THROTTLE_TEMP: f64 = 85.0;
const GAMING_THROTTLE_TEMP: f64 = 92.0;
const THERMAL_RECOVER_TEMP: f64 = 78.0;
const THERMAL_PROFILE: &str = "balanced";

// Load-sensing: jump to performance when busy, settle to power-saver when idle.
// Calibrated on this machine: idle ~19% CPU / 0% GPU, LLM generation ~48% / 24%.
const CPU_HEAVY_PCT: f64 = 40.0;
const CPU_IDLE_PCT: f64 = 25.0;
const GPU_HEAVY_PCT: f64 = 20.0;
const GPU_IDLE_PCT: f64 = 5.0;

// Number of consecutive quiet polls before dropping to Idle mode (~45s).
const IDLE_POLLS_REQUIRED: u32 = 3;

const PAUSE_APPS: &[&str] = &[
    "zen-bin", "vesktop", "discord", "spotify", "qbittorrent", 
    "steam", "lutris", "telegram-desktop", "code", "obs"
];

#[derive(Deserialize)]
struct HyprClient {
    class: String,
}

#[derive(Deserialize)]
struct HyprMonitor {
    solitary: String,
}

#[derive(PartialEq, Clone, Copy, Debug)]
enum PowerMode {
    Battery,
    ACBalanced,
    ACPerformance,
    Idle,
    Gaming,
    Thermal,
}

impl PowerMode {
    /// Short name the island shows next to "auto".
    fn name(self) -> &'static str {
        match self {
            PowerMode::Battery => "battery",
            PowerMode::ACBalanced => "ac-balanced",
            PowerMode::ACPerformance => "ac-performance",
            PowerMode::Idle => "idle",
            PowerMode::Gaming => "gaming",
            PowerMode::Thermal => "thermal",
        }
    }

    /// The power-profiles-daemon profile this mode asserts.
    fn profile(self) -> &'static str {
        match self {
            PowerMode::Battery | PowerMode::Idle => "power-saver",
            PowerMode::ACBalanced => "balanced",
            PowerMode::ACPerformance | PowerMode::Gaming => "performance",
            PowerMode::Thermal => {
                if ac_online() { THERMAL_PROFILE } else { "power-saver" }
            }
        }
    }
}

fn runtime_dir() -> String {
    std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string())
}

/// "<mode> <profile> <unix-epoch>", rewritten every poll. The island reads it (via
/// island/scripts/stats.sh) to know Auto is on and what it is doing; a file older than
/// ~a minute counts as "daemon not running". Removed on clean exit.
fn state_path() -> String {
    format!("{}/power-manager.state", runtime_dir())
}

fn write_state(mode: &str, profile: &str) {
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // write + rename so a reader never sees a half-written file
    let tmp = format!("{}.tmp", state_path());
    if fs::write(&tmp, format!("{} {} {}\n", mode, profile, epoch)).is_ok() {
        let _ = fs::rename(&tmp, state_path());
    }
}

/// The old caelestia-era behaviour (gslapper video wallpaper + recolouring
/// ~/.config/hypr/scheme) is opt-in now: Halcyon has its own wallpaper layer and palette.
/// Set PM_LIVE_WALLPAPER=1 in the service environment to get it back.
fn live_wallpaper_enabled() -> bool {
    std::env::var("PM_LIVE_WALLPAPER").map(|v| v == "1").unwrap_or(false)
}

/// Persisted state between polls, used for debounce/hysteresis.
struct LoadState {
    idle_streak: u32,
}

fn send_hyprland_cmd(socket_path: &str, cmd: &str) -> Result<String, std::io::Error> {
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    stream.write_all(cmd.as_bytes())?;
    let mut response = String::new();
    stream.read_to_string(&mut response)?;
    Ok(response)
}

fn get_hyprland_socket() -> Option<String> {
    // 1. Check if HYPRLAND_INSTANCE_SIGNATURE is set
    if let Ok(sig) = std::env::var("HYPRLAND_INSTANCE_SIGNATURE") {
        let xdg_runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
        let path = format!("{}/hypr/{}/.socket.sock", xdg_runtime, sig);
        if std::path::Path::new(&path).exists() {
            return Some(path);
        }
        let tmp_path = format!("/tmp/hypr/{}/.socket.sock", sig);
        if std::path::Path::new(&tmp_path).exists() {
            return Some(tmp_path);
        }
    }
    
    // 2. If not set, search in XDG_RUNTIME_DIR/hypr or /tmp/hypr
    let xdg_runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let search_paths = [
        format!("{}/hypr", xdg_runtime),
        "/tmp/hypr".to_string(),
    ];
    
    for search_path in &search_paths {
        if let Ok(entries) = fs::read_dir(search_path) {
            for entry in entries.flatten() {
                if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    if let Some(name) = entry.file_name().to_str() {
                        let path = format!("{}/{}/.socket.sock", search_path, name);
                        if std::path::Path::new(&path).exists() {
                            unsafe {
                                std::env::set_var("HYPRLAND_INSTANCE_SIGNATURE", name);
                            }
                            return Some(path);
                        }
                    }
                }
            }
        }
    }
    None
}

struct HyprlandConnection {
    socket_path: Option<String>,
}

impl HyprlandConnection {
    fn new() -> Self {
        let mut conn = Self { socket_path: None };
        conn.refresh();
        conn
    }

    fn refresh(&mut self) -> Option<String> {
        self.socket_path = get_hyprland_socket();
        self.socket_path.clone()
    }

    fn send_cmd(&mut self, cmd: &str) -> Result<String, std::io::Error> {
        let path = match &self.socket_path {
            Some(p) => p.clone(),
            None => match self.refresh() {
                Some(p) => p,
                None => return Err(std::io::Error::new(std::io::ErrorKind::NotFound, "Hyprland socket not found")),
            }
        };

        match send_hyprland_cmd(&path, cmd) {
            Ok(res) => Ok(res),
            Err(e) => {
                println!("Failed to communicate with socket at {}, retrying refresh...", path);
                let new_path = match self.refresh() {
                    Some(p) => p,
                    None => return Err(e),
                };
                send_hyprland_cmd(&new_path, cmd)
            }
        }
    }
}

fn main() {
    println!("Power Manager Daemon started...");

    let xdg_runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
    let lock_socket_path = format!("{}/power-manager.lock.sock", xdg_runtime);
    
    // Check if another instance is running
    if std::path::Path::new(&lock_socket_path).exists() {
        if let Ok(mut stream) = UnixStream::connect(&lock_socket_path) {
            println!("Another instance is running, sending wakeup signal and exiting.");
            let _ = stream.write_all(b"wakeup");
            std::process::exit(0);
        } else {
            // Socket exists but is dead (e.g. after crash). Remove it.
            let _ = std::fs::remove_file(&lock_socket_path);
        }
    }
    
    let listener = match UnixListener::bind(&lock_socket_path) {
        Ok(l) => l,
        Err(_) => {
            println!("Failed to bind lock socket. Exiting.");
            std::process::exit(0);
        }
    };

    // Cleanup socket and wallpaper on termination signal
    let lock_socket_path_clone = lock_socket_path.clone();
    let _ = ctrlc::set_handler(move || {
        println!("Received termination signal, cleaning up...");
        let _ = std::fs::remove_file(&lock_socket_path_clone);
        let _ = std::fs::remove_file(state_path());
        if live_wallpaper_enabled() && is_process_running("gslapper") {
            let _ = Command::new("pkill").args(["-9", "gslapper"]).status();
        }
        std::process::exit(0);
    });

    // Create channel for wakeup signals
    let (tx, rx) = mpsc::channel();

    // Spawn listener thread
    thread::spawn(move || {
        for stream in listener.incoming() {
            if let Ok(mut s) = stream {
                let mut buf = [0; 6];
                if s.read(&mut buf).is_ok() {
                    let _ = tx.send(());
                }
            }
        }
    });

    write_state("starting", "-");

    let mut conn = HyprlandConnection::new();
    let mut last_mode = None;
    let mut gslapper_running = is_process_running("gslapper");
    let mut load_state = LoadState { idle_streak: 0 };

    loop {
        let current_mode = determine_mode(&mut conn, last_mode, &mut load_state);
        
        if Some(current_mode) != last_mode {
            apply_mode(&mut conn, current_mode, last_mode);
            last_mode = Some(current_mode);
        }

        // Always re-assert the profile even if the mode is unchanged, so any
        // external override (e.g. sysmode forcing performance) is corrected.
        assert_power_profile(current_mode);
        write_state(current_mode.name(), current_mode.profile());

        // Handle wallpaper separately as it depends on fullscreen too
        gslapper_running = manage_ui_elements(current_mode, gslapper_running, &mut conn);

        // Sleep for 15 seconds, or wake up early if a signal is received on the channel
        match rx.recv_timeout(Duration::from_secs(15)) {
            Ok(_) => println!("Woke up early due to IPC signal"),
            Err(mpsc::RecvTimeoutError::Timeout) => {},
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    
    let _ = std::fs::remove_file(&lock_socket_path);
    let _ = std::fs::remove_file(state_path());
}

fn get_cpu_temp() -> Option<f64> {
    let zones = fs::read_dir("/sys/class/thermal").ok()?;
    for entry in zones.flatten() {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let type_path = dir.join("type");
        let type_str = fs::read_to_string(type_path).unwrap_or_default();
        if type_str.trim() == "x86_pkg_temp" {
            let temp_str = fs::read_to_string(dir.join("temp")).ok()?;
            if let Ok(milli) = temp_str.trim().parse::<f64>() {
                return Some(milli / 1000.0);
            }
            return None;
        }
    }
    None
}

/// Check if there has been recent keyboard or mouse input activity.
/// Reads non-blocking from /dev/input/event* devices using poll().
fn has_input_activity() -> bool {
    use std::os::unix::io::AsRawFd;

    let Ok(dir) = fs::read_dir("/dev/input") else {
        return false;
    };
    for entry in dir.flatten() {
        let path = entry.path();
        if !path.file_name().and_then(|n| n.to_str()).map_or(false, |s| s.starts_with("event")) {
            continue;
        }
        let Ok(dev) = Device::open(&path) else {
            continue;
        };
        let dominated_name = dev.name().map(|n| n.to_lowercase());
        let dominated = dominated_name.as_deref().unwrap_or("");
        let is_keyboard = dominated.contains("keyboard") || dominated.contains("kbd");
        let is_mouse = dominated.contains("mouse") || dominated.contains("logitech") || dominated.contains("bcm5974");
        if !is_keyboard && !is_mouse {
            continue;
        }
        // Use poll() with zero timeout to check for pending events without blocking
        let fd = dev.as_raw_fd();
        let mut pollfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let ret = unsafe { libc::poll(&mut pollfd, 1, 0) };
        if ret > 0 && (pollfd.revents & libc::POLLIN) != 0 {
            return true;
        }
    }
    false
}

fn determine_mode(conn: &mut HyprlandConnection, last_mode: Option<PowerMode>, state: &mut LoadState) -> PowerMode {
    let ac_online = ac_online();

    let gaming_active = is_gaming_mode();

    // Thermal guard: hold throttled while hot, with hysteresis
    if let Some(temp) = get_cpu_temp() {
        let in_thermal = last_mode == Some(PowerMode::Thermal);
        if in_thermal && temp > THERMAL_RECOVER_TEMP {
            return PowerMode::Thermal;
        }
        let limit = if gaming_active { GAMING_THROTTLE_TEMP } else { THERMAL_THROTTLE_TEMP };
        if temp > limit {
            return PowerMode::Thermal;
        }
    }

    if !ac_online {
        // Only enter Idle (dimmed) mode after sustained inactivity on battery
        let cpu_pct = get_cpu_usage();
        let gpu_pct = get_gpu_utilization();
        let input_active = has_input_activity();
        let is_idle_now = !input_active && cpu_pct < CPU_IDLE_PCT && gpu_pct < GPU_IDLE_PCT && !is_heavy_load(conn);

        if is_idle_now {
            state.idle_streak += 1;
            if state.idle_streak >= IDLE_POLLS_REQUIRED {
                return PowerMode::Idle;
            }
        } else {
            state.idle_streak = 0;
        }
        return PowerMode::Battery;
    }

    // 2. Check Gaming Mode (IPC to Quickshell Caelestia)
    if gaming_active {
        state.idle_streak = 0;
        return PowerMode::Gaming;
    }

    // 3. Load sensing: heavy AI/compile/video work -> performance
    let heavy_window = is_heavy_load(conn);
    let cpu_pct = get_cpu_usage();
    let gpu_pct = get_gpu_utilization();
    let input_active = has_input_activity();

    let is_heavy = heavy_window || cpu_pct > CPU_HEAVY_PCT || gpu_pct > GPU_HEAVY_PCT;
    let is_idle = !input_active
        && !heavy_window
        && !is_fullscreen(conn)
        && cpu_pct < CPU_IDLE_PCT
        && gpu_pct < GPU_IDLE_PCT;

    if is_heavy {
        state.idle_streak = 0;
        return PowerMode::ACPerformance;
    }

    if is_idle {
        state.idle_streak += 1;
        if state.idle_streak >= IDLE_POLLS_REQUIRED {
            return PowerMode::Idle;
        }
        return PowerMode::ACBalanced;
    }

    // Middle ground: active but not heavy
    state.idle_streak = 0;
    PowerMode::ACBalanced
}

fn ac_online() -> bool {
    fs::read_to_string("/sys/class/power_supply/AC0/online")
        .map(|s| s.trim() == "1")
        .unwrap_or(false)
}

/// Instantaneous CPU busy% from /proc/stat deltas (~500ms sample).
fn get_cpu_usage() -> f64 {
    fn snapshot() -> Option<(u64, u64)> {
        let line = fs::read_to_string("/proc/stat").ok()?.lines().next()?.to_string();
        let nums: Vec<u64> = line
            .split_whitespace()
            .skip(1)
            .filter_map(|f| f.parse().ok())
            .collect();
        if nums.len() < 4 {
            return None;
        }
        let busy = nums[0] + nums[1] + nums[2];
        let total: u64 = nums.iter().sum();
        Some((busy, total))
    }

    let Some((busy1, total1)) = snapshot() else { return 0.0 };
    thread::sleep(Duration::from_millis(500));
    let Some((busy2, total2)) = snapshot() else { return 0.0 };

    let dt = total2.saturating_sub(total1);
    if dt == 0 {
        return 0.0;
    }
    ((busy2.saturating_sub(busy1)) as f64 / dt as f64) * 100.0
}

/// True while the dGPU is runtime-suspended. Asking nvidia-smi then would wake it (and keep it
/// awake, since we poll every 15 s), so callers treat a sleeping GPU as 0 % load.
fn dgpu_asleep() -> bool {
    fs::read_to_string("/sys/bus/pci/devices/0000:01:00.0/power/runtime_status")
        .map(|s| s.trim().starts_with("suspend"))
        .unwrap_or(false)
}

fn get_gpu_utilization() -> f64 {
    if dgpu_asleep() {
        return 0.0;
    }
    Command::new("nvidia-smi")
        .args(["--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"])
        .output()
        .ok()
        .and_then(|o| {
            if !o.status.success() {
                return None;
            }
            String::from_utf8_lossy(&o.stdout).trim().parse().ok()
        })
        .unwrap_or(0.0)
}

fn apply_mode(conn: &mut HyprlandConnection, mode: PowerMode, last_mode: Option<PowerMode>) {
    let now = Local::now().format("%Y-%m-%d %H:%M:%S");
    
    match mode {
        PowerMode::Battery => {
            println!("[{}] Switching to BATTERY mode", now);
            set_power_profile("power-saver");
            set_hyprland_monitor(conn, RES_LOW);
            disable_nvidia_gpu();
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
        PowerMode::ACBalanced => {
            println!("[{}] Switching to AC BALANCED mode", now);
            set_power_profile("balanced");
            set_hyprland_monitor(conn, RES_HIGH);
            enable_nvidia_gpu();
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
        PowerMode::ACPerformance => {
            println!("[{}] Switching to AC PERFORMANCE mode", now);
            set_power_profile("performance");
            set_hyprland_monitor(conn, RES_HIGH);
            enable_nvidia_gpu();
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
        PowerMode::Idle => {
            println!("[{}] Switching to IDLE mode", now);
            set_power_profile("power-saver");
            set_hyprland_monitor(conn, RES_HIGH);
            disable_nvidia_gpu();
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
        PowerMode::Gaming => {
            println!("[{}] Switching to GAMING mode", now);
            set_power_profile("performance");
            set_hyprland_monitor(conn, RES_HIGH);
            enable_nvidia_gpu();
            toggle_gaming_optimizations(conn, true);
        }
        PowerMode::Thermal => {
            println!("[{}] Switching to THERMAL mode", now);
            // Keep power-saver on battery even under thermal hold
            set_power_profile(if ac_online() { THERMAL_PROFILE } else { "power-saver" });
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
    }
}

fn set_power_profile(profile: &str) {
    let _ = Command::new("powerprofilesctl").args(["set", profile]).status();
}

/// Re-assert the power profile for the current mode so external overrides
/// (e.g. sysmode forcing performance on battery) get reverted next poll.
fn assert_power_profile(mode: PowerMode) {
    set_power_profile(mode.profile());
}

fn set_hyprland_monitor(conn: &mut HyprlandConnection, resolution: &str) {
    let arg = format!("eval hl.monitor({{ output = '{}', mode = '{}', position = '0x0', scale = 1 }})", MONITOR, resolution);
    if let Err(e) = conn.send_cmd(&arg) {
        eprintln!("Failed to set monitor resolution via socket: {}", e);
    }
}

fn disable_nvidia_gpu() {
    let pm_paths = [
        "/sys/bus/pci/devices/0000:01:00.0/power/control",
        "/sys/bus/pci/devices/0000:01:00.1/power/control",
    ];
    for pm_path in pm_paths {
        if fs::metadata(pm_path).is_ok() {
            let _ = fs::write(pm_path, "auto");
        }
    }
}

fn enable_nvidia_gpu() {
    let pm_paths = [
        "/sys/bus/pci/devices/0000:01:00.0/power/control",
        "/sys/bus/pci/devices/0000:01:00.1/power/control",
    ];
    for pm_path in pm_paths {
        if fs::metadata(pm_path).is_ok() {
            let _ = fs::write(pm_path, "on");
        }
    }
}

fn is_gaming_mode() -> bool {
    // gamemoded (Steam/Lutris launch options, `gamemoderun`) works under any shell...
    let gamemoded = Command::new("gamemoded")
        .arg("-s")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase().contains("is active"))
        .unwrap_or(false);
    if gamemoded {
        return true;
    }
    // ...and the old caelestia game-mode toggle still counts when that shell is running.
    Command::new("qs")
        .args(["-c", "caelestia", "ipc", "call", "gameMode", "isEnabled"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase().contains("true"))
        .unwrap_or(false)
}

fn toggle_gaming_optimizations(conn: &mut HyprlandConnection, enable: bool) {
    if enable {
        let _ = conn.send_cmd("eval hl.config({ animations = { enabled = false }, decoration = { blur = { enabled = false }, shadow = { enabled = false } }, misc = { vrr = 1 }, render = { direct_scanout = true } })");
        
        // Pause apps
        for app in PAUSE_APPS {
            let _ = Command::new("pkill").args(["-STOP", "-x", app]).status();
        }
    } else {
        let _ = conn.send_cmd("eval hl.config({ animations = { enabled = true }, decoration = { blur = { enabled = true }, shadow = { enabled = false } } })");
        
        // Resume apps
        for app in PAUSE_APPS {
            let _ = Command::new("pkill").args(["-CONT", "-x", app]).status();
        }
    }
}

fn manage_ui_elements(mode: PowerMode, mut gslapper_running: bool, conn: &mut HyprlandConnection) -> bool {
    if !live_wallpaper_enabled() {
        return gslapper_running;
    }
    let home = std::env::var("HOME").unwrap();
    let disabled_file = format!("{}/.local/state/livewallpaper_disabled", home);
    let manually_disabled = std::path::Path::new(&disabled_file).exists();

    let should_wallpaper_run = !manually_disabled && mode != PowerMode::Battery && mode != PowerMode::Gaming && mode != PowerMode::Thermal && mode != PowerMode::Idle && !is_fullscreen(conn);
    
    if should_wallpaper_run {
        if !gslapper_running || !is_process_running("gslapper") {
            let live_dir = format!("{}/Pictures/Wallpapers/live", home);
            let wallpaper_path = pick_random_wallpaper(&live_dir);
            
            let xdg_runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/run/user/1000".to_string());
            let wayland_display = std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| {
                if std::path::Path::new(&format!("{}/wayland-1", xdg_runtime)).exists() {
                    "wayland-1".to_string()
                } else if std::path::Path::new(&format!("{}/wayland-0", xdg_runtime)).exists() {
                    "wayland-0".to_string()
                } else {
                    "wayland-1".to_string()
                }
            });

            let status = Command::new("gslapper")
                .env("XDG_RUNTIME_DIR", &xdg_runtime)
                .env("WAYLAND_DISPLAY", &wayland_display)
                .args(["--fork", "--cache-size", "16", "-l", "background", "-o", "no-audio loop fill", MONITOR, &wallpaper_path])
                .status();
            
            if status.map(|s| s.success()).unwrap_or(false) {
                gslapper_running = true;
                // Update the Hyprland scheme primary color to match the wallpaper
                update_scheme_primary(&wallpaper_path);
            }
        }
    } else {
        if gslapper_running {
            let _ = Command::new("pkill").args(["-9", "gslapper"]).status();
            gslapper_running = false;
        }
    }
    gslapper_running
}

fn pick_random_wallpaper(dir: &str) -> String {
    let extensions = ["mp4", "mkv", "webm"];
    let mut videos: Vec<String> = Vec::new();
    
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                if extensions.contains(&ext.to_lowercase().as_str()) {
                    if let Some(path_str) = path.to_str() {
                        videos.push(path_str.to_string());
                    }
                }
            }
        }
    }
    
    if let Some(chosen) = videos.choose(&mut rand::thread_rng()) {
        chosen.clone()
    } else {
        // Fallback to the default if no videos found
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/netrunner".to_string());
        format!("{}/Pictures/Wallpapers/jinx-mayhem-in-arcane.3840x2160.mp4", home)
    }
}

fn is_process_running(name: &str) -> bool {
    Command::new("pgrep").arg("-x").arg(name).output().map(|o| o.status.success()).unwrap_or(false)
}

fn is_fullscreen(conn: &mut HyprlandConnection) -> bool {
    if let Ok(output) = conn.send_cmd("j/monitors") {
        if let Ok(monitors) = serde_json::from_str::<Vec<HyprMonitor>>(&output) {
            return monitors.iter().any(|m| m.solitary != "0");
        }
    }
    false
}

fn is_heavy_load(conn: &mut HyprlandConnection) -> bool {
    let heavy_classes = ["steam_app", "gamescope", "Lutris", "heroic", "Minecraft", "Blender"];
    if let Ok(output) = conn.send_cmd("j/clients") {
        if let Ok(clients) = serde_json::from_str::<Vec<HyprClient>>(&output) {
            return clients.iter().any(|c| {
                heavy_classes.iter().any(|&h| c.class.contains(h))
            });
        }
    }
    false
}

/// Extract the dominant color from a video file using ffmpeg.
/// Takes a frame at the given timestamp and computes the average RGB.
fn get_dominant_color_from_video(video_path: &str) -> (u8, u8, u8) {
    // Take a frame at 2 seconds into the video
    let timestamp = "00:00:02";
    let output = Command::new("ffmpeg")
        .args([
            "-v", "quiet",
            "-ss", timestamp,
            "-i", video_path,
            "-vframes", "1",
 "-vsync", "vfr",
            "-f", "image2",
            "-",
        ])
        .output();

    let Some(output) = output.ok().and_then(|o| {
        if o.status.success() {
            Some(o.stdout)
        } else {
            None
        }
    }) else {
        return (248, 184, 157); // fallback peach color
    };

    // Calculate average color from the PPM data
    let stdout = String::from_utf8_lossy(&output);
    // PPM format: P6\nwidth height\n255\npixel data
    let lines: Vec<&str> = stdout.lines().collect();
    if lines.len() >= 4 {
        let mut r_total: u32 = 0;
        let mut g_total: u32 = 0;
        let mut b_total: u32 = 0;
        let mut pixel_count: u32 = 0;

        // Skip header lines, pixel data starts after "255\n"
        let mut start_idx = 3;
        if lines.get(3).map_or(false, |l| *l == "255") {
            start_idx = 4;
        }

        for line in lines.iter().skip(start_idx) {
            let bytes = line.as_bytes();
            if bytes.len() >= 3 && pixel_count < 1000 { // limit for performance
                r_total = r_total + bytes[0] as u32;
                g_total = g_total + bytes[1] as u32;
                b_total = b_total + bytes[2] as u32;
                pixel_count += 1;
            }
        }

        if pixel_count > 0 {
            let r = (r_total / pixel_count) as u8;
            let g = (g_total / pixel_count) as u8;
            let b = (b_total / pixel_count) as u8;
            return (r, g, b);
        }
    }
    (248, 184, 157) // fallback peach color
}

/// Update the Hyprland scheme primary color.
fn update_scheme_primary(video_path: &str) {
    let (r, g, b) = get_dominant_color_from_video(video_path);
    let hex_format = format!("{:02x}{:02x}{:02x}", r, g, b);

    let home = std::env::var("HOME").unwrap();
    let scheme_path = format!("{}/.config/hypr/scheme/current.lua", home);

    if let Ok(content) = fs::read_to_string(&scheme_path) {
        let new_primary = format!("    primary = \"{}\",\n", hex_format);
        let new_content = content.replace(
            "    primary = \"",
            &new_primary,
        );

        if let Ok(_) = fs::write(&scheme_path, &new_content) {
            println!("[POWER] Updated scheme primary color to {} ({})", hex_format, video_path);
        }
    }
}
