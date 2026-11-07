//! Which token browsing uses (`librespot` default, `own-client-id` advanced override).
//!
//! Rework Part 4. The choice lives in `auth_mode.json` in the state directory (not a secret:
//! just the mode name; written atomically). Streaming never depends on it: librespot's own
//! token is the only one that can stream.

use crate::token_store::save_file_0600;
use halcyon_music_core::models::AuthMode;
use halcyon_music_core::paths;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tracing::warn;

const FILE_NAME: &str = "auth_mode.json";

#[derive(Serialize, Deserialize)]
struct Stored {
    mode: AuthMode,
}

fn file_path() -> PathBuf {
    paths::state_dir().join(FILE_NAME)
}

/// The saved choice, or `None` if there is none or the file is unreadable (never fatal).
pub fn load() -> Option<AuthMode> {
    let bytes = std::fs::read(file_path()).ok()?;
    match serde_json::from_slice::<Stored>(&bytes) {
        Ok(s) => Some(s.mode),
        Err(_) => {
            warn!("auth_mode.json is unreadable; using the default");
            None
        }
    }
}

pub fn save(mode: AuthMode) -> Result<(), String> {
    let bytes = serde_json::to_vec(&Stored { mode }).map_err(|e| e.to_string())?;
    save_file_0600(&file_path(), &bytes)
}

/// Pure rule for the starting mode. A saved choice wins. Without one, an existing user who
/// only has the old Client-ID token keeps browsing that way (nothing breaks on upgrade); in
/// every other case the default is the librespot sign-in.
pub fn resolve(saved: Option<AuthMode>, has_librespot_token: bool, has_own_token: bool) -> AuthMode {
    match saved {
        Some(mode) => mode,
        None if has_librespot_token => AuthMode::Librespot,
        None if has_own_token => AuthMode::OwnClientId,
        None => AuthMode::Librespot,
    }
}

/// The mode to start with, from what is on disk.
pub fn initial() -> AuthMode {
    let has_librespot = matches!(crate::token_store::load_librespot_token(), Ok(Some(_)));
    let has_own = matches!(crate::token_store::load_token(), Ok(Some(_)));
    resolve(load(), has_librespot, has_own)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_choice_wins() {
        assert_eq!(resolve(Some(AuthMode::OwnClientId), true, false), AuthMode::OwnClientId);
        assert_eq!(resolve(Some(AuthMode::Librespot), false, true), AuthMode::Librespot);
    }

    #[test]
    fn upgrade_keeps_browsing_with_the_old_token() {
        assert_eq!(resolve(None, false, true), AuthMode::OwnClientId);
    }

    #[test]
    fn defaults_to_librespot() {
        assert_eq!(resolve(None, false, false), AuthMode::Librespot);
        assert_eq!(resolve(None, true, false), AuthMode::Librespot);
        // Both tokens, no choice: the new default wins.
        assert_eq!(resolve(None, true, true), AuthMode::Librespot);
    }

    #[test]
    fn stored_file_shape_uses_the_wire_names() {
        let json = serde_json::to_string(&Stored { mode: AuthMode::OwnClientId }).expect("json");
        assert_eq!(json, r#"{"mode":"own-client-id"}"#);
    }
}
