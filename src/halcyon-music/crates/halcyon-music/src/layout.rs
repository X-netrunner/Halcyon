//! How the window is arranged (layout), which full-screen visualizer is shown, and whether the
//! small visualizer sits in the player.
//!
//! These three settings are remembered the same way as the colour mood (`theme::Mood`): one small
//! text file each in `~/.local/state/halcyon-music/`. A missing, empty or unknown value gives the
//! default. Reading never writes, and a failed save is ignored.

use std::path::{Path, PathBuf};

/// The layout used when nothing is saved. One constant so it can be flipped after checking on a
/// screen. Part A keeps it at Classic on purpose.
pub const LAYOUT_DEFAULT: LayoutKind = LayoutKind::Classic;
/// The full-screen visualizer used when nothing is saved.
pub const VISUALIZER_DEFAULT: VisualizerKind = VisualizerKind::Aurora;
/// The small player visualizer is off unless the person turns it on.
pub const MINI_VISUALIZER_DEFAULT: MiniVisualizer = MiniVisualizer::Off;

const LAYOUT_FILE: &str = "layout";
const VISUALIZER_FILE: &str = "visualizer";
const MINI_VISUALIZER_FILE: &str = "mini-visualizer";

/// `~/.local/state/halcyon-music`, the same folder the mood is kept in.
pub fn state_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    Path::new(&home).join(".local/state/halcyon-music")
}

fn read_in(dir: &Path, name: &str) -> Option<String> {
    std::fs::read_to_string(dir.join(name)).ok()
}

fn write_in(dir: &Path, name: &str, value: &str) {
    let _ = std::fs::create_dir_all(dir);
    let _ = std::fs::write(dir.join(name), value);
}

/// How the same pieces (title bar, navigation, page, queue, player) are arranged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayoutKind {
    /// Today's arrangement: sidebar rail, page, queue column, full-width player bar.
    Classic,
    TopTabs,
    Dock,
    PlayerPanel,
    LibraryList,
}

impl LayoutKind {
    /// Every layout, in the order Settings lists them and `next()` walks them.
    pub const ALL: [LayoutKind; 5] = [
        LayoutKind::Classic,
        LayoutKind::TopTabs,
        LayoutKind::Dock,
        LayoutKind::PlayerPanel,
        LayoutKind::LibraryList,
    ];

    pub fn key(&self) -> &'static str {
        match self {
            LayoutKind::Classic => "classic",
            LayoutKind::TopTabs => "top-tabs",
            LayoutKind::Dock => "dock",
            LayoutKind::PlayerPanel => "player-panel",
            LayoutKind::LibraryList => "library-list",
        }
    }

    pub fn from_key(key: &str) -> Option<LayoutKind> {
        match key.trim() {
            "classic" => Some(LayoutKind::Classic),
            "top-tabs" => Some(LayoutKind::TopTabs),
            "dock" => Some(LayoutKind::Dock),
            "player-panel" => Some(LayoutKind::PlayerPanel),
            "library-list" => Some(LayoutKind::LibraryList),
            _ => None,
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            LayoutKind::Classic => "Classic",
            LayoutKind::TopTabs => "Top tabs",
            LayoutKind::Dock => "Dock",
            LayoutKind::PlayerPanel => "Player panel",
            LayoutKind::LibraryList => "Library list",
        }
    }

    /// The layout after this one, wrapping round (the `CycleLayout` shortcut).
    pub fn next(&self) -> LayoutKind {
        match self {
            LayoutKind::Classic => LayoutKind::TopTabs,
            LayoutKind::TopTabs => LayoutKind::Dock,
            LayoutKind::Dock => LayoutKind::PlayerPanel,
            LayoutKind::PlayerPanel => LayoutKind::LibraryList,
            LayoutKind::LibraryList => LayoutKind::Classic,
        }
    }

    /// Whether the window is really drawn in this layout yet. Until a layout has its own
    /// arrangement in `views::frame`, it is drawn like Classic.
    pub fn is_drawn(&self) -> bool {
        matches!(
            self,
            LayoutKind::Classic
                | LayoutKind::TopTabs
                | LayoutKind::Dock
                | LayoutKind::PlayerPanel
                | LayoutKind::LibraryList
        )
    }

    pub fn load_from(dir: &Path) -> LayoutKind {
        read_in(dir, LAYOUT_FILE)
            .and_then(|k| LayoutKind::from_key(&k))
            .unwrap_or(LAYOUT_DEFAULT)
    }

    pub fn save_to(&self, dir: &Path) {
        write_in(dir, LAYOUT_FILE, self.key());
    }

    pub fn load() -> LayoutKind {
        Self::load_from(&state_dir())
    }

    /// Remember the layout for next launch. Failure is harmless, so it is ignored.
    pub fn save(&self) {
        self.save_to(&state_dir());
    }
}

/// What the full-screen Now Playing page draws behind the lyrics.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VisualizerKind {
    Aurora,
    Silk,
    /// Song and lyrics only.
    None,
}

impl VisualizerKind {
    pub const ALL: [VisualizerKind; 3] = [VisualizerKind::Aurora, VisualizerKind::Silk, VisualizerKind::None];

    pub fn key(&self) -> &'static str {
        match self {
            VisualizerKind::Aurora => "aurora",
            VisualizerKind::Silk => "silk",
            VisualizerKind::None => "none",
        }
    }

    pub fn from_key(key: &str) -> Option<VisualizerKind> {
        match key.trim() {
            "aurora" => Some(VisualizerKind::Aurora),
            "silk" => Some(VisualizerKind::Silk),
            "none" => Some(VisualizerKind::None),
            _ => None,
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            VisualizerKind::Aurora => "Aurora",
            VisualizerKind::Silk => "Silk",
            VisualizerKind::None => "Off",
        }
    }

    #[allow(dead_code)]
    pub fn next(&self) -> VisualizerKind {
        match self {
            VisualizerKind::Aurora => VisualizerKind::Silk,
            VisualizerKind::Silk => VisualizerKind::None,
            VisualizerKind::None => VisualizerKind::Aurora,
        }
    }

    pub fn load_from(dir: &Path) -> VisualizerKind {
        read_in(dir, VISUALIZER_FILE)
            .and_then(|k| VisualizerKind::from_key(&k))
            .unwrap_or(VISUALIZER_DEFAULT)
    }

    pub fn save_to(&self, dir: &Path) {
        write_in(dir, VISUALIZER_FILE, self.key());
    }

    pub fn load() -> VisualizerKind {
        Self::load_from(&state_dir())
    }

    pub fn save(&self) {
        self.save_to(&state_dir());
    }
}

/// The small, quiet row of bars in the player area (layouts 1 to 4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MiniVisualizer {
    On,
    Off,
}

impl MiniVisualizer {
    pub fn key(&self) -> &'static str {
        match self {
            MiniVisualizer::On => "on",
            MiniVisualizer::Off => "off",
        }
    }

    pub fn from_key(key: &str) -> Option<MiniVisualizer> {
        match key.trim() {
            "on" => Some(MiniVisualizer::On),
            "off" => Some(MiniVisualizer::Off),
            _ => None,
        }
    }

    pub fn from_bool(on: bool) -> MiniVisualizer {
        if on {
            MiniVisualizer::On
        } else {
            MiniVisualizer::Off
        }
    }

    pub fn is_on(&self) -> bool {
        matches!(self, MiniVisualizer::On)
    }

    pub fn load_from(dir: &Path) -> MiniVisualizer {
        read_in(dir, MINI_VISUALIZER_FILE)
            .and_then(|k| MiniVisualizer::from_key(&k))
            .unwrap_or(MINI_VISUALIZER_DEFAULT)
    }

    pub fn save_to(&self, dir: &Path) {
        write_in(dir, MINI_VISUALIZER_FILE, self.key());
    }

    pub fn load() -> MiniVisualizer {
        Self::load_from(&state_dir())
    }

    pub fn save(&self) {
        self.save_to(&state_dir());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fresh empty folder under the system temp dir, never the real home.
    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("halcyon-music-layout-test-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn layout_keys_round_trip() {
        for l in LayoutKind::ALL {
            assert_eq!(LayoutKind::from_key(l.key()), Some(l));
        }
        assert_eq!(LayoutKind::from_key(" dock\n"), Some(LayoutKind::Dock));
        assert_eq!(LayoutKind::from_key("nope"), None);
        assert_eq!(LayoutKind::from_key(""), None);
    }

    #[test]
    fn layout_next_visits_every_value_once_then_wraps() {
        let mut seen = vec![LayoutKind::Classic];
        let mut cur = LayoutKind::Classic.next();
        while cur != LayoutKind::Classic {
            assert!(!seen.contains(&cur), "{cur:?} came round twice");
            seen.push(cur);
            cur = cur.next();
        }
        assert_eq!(seen.len(), LayoutKind::ALL.len());
        for l in LayoutKind::ALL {
            assert!(seen.contains(&l));
        }
    }

    #[test]
    fn visualizer_keys_round_trip_and_next_cycles() {
        for v in VisualizerKind::ALL {
            assert_eq!(VisualizerKind::from_key(v.key()), Some(v));
        }
        assert_eq!(VisualizerKind::from_key("bars"), None);
        let mut seen = vec![VisualizerKind::Aurora];
        let mut cur = VisualizerKind::Aurora.next();
        while cur != VisualizerKind::Aurora {
            assert!(!seen.contains(&cur));
            seen.push(cur);
            cur = cur.next();
        }
        assert_eq!(seen.len(), VisualizerKind::ALL.len());
    }

    #[test]
    fn mini_visualizer_keys_round_trip() {
        assert_eq!(MiniVisualizer::from_key("on"), Some(MiniVisualizer::On));
        assert_eq!(MiniVisualizer::from_key("off"), Some(MiniVisualizer::Off));
        assert_eq!(MiniVisualizer::from_key("maybe"), None);
        assert_eq!(MiniVisualizer::from_bool(true), MiniVisualizer::On);
        assert_eq!(MiniVisualizer::from_bool(false), MiniVisualizer::Off);
        assert!(MiniVisualizer::On.is_on());
        assert!(!MiniVisualizer::Off.is_on());
    }

    #[test]
    fn missing_empty_or_unknown_files_give_the_defaults() {
        let dir = temp_dir("defaults");
        assert_eq!(LayoutKind::load_from(&dir), LAYOUT_DEFAULT);
        assert_eq!(VisualizerKind::load_from(&dir), VISUALIZER_DEFAULT);
        assert_eq!(MiniVisualizer::load_from(&dir), MINI_VISUALIZER_DEFAULT);

        std::fs::write(dir.join(LAYOUT_FILE), "").unwrap();
        std::fs::write(dir.join(VISUALIZER_FILE), "sparkles").unwrap();
        std::fs::write(dir.join(MINI_VISUALIZER_FILE), "\n").unwrap();
        assert_eq!(LayoutKind::load_from(&dir), LAYOUT_DEFAULT);
        assert_eq!(VisualizerKind::load_from(&dir), VISUALIZER_DEFAULT);
        assert_eq!(MiniVisualizer::load_from(&dir), MINI_VISUALIZER_DEFAULT);

        // Reading did not overwrite what was there.
        assert_eq!(std::fs::read_to_string(dir.join(VISUALIZER_FILE)).unwrap(), "sparkles");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_defaults_are_the_named_constants() {
        assert_eq!(LAYOUT_DEFAULT, LayoutKind::Classic);
        assert_eq!(VISUALIZER_DEFAULT, VisualizerKind::Aurora);
        assert_eq!(MINI_VISUALIZER_DEFAULT, MiniVisualizer::Off);
    }

    #[test]
    fn saving_then_loading_returns_the_same_value() {
        let dir = temp_dir("roundtrip");
        for l in LayoutKind::ALL {
            l.save_to(&dir);
            assert_eq!(LayoutKind::load_from(&dir), l);
        }
        for v in VisualizerKind::ALL {
            v.save_to(&dir);
            assert_eq!(VisualizerKind::load_from(&dir), v);
        }
        for m in [MiniVisualizer::On, MiniVisualizer::Off] {
            m.save_to(&dir);
            assert_eq!(MiniVisualizer::load_from(&dir), m);
        }
        // The files hold the plain keys the plan names.
        LayoutKind::PlayerPanel.save_to(&dir);
        assert_eq!(std::fs::read_to_string(dir.join("layout")).unwrap(), "player-panel");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn every_layout_is_drawn_now() {
        for l in LayoutKind::ALL {
            assert!(l.is_drawn(), "{l:?}");
        }
    }
}
