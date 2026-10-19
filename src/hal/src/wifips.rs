//! hal wifips [on | off | toggle | status | apply]

use crate::util;
use std::fs;
use std::path::PathBuf;

const HELPER: &str = "/usr/local/bin/halcyon-tune";

fn saved_path() -> PathBuf {
    util::state_dir().join("wifi-powersave")
}

fn is_on() -> bool {
    if !util::command_exists("iw") {
        return false;
    }
    let dev_out = util::out("iw", &["dev"]);
    for line in dev_out.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 2 && parts[0] == "Interface" {
            let iface = parts[1];
            let ps_out = util::out("iw", &["dev", iface, "get", "power_save"]);
            if ps_out.to_lowercase().contains("power save: on") {
                return true;
            }
        }
    }
    false
}

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("toggle");
    match cmd {
        "status" => {
            if is_on() {
                println!("on");
            } else {
                println!("off");
            }
            0
        }
        "apply" => {
            let p = saved_path();
            if let Ok(s) = fs::read_to_string(&p) {
                let want = s.trim();
                if (want == "on" || want == "off") && !PathBuf::from("/run/halcyon-tune.saved").exists() {
                    let _ = util::ok("sudo", &["-n", HELPER, "wifi-ps", want]);
                }
            }
            0
        }
        "on" | "off" | "toggle" => {
            let want = match cmd {
                "on" => "on",
                "off" => "off",
                _ => if is_on() { "off" } else { "on" },
            };
            if !util::command_exists("iw") {
                util::notify("Wi-Fi power saving", "iw is not installed", Some("dialog-warning"), 2500);
                return 1;
            }
            let success = util::ok("sudo", &["-n", HELPER, "wifi-ps", want]);
            if success {
                let _ = fs::create_dir_all(util::state_dir());
                let _ = fs::write(saved_path(), format!("{}\n", want));
                let msg = if want == "on" { "On: saves battery" } else { "Off: lowest latency" };
                util::notify("Wi-Fi power saving", msg, Some("network-wireless"), 2500);
                0
            } else {
                util::notify("Wi-Fi power saving", "Could not change it: run install.sh again", Some("dialog-warning"), 3000);
                1
            }
        }
        _ => {
            eprintln!("usage: hal wifips on | off | toggle | status | apply");
            2
        }
    }
}
