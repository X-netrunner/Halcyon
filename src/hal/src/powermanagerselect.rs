//! hal power-manager-select <mgr> [quiet]

use std::fs;
use std::process::Command;

fn note(msg: &str) {
    let _ = Command::new("notify-send")
        .args([
            "-a",
            "Halcyon",
            "-i",
            "battery",
            "Power manager",
            msg,
            "-h",
            "string:x-canonical-private-synchronous:powermanager",
        ])
        .status();
}

pub fn run(args: &[String]) -> i32 {
    let mgr = args.first().map(|s| s.as_str()).unwrap_or("halcyon");
    let quiet = args.get(1).map(|s| s.as_str()).unwrap_or("");

    let state_dir = crate::util::state_dir();
    let _ = fs::create_dir_all(&state_dir);

    let bin_req = match mgr {
        "power-profiles-daemon" => Some("powerprofilesctl"),
        "tlp" => Some("tlp"),
        "auto-cpufreq" => Some("auto-cpufreq"),
        "tuned" => Some("tuned-adm"),
        _ => None,
    };

    if let Some(bin) = bin_req {
        if !crate::util::command_exists(bin) {
            note(&format!(
                "{} is not installed. Install it first (pacman -S {}), the previous manager stays active.",
                mgr, mgr
            ));
            return 1;
        }
    }

    let tune_output = Command::new("sudo")
        .args(["-n", "/usr/local/bin/halcyon-tune", "pm", mgr])
        .output();

    match tune_output {
        Ok(out) if out.status.success() => {}
        Ok(out) => {
            let err = String::from_utf8_lossy(&out.stderr);
            let last_line = err.lines().last().unwrap_or("run install.sh again to set up halcyon-tune");
            note(&format!("Could not switch to {}: {}", mgr, last_line));
            return 1;
        }
        Err(e) => {
            note(&format!("Could not run halcyon-tune: {}", e));
            return 1;
        }
    }

    let _ = fs::write(state_dir.join("power-manager"), format!("{}\n", mgr));

    if mgr == "halcyon" {
        let _ = crate::util::ok("systemctl", &["--user", "start", "power-manager.service"]);
        if quiet != "quiet" {
            note("Halcyon Auto power is on");
        }
    } else {
        let _ = crate::util::ok("systemctl", &["--user", "stop", "power-manager.service"]);
        if quiet != "quiet" {
            note(&format!("Now using {} (Halcyon Auto stopped)", mgr));
        }
    }

    0
}
