pub mod capsule;
pub mod detail;
pub mod account;
pub mod diagnostics;
pub mod fullscreen;
pub mod help_modal;
pub mod home;
pub mod library;
pub mod lyrics;
pub mod now_playing_bar;
pub mod playlist;
pub mod queue_drawer;
pub mod recent;
pub mod search;
pub mod search_dropdown;
pub mod settings;
pub mod sidebar;
pub mod track_menu;
pub mod titlebar;

use crate::theme::{self, HalcyonPalette};
use iced::widget::{button, container, slider};

/// Filled accent button for the few plain text actions (log in, go back...).
/// A soft peach-to-rose gradient pill that glows a little when hovered.
pub fn solid(
    palette: HalcyonPalette,
) -> impl Fn(&iced::Theme, button::Status) -> button::Style + Copy {
    move |_theme, status| {
        let background = match status {
            button::Status::Disabled => iced::Background::Color(theme::alpha(palette.accent, 0.35)),
            _ => palette.accent_background(),
        };
        let shadow = match status {
            button::Status::Hovered => palette.glow_shadow(0.45, 22.0),
            button::Status::Pressed => palette.glow_shadow(0.25, 10.0),
            _ => palette.glow_shadow(0.22, 14.0),
        };
        button::Style {
            background: Some(background),
            text_color: palette.on_accent(),
            border: iced::Border {
                radius: theme::radius::PILL.into(),
                ..Default::default()
            },
            shadow,
            ..Default::default()
        }
    }
}

/// Transparent icon button that lights up softly on hover (header controls).
pub fn ghost(
    palette: HalcyonPalette,
) -> impl Fn(&iced::Theme, button::Status) -> button::Style + Copy {
    move |_theme, status| button::Style {
        background: Some(
            match status {
                button::Status::Hovered => theme::alpha(palette.accent, 0.14),
                button::Status::Pressed => theme::alpha(palette.accent, 0.26),
                _ => iced::Color::TRANSPARENT,
            }
            .into(),
        ),
        text_color: if status == button::Status::Hovered {
            palette.text
        } else {
            palette.text_muted
        },
        border: iced::Border {
            radius: theme::radius::MD.into(),
            ..Default::default()
        },
        ..Default::default()
    }
}

/// A calm raised card: faint glow at the top, hairline border, soft shadow.
pub fn card(
    palette: HalcyonPalette,
) -> impl Fn(&iced::Theme) -> container::Style + Copy {
    move |_theme| container::Style {
        background: Some(palette.card_background()),
        border: iced::Border {
            color: palette.soft_border(),
            width: 1.0,
            radius: theme::radius::LG.into(),
        },
        shadow: iced::Shadow {
            color: theme::alpha(iced::Color::BLACK, if palette.is_light() { 0.08 } else { 0.28 }),
            offset: iced::Vector::new(0.0, 8.0),
            blur_radius: 24.0,
        },
        ..Default::default()
    }
}

/// A small rounded tag (for "Live Suggestions" and similar).
pub fn chip(
    palette: HalcyonPalette,
) -> impl Fn(&iced::Theme) -> container::Style + Copy {
    move |_theme| container::Style {
        background: Some(theme::alpha(palette.accent, 0.14).into()),
        border: iced::Border {
            color: theme::alpha(palette.accent, 0.30),
            width: 1.0,
            radius: theme::radius::PILL.into(),
        },
        ..Default::default()
    }
}

/// Style for a tile button (album, playlist, row) that brightens softly under the pointer.
pub fn tile(
    palette: HalcyonPalette,
    corner: f32,
) -> impl Fn(&iced::Theme, button::Status) -> button::Style + Copy {
    move |_theme, status| {
        let hovered = matches!(status, button::Status::Hovered | button::Status::Pressed);
        button::Style {
            background: Some(if hovered {
                iced::Background::from(theme::mix(palette.surface, palette.accent, 0.12))
            } else {
                iced::Background::from(theme::alpha(palette.surface, 0.55))
            }),
            text_color: palette.text,
            border: iced::Border {
                color: if hovered {
                    theme::alpha(palette.accent, 0.35)
                } else {
                    iced::Color::TRANSPARENT
                },
                width: 1.0,
                radius: corner.into(),
            },
            shadow: if hovered {
                palette.glow_shadow(0.16, 18.0)
            } else {
                iced::Shadow::default()
            },
            ..Default::default()
        }
    }
}

/// Slim glowing slider (seek bar and volume): accent up to the handle, a faint track after,
/// and a handle that only grows when it is hovered or dragged.
pub fn slider_style(
    palette: HalcyonPalette,
) -> impl Fn(&iced::Theme, slider::Status) -> slider::Style + Copy {
    move |_theme, status| {
        let handle_radius = match status {
            slider::Status::Active => 5.0,
            slider::Status::Hovered => 7.0,
            slider::Status::Dragged => 8.0,
        };
        slider::Style {
            rail: slider::Rail {
                backgrounds: (
                    palette.accent_background(),
                    iced::Background::Color(theme::alpha(palette.text_muted, 0.28)),
                ),
                width: 4.0,
                border: iced::Border {
                    radius: theme::radius::PILL.into(),
                    ..Default::default()
                },
            },
            handle: slider::Handle {
                shape: slider::HandleShape::Circle { radius: handle_radius },
                background: iced::Background::Color(palette.accent),
                border_width: if status == slider::Status::Active { 0.0 } else { 3.0 },
                border_color: theme::alpha(palette.glow, 0.35),
            },
        }
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
