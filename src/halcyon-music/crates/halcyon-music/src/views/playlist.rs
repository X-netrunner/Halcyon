//! Playlist page: header (cover, name, owner, count, Play, Shuffle) and the song table.
//!
//! The song table is *windowed*: only the rows near the visible part of the scroll area are
//! built, the rest are two spacers of the right height. A playlist of thousands of songs
//! therefore costs the same per frame as one of fifty. Row height is fixed so the maths is exact.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, radius, space, type_size, HalcyonPalette};
use halcyon_music_core::art::ArtSize;
use halcyon_music_core::models::{Playlist, Track};
use iced::widget::{button, column, container, mouse_area, row, text, Space};
use iced::{Alignment, Element, Length};

/// Height of one song row, spacing included.
pub const ROW_H: f32 = 56.0;
/// Rows built above and below the visible ones, so fast scrolling never shows a gap.
pub const BUFFER: usize = 8;
/// Height of everything above the first row (back button, header, table head). An estimate:
/// the buffer absorbs the error.
pub const HEADER_H: f32 = 330.0;
/// Rows of grey placeholders while the first page loads.
const SKELETON_ROWS: usize = 10;

/// What the page is doing about the song list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Phase {
    /// The first page has been asked for and nothing has come back.
    Loading,
    /// At least one page is here.
    Ready,
    /// Spotify answered and the playlist has no songs.
    Empty,
    /// Nothing came back in time.
    Failed,
}

/// Which rows to build: `(first, end)` for `len` rows when the scroll area is `scroll_y` down
/// and `viewport_h` tall. Always a valid slice range.
pub fn visible_range(scroll_y: f32, viewport_h: f32, len: usize) -> (usize, usize) {
    let first_visible = ((scroll_y - HEADER_H) / ROW_H).floor().max(0.0) as usize;
    let on_screen = (viewport_h.max(ROW_H) / ROW_H).ceil() as usize + 1;
    let start = first_visible.saturating_sub(BUFFER).min(len);
    let end = first_visible.saturating_add(on_screen).saturating_add(BUFFER).min(len);
    (start, end.max(start))
}

/// Put a page of songs into `list` at `offset` (replacing a cached copy of the same page).
/// Returns false when the page does not touch the list (a gap before it): the caller asks again.
pub fn merge_page(list: &mut Vec<Track>, offset: usize, page: Vec<Track>) -> bool {
    if offset > list.len() {
        return false;
    }
    let end = (offset + page.len()).min(list.len());
    list.splice(offset..end, page);
    true
}

/// True when the app should ask for the next page: the user is within `margin` px of the end of
/// the content and more songs exist.
pub fn near_end(scroll_y: f32, viewport_h: f32, content_h: f32, margin: f32) -> bool {
    content_h > 0.0 && scroll_y + viewport_h >= content_h - margin
}

/// Everything the page needs to draw.
pub struct Page<'a> {
    pub playlist: &'a Playlist,
    pub tracks: &'a [Track],
    pub total: usize,
    pub phase: Phase,
    pub loading_more: bool,
    pub more_failed: bool,
    pub selected: Option<usize>,
    pub scroll_y: f32,
    pub viewport_h: f32,
    pub shimmer: f32,
    pub palette: HalcyonPalette,
}

/// Messages the page can send.
pub struct Actions<M, F1, F2, F3> {
    pub back: M,
    pub play_all: M,
    pub shuffle: M,
    pub add_to_queue: M,
    pub play_next: M,
    pub retry: M,
    /// Delete the playlist (`None` for a mix, which is not a Spotify playlist).
    pub delete: Option<M>,
    /// Save the mix as a real playlist (`Some` only for a mix).
    pub save: Option<M>,
    /// A click on a row (select; a second quick click plays).
    pub row_click: F1,
    /// The play button of a row.
    pub row_play: F2,
    /// Right click on a row.
    pub row_menu: F3,
}

fn pulse(shimmer: f32) -> f32 {
    0.45 + 0.35 * (0.5 + 0.5 * (shimmer * std::f32::consts::TAU).sin())
}

fn block<'a, M: 'a>(w: f32, h: f32, r: f32, palette: HalcyonPalette, alpha: f32) -> Element<'a, M> {
    container(Space::new(w, h))
        .style(move |_t| container::Style {
            background: Some(iced::Color { a: alpha, ..palette.surface_variant }.into()),
            border: iced::Border { radius: r.into(), ..Default::default() },
            ..Default::default()
        })
        .into()
}

fn skeleton_row<'a, M: 'a>(palette: HalcyonPalette, alpha: f32) -> Element<'a, M> {
    container(
        row![
            Space::with_width(44),
            block(40.0, 40.0, radius::SM, palette, alpha),
            Space::with_width(space::MD),
            column![
                block(220.0, 12.0, 4.0, palette, alpha),
                block(140.0, 10.0, 4.0, palette, alpha),
            ]
            .spacing(space::SM),
        ]
        .align_y(Alignment::Center)
        .padding([0.0, space::LG]),
    )
    .height(ROW_H)
    .center_y(ROW_H)
    .into()
}

fn header<'a, M: Clone + 'a>(p: &Page<'a>, a: &Actions<M, impl Fn(usize) -> M, impl Fn(usize) -> M, impl Fn(usize) -> M>) -> Element<'a, M> {
    let pal = p.palette;
    let count = p.total.max(p.playlist.total_tracks as usize).max(p.tracks.len());
    let count_label = match (p.phase.clone(), count) {
        (Phase::Loading, 0) => "Loading songs…".to_string(),
        (_, 1) => "1 song".to_string(),
        (_, n) => format!("{n} songs"),
    };
    let can_play = !p.tracks.is_empty();

    let back = button(
        row![
            icon(Icon::ArrowLeft, 15.0, pal.text),
            Space::with_width(space::SM),
            text("Back").size(type_size::SMALL + 1.0).color(pal.text),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(a.back.clone())
    .padding([space::XS, space::SM])
    .style(crate::views::ghost(pal));

    // One big round Play, then quiet icon buttons: no capsules around words. Save shows only
    // for a mix, Delete only for a real playlist.
    let mut actions = row![
        crate::views::play_orb(Icon::Play, 56.0, pal, can_play.then(|| a.play_all.clone())),
        Space::with_width(space::SM),
        crate::views::icon_action(Icon::Shuffle, "Shuffle", pal, can_play.then(|| a.shuffle.clone())),
        crate::views::icon_action(Icon::Queue, "Add to queue", pal, can_play.then(|| a.add_to_queue.clone())),
        crate::views::icon_action(Icon::Plus, "Play next", pal, can_play.then(|| a.play_next.clone())),
    ]
    .spacing(space::XS)
    .align_y(Alignment::Center);
    if let Some(save) = a.save.clone() {
        actions = actions.push(crate::views::icon_action(
            Icon::Playlist,
            "Save as a playlist",
            pal,
            can_play.then_some(save),
        ));
    }
    actions = actions.push(Space::with_width(Length::Fill));
    if let Some(del) = a.delete.clone() {
        actions = actions.push(crate::views::icon_action(Icon::Trash, "Delete playlist", pal, Some(del)));
    }

    let kicker = if p.playlist.id.starts_with("mix:") { "MADE FOR YOU BY HALCYON" } else { "PLAYLIST" };
    let info = column![
        text(kicker).size(type_size::CAPTION).color(pal.accent),
        Space::with_height(space::XS),
        text(crate::views::ellipsize(&p.playlist.name, 60)).size(32).color(pal.text),
        Space::with_height(space::SM),
        text(format!("{} · {}", crate::views::ellipsize(&p.playlist.owner, 40), count_label))
            .size(type_size::BODY)
            .color(pal.text_muted),
        Space::with_height(space::XL),
        actions,
    ];

    column![
        back,
        Space::with_height(space::LG),
        row![
            crate::art::cover(
                p.playlist.art_url.as_deref(),
                ArtSize::Medium,
                168.0,
                radius::LG,
                Icon::Playlist,
                &p.playlist.name,
                pal,
            ),
            Space::with_width(space::XL),
            info.width(Length::Fill),
        ]
        .align_y(Alignment::End),
    ]
    .into()
}

fn table_head<'a, M: 'a>(pal: HalcyonPalette) -> Element<'a, M> {
    let cap = |s: &'static str| text(s).size(type_size::CAPTION).color(pal.text_muted);
    container(
        row![
            container(cap("#")).width(44).center_x(44),
            Space::with_width(52),
            cap("TITLE").width(Length::FillPortion(5)),
            cap("ALBUM").width(Length::FillPortion(3)),
            container(icon(Icon::Clock, 13.0, pal.text_muted)).width(56).center_x(56),
            Space::with_width(32.0 + space::SM),
        ]
        .align_y(Alignment::Center)
        .padding([0.0, space::LG]),
    )
    .height(32)
    .center_y(32)
    .style(move |_t| container::Style {
        border: iced::Border { color: pal.border, width: 0.5, radius: 0.0.into() },
        ..Default::default()
    })
    .into()
}

fn song_row<'a, M: Clone + 'a>(
    idx: usize,
    t: &'a Track,
    selected: bool,
    pal: HalcyonPalette,
    click: M,
    play: M,
    menu: M,
) -> Element<'a, M> {
    let play_btn = button(
        container(icon(Icon::Play, 13.0, pal.accent))
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x(Length::Fill)
            .center_y(Length::Fill),
    )
    .on_press(play)
    .width(32)
    .height(32)
    .padding(0)
    .style(move |_t, status| button::Style {
        background: Some(
            if matches!(status, button::Status::Hovered | button::Status::Pressed) {
                iced::Color { a: 0.18, ..pal.accent }
            } else {
                iced::Color::TRANSPARENT
            }
            .into(),
        ),
        border: iced::Border { radius: 26.0.into(), ..Default::default() },
        ..Default::default()
    });

    let content = row![
        container(text(format!("{}", idx + 1)).size(type_size::SMALL + 1.0).color(if selected { pal.accent } else { pal.text_muted }))
            .width(44)
            .center_x(44),
        crate::art::cover(t.art_url.as_deref(), ArtSize::Small, 40.0, radius::SM, Icon::Music, &t.title, pal),
        Space::with_width(space::MD),
        column![
            text(crate::views::ellipsize(&t.title, 60)).size(type_size::BODY).color(if selected { pal.accent } else { pal.text }),
            text(crate::views::ellipsize(&t.artist, 50)).size(type_size::SMALL).color(pal.text_muted),
        ]
        .spacing(2)
        .width(Length::FillPortion(5)),
        text(crate::views::ellipsize(&t.album, 50))
            .size(type_size::SMALL + 1.0)
            .color(pal.text_muted)
            .width(Length::FillPortion(3)),
        container(text(format_duration(t.duration_ms)).size(type_size::SMALL + 1.0).color(pal.text_muted))
            .width(56)
            .align_x(iced::alignment::Horizontal::Right),
        Space::with_width(space::SM),
        play_btn,
    ]
    .align_y(Alignment::Center)
    .padding([0.0, space::LG]);

    let row_btn = button(content)
        .on_press(click)
        .width(Length::Fill)
        .height(ROW_H)
        .padding(0)
        .style(move |_t, status| {
            let hovered = matches!(status, button::Status::Hovered | button::Status::Pressed);
            button::Style {
                background: Some(
                    if selected {
                        iced::Color { a: 0.7, ..pal.surface_variant }
                    } else if hovered {
                        iced::Color { a: 0.5, ..pal.surface_variant }
                    } else {
                        iced::Color::TRANSPARENT
                    }
                    .into(),
                ),
                text_color: pal.text,
                border: iced::Border { radius: radius::SM.into(), ..Default::default() },
                ..Default::default()
            }
        });

    mouse_area(row_btn).on_right_press(menu).into()
}

fn notice<'a, M: Clone + 'a>(
    title: &'static str,
    detail: &'static str,
    retry: Option<M>,
    pal: HalcyonPalette,
) -> Element<'a, M> {
    let mut col = column![
        text(title).size(type_size::TITLE).color(pal.text),
        text(detail).size(type_size::BODY).color(pal.text_muted),
    ]
    .spacing(space::SM)
    .align_x(Alignment::Center);
    if let Some(r) = retry {
        col = col.push(Space::with_height(space::SM));
        col = col.push(
            button(
                row![
                    icon(Icon::Refresh, 15.0, pal.on_accent()),
                    Space::with_width(space::SM),
                    text("Retry").size(type_size::BODY),
                ]
                .align_y(Alignment::Center),
            )
            .padding([space::SM + 2.0, space::XL - 2.0])
            .on_press(r)
            .style(crate::views::solid(pal)),
        );
    }
    container(col)
        .width(Length::Fill)
        .padding(space::XXL)
        .center_x(Length::Fill)
        .into()
}

pub fn view<'a, M: Clone + 'a>(
    p: Page<'a>,
    a: Actions<M, impl Fn(usize) -> M + 'a, impl Fn(usize) -> M + 'a, impl Fn(usize) -> M + 'a>,
) -> Element<'a, M> {
    let pal = p.palette;
    let alpha = pulse(p.shimmer);

    let mut page = column![header(&p, &a), Space::with_height(space::XL), table_head(pal)].width(Length::Fill);

    match p.phase {
        Phase::Loading => {
            for _ in 0..SKELETON_ROWS {
                page = page.push(skeleton_row(pal, alpha));
            }
        }
        Phase::Failed => {
            page = page.push(notice(
                "Couldn't load this playlist",
                "Spotify didn't answer in time. Check your connection and try again.",
                Some(a.retry.clone()),
                pal,
            ));
        }
        Phase::Empty => {
            page = page.push(notice(
                "No songs here yet",
                "This playlist is empty. Add songs from Search or Home.",
                None,
                pal,
            ));
        }
        Phase::Ready => {
            let (start, end) = visible_range(p.scroll_y, p.viewport_h, p.tracks.len());
            page = page.push(Space::with_height(start as f32 * ROW_H));
            for idx in start..end {
                if let Some(t) = p.tracks.get(idx) {
                    page = page.push(song_row(
                        idx,
                        t,
                        p.selected == Some(idx),
                        pal,
                        (a.row_click)(idx),
                        (a.row_play)(idx),
                        (a.row_menu)(idx),
                    ));
                }
            }
            page = page.push(Space::with_height(p.tracks.len().saturating_sub(end) as f32 * ROW_H));
            if p.more_failed {
                page = page.push(notice(
                    "Couldn't load more songs",
                    "The rest of the playlist didn't arrive.",
                    Some(a.retry.clone()),
                    pal,
                ));
            } else if p.loading_more || p.tracks.len() < p.total {
                for _ in 0..3 {
                    page = page.push(skeleton_row(pal, alpha));
                }
            }
        }
    }

    container(page.padding([space::XL, space::XL])).width(Length::Fill).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tracks(n: usize) -> Vec<Track> {
        (0..n)
            .map(|i| Track::simple(format!("id{i}"), format!("t{i}"), "a".into(), "b".into(), 1000))
            .collect()
    }

    #[test]
    fn window_at_the_top_starts_at_zero() {
        let (s, e) = visible_range(0.0, 700.0, 500);
        assert_eq!(s, 0);
        assert!(e > 0 && e < 40, "only a few rows are built, got {e}");
    }

    #[test]
    fn window_follows_the_scroll_position() {
        let (s, e) = visible_range(HEADER_H + 100.0 * ROW_H, 700.0, 500);
        assert!(s <= 100 && s >= 100 - BUFFER - 1);
        assert!(e > 100 && e <= 100 + 14 + BUFFER + 2);
    }

    #[test]
    fn window_never_leaves_the_list() {
        for len in [0usize, 1, 5, 50] {
            for y in [0.0, 500.0, 1e6] {
                let (s, e) = visible_range(y, 800.0, len);
                assert!(s <= e && e <= len, "len {len} y {y} -> {s}..{e}");
            }
        }
    }

    #[test]
    fn merging_replaces_a_cached_page_and_appends_new_ones() {
        let mut list = tracks(3);
        assert!(merge_page(&mut list, 0, tracks(3)));
        assert_eq!(list.len(), 3, "same page replaces, does not double");
        assert!(merge_page(&mut list, 3, tracks(2)));
        assert_eq!(list.len(), 5);
        assert!(!merge_page(&mut list, 9, tracks(1)), "a gap is refused");
        assert_eq!(list.len(), 5);
    }

    #[test]
    fn duplicate_songs_in_a_playlist_are_kept() {
        let mut list = Vec::new();
        let dup = Track::simple("same".into(), "t".into(), "a".into(), "b".into(), 1);
        assert!(merge_page(&mut list, 0, vec![dup.clone(), dup]));
        assert_eq!(list.len(), 2);
    }

    #[test]
    fn near_end_triggers_before_the_bottom() {
        assert!(near_end(1000.0, 700.0, 1900.0, 400.0));
        assert!(!near_end(0.0, 700.0, 5000.0, 400.0));
        assert!(!near_end(0.0, 700.0, 0.0, 400.0), "no content measured yet");
    }
}
