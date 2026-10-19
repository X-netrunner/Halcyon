//! Small helpers shared by the ports. std only.

use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub fn home() -> String {
    env::var("HOME").unwrap_or_else(|_| "/tmp".to_string())
}

/// ~/.local/state/island : where Settings keeps the one-line state files and gestures.conf
pub fn state_dir() -> PathBuf {
    PathBuf::from(home()).join(".local/state/island")
}

/// ~/.config/Halcyon : the installed rice
pub fn rice_dir() -> PathBuf {
    PathBuf::from(home()).join(".config/Halcyon")
}

/// First line of a file without its newline (like `head -n1`). None when the file cannot be read.
pub fn first_line(path: &Path) -> Option<String> {
    let s = fs::read_to_string(path).ok()?;
    Some(s.lines().next().unwrap_or("").to_string())
}

/// Runs a command with all of its output thrown away. true = it started and exited with 0.
pub fn ok(cmd: &str, args: &[&str]) -> bool {
    Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// What a command prints on stdout; "" when it could not be started. Its stderr is thrown away.
pub fn out(cmd: &str, args: &[&str]) -> String {
    match Command::new(cmd).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout).to_string(),
        Err(_) => String::new(),
    }
}

/// Is `name` an executable file somewhere in PATH?
pub fn command_exists(name: &str) -> bool {
    match env::var_os("PATH") {
        Some(paths) => env::split_paths(&paths).any(|d| d.join(name).is_file()),
        None => false,
    }
}

/// Sends a desktop notification asynchronously with notify-send if installed.
pub fn notify(summary: &str, body: &str, icon: Option<&str>, timeout_ms: u32) {
    if !command_exists("notify-send") {
        return;
    }
    let timeout_str = timeout_ms.to_string();
    let mut args = vec!["-a", "Halcyon", "-t", &timeout_str];
    if let Some(ic) = icon {
        args.push("-i");
        args.push(ic);
    }
    args.push(summary);
    args.push(body);
    let _ = Command::new("notify-send")
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// Appends "HH:MM:SS text" to ~/.cache/island/<name> and keeps the file to about 200 lines.
pub fn trace(name: &str, text: &str) {
    let cache = PathBuf::from(home()).join(".cache/island");
    let _ = fs::create_dir_all(&cache);
    let log = cache.join(name);
    let stamp = out("date", &["+%T"]);
    let line = format!("{} {}\n", stamp.trim(), text);
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&log) {
        let _ = f.write_all(line.as_bytes());
    }
    if let Ok(body) = fs::read_to_string(&log) {
        let lines: Vec<&str> = body.lines().collect();
        if lines.len() > 200 {
            let keep = lines[lines.len() - 50..].join("\n") + "\n";
            let tmp = cache.join(format!("{}.t", name));
            if fs::write(&tmp, keep).is_ok() {
                let _ = fs::rename(&tmp, &log);
            }
        }
    }
}
