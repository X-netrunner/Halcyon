//! hal lock: lock the screen with Halcyon's own lock screen (quickshell/island/Lock.qml).
//! Falls back to hyprlock when the island is not running, so you can never end up unable to lock.
//! Use it as hypridle's lock_cmd:  lock_cmd = ~/.config/Halcyon/scripts/lock.sh   (that script runs this)

use crate::util;
use std::os::unix::process::CommandExt;
use std::process::Command;

pub fn run() -> i32 {
    let island = util::rice_dir().join("quickshell/island");
    let island = island.to_string_lossy().to_string();
    if util::ok_timeout("quickshell", &["ipc", "-p", &island, "call", "island", "lock"], 2000) {
        return 0;
    }
    if util::command_exists("hyprlock") {
        // exec: hyprlock becomes this process, so hypridle waits for the real lock screen
        let err = Command::new("hyprlock").exec();
        eprintln!("lock: could not start hyprlock: {}", err);
        return 1;
    }
    util::notify("Lock screen", "The island is not running and hyprlock is not installed", None, 5000);
    1
}
