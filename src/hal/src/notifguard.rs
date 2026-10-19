//! hal notif-guard: terminate competing notification daemons before island starts

use crate::util;

pub fn run() -> i32 {
    let targets = [
        "mako",
        "dunst",
        "swaync",
        "xfce4-notifyd",
        "notification-daemon",
        "mate-notification-daemon",
        "deadd-notification-center",
        "fnott",
    ];
    for d in targets {
        let _ = util::ok("pkill", &["-x", d]);
    }
    let _ = util::ok("pkill", &["-f", "quickshell.*caelestia"]);
    let _ = util::ok("pkill", &["-f", "qs .*-c caelestia"]);
    0
}
