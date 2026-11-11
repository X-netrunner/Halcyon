//! Account circle (profile picture or initial) and its dropdown menu.

use crate::icons::{icon, Icon};
use crate::theme::{alpha, radius, space, type_size, HalcyonPalette};
use halcyon_music_core::art::ArtSize;
use iced::widget::{button, column, container, mouse_area, row, stack, text, Space};
use iced::{Alignment, Element, Length, Padding};

pub const AVATAR_SIZE: f32 = 32.0;
pub const MENU_WIDTH: f32 = 276.0;

/// The first letter to show when there is no picture. Never empty.
pub fn initial(name: &str) -> String {
    name.trim()
        .chars()
        .find(|c| c.is_alphanumeric())
        .map(|c| c.to_uppercase().collect())
        .unwrap_or_else(|| "?".to_string())
}

/// The circle itself: the picture once it is decoded, the initial before that
/// (and for good when the picture cannot be had).
pub fn avatar<'a, M: 'a>(
    name: &str,
    image_url: Option<&str>,
    size: f32,
    palette: HalcyonPalette,
) -> Element<'a, M> {
    if let Some(url) = image_url.filter(|u| !u.is_empty()) {
        if crate::art::is_ready(url, ArtSize::Small) {
            return crate::art::cover(Some(url), ArtSize::Small, size, size / 2.0, Icon::Artist, name, palette);
        }
    }
    container(text(initial(name)).size(size * 0.45).color(palette.background))
        .width(size)
        .height(size)
        .center_x(size)
        .center_y(size)
        .style(move |_t| container::Style {
            background: Some(palette.accent_background()),
            border: iced::Border { radius: (size / 2.0).into(), ..Default::default() },
            ..Default::default()
        })
        .into()
}

/// The clickable circle. `open` keeps a ring around it while the menu is shown.
pub fn avatar_button<'a, M: Clone + 'a>(
    name: &str,
    image_url: Option<&str>,
    open: bool,
    palette: HalcyonPalette,
    on_press: M,
) -> Element<'a, M> {
    button(avatar(name, image_url, AVATAR_SIZE, palette))
        .on_press(on_press)
        .padding(2)
        .style(move |_t, status| {
            let ring = open || matches!(status, button::Status::Hovered | button::Status::Pressed);
            button::Style {
                background: None,
                text_color: palette.text,
                border: iced::Border {
                    color: if ring { palette.accent } else { iced::Color::TRANSPARENT },
                    width: 1.5,
                    radius: ((AVATAR_SIZE + 4.0) / 2.0).into(),
                },
                ..Default::default()
            }
        })
        .into()
}

/// One row of the menu: the icon in a soft rounded tile, the name, and optionally a small
/// trailing icon. `danger` tints the row for the destructive entry (Sign out).
fn item<'a, M: Clone + 'a>(
    glyph: Icon,
    label: &'static str,
    palette: HalcyonPalette,
    trailing: Option<Icon>,
    danger: bool,
    msg: M,
) -> Element<'a, M> {
    let ink = if danger { palette.danger } else { palette.text };
    let tile = container(icon(glyph, 15.0, if danger { palette.danger } else { palette.text_muted }))
        .width(TILE)
        .height(TILE)
        .center_x(TILE)
        .center_y(TILE)
        .style(move |_t| container::Style {
            background: Some(alpha(if danger { palette.danger } else { palette.text }, 0.07).into()),
            border: iced::Border { radius: 10.0.into(), ..Default::default() },
            ..Default::default()
        });
    let mut content = row![
        tile,
        Space::with_width(space::MD),
        text(label).size(type_size::BODY).color(ink).width(Length::Fill),
    ]
    .align_y(Alignment::Center);
    if let Some(t) = trailing {
        content = content.push(icon(t, 13.0, palette.text_muted));
    }
    button(content)
        .on_press(msg)
        .width(Length::Fill)
        .padding([6, 8])
        .style(move |_t, status| {
            let hot = matches!(status, button::Status::Hovered | button::Status::Pressed);
            button::Style {
                background: Some(
                    if hot {
                        alpha(if danger { palette.danger } else { palette.text }, if danger { 0.12 } else { 0.07 })
                    } else {
                        iced::Color::TRANSPARENT
                    }
                    .into(),
                ),
                text_color: ink,
                border: iced::Border { radius: 14.0.into(), ..Default::default() },
                ..Default::default()
            }
        })
        .into()
}

/// Size of the icon tile in a row.
const TILE: f32 = 30.0;

/// A small pill with the plan ("Premium" / "Free").
fn plan_chip<'a, M: 'a>(plan: String, palette: HalcyonPalette) -> Element<'a, M> {
    container(text(plan).size(type_size::CAPTION).color(palette.accent))
        .padding([1, 8])
        .style(move |_t| container::Style {
            background: Some(alpha(palette.accent, 0.14).into()),
            border: iced::Border { radius: radius::PILL.into(), ..Default::default() },
            ..Default::default()
        })
        .into()
}

/// A hairline that stops short of the card's edges.
fn divider<'a, M: 'a>(palette: HalcyonPalette) -> Element<'a, M> {
    container(
        container(Space::with_height(1))
            .width(Length::Fill)
            .style(move |_t| container::Style {
                background: Some(alpha(palette.border, 0.6).into()),
                ..Default::default()
            }),
    )
    .padding([space::XS, space::SM])
    .into()
}

/// The dropdown card: a header with the picture, name, `@username` and plan, and where this app
/// is connected; then Settings and Spotify Settings; then Sign out apart from the rest.
#[allow(clippy::too_many_arguments)]
pub fn menu_card<'a, M: Clone + 'a>(
    name: String,
    handle: Option<String>,
    plan: Option<String>,
    device_line: String,
    image_url: Option<&str>,
    palette: HalcyonPalette,
    on_settings: M,
    on_spotify_settings: M,
    on_sign_out: M,
) -> Element<'a, M> {
    // The picture sits in a thin accent ring, like the button that opened the menu.
    let picture = container(avatar(&name, image_url, 44.0, palette))
        .padding(2)
        .style(move |_t| container::Style {
            border: iced::Border { color: alpha(palette.accent, 0.55), width: 1.5, radius: 26.0.into() },
            ..Default::default()
        });

    let mut who = column![text(name.clone()).size(type_size::BODY + 1.0).color(palette.text)].spacing(3);
    let mut second = row![].spacing(space::SM).align_y(Alignment::Center);
    if let Some(h) = handle {
        second = second.push(text(crate::views::ellipsize(&h, 18)).size(type_size::CAPTION).color(palette.text_muted));
    }
    if let Some(p) = plan {
        second = second.push(plan_chip(p, palette));
    }
    who = who.push(second);

    // Where this app is connected, with a small lit dot.
    let dot = container(Space::new(6, 6)).style(move |_t| container::Style {
        background: Some(palette.accent.into()),
        border: iced::Border { radius: 3.0.into(), ..Default::default() },
        ..Default::default()
    });
    let status = row![dot, text(device_line).size(type_size::CAPTION).color(palette.text_muted)]
        .spacing(space::SM)
        .align_y(Alignment::Center);

    let header = column![
        row![picture, Space::with_width(space::MD), who].align_y(Alignment::Center),
        Space::with_height(space::SM),
        status,
    ]
    .padding(iced::Padding { top: space::SM, right: space::SM, bottom: space::XS, left: space::SM });

    container(
        column![
            header,
            divider(palette),
            item(Icon::Settings, "Settings", palette, None, false, on_settings),
            item(Icon::Music, "Spotify settings", palette, Some(Icon::ExternalLink), false, on_spotify_settings),
            divider(palette),
            item(Icon::LogOut, "Sign out", palette, None, true, on_sign_out),
        ]
        .spacing(2),
    )
    .width(MENU_WIDTH)
    .padding(space::SM)
    .style(move |_t| container::Style {
        // A solid surface a little above the page, so the card is clearly in front of it.
        background: Some(crate::theme::mix(palette.surface, palette.text, 0.035).into()),
        border: iced::Border { color: palette.soft_border(), width: 1.0, radius: 22.0.into() },
        shadow: iced::Shadow {
            color: iced::Color { a: 0.45, ..iced::Color::BLACK },
            offset: iced::Vector::new(0.0, 12.0),
            blur_radius: 32.0,
        },
        ..Default::default()
    })
    .into()
}

/// A full-window layer: a transparent catcher that closes the menu on any click
/// outside it, and the menu itself at `left`/`top` from the window's top-left.
pub fn overlay<'a, M: Clone + 'a>(
    menu: Element<'a, M>,
    left: f32,
    top: f32,
    on_close: M,
) -> Element<'a, M> {
    stack![
        mouse_area(Space::new(Length::Fill, Length::Fill))
            .on_press(on_close.clone())
            .on_right_press(on_close),
        container(menu)
            .width(Length::Fill)
            .height(Length::Fill)
            .padding(Padding { top, left, right: 0.0, bottom: 0.0 }),
    ]
    .into()
}

/// Like `overlay`, but the card sits above a point near the bottom of the window (the dock's
/// account circle): `bottom` is the card's distance from the window's bottom edge.
pub fn overlay_above<'a, M: Clone + 'a>(
    menu: Element<'a, M>,
    left: f32,
    bottom: f32,
    on_close: M,
) -> Element<'a, M> {
    stack![
        mouse_area(Space::new(Length::Fill, Length::Fill))
            .on_press(on_close.clone())
            .on_right_press(on_close),
        container(menu)
            .width(Length::Fill)
            .height(Length::Fill)
            .align_y(iced::alignment::Vertical::Bottom)
            .padding(Padding { top: 0.0, left, right: 0.0, bottom }),
    ]
    .into()
}

#[cfg(test)]
mod tests {
    use super::initial;

    #[test]
    fn initial_is_the_first_letter_uppercased() {
        assert_eq!(initial("nex"), "N");
        assert_eq!(initial("  ada lovelace"), "A");
        assert_eq!(initial("émile"), "É");
    }

    #[test]
    fn initial_never_returns_nothing() {
        assert_eq!(initial(""), "?");
        assert_eq!(initial("   "), "?");
        assert_eq!(initial("!!!"), "?");
    }
}
