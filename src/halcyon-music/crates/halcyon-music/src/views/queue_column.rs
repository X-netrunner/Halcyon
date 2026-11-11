//! The compact queue of the Top tabs layout: a narrow column on the window frame, always there
//! while the window is wide enough (`frame::queue_is_column`). The song playing comes first, then
//! the songs coming up, each with title, artist and length. No labels, no boxes.
//!
//! The queue button still opens the full drawer (`queue_drawer`) in this column's place.

use crate::icons::{icon, Icon};
use crate::theme::{self, format_duration, HalcyonPalette};
use halcyon_music_core::state::PlayerState;
use halcyon_music_core::Track;
use iced::widget::{column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

pub const WIDTH: f32 = 150.0;
const COVER_PX: f32 = 36.0;
/// How many upcoming songs are drawn. The drawer shows the rest.
const MAX_UPCOMING: usize = 40;

/// The songs after the one playing, for the column. Pure, so the rule is tested.
pub fn upcoming(state: &PlayerState) -> Vec<&Track> {
    state.queue.iter().skip(state.queue_pos + 1).take(MAX_UPCOMING).collect()
}

/// A cover: the picture when there is one, otherwise the dim tint with a note on it.
fn cover<'a, M: 'a>(track: &Track, palette: HalcyonPalette) -> Element<'a, M> {
    cover_px(track, COVER_PX, theme::radius::COVER, palette)
}

/// The same cover at any size and corner (the up-next list on the Player panel Home uses it).
pub(crate) fn cover_px<'a, M: 'a>(track: &Track, px: f32, radius: f32, palette: HalcyonPalette) -> Element<'a, M> {
    let has_art = track.art_url.as_deref().is_some_and(|u| !u.is_empty());
    if has_art {
        crate::art::cover(
            track.art_url.as_deref(),
            halcyon_music_core::art::ArtSize::Small,
            px,
            radius,
            Icon::Music,
            &track.title,
            palette,
        )
    } else {
        let tint = palette.dim_tint();
        container(icon(Icon::Music, px * 0.39, palette.text))
            .width(px)
            .height(px)
            .center_x(px)
            .center_y(px)
            .style(move |_t| container::Style {
                background: Some(tint.into()),
                border: iced::Border { radius: radius.into(), ..Default::default() },
                ..Default::default()
            })
            .into()
    }
}

fn entry<'a, M: 'a>(track: &'a Track, playing_now: bool, palette: HalcyonPalette) -> Element<'a, M> {
    let title_colour = if playing_now { palette.text } else { palette.text_muted };
    let info = column![
        text(super::ellipsize(&track.title, 12)).size(12).color(title_colour),
        text(super::ellipsize(&track.artist, 14)).size(11).color(palette.text_muted),
        text(format_duration(track.duration_ms)).size(10).color(palette.text_muted),
    ]
    .spacing(1)
    .width(Length::Fill);
    container(row![cover(track, palette), Space::with_width(8), info].align_y(Alignment::Center))
        .padding([4, 4])
        .width(Length::Fill)
        .into()
}

/// The column. Rows only show the queue; removing or reordering is in the drawer.
pub fn view<'a, M: 'a>(state: &'a PlayerState, palette: HalcyonPalette) -> Element<'a, M> {
    container(list(state, palette)).width(WIDTH).height(Length::Fill).into()
}

/// The rows alone, as wide as the space they are put in. The Library list layout reuses them
/// in its Queue / Lyrics panel.
pub fn list<'a, M: 'a>(state: &'a PlayerState, palette: HalcyonPalette) -> Element<'a, M> {
    let mut list = column![].spacing(2).width(Length::Fill).padding(iced::Padding {
        top: 4.0,
        right: 8.0,
        bottom: 16.0,
        left: 8.0,
    });
    if let Some(cur) = state.track.as_ref() {
        list = list.push(entry(cur, true, palette));
    }
    for track in upcoming(state) {
        list = list.push(entry(track, false, palette));
    }
    scrollable(list)
        .direction(scrollable::Direction::Vertical(
            scrollable::Scrollbar::new().width(0).scroller_width(0).margin(0),
        ))
        .height(Length::Fill)
        .width(Length::Fill)
        .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upcoming_is_what_follows_the_song_playing() {
        let mut state = PlayerState::default();
        assert!(upcoming(&state).is_empty());
        for i in 0..5 {
            state.queue.push(Track::simple(format!("t{i}"), "T".into(), "A".into(), "B".into(), 1000));
        }
        state.queue_pos = 1;
        let ids: Vec<&str> = upcoming(&state).iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, ["t2", "t3", "t4"]);
        state.queue_pos = 4;
        assert!(upcoming(&state).is_empty());
    }

    #[test]
    fn the_column_builds_with_no_track_and_with_a_queue() {
        let palette = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        let mut state = PlayerState::default();
        let _: Element<'_, ()> = view(&state, palette);
        let t = Track::simple("x".into(), "Song".into(), "Artist".into(), "Album".into(), 180_000);
        state.track = Some(t.clone());
        state.queue.push(t.clone());
        state.queue.push(t);
        let _: Element<'_, ()> = view(&state, palette);
    }
}
