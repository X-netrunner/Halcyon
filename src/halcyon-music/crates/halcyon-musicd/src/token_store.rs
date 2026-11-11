//! OAuth token storage.
//!
//! Stores tokens in Secret Service keyring when available, with fallback to an
//! atomically written `0600` file in the state dir.
//! Enforces pre-expiry refresh check (at 80% of token lifetime).
//!
//! Two independent slots, each keyring-first with a `0600` file fallback:
//! - `TokenData` ("own Client ID" PKCE token, used for browsing only), `token.json`
//! - `LibrespotToken` (librespot's own OAuth token, used for streaming and, by default, browsing),
//!   `librespot_token.json`
//!
//! Tokens are secrets: neither type derives `Debug` (both print a redacted form), and no error
//! string in this module contains token text.

use halcyon_music_core::paths;
use librespot_core::config::SessionConfig;
use librespot_oauth::OAuthClientBuilder;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tracing::{debug, info, warn};

const SERVICE_NAME: &str = "halcyon-music";
const KEYRING_USER: &str = "spotify_token";
const TOKEN_FILE_NAME: &str = "token.json";

/// How long to wait for the Secret Service (the desktop keyring) before giving up on it.
const KEYRING_TIMEOUT: Duration = Duration::from_secs(3);
/// Set once the keyring did not answer in time: it is skipped for the rest of this run (every
/// further call would only add another wait), and the 0600 files are used instead.
static KEYRING_STUCK: AtomicBool = AtomicBool::new(false);

/// Run one keyring call on its own thread and wait at most `KEYRING_TIMEOUT` for it.
///
/// The keyring talks to the Secret Service over D-Bus and can wait forever: when the keyring is
/// locked and asking for a password that no window can show (a daemon started by systemd has no
/// screen to draw it on), or when the service is half-started. A call made straight from the
/// daemon's startup then froze it before it could say it was ready, and systemd killed it after
/// 90 s, over and over. `None` means "no answer": the caller uses the file fallback.
fn keyring_call<T: Send + 'static>(f: impl FnOnce() -> Option<T> + Send + 'static) -> Option<T> {
    if KEYRING_STUCK.load(Ordering::Relaxed) {
        return None;
    }
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("keyring".into())
        .spawn(move || {
            let _ = tx.send(f());
        })
        .ok()?;
    match rx.recv_timeout(KEYRING_TIMEOUT) {
        Ok(v) => v,
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
            KEYRING_STUCK.store(true, Ordering::Relaxed);
            warn!(
                "the keyring (Secret Service) did not answer in {} s; using the token files instead",
                KEYRING_TIMEOUT.as_secs()
            );
            None
        }
        Err(_) => None,
    }
}

fn keyring_get(user: &'static str) -> Option<String> {
    keyring_call(move || keyring::Entry::new(SERVICE_NAME, user).ok()?.get_password().ok())
}

/// True when the keyring took the value.
fn keyring_set(user: &'static str, value: String) -> bool {
    keyring_call(move || {
        let entry = keyring::Entry::new(SERVICE_NAME, user).ok()?;
        match entry.set_password(&value) {
            Ok(()) => Some(()),
            Err(e) => {
                debug!("keyring set_password failed ({e}); falling back to file");
                None
            }
        }
    })
    .is_some()
}

fn keyring_delete(user: &'static str) {
    let _ = keyring_call(move || {
        let _ = keyring::Entry::new(SERVICE_NAME, user).ok()?.delete_credential();
        Some(())
    });
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
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

impl fmt::Debug for TokenData {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TokenData")
            .field("client_id", &self.client_id)
            .field("access_token", &"<redacted>")
            .field("refresh_token", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("expires_in", &self.expires_in)
            .field("token_type", &self.token_type)
            .field("scopes", &self.scopes)
            .finish()
    }
}

/// True when `now` is past 80% of the token's lifetime (remaining <= 20% of `expires_in`),
/// or the token has expired.
fn refresh_due(now: u64, expires_at: u64, expires_in: u64) -> bool {
    let buffer = expires_in.saturating_mul(20) / 100;
    now >= expires_at.saturating_sub(buffer)
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
        refresh_due(now_secs(), self.expires_at, self.expires_in)
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
    let keyring_saved = keyring_set(KEYRING_USER, serialized.clone());
    if keyring_saved {
        debug!("token saved to Secret Service keyring");
    }

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
    if let Some(pw) = keyring_get(KEYRING_USER) {
        if let Ok(token) = serde_json::from_str::<TokenData>(&pw) {
            debug!("loaded token from Secret Service keyring");
            return Ok(Some(token));
        }
    }

    // 2. Try file fallback
    match read_json_file::<TokenData>(&token_file_path()) {
        FileRead::Found(token) => {
            debug!("loaded token from secure state file");
            Ok(Some(token))
        }
        FileRead::Missing | FileRead::Corrupt | FileRead::Unreadable => Ok(None),
    }
}

/// Clear token from both keyring and file fallback.
pub fn clear_token() -> Result<(), String> {
    keyring_delete(KEYRING_USER);
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

    let target_name = target
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "token".to_string());
    let tmp_path = parent.join(format!(".{target_name}.{}.tmp", std::process::id()));

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

// ----------------------------------------------------------------------
// Shared file helpers
// ----------------------------------------------------------------------

/// Outcome of reading one JSON token file.
enum FileRead<T> {
    Missing,
    Found(T),
    /// The file exists but is not valid JSON for this type.
    Corrupt,
    /// The file exists but could not be read (permissions, I/O).
    Unreadable,
}

fn read_json_file<T: DeserializeOwned>(path: &Path) -> FileRead<T> {
    if !path.exists() {
        return FileRead::Missing;
    }
    match std::fs::read_to_string(path) {
        Ok(content) => match serde_json::from_str::<T>(&content) {
            Ok(value) => FileRead::Found(value),
            Err(e) => {
                // serde_json's message names a position, never file content.
                warn!("corrupt token file at {}: {e}", path.display());
                FileRead::Corrupt
            }
        },
        Err(e) => {
            warn!("unable to read token file at {}: {e}", path.display());
            FileRead::Unreadable
        }
    }
}

/// Move an unreadable token file aside (`<name>.corrupt`, still 0600) so the next sign-in starts
/// clean and the daemon does not warn about it on every start.
fn quarantine_file(path: &Path) {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".corrupt");
    let target = path.with_file_name(name);
    match std::fs::rename(path, &target) {
        Ok(()) => warn!("moved the unreadable token file to {}", target.display()),
        Err(e) => warn!("could not move the unreadable token file aside: {e}"),
    }
}

// ----------------------------------------------------------------------
// Streaming slot: librespot's own OAuth token
// ----------------------------------------------------------------------

const LIBRESPOT_KEYRING_USER: &str = "librespot_token";
const LIBRESPOT_TOKEN_FILE_NAME: &str = "librespot_token.json";

/// Redirect URI of the browser sign-in. `librespot-oauth` has no constant for it: this is the
/// value its own examples (`oauth/examples/oauth_*.rs`, `examples/play_connect.rs`) use with
/// librespot's client ID. `librespot`'s binary builds `http://127.0.0.1[:port]/login` from an
/// optional `--oauth-port`; the callback listener only starts when the URI has a port.
pub const LIBRESPOT_REDIRECT_URI: &str = "http://127.0.0.1:8898/login";

/// Scopes librespot's binary requests (`OAUTH_SCOPES` in its `src/main.rs`, "what Spotify's
/// Desktop app uses"). `streaming` is the one playback needs.
pub const LIBRESPOT_SCOPES: &[&str] = &[
    "app-remote-control",
    "playlist-modify",
    "playlist-modify-private",
    "playlist-modify-public",
    "playlist-read",
    "playlist-read-collaborative",
    "playlist-read-private",
    "streaming",
    "ugc-image-upload",
    "user-follow-modify",
    "user-follow-read",
    "user-library-modify",
    "user-library-read",
    "user-modify",
    "user-modify-playback-state",
    "user-modify-private",
    "user-personalized",
    "user-read-birthdate",
    "user-read-currently-playing",
    "user-read-email",
    "user-read-play-history",
    "user-read-playback-position",
    "user-read-playback-state",
    "user-read-private",
    "user-read-recently-played",
    "user-top-read",
];

/// The client ID librespot's session uses (taken from the crate, not hard-coded here). The
/// OAuth token must come from this same client ID: login5 only accepts stored credentials
/// that match the session's client ID.
pub fn librespot_client_id() -> String {
    SessionConfig::default().client_id
}

/// Token from librespot's own OAuth flow.
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LibrespotToken {
    pub access_token: String,
    pub refresh_token: String,
    /// Absolute unix timestamp (seconds) when `access_token` expires.
    pub expires_at: u64,
    /// Lifetime in seconds at issue time (usually 3600).
    pub expires_in: u64,
    #[serde(default)]
    pub scopes: Vec<String>,
}

impl fmt::Debug for LibrespotToken {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("LibrespotToken")
            .field("access_token", &"<redacted>")
            .field("refresh_token", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("expires_in", &self.expires_in)
            .field("scopes", &self.scopes)
            .finish()
    }
}

impl LibrespotToken {
    pub fn new(
        access_token: String,
        refresh_token: String,
        expires_in: u64,
        scopes: Vec<String>,
    ) -> Self {
        Self::new_at(now_secs(), access_token, refresh_token, expires_in, scopes)
    }

    fn new_at(
        now: u64,
        access_token: String,
        refresh_token: String,
        expires_in: u64,
        scopes: Vec<String>,
    ) -> Self {
        Self {
            access_token,
            refresh_token,
            expires_at: now.saturating_add(expires_in),
            expires_in,
            scopes,
        }
    }

    /// Expired, or past 80% of its lifetime (same rule as `TokenData`).
    pub fn needs_refresh(&self) -> bool {
        refresh_due(now_secs(), self.expires_at, self.expires_in)
    }

    pub fn is_expired(&self) -> bool {
        now_secs() >= self.expires_at
    }

    /// Seconds until the access token expires (0 if it already has).
    pub fn seconds_left(&self) -> u64 {
        self.expires_at.saturating_sub(now_secs())
    }

    /// True if the token was granted the `streaming` scope.
    pub fn can_stream(&self) -> bool {
        self.scopes.iter().any(|s| s == "streaming")
    }
}

fn librespot_token_file_path() -> PathBuf {
    paths::state_dir().join(LIBRESPOT_TOKEN_FILE_NAME)
}

fn write_librespot_token_file(path: &Path, token: &LibrespotToken) -> Result<(), String> {
    let serialized = serde_json::to_string(token).map_err(|e| e.to_string())?;
    save_file_0600(path, serialized.as_bytes())
}

/// A missing file is `Ok(None)`. A corrupt one is moved aside and is also `Ok(None)`, so the
/// caller just asks for a new sign-in.
fn read_librespot_token_file(path: &Path) -> Result<Option<LibrespotToken>, String> {
    match read_json_file::<LibrespotToken>(path) {
        FileRead::Found(token) => Ok(Some(token)),
        FileRead::Missing | FileRead::Unreadable => Ok(None),
        FileRead::Corrupt => {
            quarantine_file(path);
            Ok(None)
        }
    }
}

/// Save the streaming token to the keyring if available, otherwise to a 0600 file.
pub fn save_librespot_token(token: &LibrespotToken) -> Result<(), String> {
    let serialized = serde_json::to_string(token).map_err(|e| e.to_string())?;
    let path = librespot_token_file_path();

    let keyring_saved = keyring_set(LIBRESPOT_KEYRING_USER, serialized.clone());
    if keyring_saved {
        debug!("streaming token saved to Secret Service keyring");
    }

    if keyring_saved {
        // A file left from an earlier fallback would be an older token: remove it.
        if path.exists() {
            if let Err(e) = std::fs::remove_file(&path) {
                warn!("could not remove the older streaming token file: {e}");
            }
        }
        Ok(())
    } else {
        write_librespot_token_file(&path, token)?;
        info!("streaming token saved to secure state file ({})", path.display());
        Ok(())
    }
}

/// Load the streaming token from the keyring if available, otherwise from the 0600 file.
pub fn load_librespot_token() -> Result<Option<LibrespotToken>, String> {
    if let Some(pw) = keyring_get(LIBRESPOT_KEYRING_USER) {
        match serde_json::from_str::<LibrespotToken>(&pw) {
            Ok(token) => {
                debug!("loaded streaming token from Secret Service keyring");
                return Ok(Some(token));
            }
            Err(_) => warn!("the streaming token in the keyring is unreadable; ignoring it"),
        }
    }
    read_librespot_token_file(&librespot_token_file_path())
}

/// Clear the streaming token from both keyring and file fallback.
pub fn clear_librespot_token() -> Result<(), String> {
    keyring_delete(LIBRESPOT_KEYRING_USER);
    let path = librespot_token_file_path();
    if path.exists() {
        let _ = std::fs::remove_file(path);
    }
    Ok(())
}

// ----------------------------------------------------------------------
// Refresh
// ----------------------------------------------------------------------

/// Why a refresh failed. Fixed strings only: nothing here can carry token text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshError {
    /// The stored token has no refresh token.
    MissingRefreshToken,
    /// Spotify refused the refresh token (revoked or expired): a new sign-in is needed.
    Rejected,
    /// Spotify could not be reached; try again later.
    Network,
    Other,
}

impl fmt::Display for RefreshError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            RefreshError::MissingRefreshToken => "the saved sign-in has no refresh token",
            RefreshError::Rejected => "Spotify refused to renew the sign-in",
            RefreshError::Network => "could not reach Spotify to renew the sign-in",
            RefreshError::Other => "renewing the sign-in failed",
        })
    }
}

impl std::error::Error for RefreshError {}

/// Best-effort classification of the text `librespot-oauth` puts in `OAuthError::ExchangeCode`.
/// That text comes from the `oauth2` crate, which was not available to read here, so treat
/// `Other` as "unknown": callers must not delete a token on `Other`.
fn classify_refresh_error(text: &str) -> RefreshError {
    let lower = text.to_lowercase();
    if lower.contains("invalid_grant") {
        RefreshError::Rejected
    } else if ["request failed", "error sending request", "connect", "timed out", "timeout", "dns"]
        .iter()
        .any(|needle| lower.contains(needle))
    {
        RefreshError::Network
    } else {
        RefreshError::Other
    }
}

/// Build the refreshed token. Spotify may omit the refresh token or the scopes in the answer
/// (the crate then returns an empty string / the requested scopes): keep the old refresh token.
fn merge_refreshed(
    now: u64,
    old: &LibrespotToken,
    access_token: String,
    refresh_token: String,
    expires_in: u64,
    scopes: Vec<String>,
) -> LibrespotToken {
    let refresh_token = if refresh_token.is_empty() {
        old.refresh_token.clone()
    } else {
        refresh_token
    };
    let scopes = if scopes.is_empty() {
        old.scopes.clone()
    } else {
        scopes
    };
    // Same default the crate uses when Spotify omits the lifetime.
    let expires_in = if expires_in == 0 { 3600 } else { expires_in };
    LibrespotToken::new_at(now, access_token, refresh_token, expires_in, scopes)
}

/// Trade the refresh token for a new access token (does not store it).
pub async fn refresh_librespot_token(
    current: &LibrespotToken,
) -> Result<LibrespotToken, RefreshError> {
    if current.refresh_token.is_empty() {
        return Err(RefreshError::MissingRefreshToken);
    }
    let scopes: Vec<&str> = if current.scopes.is_empty() {
        LIBRESPOT_SCOPES.to_vec()
    } else {
        current.scopes.iter().map(String::as_str).collect()
    };
    let client = OAuthClientBuilder::new(&librespot_client_id(), LIBRESPOT_REDIRECT_URI, scopes)
        .build()
        .map_err(|e| {
            warn!("could not build the OAuth client for the refresh: {e}");
            RefreshError::Other
        })?;

    match client.refresh_token_async(&current.refresh_token).await {
        Ok(fresh) => {
            let expires_in = fresh
                .expires_at
                .saturating_duration_since(std::time::Instant::now())
                .as_secs();
            Ok(merge_refreshed(
                now_secs(),
                current,
                fresh.access_token,
                fresh.refresh_token,
                expires_in,
                fresh.scopes,
            ))
        }
        Err(e) => {
            let kind = classify_refresh_error(&e.to_string());
            warn!(?kind, "streaming token refresh failed");
            Err(kind)
        }
    }
}

/// Refresh and save. If saving fails the fresh token is still returned (it works for this run);
/// the failure is logged.
pub async fn refresh_and_store_librespot_token(
    current: &LibrespotToken,
) -> Result<LibrespotToken, RefreshError> {
    let fresh = refresh_librespot_token(current).await?;
    if let Err(e) = save_librespot_token(&fresh) {
        warn!("could not save the renewed streaming token: {e}");
    }
    Ok(fresh)
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

    // ---- Part 2: streaming slot ----

    const SECRET_ACCESS: &str = "SECRET-ACCESS-abc123";
    const SECRET_REFRESH: &str = "SECRET-REFRESH-xyz789";

    fn ls_token(expires_in: u64, expires_at: u64) -> LibrespotToken {
        LibrespotToken {
            access_token: SECRET_ACCESS.into(),
            refresh_token: SECRET_REFRESH.into(),
            expires_at,
            expires_in,
            scopes: vec!["streaming".into(), "user-library-read".into()],
        }
    }

    #[test]
    fn refresh_window_edges() {
        // 3600 s lifetime: buffer is 720 s
        assert!(!refresh_due(1_000, 1_000 + 3600, 3600)); // fresh
        assert!(!refresh_due(1_000, 1_000 + 721, 3600)); // 1 s before the window
        assert!(refresh_due(1_000, 1_000 + 720, 3600)); // window opens
        assert!(refresh_due(1_000, 1_000, 3600)); // expires now
        assert!(refresh_due(1_000, 900, 3600)); // already expired
        // zero lifetime: due only once expired
        assert!(!refresh_due(1_000, 1_001, 0));
        assert!(refresh_due(1_000, 1_000, 0));
        // huge values do not overflow
        assert!(!refresh_due(0, u64::MAX, u64::MAX));
    }

    #[test]
    fn librespot_token_expiry_helpers() {
        let now = now_secs();
        let fresh = ls_token(3600, now + 3600);
        assert!(!fresh.needs_refresh());
        assert!(!fresh.is_expired());
        assert!(fresh.seconds_left() > 3590);
        assert!(fresh.can_stream());

        let due = ls_token(3600, now + 700);
        assert!(due.needs_refresh());
        assert!(!due.is_expired());

        let gone = ls_token(3600, now.saturating_sub(5));
        assert!(gone.is_expired());
        assert_eq!(gone.seconds_left(), 0);

        let mut no_stream = ls_token(3600, now + 3600);
        no_stream.scopes = vec!["user-library-read".into()];
        assert!(!no_stream.can_stream());
    }

    #[test]
    fn debug_output_never_contains_secrets() {
        let ls = ls_token(3600, 5_000);
        let shown = format!("{ls:?} {:#?}", ls);
        assert!(!shown.contains(SECRET_ACCESS));
        assert!(!shown.contains(SECRET_REFRESH));
        assert!(shown.contains("<redacted>"));

        let own = TokenData {
            client_id: "client".into(),
            access_token: SECRET_ACCESS.into(),
            refresh_token: SECRET_REFRESH.into(),
            expires_at: 5_000,
            expires_in: 3600,
            token_type: "Bearer".into(),
            scopes: vec![],
        };
        let shown = format!("{own:?} {:#?}", own);
        assert!(!shown.contains(SECRET_ACCESS));
        assert!(!shown.contains(SECRET_REFRESH));
        // Option / Vec wrappers use the same Debug
        let wrapped = format!("{:?}", Some(ls));
        assert!(!wrapped.contains(SECRET_ACCESS));
    }

    #[test]
    fn refresh_errors_carry_no_token_text() {
        for e in [
            RefreshError::MissingRefreshToken,
            RefreshError::Rejected,
            RefreshError::Network,
            RefreshError::Other,
        ] {
            let shown = format!("{e} {e:?}");
            assert!(!shown.contains(SECRET_ACCESS));
            assert!(!shown.contains(SECRET_REFRESH));
        }
    }

    #[test]
    fn refresh_error_classification() {
        assert_eq!(
            classify_refresh_error("Failed to exchange code for access token (invalid_grant)"),
            RefreshError::Rejected
        );
        assert_eq!(
            classify_refresh_error("Failed to exchange code for access token (Request failed)"),
            RefreshError::Network
        );
        assert_eq!(
            classify_refresh_error("operation timed out"),
            RefreshError::Network
        );
        assert_eq!(classify_refresh_error("something else"), RefreshError::Other);
    }

    #[test]
    fn merge_keeps_old_refresh_token_and_scopes_when_omitted() {
        let old = ls_token(3600, 1_000);
        let merged = merge_refreshed(10_000, &old, "NEW-ACCESS".into(), String::new(), 3600, vec![]);
        assert_eq!(merged.access_token, "NEW-ACCESS");
        assert_eq!(merged.refresh_token, SECRET_REFRESH);
        assert_eq!(merged.scopes, old.scopes);
        assert_eq!(merged.expires_at, 13_600);
        assert_eq!(merged.expires_in, 3600);

        // a rotated refresh token and new scopes win
        let rotated = merge_refreshed(
            10_000,
            &old,
            "A2".into(),
            "R2".into(),
            1800,
            vec!["streaming".into()],
        );
        assert_eq!(rotated.refresh_token, "R2");
        assert_eq!(rotated.scopes, vec!["streaming".to_string()]);
        assert_eq!(rotated.expires_at, 11_800);

        // a zero lifetime falls back to 3600 so it cannot trigger a refresh loop
        let zero = merge_refreshed(10_000, &old, "A3".into(), "R3".into(), 0, vec![]);
        assert_eq!(zero.expires_in, 3600);
    }

    #[test]
    fn streaming_token_file_round_trip_is_0600() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("state/librespot_token.json");
        let token = ls_token(3600, 123_456);

        assert_eq!(read_librespot_token_file(&path).expect("read"), None);
        write_librespot_token_file(&path, &token).expect("write");
        let mode = std::fs::metadata(&path).expect("meta").permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert_eq!(read_librespot_token_file(&path).expect("read"), Some(token));

        // no temp file is left behind by the atomic write
        let leftovers: Vec<_> = std::fs::read_dir(path.parent().expect("parent"))
            .expect("dir")
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());
    }

    #[test]
    fn corrupt_streaming_file_is_moved_aside_and_recovers() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("librespot_token.json");
        std::fs::write(&path, b"{ this is not json").expect("write garbage");

        // reading never fails hard: no token, file quarantined
        assert_eq!(read_librespot_token_file(&path).expect("read"), None);
        assert!(!path.exists());
        assert!(dir.path().join("librespot_token.json.corrupt").exists());

        // a new sign-in saves and loads normally afterwards
        let token = ls_token(3600, 999);
        write_librespot_token_file(&path, &token).expect("write");
        assert_eq!(read_librespot_token_file(&path).expect("read"), Some(token));

        // wrong shape (valid JSON, missing fields) is also treated as corrupt
        std::fs::write(&path, b"{\"access_token\":\"x\"}").expect("write partial");
        assert_eq!(read_librespot_token_file(&path).expect("read"), None);
    }

    #[test]
    fn old_token_store_loads_unchanged() {
        // token.json as written before the rework, including one without the `scopes` field
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("token.json");
        let old = r#"{"client_id":"abc","access_token":"AT","refresh_token":"RT","expires_at":4102444800,"expires_in":3600,"token_type":"Bearer"}"#;
        std::fs::write(&path, old).expect("write");
        match read_json_file::<TokenData>(&path) {
            FileRead::Found(t) => {
                assert_eq!(t.client_id, "abc");
                assert_eq!(t.access_token, "AT");
                assert!(t.scopes.is_empty());
            }
            _ => panic!("old token file did not load"),
        }
        // and with scopes
        let with_scopes = r#"{"client_id":"abc","access_token":"AT","refresh_token":"RT","expires_at":4102444800,"expires_in":3600,"token_type":"Bearer","scopes":["user-library-read"]}"#;
        std::fs::write(&path, with_scopes).expect("write");
        assert!(matches!(read_json_file::<TokenData>(&path), FileRead::Found(_)));

        // the two slots never share a file or a keyring entry
        assert_ne!(token_file_path(), librespot_token_file_path());
        assert_ne!(KEYRING_USER, LIBRESPOT_KEYRING_USER);
    }

    #[test]
    fn two_slots_do_not_share_a_temp_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let a = dir.path().join("token.json");
        let b = dir.path().join("librespot_token.json");
        save_file_0600(&a, b"{\"a\":1}").expect("a");
        save_file_0600(&b, b"{\"b\":2}").expect("b");
        assert_eq!(std::fs::read(&a).expect("read a"), b"{\"a\":1}");
        assert_eq!(std::fs::read(&b).expect("read b"), b"{\"b\":2}");
    }

    #[test]
    fn librespot_oauth_parameters_come_from_the_crate_or_its_examples() {
        let id = librespot_client_id();
        assert_eq!(id.len(), 32); // a Spotify client ID, taken from SessionConfig
        assert!(LIBRESPOT_SCOPES.contains(&"streaming"));
        assert!(LIBRESPOT_REDIRECT_URI.starts_with("http://127.0.0.1:"));
    }

    #[tokio::test]
    async fn refresh_without_a_refresh_token_fails_cleanly() {
        let mut t = ls_token(3600, 1);
        t.refresh_token = String::new();
        assert_eq!(
            refresh_librespot_token(&t).await,
            Err(RefreshError::MissingRefreshToken)
        );
    }
}
