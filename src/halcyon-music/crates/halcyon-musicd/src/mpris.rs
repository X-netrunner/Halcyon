//! MPRIS 2 D-Bus interface for Halcyon Music (`org.mpris.MediaPlayer2.halcyon`).
//!
//! Complies with the FreeDesktop MPRIS 2 specification:
//! - `org.mpris.MediaPlayer2`
//! - `org.mpris.MediaPlayer2.Player`
//!
//! Provides metadata, local cached cover URL (`file://`), position, seek,
//! volume, transport controls, and integrates with Quickshell island & media keys.

use crate::cache::Cache;
use crate::daemon::Player;
use halcyon_music_core::protocol;
use halcyon_music_core::RepeatMode;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::broadcast;
use tracing::info;
use zbus::zvariant::{ObjectPath, Value};
use zbus::{connection::Builder, interface};

pub const MPRIS_BUS_NAME: &str = "org.mpris.MediaPlayer2.halcyon";
pub const MPRIS_OBJECT_PATH: &str = "/org/mpris/MediaPlayer2";

pub struct MprisRoot;

#[interface(name = "org.mpris.MediaPlayer2")]
impl MprisRoot {
    async fn raise(&self) {
        let _ = tokio::process::Command::new("hyprctl")
            .args(["dispatch", "focuswindow", "halcyon-music"])
            .output()
            .await;
    }

    async fn quit(&self) {}

    #[zbus(property)]
    fn can_quit(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_raise(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn has_track_list(&self) -> bool {
        false
    }

    #[zbus(property)]
    fn identity(&self) -> &str {
        "Halcyon Music"
    }

    #[zbus(property)]
    fn supported_uri_schemes(&self) -> Vec<String> {
        vec!["spotify".into()]
    }

    #[zbus(property)]
    fn supported_mime_types(&self) -> Vec<String> {
        vec!["audio/mpeg".into(), "audio/ogg".into(), "audio/flac".into()]
    }
}

pub struct MprisPlayer {
    player: Arc<Player>,
    cache: Cache,
    events_tx: broadcast::Sender<protocol::Event>,
}

impl MprisPlayer {
    pub fn new(
        player: Arc<Player>,
        cache: Cache,
        events_tx: broadcast::Sender<protocol::Event>,
    ) -> Self {
        Self {
            player,
            cache,
            events_tx,
        }
    }

    async fn broadcast_state(&self) {
        let snap = self.player.snapshot().await;
        let _ = self.events_tx.send(protocol::event(protocol::EventBody::State {
            state: snap,
        }));
    }
}

#[interface(name = "org.mpris.MediaPlayer2.Player")]
impl MprisPlayer {
    async fn next(&self) {
        self.player
            .mutate(|s| {
                let _ = s.advance_next();
            })
            .await;
        self.broadcast_state().await;
    }

    async fn previous(&self) {
        self.player
            .mutate(|s| {
                let _ = s.advance_prev();
            })
            .await;
        self.broadcast_state().await;
    }

    async fn pause(&self) {
        self.player
            .mutate(|s| {
                s.playing = false;
            })
            .await;
        self.broadcast_state().await;
    }

    async fn play_pause(&self) {
        self.player
            .mutate(|s| {
                if s.track.is_some() || !s.queue.is_empty() {
                    s.playing = !s.playing;
                }
            })
            .await;
        self.broadcast_state().await;
    }

    async fn stop(&self) {
        self.player
            .mutate(|s| {
                s.playing = false;
                s.position_ms = 0;
            })
            .await;
        self.broadcast_state().await;
    }

    async fn play(&self) {
        self.player
            .mutate(|s| {
                if s.track.is_some() || !s.queue.is_empty() {
                    s.playing = true;
                }
            })
            .await;
        self.broadcast_state().await;
    }

    async fn seek(&self, offset_us: i64) {
        let delta_ms = offset_us / 1000;
        self.player
            .mutate(|s| {
                if let Some(t) = s.track.as_ref() {
                    let cur = s.position_ms as i64;
                    let target = (cur + delta_ms).clamp(0, t.duration_ms as i64) as u64;
                    s.position_ms = target;
                }
            })
            .await;
        self.broadcast_state().await;
    }

    async fn set_position(
        &self,
        _track_id: ObjectPath<'_>,
        position_us: i64,
    ) {
        let pos_ms = (position_us.max(0) / 1000) as u64;
        self.player
            .mutate(|s| {
                if let Some(t) = s.track.as_ref() {
                    s.position_ms = pos_ms.min(t.duration_ms);
                }
            })
            .await;
        self.broadcast_state().await;
    }

    async fn open_uri(&self, uri: String) {
        if uri.starts_with("spotify:track:") {
            let id = uri.trim_start_matches("spotify:track:").to_string();
            if let Ok(Some(t)) = self.cache.get_track(&id) {
                self.player
                    .mutate(|s| {
                        s.play_track(t);
                    })
                    .await;
                self.broadcast_state().await;
            }
        }
    }

    #[zbus(property)]
    async fn playback_status(&self) -> String {
        let s = self.player.snapshot().await;
        if s.playing {
            "Playing".to_string()
        } else if s.track.is_some() {
            "Paused".to_string()
        } else {
            "Stopped".to_string()
        }
    }

    #[zbus(property)]
    async fn loop_status(&self) -> String {
        let s = self.player.snapshot().await;
        match s.repeat {
            RepeatMode::Off => "None".to_string(),
            RepeatMode::One => "Track".to_string(),
            RepeatMode::All => "Playlist".to_string(),
        }
    }

    #[zbus(property)]
    async fn set_loop_status(&self, status: String) {
        let mode = match status.as_str() {
            "Track" => RepeatMode::One,
            "Playlist" => RepeatMode::All,
            _ => RepeatMode::Off,
        };
        self.player
            .mutate(|s| {
                s.repeat = mode;
            })
            .await;
        self.broadcast_state().await;
    }

    #[zbus(property)]
    fn rate(&self) -> f64 {
        1.0
    }

    #[zbus(property)]
    async fn shuffle(&self) -> bool {
        self.player.snapshot().await.shuffle
    }

    #[zbus(property)]
    async fn set_shuffle(&self, shuffle: bool) {
        self.player
            .mutate(|s| {
                s.shuffle = shuffle;
            })
            .await;
        self.broadcast_state().await;
    }

    #[zbus(property)]
    async fn metadata(&self) -> HashMap<String, Value<'_>> {
        let s = self.player.snapshot().await;
        let mut map = HashMap::new();

        if let Some(t) = s.track.as_ref() {
            let track_id_path = format!(
                "/org/mpris/MediaPlayer2/track/{}",
                t.id.replace(|c: char| !c.is_alphanumeric(), "_")
            );
            if let Ok(path) = ObjectPath::try_from(track_id_path) {
                map.insert("mpris:trackid".into(), Value::from(path));
            }

            // Duration in microseconds
            let length_us = (t.duration_ms as i64) * 1000;
            map.insert("mpris:length".into(), Value::from(length_us));

            map.insert("xesam:title".into(), Value::from(t.title.clone()));
            map.insert("xesam:album".into(), Value::from(t.album.clone()));
            map.insert(
                "xesam:artist".into(),
                Value::from(vec![t.artist.clone()]),
            );
            map.insert("xesam:url".into(), Value::from(t.uri.clone()));

            // Art URL: check cached local image file first (for instantaneous offline display)
            if let Some(url) = t.art_url.as_ref() {
                if let Ok(Some(cached_path)) = self.cache.get_image(url) {
                    let local_file_url = format!("file://{}", cached_path.display());
                    map.insert("mpris:artUrl".into(), Value::from(local_file_url));
                } else {
                    map.insert("mpris:artUrl".into(), Value::from(url.clone()));
                }
            }
        }

        map
    }

    #[zbus(property)]
    async fn volume(&self) -> f64 {
        let s = self.player.snapshot().await;
        (s.volume as f64) / 100.0
    }

    #[zbus(property)]
    async fn set_volume(&self, vol: f64) {
        let clamped = (vol.clamp(0.0, 1.0) * 100.0).round() as u8;
        self.player
            .mutate(|s| {
                s.volume = clamped;
            })
            .await;
        self.broadcast_state().await;
    }

    #[zbus(property)]
    async fn position(&self) -> i64 {
        let s = self.player.snapshot().await;
        (s.position_ms as i64) * 1000
    }

    #[zbus(property)]
    fn can_go_next(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_go_previous(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_play(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_pause(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_seek(&self) -> bool {
        true
    }

    #[zbus(property)]
    fn can_control(&self) -> bool {
        true
    }
}

/// Spawns the MPRIS D-Bus service on the user session bus.
pub async fn start_mpris_server(
    player: Arc<Player>,
    cache: Cache,
    events_tx: broadcast::Sender<protocol::Event>,
) -> anyhow::Result<zbus::Connection> {
    let mpris_player = MprisPlayer::new(player, cache, events_tx);
    let root = MprisRoot;

    let conn = Builder::session()?
        .name(MPRIS_BUS_NAME)?
        .serve_at(MPRIS_OBJECT_PATH, root)?
        .serve_at(MPRIS_OBJECT_PATH, mpris_player)?
        .build()
        .await?;

    info!(bus = MPRIS_BUS_NAME, path = MPRIS_OBJECT_PATH, "MPRIS 2 service registered");
    Ok(conn)
}
