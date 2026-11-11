//! State persistence: atomic writes, corruption recovery.
//!
//! Rules from Part 0: files are written atomically (temp → fsync → rename).
//! A corrupt state file is moved aside and rebuilt, never fatal.

use halcyon_music_core::PlayerState;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use thiserror::Error;
use tracing::{info, warn};

#[derive(Debug, Error)]
pub enum StateError {
    #[error("could not create state directory: {0}")]
    CreateDir(std::io::Error),
    #[error("could not write state: {0}")]
    Write(std::io::Error),
}

/// Outcome of a load: the state plus whether we had to recover.
#[derive(Debug)]
pub struct LoadedState {
    pub state: PlayerState,
    /// True when the previous file was corrupt and has been moved aside.
    pub recovered: bool,
    /// Human-readable note for logs/toasts.
    pub note: Option<String>,
}

/// Save `state` to `path` atomically: write `path.tmp`, fsync, rename.
pub fn save(path: &Path, state: &PlayerState) -> Result<(), StateError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(StateError::CreateDir)?;
    }
    let json = serde_json::to_vec_pretty(state)
        .map_err(|e| StateError::Write(std::io::Error::new(std::io::ErrorKind::InvalidData, e)))?;

    let tmp = temp_path_for(path);
    {
        let mut f = std::fs::File::create(&tmp).map_err(StateError::Write)?;
        f.write_all(&json).map_err(StateError::Write)?;
        f.sync_all().map_err(StateError::Write)?;
    }
    // fsync the directory so the rename itself is durable.
    std::fs::rename(&tmp, path).map_err(StateError::Write)?;
    if let Some(parent) = path.parent() {
        if let Ok(dir) = std::fs::File::open(parent) {
            let _ = dir.sync_all();
        }
    }
    Ok(())
}

fn temp_path_for(path: &Path) -> PathBuf {
    let mut name = path
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_default();
    name.push(".tmp");
    path.with_file_name(name)
}

/// Load state from `path`. A missing file yields defaults. A corrupt file is
/// renamed to `<name>.corrupt-<unix-ts>` and defaults are returned.
pub fn load(path: &Path) -> LoadedState {
    match std::fs::File::open(path) {
        Ok(mut f) => {
            let mut buf = Vec::new();
            match f.read_to_end(&mut buf) {
                Ok(_) => match serde_json::from_slice::<PlayerState>(&buf) {
                    Ok(mut state) => {
                        state.sanitize();
                        LoadedState {
                            state,
                            recovered: false,
                            note: None,
                        }
                    }
                    Err(e) => recover_corrupt(path, format!("invalid JSON: {e}")),
                },
                Err(e) => recover_corrupt(path, format!("unreadable: {e}")),
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            info!(path = %path.display(), "no saved state yet; starting fresh");
            LoadedState {
                state: PlayerState::default(),
                recovered: false,
                note: None,
            }
        }
        Err(e) => recover_corrupt(path, format!("cannot open: {e}")),
    }
}

fn recover_corrupt(path: &Path, why: String) -> LoadedState {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let aside = path.with_extension(format!("corrupt-{ts}"));
    let moved = std::fs::rename(path, &aside).is_ok();
    warn!(
        path = %path.display(),
        aside = %aside.display(),
        moved,
        "state file was corrupt ({why}); moved aside and rebuilt from defaults"
    );
    LoadedState {
        state: PlayerState::default(),
        recovered: true,
        note: Some(if moved {
            format!("Saved state was damaged ({why}); it was set aside and Halcyon started fresh.")
        } else {
            format!("Saved state was damaged ({why}); Halcyon started fresh.")
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use halcyon_music_core::{RepeatMode, Track};

    fn sample_state() -> PlayerState {
        PlayerState {
            track: Some(Track {
                id: "spotify:track:abc".into(),
                title: "Northern Attic".into(),
                artist: "Kyoto Weather".into(),
                artists: vec!["Kyoto Weather".into()],
                album: "Halcyon Days".into(),
                album_id: None,
                duration_ms: 214_000,
                art_url: Some("https://i.scdn.co/image/x".into()),
                uri: "spotify:track:abc".into(),
            }),
            position_ms: 61_000,
            queue: vec![
                Track::simple("q1".into(), "One".into(), "A".into(), "B".into(), 180_000),
                Track::simple("q2".into(), "Two".into(), "A".into(), "B".into(), 200_000),
            ],
            queue_pos: 1,
            volume: 80,
            shuffle: true,
            repeat: RepeatMode::All,
            playing: true,
            ..Default::default()
        }
    }

    #[test]
    fn save_then_load_round_trip() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("player-state.json");
        let original = sample_state();
        save(&path, &original).expect("save");
        let loaded = load(&path);
        assert!(!loaded.recovered);
        assert_eq!(loaded.state, original);
    }

    #[test]
    fn corrupt_file_is_moved_aside_and_rebuilt() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("player-state.json");
        std::fs::write(&path, b"{ not json !!!").expect("write garbage");
        let loaded = load(&path);
        assert!(loaded.recovered);
        assert!(loaded.note.is_some());
        assert_eq!(loaded.state, PlayerState::default());
        // The corrupt file must no longer exist at the original path, and a
        // moved-aside copy must exist next to it.
        assert!(!path.exists());
        let mut found_corrupt_copy = false;
        for entry in std::fs::read_dir(dir.path()).expect("read dir") {
            let name = entry.expect("entry").file_name();
            if name.to_string_lossy().contains("corrupt-") {
                found_corrupt_copy = true;
            }
        }
        assert!(found_corrupt_copy);
        // And after recovery a fresh save works.
        save(&path, &PlayerState::default()).expect("re-save");
        assert!(load(&path).state == PlayerState::default());
    }

    #[test]
    fn missing_file_yields_defaults_without_recovery_flag() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("nope.json");
        let loaded = load(&path);
        assert!(!loaded.recovered);
        assert_eq!(loaded.state, PlayerState::default());
    }

    #[test]
    fn truncated_json_recovers() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("player-state.json");
        let good = serde_json::to_vec_pretty(&sample_state()).expect("encode");
        let cut = &good[..good.len().saturating_sub(10)]; // chop the tail off
        std::fs::write(&path, cut).expect("write truncated");
        let loaded = load(&path);
        assert!(loaded.recovered);
    }

    #[test]
    fn out_of_range_values_are_sanitized_on_load() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("player-state.json");
        let mut s = sample_state();
        s.volume = 240;
        s.queue_pos = 42;
        save(&path, &s).expect("save");
        let loaded = load(&path);
        assert_eq!(loaded.state.volume, 100);
        assert!(loaded.state.queue_pos < loaded.state.queue.len());
    }
}
