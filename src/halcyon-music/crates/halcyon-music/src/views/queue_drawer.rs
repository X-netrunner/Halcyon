//! Queue drawer: an open, borderless panel that dissolves into the page. The song playing now
//! is a big glowing cover with a live equalizer under it; the songs coming up are airy rows with
//! no boxes, stripes or outlines.

use crate::icons::{icon, Icon};
use crate::theme::{self, format_duration, HalcyonPalette};
use halcyon_music_core::state::PlayerState;
use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

pub const QUEUE_DRAWER_WIDTH: f32 = 340.0;

/// `clock` is the animation clock in seconds (drives the equalizer bars).
pub fn view<'a, Message: Clone + 'static>(
    state: &'a PlayerState,
    palette: HalcyonPalette,
    clock: f32,
    on_close: Message,
    on_dequeue: impl Fn(usize) -> Message + 'a,
) -> Element<'a, Message> {
    let upcoming: Vec<(usize, &halcyon_music_core::Track)> = state
        .queue
        .iter()
        .enumerate()
        .skip(state.queue_pos + 1)
        .collect();
    let up_count = upcoming.len();

    let header = row![
        text("Queue").size(20).color(palette.text),
        Space::with_width(Length::Fill),
        button(icon(Icon::Close, 16.0, palette.text_muted))
            .on_press(on_close)
            .padding(8)
            .style(crate::views::ghost(palette)),
    ]
    .align_y(Alignment::Center)
    .padding(iced::Padding { top: 16.0, right: 14.0, bottom: 4.0, left: 24.0 });

    let mut list = column![]
        .spacing(2)
        .width(Length::Fill)
        .padding(iced::Padding { top: 0.0, right: 12.0, bottom: 28.0, left: 12.0 });

    // Now playing: a large cover in a halo of its own colour, no frame around it.
    if let Some(cur) = state.track.as_ref() {
        let seed = cur.id.bytes().fold(0u32, |a, b| a.wrapping_mul(31).wrapping_add(b as u32)) as f32 % 97.0;
        let bass = crate::views::spectrum_level(1, 16, clock, seed, state.playing);
        let cover = container(crate::art::cover(
            cur.art_url.as_deref(),
            halcyon_music_core::art::ArtSize::Large,
            148.0 + 8.0 * bass,
            22.0,
            Icon::Music,
            &cur.title,
            palette,
        ))
        .style(move |_t| container::Style {
            border: iced::Border { radius: 22.0.into(), ..Default::default() },
            shadow: iced::Shadow {
                color: theme::alpha(palette.glow, 0.30 + 0.20 * bass),
                offset: iced::Vector::new(0.0, 6.0),
                blur_radius: 36.0,
            },
            ..Default::default()
        });
        let eq = crate::views::equalizer(9, 3.0, 3.0, 16.0, clock, seed, state.playing, true, palette);
        list = list.push(
            container(
                column![
                    container(cover).width(164).height(164).center_x(164).center_y(164),
                    Space::with_height(12),
                    text(super::ellipsize(&cur.title, 28)).size(16).color(palette.text),
                    text(super::ellipsize(&cur.artist, 34)).size(13).color(palette.accent),
                    Space::with_height(8),
                    eq,
                ]
                .spacing(2)
                .align_x(Alignment::Center),
            )
            .width(Length::Fill)
            .center_x(Length::Fill)
            .padding(iced::Padding { top: 8.0, right: 0.0, bottom: 18.0, left: 0.0 }),
        );
    }

    list = list.push(
        container(
            text(if up_count == 1 { "Next up · 1 song".to_string() } else { format!("Next up · {up_count} songs") })
                .size(12)
                .color(palette.text_muted),
        )
        .padding(iced::Padding { top: 0.0, right: 0.0, bottom: 6.0, left: 12.0 }),
    );

    if upcoming.is_empty() {
        list = list.push(
            container(
                column![
                    icon(Icon::Queue, 26.0, theme::alpha(palette.text_muted, 0.6)),
                    Space::with_height(10),
                    text("Nothing queued").size(14).color(palette.text),
                    text("Songs you add will wait here.").size(12).color(palette.text_muted),
                ]
                .spacing(2)
                .align_x(Alignment::Center),
            )
            .padding(24)
            .width(Length::Fill)
            .center_x(Length::Fill),
        );
    } else {
        for (n, (idx, track)) in upcoming.into_iter().enumerate() {
            let rm = button(icon(Icon::Close, 12.0, theme::alpha(palette.text_muted, 0.55)))
                .on_press(on_dequeue(idx))
                .padding(6)
                .style(crate::views::ghost(palette));
            let line = row![
                container(text(format!("{}", n + 1)).size(11).color(theme::alpha(palette.text_muted, 0.7)))
                    .width(20)
                    .center_x(20),
                crate::art::cover(
                    track.art_url.as_deref(),
                    halcyon_music_core::art::ArtSize::Small,
                    42.0,
                    12.0,
                    Icon::Music,
                    &track.title,
                    palette,
                ),
                Space::with_width(12),
                column![
                    text(super::ellipsize(&track.title, 28)).size(13).color(palette.text),
                    text(super::ellipsize(&track.artist, 32)).size(11).color(palette.text_muted),
                ]
                .spacing(2)
                .width(Length::Fill),
                text(format_duration(track.duration_ms)).size(11).color(theme::alpha(palette.text_muted, 0.8)),
                rm,
            ]
            .align_y(Alignment::Center)
            .padding([6, 8]);
            list = list.push(line);
        }
    }

    // No fill and no border: the drawer is drawn straight on the window frame, so it reads as
    // one piece with the sidebar, title bar and player bar (the page is the only raised card).
    container(
        column![
            header,
            scrollable(list)
                .direction(scrollable::Direction::Vertical(
                    scrollable::Scrollbar::new().width(0).scroller_width(0).margin(0),
                ))
                .height(Length::Fill)
                .width(Length::Fill),
        ]
        .width(QUEUE_DRAWER_WIDTH)
        .height(Length::Fill),
    )
    .width(QUEUE_DRAWER_WIDTH)
    .height(Length::Fill)
    .into()
}
