//! Sidebar navigation. Icons only by default; the sidebar opens while the pointer is over it
//! and pushes the page aside instead of covering it.
//!
//! The icons never move: each one sits in a fixed 48 px slot, and opening the sidebar only
//! widens the strip and fades the labels in on the same line. The sidebar has no fill of its
//! own: it is part of the one frame (see `HalcyonApp::view`) that also holds the player bar.

use crate::icons::{icon, Icon};
use crate::theme::{Density, HalcyonPalette};
use iced::widget::{button, column, container, row, text, tooltip, Space};
use iced::{Alignment, Element, Length};

pub const SIDEBAR_EXPANDED_WIDTH: f32 = 236.0;
pub const SIDEBAR_COLLAPSED_WIDTH: f32 = 76.0;
/// Space kept on the left and right of the items. With the collapsed width it leaves a
/// 48 px column, so an icon slot is exactly as wide as the collapsed sidebar's inside.
const SIDE_PAD: f32 = 14.0;
/// Width of the slot every icon sits in (and so the x position of every icon).
const ICON_SLOT: f32 = 48.0;
const ITEM_HEIGHT: f32 = 46.0;
/// Size of the icons in the rail.
const ICON_PX: f32 = 22.0;

/// The sidebar's width for an open amount from 0.0 (collapsed) to 1.0 (open).
pub fn width_for(expand: f32) -> f32 {
    let t = expand.clamp(0.0, 1.0);
    SIDEBAR_COLLAPSED_WIDTH + (SIDEBAR_EXPANDED_WIDTH - SIDEBAR_COLLAPSED_WIDTH) * t
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NavPage {
    Home = 0,
    Search = 1,
    Library = 2,
    Liked = 3,
    Capsule = 4,
    Settings = 5,
    AlbumDetail = 6,
    ArtistDetail = 7,
    PlaylistDetail = 8,
    Lyrics = 9,
    Recent = 10,
    Discover = 11,
}

impl NavPage {
    pub fn all() -> &'static [NavPage] {
        &[
            NavPage::Home,
            NavPage::Discover,
            NavPage::Library,
            NavPage::Recent,
            NavPage::Capsule,
        ]
    }

    /// Which row of the sidebar lights up for this page, if any. Liked Songs lives inside
    /// Your Library, so Library stays lit while it is open.
    pub fn slot(&self) -> Option<usize> {
        let page = if *self == NavPage::Liked {
            NavPage::Library
        } else {
            *self
        };
        NavPage::all().iter().position(|p| *p == page)
    }

    pub fn label(&self) -> &'static str {
        match self {
            NavPage::Home => "Home",
            NavPage::Search => "Search",
            NavPage::Library => "Your Library",
            NavPage::Liked => "Liked Songs",
            NavPage::Capsule => "Capsule",
            NavPage::Settings => "Settings",
            NavPage::AlbumDetail => "Album",
            NavPage::ArtistDetail => "Artist",
            NavPage::PlaylistDetail => "Playlist",
            NavPage::Lyrics => "Lyrics",
            NavPage::Recent => "Recently played",
            NavPage::Discover => "Discover",
        }
    }

    pub fn icon(&self) -> Icon {
        match self {
            NavPage::Home => Icon::Home,
            NavPage::Search => Icon::Search,
            NavPage::Library => Icon::Library,
            NavPage::Liked => Icon::Heart,
            NavPage::Capsule => Icon::Chart,
            NavPage::Settings => Icon::Settings,
            NavPage::AlbumDetail => Icon::Album,
            NavPage::ArtistDetail => Icon::Artist,
            NavPage::PlaylistDetail => Icon::Playlist,
            NavPage::Lyrics => Icon::Lyrics,
            NavPage::Recent => Icon::Clock,
            NavPage::Discover => Icon::Sparkles,
        }
    }
}

/// One row of the sidebar. The icon is always in the same place; the label follows it on the
/// same line and fades in as the sidebar opens.
fn item_button<'a, Message: Clone + 'static>(
    ic: Icon,
    label: &'static str,
    is_active: bool,
    expand: f32,
    palette: HalcyonPalette,
    density: Density,
    msg: Message,
) -> Element<'a, Message> {
    let tint = if is_active {
        palette.accent
    } else {
        palette.text
    };
    // Labels start to appear once the strip is a third open, so they never show squashed.
    let label_alpha = ((expand - 0.35) / 0.65).clamp(0.0, 1.0);

    let icon_slot = container(icon(ic, ICON_PX, tint))
        .width(ICON_SLOT)
        .height(ITEM_HEIGHT)
        .center_x(ICON_SLOT)
        .center_y(ITEM_HEIGHT);

    // The label lives in its own clipped, fixed-height cell: however long it is, it can never
    // push the icon or change the height of the row.
    let label_cell = container(
        text(label)
            .size(density.body_size())
            .color(crate::theme::alpha(tint, label_alpha))
            .wrapping(iced::widget::text::Wrapping::None),
    )
    .width(Length::Fill)
    .height(ITEM_HEIGHT)
    .center_y(ITEM_HEIGHT)
    .clip(true);

    let content = row![icon_slot, label_cell]
        .height(ITEM_HEIGHT)
        .align_y(Alignment::Center);

    let btn = button(content)
        .on_press(msg)
        .width(Length::Fill)
        .height(ITEM_HEIGHT)
        .padding(0)
        .style(move |_theme, status| {
            let hovered = matches!(status, button::Status::Hovered | button::Status::Pressed);
            button::Style {
                // The active row's fill is the sliding pill behind the rows.
                background: if hovered && !is_active {
                    Some(crate::theme::gradient2(
                        crate::theme::alpha(palette.accent, 0.14),
                        crate::theme::alpha(palette.accent, 0.04),
                        false,
                    ))
                } else {
                    None
                },
                text_color: tint,
                border: iced::Border {
                    radius: crate::theme::radius::MD.into(),
                    ..Default::default()
                },
                ..Default::default()
            }
        });

    // The rail never opens, so the name of each page floats out to the right on hover.
    labelled(btn.into(), label, palette, density.body_size())
}

/// Wrap `content` in a small tooltip showing `label` to its right.
fn labelled<'a, Message: 'a>(
    content: Element<'a, Message>,
    label: &'static str,
    palette: HalcyonPalette,
    size: f32,
) -> Element<'a, Message> {
    tooltip(
        content,
        container(text(label).size(size).color(palette.text))
            .padding([6, 12])
            .style(move |_t| container::Style {
                background: Some(palette.surface_variant.into()),
                border: iced::Border {
                    color: palette.soft_border(),
                    width: 1.0,
                    radius: crate::theme::radius::SM.into(),
                },
                shadow: palette.glow_shadow(0.14, 14.0),
                ..Default::default()
            }),
        tooltip::Position::Right,
    )
    .gap(10)
    .into()
}

/// The glow behind the active row: a soft accent wash that fades to the right, with a short
/// bright bar on its left edge. No outline, so it reads as light and not as a box.
fn active_pill<'a, Message: 'a>(palette: HalcyonPalette) -> Element<'a, Message> {
    let bar = container(Space::new(3, 20)).style(move |_t| container::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: 2.0.into(),
            ..Default::default()
        },
        shadow: palette.glow_shadow(0.55, 10.0),
        ..Default::default()
    });
    container(
        row![Space::with_width(4), bar, Space::with_width(Length::Fill)]
            .height(Length::Fill)
            .align_y(Alignment::Center),
    )
    .width(Length::Fill)
    .height(ITEM_HEIGHT)
    .style(move |_t| container::Style {
        background: Some(crate::theme::gradient2(
            crate::theme::alpha(palette.accent, 0.22),
            crate::theme::alpha(palette.accent, 0.04),
            false,
        )),
        border: iced::Border {
            radius: crate::theme::radius::MD.into(),
            ..Default::default()
        },
        ..Default::default()
    })
    .into()
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    current_page: NavPage,
    expand: f32,
    pill_slot: Option<f32>,
    palette: HalcyonPalette,
    density: Density,
    on_select: impl Fn(NavPage) -> Message + 'a,
    _on_hover: impl Fn(bool) -> Message + 'a,
    queue_open: bool,
    on_queue: Message,
    clock: f32,
    playing: bool,
    seed: f32,
    header: Element<'a, Message>,
) -> Element<'a, Message> {
    let width = width_for(expand);
    let gap = crate::theme::space::XS;

    let mut nav_items = column![].spacing(gap).width(Length::Fill);
    let mut rows = 0usize;
    for &page in NavPage::all() {
        rows += 1;
        nav_items = nav_items.push(item_button(
            page.icon(),
            page.label(),
            current_page.slot() == page.slot(),
            expand,
            palette,
            density,
            on_select(page),
        ));
    }

    // The active pill is drawn first (under the rows) and slides between them.
    let group_height = rows as f32 * ITEM_HEIGHT + rows.saturating_sub(1) as f32 * gap;
    let mut pill_layer = column![];
    if let Some(slot) = pill_slot {
        pill_layer = pill_layer.push(Space::with_height(slot * (ITEM_HEIGHT + gap)));
        pill_layer = pill_layer.push(active_pill(palette));
    }
    let nav_items = nav_items.height(group_height);
    let nav_group = iced::widget::stack![
        container(pill_layer)
            .width(Length::Fill)
            .height(group_height),
        nav_items,
    ];

    // At the foot of the rail, in place of a Queue row: a column of dancing bars. Pressing it
    // opens the queue; it glows while the queue is open.
    let viz = crate::views::equalizer_vertical(14, 3.0, 5.0, 38.0, clock, seed, playing, palette);
    let viz_btn = button(
        container(viz)
            .width(ICON_SLOT)
            .center_x(ICON_SLOT)
            .padding([10, 0]),
    )
    .on_press(on_queue)
    .padding(0)
    .style(move |_t, status| {
        let hot = queue_open || matches!(status, button::Status::Hovered | button::Status::Pressed);
        button::Style {
            background: Some(
                if hot {
                    crate::theme::alpha(palette.accent, 0.12)
                } else {
                    iced::Color::TRANSPARENT
                }
                .into(),
            ),
            border: iced::Border {
                radius: crate::theme::radius::MD.into(),
                ..Default::default()
            },
            ..Default::default()
        }
    });
    let queue_row = labelled(viz_btn.into(), "Queue", palette, density.body_size());

    let panel = column![
        // The account circle sits in the same slot as the icons below it.
        container(header).width(ICON_SLOT).center_x(ICON_SLOT),
        Space::with_height(crate::theme::space::XL),
        nav_group,
        Space::with_height(Length::Fill),
        queue_row,
    ]
    .width(Length::Fill)
    .height(Length::Fill);

    // Clipping keeps the labels inside the strip while it is still narrow.
    let strip = container(panel)
        .width(width)
        .height(Length::Fill)
        .padding(iced::Padding {
            top: crate::theme::space::SM,
            right: SIDE_PAD,
            bottom: crate::theme::space::SM,
            left: SIDE_PAD,
        })
        .clip(true);

    strip.into()
}
