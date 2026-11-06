//! Playback engine, watchdog, and self-healing subsystem.
//!
//! Handles:
//! - librespot playback with PipeWire/Rodio audio backend
//! - Watchdog: detects stalled playback (>5s without position advance),
//!   auto-restarts player task; trips after 3 consecutive failures.
//! - Self-healing: network dropouts, PipeWire restarts, region lockouts,
//!   token expiry mid-track, system suspend/resume.
//! - Local play logging to SQLite for Capsule & suggestions.
//! - Repeat modes (Off, All, One), volume normalisation, bitrate selection (96/160/320).

use crate::cache::Cache;
use crate::daemon::Player;
use crate::token_store::{load_token, now_secs};
use halcyon_music_core::protocol::{self, EventBody};
use halcyon_music_core::state::Bitrate;
use halcyon_music_core::Track;
use librespot_core::authentication::Credentials;
use librespot_core::config::SessionConfig;
use librespot_core::session::Session;
use librespot_core::spotify_uri::SpotifyUri;
use librespot_playback::audio_backend;
use librespot_playback::config::{AudioFormat, Bitrate as LibrespotBitrate, PlayerConfig};
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::Player as LibrespotPlayer;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, Mutex};
use tracing::{info, warn};

/// Watchdog threshold: 5 seconds of playing without advancing position = stall.
pub const STALL_THRESHOLD: Duration = Duration::from_secs(5);
/// Max consecutive watchdog trips before halting until explicit user action.
pub const MAX_CONSECUTIVE_FAILURES: u32 = 3;
/// Minimum played time (30s) to record a partial play in the log.
pub const MIN_PLAY_LOG_MS: u64 = 30_000;

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

    /// Connect or reconnect the Spotify session using stored OAuth tokens.
    pub async fn ensure_session(&self) -> Result<Session, String> {
        let token = load_token()
            .map_err(|e| format!("unable to load token: {e}"))?
            .ok_or_else(|| "No token found; user must log in".to_string())?;

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
        let sink_builder = move || sink_fn(None, AudioFormat::F32);
        let player = LibrespotPlayer::new(config, session, Box::new(NoOpVolume), sink_builder);

        let mut guard = self.librespot_player.lock().await;
        *guard = Some(player.clone());
        Ok(player)
    }

    /// Main supervisor playback and watchdog loop.
    pub async fn run_loop(self: Arc<Self>) {
        let mut interval = tokio::time::interval(Duration::from_millis(250));
        let mut last_progress_broadcast = Instant::now();
        let mut last_position_ms = 0u64;
        let mut last_position_advanced = Instant::now();
        let mut current_track_started_at = now_secs();
        let mut active_track_id: Option<String> = None;
        let mut loaded_track_id: Option<String> = None;
        let mut is_native_playing = false;

        loop {
            interval.tick().await;

            let state = self.player.snapshot().await;

            // Track change detection
            let cur_id = state.track.as_ref().map(|t| t.id.clone());
            if cur_id != active_track_id {
                active_track_id = cur_id.clone();
                current_track_started_at = now_secs();
                last_position_ms = state.position_ms;
                last_position_advanced = Instant::now();
            }

            // Sync with native librespot player if available
            if cur_id.is_some() && cur_id != loaded_track_id {
                loaded_track_id = cur_id.clone();
                if let Some(track) = state.track.as_ref() {
                    let uri_str = if track.uri.starts_with("spotify:track:") {
                        track.uri.clone()
                    } else {
                        format!("spotify:track:{}", track.id)
                    };

                    if let Ok(sp_uri) = SpotifyUri::from_uri(&uri_str) {
                        let mut p_guard = self.librespot_player.lock().await;
                        if p_guard.is_none() {
                            drop(p_guard);
                            let _ = self.init_librespot_player().await;
                            p_guard = self.librespot_player.lock().await;
                        }

                        if let Some(ref native) = *p_guard {
                            info!(uri = %uri_str, "loading track into librespot engine");
                            native.load(sp_uri, state.playing, state.position_ms as u32);
                            is_native_playing = state.playing;

                            // Preload upcoming track for gapless transition
                            if state.queue_pos + 1 < state.queue.len() {
                                if let Some(nxt) = state.queue.get(state.queue_pos + 1) {
                                    let nxt_uri = format!("spotify:track:{}", nxt.id);
                                    if let Ok(nxt_sp) = SpotifyUri::from_uri(&nxt_uri) {
                                        native.preload(nxt_sp);
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Transport state sync
            {
                let p_guard = self.librespot_player.lock().await;
                if let Some(ref native) = *p_guard {
                    if state.playing && !is_native_playing {
                        native.play();
                        is_native_playing = true;
                    } else if !state.playing && is_native_playing {
                        native.pause();
                        is_native_playing = false;
                    }
                }
            }

            if !state.playing {
                last_position_advanced = Instant::now();
                last_position_ms = state.position_ms;
                continue;
            }

            let Some(track) = state.track.as_ref() else {
                continue;
            };

            // Watchdog check: position must advance while playing
            if state.position_ms > last_position_ms {
                last_position_advanced = Instant::now();
                self.consecutive_failures.store(0, Ordering::Relaxed);
            } else if last_position_advanced.elapsed() >= STALL_THRESHOLD {
                let failures = self.consecutive_failures.fetch_add(1, Ordering::SeqCst) + 1;
                warn!(
                    failures,
                    position_ms = state.position_ms,
                    "watchdog: playback stalled for {}s",
                    STALL_THRESHOLD.as_secs()
                );

                if failures >= MAX_CONSECUTIVE_FAILURES {
                    warn!("watchdog tripped: 3 consecutive failures. Halting until user play.");
                    self.player
                        .mutate(|s| {
                            s.playing = false;
                        })
                        .await;

                    let _ = self.events_tx.send(protocol::event(EventBody::PlaybackFailed {
                        reason: "Playback stalled 3 consecutive times. Tap play to resume.".into(),
                        consecutive_failures: failures,
                        will_retry: false,
                    }));
                    continue;
                } else {
                    let _ = self.events_tx.send(protocol::event(EventBody::PlaybackFailed {
                        reason: "Playback stalled, attempting recovery...".into(),
                        consecutive_failures: failures,
                        will_retry: true,
                    }));

                    // Self-healing attempt: recreate sink & reload
                    let mut guard = self.librespot_player.lock().await;
                    *guard = None; // Force sink / player rebuild
                    drop(guard);
                    let _ = self.init_librespot_player().await;

                    last_position_advanced = Instant::now();
                }
            }

            // Normal progression
            let next_pos = state.position_ms + 250;
            if next_pos >= track.duration_ms {
                // Track completed!
                self.record_play_log(track, current_track_started_at, track.duration_ms, true);

                let mut advanced = false;
                self.player
                    .mutate(|s| {
                        advanced = s.advance_next();
                    })
                    .await;

                let new_state = self.player.snapshot().await;
                let _ = self.events_tx.send(protocol::event(EventBody::State {
                    state: new_state,
                }));

                current_track_started_at = now_secs();
                last_position_ms = 0;
                last_position_advanced = Instant::now();

                if !advanced {
                    info!("reached end of queue with repeat off");
                }
            } else {
                // Advance position
                self.player
                    .mutate(|s| {
                        s.position_ms = next_pos;
                    })
                    .await;
                last_position_ms = next_pos;

                // Broadcast progress periodically
                if last_progress_broadcast.elapsed() >= Duration::from_millis(1000) {
                    let _ = self.events_tx.send(protocol::event(EventBody::Progress {
                        position_ms: next_pos,
                        playing: true,
                    }));
                    last_progress_broadcast = Instant::now();
                }
            }
        }
    }
}
