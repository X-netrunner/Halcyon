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

/// `~/.local/share/halcyon-music/` (XDG_DATA_HOME respected).
pub fn data_dir() -> PathBuf {
    if let Ok(v) = std::env::var("XDG_DATA_HOME") {
        if !v.is_empty() {
            return PathBuf::from(v).join(APP_DIR_NAME);
        }
    }
    home_dir().join(".local/share").join(APP_DIR_NAME)
}

/// Where the built-in language model files live: `~/.local/share/halcyon-music/models/`.
pub fn models_dir() -> PathBuf {
    data_dir().join("models")
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

/// `~/.config/halcyon-music/connect`: the Spotify Connect choice made in Settings. The file holds
/// `on` or `off`; no file means "not chosen yet" and the installer's default (the environment) applies.
pub fn connect_pref_file() -> PathBuf {
    config_dir().join("connect")
}

// ---------------------------------------------------------------------------------------------
// The Halcyon avatar (the same picture `hal avatar` prints)
// ---------------------------------------------------------------------------------------------

/// Where the rice keeps the user's picture, best first. This is the same list, in the same order,
/// as `src/hal/src/avatar.rs`; keep the two in step. `user` may be empty (the AccountsService entry
/// is then skipped). Nothing is read from disk here.
pub fn avatar_candidates_in(home: &std::path::Path, user: &str) -> Vec<PathBuf> {
    let mut v = vec![home.join(".face"), home.join(".face.icon")];
    if !user.is_empty() {
        v.push(PathBuf::from(format!("/var/lib/AccountsService/icons/{user}")));
    }
    let extensions = ["png", "jpg", "jpeg", "webp"];
    for ext in extensions {
        v.push(home.join(format!(".config/Halcyon/avatar.{ext}")));
    }
    for ext in extensions {
        v.push(home.join(format!("Pictures/avatar.{ext}")));
    }
    v
}

/// The first candidate that is a non-empty file.
pub fn first_existing_avatar(candidates: &[PathBuf]) -> Option<PathBuf> {
    candidates
        .iter()
        .find(|p| p.is_file() && std::fs::metadata(p).map(|m| m.len() > 0).unwrap_or(false))
        .cloned()
}

/// Turn a path from a settings file into a real path (`~` is the home folder). Empty or
/// non-text values give `None`.
fn expand_user_path(home: &std::path::Path, raw: &str) -> Option<PathBuf> {
    let p = raw.trim();
    if p.is_empty() {
        return None;
    }
    Some(match p.strip_prefix('~') {
        Some(rest) => home.join(rest.trim_start_matches('/')),
        None => PathBuf::from(p),
    })
}

/// The picture chosen in the island's Settings > Profile (or E on the laptop node in the tree):
/// `"profileAvatar"` in `~/.local/state/island/settings.json`. This is the first thing the rice
/// itself looks at (`avatar.sh <chosen>`), so it has to be first here too, or choosing a picture
/// in Halcyon would not change anything in the music app.
pub fn profile_avatar_from_settings(home: &std::path::Path, settings_json: &str) -> Option<PathBuf> {
    let v: serde_json::Value = serde_json::from_str(settings_json).ok()?;
    expand_user_path(home, v.get("profileAvatar")?.as_str()?)
}

/// The picture the island reports it is showing: `"avatar"` in `~/.cache/island/greeter-look.json`
/// (only format version 1 is understood, same as the greeter script).
pub fn shown_avatar_from_greeter_look(home: &std::path::Path, look_json: &str) -> Option<PathBuf> {
    let v: serde_json::Value = serde_json::from_str(look_json).ok()?;
    if v.get("v").and_then(|x| x.as_i64()) != Some(1) {
        return None;
    }
    expand_user_path(home, v.get("avatar")?.as_str()?)
}

/// Every place to look, best first: the picture chosen in Halcyon's settings, the one the island
/// says it shows, then the usual places from [`avatar_candidates_in`]. Nothing is read from disk.
pub fn avatar_candidates_full(
    home: &std::path::Path,
    user: &str,
    chosen: Option<PathBuf>,
    shown: Option<PathBuf>,
) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = Vec::new();
    v.extend(chosen);
    v.extend(shown);
    v.extend(avatar_candidates_in(home, user));
    v
}

/// The user's Halcyon avatar right now, if there is one. Cheap (two small file reads and a few
/// `stat` calls) but it touches the disk, so call it from a timer or a background task, not from
/// `view`. The picture chosen in Halcyon's Profile settings wins over `~/.face` and friends.
pub fn halcyon_avatar() -> Option<PathBuf> {
    let home = home_dir();
    let user = std::env::var("USER").unwrap_or_default();
    let chosen = std::fs::read_to_string(home.join(".local/state/island/settings.json"))
        .ok()
        .and_then(|j| profile_avatar_from_settings(&home, &j));
    let shown = std::fs::read_to_string(home.join(".cache/island/greeter-look.json"))
        .ok()
        .and_then(|j| shown_avatar_from_greeter_look(&home, &j));
    first_existing_avatar(&avatar_candidates_full(&home, &user, chosen, shown))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("halcyon-paths-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        dir
    }

    #[test]
    fn a_picture_chosen_in_halcyon_comes_before_face_and_the_standard_places() {
        let home = PathBuf::from("/h");
        let chosen = profile_avatar_from_settings(&home, r#"{"profileAvatar":"~/Pictures/me.png"}"#);
        assert_eq!(chosen, Some(PathBuf::from("/h/Pictures/me.png")));
        assert_eq!(profile_avatar_from_settings(&home, r#"{"profileAvatar":""}"#), None);
        assert_eq!(profile_avatar_from_settings(&home, "not json"), None);
        let shown = shown_avatar_from_greeter_look(&home, r#"{"v":1,"avatar":"/x/a.jpg"}"#);
        assert_eq!(shown, Some(PathBuf::from("/x/a.jpg")));
        assert_eq!(shown_avatar_from_greeter_look(&home, r#"{"v":2,"avatar":"/x/a.jpg"}"#), None);
        let c = avatar_candidates_full(&home, "ada", chosen, shown);
        assert_eq!(c[0], PathBuf::from("/h/Pictures/me.png"));
        assert_eq!(c[1], PathBuf::from("/x/a.jpg"));
        assert_eq!(c[2], PathBuf::from("/h/.face"));
        assert_eq!(c.len(), 13);
    }

    #[test]
    fn candidate_order_matches_hal_avatar() {
        let home = PathBuf::from("/h");
        let c = avatar_candidates_in(&home, "ada");
        assert_eq!(c[0], PathBuf::from("/h/.face"));
        assert_eq!(c[1], PathBuf::from("/h/.face.icon"));
        assert_eq!(c[2], PathBuf::from("/var/lib/AccountsService/icons/ada"));
        assert_eq!(c[3], PathBuf::from("/h/.config/Halcyon/avatar.png"));
        assert_eq!(c[6], PathBuf::from("/h/.config/Halcyon/avatar.webp"));
        assert_eq!(c[7], PathBuf::from("/h/Pictures/avatar.png"));
        assert_eq!(c.len(), 11);
        // No user name: the AccountsService entry is left out.
        assert_eq!(avatar_candidates_in(&home, "").len(), 10);
    }

    #[test]
    fn first_existing_skips_missing_and_empty_files() {
        let home = temp_home("first");
        std::fs::write(home.join(".face"), b"").expect("empty file");
        std::fs::create_dir_all(home.join(".config/Halcyon")).expect("dir");
        std::fs::write(home.join(".config/Halcyon/avatar.jpg"), b"x").expect("file");
        std::fs::write(home.join(".config/Halcyon/avatar.png"), b"y").expect("file");
        let found = first_existing_avatar(&avatar_candidates_in(&home, ""));
        // .face is empty, so the first real file in list order wins: avatar.png before avatar.jpg.
        assert_eq!(found, Some(home.join(".config/Halcyon/avatar.png")));
        assert_eq!(first_existing_avatar(&[home.join("nope")]), None);
        let _ = std::fs::remove_dir_all(&home);
    }
}
