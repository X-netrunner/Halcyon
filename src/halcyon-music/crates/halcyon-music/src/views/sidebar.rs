//! Sidebar navigation. Collapsed (icons only) by default; it expands while the
//! pointer is over it.

use crate::icons::{icon, Icon};
use crate::theme::{Density, HalcyonPalette};
use iced::widget::{button, column, container, mouse_area, row, text, tooltip, Space};
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
    let icon_txt = icon(ic, if collapsed { 22.0 } else { 18.0 }, tint);

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
        .padding(if collapsed { [10, 0] } else { [8, 12] })
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
    on_hover: impl Fn(bool) -> Message + 'a,
    queue_open: bool,
    on_queue: Message,
    on_playlists: Message,
    header: Element<'a, Message>,
) -> Element<'a, Message> {
    let width = if collapsed {
        SIDEBAR_COLLAPSED_WIDTH
    } else {
        SIDEBAR_EXPANDED_WIDTH
    };

    let mut nav_items = column![].spacing(crate::theme::space::XS);

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

    let panel = container(
        column![
            // Account circle (top left)
            if collapsed {
                container(header).width(Length::Fill).center_x(Length::Fill)
            } else {
                container(header)
            },
            Space::with_height(crate::theme::space::XL),
            nav_items,
        ]
        .padding(if collapsed { 10.0 } else { crate::theme::space::LG }),
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
        shadow: if collapsed {
            iced::Shadow::default()
        } else {
            iced::Shadow {
                color: iced::Color { a: 0.35, ..iced::Color::BLACK },
                offset: iced::Vector::new(4.0, 0.0),
                blur_radius: 16.0,
            }
        },
        ..Default::default()
    });

    mouse_area(panel)
        .on_enter(on_hover(true))
        .on_exit(on_hover(false))
        .into()
}
