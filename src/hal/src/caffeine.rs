//! hal caffeine on [minutes] | off | toggle [minutes] | status

use crate::util;
use std::fs;
use std::process::Command;

const UNIT: &str = "halcyon-caffeine.service";
const UNIT_NAME: &str = "halcyon-caffeine";
const STATE_FILE: &str = "/dev/shm/halcyon-caffeine";

fn is_on() -> bool {
    util::ok("systemctl", &["--user", "is-active", "--quiet", UNIT])
}

fn note(msg: &str) {
    util::notify("Caffeine", msg, Some("weather-clear"), 2500);
}

fn status() -> i32 {
    if is_on() {
        println!("on");
    } else {
        println!("off");
        let _ = fs::remove_file(STATE_FILE);
    }
    0
}

fn off() -> i32 {
    let _ = util::ok("systemctl", &["--user", "stop", UNIT]);
    let _ = fs::remove_file(STATE_FILE);
    note("Off");
    0
}

fn on(mins_str: Option<&str>) -> i32 {
    let mins: Option<u64> = match mins_str {
        Some(s) if !s.is_empty() => match s.parse::<u64>() {
            Ok(m) if m > 0 && m <= 999_999 => Some(m),
            _ => {
                eprintln!("caffeine: minutes must be a whole number between 1 and 999999");
                return 2;
            }
        },
        _ => None,
    };

    if is_on() {
        let cur = util::out("systemctl", &["--user", "show", "-p", "RuntimeMaxUSec", "--value", UNIT]);
        let cur = cur.trim();
        if mins.is_none() && (cur.is_empty() || cur == "infinity") {
            return 0;
        }
        let _ = util::ok("systemctl", &["--user", "stop", UNIT]);
    }

    let mut args = vec![
        "--user".to_string(),
        "--quiet".to_string(),
        "--collect".to_string(),
        format!("--unit={}", UNIT_NAME),
    ];
    if let Some(m) = mins {
        args.push(format!("--property=RuntimeMaxSec={}m", m));
    }
    args.extend([
        "systemd-inhibit".to_string(),
        "--what=idle:sleep".to_string(),
        "--who=Halcyon".to_string(),
        "--why=Caffeine".to_string(),
        "--mode=block".to_string(),
        "sleep".to_string(),
        "infinity".to_string(),
    ]);

    let success = Command::new("systemd-run")
        .args(&args)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);

    if success {
        let _ = fs::write(STATE_FILE, "on\n");
        let text = match mins {
            Some(m) => format!("On for {} min: screen stays awake", m),
            None => "On: screen stays awake".to_string(),
        };
        note(&text);
        0
    } else {
        eprintln!("caffeine: could not start (is systemd-run / systemd-inhibit available?)");
        1
    }
}

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("toggle");
    let rest = if args.len() > 1 { Some(args[1].as_str()) } else { None };
    match cmd {
        "on" => on(rest),
        "off" => off(),
        "toggle" => {
            if is_on() {
                off()
            } else {
                on(rest)
            }
        }
        "status" => status(),
        _ => {
            eprintln!("usage: hal caffeine on [minutes] | off | toggle | status");
            2
        }
    }
}
