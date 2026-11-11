//! The Spirc side of the Connect backend (Part 2, Step B). Needs `--features connect`.
//!
//! Everything decided here is thin glue; the decisions themselves (what to send, how to read an
//! event, how to avoid echoes) live in `backend.rs` and are tested there without Spotify.
//!
//! Every call into librespot-connect is in [`SpircTransport::send`] and [`map_player_event`], so
//! if a signature differs from what 0.8.0 really has, `cargo check --features connect` points at
//! one of those two places. Calls marked `VERIFY` were written from memory of the 0.8 API, not
//! from compiled code (the spike in `connect.rs` only used `Spirc::new`, `shutdown` and the player
//! events).

use crate::audio::{describe_engine_start_error, describe_failure, FailureCause};
use crate::backend::{
    adopt_foreign, apply_edit, event_to_edit, is_free_account_error, reconcile, track_id_from_uri,
    ConnectTransport, DeviceEvent, Mirror, RunEnd, RunError, TransportCmd,
};
use crate::cache::Cache;
use crate::connect::{
    clear_status, device_name, hostname, percent_to_connect, write_status, ConnectStatus,
};
use crate::daemon::Player;
use crate::session_browse::track_from_librespot;
use crate::stream_auth::fresh_streaming_token;
use crate::token_store::{load_token, now_secs};
use halcyon_music_core::protocol::{self, EventBody};
use halcyon_music_core::state::{Bitrate, RepeatMode};
use halcyon_music_core::{PlayerState, Track};
use librespot_connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc}; // VERIFY exports
use librespot_core::authentication::Credentials;
use librespot_core::config::{DeviceType, SessionConfig};
use librespot_core::session::Session;
use librespot_core::spotify_uri::SpotifyUri;
use librespot_metadata::{Metadata, Track as LsTrack};
use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, Bitrate as LsBitrate, PlayerConfig};
use librespot_playback::mixer::softmixer::SoftMixer;
use librespot_playback::mixer::{Mixer, MixerConfig};
use librespot_playback::player::{Player as LsPlayer, PlayerEvent};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::broadcast;
use tokio::time::MissedTickBehavior;
use tracing::{debug, info, warn};

/// Progress events for the GUI's slider: at most one per second (the direct engine does the same).
const PROGRESS_EVERY: Duration = Duration::from_millis(1000);
/// How long to wait for a track's metadata before showing a placeholder.
const METADATA_TIMEOUT: Duration = Duration::from_secs(5);

// ---------------------------------------------------------------------------------------------
// The two places that touch Spirc / player event types
// ---------------------------------------------------------------------------------------------

struct SpircTransport {
    spirc: Spirc,
}

impl ConnectTransport for SpircTransport {
    fn send(&mut self, cmd: &TransportCmd) -> Result<(), String> {
        let s = &self.spirc;
        let fail = |e: librespot_core::error::Error| e.to_string();
        match cmd {
            TransportCmd::Activate => s.activate().map_err(fail), // VERIFY
            TransportCmd::Load {
                uris,
                index,
                start_playing,
                position_ms,
            } => {
                // VERIFY: field names of LoadRequestOptions and the PlayingTrack variant.
                let options = LoadRequestOptions {
                    start_playing: *start_playing,
                    seek_to: *position_ms,
                    playing_track: Some(PlayingTrack::Index(u32::try_from(*index).unwrap_or(0))),
                    ..Default::default()
                };
                s.load(LoadRequest::from_tracks(uris.clone(), options))
                    .map_err(fail)
            }
            TransportCmd::Play => s.play().map_err(fail),
            TransportCmd::Pause => s.pause().map_err(fail),
            TransportCmd::Next => s.next().map_err(fail),
            TransportCmd::Prev => s.prev().map_err(fail),
            TransportCmd::Seek(ms) => s.set_position_ms(*ms).map_err(fail), // VERIFY
            TransportCmd::SetVolume(v) => s.set_volume(*v).map_err(fail),   // VERIFY
            TransportCmd::Shuffle(on) => s.shuffle(*on).map_err(fail),
            TransportCmd::Repeat(mode) => match mode {
                RepeatMode::Off => s
                    .repeat(false)
                    .and_then(|()| s.repeat_track(false)) // VERIFY
                    .map_err(fail),
                RepeatMode::All => s
                    .repeat(true)
                    .and_then(|()| s.repeat_track(false))
                    .map_err(fail),
                RepeatMode::One => s.repeat_track(true).map_err(fail),
            },
        }
    }
}

fn id_of(uri: &SpotifyUri) -> Option<String> {
    uri.to_uri().ok().and_then(|s| track_id_from_uri(&s))
}

/// Only events whose shape is already used by compiled code in `audio.rs` and `connect.rs`.
fn map_player_event(event: PlayerEvent) -> Option<DeviceEvent> {
    match event {
        PlayerEvent::Playing {
            track_id,
            position_ms,
            ..
        } => Some(DeviceEvent::Playing {
            track_id: id_of(&track_id)?,
            position_ms: u64::from(position_ms),
        }),
        PlayerEvent::Paused {
            track_id,
            position_ms,
            ..
        } => Some(DeviceEvent::Paused {
            track_id: id_of(&track_id)?,
            position_ms: u64::from(position_ms),
        }),
        PlayerEvent::PositionChanged {
            track_id,
            position_ms,
            ..
        }
        | PlayerEvent::PositionCorrection {
            track_id,
            position_ms,
            ..
        }
        | PlayerEvent::Seeked {
            track_id,
            position_ms,
            ..
        } => Some(DeviceEvent::Position {
            track_id: id_of(&track_id)?,
            position_ms: u64::from(position_ms),
        }),
        PlayerEvent::EndOfTrack { track_id, .. } => Some(DeviceEvent::EndOfTrack {
            track_id: id_of(&track_id)?,
        }),
        PlayerEvent::Unavailable { track_id, .. } => Some(DeviceEvent::Unavailable {
            track_id: id_of(&track_id)?,
        }),
        PlayerEvent::Stopped { .. } => Some(DeviceEvent::Stopped),
        PlayerEvent::VolumeChanged { volume } => Some(DeviceEvent::Volume(volume)),
        _ => None,
    }
}

// ---------------------------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------------------------

fn player_config(state: &PlayerState) -> PlayerConfig {
    let bitrate = match state.bitrate {
        Bitrate::Bitrate96 => LsBitrate::Bitrate96,
        Bitrate::Bitrate160 => LsBitrate::Bitrate160,
        Bitrate::Bitrate320 => LsBitrate::Bitrate320,
    };
    PlayerConfig {
        bitrate,
        gapless: true,
        normalisation: state.normalisation,
        position_update_interval: Some(Duration::from_millis(250)),
        ..Default::default()
    }
}

fn elapsed_ms(base: Instant) -> u64 {
    u64::try_from(base.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Starting failed while the user wants music: say so, and stop pretending to play.
async fn report_start_failure(
    player: &Player,
    events: &broadcast::Sender<protocol::Event>,
    text: &str,
) {
    let snapshot = player.snapshot().await;
    if !snapshot.playing {
        return;
    }
    player.mutate(|s| s.playing = false).await;
    let _ = events.send(protocol::event(EventBody::PlaybackFailed {
        reason: describe_engine_start_error(text).to_string(),
        consecutive_failures: 1,
        will_retry: true,
    }));
    let state = player.snapshot().await;
    let _ = events.send(protocol::event(EventBody::State { state }));
}

fn placeholder_track(id: &str) -> Track {
    Track {
        id: id.to_string(),
        title: "Spotify track".to_string(),
        artist: "Unknown Artist".to_string(),
        artists: Vec::new(),
        album: "Unknown Album".to_string(),
        album_id: None,
        // Not zero: the GUI divides position by duration.
        duration_ms: 180_000,
        art_url: None,
        uri: format!("spotify:track:{id}"),
    }
}

/// Metadata for a track the phone started: cache, then the session, else a placeholder.
async fn resolve_track(cache: &Cache, session: &Session, id: &str) -> Track {
    if let Ok(Some(t)) = cache.get_track(id) {
        return t;
    }
    if let Ok(uri) = SpotifyUri::from_uri(&format!("spotify:track:{id}")) {
        match tokio::time::timeout(METADATA_TIMEOUT, LsTrack::get(session, &uri)).await {
            Ok(Ok(t)) => {
                let track = track_from_librespot(&t);
                let _ = cache.put_tracks(std::slice::from_ref(&track));
                return track;
            }
            Ok(Err(e)) => debug!("metadata lookup failed: {e}"),
            Err(_) => debug!("metadata lookup timed out"),
        }
    }
    placeholder_track(id)
}

/// Remembers which track is being listened to, so a finished track is logged with its start time.
#[derive(Default)]
struct PlayLog {
    track_id: Option<String>,
    started_at: u64,
}

impl PlayLog {
    fn note(&mut self, id: &str) {
        if self.track_id.as_deref() != Some(id) {
            self.track_id = Some(id.to_string());
            self.started_at = now_secs();
        }
    }

    /// Same rule as the direct engine: only finished tracks are logged (Part 3 explains why
    /// skips are still missing, and that is a separate decision).
    fn finished(&mut self, cache: &Cache, track: &Track) {
        let started_at = if self.track_id.as_deref() == Some(track.id.as_str()) {
            self.started_at
        } else {
            now_secs().saturating_sub(track.duration_ms / 1000)
        };
        let _ = cache.put_tracks(std::slice::from_ref(track));
        match cache.log_play(
            &track.id,
            &track.title,
            &track.artist,
            &track.album,
            started_at,
            track.duration_ms,
            true,
        ) {
            Ok(_) => {
                info!(track_id = %track.id, completed = true, "recorded play in local play log")
            }
            Err(e) => warn!("failed to write play log: {e}"),
        }
        self.track_id = None;
    }
}

/// The current lyric line, as the direct engine sends it.
#[derive(Default)]
struct LyricTracker {
    last_idx: Option<usize>,
    last_track: Option<String>,
}

impl LyricTracker {
    fn update(
        &mut self,
        cache: &Cache,
        events: &broadcast::Sender<protocol::Event>,
        track_id: &str,
        pos_ms: u64,
    ) {
        if self.last_track.as_deref() != Some(track_id) {
            self.last_track = Some(track_id.to_string());
            self.last_idx = None;
        }
        let Ok(Some(Some(lrc))) = cache.get_lyrics(track_id) else {
            return;
        };
        if !lrc.synced || lrc.lines.is_empty() {
            return;
        }
        let offset = cache.get_lyric_offset(track_id).unwrap_or(lrc.offset_ms);
        let eff = i64::try_from(pos_ms)
            .unwrap_or(i64::MAX)
            .saturating_add(offset)
            .max(0) as u64;
        let active = lrc.lines.iter().rposition(|l| eff >= l.start_ms);
        if active != self.last_idx {
            self.last_idx = active;
            if let Some(idx) = active {
                let _ = events.send(protocol::event(EventBody::CurrentLyric {
                    track_id: track_id.to_string(),
                    line_idx: idx,
                    line: lrc.lines.get(idx).map(|l| l.text.clone()),
                }));
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------------------------

/// Register as a Connect device and keep the GUI's state and the device in step until the
/// session ends. Returns `Restart` when the audio quality changed, an error otherwise.
pub async fn run_once(
    player: Arc<Player>,
    cache: Cache,
    events: broadcast::Sender<protocol::Event>,
) -> Result<RunEnd, RunError> {
    let state = player.snapshot().await;

    let token = match fresh_streaming_token().await {
        Ok(t) => t,
        Err(e) => {
            if e.needs_sign_in() && load_token().ok().flatten().is_none() {
                let _ = events.send(protocol::event(EventBody::AuthRequired {
                    reason: "Sign in with Spotify to browse and play music.".to_string(),
                }));
            }
            let text = e.to_string();
            report_start_failure(&player, &events, &text).await;
            return Err(RunError::Failed(format!("no streaming token: {text}")));
        }
    };
    let creds = Credentials::with_access_token(&token.access_token);

    let name = device_name(&hostname());
    let session = Session::new(SessionConfig::default(), None);
    let mixer = Arc::new(
        SoftMixer::open(MixerConfig::default())
            .map_err(|e| RunError::Failed(format!("mixer: {e}")))?,
    );
    let sink_fn = audio_backend::find(None)
        .ok_or_else(|| RunError::Failed("No audio backend found".to_string()))?;
    let bus = crate::tap::audio_bus().clone();
    let sink_builder = move || -> Box<dyn audio_backend::Sink> {
        Box::new(crate::tap::TapSink::new(
            sink_fn(None, AudioFormat::F32),
            bus,
        ))
    };
    let ls_player = LsPlayer::new(
        player_config(&state),
        session.clone(),
        mixer.get_soft_volume(),
        sink_builder,
    );
    let mut device_events = ls_player.get_player_event_channel();

    let config = ConnectConfig {
        name: name.clone(),
        device_type: DeviceType::Computer,
        initial_volume: percent_to_connect(state.volume),
        ..Default::default()
    };

    // Spirc::new connects the session itself, so it must not be connected before this call.
    info!(device = %name, "registering as a Spotify Connect device");
    let (spirc, task) = match Spirc::new(config, session.clone(), creds, ls_player, mixer.clone())
        .await
    {
        Ok(pair) => pair,
        Err(e) => {
            let text = e.to_string();
            if is_free_account_error(&text) {
                let _ = events.send(protocol::event(EventBody::Error {
                    message: "Spotify Free accounts cannot be Connect devices or stream through \
                              this player. Browsing remains available."
                        .to_string(),
                }));
                return Err(RunError::Unsupported(text));
            }
            report_start_failure(&player, &events, &text).await;
            return Err(RunError::Failed(format!(
                "could not start Spotify Connect: {text}"
            )));
        }
    };
    let mut task = tokio::spawn(task);

    if let Err(e) = write_status(&ConnectStatus {
        name: name.clone(),
        pid: std::process::id(),
        since: now_secs(),
    }) {
        warn!("could not write the connect status file: {e}");
    }
    let _ = events.send(protocol::event(EventBody::ConnectDevice {
        name: Some(name.clone()),
    }));
    info!(device = %name, "registered; waiting for the phone or the GUI");

    let mut transport = SpircTransport { spirc };
    let built_with = (state.bitrate, state.normalisation);
    let base = Instant::now();
    let mut mirror = Mirror::new(state.volume);
    let mut play_log = PlayLog::default();
    let mut lyrics = LyricTracker::default();
    let mut last_progress = Instant::now();

    let mut tick = tokio::time::interval(Duration::from_millis(250));
    tick.set_missed_tick_behavior(MissedTickBehavior::Skip);

    let mut task_done = false;
    let result = loop {
        tokio::select! {
            _ = tick.tick() => {
                let snapshot = player.snapshot().await;
                if (snapshot.bitrate, snapshot.normalisation) != built_with {
                    info!("audio quality changed: re-registering the Connect device");
                    break Ok(RunEnd::Restart);
                }
                reconcile(&snapshot, &mut mirror, &mut transport, elapsed_ms(base));
            }
            event = device_events.recv() => {
                let Some(event) = event else {
                    break Err(RunError::Failed("the player's event channel closed".to_string()));
                };
                let Some(device_event) = map_player_event(event) else { continue };
                on_device_event(
                    &player, &cache, &events, &session, &mut mirror, &mut play_log,
                    &mut lyrics, &mut last_progress, device_event, elapsed_ms(base),
                ).await;
            }
            _ = &mut task => {
                // A finished JoinHandle must not be polled again.
                task_done = true;
                break Err(RunError::Failed("the Spotify Connect session ended".to_string()));
            }
        }
    };

    let _ = transport.spirc.shutdown();
    if !task_done {
        let _ = tokio::time::timeout(Duration::from_secs(5), &mut task).await;
    }
    clear_status();
    let _ = events.send(protocol::event(EventBody::ConnectDevice { name: None }));
    result
}

#[allow(clippy::too_many_arguments)]
async fn on_device_event(
    player: &Arc<Player>,
    cache: &Cache,
    events: &broadcast::Sender<protocol::Event>,
    session: &Session,
    mirror: &mut Mirror,
    play_log: &mut PlayLog,
    lyrics: &mut LyricTracker,
    last_progress: &mut Instant,
    event: DeviceEvent,
    now_ms: u64,
) {
    let snapshot = player.snapshot().await;
    let mut edit = event_to_edit(&snapshot, mirror, &event, now_ms);

    // The phone started something Halcyon never queued: look it up, then install it as the queue.
    if let Some(unknown) = edit.unknown.take() {
        let track = resolve_track(cache, session, &unknown.track_id).await;
        // The state may have moved while we waited for the lookup.
        let fresh = player.snapshot().await;
        edit = adopt_foreign(&fresh, mirror, track, &unknown);
    }

    if let Some(id) = edit.unavailable.as_deref() {
        debug!(
            track_id = id,
            "Spotify has no playable version of this track"
        );
        let _ = events.send(protocol::event(EventBody::PlaybackFailed {
            reason: describe_failure(FailureCause::TrackUnavailable).to_string(),
            consecutive_failures: 0,
            will_retry: false,
        }));
    }

    if let Some(id) = edit.ended.as_deref() {
        if let Some(track) = snapshot.queue.iter().find(|t| t.id == id) {
            play_log.finished(cache, track);
        }
    }
    match &event {
        DeviceEvent::Playing { track_id, .. } | DeviceEvent::Paused { track_id, .. } => {
            play_log.note(track_id);
        }
        _ => {}
    }

    let view_changed = edit.changes_view();
    player.mutate(|s| apply_edit(s, &edit)).await;

    let after = player.snapshot().await;
    if view_changed {
        let _ = events.send(protocol::event(EventBody::State {
            state: after.clone(),
        }));
    }

    if let (Some(pos), Some(track)) = (edit.position_ms, after.track.as_ref()) {
        let force = view_changed
            || matches!(
                event,
                DeviceEvent::Playing { .. } | DeviceEvent::Paused { .. }
            );
        if force || last_progress.elapsed() >= PROGRESS_EVERY {
            let _ = events.send(protocol::event(EventBody::Progress {
                position_ms: pos.min(track.duration_ms),
                playing: after.playing,
            }));
            *last_progress = Instant::now();
        }
        lyrics.update(cache, events, &track.id, pos);
    }
}
