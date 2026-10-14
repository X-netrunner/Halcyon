//! Halcyon Auto power manager.
//!
//! Wakes every 15 s (or immediately when a second instance pings the lock socket), works out the
//! right power mode from AC state, temperature, CPU/GPU load, input activity and what is on screen,
//! and applies it: power-profiles-daemon profile, Hyprland refresh rate, NVIDIA runtime PM and the
//! gaming tweaks. The current mode is published to `$XDG_RUNTIME_DIR/power-manager.state` for the island.
//!
//! Design notes (why it is cheap):
//!   * one thread, one `poll(2)` sleep that also watches the IPC socket and a signalfd
//!   * sysfs paths (AC, temperature) are discovered once and cached, not rescanned every poll
//!   * `/proc/stat` is only read for its first line; all small reads use stack buffers
//!   * Hyprland JSON is scanned in place (no parser, no allocation per field) and only queried
//!     when the answer can still change the decision
//!   * child processes (`powerprofilesctl`, `nvidia-smi`) are spawned only when really needed
//!   * only dependency is `libc`

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------------------------------

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

/// Consecutive quiet polls before dropping to Idle (~45 s).
const IDLE_POLLS_REQUIRED: u32 = 3;
const POLL_MS: i32 = 15_000;
/// Re-enumerate input devices every N polls (~5 min) so hot-plugged mice/keyboards are picked up.
const RESCAN_POLLS: u32 = 20;
/// Ignore CPU deltas covering fewer than this many jiffies (an early wake-up would give noisy percentages).
const MIN_CPU_TICKS: u64 = 100;
/// nvidia-smi costs ~0.2 s of CPU per start: ask every Nth poll and reuse the answer.
const GPU_QUERY_EVERY: u32 = 3;

const PAUSE_APPS: &[&str] = &[
    "zen-bin", "spotify", "qbittorrent", "telegram-desktop", "code",
];
const HEAVY_CLASSES: &[&str] = &["steam_app", "gamescope", "Lutris", "heroic", "Minecraft", "Blender"];

const GAMEMODE_FLAG: &str = "/dev/shm/halcyon-gamemode";
const DIM_FLAG: &str = "/dev/shm/halcyon-dim";

const DGPU_CONTROL: [&str; 2] = [
    "/sys/bus/pci/devices/0000:01:00.0/power/control",
    "/sys/bus/pci/devices/0000:01:00.1/power/control",
];
const DGPU_STATUS: &str = "/sys/bus/pci/devices/0000:01:00.0/power/runtime_status";

// ---------------------------------------------------------------------------------------------
// Modes
// ---------------------------------------------------------------------------------------------

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
    fn profile(self, ac: bool) -> &'static str {
        match self {
            PowerMode::Battery | PowerMode::Idle => "power-saver",
            PowerMode::ACBalanced => "balanced",
            PowerMode::ACPerformance | PowerMode::Gaming => "performance",
            PowerMode::Thermal => if ac { THERMAL_PROFILE } else { "power-saver" },
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------------------------

/// Read a small file into a caller-provided buffer (no heap allocation) and return it trimmed.
fn read_trim<'a>(path: impl AsRef<Path>, buf: &'a mut [u8]) -> Option<&'a str> {
    let n = File::open(path).ok()?.read(buf).ok()?;
    std::str::from_utf8(&buf[..n]).ok().map(str::trim)
}

/// A sysfs millidegree file as degrees C, if it parses and is plausible.
fn read_milli_c(path: &Path) -> Option<f64> {
    let mut b = [0u8; 32];
    let milli: i64 = read_trim(path, &mut b)?.parse().ok()?;
    (milli > 0 && milli < 150_000).then(|| milli as f64 / 1000.0)
}

fn write_sysfs(path: &str, val: &str) {
    if let Ok(mut f) = OpenOptions::new().write(true).open(path) {
        let _ = f.write_all(val.as_bytes());
    }
}

/// XDG_RUNTIME_DIR, or /run/user/<this user's uid> when the service did not inherit it.
fn runtime_dir() -> String {
    std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }))
}

/// First PID whose /proc/<pid>/comm equals `name`.
fn find_pid(name: &str) -> Option<i32> {
    let mut b = [0u8; 32];
    for e in fs::read_dir("/proc").ok()?.flatten() {
        let fname = e.file_name();
        let Some(pid) = fname.to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
        if read_trim(e.path().join("comm"), &mut b) == Some(name) {
            return Some(pid);
        }
    }
    None
}

/// Send `sig` to every process of ours whose name is in PAUSE_APPS (one /proc pass, no pkill spawns).
/// `comm` is truncated to 15 bytes by the kernel, so long names are compared truncated too.
fn signal_apps(sig: i32) {
    let uid = unsafe { libc::getuid() };
    let Ok(rd) = fs::read_dir("/proc") else { return };
    let mut b = [0u8; 32];
    for e in rd.flatten() {
        let fname = e.file_name();
        let Some(pid) = fname.to_str().and_then(|s| s.parse::<i32>().ok()) else { continue };
        let Some(comm) = read_trim(e.path().join("comm"), &mut b) else { continue };
        if !PAUSE_APPS.iter().any(|a| comm == &a[..a.len().min(15)]) {
            continue;
        }
        if e.metadata().map_or(false, |m| m.uid() == uid) {
            unsafe { libc::kill(pid, sig) };
        }
    }
}

fn set_profile(profile: &str) {
    let _ = Command::new("powerprofilesctl")
        .args(["set", profile])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .status();
}

/// The profile the kernel is running right now (ACPI platform_profile, which power-profiles-daemon drives),
/// as a power-profiles-daemon name. None when the machine has no such file.
fn active_profile() -> Option<&'static str> {
    let mut b = [0u8; 32];
    match read_trim("/sys/firmware/acpi/platform_profile", &mut b)? {
        "low-power" | "quiet" | "cool" => Some("power-saver"),
        "balanced" | "balanced-performance" => Some("balanced"),
        "performance" => Some("performance"),
        _ => None,
    }
}

// ---------------------------------------------------------------------------------------------
// Minimal JSON scanning for Hyprland replies (their shape is fixed; a full parser is overkill)
// ---------------------------------------------------------------------------------------------

/// Next string value of `"key": "value"` at/after `*pos` (`pat` is the quoted key, e.g. `"\"class\""`).
fn next_str<'a>(json: &'a str, pat: &str, pos: &mut usize) -> Option<&'a str> {
    loop {
        let i = json.get(*pos..)?.find(pat)? + *pos;
        *pos = i + pat.len();
        let rest = json[*pos..].trim_start();
        let Some(rest) = rest.strip_prefix(':') else { continue };
        let Some(rest) = rest.trim_start().strip_prefix('"') else { continue };
        let end = rest.find('"')?;
        return Some(&rest[..end]);
    }
}

fn first_str<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let mut pos = 0;
    next_str(json, &format!("\"{key}\""), &mut pos)
}

fn num_field(obj: &str, key: &str) -> Option<f64> {
    let pat = format!("\"{key}\"");
    let rest = obj[obj.find(&pat)? + pat.len()..].trim_start().strip_prefix(':')?.trim_start();
    let end = rest
        .find(|c: char| !(c.is_ascii_digit() || c == '.' || c == '-'))
        .unwrap_or(rest.len());
    rest[..end].parse().ok()
}

/// The top-level `{...}` objects of a JSON array (string- and escape-aware).
fn top_objects(json: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let (mut depth, mut start, mut in_str, mut esc) = (0usize, 0usize, false, false);
    for (i, &c) in json.as_bytes().iter().enumerate() {
        if in_str {
            if esc {
                esc = false;
            } else if c == b'\\' {
                esc = true;
            } else if c == b'"' {
                in_str = false;
            }
            continue;
        }
        match c {
            b'"' => in_str = true,
            b'{' => {
                if depth == 0 {
                    start = i;
                }
                depth += 1;
            }
            b'}' if depth > 0 => {
                depth -= 1;
                if depth == 0 {
                    out.push(&json[start..=i]);
                }
            }
            _ => {}
        }
    }
    out
}

/// `j/clients`: is any window one of the heavy classes?
fn heavy_class_present(json: &str) -> bool {
    let mut pos = 0;
    while let Some(class) = next_str(json, "\"class\"", &mut pos) {
        if HEAVY_CLASSES.iter().any(|h| class.contains(h)) {
            return true;
        }
    }
    false
}

/// `j/monitors`: is any monitor showing a single (fullscreen) window?
fn any_solitary(json: &str) -> bool {
    let mut pos = 0;
    while let Some(v) = next_str(json, "\"solitary\"", &mut pos) {
        if v != "0" {
            return true;
        }
    }
    false
}

/// `j/monitors` -> (name, "WxH@maxHz", "WxH@60") for the internal panel (or the first monitor).
fn parse_monitor_config(json: &str) -> Option<(String, String, String)> {
    let (name, high, low, _, _) = parse_monitor_detail(json)?;
    Some((name, high, low))
}

/// `j/monitors` -> (name, "WxH@maxHz", "WxH@60", "XxY", scale) preserving multi-monitor position and HiDPI scale.
fn parse_monitor_detail(json: &str) -> Option<(String, String, String, String, f64)> {
    let objs = top_objects(json);
    let m = objs
        .iter()
        .copied()
        .find(|o| first_str(o, "name").is_some_and(|n| n.starts_with("eDP")))
        .or_else(|| objs.first().copied())?;

    let name = first_str(m, "name").unwrap_or(DEFAULT_MONITOR);
    let w = num_field(m, "width").unwrap_or(1920.0) as u64;
    let h = num_field(m, "height").unwrap_or(1080.0) as u64;
    let x = num_field(m, "x").unwrap_or(0.0) as i64;
    let y = num_field(m, "y").unwrap_or(0.0) as i64;
    let scale = num_field(m, "scale").unwrap_or(1.0);

    // Highest refresh rate offered at the current resolution ("1920x1080@144.00Hz" -> 144).
    let prefix = format!("{w}x{h}@");
    let modes = m
        .find("\"availableModes\"")
        .and_then(|i| {
            let s = &m[i..];
            s.get(s.find('[')?..s.find(']')?)
        })
        .unwrap_or("");
    let max_hz = modes
        .split('"')
        .skip(1)
        .step_by(2)
        .filter_map(|s| s.strip_prefix(prefix.as_str()))
        .filter_map(|r| {
            let end = r.find(|c: char| !c.is_ascii_digit()).unwrap_or(r.len());
            r[..end].parse::<u64>().ok()
        })
        .max()
        .or_else(|| num_field(m, "refreshRate").map(|r| r.round() as u64))
        .unwrap_or(144);

    Some((name.to_string(), format!("{w}x{h}@{max_hz}"), format!("{w}x{h}@60"), format!("{x}x{y}"), scale))
}

// ---------------------------------------------------------------------------------------------
// Hyprland socket
// ---------------------------------------------------------------------------------------------

fn find_hypr_socket(runtime: &str) -> Option<String> {
    let bases = [format!("{runtime}/hypr"), "/tmp/hypr".to_string()];
    if let Ok(sig) = std::env::var("HYPRLAND_INSTANCE_SIGNATURE") {
        for base in &bases {
            let p = format!("{base}/{sig}/.socket.sock");
            if UnixStream::connect(&p).is_ok() {
                return Some(p);
            }
        }
    }
    for base in &bases {
        let Ok(rd) = fs::read_dir(base) else { continue };
        for e in rd.flatten() {
            let p = format!("{}/{}/.socket.sock", base, e.file_name().to_string_lossy());
            if UnixStream::connect(&p).is_ok() {
                return Some(p);
            }
        }
    }
    None
}

fn hypr_send(path: &str, cmd: &str) -> io::Result<String> {
    let mut s = UnixStream::connect(path)?;
    s.set_read_timeout(Some(Duration::from_secs(2)))?;
    s.set_write_timeout(Some(Duration::from_secs(2)))?;
    s.write_all(cmd.as_bytes())?;
    let mut out = String::new();
    s.read_to_string(&mut out)?;
    Ok(out)
}

struct Hypr {
    runtime: String,
    path: Option<String>,
    monitor_cfg: Option<(String, String, String, String, f64)>,
}

impl Hypr {
    /// Send a command; on failure forget the socket path (Hyprland may have restarted) and retry once.
    fn query(&mut self, cmd: &str) -> Option<String> {
        for _ in 0..2 {
            if self.path.is_none() {
                self.path = find_hypr_socket(&self.runtime);
            }
            let path = self.path.as_deref()?;
            match hypr_send(path, cmd) {
                Ok(r) => return Some(r),
                Err(_) => self.path = None,
            }
        }
        None
    }

    fn heavy_window(&mut self) -> bool {
        self.query("j/clients").map_or(false, |j| heavy_class_present(&j))
    }

    fn fullscreen(&mut self) -> bool {
        self.query("j/monitors").map_or(false, |j| any_solitary(&j))
    }

    fn set_refresh(&mut self, high: bool) {
        // Disabled by default: changing monitor refresh rate triggers a full kernel DRM modeset,
        // which blanks/blacks out the screen for 1-2 seconds every time the system transitions
        // between idle and active modes. Enabled only when explicitly requested via HALCYON_DYNAMIC_REFRESH=1.
        if std::env::var("HALCYON_DYNAMIC_REFRESH").map(|v| v == "1").unwrap_or(false) {
            if let Some(cfg) = self.query("j/monitors").and_then(|j| parse_monitor_detail(&j)) {
                self.monitor_cfg = Some(cfg);
            }
            let (name, res_high, res_low, pos, scale) = self.monitor_cfg.as_ref().cloned().unwrap_or_else(|| {
                (DEFAULT_MONITOR.to_string(), DEFAULT_RES_HIGH.to_string(), DEFAULT_RES_LOW.to_string(), "0x0".to_string(), 1.0)
            });
            let res = if high { res_high } else { res_low };
            let cmd = format!(
                "eval hl.monitor({{ output = '{name}', mode = '{res}', position = '{pos}', scale = {scale} }})"
            );
            if self.query(&cmd).is_none() {
                eprintln!("Failed to set monitor mode via socket");
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Sensors (all cached / allocation-free on the hot path)
// ---------------------------------------------------------------------------------------------

/// AC adapter `online` files, discovered once (and again only if they stop being readable).
struct Ac {
    files: Vec<PathBuf>,
}

impl Ac {
    fn discover(&mut self) {
        self.files.clear();
        let Ok(rd) = fs::read_dir("/sys/class/power_supply") else { return };
        let mut b = [0u8; 16];
        for e in rd.flatten() {
            let dir = e.path();
            let name = e.file_name();
            let name = name.to_string_lossy();
            let is_ac = name.starts_with("AC")
                || name.starts_with("ADP")
                || name.starts_with("ucsi")
                || read_trim(dir.join("type"), &mut b).map_or(false, |t| {
                    t.eq_ignore_ascii_case("Mains") || t.eq_ignore_ascii_case("USB") || t.eq_ignore_ascii_case("USB_PD")
                });
            if is_ac {
                let online = dir.join("online");
                if online.exists() {
                    self.files.push(online);
                }
            }
        }
    }

    fn online(&mut self) -> bool {
        if self.files.is_empty() {
            self.discover();
        }
        let mut b = [0u8; 8];
        let mut readable = false;
        for f in &self.files {
            if let Some(s) = read_trim(f, &mut b) {
                readable = true;
                if s == "1" {
                    return true;
                }
            }
        }
        if !readable {
            self.files.clear();
        }
        false
    }
}

/// CPU package temperature. The sensor file(s) are found once; hot path is one tiny read.
struct Temp {
    files: Vec<PathBuf>,
}

impl Temp {
    fn discover(&mut self) {
        self.files.clear();
        let mut b = [0u8; 64];

        // 1. dedicated CPU drivers (AMD k10temp, Intel coretemp)
        if let Ok(rd) = fs::read_dir("/sys/class/hwmon") {
            for e in rd.flatten() {
                let dir = e.path();
                let Some(name) = read_trim(dir.join("name"), &mut b) else { continue };
                if name == "k10temp" || name == "coretemp" {
                    for t in ["temp1_input", "temp2_input"] {
                        let p = dir.join(t);
                        if read_milli_c(&p).is_some() {
                            self.files.push(p);
                            return;
                        }
                    }
                }
            }
        }

        // 2. thermal zones: a package sensor wins outright, otherwise the hottest of the candidates
        let Ok(rd) = fs::read_dir("/sys/class/thermal") else { return };
        let mut others = Vec::new();
        for e in rd.flatten() {
            let dir = e.path();
            let Some(t) = read_trim(dir.join("type"), &mut b) else { continue };
            let preferred = matches!(t, "x86_pkg_temp" | "k10temp" | "Tctl");
            if preferred || t == "acpitz" || t.contains("cpu") {
                let p = dir.join("temp");
                if read_milli_c(&p).is_some() {
                    if preferred {
                        self.files = vec![p];
                        return;
                    }
                    others.push(p);
                }
            }
        }
        self.files = others;
    }

    fn read(&mut self) -> Option<f64> {
        if self.files.is_empty() {
            self.discover();
        }
        let hottest = self
            .files
            .iter()
            .filter_map(|p| read_milli_c(p))
            .fold(None, |acc: Option<f64>, c| Some(acc.map_or(c, |m| m.max(c))));
        if hottest.is_none() {
            self.files.clear(); // sensor vanished: rediscover next poll
        }
        hottest
    }
}

/// (busy, total) jiffies from the first line of /proc/stat.
fn parse_cpu_line(line: &str) -> Option<(u64, u64)> {
    let (mut busy, mut total, mut n) = (0u64, 0u64, 0usize);
    for f in line.split_ascii_whitespace().skip(1) {
        if let Ok(v) = f.parse::<u64>() {
            if n < 3 {
                busy += v; // user + nice + system
            }
            total += v;
            n += 1;
        }
    }
    (n >= 4).then_some((busy, total))
}

fn cpu_snapshot() -> Option<(u64, u64)> {
    let mut b = [0u8; 512]; // the first line is ~100 bytes; the rest of /proc/stat (huge "intr" line) is never read
    parse_cpu_line(read_trim("/proc/stat", &mut b)?.lines().next()?)
}

struct Cpu {
    prev: Option<(u64, u64)>,
    last_pct: f64,
}

impl Cpu {
    /// Busy % since the previous accepted sample (no sleeping, deltas across poll intervals).
    fn usage(&mut self) -> f64 {
        let Some((busy2, total2)) = cpu_snapshot() else { return 0.0 };
        let Some((busy1, total1)) = self.prev else {
            self.prev = Some((busy2, total2));
            return 0.0;
        };
        let dt = total2.saturating_sub(total1);
        if dt < MIN_CPU_TICKS {
            return self.last_pct;
        }
        self.prev = Some((busy2, total2));
        self.last_pct = busy2.saturating_sub(busy1) as f64 / dt as f64 * 100.0;
        self.last_pct
    }
}

/// Dynamically locate the NVIDIA display controller (0x10de, class 0x03*) and its companion audio function.
fn discover_nvidia_pci() -> (Option<PathBuf>, Vec<PathBuf>) {
    let mut status_path = None;
    let mut control_paths = Vec::new();
    let mut b = [0u8; 32];
    if let Ok(rd) = fs::read_dir("/sys/bus/pci/devices") {
        for e in rd.flatten() {
            let p = e.path();
            if read_trim(p.join("vendor"), &mut b) == Some("0x10de") {
                let ctrl = p.join("power/control");
                if ctrl.exists() {
                    control_paths.push(ctrl);
                }
                if status_path.is_none() && read_trim(p.join("class"), &mut b).map_or(false, |c| c.starts_with("0x03")) {
                    let st = p.join("power/runtime_status");
                    if st.exists() {
                        status_path = Some(st);
                    }
                }
            }
        }
    }
    (status_path, control_paths)
}

/// True when there is no NVIDIA GPU or when the NVIDIA dGPU is runtime-suspended.
fn dgpu_asleep() -> bool {
    let mut b = [0u8; 32];
    let (status_path, _) = discover_nvidia_pci();
    match status_path {
        Some(st) => read_trim(&st, &mut b).map_or(false, |s| s.starts_with("suspend")),
        None => !Path::new(DGPU_STATUS).exists() || read_trim(DGPU_STATUS, &mut b).map_or(true, |s| s.starts_with("suspend")),
    }
}

fn query_nvidia() -> f64 {
    Command::new("nvidia-smi")
        .args(["--query-gpu=utilization.gpu", "--format=csv,noheader,nounits"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8_lossy(&o.stdout).lines().next()?.trim().parse().ok())
        .unwrap_or(0.0)
}

struct Gpu {
    phase: u32,
    last: f64,
}

impl Gpu {
    fn util(&mut self) -> f64 {
        if dgpu_asleep() {
            self.phase = 0;
            self.last = 0.0;
            return 0.0;
        }
        if self.phase == 0 {
            self.last = query_nvidia();
        }
        self.phase = (self.phase + 1) % GPU_QUERY_EVERY;
        self.last
    }
}

/// Keyboard / mouse / touchpad activity. Descriptors stay open (non-blocking) across polls, all are
/// checked with a single poll(2), and pending events are drained so each poll only sees new input.
struct Input {
    devs: Vec<File>,
    pfds: Vec<libc::pollfd>,
    polls: u32,
}

impl Input {
    fn scan(&mut self) {
        self.devs.clear();
        if let Ok(rd) = fs::read_dir("/dev/input") {
            let mut b = [0u8; 128];
            for e in rd.flatten() {
                let fname = e.file_name();
                let Some(fname) = fname.to_str() else { continue };
                if !fname.starts_with("event") {
                    continue;
                }
                // same string EVIOCGNAME returns, without opening the device just to ask
                let Some(name) = read_trim(format!("/sys/class/input/{fname}/device/name"), &mut b) else { continue };
                let n = name.to_ascii_lowercase();
                let keyboard = n.contains("keyboard") || n.contains("kbd");
                let pointer = n.contains("mouse")
                    || n.contains("logitech")
                    || n.contains("bcm5974")
                    || n.contains("touchpad");
                if !(keyboard || pointer) {
                    continue;
                }
                if let Ok(f) = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(e.path()) {
                    self.devs.push(f);
                }
            }
        }
        self.pfds = self
            .devs
            .iter()
            .map(|f| libc::pollfd { fd: f.as_raw_fd(), events: libc::POLLIN, revents: 0 })
            .collect();
    }

    fn active(&mut self) -> bool {
        // If hypridle dimmed the screen, we are definitely idle
        if Path::new(DIM_FLAG).exists() {
            return false;
        }
        if self.polls == 0 {
            self.scan();
        }
        self.polls = self.polls.wrapping_add(1);

        let (mut activity, mut broken) = (false, false);
        if !self.pfds.is_empty() {
            for p in self.pfds.iter_mut() {
                p.revents = 0;
            }
            let n = unsafe { libc::poll(self.pfds.as_mut_ptr(), self.pfds.len() as libc::nfds_t, 0) };
            if n > 0 {
                for (i, p) in self.pfds.iter().enumerate() {
                    if p.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                        broken = true;
                    }
                    if p.revents & libc::POLLIN != 0 {
                        activity = true;
                        let mut buf = [0u8; 1536];
                        while let Ok(got) = self.devs[i].read(&mut buf) {
                            if got < buf.len() {
                                break;
                            }
                        }
                    }
                }
            }
        }
        // rescan after a device error (unplug) and periodically (hot-plug); after draining, so nothing is lost
        if broken || self.polls % RESCAN_POLLS == 0 {
            self.scan();
        }
        activity
    }
}

// ---------------------------------------------------------------------------------------------
// The daemon
// ---------------------------------------------------------------------------------------------

struct Daemon {
    mode: Option<PowerMode>,
    idle_streak: u32,
    prof_tick: u32,
    gamemoded_pid: Option<i32>,
    state_path: String,
    state_tmp: String,
    dgpu_mode_file: String,
    hypr: Hypr,
    ac: Ac,
    temp: Temp,
    cpu: Cpu,
    gpu: Gpu,
    input: Input,
}

impl Daemon {
    fn new(runtime: &str) -> Self {
        let home = std::env::var("HOME").unwrap_or_default();
        let state_path = format!("{runtime}/power-manager.state");
        Daemon {
            mode: None,
            idle_streak: 0,
            prof_tick: 0,
            gamemoded_pid: None,
            state_tmp: format!("{state_path}.tmp"),
            state_path,
            dgpu_mode_file: format!("{home}/.config/Halcyon/gpu-mode"),
            hypr: Hypr { runtime: runtime.to_string(), path: None, monitor_cfg: None },
            ac: Ac { files: Vec::new() },
            temp: Temp { files: Vec::new() },
            cpu: Cpu { prev: cpu_snapshot(), last_pct: 0.0 },
            gpu: Gpu { phase: 0, last: 0.0 },
            input: Input { devs: Vec::new(), pfds: Vec::new(), polls: 0 },
        }
    }

    /// "<mode> <profile> <unix-epoch>", rewritten every poll. The island reads it (via
    /// island/scripts/stats.sh) to know Auto is on and what it is doing; a file older than
    /// ~a minute counts as "daemon not running". Removed on clean exit.
    fn write_state(&self, mode: &str, profile: &str) {
        let epoch = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs());
        // write + rename so a reader never sees a half-written file
        if fs::write(&self.state_tmp, format!("{mode} {profile} {epoch}\n")).is_ok() {
            let _ = fs::rename(&self.state_tmp, &self.state_path);
        }
    }

    fn gaming_active(&mut self) -> bool {
        // Halcyon's own gamemode flag: instant, no process lookup
        if Path::new(GAMEMODE_FLAG).exists() {
            return true;
        }
        // gamemoded (Steam/Lutris launch options, `gamemoderun`) works under any shell
        let mut b = [0u8; 32];
        let running = match self.gamemoded_pid {
            Some(pid) if read_trim(format!("/proc/{pid}/comm"), &mut b) == Some("gamemoded") => true,
            _ => {
                self.gamemoded_pid = find_pid("gamemoded");
                self.gamemoded_pid.is_some()
            }
        };
        if !running {
            return false;
        }
        let need_check = self.mode == Some(PowerMode::Gaming) || self.prof_tick % 4 == 0;
        if !need_check {
            return false;
        }
        Command::new("gamemoded")
            .arg("-s")
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .map_or(false, |o| String::from_utf8_lossy(&o.stdout).to_lowercase().contains("is active"))
    }

    fn determine_mode(&mut self, ac: bool) -> PowerMode {
        let gaming = self.gaming_active();

        // Thermal guard: hold throttled while hot, with hysteresis
        if let Some(t) = self.temp.read() {
            let limit = if gaming { GAMING_THROTTLE_TEMP } else { THERMAL_THROTTLE_TEMP };
            let holding = self.mode == Some(PowerMode::Thermal) && t > THERMAL_RECOVER_TEMP;
            if holding || t > limit {
                return PowerMode::Thermal;
            }
        }

        if gaming {
            self.idle_streak = 0;
            return PowerMode::Gaming;
        }

        // Cheap telemetry every poll (the CPU delta and the input queue must be consumed each cycle) ...
        let cpu = self.cpu.usage();
        let gpu = self.gpu.util();
        let input = self.input.active();
        let quiet = cpu < CPU_IDLE_PCT && gpu < GPU_IDLE_PCT;

        // ... Hyprland is only asked when its answer can still change the outcome.
        if !ac {
            // Only enter Idle (dimmed) after sustained inactivity on battery
            if !input && quiet && !self.hypr.heavy_window() {
                self.idle_streak = (self.idle_streak + 1).min(IDLE_POLLS_REQUIRED);
                if self.idle_streak >= IDLE_POLLS_REQUIRED {
                    return PowerMode::Idle;
                }
            } else {
                self.idle_streak = 0;
            }
            return PowerMode::Battery;
        }

        // AC: heavy AI/compile/video work -> performance. (If we get past this, no heavy window exists.)
        if cpu > CPU_HEAVY_PCT || gpu > GPU_HEAVY_PCT || self.hypr.heavy_window() {
            self.idle_streak = 0;
            return PowerMode::ACPerformance;
        }
        if !input && quiet && !self.hypr.fullscreen() {
            self.idle_streak = (self.idle_streak + 1).min(IDLE_POLLS_REQUIRED);
            if self.idle_streak >= IDLE_POLLS_REQUIRED {
                return PowerMode::Idle;
            }
            return PowerMode::ACBalanced;
        }
        // Middle ground: active but not heavy
        self.idle_streak = 0;
        PowerMode::ACBalanced
    }

    /// Keep the power-profiles-daemon profile in line with the mode. `powerprofilesctl` is a Python
    /// script (~100 ms of CPU per start), so it only runs when the kernel says the profile differs
    /// (this also reverts external overrides, e.g. sysmode forcing performance). Without the
    /// platform_profile file it runs on a mode change and then every 8th poll (~2 min).
    fn sync_profile(&mut self, target: &str, changed: bool) {
        self.prof_tick = self.prof_tick.wrapping_add(1);
        let needed = match active_profile() {
            Some(p) => p != target,
            None => changed || self.prof_tick % 8 == 0,
        };
        if needed {
            set_profile(target);
        }
    }

    /// `~/.config/Halcyon/gpu-mode` says `dgpu` (scripts/gpu-mode.sh): the NVIDIA GPU draws the desktop,
    /// so it must never be runtime-suspended, on battery or not.
    fn dgpu_forced(&self) -> bool {
        let mut b = [0u8; 16];
        read_trim(&self.dgpu_mode_file, &mut b) == Some("dgpu")
    }

    fn gpu_runtime_pm(&self, allow_sleep: bool) {
        let val = if allow_sleep && !self.dgpu_forced() { "auto" } else { "on" };
        let (_, control_paths) = discover_nvidia_pci();
        if !control_paths.is_empty() {
            for ctrl in control_paths {
                if let Some(s) = ctrl.to_str() {
                    write_sysfs(s, val);
                }
            }
        } else {
            for p in DGPU_CONTROL {
                write_sysfs(p, val);
            }
        }
    }

    fn gaming_tweaks(&mut self, on: bool) {
        if on {
            let _ = self.hypr.query("eval hl.config({ animations = { enabled = false }, decoration = { blur = { enabled = false }, shadow = { enabled = false } }, misc = { vrr = 1 }, render = { direct_scanout = true } })");
            signal_apps(libc::SIGSTOP);
        } else {
            let _ = self.hypr.query("eval hl.config({ animations = { enabled = true }, decoration = { blur = { enabled = true }, shadow = { enabled = true } } })");
            signal_apps(libc::SIGCONT);
        }
    }

    fn apply_mode(&mut self, mode: PowerMode) {
        let last = self.mode;
        println!("Switching to {} mode", mode.name());
        match mode {
            PowerMode::Battery => {
                self.hypr.set_refresh(false);
                self.gpu_runtime_pm(true);
            }
            PowerMode::ACBalanced | PowerMode::ACPerformance | PowerMode::Gaming => {
                self.hypr.set_refresh(true);
                self.gpu_runtime_pm(false);
            }
            PowerMode::Idle => {
                self.hypr.set_refresh(false);
                self.gpu_runtime_pm(true);
            }
            PowerMode::Thermal => {} // just the profile: leave refresh rate and GPU alone
        }
        if last == Some(PowerMode::Gaming) && mode != PowerMode::Gaming {
            self.gaming_tweaks(false);
        }
        if mode == PowerMode::Gaming {
            self.gaming_tweaks(true);
        }
    }

    fn tick(&mut self) {
        let ac = self.ac.online();
        let mode = self.determine_mode(ac);
        let changed = self.mode != Some(mode);
        let profile = mode.profile(ac);

        self.sync_profile(profile, changed);
        if changed {
            self.apply_mode(mode);
            self.mode = Some(mode);
        }
        self.write_state(mode.name(), profile);
    }

    /// Never leave apps frozen / animations off if we are stopped while gaming.
    fn shutdown(&mut self) {
        if self.mode == Some(PowerMode::Gaming) {
            self.gaming_tweaks(false);
        }
        let _ = fs::remove_file(&self.state_path);
    }
}

// ---------------------------------------------------------------------------------------------
// main: single instance + one poll() loop (IPC wake-up, SIGTERM/SIGINT/SIGHUP, 15 s timer)
// ---------------------------------------------------------------------------------------------

/// A signalfd for the termination signals (replaces a signal-handler thread). Signals are only
/// blocked once the fd exists, so a failure here leaves default signal handling intact.
fn termination_signalfd() -> RawFd {
    unsafe {
        let mut set: libc::sigset_t = std::mem::zeroed();
        libc::sigemptyset(&mut set);
        for s in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
            libc::sigaddset(&mut set, s);
        }
        let fd = libc::signalfd(-1, &set, libc::SFD_NONBLOCK | libc::SFD_CLOEXEC);
        if fd >= 0 {
            libc::sigprocmask(libc::SIG_BLOCK, &set, std::ptr::null_mut());
        }
        fd
    }
}

fn main() {
    let runtime = runtime_dir();
    let lock_path = format!("{runtime}/power-manager.lock.sock");

    // Another instance running? Poke it so it re-evaluates now, then exit.
    if let Ok(mut s) = UnixStream::connect(&lock_path) {
        let _ = s.write_all(b"wakeup");
        println!("Another instance is running, sent wakeup signal.");
        return;
    }
    let _ = fs::remove_file(&lock_path); // stale socket left by a crash
    let listener = match UnixListener::bind(&lock_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("Failed to bind lock socket ({e}). Exiting.");
            return;
        }
    };
    let _ = listener.set_nonblocking(true);

    let sfd = termination_signalfd();
    let mut pfds = [
        libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 },
        libc::pollfd { fd: sfd, events: libc::POLLIN, revents: 0 }, // a negative fd is ignored by poll()
    ];

    println!("Power Manager Daemon started...");
    let mut daemon = Daemon::new(&runtime);
    daemon.write_state("starting", "-");

    loop {
        daemon.tick();

        pfds[0].revents = 0;
        pfds[1].revents = 0;
        let n = unsafe { libc::poll(pfds.as_mut_ptr(), 2, POLL_MS) };
        if n > 0 {
            if pfds[1].revents & libc::POLLIN != 0 {
                println!("Received termination signal, cleaning up...");
                break;
            }
            if pfds[0].revents & libc::POLLIN != 0 {
                // any connection is a wake-up; drain them all
                while let Ok((mut s, _)) = listener.accept() {
                    let _ = s.set_nonblocking(true);
                    let _ = s.read(&mut [0u8; 8]);
                }
            }
        }
    }

    daemon.shutdown();
    let _ = fs::remove_file(&lock_path);
    if sfd >= 0 {
        unsafe { libc::close(sfd) };
    }
}

// ---------------------------------------------------------------------------------------------
// Tests (cargo test): the parsing that replaced serde_json
// ---------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    const MONITORS: &str = r#"[{
	"id": 0,
	"name": "eDP-1",
	"description": "Some Panel \"quoted\"",
	"width": 1920,
	"height": 1080,
	"refreshRate": 143.99800,
	"activeWorkspace": {"id": 1, "name": "1"},
	"solitary": "0",
	"availableModes": ["1920x1080@144.00Hz","1920x1080@60.00Hz","1280x720@240.00Hz"]
},{
	"id": 1,
	"name": "HDMI-A-1",
	"width": 3840,
	"height": 2160,
	"solitary": "0x55d1c0a8b2f0",
	"availableModes": ["3840x2160@60.00Hz"]
}]"#;

    #[test]
    fn monitor_config_picks_internal_panel_and_max_hz_at_current_resolution() {
        let (name, high, low) = parse_monitor_config(MONITORS).unwrap();
        assert_eq!(name, "eDP-1");
        assert_eq!(high, "1920x1080@144"); // not 240: that is another resolution
        assert_eq!(low, "1920x1080@60");
    }

    #[test]
    fn solitary_detects_fullscreen() {
        assert!(any_solitary(MONITORS));
        assert!(!any_solitary(r#"[{"solitary": "0"}]"#));
        assert!(!any_solitary("[]"));
    }

    #[test]
    fn heavy_classes_match_by_substring() {
        assert!(heavy_class_present(r#"[{"class": "zen"},{"class": "steam_app_1245620"}]"#));
        assert!(!heavy_class_present(r#"[{"class": "zen","initialClass": "Blender"}]"#));
        assert!(!heavy_class_present("[]"));
    }

    #[test]
    fn cpu_line_parses() {
        assert_eq!(parse_cpu_line("cpu  100 20 30 800 10 0 0 0 0 0"), Some((150, 960)));
        assert_eq!(parse_cpu_line("cpu  1 2"), None);
    }

    #[test]
    fn top_objects_ignores_braces_in_strings() {
        let objs = top_objects(r#"[{"a": "}{"},{"b": {"c": 1}}]"#);
        assert_eq!(objs.len(), 2);
    }
}
