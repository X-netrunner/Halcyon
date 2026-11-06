//! XDG path resolution shared by daemon and GUI.
//!
//! - config:  `~/.config/halcyon-music/config.toml`   (Part 2)
//! - state:   `~/.local/state/halcyon-music/`
//! - socket:  `$XDG_RUNTIME_DIR/halcyon-music/ctl.sock`
//! - cache:   `~/.cache/halcyon-music/`               (Part 2)

use std::path::PathBuf;

pub const APP_DIR_NAME: &str = "halcyon-music";
pub const SOCKET_DIR_NAME: &str = "halcyon-music";
pub const SOCKET_FILE_NAME: &str = "ctl.sock";
pub const STATE_FILE_NAME: &str = "player-state.json";

/// `$XDG_RUNTIME_DIR`, falling back to `/run/user/<uid>` (what systemd sets
/// anyway) so the app still works under a minimal session.
pub fn runtime_dir() -> PathBuf {
    if let Ok(v) = std::env::var("XDG_RUNTIME_DIR") {
        if !v.is_empty() {
            return PathBuf::from(v);
        }
    }
    let uid = rust_uid();
    PathBuf::from(format!("/run/user/{uid}"))
}

fn rust_uid() -> u32 {
    // std has no uid accessor; read it from /proc to avoid a libc dependency
    // in this tiny crate. Fall back to 1000 only if /proc is unreadable.
    std::fs::read_to_string("/proc/self/loginuid")
        .ok()
        .and_then(|s| s.trim().parse::<u32>().ok())
        .filter(|u| *u != u32::MAX)
        .unwrap_or_else(|| {
            std::env::var("UID")
                .ok()
                .and_then(|s| s.parse::<u32>().ok())
                .unwrap_or(1000)
        })
}

/// Directory that holds the control socket: `$XDG_RUNTIME_DIR/halcyon-music/`
pub fn socket_dir() -> PathBuf {
    runtime_dir().join(SOCKET_DIR_NAME)
}

/// The daemon's control socket.
pub fn ctl_socket() -> PathBuf {
    socket_dir().join(SOCKET_FILE_NAME)
}

/// `~/.local/state/halcyon-music/` (XDG_STATE_HOME respected).
pub fn state_dir() -> PathBuf {
    if let Ok(v) = std::env::var("XDG_STATE_HOME") {
        if !v.is_empty() {
            return PathBuf::from(v).join(APP_DIR_NAME);
        }
    }
    home_dir().join(".local/state").join(APP_DIR_NAME)
}

/// `~/.cache/halcyon-music/` (XDG_CACHE_HOME respected).
pub fn cache_dir() -> PathBuf {
    if let Ok(v) = std::env::var("XDG_CACHE_HOME") {
        if !v.is_empty() {
            return PathBuf::from(v).join(APP_DIR_NAME);
        }
    }
    home_dir().join(".cache").join(APP_DIR_NAME)
}

/// `~/.config/halcyon-music/` (XDG_CONFIG_HOME respected).
pub fn config_dir() -> PathBuf {
    if let Ok(v) = std::env::var("XDG_CONFIG_HOME") {
        if !v.is_empty() {
            return PathBuf::from(v).join(APP_DIR_NAME);
        }
    }
    home_dir().join(".config").join(APP_DIR_NAME)
}

fn home_dir() -> PathBuf {
    std::env::var("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/tmp"))
}

/// Full path of the persisted player state file.
pub fn state_file() -> PathBuf {
    state_dir().join(STATE_FILE_NAME)
}
