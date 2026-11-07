//! Collapsible sidebar navigation.

use crate::icons::{icon, Icon};
use crate::theme::{Density, HalcyonPalette};
use iced::widget::{button, column, container, row, text, tooltip, Space};
use iced::{Alignment, Element, Length};

pub const SIDEBAR_EXPANDED_WIDTH: f32 = 220.0;
pub const SIDEBAR_COLLAPSED_WIDTH: f32 = 64.0;

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
}

impl NavPage {
    pub fn all() -> &'static [NavPage] {
        &[
            NavPage::Home,
            NavPage::Search,
            NavPage::Library,
            NavPage::Liked,
            NavPage::Recent,
            NavPage::Capsule,
            NavPage::Lyrics,
            NavPage::Settings,
        ]
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
        }
    }
}

/// One row of the sidebar. When the sidebar is collapsed only the icon shows,
/// so the label moves into a tooltip.
fn item_button<'a, Message: Clone + 'static>(
    ic: Icon,
    label: &'static str,
    is_active: bool,
    collapsed: bool,
    palette: HalcyonPalette,
    density: Density,
    msg: Message,
) -> Element<'a, Message> {
    let tint = if is_active { palette.accent } else { palette.text };
    let icon_txt = icon(ic, 18.0, tint);

    let content: Element<'a, Message> = if collapsed {
        container(icon_txt)
            .width(Length::Fill)
            .center_x(Length::Fill)
            .into()
    } else {
        row![
            icon_txt,
            Space::with_width(12),
            text(label).size(density.body_size())
        ]
        .align_y(Alignment::Center)
        .into()
    };

    let btn = button(content)
        .on_press(msg)
        .width(Length::Fill)
        .padding([8, 12])
        .style(move |_theme, status| {
            let mut bg = iced::Color::TRANSPARENT;
            let text_color = if is_active { palette.accent } else { palette.text };

            if is_active {
                bg = palette.surface_variant;
            } else if status == button::Status::Hovered {
                bg = iced::Color {
                    a: 0.08,
                    ..palette.accent
                };
            }

            button::Style {
                background: Some(bg.into()),
                text_color,
                border: iced::Border {
                    radius: 8.0.into(),
                    width: if is_active { 1.5 } else { 0.0 },
                    color: if is_active {
                        palette.accent
                    } else {
                        iced::Color::TRANSPARENT
                    },
                },
                ..Default::default()
            }
        });

    if collapsed {
        tooltip(
            btn,
            container(text(label).size(12).color(palette.text))
                .padding([4, 8])
                .style(move |_theme| container::Style {
                    background: Some(palette.surface_variant.into()),
                    border: iced::Border {
                        color: palette.border,
                        width: 1.0,
                        radius: 6.0.into(),
                    },
                    ..Default::default()
                }),
            tooltip::Position::Right,
        )
        .into()
    } else {
        btn.into()
    }
}

pub fn view<'a, Message: Clone + 'static>(
    current_page: NavPage,
    collapsed: bool,
    palette: HalcyonPalette,
    density: Density,
    on_select: impl Fn(NavPage) -> Message + 'a,
    on_toggle_collapse: Message,
    queue_open: bool,
    on_queue: Message,
    on_playlists: Message,
) -> Element<'a, Message> {
    let width = if collapsed {
        SIDEBAR_COLLAPSED_WIDTH
    } else {
        SIDEBAR_EXPANDED_WIDTH
    };

    let mut nav_items = column![].spacing(density.row_padding() / 2);

    for &page in NavPage::all() {
        nav_items = nav_items.push(item_button(
            page.icon(),
            page.label(),
            page == current_page,
            collapsed,
            palette,
            density,
            on_select(page),
        ));
    }

    // Shortcuts that are not pages of their own.
    nav_items = nav_items.push(Space::with_height(8));
    nav_items = nav_items.push(item_button(
        Icon::Playlist,
        "Playlists",
        false,
        collapsed,
        palette,
        density,
        on_playlists,
    ));
    nav_items = nav_items.push(item_button(
        Icon::Queue,
        "Queue",
        queue_open,
        collapsed,
        palette,
        density,
        on_queue,
    ));

    let toggle_content: Element<'a, Message> = if collapsed {
        icon(Icon::ChevronRight, 14.0, palette.text_muted).into()
    } else {
        row![
            icon(Icon::ChevronLeft, 14.0, palette.text_muted),
            Space::with_width(6),
            text("Collapse").size(13),
        ]
        .align_y(Alignment::Center)
        .into()
    };
    let toggle_btn = button(
        container(toggle_content)
            .width(Length::Fill)
            .center_x(Length::Fill),
    )
    .on_press(on_toggle_collapse)
    .padding(6)
    .style(move |_theme, status| button::Style {
        background: Some(
            if status == button::Status::Hovered {
                palette.surface_variant
            } else {
                iced::Color::TRANSPARENT
            }
            .into(),
        ),
        text_color: palette.text_muted,
        border: iced::Border {
            radius: 6.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    container(
        column![
            // Header / App Branding
            if collapsed {
                container(icon(Icon::Music, 22.0, palette.accent))
                    .width(Length::Fill)
                    .center_x(Length::Fill)
            } else {
                container(
                    row![
                        icon(Icon::Music, 22.0, palette.accent),
                        Space::with_width(8),
                        text("Halcyon").size(17).color(palette.text),
                    ]
                    .align_y(Alignment::Center),
                )
            },
            Space::with_height(16),
            nav_items,
            Space::with_height(Length::Fill),
            toggle_btn,
        ]
        .padding(12),
    )
    .width(width)
    .height(Length::Fill)
    .style(move |_theme| container::Style {
        background: Some(palette.surface.into()),
        border: iced::Border {
            color: palette.border,
            width: 1.0,
            ..Default::default()
        },
        ..Default::default()
    })
    .into()
}
