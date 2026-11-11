//! The lyrics of the song playing, small enough for the narrow side panel of the Library list
//! layout. No buttons, no offset controls, no timestamps: the line being sung is in full text
//! colour, the rest is muted. The full page (`lyrics.rs`) stays the place to seek and tune.
//!
//! Which lines are drawn is decided by pure functions (`active_index`, `window`), so the rule is
//! tested without a window.

use crate::theme::HalcyonPalette;
use halcyon_music_core::models::{LyricLine, Lyrics};
use iced::widget::{column, container, scrollable, text};
use iced::{Element, Length};

/// Lines kept before the one being sung, and after it.
const BEFORE: usize = 2;
const AFTER: usize = 12;
/// For lyrics without timing there is no current line: the first lines are shown.
const PLAIN_MAX: usize = 40;

/// The line being sung at `position_ms`, with the manual offset applied. Before the first line
/// starts, the first line counts as current (same rule as the full page).
pub fn active_index(lines: &[LyricLine], position_ms: u64, offset_ms: i64) -> usize {
    let at = (position_ms as i64).saturating_add(offset_ms).max(0) as u64;
    let mut active = 0;
    for (i, line) in lines.iter().enumerate() {
        if line.start_ms <= at {
            active = i;
        } else {
            break;
        }
    }
    active
}

/// The range of line indices to draw around `active`, never outside `0..len`.
pub fn window(active: usize, len: usize) -> std::ops::Range<usize> {
    let start = active.saturating_sub(BEFORE).min(len);
    let end = (active + AFTER + 1).min(len);
    start..end.max(start)
}

fn quiet<'a, M: 'a>(label: &'static str, palette: HalcyonPalette) -> Element<'a, M> {
    container(text(label).size(12).color(palette.text_muted))
        .width(Length::Fill)
        .padding([8, 10])
        .into()
}

/// The panel body. `lyrics` is what the daemon sent for the current song, if anything.
pub fn view<'a, M: 'a>(
    lyrics: Option<&'a Lyrics>,
    position_ms: u64,
    palette: HalcyonPalette,
) -> Element<'a, M> {
    let Some(lrc) = lyrics.filter(|l| !l.lines.is_empty()) else {
        return quiet("No lyrics for this song", palette);
    };
    let (range, active) = if lrc.synced {
        let a = active_index(&lrc.lines, position_ms, lrc.offset_ms);
        (window(a, lrc.lines.len()), Some(a))
    } else {
        (0..lrc.lines.len().min(PLAIN_MAX), None)
    };
    let mut col = column![].spacing(8).width(Length::Fill).padding(iced::Padding {
        top: 4.0,
        right: 10.0,
        bottom: 16.0,
        left: 10.0,
    });
    for idx in range {
        let line = &lrc.lines[idx];
        let current = active == Some(idx);
        let (size, colour) = if current { (13.0, palette.text) } else { (12.0, palette.text_muted) };
        col = col.push(text(&line.text).size(size).color(colour).width(Length::Fill));
    }
    scrollable(col)
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

    fn lines(starts: &[u64]) -> Vec<LyricLine> {
        starts
            .iter()
            .map(|s| LyricLine { start_ms: *s, text: format!("line {s}"), ..Default::default() })
            .collect()
    }

    #[test]
    fn the_current_line_is_the_last_one_that_has_started() {
        let l = lines(&[1000, 2000, 3000]);
        assert_eq!(active_index(&l, 0, 0), 0);
        assert_eq!(active_index(&l, 2500, 0), 1);
        assert_eq!(active_index(&l, 9000, 0), 2);
        // The manual offset moves the line: 500 ms ahead reaches the third line at 2500.
        assert_eq!(active_index(&l, 2500, 500), 2);
        // A large negative offset never goes below zero.
        assert_eq!(active_index(&l, 100, -5000), 0);
        assert_eq!(active_index(&[], 100, 0), 0);
    }

    #[test]
    fn the_window_stays_inside_the_lines() {
        assert_eq!(window(0, 0), 0..0);
        assert_eq!(window(0, 5), 0..5);
        assert_eq!(window(1, 100), 0..14);
        assert_eq!(window(50, 100), 48..63);
        assert_eq!(window(99, 100), 97..100);
        for len in 0..30 {
            for a in 0..30 {
                let r = window(a, len);
                assert!(r.start <= r.end && r.end <= len);
            }
        }
    }

    #[test]
    fn the_panel_builds_without_lyrics_with_synced_and_with_plain_lyrics() {
        let palette = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        let _: Element<'_, ()> = view(None, 0, palette);
        let mut l = Lyrics { track_id: "t".into(), synced: true, lines: lines(&[0, 1000, 2000]), offset_ms: 0 };
        let _: Element<'_, ()> = view(Some(&l), 1500, palette);
        l.synced = false;
        let _: Element<'_, ()> = view(Some(&l), 0, palette);
        l.lines.clear();
        let _: Element<'_, ()> = view(Some(&l), 0, palette);
    }
}
