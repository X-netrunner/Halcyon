//! Newline-delimited JSON protocol over the daemon's Unix socket.
//!
//! Every message is an [`Envelope`] carrying a `version` field. Unknown fields
//! are ignored on decode (`serde` default) and unknown *message kinds* decode
//! to [`Command::Unknown`] / [`Event::Unknown`] so an old daemon paired with a
//! new GUI (or vice versa) degrades instead of erroring out.

use crate::art::ArtSize;
use crate::models::{
    Album, Artist, AuthMode, AuthStatus, DetailedSearchResults, DiscoverFeed, EndpointProbe, FullCapsule, HomeFeed,
    Lyrics, MixMeta, MusicMix, Playlist,
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
    /// Look up the account's name, username and plan again now (the Refresh button in Settings).
    /// The answer arrives as `Profile`, and as `AuthStatus` when the name changed.
    RefreshProfile,
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
    /// Request the Discover page (new releases and new songs).
    GetDiscover,
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
    /// Start or stop the live audio frames ([`EventBody::AudioLevels`]) for *this* connection.
    /// Off by default: the GUI turns them on only while something that dances is on screen
    /// (the queue drawer, the full-screen player), so nothing is sent or analysed otherwise.
    SetAudioStream { enabled: bool },
    /// Ask whether Spotify Connect (Halcyon in the phone's Devices list) is on; answered with
    /// [`EventBody::ConnectSetting`]. An older daemon answers "unsupported".
    GetConnectSetting,
    /// Turn Spotify Connect on or off. The choice is saved and the daemon restarts its player so it
    /// takes effect (playback stops for a moment; the service comes back by itself). Answered with
    /// [`EventBody::ConnectSetting`] before the restart.
    SetConnectEnabled { enabled: bool },
    /// Ask whether the optional LLM layer is on and which model it uses; answered with
    /// [`EventBody::LlmStatus`] without contacting the model. An older daemon ignores it.
    GetLlmStatus,
    /// Turn the optional LLM layer on or off and choose its backend and model (`backend` is
    /// `ollama` today). Answered with [`EventBody::LlmStatus`]. The layer is off by default.
    ///
    /// Part 7: `backend` is `local` (the built-in model) or `ollama`. `model` is the model of the
    /// chosen backend (a built-in model id for `local`). `endpoint` is Ollama's address; empty
    /// keeps the stored one. An older client that sends only the first three still works.
    SetLlmSettings {
        enabled: bool,
        backend: String,
        model: String,
        #[serde(default)]
        endpoint: String,
    },
    /// Ask for the built-in models and what is on disk; answered with [`EventBody::LlmModels`].
    ListLlmModels,
    /// Download a built-in model (resumes an interrupted one). Progress arrives as
    /// [`EventBody::LlmDownload`], and a fresh [`EventBody::LlmModels`] when it ends. One at a time.
    DownloadLlmModel { id: String },
    /// Stop the running download. What was fetched is kept so the next download resumes.
    CancelLlmDownload,
    /// Delete a built-in model file (and any half-finished download of it).
    DeleteLlmModel { id: String },
    /// Check whether the chosen backend answers and has the model; answered with
    /// [`EventBody::LlmStatus`] carrying `reachable` and, when something is wrong, a `hint`.
    TestLlmConnection,
    /// Turn a mood or request typed by the listener ("rainy night coding, no lyrics") into a
    /// mix of real songs. Needs the optional LLM layer to be on. Answered on the event stream by
    /// [`EventBody::PromptPlaylistProgress`] (optional, a few times) and then exactly one of
    /// [`EventBody::PromptPlaylistResult`] or [`EventBody::PromptPlaylistFailed`]. An older
    /// daemon answers with an "unsupported" error.
    PromptPlaylist { text: String },
    /// Part 6: the stored mixes at once (answered with [`EventBody::MixesUpdated`]), then any mix
    /// whose schedule is due is rebuilt in the background and sent again as it finishes.
    GetMixes,
    /// Part 6: rebuild one mix now (the Refresh button). Answered with [`EventBody::MixesUpdated`].
    RefreshMix { mix_id: String },
    /// Part 6: "Less like this" / "Not my taste". With `track_id` it is about that song and its
    /// artist; without, about the whole mix. Takes effect on the taste model at once and is
    /// answered with [`EventBody::MixesUpdated`].
    MixFeedback {
        mix_id: String,
        #[serde(default)]
        track_id: Option<String>,
        action: MixFeedbackAction,
    },
    /// Part 6: song radio. Builds a list from one song with the same ranker and keeps adding
    /// songs while it plays. Answered with [`EventBody::RadioStarted`].
    StartRadio { track: Track },
    /// Part 6: stop adding songs to a running radio.
    StopRadio,
    /// Part 6: Smart Shuffle for a list of your own. The daemon puts one suggestion after every
    /// three of your songs and starts playing. Answered with [`EventBody::SmartShuffleStarted`].
    SmartShuffle { name: String, tracks: Vec<Track> },
    /// Anything we do not recognise yet: kept, not fatal.
    #[serde(other)]
    Unknown,
}

/// What the listener said about a song or a mix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MixFeedbackAction {
    /// Play fewer songs like this: the artist is capped at one song per list.
    LessLikeThis,
    /// Never this song again, and a strong negative for the taste model.
    NotMyTaste,
    /// "Not this" on a Smart Shuffle suggestion: same as `NotMyTaste` for that song.
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
    /// `username` (Spotify's canonical user id) and `plan` ("Premium" / "Free") were added later:
    /// both default to `None`, so an older daemon's event still decodes.
    Profile {
        display_name: Option<String>,
        image_url: Option<String>,
        #[serde(default)]
        username: Option<String>,
        #[serde(default)]
        plan: Option<String>,
    },
    /// Re-login required (token expired / revoked).
    AuthRequired { reason: String },
    /// The token browsing uses changed (also sent when a client connects).
    AuthModeChanged { mode: AuthMode },
    /// State of the streaming sign-in (librespot's own token). Never carries a token.
    /// `seconds_left` is the lifetime of the current access token (it is renewed on its own).
    StreamingAuth { signed_in: bool, seconds_left: Option<u64> },
    /// The Spotify Connect device name this daemon is registered under ("Halcyon (host)"), or
    /// `None` when it is not registered. Sent when a client connects and whenever it changes.
    /// An older client sees an unknown kind and ignores it.
    ConnectDevice {
        #[serde(default)]
        name: Option<String>,
    },
    /// Whether Spotify Connect is switched on (`enabled`) and whether this daemon build contains
    /// the Connect code at all (`available`). Without it the switch cannot do anything.
    ConnectSetting {
        enabled: bool,
        #[serde(default)]
        available: bool,
    },
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
    /// Discover page: sent as soon as something is known, then again when it is complete.
    DiscoverResult(Box<DiscoverFeed>),
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
    /// One frame of live analysis of what is coming out of the speakers, about 43 a second
    /// while [`CommandBody::SetAudioStream`] is on. `bands` is a log-spaced spectrum (low to
    /// high, 0..=255 each), `bass` the average of the lowest bands, `beat` 0 or, when a kick or
    /// snare just hit, its strength 1..=255. The frames are timed to the sound: the daemon
    /// holds each one back until it is due at the speakers. One all-zero frame is sent when
    /// playback stops.
    AudioLevels { bands: Vec<u8>, bass: u8, beat: u8 },
    /// State of the optional LLM layer. `reachable` is only meaningful after a connection test
    /// (it is `false` when the layer is off or has not been tested). `hint` is a plain-language
    /// fix when something is wrong.
    LlmStatus {
        enabled: bool,
        backend: String,
        model: String,
        reachable: bool,
        #[serde(default)]
        hint: Option<String>,
    },
    /// The built-in language models (Part 7): what the catalogue offers and what is on disk.
    /// `engine` is whether this daemon was built with the embedded model engine; `active` is
    /// the model Smart suggestions would use; `dir` is the folder the files live in.
    LlmModels {
        models: Vec<crate::models::LlmModelInfo>,
        #[serde(default)]
        engine: bool,
        #[serde(default)]
        active: String,
        #[serde(default)]
        dir: String,
    },
    /// Where a model download is. `state` is `downloading`, `verifying`, `done`, `cancelled` or
    /// `failed` (with `error` in plain language). A client that does not know a state shows the numbers.
    LlmDownload {
        id: String,
        state: String,
        done: u64,
        total: u64,
        #[serde(default)]
        error: Option<String>,
    },
    /// A Home mix got a better title and a short reason. Sent when the answer is ready (or
    /// found in the cache), never before; the mix keeps working as it is until then.
    MixEnriched { mix_id: String, title: String, reason: String },
    /// The best order (and trim) of a Home mix's own songs, chosen by the optional LLM layer
    /// from the songs the engine already put in that mix. `track_ids` are ids from that mix only,
    /// best first; a client ignores ids it does not have and keeps the engine's order when too
    /// few match. Never carries a song the client does not already hold.
    MixReranked { mix_id: String, track_ids: Vec<String> },
    /// Where a [`CommandBody::PromptPlaylist`] request is: `step` is `understanding`,
    /// `searching` or `choosing`. A client that does not know a step shows a generic
    /// "working" line. `request` echoes the text that was sent.
    PromptPlaylistProgress { request: String, step: String },
    /// The mix made for a [`CommandBody::PromptPlaylist`] request. Every song in it came from
    /// the catalogue; the model only chose and ordered them and wrote the words.
    PromptPlaylistResult { request: String, mix: MusicMix },
    /// A [`CommandBody::PromptPlaylist`] request that could not be answered. `reason` is plain
    /// language and says what to do.
    PromptPlaylistFailed { request: String, reason: String },
    /// Part 6: the generated mixes (Daily Mix, Discover Weekly, Release Radar, On Repeat, Repeat
    /// Rewind, Daylist) as they stand, with the reason line and schedule of each. A client
    /// replaces the mixes with the same ids and keeps the rest.
    MixesUpdated { mixes: Vec<MusicMix>, meta: Vec<MixMeta> },
    /// Part 6: a radio started (first songs are already queued and playing). Later songs are
    /// appended to the queue by the daemon.
    RadioStarted { mix: MusicMix, meta: MixMeta },
    /// Part 6: the radio ended, or could not start; `reason` is plain language.
    RadioStopped { reason: String },
    /// Part 6: Smart Shuffle started. `suggested` are the ids of the inserted songs, so a client
    /// can mark them and offer "Not this".
    SmartShuffleStarted { name: String, suggested: Vec<String> },
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
    fn discover_command_and_event_round_trip() {
        let cmd = command(CommandBody::GetDiscover);
        let back: Command = decode_line(&encode_line(&cmd).unwrap()).unwrap();
        assert_eq!(cmd, back);
        let feed = DiscoverFeed { complete: true, built_at: 7, ..Default::default() };
        let ev = event(EventBody::DiscoverResult(Box::new(feed)));
        let back: Event = decode_line(&encode_line(&ev).unwrap()).unwrap();
        assert_eq!(ev, back);
    }

    #[test]
    fn discover_feed_decodes_with_missing_sections() {
        // A feed saved by an older build, or cut short, must still load.
        let line = br#"{"version":1,"type":"discover_result","new_songs":[]}
"#;
        let ev: Event = decode_line(line).expect("decode");
        assert!(matches!(ev.body, EventBody::DiscoverResult(_)));
    }

    #[test]
    fn profile_command_and_event_round_trip() {
        let cmd = command(CommandBody::GetProfile);
        let back: Command = decode_line(&encode_line(&cmd).unwrap()).unwrap();
        assert_eq!(cmd, back);
        let ev = event(EventBody::Profile {
            display_name: Some("Ada".into()),
            image_url: Some("https://i.scdn.co/image/x".into()),
            username: Some("ada123".into()),
            plan: Some("Premium".into()),
        });
        let back: Event = decode_line(&encode_line(&ev).unwrap()).unwrap();
        assert_eq!(ev, back);
    }

    #[test]
    fn connect_device_event_round_trips_and_old_peers_ignore_it() {
        let ev = event(EventBody::ConnectDevice { name: Some("Halcyon (box)".into()) });
        let line = encode_line(&ev).expect("encode");
        assert!(String::from_utf8_lossy(&line).contains("\"connect_device\""));
        let back: Event = decode_line(&line).expect("decode");
        assert_eq!(ev, back);
        // The name may be missing (not registered).
        let bare = br#"{"version":1,"type":"connect_device"}
"#;
        let ev: Event = decode_line(bare).expect("decode");
        assert!(matches!(ev.body, EventBody::ConnectDevice { name: None }));
    }

    #[test]
    fn refresh_profile_command_has_a_stable_wire_name() {
        let cmd = command(CommandBody::RefreshProfile);
        let line = encode_line(&cmd).expect("encode");
        assert!(String::from_utf8_lossy(&line).contains("\"refresh_profile\""));
        let back: Command = decode_line(&line).expect("decode");
        assert_eq!(cmd, back);
    }

    #[test]
    fn profile_event_from_an_older_daemon_has_no_username_or_plan() {
        let line = br#"{"version":1,"type":"profile","display_name":"Ada","image_url":null}
"#;
        let ev: Event = decode_line(line).expect("decode");
        match ev.body {
            EventBody::Profile { display_name, username, plan, .. } => {
                assert_eq!(display_name.as_deref(), Some("Ada"));
                assert_eq!(username, None);
                assert_eq!(plan, None);
            }
            other => panic!("wrong event: {other:?}"),
        }
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
    fn audio_stream_messages_round_trip() {
        let cmd = command(CommandBody::SetAudioStream { enabled: true });
        let line = encode_line(&cmd).expect("encode");
        assert!(String::from_utf8_lossy(&line).contains("\"set_audio_stream\""));
        let back: Command = decode_line(&line).expect("decode");
        assert_eq!(cmd, back);

        let ev = event(EventBody::AudioLevels { bands: vec![0, 128, 255], bass: 90, beat: 200 });
        let line = encode_line(&ev).expect("encode");
        let back: Event = decode_line(&line).expect("decode");
        assert_eq!(ev, back);
    }

    #[test]
    fn connect_setting_messages_round_trip() {
        for cmd in [command(CommandBody::GetConnectSetting), command(CommandBody::SetConnectEnabled { enabled: true })] {
            let line = encode_line(&cmd).expect("encode");
            let back: Command = decode_line(&line).expect("decode");
            assert_eq!(cmd, back);
        }
        let ev = event(EventBody::ConnectSetting { enabled: false, available: true });
        let line = encode_line(&ev).expect("encode");
        let back: Event = decode_line(&line).expect("decode");
        assert_eq!(ev, back);
        // `available` is optional on the wire (an older daemon never sends it).
        let old: Event = decode_line(br#"{"version":1,"type":"connect_setting","enabled":true}"#).expect("decode");
        assert!(matches!(old.body, EventBody::ConnectSetting { enabled: true, available: false }));
    }

    #[test]
    fn llm_messages_round_trip() {
        for cmd in [
            command(CommandBody::GetLlmStatus),
            command(CommandBody::TestLlmConnection),
            command(CommandBody::SetLlmSettings {
                enabled: true,
                backend: "ollama".into(),
                model: "qwen2.5:3b".into(),
                endpoint: String::new(),
            }),
        ] {
            let line = encode_line(&cmd).expect("encode");
            let back: Command = decode_line(&line).expect("decode");
            assert_eq!(cmd, back);
        }
        for ev in [
            event(EventBody::LlmStatus {
                enabled: true,
                backend: "ollama".into(),
                model: "qwen2.5:3b".into(),
                reachable: false,
                hint: Some("Start Ollama with: ollama serve".into()),
            }),
            event(EventBody::MixEnriched {
                mix_id: "on-repeat".into(),
                title: "Your Heavy Rotation".into(),
                reason: "The songs you keep coming back to.".into(),
            }),
        ] {
            let line = encode_line(&ev).expect("encode");
            let back: Event = decode_line(&line).expect("decode");
            assert_eq!(ev, back);
        }
    }

    #[test]
    fn set_llm_settings_from_an_older_client_still_decodes() {
        // Part 7 added `endpoint`; a client that does not send it must still work.
        let line = br#"{"version":1,"type":"set_llm_settings","enabled":true,"backend":"ollama","model":"qwen2.5:3b"}
"#;
        let cmd: Command = decode_line(line).expect("decode");
        assert!(matches!(cmd.body, CommandBody::SetLlmSettings { enabled: true, ref endpoint, .. } if endpoint.is_empty()));
    }

    #[test]
    fn local_model_messages_round_trip_and_have_stable_wire_names() {
        for (cmd, wire) in [
            (command(CommandBody::ListLlmModels), "list_llm_models"),
            (command(CommandBody::DownloadLlmModel { id: "qwen2.5-0.5b-instruct".into() }), "download_llm_model"),
            (command(CommandBody::CancelLlmDownload), "cancel_llm_download"),
            (command(CommandBody::DeleteLlmModel { id: "x".into() }), "delete_llm_model"),
        ] {
            let line = encode_line(&cmd).expect("encode");
            assert!(String::from_utf8_lossy(&line).contains(&format!("\"type\":\"{wire}\"")));
            let back: Command = decode_line(&line).expect("decode");
            assert_eq!(cmd, back);
        }
        let info = crate::models::LlmModelInfo {
            id: "qwen2.5-0.5b-instruct".into(),
            name: "Qwen2.5 0.5B".into(),
            size_bytes: 491_000_000,
            licence: "Apache-2.0".into(),
            installed: false,
            partial_bytes: 1024,
            verified: String::new(),
        };
        for ev in [
            event(EventBody::LlmModels { models: vec![info], engine: true, active: "qwen2.5-0.5b-instruct".into(), dir: "/d".into() }),
            event(EventBody::LlmDownload { id: "m".into(), state: "downloading".into(), done: 5, total: 10, error: None }),
            event(EventBody::LlmDownload { id: "m".into(), state: "failed".into(), done: 5, total: 10, error: Some("offline".into()) }),
        ] {
            let line = encode_line(&ev).expect("encode");
            let back: Event = decode_line(&line).expect("decode");
            assert_eq!(ev, back);
        }
        // a peer that sends only the models still decodes
        let line = br#"{"version":1,"type":"llm_models","models":[{"id":"a"}]}
"#;
        let ev: Event = decode_line(line).expect("decode");
        assert!(matches!(ev.body, EventBody::LlmModels { engine: false, .. }));
    }

    #[test]
    fn llm_status_decodes_without_a_hint() {
        // A peer that does not send `hint` (older or simpler) must still decode.
        let line = br#"{"version":1,"type":"llm_status","enabled":false,"backend":"ollama","model":"m","reachable":false}
"#;
        let ev: Event = decode_line(line).expect("decode");
        assert!(matches!(ev.body, EventBody::LlmStatus { hint: None, enabled: false, .. }));
    }

    #[test]
    fn mix_reranked_round_trips_and_has_a_stable_wire_name() {
        let ev = event(EventBody::MixReranked { mix_id: "on-repeat".into(), track_ids: vec!["a".into(), "b".into()] });
        let line = encode_line(&ev).expect("encode");
        assert!(String::from_utf8_lossy(&line).contains("\"type\":\"mix_reranked\""));
        let back: Event = decode_line(&line).expect("decode");
        assert_eq!(ev, back);
        // An older client that has no such variant sees Unknown; this build ignores extra fields.
        let newer = br#"{"version":1,"type":"mix_reranked","mix_id":"m","track_ids":[],"why":"later"}
"#;
        let ev: Event = decode_line(newer).expect("decode");
        assert!(matches!(ev.body, EventBody::MixReranked { .. }));
    }

    #[test]
    fn prompt_playlist_messages_round_trip() {
        let cmd = command(CommandBody::PromptPlaylist { text: "rainy night coding, no lyrics".into() });
        let back: Command = decode_line(&encode_line(&cmd).expect("encode")).expect("decode");
        assert_eq!(cmd, back);

        let mix = MusicMix {
            id: "prompt-abc".into(),
            title: "Rainy Night Code".into(),
            description: "Calm, lyric-free tracks.".into(),
            source: "Halcyon Local".into(),
            tracks: vec![crate::models::Track::simple("1".into(), "Glow".into(), "Echo".into(), "Dusk".into(), 1000)],
            art_url: None,
        };
        for ev in [
            event(EventBody::PromptPlaylistProgress { request: "rainy".into(), step: "searching".into() }),
            event(EventBody::PromptPlaylistResult { request: "rainy".into(), mix }),
            event(EventBody::PromptPlaylistFailed {
                request: "rainy".into(),
                reason: "Smart suggestions are off. Turn them on in Settings.".into(),
            }),
        ] {
            let line = encode_line(&ev).expect("encode");
            let back: Event = decode_line(&line).expect("decode");
            assert_eq!(ev, back);
        }
    }

    #[test]
    fn prompt_playlist_wire_names_are_stable() {
        // These strings are the contract with other builds; changing one breaks older peers.
        let line = encode_line(&command(CommandBody::PromptPlaylist { text: "x".into() })).expect("encode");
        assert!(String::from_utf8_lossy(&line).contains("\"type\":\"prompt_playlist\""));
        let line = encode_line(&event(EventBody::PromptPlaylistFailed { request: "x".into(), reason: "y".into() }))
            .expect("encode");
        assert!(String::from_utf8_lossy(&line).contains("\"type\":\"prompt_playlist_failed\""));
    }

    #[test]
    fn prompt_playlist_progress_with_an_unknown_step_still_decodes() {
        // A newer daemon may add steps; the client shows a generic line for ones it does not know.
        let line = br#"{"version":1,"type":"prompt_playlist_progress","request":"r","step":"polishing","extra":1}
"#;
        let ev: Event = decode_line(line).expect("decode");
        assert!(matches!(ev.body, EventBody::PromptPlaylistProgress { .. }));
    }

    #[test]
    fn older_peer_sees_llm_messages_as_unknown() {
        // Simulates a peer built before the LLM layer: a kind it does not list decodes to Unknown.
        // The same bytes decode to the real variant here, and an unlisted kind decodes to Unknown.
        let line = br#"{"version":1,"type":"prompt_playlist_from_the_future","text":"x"}
"#;
        let cmd: Command = decode_line(line).expect("decode");
        assert!(matches!(cmd.body, CommandBody::Unknown));
        let line = br#"{"version":1,"type":"mix_enriched_v2","mix_id":"a"}
"#;
        let ev: Event = decode_line(line).expect("decode");
        assert!(matches!(ev.body, EventBody::Unknown));
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
