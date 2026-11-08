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
/// Room right of the window buttons and above/below them, so a lit button stays inside the
/// window's rounded corner instead of poking out of it.
const CONTROLS_INSET: f32 = 8.0;
const BUTTON_HEIGHT: f32 = HEIGHT - 2.0 * 4.0;

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
                color: palette.soft_border(),
                width: 1.0,
                radius: crate::theme::radius::SM.into(),
            },
            shadow: palette.glow_shadow(0.12, 12.0),
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
    .height(BUTTON_HEIGHT)
    .padding(0)
    .style(move |_t, status| {
        let hovered = matches!(status, button::Status::Hovered | button::Status::Pressed);
        button::Style {
            background: Some(
                if hovered && danger {
                    crate::theme::alpha(palette.danger, 0.85)
                } else if hovered {
                    crate::theme::alpha(palette.accent, 0.16)
                } else {
                    iced::Color::TRANSPARENT
                }
                .into(),
            ),
            text_color: palette.text,
            border: iced::Border {
                radius: crate::theme::radius::SM.into(),
                ..Default::default()
            },
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
        text("Halcyon").size(type_size::BODY).color(palette.text_muted),
        Space::with_width(space::SM),
        star,
    ]
    .align_y(Alignment::Center);

    // The name sits in the middle of the bar. An empty block as wide as the three window
    // buttons on the left keeps it centred on the window rather than on the free space.
    let drag_area = mouse_area(
        row![
            // As wide as the window buttons and their inset on the right.
            Space::with_width(BUTTON_WIDTH * 3.0 + CONTROLS_INSET),
            container(brand)
                .width(Length::Fill)
                .height(HEIGHT)
                .center_x(Length::Fill)
                .align_y(iced::alignment::Vertical::Center),
        ],
    )
    .on_press(on_press_bar);

    let controls = row![
        window_button(Icon::Minus, palette, false, on_minimize),
        window_button(Icon::Square, palette, false, on_toggle_maximize),
        window_button(Icon::Close, palette, true, on_close),
    ];

    let controls = container(controls).padding(iced::Padding {
        top: 0.0,
        right: CONTROLS_INSET,
        bottom: 0.0,
        left: 0.0,
    });

    container(row![drag_area, controls].align_y(Alignment::Center))
        .width(Length::Fill)
        .height(HEIGHT)
        // No fill and no line: the page gradient flows straight up under the title.
        .style(move |_t| container::Style::default())
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
