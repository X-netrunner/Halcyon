//! Playback backends (Part 2, Step B).
//!
//! Two ways to play music sit behind one small trait:
//!
//! - [`DirectBackend`] is the engine the daemon always had (`audio::AudioEngine`): a private
//!   librespot player that the GUI's [`PlayerState`] drives. Nothing about it changed.
//! - [`SpircBackend`] (needs `--features connect` and `HALCYON_CONNECT=1`) registers Halcyon as a
//!   Spotify Connect device and lets Spirc own playback, so a phone can see it, transfer to it and
//!   change its volume. The GUI protocol is unchanged: [`PlayerState`] stays the single thing the
//!   GUI reads and writes, and this module keeps it and Spirc in step.
//!
//! How the two are kept in step (the part that can go wrong, so it is pure and tested):
//!
//! - GUI -> device: every 250 ms [`plan_commands`] compares the state with a [`Mirror`] (what the
//!   device is known to be doing) and returns the few [`TransportCmd`]s that close the gap.
//! - device -> GUI: librespot player events are turned into [`DeviceEvent`]s, then into an
//!   [`Edit`] of the state by [`event_to_edit`]. The mirror is updated in the same step, so an
//!   event does not come back as a command (no feedback loop).
//! - Stale events: right after Halcyon moves the device to another track, late events about the
//!   old track are ignored for a short time, otherwise they would move the GUI back.
//!
//! Nothing here touches librespot types, so all of it runs in the default build and in tests.
//! The only librespot-facing code is `connect_backend.rs` (feature `connect`).

use crate::audio::AudioEngine;
use crate::cache::Cache;
use crate::connect::{connect_to_percent, percent_to_connect};
use crate::daemon::Player;
use halcyon_music_core::protocol::{self, EventBody};
use halcyon_music_core::state::RepeatMode;
use halcyon_music_core::{PlayerState, Track};
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use tokio::sync::broadcast;
use tracing::{info, warn};

/// A difference this large between the state's position and the last position the device
/// reported means the user moved it: forward it as a seek (same value the direct engine uses).
pub const SEEK_JUMP_MS: u64 = 1_500;
/// After Halcyon moves the device off a track, events about that track are ignored this long.
pub const STALE_GRACE_MS: u64 = 4_000;
/// Longest history kept when the phone plays music Halcyon never heard of.
pub const FOREIGN_HISTORY_MAX: usize = 200;

// ---------------------------------------------------------------------------------------------
// Backend choice and the trait
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    Direct,
    Spirc,
}

/// Spirc only when it is asked for (`HALCYON_CONNECT`) AND this binary contains it.
pub fn choose_backend(requested: bool, compiled_in: bool) -> BackendKind {
    if requested && compiled_in {
        BackendKind::Spirc
    } else {
        BackendKind::Direct
    }
}

/// True when a session error says the account cannot stream (Spotify Free).
pub fn is_free_account_error(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("free") || lower.contains("premium")
}

/// Why a Spirc run ended without being asked to stop.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunEnd {
    /// Rebuild and register again (for example the audio quality changed).
    Restart,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunError {
    /// This account or build cannot be a Connect device: fall back to the direct engine.
    Unsupported(String),
    /// Something failed that a retry (with backoff, by the supervisor) may fix.
    Failed(String),
}

/// One way of playing music. `run` never returns while the backend is healthy; an `Err` makes
/// the supervisor restart it with backoff.
pub trait PlaybackBackend: Send {
    fn kind(&self) -> BackendKind;
    fn run(self: Box<Self>) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>>;
}

pub struct DirectBackend {
    player: Arc<Player>,
    cache: Cache,
    events: broadcast::Sender<protocol::Event>,
}

impl DirectBackend {
    pub fn new(
        player: Arc<Player>,
        cache: Cache,
        events: broadcast::Sender<protocol::Event>,
    ) -> Self {
        Self {
            player,
            cache,
            events,
        }
    }
}

impl PlaybackBackend for DirectBackend {
    fn kind(&self) -> BackendKind {
        BackendKind::Direct
    }

    fn run(self: Box<Self>) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>> {
        Box::pin(async move {
            let DirectBackend {
                player,
                cache,
                events,
            } = *self;
            let engine = Arc::new(AudioEngine::new(player, cache, events));
            engine.run_loop().await;
            Ok(())
        })
    }
}

pub struct SpircBackend {
    player: Arc<Player>,
    cache: Cache,
    events: broadcast::Sender<protocol::Event>,
}

impl SpircBackend {
    pub fn new(
        player: Arc<Player>,
        cache: Cache,
        events: broadcast::Sender<protocol::Event>,
    ) -> Self {
        Self {
            player,
            cache,
            events,
        }
    }
}

impl PlaybackBackend for SpircBackend {
    fn kind(&self) -> BackendKind {
        BackendKind::Spirc
    }

    fn run(self: Box<Self>) -> Pin<Box<dyn Future<Output = anyhow::Result<()>> + Send>> {
        Box::pin(async move {
            let SpircBackend {
                player,
                cache,
                events,
            } = *self;
            loop {
                match run_once(player.clone(), cache.clone(), events.clone()).await {
                    Ok(RunEnd::Restart) => {
                        info!("connect backend restarting");
                        continue;
                    }
                    Err(RunError::Unsupported(why)) => {
                        // Keep the app playing music: the old engine does not need Connect.
                        warn!("Spotify Connect is not available ({why}); using the direct engine");
                        let _ =
                            events.send(protocol::event(EventBody::ConnectDevice { name: None }));
                        return Box::new(DirectBackend::new(player, cache, events))
                            .run()
                            .await;
                    }
                    Err(RunError::Failed(why)) => return Err(anyhow::anyhow!(why)),
                }
            }
        })
    }
}

#[cfg(feature = "connect")]
use crate::connect_backend::run_once;

/// Without the feature there is no Spirc code: report "unsupported" so the caller falls back.
#[cfg(not(feature = "connect"))]
async fn run_once(
    _player: Arc<Player>,
    _cache: Cache,
    _events: broadcast::Sender<protocol::Event>,
) -> Result<RunEnd, RunError> {
    Err(RunError::Unsupported(
        "this build has no Spotify Connect code".to_string(),
    ))
}

/// The backend for this process: decided once per (re)start of the supervised player task.
pub fn select_backend(
    player: Arc<Player>,
    cache: Cache,
    events: broadcast::Sender<protocol::Event>,
) -> Box<dyn PlaybackBackend> {
    match choose_backend(crate::connect::enabled(), crate::connect::compiled_in()) {
        BackendKind::Spirc => Box::new(SpircBackend::new(player, cache, events)),
        BackendKind::Direct => Box::new(DirectBackend::new(player, cache, events)),
    }
}

// ---------------------------------------------------------------------------------------------
// Ids
// ---------------------------------------------------------------------------------------------

/// `spotify:track:<id>` -> `<id>`. Anything else (episodes, local files) is not a track.
pub fn track_id_from_uri(uri: &str) -> Option<String> {
    let mut parts = uri.split(':');
    if parts.next()? != "spotify" || parts.next()? != "track" {
        return None;
    }
    let id = parts.next()?;
    if id.is_empty() || parts.next().is_some() {
        return None;
    }
    Some(id.to_string())
}

/// The URI to hand to Spirc for a track (same rule the direct engine uses).
pub fn track_uri(track: &Track) -> String {
    if track.uri.starts_with("spotify:track:") {
        track.uri.clone()
    } else {
        format!("spotify:track:{}", track.id)
    }
}

// ---------------------------------------------------------------------------------------------
// GUI -> device
// ---------------------------------------------------------------------------------------------

/// What Halcyon can ask the Connect device to do. The adapter turns each into one Spirc call.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TransportCmd {
    /// Make this device the active one (needed before the first load).
    Activate,
    /// Load this list and start at `index`.
    Load {
        uris: Vec<String>,
        index: usize,
        start_playing: bool,
        position_ms: u32,
    },
    Play,
    Pause,
    Next,
    Prev,
    Seek(u32),
    /// Connect scale, 0..=65535.
    SetVolume(u16),
    Shuffle(bool),
    Repeat(RepeatMode),
}

/// The one seam to Spirc. A mock records commands in tests.
pub trait ConnectTransport {
    fn send(&mut self, cmd: &TransportCmd) -> Result<(), String>;
}

/// What the device is known to be doing. Kept in step with the state by [`plan_commands`] (for
/// what Halcyon sent) and [`event_to_edit`] (for what the device reported).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mirror {
    /// The device has a loaded context (set by our load or by any playing/paused event).
    pub active: bool,
    pub playing: bool,
    /// Ids of the list the device holds, in order. Equal to the state's queue when in step.
    pub queue_ids: Vec<String>,
    pub index: usize,
    pub track_id: Option<String>,
    pub position_ms: u64,
    pub volume: u8,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    /// The queue came from the phone (music Halcyon did not start), not from the GUI.
    pub foreign: bool,
    /// A track Halcyon just left, and until when (monotonic ms) its events are ignored.
    pub stale: Option<(String, u64)>,
}

impl Mirror {
    pub fn new(volume: u8) -> Self {
        Self {
            active: false,
            playing: false,
            queue_ids: Vec::new(),
            index: 0,
            track_id: None,
            position_ms: 0,
            volume: volume.min(100),
            shuffle: false,
            repeat: RepeatMode::Off,
            foreign: false,
            stale: None,
        }
    }
}

fn is_user_seek(state_pos_ms: u64, last_reported_ms: u64) -> bool {
    state_pos_ms.abs_diff(last_reported_ms) > SEEK_JUMP_MS
}

fn queue_ids(state: &PlayerState) -> Vec<String> {
    state.queue.iter().map(|t| t.id.clone()).collect()
}

/// Commands that make the device match `state`. `mirror` is updated as if they all succeed
/// (a failed command is logged by [`reconcile`] and not retried every tick).
pub fn plan_commands(state: &PlayerState, m: &mut Mirror, now_ms: u64) -> Vec<TransportCmd> {
    let mut out = Vec::new();
    let cur = state.track.as_ref();

    match cur {
        Some(cur) if !state.queue.is_empty() => {
            let ids = queue_ids(state);
            let same_queue = ids == m.queue_ids;
            let on_track = m.track_id.as_deref() == Some(cur.id.as_str());

            if !same_queue || !m.active {
                // Do not wake the device (and show "Halcyon" as the active device on the phone)
                // just because the app opened with a saved queue. Wait for a real play.
                if state.playing || m.active {
                    push_load(&mut out, state, m, ids, now_ms);
                }
            } else if !on_track {
                // Same list, different track: the user pressed next/previous or picked a row.
                let delta = state.queue_pos as i64 - m.index as i64;
                if delta == 1 || delta == -1 {
                    let left = m.track_id.clone();
                    out.push(if delta == 1 {
                        TransportCmd::Next
                    } else {
                        TransportCmd::Prev
                    });
                    // What Spirc does to the play state on a skip is not documented: say it.
                    out.push(if state.playing {
                        TransportCmd::Play
                    } else {
                        TransportCmd::Pause
                    });
                    m.index = state.queue_pos;
                    m.track_id = Some(cur.id.clone());
                    m.playing = state.playing;
                    m.position_ms = state.position_ms;
                    set_stale(m, left, &cur.id, now_ms);
                } else {
                    push_load(&mut out, state, m, ids, now_ms);
                }
            } else {
                if state.playing != m.playing {
                    out.push(if state.playing {
                        TransportCmd::Play
                    } else {
                        TransportCmd::Pause
                    });
                    m.playing = state.playing;
                }
                if is_user_seek(state.position_ms, m.position_ms) {
                    out.push(TransportCmd::Seek(
                        u32::try_from(state.position_ms).unwrap_or(u32::MAX),
                    ));
                    m.position_ms = state.position_ms;
                }
            }
        }
        _ => {
            // Nothing to play: make sure the device is not left playing the old list.
            if m.active && m.playing {
                out.push(TransportCmd::Pause);
                m.playing = false;
            }
        }
    }

    if state.volume != m.volume {
        out.push(TransportCmd::SetVolume(percent_to_connect(state.volume)));
        m.volume = state.volume;
    }
    // Shuffle and repeat only mean something once the device holds a list.
    if m.active {
        if state.shuffle != m.shuffle {
            out.push(TransportCmd::Shuffle(state.shuffle));
            m.shuffle = state.shuffle;
        }
        if state.repeat != m.repeat {
            out.push(TransportCmd::Repeat(state.repeat));
            m.repeat = state.repeat;
        }
    }
    out
}

fn set_stale(m: &mut Mirror, left: Option<String>, arrived: &str, now_ms: u64) {
    m.stale = match left {
        Some(id) if id != arrived => Some((id, now_ms.saturating_add(STALE_GRACE_MS))),
        _ => None,
    };
}

fn push_load(
    out: &mut Vec<TransportCmd>,
    state: &PlayerState,
    m: &mut Mirror,
    ids: Vec<String>,
    now_ms: u64,
) {
    let Some(cur) = state.track.as_ref() else {
        return;
    };
    if !m.active {
        out.push(TransportCmd::Activate);
    }
    out.push(TransportCmd::Load {
        uris: state.queue.iter().map(track_uri).collect(),
        index: state.queue_pos,
        start_playing: state.playing,
        position_ms: u32::try_from(state.position_ms).unwrap_or(0),
    });
    let left = m.track_id.clone();
    m.active = true;
    m.queue_ids = ids;
    m.index = state.queue_pos;
    m.track_id = Some(cur.id.clone());
    m.playing = state.playing;
    m.position_ms = state.position_ms;
    m.foreign = false;
    set_stale(m, left, &cur.id, now_ms);
}

/// Plan and send. Returns what was sent (for tests and logs). A failed send is logged once and
/// not retried by the next tick: the mirror already assumes success, and a dead Spirc ends the
/// run anyway.
pub fn reconcile(
    state: &PlayerState,
    m: &mut Mirror,
    transport: &mut dyn ConnectTransport,
    now_ms: u64,
) -> Vec<TransportCmd> {
    let cmds = plan_commands(state, m, now_ms);
    for cmd in &cmds {
        if let Err(e) = transport.send(cmd) {
            warn!(command = command_name(cmd), error = %e, "connect command failed");
        }
    }
    cmds
}

fn command_name(cmd: &TransportCmd) -> &'static str {
    match cmd {
        TransportCmd::Activate => "activate",
        TransportCmd::Load { .. } => "load",
        TransportCmd::Play => "play",
        TransportCmd::Pause => "pause",
        TransportCmd::Next => "next",
        TransportCmd::Prev => "prev",
        TransportCmd::Seek(_) => "seek",
        TransportCmd::SetVolume(_) => "volume",
        TransportCmd::Shuffle(_) => "shuffle",
        TransportCmd::Repeat(_) => "repeat",
    }
}

// ---------------------------------------------------------------------------------------------
// Device -> GUI
// ---------------------------------------------------------------------------------------------

/// What the device told us, free of librespot types.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceEvent {
    Playing {
        track_id: String,
        position_ms: u64,
    },
    Paused {
        track_id: String,
        position_ms: u64,
    },
    Position {
        track_id: String,
        position_ms: u64,
    },
    EndOfTrack {
        track_id: String,
    },
    Unavailable {
        track_id: String,
    },
    Stopped,
    /// Connect scale, 0..=65535.
    Volume(u16),
}

/// A track the device plays that Halcyon has no metadata for (the phone started it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Unknown {
    pub track_id: String,
    pub playing: Option<bool>,
    pub position_ms: u64,
}

/// Changes to make to the state. Applied under the state's lock by [`apply_edit`], so a GUI
/// command that arrived in between is not overwritten with a stale copy.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Edit {
    pub playing: Option<bool>,
    pub position_ms: Option<u64>,
    pub volume: Option<u8>,
    /// Make this queue entry (index, track id) the current track.
    pub select: Option<(usize, String)>,
    /// Replace the queue (music the phone started): the list and the current index.
    pub adopt: Option<(Vec<Track>, usize)>,
    /// The device is on a track Halcyon cannot place: resolve it, then call [`adopt_foreign`].
    pub unknown: Option<Unknown>,
    /// A track finished (play log).
    pub ended: Option<String>,
    /// A track could not be played (toast).
    pub unavailable: Option<String>,
}

impl Edit {
    /// True when the GUI has something to redraw (position-only edits are throttled elsewhere).
    pub fn changes_view(&self) -> bool {
        self.playing.is_some()
            || self.volume.is_some()
            || self.select.is_some()
            || self.adopt.is_some()
    }
}

/// Where the track sits in the queue: at the current position, else after it, else anywhere.
pub fn locate(state: &PlayerState, id: &str) -> Option<usize> {
    if state.queue.get(state.queue_pos).is_some_and(|t| t.id == id) {
        return Some(state.queue_pos);
    }
    state
        .queue
        .iter()
        .enumerate()
        .skip(state.queue_pos.saturating_add(1))
        .find(|(_, t)| t.id == id)
        .map(|(i, _)| i)
        .or_else(|| state.queue.iter().position(|t| t.id == id))
}

/// Turn one device event into a state edit and update the mirror to match.
pub fn event_to_edit(state: &PlayerState, m: &mut Mirror, ev: &DeviceEvent, now_ms: u64) -> Edit {
    let mut edit = Edit::default();
    match ev {
        DeviceEvent::Volume(raw) => {
            let percent = connect_to_percent(*raw);
            m.volume = percent;
            if percent != state.volume {
                edit.volume = Some(percent);
            }
        }
        DeviceEvent::Stopped => {
            // Playback was moved away (or the list ended): the device holds nothing to resume.
            m.playing = false;
            m.active = false;
            if state.playing {
                edit.playing = Some(false);
            }
        }
        DeviceEvent::EndOfTrack { track_id } => {
            if state.queue.iter().any(|t| t.id == *track_id) {
                edit.ended = Some(track_id.clone());
            }
        }
        DeviceEvent::Unavailable { track_id } => {
            edit.unavailable = Some(track_id.clone());
        }
        DeviceEvent::Playing {
            track_id,
            position_ms,
        }
        | DeviceEvent::Paused {
            track_id,
            position_ms,
        }
        | DeviceEvent::Position {
            track_id,
            position_ms,
        } => {
            if is_stale(m, track_id, now_ms) {
                return edit;
            }
            let flag = match ev {
                DeviceEvent::Playing { .. } => Some(true),
                DeviceEvent::Paused { .. } => Some(false),
                _ => None,
            };
            match locate(state, track_id) {
                Some(idx) => {
                    let current = state.track.as_ref().map(|t| t.id.as_str())
                        == Some(track_id.as_str())
                        && state.queue_pos == idx;
                    if !current {
                        edit.select = Some((idx, track_id.clone()));
                    }
                    m.index = idx;
                    m.track_id = Some(track_id.clone());
                    m.active = true;
                    if let Some(playing) = flag {
                        m.playing = playing;
                        if playing != state.playing {
                            edit.playing = Some(playing);
                        }
                    }
                    // A seek the user just made has not been forwarded yet: keep it.
                    if current && is_user_seek(state.position_ms, m.position_ms) {
                        return edit;
                    }
                    m.position_ms = *position_ms;
                    edit.position_ms = Some(*position_ms);
                }
                None => {
                    m.active = true;
                    if let Some(playing) = flag {
                        m.playing = playing;
                    }
                    edit.unknown = Some(Unknown {
                        track_id: track_id.clone(),
                        playing: flag,
                        position_ms: *position_ms,
                    });
                }
            }
        }
    }
    edit
}

fn is_stale(m: &mut Mirror, track_id: &str, now_ms: u64) -> bool {
    let Some((old, until)) = m.stale.clone() else {
        return false;
    };
    if now_ms < until && old == track_id {
        return true;
    }
    // Either the grace ran out, or the device moved on to something else: it is over.
    m.stale = None;
    false
}

/// The phone started music Halcyon has no queue for. The first such track replaces the queue;
/// the ones that follow are appended, so the queue drawer shows what played on the phone.
/// Returns the edit that installs it, and updates the mirror so no command is sent back.
pub fn adopt_foreign(state: &PlayerState, m: &mut Mirror, track: Track, u: &Unknown) -> Edit {
    let mut queue = if m.foreign {
        state.queue.clone()
    } else {
        Vec::new()
    };
    queue.push(track.clone());
    if queue.len() > FOREIGN_HISTORY_MAX {
        let extra = queue.len() - FOREIGN_HISTORY_MAX;
        queue.drain(0..extra);
    }
    let pos = queue.len().saturating_sub(1);
    m.foreign = true;
    m.queue_ids = queue.iter().map(|t| t.id.clone()).collect();
    m.index = pos;
    m.track_id = Some(track.id);
    m.position_ms = u.position_ms;
    Edit {
        adopt: Some((queue, pos)),
        playing: u.playing,
        position_ms: Some(u.position_ms),
        ..Edit::default()
    }
}

/// Write an edit into the state. Safe to call on a state that changed since the edit was planned.
pub fn apply_edit(s: &mut PlayerState, e: &Edit) {
    if let Some((queue, pos)) = &e.adopt {
        s.queue = queue.clone();
        s.queue_pos = (*pos).min(s.queue.len().saturating_sub(1));
        s.track = s.queue.get(s.queue_pos).cloned();
        s.position_ms = 0;
    }
    if let Some((idx, id)) = &e.select {
        let at = if s.queue.get(*idx).is_some_and(|t| t.id == *id) {
            Some(*idx)
        } else {
            s.queue.iter().position(|t| t.id == *id)
        };
        if let Some(i) = at {
            s.queue_pos = i;
            s.track = s.queue.get(i).cloned();
            s.position_ms = 0;
        }
    }
    if let Some(p) = e.playing {
        s.playing = p;
    }
    if let Some(p) = e.position_ms {
        s.position_ms = p;
    }
    if let Some(v) = e.volume {
        s.volume = v.min(100);
    }
}

// ---------------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str) -> Track {
        Track {
            id: id.into(),
            title: format!("Song {id}"),
            artist: "Artist".into(),
            artists: vec!["Artist".into()],
            album: "Album".into(),
            album_id: None,
            duration_ms: 200_000,
            art_url: None,
            uri: format!("spotify:track:{id}"),
        }
    }

    fn state(ids: &[&str], pos: usize, playing: bool) -> PlayerState {
        let mut s = PlayerState::default();
        s.play_context(ids.iter().map(|i| track(i)).collect(), pos);
        s.playing = playing;
        s.volume = 50;
        s
    }

    #[derive(Default)]
    struct Mock {
        sent: Vec<TransportCmd>,
        fail: bool,
    }
    impl ConnectTransport for Mock {
        fn send(&mut self, cmd: &TransportCmd) -> Result<(), String> {
            self.sent.push(cmd.clone());
            if self.fail {
                Err("boom".into())
            } else {
                Ok(())
            }
        }
    }

    // --- choice ---------------------------------------------------------------------------

    #[test]
    fn spirc_needs_the_flag_and_the_code() {
        assert_eq!(choose_backend(true, true), BackendKind::Spirc);
        assert_eq!(choose_backend(true, false), BackendKind::Direct);
        assert_eq!(choose_backend(false, true), BackendKind::Direct);
        assert_eq!(choose_backend(false, false), BackendKind::Direct);
    }

    #[test]
    fn free_account_errors_are_recognised() {
        assert!(is_free_account_error("Premium account required"));
        assert!(is_free_account_error("this is a FREE account"));
        assert!(!is_free_account_error("connection refused"));
    }

    #[test]
    fn track_ids_come_only_from_track_uris() {
        assert_eq!(
            track_id_from_uri("spotify:track:abc123"),
            Some("abc123".into())
        );
        assert_eq!(track_id_from_uri("spotify:episode:abc"), None);
        assert_eq!(track_id_from_uri("spotify:track:"), None);
        assert_eq!(track_id_from_uri("spotify:track:a:b"), None);
        assert_eq!(track_id_from_uri("garbage"), None);
    }

    #[test]
    fn track_uri_falls_back_to_the_id() {
        let mut t = track("x1");
        assert_eq!(track_uri(&t), "spotify:track:x1");
        t.uri = "local:file".into();
        assert_eq!(track_uri(&t), "spotify:track:x1");
    }

    // --- GUI -> device --------------------------------------------------------------------

    #[test]
    fn opening_the_app_with_a_saved_queue_does_not_wake_the_device() {
        let s = state(&["a", "b"], 0, false);
        let mut m = Mirror::new(50);
        assert!(plan_commands(&s, &mut m, 0).is_empty());
        assert!(!m.active);
    }

    #[test]
    fn first_play_activates_then_loads_the_whole_list() {
        let mut s = state(&["a", "b", "c"], 1, true);
        s.position_ms = 12_000;
        let mut m = Mirror::new(50);
        let cmds = plan_commands(&s, &mut m, 0);
        assert_eq!(cmds.len(), 2, "{cmds:?}");
        assert_eq!(cmds.first(), Some(&TransportCmd::Activate));
        match cmds.get(1) {
            Some(TransportCmd::Load {
                uris,
                index,
                start_playing,
                position_ms,
            }) => {
                assert_eq!(uris.len(), 3);
                assert_eq!(*index, 1);
                assert!(*start_playing);
                assert_eq!(*position_ms, 12_000);
            }
            other => panic!("expected a load, got {other:?}"),
        }
        assert!(m.active && m.playing);
        assert_eq!(m.track_id.as_deref(), Some("b"));
    }

    #[test]
    fn a_second_tick_with_nothing_new_sends_nothing() {
        let s = state(&["a", "b"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        assert!(plan_commands(&s, &mut m, 250).is_empty());
    }

    #[test]
    fn pause_play_and_seek_are_forwarded() {
        let mut s = state(&["a", "b"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);

        s.playing = false;
        assert_eq!(plan_commands(&s, &mut m, 250), vec![TransportCmd::Pause]);
        s.playing = true;
        assert_eq!(plan_commands(&s, &mut m, 500), vec![TransportCmd::Play]);

        s.position_ms = 90_000;
        assert_eq!(
            plan_commands(&s, &mut m, 750),
            vec![TransportCmd::Seek(90_000)]
        );
        // normal drift is not a seek
        s.position_ms = 90_900;
        assert!(plan_commands(&s, &mut m, 1000).is_empty());
    }

    #[test]
    fn next_and_previous_are_skips_not_reloads() {
        let mut s = state(&["a", "b", "c"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);

        assert!(s.advance_next());
        assert_eq!(
            plan_commands(&s, &mut m, 250),
            vec![TransportCmd::Next, TransportCmd::Play]
        );
        assert_eq!(m.index, 1);
        assert!(s.advance_prev());
        assert_eq!(
            plan_commands(&s, &mut m, 500),
            vec![TransportCmd::Prev, TransportCmd::Play]
        );
        // paused skip says pause explicitly
        s.playing = false;
        let _ = plan_commands(&s, &mut m, 750);
        assert!(s.advance_next());
        assert_eq!(
            plan_commands(&s, &mut m, 1000),
            vec![TransportCmd::Next, TransportCmd::Pause]
        );
    }

    #[test]
    fn jumping_inside_the_list_reloads_at_the_new_index() {
        let mut s = state(&["a", "b", "c", "d"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        s.queue_pos = 3;
        s.track = s.queue.get(3).cloned();
        let cmds = plan_commands(&s, &mut m, 250);
        assert!(
            matches!(cmds.first(), Some(TransportCmd::Load { index: 3, .. })),
            "{cmds:?}"
        );
    }

    #[test]
    fn changing_the_queue_reloads_the_list_keeping_track_and_position() {
        let mut s = state(&["a", "b"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        s.position_ms = 30_000;
        m.position_ms = 30_000;
        s.enqueue(track("z"));
        let cmds = plan_commands(&s, &mut m, 250);
        match cmds.first() {
            Some(TransportCmd::Load {
                uris,
                index,
                position_ms,
                start_playing,
            }) => {
                assert_eq!(uris.len(), 3);
                assert_eq!(*index, 0);
                assert_eq!(*position_ms, 30_000);
                assert!(*start_playing);
            }
            other => panic!("expected a load, got {other:?}"),
        }
        assert!(!cmds.contains(&TransportCmd::Activate), "already active");
    }

    #[test]
    fn volume_shuffle_and_repeat_are_forwarded_once() {
        let mut s = state(&["a"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        s.volume = 80;
        s.shuffle = true;
        s.repeat = RepeatMode::One;
        let cmds = plan_commands(&s, &mut m, 250);
        assert_eq!(
            cmds,
            vec![
                TransportCmd::SetVolume(percent_to_connect(80)),
                TransportCmd::Shuffle(true),
                TransportCmd::Repeat(RepeatMode::One),
            ]
        );
        assert!(plan_commands(&s, &mut m, 500).is_empty());
    }

    #[test]
    fn volume_is_sent_even_before_the_device_is_active_but_shuffle_waits() {
        let mut s = state(&["a"], 0, false);
        s.volume = 20;
        s.shuffle = true;
        let mut m = Mirror::new(50);
        let cmds = plan_commands(&s, &mut m, 0);
        assert_eq!(cmds, vec![TransportCmd::SetVolume(percent_to_connect(20))]);
    }

    #[test]
    fn an_emptied_queue_pauses_a_playing_device() {
        let mut s = state(&["a"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        s.queue.clear();
        s.sanitize();
        assert_eq!(plan_commands(&s, &mut m, 250), vec![TransportCmd::Pause]);
    }

    #[test]
    fn reconcile_sends_through_the_transport_and_survives_errors() {
        let s = state(&["a", "b"], 0, true);
        let mut m = Mirror::new(50);
        let mut t = Mock {
            fail: true,
            ..Mock::default()
        };
        let cmds = reconcile(&s, &mut m, &mut t, 0);
        assert_eq!(t.sent, cmds);
        assert!(!cmds.is_empty());
        // a failed command is not repeated every tick
        assert!(reconcile(&s, &mut m, &mut t, 250).is_empty());
    }

    // --- device -> GUI --------------------------------------------------------------------

    fn playing(id: &str, pos: u64) -> DeviceEvent {
        DeviceEvent::Playing {
            track_id: id.into(),
            position_ms: pos,
        }
    }

    #[test]
    fn phone_pause_and_resume_reach_the_state_without_an_echo() {
        let mut s = state(&["a", "b"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);

        let paused = DeviceEvent::Paused {
            track_id: "a".into(),
            position_ms: 5_000,
        };
        let edit = event_to_edit(&s, &mut m, &paused, 100);
        assert_eq!(edit.playing, Some(false));
        apply_edit(&mut s, &edit);
        assert!(!s.playing);
        assert_eq!(s.position_ms, 5_000);
        assert!(
            plan_commands(&s, &mut m, 250).is_empty(),
            "no command echoed back"
        );

        let edit = event_to_edit(&s, &mut m, &playing("a", 5_000), 300);
        apply_edit(&mut s, &edit);
        assert!(s.playing);
        assert!(plan_commands(&s, &mut m, 500).is_empty());
    }

    #[test]
    fn natural_advance_moves_the_queue_position_without_commands() {
        let mut s = state(&["a", "b", "c"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        let edit = event_to_edit(&s, &mut m, &playing("b", 0), 100);
        assert_eq!(edit.select, Some((1, "b".into())));
        apply_edit(&mut s, &edit);
        assert_eq!(s.queue_pos, 1);
        assert_eq!(s.track.as_ref().map(|t| t.id.as_str()), Some("b"));
        assert!(plan_commands(&s, &mut m, 250).is_empty());
    }

    #[test]
    fn phone_skip_inside_the_list_follows_the_device_even_when_shuffled() {
        let mut s = state(&["a", "b", "c", "d"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        let edit = event_to_edit(&s, &mut m, &playing("d", 0), 100);
        apply_edit(&mut s, &edit);
        assert_eq!(s.queue_pos, 3);
        assert!(plan_commands(&s, &mut m, 250).is_empty());
    }

    #[test]
    fn late_events_about_the_track_we_just_left_are_ignored() {
        let mut s = state(&["a", "b", "c"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        assert!(s.advance_next());
        let _ = plan_commands(&s, &mut m, 1_000); // Next sent, "a" is now stale until 5_000

        // the device still reports "a": must not move the GUI back or trigger Prev
        let late = DeviceEvent::Position {
            track_id: "a".into(),
            position_ms: 40_000,
        };
        let edit = event_to_edit(&s, &mut m, &late, 1_100);
        assert_eq!(edit, Edit::default());
        assert!(plan_commands(&s, &mut m, 1_250).is_empty());

        // once the device reports the new track the grace ends
        let edit = event_to_edit(&s, &mut m, &playing("b", 0), 1_400);
        apply_edit(&mut s, &edit);
        assert!(m.stale.is_none());
        // and after the grace window a real move back to "a" is believed
        let edit = event_to_edit(&s, &mut m, &playing("a", 0), 9_000);
        assert_eq!(edit.select, Some((0, "a".into())));
    }

    #[test]
    fn stale_grace_expires_by_time() {
        let mut s = state(&["a", "b"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        assert!(s.advance_next());
        let _ = plan_commands(&s, &mut m, 1_000);
        let late = DeviceEvent::Position {
            track_id: "a".into(),
            position_ms: 1,
        };
        // after the window the device is believed
        let edit = event_to_edit(&s, &mut m, &late, 1_000 + STALE_GRACE_MS + 1);
        assert_eq!(edit.select, Some((0, "a".into())));
    }

    #[test]
    fn phone_volume_lands_in_the_state_once() {
        let mut s = state(&["a"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        let edit = event_to_edit(
            &s,
            &mut m,
            &DeviceEvent::Volume(percent_to_connect(30)),
            100,
        );
        assert_eq!(edit.volume, Some(30));
        apply_edit(&mut s, &edit);
        assert_eq!(s.volume, 30);
        assert!(plan_commands(&s, &mut m, 250).is_empty(), "no echo");
        // the same volume again is not an edit
        let edit = event_to_edit(
            &s,
            &mut m,
            &DeviceEvent::Volume(percent_to_connect(30)),
            300,
        );
        assert!(edit.volume.is_none());
    }

    #[test]
    fn a_seek_the_user_just_made_is_not_overwritten_by_a_stale_position() {
        let mut s = state(&["a"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        let _ = event_to_edit(
            &s,
            &mut m,
            &DeviceEvent::Position {
                track_id: "a".into(),
                position_ms: 10_000,
            },
            100,
        );
        s.position_ms = 120_000; // the user dragged the slider
        let edit = event_to_edit(
            &s,
            &mut m,
            &DeviceEvent::Position {
                track_id: "a".into(),
                position_ms: 10_250,
            },
            200,
        );
        assert!(edit.position_ms.is_none());
        assert_eq!(
            plan_commands(&s, &mut m, 250),
            vec![TransportCmd::Seek(120_000)]
        );
    }

    #[test]
    fn stopped_means_the_next_play_loads_again() {
        let mut s = state(&["a", "b"], 0, true);
        let mut m = Mirror::new(50);
        let _ = plan_commands(&s, &mut m, 0);
        let edit = event_to_edit(&s, &mut m, &DeviceEvent::Stopped, 100);
        apply_edit(&mut s, &edit);
        assert!(!s.playing);
        assert!(!m.active);
        assert!(
            plan_commands(&s, &mut m, 250).is_empty(),
            "paused and inactive: stay quiet"
        );
        s.playing = true; // the user presses play
        let cmds = plan_commands(&s, &mut m, 500);
        assert_eq!(cmds.first(), Some(&TransportCmd::Activate));
        assert!(matches!(
            cmds.get(1),
            Some(TransportCmd::Load {
                start_playing: true,
                ..
            })
        ));
    }

    #[test]
    fn music_started_on_the_phone_replaces_then_extends_the_queue() {
        let mut s = state(&["a", "b"], 0, false);
        let mut m = Mirror::new(50);

        let ev = playing("x", 1_000);
        let edit = event_to_edit(&s, &mut m, &ev, 100);
        let unknown = edit.unknown.clone().expect("unknown track");
        assert_eq!(unknown.track_id, "x");
        let adopted = adopt_foreign(&s, &mut m, track("x"), &unknown);
        apply_edit(&mut s, &adopted);
        assert_eq!(queue_ids(&s), vec!["x".to_string()]);
        assert!(s.playing);
        assert_eq!(s.position_ms, 1_000);
        assert!(m.foreign);
        assert!(
            plan_commands(&s, &mut m, 250).is_empty(),
            "adopting must not send a load"
        );

        // the next track of the phone's context is appended, history stays
        let edit = event_to_edit(&s, &mut m, &playing("y", 0), 5_000);
        let unknown = edit.unknown.clone().expect("unknown track");
        let adopted = adopt_foreign(&s, &mut m, track("y"), &unknown);
        apply_edit(&mut s, &adopted);
        assert_eq!(queue_ids(&s), vec!["x".to_string(), "y".to_string()]);
        assert_eq!(s.queue_pos, 1);
        assert!(plan_commands(&s, &mut m, 5_250).is_empty());

        // a track already in the history is found, not adopted again
        let edit = event_to_edit(&s, &mut m, &playing("x", 0), 9_000);
        assert!(edit.unknown.is_none());
        assert_eq!(edit.select, Some((0, "x".into())));
    }

    #[test]
    fn foreign_history_is_bounded() {
        let mut s = PlayerState::default();
        let mut m = Mirror::new(50);
        for i in 0..(FOREIGN_HISTORY_MAX + 30) {
            let u = Unknown {
                track_id: format!("t{i}"),
                playing: Some(true),
                position_ms: 0,
            };
            let e = adopt_foreign(&s, &mut m, track(&format!("t{i}")), &u);
            apply_edit(&mut s, &e);
        }
        assert_eq!(s.queue.len(), FOREIGN_HISTORY_MAX);
        assert_eq!(s.queue_pos, FOREIGN_HISTORY_MAX - 1);
        assert_eq!(m.queue_ids.len(), FOREIGN_HISTORY_MAX);
    }

    #[test]
    fn gui_picking_something_after_phone_music_makes_the_queue_ours_again() {
        let mut s = PlayerState::default();
        let mut m = Mirror::new(50);
        let u = Unknown {
            track_id: "x".into(),
            playing: Some(true),
            position_ms: 0,
        };
        let e = adopt_foreign(&s, &mut m, track("x"), &u);
        apply_edit(&mut s, &e);
        assert!(m.foreign);
        s.play_context(vec![track("p"), track("q")], 0);
        let cmds = plan_commands(&s, &mut m, 1_000);
        assert!(
            cmds.iter().any(|c| matches!(c, TransportCmd::Load { .. })),
            "{cmds:?}"
        );
        assert!(!m.foreign);
    }

    #[test]
    fn end_of_track_is_reported_only_for_known_tracks() {
        let s = state(&["a", "b"], 0, true);
        let mut m = Mirror::new(50);
        let e = event_to_edit(
            &s,
            &mut m,
            &DeviceEvent::EndOfTrack {
                track_id: "a".into(),
            },
            0,
        );
        assert_eq!(e.ended.as_deref(), Some("a"));
        let e = event_to_edit(
            &s,
            &mut m,
            &DeviceEvent::EndOfTrack {
                track_id: "zzz".into(),
            },
            0,
        );
        assert!(e.ended.is_none());
    }

    #[test]
    fn apply_edit_survives_a_queue_that_changed_meanwhile() {
        let mut s = state(&["a", "b", "c"], 0, true);
        let edit = Edit {
            select: Some((2, "c".into())),
            ..Edit::default()
        };
        s.dequeue(1); // "c" is now at index 1
        apply_edit(&mut s, &edit);
        assert_eq!(s.track.as_ref().map(|t| t.id.as_str()), Some("c"));
        assert_eq!(s.queue_pos, 1);
        // a track that vanished is simply not selected
        let edit = Edit {
            select: Some((0, "gone".into())),
            ..Edit::default()
        };
        let before = s.clone();
        apply_edit(&mut s, &edit);
        assert_eq!(s, before);
    }

    #[test]
    fn locate_prefers_the_current_slot_then_later_then_earlier() {
        let mut s = state(&["a", "b", "a", "c"], 2, true);
        assert_eq!(locate(&s, "a"), Some(2));
        s.queue_pos = 1;
        s.track = s.queue.get(1).cloned();
        assert_eq!(locate(&s, "a"), Some(2), "later occurrence first");
        s.queue_pos = 3;
        s.track = s.queue.get(3).cloned();
        assert_eq!(locate(&s, "a"), Some(0));
        assert_eq!(locate(&s, "nope"), None);
    }

    #[test]
    fn edits_report_whether_the_view_changed() {
        assert!(!Edit::default().changes_view());
        assert!(Edit {
            playing: Some(true),
            ..Edit::default()
        }
        .changes_view());
        assert!(!Edit {
            position_ms: Some(5),
            ..Edit::default()
        }
        .changes_view());
    }
}
