//! `hx ids`: the signature-matching IDS that tails the honeypot log (replaces log-analyst.py).
use crate::util;
use regex::{Regex, RegexBuilder};
use std::fs::{self, File};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::os::unix::fs::MetadataExt;
use std::time::Duration;

fn sig(p: &str) -> Regex {
    RegexBuilder::new(p).case_insensitive(true).build().expect("bad IDS signature")
}

/// uid of SYS_USER (the desktop user whose session gets the notification).
pub fn sys_uid() -> u32 {
    let user = util::sys_user();
    for l in util::read("/etc/passwd").lines() {
        let f: Vec<&str> = l.split(':').collect();
        if f.len() > 2 && f[0] == user {
            if let Ok(n) = f[2].parse() {
                return n;
            }
        }
    }
    1000
}

/// Environment of a running graphical session of the desktop user, so root can notify-send into it.
pub fn desktop_env() -> Vec<(String, String)> {
    let uid = sys_uid();
    let mut env = vec![
        ("DISPLAY".to_string(), ":0".to_string()),
        ("XDG_RUNTIME_DIR".to_string(), format!("/run/user/{}", uid)),
    ];
    if let Ok(rd) = fs::read_dir("/proc") {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            match fs::metadata(e.path()) {
                Ok(m) if m.uid() == uid => {}
                _ => continue,
            }
            let raw = match fs::read(format!("/proc/{}/environ", name)) {
                Ok(r) => r,
                Err(_) => continue,
            };
            let vars: Vec<(String, String)> = raw
                .split(|b| *b == 0)
                .filter_map(|kv| {
                    let s = String::from_utf8_lossy(kv).into_owned();
                    s.split_once('=').map(|(k, v)| (k.to_string(), v.to_string()))
                })
                .collect();
            if vars.iter().any(|(k, _)| k == "WAYLAND_DISPLAY" || k == "DISPLAY") {
                for want in ["DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
                    if let Some((_, v)) = vars.iter().find(|(k, _)| k == want) {
                        env.retain(|(k, _)| k != want);
                        env.push((want.to_string(), v.clone()));
                    }
                }
                return env;
            }
        }
    }
    env
}

/// notify-send as the desktop user (the island is the notification daemon).
pub fn notify(title: &str, message: &str, urgency: &str, icon: &str) {
    let env = desktop_env();
    let uid = sys_uid();
    let mut args: Vec<String> = vec!["-u".into(), util::sys_user(), "env".into()];
    let mut have_bus = false;
    for (k, v) in &env {
        have_bus |= k == "DBUS_SESSION_BUS_ADDRESS";
        args.push(format!("{}={}", k, v));
    }
    if !have_bus {
        args.push(format!("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/{}/bus", uid));
    }
    for a in ["notify-send", "-u", urgency, "-i", icon, &title.replace('\0', ""), &message.replace('\0', "")] {
        args.push(a.to_string());
    }
    let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    util::spawn_quiet("sudo", &refs);
}

pub fn run() {
    let logs = util::logs_dir();
    let log_file = format!("{}/recon-attempts.log", logs);
    let alert_log = format!("{}/ids-alerts.log", logs);

    let sigs: Vec<(&str, Regex)> = vec![
        ("Metasploit / Automated Login Scan", sig(r"CREDENTIALS HARVESTED.*(Username|USER)=(admin|root|1234)")),
        ("Directory Brute Force Attempt", sig(r"Directory brute-force detected|GET /(wp-admin|admin|config|backup|shell|phpmyadmin|\.env)")),
        ("Automated SSH Scanner Footprint", sig(r"\[PAYLOAD\] SSH packet.*(libssh|Paramiko|Go-SSH)")),
        ("SQL Injection Probing Pattern", sig(r"(' OR '1'='1|UNION SELECT|SELECT.*FROM|waitfor delay)")),
        ("Cross-Site Scripting Probe", sig(r"(<script>|alert\(|javascript:)")),
    ];

    if !std::path::Path::new(&log_file).exists() {
        println!("[!] Target log file {} does not exist yet. Waiting for initialization...", log_file);
        let _ = fs::create_dir_all(&logs);
        let _ = File::create(&log_file);
    }
    println!("[*] Lightweight Signature-Matching IDS Daemon Active (RAM safe)...");

    loop {
        let f = match File::open(&log_file) {
            Ok(f) => f,
            Err(_) => {
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
        };
        let ino = f.metadata().map(|m| m.ino()).unwrap_or(0);
        let mut r = BufReader::new(f);
        let _ = r.seek(SeekFrom::End(0));
        let mut line = String::new();
        loop {
            line.clear();
            match r.read_line(&mut line) {
                Ok(0) => {
                    std::thread::sleep(Duration::from_secs(1));
                    let pos = r.stream_position().unwrap_or(0);
                    match fs::metadata(&log_file) {
                        Ok(m) if m.ino() != ino || m.len() < pos => break, // rotated or truncated: reopen
                        _ => {}
                    }
                }
                Ok(_) => {
                    for (name, re) in &sigs {
                        if re.is_match(&line) {
                            alert(&alert_log, name, line.trim());
                        }
                    }
                }
                Err(_) => {
                    std::thread::sleep(Duration::from_secs(2));
                    break;
                }
            }
        }
    }
}

fn alert(path: &str, name: &str, raw: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = write!(f, "[{}] [CRITICAL ALERT] Match Found: {}\n    Raw Log Entry: {}\n\n", util::now_stamp(), name, raw);
    }
    let short: String = raw.chars().take(100).collect();
    notify("IDS Attack Detected", &format!("Signature: {}\nLog: {}...", name, short), "critical", "security-high");
}
