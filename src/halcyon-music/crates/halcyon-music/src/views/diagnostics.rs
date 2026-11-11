//! "Something went wrong?" diagnostics modal.
//!
//! Provides plain-language explanations of daemon/player state and
//! a single-click "Copy Diagnostics" button for reporting.

use crate::animation::{motion, FrameStats};
use crate::client::ConnStatus;
use crate::icons::{icon, Icon};
use crate::theme::HalcyonPalette;
use halcyon_music_core::models::AuthStatus;
use halcyon_music_core::state::PlayerState;
use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Element, Length};

/// How often the animation ticks arrived while something moved.
pub fn frame_cadence_line(f: &FrameStats) -> String {
    if f.ticks == 0 {
        return "not measured yet (nothing has animated)".to_string();
    }
    format!(
        "{} ticks, average {:.1} ms, worst {:.1} ms, {} late",
        f.ticks, f.avg_gap_ms, f.worst_gap_ms, f.late_ticks
    )
}

/// How long building the interface took, against the 16 ms budget.
pub fn view_build_line(f: &FrameStats) -> String {
    if f.views == 0 {
        return "not measured yet".to_string();
    }
    format!(
        "{} builds, average {:.1} ms, worst {:.1} ms, {} over {} ms",
        f.views,
        f.avg_view_ms,
        f.worst_view_ms,
        f.slow_views,
        motion::FRAME_BUDGET_MS as u32
    )
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    status: &'a ConnStatus,
    auth_status: &'a AuthStatus,
    state: &'a PlayerState,
    last_error: Option<&'a str>,
    frame: FrameStats,
    reduce_motion: bool,
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
            background: Some(
                iced::Color {
                    a: 0.1,
                    ..palette.danger
                }
                .into(),
            ),
            border: iced::Border {
                radius: 18.0.into(),
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
                radius: 18.0.into(),
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
            text("Something went wrong? — Diagnostics")
                .size(18)
                .color(palette.text),
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
        info_row(
            "Control Socket:",
            "$XDG_RUNTIME_DIR/halcyon-music/ctl.sock".to_string()
        ),
        info_row(
            "Cache Database:",
            "~/.cache/halcyon-music/cache.db".to_string()
        ),
        info_row(
            "Self-healing:",
            "Watchdog active (auto-recovers on stall)".to_string()
        ),
        info_row(
            "Motion:",
            if reduce_motion {
                "Reduced (nothing animates)".to_string()
            } else {
                "On".to_string()
            }
        ),
        info_row("Frame cadence:", frame_cadence_line(&frame)),
        info_row("Interface build:", view_build_line(&frame)),
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
                    radius: 18.0.into(),
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
                        if s == button::Status::Hovered {
                            crate::theme::mix(palette.surface, palette.accent, 0.16)
                        } else {
                            crate::theme::alpha(palette.surface, 0.62)
                        }
                        .into(),
                    ),
                    border: iced::Border {
                        radius: 18.0.into(),
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
                    radius: 26.0.into(),
                    color: palette.soft_border(),
                    width: 1.0,
                },
                shadow: iced::Shadow {
                    color: iced::Color {
                        a: 0.5,
                        ..iced::Color::BLACK
                    },
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
        background: Some(
            iced::Color {
                a: 0.65,
                ..iced::Color::BLACK
            }
            .into(),
        ),
        ..Default::default()
    })
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn readout_says_when_nothing_was_measured() {
        let f = FrameStats::default();
        assert!(frame_cadence_line(&f).contains("not measured"));
        assert!(view_build_line(&f).contains("not measured"));
    }

    #[test]
    fn readout_shows_numbers_and_the_budget() {
        let f = FrameStats {
            ticks: 120,
            avg_gap_ms: 16.7,
            worst_gap_ms: 31.2,
            late_ticks: 2,
            views: 300,
            avg_view_ms: 2.4,
            worst_view_ms: 9.1,
            slow_views: 0,
        };
        assert_eq!(
            frame_cadence_line(&f),
            "120 ticks, average 16.7 ms, worst 31.2 ms, 2 late"
        );
        assert_eq!(
            view_build_line(&f),
            "300 builds, average 2.4 ms, worst 9.1 ms, 0 over 16 ms"
        );
    }
}
