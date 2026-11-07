//! Home page view featuring dynamic greeting, quick picks, jump back in,
//! Made-for-You mixes with one-click play & save, shelves, and Capsule card.

use crate::icons::{icon, Icon};
use crate::theme::{Density, HalcyonPalette};
use crate::views::sidebar::NavPage;
use halcyon_music_core::models::{HomeFeed, MusicMix, QuickPick, ShelfItem, Track};
use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

/// Main Home page element builder.
#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    feed: &'a HomeFeed,
    palette: HalcyonPalette,
    density: Density,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_play_mix: impl Fn(Vec<Track>, String) -> Message + 'a + Copy,
    on_save_mix: impl Fn(String, Vec<String>) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
    shimmer: f32,
) -> Element<'a, Message> {
    let mut page = column![].spacing(28).padding([16, 24]);

    // 1. Dynamic Greeting
    let greeting_text = if feed.greeting.is_empty() {
        "Welcome to Halcyon Music"
    } else {
        &feed.greeting
    };

    page = page.push(
        row![
            column![
                text(greeting_text)
                    .size(density.heading_size() + 10.0)
                    .color(palette.text),
                text("Slow down. Let the music do the rest.")
                    .size(13)
                    .color(palette.text_muted),
            ]
            .spacing(4),
            Space::with_width(Length::Fill),
            // Quick Refresh / Status
            container(row![icon(Icon::Sparkles, 12.0, palette.accent), Space::with_width(6), text("Live Suggestions").size(12).color(palette.accent)].align_y(Alignment::Center))
                .padding([6, 14])
                .style(crate::views::chip(palette)),
        ]
        .align_y(Alignment::Center),
    );

    // Nothing has arrived yet: show grey placeholders instead of a blank page.
    if feed.quick_picks.is_empty() && feed.jump_back_in.is_empty() && feed.made_for_you.is_empty() {
        page = page.push(view_skeleton(palette, shimmer));
    }

    // 2. Greeting + Quick Picks Grid (6-8 big tiles)
    if !feed.quick_picks.is_empty() {
        page = page.push(view_quick_picks(
            &feed.quick_picks,
            palette,
            density,
            on_play_context,
            on_play_playlist,
            on_open_playlist,
            on_play_mix,
            on_navigate,
        ));
    }

    // 3. Jump Back In Shelf
    if !feed.jump_back_in.is_empty() {
        page = page.push(view_shelf(
            "Jump back in",
            "Pick up where you left off",
            &feed.jump_back_in,
            palette,
            on_play_track,
            on_play_context,
            on_play_playlist,
            on_open_playlist,
        ));
    }

    // 4. Made For You (Halcyon Suggestion Engine)
    if !feed.made_for_you.is_empty() {
        page = page.push(view_made_for_you_mixes(
            &feed.made_for_you,
            palette,
            density,
            on_play_mix,
            on_save_mix,
        ));
    }

    // 5. Popular Right Now (Global Charts)
    if !feed.popular_charts.is_empty() {
        page = page.push(view_shelf(
            "Popular right now",
            "Trending worldwide, resolved to Spotify",
            &feed.popular_charts,
            palette,
            on_play_track,
            on_play_context,
            on_play_playlist,
            on_open_playlist,
        ));
    }

    // 6. New from Artists You Follow
    if !feed.new_releases.is_empty() {
        page = page.push(view_shelf(
            "New from artists you follow",
            "Latest singles and albums from your favorite artists",
            &feed.new_releases,
            palette,
            on_play_track,
            on_play_context,
            on_play_playlist,
            on_open_playlist,
        ));
    }

    // 7. Fresh Releases (ListenBrainz)
    if !feed.fresh_releases.is_empty() {
        page = page.push(view_shelf(
            "Fresh releases you may like",
            "Curated by ListenBrainz explore engine",
            &feed.fresh_releases,
            palette,
            on_play_track,
            on_play_context,
            on_play_playlist,
            on_open_playlist,
        ));
    }

    // 8. Your Capsule Preview Card
    if let Some(ref capsule) = feed.capsule_preview {
        page = page.push(view_capsule_card(capsule, palette, on_navigate));
    }

    // Bottom breathing room
    page = page.push(Space::with_height(32));

    container(page).width(Length::Fill).into()
}

/// Grey blocks in the shape of the quick picks and one shelf.
fn view_skeleton<'a, Message: 'a>(palette: HalcyonPalette, shimmer: f32) -> Element<'a, Message> {
    // One slow breath: 0.45 -> 0.8 -> 0.45 opacity over the phase.
    let pulse = 0.45 + 0.35 * (0.5 + 0.5 * (shimmer * std::f32::consts::TAU).sin());
    fn block<'a, Message: 'a>(w: Length, h: f32, radius: f32, palette: HalcyonPalette, pulse: f32) -> Element<'a, Message> {
        container(Space::new(w, h))
            .style(move |_t| container::Style {
                background: Some(iced::Color { a: pulse, ..palette.surface_variant }.into()),
                border: iced::Border {
                    radius: radius.into(),
                    ..Default::default()
                },
                ..Default::default()
            })
            .into()
    }

    let mut tiles = column![].spacing(10);
    for _ in 0..2 {
        let mut r = row![].spacing(12).width(Length::Fill);
        for _ in 0..3 {
            r = r.push(block(Length::FillPortion(1), 64.0, 8.0, palette, pulse));
        }
        tiles = tiles.push(r);
    }

    let mut cards = row![].spacing(14);
    for _ in 0..6 {
        cards = cards.push(
            column![
                block(Length::Fixed(140.0), 140.0, 10.0, palette, pulse),
                block(Length::Fixed(100.0), 12.0, 4.0, palette, pulse),
                block(Length::Fixed(70.0), 10.0, 4.0, palette, pulse),
            ]
            .spacing(8),
        );
    }

    column![tiles, Space::with_height(8), block(Length::Fixed(160.0), 18.0, 4.0, palette, pulse), cards]
        .spacing(14)
        .into()
}

/// Quick Picks Grid: 2 rows of 3-4 tiles.
fn view_quick_picks<'a, Message: Clone + 'static>(
    picks: &'a [QuickPick],
    palette: HalcyonPalette,
    _density: Density,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_play_mix: impl Fn(Vec<Track>, String) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut grid = column![].spacing(10);
    let chunks: Vec<&[QuickPick]> = picks.chunks(3).collect();

    for row_picks in chunks.into_iter().take(2) {
        let mut r = row![].spacing(12).width(Length::Fill);
        for item in row_picks {
            let tracks = item.tracks.clone();
            let title = item.title.clone();

            let is_liked = item.id == "liked-songs";
            let is_mix = !is_liked && !tracks.is_empty();

            // Clicking the tile opens it (a playlist's song list, the Liked page); a mix has no
            // page, so it plays. The round play button always plays straight away.
            let open_msg = if is_liked {
                on_navigate(NavPage::Liked)
            } else if is_mix {
                on_play_mix(tracks.clone(), title.clone())
            } else {
                on_open_playlist(item.id.clone())
            };
            let play_msg = if is_liked {
                if tracks.is_empty() {
                    on_navigate(NavPage::Liked)
                } else {
                    on_play_context(tracks.clone(), 0)
                }
            } else if is_mix {
                on_play_mix(tracks, title)
            } else {
                on_play_playlist(item.id.clone())
            };

            let body_btn = button(
                row![
                    crate::art::cover(item.art_url.as_deref(), halcyon_music_core::art::ArtSize::Small, 52.0, 8.0, Icon::Music, &item.title, palette),
                    Space::with_width(12),
                    column![
                        text(super::ellipsize(&item.title, 30))
                            .size(13)
                            .color(palette.text),
                        text(super::ellipsize(&item.subtitle, 34))
                            .size(11)
                            .color(palette.text_muted),
                    ]
                    .width(Length::Fill),
                ]
                .align_y(Alignment::Center)
                .padding([6, 8]),
            )
            .width(Length::Fill)
            .on_press(open_msg)
            .style(move |_t, _s| button::Style::default());

            let play_btn = button(
                container(icon(Icon::Play, 16.0, palette.background))
                    .width(34)
                    .height(34)
                    .center_x(34)
                    .center_y(34),
            )
            .padding(0)
            .on_press(play_msg)
            .style(move |_t, s| button::Style {
                background: Some(palette.accent_background()),
                border: iced::Border { radius: 17.0.into(), ..Default::default() },
                ..Default::default()
            });

            let tile_btn = container(
                row![body_btn, play_btn, Space::with_width(12)].align_y(Alignment::Center),
            )
            .width(Length::FillPortion(1))
            .style(move |_t| container::Style {
                background: Some(palette.card_background()),
                border: iced::Border { radius: 12.0.into(), ..Default::default() },
                ..Default::default()
            });

            r = r.push(tile_btn);
        }
        // Keep a short last row the same tile width as the full rows.
        for _ in row_picks.len()..3 {
            r = r.push(Space::with_width(Length::FillPortion(1)));
        }
        grid = grid.push(r);
    }

    grid.into()
}

/// Horizontal shelf for Albums, Artists, Charts.
fn view_shelf<'a, Message: Clone + 'static>(
    header_title: &'static str,
    subtitle: &'static str,
    items: &'a [ShelfItem],
    palette: HalcyonPalette,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let header = column![
        text(header_title).size(18).color(palette.text),
        text(subtitle).size(12).color(palette.text_muted),
    ]
    .spacing(2);

    let mut cards_row = row![].spacing(14).padding([4, 0]);

    for item in items.iter().take(8) {
        let tracks = item.tracks.clone();
        let card_btn = button(
            column![
                // Artwork card
                crate::art::cover(item.art_url.as_deref(), halcyon_music_core::art::ArtSize::Medium, 140.0, 10.0, Icon::Music, &item.title, palette),
                Space::with_height(8),
                text(super::ellipsize(&item.title, 17))
                    .size(13)
                    .color(palette.text),
                text(super::ellipsize(&item.subtitle, 20))
                    .size(11)
                    .color(palette.text_muted),
            ]
            .width(140),
        )
        .padding(8)
        .on_press(if item.context_type == "playlist" {
            on_open_playlist(item.id.clone())
        } else if tracks.len() > 1 {
            on_play_context(tracks, 0)
        } else if let Some(first) = tracks.first() {
            on_play_track(first.clone())
        } else {
            on_play_context(tracks, 0)
        })
        .style(move |_t, s| button::Style {
            background: Some(
                if s == button::Status::Hovered { crate::theme::mix(palette.surface, palette.accent, 0.16) } else { crate::theme::alpha(palette.surface, 0.62) }
                .into(),
            ),
            border: iced::Border {
                radius: 18.0.into(),
                ..Default::default()
            },
            ..Default::default()
        });

        if item.context_type == "playlist" {
            // A round play button over the cover starts the whole playlist.
            let play_btn = button(
                container(icon(Icon::Play, 16.0, palette.background))
                    .width(34)
                    .height(34)
                    .center_x(34)
                    .center_y(34),
            )
            .padding(0)
            .on_press(on_play_playlist(item.id.clone()))
            .style(move |_t, _s| button::Style {
                background: Some(palette.accent_background()),
                border: iced::Border { radius: 17.0.into(), ..Default::default() },
                ..Default::default()
            });
            cards_row = cards_row.push(iced::widget::stack![
                card_btn,
                container(play_btn)
                    .width(Length::Fill)
                    .height(Length::Fill)
                    .align_x(iced::alignment::Horizontal::Right)
                    .padding(iced::Padding { top: 104.0, right: 16.0, bottom: 0.0, left: 0.0 }),
            ]);
        } else {
            cards_row = cards_row.push(card_btn);
        }
    }

    let shelf_scroll = scrollable(cards_row).direction(scrollable::Direction::Horizontal(
        scrollable::Scrollbar::default(),
    ));

    column![header, Space::with_height(10), shelf_scroll]
        .spacing(4)
        .into()
}

/// Made-For-You Mixes shelf with One-Click Play & Save buttons.
fn view_made_for_you_mixes<'a, Message: Clone + 'static>(
    mixes: &'a [MusicMix],
    palette: HalcyonPalette,
    _density: Density,
    on_play_mix: impl Fn(Vec<Track>, String) -> Message + 'a + Copy,
    on_save_mix: impl Fn(String, Vec<String>) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let header = column![
        row![
            text("Made for you").size(18).color(palette.text),
            Space::with_width(8),
            text("by Halcyon").size(13).color(palette.accent),
        ]
        .align_y(Alignment::Center),
        text("Mixes generated by local listening history and open recommendations")
            .size(12)
            .color(palette.text_muted),
    ]
    .spacing(2);

    let mut mix_row = row![].spacing(16);

    for mix in mixes {
        let tracks = mix.tracks.clone();
        let track_count = tracks.len();
        let title_clone = mix.title.clone();
        let title_for_save = mix.title.clone();
        let uris: Vec<String> = tracks.iter().map(|t| t.uri.clone()).collect();

        // Source badge color
        let badge_bg = match mix.source.as_str() {
            "ListenBrainz" => Color::from_rgb8(235, 116, 52),
            "Deezer" => Color::from_rgb8(155, 89, 182),
            "Spotify" => Color::from_rgb8(30, 215, 96),
            _ => palette.accent,
        };

        let card = container(
            column![
                // Card header with source attribution badge
                row![
                    container(text(&mix.source).size(10).color(Color::WHITE))
                        .padding([2, 8])
                        .style(move |_t| container::Style {
                            background: Some(badge_bg.into()),
                            border: iced::Border {
                                radius: 14.0.into(),
                                ..Default::default()
                            },
                            ..Default::default()
                        }),
                    Space::with_width(Length::Fill),
                    text(format!("{track_count} tracks")).size(11).color(palette.text_muted),
                ]
                .align_y(Alignment::Center),
                Space::with_height(10),
                text(&mix.title).size(16).color(palette.text),
                Space::with_height(4),
                text(&mix.description)
                    .size(11)
                    .color(palette.text_muted),
                Space::with_height(14),
                // Action Buttons: Play Mix & Save as Playlist
                row![
                    button(
                        row![
                            icon(Icon::Play, 14.0, palette.background),
                            Space::with_width(6),
                            text("Play").size(12).color(palette.background),
                        ]
                        .align_y(Alignment::Center),
                    )
                    .on_press(on_play_mix(tracks, title_clone))
                    .padding([6, 14])
                    .style(move |_t, _s| button::Style {
                        background: Some(palette.accent_background()),
                        border: iced::Border {
                            radius: 20.0.into(),
                            ..Default::default()
                        },
                        ..Default::default()
                    }),
                    Space::with_width(8),
                    button(
                        row![
                            icon(Icon::Settings, 13.0, palette.text),
                            Space::with_width(6),
                            text("Save").size(12).color(palette.text),
                        ]
                        .align_y(Alignment::Center),
                    )
                    .on_press(on_save_mix(title_for_save, uris))
                    .padding([6, 12])
                    .style(move |_t, s| button::Style {
                        background: Some(
                            if s == button::Status::Hovered {
                                palette.surface_variant
                            } else {
                                palette.border
                            }
                            .into(),
                        ),
                        border: iced::Border {
                            radius: 20.0.into(),
                            ..Default::default()
                        },
                        ..Default::default()
                    }),
                ]
                .align_y(Alignment::Center),
            ]
            .width(220)
            .padding(14),
        )
        .style(move |_t| container::Style {
            background: Some(palette.card_background()),
            border: iced::Border {
                radius: 18.0.into(),
                width: 1.0,
                color: palette.soft_border(),
            },
            ..Default::default()
        });

        mix_row = mix_row.push(card);
    }

    let mix_scroll = scrollable(mix_row).direction(scrollable::Direction::Horizontal(
        scrollable::Scrollbar::default(),
    ));

    column![header, Space::with_height(12), mix_scroll]
        .spacing(4)
        .into()
}

/// Capsule Preview Card pointing to full Capsule in Part 6.
fn view_capsule_card<'a, Message: Clone + 'static>(
    capsule: &'a halcyon_music_core::models::CapsuleSummary,
    palette: HalcyonPalette,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let top_song_title = capsule
        .top_track
        .as_ref()
        .map(|t| t.title.as_str())
        .unwrap_or("None");
    let top_artist = capsule
        .top_artist
        .as_deref()
        .unwrap_or("Various Artists");

    container(
        row![
            // Left column: Icon & month
            container(icon(Icon::Chart, 32.0, palette.accent))
                .width(60)
                .height(60)
                .center_x(60)
                .center_y(60)
                .style(move |_t| container::Style {
                    background: Some(palette.surface_variant.into()),
                    border: iced::Border {
                        radius: 18.0.into(),
                        ..Default::default()
                    },
                    ..Default::default()
                }),
            Space::with_width(18),
            // Middle stats
            column![
                text(format!("Your Halcyon Capsule • {}", capsule.month_name))
                    .size(15)
                    .color(palette.text),
                Space::with_height(4),
                row![
                    text(format!("{} minutes listened", capsule.total_minutes))
                        .size(12)
                        .color(palette.accent),
                    text(" • ").size(12).color(palette.text_muted),
                    text(format!("{} plays", capsule.play_count))
                        .size(12)
                        .color(palette.text_muted),
                    text(" • Top song: ").size(12).color(palette.text_muted),
                    text(top_song_title).size(12).color(palette.text),
                    text(format!(" by {top_artist}")).size(12).color(palette.text_muted),
                ],
            ]
            .width(Length::Fill),
            // Right button
            button("Open Capsule")
                .on_press(on_navigate(NavPage::Capsule))
                .padding([8, 16])
                .style(move |_t, s| button::Style {
                    background: Some(
                        if s == button::Status::Hovered { crate::theme::mix(palette.surface, palette.accent, 0.16) } else { crate::theme::alpha(palette.surface, 0.62) }
                        .into(),
                    ),
                    border: iced::Border {
                        radius: 20.0.into(),
                        ..Default::default()
                    },
                    ..Default::default()
                }),
        ]
        .align_y(Alignment::Center)
        .padding(18),
    )
    .width(Length::Fill)
    .style(move |_t| container::Style {
        background: Some(palette.card_background()),
        border: iced::Border {
            radius: 20.0.into(),
            width: 1.0,
            color: palette.soft_border(),
        },
        ..Default::default()
    })
    .into()
}

use iced::Color;
