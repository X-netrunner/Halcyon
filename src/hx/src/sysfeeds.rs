//! stats / net / states: the always-on feeds of the bar, in Rust (ports of scripts/stats.sh, scripts/net.sh and the 15 s
//! poll of gaming / caffeine / power profile / focus).
//!
//! Why: the bash versions are lean, but net.sh still starts nmcli + bluetoothctl on every tick and the 15 s poll starts a
//! Python interpreter (focus.py status) and a second one (powerprofilesctl). Here everything comes from /proc and /sys
//! (no process at all in steady state); an external tool is only run when something CHANGED (a Bluetooth link came or
//! went) or cannot be read any other way (the SSID on a driver without wireless-extensions).
//!
//! Same JSON as the scripts, same wake pipes ($XDG_RUNTIME_DIR/halcyon-{stats,net}.wake), same flag files
//! (~/.local/state/island/bg-refresh, stats-fast). Escape hatch: `touch ~/.local/state/island/net-legacy` (or stats-legacy)
//! makes the feed exit with code 3 and the island falls back to the old script.
use crate::util::{home, run};
use serde_json::{json, Value};
use std::io::Write;
use std::os::unix::io::RawFd;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

// ------------------------------------------------------------------ small helpers
/// Test hook: with HX_FAKE_ROOT=<dir> every /sys, /proc and /etc path is looked up under that directory instead.
fn fx(p: &str) -> String {
    if p.starts_with("/sys/") || p.starts_with("/proc/") || p.starts_with("/etc/") {
        if let Ok(r) = std::env::var("HX_FAKE_ROOT") {
            return format!("{}{}", r, p);
        }
    }
    p.to_string()
}
fn read(p: &str) -> String {
    crate::util::read(&fx(p))
}
fn xdg_rt() -> Option<String> {
    std::env::var("XDG_RUNTIME_DIR").ok().filter(|s| !s.is_empty())
}
fn state_dir() -> String {
    format!("{}/.local/state/island", home())
}
fn first_line(path: &str) -> String {
    read(path).lines().next().unwrap_or("").trim().to_string()
}
fn exists(p: &str) -> bool {
    Path::new(&fx(p)).exists()
}
fn names(dir: &str) -> Vec<String> {
    let mut v: Vec<String> = match std::fs::read_dir(fx(dir)) {
        Ok(rd) => rd.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect(),
        Err(_) => Vec::new(),
    };
    v.sort();
    v
}
fn js(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}
fn lower_dash(s: &str) -> String {
    s.chars().filter(|c| c.is_ascii_lowercase() || *c == '-').collect()
}

/// Prints a line unless it is the same as the last one (the island ignores repeats anyway). false = the pipe is closed.
struct Out {
    last: String,
}
impl Out {
    fn line(&mut self, s: String) -> bool {
        if s == self.last {
            return true;
        }
        let so = std::io::stdout();
        let mut l = so.lock();
        if writeln!(l, "{}", s).is_err() || l.flush().is_err() {
            return false;
        }
        self.last = s;
        true
    }
}

// ------------------------------------------------------------------ the wake pipe
/// A FIFO in $XDG_RUNTIME_DIR that wifi-connect.sh, bt-set.sh and the island poke after a change: the wait between two
/// samples is a poll() on it, so a change shows within a second instead of at the end of a slow wait.
struct Wake {
    fd: RawFd,
}
impl Wake {
    fn open(name: &str) -> Wake {
        let path = format!("{}/halcyon-{}.wake", xdg_rt().unwrap_or_else(|| "/tmp".into()), name);
        let c = match std::ffi::CString::new(path) {
            Ok(c) => c,
            Err(_) => return Wake { fd: -1 },
        };
        unsafe {
            let mut st: libc::stat = std::mem::zeroed();
            if libc::stat(c.as_ptr(), &mut st) == 0 && (st.st_mode & libc::S_IFMT) != libc::S_IFIFO {
                libc::unlink(c.as_ptr());
            }
            libc::mkfifo(c.as_ptr(), 0o600); // already there = fine
            let fd = libc::open(c.as_ptr(), libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC);
            Wake { fd }
        }
    }
    fn poll(&self, ms: i32) -> bool {
        let mut p = libc::pollfd { fd: self.fd, events: libc::POLLIN, revents: 0 };
        unsafe { libc::poll(&mut p, 1, ms) > 0 && (p.revents & libc::POLLIN) != 0 }
    }
    fn drain(&self) {
        let mut buf = [0u8; 256];
        unsafe { while libc::read(self.fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) > 0 {} }
    }
    /// Sleep `secs`, or less when poked. A poke gets one more second so the action that caused it can finish first.
    fn wait(&self, secs: f64) {
        if self.fd < 0 {
            std::thread::sleep(Duration::from_secs_f64(secs.max(0.1)));
            return;
        }
        if self.poll((secs * 1000.0) as i32) {
            self.drain();
            if self.poll(1000) {
                self.drain();
            }
        }
    }
}
impl Drop for Wake {
    fn drop(&mut self) {
        if self.fd >= 0 {
            unsafe { libc::close(self.fd) };
        }
    }
}

/// Adaptive update speed: how much slower than normal the feeds may look right now, worked out from what the machine is doing.
/// A busy machine (a game, a build, a render: the 1-minute load is about every core) is left alone: 5x. On a laptop running on
/// its battery: 2.5x, and 5x once it is nearly empty. On the mains, or a desktop: 1x, the feeds stay live. It only looks at
/// /proc and /sys (no process), and it is asked once per wait, so it follows the machine within a few seconds.
fn adaptive_factor() -> f64 {
    let load: f64 = read("/proc/loadavg").split_whitespace().next().and_then(|x| x.parse().ok()).unwrap_or(0.0);
    let cores = std::thread::available_parallelism().map(|n| n.get() as f64).unwrap_or(1.0);
    if load >= cores * 0.9 {
        return 5.0;
    }
    for n in names("/sys/class/power_supply") {
        if n.starts_with("BAT") {
            if ac_online() {
                return 1.0;
            }
            let cap: i64 = first_line(&format!("/sys/class/power_supply/{}/capacity", n)).parse().unwrap_or(100);
            return if cap <= 20 { 5.0 } else { 2.5 };
        }
    }
    1.0
}

/// Settings > Performance > Update speed (flag file bg-refresh): normal | relaxed | slow = 1x / 2.5x / 5x (High / Medium / Low),
/// or auto (Adaptive, see adaptive_factor). It is its own choice: the Resource use presets no longer set it.
/// `fast_aware`: the stats feed keeps its normal pace while the performance page (or the bar's CPU / RAM row) can be on
/// screen (flag stats-fast = 1, missing = 1).
fn pace(iv: f64, fast_aware: bool) -> f64 {
    let dir = state_dir();
    if fast_aware {
        let f = first_line(&format!("{}/stats-fast", dir));
        if f.is_empty() || f == "1" {
            return iv;
        }
    }
    match first_line(&format!("{}/bg-refresh", dir)).as_str() {
        "relaxed" => iv * 2.5,
        "slow" => iv * 5.0,
        "auto" => iv * adaptive_factor(),
        _ => iv,
    }
}

// ================================================================== stats
fn cpu_times() -> (u64, u64) {
    let s = read("/proc/stat");
    let f: Vec<u64> = s.lines().next().unwrap_or("").split_whitespace().skip(1).take(8).map(|x| x.parse().unwrap_or(0)).collect();
    if f.len() < 8 {
        return (0, 0);
    }
    (f.iter().sum(), f[3] + f[4]) // total = user nice system idle iowait irq softirq steal; idle = idle + iowait
}

fn net_bytes() -> (u64, u64) {
    let (mut rx, mut tx) = (0u64, 0u64);
    for l in read("/proc/net/dev").lines().skip(2) {
        if let Some((name, rest)) = l.split_once(':') {
            if name.trim() == "lo" {
                continue;
            }
            let f: Vec<&str> = rest.split_whitespace().collect();
            rx += f.first().and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
            tx += f.get(8).and_then(|x| x.parse::<u64>().ok()).unwrap_or(0);
        }
    }
    (rx, tx)
}

fn mem_kb() -> (u64, u64) {
    let (mut mt, mut ma) = (0, 0);
    for l in read("/proc/meminfo").lines() {
        let mut it = l.split_whitespace();
        match it.next() {
            Some("MemTotal:") => mt = it.next().and_then(|x| x.parse().ok()).unwrap_or(0),
            Some("MemAvailable:") => {
                ma = it.next().and_then(|x| x.parse().ok()).unwrap_or(0);
                break;
            }
            _ => {}
        }
    }
    (mt, ma)
}

fn temp_paths() -> Vec<String> {
    let mut v = Vec::new();
    for (dir, prefix, file) in [("/sys/class/hwmon", "hwmon", "temp1_input"), ("/sys/class/thermal", "thermal_zone", "temp")] {
        for n in names(dir) {
            if n.starts_with(prefix) {
                v.push(format!("{}/{}/{}", dir, n, file));
            }
        }
    }
    v
}

fn hottest(paths: &[String]) -> i64 {
    let mut temp = 0;
    for p in paths {
        if let Ok(s) = std::fs::read_to_string(fx(p)) {
            if let Ok(raw) = s.trim().parse::<i64>() {
                let v = raw / 1000;
                if v > temp && v < 120 {
                    temp = v;
                }
            }
        }
    }
    temp
}

fn ac_online() -> bool {
    for n in names("/sys/class/power_supply") {
        let p = format!("/sys/class/power_supply/{}", n);
        let t = first_line(&format!("{}/type", p));
        let is_ac = n.starts_with("AC")
            || n.starts_with("ADP")
            || n.starts_with("ucsi")
            || t.eq_ignore_ascii_case("Mains")
            || t.eq_ignore_ascii_case("USB")
            || t.eq_ignore_ascii_case("USB_PD")
            || t.eq_ignore_ascii_case("USB_C");
        if is_ac && first_line(&format!("{}/online", p)) == "1" {
            return true;
        }
    }
    false
}

fn fmt_min(m: u64) -> String {
    if m >= 60 {
        format!("{}h {:02}m", m / 60, m % 60)
    } else {
        format!("{}m", m)
    }
}

/// upower: looked up once, read at most every 15 s with ONE call (the fallback for machines whose kernel gives no estimate).
struct Upower {
    probed: bool,
    dev: Option<String>,
    at: Option<Instant>,
    cap: i64,
    st: String,
    est: String,
}
impl Upower {
    fn read(&mut self) {
        if !self.probed {
            self.probed = true;
            self.dev = run("upower", &["-e"], 3).lines().find(|l| l.to_lowercase().contains("bat")).map(|s| s.trim().to_string());
        }
        let dev = match &self.dev {
            Some(d) => d.clone(),
            None => return,
        };
        if self.at.map(|t| t.elapsed() < Duration::from_secs(15)).unwrap_or(false) {
            return;
        }
        self.at = Some(Instant::now());
        let (mut p, mut s, mut e, mut f) = (0f64, String::new(), String::new(), String::new());
        for l in run("upower", &["-i", &dev], 3).lines() {
            let mut it = l.splitn(3, ':');
            let k = it.next().unwrap_or("");
            let v = it.next().unwrap_or("").trim().to_string();
            if k.contains("percentage") {
                p = v.trim_end_matches('%').trim().parse().unwrap_or(0.0);
            } else if k.contains("state") {
                s = v;
            } else if k.contains("time to empty") {
                e = v;
            } else if k.contains("time to full") {
                f = format!("{} to full", v);
            }
        }
        self.cap = p as i64;
        self.st = s;
        self.est = if f.is_empty() { e } else { f };
    }
}

struct Bat {
    dir: Option<String>,
    rate_avg: u64,
    last_st: String,
    up: Upower,
}
struct BatNow {
    has: bool,
    cap: i64,
    chg: bool,
    w: f64, // power going out of (discharging) or into (charging) the battery, watts, smoothed; 0 = not known
    est: String,
}
impl Bat {
    fn new() -> Bat {
        let ns = names("/sys/class/power_supply");
        let mut dir = None;
        'find: for pat in 0..4 {
            for n in &ns {
                let hit = match pat {
                    0 => n.starts_with("BAT"),
                    1 => n.starts_with("bat"),
                    2 => n.starts_with("CMB"),
                    _ => n.contains("battery"),
                };
                if hit {
                    dir = Some(format!("/sys/class/power_supply/{}", n));
                    break 'find;
                }
            }
        }
        Bat { dir, rate_avg: 0, last_st: String::new(), up: Upower { probed: false, dev: None, at: None, cap: 0, st: String::new(), est: String::new() } }
    }

    fn read(&mut self) -> BatNow {
        let d = match self.dir.clone() {
            Some(d) => d,
            None => {
                self.up.read();
                return if self.up.dev.is_some() {
                    BatNow { has: true, cap: self.up.cap, chg: self.up.st == "charging", w: 0.0, est: self.up.est.clone() }
                } else {
                    BatNow { has: false, cap: 0, chg: false, w: 0.0, est: String::new() }
                };
            }
        };
        let cap = first_line(&format!("{}/capacity", d)).parse::<i64>().unwrap_or(0);
        let st = first_line(&format!("{}/status", d));
        let num = |f: &str| -> Option<u64> { first_line(&format!("{}/{}", d, f)).trim_start_matches('-').parse().ok() };
        let by_charge = exists(&format!("{}/charge_now", d)) && exists(&format!("{}/current_now", d));
        let (now, full, rate) = if by_charge {
            (num("charge_now"), num("charge_full"), num("current_now"))
        } else if exists(&format!("{}/energy_now", d)) && exists(&format!("{}/power_now", d)) {
            (num("energy_now"), num("energy_full"), num("power_now"))
        } else {
            (None, None, None)
        };
        if st != self.last_st {
            self.rate_avg = 0;
            self.last_st = st.clone();
        }
        if let Some(r) = rate {
            if r > 0 {
                self.rate_avg = if self.rate_avg == 0 { r } else { (self.rate_avg * 7 + r) / 8 }; // smoothed, so the estimate does not jump
            }
        }
        let mut est = String::new();
        if st == "Discharging" && self.rate_avg > 0 {
            if let Some(n) = now {
                est = fmt_min(n * 60 / self.rate_avg);
            }
        } else if st == "Charging" && self.rate_avg > 0 {
            if let (Some(n), Some(f)) = (now, full) {
                if f > n {
                    est = format!("{} to full", fmt_min((f - n) * 60 / self.rate_avg));
                }
            }
        }
        // "Not charging" (plugged in at a charge limit) has no estimate either: do not start upower every 15 s for nothing
        if est.is_empty() && st != "Full" && st != "Not charging" {
            self.up.read();
            est = self.up.est.clone();
        }
        // watts from the smoothed rate: µW as it is (energy_* / power_now), or µA x µV (charge_* / current_now)
        let w = if self.rate_avg == 0 || (st != "Discharging" && st != "Charging") {
            0.0
        } else if by_charge {
            num("voltage_now").map(|v| self.rate_avg as f64 * v as f64 / 1e12).unwrap_or(0.0)
        } else {
            self.rate_avg as f64 / 1e6
        };
        BatNow { has: true, cap, chg: st == "Charging", w, est }
    }
}

pub fn stats(iv: f64) {
    if exists(&format!("{}/stats-legacy", state_dir())) {
        std::process::exit(3);
    }
    let wake = Wake::open("stats");
    let temps = temp_paths();
    let mut bat = Bat::new();
    let (mut pt, mut pi) = cpu_times();
    let (mut prx, mut ptx) = net_bytes();
    let uid = unsafe { libc::getuid() };
    let pm_state = format!("{}/power-manager.state", xdg_rt().unwrap_or_else(|| format!("/run/user/{}", uid)));
    let mut out = Out { last: String::new() };
    let mut tprev = Instant::now();
    std::thread::sleep(Duration::from_millis(1000)); // a first sample soon, from a one second window
    loop {
        let ems = (tprev.elapsed().as_millis() as i64).max(1);
        tprev = Instant::now();

        let (t, idl) = cpu_times();
        let dt = t.saturating_sub(pt);
        let di = idl.saturating_sub(pi).min(dt);
        let cpu = if dt > 0 { 100 * (dt - di) / dt } else { 0 };
        pt = t;
        pi = idl;

        let (mt, ma) = mem_kb();
        let (mem, memgb) = if mt > 0 {
            let u = mt.saturating_sub(ma);
            (u * 100 / mt, format!("{}.{}", u / 1_048_576, (u * 10 / 1_048_576) % 10))
        } else {
            (0, "0.0".to_string())
        };

        let temp = hottest(&temps);

        let (rx, tx) = net_bytes();
        let down = (rx.saturating_sub(prx) as i64 * 1000 / ems).max(0);
        let up = (tx.saturating_sub(ptx) as i64 * 1000 / ems).max(0);
        prx = rx;
        ptx = tx;

        let b = bat.read();
        let ac = ac_online();

        // sysmode: secure | stealth | relaxed | lockdown ("" = never set); `hacking` = stealth, `cyber` (old name) = relaxed
        let mut sm = lower_dash(&first_line("/etc/sysmode.mode"));
        if sm == "hacking" {
            sm = "stealth".into();
        } else if sm == "cyber" {
            sm = "relaxed".into();
        }

        // Auto power = the power-manager daemon is running (its state file is fresh)
        let (mut auto, mut pmode, mut pprof) = (false, String::new(), String::new());
        let raw = read(&pm_state);
        let mut it = raw.lines().next().unwrap_or("").split_whitespace();
        if let (Some(m), Some(p), Some(ts)) = (it.next(), it.next(), it.next().and_then(|x| x.parse::<i64>().ok())) {
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0);
            if now - ts < 90 {
                auto = true;
                pmode = lower_dash(m);
                pprof = lower_dash(p);
                if p == "-" {
                    pprof.clear();
                }
            }
        }

        let line = format!(
            "{{\"cpu\":{},\"mem\":{},\"memGb\":\"{}\",\"temp\":{},\"down\":{},\"up\":{},\"bat\":{},\"batEst\":{},\"charging\":{},\"ac\":{},\"hasBat\":{},\"batW\":{:.1},\"sysmode\":\"{}\",\"auto\":{},\"pmode\":\"{}\",\"pprofile\":\"{}\"}}",
            cpu, mem, memgb, temp, down, up, b.cap, js(&b.est), b.chg, ac, b.has, b.w, sm, auto, pmode, pprof
        );
        if !out.line(line) {
            return;
        }
        wake.wait(pace(iv, true));
    }
}

// ================================================================== net
#[repr(C)]
struct IwReq {
    name: [u8; 16],
    pointer: *mut u8,
    length: u16,
    flags: u16,
    _pad: [u8; 4],
}

struct Net {
    ip_sock: RawFd,
    hci_sock: RawFd,
    ssid_cache: Option<(String, String, i32, Instant)>, // iface, ssid, signal (from nmcli), when
    bt_sig: String,
    bt_n: usize,
    bt_dev: String,
    bt_at: Option<Instant>,
    bt_settle: bool,
}

fn unescape(s: &str) -> String {
    let mut o = String::new();
    let mut esc = false;
    for c in s.chars() {
        if esc {
            o.push(c);
            esc = false;
        } else if c == '\\' {
            esc = true;
        } else {
            o.push(c);
        }
    }
    o
}

/// nmcli's own scale: -90 dBm and below is 30, -20 dBm and above is 100 (what the old script printed)
fn dbm_to_pct(dbm: f64) -> i32 {
    let v = dbm.clamp(-90.0, -20.0);
    (100.0 - 70.0 * ((-20.0 - v) / 70.0)).round() as i32
}

fn proc_wireless(iface: &str) -> Option<i32> {
    for l in read("/proc/net/wireless").lines() {
        if let Some((n, rest)) = l.split_once(':') {
            if n.trim() == iface {
                let f: Vec<f64> = rest.split_whitespace().skip(1).take(2).map(|x| x.trim_end_matches('.').parse().unwrap_or(0.0)).collect();
                if f.len() == 2 {
                    return Some(if f[1] < 0.0 { dbm_to_pct(f[1]) } else { ((f[0] * 100.0 / 70.0).round() as i32).clamp(0, 100) });
                }
            }
        }
    }
    None
}

/// Is a Wi-Fi radio switched on? None = no Wi-Fi rfkill switch to look at (then nmcli is asked, as before).
fn wifi_radio() -> Option<bool> {
    let (mut found, mut on) = (false, false);
    for n in names("/sys/class/rfkill") {
        let p = format!("/sys/class/rfkill/{}", n);
        if first_line(&format!("{}/type", p)) == "wlan" {
            found = true;
            if first_line(&format!("{}/soft", p)) == "0" && first_line(&format!("{}/hard", p)) == "0" {
                on = true;
            }
        }
    }
    if found { Some(on) } else { None }
}

impl Drop for Net {
    fn drop(&mut self) {
        unsafe {
            if self.ip_sock >= 0 { libc::close(self.ip_sock); }
            if self.hci_sock >= 0 { libc::close(self.hci_sock); }
        }
    }
}

impl Net {
    fn new() -> Net {
        let ip_sock = unsafe { libc::socket(libc::AF_INET, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 0) };
        // AF_BLUETOOTH = 31, BTPROTO_HCI = 1: only used to ask "is the adapter up" (no root needed)
        let hci_sock = unsafe { libc::socket(31, libc::SOCK_RAW | libc::SOCK_CLOEXEC, 1) };
        Net { ip_sock, hci_sock, ssid_cache: None, bt_sig: String::new(), bt_n: 0, bt_dev: String::new(), bt_at: None, bt_settle: false }
    }

    fn ssid_ioctl(&self, iface: &str) -> Option<String> {
        if self.ip_sock < 0 {
            return None;
        }
        let mut buf = [0u8; 40];
        let mut req = IwReq { name: [0; 16], pointer: buf.as_mut_ptr(), length: 33, flags: 0, _pad: [0; 4] };
        for (i, b) in iface.bytes().take(15).enumerate() {
            req.name[i] = b;
        }
        // SIOCGIWESSID = 0x8B1B (wireless extensions, still served by cfg80211 on mainstream kernels)
        let rc = unsafe { libc::ioctl(self.ip_sock, 0x8B1B as libc::c_ulong, &mut req as *mut IwReq) };
        if rc < 0 {
            return None;
        }
        let n = (req.length as usize).min(32);
        let s = String::from_utf8_lossy(&buf[..n]).into_owned();
        if s.is_empty() { None } else { Some(s) }
    }

    fn hci_up(&self, id: u16) -> Option<bool> {
        if let Ok(v) = std::env::var("HX_FAKE_HCI") {
            return Some(v == "up"); // test hook
        }
        if self.hci_sock < 0 {
            return None;
        }
        let mut buf = [0u8; 128]; // struct hci_dev_info: dev_id u16 first, flags u32 at offset 16, HCI_UP = bit 0
        buf[..2].copy_from_slice(&id.to_ne_bytes());
        let rc = unsafe { libc::ioctl(self.hci_sock, 0x800448D3 as libc::c_ulong, buf.as_mut_ptr()) }; // HCIGETDEVINFO
        if rc < 0 {
            return None;
        }
        Some(u32::from_ne_bytes([buf[16], buf[17], buf[18], buf[19]]) & 1 == 1)
    }

    fn wifi(&mut self) -> (bool, String, i32, bool) {
        let radio = match wifi_radio() {
            Some(r) => r,
            None => run("nmcli", &["-t", "radio", "wifi"], 3).trim() == "enabled",
        };
        let (mut eth, mut wlan_up) = (false, None);
        for n in names("/sys/class/net") {
            if n == "lo" {
                continue;
            }
            let base = format!("/sys/class/net/{}", n);
            let oper = first_line(&format!("{}/operstate", base));
            let up = oper == "up" || (oper == "unknown" && first_line(&format!("{}/carrier", base)) == "1");
            if exists(&format!("{}/wireless", base)) || exists(&format!("{}/phy80211", base)) {
                if oper == "up" && wlan_up.is_none() {
                    wlan_up = Some(n);
                }
            } else if up && exists(&format!("{}/device", base)) {
                eth = true; // a physical wired port with a link
            }
        }
        let (mut ssid, mut sig) = (String::new(), 0);
        match (&wlan_up, radio) {
            (Some(ifc), true) => {
                sig = proc_wireless(ifc).unwrap_or(-1);
                match self.ssid_ioctl(ifc) {
                    Some(s) => {
                        ssid = s;
                        if sig < 0 {
                            sig = 0;
                        }
                    }
                    None => {
                        // no wireless-extensions on this driver: ask nmcli, then reuse the answer for a minute
                        let fresh = self.ssid_cache.as_ref().map(|c| &c.0 == ifc && c.3.elapsed() < Duration::from_secs(60)).unwrap_or(false);
                        if !fresh {
                            let o = run("nmcli", &["-t", "-f", "active,signal,ssid", "dev", "wifi", "list", "--rescan", "no"], 3);
                            let hit = o.lines().find_map(|l| l.strip_prefix("yes:").map(|r| r.to_string()));
                            if let Some(r) = hit {
                                let (s, n) = r.split_once(':').unwrap_or((r.as_str(), ""));
                                self.ssid_cache = Some((ifc.clone(), unescape(n), s.parse().unwrap_or(0), Instant::now()));
                            }
                        }
                        if let Some(c) = &self.ssid_cache {
                            ssid = c.1.clone();
                            if sig < 0 {
                                sig = c.2;
                            }
                        }
                        if sig < 0 {
                            sig = 0;
                        }
                    }
                }
            }
            _ => self.ssid_cache = None,
        }
        (radio, ssid, sig, eth)
    }

    /// btdev = the first connected device's name, btn = how many are connected (the dots in the combined status icon).
    /// Powered comes from the adapter's flags, the number of links from /sys/class/bluetooth/hciX:<handle>, and
    /// bluetoothctl is only run when that set CHANGED (plus once a minute and once after a change has settled).
    fn bluetooth(&mut self) -> (bool, String, usize) {
        let ns = names("/sys/class/bluetooth");
        let ids: Vec<u16> = ns.iter().filter(|n| !n.contains(':')).filter_map(|n| n.strip_prefix("hci").and_then(|d| d.parse().ok())).collect();
        if ids.is_empty() && std::env::var("HX_FAKE_HCI").is_err() {
            // no Bluetooth adapter at all
            self.bt_sig.clear();
            self.bt_n = 0;
            self.bt_dev.clear();
            return (false, String::new(), 0);
        }
        // Powered = the adapter is up. If the kernel will not tell us (no HCI socket, odd driver) ask bluetoothctl, as before.
        let mut fast = true;
        let mut powered = false;
        for id in &ids {
            match self.hci_up(*id) {
                Some(u) => powered |= u,
                None => {
                    fast = false;
                    break;
                }
            }
        }
        if !fast {
            powered = run("bluetoothctl", &["show"], 3).contains("Powered: yes");
        }
        if !powered {
            self.bt_sig.clear();
            self.bt_n = 0;
            self.bt_dev.clear();
            return (false, String::new(), 0);
        }
        let links: Vec<&String> = ns.iter().filter(|n| n.starts_with("hci") && n.contains(':')).collect();
        let sig = links.iter().map(|s| s.as_str()).collect::<Vec<_>>().join(",");
        if fast && links.is_empty() {
            self.bt_sig = sig;
            self.bt_n = 0;
            self.bt_dev.clear();
            return (true, String::new(), 0);
        }
        let age = self.bt_at.map(|t| t.elapsed());
        let changed = sig != self.bt_sig;
        let due = !fast
            || changed
            || age.map(|a| a > Duration::from_secs(60)).unwrap_or(true)
            || (self.bt_settle && age.map(|a| a > Duration::from_secs(3)).unwrap_or(true));
        if due {
            self.bt_settle = changed;
            self.bt_sig = sig;
            self.bt_at = Some(Instant::now());
            self.bt_n = 0;
            self.bt_dev.clear();
            for l in run("bluetoothctl", &["devices", "Connected"], 3).lines() {
                if l.trim().is_empty() {
                    continue;
                }
                self.bt_n += 1;
                if self.bt_dev.is_empty() {
                    self.bt_dev = l.splitn(3, ' ').nth(2).unwrap_or("").trim().to_string();
                }
            }
        }
        (true, self.bt_dev.clone(), self.bt_n)
    }

    fn sample(&mut self) -> String {
        let (radio, ssid, sig, eth) = self.wifi();
        let (bt, btdev, btn) = self.bluetooth();
        format!(
            "{{\"wifi\":\"{}\",\"ssid\":{},\"eth\":{},\"bt\":\"{}\",\"btdev\":{},\"btn\":{},\"signal\":{}}}",
            if radio { "on" } else { "off" },
            js(&ssid),
            eth,
            if bt { "on" } else { "off" },
            js(&btdev),
            btn,
            sig
        )
    }
}

// ------------------------------------------------------------------ Adaptive update speed: the part that learns
// Settings > Performance > Update speed > Adaptive. adaptive_factor() above looks at what the MACHINE is doing; this looks at what
// the USER does: how often the Wi-Fi / Bluetooth picture really changes (a network or device connects, disconnects, a radio is
// switched). Someone who sets it up once and never touches it gets slower background looks (up to 4x, never slower than one look a
// minute); someone who hops between networks and devices all day stays live. The signal strength is NOT counted (it moves all the
// time). Learning needs 3 days the desktop was used; after a change the feed is live again for 5 minutes. Actions done in the island
// (Wi-Fi / Bluetooth switches, connecting) poke the wake pipe, so they never wait for a slow look.
// File: ~/.local/state/island/adaptive-net.tsv, lines "d <day number>" (a day the feed ran) and "c <epoch>" (a change), the last
// 14 days only. scripts/net.sh (the fallback) reads and writes the same file. Deleting it (Settings: "Forget what it learned") starts over.
const LEARN_DAYS: u64 = 14;
const LEARN_MIN_DAYS: usize = 3;
const LEARN_MAX_SECS: f64 = 60.0;

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

struct Learner {
    path: String,
    days: Vec<u64>,
    changes: Vec<u64>,
    last_key: Option<String>,
}

impl Learner {
    fn load() -> Learner {
        let path = format!("{}/adaptive-net.tsv", state_dir());
        let oldest = now_secs().saturating_sub(LEARN_DAYS * 86400);
        let mut days: Vec<u64> = Vec::new();
        let mut changes: Vec<u64> = Vec::new();
        for l in read(&path).lines() {
            let mut it = l.split_whitespace();
            let kind = it.next().unwrap_or("");
            let v: u64 = match it.next().and_then(|x| x.parse().ok()) {
                Some(v) => v,
                None => continue,
            };
            if kind == "d" && v.saturating_mul(86400).saturating_add(86400) > oldest {
                days.push(v);
            } else if kind == "c" && v > oldest {
                changes.push(v);
            }
        }
        let l = Learner { path, days, changes, last_key: None };
        l.rewrite(); // drops what is older than 14 days
        l
    }

    fn rewrite(&self) {
        if self.days.is_empty() && self.changes.is_empty() {
            return;
        }
        let mut text = String::new();
        for d in &self.days {
            text.push_str(&format!("d {}\n", d));
        }
        for c in &self.changes {
            text.push_str(&format!("c {}\n", c));
        }
        let _ = std::fs::create_dir_all(state_dir());
        let _ = std::fs::write(&self.path, text);
    }

    fn append(&self, line: &str) {
        let _ = std::fs::create_dir_all(state_dir());
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&self.path) {
            let _ = writeln!(f, "{}", line);
        }
    }

    /// Called with every sample line: notes the day, and a change of anything except the signal strength.
    fn seen(&mut self, line: &str) {
        if (!self.days.is_empty() || !self.changes.is_empty()) && !Path::new(&self.path).exists() {
            self.days.clear(); // the file was deleted ("Forget what it learned"): start again
            self.changes.clear();
        }
        let key = match line.rsplit_once(",\"signal\":") {
            Some((a, _)) => a,
            None => line,
        };
        let now = now_secs();
        let day = now / 86400;
        if !self.days.contains(&day) {
            self.days.push(day);
            self.append(&format!("d {}", day));
        }
        let first = self.last_key.is_none();
        let same = self.last_key.as_deref() == Some(key);
        if !same {
            self.last_key = Some(key.to_string());
            if !first {
                self.changes.push(now);
                if self.changes.len() > 2000 {
                    self.changes.remove(0);
                }
                self.append(&format!("c {}", now));
            }
        }
    }

    /// 1.0 = no change to the pace; 2 / 3 / 4 = how many times slower the looks may be.
    fn factor(&self) -> f64 {
        let now = now_secs();
        let oldest = now.saturating_sub(LEARN_DAYS * 86400);
        let days = self.days.iter().filter(|d| d.saturating_mul(86400).saturating_add(86400) > oldest).count();
        if days < LEARN_MIN_DAYS {
            return 1.0;
        }
        if let Some(last) = self.changes.last() {
            if now.saturating_sub(*last) < 300 {
                return 1.0;
            }
        }
        let n = self.changes.iter().filter(|c| **c > oldest).count() as f64;
        let rate = n / days as f64; // changes per day the desktop was used
        if rate < 1.0 {
            4.0
        } else if rate < 4.0 {
            3.0
        } else if rate < 12.0 {
            2.0
        } else {
            1.0
        }
    }
}

/// The wait between two looks of the net feed: the usual pace, and with Adaptive chosen also what was learned about this user.
fn net_pace(iv: f64, learner: &Learner) -> f64 {
    let p = pace(iv, false);
    if first_line(&format!("{}/bg-refresh", state_dir())) == "auto" {
        return (p * learner.factor()).min(LEARN_MAX_SECS.max(p));
    }
    p
}

pub fn net(iv: f64) {
    if exists(&format!("{}/net-legacy", state_dir())) {
        std::process::exit(3);
    }
    let wake = Wake::open("net");
    let mut n = Net::new();
    let mut out = Out { last: String::new() };
    let mut learner = Learner::load();
    loop {
        let line = n.sample();
        learner.seen(&line);
        if !out.line(line) {
            return;
        }
        wake.wait(net_pace(iv, &learner));
    }
}

// ================================================================== states (the 15 s poll)
fn caffeine_on() -> bool {
    // scripts/caffeine.sh writes this file when it starts the unit; with no file nothing was started
    const FLAG: &str = "/dev/shm/halcyon-caffeine";
    if !exists(FLAG) {
        return false;
    }
    let uid = unsafe { libc::getuid() };
    let cg = format!("/sys/fs/cgroup/user.slice/user-{0}.slice/user@{0}.service/app.slice/halcyon-caffeine.service", uid);
    if exists(&cg) {
        return true;
    }
    // the file is there but the unit's cgroup is not where it is expected: let systemd decide (and tidy up like `status` does)
    let on = Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", "halcyon-caffeine.service"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !on {
        let _ = std::fs::remove_file(FLAG);
    }
    on
}

fn power_profile() -> String {
    let o = run(
        "busctl",
        &["get-property", "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles", "net.hadess.PowerProfiles", "ActiveProfile"],
        3,
    );
    if let Some(p) = o.split('"').nth(1) {
        if !p.is_empty() {
            return p.to_string();
        }
    }
    run("powerprofilesctl", &["get"], 3).trim().to_string()
}

fn truthy(v: &Value) -> bool {
    match v {
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|x| x != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Null => false,
        _ => true,
    }
}

fn focus_flag(conf: &str, key: &str, default: bool) -> bool {
    for l in conf.lines() {
        if let Some((k, v)) = l.trim().split_once('=') {
            if k == key {
                return match v.trim().to_lowercase().as_str() {
                    "1" | "true" | "on" | "yes" => true,
                    "0" | "false" | "off" | "no" => false,
                    _ => default,
                };
            }
        }
    }
    default
}

/// What `focus.sh status` prints. The common cases (no session; a session whose helper is alive) are answered from the
/// state file; anything that needs clean-up (a dead helper, a left-over restore marker) is handed to focus.py as before.
fn focus_status() -> Value {
    let rt = xdg_rt().unwrap_or_else(|| format!("/run/user/{}", unsafe { libc::getuid() }));
    let st: Option<Value> = serde_json::from_str(&read(&format!("{}/halcyon-focus.json", rt))).ok().filter(|v: &Value| v.is_object());
    let slow = || -> Value {
        let o = run("bash", &[&format!("{}/.config/Halcyon/scripts/focus.sh", home()), "status"], 10);
        serde_json::from_str(o.trim()).unwrap_or_else(|_| json!({"on": false}))
    };
    let st = match st {
        None => {
            return if exists(&format!("{}/focus-restore.json", state_dir())) { slow() } else { json!({"on": false}) };
        }
        Some(s) => s,
    };
    if !truthy(&st["on"]) {
        return json!({"on": false});
    }
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    let alive = match st["pid"].as_i64().filter(|p| *p != 0) {
        Some(pid) => unsafe { libc::kill(pid as i32, 0) == 0 },
        None => now - st["t0"].as_f64().unwrap_or(0.0) < 8.0, // the helper is still starting
    };
    if !alive {
        return slow();
    }
    let paused = truthy(&st["paused"]);
    let left = if paused { st["left"].clone() } else { json!(((st["end"].as_f64().unwrap_or(0.0) - now).round() as i64).max(0)) };
    let conf = read(&format!("{}/.config/Halcyon/focus.conf", home()));
    let blocking = focus_flag(&conf, "BLOCK", true) && !paused && (st["phase"] == "work" || !focus_flag(&conf, "BREAK_FREE", true));
    json!({
        "on": true, "phase": st["phase"], "paused": paused, "left": left, "end": st["end"], "total": st["total"],
        "cycle": st["cycle"], "cycles": st["cycles"], "pomodoro": truthy(&st["pomodoro"]), "mins": st["mins"],
        "closed": if st["closed"].is_null() { json!(0) } else { st["closed"].clone() }, "blocking": blocking
    })
}

/// One JSON line: the four slow readers the island looked at every 15 s, each of which used to be its own process
/// (sh, bash + systemctl, python3 focus.py, python3 powerprofilesctl).
pub fn states() {
    let v = json!({
        "gaming": exists("/dev/shm/halcyon-gamemode"),
        "caffeine": caffeine_on(),
        "profile": power_profile(),
        "focus": focus_status(),
    });
    println!("{}", v);
}
