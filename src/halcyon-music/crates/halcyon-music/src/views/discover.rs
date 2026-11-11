//! Discover: new music. New releases from the artists you listen to, the latest popular releases
//! as a grid of cards, a song from each, what listeners play most this week, and "If you like ..."
//! mixes built from your artists, and mood and genre sections (Calm, Hip-Hop, Pop, ...).
//!
//! The daemon builds the page in stages, so a section may still be empty while it loads; the
//! status chip says so, and a section with nothing to show is left out rather than drawn empty.

use crate::icons::{icon, Icon};
use crate::theme::HalcyonPalette;
use halcyon_music_core::art::ArtSize;
use halcyon_music_core::models::{DiscoverFeed, MusicMix, ShelfItem, Track};
use iced::widget::{button, column, container, row, text, Space};
use iced::{Alignment, Element, Length};

const COVER: f32 = 132.0;
const PER_ROW: usize = 5;
const SONG_COVER: f32 = 44.0;

/// Main Discover page element builder.
#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    feed: &'a DiscoverFeed,
    loading: bool,
    palette: HalcyonPalette,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
    on_open_mix: impl Fn(String) -> Message + 'a + Copy,
    on_refresh: Message,
) -> Element<'a, Message> {
    let tint = if loading {
        palette.text_muted
    } else {
        palette.accent
    };
    let chip = container(
        row![
            icon(Icon::Sparkles, 12.0, tint),
            Space::with_width(6),
            text(if loading {
                "Finding new music…"
            } else {
                "Up to date"
            })
            .size(12)
            .color(tint),
        ]
        .align_y(Alignment::Center),
    )
    .padding([6, 14])
    .style(crate::views::chip(palette));

    let mut page = column![row![
        column![
            text("Discover").size(26).color(palette.text),
            text("New releases and fresh songs, picked from what is out now")
                .size(13)
                .color(palette.text_muted),
        ]
        .spacing(4),
        Space::with_width(Length::Fill),
        chip,
        Space::with_width(8),
        button(icon(Icon::Refresh, 14.0, tint))
            .on_press_maybe(if loading { None } else { Some(on_refresh) })
            .padding(8)
            .style(crate::views::ghost(palette)),
    ]
    .align_y(Alignment::Center)]
    .spacing(24)
    .padding([16, 24])
    .width(Length::Fill);

    let nothing_yet = feed.new_albums.is_empty()
        && feed.new_songs.is_empty()
        && feed.from_artists.is_empty()
        && feed.trending.is_empty()
        && feed.mixes.is_empty()
        && feed.genres.is_empty();
    if nothing_yet {
        page = page.push(
            text(if loading {
                "Looking for the newest releases. This takes a few seconds the first time."
            } else {
                "Could not reach the release sources just now. Check your connection and press Refresh."
            })
            .size(13)
            .color(palette.text_muted),
        );
        return page.into();
    }

    if !feed.from_artists.is_empty() {
        page = page.push(section(
            "New from your artists".to_string(),
            "Recent releases by the artists you listen to most".to_string(),
            album_grid(
                &feed.from_artists,
                palette,
                on_play_track,
                on_play_context,
                on_open_album,
            ),
            None,
            palette,
        ));
    }

    if !feed.new_albums.is_empty() {
        page = page.push(section(
            "Latest releases".to_string(),
            "The newest albums and singles people are playing".to_string(),
            album_grid(
                &feed.new_albums,
                palette,
                on_play_track,
                on_play_context,
                on_open_album,
            ),
            None,
            palette,
        ));
    }

    if !feed.new_songs.is_empty() {
        let play_all = on_play_context(feed.new_songs.clone(), 0);
        page = page.push(section(
            "New songs".to_string(),
            "A song from each fresh album".to_string(),
            song_list(&feed.new_songs, palette, on_play_context),
            Some(play_all),
            palette,
        ));
    }

    if !feed.trending.is_empty() {
        let play_all = on_play_context(feed.trending.clone(), 0);
        page = page.push(section(
            "Trending this week".to_string(),
            "What listeners are playing most right now".to_string(),
            song_list(&feed.trending, palette, on_play_context),
            Some(play_all),
            palette,
        ));
    }

    // Mood and genre playlists (Calm, Hip-Hop, ...): the best songs of each, one card per
    // playlist; a card opens the playlist page.
    if !feed.genres.is_empty() {
        page = page.push(section(
            "Genres and moods".to_string(),
            "The best songs of each sound, as playlists".to_string(),
            playlist_grid(&feed.genres, palette, on_open_mix),
            None,
            palette,
        ));
    }

    for mix in &feed.mixes {
        let play_all = on_play_context(mix.tracks.clone(), 0);
        page = page.push(section(
            mix.title.clone(),
            mix.description.clone(),
            song_list(&mix.tracks, palette, on_play_context),
            Some(play_all),
            palette,
        ));
    }

    page.into()
}

/// A titled block: heading, a line under it, an optional "Play all" button, then the content.
fn section<'a, Message: Clone + 'static>(
    title: String,
    subtitle: String,
    content: Element<'a, Message>,
    play_all: Option<Message>,
    palette: HalcyonPalette,
) -> Element<'a, Message> {
    let mut head = row![column![
        text(title).size(18).color(palette.text),
        text(subtitle).size(12).color(palette.text_muted),
    ]
    .spacing(2)]
    .align_y(Alignment::Center);

    if let Some(msg) = play_all {
        head = head.push(Space::with_width(Length::Fill)).push(
            button(
                row![
                    icon(Icon::Play, 13.0, palette.accent),
                    Space::with_width(6),
                    text("Play all").size(12).color(palette.accent),
                ]
                .align_y(Alignment::Center),
            )
            .padding([6, 12])
            .on_press(msg)
            .style(crate::views::ghost(palette)),
        );
    }

    column![head, content]
        .spacing(12)
        .width(Length::Fill)
        .into()
}

/// Playlist cards (cover, name, song count) in fixed-size rows; a press opens the playlist.
fn playlist_grid<'a, Message: Clone + 'static>(
    mixes: &'a [MusicMix],
    palette: HalcyonPalette,
    on_open_mix: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut grid = column![].spacing(14).width(Length::Fill);
    for chunk in mixes.chunks(PER_ROW) {
        let mut r = row![].spacing(14).width(Length::Fill);
        for mix in chunk {
            let card = button(
                column![
                    crate::art::cover(
                        mix.art_url.as_deref(),
                        ArtSize::Medium,
                        COVER,
                        14.0,
                        Icon::Music,
                        &mix.title,
                        palette,
                    ),
                    Space::with_height(8),
                    text(super::ellipsize(&mix.title, 22))
                        .size(13)
                        .color(palette.text),
                    text(format!("{} songs", mix.tracks.len()))
                        .size(11)
                        .color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .width(Length::Fill),
            )
            .width(Length::FillPortion(1))
            .padding(10)
            .on_press(on_open_mix(mix.id.clone()))
            .style(move |_t, s| button::Style {
                background: Some(
                    if s == button::Status::Hovered {
                        crate::theme::mix(palette.surface, palette.accent, 0.16)
                    } else {
                        crate::theme::alpha(palette.surface, 0.62)
                    }
                    .into(),
                ),
                border: iced::Border {
                    radius: 24.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            r = r.push(card);
        }
        for _ in chunk.len()..PER_ROW {
            r = r.push(Space::with_width(Length::FillPortion(1)));
        }
        grid = grid.push(r);
    }
    grid.into()
}

/// Cards in fixed-size rows, so the columns line up whatever the window width. A card whose
/// item is an album opens that album; one that only knows a song plays it.
fn album_grid<'a, Message: Clone + 'static>(
    items: &'a [ShelfItem],
    palette: HalcyonPalette,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_open_album: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut grid = column![].spacing(14).width(Length::Fill);
    for chunk in items.chunks(PER_ROW) {
        let mut r = row![].spacing(14).width(Length::Fill);
        for item in chunk {
            let press = if item.context_type == "album" {
                on_open_album(item.id.clone())
            } else if let Some(first) = item.tracks.first() {
                on_play_track(first.clone())
            } else {
                on_play_context(item.tracks.clone(), 0)
            };
            let card = button(
                column![
                    crate::art::cover(
                        item.art_url.as_deref(),
                        ArtSize::Medium,
                        COVER,
                        14.0,
                        Icon::Music,
                        &item.title,
                        palette,
                    ),
                    Space::with_height(8),
                    text(super::ellipsize(&item.title, 22))
                        .size(13)
                        .color(palette.text),
                    text(super::ellipsize(&item.subtitle, 26))
                        .size(11)
                        .color(palette.text_muted),
                ]
                .align_x(Alignment::Center)
                .width(Length::Fill),
            )
            .width(Length::FillPortion(1))
            .padding(10)
            .on_press(press)
            .style(move |_t, s| button::Style {
                background: Some(
                    if s == button::Status::Hovered {
                        crate::theme::mix(palette.surface, palette.accent, 0.16)
                    } else {
                        crate::theme::alpha(palette.surface, 0.62)
                    }
                    .into(),
                ),
                border: iced::Border {
                    radius: 24.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            r = r.push(card);
        }
        for _ in chunk.len()..PER_ROW {
            r = r.push(Space::with_width(Length::FillPortion(1)));
        }
        grid = grid.push(r);
    }
    grid.into()
}

/// Songs as rows (cover, title, artist and album); a press plays the list from that song.
fn song_list<'a, Message: Clone + 'static>(
    songs: &'a [Track],
    palette: HalcyonPalette,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut list = column![].spacing(4).width(Length::Fill);
    for (i, t) in songs.iter().enumerate() {
        let line = row![
            crate::art::cover(
                t.art_url.as_deref(),
                ArtSize::Small,
                SONG_COVER,
                9.0,
                Icon::Music,
                &t.title,
                palette
            ),
            Space::with_width(12),
            column![
                text(super::ellipsize(&t.title, 48))
                    .size(13)
                    .color(palette.text),
                text(super::ellipsize(&format!("{} • {}", t.artist, t.album), 64))
                    .size(11)
                    .color(palette.text_muted),
            ]
            .spacing(2)
            .width(Length::Fill),
            icon(Icon::Play, 13.0, palette.text_muted),
        ]
        .align_y(Alignment::Center)
        .width(Length::Fill);

        list = list.push(
            button(line)
                .width(Length::Fill)
                .padding([6, 10])
                .on_press(on_play_context(songs.to_vec(), i))
                .style(move |_t, s| button::Style {
                    background: Some(
                        if s == button::Status::Hovered {
                            crate::theme::mix(palette.surface, palette.accent, 0.16)
                        } else {
                            crate::theme::alpha(palette.surface, 0.0)
                        }
                        .into(),
                    ),
                    border: iced::Border {
                        radius: 18.0.into(),
                        ..Default::default()
                    },
                    ..Default::default()
                }),
        );
    }
    list.into()
}
