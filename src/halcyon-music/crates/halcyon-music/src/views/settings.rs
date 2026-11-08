//! Settings page: account, appearance, diagnostics, keyboard shortcuts.

use crate::avatar::AvatarSource;
use crate::icons::{icon, Icon};
use crate::shortcuts::SHORTCUT_HELP;
use crate::theme::{radius, space, type_size, Density, HalcyonPalette, Mood};
use halcyon_music_core::state::Bitrate;
use iced::widget::{button, column, container, row, text, Space};
use iced::{Alignment, Element, Length};

pub(crate) fn card<'a, M: 'a>(title: &'static str, body: Element<'a, M>, palette: HalcyonPalette) -> Element<'a, M> {
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

pub(crate) fn action<'a, M: Clone + 'a>(label: &'static str, trailing: Option<Icon>, palette: HalcyonPalette, msg: M) -> Element<'a, M> {
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
                radius: radius::MD.into(),
            },
            ..Default::default()
        })
        .into()
}

/// One selectable theme tile: a title, a one-line description, lit when it is the current one.
fn choice<'a, M: Clone + 'a>(
    title: &'static str,
    detail: &'static str,
    selected: bool,
    palette: HalcyonPalette,
    msg: M,
) -> Element<'a, M> {
    button(
        column![
            text(title).size(type_size::BODY).color(if selected { palette.accent } else { palette.text }),
            text(detail).size(type_size::SMALL).color(palette.text_muted),
        ]
        .spacing(4)
        .width(Length::Fill),
    )
    .on_press(msg)
    .width(Length::FillPortion(1))
    .padding(space::LG)
    .style(move |_t, status| {
        let hot = matches!(status, button::Status::Hovered | button::Status::Pressed);
        button::Style {
            background: Some(
                if selected {
                    crate::theme::alpha(palette.accent, 0.16)
                } else if hot {
                    crate::theme::alpha(palette.accent, 0.08)
                } else {
                    crate::theme::alpha(palette.surface_variant, 0.5)
                }
                .into(),
            ),
            text_color: palette.text,
            border: iced::Border {
                color: if selected { crate::theme::alpha(palette.accent, 0.6) } else { crate::theme::alpha(palette.border, 0.5) },
                width: 1.0,
                radius: radius::MD.into(),
            },
            ..Default::default()
        }
    })
    .into()
}

#[allow(clippy::too_many_arguments)]
#[allow(clippy::too_many_arguments)]
pub fn view<'a, M: Clone + 'a>(
    account_label: String,
    account_detail: String,
    avatar_source: AvatarSource,
    on_set_avatar: impl Fn(AvatarSource) -> M + 'a + Copy,
    on_refresh_profile: M,
    density: Density,
    mood: Mood,
    bitrate: Bitrate,
    normalisation: bool,
    palette: HalcyonPalette,
    on_toggle_density: M,
    on_set_mood: impl Fn(Mood) -> M + 'a + Copy,
    on_set_bitrate: impl Fn(Bitrate) -> M + 'a + Copy,
    on_toggle_normalisation: M,
    on_sign_out: M,
    on_spotify_settings: M,
    has_error: bool,
    on_open_diagnostics: M,
    on_copy_diagnostics: M,
    llm_card: Element<'a, M>,
) -> Element<'a, M> {
    let account = card(
        "Account",
        column![
            text(account_label).size(type_size::BODY).color(palette.accent),
            text(account_detail).size(type_size::SMALL).color(palette.text_muted),
            Space::with_height(space::LG),
            text("Account picture").size(type_size::BODY).color(palette.text),
            text("Which picture the round account button shows.")
                .size(type_size::SMALL)
                .color(palette.text_muted),
            Space::with_height(space::MD),
            row![
                choice(
                    AvatarSource::Halcyon.label(),
                    AvatarSource::Halcyon.detail(),
                    avatar_source == AvatarSource::Halcyon,
                    palette,
                    on_set_avatar(AvatarSource::Halcyon),
                ),
                choice(
                    AvatarSource::Spotify.label(),
                    AvatarSource::Spotify.detail(),
                    avatar_source == AvatarSource::Spotify,
                    palette,
                    on_set_avatar(AvatarSource::Spotify),
                ),
                choice(
                    AvatarSource::Initial.label(),
                    AvatarSource::Initial.detail(),
                    avatar_source == AvatarSource::Initial,
                    palette,
                    on_set_avatar(AvatarSource::Initial),
                ),
            ]
            .spacing(space::MD),
            Space::with_height(space::LG),
            row![
                action("Refresh account", None, palette, on_refresh_profile),
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
            text("Theme").size(type_size::BODY).color(palette.text),
            text("What the colours of the app follow.").size(type_size::SMALL).color(palette.text_muted),
            Space::with_height(space::MD),
            row![
                choice(
                    "Wallpaper",
                    "Matches your desktop wallpaper colours.",
                    mood == Mood::Wallpaper,
                    palette,
                    on_set_mood(Mood::Wallpaper),
                ),
                choice(
                    "Song colours",
                    "The whole page takes the colour of the song playing.",
                    mood == Mood::Song,
                    palette,
                    on_set_mood(Mood::Song),
                ),
                choice(
                    "Pitch black",
                    "Black, with an ambient glow in the song's colour.",
                    mood == Mood::Ambient,
                    palette,
                    on_set_mood(Mood::Ambient),
                ),
            ]
            .spacing(space::MD),
            Space::with_height(space::LG),
            text("Fixed rooms").size(type_size::SMALL).color(palette.text_muted),
            Space::with_height(space::SM),
            row![
                choice("Dusk", "Plum and peach.", mood == Mood::Dusk, palette, on_set_mood(Mood::Dusk)),
                choice("Dawn", "Cream and rose.", mood == Mood::Dawn, palette, on_set_mood(Mood::Dawn)),
                choice("Forest", "Moss and honey.", mood == Mood::Forest, palette, on_set_mood(Mood::Forest)),
                choice("Ocean", "Blue-teal night.", mood == Mood::Ocean, palette, on_set_mood(Mood::Ocean)),
            ]
            .spacing(space::MD),
            Space::with_height(space::XL),
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

    // Audio quality, like Spotify's: the daemon rebuilds its player with the new bitrate and
    // carries on from the same spot, so the change is heard right away.
    let audio = card(
        "Audio quality",
        column![
            text("Streaming quality").size(type_size::BODY).color(palette.text),
            text("Higher quality sounds better and uses more data.")
                .size(type_size::SMALL)
                .color(palette.text_muted),
            Space::with_height(space::MD),
            row![
                choice(
                    "Low",
                    "96 kbps. Saves data.",
                    bitrate == Bitrate::Bitrate96,
                    palette,
                    on_set_bitrate(Bitrate::Bitrate96),
                ),
                choice(
                    "Normal",
                    "160 kbps. Good for everyday listening.",
                    bitrate == Bitrate::Bitrate160,
                    palette,
                    on_set_bitrate(Bitrate::Bitrate160),
                ),
                choice(
                    "Very high",
                    "320 kbps. The best Spotify streams.",
                    bitrate == Bitrate::Bitrate320,
                    palette,
                    on_set_bitrate(Bitrate::Bitrate320),
                ),
            ]
            .spacing(space::MD),
            Space::with_height(space::XL),
            row![
                column![
                    text("Normalise volume").size(type_size::BODY).color(palette.text),
                    text("Plays every song at about the same loudness.")
                        .size(type_size::SMALL)
                        .color(palette.text_muted),
                ]
                .spacing(2),
                Space::with_width(Length::Fill),
                action(if normalisation { "On" } else { "Off" }, None, palette, on_toggle_normalisation),
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
        audio,
        llm_card,
        diagnostics,
        shortcuts,
    ]
    .spacing(space::XL)
    .padding(space::XL)
    .width(Length::Fill)
    .into()
}
