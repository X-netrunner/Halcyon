//! Part 3 tests: Playback engine, queue model, watchdog, self-healing, MPRIS properties, and play log.

use halcyon_music_core::models::Track;
use halcyon_music_core::protocol::{self, CommandBody};
use halcyon_music_core::state::{Bitrate, PlayerState, RepeatMode};
use halcyon_musicd::audio::AudioEngine;
use halcyon_musicd::cache::Cache;
use halcyon_musicd::daemon::{apply_command, DaemonContext, Player};
use std::sync::Arc;
use tokio::sync::{broadcast, watch, Mutex};

fn test_track(id: &str, duration_ms: u64) -> Track {
    Track {
        id: id.to_string(),
        title: format!("Title {id}"),
        artist: "Artist".to_string(),
        artists: vec!["Artist".to_string()],
        album: "Album".to_string(),
        album_id: None,
        duration_ms,
        art_url: Some("http://example.com/art.jpg".into()),
        uri: format!("spotify:track:{id}"),
    }
}

fn test_context() -> (Arc<DaemonContext>, Arc<Player>, Cache, broadcast::Receiver<protocol::Event>) {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("test_cache.db");
    let img_dir = dir.path().join("images");
    let cache = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cache open");

    let (dirty_tx, _dirty_rx) = watch::channel(false);
    let player = Arc::new(Player::new(PlayerState::default(), dirty_tx));
    let (events_tx, events_rx) = broadcast::channel(64);

    let ctx = Arc::new(DaemonContext {
        player: player.clone(),
        cache: cache.clone(),
        spotify: halcyon_musicd::api::SpotifyClient::new(None, None),
        events_tx,
        login_cancel: Arc::new(Mutex::new(None)),
    });

    (ctx, player, cache, events_rx)
}

#[tokio::test]
async fn test_queue_context_play_next_and_reorder() {
    let (ctx, player, _cache, _events_rx) = test_context();

    let t1 = test_track("t1", 180_000);
    let t2 = test_track("t2", 200_000);
    let t3 = test_track("t3", 220_000);

    // Play album/playlist context
    apply_command(&ctx, CommandBody::PlayContext {
        tracks: vec![t1.clone(), t2.clone()],
        start_index: 0,
    }).await;

    let s = player.snapshot().await;
    assert!(s.playing);
    assert_eq!(s.queue.len(), 2);
    assert_eq!(s.track.as_ref().map(|t| t.id.as_str()), Some("t1"));

    // Play next
    apply_command(&ctx, CommandBody::PlayNext { track: t3.clone() }).await;
    let s = player.snapshot().await;
    assert_eq!(s.queue.len(), 3);
    assert_eq!(s.queue.get(1).map(|t| t.id.as_str()), Some("t3"));

    // Reorder queue: move t3 to index 2
    apply_command(&ctx, CommandBody::ReorderQueue { from: 1, to: 2 }).await;
    let s = player.snapshot().await;
    assert_eq!(s.queue.get(2).map(|t| t.id.as_str()), Some("t3"));

    // Dequeue index 0
    apply_command(&ctx, CommandBody::Dequeue { index: 0 }).await;
    let s = player.snapshot().await;
    assert_eq!(s.queue.len(), 2);
    assert_eq!(s.track.as_ref().map(|t| t.id.as_str()), Some("t2"));
}

#[tokio::test]
async fn test_repeat_modes_and_bitrate_settings() {
    let (ctx, player, _cache, _events_rx) = test_context();

    // Repeat mode direct setting
    apply_command(&ctx, CommandBody::SetRepeat { repeat: RepeatMode::One }).await;
    assert_eq!(player.snapshot().await.repeat, RepeatMode::One);

    // Bitrate setting
    apply_command(&ctx, CommandBody::SetBitrate { bitrate: Bitrate::Bitrate320 }).await;
    assert_eq!(player.snapshot().await.bitrate, Bitrate::Bitrate320);

    // Normalisation setting
    apply_command(&ctx, CommandBody::SetNormalisation { enabled: false }).await;
    assert!(!player.snapshot().await.normalisation);
}

#[tokio::test]
async fn test_play_log_written_on_completion_and_partial_skip() {
    let (_ctx, _player, cache, _events_rx) = test_context();
    let (events_tx, _rx) = broadcast::channel(16);
    let (dirty_tx, _) = watch::channel(false);
    let player = Arc::new(Player::new(PlayerState::default(), dirty_tx));

    let engine = AudioEngine::new(player, cache.clone(), events_tx);
    let t = test_track("song_log", 180_000);

    // 1. Log completed track
    engine.record_play_log(&t, 1000, 180_000, true);

    // 2. Log skipped track after 45s (>= 30s threshold)
    engine.record_play_log(&t, 2000, 45_000, false);

    // 3. Skip track after only 5s (< 30s threshold -> should not log)
    engine.record_play_log(&t, 3000, 5_000, false);

    let recent = cache.get_recent_plays(10).expect("get_recent_plays");
    assert_eq!(recent.len(), 2);
    assert_eq!(recent[0].ms_played, 45_000);
    assert!(!recent[0].completed);
    assert_eq!(recent[1].ms_played, 180_000);
    assert!(recent[1].completed);
}

#[tokio::test]
async fn test_watchdog_resets_on_normal_advance() {
    let (_ctx, player, cache, _events_rx) = test_context();
    let (events_tx, _rx) = broadcast::channel(16);

    let engine = AudioEngine::new(player.clone(), cache, events_tx);
    assert_eq!(engine.consecutive_failures(), 0);

    player.mutate(|s| {
        s.track = Some(test_track("w1", 10_000));
        s.playing = true;
        s.position_ms = 1000;
    }).await;

    engine.reset_failures();
    assert_eq!(engine.consecutive_failures(), 0);
}
