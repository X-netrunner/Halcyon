//! The "best results" list under the top search box. It fills in while you type, so you
//! can pick a song, artist, album or playlist without typing the whole name or opening
//! the full Search page.

use crate::icons::{icon, Icon};
use crate::theme::{radius, space, type_size, HalcyonPalette};
use halcyon_music_core::art::ArtSize;
use halcyon_music_core::models::{DetailedSearchResults, Track};
use iced::widget::{button, column, container, row, text, Space};
use iced::{Alignment, Element, Length};

pub const WIDTH: f32 = 560.0;
const ROW_H: f32 = 48.0;

const MAX_SONGS: usize = 4;
const MAX_ARTISTS: usize = 2;
const MAX_ALBUMS: usize = 2;
const MAX_PLAYLISTS: usize = 2;

/// What a row stands for.
#[derive(Debug, Clone)]
pub enum Pick {
    Track(Track),
    Artist(String),
    Album(String),
    Playlist(String),
}

struct Entry<'a> {
    pick: Pick,
    art: Option<&'a str>,
    size: ArtSize,
    fallback: Icon,
    title: String,
    subtitle: String,
    kind: &'static str,
    round: bool,
}

/// The rows to show, best first: an artist whose name is exactly what was typed leads,
/// then songs, artists, albums and playlists.
fn entries<'a>(query: &str, r: &'a DetailedSearchResults) -> Vec<Entry<'a>> {
    let q = query.trim().to_lowercase();
    let mut out: Vec<Entry<'a>> = Vec::new();

    let artist = |a: &'a halcyon_music_core::models::Artist| Entry {
        pick: Pick::Artist(a.id.clone()),
        art: a.image_url.as_deref(),
        size: ArtSize::Medium,
        fallback: Icon::Artist,
        title: a.name.clone(),
        subtitle: "Artist".to_string(),
        kind: "Artist",
        round: true,
    };

    // Index of the artist whose name is exactly what was typed; it leads the list and is
    // skipped when the remaining artists are added below.
    let exact_artist = r
        .artists
        .iter()
        .position(|a| a.name.trim().to_lowercase() == q);
    if let Some(a) = exact_artist.and_then(|i| r.artists.get(i)) {
        out.push(artist(a));
    }
    for t in r.tracks.iter().take(MAX_SONGS) {
        out.push(Entry {
            pick: Pick::Track(t.clone()),
            art: t.art_url.as_deref(),
            size: ArtSize::Small,
            fallback: Icon::Music,
            title: t.title.clone(),
            subtitle: t.artist.clone(),
            kind: "Song",
            round: false,
        });
    }
    for (i, a) in r.artists.iter().enumerate().take(MAX_ARTISTS + 1) {
        if Some(i) != exact_artist
            && out.iter().filter(|e| e.kind == "Artist").count() < MAX_ARTISTS
        {
            out.push(artist(a));
        }
    }
    for a in r.albums.iter().take(MAX_ALBUMS) {
        out.push(Entry {
            pick: Pick::Album(a.id.clone()),
            art: a.art_url.as_deref(),
            size: ArtSize::Medium,
            fallback: Icon::Album,
            title: a.title.clone(),
            subtitle: a.artist.clone(),
            kind: "Album",
            round: false,
        });
    }
    for p in r.playlists.iter().take(MAX_PLAYLISTS) {
        out.push(Entry {
            pick: Pick::Playlist(p.id.clone()),
            art: p.art_url.as_deref(),
            size: ArtSize::Medium,
            fallback: Icon::Playlist,
            title: p.name.clone(),
            subtitle: format!("By {}", p.owner),
            kind: "Playlist",
            round: false,
        });
    }
    out
}

fn note<'a, M: 'a>(label: String, pal: HalcyonPalette) -> Element<'a, M> {
    container(
        text(label)
            .size(type_size::SMALL + 1.0)
            .color(pal.text_muted),
    )
    .padding([space::MD, space::LG])
    .width(Length::Fill)
    .into()
}

pub fn view<'a, M: Clone + 'a>(
    query: &'a str,
    results: Option<&'a DetailedSearchResults>,
    pal: HalcyonPalette,
    on_pick: impl Fn(Pick) -> M + 'a + Copy,
    on_see_all: M,
) -> Element<'a, M> {
    let mut col = column![].width(Length::Fill);

    match results {
        None => col = col.push(note("Searching…".to_string(), pal)),
        Some(r) => {
            let list = entries(query, r);
            if list.is_empty() {
                col = col.push(note(
                    format!(
                        "No matches for \u{201C}{}\u{201D}",
                        super::ellipsize(query.trim(), 40)
                    ),
                    pal,
                ));
            }
            for e in list {
                let cover = crate::art::cover(
                    e.art,
                    e.size,
                    36.0,
                    if e.round { 18.0 } else { radius::SM },
                    e.fallback,
                    &e.title,
                    pal,
                );
                let line = row![
                    cover,
                    Space::with_width(space::MD),
                    column![
                        text(super::ellipsize(&e.title, 44))
                            .size(type_size::BODY)
                            .color(pal.text),
                        text(super::ellipsize(&e.subtitle, 48))
                            .size(type_size::SMALL)
                            .color(pal.text_muted),
                    ]
                    .spacing(2)
                    .width(Length::Fill),
                    text(e.kind).size(type_size::CAPTION).color(pal.text_muted),
                ]
                .align_y(Alignment::Center)
                .padding([0.0, space::MD]);

                col = col.push(
                    button(line)
                        .on_press(on_pick(e.pick))
                        .width(Length::Fill)
                        .height(ROW_H)
                        .padding(0)
                        .style(move |_t, status| {
                            let hovered =
                                matches!(status, button::Status::Hovered | button::Status::Pressed);
                            button::Style {
                                background: Some(
                                    if hovered {
                                        pal.surface_variant
                                    } else {
                                        iced::Color::TRANSPARENT
                                    }
                                    .into(),
                                ),
                                text_color: pal.text,
                                border: iced::Border {
                                    radius: radius::SM.into(),
                                    ..Default::default()
                                },
                                ..Default::default()
                            }
                        }),
                );
            }
        }
    }

    col = col.push(
        button(
            row![
                icon(Icon::Search, 14.0, pal.accent),
                Space::with_width(space::SM),
                text(format!(
                    "See all results for \u{201C}{}\u{201D}",
                    super::ellipsize(query.trim(), 36)
                ))
                .size(type_size::SMALL + 1.0)
                .color(pal.accent),
            ]
            .align_y(Alignment::Center),
        )
        .on_press(on_see_all)
        .width(Length::Fill)
        .padding([space::SM + 2.0, space::MD + 2.0])
        .style(move |_t, status| button::Style {
            background: Some(
                if matches!(status, button::Status::Hovered) {
                    pal.surface_variant
                } else {
                    iced::Color::TRANSPARENT
                }
                .into(),
            ),
            text_color: pal.accent,
            border: iced::Border {
                radius: radius::SM.into(),
                ..Default::default()
            },
            ..Default::default()
        }),
    );

    container(col)
        .width(WIDTH)
        .padding(space::XS)
        .style(move |_t| container::Style {
            background: Some(pal.surface.into()),
            border: iced::Border {
                color: pal.border,
                width: 1.0,
                radius: radius::MD.into(),
            },
            shadow: iced::Shadow {
                color: iced::Color {
                    a: 0.4,
                    ..iced::Color::BLACK
                },
                offset: iced::Vector::new(0.0, 6.0),
                blur_radius: 20.0,
            },
            ..Default::default()
        })
        .into()
}
