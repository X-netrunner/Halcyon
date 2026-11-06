//! Newline-delimited JSON protocol over the daemon's Unix socket.
//!
//! Every message is an [`Envelope`] carrying a `version` field. Unknown fields
//! are ignored on decode (`serde` default) and unknown *message kinds* decode
//! to [`Command::Unknown`] / [`Event::Unknown`] so an old daemon paired with a
//! new GUI (or vice versa) degrades instead of erroring out.

use crate::models::{AuthStatus, EndpointProbe, Playlist};
use crate::state::{PlayerState, Track};
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
    /// Cancel in-flight login flow.
    LoginCancel,
    /// Clear credentials and log out.
    Logout,
    /// Query current authentication status.
    GetAuthStatus,
    /// Request user's playlists (stale-while-revalidate).
    GetPlaylists { limit: Option<u32>, offset: Option<u32> },
    /// Request tracks of a specific playlist (stale-while-revalidate).
    GetPlaylistTracks { id: String, limit: Option<u32>, offset: Option<u32> },
    /// Request user's saved/liked tracks (stale-while-revalidate).
    GetLikedTracks { limit: Option<u32>, offset: Option<u32> },
    /// Search tracks (Spotify search capped at 10 results per request).
    Search { query: String, limit: Option<u32>, offset: Option<u32> },
    /// Probe optional Spotify endpoints.
    ProbeEndpoints,
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
    /// Re-login required (token expired / revoked).
    AuthRequired { reason: String },
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
    /// Search results.
    SearchResults {
        query: String,
        tracks: Vec<Track>,
        total: usize,
        is_cached: bool,
    },
    /// Probed endpoints status.
    ProbeResult { probes: Vec<EndpointProbe> },
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
}
