use regex::Regex;
use std::collections::HashMap;
use std::fs;
use std::sync::LazyLock;

static ANY_IP: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\b(\d{1,3}(?:\.\d{1,3}){3})\b").unwrap());
static ALERT_PREFIX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\[[^\]]*\]\s*\[ALERT\]\s*").unwrap());
static IP_LABEL_CLEAN: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"\s*\b(?:from|Source IP|Banning IP)\s+\d{1,3}(?:\.\d{1,3}){3}\b").unwrap()
});

#[derive(Default, Clone)]
struct Counter {
    items: Vec<(String, u64)>,
}

impl Counter {
    fn add(&mut self, k: &str) {
        if let Some((_, c)) = self.items.iter_mut().find(|(n, _)| n == k) {
            *c += 1;
        } else {
            self.items.push((k.to_string(), 1));
        }
    }

    fn total(&self) -> u64 {
        self.items.iter().map(|(_, c)| c).sum()
    }

    fn most_common(&self, limit: usize) -> Vec<(String, u64)> {
        let mut v = self.items.clone();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        if v.len() > limit {
            v.truncate(limit);
        }
        v
    }

    fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

#[derive(Default, Clone)]
struct CowrieData {
    sessions: u64,
    logins: Counter,
    cmds: Vec<String>,
    last: String,
}

fn clean(s: &str) -> String {
    s.chars()
        .map(|c| {
            if (c as u32) < 0x20 || c as u32 == 0x7f {
                '?'
            } else {
                c
            }
        })
        .collect()
}

fn ts(t: &str) -> String {
    if t.is_empty() {
        return "-".to_string();
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
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = yy.div_euclid(400);
    let yoe = yy - era * 400;
    let doy = (153 * (if mo > 2 { mo - 3 } else { mo + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    let mut secs = days * 86400 + h * 3600 + mi * 60 + s;
    if let Some(off) = t
        .get(19..)
        .and_then(|r| r.rfind(|c| c == '+' || c == '-').map(|i| &r[i..]))
    {
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
        format!(
            "{:02}-{:02} {:02}:{:02}",
            tm.tm_mon + 1,
            tm.tm_mday,
            tm.tm_hour,
            tm.tm_min
        )
    }
}

fn logs_dir() -> String {
    if let Ok(content) = fs::read_to_string("/etc/sysmode.conf") {
        for line in content.lines() {
            if let Some(rest) = line.trim().strip_prefix("SYS_HOME=") {
                let h = rest.trim().trim_matches('"').trim_matches('\'');
                if !h.is_empty() {
                    return format!("{}/logs", h);
                }
            }
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() && home != "/root" {
            return format!("{}/logs", home);
        }
    }
    "/home/sushanth/logs".to_string()
}

fn load_cowrie(logs: &str) -> (HashMap<String, CowrieData>, Vec<(String, String, String, String)>) {
    let mut agg: HashMap<String, CowrieData> = HashMap::new();
    let mut login_events = Vec::new();
    let p = format!("{}/cowrie/cowrie.json", logs);
    let raw = match fs::read_to_string(&p) {
        Ok(c) => c,
        Err(_) => return (agg, login_events),
    };

    for line in raw.lines() {
        let e: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let ip = match e.get("src_ip").and_then(|v| v.as_str()) {
            Some(i) if !i.is_empty() => i.to_string(),
            _ => continue,
        };
        let ev = match e.get("eventid").and_then(|v| v.as_str()) {
            Some(v) if !v.is_empty() => v,
            _ => continue,
        };
        let d = agg.entry(ip.clone()).or_default();
        let t = e
            .get("timestamp")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        match ev {
            "cowrie.session.connect" => {
                d.sessions += 1;
            }
            "cowrie.login.success" => {
                let u = e.get("username").and_then(|v| v.as_str()).unwrap_or("").to_string();
                let p = e.get("password").and_then(|v| v.as_str()).unwrap_or("").to_string();
                d.logins.add(&format!("{}:{}", u, p));
                login_events.push((ip.clone(), u, p, t.clone()));
            }
            "cowrie.command.input" => {
                if let Some(c) = e.get("input").and_then(|v| v.as_str()) {
                    if !c.is_empty() && (d.cmds.is_empty() || d.cmds.last().map(|s| s.as_str()) != Some(c)) {
                        d.cmds.push(c.to_string());
                    }
                }
            }
            _ => {}
        }
        if t > d.last {
            d.last = t;
        }
    }
    (agg, login_events)
}

fn load_recon(logs: &str) -> HashMap<String, Counter> {
    let mut agg: HashMap<String, Counter> = HashMap::new();
    let p = format!("{}/recon-attempts.log", logs);
    let bytes = match fs::read(&p) {
        Ok(b) => b,
        Err(_) => return agg,
    };
    let text = String::from_utf8_lossy(&bytes);
    for line in text.lines() {
        if !line.contains("[ALERT]") {
            continue;
        }
        let m = match ANY_IP.find(line) {
            Some(m) => m.as_str(),
            None => continue,
        };
        let ip = m.to_string();
        let trimmed = line.trim();
        let label = ALERT_PREFIX.replace(trimmed, "");
        let label = IP_LABEL_CLEAN.replace(&label, "");
        let cleaned_label = clean(label.trim());
        agg.entry(ip).or_default().add(&cleaned_label);
    }
    agg
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("attacker-dossier - Cowrie & recon-deceiver honeypot activity summarizer\n\nUsage: attacker-dossier [OPTIONS] [IP]\n\nArguments:\n  [IP]          Optional IP address to filter dossier intel for\n\nOptions:\n  -h, --help    Show this help message and exit");
        return;
    }
    let filter_ip = args.first().map(|s| s.as_str());

    let logs = logs_dir();
    let (cow, login_events) = load_cowrie(&logs);
    let recon = load_recon(&logs);

    println!("=== Cowrie SSH Honeypot ===");
    let sess: u64 = cow.values().map(|d| d.sessions).sum();
    let logn: u64 = cow.values().map(|d| d.logins.total()).sum();
    let cmds: usize = cow.values().map(|d| d.cmds.len()).sum();
    println!("  sessions {}   logins captured {}   commands {}", sess, logn, cmds);

    let start = if login_events.len() > 6 {
        login_events.len() - 6
    } else {
        0
    };
    for (ip, u, p, t) in &login_events[start..] {
        println!("    {}:{}  @ {}  {}", u, p, ip, ts(t));
    }

    println!("\n=== Attacker Dossiers (by activity) ===");
    let mut ips: Vec<String> = {
        let mut set: std::collections::HashSet<String> = cow.keys().cloned().collect();
        for k in recon.keys() {
            set.insert(k.clone());
        }
        if let Some(target) = filter_ip {
            set.retain(|ip| ip == target);
        }
        set.into_iter().collect()
    };

    if ips.is_empty() {
        println!("  No attacker activity yet.");
        return;
    }

    let mut rows: Vec<(String, u64, CowrieData, Counter)> = Vec::new();
    for ip in ips.drain(..) {
        let c = cow.get(&ip).cloned().unwrap_or_default();
        let r = recon.get(&ip).cloned().unwrap_or_default();
        let total = c.sessions + c.logins.total() + (c.cmds.len() as u64) + r.total();
        rows.push((ip, total, c, r));
    }
    rows.sort_by(|a, b| b.1.cmp(&a.1));

    for (ip, total, c, r) in rows {
        println!("\n  {}   activity: {}   (last cowrie hit {})", ip, total, ts(&c.last));
        if !c.logins.is_empty() {
            let creds = c
                .logins
                .most_common(5)
                .into_iter()
                .map(|(k, _)| k)
                .collect::<Vec<_>>()
                .join(", ");
            println!("    SSH creds:  {}", clean(&creds));
        }
        if !c.cmds.is_empty() {
            let limit = c.cmds.len().min(6);
            println!("    Commands:   {}", c.cmds[..limit].join(", "));
        }
        if !r.is_empty() {
            for (k, v) in r.most_common(5) {
                println!("    decoy:      {}  (x{})", k, v);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_counter() {
        let mut c = Counter::default();
        c.add("admin:root");
        c.add("admin:root");
        c.add("user:pass");
        assert_eq!(c.total(), 3);
        let mc = c.most_common(5);
        assert_eq!(mc[0].0, "admin:root");
        assert_eq!(mc[0].1, 2);
    }

    #[test]
    fn test_clean() {
        assert_eq!(clean("test\x00\x1f\x7fclean"), "test???clean");
    }

    #[test]
    fn test_ts() {
        assert_eq!(ts(""), "-");
        let formatted = ts("2026-10-06T18:04:11.123Z");
        assert!(formatted.contains("10-06"));
    }
}
