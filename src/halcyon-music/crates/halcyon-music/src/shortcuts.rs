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
    NavigatePage(usize), // 1..=6
    BackOrClose,       // Esc
    PlaySelected,      // Enter
    PlayNextSelected,  // Shift+Enter
    EnqueueSelected,   // Ctrl+Enter
    ToggleFullscreen,  // F
    Refresh,           // Ctrl+R
    ToggleHelp,        // ?
    OffsetLyricsMinus, // [
    OffsetLyricsPlus,  // ]
}

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
                if modifiers.control() {
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
}


