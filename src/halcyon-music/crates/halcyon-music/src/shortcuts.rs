//! Global keyboard shortcut handler.
//!
//! Maps key combinations to application actions per Part 4 specification.

use iced::keyboard::key::Named;
use iced::keyboard::{Key, Modifiers};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShortcutAction {
    PlayPause,
    Next,
    Previous,
    SeekBackShort,     // Left: 5s
    SeekForwardShort,  // Right: 5s
    SeekBackLong,      // Shift+Left: 30s
    SeekForwardLong,   // Shift+Right: 30s
    VolumeUp,          // Up
    VolumeDown,        // Down
    ToggleMute,        // M
    ToggleShuffle,     // S
    CycleRepeat,       // R
    ToggleLike,        // L
    OpenSearch,        // / or Ctrl+K
    ToggleLyrics,      // Ctrl+L
    ToggleQueue,       // Q
    NavigatePage(usize), // 1..=6 (the sidebar rows, in order)
    BackOrClose,       // Esc
    PlaySelected,      // Enter
    PlayNextSelected,  // Shift+Enter
    EnqueueSelected,   // Ctrl+Enter
    ToggleFullscreen,  // F
    Refresh,           // Ctrl+R
    ToggleHelp,        // ?
    CycleLayout,       // Ctrl+Shift+L
    OffsetLyricsMinus, // [
    OffsetLyricsPlus,  // ]
}

/// What the Settings page lists. One place, so the list cannot drift from `match_shortcut`.
pub const SHORTCUT_HELP: &[(&str, &str)] = &[
    ("Space", "Play / pause"),
    ("Left / Right", "Seek 5 seconds back / forward"),
    ("Shift + Left / Right", "Seek 30 seconds"),
    ("Up / Down", "Volume up / down"),
    ("N / P", "Next / previous song"),
    ("Ctrl + K  or  /", "Focus the search box"),
    ("Esc", "Clear search; close menus and panels"),
    ("Ctrl + L", "Lyrics for the current song"),
    ("Ctrl + Shift + L", "Next layout"),
    ("Q", "Queue"),
    ("F", "Full-screen now playing"),
    ("M", "Mute"),
    ("S / R", "Shuffle / repeat"),
    ("L", "Like the current song"),
    ("Ctrl + R", "Refresh"),
    ("[ / ]", "Lyrics timing −100 ms / +100 ms"),
    ("?", "Shortcut cheat sheet"),
];

/// Match a keyboard key and active modifiers to a shortcut action.
pub fn match_shortcut(key: &Key, modifiers: Modifiers) -> Option<ShortcutAction> {
    match key {
        Key::Named(Named::Space) => Some(ShortcutAction::PlayPause),
        Key::Named(Named::ArrowLeft) => {
            if modifiers.shift() {
                Some(ShortcutAction::SeekBackLong)
            } else {
                Some(ShortcutAction::SeekBackShort)
            }
        }
        Key::Named(Named::ArrowRight) => {
            if modifiers.shift() {
                Some(ShortcutAction::SeekForwardLong)
            } else {
                Some(ShortcutAction::SeekForwardShort)
            }
        }
        Key::Named(Named::ArrowUp) => Some(ShortcutAction::VolumeUp),
        Key::Named(Named::ArrowDown) => Some(ShortcutAction::VolumeDown),
        Key::Named(Named::Escape) => Some(ShortcutAction::BackOrClose),
        Key::Named(Named::Enter) => {
            if modifiers.shift() {
                Some(ShortcutAction::PlayNextSelected)
            } else if modifiers.control() {
                Some(ShortcutAction::EnqueueSelected)
            } else {
                Some(ShortcutAction::PlaySelected)
            }
        }
        Key::Character(c) => match c.as_str() {
            "n" | "N" => Some(ShortcutAction::Next),
            "p" | "P" => Some(ShortcutAction::Previous),
            "m" | "M" => Some(ShortcutAction::ToggleMute),
            "s" | "S" => Some(ShortcutAction::ToggleShuffle),
            "r" | "R" => {
                if modifiers.control() {
                    Some(ShortcutAction::Refresh)
                } else {
                    Some(ShortcutAction::CycleRepeat)
                }
            }
            "l" | "L" => {
                if modifiers.control() && modifiers.shift() {
                    Some(ShortcutAction::CycleLayout)
                } else if modifiers.control() {
                    Some(ShortcutAction::ToggleLyrics)
                } else {
                    Some(ShortcutAction::ToggleLike)
                }
            }
            "k" | "K" if modifiers.control() => Some(ShortcutAction::OpenSearch),
            "/" => Some(ShortcutAction::OpenSearch),
            "q" | "Q" => Some(ShortcutAction::ToggleQueue),
            "f" | "F" => Some(ShortcutAction::ToggleFullscreen),
            "?" => Some(ShortcutAction::ToggleHelp),
            "[" => Some(ShortcutAction::OffsetLyricsMinus),
            "]" => Some(ShortcutAction::OffsetLyricsPlus),
            "1" => Some(ShortcutAction::NavigatePage(0)),
            "2" => Some(ShortcutAction::NavigatePage(1)),
            "3" => Some(ShortcutAction::NavigatePage(2)),
            "4" => Some(ShortcutAction::NavigatePage(3)),
            "5" => Some(ShortcutAction::NavigatePage(4)),
            "6" => Some(ShortcutAction::NavigatePage(5)),
            _ => None,
        },
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use iced::keyboard::key::Named;

    #[test]
    fn test_shortcuts_match() {
        let no_mods = Modifiers::empty();
        assert_eq!(
            match_shortcut(&Key::Named(Named::Space), no_mods),
            Some(ShortcutAction::PlayPause)
        );
        assert_eq!(
            match_shortcut(&Key::Character("n".into()), no_mods),
            Some(ShortcutAction::Next)
        );
        assert_eq!(
            match_shortcut(&Key::Character("p".into()), no_mods),
            Some(ShortcutAction::Previous)
        );
        assert_eq!(
            match_shortcut(&Key::Character("f".into()), no_mods),
            Some(ShortcutAction::ToggleFullscreen)
        );
        assert_eq!(
            match_shortcut(&Key::Character("?".into()), no_mods),
            Some(ShortcutAction::ToggleHelp)
        );
        assert_eq!(
            match_shortcut(&Key::Character("1".into()), no_mods),
            Some(ShortcutAction::NavigatePage(0))
        );
    }

    #[test]
    fn search_shortcuts_are_slash_and_ctrl_k() {
        assert_eq!(match_shortcut(&Key::Character("/".into()), Modifiers::empty()), Some(ShortcutAction::OpenSearch));
        assert_eq!(match_shortcut(&Key::Character("k".into()), Modifiers::CTRL), Some(ShortcutAction::OpenSearch));
        assert_eq!(match_shortcut(&Key::Character("k".into()), Modifiers::empty()), None);
    }

    #[test]
    fn ctrl_shift_l_cycles_the_layout_and_ctrl_l_still_opens_lyrics() {
        let l = Key::Character("L".into());
        assert_eq!(match_shortcut(&l, Modifiers::CTRL | Modifiers::SHIFT), Some(ShortcutAction::CycleLayout));
        let l = Key::Character("l".into());
        assert_eq!(match_shortcut(&l, Modifiers::CTRL), Some(ShortcutAction::ToggleLyrics));
        assert_eq!(match_shortcut(&l, Modifiers::empty()), Some(ShortcutAction::ToggleLike));
        assert!(super::SHORTCUT_HELP.iter().any(|(k, _)| k.contains("Ctrl + Shift + L")));
    }

    #[test]
    fn arrows_seek_and_escape_closes() {
        let none = Modifiers::empty();
        assert_eq!(match_shortcut(&Key::Named(Named::ArrowRight), none), Some(ShortcutAction::SeekForwardShort));
        assert_eq!(match_shortcut(&Key::Named(Named::ArrowLeft), none), Some(ShortcutAction::SeekBackShort));
        assert_eq!(match_shortcut(&Key::Named(Named::Escape), none), Some(ShortcutAction::BackOrClose));
    }
}


