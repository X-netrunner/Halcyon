//! hal supertap: handle Super key tap to trigger launcher

use crate::util;
use std::env;
use std::fs;
use std::path::PathBuf;

pub fn run() -> i32 {
    let xdg = env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".to_string());
    let trigger_path = PathBuf::from(&xdg).join("halcyon-super-tap");
    let pid = std::process::id().to_string();

    let write_ok = fs::write(&trigger_path, format!("{}\n", pid)).is_ok();
    if write_ok {
        return 0;
    }

    // Fallback: IPC call to island
    let island_path = util::rice_dir().join("quickshell/island");
    let island_str = island_path.to_string_lossy().to_string();
    let _ = util::ok("quickshell", &["ipc", "-p", &island_str, "call", "island", "supertap"]);
    0
}
