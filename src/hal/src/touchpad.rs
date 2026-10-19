//! hal touchpad [toggle | status]

use crate::util;
use std::env;
use std::fs;
use std::path::PathBuf;

fn status_path() -> PathBuf {
    let xdg = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(xdg).join("touchpad.status")
}

fn get_touchpad_device() -> Option<String> {
    let out = util::out("hyprctl", &["devices", "-j"]);
    for line in out.lines() {
        if line.contains("\"name\":") && line.to_lowercase().contains("touchpad") {
            if let Some(start) = line.find('\"') {
                let rest = &line[start + 1..];
                if let Some(colon) = rest.find(':') {
                    let val_part = &rest[colon + 1..];
                    if let Some(v_start) = val_part.find('\"') {
                        let after_quote = &val_part[v_start + 1..];
                        if let Some(v_end) = after_quote.find('\"') {
                            let name = &after_quote[..v_end];
                            if name.chars().all(|c| c.is_ascii_alphanumeric() || " _:./+@()-".contains(c)) {
                                return Some(name.to_string());
                            }
                        }
                    }
                }
            }
        }
    }
    None
}

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("toggle");
    let sp = status_path();

    match cmd {
        "status" => {
            let st = fs::read_to_string(&sp).unwrap_or_else(|_| "enabled".to_string());
            println!("{}", st.trim());
            0
        }
        "toggle" => {
            let dev = match get_touchpad_device() {
                Some(d) => d,
                None => {
                    util::notify("Touchpad", "No touchpad found", Some("input-touchpad"), 2500);
                    return 1;
                }
            };
            let current = fs::read_to_string(&sp).unwrap_or_else(|_| "enabled".to_string());
            let is_enabled = current.trim() == "enabled";
            let (new_st, flag_str) = if is_enabled {
                ("disabled", "false")
            } else {
                ("enabled", "true")
            };

            let eval_cmd = format!("hl.device({{ name = \"{}\", enabled = {} }})", dev, flag_str);
            let ok = util::ok("hyprctl", &["eval", &eval_cmd]);
            if ok {
                let _ = fs::write(&sp, format!("{}\n", new_st));
                let capitalized = if new_st == "enabled" { "Enabled" } else { "Disabled" };
                util::notify("Touchpad", capitalized, Some("input-touchpad"), 2000);
                0
            } else {
                util::notify("Touchpad", "Could not switch it (hyprctl failed)", Some("input-touchpad"), 2500);
                1
            }
        }
        _ => {
            eprintln!("usage: hal touchpad toggle | status");
            2
        }
    }
}
