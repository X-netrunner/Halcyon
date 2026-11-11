//! Multi-tier Suggestion Engine and Home feed generator.
//!
//! Tiers:
//! - Tier 1: Spotify API (`recommendations`, `top-tracks`, `recently-played`, `followed-artists`)
//! - Tier 2: Outside data resolved to Spotify:
//!   - ListenBrainz (open public API, no key)
//!   - Deezer public charts (no key)
//!   - Last.fm (optional key)
//! - Tier 3: Local SQLite mixes (offline-capable):
//!   - "On Repeat" (30-day top played)
//!   - "Rediscover" (liked tracks not played in 90+ days)
//!   - "Time-of-day mix" (tracks played around this hour)
//!   - "Because you played <Artist>"
//!
//! Diversity rules:
//! - Max 2 tracks per artist per mix
//! - No duplicate tracks across mixes on the same page
//! - Skip tracks played in the last 24h (except for On Repeat)

use crate::api::SpotifyClient;
use crate::cache::{Cache, PlayLogEntry};
use crate::token_store::now_secs;
use halcyon_music_core::models::{
    Album, DiscoverFeed, HomeFeed, MusicMix, QuickPick, ShelfItem, Track,
};
use serde::Deserialize;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::Duration;
use tracing::{debug, warn};

// --- Fuzzy String Matching & Spotify Resolution ---

/// Normalize title/artist for fuzzy matching: lowercase, strip punctuation and bracketed noise.
pub fn normalize_string(input: &str) -> String {
    let base = if let Some((prefix, suffix)) = input.split_once(" - ") {
        let s_lower = suffix.to_lowercase();
        if s_lower.contains("remaster")
            || s_lower.contains("live")
            || s_lower.contains("edit")
            || s_lower.contains("single")
            || s_lower.contains("version")
        {
            prefix
        } else {
            input
        }
    } else {
        input
    };

    let mut clean = String::with_capacity(base.len());
    let mut in_bracket = 0;

    for c in base.chars() {
        match c {
            '(' | '[' => in_bracket += 1,
            ')' | ']' => {
                if in_bracket > 0 {
                    in_bracket -= 1;
                }
            }
            _ => {
                if in_bracket == 0 && (c.is_alphanumeric() || c.is_whitespace()) {
                    clean.push(c.to_ascii_lowercase());
                }
            }
        }
    }

    clean.split_whitespace().collect::<Vec<&str>>().join(" ")
}

/// Token-based overlap similarity between two normalized strings (0.0 ..= 1.0).
pub fn token_similarity(a: &str, b: &str) -> f32 {
    let a_tokens: HashSet<&str> = a.split_whitespace().collect();
    let b_tokens: HashSet<&str> = b.split_whitespace().collect();

    if a_tokens.is_empty() || b_tokens.is_empty() {
        return 0.0;
    }

    let intersection = a_tokens.intersection(&b_tokens).count();
    let union = a_tokens.union(&b_tokens).count();

    if union == 0 {
        0.0
    } else {
        (intersection as f32) / (union as f32)
    }
}

/// Score a candidate track against target artist, title and optional duration.
pub fn score_track_match(
    candidate: &Track,
    target_artist: &str,
    target_title: &str,
    target_duration_ms: Option<u64>,
) -> f32 {
    let norm_target_title = normalize_string(target_title);
    let norm_target_artist = normalize_string(target_artist);

    let norm_cand_title = normalize_string(&candidate.title);
    let norm_cand_artist = normalize_string(&candidate.artist);

    let title_score = token_similarity(&norm_cand_title, &norm_target_title);
    let artist_score = token_similarity(&norm_cand_artist, &norm_target_artist);

    let duration_score = if let Some(target_dur) = target_duration_ms {
        let diff = (candidate.duration_ms as i64 - target_dur as i64).unsigned_abs();
        if diff <= 3_000 {
            1.0
        } else if diff <= 10_000 {
            0.7
        } else {
            0.3
        }
    } else {
        1.0
    };

    0.5 * title_score + 0.35 * artist_score + 0.15 * duration_score
}

/// Uncached Spotify searches still allowed during this Home build. Matches are cached, so
/// the mixes fill in over a few loads instead of one burst that gets us rate limited.
static SEARCH_BUDGET: AtomicU32 = AtomicU32::new(0);
/// After a failed search (usually HTTP 429) no more searches are sent until this time (unix secs).
static SEARCH_PAUSED_UNTIL: AtomicU64 = AtomicU64::new(0);
const SEARCHES_PER_BUILD: u32 = 36;

/// Part 5: allow up to `n` more uncached Spotify searches (never lowers a budget already granted).
pub(crate) fn grant_search_budget(n: u32) {
    SEARCH_BUDGET.fetch_max(n, Ordering::Relaxed);
}

/// One uncached Spotify song search, within the budget and not while paused. It goes through
/// `search_detailed`, which in the default sign-in reads the librespot session (no Web API
/// quota, so no 429s) and in Client ID mode uses the Web API.
///
/// `None`: no search was made (paused or out of budget) or it failed. `Some(vec![])`: it ran
/// and found nothing.
async fn search_songs_budgeted(spotify: &SpotifyClient, query: &str) -> Option<Vec<Track>> {
    if now_secs() < SEARCH_PAUSED_UNTIL.load(Ordering::Relaxed) {
        return None;
    }
    // `fetch_update` was renamed `try_update` in newer Rust; keep the old name so older toolchains build.
    #[allow(deprecated)]
    let had_budget = SEARCH_BUDGET
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_sub(1))
        .is_ok();
    if !had_budget {
        return None;
    }
    // Space uncached searches out: a burst of lookups on top of the start-up calls is what
    // trips Spotify's limits.
    tokio::time::sleep(Duration::from_millis(600)).await;
    match spotify.search_detailed(query, "songs", 10, 0).await {
        Ok(found) => Some(found.tracks),
        Err(e)
            if {
                let m = e.to_string();
                m.contains("invalid argument") || m.contains("400 Bad Request")
            } =>
        {
            // Spotify refused this one query (a bad request), which says nothing about the
            // others. Pausing here made the same song fail first every round and blocked
            // every song behind it, so skip it and carry on.
            warn!("Spotify refused the search {query:?}: {e}; skipping this song");
            Some(Vec::new())
        }
        Err(e) => {
            // Rate limited: wait as long as Spotify asked (1 min to 1 h). Cooling down: a minute.
            // Anything else (a dropped connection, a timeout): a short pause only.
            let pause = match &e {
                crate::api::ApiError::RateLimited(secs) => (*secs).clamp(60, 3600),
                crate::api::ApiError::CircuitOpen { .. } => 60,
                _ => 20,
            };
            warn!("Spotify search failed for {query:?}: {e}; pausing lookups for {pause}s");
            SEARCH_PAUSED_UNTIL.fetch_max(now_secs() + pause, Ordering::Relaxed);
            None
        }
    }
}

/// Resolve an outside track (artist + title) to a Spotify track via search with SQLite resolution cache.
pub async fn resolve_outside_track(
    spotify: &SpotifyClient,
    cache: &Cache,
    artist: &str,
    title: &str,
    duration_ms: Option<u64>,
) -> Option<Track> {
    let query_key = format!(
        "{} - {}",
        artist.trim().to_lowercase(),
        title.trim().to_lowercase()
    );

    // 1. Check cache
    if let Ok(Some(cached_res)) = cache.get_resolved_track(&query_key) {
        return cached_res; // Some(track) on hit, None on cached miss
    }

    // 2. Search Spotify (capped at 10 results)
    let found = search_songs_budgeted(spotify, &format!("{artist} {title}")).await?;
    // An empty answer is far more often a hiccup (session reconnecting) than a song that is
    // really not on Spotify, so it is not remembered as a permanent "no match".
    let nothing_came_back = found.is_empty();
    let mut best_track: Option<Track> = None;
    let mut best_score = 0.0f32;
    for t in found {
        let s = score_track_match(&t, artist, title, duration_ms);
        if s > best_score {
            best_score = s;
            best_track = Some(t);
        }
    }

    if best_score >= 0.70 {
        if let Some(ref t) = best_track {
            let _ = cache.put_resolved_track(&query_key, Some(t));
        }
        best_track
    } else {
        // Cache resolution miss to avoid repeating searches
        if !nothing_came_back {
            let _ = cache.put_resolved_track(&query_key, None);
        }
        None
    }
}

/// Resolve an album (artist + album title) to one of its songs on Spotify, which carries the
/// album id and cover. A miss is not cached: a brand-new release may not be searchable yet.
pub async fn resolve_outside_album(
    spotify: &SpotifyClient,
    cache: &Cache,
    artist: &str,
    album: &str,
) -> Option<Track> {
    let key = format!(
        "album:{} - {}",
        artist.trim().to_lowercase(),
        album.trim().to_lowercase()
    );
    if let Ok(Some(Some(track))) = cache.get_resolved_track(&key) {
        return Some(track);
    }
    let found = search_songs_budgeted(spotify, &format!("{artist} {album}")).await?;
    let want_album = normalize_string(album);
    let want_artist = normalize_string(artist);
    let mut best: Option<Track> = None;
    let mut best_score = 0.0f32;
    for t in found {
        let artist_score = t
            .artists
            .iter()
            .map(|a| token_similarity(&normalize_string(a), &want_artist))
            .fold(
                token_similarity(&normalize_string(&t.artist), &want_artist),
                f32::max,
            );
        let s =
            0.6 * token_similarity(&normalize_string(&t.album), &want_album) + 0.4 * artist_score;
        if s > best_score {
            best_score = s;
            best = Some(t);
        }
    }
    if best_score >= 0.75 {
        if let Some(ref t) = best {
            let _ = cache.put_resolved_track(&key, Some(t));
        }
        best
    } else {
        None
    }
}

// --- Outside Data Clients (ListenBrainz & Deezer) ---

#[derive(Debug, Deserialize)]
struct ListenBrainzFreshRelease {
    pub release_name: Option<String>,
    pub artist_name: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListenBrainzReleasesResponse {
    pub payload: Option<ListenBrainzPayload>,
}

#[derive(Debug, Deserialize)]
struct ListenBrainzPayload {
    pub releases: Option<Vec<ListenBrainzFreshRelease>>,
}

/// Query ListenBrainz open explore API for fresh releases.
pub async fn fetch_listenbrainz_fresh_releases(http: &reqwest::Client) -> Vec<(String, String)> {
    let url = "https://api.listenbrainz.org/1/explore/fresh-releases";
    let resp = http.get(url).timeout(Duration::from_secs(6)).send().await;

    match resp {
        Ok(res) if res.status().is_success() => {
            if let Ok(parsed) = res.json::<ListenBrainzReleasesResponse>().await {
                if let Some(payload) = parsed.payload {
                    if let Some(releases) = payload.releases {
                        return releases
                            .into_iter()
                            .filter_map(|r| {
                                let art = r.artist_name?;
                                let rel = r.release_name?;
                                Some((art, rel))
                            })
                            .take(15)
                            .collect();
                    }
                }
            }
        }
        _ => {}
    }

    Vec::new()
}

#[derive(Debug, Deserialize)]
struct DeezerChartResponse {
    /// Shape of `/chart`.
    pub tracks: Option<DeezerTrackList>,
    /// Shape of `/chart/<genre>/tracks`.
    pub data: Option<Vec<DeezerTrack>>,
}

#[derive(Debug, Deserialize)]
struct DeezerTrackList {
    pub data: Option<Vec<DeezerTrack>>,
}

#[derive(Debug, Deserialize)]
struct DeezerTrack {
    pub title: String,
    pub duration: Option<u64>,
    pub artist: DeezerArtist,
}

#[derive(Debug, Deserialize)]
struct DeezerArtist {
    pub name: String,
}

/// Query Deezer public chart for top global tracks.
pub async fn fetch_deezer_top_tracks(http: &reqwest::Client) -> Vec<(String, String, Option<u64>)> {
    let url = "https://api.deezer.com/chart/0/tracks";
    let resp = http.get(url).timeout(Duration::from_secs(6)).send().await;

    if let Ok(res) = resp {
        if res.status().is_success() {
            if let Ok(parsed) = res.json::<DeezerChartResponse>().await {
                let data = parsed.data.or_else(|| parsed.tracks.and_then(|t| t.data));
                if let Some(data) = data {
                    if !data.is_empty() {
                        return data
                            .into_iter()
                            .map(|t| (t.artist.name, t.title, t.duration.map(|d| d * 1000)))
                            .take(20)
                            .collect();
                    }
                }
            }
        }
    }

    // Deezer returns an empty chart for some regions. Its editorial "Top Worldwide" playlist
    // still answers there, so fall back to that.
    warn!("Deezer chart/0 returned no tracks; falling back to the Top Worldwide playlist");
    fetch_deezer_playlist_tracks(http, 3155776842, 30).await
}

/// Songs of one public Deezer playlist (no key): `(artist, title, duration_ms)` rows.
pub async fn fetch_deezer_playlist_tracks(
    http: &reqwest::Client,
    playlist_id: u64,
    limit: u32,
) -> Vec<(String, String, Option<u64>)> {
    let url = format!("https://api.deezer.com/playlist/{playlist_id}/tracks?limit={limit}");
    let Ok(res) = http.get(url).timeout(Duration::from_secs(6)).send().await else {
        warn!("Deezer playlist {playlist_id}: request failed");
        return Vec::new();
    };
    if !res.status().is_success() {
        warn!("Deezer playlist {playlist_id}: HTTP {}", res.status());
        return Vec::new();
    }
    match res.json::<DeezerChartResponse>().await {
        Ok(parsed) => parsed
            .data
            .unwrap_or_default()
            .into_iter()
            .map(|t| (t.artist.name, t.title, t.duration.map(|d| d * 1000)))
            .collect(),
        Err(e) => {
            warn!("Deezer playlist {playlist_id}: bad response: {e}");
            Vec::new()
        }
    }
}

/// ListenBrainz sitewide most-played songs this week (open API, no key):
/// `(artist, title, None)` rows.
pub async fn fetch_listenbrainz_trending(
    http: &reqwest::Client,
) -> Vec<(String, String, Option<u64>)> {
    let url = "https://api.listenbrainz.org/1/stats/sitewide/recordings?range=this_week&count=40";
    let Ok(res) = http.get(url).timeout(Duration::from_secs(8)).send().await else {
        warn!("ListenBrainz trending: request failed");
        return Vec::new();
    };
    if !res.status().is_success() {
        warn!("ListenBrainz trending: HTTP {}", res.status());
        return Vec::new();
    }
    let Ok(v) = res.json::<serde_json::Value>().await else {
        return Vec::new();
    };
    v.pointer("/payload/recordings")
        .and_then(serde_json::Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|r| {
                    Some((
                        r.get("artist_name")?.as_str()?.to_string(),
                        r.get("track_name")?.as_str()?.to_string(),
                        None,
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Genre charts offered as Made-for-you mixes: (Deezer genre id, label, mix id).
const DEEZER_GENRES: &[(u32, &str, &str)] = &[
    (132, "Pop", "pop"),
    (116, "Hip-Hop", "hiphop"),
    (152, "Rock", "rock"),
    (113, "Dance", "dance"),
    (165, "R&B", "rnb"),
    (197, "Latin", "latin"),
];

/// Deezer's public chart for one genre (no key): `(artist, title, duration_ms)` rows.
pub async fn fetch_deezer_genre_chart(
    http: &reqwest::Client,
    genre_id: u32,
    limit: usize,
) -> Vec<(String, String, Option<u64>)> {
    let url = format!("https://api.deezer.com/chart/{genre_id}/tracks?limit={limit}");
    match http.get(url).timeout(Duration::from_secs(6)).send().await {
        Ok(res) if res.status().is_success() => match res.json::<DeezerChartResponse>().await {
            Ok(parsed) => parsed
                .data
                .or_else(|| parsed.tracks.and_then(|t| t.data))
                .unwrap_or_default()
                .into_iter()
                .map(|t| (t.artist.name, t.title, t.duration.map(|d| d * 1000)))
                .take(limit)
                .collect(),
            Err(_) => Vec::new(),
        },
        _ => Vec::new(),
    }
}

#[derive(Debug, Deserialize)]
struct DeezerAlbumList {
    pub data: Option<Vec<DeezerAlbum>>,
}

#[derive(Debug, Deserialize)]
struct DeezerAlbum {
    pub id: u64,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub release_date: Option<String>,
    pub artist: DeezerArtist,
}

#[derive(Debug, Deserialize)]
struct DeezerAlbumTracks {
    pub data: Option<Vec<DeezerAlbumTrack>>,
}

#[derive(Debug, Deserialize)]
struct DeezerAlbumTrack {
    pub title: String,
    pub duration: Option<u64>,
    pub rank: Option<u64>,
}

/// One fresh album from Deezer's editorial releases, with its most popular song.
#[derive(Debug, Clone)]
pub struct FreshAlbum {
    pub artist: String,
    pub album: String,
    /// `YYYY-MM-DD`, or empty when Deezer did not say.
    pub release_date: String,
    pub song: String,
    pub duration_ms: Option<u64>,
}

/// Deezer's editorial "new releases" (no key): for each of the latest albums, its most popular
/// song. Newest first.
pub async fn fetch_deezer_fresh_albums(http: &reqwest::Client) -> Vec<FreshAlbum> {
    let albums = match http
        .get("https://api.deezer.com/editorial/0/releases?limit=24")
        .timeout(Duration::from_secs(6))
        .send()
        .await
    {
        Ok(res) if res.status().is_success() => match res.json::<DeezerAlbumList>().await {
            Ok(list) => list.data.unwrap_or_default(),
            Err(_) => return Vec::new(),
        },
        _ => return Vec::new(),
    };

    let mut out = Vec::new();
    for album in albums.into_iter().take(16) {
        let url = format!("https://api.deezer.com/album/{}/tracks?limit=25", album.id);
        let Ok(res) = http.get(url).timeout(Duration::from_secs(6)).send().await else {
            continue;
        };
        if !res.status().is_success() {
            continue;
        }
        let Ok(list) = res.json::<DeezerAlbumTracks>().await else {
            continue;
        };
        let best = list
            .data
            .unwrap_or_default()
            .into_iter()
            .max_by_key(|t| t.rank.unwrap_or(0));
        if let Some(t) = best {
            out.push(FreshAlbum {
                artist: album.artist.name,
                album: album.title,
                release_date: album.release_date.unwrap_or_default(),
                song: t.title,
                duration_ms: t.duration.map(|d| d * 1000),
            });
        }
    }
    out.sort_by(|a, b| b.release_date.cmp(&a.release_date));
    out
}

/// The lead song of each fresh album, as `(artist, title, duration_ms)` rows ready to be
/// matched on Spotify.
pub async fn fetch_deezer_new_release_songs(
    http: &reqwest::Client,
) -> Vec<(String, String, Option<u64>)> {
    fetch_deezer_fresh_albums(http)
        .await
        .into_iter()
        .map(|a| (a.artist, a.song, a.duration_ms))
        .collect()
}

/// Match outside `(artist, title, duration)` rows to Spotify songs, stopping at `want` matches
/// or after `max_tries` lookups (matches are cached, so later builds are instant).
async fn resolve_many(
    spotify: &SpotifyClient,
    cache: &Cache,
    entries: Vec<(String, String, Option<u64>)>,
    want: usize,
    max_tries: usize,
) -> Vec<Track> {
    let mut out: Vec<Track> = Vec::new();
    let mut rest = entries.into_iter().take(max_tries);
    // Four lookups at a time: one at a time (a search takes a second or more) made the big
    // lists and the Discover genres take most of an hour to fill. Row order is kept.
    while out.len() < want {
        let chunk: Vec<(String, String, Option<u64>)> = rest.by_ref().take(4).collect();
        if chunk.is_empty() {
            break;
        }
        let chunk = &chunk;
        let get = |i: usize| async move {
            match chunk.get(i) {
                Some((artist, title, dur)) => {
                    resolve_outside_track(spotify, cache, artist, title, *dur).await
                }
                None => None,
            }
        };
        let (a, b, c, d) = tokio::join!(get(0), get(1), get(2), get(3));
        out.extend([a, b, c, d].into_iter().flatten());
    }
    out.truncate(want);
    out
}

/// Deterministic shuffle (xorshift), so the same `seed` gives the same order.
fn shuffle<T>(items: &mut [T], seed: u64) {
    let mut x = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1;
    for i in (1..items.len()).rev() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        let j = (x % (i as u64 + 1)) as usize;
        items.swap(i, j);
    }
}

// --- Diversity Rules Enforcer ---

/// Filter a candidate list of tracks according to Halcyon diversity rules:
/// - Max 2 tracks per artist per mix
/// - No duplicate tracks across mixes on the same page (`global_seen`)
/// - Skip tracks played in the last 24h (`recent_24h_ids`, unless allow_recent is true)
pub fn filter_mix_tracks(
    candidates: Vec<Track>,
    max_per_artist: usize,
    global_seen: &mut HashSet<String>,
    recent_24h_ids: &HashSet<String>,
    allow_recent: bool,
    limit: usize,
) -> Vec<Track> {
    let mut result = Vec::with_capacity(limit);
    let mut artist_counts = std::collections::HashMap::new();

    for t in candidates {
        if result.len() >= limit {
            break;
        }

        if global_seen.contains(&t.id) {
            continue;
        }

        if !allow_recent && recent_24h_ids.contains(&t.id) {
            continue;
        }

        let count = artist_counts.entry(t.artist.clone()).or_insert(0);
        if *count >= max_per_artist {
            continue;
        }

        *count += 1;
        global_seen.insert(t.id.clone());
        result.push(t);
    }

    result
}

/// The biggest English-language songs of all time (Billboard chart-toppers and songs with
/// billions of streams and views), across the decades: `(artist, title)`.
/// They are matched on Spotify by `resolve_many`, so the spelling follows Spotify's.
const ALL_TIME_CLASSICS: &[(&str, &str)] = &[
    ("The Beatles", "Hey Jude"),
    ("The Beatles", "Let It Be"),
    ("The Beatles", "Come Together"),
    ("Queen", "Bohemian Rhapsody"),
    ("Queen", "Don't Stop Me Now"),
    ("Queen", "Somebody To Love"),
    ("Led Zeppelin", "Stairway to Heaven"),
    ("Eagles", "Hotel California"),
    ("Michael Jackson", "Billie Jean"),
    ("Michael Jackson", "Thriller"),
    ("Michael Jackson", "Beat It"),
    ("Prince", "Purple Rain"),
    (
        "Whitney Houston",
        "I Wanna Dance with Somebody (Who Loves Me)",
    ),
    ("Nirvana", "Smells Like Teen Spirit"),
    ("Oasis", "Wonderwall"),
    ("Radiohead", "Creep"),
    ("Fleetwood Mac", "Dreams"),
    ("Bob Dylan", "Like a Rolling Stone"),
    ("Elvis Presley", "Can't Help Falling in Love"),
    ("The Rolling Stones", "Paint It, Black"),
    ("David Bowie", "Space Oddity"),
    ("David Bowie", "Starman"),
    ("Pink Floyd", "Comfortably Numb"),
    ("AC/DC", "Back In Black"),
    ("AC/DC", "Highway to Hell"),
    ("Guns N' Roses", "Sweet Child O' Mine"),
    ("Journey", "Don't Stop Believin'"),
    ("Bon Jovi", "Livin' On A Prayer"),
    ("Aerosmith", "I Don't Want to Miss a Thing"),
    ("U2", "With Or Without You"),
    ("Coldplay", "Yellow"),
    ("Coldplay", "Viva La Vida"),
    ("The Killers", "Mr. Brightside"),
    ("Green Day", "Boulevard of Broken Dreams"),
    ("Linkin Park", "In the End"),
    ("Eminem", "Lose Yourself"),
    ("Adele", "Rolling in the Deep"),
    ("Adele", "Someone Like You"),
    ("Ed Sheeran", "Shape of You"),
    ("Ed Sheeran", "Perfect"),
    ("The Weeknd", "Blinding Lights"),
    ("Taylor Swift", "Shake It Off"),
    ("Taylor Swift", "Love Story"),
    ("Rihanna", "Umbrella"),
    ("Beyonce", "Crazy In Love"),
    ("Mark Ronson", "Uptown Funk"),
    ("Bruno Mars", "Just the Way You Are"),
    ("Katy Perry", "Firework"),
    ("Lady Gaga", "Bad Romance"),
    ("Justin Timberlake", "Cry Me a River"),
    ("Maroon 5", "Sugar"),
    ("Imagine Dragons", "Believer"),
    ("Post Malone", "Circles"),
    ("Billie Eilish", "bad guy"),
    ("Dua Lipa", "Levitating"),
    ("Harry Styles", "As It Was"),
    ("Olivia Rodrigo", "drivers license"),
    ("Lewis Capaldi", "Someone You Loved"),
    ("Sam Smith", "Stay With Me"),
    ("John Legend", "All of Me"),
    ("Stevie Wonder", "Superstition"),
    ("Marvin Gaye", "Let's Get It On"),
    ("Aretha Franklin", "Respect"),
    ("Otis Redding", "(Sittin' On) The Dock Of The Bay"),
    ("Bill Withers", "Ain't No Sunshine"),
    ("Ben E. King", "Stand By Me"),
    ("Louis Armstrong", "What A Wonderful World"),
    ("Frank Sinatra", "My Way"),
    ("Nina Simone", "Feeling Good"),
    ("Simon & Garfunkel", "The Sound of Silence"),
    ("Bob Marley & The Wailers", "No Woman, No Cry"),
    ("Johnny Cash", "Hurt"),
    ("Dolly Parton", "Jolene"),
    ("Tina Turner", "The Best"),
    ("Madonna", "Like a Prayer"),
    ("Cyndi Lauper", "Girls Just Want to Have Fun"),
    ("a-ha", "Take On Me"),
    ("George Michael", "Careless Whisper"),
    ("Phil Collins", "In The Air Tonight"),
    ("Dire Straits", "Sultans Of Swing"),
    ("Toto", "Africa"),
    ("Van Halen", "Jump"),
    ("Metallica", "Enter Sandman"),
    ("Red Hot Chili Peppers", "Under the Bridge"),
    ("Red Hot Chili Peppers", "Californication"),
    ("Foo Fighters", "Everlong"),
    ("Blur", "Song 2"),
    ("The Cranberries", "Zombie"),
    ("Alanis Morissette", "You Oughta Know"),
    ("Backstreet Boys", "I Want It That Way"),
    ("*NSYNC", "Bye Bye Bye"),
    ("Britney Spears", "...Baby One More Time"),
    ("Destiny's Child", "Say My Name"),
    ("Usher", "Yeah!"),
    ("Outkast", "Hey Ya!"),
    ("Kanye West", "Stronger"),
    ("JAY-Z", "Empire State of Mind"),
    ("Drake", "God's Plan"),
    ("Kendrick Lamar", "HUMBLE."),
    ("Travis Scott", "SICKO MODE"),
    ("Lizzo", "Good as Hell"),
    ("Gotye", "Somebody That I Used To Know"),
    ("Pharrell Williams", "Happy"),
    ("Passenger", "Let Her Go"),
    ("The Beach Boys", "God Only Knows"),
    (
        "Creedence Clearwater Revival",
        "Have You Ever Seen The Rain?",
    ),
    ("The Police", "Every Breath You Take"),
    ("Elton John", "Rocket Man"),
    ("Elton John", "Tiny Dancer"),
    ("Billy Joel", "Piano Man"),
    ("Bruce Springsteen", "Born to Run"),
    ("Tom Petty", "Free Fallin'"),
    ("Lynyrd Skynyrd", "Sweet Home Alabama"),
    ("Eric Clapton", "Tears in Heaven"),
    ("Celine Dion", "My Heart Will Go On"),
    ("Mariah Carey", "Fantasy"),
    ("Alicia Keys", "Fallin'"),
    ("Amy Winehouse", "Back To Black"),
    ("The Verve", "Bitter Sweet Symphony"),
    ("Joy Division", "Love Will Tear Us Apart"),
    ("The Smiths", "There Is A Light That Never Goes Out"),
    ("Depeche Mode", "Enjoy the Silence"),
    ("Gorillaz", "Feel Good Inc."),
    ("Arctic Monkeys", "Do I Wanna Know?"),
    ("Tame Impala", "The Less I Know The Better"),
    ("Daft Punk", "Get Lucky"),
    // More Billboard chart-toppers and billion-view songs.
    ("Luis Fonsi", "Despacito"),
    ("PSY", "Gangnam Style"),
    ("Wiz Khalifa", "See You Again"),
    ("Justin Bieber", "Sorry"),
    ("Justin Bieber", "Baby"),
    ("Lil Nas X", "Old Town Road"),
    ("Dua Lipa", "Don't Start Now"),
    ("The Weeknd", "Starboy"),
    ("The Weeknd", "Save Your Tears"),
    ("Post Malone", "Sunflower"),
    ("Post Malone", "rockstar"),
    ("Ed Sheeran", "Thinking Out Loud"),
    ("Bruno Mars", "Locked Out of Heaven"),
    ("Bruno Mars", "When I Was Your Man"),
    ("Adele", "Hello"),
    ("Sia", "Chandelier"),
    ("Katy Perry", "Roar"),
    ("Rihanna", "We Found Love"),
    ("Rihanna", "Diamonds"),
    ("Miley Cyrus", "Flowers"),
    ("Taylor Swift", "Blank Space"),
    ("Taylor Swift", "Anti-Hero"),
    ("Harry Styles", "Watermelon Sugar"),
    ("Olivia Rodrigo", "good 4 u"),
    ("Glass Animals", "Heat Waves"),
    ("Doja Cat", "Say So"),
    ("Mariah Carey", "All I Want for Christmas Is You"),
    ("Shakira", "Hips Don't Lie"),
    ("Black Eyed Peas", "I Gotta Feeling"),
    ("Eminem", "Love The Way You Lie"),
    ("Eminem", "Without Me"),
    ("Lady Gaga", "Just Dance"),
    ("Lady Gaga", "Shallow"),
    ("Avicii", "Wake Me Up"),
    ("The Chainsmokers", "Closer"),
    ("Maroon 5", "Girls Like You"),
    ("Charlie Puth", "Attention"),
    ("Queen", "We Will Rock You"),
    ("Survivor", "Eye of the Tiger"),
    ("Whitney Houston", "I Will Always Love You"),
    ("Michael Jackson", "Smooth Criminal"),
    ("The Beatles", "Yesterday"),
    ("Bee Gees", "Stayin' Alive"),
    ("ABBA", "Dancing Queen"),
    ("Earth, Wind & Fire", "September"),
    ("Kanye West", "Gold Digger"),
    ("50 Cent", "In Da Club"),
    ("Drake", "One Dance"),
    ("Drake", "Hotline Bling"),
    ("Cardi B", "Bodak Yellow"),
    ("Beyonce", "Halo"),
    ("Shawn Mendes", "Senorita"),
    ("Camila Cabello", "Havana"),
    ("Ariana Grande", "7 rings"),
    ("Ariana Grande", "thank u, next"),
    ("Lorde", "Royals"),
    ("Imagine Dragons", "Radioactive"),
    ("OneRepublic", "Counting Stars"),
    ("Coldplay", "Fix You"),
    ("Pitbull", "Timber"),
    ("Flo Rida", "Low"),
    ("Kesha", "TiK ToK"),
    ("Sabrina Carpenter", "Espresso"),
    ("Billie Eilish", "BIRDS OF A FEATHER"),
    ("Kendrick Lamar", "Not Like Us"),
    ("Shaboozey", "A Bar Song (Tipsy)"),
    ("ROSE", "APT."),
    ("Lady Gaga", "Die With A Smile"),
];

// --- Big lists: All-Time Best, Top 100, Top 200 ---

/// Songs in "All-Time Best".
const ALL_TIME_SIZE: usize = 50;
/// Songs in the biggest chart playlist ("Top 200"); "Top 100" is its first half.
const TOP_BIG: usize = 200;
/// Chart rows gathered before matching, so songs Spotify cannot match still leave 200.
const CHART_POOL_SIZE: usize = 280;
/// How long a gathered chart is reused before the sources are asked again.
const CHART_POOL_TTL: u64 = 6 * 3600;
/// Uncached Spotify searches allowed per step of `warm_big_lists_step`.
const WARM_SEARCHES: u32 = 330;

type OutsideSong = (String, String, Option<u64>);

static CHART_POOL: std::sync::Mutex<Option<(u64, Vec<OutsideSong>)>> = std::sync::Mutex::new(None);

/// Adds rows to `pool`, skipping a song that is already in it (same artist and title).
fn push_unique_songs(
    pool: &mut Vec<OutsideSong>,
    seen: &mut HashSet<String>,
    rows: Vec<OutsideSong>,
) {
    for (artist, title, dur) in rows {
        let key = format!("{}|{}", normalize_string(&artist), normalize_string(&title));
        if seen.insert(key) {
            pool.push((artist, title, dur));
        }
    }
}

/// Deezer's worldwide chart, up to 100 songs, best first.
async fn fetch_deezer_chart_100(http: &reqwest::Client) -> Vec<OutsideSong> {
    let url = "https://api.deezer.com/chart/0/tracks?limit=100";
    if let Ok(res) = http.get(url).timeout(Duration::from_secs(8)).send().await {
        if res.status().is_success() {
            if let Ok(parsed) = res.json::<DeezerChartResponse>().await {
                return parsed
                    .data
                    .or_else(|| parsed.tracks.and_then(|t| t.data))
                    .unwrap_or_default()
                    .into_iter()
                    .map(|t| (t.artist.name, t.title, t.duration.map(|d| d * 1000)))
                    .collect();
            }
        }
    }
    Vec::new()
}

/// ListenBrainz sitewide most-played songs for one stats `range` (`this_month`, `month`,
/// `quarter`, `half_yearly`, `this_year`, `year`), 100 rows from `offset`. Open API, no key.
async fn fetch_listenbrainz_range(
    http: &reqwest::Client,
    range: &str,
    offset: u32,
) -> Vec<OutsideSong> {
    let url = format!(
        "https://api.listenbrainz.org/1/stats/sitewide/recordings?range={range}&count=100&offset={offset}"
    );
    let Ok(res) = http.get(url).timeout(Duration::from_secs(8)).send().await else {
        return Vec::new();
    };
    if !res.status().is_success() {
        return Vec::new();
    }
    let Ok(v) = res.json::<serde_json::Value>().await else {
        return Vec::new();
    };
    v.pointer("/payload/recordings")
        .and_then(serde_json::Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|r| {
                    Some((
                        r.get("artist_name")?.as_str()?.to_string(),
                        r.get("track_name")?.as_str()?.to_string(),
                        None,
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// The songs behind "Top 100" and "Top 200", best first. It starts with what is charting now
/// (Deezer), then the last month, the month before and the quarter, and only if that still
/// falls short it reaches back further (half a year, this year, last year) until the pool is
/// full. A song is listed once, at its best place.
pub async fn fetch_chart_pool(http: &reqwest::Client) -> Vec<OutsideSong> {
    if let Ok(guard) = CHART_POOL.lock() {
        if let Some((at, rows)) = guard.as_ref() {
            if !rows.is_empty() && now_secs().saturating_sub(*at) < CHART_POOL_TTL {
                return rows.clone();
            }
        }
    }

    let mut pool: Vec<OutsideSong> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    push_unique_songs(&mut pool, &mut seen, fetch_deezer_chart_100(http).await);
    if pool.len() < CHART_POOL_SIZE {
        push_unique_songs(
            &mut pool,
            &mut seen,
            fetch_deezer_playlist_tracks(http, 3155776842, 100).await,
        );
    }
    for range in [
        "this_month",
        "month",
        "quarter",
        "half_yearly",
        "this_year",
        "year",
    ] {
        for offset in [0u32, 100] {
            if pool.len() >= CHART_POOL_SIZE {
                break;
            }
            push_unique_songs(
                &mut pool,
                &mut seen,
                fetch_listenbrainz_range(http, range, offset).await,
            );
        }
    }
    pool.truncate(CHART_POOL_SIZE);

    if !pool.is_empty() {
        if let Ok(mut guard) = CHART_POOL.lock() {
            *guard = Some((now_secs(), pool.clone()));
        }
    }
    pool
}

/// The "All-Time Best" candidates in today's order (a different order each day).
pub(crate) fn all_time_candidates() -> Vec<OutsideSong> {
    let mut classics: Vec<OutsideSong> = ALL_TIME_CLASSICS
        .iter()
        .map(|&(artist, title)| (artist.to_string(), title.to_string(), None))
        .collect();
    shuffle(&mut classics, now_secs() / 86_400);
    classics
}

/// A song already matched on Spotify earlier, found without any lookup.
fn resolve_cached(cache: &Cache, artist: &str, title: &str) -> Option<Track> {
    let key = format!(
        "{} - {}",
        artist.trim().to_lowercase(),
        title.trim().to_lowercase()
    );
    cache.get_resolved_track(&key).ok().flatten().flatten()
}

/// The first `want` rows that are already matched on Spotify, in row order, each song once.
fn resolve_many_cached(cache: &Cache, entries: &[OutsideSong], want: usize) -> Vec<Track> {
    let mut out: Vec<Track> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for (artist, title, _) in entries {
        if out.len() >= want {
            break;
        }
        if let Some(t) = resolve_cached(cache, artist, title) {
            if seen.insert(t.id.clone()) {
                out.push(t);
            }
        }
    }
    out
}

/// Seconds until Spotify lookups are allowed again (0 when they are not paused).
pub fn search_pause_remaining() -> u64 {
    SEARCH_PAUSED_UNTIL
        .load(Ordering::Relaxed)
        .saturating_sub(now_secs())
}

/// `(matched, unknown)` for the first rows of a list: how many are matched on Spotify, and
/// how many were never looked up (a lookup that found nothing is not unknown).
fn resolution_state(cache: &Cache, entries: &[OutsideSong], first: usize) -> (usize, usize) {
    let mut matched = 0;
    let mut unknown = 0;
    for (artist, title, _) in entries.iter().take(first) {
        let key = format!(
            "{} - {}",
            artist.trim().to_lowercase(),
            title.trim().to_lowercase()
        );
        match cache.get_resolved_track(&key).ok().flatten() {
            Some(Some(_)) => matched += 1,
            Some(None) => {}
            None => unknown += 1,
        }
    }
    (matched, unknown)
}

/// True while Top 200 or All-Time Best still has songs that could be matched but have not
/// been looked up (so another round is worth running).
pub async fn big_lists_incomplete(cache: &Cache, http: &reqwest::Client) -> bool {
    let pool = fetch_chart_pool(http).await;
    let (m, u) = resolution_state(cache, &pool, pool.len());
    let (am, au) = resolution_state(cache, &all_time_candidates(), usize::MAX);
    tracing::info!("big lists: top chart {m} matched, {u} not looked up; all-time {am} matched, {au} not looked up");
    (m < TOP_BIG && u > 0) || (am < ALL_TIME_SIZE && au > 0)
}

/// How many steps `warm_big_lists_step` has (0-based).
pub const WARM_STEPS: usize = 5;

/// Matches the songs of Top 100, All-Time Best and Top 200 on Spotify, a step at a time, and
/// remembers the matches. The Home page only reads those matches (it never waits for 250
/// lookups), so this runs after Home is shown. The steps are small at first, so a list shows
/// up after a minute rather than after all the lookups: Top 100 gets its first 30 songs, then
/// All-Time Best its first 30, then Top 100 is completed, then All-Time Best, then Top 200.
///
/// Returns true when the step did new lookups, i.e. when Home should be built again to show them.
pub async fn warm_big_lists_step(
    spotify: &SpotifyClient,
    cache: &Cache,
    http: &reqwest::Client,
    step: usize,
) -> bool {
    SEARCH_BUDGET.fetch_max(WARM_SEARCHES, Ordering::Relaxed);
    let before = SEARCH_BUDGET.load(Ordering::Relaxed);

    // `resolve_many` counts songs matched earlier too, so each step builds on the last.
    let (all_time, chart_want) = match step {
        0 => (0, 30),
        1 => (30, 0),
        2 => (0, 100),
        3 => (ALL_TIME_SIZE + 10, 0),
        _ => (0, TOP_BIG),
    };
    if all_time > 0 {
        let _ = resolve_many(spotify, cache, all_time_candidates(), all_time, usize::MAX).await;
    }
    if chart_want > 0 {
        let pool = fetch_chart_pool(http).await;
        let _ = resolve_many(spotify, cache, pool, chart_want, usize::MAX).await;
    }

    SEARCH_BUDGET.load(Ordering::Relaxed) < before
}

// --- Discover ---

/// An album from an outside source, before it is matched on Spotify.
#[derive(Debug, Clone)]
pub struct OutsideAlbum {
    pub artist: String,
    pub title: String,
    /// `YYYY-MM-DD`.
    pub release_date: String,
    pub art: Option<String>,
}

/// The first ten characters of an ISO date or timestamp (`2026-10-30T07:00:00Z` -> `2026-10-30`).
fn short_date(s: &str) -> String {
    s.chars().take(10).collect()
}

#[derive(Debug, Deserialize)]
struct ItunesResponse {
    #[serde(default)]
    results: Vec<ItunesItem>,
}

#[derive(Debug, Deserialize)]
struct ItunesItem {
    #[serde(rename = "artistName")]
    artist_name: Option<String>,
    #[serde(rename = "collectionName")]
    collection_name: Option<String>,
    #[serde(rename = "releaseDate")]
    release_date: Option<String>,
    #[serde(rename = "artworkUrl100")]
    artwork: Option<String>,
}

/// An artist's albums from the Apple iTunes Search API (open, no key, works everywhere), newest
/// first. It is how Discover learns what your artists released lately without the Spotify Web API.
pub async fn fetch_itunes_artist_albums(http: &reqwest::Client, artist: &str) -> Vec<OutsideAlbum> {
    let sent = http
        .get("https://itunes.apple.com/search")
        .query(&[
            ("term", artist),
            ("entity", "album"),
            ("attribute", "artistTerm"),
            ("limit", "30"),
        ])
        .timeout(Duration::from_secs(6))
        .send()
        .await;
    let res = match sent {
        Ok(r) if r.status().is_success() => r,
        Ok(r) => {
            warn!("iTunes albums for {artist:?}: HTTP {}", r.status());
            return Vec::new();
        }
        Err(e) => {
            warn!("iTunes albums for {artist:?}: {e}");
            return Vec::new();
        }
    };
    let Ok(parsed) = res.json::<ItunesResponse>().await else {
        return Vec::new();
    };
    let want = normalize_string(artist);
    let mut out: Vec<OutsideAlbum> = parsed
        .results
        .into_iter()
        .filter_map(|r| {
            let name = r.artist_name?;
            let title = r.collection_name?;
            let date = short_date(&r.release_date?);
            // The artist search also finds records the artist only appears on; keep their own.
            if !normalize_string(&name).contains(&want) {
                return None;
            }
            Some(OutsideAlbum {
                artist: name,
                title,
                release_date: date,
                art: r.artwork.map(|u| u.replace("100x100bb", "600x600bb")),
            })
        })
        .collect();
    out.sort_by(|a, b| b.release_date.cmp(&a.release_date));
    out
}

#[derive(Debug, Deserialize)]
struct AppleFeed {
    feed: AppleFeedInner,
}

#[derive(Debug, Deserialize)]
struct AppleFeedInner {
    #[serde(default)]
    results: Vec<AppleAlbum>,
}

#[derive(Debug, Deserialize)]
struct AppleAlbum {
    name: String,
    #[serde(rename = "artistName")]
    artist_name: String,
    #[serde(default, rename = "releaseDate")]
    release_date: Option<String>,
    #[serde(default, rename = "artworkUrl100")]
    artwork: Option<String>,
}

/// Apple Music's most played albums (open feed, no key). Each has a release date, so Discover
/// keeps the recent ones: the new albums people actually play.
pub async fn fetch_apple_hot_albums(http: &reqwest::Client) -> Vec<OutsideAlbum> {
    let url = "https://rss.applemarketingtools.com/api/v2/us/music/most-played/50/albums.json";
    let res = match http.get(url).timeout(Duration::from_secs(8)).send().await {
        Ok(r) if r.status().is_success() => r,
        Ok(r) => {
            warn!("Apple most-played albums: HTTP {}", r.status());
            return Vec::new();
        }
        Err(e) => {
            warn!("Apple most-played albums: {e}");
            return Vec::new();
        }
    };
    let Ok(parsed) = res.json::<AppleFeed>().await else {
        warn!("Apple most-played albums: unexpected answer");
        return Vec::new();
    };
    parsed
        .feed
        .results
        .into_iter()
        .filter_map(|a| {
            Some(OutsideAlbum {
                artist: a.artist_name,
                title: a.name,
                release_date: short_date(&a.release_date?),
                art: a.artwork.map(|u| u.replace("100x100bb", "600x600bb")),
            })
        })
        .collect()
}

/// ListenBrainz fresh releases (open, no key). Read loosely, since the shape of the answer has
/// changed over time: a list at the top, or under `payload.releases`.
pub async fn fetch_listenbrainz_fresh_albums(http: &reqwest::Client) -> Vec<OutsideAlbum> {
    let res = match http
        .get("https://api.listenbrainz.org/1/explore/fresh-releases")
        .timeout(Duration::from_secs(8))
        .send()
        .await
    {
        Ok(r) if r.status().is_success() => r,
        Ok(r) => {
            warn!("ListenBrainz fresh releases: HTTP {}", r.status());
            return Vec::new();
        }
        Err(e) => {
            warn!("ListenBrainz fresh releases: {e}");
            return Vec::new();
        }
    };
    let Ok(v) = res.json::<serde_json::Value>().await else {
        return Vec::new();
    };
    let rows = v
        .pointer("/payload/releases")
        .and_then(serde_json::Value::as_array)
        .or_else(|| v.get("releases").and_then(serde_json::Value::as_array))
        .or_else(|| v.as_array());
    let today = date_from_unix_secs(now_secs());
    let mut out: Vec<OutsideAlbum> = rows
        .map(|rows| {
            rows.iter()
                .filter_map(|r| {
                    let artist = r["artist_credit_name"]
                        .as_str()
                        .or_else(|| r["artist_name"].as_str())?;
                    let title = r["release_name"].as_str()?;
                    let date = r["release_date"]
                        .as_str()
                        .map(short_date)
                        .unwrap_or_else(|| today.clone());
                    Some(OutsideAlbum {
                        artist: artist.to_string(),
                        title: title.to_string(),
                        release_date: date,
                        art: None,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    out.sort_by(|a, b| b.release_date.cmp(&a.release_date));
    out.truncate(40);
    out
}

/// A Deezer API answer (open, no key) as loose JSON.
async fn deezer_get(
    http: &reqwest::Client,
    path: &str,
    query: &[(&str, &str)],
) -> Option<serde_json::Value> {
    let res = http
        .get(format!("https://api.deezer.com{path}"))
        .query(query)
        .timeout(Duration::from_secs(6))
        .send()
        .await
        .ok()?;
    if !res.status().is_success() {
        return None;
    }
    res.json().await.ok()
}

/// Deezer's id for an artist, when the best hit is really that artist.
pub(crate) async fn deezer_artist_id(http: &reqwest::Client, name: &str) -> Option<u64> {
    let v = deezer_get(http, "/search/artist", &[("q", name), ("limit", "1")]).await?;
    let hit = v.get("data")?.as_array()?.first()?;
    let found = normalize_string(hit.get("name")?.as_str()?);
    if token_similarity(&found, &normalize_string(name)) < 0.6 {
        return None;
    }
    hit.get("id")?.as_u64()
}

/// Artists Deezer lists as similar to `id` (their ids).
pub(crate) async fn deezer_related_artists(
    http: &reqwest::Client,
    id: u64,
    limit: u32,
) -> Vec<u64> {
    let limit = limit.to_string();
    let Some(v) = deezer_get(http, &format!("/artist/{id}/related"), &[("limit", &limit)]).await
    else {
        return Vec::new();
    };
    v.get("data")
        .and_then(serde_json::Value::as_array)
        .map(|rows| rows.iter().filter_map(|r| r.get("id")?.as_u64()).collect())
        .unwrap_or_default()
}

/// An artist's most popular songs on Deezer, as `(artist, title, duration_ms)` rows.
pub(crate) async fn deezer_artist_top(
    http: &reqwest::Client,
    id: u64,
    limit: u32,
) -> Vec<(String, String, Option<u64>)> {
    let limit = limit.to_string();
    let Some(v) = deezer_get(http, &format!("/artist/{id}/top"), &[("limit", &limit)]).await else {
        return Vec::new();
    };
    v.get("data")
        .and_then(serde_json::Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|r| {
                    Some((
                        r.pointer("/artist/name")?.as_str()?.to_string(),
                        r.get("title")?.as_str()?.to_string(),
                        r.get("duration")
                            .and_then(serde_json::Value::as_u64)
                            .map(|d| d * 1000),
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// `YYYY-MM-DD` (UTC) for a unix time.
fn date_from_unix_secs(secs: u64) -> String {
    let z = (secs / 86_400) as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

/// An album from the Spotify Web API as a Discover card; a press on it opens the album.
fn album_card(a: Album) -> ShelfItem {
    ShelfItem {
        id: a.id,
        title: a.title,
        subtitle: format!("New • {}", a.artist),
        art_url: a.art_url,
        uri: a.uri,
        context_type: "album".to_string(),
        tracks: vec![],
    }
}

/// Rank the artists you listen to: each place in your most played artists counts three points
/// (the top one the most), each liked song one.
fn rank_artists(played: &[String], liked: &[Track], want: usize) -> Vec<String> {
    fn bump(score: &mut HashMap<String, (String, f32)>, name: &str, weight: f32) {
        let key = normalize_string(name);
        if key.is_empty() || key == "various artists" {
            return;
        }
        score
            .entry(key)
            .or_insert_with(|| (name.trim().to_string(), 0.0))
            .1 += weight;
    }
    let mut score: HashMap<String, (String, f32)> = HashMap::new();
    for (i, name) in played.iter().enumerate() {
        bump(&mut score, name, 3.0 * (played.len() - i) as f32);
    }
    for t in liked {
        bump(&mut score, &t.artist, 1.0);
    }
    let mut ranked: Vec<(String, f32)> = score.into_values().collect();
    ranked.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.cmp(&b.0))
    });
    ranked
        .into_iter()
        .map(|(name, _)| name)
        .take(want)
        .collect()
}

/// The artists Discover is built around: from your play log and liked songs, so it works
/// without the Spotify "followed artists" list (which the default sign-in cannot read).
fn taste_artists(cache: &Cache, want: usize) -> Vec<String> {
    let played = cache.get_top_artists_in_period(365, 25).unwrap_or_default();
    let liked: Vec<Track> = cache
        .get_liked_tracks(1000, 0)
        .map(|(t, _)| t)
        .unwrap_or_default();
    rank_artists(&played, &liked, want)
}

/// Match albums on Spotify, in order, until `want` cards or `max_tries` lookups. A card whose
/// song carries an album id opens that album; the song is kept so the card can also be played.
/// Albums released on or after `new_after` are labelled "New", older ones with their year.
async fn resolve_album_cards(
    spotify: &SpotifyClient,
    cache: &Cache,
    albums: Vec<OutsideAlbum>,
    want: usize,
    max_tries: usize,
    new_after: &str,
) -> Vec<ShelfItem> {
    let mut out: Vec<ShelfItem> = Vec::new();
    let mut seen_albums: HashSet<String> = HashSet::new();
    let mut seen_ids: HashSet<String> = HashSet::new();
    for (tries, a) in albums.into_iter().enumerate() {
        if out.len() >= want || tries >= max_tries {
            break;
        }
        let key = format!(
            "{}|{}",
            normalize_string(&a.artist),
            normalize_string(&a.title)
        );
        if !seen_albums.insert(key) {
            continue;
        }
        let Some(track) = resolve_outside_album(spotify, cache, &a.artist, &a.title).await else {
            continue;
        };
        let (id, uri, kind) = match &track.album_id {
            Some(alb) => (alb.clone(), format!("spotify:album:{alb}"), "album"),
            None => (track.id.clone(), track.uri.clone(), "track"),
        };
        if !seen_ids.insert(id.clone()) {
            continue;
        }
        let kicker = if a.release_date.as_str() >= new_after {
            "New".to_string()
        } else {
            a.release_date.chars().take(4).collect::<String>()
        };
        out.push(ShelfItem {
            id,
            title: a.title.clone(),
            subtitle: format!("{kicker} • {}", a.artist),
            art_url: track.art_url.clone().or_else(|| a.art.clone()),
            uri,
            context_type: kind.to_string(),
            tracks: vec![track],
        });
    }
    out
}

/// "If you like <artist>": the artist's best songs and the best songs of similar artists
/// (Deezer's related-artists list), matched on Spotify.
async fn build_artist_mix(
    spotify: &SpotifyClient,
    cache: &Cache,
    http: &reqwest::Client,
    artist: &str,
    seen: &mut HashSet<String>,
) -> Option<MusicMix> {
    let id = deezer_artist_id(http, artist).await?;
    let mut entries = deezer_artist_top(http, id, 4).await;
    for related in deezer_related_artists(http, id, 6)
        .await
        .into_iter()
        .take(5)
    {
        entries.extend(deezer_artist_top(http, related, 3).await);
    }
    let resolved = resolve_many(spotify, cache, entries, 14, 24).await;
    let tracks = filter_mix_tracks(resolved, 2, seen, &HashSet::new(), true, 14);
    if tracks.len() < 5 {
        return None;
    }
    let art = tracks.first().and_then(|t| t.art_url.clone());
    Some(MusicMix {
        id: format!("discover-{}", normalize_string(artist).replace(' ', "-")),
        title: format!("If you like {artist}"),
        description: format!("Songs by {artist} and by artists with a similar sound."),
        source: "Deezer".to_string(),
        tracks,
        art_url: art,
    })
}

/// Where a Discover section gets its songs.
enum GenreSource {
    /// Deezer's chart for one genre id.
    Chart(u32),
    /// The best match of a Deezer playlist search (moods have no chart of their own).
    Playlist(&'static str),
}

/// One Discover section by mood or genre.
struct GenreSection {
    id: &'static str,
    title: &'static str,
    blurb: &'static str,
    source: GenreSource,
}

/// Mood and genre sections of Discover, in page order.
const DISCOVER_GENRES: &[GenreSection] = &[
    GenreSection {
        id: "genre-calm",
        title: "Calm",
        blurb: "Soft, slow songs to unwind to",
        source: GenreSource::Playlist("calm"),
    },
    GenreSection {
        id: "genre-hiphop",
        title: "Hip-Hop",
        blurb: "The best hip-hop right now",
        source: GenreSource::Chart(116),
    },
    GenreSection {
        id: "genre-pop",
        title: "Pop",
        blurb: "The biggest pop songs right now",
        source: GenreSource::Chart(132),
    },
    GenreSection {
        id: "genre-rock",
        title: "Rock",
        blurb: "The best rock right now",
        source: GenreSource::Chart(152),
    },
    GenreSection {
        id: "genre-rnb",
        title: "R&B",
        blurb: "Smooth R&B at the top of the charts",
        source: GenreSource::Chart(165),
    },
    GenreSection {
        id: "genre-dance",
        title: "Dance",
        blurb: "Dance floor songs at the top of the charts",
        source: GenreSource::Chart(113),
    },
    GenreSection {
        id: "genre-latin",
        title: "Latin",
        blurb: "The best Latin songs right now",
        source: GenreSource::Chart(197),
    },
    GenreSection {
        id: "genre-indie",
        title: "Indie & Alternative",
        blurb: "The best indie and alternative songs right now",
        source: GenreSource::Chart(85),
    },
    GenreSection {
        id: "genre-jazz",
        title: "Jazz",
        blurb: "The best jazz right now",
        source: GenreSource::Chart(129),
    },
    GenreSection {
        id: "genre-country",
        title: "Country",
        blurb: "The best country right now",
        source: GenreSource::Chart(84),
    },
    GenreSection {
        id: "genre-focus",
        title: "Focus",
        blurb: "Steady songs to work and study to",
        source: GenreSource::Playlist("deep focus"),
    },
    GenreSection {
        id: "genre-workout",
        title: "Workout",
        blurb: "High-energy songs to move to",
        source: GenreSource::Playlist("workout"),
    },
];

/// Uncached Spotify searches the genre sections may use in one Discover build.
const GENRE_SEARCHES: u32 = 420;
/// Songs in one genre playlist.
const GENRE_SONGS: usize = 40;
/// Songs matched for every genre in the first pass, so each shows up early.
const GENRE_FIRST_PASS: usize = 12;

/// Songs of the first Deezer playlist matching `query` that has enough songs to be a real
/// playlist: `(artist, title, duration_ms)` rows.
async fn fetch_deezer_mood_playlist(
    http: &reqwest::Client,
    query: &str,
    limit: u32,
) -> Vec<OutsideSong> {
    let Some(v) = deezer_get(http, "/search/playlist", &[("q", query), ("limit", "10")]).await
    else {
        return Vec::new();
    };
    let id = v
        .get("data")
        .and_then(serde_json::Value::as_array)
        .and_then(|rows| {
            rows.iter().find(|r| {
                r.get("nb_tracks")
                    .and_then(serde_json::Value::as_u64)
                    .unwrap_or(0)
                    >= 25
            })
        })
        .and_then(|r| r.get("id")?.as_u64());
    match id {
        Some(id) => fetch_deezer_playlist_tracks(http, id, limit).await,
        None => Vec::new(),
    }
}

/// The genre sections in page order. A section built now wins over the same one from an
/// earlier build; one that could not be built this time keeps its old songs.
fn ordered_genres(new: &[MusicMix], old: &[MusicMix]) -> Vec<MusicMix> {
    DISCOVER_GENRES
        .iter()
        .filter_map(|g| new.iter().chain(old.iter()).find(|m| m.id == g.id).cloned())
        .collect()
}

/// Uncached Spotify searches allowed for one Discover build.
const DISCOVER_SEARCHES: u32 = 60;

/// Build the Discover page in stages and call `emit` after each, so the page fills in while
/// the slower Spotify lookups run. `seed` is the last finished feed (shown meanwhile); a
/// section the new build could not fetch keeps its old content.
///
/// Nothing here needs the Spotify Web API (the default sign-in is rate limited there): what is
/// new comes from open feeds, and Spotify is only searched to match it (see `search_songs_budgeted`).
///
/// 1. New from the artists you listen to (your play log and liked songs, then iTunes releases).
/// 2. The newest popular releases (Apple, Deezer, ListenBrainz), with a song from each.
/// 3. What listeners play most this week (ListenBrainz).
/// 4. "If you like ..." mixes for two of your artists (Deezer's similar artists).
/// 5. Mood and genre sections: Calm, Hip-Hop, Pop, Rock, R&B and more (`DISCOVER_GENRES`).
pub async fn build_discover_feed(
    spotify: &SpotifyClient,
    cache: &Cache,
    http: &reqwest::Client,
    seed: DiscoverFeed,
    emit: impl Fn(&DiscoverFeed),
) -> DiscoverFeed {
    // `fetch_max`, so a Home build running at the same time keeps the budget it has left.
    SEARCH_BUDGET.fetch_max(DISCOVER_SEARCHES, Ordering::Relaxed);
    let mut feed = seed;
    feed.complete = false;

    let now = now_secs();
    let today = date_from_unix_secs(now);
    let artist_cutoff = date_from_unix_secs(now.saturating_sub(150 * 86_400));
    let global_cutoff = date_from_unix_secs(now.saturating_sub(75 * 86_400));
    let new_label_cutoff = date_from_unix_secs(now.saturating_sub(60 * 86_400));

    // Stage 1: your artists.
    let artists = taste_artists(cache, 12);
    if artists.is_empty() {
        debug!("Discover: no listening history or liked songs yet, so no artist section");
    } else {
        let mut recent: Vec<OutsideAlbum> = Vec::new();
        let mut newest_each: Vec<OutsideAlbum> = Vec::new();
        for name in &artists {
            let mut albums = fetch_itunes_artist_albums(http, name).await;
            // Never a release dated in the future (pre-release listings).
            albums.retain(|a| a.release_date.as_str() <= today.as_str());
            if let Some(first) = albums.first() {
                newest_each.push(first.clone());
            }
            recent.extend(
                albums
                    .into_iter()
                    .filter(|a| a.release_date.as_str() >= artist_cutoff.as_str())
                    .take(2),
            );
        }
        recent.sort_by(|a, b| b.release_date.cmp(&a.release_date));
        // With nothing recent, show the latest record of each of your top artists instead.
        if recent.is_empty() {
            newest_each.sort_by(|a, b| b.release_date.cmp(&a.release_date));
            newest_each.truncate(10);
            recent = newest_each;
        }
        debug!(
            "Discover: {} candidate releases from {} artists",
            recent.len(),
            artists.len()
        );
        let cards = resolve_album_cards(spotify, cache, recent, 12, 22, &new_label_cutoff).await;
        if !cards.is_empty() {
            feed.from_artists = cards;
        }
    }
    feed.built_at = now_secs();
    emit(&feed);

    // Stage 2: the newest popular releases.
    let mut new_cards: Vec<ShelfItem> = Vec::new();
    // Spotify's own list, only with your own Client ID: the default sign-in is refused there.
    if spotify.auth_mode() == halcyon_music_core::models::AuthMode::OwnClientId {
        if let Ok(albums) = spotify.get_new_releases(20).await {
            new_cards.extend(albums.into_iter().map(album_card));
        }
    }
    let mut apple = fetch_apple_hot_albums(http).await;
    let mut deezer: Vec<OutsideAlbum> = fetch_deezer_fresh_albums(http)
        .await
        .into_iter()
        .map(|f| OutsideAlbum {
            artist: f.artist,
            title: f.album,
            release_date: f.release_date,
            art: None,
        })
        .collect();
    let mut brainz = fetch_listenbrainz_fresh_albums(http).await;
    debug!(
        "Discover sources: apple {}, deezer {}, listenbrainz {}",
        apple.len(),
        deezer.len(),
        brainz.len()
    );
    if apple.is_empty() && deezer.is_empty() && brainz.is_empty() {
        warn!("Discover: no outside release source answered (check the network)");
    }
    for list in [&mut apple, &mut deezer, &mut brainz] {
        list.retain(|a| {
            a.release_date.as_str() >= global_cutoff.as_str()
                && a.release_date.as_str() <= today.as_str()
        });
        list.sort_by(|a, b| b.release_date.cmp(&a.release_date));
    }
    // Popular first (Apple), then Deezer's editors, then whatever else is fresh.
    let mut pool = apple;
    pool.extend(deezer);
    pool.extend(brainz);
    let taken: HashSet<String> = feed.from_artists.iter().map(|c| c.id.clone()).collect();
    for card in resolve_album_cards(spotify, cache, pool, 16, 28, &new_label_cutoff).await {
        if !taken.contains(&card.id) && !new_cards.iter().any(|c| c.id == card.id) {
            new_cards.push(card);
        }
    }
    let mut seen_songs: HashSet<String> = HashSet::new();
    let songs: Vec<Track> = new_cards
        .iter()
        .filter_map(|c| c.tracks.first().cloned())
        .filter(|t| seen_songs.insert(t.id.clone()))
        .take(14)
        .collect();
    if !new_cards.is_empty() {
        feed.new_albums = new_cards;
    }
    if !songs.is_empty() {
        feed.new_songs = songs;
    }
    feed.built_at = now_secs();
    emit(&feed);

    // Stage 3: trending.
    let entries = fetch_listenbrainz_trending(http).await;
    let resolved = resolve_many(spotify, cache, entries, 10, 18).await;
    let mut seen: HashSet<String> = feed.new_songs.iter().map(|t| t.id.clone()).collect();
    let trending = filter_mix_tracks(resolved, 1, &mut seen, &HashSet::new(), true, 10);
    if !trending.is_empty() {
        feed.trending = trending;
    }
    feed.built_at = now_secs();
    emit(&feed);

    // Stage 4: "If you like ..." for two of your top artists, a different two each day.
    let pool_size = artists.len().min(6);
    if pool_size > 0 {
        let start = (now / 86_400) as usize % pool_size;
        let mut mix_seen: HashSet<String> = HashSet::new();
        let mut mixes: Vec<MusicMix> = Vec::new();
        for i in 0..pool_size {
            if mixes.len() >= 2 {
                break;
            }
            let Some(name) = artists.get((start + i) % pool_size) else {
                continue;
            };
            if let Some(m) = build_artist_mix(spotify, cache, http, name, &mut mix_seen).await {
                mixes.push(m);
            }
        }
        if !mixes.is_empty() {
            feed.mixes = mixes;
        }
    }

    // Stage 5: mood and genre playlists ("Calm", "Hip-Hop", ...), the best songs of each.
    // Two passes: the first matches a dozen songs for every genre so each playlist shows up
    // early; the second fills each up to 40. Each one is sent as soon as it is ready, and
    // matches are cached, so a later build only has the gaps left to fill.
    SEARCH_BUDGET.fetch_max(GENRE_SEARCHES, Ordering::Relaxed);
    let old_genres = std::mem::take(&mut feed.genres);
    let mut sources: Vec<(&GenreSection, Vec<OutsideSong>)> = Vec::new();
    for g in DISCOVER_GENRES {
        let rows = match g.source {
            GenreSource::Chart(genre_id) => fetch_deezer_genre_chart(http, genre_id, 60).await,
            GenreSource::Playlist(query) => fetch_deezer_mood_playlist(http, query, 60).await,
        };
        if rows.is_empty() {
            warn!("Discover: no songs found for the {} playlist", g.title);
        } else {
            sources.push((g, rows));
        }
    }
    let mut built: Vec<MusicMix> = Vec::new();
    feed.genres = ordered_genres(&built, &old_genres);
    for (want, tries) in [(GENRE_FIRST_PASS, GENRE_FIRST_PASS + 8), (GENRE_SONGS, 60)] {
        for (g, rows) in &sources {
            let resolved = resolve_many(spotify, cache, rows.clone(), want, tries).await;
            // Up to 3 songs per artist, so one act cannot take over a genre.
            let tracks = filter_mix_tracks(
                resolved,
                3,
                &mut HashSet::new(),
                &HashSet::new(),
                true,
                GENRE_SONGS,
            );
            if tracks.len() < 8 {
                continue;
            }
            if built
                .iter()
                .any(|m| m.id == g.id && m.tracks.len() >= tracks.len())
            {
                continue;
            }
            built.retain(|m| m.id != g.id);
            let art = tracks.first().and_then(|t| t.art_url.clone());
            built.push(MusicMix {
                id: g.id.to_string(),
                title: g.title.to_string(),
                description: g.blurb.to_string(),
                source: "Deezer".to_string(),
                tracks,
                art_url: art,
            });
            feed.genres = ordered_genres(&built, &old_genres);
            feed.built_at = now_secs();
            emit(&feed);
        }
    }
    feed.genres = ordered_genres(&built, &old_genres);

    feed.complete = true;
    feed.built_at = now_secs();
    emit(&feed);
    feed
}

// --- Home Feed Generator ---

/// Get system local hour of day (0..=23).
pub fn get_hour_of_day() -> u32 {
    let secs = now_secs();
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let t = secs as libc::time_t;
    unsafe {
        libc::localtime_r(&t, &mut tm);
    }
    tm.tm_hour.clamp(0, 23) as u32
}

/// Generate the dynamic greeting based on system local time.
pub fn get_greeting() -> String {
    let hour = get_hour_of_day();
    if hour < 12 {
        "Good morning".to_string()
    } else if hour < 18 {
        "Good afternoon".to_string()
    } else {
        "Good evening".to_string()
    }
}

// --- Taste: what you actually listen to ---

/// The weight of one play. Recent plays count more (half-life 30 days) and a play you stayed
/// for counts more than one you skipped; a song dropped within 30 seconds counts against it.
pub(crate) fn play_weight(p: &PlayLogEntry, now: u64) -> f32 {
    let age_days = now.saturating_sub(p.started_at) as f32 / 86_400.0;
    let recency = 0.5f32.powf(age_days / 30.0);
    let engagement = if p.completed {
        1.0
    } else if p.ms_played >= 60_000 {
        0.6
    } else if p.ms_played >= 30_000 {
        0.3
    } else {
        -0.4
    };
    (0.25 + 0.75 * recency) * engagement
}

/// What Halcyon has learned about your taste from the play log.
pub struct Taste {
    /// Song ids you really listen to, best first (only songs with a clearly positive score).
    pub songs: Vec<String>,
    /// Artists you really listen to, best first.
    pub artists: Vec<String>,
}

/// Learn your taste from listening, not from likes: every play is a vote (see `play_weight`).
/// A like is only a small extra vote on a song you also played, so a liked song you never
/// listen to does not make it into `songs`. Likes do add a little to an artist.
pub(crate) fn learn_taste(plays: &[PlayLogEntry], liked: &[Track], now: u64) -> Taste {
    let mut song_score: HashMap<String, f32> = HashMap::new();
    let mut artist_score: HashMap<String, (String, f32)> = HashMap::new();
    let mut bump_artist = |name: &str, w: f32| {
        let key = normalize_string(name);
        if key.is_empty() || key == "various artists" {
            return;
        }
        artist_score
            .entry(key)
            .or_insert_with(|| (name.trim().to_string(), 0.0))
            .1 += w;
    };
    for p in plays {
        let w = play_weight(p, now);
        *song_score.entry(p.track_id.clone()).or_insert(0.0) += w;
        bump_artist(&p.artist, w);
    }
    for t in liked {
        if let Some(s) = song_score.get_mut(&t.id) {
            if *s > 0.0 {
                *s += 0.3;
            }
        }
        bump_artist(&t.artist, 0.2);
    }

    let mut songs: Vec<(String, f32)> = song_score.into_iter().filter(|(_, s)| *s > 0.2).collect();
    songs.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.cmp(&b.0))
    });
    let mut artists: Vec<(String, f32)> = artist_score
        .into_values()
        .filter(|(_, s)| *s > 0.0)
        .collect();
    artists.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.cmp(&b.0))
    });
    Taste {
        songs: songs.into_iter().map(|(id, _)| id).collect(),
        artists: artists.into_iter().map(|(name, _)| name).collect(),
    }
}

/// Names of the artists Deezer lists as similar to `id`.
async fn deezer_related_artist_names(http: &reqwest::Client, id: u64, limit: u32) -> Vec<String> {
    let limit = limit.to_string();
    let Some(v) = deezer_get(http, &format!("/artist/{id}/related"), &[("limit", &limit)]).await
    else {
        return Vec::new();
    };
    v.get("data")
        .and_then(serde_json::Value::as_array)
        .map(|rows| {
            rows.iter()
                .filter_map(|r| r.get("name")?.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// How long the list of fresh releases for your sound is reused before the sources are asked again.
const FRESH_SOUND_TTL: u64 = 6 * 3600;

/// New music in your sound: the newest releases (last 120 days) of your top artists and of
/// artists that sound like them (Deezer's similar-artists list, a different pair each day).
/// Returns `(artist, album, release date)`; the list is kept for a few hours because it takes
/// a dozen requests to gather and Home is rebuilt several times while the big lists fill in.
async fn fresh_in_your_sound(
    cache: &Cache,
    http: &reqwest::Client,
    artists: &[String],
) -> Vec<OutsideAlbum> {
    let key = format!(
        "taste.fresh.v1.{}",
        artists
            .iter()
            .take(5)
            .cloned()
            .collect::<Vec<_>>()
            .join("|")
    );
    let to_albums = |rows: Vec<(String, String, String)>| -> Vec<OutsideAlbum> {
        rows.into_iter()
            .map(|(artist, title, release_date)| OutsideAlbum {
                artist,
                title,
                release_date,
                art: None,
            })
            .collect()
    };
    if let Ok(Some(item)) = cache.kv_get(&key) {
        if !item.is_stale {
            if let Ok(rows) = serde_json::from_str::<Vec<(String, String, String)>>(&item.item) {
                if !rows.is_empty() {
                    return to_albums(rows);
                }
            }
        }
    }

    let now = now_secs();
    let today = date_from_unix_secs(now);
    let cutoff = date_from_unix_secs(now.saturating_sub(120 * 86_400));
    let day = (now / 86_400) as usize;

    // (artist name, releases to take): your own artists first, then similar ones.
    let mut wanted: Vec<(String, usize)> = artists.iter().take(5).map(|a| (a.clone(), 2)).collect();
    for name in artists.iter().take(3) {
        let Some(id) = deezer_artist_id(http, name).await else {
            continue;
        };
        let related = deezer_related_artist_names(http, id, 8).await;
        if related.is_empty() {
            continue;
        }
        for i in 0..2 {
            if let Some(name) = related.get((day + i) % related.len()) {
                wanted.push((name.clone(), 1));
            }
        }
    }

    let mut seen_artists: HashSet<String> = HashSet::new();
    let mut rows: Vec<(String, String, String)> = Vec::new();
    for (name, take) in wanted {
        if !seen_artists.insert(normalize_string(&name)) {
            continue;
        }
        let mut albums = fetch_itunes_artist_albums(http, &name).await;
        albums.retain(|a| {
            a.release_date.as_str() <= today.as_str() && a.release_date.as_str() >= cutoff.as_str()
        });
        for a in albums.into_iter().take(take) {
            rows.push((a.artist, a.title, a.release_date));
        }
    }
    // Newest first, so the freshest songs lead the mix.
    rows.sort_by(|a, b| b.2.cmp(&a.2));
    if !rows.is_empty() {
        if let Ok(json) = serde_json::to_string(&rows) {
            let _ = cache.kv_set(&key, &json, FRESH_SOUND_TTL);
        }
    }
    to_albums(rows)
}

/// "Halcyon Mix": picked by Halcyon from what you actually play (not only what you liked),
/// blended one-for-one with new music in the same sound. Needs a little listening history.
async fn build_halcyon_mix(
    spotify: &SpotifyClient,
    cache: &Cache,
    http: &reqwest::Client,
    recent_24h_ids: &HashSet<String>,
) -> Option<MusicMix> {
    let now = now_secs();
    let plays = cache.get_recent_plays(5000).unwrap_or_default();
    if plays.len() < 5 {
        return None;
    }
    let liked: Vec<Track> = cache
        .get_liked_tracks(1000, 0)
        .map(|(t, _)| t)
        .unwrap_or_default();
    let taste = learn_taste(&plays, &liked, now);
    let played_ids: HashSet<String> = plays.iter().map(|p| p.track_id.clone()).collect();

    // The songs you listen to: your best 40, drawn in a different order each day.
    let mut known: Vec<Track> = taste
        .songs
        .iter()
        .take(40)
        .filter_map(|id| cache.get_track(id).ok().flatten())
        .collect();
    shuffle(&mut known, now / 86_400);
    let mut seen: HashSet<String> = HashSet::new();
    let familiar = filter_mix_tracks(known, 2, &mut seen, recent_24h_ids, false, 10);

    // New songs in your sound: one song from each fresh release, none you already played.
    let albums = fresh_in_your_sound(cache, http, &taste.artists).await;
    let cards = resolve_album_cards(spotify, cache, albums, 14, 24, "9999-99-99").await;
    let fresh: Vec<Track> = cards
        .into_iter()
        .filter_map(|c| c.tracks.into_iter().next())
        .filter(|t| !played_ids.contains(&t.id))
        .collect();
    let fresh = filter_mix_tracks(fresh, 2, &mut seen, &HashSet::new(), true, 10);

    // One of yours, one new, one of yours, one new ...
    let mut tracks: Vec<Track> = Vec::new();
    let (mut mine, mut new) = (familiar.into_iter(), fresh.into_iter());
    loop {
        let (a, b) = (mine.next(), new.next());
        if a.is_none() && b.is_none() {
            break;
        }
        tracks.extend(a);
        tracks.extend(b);
    }
    if tracks.len() < 6 {
        return None;
    }
    let art = tracks.first().and_then(|t| t.art_url.clone());
    Some(MusicMix {
        id: "halcyon-mix".to_string(),
        title: "Halcyon Mix".to_string(),
        description: "Picked from what you really play, blended with new music in your sound."
            .to_string(),
        source: "Halcyon Local".to_string(),
        tracks,
        art_url: art,
    })
}

/// Assemble the complete Home page feed from Spotify, outside services, and local cache.
pub async fn build_home_feed(
    spotify: &SpotifyClient,
    cache: &Cache,
    http: &reqwest::Client,
) -> HomeFeed {
    let greeting = get_greeting();
    SEARCH_BUDGET.fetch_max(SEARCHES_PER_BUILD, Ordering::Relaxed);
    let mut global_seen_track_ids = HashSet::new();

    // Once: earlier builds remembered an empty search answer as a permanent "no match", which
    // can leave Top 100 / Top 200 stuck on the few songs matched before. Look those up again.
    if cache
        .kv_get("purge.resolution-misses.v1")
        .ok()
        .flatten()
        .is_none()
    {
        match cache.purge_resolution_misses() {
            Ok(n) => tracing::info!("forgot {n} cached song misses so they are matched again"),
            Err(e) => warn!("could not forget cached song misses: {e}"),
        }
        let _ = cache.kv_set("purge.resolution-misses.v1", "done", 10 * 365 * 86_400);
    }

    // 1. Gather recent 24h play history for diversity filtering
    let recent_24h_cutoff = now_secs().saturating_sub(86_400);
    let recent_plays = cache.get_recent_plays(200).unwrap_or_default();
    let recent_24h_ids: HashSet<String> = recent_plays
        .into_iter()
        .filter(|p| p.started_at >= recent_24h_cutoff)
        .map(|p| p.track_id)
        .collect();

    // 2. User Shelves: Playlists & Saved Albums
    let (mut playlists, _) = cache.get_playlists(20, 0).unwrap_or_default();
    // A playlist with no cover of its own borrows the cover of its first cached song.
    for pl in playlists.iter_mut() {
        if pl.art_url.is_none() {
            if let Ok((first, _)) = cache.get_playlist_tracks(&pl.id, 1, 0) {
                pl.art_url = first.into_iter().next().and_then(|t| t.art_url);
            }
        }
    }
    let saved_albums = spotify
        .get_saved_albums(20, 0)
        .await
        .map(|p| p.items)
        .unwrap_or_default();

    // 3. Jump Back In: Merge Spotify recently-played with local play_log
    let mut jump_back_in = Vec::new();
    let mut seen_contexts = HashSet::new();

    if let Ok(sp_recent) = spotify.get_recently_played(20).await {
        for t in sp_recent {
            if let Some(ref alb_id) = t.album_id {
                if !seen_contexts.contains(alb_id) {
                    seen_contexts.insert(alb_id.clone());
                    jump_back_in.push(ShelfItem {
                        id: alb_id.clone(),
                        title: t.album.clone(),
                        subtitle: format!("Album • {}", t.artist),
                        art_url: t.art_url.clone(),
                        uri: format!("spotify:album:{alb_id}"),
                        context_type: "album".to_string(),
                        tracks: vec![t],
                    });
                }
            }
        }
    }

    // Complement with local play log if Spotify returned fewer than 6
    if jump_back_in.len() < 6 {
        for p in cache.get_recent_plays(50).unwrap_or_default() {
            if !seen_contexts.contains(&p.album) {
                seen_contexts.insert(p.album.clone());
                // The cached track carries the cover and lets the card play the song.
                let cached = cache.get_track(&p.track_id).ok().flatten();
                jump_back_in.push(ShelfItem {
                    id: p.track_id.clone(),
                    title: p.album.clone(),
                    subtitle: format!("Recently Played • {}", p.artist),
                    art_url: cached.as_ref().and_then(|t| t.art_url.clone()),
                    uri: format!("spotify:track:{}", p.track_id),
                    context_type: "track".to_string(),
                    tracks: cached.into_iter().collect(),
                });
                if jump_back_in.len() >= 8 {
                    break;
                }
            }
        }
    }

    // 4. Made For You: Tier 3 Local Mixes + Tier 2 Outside Mixes
    let mut made_for_you = Vec::new();

    // (a) "On Repeat" (Local play log, 30-day top)
    if let Ok(on_repeat_raw) = cache.get_on_repeat(30) {
        let on_repeat_tracks = filter_mix_tracks(
            on_repeat_raw,
            3,
            &mut global_seen_track_ids,
            &recent_24h_ids,
            true, // allow recently played since it IS On Repeat
            15,
        );
        if !on_repeat_tracks.is_empty() {
            let art = on_repeat_tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "on-repeat".to_string(),
                title: "On Repeat".to_string(),
                description: "The tracks you have had on continuous loop this month.".to_string(),
                source: "Halcyon Local".to_string(),
                tracks: on_repeat_tracks,
                art_url: art,
            });
        }
    }

    // (b) "Rediscover" (Liked songs not heard in 90+ days)
    if let Ok(rediscover_raw) = cache.get_rediscover(30) {
        let rediscover_tracks = filter_mix_tracks(
            rediscover_raw,
            2,
            &mut global_seen_track_ids,
            &recent_24h_ids,
            false,
            15,
        );
        if !rediscover_tracks.is_empty() {
            let art = rediscover_tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "rediscover".to_string(),
                title: "Rediscover".to_string(),
                description: "Favorites from your liked library waiting to be heard again."
                    .to_string(),
                source: "Halcyon Local".to_string(),
                tracks: rediscover_tracks,
                art_url: art,
            });
        }
    }

    // (c) "Time-of-day mix"
    let current_hour = get_hour_of_day();
    if let Ok(tod_raw) = cache.get_time_of_day_tracks(current_hour, 30) {
        let tod_tracks = filter_mix_tracks(
            tod_raw,
            2,
            &mut global_seen_track_ids,
            &recent_24h_ids,
            false,
            15,
        );
        if !tod_tracks.is_empty() {
            let art = tod_tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "time-of-day".to_string(),
                title: format!("{greeting} Mix"),
                description: "Selected songs tuned to your usual listening rhythm at this hour."
                    .to_string(),
                source: "Halcyon Local".to_string(),
                tracks: tod_tracks,
                art_url: art,
            });
        }
    }

    // (d) "Because you played <Top Artist>"
    if let Ok(top_artists) = cache.get_top_artists_in_period(7, 3) {
        if let Some(fav_artist) = top_artists.first() {
            if let Ok(artist_tracks) = cache.get_tracks_by_artist(fav_artist, 20) {
                let filtered = filter_mix_tracks(
                    artist_tracks,
                    4,
                    &mut global_seen_track_ids,
                    &recent_24h_ids,
                    false,
                    12,
                );
                if !filtered.is_empty() {
                    let art = filtered.first().and_then(|t| t.art_url.clone());
                    made_for_you.push(MusicMix {
                        id: format!("because-{}", fav_artist.to_lowercase().replace(' ', "-")),
                        title: format!("Because you played {fav_artist}"),
                        description: format!("More deep cuts and saved gems by {fav_artist}."),
                        source: "Halcyon Local".to_string(),
                        tracks: filtered,
                        art_url: art,
                    });
                }
            }
        }
    }

    // (d2) Mix It Up, Hidden Gems, All-Time Best: built from your own library and play log,
    // so they need no Spotify lookups and appear at once, even while Spotify rate limits us.
    let liked_all: Vec<Track> = cache
        .get_liked_tracks(1000, 0)
        .map(|(t, _)| t)
        .unwrap_or_default();
    let play_counts = cache.get_play_counts().unwrap_or_default();
    // The seed changes every hour, so a refresh later in the day gives a new draw.
    let seed = now_secs() / 3600;

    // "Mix It Up": one song per artist, drawn at random across the whole liked library.
    {
        let mut pool = liked_all.clone();
        shuffle(&mut pool, seed);
        let mut artists_seen = HashSet::new();
        let one_per_artist: Vec<Track> = pool
            .into_iter()
            .filter(|t| artists_seen.insert(t.artist.to_lowercase()))
            .collect();
        let tracks = filter_mix_tracks(
            one_per_artist,
            1,
            &mut global_seen_track_ids,
            &recent_24h_ids,
            false,
            20,
        );
        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "mix-it-up".to_string(),
                title: "Mix It Up".to_string(),
                description: "One song each from many of your artists, drawn fresh every hour."
                    .to_string(),
                source: "Halcyon Local".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // "Hidden Gems": liked songs you have barely played, by artists you have few songs from.
    {
        let mut per_artist: HashMap<String, u32> = HashMap::new();
        for t in &liked_all {
            *per_artist.entry(t.artist.to_lowercase()).or_insert(0) += 1;
        }
        let mut gems: Vec<Track> = liked_all
            .iter()
            .filter(|t| {
                play_counts.get(&t.id).copied().unwrap_or(0) <= 1
                    && per_artist
                        .get(&t.artist.to_lowercase())
                        .copied()
                        .unwrap_or(0)
                        <= 2
            })
            .cloned()
            .collect();
        shuffle(&mut gems, seed.wrapping_add(7));
        // Rarest artists first; the shuffle above decides the order among equals.
        gems.sort_by_key(|t| {
            per_artist
                .get(&t.artist.to_lowercase())
                .copied()
                .unwrap_or(0)
        });
        let tracks = filter_mix_tracks(
            gems,
            1,
            &mut global_seen_track_ids,
            &recent_24h_ids,
            false,
            15,
        );
        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "hidden-gems".to_string(),
                title: "Hidden Gems".to_string(),
                description: "Songs you saved but barely played, by artists you rarely hear."
                    .to_string(),
                source: "Halcyon Local".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // "Remember the Past": songs you played a lot a while ago and have not heard for weeks.
    // With little history yet, your oldest likes fill it up.
    {
        let mut pool = cache.get_past_favorites(60, 45).unwrap_or_default();
        if pool.len() < 15 {
            let mut oldest = liked_all.clone();
            oldest.reverse();
            pool.extend(oldest);
        }
        let tracks = filter_mix_tracks(pool, 2, &mut HashSet::new(), &recent_24h_ids, false, 25);
        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "remember-the-past".to_string(),
                title: "Remember the Past".to_string(),
                description: "Songs you used to play on loop and have not heard in a while."
                    .to_string(),
                source: "Halcyon Local".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // "Liked & Loved": songs you liked and then really played, most played first.
    {
        let mut loved: Vec<Track> = liked_all
            .iter()
            .filter(|t| play_counts.get(&t.id).copied().unwrap_or(0) >= 2)
            .cloned()
            .collect();
        loved.sort_by_key(|t| std::cmp::Reverse(play_counts.get(&t.id).copied().unwrap_or(0)));
        let tracks = filter_mix_tracks(loved, 2, &mut HashSet::new(), &recent_24h_ids, true, 25);
        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "liked-and-loved".to_string(),
                title: "Liked & Loved".to_string(),
                description: "The songs you liked and kept coming back to.".to_string(),
                source: "Halcyon Local".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // "Fresh Likes": what you liked most recently (Liked Songs is stored newest first).
    {
        let recent: Vec<Track> = liked_all.iter().take(60).cloned().collect();
        let tracks = filter_mix_tracks(recent, 2, &mut HashSet::new(), &recent_24h_ids, true, 25);
        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "fresh-likes".to_string(),
                title: "Fresh Likes".to_string(),
                description: "Your newest liked songs, all in one place.".to_string(),
                source: "Halcyon Local".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // Halcyon Mix: the headline mix of "Made for you", first on the shelf. It keeps its own
    // list of seen songs, so building it does not empty On Repeat and the other mixes.
    if let Some(mix) = build_halcyon_mix(spotify, cache, http, &recent_24h_ids).await {
        made_for_you.insert(0, mix);
    }

    // (e) Tier 2: Deezer Top Chart Mix (Resolved to Spotify)
    let deezer_entries = fetch_deezer_top_tracks(http).await;
    if !deezer_entries.is_empty() {
        let mut deezer_resolved = Vec::new();
        for (artist, title, dur) in deezer_entries {
            if deezer_resolved.len() >= 15 {
                break;
            }
            if let Some(t) = resolve_outside_track(spotify, cache, &artist, &title, dur).await {
                deezer_resolved.push(t);
            }
        }

        let deezer_tracks = filter_mix_tracks(
            deezer_resolved,
            2,
            &mut global_seen_track_ids,
            &recent_24h_ids,
            true,
            12,
        );

        if !deezer_tracks.is_empty() {
            let art = deezer_tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "deezer-global-chart".to_string(),
                title: "Global Hitlist".to_string(),
                description: "Worldwide viral sensations and charting tracks, resolved to Spotify."
                    .to_string(),
                source: "Deezer".to_string(),
                tracks: deezer_tracks,
                art_url: art,
            });
        }
    }

    // (f) Hot new releases: the most popular song of each fresh album (Deezer editorial).
    {
        let mut entries = fetch_deezer_new_release_songs(http).await;
        let from_deezer = !entries.is_empty();
        if !from_deezer {
            // Deezer's editorial releases are empty in some regions: use what listeners play this week.
            entries = fetch_listenbrainz_trending(http).await;
        }
        let resolved = resolve_many(spotify, cache, entries, 14, 24).await;
        let tracks = filter_mix_tracks(
            resolved,
            1,
            &mut global_seen_track_ids,
            &recent_24h_ids,
            true,
            12,
        );
        if tracks.is_empty() {
            warn!("Hot/Trending mix is empty: no song could be matched on Spotify");
        } else {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: if from_deezer {
                    "hot-new-releases"
                } else {
                    "trending-week"
                }
                .to_string(),
                title: if from_deezer {
                    "Hot New Releases"
                } else {
                    "Trending This Week"
                }
                .to_string(),
                description: if from_deezer {
                    "The lead song of this week's freshest albums and singles.".to_string()
                } else {
                    "What ListenBrainz listeners are playing most this week.".to_string()
                },
                source: if from_deezer {
                    "Deezer"
                } else {
                    "ListenBrainz"
                }
                .to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // (g) One chart mix per genre, so the shelf is not all one sound.
    {
        let mut set = tokio::task::JoinSet::new();
        for &(gid, _, _) in DEEZER_GENRES {
            let h = http.clone();
            set.spawn(async move { (gid, fetch_deezer_genre_chart(&h, gid, 20).await) });
        }
        let mut charts: std::collections::HashMap<u32, Vec<(String, String, Option<u64>)>> =
            std::collections::HashMap::new();
        while let Some(done) = set.join_next().await {
            if let Ok((gid, rows)) = done {
                charts.insert(gid, rows);
            }
        }
        for &(gid, label, mix_id) in DEEZER_GENRES {
            let rows = charts.remove(&gid).unwrap_or_default();
            if rows.is_empty() {
                continue;
            }
            let resolved = resolve_many(spotify, cache, rows, 10, 14).await;
            let tracks = filter_mix_tracks(
                resolved,
                2,
                &mut global_seen_track_ids,
                &recent_24h_ids,
                true,
                10,
            );
            if tracks.is_empty() {
                continue;
            }
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: format!("top-{mix_id}"),
                title: format!("Top {label}"),
                description: format!("What is charting in {label} right now."),
                source: "Deezer".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // "Top 100" and "Top 200": the biggest songs of the last three months, widening to earlier
    // months only when the list would otherwise fall short (see `fetch_chart_pool`). Only songs
    // already matched on Spotify are used, so Home is not held up; `warm_big_lists_step` matches the
    // rest in the background and Home is rebuilt when it is done. These two lists skip the
    // per-artist limit and the played-today filter on purpose: a chart is a chart.
    {
        let pool = fetch_chart_pool(http).await;
        let matched = resolve_many_cached(cache, &pool, TOP_BIG);
        for (size, id) in [(100usize, "top-100"), (TOP_BIG, "top-200")] {
            let tracks: Vec<Track> = matched.iter().take(size).cloned().collect();
            if tracks.len() < 10 {
                continue;
            }
            let description = if tracks.len() >= size {
                format!("The {size} biggest songs of the last three months, widened to earlier months when short.")
            } else {
                format!(
                    "The biggest songs of the moment. Filling up: {} of {size} matched so far.",
                    tracks.len()
                )
            };
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: id.to_string(),
                title: format!("Top {size}"),
                description,
                source: "Deezer".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // "All-Time Best": only the biggest songs ever, the Billboard chart-toppers and the songs
    // with billions of streams and views, up to 50 of them, a different draw each day. It holds
    // none of your own plays (those have their own mixes above). Like the charts it reads only
    // songs already matched on Spotify; `warm_big_lists_step` fills the rest in.
    {
        let candidates = all_time_candidates();
        let matched = resolve_many_cached(cache, &candidates, ALL_TIME_SIZE + 10);
        let tracks = filter_mix_tracks(
            matched,
            2,
            &mut HashSet::new(),
            &HashSet::new(),
            true,
            ALL_TIME_SIZE,
        );

        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            // It is for discovering, not one of your own mixes, so it sits in Discover
            // (any source but "Halcyon Local"), after Top 100 and Top 200.
            made_for_you.push(MusicMix {
                id: "all-time-best".to_string(),
                title: "All-Time Best".to_string(),
                description:
                    "The biggest songs ever: chart-toppers with billions of streams and views."
                        .to_string(),
                source: "Halcyon".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // 5. Popular Right Now: Charts shelf
    let mut popular_charts = Vec::new();
    if let Some(chart_mix) = made_for_you.iter().find(|m| m.id == "deezer-global-chart") {
        for t in &chart_mix.tracks {
            popular_charts.push(ShelfItem {
                id: t.id.clone(),
                title: t.title.clone(),
                subtitle: t.artist.clone(),
                art_url: t.art_url.clone(),
                uri: t.uri.clone(),
                context_type: "track".to_string(),
                tracks: vec![t.clone()],
            });
            if popular_charts.len() >= 10 {
                break;
            }
        }
    }

    // 6. New from Artists You Follow
    let mut new_releases = Vec::new();
    if let Ok(followed) = spotify.get_followed_artists(8).await {
        for artist in followed {
            if let Ok(albums) = spotify.get_artist_albums(&artist.id, 2).await {
                for alb in albums {
                    new_releases.push(ShelfItem {
                        id: alb.id.clone(),
                        title: alb.title,
                        subtitle: format!("New • {}", alb.artist),
                        art_url: alb.art_url,
                        uri: alb.uri,
                        context_type: "album".to_string(),
                        tracks: vec![],
                    });
                }
            }
        }
    }

    // ListenBrainz fresh releases row
    let mut fresh_releases = Vec::new();
    let lb_releases = fetch_listenbrainz_fresh_releases(http).await;
    for (art_name, rel_name) in lb_releases {
        if fresh_releases.len() >= 8 {
            break;
        }
        if let Some(track) = resolve_outside_track(spotify, cache, &art_name, &rel_name, None).await
        {
            fresh_releases.push(ShelfItem {
                id: track.id.clone(),
                title: rel_name,
                subtitle: format!("Fresh • {art_name}"),
                art_url: track.art_url.clone(),
                uri: track.uri.clone(),
                context_type: "track".to_string(),
                tracks: vec![track],
            });
        }
    }

    // 7. Greeting + Quick Picks (6-8 big tiles)
    let mut quick_picks = Vec::new();

    // Tile 1: Liked Songs
    let (liked_sample, liked_total) = cache.get_liked_tracks(20, 0).unwrap_or_default();
    if liked_total > 0 {
        let art = liked_sample.first().and_then(|t| t.art_url.clone());
        quick_picks.push(QuickPick {
            id: "liked-songs".to_string(),
            title: "Liked Songs".to_string(),
            subtitle: format!("{liked_total} tracks"),
            art_url: art,
            uri: "spotify:collection:tracks".to_string(),
            tracks: liked_sample,
        });
    }

    // Tiles 2-4: Top Playlists
    for pl in playlists.iter().take(4) {
        quick_picks.push(QuickPick {
            id: pl.id.clone(),
            title: pl.name.clone(),
            subtitle: format!("Playlist • {}", pl.owner),
            art_url: pl.art_url.clone(),
            uri: pl.uri.clone(),
            tracks: vec![],
        });
    }

    // Tiles 5-8: Generated Mixes
    for mix in made_for_you.iter().take(3) {
        quick_picks.push(QuickPick {
            id: mix.id.clone(),
            title: mix.title.clone(),
            subtitle: format!("Mix • {}", mix.source),
            art_url: mix.art_url.clone(),
            uri: format!("halcyon:mix:{}", mix.id),
            tracks: mix.tracks.clone(),
        });
    }

    // 8. Capsule Preview
    let capsule_preview = cache.get_capsule_summary().unwrap_or(None);

    HomeFeed {
        greeting,
        quick_picks,
        jump_back_in,
        new_releases,
        fresh_releases,
        made_for_you,
        popular_charts,
        playlists,
        saved_albums,
        capsule_preview,
        mix_meta: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rank_artists_counts_plays_then_likes() {
        let song = |artist: &str, n: u32| {
            Track::simple(
                format!("id{n}"),
                "t".into(),
                artist.into(),
                "a".into(),
                1000,
            )
        };
        let liked = vec![
            song("Beta", 1),
            song("Beta", 2),
            song("Gamma", 3),
            song("Various Artists", 4),
        ];
        let played = vec!["Alpha".to_string()];
        assert_eq!(
            rank_artists(&played, &liked, 5),
            vec!["Alpha", "Beta", "Gamma"]
        );
        assert_eq!(rank_artists(&played, &liked, 2), vec!["Alpha", "Beta"]);
        assert!(rank_artists(&[], &[], 5).is_empty());
    }

    fn play(
        id: &str,
        artist: &str,
        started_at: u64,
        ms_played: u64,
        completed: bool,
    ) -> PlayLogEntry {
        PlayLogEntry {
            id: 0,
            track_id: id.to_string(),
            title: id.to_string(),
            artist: artist.to_string(),
            album: "Album".to_string(),
            started_at,
            ms_played,
            completed,
        }
    }

    #[test]
    fn test_learn_taste_listening_beats_likes() {
        let now = 100 * 86_400;
        let plays = vec![
            play("a", "Alpha", now, 200_000, true),
            play("a", "Alpha", now - 86_400, 200_000, true),
            play("a", "Alpha", now - 2 * 86_400, 200_000, true),
            play("b", "Beta", now, 4_000, false), // skipped at once
        ];
        let liked = vec![Track::simple(
            "c".into(),
            "t".into(),
            "Gamma".into(),
            "x".into(),
            1000,
        )];
        let taste = learn_taste(&plays, &liked, now);
        // Only the song you really listened to; the skipped one and the never-played like are out.
        assert_eq!(taste.songs, vec!["a"]);
        assert_eq!(taste.artists.first().map(String::as_str), Some("Alpha"));
        // A like still says something about an artist.
        assert!(taste.artists.iter().any(|a| a == "Gamma"));
        assert!(!taste.artists.iter().any(|a| a == "Beta"));
    }

    #[test]
    fn test_play_weight_recent_and_finished_count_more() {
        let now = 200 * 86_400;
        let fresh_done = play_weight(&play("a", "A", now, 180_000, true), now);
        let old_done = play_weight(&play("a", "A", now - 120 * 86_400, 180_000, true), now);
        let half = play_weight(&play("a", "A", now, 70_000, false), now);
        let skip = play_weight(&play("a", "A", now, 3_000, false), now);
        assert!(fresh_done > old_done && old_done > 0.0);
        assert!(fresh_done > half && half > 0.0);
        assert!(skip < 0.0);
    }

    #[test]
    fn test_short_date_trims_timestamps() {
        assert_eq!(short_date("2026-10-30T07:00:00Z"), "2026-10-30");
        assert_eq!(short_date("2026-10"), "2026-10");
    }

    #[test]
    fn test_date_from_unix_secs() {
        assert_eq!(date_from_unix_secs(0), "1970-01-01");
        assert_eq!(date_from_unix_secs(1_700_000_000), "2023-11-14");
        // 29 February of a leap year.
        assert_eq!(date_from_unix_secs(1_709_164_800), "2024-02-29");
    }

    #[test]
    fn test_normalize_string_strips_brackets() {
        assert_eq!(
            normalize_string("Starboy (feat. Daft Punk) - Remastered"),
            "starboy"
        );
        assert_eq!(
            normalize_string("Blinding Lights [Club Mix]"),
            "blinding lights"
        );
    }

    #[test]
    fn test_token_similarity() {
        assert_eq!(token_similarity("blinding lights", "blinding lights"), 1.0);
        assert!(token_similarity("blinding lights", "lights") > 0.4);
        assert_eq!(token_similarity("hello world", "goodbye moon"), 0.0);
    }

    #[test]
    fn test_score_track_match() {
        let candidate = Track::simple(
            "t1".into(),
            "Starboy (feat. Daft Punk)".into(),
            "The Weeknd".into(),
            "Starboy".into(),
            230_000,
        );

        let score = score_track_match(&candidate, "The Weeknd", "Starboy", Some(231_000));
        assert!(score >= 0.85, "Expected high score >= 0.85, got {score}");

        let bad_score = score_track_match(&candidate, "Drake", "Hotline Bling", Some(260_000));
        assert!(bad_score < 0.3, "Expected low score, got {bad_score}");
    }

    #[test]
    fn test_filter_mix_tracks_diversity() {
        let t1 = Track::simple(
            "1".into(),
            "Song 1".into(),
            "Artist A".into(),
            "Alb".into(),
            100,
        );
        let t2 = Track::simple(
            "2".into(),
            "Song 2".into(),
            "Artist A".into(),
            "Alb".into(),
            100,
        );
        let t3 = Track::simple(
            "3".into(),
            "Song 3".into(),
            "Artist A".into(),
            "Alb".into(),
            100,
        );
        let t4 = Track::simple(
            "4".into(),
            "Song 4".into(),
            "Artist B".into(),
            "Alb".into(),
            100,
        );
        let t5 = Track::simple(
            "5".into(),
            "Song 5".into(),
            "Artist C".into(),
            "Alb".into(),
            100,
        );

        let mut global_seen = HashSet::new();
        let mut recent_24h = HashSet::new();
        recent_24h.insert("5".to_string()); // Track 5 played in last 24h

        let candidates = vec![t1, t2, t3, t4, t5];
        let filtered = filter_mix_tracks(candidates, 2, &mut global_seen, &recent_24h, false, 10);

        // Max 2 for Artist A: so only 2 of t1, t2, t3 are included
        let artist_a_count = filtered.iter().filter(|t| t.artist == "Artist A").count();
        assert_eq!(artist_a_count, 2);

        // Track 4 (Artist B) should be included
        assert!(filtered.iter().any(|t| t.id == "4"));

        // Track 5 (recent 24h) should be skipped
        assert!(!filtered.iter().any(|t| t.id == "5"));

        // Global seen should contain the accepted tracks
        assert_eq!(global_seen.len(), 3);
    }
}
