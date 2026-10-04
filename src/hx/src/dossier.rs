//! `hx dossier [ip]`: per-attacker summary built from the honeypot logs (replaces attacker-dossier.py).
use crate::util;
use regex::Regex;
use std::collections::HashMap;
use std::fs;

/// Counter that remembers first-seen order, so ties print the way the Python version did.
#[derive(Default, Clone)]
struct Counter {
    items: Vec<(String, u64)>,
}
impl Counter {
    fn add(&mut self, k: &str) {
        match self.items.iter_mut().find(|(n, _)| n == k) {
            Some((_, c)) => *c += 1,
            None => self.items.push((k.to_string(), 1)),
        }
    }
    fn total(&self) -> u64 {
        self.items.iter().map(|(_, c)| c).sum()
    }
    fn most_common(&self) -> Vec<(String, u64)> {
        let mut v = self.items.clone();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        v
    }
    fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

#[derive(Default, Clone)]
struct Cowrie {
    sessions: u64,
    logins: Counter,
    cmds: Vec<String>,
    last: String,
}

fn clean(s: &str) -> String {
    s.chars().map(|c| if (c as u32) < 0x20 || c as u32 == 0x7f { '?' } else { c }).collect()
}

/// "2026-10-03T18:04:11.123Z" -> "10-03 23:34" in local time; anything odd falls back to the first 16 chars.
fn ts(t: &str) -> String {
    if t.is_empty() {
        return "-".into();
    }
    let fallback = || t.chars().take(16).collect::<String>();
    let b = t.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[10] != b'T' {
        return fallback();
    }
    let n = |a: usize, z: usize| t.get(a..z).and_then(|s| s.parse::<i64>().ok());
    let (y, mo, d, h, mi, s) = match (n(0, 4), n(5, 7), n(8, 10), n(11, 13), n(14, 16), n(17, 19)) {
        (Some(y), Some(mo), Some(d), Some(h), Some(mi), Some(s)) => (y, mo, d, h, mi, s),
        _ => return fallback(),
    };
    // days from civil (Howard Hinnant)
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * (if mo > 2 { mo - 3 } else { mo + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    let mut secs = days * 86400 + h * 3600 + mi * 60 + s;
    // an explicit +hh:mm offset (cowrie writes Z, but be tolerant)
    if let Some(off) = t.get(19..).and_then(|r| r.rfind(|c| c == '+' || c == '-').map(|i| &r[i..])) {
        if off.len() >= 6 {
            if let (Ok(oh), Ok(om)) = (off[1..3].parse::<i64>(), off[4..6].parse::<i64>()) {
                let o = oh * 3600 + om * 60;
                secs -= if off.starts_with('-') { -o } else { o };
            }
        }
    }
    unsafe {
        let tt = secs as libc::time_t;
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&tt, &mut tm);
        format!("{:02}-{:02} {:02}:{:02}", tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min)
    }
}

fn load_cowrie(logs: &str) -> (HashMap<String, Cowrie>, Vec<(String, String, String, String)>) {
    let mut agg: HashMap<String, Cowrie> = HashMap::new();
    let mut logins = Vec::new();
    let raw = fs::read(format!("{}/cowrie/cowrie.json", logs)).unwrap_or_default();
    for line in String::from_utf8_lossy(&raw).lines() {
        let e: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let s = |k: &str| e.get(k).and_then(|v| v.as_str()).map(|x| x.to_string());
        let (ip, ev) = match (s("src_ip"), s("eventid")) {
            (Some(i), Some(v)) if !i.is_empty() && !v.is_empty() => (i, v),
            _ => continue,
        };
        let d = agg.entry(ip.clone()).or_default();
        let t = s("timestamp").unwrap_or_default();
        match ev.as_str() {
            "cowrie.session.connect" => d.sessions += 1,
            "cowrie.login.success" => {
                let (u, p) = (s("username").unwrap_or_default(), s("password").unwrap_or_default());
                d.logins.add(&format!("{}:{}", u, p));
                logins.push((ip.clone(), u, p, t.clone()));
            }
            "cowrie.command.input" => {
                if let Some(c) = s("input") {
                    if !c.is_empty() && d.cmds.last() != Some(&c) {
                        d.cmds.push(c);
                    }
                }
            }
            _ => {}
        }
        if t > d.last {
            d.last = t;
        }
    }
    (agg, logins)
}

fn load_recon(logs: &str) -> HashMap<String, Counter> {
    let mut agg: HashMap<String, Counter> = HashMap::new();
    let any_ip = Regex::new(r"\b(\d{1,3}(?:\.\d{1,3}){3})\b").unwrap();
    let head = Regex::new(r"^\[[^\]]*\]\s*\[ALERT\]\s*").unwrap();
    let from_ip = Regex::new(r"\s*\b(?:from|Source IP|Banning IP)\s+\d{1,3}(?:\.\d{1,3}){3}\b").unwrap();
    let raw = fs::read(format!("{}/recon-attempts.log", logs)).unwrap_or_default();
    for line in String::from_utf8_lossy(&raw).lines() {
        if !line.contains("[ALERT]") {
            continue;
        }
        let ip = match any_ip.captures(line) {
            Some(m) => m[1].to_string(),
            None => continue,
        };
        let label = head.replace(line.trim(), "").into_owned();
        let label = from_ip.replace_all(&label, "").into_owned();
        agg.entry(ip).or_default().add(&clean(&label));
    }
    agg
}

pub fn run(target: Option<&str>) {
    let logs = util::logs_dir();
    let (cow, login_events) = load_cowrie(&logs);
    let recon = load_recon(&logs);
    let empty_c = Cowrie::default();
    let empty_r = Counter::default();

    if let Some(ip) = target.map(|t| t.trim()).filter(|t| !t.is_empty()) {
        println!("=== Detailed Attacker Dossier for IP: {} ===", ip);
        let c = cow.get(ip).unwrap_or(&empty_c);
        let r = recon.get(ip).unwrap_or(&empty_r);
        println!("  Total Cowrie SSH Sessions : {}", c.sessions);
        println!("  Last Cowrie Hit           : {}", ts(&c.last));
        if !c.logins.is_empty() {
            let creds: Vec<String> = c.logins.most_common().into_iter().take(10).map(|(k, _)| k).collect();
            println!("  Captured SSH Credentials  : {}", clean(&creds.join(", ")));
        }
        if !c.cmds.is_empty() {
            println!("  Executed Shell Commands   :");
            for cmd in &c.cmds {
                println!("    $ {}", clean(cmd));
            }
        }
        if !r.is_empty() {
            println!("  Decoy Port Activity       :");
            for (k, v) in r.most_common() {
                println!("    - {} (x{})", k, v);
            }
        }
        let scan_log = format!("{}/attacker-scans.log", logs);
        if std::path::Path::new(&scan_log).is_file() {
            println!("\n  Counter-Scan Intel        :");
            let content = String::from_utf8_lossy(&fs::read(&scan_log).unwrap_or_default()).into_owned();
            if content.contains(ip) {
                for b in content.split("===== COUNTER-SCAN") {
                    if b.contains(ip) {
                        for ln in b.lines().filter(|l| !l.trim().is_empty()).take(10) {
                            println!("    {}", ln);
                        }
                    }
                }
            } else {
                println!("    No counter-scan data recorded for this IP.");
            }
        }
        return;
    }

    println!("=== Cowrie SSH Honeypot ===");
    let sess: u64 = cow.values().map(|d| d.sessions).sum();
    let logn: u64 = cow.values().map(|d| d.logins.total()).sum();
    let cmds: usize = cow.values().map(|d| d.cmds.len()).sum();
    println!("  sessions {}   logins captured {}   commands {}", sess, logn, cmds);
    for (ip, u, p, t) in login_events.iter().rev().take(6).collect::<Vec<_>>().into_iter().rev() {
        println!("    {}:{}  @ {}  {}", u, p, ip, ts(t));
    }

    println!("\n=== Attacker Dossiers (by activity) ===");
    let mut ips: Vec<&String> = cow.keys().chain(recon.keys()).collect();
    ips.sort();
    ips.dedup();
    if ips.is_empty() {
        println!("  No attacker activity yet.");
        return;
    }
    let mut rows: Vec<(&String, u64, &Cowrie, &Counter)> = ips
        .into_iter()
        .map(|ip| {
            let c = cow.get(ip).unwrap_or(&empty_c);
            let r = recon.get(ip).unwrap_or(&empty_r);
            (ip, c.sessions + c.logins.total() + c.cmds.len() as u64 + r.total(), c, r)
        })
        .collect();
    rows.sort_by(|a, b| b.1.cmp(&a.1));
    for (ip, total, c, r) in rows {
        println!("\n  {}   activity: {}   (last cowrie hit {})", ip, total, ts(&c.last));
        if !c.logins.is_empty() {
            let creds: Vec<String> = c.logins.most_common().into_iter().take(5).map(|(k, _)| k).collect();
            println!("    SSH creds:  {}", clean(&creds.join(", ")));
        }
        if !c.cmds.is_empty() {
            let first: Vec<&str> = c.cmds.iter().take(6).map(|s| s.as_str()).collect();
            println!("    Commands:   {}", first.join(", "));
        }
        for (k, v) in r.most_common().into_iter().take(5) {
            println!("    decoy:      {}  (x{})", k, v);
        }
    }
}
