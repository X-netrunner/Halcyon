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
use crate::cache::Cache;
use crate::token_store::now_secs;
use halcyon_music_core::models::{
    HomeFeed, MusicMix, QuickPick, ShelfItem, Track,
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
const SEARCHES_PER_BUILD: u32 = 24;

/// Resolve an outside track (artist + title) to a Spotify track via search with SQLite resolution cache.
pub async fn resolve_outside_track(
    spotify: &SpotifyClient,
    cache: &Cache,
    artist: &str,
    title: &str,
    duration_ms: Option<u64>,
) -> Option<Track> {
    let query_key = format!("{} - {}", artist.trim().to_lowercase(), title.trim().to_lowercase());

    // 1. Check cache
    if let Ok(Some(cached_res)) = cache.get_resolved_track(&query_key) {
        return cached_res; // Some(track) on hit, None on cached miss
    }

    // 2. Query Spotify search (capped at 10 results), within the budget and not while paused
    if now_secs() < SEARCH_PAUSED_UNTIL.load(Ordering::Relaxed) {
        return None;
    }
    let had_budget = SEARCH_BUDGET
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_sub(1))
        .is_ok();
    if !had_budget {
        return None;
    }
    // Space uncached searches out: Spotify's limit is a short rolling window, and a burst of
    // lookups on top of the start-up calls is what trips it.
    tokio::time::sleep(Duration::from_millis(600)).await;
    let search_q = format!("{artist} {title}");
    match spotify.search_tracks(&search_q, 10, 0).await {
        Ok(page) => {
            let mut best_track: Option<Track> = None;
            let mut best_score = 0.0f32;

            for t in page.items {
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
                let _ = cache.put_resolved_track(&query_key, None);
                None
            }
        }
        Err(e) => {
            // Rate limited: wait as long as Spotify asked (1 min to 1 h). Cooling down: a minute.
            // Anything else (a dropped connection, a timeout): a short pause only.
            let pause = match &e {
                crate::api::ApiError::RateLimited(secs) => (*secs).clamp(60, 3600),
                crate::api::ApiError::CircuitOpen { .. } => 60,
                _ => 20,
            };
            warn!("Spotify search resolution failed for {query_key}: {e}; pausing lookups for {pause}s");
            SEARCH_PAUSED_UNTIL.fetch_max(now_secs() + pause, Ordering::Relaxed);
            None
        }
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
    let resp = http
        .get(url)
        .timeout(Duration::from_secs(6))
        .send()
        .await;

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
    let resp = http
        .get(url)
        .timeout(Duration::from_secs(6))
        .send()
        .await;

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
pub async fn fetch_listenbrainz_trending(http: &reqwest::Client) -> Vec<(String, String, Option<u64>)> {
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
    v["payload"]["recordings"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|r| {
                    Some((
                        r["artist_name"].as_str()?.to_string(),
                        r["track_name"].as_str()?.to_string(),
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
) -> Vec<(String, String, Option<u64>)> {
    let url = format!("https://api.deezer.com/chart/{genre_id}/tracks?limit=20");
    match http.get(url).timeout(Duration::from_secs(6)).send().await {
        Ok(res) if res.status().is_success() => match res.json::<DeezerChartResponse>().await {
            Ok(parsed) => parsed
                .data
                .or_else(|| parsed.tracks.and_then(|t| t.data))
                .unwrap_or_default()
                .into_iter()
                .map(|t| (t.artist.name, t.title, t.duration.map(|d| d * 1000)))
                .take(20)
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

/// Deezer's editorial "new releases": for each of the latest albums, its most popular song.
/// Returns `(artist, title, duration_ms)` rows ready to be matched on Spotify.
pub async fn fetch_deezer_new_release_songs(http: &reqwest::Client) -> Vec<(String, String, Option<u64>)> {
    let albums = match http
        .get("https://api.deezer.com/editorial/0/releases?limit=20")
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
    for album in albums.into_iter().take(14) {
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
            out.push((album.artist.name, t.title, t.duration.map(|d| d * 1000)));
        }
    }
    out
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
    let mut out = Vec::new();
    for (artist, title, dur) in entries.into_iter().take(max_tries) {
        if out.len() >= want {
            break;
        }
        if let Some(t) = resolve_outside_track(spotify, cache, &artist, &title, dur).await {
            out.push(t);
        }
    }
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

/// Assemble the complete Home page feed from Spotify, outside services, and local cache.
pub async fn build_home_feed(
    spotify: &SpotifyClient,
    cache: &Cache,
    http: &reqwest::Client,
) -> HomeFeed {
    let greeting = get_greeting();
    SEARCH_BUDGET.store(SEARCHES_PER_BUILD, Ordering::Relaxed);
    let mut global_seen_track_ids = HashSet::new();

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
                description: "Favorites from your liked library waiting to be heard again.".to_string(),
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
                description: "Selected songs tuned to your usual listening rhythm at this hour.".to_string(),
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
    let liked_all: Vec<Track> = cache.get_liked_tracks(1000, 0).map(|(t, _)| t).unwrap_or_default();
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
        let tracks = filter_mix_tracks(one_per_artist, 1, &mut global_seen_track_ids, &recent_24h_ids, false, 20);
        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "mix-it-up".to_string(),
                title: "Mix It Up".to_string(),
                description: "One song each from many of your artists, drawn fresh every hour.".to_string(),
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
                    && per_artist.get(&t.artist.to_lowercase()).copied().unwrap_or(0) <= 2
            })
            .cloned()
            .collect();
        shuffle(&mut gems, seed.wrapping_add(7));
        // Rarest artists first; the shuffle above decides the order among equals.
        gems.sort_by_key(|t| per_artist.get(&t.artist.to_lowercase()).copied().unwrap_or(0));
        let tracks = filter_mix_tracks(gems, 1, &mut global_seen_track_ids, &recent_24h_ids, false, 15);
        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "hidden-gems".to_string(),
                title: "Hidden Gems".to_string(),
                description: "Songs you saved but barely played, by artists you rarely hear.".to_string(),
                source: "Halcyon Local".to_string(),
                tracks,
                art_url: art,
            });
        }
    }

    // "All-Time Best": your most played songs ever. It may repeat songs from On Repeat.
    if let Ok(top_raw) = cache.get_all_time_top(40) {
        let mut own_seen = HashSet::new();
        let tracks = filter_mix_tracks(top_raw, 2, &mut own_seen, &recent_24h_ids, true, 20);
        if tracks.len() >= 5 {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: "all-time-best".to_string(),
                title: "All-Time Best".to_string(),
                description: "The songs you have played most, ever.".to_string(),
                source: "Halcyon Local".to_string(),
                tracks,
                art_url: art,
            });
        }
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
                description: "Worldwide viral sensations and charting tracks, resolved to Spotify.".to_string(),
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
        let tracks = filter_mix_tracks(resolved, 1, &mut global_seen_track_ids, &recent_24h_ids, true, 12);
        if tracks.is_empty() {
            warn!("Hot/Trending mix is empty: no song could be matched on Spotify");
        } else {
            let art = tracks.first().and_then(|t| t.art_url.clone());
            made_for_you.push(MusicMix {
                id: if from_deezer { "hot-new-releases" } else { "trending-week" }.to_string(),
                title: if from_deezer { "Hot New Releases" } else { "Trending This Week" }.to_string(),
                description: if from_deezer {
                    "The lead song of this week's freshest albums and singles.".to_string()
                } else {
                    "What ListenBrainz listeners are playing most this week.".to_string()
                },
                source: if from_deezer { "Deezer" } else { "ListenBrainz" }.to_string(),
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
            set.spawn(async move { (gid, fetch_deezer_genre_chart(&h, gid).await) });
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
            let tracks = filter_mix_tracks(resolved, 2, &mut global_seen_track_ids, &recent_24h_ids, true, 10);
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
        if let Some(track) = resolve_outside_track(spotify, cache, &art_name, &rel_name, None).await {
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let t1 = Track::simple("1".into(), "Song 1".into(), "Artist A".into(), "Alb".into(), 100);
        let t2 = Track::simple("2".into(), "Song 2".into(), "Artist A".into(), "Alb".into(), 100);
        let t3 = Track::simple("3".into(), "Song 3".into(), "Artist A".into(), "Alb".into(), 100);
        let t4 = Track::simple("4".into(), "Song 4".into(), "Artist B".into(), "Alb".into(), 100);
        let t5 = Track::simple("5".into(), "Song 5".into(), "Artist C".into(), "Alb".into(), 100);

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

