//! hal toggle-power: toggle the power-manager systemd user service

use std::process::Command;

fn notify_power(summary: &str, body: &str, icon: &str) {
    let _ = Command::new("notify-send")
        .args([
            summary,
            body,
            "-i",
            icon,
            "-h",
            "string:x-canonical-private-synchronous:powermanager",
        ])
        .status();
}

pub fn run() -> i32 {
    let is_active = crate::util::ok("systemctl", &["--user", "is-active", "--quiet", "power-manager.service"]);
    if is_active {
        let _ = crate::util::ok("systemctl", &["--user", "stop", "power-manager.service"]);
        notify_power("Power Manager", "Disabled (Manual Mode)", "battery-caution");
    } else {
        let _ = crate::util::ok("systemctl", &["--user", "start", "power-manager.service"]);
        notify_power("Power Manager", "Enabled (Automatic Mode)", "battery");
    }
    0
}
