//! hal supertap: handle Super key tap to trigger launcher

use crate::util;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

pub fn run() -> i32 {
    let xdg = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    let trigger_path = PathBuf::from(&xdg).join("halcyon-super-tap");
    let ack_path = PathBuf::from(&xdg).join("halcyon-super-ack");
    let pid = std::process::id().to_string();

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
