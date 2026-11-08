//! Playback engine, watchdog, and self-healing subsystem.
//!
//! Handles:
//! - librespot playback with PipeWire/Rodio audio backend
//! - Position, play/pause state, end-of-track and load failures come from the
//!   real librespot player events (`PlayerEvent`), not from a simulated clock.
//!   If nothing plays, the UI is told so (`PlaybackFailed` with a reason and a hint).
//! - Watchdog: only trips on a real stall (engine says "playing" but no position
//!   event arrives for 5 s, or a load never finishes). It rebuilds the player and
//!   reloads the current track; after 3 failures in a row it halts until the user
//!   presses play again.
//! - Self-healing: network dropouts, PipeWire restarts, region lockouts,
//!   token expiry mid-track, system suspend/resume.
//! - Local play logging to SQLite for Capsule & suggestions.
//! - Repeat modes (Off, All, One), volume normalisation, bitrate selection (96/160/320).

use crate::cache::Cache;
use crate::daemon::Player;
use crate::stream_auth::fresh_streaming_token;
use crate::token_store::{load_token, now_secs};
use halcyon_music_core::protocol::{self, EventBody};
use halcyon_music_core::state::Bitrate;
use halcyon_music_core::Track;
use librespot_core::authentication::Credentials;
use librespot_core::error::ErrorKind;
use librespot_core::config::SessionConfig;
use librespot_core::session::Session;
use librespot_core::spotify_uri::SpotifyUri;
use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, Bitrate as LibrespotBitrate, PlayerConfig};
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::{Player as LibrespotPlayer, PlayerEvent};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc, Mutex};
use tokio::time::MissedTickBehavior;
use tracing::{debug, info, warn};

/// Watchdog threshold: 5 seconds of playing without advancing position = stall.
pub const STALL_THRESHOLD: Duration = Duration::from_secs(5);
/// Max consecutive watchdog trips before halting until explicit user action.
pub const MAX_CONSECUTIVE_FAILURES: u32 = 3;
/// Minimum played time (30s) to record a partial play in the log.
pub const MIN_PLAY_LOG_MS: u64 = 30_000;
/// A load that produces neither `Playing`/`Paused` nor `Unavailable` within this time is a stall.
pub const LOAD_TIMEOUT: Duration = Duration::from_secs(20);
/// A difference this large between the state's position and the last position the engine
/// reported means the user (or a "previous" restart) moved it: forward it to the engine as a seek.
const SEEK_JUMP_MS: u64 = 1_500;
/// Real playback progress needed after a rebuild before the failure counter is cleared.
const PROGRESS_RESET_MS: u64 = 3_000;

/// What the librespot engine is doing, as told by its events.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EngineStatus {
    /// Nothing loaded, or the track ended / stopped.
    Idle,
    /// `load()` (or a resume) was sent; waiting for `Playing` / `Paused` / `Unavailable`.
    Loading,
    Playing,
    Paused,
}

/// Why a track could not be played. Carries no secrets, so it is safe to log.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureCause {
    /// Spotify rejected the sign-in used for streaming (the `INVALID_CREDENTIALS` case).
    CredentialsRejected,
    Network,
    SessionLost,
    /// Sign-in is fine; Spotify has no playable version (region, licensing, Free account).
    TrackUnavailable,
    Other,
}

/// Map a failed login5 token request to a cause. Only the error kind and the fixed
/// `INVALID_CREDENTIALS` marker are looked at; the text is never stored or logged.
pub fn classify_login_failure(kind: ErrorKind, text: &str) -> FailureCause {
    if text.contains("INVALID_CREDENTIALS") {
        return FailureCause::CredentialsRejected;
    }
    match kind {
        ErrorKind::Unavailable | ErrorKind::DeadlineExceeded | ErrorKind::ResourceExhausted => {
            FailureCause::Network
        }
        ErrorKind::Unauthenticated | ErrorKind::PermissionDenied | ErrorKind::FailedPrecondition => {
            FailureCause::CredentialsRejected
        }
        _ => FailureCause::Other,
    }
}

/// Human-readable "reason. what to do" for the toast (one string: the protocol stays unchanged).
pub fn describe_failure(cause: FailureCause) -> &'static str {
    match cause {
        FailureCause::CredentialsRejected => {
            "Spotify rejected the sign-in used for streaming, so this track can't play. \
             A token from your own Client ID can't stream: sign in again with the playback sign-in \
             (Premium is required). Browsing still works."
        }
        FailureCause::Network => {
            "Couldn't reach Spotify to start this track. Check your connection, then press play to try again."
        }
        FailureCause::SessionLost => {
            "The Spotify connection was lost. Press play to reconnect."
        }
        FailureCause::TrackUnavailable => {
            "Spotify has no playable version of this track for your account or region. \
             Free accounts can't stream through this player (Premium is required)."
        }
        FailureCause::Other => {
            "Spotify could not start this track. Press play to try again; if it keeps failing, \
             run `halcyon-musicd --doctor`."
        }
    }
}

/// Reason + hint for an engine that did not start (session or audio output).
pub fn describe_engine_start_error(err: &str) -> &'static str {
    let lower = err.to_lowercase();
    if lower.contains("no token") || lower.contains("must log in") {
        "You're not signed in for playback. Use Sign in with Spotify, then press play."
    } else if lower.contains("no audio backend") {
        "No audio output is available. Check that PipeWire or PulseAudio is running, then press play."
    } else if lower.contains("session connect failed") {
        "Couldn't open a Spotify playback session. Check your connection; Free accounts can't stream. Press play to retry."
    } else {
        "The audio engine did not start. Press play to try again; if it keeps failing, run `halcyon-musicd --doctor`."
    }
}

/// True when the quality the user asked for differs from what the running player was built
/// with. librespot cannot change bitrate or normalisation on a live player.
fn quality_changed(built_with: (Bitrate, bool), wanted: (Bitrate, bool)) -> bool {
    built_with != wanted
}

/// True when the state's position moved away from what the engine last reported.
fn is_user_seek(state_pos_ms: u64, last_reported_ms: u64) -> bool {
    state_pos_ms.abs_diff(last_reported_ms) > SEEK_JUMP_MS
}

/// A stall is only real when the engine owes us an event: it claims to play (or is
/// meant to be playing) and no position event came, or a load never answered.
fn stall_detected(
    status: EngineStatus,
    wants_play: bool,
    since_event: Duration,
    since_load: Duration,
) -> bool {
    match status {
        EngineStatus::Playing => since_event >= STALL_THRESHOLD,
        EngineStatus::Paused => wants_play && since_event >= STALL_THRESHOLD,
        EngineStatus::Loading => since_load >= LOAD_TIMEOUT,
        EngineStatus::Idle => false,
    }
}

/// Mutable state of the run loop.
struct Rt {
    /// Bumped whenever the librespot player is dropped; events of older players are ignored.
    generation: u64,
    status: EngineStatus,
    /// Track id of the state's current track, to notice changes.
    active_track_id: Option<String>,
    /// Track id we last sent to `load()`.
    loaded_track_id: Option<String>,
    /// Canonical URI of that load, to match events.
    loaded_uri: Option<String>,
    /// Track that failed to load or stalled for good: not retried until the user presses play.
    failed_track_id: Option<String>,
    track_started_at: u64,
    last_event_at: Instant,
    load_started_at: Instant,
    /// Last position the engine reported (what we wrote into the state).
    last_reported_pos: u64,
    advance_acc_ms: u64,
    last_progress_broadcast: Instant,
    last_lyric_idx: Option<usize>,
    /// The last transport request we sent the engine (true = play).
    native_wants_play: bool,
    /// Audio quality the running librespot player was built with. librespot fixes the bitrate
    /// and normalisation when a player is created, so a change means building a new player.
    engine_quality: (Bitrate, bool),
}

impl Rt {
    fn new() -> Self {
        let now = Instant::now();
        Self {
            generation: 0,
            status: EngineStatus::Idle,
            active_track_id: None,
            loaded_track_id: None,
            loaded_uri: None,
            failed_track_id: None,
            track_started_at: now_secs(),
            last_event_at: now,
            load_started_at: now,
            last_reported_pos: 0,
            advance_acc_ms: 0,
            last_progress_broadcast: now,
            last_lyric_idx: None,
            native_wants_play: false,
            engine_quality: (Bitrate::default(), true),
        }
    }

    fn is_loaded(&self, uri: &librespot_core::spotify_uri::SpotifyUri) -> bool {
        match uri.to_uri() {
            Ok(s) => self.loaded_uri.as_deref() == Some(s.as_str()),
            // A URI that cannot be rendered can never match a loaded track.
            Err(_) => false,
        }
    }
}

type EngineEvent = (u64, PlayerEvent);

pub struct AudioEngine {
    player: Arc<Player>,
    cache: Cache,
    events_tx: broadcast::Sender<protocol::Event>,
    consecutive_failures: Arc<AtomicU32>,
    librespot_player: Arc<Mutex<Option<Arc<LibrespotPlayer>>>>,
    session: Arc<Mutex<Option<Session>>>,
    is_free_account: Arc<AtomicBool>,
}

impl AudioEngine {
    pub fn new(
        player: Arc<Player>,
        cache: Cache,
        events_tx: broadcast::Sender<protocol::Event>,
    ) -> Self {
        Self {
            player,
            cache,
            events_tx,
            consecutive_failures: Arc::new(AtomicU32::new(0)),
            librespot_player: Arc::new(Mutex::new(None)),
            session: Arc::new(Mutex::new(None)),
            is_free_account: Arc::new(AtomicBool::new(false)),
        }
    }

    pub fn consecutive_failures(&self) -> u32 {
        self.consecutive_failures.load(Ordering::Relaxed)
    }

    pub fn reset_failures(&self) {
        self.consecutive_failures.store(0, Ordering::Relaxed);
    }

    /// Record a finished or skipped track in the SQLite play log.
    pub fn record_play_log(&self, track: &Track, started_at: u64, ms_played: u64, completed: bool) {
        if completed || ms_played >= MIN_PLAY_LOG_MS {
            // Keep the full track (with its cover) so Home can show art for recent plays.
            let _ = self.cache.put_tracks(std::slice::from_ref(track));
            if let Err(e) = self.cache.log_play(
                &track.id,
                &track.title,
                &track.artist,
                &track.album,
                started_at,
                ms_played,
                completed,
            ) {
                warn!("failed to write play log: {e}");
            } else {
                info!(
                    track_id = %track.id,
                    ms = ms_played,
                    completed,
                    "recorded play in local play log"
                );
            }
        }
    }

    /// Connect or reconnect the Spotify session with the streaming token (librespot's own
    /// OAuth sign-in). The Web API token of a custom Client ID cannot stream, so it is never
    /// used here.
    pub async fn ensure_session(&self) -> Result<Session, String> {
        let token = match fresh_streaming_token().await {
            Ok(token) => token,
            Err(e) => {
                // Only send AuthRequired when browsing is signed out too: the GUI answers it with
                // the sign-in screen, which would hide a library that still works.
                if e.needs_sign_in() && load_token().ok().flatten().is_none() {
                    let _ = self.events_tx.send(protocol::event(EventBody::AuthRequired {
                        reason: "Sign in with Spotify to browse and play music.".to_string(),
                    }));
                }
                return Err(e.to_string());
            }
        };

        // Reconnect session
        let config = SessionConfig::default();
        let session = Session::new(config, None);
        let creds = Credentials::with_access_token(&token.access_token);

        info!("connecting Spotify AP session with access token...");
        match session.connect(creds, true).await {
            Ok(()) => {
                info!("Spotify AP session connected successfully");
                let mut sess_guard = self.session.lock().await;
                *sess_guard = Some(session.clone());
                Ok(session)
            }
            Err(e) => {
                let err_str = e.to_string();
                if err_str.to_lowercase().contains("free") || err_str.to_lowercase().contains("premium") {
                    self.is_free_account.store(true, Ordering::SeqCst);
                    let msg = "Spotify Free accounts cannot stream via librespot / Spotify Connect API. Browsing remains fully available.";
                    warn!("{msg}");
                    let _ = self.events_tx.send(protocol::event(EventBody::Error {
                        message: msg.to_string(),
                    }));
                }
                Err(format!("session connect failed: {err_str}"))
            }
        }
    }

    /// Build librespot player configuration from current player state.
    fn make_player_config(&self, state: &halcyon_music_core::PlayerState) -> PlayerConfig {
        let bitrate = match state.bitrate {
            Bitrate::Bitrate96 => LibrespotBitrate::Bitrate96,
            Bitrate::Bitrate160 => LibrespotBitrate::Bitrate160,
            Bitrate::Bitrate320 => LibrespotBitrate::Bitrate320,
        };

        PlayerConfig {
            bitrate,
            gapless: true,
            normalisation: state.normalisation,
            position_update_interval: Some(Duration::from_millis(250)),
            ..Default::default()
        }
    }

    /// Initialize the native librespot player with resilient Rodio sink.
    pub async fn init_librespot_player(&self) -> Result<Arc<LibrespotPlayer>, String> {
        let session = self.ensure_session().await?;
        let state = self.player.snapshot().await;
        let config = self.make_player_config(&state);

        let sink_fn = audio_backend::find(None).ok_or_else(|| "No audio backend found".to_string())?;
        // The real sink, wrapped so the GUI's visuals can follow the actual sound (see `tap`).
        let bus = crate::tap::audio_bus().clone();
        let sink_builder = move || -> Box<dyn audio_backend::Sink> {
            Box::new(crate::tap::TapSink::new(sink_fn(None, AudioFormat::F32), bus))
        };
        let player = LibrespotPlayer::new(config, session, Box::new(NoOpVolume), sink_builder);

        let mut guard = self.librespot_player.lock().await;
        *guard = Some(player.clone());
        Ok(player)
    }

    // ------------------------------------------------------------------
    // Engine plumbing
    // ------------------------------------------------------------------

    async fn native(&self) -> Option<Arc<LibrespotPlayer>> {
        self.librespot_player.lock().await.clone()
    }

    /// Build the librespot player and forward its events (tagged with the current
    /// generation) into the run loop's channel.
    async fn start_native(
        &self,
        rt: &Rt,
        ev_tx: &mpsc::UnboundedSender<EngineEvent>,
    ) -> Result<(), String> {
        let player = self.init_librespot_player().await?;
        let mut channel = player.get_player_event_channel();
        let tx = ev_tx.clone();
        let generation = rt.generation;
        tokio::spawn(async move {
            while let Some(event) = channel.recv().await {
                if tx.send((generation, event)).is_err() {
                    break;
                }
            }
        });
        Ok(())
    }

    /// Throw the librespot player away. Events of the old player are ignored from now on;
    /// the next tick builds a new player and loads the current track again.
    async fn drop_native(&self, rt: &mut Rt) {
        {
            let mut guard = self.librespot_player.lock().await;
            *guard = None;
        }
        rt.generation = rt.generation.wrapping_add(1);
        rt.status = EngineStatus::Idle;
        rt.native_wants_play = false;
        rt.loaded_track_id = None;
        rt.loaded_uri = None;
        rt.advance_acc_ms = 0;
    }

    async fn broadcast_state(&self) {
        let state = self.player.snapshot().await;
        let _ = self
            .events_tx
            .send(protocol::event(EventBody::State { state }));
    }

    /// Stop, remember that this track failed, and tell the UI once.
    async fn fail_playback(
        &self,
        rt: &mut Rt,
        track_id: Option<String>,
        reason: String,
        will_retry: bool,
        failures: u32,
    ) {
        self.player.mutate(|s| s.playing = false).await;
        rt.failed_track_id = track_id;
        rt.native_wants_play = false;
        rt.status = EngineStatus::Idle;
        let _ = self.events_tx.send(protocol::event(EventBody::PlaybackFailed {
            reason,
            consecutive_failures: failures,
            will_retry,
        }));
        self.broadcast_state().await;
    }

    /// Like `fail_playback`, but silent when nobody asked for playback (for example the
    /// start-up load of the saved track while paused): the error shows when the user presses play.
    async fn fail_or_park(
        &self,
        rt: &mut Rt,
        playing: bool,
        track_id: Option<String>,
        reason: String,
    ) {
        if playing {
            let failures = self.consecutive_failures();
            self.fail_playback(rt, track_id, reason, false, failures).await;
        } else {
            debug!("playback not available while paused: {reason}");
            rt.failed_track_id = track_id;
            rt.status = EngineStatus::Idle;
        }
    }

    /// Find out why a load failed. `PlayerEvent::Unavailable` carries no reason (librespot only
    /// logs it), so ask the same login5 token request the load used. The token is dropped unread.
    async fn diagnose_failure(&self) -> FailureCause {
        let session = self.session.lock().await.clone();
        let Some(session) = session else {
            return FailureCause::SessionLost;
        };
        if session.is_invalid() {
            return FailureCause::SessionLost;
        }
        match tokio::time::timeout(Duration::from_secs(10), session.login5().auth_token()).await {
            Err(_) => FailureCause::Network,
            Ok(Ok(_token)) => FailureCause::TrackUnavailable,
            Ok(Err(e)) => classify_login_failure(e.kind, &e.error.to_string()),
        }
    }

    // ------------------------------------------------------------------
    // Loading
    // ------------------------------------------------------------------

    async fn load_current(
        &self,
        rt: &mut Rt,
        state: &halcyon_music_core::PlayerState,
        track: &Track,
        ev_tx: &mpsc::UnboundedSender<EngineEvent>,
    ) {
        let cur_id = Some(track.id.clone());
        let uri_str = if track.uri.starts_with("spotify:track:") {
            track.uri.clone()
        } else {
            format!("spotify:track:{}", track.id)
        };

        let sp_uri = match SpotifyUri::from_uri(&uri_str) {
            Ok(u) => u,
            Err(e) => {
                warn!(uri = %uri_str, error = %e, "track has an invalid Spotify URI");
                self.fail_or_park(
                    rt,
                    state.playing,
                    cur_id,
                    "This track has an invalid Spotify ID, so it can't be played.".to_string(),
                )
                .await;
                return;
            }
        };

        if self.native().await.is_none() {
            if let Err(e) = self.start_native(rt, ev_tx).await {
                warn!(error = %e, "could not start the audio engine (Spotify session / audio output)");
                let msg = describe_engine_start_error(&e).to_string();
                self.fail_or_park(rt, state.playing, cur_id, msg).await;
                return;
            }
            // The new player was built from the state as it is right now.
            rt.engine_quality = (state.bitrate, state.normalisation);
        }
        let Some(native) = self.native().await else {
            return;
        };

        info!(uri = %uri_str, "loading track into librespot engine");
        native.load(
            sp_uri.clone(),
            state.playing,
            u32::try_from(state.position_ms).unwrap_or(0),
        );

        let now = Instant::now();
        rt.loaded_track_id = cur_id;
        // `None` only means "unknown": the next is_loaded() check then reloads.
        rt.loaded_uri = sp_uri.to_uri().ok();
        rt.status = EngineStatus::Loading;
        rt.load_started_at = now;
        rt.last_event_at = now;
        rt.native_wants_play = state.playing;
        rt.last_reported_pos = state.position_ms;

        // Preload the upcoming track for a gapless transition.
        if let Some(nxt) = state.queue.get(state.queue_pos + 1) {
            let nxt_uri = format!("spotify:track:{}", nxt.id);
            if let Ok(nxt_sp) = SpotifyUri::from_uri(&nxt_uri) {
                native.preload(nxt_sp);
            }
        }
    }

    // ------------------------------------------------------------------
    // Tick: control side (load, play/pause, seek, watchdog)
    // ------------------------------------------------------------------

    async fn on_tick(&self, rt: &mut Rt, ev_tx: &mpsc::UnboundedSender<EngineEvent>) {
        let state = self.player.snapshot().await;
        let cur_id = state.track.as_ref().map(|t| t.id.clone());

        if cur_id != rt.active_track_id {
            rt.active_track_id = cur_id.clone();
            rt.track_started_at = now_secs();
            rt.last_reported_pos = state.position_ms;
            rt.last_lyric_idx = None;
        }

        let Some(track) = state.track.as_ref() else {
            return;
        };

        // A track that failed stays failed until the user asks to play again.
        if rt.failed_track_id.is_some() {
            if rt.failed_track_id == cur_id {
                if !state.playing {
                    return;
                }
                info!("play pressed after a failure: rebuilding the engine and loading again");
                rt.failed_track_id = None;
                self.reset_failures();
                // A fresh player: librespot ignores a second load of a track that just failed.
                self.drop_native(rt).await;
            } else {
                rt.failed_track_id = None; // the user moved to another track
            }
        }

        // Audio quality (bitrate, volume normalisation) was changed in Settings: the player is
        // rebuilt with it and the current track is loaded again at the same position, so the
        // change is heard within a moment instead of at the next app start.
        if self.native().await.is_some()
            && quality_changed(rt.engine_quality, (state.bitrate, state.normalisation))
        {
            info!(
                bitrate = ?state.bitrate,
                normalisation = state.normalisation,
                "audio quality changed: rebuilding the engine"
            );
            self.drop_native(rt).await;
        }

        // The engine has nothing playing (track ended, queue finished) but playback is wanted.
        if state.playing
            && rt.status == EngineStatus::Idle
            && rt.loaded_track_id.is_some()
            && rt.loaded_track_id == cur_id
        {
            rt.loaded_track_id = None;
        }

        if rt.loaded_track_id != cur_id {
            self.load_current(rt, &state, track, ev_tx).await;
            if rt.failed_track_id.is_some() {
                return;
            }
        }

        if let Some(native) = self.native().await {
            // Transport
            if state.playing && !rt.native_wants_play {
                native.play();
                rt.native_wants_play = true;
                if matches!(rt.status, EngineStatus::Paused | EngineStatus::Playing) {
                    // wait for the engine's `Playing` before believing it
                    rt.status = EngineStatus::Loading;
                    rt.load_started_at = Instant::now();
                }
            } else if !state.playing && rt.native_wants_play {
                native.pause();
                rt.native_wants_play = false;
            }

            // Seek (the state's position moved by itself)
            if matches!(rt.status, EngineStatus::Playing | EngineStatus::Paused)
                && is_user_seek(state.position_ms, rt.last_reported_pos)
            {
                native.seek(u32::try_from(state.position_ms).unwrap_or(u32::MAX));
                rt.last_reported_pos = state.position_ms;
                rt.last_event_at = Instant::now();
            }
        }

        // Watchdog: only a real stall counts.
        if state.playing
            && stall_detected(
                rt.status,
                rt.native_wants_play,
                rt.last_event_at.elapsed(),
                rt.load_started_at.elapsed(),
            )
        {
            self.on_stall(rt, cur_id).await;
        }
    }

    async fn on_stall(&self, rt: &mut Rt, cur_id: Option<String>) {
        let failures = self.consecutive_failures.fetch_add(1, Ordering::SeqCst) + 1;
        warn!(
            failures,
            status = ?rt.status,
            position_ms = rt.last_reported_pos,
            "watchdog: playback stalled"
        );

        // The old player is useless either way.
        self.drop_native(rt).await;

        if failures >= MAX_CONSECUTIVE_FAILURES {
            warn!("watchdog tripped: {failures} consecutive failures. Halting until the user presses play.");
            self.fail_playback(
                rt,
                cur_id,
                "Playback stalled 3 times in a row, so it was stopped. Check your connection and audio output, then press play to try again.".to_string(),
                false,
                failures,
            )
            .await;
        } else {
            let _ = self.events_tx.send(protocol::event(EventBody::PlaybackFailed {
                reason: "Playback stalled; restarting the audio engine and reloading the track…".to_string(),
                consecutive_failures: failures,
                will_retry: true,
            }));
            // The next tick builds a new player and loads the current track at the last real position.
        }
    }

    // ------------------------------------------------------------------
    // Player events: position, state, end of track, failures
    // ------------------------------------------------------------------

    async fn on_player_event(&self, rt: &mut Rt, generation: u64, event: PlayerEvent) {
        if generation != rt.generation {
            return; // from a player we already dropped
        }

        let is_position_event = matches!(
            event,
            PlayerEvent::Playing { .. }
                | PlayerEvent::PositionChanged { .. }
                | PlayerEvent::PositionCorrection { .. }
                | PlayerEvent::Seeked { .. }
        );
        if is_position_event && crate::faults::should_simulate_audio_stall() {
            return; // fault injection: pretend the engine went quiet
        }

        match event {
            PlayerEvent::Playing {
                track_id,
                position_ms,
                ..
            } if rt.is_loaded(&track_id) => {
                rt.status = EngineStatus::Playing;
                rt.last_event_at = Instant::now();
                self.apply_position(rt, u64::from(position_ms), true).await;
            }
            PlayerEvent::PositionChanged {
                track_id,
                position_ms,
                ..
            } if rt.is_loaded(&track_id) => {
                rt.status = EngineStatus::Playing;
                rt.last_event_at = Instant::now();
                self.apply_position(rt, u64::from(position_ms), false).await;
            }
            PlayerEvent::PositionCorrection {
                track_id,
                position_ms,
                ..
            } if rt.is_loaded(&track_id) => {
                rt.last_event_at = Instant::now();
                self.apply_position(rt, u64::from(position_ms), true).await;
            }
            PlayerEvent::Seeked {
                track_id,
                position_ms,
                ..
            } if rt.is_loaded(&track_id) => {
                rt.last_event_at = Instant::now();
                self.apply_position(rt, u64::from(position_ms), true).await;
            }
            PlayerEvent::Paused {
                track_id,
                position_ms,
                ..
            } if rt.is_loaded(&track_id) => {
                rt.status = EngineStatus::Paused;
                rt.last_event_at = Instant::now();
                self.apply_position(rt, u64::from(position_ms), true).await;
            }
            PlayerEvent::EndOfTrack { track_id, .. } if rt.is_loaded(&track_id) => {
                self.handle_end_of_track(rt).await;
            }
            PlayerEvent::Unavailable { track_id, .. } if rt.is_loaded(&track_id) => {
                self.handle_unavailable(rt).await;
            }
            PlayerEvent::Stopped { track_id, .. } if rt.is_loaded(&track_id) => {
                warn!("librespot reported the player stopped");
                rt.status = EngineStatus::Idle;
                rt.native_wants_play = false;
                self.player.mutate(|s| s.playing = false).await;
                self.broadcast_state().await;
            }
            _ => {}
        }
    }

    /// Write a position reported by the engine into the state, broadcast progress and lyrics.
    async fn apply_position(&self, rt: &mut Rt, position_ms: u64, force_progress: bool) {
        let state = self.player.snapshot().await;
        let Some(track) = state.track.as_ref() else {
            return;
        };
        // The user switched track since this event was produced: the next tick loads the new one.
        if rt.loaded_track_id.as_deref() != Some(track.id.as_str()) {
            return;
        }
        // The user seeked and the tick has not forwarded it yet: do not overwrite it.
        if is_user_seek(state.position_ms, rt.last_reported_pos) {
            return;
        }

        let pos = position_ms.min(track.duration_ms);
        let delta = pos.saturating_sub(rt.last_reported_pos);
        if delta > 0 && delta < SEEK_JUMP_MS {
            rt.advance_acc_ms = rt.advance_acc_ms.saturating_add(delta);
            if rt.advance_acc_ms >= PROGRESS_RESET_MS {
                self.consecutive_failures.store(0, Ordering::Relaxed);
            }
        }
        rt.last_reported_pos = pos;
        self.player.mutate(|s| s.position_ms = pos).await;

        if force_progress || rt.last_progress_broadcast.elapsed() >= Duration::from_millis(1000) {
            let _ = self.events_tx.send(protocol::event(EventBody::Progress {
                position_ms: pos,
                playing: rt.status == EngineStatus::Playing,
            }));
            rt.last_progress_broadcast = Instant::now();
        }

        // Live current lyric line
        if let Ok(Some(Some(lrc))) = self.cache.get_lyrics(&track.id) {
            if lrc.synced && !lrc.lines.is_empty() {
                let offset = self.cache.get_lyric_offset(&track.id).unwrap_or(lrc.offset_ms);
                let eff = (pos as i64).saturating_add(offset).max(0) as u64;
                let active_idx = lrc.lines.iter().rposition(|l| eff >= l.start_ms);
                if active_idx != rt.last_lyric_idx {
                    rt.last_lyric_idx = active_idx;
                    if let Some(idx) = active_idx {
                        let line_text = lrc.lines.get(idx).map(|l| l.text.clone());
                        let _ = self.events_tx.send(protocol::event(EventBody::CurrentLyric {
                            track_id: track.id.clone(),
                            line_idx: idx,
                            line: line_text,
                        }));
                    }
                }
            }
        }
    }

    /// The engine really reached the end of the track.
    async fn handle_end_of_track(&self, rt: &mut Rt) {
        let state = self.player.snapshot().await;
        let Some(track) = state.track.as_ref() else {
            return;
        };
        if rt.loaded_track_id.as_deref() != Some(track.id.as_str()) {
            return; // stale event for a track the user already left
        }

        self.record_play_log(track, rt.track_started_at, track.duration_ms, true);

        let mut advanced = false;
        self.player
            .mutate(|s| {
                advanced = s.advance_next();
            })
            .await;

        rt.track_started_at = now_secs();
        rt.last_reported_pos = 0;
        rt.status = EngineStatus::Idle;
        rt.native_wants_play = false;
        if advanced {
            // Load the next track (or the same one again for repeat-one) on the next tick.
            rt.loaded_track_id = None;
        } else {
            info!("reached end of queue with repeat off");
        }
        self.broadcast_state().await;
    }

    /// librespot could not load the track. The event has no reason: find one, tell the UI once, stop.
    async fn handle_unavailable(&self, rt: &mut Rt) {
        let state = self.player.snapshot().await;
        let Some(track) = state.track.as_ref() else {
            return;
        };
        if rt.loaded_track_id.as_deref() != Some(track.id.as_str()) {
            return;
        }

        let cause = self.diagnose_failure().await;
        warn!(track_id = %track.id, ?cause, "librespot could not load the track");
        let reason = describe_failure(cause).to_string();
        self.fail_or_park(rt, state.playing, Some(track.id.clone()), reason)
            .await;
    }

    /// Main supervisor playback and watchdog loop.
    pub async fn run_loop(self: Arc<Self>) {
        let mut interval = tokio::time::interval(Duration::from_millis(250));
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
        let (ev_tx, mut ev_rx) = mpsc::unbounded_channel::<EngineEvent>();
        let mut rt = Rt::new();

        loop {
            tokio::select! {
                _ = interval.tick() => {
                    self.on_tick(&mut rt, &ev_tx).await;
                }
                Some((generation, event)) = ev_rx.recv() => {
                    self.on_player_event(&mut rt, generation, event).await;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quality_change_is_detected() {
        let built = (Bitrate::Bitrate160, true);
        assert!(!quality_changed(built, (Bitrate::Bitrate160, true)));
        assert!(quality_changed(built, (Bitrate::Bitrate320, true)));
        assert!(quality_changed(built, (Bitrate::Bitrate160, false)));
    }

    #[test]
    fn user_seek_needs_a_real_jump() {
        assert!(!is_user_seek(10_000, 10_000));
        assert!(!is_user_seek(10_900, 10_000)); // normal drift between events
        assert!(is_user_seek(60_000, 10_000));
        assert!(is_user_seek(0, 45_000)); // "previous" restarting the track
    }

    #[test]
    fn stall_only_when_the_engine_owes_an_event() {
        let short = Duration::from_secs(1);
        let long = STALL_THRESHOLD + Duration::from_secs(1);
        let very_long = LOAD_TIMEOUT + Duration::from_secs(1);

        // playing, events arriving: fine; silent for 5 s: stall
        assert!(!stall_detected(EngineStatus::Playing, true, short, very_long));
        assert!(stall_detected(EngineStatus::Playing, true, long, short));
        // paused by the user: never a stall, however quiet
        assert!(!stall_detected(EngineStatus::Paused, false, very_long, very_long));
        // paused although playback is wanted: stall
        assert!(stall_detected(EngineStatus::Paused, true, long, short));
        // a load gets 20 s, not 5 s
        assert!(!stall_detected(EngineStatus::Loading, true, long, long));
        assert!(stall_detected(EngineStatus::Loading, true, short, very_long));
        // nothing loaded: nothing to stall
        assert!(!stall_detected(EngineStatus::Idle, true, very_long, very_long));
    }

    #[test]
    fn login_failures_are_classified() {
        assert_eq!(
            classify_login_failure(
                ErrorKind::FailedPrecondition,
                "Login request was denied: INVALID_CREDENTIALS"
            ),
            FailureCause::CredentialsRejected
        );
        assert_eq!(
            classify_login_failure(ErrorKind::Unavailable, "connection refused"),
            FailureCause::Network
        );
        assert_eq!(
            classify_login_failure(ErrorKind::DeadlineExceeded, "timeout"),
            FailureCause::Network
        );
        assert_eq!(
            classify_login_failure(ErrorKind::Internal, "something else"),
            FailureCause::Other
        );
    }

    #[test]
    fn messages_give_a_reason_and_a_next_step() {
        for cause in [
            FailureCause::CredentialsRejected,
            FailureCause::Network,
            FailureCause::SessionLost,
            FailureCause::TrackUnavailable,
            FailureCause::Other,
        ] {
            let m = describe_failure(cause);
            assert!(m.len() > 30, "{cause:?} message too short");
            assert!(!m.to_lowercase().contains("bearer"));
        }
        assert!(describe_failure(FailureCause::CredentialsRejected).contains("Premium"));
        assert!(describe_failure(FailureCause::TrackUnavailable).contains("Free"));
    }

    #[test]
    fn engine_start_errors_map_to_hints() {
        assert!(describe_engine_start_error("No token found; user must log in").contains("signed in"));
        assert!(describe_engine_start_error("No audio backend found").contains("PipeWire"));
        assert!(describe_engine_start_error("session connect failed: boom").contains("session"));
        assert!(describe_engine_start_error("???").contains("--doctor"));
    }
}
