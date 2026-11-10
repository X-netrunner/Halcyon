//! hal theme dark|light: tell the rest of the desktop which theme the island is using.
//! The island itself (bar, panels, lock screen, Hyprland borders) follows the setting on its own; this makes GTK 3/4,
//! libadwaita and portal-aware apps (Firefox, Chromium, Nautilus ...) switch with it.

use crate::util;
use std::fs;

pub fn run(args: &[String]) -> i32 {
    let mode = match args.first() {
        Some(m) if !m.is_empty() => m.as_str(),
        _ => "dark",
    };
    let dir = util::state_dir();
    let _ = fs::create_dir_all(&dir);
    let _ = fs::write(dir.join("theme"), format!("{}\n", mode));
    if util::command_exists("gsettings") {
        let scheme = if mode == "light" { "prefer-light" } else { "prefer-dark" };
        let _ = util::ok("gsettings", &["set", "org.gnome.desktop.interface", "color-scheme", scheme]);
    }
    // GTK apps (Thunar ...) get the matching colours; still bash for now, so it is run, not ported
    let gtk = util::scripts_dir().join("gtk-theme.sh");
    let gtk = gtk.to_string_lossy().to_string();
    let _ = util::ok("bash", &[&gtk, "--auto"]);
    0
}
