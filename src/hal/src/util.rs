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
    match Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
    {
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

/// Where the bash shims live. The shims export HALCYON_SCRIPTS_DIR (their own folder), so a checkout that is run in place
/// works too; otherwise the installed rice.
pub fn scripts_dir() -> PathBuf {
    match env::var("HALCYON_SCRIPTS_DIR") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => rice_dir().join("scripts"),
    }
}

/// Like `ok`, but gives up after `ms` milliseconds (the child is killed): `timeout 2 cmd` in the shell scripts.
pub fn ok_timeout(cmd: &str, args: &[&str], ms: u64) -> bool {
    let mut child = match Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return false,
    };
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) => {
                if start.elapsed().as_millis() >= u128::from(ms) {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            Err(_) => return false,
        }
    }
}

/// `notify-send -a APP [-i ICON] SUMMARY BODY`, waited for (the shell scripts call it in the foreground). No-op without notify-send.
pub fn notify_app(app: &str, summary: &str, body: &str, icon: Option<&str>) {
    if !command_exists("notify-send") {
        return;
    }
    let mut args = vec!["-a", app];
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
        .status();
}

/// The value of `KEY=value` in a small shell-style config (the last one wins; surrounding quotes are dropped).
/// This is what `. file` gave the scripts for the plain files Settings writes (autostart.conf, idle.env).
pub fn conf_value(text: &str, key: &str) -> Option<String> {
    let prefix = format!("{}=", key);
    let mut found = None;
    for line in text.lines() {
        if let Some(rest) = line.trim().strip_prefix(prefix.as_str()) {
            found = Some(
                rest.trim()
                    .trim_matches(|c: char| c == '"' || c == '\'')
                    .to_string(),
            );
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::conf_value;

    #[test]
    fn conf_value_reads_plain_and_quoted() {
        let t = "NM_APPLET=0\nPOLKIT=gnome\n  GPU = x\nname=\"a b\"\nPOLKIT='kde'\n";
        assert_eq!(conf_value(t, "NM_APPLET").as_deref(), Some("0"));
        assert_eq!(conf_value(t, "POLKIT").as_deref(), Some("kde")); // the last one wins
        assert_eq!(conf_value(t, "name").as_deref(), Some("a b"));
        assert_eq!(conf_value(t, "MISSING"), None);
        assert_eq!(conf_value(t, "GPU"), None); // "GPU = x" is not shell syntax either
    }
}
