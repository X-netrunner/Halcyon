//! Typed domain models shared between daemon and GUI.

use serde::{Deserialize, Serialize};

/// Extended track model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Track {
    pub id: String,
    pub title: String,
    pub artist: String,
    #[serde(default)]
    pub artists: Vec<String>,
    pub album: String,
    #[serde(default)]
    pub album_id: Option<String>,
    pub duration_ms: u64,
    pub art_url: Option<String>,
    #[serde(default)]
    pub uri: String,
}

impl Track {
    pub fn simple(id: String, title: String, artist: String, album: String, duration_ms: u64) -> Self {
        let uri = format!("spotify:track:{id}");
        Self {
            id,
            title,
            artist: artist.clone(),
            artists: vec![artist],
            album,
            album_id: None,
            duration_ms,
            art_url: None,
            uri,
        }
    }
}

/// Spotify album model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub art_url: Option<String>,
    #[serde(default)]
    pub release_date: Option<String>,
    #[serde(default)]
    pub total_tracks: u32,
    #[serde(default)]
    pub uri: String,
}

/// Spotify artist model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub image_url: Option<String>,
    #[serde(default)]
    pub genres: Vec<String>,
    #[serde(default)]
    pub uri: String,
}

/// Spotify playlist model.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub owner: String,
    #[serde(default)]
    pub snapshot_id: Option<String>,
    pub art_url: Option<String>,
    #[serde(default)]
    pub total_tracks: u32,
    #[serde(default)]
    pub uri: String,
}

/// Spotify Connect playback device.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub device_type: String,
    pub is_active: bool,
    pub volume_percent: Option<u32>,
}

/// Generic page container.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Page<T> {
    pub items: Vec<T>,
    pub total: usize,
    pub limit: usize,
    pub offset: usize,
    pub next: Option<String>,
    pub previous: Option<String>,
}

impl<T> Page<T> {
    pub fn empty(limit: usize, offset: usize) -> Self {
        Self {
            items: Vec::new(),
            total: 0,
            limit,
            offset,
            next: None,
            previous: None,
        }
    }
}

/// User authentication status.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum AuthStatus {
    LoggedOut,
    LoggingIn { auth_url: String },
    LoggedIn {
        user_id: Option<String>,
        display_name: Option<String>,
    },
    Error { message: String },
}

/// Probe status of an API endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ProbeStatus {
    Available,
    Unavailable { code: u16 },
    Unknown,
}

/// Status record for a probed Spotify endpoint.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EndpointProbe {
    pub endpoint: String,
    pub status: ProbeStatus,
    pub checked_at: u64,
    pub detail: Option<String>,
}
