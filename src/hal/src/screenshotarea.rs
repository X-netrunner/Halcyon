//! hal screenshot-area : drag a region, save to ~/Pictures/Screenshots, and copy to clipboard

use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn run() -> i32 {
    let home = crate::util::home();
    let dir = PathBuf::from(&home).join("Pictures/Screenshots");
    let _ = fs::create_dir_all(&dir);

    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let file = dir.join(format!("{}.png", epoch));
    let file_str = file.to_string_lossy().to_string();

    let mut freeze_child = if crate::util::command_exists("wayfreeze") {
        let child = Command::new("wayfreeze")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .ok();
        thread::sleep(Duration::from_millis(200));
        child
    } else {
        None
    };

    let geom = crate::util::out("slurp", &["-d"]);
    let geom_trim = geom.trim();

    let mut success = false;
    if !geom_trim.is_empty() {
        let grim_ok = crate::util::ok("grim", &["-g", geom_trim, &file_str]);
        if grim_ok {
            success = true;
        }
    }

    if let Some(mut child) = freeze_child.take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    if success {
        if let Ok(file_handle) = fs::File::open(&file) {
            let _ = Command::new("wl-copy")
                .stdin(file_handle)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status();
        }

        let _ = Command::new("notify-send")
            .args([
                "Screenshot",
                "Saved and copied",
                "-i",
                &file_str,
                "-h",
                "string:x-canonical-private-synchronous:screenshot",
            ])
            .status();
        0
    } else {
        1
    }
}
