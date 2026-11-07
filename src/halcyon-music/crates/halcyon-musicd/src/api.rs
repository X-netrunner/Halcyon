//! Spotify Web API Client.
//!
//! Features:
//! - Typed models and pagination helpers
//! - Global rate limiter that honours `Retry-After` on 429 and spreads bursts
//! - 8 s request timeout
//! - 3 retries with jitter on 5xx and network errors
//! - Circuit breaker per endpoint family
//! - Pre-expiry refresh + 401 refresh-once-and-retry, with clean `AuthRequired` on failure

use crate::auth::refresh_access_token;
use crate::auth_mode;
use crate::stream_auth::{self, StreamAuthError};
use crate::token_store::{load_token, TokenData};
use halcyon_music_core::models::AuthMode;
use std::sync::atomic::{AtomicBool, Ordering};
use halcyon_music_core::models::{Album, Artist, DetailedSearchResults, Page, Playlist, Track};
use rand::Rng;
use serde::Deserialize;
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

pub const SPOTIFY_API_BASE: &str = "https://api.spotify.com/v1";
pub const REQUEST_TIMEOUT: Duration = Duration::from_secs(8);
pub const CIRCUIT_FAILURE_THRESHOLD: u32 = 3;
pub const CIRCUIT_COOLDOWN: Duration = Duration::from_secs(30);

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("Network error: {0}")]
    Network(String),

    #[error("Request timed out (8s limit)")]
    Timeout,

    #[error("Spotify HTTP error {status}: {message}")]
    Http { status: u16, message: String },

    #[error("Rate limited by Spotify (retry after {0}s)")]
    RateLimited(u64),

    #[error("Circuit breaker is open for {family:?}: endpoint is cooling down")]
    CircuitOpen { family: EndpointFamily },

    #[error("Authentication required: {0}")]
    AuthRequired(String),

    #[error("Serialization error: {0}")]
    Serialization(String),
}

/// Map "no usable librespot token" to the errors the rest of the client already handles:
/// a missing or revoked sign-in is `AuthRequired` (the GUI shows the sign-in screen); a network
/// problem is a plain network error (the library stays on screen, served from the cache).
fn stream_auth_to_api_error(e: StreamAuthError) -> ApiError {
    match e {
        StreamAuthError::SignInRequired => ApiError::AuthRequired(
            "Your Spotify sign-in is missing or was revoked. Please sign in with Spotify.".into(),
        ),
        StreamAuthError::Unreadable => ApiError::AuthRequired(
            "The saved Spotify sign-in could not be read. Please sign in with Spotify again.".into(),
        ),
        StreamAuthError::Network | StreamAuthError::Other => ApiError::Network(e.to_string()),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EndpointFamily {
    Tracks,
    Albums,
    Artists,
    Playlists,
    UserLibrary,
    Search,
    Browse,
    Recommendations,
    Player,
    Other,
}

#[derive(Debug, Clone, Default)]
struct CircuitState {
    consecutive_failures: u32,
    open_until: Option<Instant>,
}

/// Global rate limiter and request spacing state.
struct RateLimiter {
    retry_after_until: Option<Instant>,
    last_request_time: Instant,
    min_spacing: Duration,
}

#[derive(Clone)]
pub struct SpotifyClient {
    http: reqwest::Client,
    base_url: String,
    token_url: Option<String>,
    token: Arc<Mutex<Option<TokenData>>>,
    /// True: browse with the user's own Client ID token (`token`). False (default): browse with
    /// librespot's own token (`stream_auth`). Shared by all clones.
    own_client: Arc<AtomicBool>,
    circuits: Arc<Mutex<HashMap<EndpointFamily, CircuitState>>>,
    rate_limiter: Arc<Mutex<RateLimiter>>,
    timeout: Duration,
}

impl SpotifyClient {
    pub fn new(base_url: Option<String>, token_url: Option<String>) -> Self {
        Self::with_timeout(base_url, token_url, REQUEST_TIMEOUT)
    }

    pub fn with_timeout(base_url: Option<String>, token_url: Option<String>, timeout: Duration) -> Self {
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .build()
            .unwrap_or_default();

        let token = load_token().unwrap_or(None);

        Self {
            http,
            base_url: base_url.unwrap_or_else(|| SPOTIFY_API_BASE.to_string()),
            token_url,
            token: Arc::new(Mutex::new(token)),
            own_client: Arc::new(AtomicBool::new(auth_mode::initial() == AuthMode::OwnClientId)),
            circuits: Arc::new(Mutex::new(HashMap::new())),
            rate_limiter: Arc::new(Mutex::new(RateLimiter {
                retry_after_until: None,
                last_request_time: Instant::now() - Duration::from_secs(1),
                min_spacing: Duration::from_millis(30),
            })),
            timeout,
        }
    }

    /// Store a custom-Client-ID token. Using it implies the own-client-id mode (in memory;
    /// the daemon persists the choice with [`SpotifyClient::switch_mode`]).
    pub async fn set_token(&self, token: TokenData) {
        let mut guard = self.token.lock().await;
        *guard = Some(token);
        self.own_client.store(true, Ordering::SeqCst);
    }

    /// The token browsing currently uses.
    pub fn auth_mode(&self) -> AuthMode {
        if self.own_client.load(Ordering::SeqCst) {
            AuthMode::OwnClientId
        } else {
            AuthMode::Librespot
        }
    }

    /// Change the browsing token, remember the choice, and forget circuit-breaker history (a
    /// refusal seen with the other token says nothing about this one).
    pub async fn switch_mode(&self, mode: AuthMode) {
        self.own_client
            .store(mode == AuthMode::OwnClientId, Ordering::SeqCst);
        if let Err(e) = auth_mode::save(mode) {
            warn!("could not save the sign-in mode: {e}");
        }
        self.circuits.lock().await.clear();
    }

    pub async fn clear_token(&self) {
        let mut guard = self.token.lock().await;
        *guard = None;
    }

    pub async fn is_authenticated(&self) -> bool {
        if self.auth_mode() == AuthMode::Librespot {
            return stream_auth::stored_seconds_left().is_some();
        }
        let guard = self.token.lock().await;
        guard.is_some()
    }

    pub async fn current_user_id(&self) -> Option<String> {
        if self.auth_mode() == AuthMode::Librespot {
            return None;
        }
        let guard = self.token.lock().await;
        guard.as_ref().map(|t| t.client_id.clone())
    }

    /// Check circuit breaker for endpoint family.
    async fn check_circuit(&self, family: EndpointFamily) -> Result<(), ApiError> {
        let mut circuits = self.circuits.lock().await;
        let entry = circuits.entry(family).or_default();

        if let Some(until) = entry.open_until {
            if Instant::now() < until {
                return Err(ApiError::CircuitOpen { family });
            } else {
                // Cooldown passed: half-open probe
                entry.open_until = None;
            }
        }
        Ok(())
    }

    async fn record_circuit_success(&self, family: EndpointFamily) {
        let mut circuits = self.circuits.lock().await;
        let entry = circuits.entry(family).or_default();
        entry.consecutive_failures = 0;
        entry.open_until = None;
    }

    async fn record_circuit_failure(&self, family: EndpointFamily) {
        let mut circuits = self.circuits.lock().await;
        let entry = circuits.entry(family).or_default();
        entry.consecutive_failures = entry.consecutive_failures.saturating_add(1);
        if entry.consecutive_failures >= CIRCUIT_FAILURE_THRESHOLD {
            entry.open_until = Some(Instant::now() + CIRCUIT_COOLDOWN);
            warn!("circuit breaker tripped for {family:?}; cooling down for 30s");
        }
    }

    /// Global rate limiter: enforces Retry-After and minimum spacing between bursts.
    async fn enforce_rate_limits(&self) {
        let delay_needed = {
            let mut rl = self.rate_limiter.lock().await;
            let now = Instant::now();

            // 1. Check Retry-After delay
            let wait_retry = if let Some(until) = rl.retry_after_until {
                if now < until {
                    Some(until.duration_since(now))
                } else {
                    rl.retry_after_until = None;
                    None
                }
            } else {
                None
            };

            // 2. Check spacing between requests to spread bursts
            let elapsed_since_last = now.duration_since(rl.last_request_time);
            let wait_spacing = if elapsed_since_last < rl.min_spacing {
                Some(rl.min_spacing - elapsed_since_last)
            } else {
                None
            };

            let delay = match (wait_retry, wait_spacing) {
                (Some(d1), Some(d2)) => Some(d1.max(d2)),
                (Some(d1), None) => Some(d1),
                (None, Some(d2)) => Some(d2),
                (None, None) => None,
            };

            rl.last_request_time = now + delay.unwrap_or_default();
            delay
        };

        if let Some(delay) = delay_needed {
            tokio::time::sleep(delay).await;
        }
    }

    /// Set global 429 Retry-After delay.
    async fn set_retry_after(&self, seconds: u64) {
        let mut rl = self.rate_limiter.lock().await;
        rl.retry_after_until = Some(Instant::now() + Duration::from_secs(seconds));
    }

    /// Ensure valid access token; refreshes before expiry (at 80% of lifetime).
    pub async fn ensure_valid_token(&self) -> Result<String, ApiError> {
        if self.auth_mode() == AuthMode::Librespot {
            return stream_auth::fresh_streaming_token()
                .await
                .map(|t| t.access_token)
                .map_err(stream_auth_to_api_error);
        }
        let mut guard = self.token.lock().await;

        let token = match guard.as_ref() {
            Some(t) => t.clone(),
            None => {
                return Err(ApiError::AuthRequired(
                    "No Spotify credentials found. Please log in.".into(),
                ))
            }
        };

        if token.needs_refresh() {
            debug!("token is past 80% of lifetime; refreshing before expiry");
            match refresh_access_token(&self.http, &token, self.token_url.as_deref()).await {
                Ok(new_token) => {
                    let access = new_token.access_token.clone();
                    *guard = Some(new_token);
                    return Ok(access);
                }
                Err(e) => {
                    warn!("pre-expiry token refresh failed: {e}");
                    // If strictly expired, must fail with AuthRequired
                    if token.is_expired() {
                        *guard = None;
                        return Err(ApiError::AuthRequired(format!(
                            "Spotify session expired: {e}. Please log in again."
                        )));
                    }
                }
            }
        }

        Ok(token.access_token)
    }

    /// Force refresh token once (called on 401).
    pub async fn force_refresh_token(&self) -> Result<String, ApiError> {
        if self.auth_mode() == AuthMode::Librespot {
            return stream_auth::force_refresh_streaming_token()
                .await
                .map(|t| t.access_token)
                .map_err(stream_auth_to_api_error);
        }
        let mut guard = self.token.lock().await;
        let token = match guard.as_ref() {
            Some(t) => t.clone(),
            None => return Err(ApiError::AuthRequired("No token to refresh".into())),
        };

        match refresh_access_token(&self.http, &token, self.token_url.as_deref()).await {
            Ok(new_token) => {
                let access = new_token.access_token.clone();
                *guard = Some(new_token);
                Ok(access)
            }
            Err(e) => {
                *guard = None;
                Err(ApiError::AuthRequired(format!(
                    "Spotify token refresh rejected ({e}). Please log in again."
                )))
            }
        }
    }

    /// Execute HTTP request with 8s timeout, retries, circuit breaker and 401 refresh.
    pub async fn request(
        &self,
        family: EndpointFamily,
        method: reqwest::Method,
        endpoint_or_url: &str,
        query: &[(&str, &str)],
    ) -> Result<String, ApiError> {
        self.check_circuit(family).await?;

        let url = if endpoint_or_url.starts_with("http://") || endpoint_or_url.starts_with("https://") {
            endpoint_or_url.to_string()
        } else {
            format!("{}{}", self.base_url, endpoint_or_url)
        };

        let mut token = self.ensure_valid_token().await?;
        let mut refreshed_on_401 = false;
        let mut attempts = 0;

        loop {
            attempts += 1;
            self.enforce_rate_limits().await;

            if crate::faults::should_simulate_network_drop() {
                self.record_circuit_failure(family).await;
                return Err(ApiError::Network("Injected transient network drop".into()));
            }

            if !refreshed_on_401 && crate::faults::should_simulate_auth_expired() {
                warn!("injected 401 Unauthorized for recovery testing");
                token = self.force_refresh_token().await?;
                refreshed_on_401 = true;
                continue;
            }

            let mut req = self
                .http
                .request(method.clone(), &url)
                .bearer_auth(&token)
                .timeout(self.timeout);

            if !query.is_empty() {
                req = req.query(query);
            }

            let resp_result = req.send().await;

            match resp_result {
                Ok(resp) => {
                    let status = resp.status();

                    if status.is_success() {
                        self.record_circuit_success(family).await;
                        let text = resp
                            .text()
                            .await
                            .map_err(|e| ApiError::Network(format!("read response failed: {e}")))?;
                        return Ok(text);
                    }

                    // 401 Unauthorized -> Refresh once, then retry
                    if status == reqwest::StatusCode::UNAUTHORIZED && !refreshed_on_401 {
                        info!("received 401 Unauthorized; attempting single token refresh");
                        refreshed_on_401 = true;
                        token = self.force_refresh_token().await?;
                        continue;
                    }

                    // 429 Too Many Requests -> Rate limiter with Retry-After
                    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
                        let retry_after_secs = resp
                            .headers()
                            .get("Retry-After")
                            .and_then(|h| h.to_str().ok())
                            .and_then(|s| s.parse::<u64>().ok())
                            .unwrap_or(1);

                        warn!("received 429 rate limit: Retry-After {retry_after_secs}s");
                        self.set_retry_after(retry_after_secs).await;

                        if attempts < 3 {
                            tokio::time::sleep(Duration::from_secs(retry_after_secs)).await;
                            continue;
                        } else {
                            return Err(ApiError::RateLimited(retry_after_secs));
                        }
                    }

                    // 5xx Server Errors -> Exponential backoff with jitter (3 retries)
                    if status.is_server_error() {
                        self.record_circuit_failure(family).await;
                        if attempts < 3 {
                            let backoff = calculate_jitter_backoff(attempts);
                            warn!("server error {status}; retrying in {backoff:?}");
                            tokio::time::sleep(backoff).await;
                            continue;
                        } else {
                            let text = resp.text().await.unwrap_or_default();
                            return Err(ApiError::Http {
                                status: status.as_u16(),
                                message: text,
                            });
                        }
                    }

                    // 4xx client errors
                    let text = resp.text().await.unwrap_or_default();
                    return Err(ApiError::Http {
                        status: status.as_u16(),
                        message: text,
                    });
                }
                Err(err) => {
                    let is_timeout = err.is_timeout();
                    self.record_circuit_failure(family).await;

                    if attempts < 3 {
                        let backoff = calculate_jitter_backoff(attempts);
                        warn!("network/timeout error: {err}; retrying in {backoff:?}");
                        tokio::time::sleep(backoff).await;
                        continue;
                    } else if is_timeout {
                        return Err(ApiError::Timeout);
                    } else {
                        return Err(ApiError::Network(err.to_string()));
                    }
                }
            }
        }
    }

    // --- High Level API Methods ---

    /// Search tracks (capped at 10 results per request as per brief).
    pub async fn search_tracks(&self, query: &str, limit: u32, offset: u32) -> Result<Page<Track>, ApiError> {
        let safe_limit = limit.min(10); // Hard rule: search capped at 10 results per request
        let limit_str = safe_limit.to_string();
        let offset_str = offset.to_string();

        let json = self
            .request(
                EndpointFamily::Search,
                reqwest::Method::GET,
                "/search",
                &[
                    ("q", query),
                    ("type", "track"),
                    ("limit", &limit_str),
                    ("offset", &offset_str),
                ],
            )
            .await?;

        let parsed: SpotifySearchResponse = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse search response: {e}")))?;

        let tracks = parsed
            .tracks
            .items
            .into_iter()
            .map(convert_spotify_track)
            .collect();

        Ok(Page {
            items: tracks,
            total: parsed.tracks.total,
            limit: parsed.tracks.limit,
            offset: parsed.tracks.offset,
            next: parsed.tracks.next,
            previous: parsed.tracks.previous,
        })
    }

    /// Get user's playlists.
    pub async fn get_playlists(&self, limit: u32, offset: u32) -> Result<Page<Playlist>, ApiError> {
        let limit_str = limit.to_string();
        let offset_str = offset.to_string();

        let json = self
            .request(
                EndpointFamily::Playlists,
                reqwest::Method::GET,
                "/me/playlists",
                &[("limit", &limit_str), ("offset", &offset_str)],
            )
            .await?;

        let parsed: SpotifyPaging<SpotifyPlaylist> = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse playlists: {e}")))?;

        let playlists = parsed
            .items
            .into_iter()
            .map(convert_spotify_playlist)
            .collect();

        Ok(Page {
            items: playlists,
            total: parsed.total,
            limit: parsed.limit,
            offset: parsed.offset,
            next: parsed.next,
            previous: parsed.previous,
        })
    }

    /// Get tracks in a playlist.
    pub async fn get_playlist_tracks(
        &self,
        playlist_id: &str,
        limit: u32,
        offset: u32,
    ) -> Result<Page<Track>, ApiError> {
        let limit_str = limit.to_string();
        let offset_str = offset.to_string();
        let endpoint = format!("/playlists/{playlist_id}/tracks");

        let json = self
            .request(
                EndpointFamily::Playlists,
                reqwest::Method::GET,
                &endpoint,
                &[("limit", &limit_str), ("offset", &offset_str)],
            )
            .await?;

        let parsed: SpotifyPaging<SpotifyPlaylistTrackItem> = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse playlist tracks: {e}")))?;

        let tracks = parsed
            .items
            .into_iter()
            .filter_map(|item| item.track)
            .map(convert_spotify_track)
            .collect();

        Ok(Page {
            items: tracks,
            total: parsed.total,
            limit: parsed.limit,
            offset: parsed.offset,
            next: parsed.next,
            previous: parsed.previous,
        })
    }

    /// Get user's saved/liked tracks.
    pub async fn get_saved_tracks(&self, limit: u32, offset: u32) -> Result<Page<Track>, ApiError> {
        let limit_str = limit.to_string();
        let offset_str = offset.to_string();

        let json = self
            .request(
                EndpointFamily::UserLibrary,
                reqwest::Method::GET,
                "/me/tracks",
                &[("limit", &limit_str), ("offset", &offset_str)],
            )
            .await?;

        let parsed: SpotifyPaging<SpotifySavedTrackItem> = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse saved tracks: {e}")))?;

        let tracks = parsed
            .items
            .into_iter()
            .map(|item| convert_spotify_track(item.track))
            .collect();

        Ok(Page {
            items: tracks,
            total: parsed.total,
            limit: parsed.limit,
            offset: parsed.offset,
            next: parsed.next,
            previous: parsed.previous,
        })
    }

    /// Probe an endpoint and return the HTTP status code.
    pub async fn probe(&self, endpoint: &str, _family: EndpointFamily) -> Result<u16, ApiError> {
        let url = format!("{}{}", self.base_url, endpoint);
        let token = self.ensure_valid_token().await?;

        let resp = self
            .http
            .get(&url)
            .bearer_auth(&token)
            .timeout(Duration::from_secs(5))
            .send()
            .await
            .map_err(|e| ApiError::Network(e.to_string()))?;

        Ok(resp.status().as_u16())
    }

    /// Execute HTTP request with JSON body.
    pub async fn request_json<B: serde::Serialize>(
        &self,
        family: EndpointFamily,
        method: reqwest::Method,
        endpoint_or_url: &str,
        body: &B,
    ) -> Result<String, ApiError> {
        self.check_circuit(family).await?;

        let url = if endpoint_or_url.starts_with("http://") || endpoint_or_url.starts_with("https://") {
            endpoint_or_url.to_string()
        } else {
            format!("{}{}", self.base_url, endpoint_or_url)
        };

        let mut token = self.ensure_valid_token().await?;
        let mut refreshed_on_401 = false;
        let mut attempts = 0;

        loop {
            attempts += 1;
            self.enforce_rate_limits().await;

            let req = self
                .http
                .request(method.clone(), &url)
                .bearer_auth(&token)
                .json(body)
                .timeout(self.timeout);

            let resp_result = req.send().await;

            match resp_result {
                Ok(resp) => {
                    let status = resp.status();

                    if status.is_success() {
                        self.record_circuit_success(family).await;
                        let text = resp
                            .text()
                            .await
                            .map_err(|e| ApiError::Network(format!("read response failed: {e}")))?;
                        return Ok(text);
                    }

                    if status == reqwest::StatusCode::UNAUTHORIZED && !refreshed_on_401 {
                        info!("received 401 Unauthorized; attempting single token refresh");
                        refreshed_on_401 = true;
                        token = self.force_refresh_token().await?;
                        continue;
                    }

                    if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
                        let retry_after_secs = resp
                            .headers()
                            .get("Retry-After")
                            .and_then(|h| h.to_str().ok())
                            .and_then(|s| s.parse::<u64>().ok())
                            .unwrap_or(1);
                        self.set_retry_after(retry_after_secs).await;
                        if attempts < 3 {
                            tokio::time::sleep(Duration::from_secs(retry_after_secs)).await;
                            continue;
                        } else {
                            return Err(ApiError::RateLimited(retry_after_secs));
                        }
                    }

                    if status.is_server_error() {
                        self.record_circuit_failure(family).await;
                        if attempts < 3 {
                            let backoff = calculate_jitter_backoff(attempts);
                            tokio::time::sleep(backoff).await;
                            continue;
                        }
                    }

                    let text = resp.text().await.unwrap_or_default();
                    return Err(ApiError::Http {
                        status: status.as_u16(),
                        message: text,
                    });
                }
                Err(err) => {
                    self.record_circuit_failure(family).await;
                    if attempts < 3 {
                        let backoff = calculate_jitter_backoff(attempts);
                        tokio::time::sleep(backoff).await;
                        continue;
                    }
                    if err.is_timeout() {
                        return Err(ApiError::Timeout);
                    }
                    return Err(ApiError::Network(err.to_string()));
                }
            }
        }
    }

    /// Get user's recently played tracks from Spotify.
    pub async fn get_recently_played(&self, limit: u32) -> Result<Vec<Track>, ApiError> {
        let limit_str = limit.to_string();
        let json = self
            .request(
                EndpointFamily::Player,
                reqwest::Method::GET,
                "/me/player/recently-played",
                &[("limit", &limit_str)],
            )
            .await?;

        let parsed: SpotifyRecentlyPlayedResponse = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse recently-played: {e}")))?;

        Ok(parsed.items.into_iter().map(|item| convert_spotify_track(item.track)).collect())
    }

    /// Get user's top tracks.
    pub async fn get_top_tracks(&self, limit: u32, time_range: &str) -> Result<Vec<Track>, ApiError> {
        let limit_str = limit.to_string();
        let json = self
            .request(
                EndpointFamily::UserLibrary,
                reqwest::Method::GET,
                "/me/top/tracks",
                &[("limit", &limit_str), ("time_range", time_range)],
            )
            .await?;

        let parsed: SpotifyPaging<SpotifyTrack> = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse top tracks: {e}")))?;

        Ok(parsed.items.into_iter().map(convert_spotify_track).collect())
    }

    /// Get user's top artists.
    pub async fn get_top_artists(&self, limit: u32, time_range: &str) -> Result<Vec<Artist>, ApiError> {
        let limit_str = limit.to_string();
        let json = self
            .request(
                EndpointFamily::Artists,
                reqwest::Method::GET,
                "/me/top/artists",
                &[("limit", &limit_str), ("time_range", time_range)],
            )
            .await?;

        let parsed: SpotifyPaging<SpotifyArtistItem> = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse top artists: {e}")))?;

        Ok(parsed.items.into_iter().map(convert_spotify_artist).collect())
    }

    /// Get artists the user follows.
    pub async fn get_followed_artists(&self, limit: u32) -> Result<Vec<Artist>, ApiError> {
        let limit_str = limit.to_string();
        let json = self
            .request(
                EndpointFamily::Artists,
                reqwest::Method::GET,
                "/me/following",
                &[("type", "artist"), ("limit", &limit_str)],
            )
            .await?;

        let parsed: SpotifyFollowedResponse = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse followed artists: {e}")))?;

        Ok(parsed.artists.items.into_iter().map(convert_spotify_artist).collect())
    }

    /// Get an artist's latest albums and singles.
    pub async fn get_artist_albums(&self, artist_id: &str, limit: u32) -> Result<Vec<Album>, ApiError> {
        let limit_str = limit.to_string();
        let endpoint = format!("/artists/{artist_id}/albums");
        let json = self
            .request(
                EndpointFamily::Artists,
                reqwest::Method::GET,
                &endpoint,
                &[("include_groups", "album,single"), ("limit", &limit_str)],
            )
            .await?;

        let parsed: SpotifyPaging<SpotifyAlbumItem> = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse artist albums: {e}")))?;

        Ok(parsed.items.into_iter().map(convert_spotify_album).collect())
    }

    /// Get tracks of a specific album.
    pub async fn get_album_tracks(&self, album_id: &str) -> Result<Vec<Track>, ApiError> {
        let endpoint = format!("/albums/{album_id}/tracks");
        let json = self
            .request(
                EndpointFamily::Albums,
                reqwest::Method::GET,
                &endpoint,
                &[("limit", "50")],
            )
            .await?;

        let parsed: SpotifyPaging<SpotifyTrack> = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse album tracks: {e}")))?;

        Ok(parsed.items.into_iter().map(convert_spotify_track).collect())
    }

    /// Get user's saved albums.
    pub async fn get_saved_albums(&self, limit: u32, offset: u32) -> Result<Page<Album>, ApiError> {
        let limit_str = limit.to_string();
        let offset_str = offset.to_string();
        let json = self
            .request(
                EndpointFamily::UserLibrary,
                reqwest::Method::GET,
                "/me/albums",
                &[("limit", &limit_str), ("offset", &offset_str)],
            )
            .await?;

        let parsed: SpotifyPaging<SpotifySavedAlbumItem> = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse saved albums: {e}")))?;

        let albums = parsed.items.into_iter().map(|item| convert_spotify_album(item.album)).collect();

        Ok(Page {
            items: albums,
            total: parsed.total,
            limit: parsed.limit,
            offset: parsed.offset,
            next: parsed.next,
            previous: parsed.previous,
        })
    }

    /// Create a new private playlist on Spotify.
    pub async fn create_playlist(&self, user_id: &str, name: &str, description: &str) -> Result<Playlist, ApiError> {
        let endpoint = format!("/users/{user_id}/playlists");
        #[derive(serde::Serialize)]
        struct CreateBody<'a> {
            name: &'a str,
            description: &'a str,
            public: bool,
        }

        let body = CreateBody {
            name,
            description,
            public: false,
        };

        let json = self
            .request_json(EndpointFamily::Playlists, reqwest::Method::POST, &endpoint, &body)
            .await?;

        let parsed: SpotifyPlaylist = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse created playlist: {e}")))?;

        Ok(convert_spotify_playlist(parsed))
    }

    /// Add tracks to a playlist.
    pub async fn add_tracks_to_playlist(&self, playlist_id: &str, uris: &[String]) -> Result<(), ApiError> {
        let endpoint = format!("/playlists/{playlist_id}/tracks");
        #[derive(serde::Serialize)]
        struct AddBody<'a> {
            uris: &'a [String],
        }

        let body = AddBody { uris };
        let _ = self
            .request_json(EndpointFamily::Playlists, reqwest::Method::POST, &endpoint, &body)
            .await?;

        Ok(())
    }

    /// Get recommendations based on seed artists and tracks (Tier 1).
    pub async fn get_recommendations(
        &self,
        seed_artists: &[String],
        seed_tracks: &[String],
        limit: u32,
    ) -> Result<Vec<Track>, ApiError> {
        let artists_str = seed_artists.join(",");
        let tracks_str = seed_tracks.join(",");
        let limit_str = limit.to_string();

        let mut query = vec![("limit", limit_str.as_str())];
        if !artists_str.is_empty() {
            query.push(("seed_artists", artists_str.as_str()));
        }
        if !tracks_str.is_empty() {
            query.push(("seed_tracks", tracks_str.as_str()));
        }

        let json = self
            .request(EndpointFamily::Recommendations, reqwest::Method::GET, "/recommendations", &query)
            .await?;

        let parsed: SpotifyRecommendationsResponse = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse recommendations: {e}")))?;

        Ok(parsed.tracks.into_iter().map(convert_spotify_track).collect())
    }

    /// Multi-category search (Top, Songs, Artists, Albums, Playlists).
    pub async fn search_detailed(
        &self,
        query: &str,
        search_type: &str,
        limit: u32,
        offset: u32,
    ) -> Result<DetailedSearchResults, ApiError> {
        let safe_limit = limit.min(10);
        let limit_str = safe_limit.to_string();
        let offset_str = offset.to_string();

        let types = match search_type {
            "songs" => "track",
            "artists" => "artist",
            "albums" => "album",
            "playlists" => "playlist",
            _ => "track,artist,album,playlist",
        };

        let json = self
            .request(
                EndpointFamily::Search,
                reqwest::Method::GET,
                "/search",
                &[
                    ("q", query),
                    ("type", types),
                    ("limit", &limit_str),
                    ("offset", &offset_str),
                ],
            )
            .await?;

        let parsed: SpotifyMultiSearchResponse = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse multi-search: {e}")))?;

        let total_tracks = parsed.tracks.as_ref().map(|p| p.total).unwrap_or(0);
        let total_artists = parsed.artists.as_ref().map(|p| p.total).unwrap_or(0);
        let total_albums = parsed.albums.as_ref().map(|p| p.total).unwrap_or(0);
        let total_playlists = parsed.playlists.as_ref().map(|p| p.total).unwrap_or(0);

        let tracks = parsed
            .tracks
            .map(|p| p.items.into_iter().map(convert_spotify_track).collect())
            .unwrap_or_default();
        let artists = parsed
            .artists
            .map(|p| p.items.into_iter().map(convert_spotify_artist).collect())
            .unwrap_or_default();
        let albums = parsed
            .albums
            .map(|p| p.items.into_iter().map(convert_spotify_album).collect())
            .unwrap_or_default();
        let playlists = parsed
            .playlists
            .map(|p| p.items.into_iter().map(convert_spotify_playlist).collect())
            .unwrap_or_default();

        Ok(DetailedSearchResults {
            query: query.to_string(),
            tracks,
            artists,
            albums,
            playlists,
            total_tracks,
            total_artists,
            total_albums,
            total_playlists,
        })
    }

    /// Rename a playlist.
    pub async fn rename_playlist(&self, playlist_id: &str, new_name: &str) -> Result<(), ApiError> {
        let endpoint = format!("/playlists/{playlist_id}");
        #[derive(serde::Serialize)]
        struct RenameBody<'a> {
            name: &'a str,
        }
        let body = RenameBody { name: new_name };
        let _ = self
            .request_json(EndpointFamily::Playlists, reqwest::Method::PUT, &endpoint, &body)
            .await?;
        Ok(())
    }

    /// Delete/Unfollow a playlist.
    pub async fn delete_playlist(&self, playlist_id: &str) -> Result<(), ApiError> {
        let endpoint = format!("/playlists/{playlist_id}/followers");
        let _ = self
            .request(EndpointFamily::Playlists, reqwest::Method::DELETE, &endpoint, &[])
            .await?;
        Ok(())
    }

    /// Remove a track from a playlist.
    pub async fn remove_track_from_playlist(&self, playlist_id: &str, track_uri: &str) -> Result<(), ApiError> {
        let endpoint = format!("/playlists/{playlist_id}/tracks");
        #[derive(serde::Serialize)]
        struct TrackUri<'a> {
            uri: &'a str,
        }
        #[derive(serde::Serialize)]
        struct RemoveBody<'a> {
            tracks: Vec<TrackUri<'a>>,
        }
        let body = RemoveBody {
            tracks: vec![TrackUri { uri: track_uri }],
        };
        let _ = self
            .request_json(EndpointFamily::Playlists, reqwest::Method::DELETE, &endpoint, &body)
            .await?;
        Ok(())
    }

    /// Get album detail and tracks.
    pub async fn get_album_detail(&self, album_id: &str) -> Result<(Album, Vec<Track>), ApiError> {
        let endpoint = format!("/albums/{album_id}");
        let json = self
            .request(EndpointFamily::Albums, reqwest::Method::GET, &endpoint, &[])
            .await?;

        let parsed: SpotifyAlbumDetailResponse = serde_json::from_str(&json)
            .map_err(|e| ApiError::Serialization(format!("parse album detail: {e}")))?;

        let album = convert_spotify_album(parsed.album);
        let mut tracks: Vec<Track> = parsed
            .tracks
            .items
            .into_iter()
            .map(convert_spotify_track)
            .collect();

        for t in &mut tracks {
            if t.album == "Unknown Album" {
                t.album = album.title.clone();
            }
            if t.album_id.is_none() {
                t.album_id = Some(album.id.clone());
            }
            if t.art_url.is_none() {
                t.art_url = album.art_url.clone();
            }
        }

        Ok((album, tracks))
    }

    /// Get artist detail, top tracks, and albums.
    pub async fn get_artist_detail(
        &self,
        artist_id: &str,
    ) -> Result<(Artist, Vec<Track>, Vec<Album>), ApiError> {
        let artist_endpoint = format!("/artists/{artist_id}");
        let json_artist = self
            .request(EndpointFamily::Artists, reqwest::Method::GET, &artist_endpoint, &[])
            .await?;
        let parsed_artist: SpotifyArtistItem = serde_json::from_str(&json_artist)
            .map_err(|e| ApiError::Serialization(format!("parse artist: {e}")))?;
        let artist = convert_spotify_artist(parsed_artist);

        let tracks_endpoint = format!("/artists/{artist_id}/top-tracks");
        let json_tracks = self
            .request(
                EndpointFamily::Artists,
                reqwest::Method::GET,
                &tracks_endpoint,
                &[("market", "from_token")],
            )
            .await?;
        let parsed_tracks: SpotifyRecommendationsResponse = serde_json::from_str(&json_tracks)
            .map_err(|e| ApiError::Serialization(format!("parse artist top tracks: {e}")))?;
        let top_tracks = parsed_tracks.tracks.into_iter().map(convert_spotify_track).collect();

        let albums = self.get_artist_albums(artist_id, 20).await.unwrap_or_default();

        Ok((artist, top_tracks, albums))
    }
}

fn calculate_jitter_backoff(attempt: u32) -> Duration {
    let base_ms = 250u64.saturating_mul(1 << attempt.saturating_sub(1));
    let jitter_ms = rand::thread_rng().gen_range(0..100);
    Duration::from_millis(base_ms.saturating_add(jitter_ms))
}

// --- Spotify JSON Models & Converters ---

#[derive(Debug, Deserialize)]
struct SpotifySearchResponse {
    tracks: SpotifyPaging<SpotifyTrack>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyMultiSearchResponse {
    pub tracks: Option<SpotifyPaging<SpotifyTrack>>,
    pub artists: Option<SpotifyPaging<SpotifyArtistItem>>,
    pub albums: Option<SpotifyPaging<SpotifyAlbumItem>>,
    pub playlists: Option<SpotifyPaging<SpotifyPlaylist>>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyAlbumDetailResponse {
    #[serde(flatten)]
    pub album: SpotifyAlbumItem,
    pub tracks: SpotifyPaging<SpotifyTrack>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyPaging<T> {
    pub items: Vec<T>,
    pub total: usize,
    pub limit: usize,
    pub offset: usize,
    pub next: Option<String>,
    pub previous: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyTrack {
    pub id: String,
    pub name: String,
    pub artists: Vec<SpotifyArtistRef>,
    pub album: Option<SpotifyAlbumRef>,
    pub duration_ms: u64,
    pub uri: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyArtistRef {
    pub id: Option<String>,
    pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyAlbumRef {
    pub id: Option<String>,
    pub name: String,
    pub images: Option<Vec<SpotifyImage>>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyImage {
    pub url: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyPlaylist {
    pub id: String,
    pub name: String,
    pub owner: SpotifyOwner,
    pub snapshot_id: Option<String>,
    pub images: Option<Vec<SpotifyImage>>,
    pub tracks: Option<SpotifyPlaylistTracksRef>,
    pub uri: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyOwner {
    pub display_name: Option<String>,
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyPlaylistTracksRef {
    pub total: u32,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyPlaylistTrackItem {
    pub track: Option<SpotifyTrack>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifySavedTrackItem {
    pub track: SpotifyTrack,
}

fn convert_spotify_track(t: SpotifyTrack) -> Track {
    let artist_names: Vec<String> = t.artists.iter().map(|a| a.name.clone()).collect();
    let primary_artist = artist_names
        .first()
        .cloned()
        .unwrap_or_else(|| "Unknown Artist".to_string());

    let (album_name, album_id, art_url) = if let Some(alb) = t.album {
        let art = alb
            .images
            .as_ref()
            .and_then(|imgs| imgs.first())
            .map(|i| i.url.clone());
        (alb.name, alb.id, art)
    } else {
        ("Unknown Album".to_string(), None, None)
    };

    let uri = t.uri.unwrap_or_else(|| format!("spotify:track:{}", t.id));

    Track {
        id: t.id,
        title: t.name,
        artist: primary_artist,
        artists: artist_names,
        album: album_name,
        album_id,
        duration_ms: t.duration_ms,
        art_url,
        uri,
    }
}

fn convert_spotify_playlist(p: SpotifyPlaylist) -> Playlist {
    let owner = p
        .owner
        .display_name
        .unwrap_or(p.owner.id);

    let art_url = p
        .images
        .as_ref()
        .and_then(|imgs| imgs.first())
        .map(|i| i.url.clone());

    let total_tracks = p.tracks.map(|t| t.total).unwrap_or(0);
    let uri = p.uri.unwrap_or_else(|| format!("spotify:playlist:{}", p.id));

    Playlist {
        id: p.id,
        name: p.name,
        owner,
        snapshot_id: p.snapshot_id,
        art_url,
        total_tracks,
        uri,
    }
}

#[derive(Debug, Deserialize)]
pub struct SpotifyRecentlyPlayedResponse {
    pub items: Vec<SpotifyRecentlyPlayedItem>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyRecentlyPlayedItem {
    pub track: SpotifyTrack,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyFollowedResponse {
    pub artists: SpotifyPaging<SpotifyArtistItem>,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyArtistItem {
    pub id: String,
    pub name: String,
    pub images: Option<Vec<SpotifyImage>>,
    pub genres: Option<Vec<String>>,
    pub uri: Option<String>,
}

fn convert_spotify_artist(a: SpotifyArtistItem) -> Artist {
    let image_url = a.images.as_ref().and_then(|imgs| imgs.first()).map(|i| i.url.clone());
    let uri = a.uri.unwrap_or_else(|| format!("spotify:artist:{}", a.id));
    Artist {
        id: a.id,
        name: a.name,
        image_url,
        genres: a.genres.unwrap_or_default(),
        uri,
    }
}

#[derive(Debug, Deserialize)]
pub struct SpotifyAlbumItem {
    pub id: String,
    pub name: String,
    pub artists: Vec<SpotifyArtistRef>,
    pub images: Option<Vec<SpotifyImage>>,
    pub release_date: Option<String>,
    pub total_tracks: Option<u32>,
    pub uri: Option<String>,
}

fn convert_spotify_album(a: SpotifyAlbumItem) -> Album {
    let primary_artist = a
        .artists
        .first()
        .map(|r| r.name.clone())
        .unwrap_or_else(|| "Unknown Artist".to_string());
    let art_url = a.images.as_ref().and_then(|imgs| imgs.first()).map(|i| i.url.clone());
    let uri = a.uri.unwrap_or_else(|| format!("spotify:album:{}", a.id));

    Album {
        id: a.id,
        title: a.name,
        artist: primary_artist,
        art_url,
        release_date: a.release_date,
        total_tracks: a.total_tracks.unwrap_or(0),
        uri,
    }
}

#[derive(Debug, Deserialize)]
pub struct SpotifySavedAlbumItem {
    pub album: SpotifyAlbumItem,
}

#[derive(Debug, Deserialize)]
pub struct SpotifyRecommendationsResponse {
    pub tracks: Vec<SpotifyTrack>,
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn convert_spotify_track_test() {
        let st = SpotifyTrack {
            id: "123".into(),
            name: "Song".into(),
            artists: vec![
                SpotifyArtistRef { id: Some("a1".into()), name: "Artist 1".into() },
                SpotifyArtistRef { id: Some("a2".into()), name: "Artist 2".into() },
            ],
            album: Some(SpotifyAlbumRef {
                id: Some("alb1".into()),
                name: "Cool Album".into(),
                images: Some(vec![SpotifyImage {
                    url: "http://art.com/1.jpg".into(),
                    width: Some(300),
                    height: Some(300),
                }]),
            }),
            duration_ms: 210_000,
            uri: None,
        };

        let t = convert_spotify_track(st);
        assert_eq!(t.id, "123");
        assert_eq!(t.title, "Song");
        assert_eq!(t.artist, "Artist 1");
        assert_eq!(t.artists.len(), 2);
        assert_eq!(t.album, "Cool Album");
        assert_eq!(t.album_id.as_deref(), Some("alb1"));
        assert_eq!(t.art_url.as_deref(), Some("http://art.com/1.jpg"));
        assert_eq!(t.uri, "spotify:track:123");
    }
}
