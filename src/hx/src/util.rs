use std::io::Read;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Run a command, capture stdout, give up after `secs`. Any failure gives "".
pub fn run(cmd: &str, args: &[&str], secs: u64) -> String {
    let mut child = match Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return String::new(),
    };
    let mut out = child.stdout.take();
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        if let Some(o) = out.as_mut() {
            let _ = o.read_to_end(&mut buf);
        }
        buf
    });
    let end = Instant::now() + Duration::from_secs(secs);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < end => std::thread::sleep(Duration::from_millis(8)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
        }
    }
    String::from_utf8_lossy(&reader.join().unwrap_or_default()).into_owned()
}

/// Fire and forget (used for rescan and notifications).
pub fn spawn_quiet(cmd: &str, args: &[&str]) {
    let _ = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

pub fn read(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

pub fn home() -> String {
    std::env::var("HOME").unwrap_or_else(|_| "/root".into())
}

pub fn now_stamp() -> String {
    // local time "YYYY-MM-DD HH:MM:SS" without pulling in chrono
    unsafe {
        let t = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&t, &mut tm);
        format!(
            "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
            tm.tm_year + 1900,
            tm.tm_mon + 1,
            tm.tm_mday,
            tm.tm_hour,
            tm.tm_min,
            tm.tm_sec
        )
    }
}

#[allow(dead_code)]
pub fn epoch() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[allow(dead_code)]
pub fn hostname() -> String {
    let h = read("/proc/sys/kernel/hostname");
    let h = h.trim();
    if h.is_empty() { "localhost".into() } else { h.into() }
}

/// SYS_USER / SYS_HOME like sysmode: environment first, then /etc/sysmode.conf, then the defaults it ships with.
pub fn sys_conf(key: &str, default: &str) -> String {
    if let Ok(v) = std::env::var(key) {
        if !v.is_empty() {
            return v;
        }
    }
    for line in read("/etc/sysmode.conf").lines() {
        let l = line.trim();
        if let Some(rest) = l.strip_prefix(key) {
            if let Some(v) = rest.strip_prefix('=') {
                return v.trim().trim_matches('"').trim_matches('\'').to_string();
            }
        }
    }
    default.to_string()
}

pub fn sys_user() -> String { sys_conf("SYS_USER", "netrunner") }
pub fn sys_home() -> String { sys_conf("SYS_HOME", &format!("/home/{}", sys_user())) }
pub fn logs_dir() -> String { format!("{}/logs", sys_home()) }
