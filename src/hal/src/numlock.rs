//! hal numlock [status | toggle | on | off]

use crate::util;
use std::fs;
use std::thread::sleep;
use std::time::Duration;

fn status() -> String {
    let out = util::out("hyprctl", &["devices", "-j"]);
    for line in out.lines() {
        if line.contains("\"numLock\":") {
            let is_on = line.contains("true");
            return if is_on { "on".to_string() } else { "off".to_string() };
        }
    }
    // Fallback: sysfs
    if let Ok(entries) = fs::read_dir("/sys/class/leds") {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.contains("numlock") {
                let p = entry.path().join("brightness");
                if let Ok(s) = fs::read_to_string(p) {
                    if s.trim() != "0" {
                        return "on".to_string();
                    } else {
                        return "off".to_string();
                    }
                }
            }
        }
    }
    "off".to_string()
}

fn press() -> bool {
    if util::command_exists("ydotool") && util::ok("ydotool", &["key", "69:1", "69:0"]) {
        return true;
    }
    if util::command_exists("wtype") && util::ok("wtype", &["-k", "Num_Lock"]) {
        return true;
    }
    false
}

fn flip() -> i32 {
    let before = status();
    if !press() {
        util::notify("Num Lock", "Could not press key: ydotool needed", Some("input-keyboard"), 3000);
        return 1;
    }
    sleep(Duration::from_millis(250));
    let after = status();
    if after == before {
        util::notify("Num Lock", "Key sent but Num Lock did not change", Some("input-keyboard"), 3000);
        return 1;
    }
    0
}

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("toggle");
    match cmd {
        "status" => {
            println!("{}", status());
            0
        }
        "toggle" => flip(),
        "on" => {
            if status() != "on" {
                flip()
            } else {
                0
            }
        }
        "off" => {
            if status() != "off" {
                flip()
            } else {
                0
            }
        }
        _ => {
            eprintln!("usage: hal numlock status | toggle | on | off");
            2
        }
    }
}
