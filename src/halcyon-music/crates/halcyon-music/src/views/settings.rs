//! Settings page: account, appearance, diagnostics, keyboard shortcuts.

use crate::icons::{icon, Icon};
use crate::shortcuts::SHORTCUT_HELP;
use crate::theme::{radius, space, type_size, Density, HalcyonPalette, Mood};
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
    .style(crate::views::card(palette))
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
                    crate::theme::alpha(palette.accent, 0.20)
                } else {
                    crate::theme::alpha(palette.accent, 0.08)
                }
                .into(),
            ),
            text_color: palette.text,
            border: iced::Border {
                color: crate::theme::alpha(palette.accent, 0.30),
                width: 1.0,
                radius: radius::PILL.into(),
            },
            ..Default::default()
        })
        .into()
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, M: Clone + 'a>(
    account_label: String,
    density: Density,
    mood: Mood,
    palette: HalcyonPalette,
    on_toggle_density: M,
    on_cycle_mood: M,
    on_sign_out: M,
    on_spotify_settings: M,
    has_error: bool,
    on_open_diagnostics: M,
    on_copy_diagnostics: M,
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
        column![
            row![
                column![
                    text("Mood").size(type_size::BODY).color(palette.text),
                    text("Wallpaper follows your desktop colours. Dusk, Dawn, Forest and Ocean are fixed rooms.")
                        .size(type_size::SMALL)
                        .color(palette.text_muted),
                ]
                .spacing(2),
                Space::with_width(Length::Fill),
                action(mood.label(), None, palette, on_cycle_mood),
            ]
            .align_y(Alignment::Center),
            Space::with_height(space::LG),
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
            .align_y(Alignment::Center),
        ]
        .into(),
        palette,
    );

    let status_line = if has_error {
        "Something went wrong recently. Open the report to see what."
    } else {
        "Connection, sign-in and playback status, and the last error if there was one."
    };
    let diagnostics = card(
        "Diagnostics",
        column![
            text(status_line)
                .size(type_size::SMALL)
                .color(if has_error { palette.danger } else { palette.text_muted }),
            Space::with_height(space::MD),
            row![
                action("Open diagnostics", Some(Icon::Activity), palette, on_open_diagnostics),
                action("Copy report", Some(Icon::Copy), palette, on_copy_diagnostics),
            ]
            .spacing(space::MD),
        ]
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
                        background: Some(crate::theme::alpha(palette.accent, 0.10).into()),
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
        text("Settings").size(type_size::HEADING + 6.0).color(palette.text),
        account,
        appearance,
        diagnostics,
        shortcuts,
    ]
    .spacing(space::XL)
    .padding(space::XL)
    .max_width(820)
    .into()
}
