//! The up-next list on the Home page of the Player panel layout: the songs coming after the one
//! playing, each a small cover with title and artist. No label above it and no length, and no
//! buttons: the queue itself (reordering, removing) is in the drawer the queue button opens.
//!
//! This list is the queue in this layout (there is no separate queue column), so it takes its rows
//! from `queue_column::upcoming`.

use crate::theme::{self, HalcyonPalette};
use crate::views::queue_column;
use halcyon_music_core::state::PlayerState;
use iced::widget::{column, container, row, text, Space};
use iced::{Alignment, Element, Length};

const COVER_PX: f32 = 44.0;
const TITLE_CHARS: usize = 44;
const ARTIST_CHARS: usize = 44;

/// Whether there is anything coming up. Home shows its "Recent" shelf instead when there is not.
pub fn is_empty(state: &PlayerState) -> bool {
    queue_column::upcoming(state).is_empty()
}

/// The rows. Not scrollable: the page around it scrolls.
pub fn list<'a, M: 'a>(state: &'a PlayerState, palette: HalcyonPalette) -> Element<'a, M> {
    let mut rows = column![].spacing(2).width(Length::Fill);
    for track in queue_column::upcoming(state) {
        let info = column![
            text(crate::views::ellipsize(&track.title, TITLE_CHARS)).size(14).color(palette.text),
            text(crate::views::ellipsize(&track.artist, ARTIST_CHARS)).size(12).color(palette.text_muted),
        ]
        .spacing(2)
        .width(Length::Fill);
        rows = rows.push(
            container(
                row![
                    queue_column::cover_px(track, COVER_PX, theme::radius::ROW_COVER, palette),
                    Space::with_width(12),
                    info,
                ]
                .align_y(Alignment::Center),
            )
            .padding([6, 0])
            .width(Length::Fill),
        );
    }
    rows.into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use halcyon_music_core::Track;

    fn track(i: usize) -> Track {
        Track::simple(format!("t{i}"), format!("Song {i}"), "Artist".into(), "Album".into(), 1000)
    }

    #[test]
    fn it_is_empty_until_something_is_queued_after_the_song_playing() {
        let mut state = PlayerState::default();
        assert!(is_empty(&state));
        state.queue.push(track(0));
        state.queue_pos = 0;
        assert!(is_empty(&state), "the song playing is not up next");
        state.queue.push(track(1));
        assert!(!is_empty(&state));
    }

    #[test]
    fn the_list_builds_empty_and_with_many_songs() {
        let palette = HalcyonPalette::for_mood(theme::Mood::Dusk);
        let mut state = PlayerState::default();
        let _: Element<'_, ()> = list(&state, palette);
        for i in 0..60 {
            state.queue.push(track(i));
        }
        let _: Element<'_, ()> = list(&state, palette);
    }
}
