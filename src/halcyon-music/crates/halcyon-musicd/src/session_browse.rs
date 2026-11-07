//! Browsing through the librespot session (no Client ID, no Web API quota).
//!
//! The default sign-in is librespot's own OAuth login. Its token streams audio, but the Web API
//! treats it as one shared app, so browsing with it ends in 429s. This module reads the same
//! data over the session itself: the user's playlist list ("rootlist"), playlist and track
//! metadata, liked songs and search, all through `spclient`.
//!
//! These are Spotify's internal endpoints. They are not a public API and can change; every
//! function here returns an `ApiError` instead of panicking, and the parts that only convert
//! data are plain functions with unit tests.

// `SpotifyUri::to_base62` is deprecated in favour of `to_name`, which the pinned 0.8.0 lacks.
#![allow(deprecated)]

use crate::api::ApiError;
use crate::stream_auth::fresh_streaming_token;
use halcyon_music_core::models::{Album, DetailedSearchResults, Page, Playlist, Track};
use librespot_core::authentication::Credentials;
use librespot_core::config::SessionConfig;
use librespot_core::session::Session;
use librespot_core::spotify_uri::SpotifyUri;
use librespot_metadata::image::Images;
use librespot_metadata::{Album as LsAlbum, Metadata, Playlist as LsPlaylist, Track as LsTrack};
use librespot_protocol::context::Context;
use protobuf::Message;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{Mutex, Semaphore};
use tracing::{debug, info, warn};

/// How many metadata lookups run at once. A playlist page needs one lookup per row.
const LOOKUP_CONCURRENCY: usize = 8;
/// Rootlist entries fetched per request.
const ROOTLIST_CHUNK: usize = 200;
/// Hard stop for the rootlist (a runaway answer must not loop forever).
const ROOTLIST_MAX: usize = 5000;
/// Search results per request (same cap the Web API path used).
const SEARCH_MAX: usize = 10;

fn api_err(context: &str, e: impl std::fmt::Display) -> ApiError {
    ApiError::Network(format!("{context}: {e}"))
}

// ---------------------------------------------------------------------------------------------
// Pure conversions (unit-tested)
// ---------------------------------------------------------------------------------------------

/// Image URL for a cover: the smallest image that is at least 300 px wide, else the largest.
pub fn art_url_from(images: &Images) -> Option<String> {
    let best = images
        .0
        .iter()
        .filter(|i| i.width >= 300)
        .min_by_key(|i| i.width)
        .or_else(|| images.0.iter().max_by_key(|i| i.width))?;
    let hex = best.id.to_base16().ok()?;
    Some(format!("https://i.scdn.co/image/{hex}"))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn track_from_librespot(t: &LsTrack) -> Track {
    let id = t.id.to_base62().unwrap_or_default();
    let artists: Vec<String> = t.artists.0.iter().map(|a| a.name.clone()).collect();
    let artist = artists
        .first()
        .cloned()
        .unwrap_or_else(|| "Unknown Artist".to_string());
    Track {
        uri: format!("spotify:track:{id}"),
        id,
        title: t.name.clone(),
        artist,
        artists,
        album: if t.album.name.is_empty() {
            "Unknown Album".to_string()
        } else {
            t.album.name.clone()
        },
        album_id: t.album.id.to_base62().ok(),
        duration_ms: t.duration.max(0) as u64,
        art_url: art_url_from(&t.album.covers),
    }
}

pub fn album_from_librespot(a: &LsAlbum) -> Album {
    let id = a.id.to_base62().unwrap_or_default();
    Album {
        uri: format!("spotify:album:{id}"),
        id,
        title: a.name.clone(),
        artist: a
            .artists
            .0
            .first()
            .map(|x| x.name.clone())
            .unwrap_or_else(|| "Unknown Artist".to_string()),
        art_url: art_url_from(&a.covers),
        release_date: Some(a.date.date().to_string()),
        total_tracks: a.tracks().count() as u32,
    }
}

pub fn playlist_from_librespot(p: &LsPlaylist) -> Playlist {
    let id = p.id.to_base62().unwrap_or_default();
    let owner = match &p.id {
        SpotifyUri::Playlist { user: Some(u), .. } => u.clone(),
        _ => String::new(),
    };
    let art_url = if p.attributes.picture.is_empty() {
        None
    } else {
        Some(format!("https://i.scdn.co/image/{}", hex(&p.attributes.picture)))
    };
    Playlist {
        uri: format!("spotify:playlist:{id}"),
        id,
        name: p.attributes.name.clone(),
        owner,
        snapshot_id: if p.revision.is_empty() { None } else { Some(hex(&p.revision)) },
        art_url,
        total_tracks: p.length.max(0) as u32,
    }
}

/// `(start, end)` of the requested page inside a list of `total` items.
pub fn page_bounds(total: usize, limit: usize, offset: usize) -> (usize, usize) {
    let start = offset.min(total);
    let end = start.saturating_add(limit).min(total);
    (start, end)
}

pub fn make_page<T>(items: Vec<T>, total: usize, limit: usize, offset: usize) -> Page<T> {
    let next = (offset + items.len() < total).then(|| format!("offset={}", offset + items.len()));
    let previous = (offset > 0).then(|| format!("offset={}", offset.saturating_sub(limit)));
    Page { items, total, limit, offset, next, previous }
}

/// Track URIs listed by a context (liked songs, search results), in order, without repeats.
pub fn track_uris_from_context(ctx: &Context) -> Vec<String> {
    let mut seen = std::collections::HashSet::new();
    ctx.pages
        .iter()
        .flat_map(|p| p.tracks.iter())
        .map(|t| t.uri().to_string())
        .filter(|u| u.starts_with("spotify:track:"))
        .filter(|u| seen.insert(u.clone()))
        .collect()
}

/// Search context URI: `spotify:search:never+gonna` (whitespace becomes `+`).
pub fn search_context_uri(query: &str) -> String {
    let q = query.split_whitespace().collect::<Vec<_>>().join("+");
    format!("spotify:search:{q}")
}

// ---------------------------------------------------------------------------------------------
// Session handling
// ---------------------------------------------------------------------------------------------

/// Browsing handle. Cheap to clone; all clones share one session and one track cache.
#[derive(Clone)]
pub struct SessionBrowse {
    session: Arc<Mutex<Option<Session>>>,
    tracks: Arc<Mutex<HashMap<String, Track>>>,
}

impl Default for SessionBrowse {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionBrowse {
    pub fn new() -> Self {
        Self {
            session: Arc::new(Mutex::new(None)),
            tracks: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// A connected session, reconnecting if the old one died. Uses the streaming token, which
    /// the browser sign-in already produced, so there is nothing more for the user to do.
    pub async fn session(&self) -> Result<Session, ApiError> {
        let mut guard = self.session.lock().await;
        if let Some(s) = guard.as_ref() {
            if !s.is_invalid() {
                return Ok(s.clone());
            }
            debug!("browse session is no longer valid; reconnecting");
        }
        let token = fresh_streaming_token()
            .await
            .map_err(|e| ApiError::AuthRequired(e.to_string()))?;
        let session = Session::new(SessionConfig::default(), None);
        let creds = Credentials::with_access_token(&token.access_token);
        info!("connecting browse session...");
        session
            .connect(creds, false)
            .await
            .map_err(|e| api_err("browse session connect failed", e))?;
        info!("browse session connected");
        *guard = Some(session.clone());
        Ok(session)
    }

    /// Drop the session (sign-out, or the account changed).
    pub async fn reset(&self) {
        *self.session.lock().await = None;
        self.tracks.lock().await.clear();
    }

    // -----------------------------------------------------------------------------------------
    // Lookups
    // -----------------------------------------------------------------------------------------

    /// Metadata for each track URI, in the same order. Rows that fail to load are skipped
    /// (a removed or unavailable track must not break the whole page).
    async fn tracks_for(&self, session: &Session, uris: &[String]) -> Vec<Track> {
        let sem = Arc::new(Semaphore::new(LOOKUP_CONCURRENCY));
        let mut set = tokio::task::JoinSet::new();
        for (idx, uri) in uris.iter().enumerate() {
            if let Some(hit) = self.tracks.lock().await.get(uri).cloned() {
                set.spawn(async move { (idx, Some(hit)) });
                continue;
            }
            let (session, sem, cache, uri) = (
                session.clone(),
                sem.clone(),
                self.tracks.clone(),
                uri.clone(),
            );
            set.spawn(async move {
                let _permit = sem.acquire().await.ok();
                let parsed = match SpotifyUri::from_uri(&uri) {
                    Ok(p) => p,
                    Err(_) => return (idx, None),
                };
                match LsTrack::get(&session, &parsed).await {
                    Ok(t) => {
                        let track = track_from_librespot(&t);
                        cache.lock().await.insert(uri, track.clone());
                        (idx, Some(track))
                    }
                    Err(e) => {
                        debug!(uri = %uri, error = %e, "track metadata lookup failed");
                        (idx, None)
                    }
                }
            });
        }
        let mut rows: Vec<(usize, Track)> = Vec::new();
        while let Some(done) = set.join_next().await {
            if let Ok((idx, Some(track))) = done {
                rows.push((idx, track));
            }
        }
        rows.sort_by_key(|(idx, _)| *idx);
        rows.into_iter().map(|(_, t)| t).collect()
    }

    async fn playlist_meta(&self, session: &Session, uri: &str) -> Result<LsPlaylist, ApiError> {
        let parsed = SpotifyUri::from_uri(uri).map_err(|e| api_err("bad playlist uri", e))?;
        LsPlaylist::get(session, &parsed)
            .await
            .map_err(|e| api_err("playlist lookup failed", e))
    }

    /// The user's playlists, in the order Spotify shows them (folders are skipped).
    async fn playlist_uris(&self, session: &Session) -> Result<Vec<String>, ApiError> {
        let mut uris: Vec<String> = Vec::new();
        let mut from = 0usize;
        loop {
            let bytes = session
                .spclient()
                .get_rootlist(from, Some(ROOTLIST_CHUNK))
                .await
                .map_err(|e| api_err("rootlist request failed", e))?;
            let msg = librespot_protocol::playlist4_external::SelectedListContent::parse_from_bytes(&bytes)
                .map_err(|e| api_err("rootlist parse failed", e))?;
            let list = librespot_metadata::playlist::list::SelectedListContent::try_from(&msg)
                .map_err(|e| api_err("rootlist decode failed", e))?;
            let got = list.contents.items.len();
            uris.extend(
                list.contents
                    .items
                    .iter()
                    .filter(|i| matches!(i.id, SpotifyUri::Playlist { .. }))
                    .filter_map(|i| i.id.to_uri().ok()),
            );
            from += got;
            if got == 0 || from >= list.length.max(0) as usize || from >= ROOTLIST_MAX {
                break;
            }
        }
        Ok(uris)
    }

    // -----------------------------------------------------------------------------------------
    // The calls the daemon makes
    // -----------------------------------------------------------------------------------------

    pub async fn get_playlists(&self, limit: u32, offset: u32) -> Result<Page<Playlist>, ApiError> {
        let session = self.session().await?;
        let all = self.playlist_uris(&session).await?;
        let (start, end) = page_bounds(all.len(), limit as usize, offset as usize);

        let sem = Arc::new(Semaphore::new(LOOKUP_CONCURRENCY));
        let mut set = tokio::task::JoinSet::new();
        for (idx, uri) in all[start..end].iter().enumerate() {
            let (this, session, sem, uri) = (self.clone(), session.clone(), sem.clone(), uri.clone());
            set.spawn(async move {
                let _permit = sem.acquire().await.ok();
                (idx, this.playlist_meta(&session, &uri).await)
            });
        }
        let mut rows: Vec<(usize, Playlist)> = Vec::new();
        while let Some(done) = set.join_next().await {
            match done {
                Ok((idx, Ok(p))) => rows.push((idx, playlist_from_librespot(&p))),
                Ok((_, Err(e))) => warn!(error = %e, "skipping a playlist that failed to load"),
                Err(_) => {}
            }
        }
        rows.sort_by_key(|(i, _)| *i);
        let items: Vec<Playlist> = rows.into_iter().map(|(_, p)| p).collect();
        Ok(make_page(items, all.len(), limit as usize, offset as usize))
    }

    pub async fn get_playlist_tracks(
        &self,
        playlist_id: &str,
        limit: u32,
        offset: u32,
    ) -> Result<Page<Track>, ApiError> {
        let session = self.session().await?;
        let playlist = self
            .playlist_meta(&session, &format!("spotify:playlist:{playlist_id}"))
            .await?;
        let all: Vec<String> = playlist
            .contents
            .items
            .iter()
            .filter(|i| matches!(i.id, SpotifyUri::Track { .. }))
            .filter_map(|i| i.id.to_uri().ok())
            .collect();
        let (start, end) = page_bounds(all.len(), limit as usize, offset as usize);
        let items = self.tracks_for(&session, &all[start..end]).await;
        Ok(make_page(items, all.len(), limit as usize, offset as usize))
    }

    pub async fn get_saved_tracks(&self, limit: u32, offset: u32) -> Result<Page<Track>, ApiError> {
        let session = self.session().await?;
        let uri = format!("spotify:user:{}:collection", session.username());
        let ctx = session
            .spclient()
            .get_context(&uri)
            .await
            .map_err(|e| api_err("liked songs request failed", e))?;
        let all = track_uris_from_context(&ctx);
        debug!(pages = ctx.pages.len(), tracks = all.len(), "liked songs context");
        let (start, end) = page_bounds(all.len(), limit as usize, offset as usize);
        let items = self.tracks_for(&session, &all[start..end]).await;
        Ok(make_page(items, all.len(), limit as usize, offset as usize))
    }

    /// An album and its tracks, in disc order.
    pub async fn get_album_detail(&self, album_id: &str) -> Result<(Album, Vec<Track>), ApiError> {
        let session = self.session().await?;
        let uri = SpotifyUri::from_uri(&format!("spotify:album:{album_id}"))
            .map_err(|e| api_err("bad album uri", e))?;
        let album = LsAlbum::get(&session, &uri)
            .await
            .map_err(|e| api_err("album lookup failed", e))?;
        let uris: Vec<String> = album.tracks().filter_map(|u| u.to_uri().ok()).collect();
        let mut tracks = self.tracks_for(&session, &uris).await;
        let model = album_from_librespot(&album);
        for t in &mut tracks {
            if t.album_id.is_none() {
                t.album_id = Some(model.id.clone());
            }
            if t.art_url.is_none() {
                t.art_url = model.art_url.clone();
            }
        }
        Ok((model, tracks))
    }

    /// Track search. Artists, albums and playlists are not searched through the session yet,
    /// so those lists come back empty.
    pub async fn search_detailed(
        &self,
        query: &str,
        search_type: &str,
        limit: u32,
        offset: u32,
    ) -> Result<DetailedSearchResults, ApiError> {
        let session = self.session().await?;
        let ctx = session
            .spclient()
            .get_context(&search_context_uri(query))
            .await
            .map_err(|e| api_err("search request failed", e))?;
        let all = track_uris_from_context(&ctx);
        let (start, end) = page_bounds(all.len(), limit.min(SEARCH_MAX as u32) as usize, offset as usize);
        let tracks = self.tracks_for(&session, &all[start..end]).await;
        Ok(DetailedSearchResults {
            query: query.to_string(),
            search_type: search_type.to_string(),
            offset,
            total_tracks: all.len(),
            tracks,
            artists: Vec::new(),
            albums: Vec::new(),
            playlists: Vec::new(),
            total_artists: 0,
            total_albums: 0,
            total_playlists: 0,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use librespot_protocol::context_page::ContextPage;
    use librespot_protocol::context_track::ContextTrack;

    fn ctx_with(uris: &[&str]) -> Context {
        let mut page = ContextPage::new();
        for u in uris {
            let mut t = ContextTrack::new();
            t.uri = Some((*u).to_string());
            page.tracks.push(t);
        }
        let mut ctx = Context::new();
        ctx.pages.push(page);
        ctx
    }

    #[test]
    fn page_bounds_clamps_to_the_list() {
        assert_eq!(page_bounds(10, 4, 0), (0, 4));
        assert_eq!(page_bounds(10, 4, 8), (8, 10));
        assert_eq!(page_bounds(10, 4, 50), (10, 10));
        assert_eq!(page_bounds(0, 4, 0), (0, 0));
        assert_eq!(page_bounds(10, usize::MAX, 3), (3, 10));
    }

    #[test]
    fn make_page_sets_next_and_previous() {
        let p = make_page(vec![1, 2], 5, 2, 2);
        assert_eq!(p.total, 5);
        assert!(p.next.is_some());
        assert!(p.previous.is_some());
        let last = make_page(vec![5], 5, 2, 4);
        assert!(last.next.is_none());
        let first = make_page(vec![1, 2], 5, 2, 0);
        assert!(first.previous.is_none());
    }

    #[test]
    fn context_tracks_are_filtered_and_deduplicated() {
        let ctx = ctx_with(&[
            "spotify:track:aaa",
            "spotify:episode:bbb",
            "spotify:track:aaa",
            "spotify:track:ccc",
        ]);
        assert_eq!(
            track_uris_from_context(&ctx),
            vec!["spotify:track:aaa".to_string(), "spotify:track:ccc".to_string()]
        );
        assert!(track_uris_from_context(&Context::new()).is_empty());
    }

    #[test]
    fn search_uri_joins_words_with_plus() {
        assert_eq!(search_context_uri("never  gonna give"), "spotify:search:never+gonna+give");
        assert_eq!(search_context_uri("  x "), "spotify:search:x");
    }

    #[test]
    fn hex_encodes_bytes() {
        assert_eq!(hex(&[0x00, 0xab, 0xff]), "00abff");
        assert_eq!(hex(&[]), "");
    }
}
