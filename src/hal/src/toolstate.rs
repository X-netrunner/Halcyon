//! hal tool-state: JSON state of tool toggles (nightlight, touchpad, gestures, wifips, temp)

use crate::util;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn is_hyprsunset_running() -> bool {
    let proc_dir = Path::new("/proc");
    if let Ok(entries) = fs::read_dir(proc_dir) {
        for entry in entries.flatten() {
            let fname = entry.file_name();
            let s = fname.to_string_lossy();
            if s.chars().all(|c| c.is_ascii_digit()) {
                let comm_file = entry.path().join("comm");
                if let Ok(comm) = fs::read_to_string(comm_file) {
                    if comm.trim() == "hyprsunset" {
                        return true;
                    }
                }
            }
        }
    }
    false
}

pub fn run() -> i32 {
    let nightlight = is_hyprsunset_running();
    let nightlight_ok = util::command_exists("hyprsunset");

    let xdg = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    let tp_status_path = PathBuf::from(&xdg).join("touchpad.status");
    let touchpad = match fs::read_to_string(&tp_status_path) {
        Ok(s) => s.trim() != "disabled",
        Err(_) => true,
    };

    let gestures_disabled = Path::new("/dev/shm/touchpad_music_gestures_disabled").exists();
    let gestures = !gestures_disabled;

    let mut wifi_ok = false;
    let mut wifips = false;
    if util::command_exists("iw") {
        let dev_out = util::out("iw", &["dev"]);
        for line in dev_out.lines() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 2 && parts[0] == "Interface" {
                wifi_ok = true;
                let iface = parts[1];
                let ps_out = util::out("iw", &["dev", iface, "get", "power_save"]);
                if ps_out.to_lowercase().contains("power save: on") {
                    wifips = true;
                }
            }
        }
    }

    let temp_file = util::state_dir().join("nightlight-temp");
    let temp: u32 = match fs::read_to_string(&temp_file) {
        Ok(s) => s.trim().parse::<u32>().unwrap_or(4000),
        Err(_) => 4000,
    };

    println!(
        r#"{{"nightlight":{},"nightlightOk":{},"touchpad":{},"gestures":{},"wifips":{},"wifiOk":{},"temp":{}}}"#,
        nightlight, nightlight_ok, touchpad, gestures, wifips, wifi_ok, temp
    );
    0
}
