//! Slide-in Queue drawer showing Now Playing and upcoming queued songs.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, HalcyonPalette};
use halcyon_music_core::state::PlayerState;
use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

pub const QUEUE_DRAWER_WIDTH: f32 = 320.0;

pub fn view<'a, Message: Clone + 'static>(
    state: &'a PlayerState,
    palette: HalcyonPalette,
    on_close: Message,
    on_dequeue: impl Fn(usize) -> Message + 'a,
) -> Element<'a, Message> {
    let queue_len = state.queue.len();
    let current_pos = state.queue_pos;

    let header = row![
        text("Play Queue").size(16).color(palette.text),
        Space::with_width(8),
        text(format!("({queue_len})")).size(13).color(palette.text_muted),
        Space::with_width(Length::Fill),
        button(icon(Icon::Close, 16.0, palette.text_muted))
            .on_press(on_close)
            .padding(4)
            .style(|_t, _s| button::Style::default()),
    ]
    .align_y(Alignment::Center)
    .padding([12, 16]);

    let mut list = column![].spacing(6).padding([0, 12]);

    // Now Playing section
    if let Some(cur) = state.track.as_ref() {
        list = list.push(text("Now Playing").size(12).color(palette.accent));
        let cur_card = container(
            row![
                crate::art::cover(
                    cur.art_url.as_deref(),
                    halcyon_music_core::art::ArtSize::Small,
                    40.0,
                    6.0,
                    Icon::Music,
                    &cur.title,
                    palette,
                ),
                Space::with_width(10),
                column![
                    text(super::ellipsize(&cur.title, 56)).size(13).color(palette.text),
                    text(super::ellipsize(&cur.artist, 44)).size(11).color(palette.text_muted),
                ],
                Space::with_width(Length::Fill),
                text(format_duration(cur.duration_ms)).size(11).color(palette.text_muted),
            ]
            .align_y(Alignment::Center),
        )
        .padding(8)
        .style(move |_t| container::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                radius: 8.0.into(),
                ..Default::default()
            },
            ..Default::default()
        });

        list = list.push(cur_card);
        list = list.push(Space::with_height(12));
    }

    // Next in Queue
    list = list.push(text("Next Up").size(12).color(palette.text_muted));

    let upcoming_tracks: Vec<(usize, &halcyon_music_core::Track)> = state
        .queue
        .iter()
        .enumerate()
        .skip(current_pos + 1)
        .collect();

    if upcoming_tracks.is_empty() {
        list = list.push(
            container(
                text("Queue is empty. Add songs from your library or search.")
                    .size(12)
                    .color(palette.text_muted),
            )
            .padding(16),
        );
    } else {
        for (idx, track) in upcoming_tracks {
            let item_row = container(
                row![
                    text(format!("{}", idx + 1)).size(11).color(palette.text_muted),
                    Space::with_width(8),
                    column![
                        text(super::ellipsize(&track.title, 56)).size(12).color(palette.text),
                        text(super::ellipsize(&track.artist, 44)).size(11).color(palette.text_muted),
                    ]
                    .width(Length::FillPortion(1)),
                    text(format_duration(track.duration_ms)).size(11).color(palette.text_muted),
                    Space::with_width(6),
                    button(icon(Icon::Close, 12.0, palette.text_muted))
                        .on_press(on_dequeue(idx))
                        .padding(2)
                        .style(|_t, _s| button::Style::default()),
                ]
                .align_y(Alignment::Center),
            )
            .padding(6)
            .style(move |_t| container::Style {
                background: Some(iced::Color::TRANSPARENT.into()),
                border: iced::Border {
                    radius: 6.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

            list = list.push(item_row);
        }
    }

    container(
        column![
            header,
            scrollable(list).height(Length::Fill).width(Length::Fill),
        ]
        .width(QUEUE_DRAWER_WIDTH)
        .height(Length::Fill),
    )
    .width(QUEUE_DRAWER_WIDTH)
    .height(Length::Fill)
    .style(move |_t| container::Style {
        background: Some(palette.surface.into()),
        border: iced::Border {
            color: palette.border,
            width: 1.0,
            ..Default::default()
        },
        ..Default::default()
    })
    .into()
}
