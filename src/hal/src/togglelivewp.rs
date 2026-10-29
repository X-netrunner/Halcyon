//! hal toggle-livewallpaper [file|sky]

use std::path::PathBuf;
use std::process::Command;

pub fn run(args: &[String]) -> i32 {
    let home = crate::util::home();
    let island_dir = PathBuf::from(&home).join(".config/Halcyon/quickshell/island");
    let island_str = island_dir.to_string_lossy().to_string();

    if let Some(target) = args.first() {
        let ok = crate::util::ok(
            "quickshell",
            &["ipc", "-p", &island_str, "call", "wallpaper", "live", target],
        );
        if !ok {
            crate::util::notify("Live wallpaper", "The island is not running", None, 2500);
            return 1;
        }
        return 0;
    }

    let out = crate::util::out(
        "quickshell",
        &["ipc", "-p", &island_str, "call", "wallpaper", "toggleLive"],
    );
    let trimmed = out.trim();
    if trimmed.is_empty() {
        crate::util::notify("Live wallpaper", "The island is not running", None, 2500);
        return 1;
    }

    let body = if trimmed == "on" {
        "On"
    } else {
        "Off: back to your picture"
    };

    let _ = Command::new("notify-send")
        .args([
            "-a",
            "Halcyon",
            "-i",
            "video-display",
            "-h",
            "string:x-canonical-private-synchronous:livewallpaper",
            "Live wallpaper",
            body,
        ])
        .status();

    0
}
