//! hal close: close top overlay or active window

use crate::util;

pub fn run() -> i32 {
    let island_path = util::rice_dir().join("quickshell/island");
    let island_str = island_path.to_string_lossy().to_string();
    let res = util::out("quickshell", &["ipc", "-p", &island_str, "call", "island", "closeTop"]);
    if res.trim() == "closed" {
        return 0;
    }
    let _ = util::ok("hyprctl", &["dispatch", "hl.dsp.window.close()"]);
    0
}
