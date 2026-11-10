//! The daemon itself: socket server, shared player state, supervised
//! simulated player (real playback arrives in Part 3), persistence loop,
//! systemd watchdog heartbeats, SQLite cache, and Spotify API client.

use crate::api::{self, SpotifyClient};
use crate::art::{self, ArtFetcher};
use crate::auth;
use crate::cache::Cache;
use crate::lyrics;
use crate::panic_hook;
use crate::probes;
use crate::sd_notify;
use crate::state_store;
use crate::stream_auth;
use crate::supervisor;
use crate::token_store;
use halcyon_music_core::models::{AuthMode, AuthStatus, Lyrics};
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

const KV_SAVED_ALBUMS: &str = "library.saved_albums";
const KV_FOLLOWED_ARTISTS: &str = "library.followed_artists";
const KV_DISCOVER: &str = "discover.feed";
const KV_HOME: &str = "home.feed";

/// True while a Discover build runs; a second request waits for that one instead of starting
/// another round of Spotify lookups.
static DISCOVER_RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Clears `DISCOVER_RUNNING` when the build ends, even if it panics.
struct DiscoverGuard;

impl Drop for DiscoverGuard {
    fn drop(&mut self) {
        DISCOVER_RUNNING.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}
/// True while the background matching of the big lists (All-Time Best, Top 100, Top 200) runs,
/// so two Home loads do not start two rounds of Spotify lookups.
static HOME_WARMING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Clears `HOME_WARMING` when the matching ends, even if it panics.
struct WarmGuard;

impl Drop for WarmGuard {
    fn drop(&mut self) {
        HOME_WARMING.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

/// Kept for a month; the copy is served even when stale.
const LIBRARY_KV_TTL_SECS: u64 = 30 * 24 * 3600;

/// Read a JSON value from the cache, stale or not. A corrupt entry is ignored.
fn kv_load<T: serde::de::DeserializeOwned>(cache: &crate::cache::Cache, key: &str) -> Option<T> {
    let item = cache.kv_get(key).ok().flatten()?;
    serde_json::from_str(&item.item).ok()
}

const KV_ACCOUNT: &str = crate::profile::KV_ACCOUNT;

/// The "signed in" status for the GUI, with the account name when it is known.
async fn logged_in_status(ctx: &DaemonContext) -> AuthStatus {
    let user_id = ctx.spotify.current_user_id().await;
    let display_name = ctx.spotify.cached_account().await.and_then(|a| a.display_name);
    AuthStatus::LoggedIn { user_id, display_name }
}

/// The profile event for an account (name and picture URL).
fn profile_event(account: &crate::api::AccountInfo) -> protocol::Event {
    protocol::event(EventBody::Profile {
        display_name: account.display_name.clone(),
        image_url: account.image_url.clone(),
        username: account.username.clone(),
        plan: account.plan.clone(),
    })
}

/// Forget the remembered account (sign-in, sign-out): the next one is read again.
async fn forget_account(ctx: &DaemonContext) {
    ctx.spotify.set_cached_account(None).await;
    kv_store(&ctx.cache, KV_ACCOUNT, &Option::<crate::api::AccountInfo>::None);
}

/// True while one background task is looking for the account name (so reconnecting GUIs do not
/// start a second one).
static ACCOUNT_REFRESHING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Set by the Refresh button while the task is waiting between attempts: it then looks again now.
static ACCOUNT_NUDGE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Clears `ACCOUNT_REFRESHING` when the task ends, even if it panics.
struct AccountGuard;

impl Drop for AccountGuard {
    fn drop(&mut self) {
        ACCOUNT_REFRESHING.store(false, std::sync::atomic::Ordering::SeqCst);
    }
}

/// Find out who is signed in, keep it, and tell the GUI. The order (see `profile.rs`): the cached
/// account (already shown), then the streaming session (no Web API quota), then `/v1/me` only when
/// nothing gave a name and no rate-limit wait is running. If the name is still unknown the task
/// tries again in the background after 10 s, 1 min and 10 min; nothing here blocks the UI and a
/// failure never blanks a name that is already known.
async fn refresh_account(ctx: Arc<DaemonContext>) {
    if ACCOUNT_REFRESHING.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    let _guard = AccountGuard;
    let mut attempt = 0usize;
    loop {
        let old = ctx.spotify.cached_account().await;
        let web_allowed = ctx
            .spotify
            .rate_limit_remaining(crate::api::EndpointFamily::Other)
            .await
            .is_none();
        let resolved = crate::profile::resolve_with(
            old,
            web_allowed,
            || async { ctx.spotify.session_profile().await.map_err(|e| e.to_string()) },
            || async { ctx.spotify.fetch_account().await.map_err(|e| e.to_string()) },
        )
        .await;
        let known = crate::profile::has_name(resolved.as_ref());
        if let Some(account) = resolved {
            ctx.spotify.set_cached_account(Some(account.clone())).await;
            kv_store(&ctx.cache, KV_ACCOUNT, &account);
            let status = logged_in_status(&ctx).await;
            let _ = ctx.events_tx.send(protocol::event(EventBody::AuthStatus(status)));
            let _ = ctx.events_tx.send(profile_event(&account));
        }
        if known {
            return;
        }
        let Some(delay) = crate::profile::RETRY_DELAYS_SECS.get(attempt).copied() else {
            warn!("could not read the account name; the app shows the username or \"Signed in\"");
            return;
        };
        attempt += 1;
        // Wait in one-second steps so the Refresh button can cut the wait short.
        for _ in 0..delay {
            tokio::time::sleep(Duration::from_secs(1)).await;
            if ACCOUNT_NUDGE.swap(false, std::sync::atomic::Ordering::SeqCst) {
                break;
            }
        }
        if !ctx.spotify.is_authenticated().await {
            return;
        }
    }
}

/// Combine the last Home feed with a fresh build: a section the build left empty keeps its
/// old content, and mixes from outside sources that did not come back this time are kept.
fn merge_home_feed(
    old: halcyon_music_core::models::HomeFeed,
    mut new: halcyon_music_core::models::HomeFeed,
) -> halcyon_music_core::models::HomeFeed {
    macro_rules! keep_if_empty {
        ($($f:ident),*) => { $( if new.$f.is_empty() { new.$f = old.$f.clone(); } )* };
    }
    keep_if_empty!(quick_picks, jump_back_in, new_releases, fresh_releases, popular_charts, playlists, saved_albums);
    if new.capsule_preview.is_none() {
        new.capsule_preview = old.capsule_preview.clone();
    }
    // "Halcyon" (All-Time Best) is built from a fixed list, so it does not show that the
    // outside services answered; only Deezer / ListenBrainz mixes do.
    let from_outside = |m: &halcyon_music_core::models::MusicMix| m.source != "Halcyon Local" && m.source != "Halcyon";
    let new_has_outside = new.made_for_you.iter().any(from_outside);
    if !new_has_outside {
        for mix in old.made_for_you.into_iter().filter(|m| m.source != "Halcyon Local") {
            if !new.made_for_you.iter().any(|m| m.id == mix.id) {
                new.made_for_you.push(mix);
            }
        }
    }
    new
}

/// How long a stored page of songs is trusted before Spotify is asked again.
const TRACKS_FRESH_SECS: u64 = 600;

#[derive(serde::Serialize, serde::Deserialize)]
struct SyncStamp {
    total: usize,
    at: u64,
}

fn sync_key(list_id: &str) -> String {
    format!("sync.tracks.{list_id}")
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Remember that a list was just read from Spotify, and how long it was.
fn mark_synced(cache: &crate::cache::Cache, list_id: &str, total: usize) {
    kv_store(cache, &sync_key(list_id), &SyncStamp { total, at: unix_now() });
}

/// True when the stored copy of this page was read recently and is complete, so Spotify
/// does not need to be asked again (opening the app no longer re-reads every song).
fn page_is_fresh(cache: &crate::cache::Cache, list_id: &str, offset: usize, limit: usize, have: usize) -> bool {
    let Some(stamp) = kv_load::<SyncStamp>(cache, &sync_key(list_id)) else {
        return false;
    };
    if stamp.total == 0 || unix_now().saturating_sub(stamp.at) > TRACKS_FRESH_SECS {
        return false;
    }
    have >= limit.min(stamp.total.saturating_sub(offset)) && have > 0
}

/// Save a JSON value in the cache. Failing to cache is only worth a log line.
fn kv_store<T: serde::Serialize>(cache: &crate::cache::Cache, key: &str, value: &T) {
    match serde_json::to_string(value) {
        Ok(json) => {
            if let Err(e) = cache.kv_set(key, &json, LIBRARY_KV_TTL_SECS) {
                warn!("could not cache {key}: {e}");
            }
        }
        Err(e) => warn!("could not encode {key}: {e}"),
    }
}

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

    /// Cover URL of the current track (cheap: clones one string, not the queue).
    pub async fn current_art_url(&self) -> Option<String> {
        self.state
            .read()
            .await
            .track
            .as_ref()
            .and_then(|t| t.art_url.clone())
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
    pub http: reqwest::Client,
    /// Cover-art downloader and disk cache front end.
    pub art: ArtFetcher,
    pub events_tx: broadcast::Sender<protocol::Event>,
    pub login_cancel: Arc<Mutex<Option<tokio::sync::oneshot::Sender<()>>>>,
}

/// The "made for you" mixes the daemon last saved for Home (what Smart suggestions writes words about).
pub fn load_home_mixes(cache: &Cache) -> Vec<halcyon_music_core::models::MusicMix> {
    kv_load::<halcyon_music_core::models::HomeFeed>(cache, KV_HOME).map(|f| f.made_for_you).unwrap_or_default()
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
        // Plain text: colour codes would split every `key=value` pair and break `grep status=403`.
        .with_ansi(false)
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
        http: reqwest::Client::new(),
        art: ArtFetcher::new(cache.clone()),
        events_tx: events_tx.clone(),
        login_cancel: Arc::new(Mutex::new(None)),
    });

    // Keep the streaming token fresh in the background (also right after suspend/resume).
    supervisor::supervise("stream-token", None, stream_auth::keep_fresh);

    // Supervised cover prefetch for the current track (keeps full-screen,
    // MPRIS and notifications instant)
    {
        let player = player.clone();
        let fetcher = ctx.art.clone();
        let events = events_tx.clone();
        supervisor::supervise("art-prefetch", None, move || {
            art::prefetch_current_track(player.clone(), fetcher.clone(), events.clone())
        });
    }

    // Supervised player task with watchdog & play log
    {
        let player = player.clone();
        let cache = cache.clone();
        let events = events_tx.clone();
        // The direct engine, or (with `--features connect` and HALCYON_CONNECT=1) the Spotify
        // Connect backend. Either way the GUI sees the same state and events.
        supervisor::supervise("player", None, move || {
            let backend = crate::backend::select_backend(
                player.clone(),
                cache.clone(),
                events.clone(),
            );
            async move { backend.run().await }
        });
    }

    // Part 5: keep the recommendation model up to date with new plays and skips.
    {
        let cache = cache.clone();
        supervisor::supervise("reco-learner", None, move || crate::reco::engine::learner_loop(cache.clone()));
    }

    // MPRIS 2 D-Bus server on user session bus
    {
        let player = player.clone();
        let cache = cache.clone();
        let events = events_tx.clone();
        tokio::spawn(async move {
            match crate::mpris::start_mpris_server(player, cache, events).await {
                Ok(conn) => {
                    info!("MPRIS 2 server running");
                    tokio::spawn(crate::mpris::announce_changes(conn.clone()));
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
        // Restore the remembered account name; read it once if there is none yet.
        if ctx.spotify.cached_account().await.is_none() {
            if let Some(account) = kv_load::<crate::api::AccountInfo>(&ctx.cache, KV_ACCOUNT) {
                ctx.spotify.set_cached_account(Some(account)).await;
            }
        }
        // An account saved by an older build has no username or plan (and one that never got
        // a name has no name): look again in the background. The cached copy is shown meanwhile.
        let incomplete = ctx
            .spotify
            .cached_account()
            .await
            .as_ref()
            .map_or(true, |a| a.display_name.is_none() || a.username.is_none());
        if incomplete {
            tokio::spawn(refresh_account(ctx.clone()));
        }
        EventBody::AuthStatus(logged_in_status(&ctx).await)
    } else {
        EventBody::AuthStatus(AuthStatus::LoggedOut)
    };
    writer.write_all(&protocol::encode_line(&protocol::event(auth_status))?).await?;
    let mode_event = protocol::event(EventBody::AuthModeChanged {
        mode: ctx.spotify.auth_mode(),
    });
    writer.write_all(&protocol::encode_line(&mode_event)?).await?;
    let streaming = stream_auth::stored_seconds_left();
    let streaming_status = protocol::event(EventBody::StreamingAuth {
        signed_in: streaming.is_some(),
        seconds_left: streaming,
    });
    writer.write_all(&protocol::encode_line(&streaming_status)?).await?;
    let connect_device = protocol::event(EventBody::ConnectDevice {
        name: crate::connect::registered_name(),
    });
    writer.write_all(&protocol::encode_line(&connect_device)?).await?;

    // Live audio frames are opt-in per connection (`SetAudioStream`), on their own channel.
    let mut audio_rx: Option<broadcast::Receiver<protocol::Event>> = None;

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
                if let CommandBody::SetAudioStream { enabled } = &cmd.body {
                    audio_rx = enabled.then(|| crate::tap::audio_bus().subscribe());
                    continue;
                }
                if let Some(response) = apply_command(&ctx, cmd.body).await {
                    writer.write_all(&protocol::encode_line(&response)?).await?;
                }
            }
            ev = async {
                match audio_rx.as_mut() {
                    Some(rx) => rx.recv().await,
                    None => std::future::pending().await,
                }
            } => {
                match ev {
                    Ok(ev) => writer.write_all(&protocol::encode_line(&ev)?).await?,
                    // A late frame is worth nothing: skip ahead.
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => audio_rx = None,
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
                                                ctx_clone.spotify.switch_mode(AuthMode::OwnClientId).await;
                                                ctx_clone.spotify.reset_circuits().await;
                                                forget_account(&ctx_clone).await;
                                                let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthModeChanged {
                                                    mode: AuthMode::OwnClientId,
                                                }));
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
                                                tokio::spawn(refresh_account(ctx_clone.clone()));
                                                // Trigger background probes
                                                let _ = probes::reprobe(&ctx_clone.spotify, &ctx_clone.cache).await;
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

        LoginStartLibrespot => {
            let (tx, rx) = tokio::sync::oneshot::channel();
            {
                // One sign-in at a time: starting a new one cancels the old one (either kind).
                let mut guard = ctx.login_cancel.lock().await;
                if let Some(old_cancel) = guard.take() {
                    let _ = old_cancel.send(());
                }
                *guard = Some(tx);
            }

            let ctx_clone = ctx.clone();
            tokio::spawn(async move {
                match stream_auth::sign_in(rx).await {
                    Ok(token) => {
                        info!(seconds_left = token.seconds_left(), "streaming sign-in finished");
                        let _ = ctx_clone.events_tx.send(protocol::event(EventBody::StreamingAuth {
                            signed_in: true,
                            seconds_left: Some(token.seconds_left()),
                        }));
                        // A user who chose the advanced own-Client-ID browsing keeps it (this
                        // sign-in is then only for playback). Everyone else browses with the
                        // librespot token.
                        let keep_own = ctx_clone.spotify.auth_mode() == AuthMode::OwnClientId
                            && ctx_clone.spotify.is_authenticated().await;
                        if !keep_own {
                            ctx_clone.spotify.switch_mode(AuthMode::Librespot).await;
                        }
                        let mode = ctx_clone.spotify.auth_mode();
                        let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthModeChanged { mode }));
                        // Earlier failures were seen with another token: start with a clean slate.
                        ctx_clone.spotify.reset_circuits().await;
                        forget_account(&ctx_clone).await;
                        let user_id = ctx_clone.spotify.current_user_id().await;
                        let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthSuccess {
                            user_id: user_id.clone(),
                        }));
                        let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthStatus(
                            AuthStatus::LoggedIn { user_id, display_name: None },
                        )));
                        tokio::spawn(refresh_account(ctx_clone.clone()));
                        let _ = probes::reprobe(&ctx_clone.spotify, &ctx_clone.cache).await;
                    }
                    // The GUI already got `LoggedOut` from LoginCancel.
                    Err(stream_auth::SignInError::Cancelled) => {
                        info!("streaming sign-in cancelled");
                    }
                    Err(e) => {
                        warn!(error = %e, "streaming sign-in failed");
                        let _ = ctx_clone.events_tx.send(protocol::event(EventBody::AuthStatus(
                            AuthStatus::Error { message: e.to_string() },
                        )));
                    }
                }
            });

            // The crate opens the browser itself and does not expose the URL, so there is no
            // link to hand to the GUI (empty `auth_url`; the URL is also in the daemon log).
            return Some(protocol::event(EventBody::AuthStatus(AuthStatus::LoggingIn {
                auth_url: String::new(),
            })));
        }

        SetAuthMode { mode } => {
            ctx.spotify.switch_mode(mode).await;
            let _ = ctx.events_tx.send(protocol::event(EventBody::AuthModeChanged { mode }));
            // The other token may be allowed or refused differently: probe again in the background.
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                let _ = probes::reprobe(&ctx_c.spotify, &ctx_c.cache).await;
            });
            let status = if ctx.spotify.is_authenticated().await {
                logged_in_status(&ctx).await
            } else {
                AuthStatus::LoggedOut
            };
            return Some(protocol::event(EventBody::AuthStatus(status)));
        }

        GetStreamingAuth => {
            let seconds_left = stream_auth::stored_seconds_left();
            return Some(protocol::event(EventBody::StreamingAuth {
                signed_in: seconds_left.is_some(),
                seconds_left,
            }));
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
            if let Err(e) = token_store::clear_librespot_token() {
                warn!("could not remove the streaming sign-in: {e}");
            }
            ctx.spotify.clear_token().await;
            forget_account(&ctx).await;
            ctx.spotify.switch_mode(AuthMode::Librespot).await;
            let _ = ctx.events_tx.send(protocol::event(EventBody::AuthModeChanged {
                mode: AuthMode::Librespot,
            }));
            let _ = ctx.events_tx.send(protocol::event(EventBody::StreamingAuth {
                signed_in: false,
                seconds_left: None,
            }));
            return Some(protocol::event(EventBody::AuthStatus(AuthStatus::LoggedOut)));
        }

        GetProfile => {
            // Answer from what is remembered; read `/me` in the background only when it was
            // never read (or read by a version that did not know about pictures).
            let account = ctx.spotify.cached_account().await;
            let incomplete = account
                .as_ref()
                .map_or(true, |a| !a.images_read || a.display_name.is_none() || a.username.is_none());
            if incomplete && ctx.spotify.is_authenticated().await {
                tokio::spawn(refresh_account(ctx.clone()));
            }
            return Some(match account {
                Some(a) => profile_event(&a),
                None => protocol::event(EventBody::Profile {
                    display_name: None,
                    image_url: None,
                    username: None,
                    plan: None,
                }),
            });
        }

        RefreshProfile => {
            if ctx.spotify.is_authenticated().await {
                if ACCOUNT_REFRESHING.load(std::sync::atomic::Ordering::SeqCst) {
                    ACCOUNT_NUDGE.store(true, std::sync::atomic::Ordering::SeqCst);
                } else {
                    tokio::spawn(refresh_account(ctx.clone()));
                }
            }
        }

        GetAuthStatus => {
            let status = if ctx.spotify.is_authenticated().await {
                logged_in_status(&ctx).await
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
                    Ok(mut page) => {
                        // A playlist the list call reports with 0 songs keeps the count already
                        // known for it (read when its songs were last loaded).
                        let known = ctx_c.cache.get_playlists(500, 0).map(|(l, _)| l).unwrap_or_default();
                        for p in page.items.iter_mut().filter(|p| p.total_tracks == 0) {
                            if let Some(k) = known.iter().find(|k| k.id == p.id) {
                                p.total_tracks = k.total_tracks;
                            }
                        }
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

            // Read recently and fully stored: answer from the stored copy and stop there.
            if page_is_fresh(&ctx.cache, &id, offset_val, limit_val, cached_tracks.len()) {
                return Some(protocol::event(EventBody::PlaylistTracksResult {
                    playlist_id: id,
                    tracks: cached_tracks,
                    total: cached_total,
                    offset: offset_val,
                    is_cached: false,
                }));
            }

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
                        let _ = ctx_c.cache.set_playlist_tracks_page(&pid, &page.items, page.offset, page.total);
                        let _ = ctx_c.cache.set_playlist_total(&pid, page.total);
                        mark_synced(&ctx_c.cache, &pid, page.total);
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
            return None;
        }

        GetLikedTracks { limit, offset } => {
            let limit_val = limit.unwrap_or(50) as usize;
            let offset_val = offset.unwrap_or(0) as usize;
            let liked_id = crate::cache::Cache::LIKED_PLAYLIST_ID;

            let (cached_tracks, cached_total) = ctx
                .cache
                .get_liked_tracks(limit_val, offset_val)
                .unwrap_or_default();

            // Read recently and fully stored: answer from the stored copy and stop there.
            if page_is_fresh(&ctx.cache, liked_id, offset_val, limit_val, cached_tracks.len()) {
                return Some(protocol::event(EventBody::LikedTracksResult {
                    tracks: cached_tracks,
                    total: cached_total,
                    offset: offset_val,
                    is_cached: false,
                }));
            }

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
                        let _ = ctx_c.cache.set_liked_tracks_page(&page.items, page.offset, page.total);
                        mark_synced(&ctx_c.cache, crate::cache::Cache::LIKED_PLAYLIST_ID, page.total);
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
            return None;
        }

        GetSavedAlbums => {
            // Stale-while-revalidate: the saved copy goes out at once (so the
            // tab is not empty offline), then Spotify's answer replaces it.
            if let Some(albums) = kv_load::<Vec<halcyon_music_core::models::Album>>(&ctx.cache, KV_SAVED_ALBUMS) {
                let _ = ctx.events_tx.send(protocol::event(EventBody::SavedAlbumsResult { albums }));
            }
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.get_saved_albums(50, 0).await {
                    Ok(page) => {
                        kv_store(&ctx_c.cache, KV_SAVED_ALBUMS, &page.items);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::SavedAlbumsResult {
                            albums: page.items,
                        }));
                    }
                    Err(api::ApiError::AuthRequired(reason)) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::AuthRequired { reason }));
                    }
                    Err(e) => {
                        warn!("saved albums refresh failed ({e}); serving cache");
                    }
                }
            });
            return None;
        }

        GetFollowedArtists => {
            if let Some(artists) = kv_load::<Vec<halcyon_music_core::models::Artist>>(&ctx.cache, KV_FOLLOWED_ARTISTS) {
                let _ = ctx.events_tx.send(protocol::event(EventBody::FollowedArtistsResult { artists }));
            }
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.get_followed_artists(50).await {
                    Ok(artists) => {
                        kv_store(&ctx_c.cache, KV_FOLLOWED_ARTISTS, &artists);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::FollowedArtistsResult {
                            artists,
                        }));
                    }
                    Err(api::ApiError::AuthRequired(reason)) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::AuthRequired { reason }));
                    }
                    Err(e) => {
                        warn!("followed artists refresh failed ({e}); serving cache");
                    }
                }
            });
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

        GetHomeFeed => {
            // Show the last finished Home page at once, then rebuild it.
            let previous = kv_load::<halcyon_music_core::models::HomeFeed>(&ctx.cache, KV_HOME);
            if let Some(mut seed) = previous.clone() {
                crate::mixes::build::attach(&mut seed);
                // The words for these mixes (if the LLM layer is on) usually come from the cache
                // and are sent now, so a returning visit shows them with the page, not after it.
                crate::llm::spawn_enrichment(ctx.clone(), seed.made_for_you.clone());
                let _ = ctx.events_tx.send(protocol::event(EventBody::HomeFeedResult(Box::new(seed))));
            }
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                let built = crate::suggestions::build_home_feed(&ctx_c.spotify, &ctx_c.cache, &ctx_c.http).await;
                // A rebuild that came back thinner (Spotify rate limit, a feed that did not
                // answer) must not wipe what was already on the page.
                let feed = match previous {
                    Some(old) => merge_home_feed(old, built),
                    None => built,
                };
                let mut feed = feed;
                crate::mixes::build::attach(&mut feed);
                tokio::spawn(crate::mixes::build::refresh(ctx_c.clone(), Vec::new()));
                kv_store(&ctx_c.cache, KV_HOME, &feed);
                let _ = ctx_c.events_tx.send(protocol::event(EventBody::HomeFeedResult(Box::new(feed.clone()))));
                // Optional LLM layer: words for the mixes just built. Background, off by default,
                // never waited for; the page above is already on screen.
                crate::llm::spawn_enrichment(ctx_c.clone(), feed.made_for_you.clone());

                // The big lists (All-Time Best, Top 100, Top 200) hold hundreds of songs that
                // each need a Spotify match. Home shows what is matched already; the rest is
                // matched here in steps, and Home is sent again after each step that found
                // something new, so a list appears as soon as it has a few songs.
                if !HOME_WARMING.swap(true, std::sync::atomic::Ordering::SeqCst) {
                    let _guard = WarmGuard;
                    let mut current = feed;
                    // Spotify may pause lookups (rate limit). A round that gets stuck waits the
                    // pause out and tries again, so the lists keep filling up instead of
                    // stopping at the few songs that were already matched.
                    for round in 0..20 {
                        for step in 0..crate::suggestions::WARM_STEPS {
                            let did_work = crate::suggestions::warm_big_lists_step(
                                &ctx_c.spotify,
                                &ctx_c.cache,
                                &ctx_c.http,
                                step,
                            )
                            .await;
                            if !did_work {
                                continue;
                            }
                            let rebuilt =
                                crate::suggestions::build_home_feed(&ctx_c.spotify, &ctx_c.cache, &ctx_c.http).await;
                            current = merge_home_feed(current, rebuilt);
                            crate::mixes::build::attach(&mut current);
                            kv_store(&ctx_c.cache, KV_HOME, &current);
                            let _ = ctx_c
                                .events_tx
                                .send(protocol::event(EventBody::HomeFeedResult(Box::new(current.clone()))));
                        }
                        // Chart mixes that were matched in this round get their words too.
                        crate::llm::spawn_enrichment(ctx_c.clone(), current.made_for_you.clone());
                        if !crate::suggestions::big_lists_incomplete(&ctx_c.cache, &ctx_c.http).await {
                            break;
                        }
                        let wait = crate::suggestions::search_pause_remaining().clamp(45, 900);
                        tracing::info!("big lists not complete after round {round}; trying again in {wait}s");
                        tokio::time::sleep(std::time::Duration::from_secs(wait)).await;
                    }
                }
            });
            return None;
        }

        GetDiscover => {
            // Show the last finished page at once, then rebuild it.
            let mut seed = kv_load::<halcyon_music_core::models::DiscoverFeed>(&ctx.cache, KV_DISCOVER)
                .unwrap_or_default();
            seed.complete = false;
            if seed != halcyon_music_core::models::DiscoverFeed::default() {
                let _ = ctx.events_tx.send(protocol::event(EventBody::DiscoverResult(Box::new(seed.clone()))));
            }
            if DISCOVER_RUNNING.swap(true, std::sync::atomic::Ordering::SeqCst) {
                return None;
            }
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                let _guard = DiscoverGuard;
                let tx = ctx_c.events_tx.clone();
                let feed = crate::suggestions::build_discover_feed(
                    &ctx_c.spotify,
                    &ctx_c.cache,
                    &ctx_c.http,
                    seed,
                    move |f| {
                        let _ = tx.send(protocol::event(EventBody::DiscoverResult(Box::new(f.clone()))));
                    },
                )
                .await;
                kv_store(&ctx_c.cache, KV_DISCOVER, &feed);
            });
            return None;
        }

        GetSuggestions => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                let feed = crate::suggestions::build_home_feed(&ctx_c.spotify, &ctx_c.cache, &ctx_c.http).await;
                let _ = ctx_c.events_tx.send(protocol::event(EventBody::SuggestionsResult {
                    mixes: feed.made_for_you,
                }));
            });
            return None;
        }

        // Part 6: stored mixes at once; whatever is due is rebuilt in the background.
        GetMixes => {
            let store = crate::mixes::store::MixStore::load_or_default(&crate::mixes::store::default_path()).0;
            let _ = ctx.events_tx.send(protocol::event(crate::mixes::build::updated_event(&store)));
            tokio::spawn(crate::mixes::build::refresh(ctx.clone(), Vec::new()));
            return None;
        }
        RefreshMix { mix_id } => {
            tokio::spawn(crate::mixes::build::refresh(ctx.clone(), vec![mix_id]));
            return None;
        }
        MixFeedback { mix_id, track_id, action } => {
            tokio::spawn(crate::mixes::build::feedback(ctx.clone(), mix_id, track_id, action));
            return None;
        }
        StartRadio { track } => {
            tokio::spawn(crate::mixes::build::start_radio(ctx.clone(), track));
            return None;
        }
        StopRadio => {
            crate::mixes::build::stop_radio();
            return None;
        }
        SmartShuffle { name, tracks } => {
            tokio::spawn(crate::mixes::build::start_smart_shuffle(ctx.clone(), name, tracks));
            return None;
        }

        PlayMix { tracks, name: _ } => {
            if let Some(first) = tracks.first().cloned() {
                ctx.player
                    .mutate(|s| {
                        s.queue = tracks;
                        s.queue_pos = 0;
                        s.track = Some(first);
                        s.playing = true;
                        s.position_ms = 0;
                    })
                    .await;
            }
        }

        SaveMixAsPlaylist { name, track_uris } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                let user_id = ctx_c.spotify.current_user_id().await.unwrap_or_else(|| "me".to_string());
                match ctx_c.spotify.create_playlist(&user_id, &name, "Generated by Halcyon Music").await {
                    Ok(playlist) => {
                        let _ = ctx_c.spotify.add_tracks_to_playlist(&playlist.id, &track_uris).await;
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistCreated {
                            playlist_id: playlist.id,
                            name: playlist.name,
                        }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Failed to save playlist: {e}"),
                        }));
                    }
                }
            });
            return None;
        }

        CreatePlaylist { name, description } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                let user_id = ctx_c.spotify.current_user_id().await.unwrap_or_else(|| "me".to_string());
                let desc = description.unwrap_or_else(|| "Created with Halcyon Music".to_string());
                match ctx_c.spotify.create_playlist(&user_id, &name, &desc).await {
                    Ok(playlist) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistCreated {
                            playlist_id: playlist.id.clone(),
                            name: playlist.name,
                        }));
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistUpdated {
                            id: playlist.id,
                        }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Failed to create playlist: {e}"),
                        }));
                    }
                }
            });
            return None;
        }

        RenamePlaylist { id, new_name } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.rename_playlist(&id, &new_name).await {
                    Ok(()) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistUpdated {
                            id,
                        }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Failed to rename playlist: {e}"),
                        }));
                    }
                }
            });
            return None;
        }

        DeletePlaylist { id } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.delete_playlist(&id).await {
                    Ok(()) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistUpdated {
                            id,
                        }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Failed to delete playlist: {e}"),
                        }));
                    }
                }
            });
            return None;
        }

        AddTrackToPlaylist { playlist_id, track_uri } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.add_tracks_to_playlist(&playlist_id, &[track_uri]).await {
                    Ok(()) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistUpdated {
                            id: playlist_id,
                        }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Failed to add track to playlist: {e}"),
                        }));
                    }
                }
            });
            return None;
        }

        RemoveTrackFromPlaylist { playlist_id, track_uri } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.remove_track_from_playlist(&playlist_id, &track_uri).await {
                    Ok(()) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::PlaylistUpdated {
                            id: playlist_id,
                        }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Failed to remove track from playlist: {e}"),
                        }));
                    }
                }
            });
            return None;
        }

        GetCapsule { month_offset } => {
            match ctx.cache.get_full_capsule(month_offset) {
                Ok(capsule) => {
                    return Some(protocol::event(EventBody::CapsuleResult(Box::new(capsule))));
                }
                Err(e) => {
                    return Some(protocol::event(EventBody::Error {
                        message: format!("Failed to compute capsule: {e}"),
                    }));
                }
            }
        }

        GetAlbumDetail { id } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.get_album_detail(&id).await {
                    Ok((album, tracks)) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::AlbumDetailResult {
                            album,
                            tracks,
                        }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Failed to get album detail: {e}"),
                        }));
                    }
                }
            });
            return None;
        }

        GetArtistDetail { id } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match ctx_c.spotify.get_artist_detail(&id).await {
                    Ok((artist, top_tracks, albums)) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::ArtistDetailResult {
                            artist,
                            top_tracks,
                            albums,
                        }));
                    }
                    Err(e) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::Error {
                            message: format!("Failed to get artist detail: {e}"),
                        }));
                    }
                }
            });
            return None;
        }

        DetailedSearch { query, search_type, limit, offset } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                if !query.trim().is_empty() {
                    let _ = ctx_c.cache.add_recent_search(&query);
                }
                match ctx_c.spotify.search_detailed(&query, &search_type, limit, offset).await {
                    Ok(results) => {
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::DetailedSearchResults(
                            Box::new(results),
                        )));
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

        GetRecentSearches => {
            let searches = ctx.cache.get_recent_searches(15).unwrap_or_default();
            return Some(protocol::event(EventBody::RecentSearchesResult { searches }));
        }

        ClearRecentSearches => {
            let _ = ctx.cache.clear_recent_searches();
            return Some(protocol::event(EventBody::RecentSearchesResult { searches: Vec::new() }));
        }

        GetLyrics {
            track_id,
            artist,
            title,
            album,
            duration_ms,
        } => {
            // Check cache first
            if let Ok(Some(cached_entry)) = ctx.cache.get_lyrics(&track_id) {
                return Some(protocol::event(EventBody::LyricsResult {
                    track_id,
                    lyrics: cached_entry.map(Box::new),
                }));
            }

            // Not in cache, fetch in background
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match lyrics::fetch_lrclib(
                    &ctx_c.http,
                    &track_id,
                    &artist,
                    &title,
                    &album,
                    duration_ms,
                )
                .await
                {
                    Ok(Some(mut lrc)) => {
                        if let Ok(offset) = ctx_c.cache.get_lyric_offset(&track_id) {
                            lrc.offset_ms = offset;
                        }
                        let _ = ctx_c.cache.put_lyrics(&lrc);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::LyricsResult {
                            track_id,
                            lyrics: Some(Box::new(lrc)),
                        }));
                    }
                    Ok(None) => {
                        let _ = ctx_c.cache.put_lyrics_miss(&track_id);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::LyricsResult {
                            track_id,
                            lyrics: None,
                        }));
                    }
                    Err(e) => {
                        warn!("Failed to fetch lyrics for {artist} - {title}: {e}");
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::LyricsResult {
                            track_id,
                            lyrics: None,
                        }));
                    }
                }
            });
            return None;
        }

        SetLyricOffset { track_id, offset_ms } => {
            let _ = ctx.cache.set_lyric_offset(&track_id, offset_ms);
            if let Ok(Some(Some(mut lrc))) = ctx.cache.get_lyrics(&track_id) {
                lrc.offset_ms = offset_ms;
                let _ = ctx.events_tx.send(protocol::event(EventBody::LyricsResult {
                    track_id,
                    lyrics: Some(Box::new(lrc)),
                }));
            }
            return None;
        }

        LoadLocalLrc { track_id, lrc_content } => {
            let (lines, offset_ms) = lyrics::parse_lrc(&lrc_content);
            let synced = !lines.is_empty();
            let lyrics = Lyrics {
                track_id: track_id.clone(),
                synced,
                lines,
                offset_ms,
            };
            let _ = ctx.cache.put_lyrics(&lyrics);
            return Some(protocol::event(EventBody::LyricsResult {
                track_id,
                lyrics: Some(Box::new(lyrics)),
            }));
        }

        SearchLyricsAgain { track_id, artist, title } => {
            let ctx_c = ctx.clone();
            tokio::spawn(async move {
                match lyrics::fetch_lrclib(
                    &ctx_c.http,
                    &track_id,
                    &artist,
                    &title,
                    "",
                    0,
                )
                .await
                {
                    Ok(Some(mut lrc)) => {
                        if let Ok(offset) = ctx_c.cache.get_lyric_offset(&track_id) {
                            lrc.offset_ms = offset;
                        }
                        let _ = ctx_c.cache.put_lyrics(&lrc);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::LyricsResult {
                            track_id,
                            lyrics: Some(Box::new(lrc)),
                        }));
                    }
                    _ => {
                        let _ = ctx_c.cache.put_lyrics_miss(&track_id);
                        let _ = ctx_c.events_tx.send(protocol::event(EventBody::LyricsResult {
                            track_id,
                            lyrics: None,
                        }));
                    }
                }
            });
            return None;
        }

        GetArt { url, size } => {
            // Answered asynchronously on the event stream (ArtReady / ArtFailed).
            art::spawn_request(ctx.art.clone(), ctx.events_tx.clone(), url, size);
            return None;
        }

        // --- Optional LLM layer (off by default; nothing is sent anywhere until it is turned on) ---

        GetLlmStatus => {
            crate::llm::announce_status(ctx);
            return None;
        }

        SetLlmSettings { enabled, backend, model, endpoint } => {
            crate::llm::apply_settings(ctx, enabled, &backend, &model, &endpoint);
            return None;
        }

        TestLlmConnection => {
            let home = load_home_mixes(&ctx.cache);
            crate::llm::spawn_connection_test(ctx.clone(), home);
            return None;
        }

        // Built-in model files (Part 7).
        ListLlmModels => {
            crate::llm::models::announce_models(ctx);
            return None;
        }

        DownloadLlmModel { id } => {
            crate::llm::models::spawn_download(ctx.clone(), id);
            return None;
        }

        CancelLlmDownload => {
            crate::llm::models::cancel_download();
            return None;
        }

        DeleteLlmModel { id } => {
            crate::llm::models::delete_model(ctx, &id);
            crate::llm::announce_status(ctx);
            return None;
        }

        // Answered on the event stream: progress, then exactly one result or failure.
        PromptPlaylist { text } => {
            crate::llm::playlist::spawn_prompt_playlist(ctx.clone(), text);
            return None;
        }

        // Per connection, so `handle_client` takes it before it gets here.
        SetAudioStream { .. } => {}

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
            cache: cache.clone(),
            spotify,
            http: reqwest::Client::new(),
            art: ArtFetcher::new(cache),
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
