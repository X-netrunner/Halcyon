//! The right panel of the Library list layout (~140 px, on the frame surface): two chips, Queue
//! and Lyrics. Queue shows the rows of the compact queue; Lyrics shows the lyrics of the song
//! playing in a small form. Which chip is open is kept in memory for the session only.
//!
//! The queue button still opens the full drawer in this panel's place (`frame::right_width`).

use crate::theme::HalcyonPalette;
use crate::views::{library_sidebar, lyrics_compact, queue_column};
use halcyon_music_core::models::Lyrics;
use halcyon_music_core::state::PlayerState;
use iced::widget::{column, container, row, Space};
use iced::{Alignment, Element, Length};

pub const WIDTH: f32 = 140.0;
const CHIP_TEXT: f32 = 11.0;

/// Which chip is open.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SideTab {
    #[default]
    Queue,
    Lyrics,
}

impl SideTab {
    pub const ALL: [SideTab; 2] = [SideTab::Queue, SideTab::Lyrics];

    pub fn label(&self) -> &'static str {
        match self {
            SideTab::Queue => "Queue",
            SideTab::Lyrics => "Lyrics",
        }
    }
}

pub fn view<'a, M: Clone + 'a>(
    tab: SideTab,
    state: &'a PlayerState,
    lyrics: Option<&'a Lyrics>,
    palette: HalcyonPalette,
    on_select: impl Fn(SideTab) -> M + 'a,
) -> Element<'a, M> {
    let mut chips = row![].spacing(4).align_y(Alignment::Center);
    for t in SideTab::ALL {
        chips = chips.push(library_sidebar::chip(
            t.label(),
            tab == t,
            CHIP_TEXT,
            palette,
            on_select(t),
        ));
    }
    let body: Element<'a, M> = match tab {
        SideTab::Queue => queue_column::list(state, palette),
        SideTab::Lyrics => {
            // Only the lyrics of the song playing: a leftover from an earlier song is not shown.
            let current = state.track.as_ref().map(|t| t.id.as_str());
            let fresh = lyrics.filter(|l| current == Some(l.track_id.as_str()));
            lyrics_compact::view(fresh, state.position_ms, palette)
        }
    };
    container(column![
        container(chips).padding([4, 8]),
        Space::with_height(4),
        body
    ])
    .width(WIDTH)
    .height(Length::Fill)
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use halcyon_music_core::Track;

    #[test]
    fn the_queue_chip_is_the_one_that_starts_open() {
        assert_eq!(SideTab::default(), SideTab::Queue);
        assert_eq!(SideTab::ALL.len(), 2);
    }

    #[test]
    fn the_panel_builds_for_both_chips_with_and_without_a_song() {
        let palette = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        let mut state = PlayerState::default();
        for tab in SideTab::ALL {
            let _v: Element<'_, SideTab> = view(tab, &state, None, palette, |t| t);
        }
        let t = Track::simple(
            "x".into(),
            "Song".into(),
            "Artist".into(),
            "Album".into(),
            180_000,
        );
        state.track = Some(t.clone());
        state.queue.push(t);
        let stale = Lyrics {
            track_id: "other".into(),
            synced: false,
            lines: vec![],
            offset_ms: 0,
        };
        for tab in SideTab::ALL {
            let _v: Element<'_, SideTab> = view(tab, &state, Some(&stale), palette, |t| t);
        }
    }
}
