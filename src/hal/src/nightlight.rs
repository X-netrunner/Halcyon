//! hal nightlight [on | off | toggle | temp <K> | status]

use crate::util;
use std::fs;
use std::path::PathBuf;
use std::process::Command;

fn state_path() -> PathBuf {
    util::state_dir().join("nightlight-temp")
}

fn get_temp() -> String {
    if let Ok(s) = fs::read_to_string(state_path()) {
        let t = s.trim();
        if t.chars().all(|c| c.is_ascii_digit()) && !t.is_empty() {
            return t.to_string();
        }
    }
    std::env::var("NIGHTLIGHT_TEMP").unwrap_or_else(|_| "4000".to_string())
}

fn is_running() -> bool {
    util::ok("pgrep", &["-x", "hyprsunset"])
}

fn start_hyprsunset(temp: &str) {
    let _ = util::ok("pkill", &["-x", "hyprsunset"]);
    let _ = Command::new("hyprsunset")
        .args(["-t", temp])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("toggle");
    let _ = fs::create_dir_all(util::state_dir());
    let temp = get_temp();

    match cmd {
        "status" => {
            if is_running() {
                println!("on");
            } else {
                println!("off");
            }
            0
        }
        "temp" => {
            if let Some(val) = args.get(1) {
                if val.chars().all(|c| c.is_ascii_digit()) && !val.is_empty() {
                    let _ = fs::write(state_path(), format!("{}\n", val));
                    if is_running() && util::command_exists("hyprsunset") {
                        start_hyprsunset(val);
                    }
                    return 0;
                }
            }
            eprintln!("usage: hal nightlight temp <K>");
            1
        }
        "on" => {
            if is_running() {
                return 0;
            }
            if util::command_exists("hyprsunset") {
                start_hyprsunset(&temp);
                util::notify("Nightlight", &format!("On ({}K)", temp), Some("weather-clear-night"), 2500);
            } else {
                util::notify("Nightlight", "hyprsunset is not installed", Some("dialog-warning"), 3000);
            }
            0
        }
        "off" => {
            if is_running() {
                let _ = util::ok("pkill", &["-x", "hyprsunset"]);
                util::notify("Nightlight", "Off", Some("weather-clear"), 2500);
            }
            0
        }
        "toggle" => {
            if is_running() {
                let _ = util::ok("pkill", &["-x", "hyprsunset"]);
                util::notify("Nightlight", "Off", Some("weather-clear"), 2500);
            } else if util::command_exists("hyprsunset") {
                start_hyprsunset(&temp);
                util::notify("Nightlight", &format!("On ({}K)", temp), Some("weather-clear-night"), 2500);
            } else {
                util::notify("Nightlight", "hyprsunset is not installed", Some("dialog-warning"), 3000);
            }
            0
        }
        _ => {
            eprintln!("usage: hal nightlight on | off | toggle | temp <K> | status");
            2
        }
    }
}
