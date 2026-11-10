//! hal login-status [status|enable-lock|remove-lock]

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

fn get_rice_dir() -> PathBuf {
    if let Ok(dir) = env::var("HALCYON_DIR") {
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    crate::util::rice_dir()
}

pub fn run(args: &[String]) -> i32 {
    let action = args.first().map(|s| s.as_str()).unwrap_or("status");
    match action {
        "status" => {
            let mut mode = "console";
            let mut dm = "none".to_string();
            let mut autologin = false;

            if crate::util::ok("systemctl", &["is-enabled", "display-manager.service"]) {
                if let Ok(target) = fs::read_link("/etc/systemd/system/display-manager.service") {
                    if let Some(file_name) = target.file_name().and_then(|n| n.to_str()) {
                        dm = file_name.strip_suffix(".service").unwrap_or(file_name).to_string();
                    }
                }
                mode = "display-manager";
            } else {
                let dms = ["sddm", "gdm", "gdm3", "lightdm", "greetd", "ly", "lxdm", "cosmic-greeter"];
                for candidate in &dms {
                    let unit = format!("{}.service", candidate);
                    if crate::util::ok("systemctl", &["is-enabled", &unit]) {
                        dm = (*candidate).to_string();
                        mode = "display-manager";
                        break;
                    }
                }
            }

            if Path::new("/etc/systemd/system/getty@tty1.service.d/halcyon-autologin.conf").exists() {
                autologin = true;
                mode = "lock-screen";
            }

            println!(
                "{{\"mode\":\"{}\",\"dm\":\"{}\",\"autologin\":{}}}",
                mode, dm, autologin
            );
            0
        }
        "enable-lock" => {
            let rice = get_rice_dir();
            let script = rice.join("install.sh");
            if script.exists() {
                let _ = Command::new("pkexec")
                    .args([
                        "bash",
                        &script.to_string_lossy(),
                        "--lock-login",
                        "--no-packages",
                        "--no-drivers",
                        "--yes",
                    ])
                    .status();
            }
            0
        }
        "remove-lock" => {
            let rice = get_rice_dir();
            let script = rice.join("install.sh");
            if script.exists() {
                let _ = Command::new("pkexec")
                    .args(["bash", &script.to_string_lossy(), "--remove-lock-login"])
                    .status();
            }
            0
        }
        _ => {
            eprintln!("Usage: hal login-status [status|enable-lock|remove-lock]");
            1
        }
    }
}
