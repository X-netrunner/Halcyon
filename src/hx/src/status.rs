//! `hx status`: one JSON line with the sysmode / honeypot state, shown on the quick terminal while it is idle.
//! Cheap on purpose (a few small file reads, no subprocess except one pgrep pass over /proc), so it can be polled.
use crate::util;
use std::fs;

/// Is a process with this exact command name, or whose cmdline contains `needle`, running?
fn running(comm: Option<&str>, needle: Option<&str>) -> bool {
    let rd = match fs::read_dir("/proc") {
        Ok(r) => r,
        Err(_) => return false,
    };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !name.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        if let Some(c) = comm {
            if util::read(&format!("/proc/{}/comm", name)).trim() == c {
                return true;
            }
        }
        if let Some(n) = needle {
            let cmd = util::read(&format!("/proc/{}/cmdline", name));
            if cmd.contains(n) && !cmd.contains("pgrep") {
                return true;
            }
        }
    }
    false
}

fn j(s: &str) -> String {
    serde_json::Value::String(s.to_string()).to_string()
}

pub fn run() {
    let mut mode = util::read("/etc/sysmode.mode").trim().to_string();
    mode.retain(|c| c.is_ascii_lowercase() || c == '-');
    if mode == "hacking" {
        mode = "stealth".into();
    }
    let persona = util::read("/etc/sysmode.persona").trim().to_string();
    let decoy_wifi = util::read("/etc/sysmode.decoy-wifi").trim().to_string();

    // the Rust daemons (`hx deceive`, `hx ids`) and the Python ones that may still be around
    let honeypot = running(Some("hx-deceiver"), Some("recon-deceiver")) || running(None, Some("hx\0deceive"));
    let ids = running(Some("hx-ids"), Some("log-analyst")) || running(None, Some("hx\0ids"));
    let cowrie = std::path::Path::new("/run/cowrie.active").exists();

    // honeypot counters; the log is root-only in some setups, then readable=false and the UI shows dashes
    let logs = util::logs_dir();
    let (mut alerts, mut today, mut readable) = (0u64, 0u64, false);
    let mut ips: Vec<String> = Vec::new();
    let mut last = String::new();
    if let Ok(raw) = fs::read(format!("{}/recon-attempts.log", logs)) {
        readable = true;
        let day = util::now_stamp()[..10].to_string();
        for line in String::from_utf8_lossy(&raw).lines() {
            if !line.contains("[ALERT]") {
                continue;
            }
            alerts += 1;
            if line.starts_with(&format!("[{}", day)) {
                today += 1;
            }
            if let Some(ip) = line
                .split(|c: char| !(c.is_ascii_digit() || c == '.'))
                .find(|t| t.split('.').count() == 4 && t.split('.').all(|p| !p.is_empty() && p.len() <= 3))
            {
                if !ips.iter().any(|i| i == ip) {
                    ips.push(ip.to_string());
                }
            }
            last = line.trim().chars().take(90).collect();
        }
    }
    let ids_alerts = fs::read(format!("{}/ids-alerts.log", logs))
        .map(|r| String::from_utf8_lossy(&r).matches("[CRITICAL ALERT]").count())
        .ok();

    println!(
        "{{\"mode\":{},\"persona\":{},\"decoyWifi\":{},\"honeypot\":{},\"ids\":{},\"cowrie\":{},\"readable\":{},\"alerts\":{},\"today\":{},\"attackers\":{},\"idsAlerts\":{},\"last\":{}}}",
        j(&mode), j(&persona), j(&decoy_wifi), honeypot, ids, cowrie, readable, alerts, today, ips.len(),
        ids_alerts.map(|n| n.to_string()).unwrap_or_else(|| "null".into()), j(&last)
    );
}
