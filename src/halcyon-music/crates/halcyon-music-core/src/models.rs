//! Typed domain models shared between daemon and GUI.

use serde::{Deserialize, Serialize};

/// Extended track model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub artists: Vec<String>,
    pub album: String,
    #[serde(default)]
    pub album_id: Option<String>,
    pub duration_ms: u64,
    pub art_url: Option<String>,
    #[serde(default)]
    pub uri: String,
}

impl Track {
    pub fn simple(
        id: String,
        title: String,
        artist: String,
        album: String,
        duration_ms: u64,
    ) -> Self {
        let uri = format!("spotify:track:{id}");
        Self {
            id,
            title,
            artist: artist.clone(),
            artists: vec![artist],
            album,
            album_id: None,
            duration_ms,
            art_url: None,
            uri,
        }
    }
}

/// Spotify album model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub art_url: Option<String>,
    #[serde(default)]
    pub release_date: Option<String>,
    #[serde(default)]
    pub total_tracks: u32,
    #[serde(default)]
    pub uri: String,
}

/// Spotify artist model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub image_url: Option<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub uri: String,
}

/// Spotify playlist model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub owner: String,
    #[serde(default)]
    pub snapshot_id: Option<String>,
    pub art_url: Option<String>,
    #[serde(default)]
    pub total_tracks: u32,
    #[serde(default)]
    pub uri: String,
}

/// Spotify Connect playback device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub device_type: String,
    pub is_active: bool,
    pub volume_percent: Option<u32>,
}

/// Generic page container.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub total: usize,
    pub limit: usize,
    pub offset: usize,
    pub next: Option<String>,
    pub previous: Option<String>,
}

impl<T> Page<T> {
    pub fn empty(limit: usize, offset: usize) -> Self {
        Self {
            items: Vec::new(),
            total: 0,
            limit,
            offset,
            next: None,
            previous: None,
        }
    }
}

/// User authentication status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum AuthStatus {
    LoggedOut,
    LoggingIn {
        auth_url: String,
    },
    LoggedIn {
        user_id: Option<String>,
        display_name: Option<String>,
    },
    Error {
        message: String,
    },
}

/// Which token the Web API (browsing) uses. Streaming always uses librespot's own token.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub enum AuthMode {
    /// Default: the token from librespot's own browser sign-in serves browsing and streaming.
    #[default]
    #[serde(rename = "librespot")]
    Librespot,
    /// Advanced: browse with the user's own Client ID (PKCE). Streaming still uses librespot's token.
    #[serde(rename = "own-client-id")]
    OwnClientId,
}

/// Probe status of an API endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ProbeStatus {
    Available,
    Unavailable { code: u16 },
    Unknown,
}

/// Status record for a probed Spotify endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EndpointProbe {
    pub endpoint: String,
    pub status: ProbeStatus,
    pub checked_at: u64,
    pub detail: Option<String>,
}

/// A tile in the Greeting + Quick Picks grid for one-click play.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuickPick {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub art_url: Option<String>,
    pub uri: String,
    pub tracks: Vec<Track>,
}

/// A generic horizontal shelf card (album, playlist, or context).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShelfItem {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    pub art_url: Option<String>,
    pub uri: String,
    pub context_type: String, // "album", "playlist", "artist"
    #[serde(default)]
    pub tracks: Vec<Track>,
}

/// A generated mix with source attribution and one-click play/save.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MusicMix {
    pub id: String,
    pub title: String,
    pub description: String,
    pub source: String, // "Spotify", "ListenBrainz", "Deezer", "Halcyon Local", "Community"
    pub tracks: Vec<Track>,
    pub art_url: Option<String>,
}

/// Part 6: the words and the schedule that go with one generated mix. Kept apart from
/// [`MusicMix`] so that struct stays as it is; a client matches the two by `mix_id`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct MixMeta {
    pub mix_id: String,
    /// `daily_mix`, `discover_weekly`, `release_radar`, `on_repeat`, `repeat_rewind`, `daylist`,
    /// `radio` or `smart_shuffle`. A client treats a kind it does not know as a plain mix.
    pub kind: String,
    /// One line that says why the mix is what it is: "Because you've been playing X and Y".
    pub reason: String,
    /// One line per song, same order as the mix's songs.
    pub reasons: Vec<String>,
    /// Which songs are exploration slots (artists you have not played), same order.
    pub explore: Vec<bool>,
    /// Unix seconds when the mix was built.
    pub built_at: u64,
    /// Unix seconds when it changes by itself next. 0 = no schedule (radio).
    pub next_refresh_at: u64,
    /// Up to four cover thumbnails for the mosaic cover. Empty = draw the gradient.
    pub cover_urls: Vec<String>,
    /// 0 to 359: the colour of the gradient cover when there are no thumbnails.
    pub cover_hue: u16,
}

/// Summary statistics for the Home page Capsule preview card.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapsuleSummary {
    pub month_name: String,
    pub total_minutes: u64,
    pub top_track: Option<Track>,
    pub top_artist: Option<String>,
    pub play_count: u64,
}

/// Complete aggregated Home feed loaded independently.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct HomeFeed {
    pub greeting: String,
    pub quick_picks: Vec<QuickPick>,
    pub jump_back_in: Vec<ShelfItem>,
    pub new_releases: Vec<ShelfItem>,
    pub fresh_releases: Vec<ShelfItem>,
    pub made_for_you: Vec<MusicMix>,
    pub popular_charts: Vec<ShelfItem>,
    pub playlists: Vec<Playlist>,
    pub saved_albums: Vec<Album>,
    pub capsule_preview: Option<CapsuleSummary>,
    /// Part 6: reasons and schedule for the generated mixes in `made_for_you`.
    pub mix_meta: Vec<MixMeta>,
}

/// The Discover page: new music, from outside sources and from artists the user follows.
/// Built in stages, so an early copy may have empty sections (`complete` is false until the last).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct DiscoverFeed {
    /// Latest album and single releases, newest first. A card opens its album.
    pub new_albums: Vec<ShelfItem>,
    /// New songs: the lead song of each fresh album.
    pub new_songs: Vec<Track>,
    /// Recent releases by the artists the user listens to most, newest first.
    pub from_artists: Vec<ShelfItem>,
    /// What listeners are playing most this week.
    pub trending: Vec<Track>,
    /// "If you like ..." mixes: an artist's songs and songs of similar artists.
    pub mixes: Vec<MusicMix>,
    /// Mood and genre sections ("Calm", "Hip-Hop", ...): the best songs of each.
    pub genres: Vec<MusicMix>,
    /// False while later sections are still being fetched.
    pub complete: bool,
    /// Unix seconds when this feed was last built.
    pub built_at: u64,
}

/// Comprehensive monthly Sound Capsule computed from local play log.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FullCapsule {
    pub month_name: String,
    pub year: i32,
    pub month: u32,
    pub total_minutes: u64,
    pub total_plays: u64,
    pub top_tracks: Vec<(Track, u64)>,    // (track, play count)
    pub top_artists: Vec<(String, u64)>,  // (artist name, minutes played)
    pub top_genres: Vec<(String, usize)>, // (genre name, count)
    pub hourly_distribution: [u32; 24],   // plays per hour (0..=23)
    pub longest_streak_days: u32,
    pub most_replayed_track: Option<(Track, u32)>, // (track, plays in best single day)
    pub mom_change_percent: i32,                   // Month-over-month growth percentage
}

impl Default for FullCapsule {
    fn default() -> Self {
        Self {
            month_name: "This Month".to_string(),
            year: 2026,
            month: 11,
            total_minutes: 0,
            total_plays: 0,
            top_tracks: Vec::new(),
            top_artists: Vec::new(),
            top_genres: Vec::new(),
            hourly_distribution: [0; 24],
            longest_streak_days: 0,
            most_replayed_track: None,
            mom_change_percent: 0,
        }
    }
}

/// Multi-category search results (Top / Songs / Artists / Albums / Playlists).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct DetailedSearchResults {
    pub query: String,
    #[serde(default)]
    pub search_type: String,
    #[serde(default)]
    pub offset: u32,
    pub tracks: Vec<Track>,
    pub artists: Vec<Artist>,
    pub albums: Vec<Album>,
    pub playlists: Vec<Playlist>,
    pub total_tracks: usize,
    pub total_artists: usize,
    pub total_albums: usize,
    pub total_playlists: usize,
}

/// Single word tag in an LRC file (e.g. `<00:12.34>word`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct LyricWord {
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
}

/// Single line in synced/plain lyrics.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct LyricLine {
    pub start_ms: u64,
    pub end_ms: Option<u64>,
    pub text: String,
    #[serde(default)]
    pub translation: Option<String>,
    #[serde(default)]
    pub words: Vec<LyricWord>,
}

/// Synced or plain lyrics for a track.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Lyrics {
    pub track_id: String,
    pub synced: bool,
    pub lines: Vec<LyricLine>,
    pub offset_ms: i64,
}

/// One downloadable built-in language model, as the Settings card shows it (Part 7).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct LlmModelInfo {
    /// Stable id, e.g. `qwen2.5-0.5b-instruct`.
    pub id: String,
    /// Name to show.
    pub name: String,
    /// Download size in bytes: exact once the file is on disk, otherwise the catalogue's estimate.
    pub size_bytes: u64,
    /// Licence name, e.g. `Apache-2.0`.
    pub licence: String,
    /// The file is on disk and complete.
    pub installed: bool,
    /// Bytes of an interrupted download that can be resumed (0 when none).
    pub partial_bytes: u64,
    /// How the file was checked: `pinned` (against a checksum shipped with Halcyon), `server`
    /// (against the one the download server published) or `size` (length only). Empty when not installed.
    pub verified: String,
}
