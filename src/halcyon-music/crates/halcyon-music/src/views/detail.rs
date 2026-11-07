//! Detail pages for Albums, Artists, and Playlists.
//!
//! Provides comprehensive headers, track lists, Play All, Shuffle, and management controls.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, Density, HalcyonPalette};
use halcyon_music_core::models::{Album, Artist, Playlist, Track};
use iced::widget::{button, column, container, row, text, Space};
use iced::{Alignment, Element, Length};

#[allow(clippy::too_many_arguments)]
pub fn view_album<'a, Message: Clone + 'static>(
    album: &'a Album,
    tracks: &'a [Track],
    palette: HalcyonPalette,
    density: Density,
    on_back: Message,
    _on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_open_artist: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut page = column![].spacing(20).padding(24).width(Length::Fill);

    // Back button
    let back_btn = button(
        row![
            icon(Icon::ArrowLeft, 15.0, palette.text),
            Space::with_width(6),
            text("Back").size(13).color(palette.text),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_back)
    .padding([4, 10])
    .style(|_t, _s| button::Style::default());

    page = page.push(back_btn);

    // Album Header Card
    let play_all_tracks = tracks.to_vec();
    let play_all_btn = button(
        row![
            icon(Icon::Play, 15.0, palette.background),
            Space::with_width(6),
            text("Play All").size(13).color(palette.background),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_play_context(play_all_tracks, 0))
    .padding([8, 18])
    .style(move |_t, _s| button::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: 12.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    let header_card = row![
        crate::art::cover(album.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 140.0, 12.0, Icon::Album, &album.title, palette),
        Space::with_width(20),
        column![
            text("ALBUM").size(11).color(palette.accent),
            Space::with_height(4),
            text(&album.title).size(24).color(palette.text),
            Space::with_height(6),
            row![
                button(text(super::ellipsize(&album.artist, 44)).size(13).color(palette.text))
                    .on_press(on_open_artist(album.artist.clone()))
                    .padding(0)
                    .style(|_t, _s| button::Style::default()),
                Space::with_width(8),
                text("·").size(13).color(palette.text_muted),
                Space::with_width(8),
                text(album.release_date.as_deref().unwrap_or("Release date unknown"))
                    .size(13)
                    .color(palette.text_muted),
                Space::with_width(8),
                text("·").size(13).color(palette.text_muted),
                Space::with_width(8),
                text(format!("{} tracks", tracks.len()))
                    .size(13)
                    .color(palette.text_muted),
            ]
            .align_y(Alignment::Center),
            Space::with_height(14),
            play_all_btn,
        ],
    ]
    .align_y(Alignment::Center);

    page = page.push(header_card);
    page = page.push(Space::with_height(10));

    // Tracklist Table
    let mut track_list = column![].spacing(6).width(Length::Fill);
    let all_tracks = tracks.to_vec();

    for (idx, tr) in tracks.iter().enumerate() {
        let tracks_clone = all_tracks.clone();
        let item_btn = button(
            row![
                text(format!("{}", idx + 1)).size(12).color(palette.text_muted),
                Space::with_width(12),
                column![
                    text(super::ellipsize(&tr.title, 56)).size(13).color(palette.text),
                    text(super::ellipsize(&tr.artist, 44)).size(11).color(palette.text_muted),
                ]
                .width(Length::Fill),
                text(format_duration(tr.duration_ms)).size(12).color(palette.text_muted),
                Space::with_width(12),
                icon(Icon::Play, 15.0, palette.accent),
            ]
            .align_y(Alignment::Center)
            .padding([density.row_padding() / 2, 10]),
        )
        .width(Length::Fill)
        .on_press(on_play_context(tracks_clone, idx))
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

        track_list = track_list.push(item_btn);
    }

    page = page.push(track_list);

    container(page).width(Length::Fill).into()
}

#[allow(clippy::too_many_arguments)]
pub fn view_artist<'a, Message: Clone + 'static>(
    artist: &'a Artist,
    top_tracks: &'a [Track],
    albums: &'a [Album],
    palette: HalcyonPalette,
    density: Density,
    on_back: Message,
    _on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut page = column![].spacing(20).padding(24).width(Length::Fill);

    // Back button
    let back_btn = button(
        row![
            icon(Icon::ArrowLeft, 15.0, palette.text),
            Space::with_width(6),
            text("Back").size(13).color(palette.text),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_back)
    .padding([4, 10])
    .style(|_t, _s| button::Style::default());

    page = page.push(back_btn);

    // Artist Header
    let play_top_tracks = top_tracks.to_vec();
    let play_btn = button(
        row![
            icon(Icon::Play, 15.0, palette.background),
            Space::with_width(6),
            text("Play Top Tracks").size(13).color(palette.background),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_play_context(play_top_tracks, 0))
    .padding([8, 18])
    .style(move |_t, _s| button::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: 12.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    let header = row![
        crate::art::cover(artist.image_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 130.0, 65.0, Icon::Artist, &artist.name, palette),
        Space::with_width(20),
        column![
            text("ARTIST").size(11).color(palette.accent),
            Space::with_height(4),
            text(&artist.name).size(26).color(palette.text),
            Space::with_height(6),
            text(if artist.genres.is_empty() {
                "Spotify Verified Artist".to_string()
            } else {
                artist.genres.join(" · ")
            })
            .size(13)
            .color(palette.text_muted),
            Space::with_height(14),
            play_btn,
        ],
    ]
    .align_y(Alignment::Center);

    page = page.push(header);

    // Top Tracks Section
    if !top_tracks.is_empty() {
        let mut top_sec = column![
            text("Popular Tracks").size(18).color(palette.text),
            Space::with_height(10),
        ]
        .spacing(6);

        let all_tracks = top_tracks.to_vec();
        for (idx, tr) in top_tracks.iter().take(5).enumerate() {
            let tracks_clone = all_tracks.clone();
            let row_btn = button(
                row![
                    text(format!("{}", idx + 1)).size(12).color(palette.text_muted),
                    Space::with_width(12),
                    column![
                        text(super::ellipsize(&tr.title, 56)).size(13).color(palette.text),
                        text(super::ellipsize(&tr.album, 44)).size(11).color(palette.text_muted),
                    ]
                    .width(Length::Fill),
                    text(format_duration(tr.duration_ms)).size(12).color(palette.text_muted),
                    Space::with_width(12),
                    icon(Icon::Play, 15.0, palette.accent),
                ]
                .align_y(Alignment::Center)
                .padding([density.row_padding() / 2, 10]),
            )
            .width(Length::Fill)
            .on_press(on_play_context(tracks_clone, idx))
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

            top_sec = top_sec.push(row_btn);
        }
        page = page.push(top_sec);
    }

    // Discography / Albums Grid
    if !albums.is_empty() {
        let mut disco_sec = column![
            text("Discography").size(18).color(palette.text),
            Space::with_height(10),
        ]
        .spacing(12);

        let mut grid = column![].spacing(12);
        for chunk in albums.chunks(4) {
            let mut r = row![].spacing(12).width(Length::Fill);
            for alb in chunk {
                let alb_id = alb.id.clone();
                let card = button(
                    column![
                        crate::art::cover(alb.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 96.0, 8.0, Icon::Album, &alb.title, palette),
                        Space::with_height(8),
                        text(super::ellipsize(&alb.title, 56)).size(13).color(palette.text),
                        text(alb.release_date.as_deref().unwrap_or("Album"))
                            .size(11)
                            .color(palette.text_muted),
                    ]
                    .align_x(Alignment::Center)
                    .padding(10),
                )
                .width(Length::FillPortion(1))
                .on_press(on_open_album(alb_id))
                .style(move |_t, s| button::Style {
                    background: Some(
                        if s == button::Status::Hovered { crate::theme::mix(palette.surface, palette.accent, 0.16) } else { crate::theme::alpha(palette.surface, 0.62) }
                        .into(),
                    ),
                    border: iced::Border {
                        radius: 14.0.into(),
                        ..Default::default()
                    },
                    ..Default::default()
                });

                r = r.push(card);
            }
            grid = grid.push(r);
        }

        disco_sec = disco_sec.push(grid);
        page = page.push(disco_sec);
    }

    container(page).width(Length::Fill).into()
}

#[allow(clippy::too_many_arguments)]
pub fn view_playlist<'a, Message: Clone + 'static>(
    playlist: &'a Playlist,
    tracks: &'a [Track],
    palette: HalcyonPalette,
    density: Density,
    on_back: Message,
    _on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_delete_playlist: Message,
) -> Element<'a, Message> {
    let mut page = column![].spacing(20).padding(24).width(Length::Fill);

    // Back button
    let back_btn = button(
        row![
            icon(Icon::ArrowLeft, 15.0, palette.text),
            Space::with_width(6),
            text("Back").size(13).color(palette.text),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_back)
    .padding([4, 10])
    .style(|_t, _s| button::Style::default());

    page = page.push(back_btn);

    // Playlist Header Card
    let play_all_tracks = tracks.to_vec();
    let play_all_btn = button(
        row![
            icon(Icon::Play, 15.0, palette.background),
            Space::with_width(6),
            text("Play All").size(13).color(palette.background),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_play_context(play_all_tracks, 0))
    .padding([8, 18])
    .style(move |_t, _s| button::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: 12.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    let delete_btn = button(
        row![
            icon(Icon::Trash, 14.0, palette.text_muted),
            Space::with_width(6),
            text("Delete").size(12).color(palette.text_muted),
        ]
        .align_y(Alignment::Center),
    )
    .on_press(on_delete_playlist)
    .padding([6, 12])
    .style(|_t, _s| button::Style::default());

    let header_card = row![
        crate::art::cover(playlist.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 140.0, 12.0, Icon::Playlist, &playlist.name, palette),
        Space::with_width(20),
        column![
            text("PLAYLIST").size(11).color(palette.accent),
            Space::with_height(4),
            text(&playlist.name).size(24).color(palette.text),
            Space::with_height(6),
            text(format!("By {} · {} songs", playlist.owner, tracks.len()))
                .size(13)
                .color(palette.text_muted),
            Space::with_height(14),
            row![play_all_btn, Space::with_width(12), delete_btn].align_y(Alignment::Center),
        ],
    ]
    .align_y(Alignment::Center);

    page = page.push(header_card);
    page = page.push(Space::with_height(10));

    // Tracks Table
    let mut track_list = column![].spacing(6).width(Length::Fill);
    let all_tracks = tracks.to_vec();

    if tracks.is_empty() {
        track_list = track_list.push(
            container(
                text("This playlist is empty. Add tracks from Search or Home.")
                    .size(13)
                    .color(palette.text_muted),
            )
            .padding(20),
        );
    } else {
        for (idx, tr) in tracks.iter().enumerate() {
            let tracks_clone = all_tracks.clone();
            let item_btn = button(
                row![
                    text(format!("{}", idx + 1)).size(12).color(palette.text_muted),
                    Space::with_width(12),
                    column![
                        text(super::ellipsize(&tr.title, 56)).size(13).color(palette.text),
                        text(super::ellipsize(&tr.artist, 44)).size(11).color(palette.text_muted),
                    ]
                    .width(Length::FillPortion(2)),
                    text(super::ellipsize(&tr.album, 44))
                        .size(12)
                        .color(palette.text_muted)
                        .width(Length::FillPortion(2)),
                    text(format_duration(tr.duration_ms)).size(12).color(palette.text_muted),
                    Space::with_width(12),
                    icon(Icon::Play, 15.0, palette.accent),
                ]
                .align_y(Alignment::Center)
                .padding([density.row_padding() / 2, 10]),
            )
            .width(Length::Fill)
            .on_press(on_play_context(tracks_clone, idx))
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

            track_list = track_list.push(item_btn);
        }
    }

    page = page.push(track_list);

    container(page).width(Length::Fill).into()
}
