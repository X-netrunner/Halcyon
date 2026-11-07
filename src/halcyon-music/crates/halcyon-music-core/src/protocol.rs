//! Newline-delimited JSON protocol over the daemon's Unix socket.
//!
//! Every message is an [`Envelope`] carrying a `version` field. Unknown fields
//! are ignored on decode (`serde` default) and unknown *message kinds* decode
//! to [`Command::Unknown`] / [`Event::Unknown`] so an old daemon paired with a
//! new GUI (or vice versa) degrades instead of erroring out.

use crate::art::ArtSize;
use crate::models::{
    Album, Artist, AuthMode, AuthStatus, DetailedSearchResults, EndpointProbe, FullCapsule, HomeFeed,
    Lyrics, MusicMix, Playlist,
};
use crate::state::{Bitrate, PlayerState, RepeatMode, Track};
use serde::{Deserialize, Serialize};

/// Bump when a change would confuse an older peer. Peers warn, never refuse,
/// when they see a newer version than their own.
pub const PROTOCOL_VERSION: u32 = 1;

/// Wire wrapper: `{ "version": 1, "type": "...", ... }`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Envelope<T> {
    pub version: u32,
    #[serde(flatten)]
    pub body: T,
}

/// A client → daemon message.
pub type Command = Envelope<CommandBody>;

/// A daemon → client message (event stream).
pub type Event = Envelope<EventBody>;

/// Convenience constructors.
pub fn command(body: CommandBody) -> Command {
    Envelope { version: PROTOCOL_VERSION, body }
}

pub fn event(body: EventBody) -> Event {
    Envelope { version: PROTOCOL_VERSION, body }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum CommandBody {
    /// Start playback (of the current track, or of the queue if stopped).
    Play,
    Pause,
    Toggle,
    /// Absolute seek in milliseconds.
    Seek { position_ms: u64 },
    /// Relative seek in milliseconds (may be negative).
    SeekBy { delta_ms: i64 },
    Next,
    Previous,
    /// 0..=100
    SetVolume { volume: u8 },
    /// Volume delta -100..=100, clamped by the daemon.
    VolumeBy { delta: i8 },
    SetShuffle { shuffle: bool },
    /// off → all → one → off
    CycleRepeat,
    /// Client hello; daemon answers with [`EventBody::Hello`].
    Hello,
    /// Ask for a full state snapshot.
    GetState,
    /// Queue a track after the current one.
    PlayNext { track: Track },
    /// Append a track to the end of the queue.
    Enqueue { track: Track },
    /// Remove a queue entry by index.
    Dequeue { index: usize },
    /// Start PKCE authorization flow with given Spotify Client ID.
    LoginStart { client_id: String },
    /// Start librespot's own browser sign-in (the default sign-in: one token for streaming
    /// and, from rework Part 4, browsing). Progress arrives as [`EventBody::AuthStatus`] and
    /// [`EventBody::StreamingAuth`]. An older daemon answers with an "unsupported" error.
    LoginStartLibrespot,
    /// Choose which token browsing uses (`librespot` default, `own-client-id` advanced).
    /// Answered with [`EventBody::AuthModeChanged`] and an [`EventBody::AuthStatus`].
    SetAuthMode { mode: AuthMode },
    /// Ask whether a streaming sign-in exists; answered with [`EventBody::StreamingAuth`].
    GetStreamingAuth,
    /// Cancel in-flight login flow.
    LoginCancel,
    /// Clear credentials and log out.
    Logout,
    /// Query current authentication status.
    GetAuthStatus,
    /// Ask for the account's display name and profile picture URL (answered with `Profile`).
    GetProfile,
    /// Request user's playlists (stale-while-revalidate).
    GetPlaylists { limit: Option<u32>, offset: Option<u32> },
    /// Request tracks of a specific playlist (stale-while-revalidate).
    GetPlaylistTracks { id: String, limit: Option<u32>, offset: Option<u32> },
    /// Request user's saved/liked tracks (stale-while-revalidate).
    GetLikedTracks { limit: Option<u32>, offset: Option<u32> },
    /// Request the user's saved albums (first 50).
    GetSavedAlbums,
    /// Request the artists the user follows (first 50).
    GetFollowedArtists,
    /// Search tracks (Spotify search capped at 10 results per request).
    Search { query: String, limit: Option<u32>, offset: Option<u32> },
    /// Probe optional Spotify endpoints.
    ProbeEndpoints,
    /// Play a track directly.
    PlayTrack { track: Track },
    /// Play a list of tracks starting at a given index.
    PlayContext { tracks: Vec<Track>, start_index: usize },
    /// Move a queue item from `from` index to `to` index.
    ReorderQueue { from: usize, to: usize },
    /// Set repeat mode directly.
    SetRepeat { repeat: RepeatMode },
    /// Set audio bitrate.
    SetBitrate { bitrate: Bitrate },
    /// Set volume normalisation.
    SetNormalisation { enabled: bool },
    /// Request the aggregated Home page feed.
    GetHomeFeed,
    /// Request generated mixes from the suggestion engine.
    GetSuggestions,
    /// Play a generated mix immediately.
    PlayMix { tracks: Vec<Track>, name: String },
    /// Save a generated mix as a real Spotify playlist.
    SaveMixAsPlaylist { name: String, track_uris: Vec<String> },
    /// Create a new playlist.
    CreatePlaylist { name: String, description: Option<String> },
    /// Rename a playlist.
    RenamePlaylist { id: String, new_name: String },
    /// Delete/Unfollow a playlist.
    DeletePlaylist { id: String },
    /// Add a track to a playlist.
    AddTrackToPlaylist { playlist_id: String, track_uri: String },
    /// Remove a track from a playlist.
    RemoveTrackFromPlaylist { playlist_id: String, track_uri: String },
    /// Request monthly Sound Capsule.
    GetCapsule { month_offset: u32 },
    /// Request album detail and full tracklist.
    GetAlbumDetail { id: String },
    /// Request artist detail, top tracks, and discography.
    GetArtistDetail { id: String },
    /// Multi-category search with pagination.
    DetailedSearch { query: String, search_type: String, limit: u32, offset: u32 },
    /// Request recent searches.
    GetRecentSearches,
    /// Clear recent searches history.
    ClearRecentSearches,
    /// Request synced lyrics for track.
    GetLyrics {
        track_id: String,
        artist: String,
        title: String,
        album: String,
        duration_ms: u64,
    },
    /// Adjust manual lyric offset in milliseconds (+/- 100ms).
    SetLyricOffset { track_id: String, offset_ms: i64 },
    /// Load custom local .lrc file text.
    LoadLocalLrc { track_id: String, lrc_content: String },
    /// Force fresh search on LRCLIB.
    SearchLyricsAgain { track_id: String, artist: String, title: String },
    /// Download (or find in the disk cache) a cover. The answer arrives as
    /// [`EventBody::ArtReady`] or [`EventBody::ArtFailed`]; repeating a request
    /// is cheap, the daemon de-duplicates in-flight downloads.
    GetArt { url: String, size: ArtSize },
    /// Anything we do not recognise yet: kept, not fatal.
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EventBody {
    /// Reply to [`CommandBody::Hello`]; carries daemon identity.
    Hello {
        daemon_version: String,
        protocol_version: u32,
    },
    /// Full snapshot, sent on connect and on [`CommandBody::GetState`].
    State { state: PlayerState },
    /// Periodic position update while playing.
    Progress { position_ms: u64, playing: bool },
    /// The queue changed.
    Queue { tracks: Vec<Track> },
    /// A component was restarted by the supervisor after a crash.
    Recovered { component: String, attempt: u32 },
    /// Human-readable, plain-language error the GUI can toast.
    Error { message: String },
    /// Reply to Ping-ish commands; also used as a liveness heartbeat.
    Pong,
    /// Authentication status changed or requested.
    AuthStatus(AuthStatus),
    /// The account's name and picture URL. Either may be missing; the GUI then shows an initial.
    Profile { display_name: Option<String>, image_url: Option<String> },
    /// Re-login required (token expired / revoked).
    AuthRequired { reason: String },
    /// The token browsing uses changed (also sent when a client connects).
    AuthModeChanged { mode: AuthMode },
    /// State of the streaming sign-in (librespot's own token). Never carries a token.
    /// `seconds_left` is the lifetime of the current access token (it is renewed on its own).
    StreamingAuth { signed_in: bool, seconds_left: Option<u64> },
    /// Successfully authenticated.
    AuthSuccess { user_id: Option<String> },
    /// Playlists response (stale-while-revalidate).
    PlaylistsResult {
        playlists: Vec<Playlist>,
        total: usize,
        offset: usize,
        is_cached: bool,
    },
    /// Playlist tracks response (stale-while-revalidate).
    PlaylistTracksResult {
        playlist_id: String,
        tracks: Vec<Track>,
        total: usize,
        offset: usize,
        is_cached: bool,
    },
    /// Liked tracks response (stale-while-revalidate).
    LikedTracksResult {
        tracks: Vec<Track>,
        total: usize,
        offset: usize,
        is_cached: bool,
    },
    /// Saved albums for the Library tab.
    SavedAlbumsResult { albums: Vec<Album> },
    /// Followed artists for the Library tab.
    FollowedArtistsResult { artists: Vec<Artist> },
    /// Search results.
    SearchResults {
        query: String,
        tracks: Vec<Track>,
        total: usize,
        is_cached: bool,
    },
    /// Probed endpoints status.
    ProbeResult { probes: Vec<EndpointProbe> },
    /// Playback failed (for toasts and watchdog reporting).
    PlaybackFailed {
        reason: String,
        consecutive_failures: u32,
        will_retry: bool,
    },
    /// Track unavailable in region or licensing.
    TrackUnavailable {
        track_id: String,
        title: String,
        reason: String,
    },
    /// Home feed response (stale-while-revalidate).
    HomeFeedResult(Box<HomeFeed>),
    /// Suggestions response.
    SuggestionsResult { mixes: Vec<MusicMix> },
    /// Confirmation that a mix was saved as a real playlist.
    PlaylistCreated { playlist_id: String, name: String },
    /// Monthly Sound Capsule results.
    CapsuleResult(Box<FullCapsule>),
    /// Multi-category search results.
    DetailedSearchResults(Box<DetailedSearchResults>),
    /// Album detail response.
    AlbumDetailResult { album: Album, tracks: Vec<Track> },
    /// Artist detail response.
    ArtistDetailResult {
        artist: Artist,
        top_tracks: Vec<Track>,
        albums: Vec<Album>,
    },
    /// Recent searches response.
    RecentSearchesResult { searches: Vec<String> },
    /// Playlist updated.
    PlaylistUpdated { id: String },
    /// Synced or plain lyrics response.
    LyricsResult {
        track_id: String,
        lyrics: Option<Box<Lyrics>>,
    },
    /// Live current lyric line progress for island and status indicators.
    CurrentLyric {
        track_id: String,
        line_idx: usize,
        line: Option<String>,
    },
    /// A cover is on disk. `url` and `size` echo the request.
    ArtReady { url: String, size: ArtSize, path: String },
    /// A cover could not be fetched (offline, 404, too big, not an image).
    ArtFailed { url: String, size: ArtSize, reason: String },
    /// Anything we do not recognise yet: kept, not fatal.
    #[serde(other)]
    Unknown,
}

/// The message type name is the `type` tag; this alias documents intent.
pub type Message = Command;

/// Encode one value as a single NDJSON line.
pub fn encode_line<T: Serialize>(value: &T) -> Result<Vec<u8>, serde_json::Error> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    Ok(line)
}

/// Decode one NDJSON line (trailing newline optional).
pub fn decode_line<'a, T: Deserialize<'a>>(line: &'a [u8]) -> Result<T, serde_json::Error> {
    serde_json::from_slice(line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_round_trip() {
        let cmd = command(CommandBody::Seek { position_ms: 42_000 });
        let line = encode_line(&cmd).expect("encode");
        let back: Command = decode_line(&line).expect("decode");
        assert_eq!(cmd, back);
        assert_eq!(back.version, PROTOCOL_VERSION);
    }

    #[test]
    fn event_round_trip_state() {
        let ev = event(EventBody::State { state: crate::state::PlayerState::default() });
        let line = encode_line(&ev).expect("encode");
        let back: Event = decode_line(&line).expect("decode");
        assert_eq!(ev, back);
    }

    #[test]
    fn profile_command_and_event_round_trip() {
        let cmd = command(CommandBody::GetProfile);
        let back: Command = decode_line(&encode_line(&cmd).unwrap()).unwrap();
        assert_eq!(cmd, back);
        let ev = event(EventBody::Profile {
            display_name: Some("Ada".into()),
            image_url: Some("https://i.scdn.co/image/x".into()),
        });
        let back: Event = decode_line(&encode_line(&ev).unwrap()).unwrap();
        assert_eq!(ev, back);
    }

    #[test]
    fn profile_event_decodes_without_the_picture() {
        let line = br#"{"version":1,"type":"profile","display_name":"Ada"}
"#;
        let ev: Event = decode_line(line).expect("decode");
        assert!(matches!(ev.body, EventBody::Profile { image_url: None, .. }));
    }

    #[test]
    fn unknown_fields_are_ignored() {
        // A newer peer adds a field we do not know: must still decode.
        let line = br#"{"version":1,"type":"seek","position_ms":1000,"warp":true}
"#;
        let cmd: Command = decode_line(line).expect("decode");
        assert!(matches!(cmd.body, CommandBody::Seek { position_ms: 1000 }));
    }

    #[test]
    fn login_and_playlists_round_trip() {
        let cmd = command(CommandBody::LoginStart { client_id: "test-id-123".into() });
        let line = encode_line(&cmd).expect("encode");
        let back: Command = decode_line(&line).expect("decode");
        assert_eq!(cmd, back);

        let ev = event(EventBody::PlaylistsResult {
            playlists: vec![],
            total: 0,
            offset: 0,
            is_cached: true,
        });
        let line_ev = encode_line(&ev).expect("encode");
        let back_ev: Event = decode_line(&line_ev).expect("decode");
        assert_eq!(ev, back_ev);
    }

    #[test]
    fn streaming_login_messages_round_trip_and_old_peers_ignore_them() {
        let cmd = command(CommandBody::LoginStartLibrespot);
        let line = encode_line(&cmd).expect("encode");
        let back: Command = decode_line(&line).expect("decode");
        assert_eq!(cmd, back);

        let ev = event(EventBody::StreamingAuth { signed_in: true, seconds_left: Some(1200) });
        let line = encode_line(&ev).expect("encode");
        let back: Event = decode_line(&line).expect("decode");
        assert_eq!(ev, back);

        // An older peer sees the same bytes as an unknown kind, not an error.
        let wire = br#"{"version":1,"type":"login_start_librespot"}
"#;
        let cmd: Command = decode_line(wire).expect("decode");
        assert!(matches!(cmd.body, CommandBody::LoginStartLibrespot));
    }

    #[test]
    fn auth_mode_wire_names_and_round_trip() {
        let cmd = command(CommandBody::SetAuthMode { mode: AuthMode::OwnClientId });
        let line = encode_line(&cmd).expect("encode");
        assert!(String::from_utf8_lossy(&line).contains("\"own-client-id\""));
        let back: Command = decode_line(&line).expect("decode");
        assert_eq!(cmd, back);

        let ev = event(EventBody::AuthModeChanged { mode: AuthMode::Librespot });
        let line = encode_line(&ev).expect("encode");
        assert!(String::from_utf8_lossy(&line).contains("\"librespot\""));
        let back: Event = decode_line(&line).expect("decode");
        assert_eq!(ev, back);
    }

    #[test]
    fn unknown_message_kind_is_kept() {
        let line = br#"{"version":1,"type":"teleport"}
"#;
        let cmd: Command = decode_line(line).expect("decode");
        assert!(matches!(cmd.body, CommandBody::Unknown));
    }

    #[test]
    fn older_version_still_decodes_and_peer_can_warn() {
        let line = br#"{"version":99,"type":"pong"}
"#;
        let ev: Event = decode_line(line).expect("decode");
        assert!(ev.version > PROTOCOL_VERSION); // caller decides to warn
    }

    #[test]
    fn part6_protocol_round_trip() {
        let cmd = command(CommandBody::DetailedSearch {
            query: "Daft Punk".into(),
            search_type: "artist".into(),
            limit: 10,
            offset: 0,
        });
        let line = encode_line(&cmd).expect("encode");
        let back: Command = decode_line(&line).expect("decode");
        assert_eq!(cmd, back);

        let capsule_ev = event(EventBody::CapsuleResult(Box::default()));
        let line_cap = encode_line(&capsule_ev).expect("encode");
        let back_cap: Event = decode_line(&line_cap).expect("decode");
        assert_eq!(capsule_ev, back_cap);

        let recents_ev = event(EventBody::RecentSearchesResult {
            searches: vec!["Radiohead".into(), "Kavinsky".into()],
        });
        let line_rec = encode_line(&recents_ev).expect("encode");
        let back_rec: Event = decode_line(&line_rec).expect("decode");
        assert_eq!(recents_ev, back_rec);
    }

    #[test]
    fn art_protocol_round_trip() {
        let cmd = command(CommandBody::GetArt { url: "https://x/y".into(), size: ArtSize::Medium });
        let line = encode_line(&cmd).expect("encode");
        assert!(std::str::from_utf8(&line).expect("utf8").contains("\"size\":\"medium\""));
        let back: Command = decode_line(&line).expect("decode");
        assert_eq!(cmd, back);

        for ev in [
            event(EventBody::ArtReady { url: "u".into(), size: ArtSize::Small, path: "/tmp/a.img".into() }),
            event(EventBody::ArtFailed { url: "u".into(), size: ArtSize::Large, reason: "offline".into() }),
        ] {
            let line = encode_line(&ev).expect("encode");
            let back: Event = decode_line(&line).expect("decode");
            assert_eq!(ev, back);
        }
    }

    #[test]
    fn part7_protocol_round_trip() {
        use crate::models::{LyricLine, LyricWord, Lyrics};

        let get_cmd = command(CommandBody::GetLyrics {
            track_id: "t1".into(),
            artist: "Daft Punk".into(),
            title: "Get Lucky".into(),
            album: "RAM".into(),
            duration_ms: 248_000,
        });
        let line = encode_line(&get_cmd).expect("encode");
        let back_cmd: Command = decode_line(&line).expect("decode");
        assert_eq!(get_cmd, back_cmd);

        let offset_cmd = command(CommandBody::SetLyricOffset {
            track_id: "t1".into(),
            offset_ms: -300,
        });
        let line_off = encode_line(&offset_cmd).expect("encode");
        let back_off: Command = decode_line(&line_off).expect("decode");
        assert_eq!(offset_cmd, back_off);

        let lrc = Lyrics {
            track_id: "t1".into(),
            synced: true,
            lines: vec![LyricLine {
                start_ms: 12_500,
                end_ms: Some(15_000),
                text: "Like the legend of the phoenix".into(),
                translation: None,
                words: vec![LyricWord {
                    start_ms: 12_500,
                    end_ms: 13_000,
                    text: "Like".into(),
                }],
            }],
            offset_ms: 0,
        };

        let lrc_ev = event(EventBody::LyricsResult {
            track_id: "t1".into(),
            lyrics: Some(Box::new(lrc)),
        });
        let line_lrc = encode_line(&lrc_ev).expect("encode");
        let back_lrc: Event = decode_line(&line_lrc).expect("decode");
        assert_eq!(lrc_ev, back_lrc);

        let cur_ev = event(EventBody::CurrentLyric {
            track_id: "t1".into(),
            line_idx: 0,
            line: Some("Like the legend of the phoenix".into()),
        });
        let line_cur = encode_line(&cur_ev).expect("encode");
        let back_cur: Event = decode_line(&line_cur).expect("decode");
        assert_eq!(cur_ev, back_cur);
    }
}
