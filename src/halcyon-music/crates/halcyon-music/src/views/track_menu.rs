//! Right-click menu for a song: play, play next, add to queue, go to album.

use crate::theme::{radius, space, type_size, HalcyonPalette};
use iced::widget::{button, column, container, text};
use iced::{Element, Length};

pub const WIDTH: f32 = 208.0;
/// Four rows plus padding; used to keep the menu inside the window.
pub const HEIGHT: f32 = 4.0 * 36.0 + 2.0 * space::SM + 3.0 * 2.0;

fn entry<'a, M: Clone + 'a>(label: &'static str, palette: HalcyonPalette, msg: Option<M>) -> Element<'a, M> {
    let enabled = msg.is_some();
    let mut b = button(
        text(label)
            .size(type_size::BODY)
            .color(if enabled { palette.text } else { iced::Color { a: 0.4, ..palette.text_muted } }),
    )
    .width(Length::Fill)
    .padding([space::SM, space::MD])
    .style(move |_t, status| button::Style {
        background: Some(
            if enabled && matches!(status, button::Status::Hovered | button::Status::Pressed) {
                palette.surface_variant
            } else {
                iced::Color::TRANSPARENT
            }
            .into(),
        ),
        text_color: palette.text,
        border: iced::Border { radius: radius::SM.into(), ..Default::default() },
        ..Default::default()
    });
    if let Some(m) = msg {
        b = b.on_press(m);
    }
    b.into()
}

/// `go_album` is `None` when the song carries no album id (the entry is greyed out).
pub fn card<'a, M: Clone + 'a>(
    palette: HalcyonPalette,
    play: M,
    play_next: M,
    enqueue: M,
    go_album: Option<M>,
) -> Element<'a, M> {
    container(
        column![
            entry("Play", palette, Some(play)),
            entry("Play next", palette, Some(play_next)),
            entry("Add to queue", palette, Some(enqueue)),
            entry("Go to album", palette, go_album),
        ]
        .spacing(2),
    )
    .width(WIDTH)
    .padding(space::SM)
    .style(move |_t| container::Style {
        background: Some(palette.surface.into()),
        border: iced::Border { color: palette.border, width: 1.0, radius: radius::MD.into() },
        shadow: iced::Shadow {
            color: iced::Color { a: 0.35, ..iced::Color::BLACK },
            offset: iced::Vector::new(0.0, 6.0),
            blur_radius: 18.0,
        },
        ..Default::default()
    })
    .into()
}

/// Top-left corner for the menu so that it opens at the cursor but never leaves the window.
pub fn place(cursor: iced::Point, window: iced::Size) -> (f32, f32) {
    let x = cursor.x.min(window.width - WIDTH - space::SM).max(space::SM);
    let y = cursor.y.min(window.height - HEIGHT - space::SM).max(space::SM);
    (x, y)
}

#[cfg(test)]
mod tests {
    use super::*;
    use iced::{Point, Size};

    #[test]
    fn menu_opens_at_the_cursor_when_there_is_room() {
        assert_eq!(place(Point::new(100.0, 120.0), Size::new(1280.0, 800.0)), (100.0, 120.0));
    }

    #[test]
    fn menu_is_pulled_back_inside_at_the_edges() {
        let (x, y) = place(Point::new(1275.0, 795.0), Size::new(1280.0, 800.0));
        assert!(x + WIDTH <= 1280.0 && y + HEIGHT <= 800.0);
    }
}
