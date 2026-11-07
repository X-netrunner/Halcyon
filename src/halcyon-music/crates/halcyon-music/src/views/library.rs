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
    pub fn all() -> &'static [LibraryTab] {
        &[
            LibraryTab::Liked,
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
    on_filter_changed: impl Fn(String) -> Message + 'a,
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
) -> Element<'a, Message> {
    let mut page = column![].spacing(16).padding(20).width(Length::Fill);

    // 1. Tab buttons & Search Filter row
    let mut tabs_row = row![].spacing(8);
    for tab in LibraryTab::all() {
        let is_active = *tab == active_tab;
        let tab_btn = button(
            row![
                icon(tab.icon(), 14.0, if is_active {
                    palette.background
                } else {
                    palette.accent
                }),
                Space::with_width(6),
                text(tab.label()).size(13).color(if is_active {
                    palette.background
                } else {
                    palette.text
                }),
            ]
            .align_y(Alignment::Center),
        )
        .on_press(on_select_tab(*tab))
        .padding([6, 14])
        .style(move |_t, _s| button::Style {
            background: Some(
                if is_active {
                    palette.accent
                } else {
                    palette.surface
                }
                .into(),
            ),
            border: iced::Border {
                color: if is_active {
                    palette.accent
                } else {
                    palette.border
                },
                width: 0.5,
                radius: 16.0.into(),
            },
            ..Default::default()
        });
        tabs_row = tabs_row.push(tab_btn);
    }

    let filter_input = text_input("Filter in library...", filter_text)
        .on_input(on_filter_changed)
        .padding([6, 10])
        .size(13)
        .width(Length::Fixed(240.0));

    let header_row = row![
        tabs_row,
        Space::with_width(Length::Fill),
        filter_input,
    ]
    .align_y(Alignment::Center)
    .width(Length::Fill);

    page = page.push(header_row);

    // 2. Tab Content
    let filter_lower = filter_text.to_lowercase();

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
            ));
        }
        LibraryTab::Albums => {
            page = page.push(view_albums_tab(
                albums,
                &filter_lower,
                palette,
                on_open_album,
            ));
        }
        LibraryTab::Artists => {
            page = page.push(view_artists_tab(
                artists,
                &filter_lower,
                palette,
                on_open_artist,
            ));
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
        .filter(|t| {
            if filter.is_empty() {
                true
            } else {
                t.title.to_lowercase().contains(filter)
                    || t.artist.to_lowercase().contains(filter)
                    || t.album.to_lowercase().contains(filter)
            }
        })
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
        background: Some(palette.accent.into()),
        border: iced::Border {
            radius: 8.0.into(),
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
                    if s == button::Status::Hovered {
                        palette.surface_variant
                    } else {
                        palette.surface
                    }
                    .into(),
                ),
                border: iced::Border {
                    radius: 8.0.into(),
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
) -> Element<'a, Message> {
    let mut col = column![].spacing(14).width(Length::Fill);

    // Top action row
    let new_btn = button(
        row![
            icon(Icon::Plus, 14.0, palette.background),
            Space::with_width(6),
            text("New Playlist").size(13).color(palette.background),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_toggle_new)
    .padding([6, 14])
    .style(move |_t, _s| button::Style {
        background: Some(palette.accent.into()),
        border: iced::Border {
            radius: 8.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    let mut top_bar = row![
        new_btn,
        Space::with_width(12),
        text(format!("{} playlists", playlists.len())).size(13).color(palette.text_muted),
    ]
    .align_y(Alignment::Center);

    if show_new_input {
        top_bar = top_bar.push(Space::with_width(16));
        top_bar = top_bar.push(
            text_input("Enter playlist name...", new_name)
                .on_input(on_input_new)
                .padding([6, 10])
                .size(13)
                .width(Length::Fixed(200.0)),
        );
        top_bar = top_bar.push(Space::with_width(8));
        top_bar = top_bar.push(
            button(text("Create").size(12).color(palette.background))
                .on_press(on_create)
                .padding([6, 12])
                .style(move |_t, _s| button::Style {
                    background: Some(palette.accent.into()),
                    border: iced::Border {
                        radius: 6.0.into(),
                        ..Default::default()
                    },
                    ..Default::default()
                }),
        );
    }

    col = col.push(top_bar);

    let filtered: Vec<&Playlist> = playlists
        .iter()
        .filter(|p| filter.is_empty() || p.name.to_lowercase().contains(filter))
        .collect();

    let mut grid = column![].spacing(12);
    for chunk in filtered.chunks(3) {
        let mut r = row![].spacing(12).width(Length::Fill);
        for pl in chunk {
            let id = pl.id.clone();
            let del_id = pl.id.clone();

            let card = button(
                row![
                    crate::art::cover(pl.art_url.as_deref(), halcyon_music_core::art::ArtSize::Small, 56.0, 8.0, Icon::Playlist, &pl.name, palette),
                    Space::with_width(12),
                    column![
                        text(super::ellipsize(&pl.name, 56)).size(14).color(palette.text),
                        text(format!("By {} · {} songs", pl.owner, pl.total_tracks))
                            .size(11)
                            .color(palette.text_muted),
                    ]
                    .width(Length::Fill),
                    button(icon(Icon::Trash, 14.0, palette.text_muted))
                        .on_press(on_delete_playlist(del_id))
                        .padding(4)
                        .style(|_t, _s| button::Style::default()),
                ]
                .align_y(Alignment::Center)
                .padding(10),
            )
            .width(Length::FillPortion(1))
            .on_press(on_open_playlist(id))
            .style(move |_t, s| button::Style {
                background: Some(
                    if s == button::Status::Hovered {
                        palette.surface_variant
                    } else {
                        palette.surface
                    }
                    .into(),
                ),
                border: iced::Border {
                    radius: 8.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

            r = r.push(card);
        }
        grid = grid.push(r);
    }

    col = col.push(grid);
    col.into()
}

fn view_albums_tab<'a, Message: Clone + 'static>(
    albums: &'a [Album],
    filter: &str,
    palette: HalcyonPalette,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut col = column![].spacing(14).width(Length::Fill);

    let filtered: Vec<&Album> = albums
        .iter()
        .filter(|a| {
            filter.is_empty()
                || a.title.to_lowercase().contains(filter)
                || a.artist.to_lowercase().contains(filter)
        })
        .collect();

    col = col.push(
        text(format!("{} saved albums", filtered.len())).size(13).color(palette.text_muted),
    );

    let mut grid = column![].spacing(12);
    for chunk in filtered.chunks(4) {
        let mut r = row![].spacing(12).width(Length::Fill);
        for alb in chunk {
            let id = alb.id.clone();
            let card = button(
                column![
                    crate::art::cover(alb.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 96.0, 8.0, Icon::Album, &alb.title, palette),
                    Space::with_height(10),
                    text(super::ellipsize(&alb.title, 56)).size(13).color(palette.text),
                    text(super::ellipsize(&alb.artist, 44)).size(11).color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .padding(12),
            )
            .width(Length::FillPortion(1))
            .on_press(on_open_album(id))
            .style(move |_t, s| button::Style {
                background: Some(
                    if s == button::Status::Hovered {
                        palette.surface_variant
                    } else {
                        palette.surface
                    }
                    .into(),
                ),
                border: iced::Border {
                    radius: 10.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            r = r.push(card);
        }
        grid = grid.push(r);
    }

    col = col.push(grid);
    col.into()
}

fn view_artists_tab<'a, Message: Clone + 'static>(
    artists: &'a [Artist],
    filter: &str,
    palette: HalcyonPalette,
    on_open_artist: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut col = column![].spacing(14).width(Length::Fill);

    let filtered: Vec<&Artist> = artists
        .iter()
        .filter(|a| filter.is_empty() || a.name.to_lowercase().contains(filter))
        .collect();

    col = col.push(
        text(format!("{} followed artists", filtered.len())).size(13).color(palette.text_muted),
    );

    let mut grid = column![].spacing(12);
    for chunk in filtered.chunks(4) {
        let mut r = row![].spacing(12).width(Length::Fill);
        for a in chunk {
            let id = a.id.clone();
            let card = button(
                column![
                    crate::art::cover(a.image_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 84.0, 42.0, Icon::Artist, &a.name, palette),
                    Space::with_height(10),
                    text(super::ellipsize(&a.name, 56)).size(13).color(palette.text),
                    text(if a.genres.is_empty() {
                        "Artist".to_string()
                    } else {
                        a.genres.join(", ")
                    })
                    .size(11)
                    .color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .padding(12),
            )
            .width(Length::FillPortion(1))
            .on_press(on_open_artist(id))
            .style(move |_t, s| button::Style {
                background: Some(
                    if s == button::Status::Hovered {
                        palette.surface_variant
                    } else {
                        palette.surface
                    }
                    .into(),
                ),
                border: iced::Border {
                    radius: 10.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            r = r.push(card);
        }
        grid = grid.push(r);
    }

    col = col.push(grid);
    col.into()
}
