//! hal bt-set connect|disconnect|scan MAC [NAME]: what the Bluetooth list in the bar's panel runs.
//!   connect    pairs and trusts first when the device is not paired yet, then connects
//!   disconnect
//!   scan       bluetoothctl scans for 15 seconds in the background
//! Settings > Notifications > "only tell me about errors" (~/.local/state/island/conn-errors-only = 1) skips the success notifications.
//! Any other action returns 2 without a word: the bash original (the fallback of bt-set.sh) answers.

use crate::util;
use std::env;
use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::FileTypeExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// Wakes net.sh (the bar's Wi-Fi / Bluetooth label) so it shows the result now, not at its next slow tick.
/// The wake file is a named pipe; opening it for reading and writing never blocks.
fn poke_net() {
    let dir = env::var("XDG_RUNTIME_DIR").ok().filter(|v| !v.is_empty()).unwrap_or_else(|| "/tmp".to_string());
    let wake = PathBuf::from(dir).join("halcyon-net.wake");
    let is_fifo = fs::metadata(&wake).map(|m| m.file_type().is_fifo()).unwrap_or(false);
    if !is_fifo {
        return;
    }
    if let Ok(mut f) = OpenOptions::new().read(true).write(true).open(&wake) {
        let _ = f.write_all(b"\n");
    }
}

pub fn run(args: &[String]) -> i32 {
    let code = act(args);
    poke_net(); // on every way out, as the bash trap did
    code
}

fn act(args: &[String]) -> i32 {
    let action = args.first().map(|s| s.as_str()).unwrap_or("");
    let mac = args.get(1).map(|s| s.as_str()).unwrap_or("");
    let name = match args.get(2) {
        Some(n) if !n.is_empty() => n.as_str(),
        _ => mac,
    };
    if !matches!(action, "connect" | "disconnect" | "scan") {
        return 2;
    }

    if action == "scan" {
        let _ = Command::new("bluetoothctl")
            .args(["--timeout", "15", "scan", "on"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        return 0;
    }

    let quiet = util::first_line(&util::state_dir().join("conn-errors-only")).as_deref() == Some("1");

    if action == "connect" {
        // not paired yet: pair and trust first
        let info = util::out("bluetoothctl", &["info", mac]);
        if !info.contains("Paired: yes") {
            let _ = util::ok("bluetoothctl", &["pair", mac]);
            let _ = util::ok("bluetoothctl", &["trust", mac]);
        }
    }

    // stdout and stderr together, as `2>&1` had them
    let (succeeded, text) = match Command::new("bluetoothctl").args([action, mac]).stdin(Stdio::null()).output() {
        Ok(o) => {
            let mut t = String::from_utf8_lossy(&o.stdout).to_string();
            t.push_str(&String::from_utf8_lossy(&o.stderr));
            (o.status.success(), t)
        }
        Err(e) => (false, e.to_string()),
    };

    if succeeded && !text.to_lowercase().contains("fail") {
        if quiet {
            return 0;
        }
        let summary = if action == "connect" { "Connected" } else { "Disconnected" };
        util::notify_app("Bluetooth", summary, name, Some("bluetooth"));
    } else {
        let last = text.trim_end().lines().last().unwrap_or("");
        util::notify_app("Bluetooth", &format!("Couldn't {} {}", action, name), last, Some("dialog-warning"));
    }
    0
}
