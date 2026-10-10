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

const DEFAULT_MONITOR: &str = "eDP-1";
const DEFAULT_RES_HIGH: &str = "1920x1080@144";
const DEFAULT_RES_LOW: &str = "1920x1080@60";


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

#[derive(Deserialize, Debug)]
struct HyprMonitor {
    #[serde(default)]
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
    last_cpu: Option<(u64, u64)>,
    input_devices: Option<Vec<Device>>,
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
    let mut load_state = LoadState {
        idle_streak: 0,
        last_cpu: cpu_snapshot(),
        input_devices: None,
    };

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
    // 1. Check hwmon for dedicated CPU temperature drivers (AMD k10temp, Intel coretemp)
    if let Ok(hwmon_entries) = fs::read_dir("/sys/class/hwmon") {
        for entry in hwmon_entries.flatten() {
            let dir = entry.path();
            let name = fs::read_to_string(dir.join("name")).unwrap_or_default();
            let name_trimmed = name.trim();
            if name_trimmed == "k10temp" || name_trimmed == "coretemp" {
                for temp_file in &["temp1_input", "temp2_input"] {
                    if let Ok(temp_str) = fs::read_to_string(dir.join(temp_file)) {
                        if let Ok(milli) = temp_str.trim().parse::<f64>() {
                            if milli > 0.0 && milli < 150000.0 {
                                return Some(milli / 1000.0);
                            }
                        }
                    }
                }
            }
        }
    }

    // 2. Fall back to thermal zones (x86_pkg_temp, k10temp, Tctl, acpitz, etc.)
    if let Ok(zones) = fs::read_dir("/sys/class/thermal") {
        let mut max_temp: Option<f64> = None;
        for entry in zones.flatten() {
            let dir = entry.path();
            if !dir.is_dir() {
                continue;
            }
            let type_str = fs::read_to_string(dir.join("type")).unwrap_or_default();
            let t = type_str.trim();
            if t == "x86_pkg_temp" || t == "k10temp" || t == "Tctl" || t == "acpitz" || t.contains("cpu") {
                if let Ok(temp_str) = fs::read_to_string(dir.join("temp")) {
                    if let Ok(milli) = temp_str.trim().parse::<f64>() {
                        let c = milli / 1000.0;
                        if c > 0.0 && c < 150.0 {
                            if t == "x86_pkg_temp" || t == "k10temp" || t == "Tctl" {
                                return Some(c);
                            }
                            max_temp = Some(max_temp.map_or(c, |m| m.max(c)));
                        }
                    }
                }
            }
        }
        if max_temp.is_some() {
            return max_temp;
        }
    }
    None
}

/// Check if there has been recent keyboard or mouse input activity.
/// Keeps evdev descriptors open across polls to catch buffered events without open/close thrashing.
fn check_input_activity(state: &mut LoadState) -> bool {
    use std::os::unix::io::AsRawFd;

    // If hypridle dimmed the screen, we are definitely idle
    if std::path::Path::new("/dev/shm/halcyon-dim").exists() {
        return false;
    }

    if state.input_devices.is_none() {
        let mut devs = Vec::new();
        if let Ok(dir) = fs::read_dir("/dev/input") {
            for entry in dir.flatten() {
                let path = entry.path();
                if !path.file_name().and_then(|n| n.to_str()).map_or(false, |s| s.starts_with("event")) {
                    continue;
                }
                if let Ok(dev) = Device::open(&path) {
                    let dominated_name = dev.name().map(|n| n.to_lowercase());
                    let dominated = dominated_name.as_deref().unwrap_or("");
                    let is_keyboard = dominated.contains("keyboard") || dominated.contains("kbd");
                    let is_mouse = dominated.contains("mouse") || dominated.contains("logitech") || dominated.contains("bcm5974") || dominated.contains("touchpad");
                    if is_keyboard || is_mouse {
                        devs.push(dev);
                    }
                }
            }
        }
        state.input_devices = Some(devs);
    }

    let mut had_activity = false;
    let mut device_error = false;
    if let Some(devs) = &mut state.input_devices {
        for dev in devs.iter_mut() {
            let fd = dev.as_raw_fd();
            let mut pollfd = libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            };
            let ret = unsafe { libc::poll(&mut pollfd, 1, 0) };
            if ret > 0 {
                if (pollfd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL)) != 0 {
                    device_error = true;
                }
                if (pollfd.revents & libc::POLLIN) != 0 {
                    had_activity = true;
                    if let Ok(mut events) = dev.fetch_events() {
                        while events.next().is_some() {}
                    }
                }
            }
        }
    }
    if device_error {
        state.input_devices = None;
    }
    had_activity
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

    // Gaming mode
    if gaming_active {
        state.idle_streak = 0;
        return PowerMode::Gaming;
    }

    // Sample telemetry once per cycle
    let cpu_pct = get_cpu_usage(state);
    let gpu_pct = get_gpu_utilization();
    let input_active = check_input_activity(state);
    let heavy_window = is_heavy_load(conn);

    if !ac_online {
        // Only enter Idle (dimmed) mode after sustained inactivity on battery
        let is_idle_now = !input_active && cpu_pct < CPU_IDLE_PCT && gpu_pct < GPU_IDLE_PCT && !heavy_window;

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

    // AC mode - Load sensing: heavy AI/compile/video work -> performance
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
    let Ok(entries) = fs::read_dir("/sys/class/power_supply") else {
        return false;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        let is_ac = name.starts_with("AC") || name.starts_with("ADP") || {
            let type_path = path.join("type");
            fs::read_to_string(type_path)
                .map(|t| t.trim().eq_ignore_ascii_case("Mains"))
                .unwrap_or(false)
        };
        if is_ac {
            let online_path = path.join("online");
            if let Ok(status) = fs::read_to_string(online_path) {
                if status.trim() == "1" {
                    return true;
                }
            }
        }
    }
    false
}

fn cpu_snapshot() -> Option<(u64, u64)> {
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

/// Instantaneous CPU busy% from /proc/stat deltas across poll intervals (no thread::sleep).
fn get_cpu_usage(state: &mut LoadState) -> f64 {
    let Some(curr) = cpu_snapshot() else { return 0.0 };
    let prev = state.last_cpu.replace(curr);
    let Some((busy1, total1)) = prev else {
        return 0.0;
    };
    let (busy2, total2) = curr;
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

fn get_monitor_config(conn: &mut HyprlandConnection) -> (String, String, String) {
    if let Ok(output) = conn.send_cmd("j/monitors") {
        if let Ok(monitors) = serde_json::from_str::<Vec<serde_json::Value>>(&output) {
            let mon = monitors.iter().find(|m| {
                m["name"].as_str().map_or(false, |n| n.starts_with("eDP"))
            }).or_else(|| monitors.first());

            if let Some(m) = mon {
                let name = m["name"].as_str().unwrap_or(DEFAULT_MONITOR).to_string();
                let width = m["width"].as_u64().unwrap_or(1920);
                let height = m["height"].as_u64().unwrap_or(1080);
                
                let mut max_hz = 144u64;
                if let Some(modes) = m["availableModes"].as_array() {
                    for mode_val in modes {
                        if let Some(mode_str) = mode_val.as_str() {
                            if let Some(at_idx) = mode_str.find('@') {
                                if let Some(hz_str) = mode_str[at_idx + 1..].split('.').next() {
                                    if let Ok(hz) = hz_str.parse::<u64>() {
                                        if hz > max_hz {
                                            max_hz = hz;
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else if let Some(rr) = m["refreshRate"].as_f64() {
                    max_hz = rr.round() as u64;
                }

                let high = format!("{}x{}@{}", width, height, max_hz);
                let low = format!("{}x{}@60", width, height);
                return (name, high, low);
            }
        }
    }
    (DEFAULT_MONITOR.to_string(), DEFAULT_RES_HIGH.to_string(), DEFAULT_RES_LOW.to_string())
}

fn set_hyprland_monitor(conn: &mut HyprlandConnection, high_refresh: bool) {
    let (monitor_name, res_high, res_low) = get_monitor_config(conn);
    let resolution = if high_refresh { res_high } else { res_low };
    let arg = format!("eval hl.monitor({{ output = '{}', mode = '{}', position = '0x0', scale = 1 }})", monitor_name, resolution);
    if let Err(e) = conn.send_cmd(&arg) {
        eprintln!("Failed to set monitor resolution via socket: {}", e);
    }
}

fn apply_mode(conn: &mut HyprlandConnection, mode: PowerMode, last_mode: Option<PowerMode>) {
    let now = Local::now().format("%Y-%m-%d %H:%M:%S");
    
    match mode {
        PowerMode::Battery => {
            println!("[{}] Switching to BATTERY mode", now);
            set_power_profile("power-saver");
            set_hyprland_monitor(conn, false);
            disable_nvidia_gpu();
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
        PowerMode::ACBalanced => {
            println!("[{}] Switching to AC BALANCED mode", now);
            set_power_profile("balanced");
            set_hyprland_monitor(conn, true);
            enable_nvidia_gpu();
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
        PowerMode::ACPerformance => {
            println!("[{}] Switching to AC PERFORMANCE mode", now);
            set_power_profile("performance");
            set_hyprland_monitor(conn, true);
            enable_nvidia_gpu();
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
        PowerMode::Idle => {
            println!("[{}] Switching to IDLE mode", now);
            set_power_profile("power-saver");
            set_hyprland_monitor(conn, true);
            disable_nvidia_gpu();
            if last_mode == Some(PowerMode::Gaming) {
                toggle_gaming_optimizations(conn, false);
            }
        }
        PowerMode::Gaming => {
            println!("[{}] Switching to GAMING mode", now);
            set_power_profile("performance");
            set_hyprland_monitor(conn, true);
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

/// `~/.config/Halcyon/gpu-mode` says `dgpu` (scripts/gpu-mode.sh): the NVIDIA GPU draws the desktop, so it must never be
/// runtime-suspended, on battery or not.
fn dgpu_mode() -> bool {
    let home = std::env::var("HOME").unwrap_or_default();
    fs::read_to_string(format!("{home}/.config/Halcyon/gpu-mode"))
        .map(|s| s.trim() == "dgpu")
        .unwrap_or(false)
}

fn disable_nvidia_gpu() {
    if dgpu_mode() {
        enable_nvidia_gpu();
        return;
    }
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
    // 1. Check Halcyon gamemode state in /dev/shm/halcyon-gamemode (instant, no subprocess)
    if std::path::Path::new("/dev/shm/halcyon-gamemode").exists() {
        return true;
    }
    // 2. gamemoded (Steam/Lutris launch options, `gamemoderun`) works under any shell...
    let gamemoded = Command::new("gamemoded")
        .arg("-s")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_lowercase().contains("is active"))
        .unwrap_or(false);
    if gamemoded {
        return true;
    }
    false
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

fn get_user_home() -> String {
    if let Ok(h) = std::env::var("HOME") {
        if !h.is_empty() && h != "/root" {
            return h;
        }
    }
    if let Ok(content) = fs::read_to_string("/etc/sysmode.conf") {
        for line in content.lines() {
            if let Some(rest) = line.trim().strip_prefix("SYS_HOME=") {
                let path = rest.trim().trim_matches('"').trim_matches('\'');
                if !path.is_empty() {
                    return path.to_string();
                }
            }
        }
    }
    std::env::var("HOME").unwrap_or_else(|_| "/home/sushanth".to_string())
}

fn manage_ui_elements(mode: PowerMode, mut gslapper_running: bool, conn: &mut HyprlandConnection) -> bool {
    if !live_wallpaper_enabled() {
        return gslapper_running;
    }
    let home = get_user_home();
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

            let (monitor_name, _, _) = get_monitor_config(conn);
            let status = Command::new("gslapper")
                .env("XDG_RUNTIME_DIR", &xdg_runtime)
                .env("WAYLAND_DISPLAY", &wayland_display)
                .args(["--fork", "--cache-size", "16", "-l", "background", "-o", "no-audio loop fill", &monitor_name, &wallpaper_path])
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
        let home = get_user_home();
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
    let fallback = (248, 184, 157); // fallback peach color
    let timestamp = "00:00:02";
    let output = Command::new("ffmpeg")
        .args([
            "-v", "quiet",
            "-ss", timestamp,
            "-i", video_path,
            "-vframes", "1",
            "-vsync", "vfr",
            "-f", "image2pipe",
            "-vcodec", "ppm",
            "-",
        ])
        .output();

    let Ok(out) = output else { return fallback; };
    if !out.status.success() || out.stdout.len() < 16 {
        return fallback;
    }

    let data = &out.stdout;
    if !data.starts_with(b"P6") {
        return fallback;
    }

    // Parse PPM header tokens (magic, width, height, maxval)
    let mut idx = 2;
    let mut tokens = 0;
    while idx < data.len() && tokens < 3 {
        // Skip whitespace and comments
        while idx < data.len() && (data[idx].is_ascii_whitespace() || data[idx] == b'#') {
            if data[idx] == b'#' {
                while idx < data.len() && data[idx] != b'\n' {
                    idx += 1;
                }
            } else {
                idx += 1;
            }
        }
        if idx >= data.len() {
            break;
        }
        // Read token
        while idx < data.len() && !data[idx].is_ascii_whitespace() {
            idx += 1;
        }
        tokens += 1;
    }

    // Skip the single whitespace character after maxval
    if idx < data.len() && data[idx].is_ascii_whitespace() {
        idx += 1;
    }

    let pixels = &data[idx..];
    if pixels.len() < 3 {
        return fallback;
    }

    let mut r_total: u64 = 0;
    let mut g_total: u64 = 0;
    let mut b_total: u64 = 0;
    let mut count: u64 = 0;

    let step = (pixels.len() / 3 / 2000).max(1) * 3;
    let mut i = 0;
    while i + 2 < pixels.len() {
        r_total += pixels[i] as u64;
        g_total += pixels[i + 1] as u64;
        b_total += pixels[i + 2] as u64;
        count += 1;
        i += step;
    }

    if count > 0 {
        ((r_total / count) as u8, (g_total / count) as u8, (b_total / count) as u8)
    } else {
        fallback
    }
}

/// Update the Hyprland scheme primary color.
fn update_scheme_primary(video_path: &str) {
    let (r, g, b) = get_dominant_color_from_video(video_path);
    let hex_format = format!("{:02x}{:02x}{:02x}", r, g, b);

    let home = get_user_home();
    let scheme_paths = [
        format!("{}/.config/Halcyon/scheme/current.lua", home),
        format!("{}/.config/hypr/scheme/current.lua", home),
    ];

    for scheme_path in &scheme_paths {
        if let Ok(content) = fs::read_to_string(scheme_path) {
            let mut new_lines = Vec::new();
            let mut matched = false;
            for line in content.lines() {
                let trimmed = line.trim_start();
                if trimmed.starts_with("primary") && trimmed.contains('=') {
                    new_lines.push(format!("    primary         = \"#{}\",", hex_format));
                    matched = true;
                } else {
                    new_lines.push(line.to_string());
                }
            }
            if matched {
                let new_content = new_lines.join("\n") + "\n";
                if fs::write(scheme_path, &new_content).is_ok() {
                    println!("[POWER] Updated scheme primary color to #{} in {}", hex_format, scheme_path);
                }
            }
        }
    }
}
