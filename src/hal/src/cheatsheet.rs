//! hal cheatsheet: display cheatsheet via Quickshell or fuzzel

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub fn run() -> i32 {
    let home = crate::util::home();
    let island_dir = PathBuf::from(&home).join(".config/Halcyon/quickshell/island");
    let island_str = island_dir.to_string_lossy().to_string();

    if crate::util::ok(
        "quickshell",
        &["ipc", "-p", &island_str, "call", "island", "cheatsheet"],
    ) {
        return 0;
    }

    if crate::util::ok("pkill", &["-f", "fuzzel.*--prompt=Keys"]) {
        return 0;
    }

    let binds_file = island_dir.join("Binds.js");
    let mut list = String::new();
    if let Ok(content) = fs::read_to_string(&binds_file) {
        for line in content.lines() {
            if let (Some(label_idx), Some(keys_idx)) = (line.find("label: \""), line.find("keys: \"")) {
                let after_label = &line[label_idx + 8..];
                let label = after_label.split('"').next().unwrap_or("");
                let after_keys = &line[keys_idx + 7..];
                let keys = after_keys.split('"').next().unwrap_or("");
                if !label.is_empty() && !keys.is_empty() {
                    list.push_str(&format!("{:<16} {}\n", keys, label));
                }
            }
        }
    }

    if !list.is_empty() {
        if let Ok(mut child) = Command::new("fuzzel")
            .args(["--dmenu", "--prompt=Keys > ", "--lines=18", "--width=72"])
            .stdin(Stdio::piped())
            .spawn()
        {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(list.as_bytes());
            }
            let _ = child.wait();
        }
    }

    0
}
