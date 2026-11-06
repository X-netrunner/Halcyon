//! The daemon itself: socket server, shared player state, supervised
//! simulated player (real playback arrives in Part 3), persistence loop,
//! systemd watchdog heartbeats, SQLite cache, and Spotify API client.

use crate::api::{self, SpotifyClient};
use crate::auth;
use crate::cache::Cache;
use crate::panic_hook;
use crate::probes;
use crate::sd_notify;
use crate::state_store;
use crate::supervisor;
use crate::token_store;
use halcyon_music_core::models::AuthStatus;
use halcyon_music_core::paths;
use halcyon_music_core::protocol::{self, CommandBody, EventBody};
use halcyon_music_core::{PlayerState, RepeatMode};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{broadcast, watch, Mutex, RwLock};
use tracing::{error, info, warn};

/// Save state to disk every 5 s and on every change (Part 1 rule 4).
const SAVE_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);
/// Watchdog heartbeat interval; systemd WatchdogSec must be > 2x this.
const WATCHDOG_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10);
/// Cap the event broadcast channel; a slow client must never stall others.
const EVENT_CHANNEL_CAP: usize = 256;

/// Shared player handle: state + a dirty flag the persistence loop drains.
pub struct Player {
    state: RwLock<PlayerState>,
    /// Set on every mutation; drained by the persistence loop.
    dirty: watch::Sender<bool>,
}

impl Player {
    pub fn new(state: PlayerState, dirty: watch::Sender<bool>) -> Self {
        Self {
            state: RwLock::new(state),
            dirty,
        }
    }

    pub async fn snapshot(&self) -> PlayerState {
        self.state.read().await.clone()
    }

    pub async fn mutate(&self, f: impl FnOnce(&mut PlayerState)) {
        {
            let mut guard = self.state.write().await;
            f(&mut guard);
            guard.sanitize();
        }
        // Ignore send errors: only means nobody is draining yet.
        let _ = self.dirty.send(true);
    }
}

/// Shared daemon context across all connections and background tasks.
pub struct DaemonContext {
    pub player: Arc<Player>,
    pub cache: Cache,
    pub spotify: SpotifyClient,
    pub events_tx: broadcast::Sender<protocol::Event>,
    pub login_cancel: Arc<Mutex<Option<tokio::sync::oneshot::Sender<()>>>>,
}

pub fn run() -> anyhow::Result<()> {
    let state_dir = paths::state_dir();
    std::fs::create_dir_all(&state_dir)?;

    let file_appender = tracing_appender::rolling::daily(&state_dir, "halcyon-musicd.log");
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(file_appender)
        .try_init();

    panic_hook::install(&state_dir);

    // Restore state (moved aside + rebuilt if corrupt).
    let loaded = state_store::load(&paths::state_file());
    if loaded.recovered {
        warn!("state recovery: {}", loaded.note.clone().unwrap_or_default());
    }
    info!(
        playing = loaded.state.playing,
        track = ?loaded.state.track.as_ref().map(|t| &t.title),
        "daemon starting, state restored"
    );

    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("halcyon-musicd")
        .build()?;
    rt.block_on(async_main(loaded.state))?;

    Ok(())
}

async fn async_main(restored: PlayerState) -> anyhow::Result<()> {
    let state_dir = paths::state_dir();
    let socket_dir = paths::socket_dir();
    std::fs::create_dir_all(&socket_dir)?;
    let socket_path = paths::ctl_socket();

    if socket_path.exists() {
        if UnixStream::connect(&socket_path).await.is_ok() {
            anyhow::bail!(
                "another daemon already listens on {}; refusing to start twice",
                socket_path.display()
            );
        }
        warn!(path = %socket_path.display(), "removing stale socket file");
        let _ = std::fs::remove_file(&socket_path);
    }

    let listener = UnixListener::bind(&socket_path)?;
    info!(path = %socket_path.display(), "control socket bound");

    let (dirty_tx, dirty_rx) = watch::channel(false);
    let (events_tx, _) = broadcast::channel(EVENT_CHANNEL_CAP);
    let player = Arc::new(Player::new(restored, dirty_tx));
    let was_playing = player.snapshot().await.playing;

    // Open SQLite cache
    let cache = match Cache::open_default() {
        Ok(c) => c,
        Err(e) => {
            warn!("unable to open cache database: {e}; attempting memory fallback");
            Cache::open(&state_dir.join("cache.db"), &state_dir.join("images"), 500 * 1024 * 1024)
                .map_err(|e| anyhow::anyhow!("cache open failed: {e}"))?
        }
    };

    let spotify = SpotifyClient::new(None, None);

    let ctx = Arc::new(DaemonContext {
        player: player.clone(),
        cache: cache.clone(),
        spotify: spotify.clone(),
        events_tx: events_tx.clone(),
        login_cancel: Arc::new(Mutex::new(None)),
    });

    // Supervised player task with watchdog & play log
    {
        let player = player.clone();
        let cache = cache.clone();
        let events = events_tx.clone();
        supervisor::supervise("player", None, move || {
            let engine = Arc::new(crate::audio::AudioEngine::new(
                player.clone(),
                cache.clone(),
                events.clone(),
            ));
            async move {
                engine.run_loop().await;
                Ok(())
            }
        });
    }

    // MPRIS 2 D-Bus server on user session bus
    {
        let player = player.clone();
        let cache = cache.clone();
        let events = events_tx.clone();
        tokio::spawn(async move {
            match crate::mpris::start_mpris_server(player, cache, events).await {
                Ok(_conn) => {
                    info!("MPRIS 2 server running");
                    std::future::pending::<()>().await;
                }
                Err(e) => {
                    warn!("failed to start MPRIS 2 server: {e}");
                }
            }
        });
    }

    // Supervised persistence task
    {
        let player = player.clone();
        let state_dir = state_dir.clone();
        supervisor::supervise("persistence", None, move || {
            let player = player.clone();
            let mut dirty_rx = dirty_rx.clone();
            let path = state_dir.join(paths::STATE_FILE_NAME);
            async move { persistence_loop(player, path, &mut dirty_rx).await }
        });
    }

    // Systemd watchdog heartbeat
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(WATCHDOG_INTERVAL);
        loop {
            interval.tick().await;
            sd_notify::notify_watchdog();
        }
    });

    sd_notify::notify_main_pid();
    sd_notify::notify_ready();

    if was_playing {
        player.mutate(|s| s.playing = true).await;
        info!("was playing before shutdown; resuming");
    }

    // Background endpoint probes check if authenticated
    {
        let spotify = spotify.clone();
        let cache = cache.clone();
        tokio::spawn(async move {
            if spotify.is_authenticated().await {
                let _ = probes::evaluate_probes(&spotify, &cache).await;
            }
        });
    }

    // Client accept loop
    loop {
        let (stream, _) = listener.accept().await?;
        let ctx = ctx.clone();
        let mut events = events_tx.subscribe();
        tokio::spawn(async move {
            if let Err(e) = handle_client(stream, ctx, &mut events).await {
                warn!(error = %e, "client connection ended");
            }
        });
    }
}

/// One client connection: read NDJSON commands, write NDJSON events.
async fn handle_client(
    stream: UnixStream,
    ctx: Arc<DaemonContext>,
    events: &mut broadcast::Receiver<protocol::Event>,
) -> anyhow::Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    // Say hello + send a full snapshot so the GUI paints immediately.
    let hello = protocol::event(EventBody::Hello {
        daemon_version: halcyon_music_core::CORE_VERSION.to_string(),
        protocol_version: protocol::PROTOCOL_VERSION,
    });
    writer.write_all(&protocol::encode_line(&hello)?).await?;
    let snapshot = protocol::event(EventBody::State {
        state: ctx.player.snapshot().await,
    });
    writer.write_all(&protocol::encode_line(&snapshot)?).await?;

    // Send initial AuthStatus
    let auth_status = if ctx.spotify.is_authenticated().await {
        let user_id = ctx.spotify.current_user_id().await;
        EventBody::AuthStatus(AuthStatus::LoggedIn {
            user_id,
            display_name: None,
        })
    } else {
        EventBody::AuthStatus(AuthStatus::LoggedOut)
    };
    writer.write_all(&protocol::encode_line(&protocol::event(auth_status))?).await?;

    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else { return Ok(()) };
                if line.trim().is_empty() { continue; }
                let Ok(cmd) = protocol::decode_line::<protocol::Command>(line.as_bytes()) else {
                    let ev = protocol::event(EventBody::Error {
                        message: "Got a message the daemon did not understand; ignored.".into(),
                    });
                    writer.write_all(&protocol::encode_line(&ev)?).await?;
                    continue;
                };
                if cmd.version > protocol::PROTOCOL_VERSION {
                    warn!(version = cmd.version, "client speaks a newer protocol; ignoring unknown fields");
                }
                if let Some(response) = apply_command(&ctx, cmd.body).await {
                    writer.write_all(&protocol::encode_line(&response)?).await?;
                }
            }
            ev = events.recv() => {
                match ev {
                    Ok(ev) => writer.write_all(&protocol::encode_line(&ev)?).await?,
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(skipped = n, "client was lagging; dropped old events");
                    }
                    Err(broadcast::error::RecvError::Closed) => return Ok(()),
                }
            }
        }
    }
}

/// Apply a command to shared state and trigger data fetching / auth flows.
pub async fn apply_command(ctx: &Arc<DaemonContext>, body: CommandBody) -> Option<protocol::Event> {
    use CommandBody::*;
    match body {
        Play => {
            ctx.player
                .mutate(|s| {
                    if s.track.is_none() {
                        s.track = s.queue.get(s.queue_pos).cloned();
                    }
                    if s.track.is_some() {
                        s.playing = true;
                    }
                })
                .await;
        }
        Pause => ctx.player.mutate(|s| s.playing = false).await,
        Toggle => ctx.player.mutate(|s| s.playing = !s.playing).await,
        Seek { position_ms } => ctx.player.mutate(|s| s.position_ms = position_ms).await,
        SeekBy { delta_ms } => {
            ctx.player
                .mutate(|s| {
                    s.position_ms = (s.position_ms as i64).saturating_add(delta_ms).max(0) as u64;
                })
                .await;
        }
        Next => next_track(&ctx.player).await,
        Previous => previous_track(&ctx.player).await,
        SetVolume { volume } => ctx.player.mutate(|s| s.volume = volume.min(100)).await,
        VolumeBy { delta } => {
            ctx.player
                .mutate(|s| {
                    s.volume = (s.volume as i16).saturating_add(delta as i16).clamp(0, 100) as u8;
                })
                .await;
        }
        SetShuffle { shuffle } => ctx.player.mutate(|s| s.shuffle = shuffle).await,
        CycleRepeat => {
            ctx.player
                .mutate(|s| {
                    s.repeat = match s.repeat {
                        RepeatMode::Off => RepeatMode::All,
                        RepeatMode::All => RepeatMode::One,
                        RepeatMode::One => RepeatMode::Off,
                    };
                })
                .await;
        }
        Hello => {}
        GetState => {
            return Some(protocol::event(EventBody::State {
                state: ctx.player.snapshot().await,
            }));
        }
        PlayNext { track } => ctx.player.mutate(|s| s.play_next(track)).await,
        Enqueue { track } => ctx.player.mutate(|s| s.enqueue(track)).await,
        Dequeue { index } => {
            ctx.player
                .mutate(|s| {
                    let _ = s.dequeue(index);
                })
                .await;
        }
        PlayTrack { track } => ctx.player.mutate(|s| s.play_track(track)).await,
        PlayContext { tracks, start_index } => {
            ctx.player
                .mutate(|s| s.play_context(tracks, start_index))
                .await;
        }
        ReorderQueue { from, to } => {
            ctx.player
                .mutate(|s| {
                    let _ = s.reorder(from, to);
                })
                .await;
        }
        SetRepeat { repeat } => ctx.player.mutate(|s| s.repeat = repeat).await,
        SetBitrate { bitrate } => ctx.player.mutate(|s| s.bitrate = bitrate).await,
        SetNormalisation { enabled } => ctx.player.mutate(|s| s.normalisation = enabled).await,

        // --- Part 2 Auth & Spotify API Commands ---

        LoginStart { client_id } => {
            let (tx, mut rx) = tokio::sync::oneshot::channel();
            {
                let mut guard = ctx.login_cancel.lock().await;
                if let Some(old_cancel) = guard.take() {
                    let _ = old_cancel.send(());
                }
                *guard = Some(tx);
            }

            match auth::start_pkce_flow(&client_id).await {
                Ok((session, listener)) => {
                    let auth_url = session.auth_url.clone();
                    let ctx_clone = ctx.clone();
                    let session_clone = session.clone();

                    tokio::spawn(async move {
                        tokio::select! {
                            _ = &mut rx => {
                                info!("login flow canceled by client");
                            }
                            res = auth::wait_for_callback(listener, &session_clone.state, Duration::from_secs(120)) => {
                                match res {
                                    Ok(code) => {
                                        let http = reqwest::Client::new();
                                        match auth::exchange_code(&http, &session_clone, &code).await {
                                            Ok(token) => {
                                                ctx_clone.spotify.set_token(token.clone()).await;
                                                let user_id = Some(token.client_id);
                                                let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthSuccess {
                                                    user_id: user_id.clone(),
                                                }));
                                                let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthStatus(
                                                    AuthStatus::LoggedIn {
                                                        user_id,
                                                        display_name: None,
                                                    },
                                                )));
                                                // Trigger background probes
                                                let _ = probes::evaluate_probes(&ctx_clone.spotify, &ctx_clone.cache).await;
                                            }
                                            Err(e) => {
                                                error!("token exchange failed: {e}");
                                                let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthStatus(
                                                    AuthStatus::Error { message: e },
                                                )));
                                            }
                                        }
                                    }
                                    Err(e) => {
                                        error!("callback error: {e}");
                                        let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthStatus(
                                            AuthStatus::Error { message: e },
                                        )));
                                    }
                                }
                            }
                        }
                    });

                    return Some(protocol::event(EventBody::AuthStatus(AuthStatus::LoggingIn {
                        auth_url,
                    })));
                }
                Err(e) => {
                    return Some(protocol::event(EventBody::AuthStatus(AuthStatus::Error {
                        message: e,
                    })));
                }
            }
        }

        LoginCancel => {
            let mut guard = ctx.login_cancel.lock().await;
            if let Some(cancel) = guard.take() {
                let _ = cancel.send(());
            }
            return Some(protocol::event(EventBody::AuthStatus(AuthStatus::LoggedOut)));
        }

        Logout => {
            let _ = token_store::clear_token();
            ctx.spotify.clear_token().await;
            return Some(protocol::event(EventBody::AuthStatus(AuthStatus::LoggedOut)));
        }

        GetAuthStatus => {
            let status = if ctx.spotify.is_authenticated().await {
                let user_id = ctx.spotify.current_user_id().await;
                AuthStatus::LoggedIn {
                    user_id,
                    display_name: None,
                }
            } else {
                AuthStatus::LoggedOut
            };
            return Some(protocol::event(EventBody::AuthStatus(status)));
        }

        GetPlaylists { limit, offset } => {
            let limit_val = limit.unwrap_or(20) as usize;
            let offset_val = offset.unwrap_or(0) as usize;

            // 1. Stale-while-revalidate: instant return from cache
            let (cached_playlists, cached_total) = ctx
                .cache
                .get_playlists(limit_val, offset_val)
                .unwrap_or_default();

            if !cached_playlists.is_empty() {
                let _ = ctx.events_tx.send(protocol::event(EventBody::PlaylistsResult {
                    playlists: cached_playlists.clone(),
                    total: cached_total,
                    offset: offset_val,
                    is_cached: true,
                }));
            }

            // 2. Fetch fresh from Spotify
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.get_playlists(limit_val as u32, offset_val as u32).await {
                    Ok(page) => {
                        let _ = ctx_c.cache.put_playlists(&page.items);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistsResult {
                            playlists: page.items,
                            total: page.total,
                            offset: page.offset,
                            is_cached: false,
                        }));
                    }
                    Err(api::ApiError::AuthRequired(reason)) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::AuthRequired { reason }));
                    }
                    Err(e) => {
                        warn!("playlists refresh failed ({e}); serving cache");
                    }
                }
            });

            if !cached_playlists.is_empty() {
                return Some(protocol::event(EventBody::PlaylistsResult {
                    playlists: cached_playlists,
                    total: cached_total,
                    offset: offset_val,
                    is_cached: true,
                }));
            }
            return None;
        }

        GetPlaylistTracks { id, limit, offset } => {
            let limit_val = limit.unwrap_or(50) as usize;
            let offset_val = offset.unwrap_or(0) as usize;

            let (cached_tracks, cached_total) = ctx
                .cache
                .get_playlist_tracks(&id, limit_val, offset_val)
                .unwrap_or_default();

            if !cached_tracks.is_empty() {
                let _ = ctx.events_tx.send(protocol::event(EventBody::PlaylistTracksResult {
                    playlist_id: id.clone(),
                    tracks: cached_tracks.clone(),
                    total: cached_total,
                    offset: offset_val,
                    is_cached: true,
                }));
            }

            let ctx_c = ctx.clone();
            let pid = id.clone();
            tokio::spawn(async move {
                match ctx_c
                    .spotify
                    .get_playlist_tracks(&pid, limit_val as u32, offset_val as u32)
                    .await
                {
                    Ok(page) => {
                        let _ = ctx_c.cache.set_playlist_tracks(&pid, &page.items);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistTracksResult {
                            playlist_id: pid,
                            tracks: page.items,
                            total: page.total,
                            offset: page.offset,
                            is_cached: false,
                        }));
                    }
                    Err(api::ApiError::AuthRequired(reason)) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::AuthRequired { reason }));
                    }
                    Err(e) => {
                        warn!("playlist tracks refresh failed ({e}); serving cache");
                    }
                }
            });

            if !cached_tracks.is_empty() {
                return Some(protocol::event(EventBody::PlaylistTracksResult {
                    playlist_id: id,
                    tracks: cached_tracks,
                    total: cached_total,
                    offset: offset_val,
                    is_cached: true,
                }));
            }
            return None;
        }

        GetLikedTracks { limit, offset } => {
            let limit_val = limit.unwrap_or(50) as usize;
            let offset_val = offset.unwrap_or(0) as usize;

            let (cached_tracks, cached_total) = ctx
                .cache
                .get_liked_tracks(limit_val, offset_val)
                .unwrap_or_default();

            if !cached_tracks.is_empty() {
                let _ = ctx.events_tx.send(protocol::event(EventBody::LikedTracksResult {
                    tracks: cached_tracks.clone(),
                    total: cached_total,
                    offset: offset_val,
                    is_cached: true,
                }));
            }

            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c
                    .spotify
                    .get_saved_tracks(limit_val as u32, offset_val as u32)
                    .await
                {
                    Ok(page) => {
                        let _ = ctx_c.cache.set_liked_tracks(&page.items);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::LikedTracksResult {
                            tracks: page.items,
                            total: page.total,
                            offset: page.offset,
                            is_cached: false,
                        }));
                    }
                    Err(api::ApiError::AuthRequired(reason)) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::AuthRequired { reason }));
                    }
                    Err(e) => {
                        warn!("liked tracks refresh failed ({e}); serving cache");
                    }
                }
            });

            if !cached_tracks.is_empty() {
                return Some(protocol::event(EventBody::LikedTracksResult {
                    tracks: cached_tracks,
                    total: cached_total,
                    offset: offset_val,
                    is_cached: true,
                }));
            }
            return None;
        }

        Search { query, limit, offset } => {
            let limit_val = limit.unwrap_or(10).min(10);
            let offset_val = offset.unwrap_or(0);
            let ctx_c = ctx.clone();
            let q = query.clone();

            tokio::spawn(async move {
                match ctx_c.spotify.search_tracks(&q, limit_val, offset_val).await {
                    Ok(page) => {
                        let _ = ctx_c.cache.put_tracks(&page.items);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::SearchResults {
                            query: q,
                            tracks: page.items,
                            total: page.total,
                            is_cached: false,
                        }));
                    }
                    Err(api::ApiError::AuthRequired(reason)) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::AuthRequired { reason }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Search failed: {e}"),
                        }));
                    }
                }
            });

            return None;
        }

        ProbeEndpoints => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                let probes = probes::evaluate_probes(&ctx_c.spotify, &ctx_c.cache).await;
                let _ = ctx_c.events_tx.send(protocol::event(EventBody::ProbeResult { probes }));
            });
            return None;
        }

        Unknown => {
            return Some(protocol::event(EventBody::Error {
                message: "That command is not supported by this daemon version.".into(),
            }));
        }
    }

    Some(protocol::event(EventBody::State {
        state: ctx.player.snapshot().await,
    }))
}

async fn next_track(player: &Arc<Player>) {
    player
        .mutate(|s| {
            let _ = s.advance_next();
        })
        .await;
}

async fn previous_track(player: &Arc<Player>) {
    player
        .mutate(|s| {
            let _ = s.advance_prev();
        })
        .await;
}

async fn persistence_loop(
    player: Arc<Player>,
    path: std::path::PathBuf,
    dirty_rx: &mut watch::Receiver<bool>,
) -> anyhow::Result<()> {
    let mut interval = tokio::time::interval(SAVE_INTERVAL);
    loop {
        tokio::select! {
            _ = interval.tick() => {
                save_state(&player, &path).await;
            }
            changed = dirty_rx.changed() => {
                if changed.is_err() {
                    // Sender gone
                }
                while dirty_rx.has_changed().unwrap_or(false) {
                    let _ = dirty_rx.changed().await;
                }
                save_state(&player, &path).await;
            }
        }
    }
}

async fn save_state(player: &Arc<Player>, path: &std::path::Path) {
    let snap = player.snapshot().await;
    if let Err(e) = state_store::save(path, &snap) {
        warn!(error = %e, "could not save state; will retry on next change");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use halcyon_music_core::Track;

    fn dummy_ctx(player: Arc<Player>) -> Arc<DaemonContext> {
        let (tx, _) = broadcast::channel(16);
        let dir = tempfile::tempdir().expect("tempdir");
        let cache = Cache::open(&dir.path().join("c.db"), &dir.path().join("i"), 1024 * 1024).expect("cache");
        let spotify = SpotifyClient::new(None, None);
        Arc::new(DaemonContext {
            player,
            cache,
            spotify,
            events_tx: tx,
            login_cancel: Arc::new(Mutex::new(None)),
        })
    }

    #[tokio::test]
    async fn player_mutate_marks_dirty_and_sanitizes() {
        let (tx, rx) = watch::channel(false);
        let p = Player::new(PlayerState::default(), tx);
        p.mutate(|s| s.volume = 200).await;
        assert!(rx.has_changed().unwrap_or(false));
        assert_eq!(p.snapshot().await.volume, 100);
    }

    #[tokio::test]
    async fn apply_next_advances_queue() {
        let (tx, _rx) = watch::channel(false);
        let p = Arc::new(Player::new(PlayerState::default(), tx));
        let ctx = dummy_ctx(p.clone());
        let t = |id: &str| Track::simple(id.into(), id.into(), "a".into(), "b".into(), 1000);
        p.mutate(|s| {
            s.queue = vec![t("1"), t("2"), t("3")];
            s.queue_pos = 0;
            s.track = Some(t("1"));
        })
        .await;
        apply_command(&ctx, CommandBody::Next).await;
        let s = p.snapshot().await;
        assert_eq!(s.queue_pos, 1);
        assert_eq!(s.track.as_ref().map(|t| t.id.as_str()), Some("2"));

        apply_command(&ctx, CommandBody::Next).await;
        let s = p.snapshot().await;
        // With RepeatMode::Off (default), Next at end of queue stays at end and stops
        assert_eq!(s.queue_pos, 2);
        assert!(!s.playing);

        // With RepeatMode::All, Next at end wraps to 0
        p.mutate(|s| s.repeat = RepeatMode::All).await;
        apply_command(&ctx, CommandBody::Next).await;
        let s = p.snapshot().await;
        assert_eq!(s.queue_pos, 0);
    }

    #[tokio::test]
    async fn play_with_empty_track_loads_queue_head() {
        let (tx, _rx) = watch::channel(false);
        let p = Arc::new(Player::new(PlayerState::default(), tx));
        let ctx = dummy_ctx(p.clone());
        let t = |id: &str| Track::simple(id.into(), id.into(), "a".into(), "b".into(), 1000);
        p.mutate(|s| s.queue = vec![t("1"), t("2")]).await;
        apply_command(&ctx, CommandBody::Play).await;
        let s = p.snapshot().await;
        assert!(s.playing, "play starts playback");
        assert_eq!(s.track.as_ref().map(|t| t.id.as_str()), Some("1"));
    }

    #[tokio::test]
    async fn play_with_nothing_loaded_stays_stopped() {
        let (tx, _rx) = watch::channel(false);
        let p = Arc::new(Player::new(PlayerState::default(), tx));
        let ctx = dummy_ctx(p.clone());
        apply_command(&ctx, CommandBody::Play).await;
        assert!(!p.snapshot().await.playing);
    }

    #[tokio::test]
    async fn apply_repeat_cycles() {
        let (tx, _rx) = watch::channel(false);
        let p = Arc::new(Player::new(PlayerState::default(), tx));
        let ctx = dummy_ctx(p.clone());
        apply_command(&ctx, CommandBody::CycleRepeat).await;
        assert_eq!(p.snapshot().await.repeat, RepeatMode::All);
        apply_command(&ctx, CommandBody::CycleRepeat).await;
        assert_eq!(p.snapshot().await.repeat, RepeatMode::One);
        apply_command(&ctx, CommandBody::CycleRepeat).await;
        assert_eq!(p.snapshot().await.repeat, RepeatMode::Off);
    }
}
