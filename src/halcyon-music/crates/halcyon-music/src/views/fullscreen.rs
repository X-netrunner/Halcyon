//! Full-screen Now Playing view with large cover, tinted background, and lyrics column.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, HalcyonPalette};
use halcyon_music_core::models::Lyrics;
use halcyon_music_core::state::PlayerState;
use iced::widget::{button, column, container, row, scrollable, slider, text, Space};
use iced::{Alignment, Element, Length};

#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    state: &'a PlayerState,
    palette: &'a HalcyonPalette,
    lyrics: Option<&'a Lyrics>,
    on_toggle_play: Message,
    on_next: Message,
    on_prev: Message,
    on_seek: impl Fn(u64) -> Message + 'a + Copy,
    on_exit_fullscreen: Message,
) -> Element<'a, Message> {
    let track = state.track.as_ref();
    let title = track.map(|t| t.title.as_str()).unwrap_or("No track playing");
    let artist = track.map(|t| t.artist.as_str()).unwrap_or("Halcyon");
    let album = track.map(|t| t.album.as_str()).unwrap_or("");
    let duration_ms = track.map(|t| t.duration_ms).unwrap_or(0);
    let position_ms = state.position_ms.min(duration_ms);

    // Close / Exit button
    let close_btn = button(row![icon(Icon::Close, 14.0, palette.text), Space::with_width(6), text("Close (Esc)").size(14).color(palette.text)].align_y(Alignment::Center))
        .on_press(on_exit_fullscreen)
        .padding([8, 16])
        .style(move |_t, s| button::Style {
            background: Some(
                if s == button::Status::Hovered {
                    palette.surface_variant
                } else {
                    palette.surface
                }
                .into(),
            ),
            border: iced::Border {
                radius: 20.0.into(),
                ..Default::default()
            },
            ..Default::default()
        });

    let top_bar = row![Space::with_width(Length::Fill), close_btn]
        .width(Length::Fill)
        .padding(20);

    // Left Column: Big Cover + Title + Album
    let big_art = crate::art::cover(
        track.and_then(|t| t.art_url.as_deref()),
        halcyon_music_core::art::ArtSize::Large,
        320.0,
        20.0,
        Icon::Music,
        title,
        *palette,
    );

    let left_info = column![
        big_art,
        Space::with_height(24),
        text(title).size(26).color(palette.text),
        text(artist).size(18).color(palette.accent),
        text(album).size(14).color(palette.text_muted),
    ]
    .align_x(Alignment::Center)
    .width(Length::FillPortion(1));

    // Right Column: Lyrics
    let mut lyrics_col = column![].spacing(14);
    if let Some(lrc) = lyrics {
        if lrc.lines.is_empty() {
            lyrics_col = lyrics_col.push(
                container(text("No lyrics available for this track").size(15).color(palette.text_muted))
                    .padding(40),
            );
        } else if lrc.synced {
            let effective_pos = (position_ms as i64).saturating_add(lrc.offset_ms).max(0) as u64;
            let mut active_idx = 0;
            for (i, line) in lrc.lines.iter().enumerate() {
                if line.start_ms <= effective_pos {
                    active_idx = i;
                } else {
                    break;
                }
            }

            for (idx, line) in lrc.lines.iter().enumerate() {
                let is_active = idx == active_idx;
                let distance = (idx as i64 - active_idx as i64).abs();
                let (font_size, color) = if is_active {
                    (22, palette.accent)
                } else if distance == 1 {
                    (17, palette.text)
                } else if distance == 2 {
                    (15, palette.text_muted)
                } else {
                    (14, iced::Color { a: 0.35, ..palette.text_muted })
                };

                let line_btn = button(
                    text(&line.text)
                        .size(font_size)
                        .color(color)
                        .width(Length::Fill),
                )
                .on_press(on_seek(line.start_ms))
                .padding([4, 8])
                .style(|_t, _s| button::Style::default());

                lyrics_col = lyrics_col.push(line_btn);
            }
        } else {
            for line in &lrc.lines {
                lyrics_col = lyrics_col.push(
                    text(&line.text)
                        .size(16)
                        .color(palette.text),
                );
            }
        }
    } else {
        lyrics_col = lyrics_col.push(
            container(text("No lyrics available for this track").size(15).color(palette.text_muted))
                .padding(40),
        );
    }

    let right_lyrics = container(
        scrollable(lyrics_col.padding(20))
            .height(Length::Fill)
            .width(Length::Fill),
    )
    .width(Length::FillPortion(1))
    .height(360)
    .style(move |_t| container::Style {
        background: Some(iced::Color { a: 0.4, ..palette.surface }.into()),
        border: iced::Border {
            radius: 12.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    let main_content = row![left_info, Space::with_width(40), right_lyrics]
        .align_y(Alignment::Center)
        .padding([0, 40]);

    // Bottom transport controls
    let play_pause_icon = if state.playing { Icon::Pause } else { Icon::Play };

    let prev_btn = button(icon(Icon::SkipBack, 24.0, palette.text))
        .on_press(on_prev)
        .padding(8)
        .style(|_t, _s| button::Style::default());

    let play_btn = button(
        container(icon(play_pause_icon, 28.0, palette.background))
            .width(52)
            .height(52)
            .center_x(52)
            .center_y(52),
    )
    .on_press(on_toggle_play)
    .padding(0)
    .style(move |_t, _s| button::Style {
        background: Some(palette.accent.into()),
        border: iced::Border {
            radius: 26.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    let next_btn = button(icon(Icon::SkipForward, 24.0, palette.text))
        .on_press(on_next)
        .padding(8)
        .style(|_t, _s| button::Style::default());

    let transport_row = row![prev_btn, Space::with_width(16), play_btn, Space::with_width(16), next_btn]
        .align_y(Alignment::Center);

    let dur_u32 = (duration_ms as u32).max(1);
    let pos_u32 = (position_ms as u32).min(dur_u32);
    let seek_slider = slider(0..=dur_u32, pos_u32, move |v| on_seek(v as u64)).width(500);
    let times = row![
        text(format_duration(position_ms)).size(13).color(palette.text_muted),
        Space::with_width(Length::Fill),
        text(format_duration(duration_ms)).size(13).color(palette.text_muted),
    ]
    .width(500);

    let bottom_controls = column![
        seek_slider,
        times,
        Space::with_height(12),
        transport_row,
    ]
    .align_x(Alignment::Center)
    .padding(24);

    container(
        column![
            top_bar,
            Space::with_height(Length::Fill),
            main_content,
            Space::with_height(Length::Fill),
            bottom_controls,
        ]
        .align_x(Alignment::Center),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .style(move |_t| container::Style {
        background: Some(
            // Tinted from cover art dominant color
            iced::Color {
                r: palette.background.r * 0.7 + palette.accent.r * 0.08,
                g: palette.background.g * 0.7 + palette.accent.g * 0.08,
                b: palette.background.b * 0.7 + palette.accent.b * 0.08,
                a: 1.0,
            }
            .into(),
        ),
        ..Default::default()
    })
    .into()
}
