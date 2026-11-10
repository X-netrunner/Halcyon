//! hal gestures [toggle | status]

use crate::util;
use std::fs;
use std::path::Path;

const LOCK_FILE: &str = "/dev/shm/touchpad_music_gestures_disabled";

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("toggle");
    let path = Path::new(LOCK_FILE);
    match cmd {
        "status" => {
            if path.exists() {
                println!("off");
            } else {
                println!("on");
            }
            0
        }
        "toggle" => {
            if path.exists() {
                let _ = fs::remove_file(path);
                util::notify("Music Gestures", "Enabled", Some("input-touchpad"), 2000);
            } else {
                let _ = fs::write(path, "");
                util::notify("Music Gestures", "Disabled", Some("input-touchpad"), 2000);
            }
            0
        }
        _ => {
            eprintln!("usage: hal gestures [toggle|status]");
            2
        }
    }
}
