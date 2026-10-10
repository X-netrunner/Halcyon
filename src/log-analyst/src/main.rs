use chrono::Local;
use regex::{Regex, RegexBuilder};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, SeekFrom, Write};
use std::os::unix::fs::MetadataExt;
use std::path::Path;
use std::process::Command;
use std::thread;
use std::time::Duration;

fn build_sig(pattern: &str) -> Regex {
    RegexBuilder::new(pattern)
        .case_insensitive(true)
        .build()
        .expect("invalid regex")
}

fn sys_user() -> String {
    if let Ok(content) = fs::read_to_string("/etc/sysmode.conf") {
        for line in content.lines() {
            if let Some(rest) = line.trim().strip_prefix("SYS_USER=") {
                let u = rest.trim().trim_matches('"').trim_matches('\'');
                if !u.is_empty() {
                    return u.to_string();
                }
            }
        }
    }
    if let Ok(u) = std::env::var("SUDO_USER") {
        if !u.is_empty() && u != "root" {
            return u;
        }
    }
    if let Ok(u) = std::env::var("USER") {
        if !u.is_empty() && u != "root" {
            return u;
        }
    }
    if let Ok(passwd) = fs::read_to_string("/etc/passwd") {
        for line in passwd.lines() {
            let parts: Vec<&str> = line.split(':').collect();
            if parts.len() > 2 {
                if let Ok(uid) = parts[2].parse::<u32>() {
                    if (1000..60000).contains(&uid) {
                        return parts[0].to_string();
                    }
                }
            }
        }
    }
    "sushanth".to_string()
}

fn sys_home() -> String {
    if let Ok(content) = fs::read_to_string("/etc/sysmode.conf") {
        for line in content.lines() {
            if let Some(rest) = line.trim().strip_prefix("SYS_HOME=") {
                let h = rest.trim().trim_matches('"').trim_matches('\'');
                if !h.is_empty() {
                    return h.to_string();
                }
            }
        }
    }
    if let Ok(h) = std::env::var("HOME") {
        if !h.is_empty() && h != "/root" {
            return h;
        }
    }
    format!("/home/{}", sys_user())
}

fn sys_uid(user: &str) -> u32 {
    if let Ok(passwd) = fs::read_to_string("/etc/passwd") {
        for line in passwd.lines() {
            let parts: Vec<&str> = line.split(':').collect();
            if parts.len() > 2 && parts[0] == user {
                if let Ok(uid) = parts[2].parse::<u32>() {
                    return uid;
                }
            }
        }
    }
    1000
}

fn get_desktop_env(uid: u32) -> HashMap<String, String> {
    let mut env = HashMap::new();
    env.insert("DISPLAY".to_string(), ":0".to_string());
    env.insert("XDG_RUNTIME_DIR".to_string(), format!("/run/user/{}", uid));
    env.insert(
        "DBUS_SESSION_BUS_ADDRESS".to_string(),
        format!("unix:path=/run/user/{}/bus", uid),
    );

    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            if let Ok(meta) = fs::metadata(entry.path()) {
                if meta.uid() == uid {
                    if let Ok(raw) = fs::read(format!("/proc/{}/environ", name)) {
                        let mut proc_vars = HashMap::new();
                        for item in raw.split(|b| *b == 0) {
                            if let Ok(s) = std::str::from_utf8(item) {
                                if let Some((k, v)) = s.split_once('=') {
                                    proc_vars.insert(k.to_string(), v.to_string());
                                }
                            }
                        }
                        if proc_vars.contains_key("WAYLAND_DISPLAY")
                            || proc_vars.contains_key("DISPLAY")
                        {
                            for k in [
                                "DISPLAY",
                                "WAYLAND_DISPLAY",
                                "XDG_RUNTIME_DIR",
                                "DBUS_SESSION_BUS_ADDRESS",
                            ] {
                                if let Some(v) = proc_vars.get(k) {
                                    env.insert(k.to_string(), v.clone());
                                }
                            }
                            return env;
                        }
                    }
                }
            }
        }
    }
    env
}

fn run_notify_send(title: &str, message: &str, urgency: &str, icon: &str) {
    let user = sys_user();
    let uid = sys_uid(&user);
    let env_map = get_desktop_env(uid);

    let is_root = unsafe { libc::geteuid() == 0 };
    let mut cmd = if is_root {
        let mut c = Command::new("sudo");
        c.arg("-u").arg(&user).arg("env");
        for (k, v) in &env_map {
            c.arg(format!("{}={}", k, v));
        }
        c.arg("notify-send");
        c
    } else {
        let mut c = Command::new("notify-send");
        for (k, v) in &env_map {
            c.env(k, v);
        }
        c
    };

    cmd.args(["-u", urgency, "-i", icon, title, message]);
    thread::spawn(move || {
        if let Ok(mut child) = cmd.spawn() {
            let _ = child.wait();
        }
    });
}

fn log_alert(alert_log: &str, signature_name: &str, raw_log: &str) {
    if let Some(parent) = Path::new(alert_log).parent() {
        let _ = fs::create_dir_all(parent);
    }
    let timestamp = Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(alert_log) {
        let _ = writeln!(
            file,
            "[{}] [CRITICAL ALERT] Match Found: {}\n    Raw Log Entry: {}\n",
            timestamp, signature_name, raw_log
        );
    }

    let summary = if raw_log.len() > 100 {
        &raw_log[..100]
    } else {
        raw_log
    };
    run_notify_send(
        "IDS Attack Detected",
        &format!("Signature: {}\nLog: {}...", signature_name, summary),
        "critical",
        "security-high",
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        println!("log-analyst - Lightweight Signature-Matching IDS Daemon\n\nTails ~/logs/recon-attempts.log and outputs matching alerts to ~/logs/ids-alerts.log.\n\nUsage: log-analyst [OPTIONS]\n\nOptions:\n  -h, --help    Show this help message and exit");
        return;
    }

    let home = sys_home();
    let log_file_path = format!("{}/logs/recon-attempts.log", home);
    let alert_log_path = format!("{}/logs/ids-alerts.log", home);

    let signatures = [
        (
            "Metasploit / Automated Login Scan",
            build_sig(r"CREDENTIALS HARVESTED.*(Username|USER)=(admin|root|1234)"),
        ),
        (
            "Directory Brute Force Attempt",
            build_sig(r"Directory brute-force detected|GET /(wp-admin|admin|config|backup|shell|phpmyadmin|\.env)"),
        ),
        (
            "Automated SSH Scanner Footprint",
            build_sig(r"\[PAYLOAD\] SSH packet.*(libssh|Paramiko|Go-SSH)"),
        ),
        (
            "SQL Injection Probing Pattern",
            build_sig(r"(' OR '1'='1|UNION SELECT|SELECT.*FROM|waitfor delay)"),
        ),
        (
            "Cross-Site Scripting Probe",
            build_sig(r"(<script>|alert\(|javascript:)"),
        ),
    ];

    if !Path::new(&log_file_path).exists() {
        println!(
            "[!] Target log file {} does not exist yet. Waiting for initialization...",
            log_file_path
        );
        if let Some(parent) = Path::new(&log_file_path).parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_file_path);
    }

    println!("[*] Lightweight Signature-Matching IDS Daemon Active (RAM safe)...");

    let file = match File::open(&log_file_path) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("Failed to open {}: {}", log_file_path, e);
            std::process::exit(1);
        }
    };

    let mut reader = BufReader::new(file);
    let _ = reader.seek(SeekFrom::End(0));

    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => {
                if let Ok(meta) = reader.get_ref().metadata() {
                    if let Ok(pos) = reader.stream_position() {
                        if pos > meta.len() {
                            let _ = reader.seek(SeekFrom::Start(0));
                        }
                    }
                }
                thread::sleep(Duration::from_millis(500));
            }
            Ok(_) => {
                let trimmed = line.trim();
                if !trimmed.is_empty() {
                    for (sig_name, reg) in &signatures {
                        if reg.is_match(trimmed) {
                            log_alert(&alert_log_path, sig_name, trimmed);
                            break;
                        }
                    }
                }
            }
            Err(_) => {
                thread::sleep(Duration::from_millis(500));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_signatures() {
        let metasploit_sig = build_sig(r"CREDENTIALS HARVESTED.*(Username|USER)=(admin|root|1234)");
        assert!(metasploit_sig.is_match("[ALERT] CREDENTIALS HARVESTED (FTP) from 1.2.3.4: USER=admin, PASS=secret"));

        let dir_sig = build_sig(r"Directory brute-force detected|GET /(wp-admin|admin|config|backup|shell|phpmyadmin|\.env)");
        assert!(dir_sig.is_match("Directory brute-force detected from 10.0.0.1 requesting: GET /wp-admin"));
        assert!(dir_sig.is_match("GET /phpmyadmin/index.php HTTP/1.1"));

        let ssh_sig = build_sig(r"\[PAYLOAD\] SSH packet.*(libssh|Paramiko|Go-SSH)");
        assert!(ssh_sig.is_match("[PAYLOAD] SSH packet from 1.2.3.4: SSH-2.0-Paramiko_2.7.2"));

        let sqli_sig = build_sig(r"(' OR '1'='1|UNION SELECT|SELECT.*FROM|waitfor delay)");
        assert!(sqli_sig.is_match("Probing: ' OR '1'='1 --"));
        assert!(sqli_sig.is_match("UNION SELECT 1,2,3"));

        let xss_sig = build_sig(r"(<script>|alert\(|javascript:)");
        assert!(xss_sig.is_match("<script>alert('xss')</script>"));
    }
}
