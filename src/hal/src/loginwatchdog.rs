//! hal login-watchdog: lock-screen watchdog for login

use std::fs;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

fn submap(name: &str) {
    let arg = format!("hl.dsp.submap(\"{}\")", name);
    let _ = crate::util::ok("hyprctl", &["dispatch", &arg]);
}

pub fn run() -> i32 {
    let home = crate::util::home();
    let flag = PathBuf::from(&home).join(".cache/island/lock-on-start");
    if !flag.exists() {
        return 0;
    }

    submap("halcyon-locking");

    for _ in 0..20 {
        thread::sleep(Duration::from_secs(1));
        if !flag.exists() {
            thread::sleep(Duration::from_secs(2));
            submap("reset");
            return 0;
        }
    }

    let _ = fs::remove_file(&flag);
    submap("reset");

    if crate::util::command_exists("hyprlock") && crate::util::ok("hyprlock", &[]) {
        return 0;
    }

    let _ = crate::util::ok("hyprctl", &["dispatch", "hl.dsp.exit()"]);
    let _ = crate::util::ok("pkill", &["-x", "Hyprland"]);
    0
}
