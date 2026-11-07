//! Streaming sign-in: librespot's own OAuth flow, plus keeping its token fresh.
//!
//! Rework Part 3. The token comes from `librespot-oauth` with the client ID, redirect URI and
//! scopes in `token_store` (the client ID is the one the librespot session itself uses; login5
//! rejects tokens from any other client ID with `INVALID_CREDENTIALS`).
//!
//! - [`sign_in`] runs the browser flow. The crate opens the browser and runs the loopback
//!   listener on `127.0.0.1:8898`; the listener cannot be interrupted, so a cancel or timeout
//!   connects to it once to let the blocked call return.
//! - [`fresh_streaming_token`] returns a token that is safe to hand to the session, renewing it
//!   first when it is past 80% of its life. It is called by `ensure_session` and by
//!   [`keep_fresh`], whose wall-clock check also covers suspend and resume.
//!
//! Tokens are secrets: no error type or log line here carries token text.

use crate::token_store::{
    clear_librespot_token, librespot_client_id, load_librespot_token,
    refresh_and_store_librespot_token, save_librespot_token, LibrespotToken, RefreshError,
    LIBRESPOT_REDIRECT_URI, LIBRESPOT_SCOPES,
};
use librespot_oauth::{OAuthClientBuilder, OAuthError, OAuthToken};
use std::fmt;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::sync::{oneshot, Mutex};
use tokio::task::JoinHandle;
use tokio::time::MissedTickBehavior;
use tracing::{info, warn};

/// How long the user has to finish the browser sign-in.
pub const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(180);
/// How often [`keep_fresh`] looks at the stored token. Wall-clock based, so after a suspend
/// the token is checked within this time of resuming.
const KEEP_FRESH_INTERVAL: Duration = Duration::from_secs(30);
/// Shown in the browser tab after the redirect.
const CALLBACK_MESSAGE: &str = "Signed in to Halcyon Music. You can close this tab and go back to the app.";

// ----------------------------------------------------------------------
// Using the stored token
// ----------------------------------------------------------------------

/// Why no usable streaming token is available. Fixed texts only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamAuthError {
    /// Nothing stored, or Spotify refused the stored sign-in: the user must sign in again.
    SignInRequired,
    /// The stored token could not be read (keyring / file problem).
    Unreadable,
    /// Spotify could not be reached and the stored token has expired.
    Network,
    /// Renewing failed for a reason we cannot classify and the stored token has expired.
    Other,
}

impl StreamAuthError {
    /// True when only a new browser sign-in can fix it.
    pub fn needs_sign_in(self) -> bool {
        matches!(self, StreamAuthError::SignInRequired)
    }
}

impl fmt::Display for StreamAuthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // The first three phrases are matched by `describe_engine_start_error` in `audio.rs`.
        f.write_str(match self {
            StreamAuthError::SignInRequired => {
                "No streaming sign-in found; user must log in with Spotify again"
            }
            StreamAuthError::Unreadable => "No usable streaming token: the saved sign-in could not be read",
            StreamAuthError::Network => "No usable streaming token: could not reach Spotify to renew the sign-in",
            StreamAuthError::Other => "No usable streaming token: renewing the sign-in failed",
        })
    }
}

impl std::error::Error for StreamAuthError {}

/// One refresh at a time: Spotify may rotate the refresh token, and two parallel refreshes
/// with the same old token could invalidate each other.
fn refresh_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn read_stored() -> Result<LibrespotToken, StreamAuthError> {
    match load_librespot_token() {
        Ok(Some(token)) => Ok(token),
        Ok(None) => Err(StreamAuthError::SignInRequired),
        Err(e) => {
            // `e` comes from token_store and carries no token text.
            warn!("could not read the streaming token: {e}");
            Err(StreamAuthError::Unreadable)
        }
    }
}

/// A streaming token that is safe to use now. Renews it first when it is due.
///
/// - Spotify refuses the refresh token (revoked): the stored token is deleted and the answer is
///   `SignInRequired`.
/// - A network error or an unclassified error: the stored token is kept (never deleted on a
///   guess). If it has not expired yet it is returned anyway, otherwise the error is reported.
pub async fn fresh_streaming_token() -> Result<LibrespotToken, StreamAuthError> {
    let token = read_stored()?;
    if !token.needs_refresh() {
        return Ok(token);
    }

    let _guard = refresh_lock().lock().await;
    // Someone else may have refreshed while we waited for the lock.
    let token = read_stored()?;
    if !token.needs_refresh() {
        return Ok(token);
    }

    match refresh_and_store_librespot_token(&token).await {
        Ok(fresh) => {
            info!(seconds_left = fresh.seconds_left(), "streaming token renewed");
            Ok(fresh)
        }
        Err(RefreshError::Rejected) => {
            warn!("Spotify refused the streaming refresh token; a new sign-in is needed");
            drop_stored_token();
            Err(StreamAuthError::SignInRequired)
        }
        Err(RefreshError::MissingRefreshToken) => {
            if token.is_expired() {
                warn!("the streaming token has expired and has no refresh token");
                drop_stored_token();
                Err(StreamAuthError::SignInRequired)
            } else {
                Ok(token)
            }
        }
        Err(kind) => {
            if token.is_expired() {
                Err(if kind == RefreshError::Network {
                    StreamAuthError::Network
                } else {
                    StreamAuthError::Other
                })
            } else {
                warn!(?kind, "could not renew the streaming token yet; using the current one");
                Ok(token)
            }
        }
    }
}

/// Renew the streaming token now, even if it looks fresh (used after a 401 from the Web API).
pub async fn force_refresh_streaming_token() -> Result<LibrespotToken, StreamAuthError> {
    let _guard = refresh_lock().lock().await;
    let token = read_stored()?;
    match refresh_and_store_librespot_token(&token).await {
        Ok(fresh) => Ok(fresh),
        Err(RefreshError::Rejected | RefreshError::MissingRefreshToken) => {
            warn!("Spotify refused the streaming refresh token; a new sign-in is needed");
            drop_stored_token();
            Err(StreamAuthError::SignInRequired)
        }
        Err(RefreshError::Network) => Err(StreamAuthError::Network),
        Err(RefreshError::Other) => Err(StreamAuthError::Other),
    }
}

fn drop_stored_token() {
    if let Err(e) = clear_librespot_token() {
        warn!("could not remove the unusable streaming token: {e}");
    }
}

/// Seconds the stored token still has, or `None` if there is none. For status events.
pub fn stored_seconds_left() -> Option<u64> {
    match load_librespot_token() {
        Ok(Some(t)) => Some(t.seconds_left()),
        _ => None,
    }
}

/// Renew the streaming token before it expires, forever (run it under `supervise`).
///
/// Looks at the wall clock every 30 s, so a laptop that slept past the expiry renews the token
/// right after it wakes up (a plain `sleep` would not count the time spent suspended).
pub async fn keep_fresh() -> anyhow::Result<()> {
    let mut tick = tokio::time::interval(KEEP_FRESH_INTERVAL);
    tick.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        let due = matches!(load_librespot_token(), Ok(Some(t)) if t.needs_refresh());
        if due {
            if let Err(e) = fresh_streaming_token().await {
                warn!(error = %e, "background renewal of the streaming token failed");
            }
        }
    }
}

// ----------------------------------------------------------------------
// Browser sign-in
// ----------------------------------------------------------------------

/// Why the browser sign-in did not produce a token. Fixed texts only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignInError {
    Cancelled,
    TimedOut,
    /// Port 8898 is taken (another sign-in, or another program).
    PortBusy,
    Failed(&'static str),
}

impl fmt::Display for SignInError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SignInError::Cancelled => f.write_str("Sign-in cancelled"),
            SignInError::TimedOut => f.write_str("Sign-in timed out; start it again and finish it in the browser within 3 minutes"),
            SignInError::PortBusy => f.write_str("Sign-in could not start: port 8898 is already in use (is another sign-in or librespot running?)"),
            SignInError::Failed(why) => f.write_str(why),
        }
    }
}

impl std::error::Error for SignInError {}

/// The loopback port of the redirect URI.
fn callback_port() -> Option<u16> {
    url::Url::parse(LIBRESPOT_REDIRECT_URI).ok().and_then(|u| u.port())
}

/// Log-safe name of an OAuth error (the crate's `Display` can echo server text).
fn oauth_error_kind(e: &OAuthError) -> &'static str {
    match e {
        OAuthError::AuthCodeListenerBind { .. } => "callback port in use",
        OAuthError::ExchangeCode { .. } => "code exchange refused",
        _ => "other",
    }
}

fn map_oauth_error(e: &OAuthError) -> SignInError {
    let kind = oauth_error_kind(e);
    warn!(kind, "browser sign-in failed");
    match e {
        OAuthError::AuthCodeListenerBind { .. } => SignInError::PortBusy,
        OAuthError::ExchangeCode { .. } => {
            SignInError::Failed("Spotify did not accept the sign-in; try again")
        }
        _ => SignInError::Failed("The browser sign-in did not complete; try again"),
    }
}

/// Convert the crate's token into our stored form and check it can stream.
fn into_stored(token: OAuthToken) -> Result<LibrespotToken, SignInError> {
    let left = token
        .expires_at
        .saturating_duration_since(Instant::now())
        .as_secs();
    // Same default the crate uses when Spotify omits the lifetime.
    let expires_in = if left == 0 { 3600 } else { left };
    if token.refresh_token.is_empty() {
        warn!("Spotify returned no refresh token; the sign-in will expire in about an hour");
    }
    let stored = LibrespotToken::new(token.access_token, token.refresh_token, expires_in, token.scopes);
    if !stored.can_stream() {
        return Err(SignInError::Failed(
            "Spotify did not grant the playback permission; try signing in again",
        ));
    }
    Ok(stored)
}

/// Blocking part of the sign-in: opens the browser, waits for the redirect, exchanges the code.
fn run_browser_flow() -> Result<LibrespotToken, SignInError> {
    let client = OAuthClientBuilder::new(
        &librespot_client_id(),
        LIBRESPOT_REDIRECT_URI,
        LIBRESPOT_SCOPES.to_vec(),
    )
    .open_in_browser()
    .with_custom_message(CALLBACK_MESSAGE)
    .build()
    .map_err(|e| map_oauth_error(&e))?;

    let token = client.get_access_token().map_err(|e| map_oauth_error(&e))?;
    into_stored(token)
}

/// The listener of the crate blocks until something connects. Connect once with a request that
/// carries no code: the crate then returns an error and closes the listener.
async fn unblock_listener(work: &JoinHandle<Result<LibrespotToken, SignInError>>) {
    let Some(port) = callback_port() else {
        return;
    };
    // The listener is bound a moment after the flow starts; retry briefly.
    for _ in 0..20 {
        if work.is_finished() {
            return;
        }
        if let Ok(mut stream) = TcpStream::connect(("127.0.0.1", port)).await {
            let _ = stream.write_all(b"GET / HTTP/1.1\r\n\r\n").await;
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Run the browser sign-in, store the token, and return it. `cancel` ends it early.
/// The caller decides what to tell the GUI; nothing here logs token text.
pub async fn sign_in(mut cancel: oneshot::Receiver<()>) -> Result<LibrespotToken, SignInError> {
    let mut work = tokio::task::spawn_blocking(run_browser_flow);

    enum Early {
        Cancelled,
        TimedOut,
    }

    let early = tokio::select! {
        done = &mut work => {
            let token = match done {
                Ok(result) => result?,
                Err(_) => return Err(SignInError::Failed("The sign-in stopped unexpectedly; try again")),
            };
            return store(token);
        }
        _ = &mut cancel => Early::Cancelled,
        _ = tokio::time::sleep(SIGN_IN_TIMEOUT) => Early::TimedOut,
    };

    unblock_listener(&work).await;
    // Give the blocked thread a moment to release port 8898 so a new attempt can bind it.
    let _ = tokio::time::timeout(Duration::from_secs(5), &mut work).await;
    Err(match early {
        Early::Cancelled => SignInError::Cancelled,
        Early::TimedOut => SignInError::TimedOut,
    })
}

fn store(token: LibrespotToken) -> Result<LibrespotToken, SignInError> {
    match save_librespot_token(&token) {
        Ok(()) => {
            info!(seconds_left = token.seconds_left(), "streaming sign-in stored");
            Ok(token)
        }
        Err(e) => {
            warn!("could not save the streaming sign-in: {e}");
            Err(SignInError::Failed(
                "Signed in, but the sign-in could not be saved (keyring and file both failed)",
            ))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_carry_no_token_text() {
        for e in [
            StreamAuthError::SignInRequired,
            StreamAuthError::Unreadable,
            StreamAuthError::Network,
            StreamAuthError::Other,
        ] {
            let text = format!("{e} {e:?}");
            assert!(!text.to_lowercase().contains("bearer"));
        }
        assert!(StreamAuthError::SignInRequired.needs_sign_in());
        assert!(!StreamAuthError::Network.needs_sign_in());
    }

    #[test]
    fn missing_token_error_matches_the_engine_hint() {
        // audio::describe_engine_start_error keys on these phrases.
        let text = StreamAuthError::SignInRequired.to_string().to_lowercase();
        assert!(text.contains("must log in"));
        let hint = crate::audio::describe_engine_start_error(&StreamAuthError::SignInRequired.to_string());
        assert!(hint.to_lowercase().contains("sign in"));
    }

    #[test]
    fn callback_port_comes_from_the_redirect_uri() {
        assert_eq!(callback_port(), Some(8898));
    }

    #[test]
    fn oauth_token_converts_and_must_have_streaming_scope() {
        let mk = |scopes: Vec<String>, secs: u64| OAuthToken {
            access_token: "a".into(),
            refresh_token: "r".into(),
            expires_at: Instant::now() + Duration::from_secs(secs),
            token_type: "Bearer".into(),
            scopes,
        };
        let ok = into_stored(mk(vec!["streaming".into()], 3600)).expect("converts");
        assert!(ok.can_stream());
        assert!(ok.expires_in > 3500 && ok.expires_in <= 3600);
        assert!(ok.seconds_left() > 0);

        // Lifetime already gone: the 3600 s default applies, so it cannot loop on refresh.
        let zero = into_stored(mk(vec!["streaming".into()], 0)).expect("converts");
        assert_eq!(zero.expires_in, 3600);

        assert!(matches!(
            into_stored(mk(vec!["user-read-private".into()], 3600)),
            Err(SignInError::Failed(_))
        ));
    }

    #[test]
    fn sign_in_errors_are_readable() {
        assert!(SignInError::PortBusy.to_string().contains("8898"));
        assert!(SignInError::TimedOut.to_string().contains("3 minutes"));
        assert_eq!(SignInError::Cancelled.to_string(), "Sign-in cancelled");
    }
}
