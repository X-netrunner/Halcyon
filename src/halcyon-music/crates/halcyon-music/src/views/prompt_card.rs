//! "Describe a mood": a text box on Home that turns a few words into a mix of real songs.
//!
//! Part of the optional Smart suggestions layer. The daemon does the work; this is only a view.
//! Nothing here animates or runs on a timer (so `reduce_motion` has nothing to turn off), and the
//! status line under the box has a fixed height, so going from "hint" to "working" to "failed"
//! never moves the page. The finished mix appears below it as one card with Play and Save.

use crate::icons::{icon, Icon};
use crate::theme::{alpha, radius, space, type_size, HalcyonPalette};
use halcyon_music_core::models::{MusicMix, Track};
use iced::widget::{button, column, container, row, text, text_input, Space};
use iced::{Alignment, Element, Length};

/// Height reserved for the status line: two lines of small text. Fixed, so the page never jumps.
const STATUS_H: f32 = 34.0;
/// Fewest letters and digits worth sending (the daemon checks the same number).
const MIN_CHARS: usize = 3;

/// Where the current request is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase {
    Idle,
    /// The daemon's step name (`understanding`, `searching`, `choosing`, or one we do not know).
    Working(String),
    /// A plain-language reason, with something to try.
    Failed(String),
}

/// What to say while the daemon works. Unknown steps (from a newer daemon) get a generic line.
pub fn step_label(step: &str) -> &'static str {
    match step {
        "understanding" => "Understanding your request…",
        "searching" => "Finding songs…",
        "choosing" => "Choosing the best ones…",
        _ => "Working on it…",
    }
}

/// Is there enough text to send?
pub fn can_send_text(text: &str) -> bool {
    text.chars().filter(|c| c.is_alphanumeric()).count() >= MIN_CHARS
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, M: Clone + 'static>(
    enabled: bool,
    text_value: &'a str,
    phase: &'a Phase,
    mix: Option<&'a MusicMix>,
    palette: HalcyonPalette,
    on_input: impl Fn(String) -> M + 'a,
    on_submit: M,
    on_play: impl Fn(Vec<Track>, String) -> M + 'a,
    on_save: impl Fn(String, Vec<String>) -> M + 'a,
    on_open: impl Fn(String) -> M + 'a,
    on_clear: M,
    on_settings: M,
) -> Element<'a, M> {
    let working = matches!(phase, Phase::Working(_));
    let can_send = enabled && !working && can_send_text(text_value);

    let header = row![
        icon(Icon::Sparkles, 16.0, palette.accent),
        Space::with_width(8),
        text("Describe a mood").size(18).color(palette.text),
        Space::with_width(8),
        text("Smart suggestions").size(13).color(palette.accent),
    ]
    .align_y(Alignment::Center);

    let input = text_input("rainy night coding, no lyrics", text_value)
        .on_input_maybe((enabled && !working).then_some(on_input))
        .on_submit_maybe(can_send.then(|| on_submit.clone()))
        .size(type_size::BODY)
        .padding([space::SM, space::MD])
        .width(Length::Fill)
        .style(move |_t, status| text_input::Style {
            background: alpha(palette.text, 0.06).into(),
            border: iced::Border {
                radius: radius::MD.into(),
                width: 1.0,
                color: if matches!(status, text_input::Status::Focused) { palette.accent } else { alpha(palette.border, 0.30) },
            },
            icon: palette.text_muted,
            placeholder: palette.text_muted,
            value: palette.text,
            selection: iced::Color { a: 0.3, ..palette.accent },
        });

    let go_label = if working { "Working…" } else { "Make a mix" };
    let go = button(text(go_label).size(type_size::BODY).color(if can_send { palette.text } else { palette.text_muted }))
        .on_press_maybe(can_send.then(|| on_submit.clone()))
        .padding([space::SM, space::LG])
        .style(move |_t, status| button::Style {
            background: Some(
                if can_send && matches!(status, button::Status::Hovered | button::Status::Pressed) {
                    alpha(palette.accent, 0.20)
                } else {
                    alpha(palette.accent, 0.08)
                }
                .into(),
            ),
            text_color: palette.text,
            border: iced::Border { color: alpha(palette.accent, 0.30), width: 1.0, radius: radius::MD.into() },
            ..Default::default()
        });

    let input_row = row![input, Space::with_width(space::SM), go].align_y(Alignment::Center);

    // One status line, always the same height.
    let (status_text, status_color): (String, iced::Color) = match phase {
        Phase::Working(step) => (step_label(step).to_string(), palette.text_muted),
        Phase::Failed(reason) => (reason.clone(), palette.danger),
        Phase::Idle if !enabled => ("Turn on Smart suggestions in Settings to describe a mood.".to_string(), palette.text_muted),
        Phase::Idle => ("Try “rainy night coding, no lyrics” or “upbeat 90s workout”.".to_string(), palette.text_muted),
    };
    let settings_btn: Element<'a, M> = if enabled {
        Space::with_width(0).into()
    } else {
        button(text("Open Settings").size(type_size::SMALL).color(palette.accent))
            .on_press(on_settings)
            .padding([space::XS, space::SM])
            .style(crate::views::ghost(palette))
            .into()
    };
    let status_row = row![
        container(text(status_text).size(type_size::SMALL).color(status_color)).width(Length::Fill),
        settings_btn,
    ]
    .align_y(Alignment::Start)
    .height(Length::Fixed(STATUS_H));

    let mut card = column![header, Space::with_height(10), input_row, Space::with_height(6), status_row].spacing(0);

    if let Some(mix) = mix {
        let uris: Vec<String> = mix.tracks.iter().map(|t| t.uri.clone()).collect();
        let tracks = mix.tracks.clone();

        // The first few artists, once each, so the card says what is in it.
        let mut artists: Vec<&str> = Vec::new();
        for t in &mix.tracks {
            if !artists.contains(&t.artist.as_str()) {
                artists.push(t.artist.as_str());
            }
            if artists.len() >= 3 {
                break;
            }
        }
        let preview = format!("{} songs · {}", mix.tracks.len(), artists.join(", "));

        let title_btn = button(text(super::ellipsize(&mix.title, 32)).size(type_size::BODY).color(palette.text))
            .padding(0)
            .on_press(on_open(mix.id.clone()))
            .style(|_t, _s| button::Style::default());
        let info = column![
            title_btn,
            text(super::ellipsize(&mix.description, 70)).size(type_size::SMALL).color(palette.text_muted),
            text(super::ellipsize(&preview, 60)).size(type_size::CAPTION).color(alpha(palette.text_muted, 0.85)),
        ]
        .spacing(3)
        .width(Length::Fill);

        let clear_btn = button(text("Clear").size(type_size::SMALL).color(palette.text_muted))
            .on_press(on_clear)
            .padding([space::XS, space::SM])
            .style(crate::views::ghost(palette));
        let save_btn = button(
            container(icon(Icon::Plus, 14.0, palette.text))
                .width(30)
                .height(30)
                .center_x(30)
                .center_y(30),
        )
        .padding(0)
        .on_press(on_save(mix.title.clone(), uris))
        .style(move |_t, status| {
            let hot = matches!(status, button::Status::Hovered | button::Status::Pressed);
            button::Style {
                background: Some(alpha(palette.text, if hot { 0.16 } else { 0.08 }).into()),
                border: iced::Border { color: alpha(palette.text, 0.18), width: 1.0, radius: 15.0.into() },
                ..Default::default()
            }
        });
        let play_btn = crate::views::play_orb(Icon::Play, 34.0, palette, Some(on_play(tracks, mix.title.clone())));

        let result = container(
            row![info, Space::with_width(space::MD), clear_btn, save_btn, play_btn]
                .spacing(6)
                .align_y(Alignment::Center),
        )
        .padding(space::MD)
        .width(Length::Fill)
        .style(move |_t| container::Style {
            background: Some(alpha(palette.surface, 0.55).into()),
            border: iced::Border { radius: 24.0.into(), ..Default::default() },
            ..Default::default()
        });
        card = card.push(Space::with_height(space::SM)).push(result);
    }

    card.into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_known_step_has_its_own_line_and_unknown_ones_a_generic_one() {
        assert_eq!(step_label("understanding"), "Understanding your request…");
        assert_eq!(step_label("searching"), "Finding songs…");
        assert_eq!(step_label("choosing"), "Choosing the best ones…");
        assert_eq!(step_label("polishing"), "Working on it…");
        assert_eq!(step_label(""), "Working on it…");
    }

    #[test]
    fn short_or_symbol_only_text_is_not_sent() {
        assert!(!can_send_text(""));
        assert!(!can_send_text("  ab  "));
        assert!(!can_send_text("!!! ???"));
        assert!(can_send_text("rain"));
        assert!(can_send_text("雨の夜"));
    }
}
