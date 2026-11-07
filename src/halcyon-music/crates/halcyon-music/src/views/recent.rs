//! Recently played: everything from the Home "Jump back in" shelf as a grid
//! of fixed-size cards, so rows line up whatever the window width.

use crate::icons::Icon;
use crate::theme::HalcyonPalette;
use halcyon_music_core::art::ArtSize;
use halcyon_music_core::models::{HomeFeed, Track};
use iced::widget::{button, column, row, text, Space};
use iced::{Element, Length};

const CARD_WIDTH: f32 = 140.0;
const PER_ROW: usize = 5;

pub fn view<'a, Message: Clone + 'static>(
    feed: &'a HomeFeed,
    palette: HalcyonPalette,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut page = column![
        text("Recently played").size(22).color(palette.text),
        text("Albums, playlists and artists you listened to lately")
            .size(12)
            .color(palette.text_muted),
        Space::with_height(8),
    ]
    .spacing(4)
    .padding([16, 24])
    .width(Length::Fill);

    if feed.jump_back_in.is_empty() {
        page = page.push(
            text("Nothing here yet. Play something and it will show up.")
                .size(13)
                .color(palette.text_muted),
        );
        return page.into();
    }

    let mut grid = column![].spacing(14);
    for chunk in feed.jump_back_in.chunks(PER_ROW) {
        let mut r = row![].spacing(14);
        for item in chunk {
            let tracks = item.tracks.clone();
            let card = button(
                column![
                    crate::art::cover(
                        item.art_url.as_deref(),
                        ArtSize::Medium,
                        CARD_WIDTH - 16.0,
                        10.0,
                        Icon::Music,
                        &item.title,
                        palette,
                    ),
                    Space::with_height(8),
                    text(super::ellipsize(&item.title, 17)).size(13).color(palette.text),
                    text(super::ellipsize(&item.subtitle, 20))
                        .size(11)
                        .color(palette.text_muted),
                ]
                .width(CARD_WIDTH - 16.0),
            )
            .padding(8)
            .on_press(if let Some(first) = tracks.first() {
                on_play_track(first.clone())
            } else {
                on_play_context(tracks, 0)
            })
            .style(move |_t, s| button::Style {
                background: Some(
                    if s == button::Status::Hovered { crate::theme::mix(palette.surface, palette.accent, 0.16) } else { crate::theme::alpha(palette.surface, 0.62) }
                    .into(),
                ),
                border: iced::Border {
                    radius: 18.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            r = r.push(card);
        }
        grid = grid.push(r);
    }

    page.push(grid).into()
}
