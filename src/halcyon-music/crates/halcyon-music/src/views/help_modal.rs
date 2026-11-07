//! Keyboard shortcuts modal overlay (`?`).

use crate::icons::{icon, Icon};
use crate::theme::HalcyonPalette;
use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

pub fn view<'a, Message: Clone + 'static>(
    palette: HalcyonPalette,
    on_close: Message,
) -> Element<'a, Message> {
    let row_item = |key: &'static str, desc: &'static str| {
        row![
            container(text(key).size(12).color(palette.accent))
                .padding([4, 8])
                .style(move |_t| container::Style {
                    background: Some(palette.surface_variant.into()),
                    border: iced::Border {
                        radius: 4.0.into(),
                        ..Default::default()
                    },
                    ..Default::default()
                }),
            Space::with_width(12),
            text(desc).size(13).color(palette.text),
        ]
        .align_y(Alignment::Center)
    };

    let content = column![
        row![
            text("Keyboard Shortcuts").size(18).color(palette.text),
            Space::with_width(Length::Fill),
            button(icon(Icon::Close, 16.0, palette.text_muted))
                .on_press(on_close)
                .padding(4)
                .style(|_t, _s| button::Style::default()),
        ]
        .align_y(Alignment::Center),
        Space::with_height(16),
        row_item("Space", "Play / Pause"),
        row_item("N / P", "Next / Previous track"),
        row_item("Left / Right", "Seek backward / forward 5s"),
        row_item("Shift + Left / Right", "Seek backward / forward 30s"),
        row_item("Up / Down", "Volume up / down"),
        row_item("M", "Mute toggle"),
        row_item("S", "Shuffle toggle"),
        row_item("R", "Cycle Repeat (Off -> All -> One)"),
        row_item("L", "Like / Save track"),
        row_item("/ or Ctrl + K", "Search library & Spotify"),
        row_item("Ctrl + L", "Toggle Lyrics view"),
        row_item("Q", "Toggle Queue panel"),
        row_item("1 - 6", "Jump to Page (Home, Search, Library, Liked, Capsule, Settings)"),
        row_item("F", "Toggle Full-screen Now Playing"),
        row_item("Ctrl + R", "Refresh library and probes"),
        row_item("Esc", "Close overlay / Exit full-screen"),
    ]
    .spacing(8);

    container(
        container(scrollable(content).height(Length::Fill))
            .width(440)
            .height(480)
            .padding(24)
            .style(move |_t| container::Style {
                background: Some(palette.surface.into()),
                border: iced::Border {
                    radius: 12.0.into(),
                    color: palette.border,
                    width: 1.5,
                },
                shadow: iced::Shadow {
                    color: iced::Color { a: 0.5, ..iced::Color::BLACK },
                    offset: iced::Vector::new(0.0, 8.0),
                    blur_radius: 24.0,
                },
                ..Default::default()
            }),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .center_x(Length::Fill)
    .center_y(Length::Fill)
    .style(|_t| container::Style {
        background: Some(iced::Color { a: 0.6, ..iced::Color::BLACK }.into()),
        ..Default::default()
    })
    .into()
}
