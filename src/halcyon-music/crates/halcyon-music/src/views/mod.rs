pub mod capsule;
pub mod detail;
pub mod diagnostics;
pub mod fullscreen;
pub mod help_modal;
pub mod home;
pub mod library;
pub mod lyrics;
pub mod now_playing_bar;
pub mod queue_drawer;
pub mod recent;
pub mod search;
pub mod sidebar;

use crate::theme::HalcyonPalette;
use iced::widget::button;

/// Filled accent button for the few plain text actions (log in, go back...).
pub fn solid(
    palette: HalcyonPalette,
) -> impl Fn(&iced::Theme, button::Status) -> button::Style + Copy {
    move |_theme, status| {
        let base = palette.accent;
        let bg = match status {
            button::Status::Hovered | button::Status::Pressed => iced::Color {
                a: 0.85,
                ..base
            },
            button::Status::Disabled => iced::Color { a: 0.35, ..base },
            button::Status::Active => base,
        };
        button::Style {
            background: Some(bg.into()),
            text_color: palette.background,
            border: iced::Border {
                radius: 8.0.into(),
                ..Default::default()
            },
            ..Default::default()
        }
    }
}

/// Transparent icon button that lights up on hover (header controls).
pub fn ghost(
    palette: HalcyonPalette,
) -> impl Fn(&iced::Theme, button::Status) -> button::Style + Copy {
    move |_theme, status| button::Style {
        background: Some(
            match status {
                button::Status::Hovered => palette.surface_variant,
                button::Status::Pressed => iced::Color { a: 0.5, ..palette.accent },
                _ => iced::Color::TRANSPARENT,
            }
            .into(),
        ),
        text_color: palette.text_muted,
        border: iced::Border {
            radius: 8.0.into(),
            ..Default::default()
        },
        ..Default::default()
    }
}

/// Shorten `s` to at most `max` characters, ending in "…" when it was cut.
/// iced 0.13 has no text ellipsis, so long titles are cut here instead of
/// spilling out of their card.
pub fn ellipsize(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let keep = max.saturating_sub(1);
    let mut out: String = s.chars().take(keep).collect();
    while out.ends_with(' ') {
        out.pop();
    }
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::ellipsize;

    #[test]
    fn short_text_is_untouched() {
        assert_eq!(ellipsize("Arcane", 10), "Arcane");
    }

    #[test]
    fn long_text_is_cut_with_an_ellipsis() {
        let out = ellipsize("ALL Arcane Songs in ACTUAL order - Season 1&2", 17);
        assert_eq!(out.chars().count(), 17);
        assert!(out.ends_with('…'));
    }

    #[test]
    fn multibyte_text_does_not_panic() {
        assert_eq!(ellipsize("日本語のタイトルです", 4), "日本語…");
    }
}
