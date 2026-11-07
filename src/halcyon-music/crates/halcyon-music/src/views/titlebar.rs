//! Slim custom title bar (replaces the system one).
//!
//! Left: the app name and a star that is lit while the daemon is connected.
//! Right: minimise, maximise and close. The empty middle is the drag handle;
//! the app decides what a press there means (drag, or toggle maximise on a
//! double press), so this file stays a pure view.

use crate::icons::{icon, Icon};
use crate::theme::{space, type_size, HalcyonPalette};
use iced::widget::{button, container, mouse_area, row, text, tooltip, Space};
use iced::{Alignment, Element, Length};

pub const HEIGHT: f32 = 36.0;
const BUTTON_WIDTH: f32 = 46.0;

/// The tooltip text for the star.
pub fn connection_label(connected: bool) -> &'static str {
    if connected {
        "Connected"
    } else {
        "Not connected"
    }
}

fn tip<'a, M: 'a>(label: &'static str, palette: HalcyonPalette) -> Element<'a, M> {
    container(text(label).size(type_size::SMALL).color(palette.text))
        .padding([space::XS, space::SM])
        .style(move |_t| container::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                color: palette.border,
                width: 1.0,
                radius: crate::theme::radius::SM.into(),
            },
            ..Default::default()
        })
        .into()
}

fn window_button<'a, M: Clone + 'a>(
    glyph: Icon,
    palette: HalcyonPalette,
    danger: bool,
    msg: M,
) -> Element<'a, M> {
    button(
        container(icon(glyph, 14.0, palette.text_muted))
            .width(Length::Fill)
            .height(Length::Fill)
            .center_x(Length::Fill)
            .center_y(Length::Fill),
    )
    .on_press(msg)
    .width(BUTTON_WIDTH)
    .height(HEIGHT)
    .padding(0)
    .style(move |_t, status| {
        let hovered = matches!(status, button::Status::Hovered | button::Status::Pressed);
        button::Style {
            background: Some(
                if hovered && danger {
                    palette.danger
                } else if hovered {
                    palette.surface_variant
                } else {
                    iced::Color::TRANSPARENT
                }
                .into(),
            ),
            text_color: palette.text,
            border: iced::Border::default(),
            ..Default::default()
        }
    })
    .into()
}

pub fn view<'a, M: Clone + 'a>(
    connected: bool,
    palette: HalcyonPalette,
    on_press_bar: M,
    on_minimize: M,
    on_toggle_maximize: M,
    on_close: M,
) -> Element<'a, M> {
    let star = tooltip(
        icon(
            if connected { Icon::StarFilled } else { Icon::Star },
            14.0,
            if connected {
                palette.accent
            } else {
                iced::Color { a: 0.55, ..palette.text_muted }
            },
        ),
        tip(connection_label(connected), palette),
        tooltip::Position::Bottom,
    );

    let brand = row![
        text("Halcyon").size(type_size::BODY).color(palette.text),
        Space::with_width(space::SM),
        star,
    ]
    .align_y(Alignment::Center);

    let drag_area = mouse_area(
        container(brand)
            .width(Length::Fill)
            .height(HEIGHT)
            .padding([0.0, space::LG])
            .align_y(iced::alignment::Vertical::Center),
    )
    .on_press(on_press_bar);

    let controls = row![
        window_button(Icon::Minus, palette, false, on_minimize),
        window_button(Icon::Square, palette, false, on_toggle_maximize),
        window_button(Icon::Close, palette, true, on_close),
    ];

    container(row![drag_area, controls].align_y(Alignment::Center))
        .width(Length::Fill)
        .height(HEIGHT)
        .style(move |_t| container::Style {
            background: Some(palette.background.into()),
            border: iced::Border {
                color: palette.border,
                width: 0.5,
                ..Default::default()
            },
            ..Default::default()
        })
        .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn star_tooltip_text_matches_the_spec() {
        assert_eq!(connection_label(true), "Connected");
        assert_eq!(connection_label(false), "Not connected");
    }
}
