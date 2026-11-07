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
    breath: f32,
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
                    crate::theme::alpha(palette.accent, 0.22)
                } else {
                    crate::theme::alpha(palette.surface, 0.55)
                }
                .into(),
            ),
            text_color: palette.text,
            border: iced::Border {
                color: crate::theme::alpha(palette.accent, 0.25),
                width: 1.0,
                radius: 20.0.into(),
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
        28.0,
        Icon::Music,
        title,
        *palette,
    );

    // The cover sits in a halo of the cover's own colour that slowly breathes in and out.
    let halo = container(big_art).style(move |_t| container::Style {
        border: iced::Border { radius: 28.0.into(), ..Default::default() },
        shadow: iced::Shadow {
            color: crate::theme::alpha(palette.glow, 0.22 + 0.22 * breath),
            offset: iced::Vector::new(0.0, 0.0),
            blur_radius: 50.0 + 40.0 * breath,
        },
        ..Default::default()
    });

    let left_info = column![
        halo,
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
                    (26, palette.accent)
                } else if distance == 1 {
                    (18, palette.text)
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
        background: Some(crate::theme::alpha(palette.surface, 0.45).into()),
        border: iced::Border {
            color: palette.soft_border(),
            width: 1.0,
            radius: 24.0.into(),
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
        .style(crate::views::ghost(*palette));

    let play_btn = button(
        container(icon(play_pause_icon, 28.0, palette.on_accent()))
            .width(60)
            .height(60)
            .center_x(60)
            .center_y(60),
    )
    .on_press(on_toggle_play)
    .padding(0)
    .style(move |_t, _s| button::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: 30.0.into(),
            ..Default::default()
        },
        shadow: palette.glow_shadow(0.30 + 0.25 * breath, 24.0 + 12.0 * breath),
        ..Default::default()
    });

    let next_btn = button(icon(Icon::SkipForward, 24.0, palette.text))
        .on_press(on_next)
        .padding(8)
        .style(crate::views::ghost(*palette));

    let transport_row = row![prev_btn, Space::with_width(16), play_btn, Space::with_width(16), next_btn]
        .align_y(Alignment::Center);

    let dur_u32 = (duration_ms as u32).max(1);
    let pos_u32 = (position_ms as u32).min(dur_u32);
    let seek_slider = slider(0..=dur_u32, pos_u32, move |v| on_seek(v as u64))
        .width(500)
        .style(crate::views::slider_style(*palette));
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
        // A deeper, cover-tinted gradient than the normal pages, with the glow near the top.
        background: Some(crate::theme::gradient3(
            crate::theme::mix(palette.bg_top, palette.glow, 0.10 + 0.05 * breath),
            crate::theme::mix(palette.background, palette.glow, 0.04),
            palette.bg_bottom,
        )),
        ..Default::default()
    })
    .into()
}
