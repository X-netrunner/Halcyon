//! Cover-art pipeline (daemon side).
//!
//! The GUI asks for a cover with `GetArt { url, size }`; this module finds it
//! in the on-disk cache or downloads it, and the answer goes back as
//! `ArtReady { url, size, path }` / `ArtFailed { .. }` on the event stream.
//!
//! Guarantees:
//! - every download has a connect and a total timeout (no `await` without one);
//! - the body is capped at [`MAX_ART_BYTES`] and must start with a JPEG, PNG or
//!   WebP signature, so a captive portal's HTML page never lands in the cache;
//! - N concurrent requests for one cover cause exactly one download;
//! - at most [`MAX_CONCURRENT_DOWNLOADS`] downloads run at once, so opening a
//!   300-track playlist cannot saturate the link or the Spotify CDN;
//! - failures are remembered for a short time, so a missing cover is not
//!   re-requested on every redraw;
//! - files are written atomically by [`Cache::put_image`] and pruned by its
//!   500 MB LRU.

use crate::cache::Cache;
use crate::daemon::Player;
use halcyon_music_core::art::{cache_key, ArtSize};
use halcyon_music_core::protocol::{self, EventBody};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};
use thiserror::Error;
use tokio::sync::{broadcast, Mutex, Semaphore};
use tracing::{debug, warn};

/// Largest cover we accept. Spotify's 640 px JPEGs are ~60-120 KB.
pub const MAX_ART_BYTES: usize = 4 * 1024 * 1024;
pub const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
pub const TOTAL_TIMEOUT: Duration = Duration::from_secs(12);
pub const MAX_CONCURRENT_DOWNLOADS: usize = 6;
/// How long a transient failure (offline, 5xx, timeout) is remembered.
const TRANSIENT_FAILURE_TTL: Duration = Duration::from_secs(30);
/// How long a permanent failure (404, not an image, too big) is remembered.
const PERMANENT_FAILURE_TTL: Duration = Duration::from_secs(10 * 60);
const MAX_REMEMBERED_FAILURES: usize = 1024;

#[derive(Debug, Clone, Error, PartialEq, Eq)]
pub enum ArtError {
    #[error("not a usable cover URL")]
    BadUrl,
    #[error("network error: {0}")]
    Network(String),
    #[error("server answered HTTP {0}")]
    Status(u16),
    #[error("cover is larger than {0} bytes")]
    TooLarge(usize),
    #[error("the server did not send an image")]
    NotAnImage,
    #[error("could not use the image cache: {0}")]
    Cache(String),
    #[error("failed recently: {0}")]
    RecentlyFailed(String),
}

impl ArtError {
    fn is_permanent(&self) -> bool {
        match self {
            ArtError::BadUrl | ArtError::TooLarge(_) | ArtError::NotAnImage => true,
            ArtError::Status(code) => (400..500).contains(code) && *code != 408 && *code != 429,
            _ => false,
        }
    }
}

struct Failure {
    at: Instant,
    ttl: Duration,
    reason: String,
}

/// Cheap to clone; all clones share the same state.
#[derive(Clone)]
pub struct ArtFetcher {
    cache: Cache,
    http: reqwest::Client,
    permits: Arc<Semaphore>,
    inflight: Arc<StdMutex<HashMap<String, Arc<Mutex<()>>>>>,
    failures: Arc<StdMutex<HashMap<String, Failure>>>,
}

impl ArtFetcher {
    pub fn new(cache: Cache) -> Self {
        let http = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(TOTAL_TIMEOUT)
            .user_agent(concat!("halcyon-music/", env!("CARGO_PKG_VERSION")))
            .build()
            .unwrap_or_default();
        Self {
            cache,
            http,
            permits: Arc::new(Semaphore::new(MAX_CONCURRENT_DOWNLOADS)),
            inflight: Arc::new(StdMutex::new(HashMap::new())),
            failures: Arc::new(StdMutex::new(HashMap::new())),
        }
    }

    /// Path of an already cached cover, without touching the network.
    pub fn cached(&self, url: &str, size: ArtSize) -> Option<PathBuf> {
        self.cache.get_image(&cache_key(url, size)).ok().flatten()
    }

    /// Find the cover in the cache or download it. Safe to call concurrently.
    pub async fn fetch(&self, url: &str, size: ArtSize) -> Result<PathBuf, ArtError> {
        if !is_acceptable_url(url) {
            return Err(ArtError::BadUrl);
        }
        let key = cache_key(url, size);

        if let Some(path) = self.cache_lookup(&key).await {
            return Ok(path);
        }
        if let Some(err) = self.recent_failure(&key) {
            return Err(err);
        }

        // One download per cover: later callers wait on this lock, then find
        // the file in the cache.
        let slot = self.slot_for(&key);
        let _held = slot.lock().await;

        if let Some(path) = self.cache_lookup(&key).await {
            self.release_slot(&key);
            return Ok(path);
        }
        if let Some(err) = self.recent_failure(&key) {
            self.release_slot(&key);
            return Err(err);
        }

        let result = self.download_and_store(url, size, &key).await;
        match &result {
            Ok(_) => self.forget_failure(&key),
            Err(e) => self.remember_failure(&key, e),
        }
        self.release_slot(&key);
        result
    }

    async fn download_and_store(
        &self,
        url: &str,
        size: ArtSize,
        key: &str,
    ) -> Result<PathBuf, ArtError> {
        let _permit = self
            .permits
            .acquire()
            .await
            .map_err(|e| ArtError::Network(e.to_string()))?;

        let mut last_err = ArtError::BadUrl;
        for candidate in size.candidates(url) {
            if !is_acceptable_url(&candidate) {
                continue;
            }
            match self.download(&candidate).await {
                Ok(bytes) => {
                    let cache = self.cache.clone();
                    let key = key.to_string();
                    let stored = tokio::task::spawn_blocking(move || cache.put_image(&key, &bytes))
                        .await
                        .map_err(|e| ArtError::Cache(e.to_string()))?;
                    return stored.map_err(ArtError::Cache);
                }
                Err(e) => {
                    debug!(url = %candidate, error = %e, "cover download failed");
                    last_err = e;
                }
            }
        }
        Err(last_err)
    }

    async fn download(&self, url: &str) -> Result<Vec<u8>, ArtError> {
        // The client has connect + total timeouts; the outer timeout is a
        // second line of defence so a stalled body can never hold a permit.
        match tokio::time::timeout(
            TOTAL_TIMEOUT + Duration::from_secs(2),
            self.download_inner(url),
        )
        .await
        {
            Ok(r) => r,
            Err(_) => Err(ArtError::Network("timed out".into())),
        }
    }

    async fn download_inner(&self, url: &str) -> Result<Vec<u8>, ArtError> {
        let mut resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(|e| ArtError::Network(e.to_string()))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(ArtError::Status(status.as_u16()));
        }
        if let Some(len) = resp.content_length() {
            if len > MAX_ART_BYTES as u64 {
                return Err(ArtError::TooLarge(MAX_ART_BYTES));
            }
        }
        let mut body: Vec<u8> = Vec::with_capacity(
            resp.content_length()
                .unwrap_or(64 * 1024)
                .min(MAX_ART_BYTES as u64) as usize,
        );
        while let Some(chunk) = resp
            .chunk()
            .await
            .map_err(|e| ArtError::Network(e.to_string()))?
        {
            if body.len() + chunk.len() > MAX_ART_BYTES {
                return Err(ArtError::TooLarge(MAX_ART_BYTES));
            }
            body.extend_from_slice(&chunk);
        }
        if !looks_like_image(&body) {
            return Err(ArtError::NotAnImage);
        }
        Ok(body)
    }

    async fn cache_lookup(&self, key: &str) -> Option<PathBuf> {
        let cache = self.cache.clone();
        let key = key.to_string();
        tokio::task::spawn_blocking(move || cache.get_image(&key).ok().flatten())
            .await
            .ok()
            .flatten()
    }

    fn slot_for(&self, key: &str) -> Arc<Mutex<()>> {
        let mut map = self.inflight.lock().unwrap_or_else(|p| p.into_inner());
        map.entry(key.to_string())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    fn release_slot(&self, key: &str) {
        let mut map = self.inflight.lock().unwrap_or_else(|p| p.into_inner());
        map.remove(key);
    }

    fn recent_failure(&self, key: &str) -> Option<ArtError> {
        let map = self.failures.lock().unwrap_or_else(|p| p.into_inner());
        map.get(key)
            .filter(|f| f.at.elapsed() < f.ttl)
            .map(|f| ArtError::RecentlyFailed(f.reason.clone()))
    }

    fn remember_failure(&self, key: &str, err: &ArtError) {
        let mut map = self.failures.lock().unwrap_or_else(|p| p.into_inner());
        if map.len() >= MAX_REMEMBERED_FAILURES {
            map.retain(|_, f| f.at.elapsed() < f.ttl);
            if map.len() >= MAX_REMEMBERED_FAILURES {
                map.clear();
            }
        }
        let ttl = if err.is_permanent() {
            PERMANENT_FAILURE_TTL
        } else {
            TRANSIENT_FAILURE_TTL
        };
        map.insert(
            key.to_string(),
            Failure {
                at: Instant::now(),
                ttl,
                reason: err.to_string(),
            },
        );
    }

    fn forget_failure(&self, key: &str) {
        let mut map = self.failures.lock().unwrap_or_else(|p| p.into_inner());
        map.remove(key);
    }
}

/// Only https is fetched (plus plain http to loopback, used by the tests).
pub fn is_acceptable_url(raw: &str) -> bool {
    let Ok(parsed) = url::Url::parse(raw) else {
        return false;
    };
    match parsed.scheme() {
        "https" => parsed.host_str().is_some(),
        "http" => matches!(
            parsed.host_str(),
            Some("127.0.0.1") | Some("localhost") | Some("[::1]")
        ),
        _ => false,
    }
}

/// JPEG, PNG or WebP signature.
pub fn looks_like_image(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xFF, 0xD8, 0xFF])
        || bytes.starts_with(&[0x89, b'P', b'N', b'G'])
        || (bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP".as_slice()))
}

/// Answer one `GetArt` request in the background and publish the result.
pub fn spawn_request(
    fetcher: ArtFetcher,
    events_tx: broadcast::Sender<protocol::Event>,
    url: String,
    size: ArtSize,
) {
    tokio::spawn(async move {
        let result = fetcher.fetch(&url, size).await;
        let body = match result {
            Ok(path) => EventBody::ArtReady {
                url,
                size,
                path: path.to_string_lossy().into_owned(),
            },
            Err(e) => EventBody::ArtFailed {
                url,
                size,
                reason: e.to_string(),
            },
        };
        let _ = events_tx.send(protocol::event(body));
    });
}

/// Keep the cover of the current track warm in the cache at every size, so the
/// full-screen view, the now-playing bar, MPRIS clients and notifications have
/// it before anyone asks. Runs forever (call under the supervisor).
pub async fn prefetch_current_track(
    player: Arc<Player>,
    fetcher: ArtFetcher,
    events_tx: broadcast::Sender<protocol::Event>,
) -> anyhow::Result<()> {
    let mut last: Option<String> = None;
    let mut tick = tokio::time::interval(Duration::from_secs(2));
    loop {
        tick.tick().await;
        let current = player.current_art_url().await;
        if current == last {
            continue;
        }
        last = current.clone();
        let Some(url) = current else { continue };
        for size in [ArtSize::Medium, ArtSize::Large, ArtSize::Small] {
            match fetcher.fetch(&url, size).await {
                Ok(path) => {
                    let _ = events_tx.send(protocol::event(EventBody::ArtReady {
                        url: url.clone(),
                        size,
                        path: path.to_string_lossy().into_owned(),
                    }));
                }
                Err(e) => warn!(error = %e, ?size, "could not prefetch current cover"),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_policy() {
        assert!(is_acceptable_url("https://i.scdn.co/image/abc"));
        assert!(is_acceptable_url("http://127.0.0.1:8080/a.jpg"));
        assert!(!is_acceptable_url("http://example.com/a.jpg"));
        assert!(!is_acceptable_url("file:///etc/passwd"));
        assert!(!is_acceptable_url("not a url"));
    }

    #[test]
    fn image_signatures() {
        assert!(looks_like_image(&[0xFF, 0xD8, 0xFF, 0xE0, 0, 0]));
        assert!(looks_like_image(&[0x89, b'P', b'N', b'G', 13, 10]));
        assert!(looks_like_image(b"RIFF\x00\x00\x00\x00WEBPVP8 "));
        assert!(!looks_like_image(b"<html>"));
        assert!(!looks_like_image(b""));
    }

    #[test]
    fn permanent_vs_transient() {
        assert!(ArtError::Status(404).is_permanent());
        assert!(!ArtError::Status(429).is_permanent());
        assert!(!ArtError::Status(503).is_permanent());
        assert!(ArtError::NotAnImage.is_permanent());
        assert!(!ArtError::Network("x".into()).is_permanent());
    }
}
