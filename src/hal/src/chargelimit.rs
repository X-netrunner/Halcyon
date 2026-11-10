//! hal charge-limit: control battery charge threshold

use crate::util;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn find_threshold_file() -> Option<PathBuf> {
    let power_dir = Path::new("/sys/class/power_supply");
    if let Ok(entries) = fs::read_dir(power_dir) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with("BAT") {
                let candidate = entry.path().join("charge_control_end_threshold");
                if candidate.exists() {
                    return Some(candidate);
                }
            }
        }
    }
    None
}

pub fn run(args: &[String]) -> i32 {
    let limit_env = env::var("HALCYON_CHARGE_LIMIT").unwrap_or_else(|_| "80".to_string());
    let limit: u32 = limit_env.parse::<u32>().unwrap_or(80).clamp(40, 99);

    let threshold_file = match find_threshold_file() {
        Some(f) => f,
        None => {
            println!("none");
            return 0;
        }
    };

    let cur_str = fs::read_to_string(&threshold_file).unwrap_or_default();
    let cur: u32 = match cur_str.trim().parse() {
        Ok(val) => val,
        Err(_) => {
            println!("none");
            return 0;
        }
    };

    let action = args.first().map(|s| s.as_str()).unwrap_or("status");
    let new_val = match action {
        "status" => {
            println!("{}", cur);
            return 0;
        }
        "toggle" => {
            if cur < 100 {
                100
            } else {
                limit
            }
        }
        "on" => limit,
        "off" => 100,
        _ => {
            eprintln!("usage: hal charge-limit status | toggle | on | off");
            return 2;
        }
    };

    if fs::write(&threshold_file, format!("{}\n", new_val)).is_ok() {
        println!("{}", new_val);
        0
    } else {
        let f_display = threshold_file.display().to_string();
        let _ = util::ok(
            "notify-send",
            &[
                "-a",
                "Halcyon",
                "-i",
                "battery",
                "Charge limit",
                &format!(
                    "Cannot change it: your user may not write {}. Install the udev rule (udev/90-halcyon-battery.rules, install.sh does it) and log in again.",
                    f_display
                ),
            ],
        );
        println!("{}", cur);
        1
    }
}
