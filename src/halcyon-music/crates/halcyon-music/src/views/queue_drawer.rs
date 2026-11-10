//! Queue drawer: an open, borderless panel that dissolves into the page. The song playing now
//! is a big glowing cover that swells softly on every beat, with thin ripples spreading from it
//! and fading into curves (see `orbit` and `viz`); the songs coming up are airy rows with
//! no boxes, stripes or outlines.

use crate::icons::{icon, Icon};
use crate::theme::{self, format_duration, HalcyonPalette};
use halcyon_music_core::state::PlayerState;
use crate::viz::VizFrame;
use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

pub const QUEUE_DRAWER_WIDTH: f32 = 340.0;
/// Edge of the cover at rest, and of the square the ring is drawn in.
const COVER_PX: f32 = 148.0;
const ORBIT_PX: f32 = 264.0;

/// `viz` is this frame's snapshot of the sound (beat swell and ripples).
pub fn view<'a, Message: Clone + 'static>(
    state: &'a PlayerState,
    palette: HalcyonPalette,
    viz: VizFrame,
    on_close: Message,
    on_dequeue: impl Fn(usize) -> Message + 'a,
    suggested: &'a std::collections::HashSet<String>,
    on_reject: impl Fn(String) -> Message + 'a,
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

    // Now playing: the cover swells on each beat inside ripples, in a halo of its own
    // colour. No frame around it.
    if let Some(cur) = state.track.as_ref() {
        let cover_px = COVER_PX * (1.0 + 0.032 * viz.pulse + 0.008 * viz.bass);
        let glow = viz.pulse;
        let cover = container(crate::art::cover(
            cur.art_url.as_deref(),
            halcyon_music_core::art::ArtSize::Large,
            cover_px,
            22.0 * cover_px / COVER_PX,
            Icon::Music,
            &cur.title,
            palette,
        ))
        .style(move |_t| container::Style {
            border: iced::Border { radius: 28.0.into(), ..Default::default() },
            shadow: iced::Shadow {
                color: theme::alpha(palette.glow, 0.26 + 0.22 * glow),
                offset: iced::Vector::new(0.0, 6.0),
                blur_radius: 36.0 + 10.0 * glow,
            },
            ..Default::default()
        });
        // One layer, not a `stack!`: this lives inside a scrollable, and a stack's extra layer is
        // drawn after the whole window, so it could paint over the player bar. `Crossfade` draws
        // both children in the layer the scroll area has already clipped.
        let art: Element<'a, Message> = crate::views::crossfade::Crossfade::new(
            crate::views::orbit::view(viz, cover_px, ORBIT_PX, palette),
            container(cover)
                .width(ORBIT_PX)
                .height(ORBIT_PX)
                .center_x(ORBIT_PX)
                .center_y(ORBIT_PX),
        )
        .into();
        list = list.push(
            container(
                column![
                    art,
                    Space::with_height(4),
                    text(super::ellipsize(&cur.title, 28)).size(16).color(palette.text),
                    text(super::ellipsize(&cur.artist, 34)).size(13).color(palette.accent),
                ]
                .spacing(2)
                .align_x(Alignment::Center),
            )
            .width(Length::Fill)
            .center_x(Length::Fill)
            .padding(iced::Padding { top: 0.0, right: 0.0, bottom: 18.0, left: 0.0 }),
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
            // Part 6, Smart Shuffle: a song Halcyon added is tagged, with a "Not this" button.
            let is_suggestion = suggested.contains(&track.id);
            let tag: Element<'a, Message> = if is_suggestion {
                button(text("Suggested · Not this").size(10).color(palette.accent))
                    .on_press(on_reject(track.id.clone()))
                    .padding([2, 6])
                    .style(crate::views::ghost(palette))
                    .into()
            } else {
                Space::with_width(0).into()
            };
            let line = row![
                container(text(format!("{}", n + 1)).size(11).color(theme::alpha(palette.text_muted, 0.7)))
                    .width(20)
                    .center_x(20),
                crate::art::cover(
                    track.art_url.as_deref(),
                    halcyon_music_core::art::ArtSize::Small,
                    42.0,
                    18.0,
                    Icon::Music,
                    &track.title,
                    palette,
                ),
                Space::with_width(12),
                column![
                    text(super::ellipsize(&track.title, 28)).size(13).color(palette.text),
                    text(super::ellipsize(&track.artist, 32)).size(11).color(palette.text_muted),
                    tag,
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
