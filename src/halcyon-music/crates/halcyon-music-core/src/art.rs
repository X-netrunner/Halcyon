//! Cover-art sizes and URL helpers shared by the daemon and the GUI.
//!
//! Spotify serves every cover in three sizes (640, 300 and 64 px). The API
//! hands us the 640 px one, so rows would download ten times more data than
//! they need. [`ArtSize::candidates`] derives the smaller variants from the
//! URL; if a derived URL does not exist the fetcher falls back to the original,
//! so an unknown host or a changed URL scheme only costs bandwidth, never a
//! missing cover.

use serde::{Deserialize, Serialize};

/// How big a cover the caller wants. Pick the smallest that still looks sharp.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtSize {
    /// ~64 px: list rows, quick picks, the now-playing bar.
    Small,
    /// ~300 px: cards, grids, detail headers.
    Medium,
    /// ~640 px: full-screen now playing, MPRIS, notifications.
    Large,
}

/// Spotify image-id prefixes, (640 px, 300 px, 64 px).
const SPOTIFY_ALBUM_PREFIXES: (&str, &str, &str) =
    ("ab67616d0000b273", "ab67616d00001e02", "ab67616d00004851");

impl ArtSize {
    pub const ALL: [ArtSize; 3] = [ArtSize::Small, ArtSize::Medium, ArtSize::Large];

    /// Nominal edge length in pixels.
    pub fn px(self) -> u32 {
        match self {
            ArtSize::Small => 64,
            ArtSize::Medium => 300,
            ArtSize::Large => 640,
        }
    }

    /// URLs to try, best first. Always ends with the original URL.
    pub fn candidates(self, url: &str) -> Vec<String> {
        let (large, medium, small) = SPOTIFY_ALBUM_PREFIXES;
        let wanted = match self {
            ArtSize::Small => small,
            ArtSize::Medium => medium,
            ArtSize::Large => large,
        };
        let mut out = Vec::with_capacity(2);
        if url.contains("i.scdn.co/image/") {
            for prefix in [large, medium, small] {
                if prefix != wanted && url.contains(prefix) {
                    out.push(url.replacen(prefix, wanted, 1));
                    break;
                }
            }
        }
        out.push(url.to_string());
        out
    }
}

/// Key under which a (url, size) pair is stored in the on-disk image cache.
pub fn cache_key(url: &str, size: ArtSize) -> String {
    format!("{url}#{}", size.px())
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALBUM_640: &str = "https://i.scdn.co/image/ab67616d0000b2731234abcd";

    #[test]
    fn small_and_medium_variants_are_derived() {
        assert_eq!(
            ArtSize::Small.candidates(ALBUM_640),
            vec![
                "https://i.scdn.co/image/ab67616d000048511234abcd".to_string(),
                ALBUM_640.to_string()
            ]
        );
        assert_eq!(
            ArtSize::Medium.candidates(ALBUM_640)[0],
            "https://i.scdn.co/image/ab67616d00001e021234abcd"
        );
    }

    #[test]
    fn large_keeps_the_original_only() {
        assert_eq!(ArtSize::Large.candidates(ALBUM_640), vec![ALBUM_640.to_string()]);
    }

    #[test]
    fn unknown_hosts_are_left_alone() {
        let u = "https://cdn-images.dzcdn.net/images/cover/abc/500x500.jpg";
        for s in ArtSize::ALL {
            assert_eq!(s.candidates(u), vec![u.to_string()]);
        }
    }

    #[test]
    fn cache_keys_differ_per_size() {
        assert_ne!(cache_key("u", ArtSize::Small), cache_key("u", ArtSize::Large));
    }
}
