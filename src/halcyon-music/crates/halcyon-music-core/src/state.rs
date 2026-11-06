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

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Bitrate {
    Bitrate96,
    #[default]
    Bitrate160,
    Bitrate320,
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
    pub bitrate: Bitrate,
    pub normalisation: bool,
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
            bitrate: Bitrate::Bitrate160,
            normalisation: true,
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
        if self.queue.is_empty() {
            self.queue_pos = 0;
            self.track = None;
            self.playing = false;
            self.position_ms = 0;
        } else {
            if self.queue_pos >= self.queue.len() {
                self.queue_pos = self.queue.len().saturating_sub(1);
            }
            if self.track.is_none() {
                self.track = self.queue.get(self.queue_pos).cloned();
            }
            if let Some(t) = self.track.as_ref() {
                self.position_ms = self.position_ms.min(t.duration_ms);
            } else {
                self.position_ms = 0;
            }
        }
    }

    /// Play a single track immediately.
    pub fn play_track(&mut self, track: Track) {
        self.track = Some(track.clone());
        self.position_ms = 0;
        self.playing = true;
        // If track is already in queue at current pos, keep it, else set single-item queue or append
        if self.queue.is_empty() {
            self.queue.push(track);
            self.queue_pos = 0;
        } else if self.queue_pos < self.queue.len() && self.queue[self.queue_pos].id == track.id {
            // Already at position
        } else {
            self.queue.insert(self.queue_pos, track);
        }
    }

    /// Load a list of tracks (e.g. from an album or playlist) and start playing from `start_index`.
    pub fn play_context(&mut self, tracks: Vec<Track>, start_index: usize) {
        if tracks.is_empty() {
            self.queue.clear();
            self.queue_pos = 0;
            self.track = None;
            self.position_ms = 0;
            self.playing = false;
            return;
        }
        let pos = start_index.min(tracks.len().saturating_sub(1));
        self.queue = tracks;
        self.queue_pos = pos;
        self.track = self.queue.get(pos).cloned();
        self.position_ms = 0;
        self.playing = true;
    }

    /// Enqueue a track at the end of the queue.
    pub fn enqueue(&mut self, track: Track) {
        if self.queue.is_empty() {
            self.queue.push(track.clone());
            self.queue_pos = 0;
            self.track = Some(track);
        } else {
            self.queue.push(track);
        }
    }

    /// Play this track immediately after the current playing track.
    pub fn play_next(&mut self, track: Track) {
        if self.queue.is_empty() {
            self.queue.push(track.clone());
            self.queue_pos = 0;
            self.track = Some(track);
        } else {
            let next_pos = (self.queue_pos + 1).min(self.queue.len());
            self.queue.insert(next_pos, track);
        }
    }

    /// Remove a track from the queue by index.
    pub fn dequeue(&mut self, index: usize) -> Option<Track> {
        if index >= self.queue.len() {
            return None;
        }
        let removed = self.queue.remove(index);
        if self.queue.is_empty() {
            self.queue_pos = 0;
            self.track = None;
            self.position_ms = 0;
            self.playing = false;
        } else if index < self.queue_pos {
            self.queue_pos = self.queue_pos.saturating_sub(1);
        } else if index == self.queue_pos {
            if self.queue_pos >= self.queue.len() {
                self.queue_pos = self.queue.len().saturating_sub(1);
            }
            self.track = self.queue.get(self.queue_pos).cloned();
            self.position_ms = 0;
        }
        Some(removed)
    }

    /// Reorder a queue item from index `from` to index `to`.
    pub fn reorder(&mut self, from: usize, to: usize) -> bool {
        if from >= self.queue.len() || to >= self.queue.len() || from == to {
            return false;
        }
        let item = self.queue.remove(from);
        self.queue.insert(to, item);

        if self.queue_pos == from {
            self.queue_pos = to;
        } else if from < self.queue_pos && to >= self.queue_pos {
            self.queue_pos = self.queue_pos.saturating_sub(1);
        } else if from > self.queue_pos && to <= self.queue_pos {
            self.queue_pos = (self.queue_pos + 1).min(self.queue.len().saturating_sub(1));
        }
        true
    }

    /// Advance to the next track according to repeat mode. Returns true if a next track is playing.
    pub fn advance_next(&mut self) -> bool {
        if self.queue.is_empty() {
            self.track = None;
            self.position_ms = 0;
            self.playing = false;
            return false;
        }

        match self.repeat {
            RepeatMode::One => {
                self.position_ms = 0;
                true
            }
            RepeatMode::All => {
                self.queue_pos = (self.queue_pos + 1) % self.queue.len();
                self.track = self.queue.get(self.queue_pos).cloned();
                self.position_ms = 0;
                true
            }
            RepeatMode::Off => {
                if self.queue_pos + 1 < self.queue.len() {
                    self.queue_pos += 1;
                    self.track = self.queue.get(self.queue_pos).cloned();
                    self.position_ms = 0;
                    true
                } else {
                    self.position_ms = 0;
                    self.playing = false;
                    false
                }
            }
        }
    }

    /// Step to previous track, or restart current track if more than 3s in.
    pub fn advance_prev(&mut self) -> bool {
        if self.queue.is_empty() {
            self.track = None;
            self.position_ms = 0;
            self.playing = false;
            return false;
        }

        if self.position_ms > 3000 {
            self.position_ms = 0;
            return true;
        }

        if self.queue_pos > 0 {
            self.queue_pos -= 1;
            self.track = self.queue.get(self.queue_pos).cloned();
            self.position_ms = 0;
            true
        } else if self.repeat == RepeatMode::All {
            self.queue_pos = self.queue.len().saturating_sub(1);
            self.track = self.queue.get(self.queue_pos).cloned();
            self.position_ms = 0;
            true
        } else {
            self.position_ms = 0;
            false
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
            ..Default::default()
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

    #[test]
    fn queue_manipulation_operations() {
        let mut s = PlayerState::default();
        let t1 = track(10_000);
        let mut t2 = track(20_000);
        t2.id = "t2".into();
        let mut t3 = track(30_000);
        t3.id = "t3".into();

        // play_context
        s.play_context(vec![t1.clone(), t2.clone()], 0);
        assert_eq!(s.queue.len(), 2);
        assert_eq!(s.queue_pos, 0);
        assert_eq!(s.track.as_ref().map(|t| t.id.as_str()), Some("t1"));

        // play_next
        s.play_next(t3.clone());
        assert_eq!(s.queue.len(), 3);
        assert_eq!(s.queue.get(1).map(|t| t.id.as_str()), Some("t3"));

        // reorder
        assert!(s.reorder(1, 2));
        assert_eq!(s.queue.get(2).map(|t| t.id.as_str()), Some("t3"));

        // advance_next
        assert!(s.advance_next());
        assert_eq!(s.queue_pos, 1);
        assert_eq!(s.track.as_ref().map(|t| t.id.as_str()), Some("t2"));

        // dequeue
        let removed = s.dequeue(0);
        assert_eq!(removed.map(|t| t.id), Some("t1".into()));
        assert_eq!(s.queue_pos, 0); // was 1, shifted to 0
    }
}
