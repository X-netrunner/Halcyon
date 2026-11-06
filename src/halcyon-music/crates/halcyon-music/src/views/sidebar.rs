//! Collapsible sidebar navigation.

use crate::theme::{Density, HalcyonPalette};
use iced::widget::{button, column, container, row, text, Space};
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
}

impl NavPage {
    pub fn all() -> &'static [NavPage] {
        &[
            NavPage::Home,
            NavPage::Search,
            NavPage::Library,
            NavPage::Liked,
            NavPage::Capsule,
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
        }
    }

    pub fn icon(&self) -> &'static str {
        match self {
            NavPage::Home => "󰋜",
            NavPage::Search => "󰍉",
            NavPage::Library => "󰲸",
            NavPage::Liked => "󰋑",
            NavPage::Capsule => "󰑈",
            NavPage::Settings => "󰒓",
        }
    }
}

pub fn view<'a, Message: Clone + 'static>(
    current_page: NavPage,
    collapsed: bool,
    palette: &HalcyonPalette,
    density: Density,
    on_select: impl Fn(NavPage) -> Message + 'a,
    on_toggle_collapse: Message,
) -> Element<'a, Message> {
    let width = if collapsed {
        SIDEBAR_COLLAPSED_WIDTH
    } else {
        SIDEBAR_EXPANDED_WIDTH
    };

    let mut nav_items = column![].spacing(density.row_padding() / 2);

    for &page in NavPage::all() {
        let is_active = page == current_page;
        let icon_txt = text(page.icon()).size(18);

        let content: Element<'a, Message> = if collapsed {
            container(icon_txt)
                .width(Length::Fill)
                .center_x(Length::Fill)
                .into()
        } else {
            row![
                icon_txt,
                Space::with_width(12),
                text(page.label()).size(density.body_size())
            ]
            .align_y(Alignment::Center)
            .into()
        };

        let btn = button(content)
            .on_press(on_select(page))
            .width(Length::Fill)
            .padding([8, 12])
            .style(move |_theme, status| {
                let mut bg = iced::Color::TRANSPARENT;
                let text_color = if is_active {
                    palette.accent
                } else {
                    palette.text
                };

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

        nav_items = nav_items.push(btn);
    }

    let toggle_label = if collapsed { "󰅂" } else { "󰅁 Collapse" };
    let toggle_btn = button(
        container(text(toggle_label).size(13))
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
                container(text("󰝚").size(22).color(palette.accent))
                    .width(Length::Fill)
                    .center_x(Length::Fill)
            } else {
                container(
                    row![
                        text("󰝚").size(22).color(palette.accent),
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
