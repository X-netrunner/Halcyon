//! hal supertap: handle Super key tap to trigger launcher

use crate::util;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

/// The Super binds (SUPER_L, SUPER_R and both "SUPER + ..." spellings) can all fire on ONE key release. Only the first process may
/// carry on; the rest exit at once, so a single tap can never toggle the launcher open and straight shut again.
fn claim(lock: &Path) -> bool {
    for _ in 0..2 {
        match OpenOptions::new().write(true).create_new(true).open(lock) {
            Ok(_) => return true,
            Err(e) if e.kind() == ErrorKind::AlreadyExists => {
                let fresh = lock
                    .metadata()
                    .and_then(|m| m.modified())
                    .ok()
                    .and_then(|t| t.elapsed().ok())
                    .map_or(false, |age| age < Duration::from_millis(300));
                if fresh {
                    return false;
                }
                let _ = fs::remove_file(lock); // stale lock from an earlier tap
            }
            Err(_) => return true, // cannot tell: never block the tap
        }
    }
    true
}

pub fn run() -> i32 {
    let xdg = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    let trigger_path = PathBuf::from(&xdg).join("halcyon-super-tap");
    let ack_path = PathBuf::from(&xdg).join("halcyon-super-ack");
    let pid = std::process::id().to_string();

    if !claim(&PathBuf::from(&xdg).join("halcyon-super-lock")) {
        return 0;
    }

    let _ = fs::write(&trigger_path, format!("{}\n", pid));

    // Wait up to ~150ms for the island to touch halcyon-super-ack
    for _ in 0..5 {
        if let (Ok(ack_meta), Ok(trig_meta)) = (ack_path.metadata(), trigger_path.metadata()) {
            if let (Ok(ack_mtime), Ok(trig_mtime)) = (ack_meta.modified(), trig_meta.modified()) {
                if ack_mtime >= trig_mtime {
                    return 0;
                }
            }
        }
        thread::sleep(Duration::from_millis(30));
    }

    // Fallback: IPC call to island
    let island_path = util::rice_dir().join("quickshell/island");
    let island_str = island_path.to_string_lossy().to_string();
    let _ = util::ok("quickshell", &["ipc", "-p", &island_str, "call", "island", "supertap"]);
    0
}
