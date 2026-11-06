//! Shared view of "what is playing right now", persisted by the daemon and
//! rendered by the GUI.

pub use crate::models::Track;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RepeatMode {
    Off,
    All,
    One,
}

/// Everything needed to rebuild the session after a daemon restart.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlayerState {
    pub track: Option<Track>,
    pub position_ms: u64,
    pub queue: Vec<Track>,
    /// Index into `queue` of the current track. `queue_pos < queue.len()`
    /// whenever a track is loaded.
    pub queue_pos: usize,
    /// 0..=100
    pub volume: u8,
    pub shuffle: bool,
    pub repeat: RepeatMode,
    pub playing: bool,
}

impl Default for PlayerState {
    fn default() -> Self {
        Self {
            track: None,
            position_ms: 0,
            queue: Vec::new(),
            queue_pos: 0,
            volume: 50,
            shuffle: false,
            repeat: RepeatMode::Off,
            playing: false,
        }
    }
}

impl PlayerState {
    /// Current track as a reference, if any.
    pub fn current_track(&self) -> Option<&Track> {
        self.track.as_ref()
    }

    /// Clamp fields that could have been hand-edited or half-written into a
    /// sane range so a restored state can never panic the player.
    pub fn sanitize(&mut self) {
        self.volume = self.volume.min(100);
        if self.queue_pos >= self.queue.len() {
            self.queue_pos = self.queue.len().saturating_sub(1);
        }
        if let Some(t) = self.track.as_ref() {
            self.position_ms = self.position_ms.min(t.duration_ms);
        } else {
            self.playing = false;
            self.position_ms = 0;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(ms: u64) -> Track {
        Track {
            id: "t1".into(),
            title: "Song".into(),
            artist: "Artist".into(),
            artists: vec!["Artist".into()],
            album: "Album".into(),
            album_id: None,
            duration_ms: ms,
            art_url: None,
            uri: "spotify:track:t1".into(),
        }
    }

    #[test]
    fn sanitize_clamps_bad_values() {
        let mut s = PlayerState {
            track: Some(track(30_000)),
            position_ms: 99_000, // past the end
            queue: vec![track(30_000)],
            queue_pos: 17,       // out of range
            volume: 250,         // out of range
            shuffle: false,
            repeat: RepeatMode::Off,
            playing: true,
        };
        s.sanitize();
        assert_eq!(s.position_ms, 30_000);
        assert_eq!(s.queue_pos, 0);
        assert_eq!(s.volume, 100);
    }

    #[test]
    fn sanitize_stops_playback_without_track() {
        let mut s = PlayerState { playing: true, position_ms: 5000, ..Default::default() };
        s.sanitize();
        assert!(!s.playing);
        assert_eq!(s.position_ms, 0);
    }
}
