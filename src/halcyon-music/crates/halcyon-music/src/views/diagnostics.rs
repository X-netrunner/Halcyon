//! "Something went wrong?" diagnostics modal.
//!
//! Provides plain-language explanations of daemon/player state and
//! a single-click "Copy Diagnostics" button for reporting.

use crate::icons::{icon, Icon};
use crate::client::ConnStatus;
use crate::theme::HalcyonPalette;
use halcyon_music_core::models::AuthStatus;
use halcyon_music_core::state::PlayerState;
use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

pub fn view<'a, Message: Clone + 'static>(
    status: &'a ConnStatus,
    auth_status: &'a AuthStatus,
    state: &'a PlayerState,
    last_error: Option<&'a str>,
    palette: HalcyonPalette,
    on_copy: Message,
    on_close: Message,
) -> Element<'a, Message> {
    let daemon_str = match status {
        ConnStatus::Connected { .. } => "Connected (Healthy)",
        ConnStatus::Connecting => "Connecting...",
        ConnStatus::SpawnedDaemon => "Spawned background daemon",
        ConnStatus::Reconnecting { .. } => "Reconnecting...",
        ConnStatus::Failed(err) => err.as_str(),
    };

    let auth_str = match auth_status {
        AuthStatus::LoggedIn { user_id, .. } => {
            if let Some(uid) = user_id {
                format!("Logged in as {uid}")
            } else {
                "Logged in (Active session)".to_string()
            }
        }
        AuthStatus::LoggingIn { .. } => "Authenticating in browser...".to_string(),
        AuthStatus::LoggedOut => "Not logged in".to_string(),
        AuthStatus::Error { message } => format!("Auth error: {message}"),
    };

    let playback_str = if state.playing {
        if let Some(ref t) = state.track {
            format!("Playing: \"{}\" by {}", t.title, t.artist)
        } else {
            "Playing (no track info)".to_string()
        }
    } else if state.track.is_some() {
        "Paused".to_string()
    } else {
        "Idle / Stopped".to_string()
    };

    let error_section: Element<Message> = if let Some(err) = last_error {
        container(
            column![
                row![
                    icon(Icon::XCircle, 16.0, palette.danger),
                    Space::with_width(8),
                    text("Last Reported Error:").size(13).color(palette.danger),
                ]
                .align_y(Alignment::Center),
                Space::with_height(6),
                text(err).size(13).color(palette.text),
            ]
            .padding(12),
        )
        .style(move |_t| container::Style {
            background: Some(iced::Color { a: 0.1, ..palette.danger }.into()),
            border: iced::Border {
                radius: 12.0.into(),
                color: palette.danger,
                width: 1.0,
            },
            ..Default::default()
        })
        .width(Length::Fill)
        .into()
    } else {
        container(
            row![
                icon(Icon::Check, 16.0, palette.accent),
                Space::with_width(8),
                text("No active errors reported. Daemon is operating normally.")
                    .size(13)
                    .color(palette.text_muted),
            ]
            .align_y(Alignment::Center)
            .padding(12),
        )
        .style(move |_t| container::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                radius: 12.0.into(),
                color: palette.soft_border(),
                width: 0.5,
            },
            ..Default::default()
        })
        .width(Length::Fill)
        .into()
    };

    let info_row = |label: &'static str, val: String| {
        row![
            text(label).size(13).color(palette.text_muted).width(160),
            text(val).size(13).color(palette.text).width(Length::Fill),
        ]
        .align_y(Alignment::Center)
    };

    let content = column![
        row![
            text("Something went wrong? — Diagnostics").size(18).color(palette.text),
            Space::with_width(Length::Fill),
            button(icon(Icon::Close, 16.0, palette.text_muted))
                .on_press(on_close.clone())
                .padding(4)
                .style(|_t, _s| button::Style::default()),
        ]
        .align_y(Alignment::Center),
        Space::with_height(14),
        error_section,
        Space::with_height(14),
        info_row("Daemon Status:", daemon_str.to_string()),
        info_row("Spotify Session:", auth_str),
        info_row("Playback Engine:", playback_str),
        info_row("Queue Length:", format!("{} tracks", state.queue.len())),
        info_row("Volume:", format!("{}%", state.volume)),
        info_row("Control Socket:", "$XDG_RUNTIME_DIR/halcyon-music/ctl.sock".to_string()),
        info_row("Cache Database:", "~/.cache/halcyon-music/cache.db".to_string()),
        info_row("Self-healing:", "Watchdog active (auto-recovers on stall)".to_string()),
        Space::with_height(20),
        row![
            button(
                row![
                    icon(Icon::Copy, 14.0, palette.background),
                    Space::with_width(8),
                    text("Copy Diagnostics").size(13).color(palette.background),
                ]
                .align_y(Alignment::Center)
            )
            .on_press(on_copy)
            .padding([8, 16])
            .style(move |_t, _s| button::Style {
                background: Some(palette.accent_background()),
                border: iced::Border {
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            }),
            Space::with_width(12),
            button(text("Close").size(13).color(palette.text))
                .on_press(on_close)
                .padding([8, 16])
                .style(move |_t, s| button::Style {
                    background: Some(
                        if s == button::Status::Hovered { crate::theme::mix(palette.surface, palette.accent, 0.16) } else { crate::theme::alpha(palette.surface, 0.62) }
                        .into(),
                    ),
                    border: iced::Border {
                        radius: 12.0.into(),
                        color: palette.soft_border(),
                        width: 0.5,
                    },
                    ..Default::default()
                }),
        ]
        .align_y(Alignment::Center),
    ]
    .spacing(8);

    container(
        container(scrollable(content).height(Length::Shrink))
            .width(520)
            .padding(24)
            .style(move |_t| container::Style {
                background: Some(palette.card_background()),
                border: iced::Border {
                    radius: 20.0.into(),
                    color: palette.soft_border(),
                    width: 1.0,
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
        background: Some(iced::Color { a: 0.65, ..iced::Color::BLACK }.into()),
        ..Default::default()
    })
    .into()
}
