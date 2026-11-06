//! OAuth token storage.
//!
//! Stores tokens in Secret Service keyring when available, with fallback to an
//! atomically written `0600` file in the state dir.
//! Enforces pre-expiry refresh check (at 80% of token lifetime).

use halcyon_music_core::paths;
use serde::{Deserialize, Serialize};
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use tracing::{debug, info, warn};

const SERVICE_NAME: &str = "halcyon-music";
const KEYRING_USER: &str = "spotify_token";
const TOKEN_FILE_NAME: &str = "token.json";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TokenData {
    pub client_id: String,
    pub access_token: String,
    pub refresh_token: String,
    /// Absolute unix timestamp (seconds) when access_token expires
    pub expires_at: u64,
    /// Total lifetime in seconds (usually 3600)
    pub expires_in: u64,
    pub token_type: String,
    #[serde(default)]
    pub scopes: Vec<String>,
}

impl TokenData {
    pub fn new(
        client_id: String,
        access_token: String,
        refresh_token: String,
        expires_in: u64,
        token_type: String,
        scopes: Vec<String>,
    ) -> Self {
        let now = now_secs();
        let expires_at = now.saturating_add(expires_in);
        Self {
            client_id,
            access_token,
            refresh_token,
            expires_at,
            expires_in,
            token_type,
            scopes,
        }
    }

    /// True if token has expired or is past 80% of its lifetime.
    ///
    /// At 80% of lifetime, remaining lifetime is <= 20% of expires_in.
    pub fn needs_refresh(&self) -> bool {
        let now = now_secs();
        let buffer = (self.expires_in.saturating_mul(20)) / 100;
        let refresh_deadline = self.expires_at.saturating_sub(buffer);
        now >= refresh_deadline
    }

    /// True if the access token is strictly expired.
    pub fn is_expired(&self) -> bool {
        now_secs() >= self.expires_at
    }
}

pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn token_file_path() -> PathBuf {
    paths::state_dir().join(TOKEN_FILE_NAME)
}

/// Save token to Secret Service keyring if available, otherwise to a 0600 file.
pub fn save_token(token: &TokenData) -> Result<(), String> {
    let serialized = serde_json::to_string(token).map_err(|e| e.to_string())?;

    // Try keyring first
    let keyring_entry = keyring::Entry::new(SERVICE_NAME, KEYRING_USER);
    let keyring_saved = match keyring_entry {
        Ok(entry) => match entry.set_password(&serialized) {
            Ok(()) => {
                debug!("token saved to Secret Service keyring");
                true
            }
            Err(e) => {
                debug!("keyring set_password failed ({e}); falling back to file");
                false
            }
        },
        Err(e) => {
            debug!("keyring entry creation failed ({e}); falling back to file");
            false
        }
    };

    // If keyring was unavailable or failed, write 0600 file atomically
    if !keyring_saved {
        let path = token_file_path();
        save_file_0600(&path, serialized.as_bytes())?;
        info!("token saved to secure state file ({})", path.display());
    }

    Ok(())
}

/// Load token from Secret Service keyring if available, otherwise from 0600 file.
pub fn load_token() -> Result<Option<TokenData>, String> {
    // 1. Try keyring
    if let Ok(entry) = keyring::Entry::new(SERVICE_NAME, KEYRING_USER) {
        if let Ok(pw) = entry.get_password() {
            if let Ok(token) = serde_json::from_str::<TokenData>(&pw) {
                debug!("loaded token from Secret Service keyring");
                return Ok(Some(token));
            }
        }
    }

    // 2. Try file fallback
    let path = token_file_path();
    if !path.exists() {
        return Ok(None);
    }

    match std::fs::read_to_string(&path) {
        Ok(content) => match serde_json::from_str::<TokenData>(&content) {
            Ok(token) => {
                debug!("loaded token from secure state file");
                Ok(Some(token))
            }
            Err(e) => {
                warn!("corrupt token file at {}: {e}", path.display());
                Ok(None)
            }
        },
        Err(e) => {
            warn!("unable to read token file at {}: {e}", path.display());
            Ok(None)
        }
    }
}

/// Clear token from both keyring and file fallback.
pub fn clear_token() -> Result<(), String> {
    if let Ok(entry) = keyring::Entry::new(SERVICE_NAME, KEYRING_USER) {
        let _ = entry.delete_credential();
    }
    let path = token_file_path();
    if path.exists() {
        let _ = std::fs::remove_file(path);
    }
    Ok(())
}

/// Atomically write data with 0600 permissions (read/write owner only).
pub fn save_file_0600(target: &Path, data: &[u8]) -> Result<(), String> {
    let parent = target.parent().unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;

    let tmp_path = parent.join(format!(".token.{}.tmp", std::process::id()));

    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&tmp_path)
        .map_err(|e| e.to_string())?;

    // Set 0600 permissions
    let mut perms = file
        .metadata()
        .map_err(|e| e.to_string())?
        .permissions();
    perms.set_mode(0o600);
    std::fs::set_permissions(&tmp_path, perms).map_err(|e| e.to_string())?;

    file.write_all(data).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    drop(file);

    std::fs::rename(&tmp_path, target).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn needs_refresh_calculation() {
        let now = now_secs();
        // 3600s total, expires in 3600s: 0% elapsed -> no refresh
        let fresh = TokenData {
            client_id: "c".into(),
            access_token: "a".into(),
            refresh_token: "r".into(),
            expires_at: now + 3600,
            expires_in: 3600,
            token_type: "Bearer".into(),
            scopes: vec![],
        };
        assert!(!fresh.needs_refresh());
        assert!(!fresh.is_expired());

        // 3600s total, expires in 700s (2900s elapsed, > 80% elapsed) -> needs refresh
        let due = TokenData {
            client_id: "c".into(),
            access_token: "a".into(),
            refresh_token: "r".into(),
            expires_at: now + 700,
            expires_in: 3600,
            token_type: "Bearer".into(),
            scopes: vec![],
        };
        assert!(due.needs_refresh());
        assert!(!due.is_expired());

        // Expired
        let expired = TokenData {
            client_id: "c".into(),
            access_token: "a".into(),
            refresh_token: "r".into(),
            expires_at: now.saturating_sub(10),
            expires_in: 3600,
            token_type: "Bearer".into(),
            scopes: vec![],
        };
        assert!(expired.needs_refresh());
        assert!(expired.is_expired());
    }

    #[test]
    fn secure_file_round_trip() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("sub/token.json");
        let data = b"{\"hello\":\"world\"}";
        save_file_0600(&path, data).expect("save");

        let meta = std::fs::metadata(&path).expect("meta");
        let mode = meta.permissions().mode();
        assert_eq!(mode & 0o777, 0o600);

        let read_back = std::fs::read(&path).expect("read");
        assert_eq!(read_back, data);
    }
}
