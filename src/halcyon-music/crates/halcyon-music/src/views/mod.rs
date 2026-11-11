pub mod account;
pub mod capsule;
pub mod connect_settings;
pub mod crossfade;
pub mod detail;
pub mod diagnostics;
pub mod discover;
pub mod dock;
pub mod frame;
pub mod fullscreen;
pub mod help_modal;
pub mod home;
pub mod library;
pub mod library_sidebar;
pub mod llm_settings;
pub mod lyrics;
pub mod lyrics_compact;
pub mod notch;
pub mod now_playing_bar;
pub mod orbit;
pub mod player_panel;
pub mod playlist;
pub mod prompt_card;
pub mod queue_column;
pub mod queue_drawer;
pub mod recent;
pub mod search;
pub mod search_dropdown;
pub mod settings;
pub mod side_panel;
pub mod sidebar;
pub mod slide;
pub mod tabs;
pub mod titlebar;
pub mod track_menu;
pub mod up_next;
pub mod viz_canvas;

use crate::icons::{icon, Icon};
use crate::theme::{self, HalcyonPalette};
use iced::widget::{button, column, container, slider, text, tooltip, Space};
use iced::{Alignment, Element};

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
            // A softly rounded rectangle, not a capsule: it sits calmer next to the cards.
            border: iced::Border {
                radius: theme::radius::MD.into(),
                color: theme::alpha(palette.on_accent(), 0.10),
                width: 1.0,
            },
            shadow,
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
pub fn card(palette: HalcyonPalette) -> impl Fn(&iced::Theme) -> container::Style + Copy {
    move |_theme| container::Style {
        background: Some(palette.card_background()),
        border: iced::Border {
            color: palette.soft_border(),
            width: 1.0,
            radius: theme::radius::LG.into(),
        },
        shadow: iced::Shadow {
            color: theme::alpha(
                iced::Color::BLACK,
                if palette.is_light() { 0.08 } else { 0.28 },
            ),
            offset: iced::Vector::new(0.0, 8.0),
            blur_radius: 24.0,
        },
        ..Default::default()
    }
}

/// A small rounded tag (for "Live Suggestions" and similar).
pub fn chip(palette: HalcyonPalette) -> impl Fn(&iced::Theme) -> container::Style + Copy {
    move |_theme| container::Style {
        background: Some(theme::alpha(palette.accent, 0.14).into()),
        border: iced::Border {
            color: theme::alpha(palette.accent, 0.30),
            width: 1.0,
            radius: 14.0.into(),
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
        }
    }
}

/// The Liked Songs "cover": a soft accent gradient square with a heart.
pub fn liked_cover<'a, M: 'a>(
    px: f32,
    corner: f32,
    palette: HalcyonPalette,
) -> iced::Element<'a, M> {
    container(crate::icons::icon(
        crate::icons::Icon::Heart,
        px * 0.42,
        palette.on_accent(),
    ))
    .width(px)
    .height(px)
    .center_x(px)
    .center_y(px)
    .style(move |_t| container::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: corner.into(),
            ..Default::default()
        },
        shadow: palette.glow_shadow(0.25, 14.0),
        ..Default::default()
    })
    .into()
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
                shape: slider::HandleShape::Circle {
                    radius: handle_radius,
                },
                background: iced::Background::Color(palette.accent),
                border_width: if status == slider::Status::Active {
                    0.0
                } else {
                    3.0
                },
                border_color: theme::alpha(palette.glow, 0.35),
            },
        }
    }
}

/// A round, quiet icon button with a label that appears as a tooltip. This replaces rows of
/// text buttons wrapped in capsules: the icon is the button, the hover glow is its only chrome.
/// `msg = None` draws it dimmed and inert.
pub fn icon_action<'a, M: Clone + 'a>(
    glyph: Icon,
    label: &'static str,
    palette: HalcyonPalette,
    msg: Option<M>,
) -> Element<'a, M> {
    let tint = if msg.is_some() {
        palette.text
    } else {
        theme::alpha(palette.text_muted, 0.55)
    };
    let mut b = button(
        container(icon(glyph, 18.0, tint))
            .width(40)
            .height(40)
            .center_x(40)
            .center_y(40),
    )
    .padding(0)
    .style(move |_t, status| {
        let hot = matches!(status, button::Status::Hovered | button::Status::Pressed);
        button::Style {
            background: Some(
                if hot {
                    theme::alpha(palette.accent, 0.16)
                } else {
                    iced::Color::TRANSPARENT
                }
                .into(),
            ),
            text_color: tint,
            border: iced::Border {
                radius: 26.0.into(),
                color: if hot {
                    theme::alpha(palette.accent, 0.35)
                } else {
                    iced::Color::TRANSPARENT
                },
                width: 1.0,
            },
            ..Default::default()
        }
    });
    if let Some(m) = msg {
        b = b.on_press(m);
    }
    tooltip(
        b,
        container(
            text(label)
                .size(theme::type_size::SMALL)
                .color(palette.text),
        )
        .padding([5, 10])
        .style(move |_t| container::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                color: palette.soft_border(),
                width: 1.0,
                radius: theme::radius::SM.into(),
            },
            ..Default::default()
        }),
        tooltip::Position::Bottom,
    )
    .gap(6)
    .into()
}

/// The one big round play button: accent gradient, a glow that follows the hover, and the
/// glyph centred. `msg = None` dims it.
pub fn play_orb<'a, M: Clone + 'a>(
    glyph: Icon,
    size: f32,
    palette: HalcyonPalette,
    msg: Option<M>,
) -> Element<'a, M> {
    let enabled = msg.is_some();
    let mut b = button(
        container(icon(glyph, size * 0.42, palette.on_accent()))
            .width(size)
            .height(size)
            .center_x(size)
            .center_y(size),
    )
    .padding(0)
    .style(move |_t, status| {
        let shadow = match status {
            button::Status::Hovered => palette.glow_shadow(0.60, 30.0),
            button::Status::Pressed => palette.glow_shadow(0.30, 12.0),
            _ => palette.glow_shadow(0.32, 18.0),
        };
        button::Style {
            background: Some(if enabled {
                palette.accent_background()
            } else {
                iced::Background::Color(theme::alpha(palette.accent, 0.35))
            }),
            border: iced::Border {
                radius: (size / 2.0).into(),
                ..Default::default()
            },
            shadow: if enabled {
                shadow
            } else {
                iced::Shadow::default()
            },
            ..Default::default()
        }
    });
    if let Some(m) = msg {
        b = b.on_press(m);
    }
    b.into()
}

/// A pseudo-spectrum level for bar `i` of `n` (0.06 ..= 1.0). The GUI is a pure view and never
/// sees the audio, so the bars are layered sine waves driven by `clock` (seconds) and a
/// per-song `seed`: they dance while music plays and settle flat when it is paused.
pub fn spectrum_level(i: usize, n: usize, clock: f32, seed: f32, playing: bool) -> f32 {
    if !playing {
        return 0.06;
    }
    let x = i as f32 / n.max(1) as f32;
    let a = (clock * 2.1 + x * 9.0 + seed).sin();
    let b = (clock * 3.7 - x * 5.0 + seed * 1.7).sin();
    let c = (clock * 1.3 + x * 17.0).sin();
    let v = 0.5 + 0.5 * (0.55 * a + 0.30 * b + 0.15 * c);
    // The low end hits harder than the high end, like a real spectrum.
    let tilt = 1.0 - 0.45 * x;
    (v * v * tilt).clamp(0.06, 1.0)
}

/// Dancing bars turned on their side and stacked: a column of short horizontal bars that grow
/// from the middle line. It suits a narrow rail. (They follow a clock, not the real audio; the
/// full-screen visualizers use the real spectrum.)
#[allow(clippy::too_many_arguments)]
pub fn equalizer_vertical<'a, M: 'a>(
    rows: usize,
    bar_h: f32,
    gap: f32,
    max_w: f32,
    clock: f32,
    seed: f32,
    playing: bool,
    palette: HalcyonPalette,
) -> Element<'a, M> {
    let mut col = column![].spacing(gap).align_x(Alignment::Center);
    for i in 0..rows {
        let lvl = spectrum_level(i, rows, clock, seed, playing);
        let w = 4.0 + (max_w - 4.0) * lvl;
        let t = i as f32 / rows.max(1) as f32;
        let base = theme::mix(palette.accent, palette.accent_secondary, t);
        col = col.push(
            container(Space::new(w, bar_h)).style(move |_t| container::Style {
                background: Some(theme::gradient2(theme::alpha(base, 0.35), base, false)),
                border: iced::Border {
                    radius: (bar_h / 2.0).into(),
                    ..Default::default()
                },
                ..Default::default()
            }),
        );
    }
    col.into()
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

/// One friendly line and one action: the shape of every empty, error and offline state.
/// `message` says what happened in plain words; `action` is the single thing to do about it.
pub fn empty_state<'a, M: Clone + 'a>(
    icon_kind: crate::icons::Icon,
    message: &'a str,
    action: Option<(&'static str, M)>,
    palette: crate::theme::HalcyonPalette,
) -> iced::Element<'a, M> {
    use iced::widget::{column, container, text, Space};
    use iced::{Alignment, Length};
    let mut col = column![
        crate::icons::icon(icon_kind, 28.0, palette.text_muted),
        Space::with_height(theme::space::MD),
        text(message)
            .size(theme::type_size::BODY)
            .color(palette.text_muted),
    ]
    .align_x(Alignment::Center);
    if let Some((label, msg)) = action {
        col = col.push(Space::with_height(theme::space::LG));
        col = col.push(settings::action(label, None, palette, msg));
    }
    container(col)
        .width(Length::Fill)
        .padding(theme::space::XXL)
        .center_x(Length::Fill)
        .into()
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
