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
use crate::token_store::{load_token, TokenData};
use halcyon_music_core::models::{Page, Playlist, Track};
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
            circuits: Arc::new(Mutex::new(HashMap::new())),
            rate_limiter: Arc::new(Mutex::new(RateLimiter {
                retry_after_until: None,
                last_request_time: Instant::now() - Duration::from_secs(1),
                min_spacing: Duration::from_millis(30),
            })),
            timeout,
        }
    }

    pub async fn set_token(&self, token: TokenData) {
        let mut guard = self.token.lock().await;
        *guard = Some(token);
    }

    pub async fn clear_token(&self) {
        let mut guard = self.token.lock().await;
        *guard = None;
    }

    pub async fn is_authenticated(&self) -> bool {
        let guard = self.token.lock().await;
        guard.is_some()
    }

    pub async fn current_user_id(&self) -> Option<String> {
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
