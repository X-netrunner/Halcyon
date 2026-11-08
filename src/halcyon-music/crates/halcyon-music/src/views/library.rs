//! Library view: Liked songs, Playlists, Saved Albums, and Followed Artists.
//!
//! Fully cached offline in SQLite with instant filtering and sorting.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, Density, HalcyonPalette};
use halcyon_music_core::models::{Album, Artist, Playlist, Track};
use iced::widget::{button, column, container, row, text, text_input, Space};
use iced::{Alignment, Element, Length};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LibraryTab {
    #[default]
    Liked,
    Playlists,
    Albums,
    Artists,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LikedSort {
    #[default]
    Title,
    Artist,
    Album,
    Duration,
}

impl LibraryTab {
    /// The tabs shown on the page. Liked Songs is a pinned playlist now, not a tab.
    pub fn all() -> &'static [LibraryTab] {
        &[
            LibraryTab::Playlists,
            LibraryTab::Albums,
            LibraryTab::Artists,
        ]
    }

    pub fn label(&self) -> &'static str {
        match self {
            LibraryTab::Liked => "Liked Songs",
            LibraryTab::Playlists => "Playlists",
            LibraryTab::Albums => "Albums",
            LibraryTab::Artists => "Artists",
        }
    }

    pub fn icon(&self) -> Icon {
        match self {
            LibraryTab::Liked => Icon::Heart,
            LibraryTab::Playlists => Icon::Playlist,
            LibraryTab::Albums => Icon::Album,
            LibraryTab::Artists => Icon::Artist,
        }
    }
}

/// Every word typed must appear in at least one of the fields (any order, any case).
/// `filter` is already lower case. An empty filter matches everything.
fn matches(filter: &str, fields: &[&str]) -> bool {
    filter
        .split_whitespace()
        .all(|word| fields.iter().any(|f| f.to_lowercase().contains(word)))
}

/// The tabs as quiet text with a thin accent line under the open one: no pills, no boxes, so the
/// page stays as calm as the rest of the player. Each shows how many entries it holds (or how
/// many match the search), so a search is never a dead end on the wrong tab.
fn tab_strip<'a, Message: Clone + 'a>(
    active_tab: LibraryTab,
    counts: &[(LibraryTab, usize)],
    palette: HalcyonPalette,
    on_select_tab: impl Fn(LibraryTab) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut strip = row![].spacing(28).align_y(Alignment::End);
    for (tab, count) in counts {
        let is_active = *tab == active_tab;
        let tint = if is_active { palette.text } else { palette.text_muted };
        let label = row![
            text(tab.label()).size(14).color(tint),
            Space::with_width(6),
            text(count.to_string()).size(11).color(crate::theme::alpha(palette.text_muted, 0.8)),
        ]
        .align_y(Alignment::Center);
        let underline = container(Space::with_height(2))
            .width(Length::Fill)
            .style(move |_t| container::Style {
                background: Some(if is_active {
                    crate::theme::alpha(palette.accent, 0.9).into()
                } else {
                    iced::Color::TRANSPARENT.into()
                }),
                border: iced::Border { radius: 2.0.into(), ..Default::default() },
                ..Default::default()
            });
        strip = strip.push(
            button(column![label, Space::with_height(8), underline].width(Length::Shrink))
                .on_press(on_select_tab(*tab))
                .padding([4, 2])
                .style(move |_t, status| button::Style {
                    background: None,
                    text_color: if status == button::Status::Hovered { palette.text } else { tint },
                    ..Default::default()
                }),
        );
    }
    strip.into()
}

/// Lay tiles out in rows of `cols`; the last row is padded so tiles keep one width.
fn grid<'a, Message: 'a>(items: Vec<Element<'a, Message>>, cols: usize) -> Element<'a, Message> {
    let mut rows = column![].spacing(12).width(Length::Fill);
    let mut iter = items.into_iter();
    loop {
        let mut r = row![].spacing(12).width(Length::Fill);
        let mut got = 0;
        for _ in 0..cols {
            match iter.next() {
                Some(item) => {
                    r = r.push(item);
                    got += 1;
                }
                None => r = r.push(Space::with_width(Length::FillPortion(1))),
            }
        }
        if got == 0 {
            break;
        }
        rows = rows.push(r);
    }
    rows.into()
}

/// What a tab shows when nothing is in it: a short line, and when the search found matches on
/// other tabs, a button for each.
fn empty_state<'a, Message: Clone + 'a>(
    glyph: Icon,
    headline: String,
    hint: &'static str,
    elsewhere: Vec<(LibraryTab, usize)>,
    palette: HalcyonPalette,
    on_select_tab: impl Fn(LibraryTab) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut jump = row![].spacing(8).align_y(Alignment::Center);
    for (tab, n) in elsewhere {
        jump = jump.push(
            button(
                text(format!("{} in {}", n, tab.label()))
                    .size(12)
                    .color(palette.accent),
            )
            .on_press(on_select_tab(tab))
            .padding([6, 12])
            .style(move |_t, status| button::Style {
                background: Some(
                    crate::theme::alpha(palette.accent, if status == button::Status::Hovered { 0.20 } else { 0.10 })
                        .into(),
                ),
                text_color: palette.accent,
                border: iced::Border {
                    color: crate::theme::alpha(palette.accent, 0.30),
                    width: 1.0,
                    radius: crate::theme::radius::PILL.into(),
                },
                ..Default::default()
            }),
        );
    }
    container(
        column![
            Space::with_height(36),
            icon(glyph, 34.0, palette.text_muted),
            Space::with_height(12),
            text(headline).size(15).color(palette.text),
            Space::with_height(4),
            text(hint).size(12).color(palette.text_muted),
            Space::with_height(14),
            jump,
        ]
        .align_x(Alignment::Center),
    )
    .width(Length::Fill)
    .center_x(Length::Fill)
    .into()
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    active_tab: LibraryTab,
    filter_text: &'a str,
    liked_sort: LikedSort,
    liked_tracks: &'a [Track],
    playlists: &'a [Playlist],
    albums: &'a [Album],
    artists: &'a [Artist],
    new_playlist_name: &'a str,
    show_new_playlist_input: bool,
    palette: HalcyonPalette,
    density: Density,
    on_select_tab: impl Fn(LibraryTab) -> Message + 'a + Copy,
    _on_filter_changed: impl Fn(String) -> Message + 'a + Copy,
    on_change_sort: impl Fn(LikedSort) -> Message + 'a + Copy,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
    on_open_artist: impl Fn(String) -> Message + 'a + Copy,
    on_toggle_new_playlist: Message,
    on_new_playlist_input: impl Fn(String) -> Message + 'a,
    on_create_playlist: Message,
    on_delete_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_liked: Message,
) -> Element<'a, Message> {
    let mut page = column![].spacing(18).padding(20).width(Length::Fill);
    let filter_lower = filter_text.to_lowercase();

    // What each tab would show for the current search. Liked Songs is the first playlist.
    let liked_shown = matches(&filter_lower, &["liked songs"]);
    let playlist_hits = playlists
        .iter()
        .filter(|p| matches(&filter_lower, &[p.name.as_str(), p.owner.as_str()]))
        .count()
        + usize::from(liked_shown);
    let album_hits = albums
        .iter()
        .filter(|a| matches(&filter_lower, &[a.title.as_str(), a.artist.as_str()]))
        .count();
    let artist_hits = artists
        .iter()
        .filter(|a| {
            let genres = a.genres.join(" ");
            matches(&filter_lower, &[a.name.as_str(), genres.as_str()])
        })
        .count();
    let counts = [
        (LibraryTab::Playlists, playlist_hits),
        (LibraryTab::Albums, album_hits),
        (LibraryTab::Artists, artist_hits),
    ];

    // Heading and search on one line. Liked Songs opens like a playlist, so it brings its own heading.
    let heading: Element<'a, Message> = if active_tab == LibraryTab::Liked {
        row![
            crate::views::liked_cover(64.0, 16.0, palette),
            Space::with_width(16),
            column![
                text("Liked Songs").size(26).color(palette.text),
                text(format!("Playlist · {} songs", liked_tracks.len()))
                    .size(13)
                    .color(palette.text_muted),
            ]
            .spacing(4),
        ]
        .align_y(Alignment::Center)
        .into()
    } else {
        text("Your Library").size(26).color(palette.text).into()
    };
    page = page.push(heading);

    // The tabs (on the Liked Songs page none is lit and each leads back to the library).
    page = page.push(tab_strip(active_tab, &counts, palette, on_select_tab));

    // The content of the open tab, or an empty state that points at where the matches are.
    let shown = match active_tab {
        LibraryTab::Playlists => playlist_hits,
        LibraryTab::Albums => album_hits,
        LibraryTab::Artists => artist_hits,
        LibraryTab::Liked => 1,
    };
    let searching = !filter_lower.trim().is_empty();
    if shown == 0 {
        let elsewhere: Vec<(LibraryTab, usize)> = counts
            .iter()
            .filter(|(t, n)| *t != active_tab && *n > 0 && searching)
            .copied()
            .collect();
        let (glyph, noun) = match active_tab {
            LibraryTab::Albums => (Icon::Album, "albums"),
            LibraryTab::Artists => (Icon::Artist, "artists"),
            _ => (Icon::Playlist, "playlists"),
        };
        let headline = if searching {
            format!("No {noun} match \u{201c}{}\u{201d}", filter_text.trim())
        } else {
            format!("No {noun} yet")
        };
        let hint = if searching {
            "Try fewer words, or check the spelling."
        } else if active_tab == LibraryTab::Albums {
            "Albums you save on Spotify show up here."
        } else {
            "Artists you follow on Spotify show up here."
        };
        page = page.push(empty_state(glyph, headline, hint, elsewhere, palette, on_select_tab));
        return container(page).width(Length::Fill).into();
    }

    match active_tab {
        LibraryTab::Liked => {
            page = page.push(view_liked_tab(
                liked_tracks,
                &filter_lower,
                liked_sort,
                palette,
                density,
                on_change_sort,
                on_play_track,
                on_play_context,
            ));
        }
        LibraryTab::Playlists => {
            page = page.push(view_playlists_tab(
                playlists,
                &filter_lower,
                new_playlist_name,
                show_new_playlist_input,
                palette,
                on_open_playlist,
                on_toggle_new_playlist,
                on_new_playlist_input,
                on_create_playlist,
                on_delete_playlist,
                liked_tracks.len(),
                on_open_liked,
            ));
        }
        LibraryTab::Albums => {
            page = page.push(view_albums_tab(albums, &filter_lower, palette, on_open_album));
        }
        LibraryTab::Artists => {
            page = page.push(view_artists_tab(artists, &filter_lower, palette, on_open_artist));
        }
    }

    container(page).width(Length::Fill).into()
}

#[allow(clippy::too_many_arguments)]
fn view_liked_tab<'a, Message: Clone + 'static>(
    tracks: &'a [Track],
    filter: &str,
    sort: LikedSort,
    palette: HalcyonPalette,
    density: Density,
    on_change_sort: impl Fn(LikedSort) -> Message + 'a + Copy,
    _on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut col = column![].spacing(12).width(Length::Fill);

    // Filtered & sorted tracks
    let mut filtered: Vec<Track> = tracks
        .iter()
        .filter(|t| matches(filter, &[t.title.as_str(), t.artist.as_str(), t.album.as_str()]))
        .cloned()
        .collect();

    match sort {
        LikedSort::Title => filtered.sort_by(|a, b| a.title.cmp(&b.title)),
        LikedSort::Artist => filtered.sort_by(|a, b| a.artist.cmp(&b.artist)),
        LikedSort::Album => filtered.sort_by(|a, b| a.album.cmp(&b.album)),
        LikedSort::Duration => filtered.sort_by_key(|a| a.duration_ms),
    }

    // Top action bar: Play all, Shuffle, and Sort chips
    let play_all_tracks = filtered.clone();
    let play_all_btn = button(
        row![
            icon(Icon::Play, 15.0, palette.background),
            Space::with_width(6),
            text("Play All").size(13).color(palette.background),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_play_context(play_all_tracks, 0))
    .padding([6, 14])
    .style(move |_t, _s| button::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: 12.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    let sort_title_btn = button(text("Title").size(12).color(if sort == LikedSort::Title {
        palette.accent
    } else {
        palette.text_muted
    }))
    .on_press(on_change_sort(LikedSort::Title))
    .padding([4, 8])
    .style(|_t, _s| button::Style::default());

    let sort_artist_btn = button(text("Artist").size(12).color(if sort == LikedSort::Artist {
        palette.accent
    } else {
        palette.text_muted
    }))
    .on_press(on_change_sort(LikedSort::Artist))
    .padding([4, 8])
    .style(|_t, _s| button::Style::default());

    let sort_album_btn = button(text("Album").size(12).color(if sort == LikedSort::Album {
        palette.accent
    } else {
        palette.text_muted
    }))
    .on_press(on_change_sort(LikedSort::Album))
    .padding([4, 8])
    .style(|_t, _s| button::Style::default());

    let sort_duration_btn = button(text("Duration").size(12).color(if sort == LikedSort::Duration {
        palette.accent
    } else {
        palette.text_muted
    }))
    .on_press(on_change_sort(LikedSort::Duration))
    .padding([4, 8])
    .style(|_t, _s| button::Style::default());

    let top_bar = row![
        play_all_btn,
        Space::with_width(16),
        text(format!("{} songs", filtered.len())).size(13).color(palette.text_muted),
        Space::with_width(Length::Fill),
        text("Sort by:").size(12).color(palette.text_muted),
        Space::with_width(6),
        sort_title_btn,
        sort_artist_btn,
        sort_album_btn,
        sort_duration_btn,
    ]
    .align_y(Alignment::Center)
    .width(Length::Fill);

    col = col.push(top_bar);

    if filtered.is_empty() {
        col = col.push(
            container(
                column![
                    Space::with_height(30),
                    icon(Icon::Heart, 36.0, palette.text_muted),
                    Space::with_height(10),
                    text(if tracks.is_empty() {
                        "No liked songs found. Like songs by pressing L or clicking the heart icon."
                    } else {
                        "No songs match your search query."
                    })
                    .size(13)
                    .color(palette.text_muted),
                ]
                .align_x(Alignment::Center),
            )
            .width(Length::Fill)
            .center_x(Length::Fill),
        );
    } else {
        let all_context = filtered.clone();
        for (i, t) in filtered.iter().enumerate() {
            let context_clone = all_context.clone();
            let row_btn = button(
                row![
                    text(format!("{}", i + 1)).size(12).color(palette.text_muted),
                    Space::with_width(12),
                    crate::art::cover(t.art_url.as_deref(), halcyon_music_core::art::ArtSize::Small, 36.0, 6.0, Icon::Music, &t.title, palette),
                    Space::with_width(12),
                    column![
                        text(t.title.clone()).size(13).color(palette.text),
                        text(t.artist.clone()).size(11).color(palette.text_muted),
                    ]
                    .width(Length::FillPortion(2)),
                    text(t.album.clone())
                        .size(12)
                        .color(palette.text_muted)
                        .width(Length::FillPortion(2)),
                    text(format_duration(t.duration_ms)).size(12).color(palette.text_muted),
                    Space::with_width(12),
                    icon(Icon::Play, 16.0, palette.accent),
                ]
                .align_y(Alignment::Center)
                .padding([density.row_padding() / 2, 8]),
            )
            .width(Length::Fill)
            .on_press(on_play_context(context_clone, i))
            .style(move |_t, s| button::Style {
                background: Some(
                    if s == button::Status::Hovered { crate::theme::mix(palette.surface, palette.accent, 0.16) } else { crate::theme::alpha(palette.surface, 0.62) }
                    .into(),
                ),
                border: iced::Border {
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

            col = col.push(row_btn);
        }
    }

    col.into()
}

#[allow(clippy::too_many_arguments)]
fn view_playlists_tab<'a, Message: Clone + 'static>(
    playlists: &'a [Playlist],
    filter: &str,
    new_name: &'a str,
    show_new_input: bool,
    palette: HalcyonPalette,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_toggle_new: Message,
    on_input_new: impl Fn(String) -> Message + 'a,
    on_create: Message,
    on_delete_playlist: impl Fn(String) -> Message + 'a + Copy,
    liked_count: usize,
    on_open_liked: Message,
) -> Element<'a, Message> {
    let mut col = column![].spacing(14).width(Length::Fill);

    let new_btn = button(
        row![
            icon(Icon::Plus, 14.0, palette.on_accent()),
            Space::with_width(6),
            text("New playlist").size(13).color(palette.on_accent()),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_toggle_new)
    .padding([7, 16])
    .style(crate::views::solid(palette));

    let mut top_bar = row![new_btn].align_y(Alignment::Center);

    if show_new_input {
        top_bar = top_bar.push(Space::with_width(12));
        top_bar = top_bar.push(
            text_input("Name your playlist", new_name)
                .on_input(on_input_new)
                .on_submit(on_create.clone())
                .padding([7, 12])
                .size(13)
                .width(Length::Fixed(220.0)),
        );
        top_bar = top_bar.push(Space::with_width(8));
        top_bar = top_bar.push(
            button(text("Create").size(12).color(palette.on_accent()))
                .on_press(on_create)
                .padding([7, 14])
                .style(crate::views::solid(palette)),
        );
    }
    col = col.push(top_bar);

    let filtered: Vec<&Playlist> = playlists
        .iter()
        .filter(|p| matches(filter, &[p.name.as_str(), p.owner.as_str()]))
        .collect();

    let mut tiles: Vec<Element<'a, Message>> = Vec::new();

    // Liked Songs: always the first playlist.
    if matches(filter, &["liked songs"]) {
        tiles.push(
            button(
                row![
                    crate::views::liked_cover(56.0, 12.0, palette),
                    Space::with_width(14),
                    column![
                        text("Liked Songs").size(14).color(palette.text),
                        text(format!("Pinned · {liked_count} songs"))
                            .size(11)
                            .color(palette.text_muted),
                    ]
                    .spacing(3)
                    .width(Length::Fill),
                ]
                .align_y(Alignment::Center)
                .padding(10),
            )
            .width(Length::FillPortion(1))
            .on_press(on_open_liked)
            .style(crate::views::tile(palette, 16.0))
            .into(),
        );
    }

    for pl in filtered {
        let id = pl.id.clone();
        let del_id = pl.id.clone();
        tiles.push(
            button(
                row![
                    crate::art::cover(pl.art_url.as_deref(), halcyon_music_core::art::ArtSize::Small, 56.0, 10.0, Icon::Playlist, &pl.name, palette),
                    Space::with_width(14),
                    column![
                        text(super::ellipsize(&pl.name, 30)).size(14).color(palette.text),
                        text(format!("{} · {} songs", super::ellipsize(&pl.owner, 18), pl.total_tracks))
                            .size(11)
                            .color(palette.text_muted),
                    ]
                    .spacing(3)
                    .width(Length::Fill),
                    button(icon(Icon::Trash, 14.0, palette.text_muted))
                        .on_press(on_delete_playlist(del_id))
                        .padding(6)
                        .style(crate::views::ghost(palette)),
                ]
                .align_y(Alignment::Center)
                .padding(10),
            )
            .width(Length::FillPortion(1))
            .on_press(on_open_playlist(id))
            .style(crate::views::tile(palette, 16.0))
            .into(),
        );
    }

    col = col.push(grid(tiles, 3));
    col.into()
}

fn view_albums_tab<'a, Message: Clone + 'static>(
    albums: &'a [Album],
    filter: &str,
    palette: HalcyonPalette,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut tiles: Vec<Element<'a, Message>> = Vec::new();
    for alb in albums
        .iter()
        .filter(|a| matches(filter, &[a.title.as_str(), a.artist.as_str()]))
    {
        let id = alb.id.clone();
        tiles.push(
            button(
                column![
                    crate::art::cover(alb.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 120.0, 10.0, Icon::Album, &alb.title, palette),
                    Space::with_height(10),
                    text(super::ellipsize(&alb.title, 24)).size(13).color(palette.text),
                    text(super::ellipsize(&alb.artist, 26)).size(11).color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .padding(12),
            )
            .width(Length::FillPortion(1))
            .on_press(on_open_album(id))
            .style(crate::views::tile(palette, 16.0))
            .into(),
        );
    }
    grid(tiles, 4)
}

fn view_artists_tab<'a, Message: Clone + 'static>(
    artists: &'a [Artist],
    filter: &str,
    palette: HalcyonPalette,
    on_open_artist: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut tiles: Vec<Element<'a, Message>> = Vec::new();
    for a in artists.iter().filter(|a| {
        let genres = a.genres.join(" ");
        matches(filter, &[a.name.as_str(), genres.as_str()])
    }) {
        let id = a.id.clone();
        let sub = if a.genres.is_empty() {
            "Artist".to_string()
        } else {
            super::ellipsize(&a.genres.join(", "), 26)
        };
        tiles.push(
            button(
                column![
                    crate::art::cover(a.image_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 104.0, 52.0, Icon::Artist, &a.name, palette),
                    Space::with_height(10),
                    text(super::ellipsize(&a.name, 24)).size(13).color(palette.text),
                    text(sub).size(11).color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .padding(12),
            )
            .width(Length::FillPortion(1))
            .on_press(on_open_artist(id))
            .style(crate::views::tile(palette, 16.0))
            .into(),
        );
    }
    grid(tiles, 4)
}
