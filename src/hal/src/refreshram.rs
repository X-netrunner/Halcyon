//! hal refresh-ram [--gui]: RAM type / speed / channels for the performance page.
//! dmidecode needs root, the island does not, so the output is saved once to ~/.cache/island/dmi-memory.txt
//! (and /var/lib/halcyon/dmi-memory.txt, refreshed at every boot by halcyon-ram.service, which install.sh sets up).
//!   refresh-ram          terminal: asks for sudo
//!   refresh-ram --gui    from the island (Settings > Detect RAM details): asks with a password window (polkit)

use crate::util;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn msg(gui: bool, text: &str) {
    if gui {
        util::notify_app("Halcyon", "RAM details", text, None);
    } else {
        println!("{}", text);
    }
}

/// The few lines worth showing in the terminal: size, type, speed and slot of each module, up to 12.
fn summary_lines(text: &str) -> Vec<&str> {
    const KEYS: [&str; 5] = [
        "Size:",
        "Type:",
        "Speed:",
        "Configured Memory Speed:",
        "Locator:",
    ];
    text.lines()
        .filter(|l| {
            let t = l.trim_start();
            KEYS.iter().any(|k| t.starts_with(*k)) && !l.contains("No Module")
        })
        .take(12)
        .collect()
}

pub fn run(args: &[String]) -> i32 {
    let gui = args.first().map(|s| s.as_str()) == Some("--gui");
    if !util::command_exists("dmidecode") {
        msg(gui, "dmidecode is not installed:  sudo pacman -S dmidecode");
        return 1;
    }
    let prog = if gui { "pkexec" } else { "sudo" };
    // stdin stays the terminal so sudo can ask for the password; its other chatter is thrown away
    let text = match Command::new(prog)
        .args(["dmidecode", "-t", "memory"])
        .stdin(Stdio::inherit())
        .stderr(Stdio::null())
        .output()
    {
        Ok(o) => String::from_utf8_lossy(&o.stdout).to_string(),
        Err(_) => String::new(),
    };
    if text.contains("Memory Device") {
        let out = PathBuf::from(util::home()).join(".cache/island/dmi-memory.txt");
        if let Some(dir) = out.parent() {
            let _ = fs::create_dir_all(dir);
        }
        if fs::write(&out, &text).is_err() {
            msg(
                gui,
                "Could not save the RAM details to ~/.cache/island/dmi-memory.txt.",
            );
            return 1;
        }
        let _ = fs::set_permissions(&out, fs::Permissions::from_mode(0o644));
        msg(
            gui,
            "Saved. Reopen the Performance page (or restart the island) to see type and speed.",
        );
        if !gui {
            for line in summary_lines(&text) {
                println!("{}", line);
            }
        }
        0
    } else {
        msg(
            gui,
            "dmidecode returned no memory info (password cancelled, or the BIOS hides it). The page keeps showing the size only.",
        );
        1
    }
}

#[cfg(test)]
mod tests {
    use super::summary_lines;

    #[test]
    fn summary_keeps_the_module_lines_only() {
        let t = "Memory Device\n\tSize: 8 GB\n\tType: DDR5\n\tType Detail: Synchronous\n\tSpeed: 5600 MT/s\n\
                 \tLocator: DIMM A\nMemory Device\n\tSize: No Module Installed\n\tConfigured Memory Speed: 5200 MT/s\n";
        let got = summary_lines(t);
        assert_eq!(got.len(), 5);
        assert!(got[0].contains("8 GB"));
        assert!(!got.iter().any(|l| l.contains("Type Detail")));
        assert!(!got.iter().any(|l| l.contains("No Module")));
        assert!(got[4].contains("Configured Memory Speed"));
    }
}
