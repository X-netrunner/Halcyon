//! Home page view featuring dynamic greeting, quick picks, jump back in,
//! Made-for-You mixes with one-click play & save, shelves, and Capsule card.

use crate::icons::{icon, Icon};
use crate::theme::{Density, HalcyonPalette};
use crate::views::sidebar::NavPage;
use halcyon_music_core::models::{HomeFeed, MusicMix, QuickPick, ShelfItem, Track};
use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

/// What the suggestions on Home are doing, shown in the chip at the top right.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HomeStatus {
    /// A feed is being built right now.
    Loading,
    /// Everything that could load has loaded.
    Live,
    /// Only the local mixes are in; the rest is still on its way (a retry is scheduled).
    Partial,
    /// As Partial, and Spotify is rate limiting.
    WaitingOnSpotify,
}

fn status_chip<'a, Message: 'a>(
    status: HomeStatus,
    shimmer: f32,
    palette: HalcyonPalette,
) -> Element<'a, Message> {
    let (label, tint) = match status {
        HomeStatus::Loading => {
            let pulse = 0.55 + 0.45 * (0.5 + 0.5 * (shimmer * std::f32::consts::TAU).sin());
            (
                "Getting fresh suggestions…",
                crate::theme::alpha(palette.accent, pulse),
            )
        }
        HomeStatus::Live => ("Live Suggestions", palette.accent),
        HomeStatus::Partial => ("More suggestions on the way", palette.text_muted),
        HomeStatus::WaitingOnSpotify => ("Spotify is busy, retrying soon", palette.text_muted),
    };
    container(
        row![
            icon(Icon::Sparkles, 12.0, tint),
            Space::with_width(6),
            text(label).size(12).color(tint)
        ]
        .align_y(Alignment::Center),
    )
    .padding([6, 14])
    .style(crate::views::chip(palette))
    .into()
}

/// What the three small buttons under a generated mix say.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MixAction {
    Refresh,
    LessLikeThis,
    NotMyTaste,
}

/// The mixes the daemon builds on a schedule (Part 6) can be refreshed and judged.
pub fn is_generated_mix(id: &str) -> bool {
    id.starts_with("daily-mix-")
        || matches!(
            id,
            "discover-weekly" | "release-radar" | "on-repeat" | "repeat-rewind" | "daylist"
        )
}

const MIX_ACTION_H: f32 = 20.0;

/// The daemon sends the full current set of generated mixes: they replace the generated mixes on
/// Home (also ones that no longer exist, such as a Daily Mix whose cluster went away) and go in
/// front; every other mix stays where it was.
pub fn merge_generated(
    feed: &mut HomeFeed,
    mixes: Vec<MusicMix>,
    meta: Vec<halcyon_music_core::models::MixMeta>,
) {
    let mut all = mixes;
    feed.made_for_you.retain(|m| !is_generated_mix(&m.id));
    all.append(&mut feed.made_for_you);
    feed.made_for_you = all;
    feed.mix_meta = meta;
}

/// Which shelves Home shows (Spotify's chips row at the top of Home).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HomeFilter {
    #[default]
    All,
    /// Your music: Liked Songs, quick picks, jump back in, the mixes made for you.
    Music,
    /// New music: Discover, popular right now, new and fresh releases.
    New,
}

/// A block of the Home page, for deciding what a filter shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Section {
    LikedPin,
    QuickPicks,
    JumpBackIn,
    MadeForYou,
    Discover,
    Charts,
    NewReleases,
    FreshReleases,
    Capsule,
}

impl HomeFilter {
    pub const ALL: [HomeFilter; 3] = [HomeFilter::All, HomeFilter::Music, HomeFilter::New];

    pub fn label(&self) -> &'static str {
        match self {
            HomeFilter::All => "All",
            HomeFilter::Music => "Music",
            HomeFilter::New => "New",
        }
    }

    pub fn shows(&self, section: Section) -> bool {
        use Section::*;
        match self {
            HomeFilter::All => true,
            HomeFilter::Music => matches!(
                section,
                LikedPin | QuickPicks | JumpBackIn | MadeForYou | Capsule
            ),
            HomeFilter::New => matches!(section, Discover | Charts | NewReleases | FreshReleases),
        }
    }
}

/// The chips row: one pill per filter, the chosen one filled with the accent.
fn filter_chips<'a, Message: Clone + 'static>(
    current: HomeFilter,
    palette: HalcyonPalette,
    on_filter: impl Fn(HomeFilter) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut r = row![].spacing(8).align_y(Alignment::Center);
    for f in HomeFilter::ALL {
        let chosen = f == current;
        r = r.push(
            button(text(f.label()).size(13).color(if chosen {
                palette.on_accent()
            } else {
                palette.text
            }))
            .padding([6, 16])
            .on_press(on_filter(f))
            .style(move |_t, s| button::Style {
                background: Some(if chosen {
                    palette.accent_background()
                } else if s == button::Status::Hovered {
                    crate::theme::alpha(palette.accent, 0.20).into()
                } else {
                    crate::theme::alpha(palette.text, 0.07).into()
                }),
                border: iced::Border {
                    radius: 999.0.into(),
                    width: 1.0,
                    color: crate::theme::alpha(palette.border, if chosen { 0.0 } else { 0.25 }),
                },
                ..Default::default()
            }),
        );
    }
    r.into()
}

/// Main Home page element builder.
#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    feed: &'a HomeFeed,
    palette: HalcyonPalette,
    density: Density,
    liked_tracks: &'a [Track],
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_play_mix: impl Fn(Vec<Track>, String) -> Message + 'a + Copy,
    on_save_mix: impl Fn(String, Vec<String>) -> Message + 'a + Copy,
    on_open_mix: impl Fn(String) -> Message + 'a + Copy,
    on_mix_action: impl Fn(String, MixAction) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
    shimmer: f32,
    progress: f32,
    clock: f32,
    status: HomeStatus,
    on_refresh: Message,
    filter: HomeFilter,
    on_filter: impl Fn(HomeFilter) -> Message + 'a + Copy,
    prompt_card: Element<'a, Message>,
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
            column![text(greeting_text)
                .size(density.heading_size() + 10.0)
                .color(palette.text),]
            .spacing(4),
            Space::with_width(Length::Fill),
            // Status of the suggestions, with a refresh button next to it.
            status_chip(status, shimmer, palette),
            Space::with_width(8),
            button(icon(
                Icon::Refresh,
                14.0,
                if status == HomeStatus::Loading {
                    palette.text_muted
                } else {
                    palette.accent
                }
            ))
            .on_press_maybe(if status == HomeStatus::Loading {
                None
            } else {
                Some(on_refresh.clone())
            })
            .padding(8)
            .style(crate::views::ghost(palette)),
        ]
        .align_y(Alignment::Center),
    );

    page = page.push(filter_chips(filter, palette, on_filter));

    // "Describe a mood" (Smart suggestions): a text box, a one-line status and, once there is one,
    // the mix it made. Its height does not change while it works.
    page = page.push(prompt_card);

    // Liked Songs is a playlist that is always pinned to the top of Home.
    if filter.shows(Section::LikedPin) {
        page = page.push(view_liked_pin(
            liked_tracks,
            palette,
            on_play_context,
            on_navigate,
        ));
    }

    // Nothing has arrived yet: show grey placeholders instead of a blank page.
    if feed.quick_picks.is_empty() && feed.jump_back_in.is_empty() && feed.made_for_you.is_empty() {
        page = page.push(view_skeleton(palette, shimmer));
    }

    // 2. Greeting + Quick Picks Grid (6-8 big tiles)
    if filter.shows(Section::QuickPicks) && !feed.quick_picks.is_empty() {
        page = page.push(view_quick_picks(
            &feed.quick_picks,
            palette,
            density,
            on_play_context,
            on_play_playlist,
            on_open_playlist,
            on_play_mix,
            on_open_mix,
            on_navigate,
        ));
    }

    // 3. Jump Back In Shelf
    if filter.shows(Section::JumpBackIn) && !feed.jump_back_in.is_empty() {
        page = page.push(view_feed_shelf(
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

    // 4. Made For You: mixes built from your own library and listening
    let personal: Vec<&MusicMix> = feed
        .made_for_you
        .iter()
        .filter(|m| m.source == "Halcyon Local")
        .collect();
    let outside: Vec<&MusicMix> = feed
        .made_for_you
        .iter()
        .filter(|m| m.source != "Halcyon Local")
        .collect();
    if filter.shows(Section::MadeForYou) && !personal.is_empty() {
        page = page.push(view_made_for_you_mixes(
            personal,
            "Made for you",
            "by Halcyon",
            "Picked by Halcyon from what you really play, blended with new music in your sound",
            palette,
            density,
            on_play_mix,
            on_save_mix,
            on_open_mix,
            on_mix_action,
            progress,
            clock,
        ));
    }

    // 5. Discover: new music and what everyone is playing
    let has_discover = !outside.is_empty()
        || !feed.popular_charts.is_empty()
        || !feed.new_releases.is_empty()
        || !feed.fresh_releases.is_empty();
    if filter.shows(Section::Discover) && !outside.is_empty() {
        page = page.push(view_made_for_you_mixes(
            outside,
            "Discover",
            "new and famous",
            "Trending this week, chart toppers, all-time greats and the freshest releases",
            palette,
            density,
            on_play_mix,
            on_save_mix,
            on_open_mix,
            on_mix_action,
            progress,
            clock,
        ));
    } else if filter.shows(Section::Discover)
        && (!feed.made_for_you.is_empty() || !feed.jump_back_in.is_empty())
    {
        // Nothing from outside yet: say so, so the gap does not look like a bug.
        let note = match status {
            HomeStatus::Loading => "Looking for new and popular music…",
            HomeStatus::WaitingOnSpotify => {
                "Spotify is busy. Discover will fill in on its own shortly."
            }
            _ => "New and popular music will show up here as soon as it has loaded.",
        };
        if !has_discover {
            page = page.push(
                column![
                    row![
                        icon(Icon::Sparkles, 16.0, palette.accent),
                        Space::with_width(8),
                        text("Discover").size(18).color(palette.text),
                    ]
                    .align_y(Alignment::Center),
                    text(note).size(12).color(palette.text_muted),
                ]
                .spacing(4),
            );
        }
    }

    // Discover shelves (global charts, fresh releases)
    if filter.shows(Section::Charts) && !feed.popular_charts.is_empty() {
        page = page.push(view_feed_shelf(
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
    if filter.shows(Section::NewReleases) && !feed.new_releases.is_empty() {
        page = page.push(view_feed_shelf(
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
    if filter.shows(Section::FreshReleases) && !feed.fresh_releases.is_empty() {
        page = page.push(view_feed_shelf(
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
    if let Some(capsule) = feed
        .capsule_preview
        .as_ref()
        .filter(|_| filter.shows(Section::Capsule))
    {
        page = page.push(view_capsule_card(capsule, palette, on_navigate));
    }

    // The New chip with nothing to show: one line and one action, not a blank page.
    if filter == HomeFilter::New && !has_discover {
        page = page.push(crate::views::empty_state(
            Icon::Sparkles,
            "Nothing new has loaded yet.",
            Some(("Refresh", on_refresh.clone())),
            palette,
        ));
    }

    // Bottom breathing room
    page = page.push(Space::with_height(32));

    container(page).width(Length::Fill).into()
}

/// The Home page of the Dock layout: the greeting, Liked Songs as a large heart cover with a round
/// play and a round shuffle button (icons only), and one "Recent" shelf. Nothing else: no filter
/// chips, no status line, no sub-lines. The "Describe a mood" card stays below, so that feature is
/// not lost. The refresh button is a plain muted icon beside the greeting.
#[allow(clippy::too_many_arguments)]
pub fn view_dock<'a, Message: Clone + 'static>(
    feed: &'a HomeFeed,
    palette: HalcyonPalette,
    density: Density,
    liked: &'a [Track],
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
    on_shuffle_liked: Message,
    on_refresh: Message,
    loading: bool,
    shimmer: f32,
    prompt_card: Element<'a, Message>,
) -> Element<'a, Message> {
    view_shelf(
        true,
        feed,
        palette,
        density,
        liked,
        on_play_track,
        on_play_context,
        on_play_playlist,
        on_open_playlist,
        on_navigate,
        on_shuffle_liked,
        on_refresh,
        loading,
        shimmer,
        prompt_card,
    )
}

/// The calm Home of the Top tabs and Library list layouts: the greeting, then (Top tabs only,
/// `with_hero`) the Liked Songs hero, then one shelf, "Recent". It is the Dock layout's Home;
/// Library list leaves the hero out ("greeting and one shelf"). The "Describe a mood" card stays
/// below, so that feature is not lost.
#[allow(clippy::too_many_arguments)]
pub fn view_shelf<'a, Message: Clone + 'static>(
    with_hero: bool,
    feed: &'a HomeFeed,
    palette: HalcyonPalette,
    density: Density,
    liked: &'a [Track],
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
    on_shuffle_liked: Message,
    on_refresh: Message,
    loading: bool,
    shimmer: f32,
    prompt_card: Element<'a, Message>,
) -> Element<'a, Message> {
    let mut page = column![].spacing(28).padding([16, 24]);

    page = page.push(greeting_row(feed, palette, density, loading, on_refresh));

    if with_hero {
        page = page.push(dock_hero(
            liked,
            palette,
            on_play_context,
            on_navigate,
            on_shuffle_liked,
        ));
    }

    if feed.quick_picks.is_empty() && feed.jump_back_in.is_empty() && feed.made_for_you.is_empty() {
        page = page.push(view_skeleton(palette, shimmer));
    }
    if !feed.jump_back_in.is_empty() {
        page = page.push(view_shelf_with(
            true,
            "Recent",
            "",
            &feed.jump_back_in,
            palette,
            on_play_track,
            on_play_context,
            on_play_playlist,
            on_open_playlist,
        ));
    }

    page = page.push(prompt_card);
    page = page.push(Space::with_height(32));
    container(page).width(Length::Fill).into()
}

/// The greeting with the refresh button (a plain muted icon) at the right. Shared by the Dock and
/// Player panel Home pages.
fn greeting_row<'a, Message: Clone + 'a>(
    feed: &'a HomeFeed,
    palette: HalcyonPalette,
    density: Density,
    loading: bool,
    on_refresh: Message,
) -> Element<'a, Message> {
    let greeting = if feed.greeting.is_empty() {
        "Welcome to Halcyon Music"
    } else {
        &feed.greeting
    };
    row![
        text(greeting)
            .size(density.heading_size() + 10.0)
            .color(palette.text),
        Space::with_width(Length::Fill),
        button(icon(Icon::Refresh, 14.0, palette.text_muted))
            .on_press_maybe((!loading).then_some(on_refresh))
            .padding(8)
            .style(crate::views::ghost(palette)),
    ]
    .align_y(Alignment::Center)
    .into()
}

/// The Home page of the Player panel layout: the greeting, Liked Songs as the hero (the same one
/// the Dock layout draws), then the up-next list: title and artist, no label. The up-next list is
/// this layout's queue. With nothing queued yet it gives way to the "Recent" shelf, so Home is
/// never bare. The "Describe a mood" card stays below, so that feature is not lost.
#[allow(clippy::too_many_arguments)]
pub fn view_panel<'a, Message: Clone + 'static>(
    feed: &'a HomeFeed,
    palette: HalcyonPalette,
    density: Density,
    liked: &'a [Track],
    player: &'a halcyon_music_core::state::PlayerState,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
    on_shuffle_liked: Message,
    on_refresh: Message,
    loading: bool,
    shimmer: f32,
    prompt_card: Element<'a, Message>,
) -> Element<'a, Message> {
    let mut page = column![].spacing(28).padding([16, 24]);
    page = page.push(greeting_row(feed, palette, density, loading, on_refresh));
    page = page.push(dock_hero(
        liked,
        palette,
        on_play_context,
        on_navigate,
        on_shuffle_liked,
    ));

    if !crate::views::up_next::is_empty(player) {
        page = page.push(crate::views::up_next::list(player, palette));
    } else {
        if feed.quick_picks.is_empty()
            && feed.jump_back_in.is_empty()
            && feed.made_for_you.is_empty()
        {
            page = page.push(view_skeleton(palette, shimmer));
        }
        if !feed.jump_back_in.is_empty() {
            page = page.push(view_shelf_with(
                true,
                "Recent",
                "",
                &feed.jump_back_in,
                palette,
                on_play_track,
                on_play_context,
                on_play_playlist,
                on_open_playlist,
            ));
        }
    }

    page = page.push(prompt_card);
    page = page.push(Space::with_height(32));
    container(page).width(Length::Fill).into()
}

/// Edge of the heart cover in the Dock layout's Home.
pub const DOCK_HERO_COVER: f32 = 96.0;
/// Edge of the round play and shuffle buttons next to it.
pub const DOCK_HERO_BUTTON: f32 = 40.0;

fn round_button<'a, Message: Clone + 'a>(
    glyph: Icon,
    filled: bool,
    palette: HalcyonPalette,
    msg: Message,
) -> Element<'a, Message> {
    let px = DOCK_HERO_BUTTON;
    button(
        container(icon(
            glyph,
            18.0,
            if filled {
                palette.on_accent()
            } else {
                palette.text
            },
        ))
        .width(px)
        .height(px)
        .center_x(px)
        .center_y(px),
    )
    .padding(0)
    .on_press(msg)
    .style(move |_t, status| button::Style {
        background: Some(if filled {
            palette.accent_background()
        } else if matches!(status, button::Status::Hovered | button::Status::Pressed) {
            crate::theme::alpha(palette.text, 0.14).into()
        } else {
            crate::theme::alpha(palette.text, 0.08).into()
        }),
        border: iced::Border {
            radius: (px / 2.0).into(),
            ..Default::default()
        },
        ..Default::default()
    })
    .into()
}

fn dock_hero<'a, Message: Clone + 'static>(
    liked: &'a [Track],
    palette: HalcyonPalette,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
    on_shuffle_liked: Message,
) -> Element<'a, Message> {
    let tint = palette.dim_tint();
    let cover = container(icon(Icon::Heart, DOCK_HERO_COVER * 0.42, palette.text))
        .width(DOCK_HERO_COVER)
        .height(DOCK_HERO_COVER)
        .center_x(DOCK_HERO_COVER)
        .center_y(DOCK_HERO_COVER)
        .style(move |_t| container::Style {
            background: Some(tint.into()),
            border: iced::Border {
                radius: crate::theme::radius::HERO.into(),
                ..Default::default()
            },
            ..Default::default()
        });
    let open = on_navigate(NavPage::Liked);
    let cover_btn = button(cover)
        .padding(0)
        .on_press(open.clone())
        .style(|_t, _s| button::Style::default());

    let count = if liked.is_empty() {
        String::new()
    } else {
        format!("{} songs", liked.len())
    };
    let title_btn = button(
        column![
            text("Liked Songs").size(22).color(palette.text),
            text(count).size(13).color(palette.text_muted),
        ]
        .spacing(4),
    )
    .padding(0)
    .on_press(open.clone())
    .style(|_t, _s| button::Style::default());

    // Before the songs have loaded, play just opens the page, as the Classic card does.
    let play_msg = if liked.is_empty() {
        open
    } else {
        on_play_context(liked.to_vec(), 0)
    };
    let buttons = row![
        round_button(Icon::Play, true, palette, play_msg),
        round_button(Icon::Shuffle, false, palette, on_shuffle_liked),
    ]
    .spacing(10);

    row![
        cover_btn,
        Space::with_width(18),
        column![title_btn, Space::with_height(12), buttons].align_x(Alignment::Start),
    ]
    .align_y(Alignment::Center)
    .into()
}

/// Grey blocks in the shape of the quick picks and one shelf.
/// The pinned Liked Songs playlist: one wide card, always first on Home.
fn view_liked_pin<'a, Message: Clone + 'static>(
    liked: &'a [Track],
    palette: HalcyonPalette,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let subtitle = if liked.is_empty() {
        "Your favourite songs".to_string()
    } else {
        format!("{} songs", liked.len())
    };

    let body = button(
        row![
            crate::views::liked_cover(72.0, 16.0, palette),
            Space::with_width(16),
            column![
                text("Liked Songs").size(22).color(palette.text),
                text(subtitle).size(13).color(palette.text_muted),
            ]
            .spacing(4)
            .width(Length::Fill),
        ]
        .align_y(Alignment::Center)
        .padding([10, 14]),
    )
    .width(Length::Fill)
    .on_press(on_navigate(NavPage::Liked))
    .style(move |_t, _s| button::Style::default());

    // Plays the whole playlist; before the songs have loaded it just opens the page.
    let play_msg = if liked.is_empty() {
        on_navigate(NavPage::Liked)
    } else {
        on_play_context(liked.to_vec(), 0)
    };
    let play_btn = button(
        container(icon(Icon::Play, 20.0, palette.on_accent()))
            .width(46)
            .height(46)
            .center_x(46)
            .center_y(46),
    )
    .padding(0)
    .on_press(play_msg)
    .style(move |_t, s| button::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: 23.0.into(),
            ..Default::default()
        },
        shadow: if s == button::Status::Hovered {
            palette.glow_shadow(0.55, 26.0)
        } else {
            palette.glow_shadow(0.30, 16.0)
        },
        ..Default::default()
    });

    container(row![body, play_btn, Space::with_width(18)].align_y(Alignment::Center))
        .width(Length::Fill)
        .style(move |_t| container::Style {
            // A little more colour than a normal card, so it reads as the pinned one.
            background: Some(crate::theme::gradient2(
                crate::theme::mix(palette.surface, palette.accent, 0.20),
                crate::theme::mix(palette.surface, palette.accent_secondary, 0.06),
                false,
            )),
            border: iced::Border {
                color: crate::theme::alpha(palette.accent, 0.30),
                width: 1.0,
                radius: 30.0.into(),
            },
            shadow: palette.glow_shadow(0.16, 24.0),
            ..Default::default()
        })
        .into()
}

fn view_skeleton<'a, Message: 'a>(palette: HalcyonPalette, shimmer: f32) -> Element<'a, Message> {
    // One slow breath: 0.45 -> 0.8 -> 0.45 opacity over the phase.
    let pulse = 0.45 + 0.35 * (0.5 + 0.5 * (shimmer * std::f32::consts::TAU).sin());
    fn block<'a, Message: 'a>(
        w: Length,
        h: f32,
        radius: f32,
        palette: HalcyonPalette,
        pulse: f32,
    ) -> Element<'a, Message> {
        container(Space::new(w, h))
            .style(move |_t| container::Style {
                background: Some(
                    iced::Color {
                        a: pulse,
                        ..palette.surface_variant
                    }
                    .into(),
                ),
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

    column![
        tiles,
        Space::with_height(8),
        block(Length::Fixed(160.0), 18.0, 4.0, palette, pulse),
        cards
    ]
    .spacing(14)
    .into()
}

/// Quick Picks Grid: 2 rows of 3-4 tiles.
#[allow(clippy::too_many_arguments)]
fn view_quick_picks<'a, Message: Clone + 'static>(
    picks: &'a [QuickPick],
    palette: HalcyonPalette,
    _density: Density,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_play_mix: impl Fn(Vec<Track>, String) -> Message + 'a + Copy,
    on_open_mix: impl Fn(String) -> Message + 'a + Copy,
    on_navigate: impl Fn(NavPage) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut grid = column![].spacing(10);
    // Liked Songs has its own pinned card at the top of the page, so it is left out here.
    let picks: Vec<&QuickPick> = picks.iter().filter(|p| p.id != "liked-songs").collect();
    let chunks: Vec<&[&QuickPick]> = picks.chunks(3).collect();

    for row_picks in chunks.into_iter().take(2) {
        let mut r = row![].spacing(12).width(Length::Fill);
        for item in row_picks {
            let tracks = item.tracks.clone();
            let title = item.title.clone();

            let is_liked = item.id == "liked-songs";
            let is_mix = !is_liked && !tracks.is_empty();

            // Clicking the tile opens it (a playlist's or a mix's song list, the Liked page).
            // The round play button always plays straight away.
            let open_msg = if is_liked {
                on_navigate(NavPage::Liked)
            } else if is_mix {
                on_open_mix(item.id.clone())
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
                    crate::art::cover(
                        item.art_url.as_deref(),
                        halcyon_music_core::art::ArtSize::Small,
                        52.0,
                        12.0,
                        Icon::Music,
                        &item.title,
                        palette
                    ),
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
            .style(move |_t, _s| button::Style {
                background: Some(palette.accent_background()),
                border: iced::Border {
                    radius: 15.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

            let tile_btn = container(
                row![body_btn, play_btn, Space::with_width(12)].align_y(Alignment::Center),
            )
            .width(Length::FillPortion(1))
            .style(move |_t| container::Style {
                background: Some(palette.card_background()),
                border: iced::Border {
                    radius: 18.0.into(),
                    ..Default::default()
                },
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
#[allow(clippy::too_many_arguments)]
fn view_feed_shelf<'a, Message: Clone + 'static>(
    header_title: &'static str,
    subtitle: &'static str,
    items: &'a [ShelfItem],
    palette: HalcyonPalette,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    view_shelf_with(
        false,
        header_title,
        subtitle,
        items,
        palette,
        on_play_track,
        on_play_context,
        on_play_playlist,
        on_open_playlist,
    )
}

/// A shelf of covers. `compact` leaves out the line under the shelf name and the line under each
/// cover's title (the Dock layout's Home keeps one label per shelf and nothing else).
#[allow(clippy::too_many_arguments)]
fn view_shelf_with<'a, Message: Clone + 'static>(
    compact: bool,
    header_title: &'static str,
    subtitle: &'static str,
    items: &'a [ShelfItem],
    palette: HalcyonPalette,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
    on_play_context: impl Fn(Vec<Track>, usize) -> Message + 'a + Copy,
    on_play_playlist: impl Fn(String) -> Message + 'a + Copy,
    on_open_playlist: impl Fn(String) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut header = column![text(header_title).size(18).color(palette.text)].spacing(2);
    if !compact {
        header = header.push(text(subtitle).size(12).color(palette.text_muted));
    }

    let mut cards_row = row![].spacing(14).padding([4, 0]);

    for item in items.iter().take(8) {
        let tracks = item.tracks.clone();
        let card_btn = button(
            column![
                // Artwork card
                crate::art::cover(
                    item.art_url.as_deref(),
                    halcyon_music_core::art::ArtSize::Medium,
                    140.0,
                    14.0,
                    Icon::Music,
                    &item.title,
                    palette
                ),
                Space::with_height(8),
                text(super::ellipsize(&item.title, 17))
                    .size(13)
                    .color(palette.text),
                text(if compact {
                    String::new()
                } else {
                    super::ellipsize(&item.subtitle, 20)
                })
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
                border: iced::Border {
                    radius: 17.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });
            // Not a stacked overlay (those are not clipped by the scroll area and can draw over
            // the player bar): the button sits in its own strip under the card.
            cards_row = cards_row.push(column![
                card_btn,
                container(play_btn)
                    .width(Length::Fixed(156.0))
                    .align_x(iced::alignment::Horizontal::Right)
                    .padding(iced::Padding {
                        top: 6.0,
                        right: 8.0,
                        bottom: 0.0,
                        left: 0.0
                    }),
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

/// Width of one Made-for-you card, and the padding inside it.
const MIX_W: f32 = 196.0;
const MIX_PAD: f32 = 10.0;
/// Height of the text strip under a mix cover, and the width kept free in it for the buttons.
const MIX_INFO_H: f32 = 64.0;
const MIX_BTN_ZONE: f32 = 78.0;

/// Covers a mix cycles through at most (each one is a download, so not the whole playlist).
pub const MIX_SLIDES: usize = 8;
/// How long a cover stays, how long the cross-fade takes, and how far apart neighbouring cards
/// run, so the shelf ripples instead of everything changing at once.
const SLIDE_HOLD: f32 = 8.0;
const SLIDE_FADE: f32 = 2.4;
const SLIDE_STAGGER: f32 = 2.1;

/// Which cover of `count` card number `index` shows at `clock` seconds, and how far (0.0 ..= 1.0)
/// the cross-fade to the next one has got.
fn slide_at(clock: f32, index: usize, count: usize) -> (usize, f32) {
    if count < 2 {
        return (0, 0.0);
    }
    let step_len = SLIDE_HOLD + SLIDE_FADE;
    let t = (clock + index as f32 * SLIDE_STAGGER).max(0.0);
    let step = (t / step_len).floor();
    let within = t - step * step_len;
    let fade = if within > SLIDE_HOLD {
        ((within - SLIDE_HOLD) / SLIDE_FADE).clamp(0.0, 1.0)
    } else {
        0.0
    };
    // Ease in and out so the change is soft at both ends.
    let fade = fade * fade * (3.0 - 2.0 * fade);
    ((step as usize) % count, fade)
}

/// The two shelves Home draws, in the order the cards appear (the same split `view` makes).
fn shelves(feed: &HomeFeed) -> [Vec<&MusicMix>; 2] {
    [
        feed.made_for_you
            .iter()
            .filter(|m| m.source == "Halcyon Local")
            .collect(),
        feed.made_for_you
            .iter()
            .filter(|m| m.source != "Halcyon Local")
            .collect(),
    ]
}

/// `None` when no card on Home has more than one cover (nothing moves, no timer needed);
/// otherwise whether any card is mid-fade right now (the app then redraws at full rate).
pub fn slideshow_state(feed: &HomeFeed, clock: f32) -> Option<bool> {
    let mut any = false;
    let mut fading = false;
    for shelf in shelves(feed) {
        for (i, mix) in shelf.into_iter().enumerate() {
            let n = crate::art::unique_covers(mix, MIX_SLIDES).len();
            if n >= 2 {
                any = true;
                fading |= slide_at(clock, i, n).1 > 0.0;
            }
        }
    }
    any.then_some(fading)
}

/// The picture of a mix: its songs' covers one after another, each fading into the next. A mix
/// with a single cover just shows it.
fn mix_cover<'a, Message: 'a>(
    mix: &MusicMix,
    index: usize,
    clock: f32,
    px: f32,
    palette: HalcyonPalette,
) -> Element<'a, Message> {
    const RADIUS: f32 = 20.0;
    let covers = crate::art::unique_covers(mix, MIX_SLIDES);
    let size = halcyon_music_core::art::ArtSize::Medium;
    let Some(&first) = covers.first() else {
        return crate::art::cover(
            mix.art_url.as_deref(),
            size,
            px,
            RADIUS,
            Icon::Music,
            &mix.title,
            palette,
        );
    };
    let (now, fade) = slide_at(clock, index, covers.len());
    let current = covers.get(now).copied().unwrap_or(first);
    let base = crate::art::cover(
        Some(current),
        size,
        px,
        RADIUS,
        Icon::Music,
        &mix.title,
        palette,
    );
    if fade <= 0.0 {
        return base;
    }
    let next = covers
        .get((now + 1) % covers.len())
        .copied()
        .unwrap_or(first);
    match crate::art::cover_overlay(next, size, px, RADIUS, fade) {
        Some(over) => crate::views::crossfade::Crossfade::new(base, over).into(),
        None => base,
    }
}

/// "Made for you by Halcyon": a shelf of cover cards. Each card has a Play button and a Save
/// button over its cover; clicking the card itself opens the mix as a playlist page so the songs
/// can be seen first. `progress` (0..1, the page-entrance clock) makes the cards rise in turn.
#[allow(clippy::too_many_arguments)]
fn view_made_for_you_mixes<'a, Message: Clone + 'static>(
    mixes: Vec<&'a MusicMix>,
    title: &'static str,
    _byline: &'static str,
    _subtitle: &'static str,
    palette: HalcyonPalette,
    _density: Density,
    on_play_mix: impl Fn(Vec<Track>, String) -> Message + 'a + Copy,
    on_save_mix: impl Fn(String, Vec<String>) -> Message + 'a + Copy,
    on_open_mix: impl Fn(String) -> Message + 'a + Copy,
    on_mix_action: impl Fn(String, MixAction) -> Message + 'a + Copy,
    progress: f32,
    clock: f32,
) -> Element<'a, Message> {
    // One label per shelf: no "by Halcyon", no explanatory sub-line.
    let header = text(title).size(18).color(palette.text);

    let cover_px = MIX_W - MIX_PAD * 2.0;
    let mut mix_row = row![].spacing(16).padding([4, 0]);

    for (i, mix) in mixes.into_iter().enumerate() {
        let uris: Vec<String> = mix.tracks.iter().map(|t| t.uri.clone()).collect();
        let tracks = mix.tracks.clone();

        // No overlay layers: a stacked layer is not clipped by the scroll area and draws its
        // buttons over the player bar when the card is scrolled out of view. Everything here
        // is a plain sibling in one column: cover button, then a strip with the title (also a
        // button), the source line, and the Save and Play buttons on the right.
        let text_w = cover_px - MIX_BTN_ZONE;
        let cover_btn = button(mix_cover(mix, i, clock, cover_px, palette))
            .padding(0)
            .on_press(on_open_mix(mix.id.clone()))
            .style(crate::views::ghost(palette));
        let title_btn = button(
            text(super::ellipsize(&mix.title, 18))
                .size(14)
                .color(palette.text),
        )
        .padding(0)
        .on_press(on_open_mix(mix.id.clone()))
        .style(|_t, _s| button::Style::default());
        // The card has room for about 30 characters of the description (its words from the LLM
        // layer, when on). The whole sentence is one hover away, so nothing is lost and the card
        // never changes size.
        let title_el: Element<'a, Message> = if mix.description.chars().count() > 30 {
            iced::widget::tooltip(
                title_btn,
                container(text(mix.description.clone()).size(12).color(palette.text))
                    .padding(8)
                    .max_width(240),
                iced::widget::tooltip::Position::Top,
            )
            .gap(6)
            .style(crate::views::card(palette))
            .into()
        } else {
            title_btn.into()
        };
        // Just the title under the cover; the longer description stays one hover away.
        let info = column![title_el].spacing(3).width(Length::Fixed(text_w));

        // Round Save and Play buttons beside the text.
        let save_btn = button(
            container(icon(Icon::Plus, 14.0, Color::WHITE))
                .width(30)
                .height(30)
                .center_x(30)
                .center_y(30),
        )
        .padding(0)
        .on_press(on_save_mix(mix.title.clone(), uris))
        .style(move |_t, status| {
            let hot = matches!(status, button::Status::Hovered | button::Status::Pressed);
            button::Style {
                background: Some(
                    Color {
                        a: if hot { 0.78 } else { 0.55 },
                        ..Color::BLACK
                    }
                    .into(),
                ),
                border: iced::Border {
                    color: Color {
                        a: 0.28,
                        ..Color::WHITE
                    },
                    width: 1.0,
                    radius: 15.0.into(),
                },
                ..Default::default()
            }
        });
        let play_btn = crate::views::play_orb(
            Icon::Play,
            34.0,
            palette,
            Some(on_play_mix(tracks, mix.title.clone())),
        );
        let actions = row![save_btn, play_btn]
            .spacing(6)
            .align_y(Alignment::Center);

        let strip = row![info, Space::with_width(Length::Fill), actions]
            .align_y(Alignment::Start)
            .width(Length::Fixed(cover_px))
            .height(Length::Fixed(MIX_INFO_H));

        // Refresh, "Less like this", "Not my taste": plain siblings under the strip (no layers).
        let small = |label: &'static str, action: MixAction| {
            button(text(label).size(10).color(palette.text_muted))
                .padding([2, 4])
                .on_press(on_mix_action(mix.id.clone(), action))
                .style(crate::views::ghost(palette))
        };
        let judge: Element<'a, Message> = if is_generated_mix(&mix.id) {
            row![
                small("Refresh", MixAction::Refresh),
                small("Less like this", MixAction::LessLikeThis),
                small("Not my taste", MixAction::NotMyTaste)
            ]
            .spacing(2)
            .height(Length::Fixed(MIX_ACTION_H))
            .into()
        } else {
            Space::with_height(MIX_ACTION_H).into()
        };

        let card = container(column![cover_btn, Space::with_height(10), strip, judge])
            .padding(MIX_PAD)
            .width(MIX_W)
            .style(move |_t| container::Style {
                background: Some(crate::theme::alpha(palette.surface, 0.55).into()),
                border: iced::Border {
                    radius: 24.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

        // Cards rise into place one after another while the page settles.
        let p = ((progress * 1.6) - i as f32 * 0.12).clamp(0.0, 1.0);
        let off = (1.0 - crate::animation::Easing::EaseOutCubic.apply(p)) * 16.0;
        mix_row = mix_row.push(container(card).padding(iced::Padding {
            top: off,
            right: 0.0,
            bottom: 16.0 - off,
            left: 0.0,
        }));
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
    let top_artist = capsule.top_artist.as_deref().unwrap_or("Various Artists");

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
                        radius: 24.0.into(),
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
                    text(format!(" by {top_artist}"))
                        .size(12)
                        .color(palette.text_muted),
                ],
            ]
            .width(Length::Fill),
            // Right button
            // The label had no colour of its own and fell back to black on the dark card.
            // The accent pill gives it a fill and a text colour that always contrast.
            button(text("Open Capsule").size(13))
                .on_press(on_navigate(NavPage::Capsule))
                .padding([8, 18])
                .style(crate::views::solid(palette)),
        ]
        .align_y(Alignment::Center)
        .padding(18),
    )
    .width(Length::Fill)
    .style(move |_t| container::Style {
        background: Some(palette.card_background()),
        border: iced::Border {
            radius: 26.0.into(),
            width: 1.0,
            color: palette.soft_border(),
        },
        ..Default::default()
    })
    .into()
}

use iced::Color;

#[cfg(test)]
mod slideshow_tests {
    use super::*;

    #[test]
    fn a_single_cover_never_moves() {
        assert_eq!(slide_at(123.0, 2, 1), (0, 0.0));
    }

    #[test]
    fn covers_advance_one_after_another_and_wrap() {
        let step = SLIDE_HOLD + SLIDE_FADE;
        let seen: Vec<usize> = (0..6)
            .map(|k| slide_at(k as f32 * step + 0.1, 0, 4).0)
            .collect();
        assert_eq!(seen, vec![0, 1, 2, 3, 0, 1]);
    }

    #[test]
    fn fade_happens_only_at_the_end_of_each_hold() {
        assert_eq!(slide_at(1.0, 0, 3).1, 0.0);
        let mid = slide_at(SLIDE_HOLD + SLIDE_FADE / 2.0, 0, 3).1;
        assert!((mid - 0.5).abs() < 0.01, "{mid}");
        assert!(slide_at(SLIDE_HOLD + SLIDE_FADE - 0.001, 0, 3).1 > 0.99);
    }

    #[test]
    fn neighbouring_cards_are_out_of_step() {
        assert_ne!(slide_at(9.0, 0, 4), slide_at(9.0, 1, 4));
    }
}

#[cfg(test)]
mod part6_tests {
    use super::*;

    fn mix(id: &str, source: &str) -> MusicMix {
        MusicMix {
            id: id.into(),
            title: id.into(),
            description: String::new(),
            source: source.into(),
            tracks: Vec::new(),
            art_url: None,
        }
    }

    #[test]
    fn generated_mixes_replace_the_old_ones_and_lead_the_shelf() {
        let mut feed = HomeFeed {
            made_for_you: vec![
                mix("on-repeat", "Halcyon Local"),
                mix("hidden-gems", "Halcyon Local"),
                mix("daily-mix-4", "Halcyon Local"),
                mix("deezer-global-chart", "Deezer"),
            ],
            ..Default::default()
        };
        merge_generated(
            &mut feed,
            vec![
                mix("daily-mix-1", "Halcyon Local"),
                mix("on-repeat", "Halcyon Local"),
            ],
            Vec::new(),
        );
        let ids: Vec<&str> = feed.made_for_you.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "daily-mix-1",
                "on-repeat",
                "hidden-gems",
                "deezer-global-chart"
            ],
            "a vanished Daily Mix is gone, other mixes stay"
        );
    }

    #[test]
    fn only_scheduled_mixes_get_the_judging_buttons() {
        for id in [
            "daily-mix-2",
            "discover-weekly",
            "release-radar",
            "on-repeat",
            "repeat-rewind",
            "daylist",
        ] {
            assert!(is_generated_mix(id), "{id}");
        }
        for id in ["hidden-gems", "liked-songs", "halcyon-mix", "top-100"] {
            assert!(!is_generated_mix(id), "{id}");
        }
    }
}

#[cfg(test)]
mod filter_tests {
    use super::*;

    const EVERY: [Section; 9] = [
        Section::LikedPin,
        Section::QuickPicks,
        Section::JumpBackIn,
        Section::MadeForYou,
        Section::Discover,
        Section::Charts,
        Section::NewReleases,
        Section::FreshReleases,
        Section::Capsule,
    ];

    #[test]
    fn all_shows_everything() {
        assert!(EVERY.iter().all(|s| HomeFilter::All.shows(*s)));
    }

    #[test]
    fn music_and_new_split_the_page_without_overlap_or_gaps() {
        for s in EVERY {
            let (m, n) = (HomeFilter::Music.shows(s), HomeFilter::New.shows(s));
            assert!(m ^ n, "{s:?} must belong to exactly one of Music and New");
        }
        assert!(
            HomeFilter::Music.shows(Section::MadeForYou)
                && !HomeFilter::Music.shows(Section::Charts)
        );
        assert!(
            HomeFilter::New.shows(Section::NewReleases)
                && !HomeFilter::New.shows(Section::LikedPin)
        );
    }

    #[test]
    fn labels_match_spotify_chips() {
        let labels: Vec<_> = HomeFilter::ALL.iter().map(HomeFilter::label).collect();
        assert_eq!(labels, ["All", "Music", "New"]);
        assert_eq!(HomeFilter::default(), HomeFilter::All);
    }
}

#[cfg(test)]
mod dock_home_tests {
    use super::*;

    #[test]
    fn the_dock_home_builds_with_an_empty_feed_and_with_songs() {
        let palette = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        let feed = HomeFeed::default();
        let build = |feed: &HomeFeed, liked: &[Track], loading: bool| {
            let _: Element<'_, ()> = view_dock(
                feed,
                palette,
                Density::Comfortable,
                liked,
                |_| (),
                |_, _| (),
                |_| (),
                |_| (),
                |_| (),
                (),
                (),
                loading,
                0.0,
                Space::new(0, 0).into(),
            );
        };
        build(&feed, &[], false);
        build(&feed, &[], true);
        let songs = vec![Track::simple(
            "a".into(),
            "A".into(),
            "X".into(),
            "Y".into(),
            1000,
        )];
        build(&feed, &songs, false);
        // With a Recent shelf: a playlist (round play button under it) and an album.
        let mut full = HomeFeed::default();
        for (i, kind) in ["playlist", "album"].iter().enumerate() {
            full.jump_back_in.push(ShelfItem {
                id: format!("s{i}"),
                title: "A shelf title that is long".into(),
                subtitle: "Sub line".into(),
                art_url: None,
                uri: String::new(),
                context_type: (*kind).into(),
                tracks: songs.clone(),
            });
        }
        build(&full, &songs, false);
    }

    #[test]
    fn a_compact_shelf_builds() {
        let palette = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        let _: Element<'_, ()> = view_shelf_with(
            true,
            "Recent",
            "",
            &[],
            palette,
            |_| (),
            |_, _| (),
            |_| (),
            |_| (),
        );
    }

    #[test]
    fn the_panel_home_builds_with_nothing_queued_and_with_songs_up_next() {
        use halcyon_music_core::state::PlayerState;
        let palette = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        let songs: Vec<Track> = (0..4)
            .map(|i| {
                Track::simple(
                    format!("t{i}"),
                    format!("Song {i}"),
                    "X".into(),
                    "Y".into(),
                    1000,
                )
            })
            .collect();
        let mut feed = HomeFeed::default();
        feed.jump_back_in.push(ShelfItem {
            id: "s".into(),
            title: "A shelf".into(),
            subtitle: String::new(),
            art_url: None,
            uri: String::new(),
            context_type: "playlist".into(),
            tracks: songs.clone(),
        });
        let build = |feed: &HomeFeed, player: &PlayerState, loading: bool| {
            let _: Element<'_, ()> = view_panel(
                feed,
                palette,
                Density::Comfortable,
                &songs,
                player,
                |_| (),
                |_, _| (),
                |_| (),
                |_| (),
                |_| (),
                (),
                (),
                loading,
                0.0,
                Space::new(0, 0).into(),
            );
        };
        // Nothing queued: the Recent shelf (or the skeleton while the feed is empty).
        let idle = PlayerState::default();
        build(&HomeFeed::default(), &idle, true);
        build(&feed, &idle, false);
        // Songs up next: the list.
        let playing = PlayerState {
            queue: songs.clone(),
            queue_pos: 0,
            track: songs.first().cloned(),
            ..Default::default()
        };
        assert!(!crate::views::up_next::is_empty(&playing));
        build(&feed, &playing, false);
    }
}
