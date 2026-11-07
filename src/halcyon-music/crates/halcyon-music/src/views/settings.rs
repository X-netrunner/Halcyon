//! Settings page: account, appearance, keyboard shortcuts.

use crate::icons::{icon, Icon};
use crate::shortcuts::SHORTCUT_HELP;
use crate::theme::{radius, space, type_size, Density, HalcyonPalette};
use iced::widget::{button, column, container, row, text, Space};
use iced::{Alignment, Element, Length};

fn card<'a, M: 'a>(title: &'static str, body: Element<'a, M>, palette: HalcyonPalette) -> Element<'a, M> {
    container(
        column![
            text(title).size(type_size::TITLE).color(palette.text),
            Space::with_height(space::MD),
            body,
        ],
    )
    .width(Length::Fill)
    .padding(space::XL)
    .style(move |_t| container::Style {
        background: Some(palette.surface.into()),
        border: iced::Border { color: palette.border, width: 1.0, radius: radius::LG.into() },
        ..Default::default()
    })
    .into()
}

fn action<'a, M: Clone + 'a>(label: &'static str, trailing: Option<Icon>, palette: HalcyonPalette, msg: M) -> Element<'a, M> {
    let mut r = row![text(label).size(type_size::BODY).color(palette.text)].align_y(Alignment::Center);
    if let Some(t) = trailing {
        r = r.push(Space::with_width(space::SM));
        r = r.push(icon(t, 13.0, palette.text_muted));
    }
    button(r)
        .on_press(msg)
        .padding([space::SM, space::LG])
        .style(move |_t, status| button::Style {
            background: Some(
                if matches!(status, button::Status::Hovered | button::Status::Pressed) {
                    palette.surface_variant
                } else {
                    palette.background
                }
                .into(),
            ),
            text_color: palette.text,
            border: iced::Border { color: palette.border, width: 1.0, radius: radius::MD.into() },
            ..Default::default()
        })
        .into()
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, M: Clone + 'a>(
    account_label: String,
    density: Density,
    palette: HalcyonPalette,
    on_toggle_density: M,
    on_sign_out: M,
    on_spotify_settings: M,
) -> Element<'a, M> {
    let account = card(
        "Account",
        column![
            text(account_label).size(type_size::BODY).color(palette.accent),
            Space::with_height(space::MD),
            row![
                action("Spotify account settings", Some(Icon::ExternalLink), palette, on_spotify_settings),
                action("Sign out", None, palette, on_sign_out),
            ]
            .spacing(space::MD),
        ]
        .into(),
        palette,
    );

    let appearance = card(
        "Appearance",
        row![
            text("Row density").size(type_size::BODY).color(palette.text),
            Space::with_width(Length::Fill),
            action(
                match density {
                    Density::Comfortable => "Comfortable",
                    Density::Compact => "Compact",
                },
                None,
                palette,
                on_toggle_density,
            ),
        ]
        .align_y(Alignment::Center)
        .into(),
        palette,
    );

    let mut keys = column![].spacing(space::SM);
    for (key, what) in SHORTCUT_HELP {
        keys = keys.push(
            row![
                container(text(*key).size(type_size::SMALL).color(palette.accent))
                    .padding([space::XS, space::SM])
                    .width(190)
                    .style(move |_t| container::Style {
                        background: Some(palette.surface_variant.into()),
                        border: iced::Border { radius: radius::SM.into(), ..Default::default() },
                        ..Default::default()
                    }),
                Space::with_width(space::LG),
                text(*what).size(type_size::BODY).color(palette.text),
            ]
            .align_y(Alignment::Center),
        );
    }
    let shortcuts = card("Keyboard shortcuts", keys.into(), palette);

    column![
        text("Settings").size(type_size::HEADING).color(palette.text),
        account,
        appearance,
        shortcuts,
    ]
    .spacing(space::XL)
    .padding(space::XL)
    .max_width(820)
    .into()
}
