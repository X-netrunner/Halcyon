//! Which picture the account circle shows.
//!
//! Three sources, chosen in Settings > Account: the Halcyon avatar (the same file `hal avatar`
//! prints, see `halcyon_music_core::paths`), the Spotify picture, or just the initial. The chosen
//! source goes first and the other one is the fallback, so the circle is never empty: the last
//! fallback is always the initial, which `views::account::avatar` draws when no picture is ready.
//!
//! Local files live in the cover store under a `file://` key, so they are decoded off the UI
//! thread and masked to a circle the same way as the Spotify picture.

use std::path::{Path, PathBuf};
use std::time::SystemTime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AvatarSource {
    /// The rice's own picture (`~/.face`, `~/.config/Halcyon/avatar.*`, ...). The default.
    #[default]
    Halcyon,
    Spotify,
    Initial,
}

impl AvatarSource {
    pub const ALL: [AvatarSource; 3] = [AvatarSource::Halcyon, AvatarSource::Spotify, AvatarSource::Initial];

    pub fn key(self) -> &'static str {
        match self {
            AvatarSource::Halcyon => "halcyon",
            AvatarSource::Spotify => "spotify",
            AvatarSource::Initial => "initial",
        }
    }

    pub fn from_key(key: &str) -> Option<Self> {
        match key.trim() {
            "halcyon" => Some(AvatarSource::Halcyon),
            "spotify" => Some(AvatarSource::Spotify),
            "initial" => Some(AvatarSource::Initial),
            _ => None,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            AvatarSource::Halcyon => "Halcyon avatar",
            AvatarSource::Spotify => "Spotify picture",
            AvatarSource::Initial => "Initial",
        }
    }

    /// One short line for the Settings tile.
    pub fn detail(self) -> &'static str {
        match self {
            AvatarSource::Halcyon => "The picture from your Halcyon setup.",
            AvatarSource::Spotify => "Your Spotify profile picture.",
            AvatarSource::Initial => "Just the first letter of your name.",
        }
    }

    fn file() -> PathBuf {
        halcyon_music_core::paths::state_dir().join("avatar-source")
    }

    /// The choice saved last time; Halcyon's avatar when nothing (or something unreadable) is saved.
    pub fn load() -> Self {
        std::fs::read_to_string(Self::file())
            .ok()
            .and_then(|k| Self::from_key(&k))
            .unwrap_or_default()
    }

    /// Remember the choice for next launch. Failure is harmless, so it is ignored.
    pub fn save(self) {
        let path = Self::file();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(path, self.key());
    }
}

/// The key a local picture has in the cover store.
pub fn local_url(path: &Path) -> String {
    format!("file://{}", path.display())
}

/// True for a key made by [`local_url`] (the daemon must never be asked to fetch these).
pub fn is_local_url(url: &str) -> bool {
    url.starts_with("file://")
}

/// When the file last changed; a newer stamp means the picture was replaced.
pub fn stamp(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

/// The pictures to try, best first: the chosen source, then the other. `Initial` means none.
pub fn order(source: AvatarSource, halcyon: Option<&str>, spotify: Option<&str>) -> Vec<String> {
    let (first, second) = match source {
        AvatarSource::Halcyon => (halcyon, spotify),
        AvatarSource::Spotify => (spotify, halcyon),
        AvatarSource::Initial => return Vec::new(),
    };
    [first, second]
        .into_iter()
        .flatten()
        .filter(|u| !u.is_empty())
        .map(str::to_string)
        .collect()
}

/// The first picture that is ready to draw; when none is ready yet, the first one (it is on its
/// way, and the initial shows until then). `None` when there is nothing to try.
pub fn pick(candidates: &[String], ready: impl Fn(&str) -> bool) -> Option<String> {
    candidates
        .iter()
        .find(|u| ready(u.as_str()))
        .or_else(|| candidates.first())
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_round_trip_and_junk_is_ignored() {
        for s in AvatarSource::ALL {
            assert_eq!(AvatarSource::from_key(s.key()), Some(s));
        }
        assert_eq!(AvatarSource::from_key(" spotify\n"), Some(AvatarSource::Spotify));
        assert_eq!(AvatarSource::from_key("nonsense"), None);
        assert_eq!(AvatarSource::default(), AvatarSource::Halcyon);
    }

    #[test]
    fn the_chosen_source_goes_first_and_the_other_is_the_fallback() {
        let h = Some("file:///h.png");
        let s = Some("https://i.scdn.co/image/x");
        assert_eq!(order(AvatarSource::Halcyon, h, s), vec!["file:///h.png", "https://i.scdn.co/image/x"]);
        assert_eq!(order(AvatarSource::Spotify, h, s), vec!["https://i.scdn.co/image/x", "file:///h.png"]);
        assert!(order(AvatarSource::Initial, h, s).is_empty());
        // A missing or empty source is skipped.
        assert_eq!(order(AvatarSource::Halcyon, None, s), vec!["https://i.scdn.co/image/x"]);
        assert_eq!(order(AvatarSource::Spotify, h, Some("")), vec!["file:///h.png"]);
        assert!(order(AvatarSource::Halcyon, None, None).is_empty());
    }

    #[test]
    fn pick_prefers_a_ready_picture_but_never_returns_nothing_when_there_is_one() {
        let c = vec!["a".to_string(), "b".to_string()];
        assert_eq!(pick(&c, |u| u == "b").as_deref(), Some("b"), "first ready wins");
        assert_eq!(pick(&c, |_| true).as_deref(), Some("a"));
        assert_eq!(pick(&c, |_| false).as_deref(), Some("a"), "none ready yet: the first is on its way");
        assert_eq!(pick(&[], |_| true), None);
    }

    #[test]
    fn local_keys_are_recognised() {
        let url = local_url(Path::new("/home/ada/.face"));
        assert_eq!(url, "file:///home/ada/.face");
        assert!(is_local_url(&url));
        assert!(!is_local_url("https://i.scdn.co/image/x"));
    }
}
