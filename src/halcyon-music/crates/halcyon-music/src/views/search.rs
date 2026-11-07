//! Search view with as-you-type debounced input, category tabs,
//! recent searches, pagination, and multi-entity results.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, Density, HalcyonPalette};
use halcyon_music_core::models::{Album, Artist, DetailedSearchResults, Playlist, Track};
use iced::widget::{button, column, container, row, text, text_input, Space};
use iced::{Alignment, Element, Length};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SearchCategory {
    #[default]
    Top,
    Songs,
    Artists,
    Albums,
    Playlists,
}

impl SearchCategory {
    pub fn all() -> &'static [SearchCategory] {
        &[
            SearchCategory::Top,
            SearchCategory::Songs,
            SearchCategory::Artists,
            SearchCategory::Albums,
            SearchCategory::Playlists,
        ]
    }

    pub fn label(&self) -> &'static str {
        match self {
            SearchCategory::Top => "Top Results",
            SearchCategory::Songs => "Songs",
            SearchCategory::Artists => "Artists",
            SearchCategory::Albums => "Albums",
            SearchCategory::Playlists => "Playlists",
        }
    }

    pub fn api_type(&self) -> &'static str {
        match self {
            SearchCategory::Top => "all",
            SearchCategory::Songs => "songs",
            SearchCategory::Artists => "artists",
            SearchCategory::Albums => "albums",
            SearchCategory::Playlists => "playlists",
        }
    }
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    query: &'a str,
    category: SearchCategory,
    results: Option<&'a DetailedSearchResults>,
    recent_searches: &'a [String],
    palette: HalcyonPalette,
    density: Density,
    on_search_input: impl Fn(String) -> Message + 'a,
    on_select_category: impl Fn(SearchCategory) -> Message + 'a + Copy,
    on_click_recent: impl Fn(String) -> Message + 'a + Copy,
    on_clear_recents: Message,
    on_load_more: Message,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_open_artist: impl Fn(String) -> Message + 'a + Copy,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut page = column![].spacing(16).padding(20).width(Length::Fill);

    // 1. Search Bar
    let input = text_input("Search songs, artists, albums, or playlists... (/ to focus)", query)
        .on_input(on_search_input)
        .padding(12)
        .size(15)
        .width(Length::Fill);

    let search_bar = container(
        row![
            icon(Icon::Search, 18.0, palette.accent),
            Space::with_width(10),
            input,
        ]
        .align_y(Alignment::Center),
    )
    .padding([4, 12])
    .style(move |_t| container::Style {
        background: Some(palette.surface.into()),
        border: iced::Border {
            color: palette.border,
            width: 1.0,
            radius: 10.0.into(),
        },
        ..Default::default()
    });

    page = page.push(search_bar);

    // 2. Recent searches chips (if present)
    if !recent_searches.is_empty() {
        let mut recents_row = row![
            text("Recent:").size(12).color(palette.text_muted),
            Space::with_width(8),
        ]
        .align_y(Alignment::Center)
        .spacing(8);

        for s in recent_searches.iter().take(6) {
            let s_cloned = s.clone();
            let chip = button(text(s).size(12).color(palette.text))
                .on_press(on_click_recent(s_cloned))
                .padding([4, 10])
                .style(move |_t, status| button::Style {
                    background: Some(
                        if status == button::Status::Hovered {
                            palette.surface_variant
                        } else {
                            palette.surface
                        }
                        .into(),
                    ),
                    border: iced::Border {
                        color: palette.border,
                        width: 0.5,
                        radius: 12.0.into(),
                    },
                    ..Default::default()
                });
            recents_row = recents_row.push(chip);
        }

        recents_row = recents_row.push(Space::with_width(Length::Fill));
        recents_row = recents_row.push(
            button(text("Clear").size(11).color(palette.text_muted))
                .on_press(on_clear_recents)
                .padding([2, 6])
                .style(|_t, _s| button::Style::default()),
        );

        page = page.push(recents_row);
    }

    // 3. Category Tabs
    let mut tabs_row = row![].spacing(8);
    for cat in SearchCategory::all() {
        let is_active = *cat == category;
        let tab_btn = button(text(cat.label()).size(13).color(if is_active {
            palette.background
        } else {
            palette.text
        }))
        .on_press(on_select_category(*cat))
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
    page = page.push(tabs_row);

    // 4. Results
    if let Some(res) = results {
        if res.tracks.is_empty()
            && res.artists.is_empty()
            && res.albums.is_empty()
            && res.playlists.is_empty()
        {
            page = page.push(
                container(
                    column![
                        Space::with_height(40),
                        text("No results found for \"{}\"",).size(16).color(palette.text),
                        Space::with_height(8),
                        text("Check your spelling or try different keywords.")
                            .size(13)
                            .color(palette.text_muted),
                    ]
                    .align_x(Alignment::Center),
                )
                .width(Length::Fill)
                .center_x(Length::Fill),
            );
        } else {
            match category {
                SearchCategory::Top => {
                    page = page.push(view_top_results(
                        res,
                        palette,
                        density,
                        on_play_track,
                        on_play_context,
                        on_open_artist,
                        on_open_album,
                        on_open_playlist,
                    ));
                }
                SearchCategory::Songs => {
                    page = page.push(view_songs_results(
                        &res.tracks,
                        res.total_tracks,
                        palette,
                        density,
                        on_play_track,
                        on_play_context,
                        on_load_more,
                    ));
                }
                SearchCategory::Artists => {
                    page = page.push(view_artists_results(
                        &res.artists,
                        res.total_artists,
                        palette,
                        on_open_artist,
                        on_load_more,
                    ));
                }
                SearchCategory::Albums => {
                    page = page.push(view_albums_results(
                        &res.albums,
                        res.total_albums,
                        palette,
                        on_open_album,
                        on_load_more,
                    ));
                }
                SearchCategory::Playlists => {
                    page = page.push(view_playlists_results(
                        &res.playlists,
                        res.total_playlists,
                        palette,
                        on_open_playlist,
                        on_load_more,
                    ));
                }
            }
        }
    } else {
        page = page.push(
            container(
                column![
                    Space::with_height(60),
                    icon(Icon::Search, 48.0, palette.text_muted),
                    Space::with_height(16),
                    text("Search for songs, artists, albums, or playlists")
                        .size(16)
                        .color(palette.text),
                    Space::with_height(6),
                    text("Press / anytime to quickly focus search.")
                        .size(13)
                        .color(palette.text_muted),
                ]
                .align_x(Alignment::Center),
            )
            .width(Length::Fill)
            .center_x(Length::Fill),
        );
    }

    container(page).width(Length::Fill).into()
}

#[allow(clippy::too_many_arguments)]
fn view_top_results<'a, Message: Clone + 'static>(
    res: &'a DetailedSearchResults,
    palette: HalcyonPalette,
    density: Density,
    _on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_open_artist: impl Fn(String) -> Message + 'a + Copy,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut col = column![].spacing(24).width(Length::Fill);

    // 1. Top Songs
    if !res.tracks.is_empty() {
        let mut songs_sec = column![
            text("Songs").size(16).color(palette.text),
            Space::with_height(8),
        ]
        .spacing(6);

        let tracks_slice = res.tracks.get(..res.tracks.len().min(5)).unwrap_or(&res.tracks);
        for (i, t) in tracks_slice.iter().enumerate() {
            let all_tracks = res.tracks.clone();

            let row_btn = button(
                row![
                    text(format!("{}", i + 1)).size(12).color(palette.text_muted),
                    Space::with_width(12),
                    crate::art::cover(t.art_url.as_deref(), halcyon_music_core::art::ArtSize::Small, 36.0, 6.0, Icon::Music, &t.title, palette),
                    Space::with_width(12),
                    column![
                        text(super::ellipsize(&t.title, 56)).size(13).color(palette.text),
                        text(super::ellipsize(&t.artist, 44)).size(11).color(palette.text_muted),
                    ]
                    .width(Length::FillPortion(2)),
                    text(super::ellipsize(&t.album, 44))
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
            .on_press(on_play_context(all_tracks, i))
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

            songs_sec = songs_sec.push(row_btn);
        }
        col = col.push(songs_sec);
    }

    // 2. Top Artists
    if !res.artists.is_empty() {
        let mut artists_sec = column![
            text("Artists").size(16).color(palette.text),
            Space::with_height(8),
        ]
        .spacing(8);

        let mut artists_row = row![].spacing(14).width(Length::Fill);
        for a in res.artists.iter().take(4) {
            let id = a.id.clone();
            let card = button(
                column![
                    crate::art::cover(a.image_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 72.0, 36.0, Icon::Artist, &a.name, palette),
                    Space::with_height(8),
                    text(super::ellipsize(&a.name, 56)).size(13).color(palette.text),
                    text("Artist").size(11).color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .padding(10),
            )
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
            artists_row = artists_row.push(card);
        }
        artists_sec = artists_sec.push(artists_row);
        col = col.push(artists_sec);
    }

    // 3. Top Albums
    if !res.albums.is_empty() {
        let mut albums_sec = column![
            text("Albums").size(16).color(palette.text),
            Space::with_height(8),
        ]
        .spacing(8);

        let mut albums_row = row![].spacing(14).width(Length::Fill);
        for alb in res.albums.iter().take(4) {
            let id = alb.id.clone();
            let card = button(
                column![
                    crate::art::cover(alb.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 84.0, 8.0, Icon::Album, &alb.title, palette),
                    Space::with_height(8),
                    text(super::ellipsize(&alb.title, 56)).size(13).color(palette.text),
                    text(super::ellipsize(&alb.artist, 44)).size(11).color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .padding(10)
                .width(104),
            )
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
            albums_row = albums_row.push(card);
        }
        albums_sec = albums_sec.push(albums_row);
        col = col.push(albums_sec);
    }

    // 4. Top Playlists
    if !res.playlists.is_empty() {
        let mut pl_sec = column![
            text("Playlists").size(16).color(palette.text),
            Space::with_height(8),
        ]
        .spacing(8);

        let mut pl_row = row![].spacing(14).width(Length::Fill);
        for pl in res.playlists.iter().take(4) {
            let id = pl.id.clone();
            let card = button(
                column![
                    crate::art::cover(pl.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 84.0, 8.0, Icon::Playlist, &pl.name, palette),
                    Space::with_height(8),
                    text(super::ellipsize(&pl.name, 56)).size(13).color(palette.text),
                    text(super::ellipsize(&pl.owner, 44)).size(11).color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .padding(10)
                .width(104),
            )
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
                    radius: 10.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            pl_row = pl_row.push(card);
        }
        pl_sec = pl_sec.push(pl_row);
        col = col.push(pl_sec);
    }

    col.into()
}

fn view_songs_results<'a, Message: Clone + 'static>(
    tracks: &'a [Track],
    total: usize,
    palette: HalcyonPalette,
    density: Density,
    _on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_load_more: Message,
) -> Element<'a, Message> {
    let mut col = column![].spacing(6).width(Length::Fill);

    for (i, t) in tracks.iter().enumerate() {
        let all_tracks = tracks.to_vec();
        let row_btn = button(
            row![
                text(format!("{}", i + 1)).size(12).color(palette.text_muted),
                Space::with_width(12),
                crate::art::cover(t.art_url.as_deref(), halcyon_music_core::art::ArtSize::Small, 36.0, 6.0, Icon::Music, &t.title, palette),
                Space::with_width(12),
                column![
                    text(super::ellipsize(&t.title, 56)).size(13).color(palette.text),
                    text(super::ellipsize(&t.artist, 44)).size(11).color(palette.text_muted),
                ]
                .width(Length::FillPortion(2)),
                text(super::ellipsize(&t.album, 44))
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
        .on_press(on_play_context(all_tracks, i))
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

    if total > tracks.len() {
        let load_more_btn = button(
            row![
                text("Load More Songs").size(13).color(palette.text),
                Space::with_width(6),
                text(format!("({}/{})", tracks.len(), total)).size(11).color(palette.text_muted),
            ]
            .align_y(Alignment::Center),
        )
        .on_press(on_load_more)
        .padding([8, 16])
        .style(move |_t, _s| button::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                radius: 8.0.into(),
                ..Default::default()
            },
            ..Default::default()
        });

        col = col.push(
            container(load_more_btn)
                .width(Length::Fill)
                .center_x(Length::Fill)
                .padding(16),
        );
    }

    col.into()
}

fn view_artists_results<'a, Message: Clone + 'static>(
    artists: &'a [Artist],
    total: usize,
    palette: HalcyonPalette,
    on_open_artist: impl Fn(String) -> Message + 'a + Copy,
    on_load_more: Message,
) -> Element<'a, Message> {
    let mut col = column![].spacing(16).width(Length::Fill);
    let mut grid = column![].spacing(12);

    for chunk in artists.chunks(4) {
        let mut r = row![].spacing(12).width(Length::Fill);
        for a in chunk {
            let id = a.id.clone();
            let card = button(
                column![
                    crate::art::cover(a.image_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 84.0, 42.0, Icon::Artist, &a.name, palette),
                    Space::with_height(10),
                    text(super::ellipsize(&a.name, 56)).size(14).color(palette.text),
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
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            r = r.push(card);
        }
        grid = grid.push(r);
    }
    col = col.push(grid);

    if total > artists.len() {
        let load_more_btn = button(
            row![
                text("Load More Artists").size(13).color(palette.text),
                Space::with_width(6),
                text(format!("({}/{})", artists.len(), total)).size(11).color(palette.text_muted),
            ]
            .align_y(Alignment::Center),
        )
        .on_press(on_load_more)
        .padding([8, 16])
        .style(move |_t, _s| button::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                radius: 8.0.into(),
                ..Default::default()
            },
            ..Default::default()
        });

        col = col.push(
            container(load_more_btn)
                .width(Length::Fill)
                .center_x(Length::Fill)
                .padding(16),
        );
    }

    col.into()
}

fn view_albums_results<'a, Message: Clone + 'static>(
    albums: &'a [Album],
    total: usize,
    palette: HalcyonPalette,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
    on_load_more: Message,
) -> Element<'a, Message> {
    let mut col = column![].spacing(16).width(Length::Fill);
    let mut grid = column![].spacing(12);

    for chunk in albums.chunks(4) {
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
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            r = r.push(card);
        }
        grid = grid.push(r);
    }
    col = col.push(grid);

    if total > albums.len() {
        let load_more_btn = button(
            row![
                text("Load More Albums").size(13).color(palette.text),
                Space::with_width(6),
                text(format!("({}/{})", albums.len(), total)).size(11).color(palette.text_muted),
            ]
            .align_y(Alignment::Center),
        )
        .on_press(on_load_more)
        .padding([8, 16])
        .style(move |_t, _s| button::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                radius: 8.0.into(),
                ..Default::default()
            },
            ..Default::default()
        });

        col = col.push(
            container(load_more_btn)
                .width(Length::Fill)
                .center_x(Length::Fill)
                .padding(16),
        );
    }

    col.into()
}

fn view_playlists_results<'a, Message: Clone + 'static>(
    playlists: &'a [Playlist],
    total: usize,
    palette: HalcyonPalette,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_load_more: Message,
) -> Element<'a, Message> {
    let mut col = column![].spacing(16).width(Length::Fill);
    let mut grid = column![].spacing(12);

    for chunk in playlists.chunks(4) {
        let mut r = row![].spacing(12).width(Length::Fill);
        for pl in chunk {
            let id = pl.id.clone();
            let card = button(
                column![
                    crate::art::cover(pl.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 96.0, 8.0, Icon::Playlist, &pl.name, palette),
                    Space::with_height(10),
                    text(super::ellipsize(&pl.name, 56)).size(13).color(palette.text),
                    text(super::ellipsize(&pl.owner, 44)).size(11).color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .padding(12),
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
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            r = r.push(card);
        }
        grid = grid.push(r);
    }
    col = col.push(grid);

    if total > playlists.len() {
        let load_more_btn = button(
            row![
                text("Load More Playlists").size(13).color(palette.text),
                Space::with_width(6),
                text(format!("({}/{})", playlists.len(), total)).size(11).color(palette.text_muted),
            ]
            .align_y(Alignment::Center),
        )
        .on_press(on_load_more)
        .padding([8, 16])
        .style(move |_t, _s| button::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                radius: 8.0.into(),
                ..Default::default()
            },
            ..Default::default()
        });

        col = col.push(
            container(load_more_btn)
                .width(Length::Fill)
                .center_x(Length::Fill)
                .padding(16),
        );
    }

    col.into()
}
