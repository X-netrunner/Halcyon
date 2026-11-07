//! Account circle (profile picture or initial) and its dropdown menu.

use crate::icons::{icon, Icon};
use crate::theme::{radius, space, type_size, HalcyonPalette};
use halcyon_music_core::art::ArtSize;
use iced::widget::{button, column, container, mouse_area, row, stack, text, Space};
use iced::{Alignment, Element, Length, Padding};

pub const AVATAR_SIZE: f32 = 32.0;
pub const MENU_WIDTH: f32 = 248.0;

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

fn item<'a, M: Clone + 'a>(
    glyph: Icon,
    label: &'static str,
    palette: HalcyonPalette,
    trailing: Option<Icon>,
    msg: M,
) -> Element<'a, M> {
    let mut content = row![
        icon(glyph, 16.0, palette.text_muted),
        Space::with_width(space::MD),
        text(label).size(type_size::BODY).color(palette.text).width(Length::Fill),
    ]
    .align_y(Alignment::Center);
    if let Some(t) = trailing {
        content = content.push(icon(t, 13.0, palette.text_muted));
    }
    button(content)
        .on_press(msg)
        .width(Length::Fill)
        .padding([space::SM, space::MD])
        .style(move |_t, status| button::Style {
            background: Some(
                if matches!(status, button::Status::Hovered | button::Status::Pressed) {
                    palette.surface_variant
                } else {
                    iced::Color::TRANSPARENT
                }
                .into(),
            ),
            text_color: palette.text,
            border: iced::Border { radius: radius::SM.into(), ..Default::default() },
            ..Default::default()
        })
        .into()
}

/// The dropdown card: name, Settings, Spotify Settings, Sign out.
pub fn menu_card<'a, M: Clone + 'a>(
    name: String,
    image_url: Option<&str>,
    palette: HalcyonPalette,
    on_settings: M,
    on_spotify_settings: M,
    on_sign_out: M,
) -> Element<'a, M> {
    let header = row![
        avatar(&name, image_url, 36.0, palette),
        Space::with_width(space::MD),
        column![
            text(name.clone()).size(type_size::BODY).color(palette.text),
            text("Spotify account").size(type_size::CAPTION).color(palette.text_muted),
        ]
        .spacing(2),
    ]
    .align_y(Alignment::Center)
    .padding([space::SM, space::MD]);

    let divider = container(Space::with_height(1))
        .width(Length::Fill)
        .style(move |_t| container::Style {
            background: Some(palette.border.into()),
            ..Default::default()
        });

    container(
        column![
            header,
            divider,
            Space::with_height(space::XS),
            item(Icon::Settings, "Settings", palette, None, on_settings),
            item(Icon::Playlist, "Spotify Settings", palette, Some(Icon::ExternalLink), on_spotify_settings),
            item(Icon::LogOut, "Sign out", palette, None, on_sign_out),
        ]
        .spacing(2),
    )
    .width(MENU_WIDTH)
    .padding(space::SM)
    .style(move |_t| container::Style {
        background: Some(palette.card_background()),
        border: iced::Border { color: palette.soft_border(), width: 1.0, radius: radius::MD.into() },
        shadow: iced::Shadow {
            color: iced::Color { a: 0.35, ..iced::Color::BLACK },
            offset: iced::Vector::new(0.0, 6.0),
            blur_radius: 18.0,
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
