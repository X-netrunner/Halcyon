//! hal reload: reload Hyprland and rice terminal colors

use std::path::PathBuf;

pub fn run() -> i32 {
    let _ = crate::util::ok("hyprctl", &["reload"]);

    let home = crate::util::home();
    let term_colors = PathBuf::from(&home).join(".config/Halcyon/scripts/term-colors.sh");
    if term_colors.exists() {
        let _ = crate::util::ok("bash", &[&term_colors.to_string_lossy(), "--now"]);
    } else {
        let _ = crate::util::ok("term-colors.sh", &["--now"]);
    }

    0
}
