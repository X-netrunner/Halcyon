//! hal polkit-agent [check]: make sure a polkit agent (the program that shows the "enter your password" window) runs in this session.
//! Used by the Security center before it asks for a password with pkexec: without an agent pkexec fails at once with
//! "No authentication agent found" and nothing is shown. Prints  running | started NAME | none | nopkexec  and exits 0, or 1.
//!
//!   polkit-agent          check, and start one if none is running (the lightest installed: Hyprland's, GNOME's, KDE's)
//!   polkit-agent check    only check
//!
//! Not started when Settings > Startup chose "None" for the polkit agent (POLKIT=none in ~/.config/Halcyon/autostart.conf).

use crate::util;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::thread;
use std::time::Duration;

const HYPR: &[&str] = &["/usr/lib/hyprpolkitagent/hyprpolkitagent"];
const GNOME: &[&str] = &[
    "/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1",
    "/usr/libexec/polkit-gnome-authentication-agent-1",
    "/usr/lib/x86_64-linux-gnu/polkit-gnome-authentication-agent-1",
];
const KDE: &[&str] = &[
    "/usr/lib/polkit-kde-authentication-agent-1",
    "/usr/libexec/polkit-kde-authentication-agent-1",
    "/usr/lib/x86_64-linux-gnu/libexec/polkit-kde-authentication-agent-1",
];
/// Every agent that shows a password window, as an extended regular expression for pgrep -f.
const RUNNING: &str = "hyprpolkitagent|polkit-gnome-authentication-agent|polkit-kde-authentication-agent|lxqt-policykit|mate-polkit|polkit-mate-authentication-agent|xfce-polkit|polkit-dumb-agent|soteria|lxpolkit";

fn first_exec(paths: &[&str]) -> Option<String> {
    for p in paths {
        if let Ok(m) = fs::metadata(*p) {
            if m.is_file() && m.permissions().mode() & 0o111 != 0 {
                return Some((*p).to_string());
            }
        }
    }
    None
}

/// The agent for the Settings choice; when that one is not installed, any installed one is better than none.
fn pick_agent(choice: &str) -> Option<String> {
    let all: Vec<&str> = HYPR
        .iter()
        .chain(GNOME.iter())
        .chain(KDE.iter())
        .copied()
        .collect();
    let chosen = match choice {
        "hyprpolkitagent" => first_exec(HYPR),
        "gnome" => first_exec(GNOME),
        "kde" => first_exec(KDE),
        _ => first_exec(&all),
    };
    chosen.or_else(|| first_exec(&all))
}

fn running(uid: &str) -> bool {
    util::ok("pgrep", &["-u", uid, "-f", RUNNING])
}

pub fn run(args: &[String]) -> i32 {
    if !util::command_exists("pkexec") {
        println!("nopkexec");
        return 1;
    }
    let uid = util::out("id", &["-u"]).trim().to_string();
    if running(&uid) {
        println!("running");
        return 0;
    }
    if args.first().map(|s| s.as_str()) == Some("check") {
        println!("none");
        return 1;
    }
    let conf = util::rice_dir().join("autostart.conf");
    let setting = fs::read_to_string(&conf)
        .ok()
        .and_then(|t| util::conf_value(&t, "POLKIT"))
        .unwrap_or_else(|| "auto".to_string());
    if setting == "none" {
        println!("none");
        return 1;
    }
    let agent = match pick_agent(&setting) {
        Some(a) => a,
        None => {
            println!("none");
            return 1;
        }
    };
    // setsid -f: the agent must outlive this helper and not belong to the island's process group
    let _ = util::ok("setsid", &["-f", &agent]);
    let name = Path::new(&agent)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    for _ in 0..20 {
        if running(&uid) {
            println!("started {}", name);
            return 0;
        }
        thread::sleep(Duration::from_millis(200));
    }
    println!("none");
    1
}
