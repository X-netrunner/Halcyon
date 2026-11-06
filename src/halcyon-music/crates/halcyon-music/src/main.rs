//! halcyon-music — the GUI client.
//!
//! Part 2:
//! - First-run flow with Client ID paste and 4-step Spotify app setup instructions
//! - PKCE browser login flow
//! - Stale-while-revalidate display of cached playlists and tracks
//! - Clean offline degradation ("Offline" status, instant cache render)
//! - Explicit "Log in again" prompt on token revocation (no error loop)

// Part 0 rules apply to non-test code; tests may use expect/unwrap freely.
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing
    )
)]

mod client;

use client::{ConnStatus, UiEvent};
use halcyon_music_core::models::{AuthStatus, Playlist};
use halcyon_music_core::protocol::{CommandBody, EventBody};
use halcyon_music_core::PlayerState;
use iced::widget::{button, column, container, row, scrollable, text, text_input, Space};
use iced::{Alignment, Element, Length, Task, Theme};

pub fn main() -> iced::Result {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt().with_env_filter(filter).try_init();

    let window_settings = iced::window::Settings {
        platform_specific: iced::window::settings::PlatformSpecific {
            application_id: "halcyon-music".to_string(),
            ..Default::default()
        },
        ..Default::default()
    };

    iced::application("Halcyon Music", HalcyonApp::update, HalcyonApp::view)
        .window(window_settings)
        .theme(|_| Theme::Dark)
        .run_with(HalcyonApp::new)
}

struct HalcyonApp {
    status: ConnStatus,
    state: PlayerState,
    commands: tokio::sync::mpsc::Sender<CommandBody>,
    last_error: Option<String>,
    // Part 2 state
    auth_status: AuthStatus,
    client_id_input: String,
    auth_reason: Option<String>,
    playlists: Vec<Playlist>,
    is_offline: bool,
}

#[derive(Debug, Clone)]
enum Message {
    UiEvent(Box<UiEvent>),
    Toggle,
    Next,
    Previous,
    SeekBack,
    SeekForward,
    DismissError,
    // Auth & Part 2 actions
    ClientIdChanged(String),
    StartLogin,
    CancelLogin,
    Logout,
    OpenBrowserAuth(String),
    RefreshLibrary,
}

impl HalcyonApp {
    fn new() -> (Self, Task<Message>) {
        let mut client = client::connect();

        // Bridge the client's async event channel into iced's task world.
        let task = Task::run(
            iced::stream::channel(256, |mut out| async move {
                use iced::futures::SinkExt;
                loop {
                    match client.events.recv().await {
                        Some(ev) => {
                            let _ = out.send(Message::UiEvent(Box::new(ev))).await;
                        }
                        None => std::future::pending::<()>().await,
                    }
                }
            }),
            |m| m,
        );

        let app = Self {
            status: ConnStatus::Connecting,
            state: PlayerState::default(),
            commands: client.commands,
            last_error: None,
            auth_status: AuthStatus::LoggedOut,
            client_id_input: String::new(),
            auth_reason: None,
            playlists: Vec::new(),
            is_offline: false,
        };
        (app, task)
    }

    fn send(&self, body: CommandBody) {
        let _ = self.commands.try_send(body);
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::UiEvent(ev) => match *ev {
                UiEvent::Status(s) => {
                    self.status = s;
                    if let ConnStatus::Connected { .. } = &self.status {
                        self.send(CommandBody::GetAuthStatus);
                        self.send(CommandBody::GetPlaylists {
                            limit: Some(20),
                            offset: Some(0),
                        });
                    }
                    Task::none()
                }
                UiEvent::DaemonError(msg) => {
                    self.last_error = Some(msg);
                    Task::none()
                }
                UiEvent::Protocol(boxed_ev) => match boxed_ev.body {
                    EventBody::State { state } => {
                        self.state = state;
                        Task::none()
                    }
                    EventBody::Progress {
                        position_ms,
                        playing,
                    } => {
                        self.state.position_ms = position_ms;
                        self.state.playing = playing;
                        Task::none()
                    }
                    EventBody::Queue { tracks } => {
                        self.state.queue = tracks;
                        Task::none()
                    }
                    EventBody::AuthStatus(status) => {
                        if let AuthStatus::LoggingIn { ref auth_url } = status {
                            let url = auth_url.clone();
                            self.auth_status = status;
                            return Task::perform(async move { url }, Message::OpenBrowserAuth);
                        }
                        self.auth_status = status;
                        if matches!(self.auth_status, AuthStatus::LoggedIn { .. }) {
                            self.auth_reason = None;
                            self.send(CommandBody::GetPlaylists {
                                limit: Some(20),
                                offset: Some(0),
                            });
                        }
                        Task::none()
                    }
                    EventBody::AuthRequired { reason } => {
                        self.auth_status = AuthStatus::LoggedOut;
                        self.auth_reason = Some(reason);
                        Task::none()
                    }
                    EventBody::AuthSuccess { .. } => {
                        self.auth_reason = None;
                        self.send(CommandBody::GetAuthStatus);
                        self.send(CommandBody::GetPlaylists {
                            limit: Some(20),
                            offset: Some(0),
                        });
                        Task::none()
                    }
                    EventBody::PlaylistsResult {
                        playlists,
                        is_cached,
                        ..
                    } => {
                        self.playlists = playlists;
                        self.is_offline = is_cached;
                        Task::none()
                    }
                    _ => Task::none(),
                },
            },
            Message::Toggle => {
                self.send(CommandBody::Toggle);
                Task::none()
            }
            Message::Next => {
                self.send(CommandBody::Next);
                Task::none()
            }
            Message::Previous => {
                self.send(CommandBody::Previous);
                Task::none()
            }
            Message::SeekBack => {
                self.send(CommandBody::SeekBy { delta_ms: -5_000 });
                Task::none()
            }
            Message::SeekForward => {
                self.send(CommandBody::SeekBy { delta_ms: 5_000 });
                Task::none()
            }
            Message::DismissError => {
                self.last_error = None;
                Task::none()
            }
            Message::ClientIdChanged(val) => {
                self.client_id_input = val;
                Task::none()
            }
            Message::StartLogin => {
                let id = self.client_id_input.trim().to_string();
                if !id.is_empty() {
                    self.send(CommandBody::LoginStart { client_id: id });
                }
                Task::none()
            }
            Message::CancelLogin => {
                self.send(CommandBody::LoginCancel);
                Task::none()
            }
            Message::Logout => {
                self.send(CommandBody::Logout);
                Task::none()
            }
            Message::OpenBrowserAuth(url) => {
                tokio::spawn(async move {
                    let _ = tokio::process::Command::new("xdg-open")
                        .arg(&url)
                        .spawn();
                });
                Task::none()
            }
            Message::RefreshLibrary => {
                self.send(CommandBody::GetPlaylists {
                    limit: Some(20),
                    offset: Some(0),
                });
                Task::none()
            }
        }
    }

    fn view(&self) -> Element<'_, Message> {
        let header = text("Halcyon Music").size(28);

        let mut status_line_text = status_text(&self.status);
        if self.is_offline {
            status_line_text.push_str(" · Offline (showing cached library)");
        }
        let status_line = text(status_line_text).size(13);

        // Check if first-run / login view is needed
        let main_view: Element<Message> = match &self.auth_status {
            AuthStatus::LoggedOut | AuthStatus::Error { .. } => self.view_first_run(),
            AuthStatus::LoggingIn { auth_url } => self.view_logging_in(auth_url),
            AuthStatus::LoggedIn { user_id, .. } => self.view_player_and_library(user_id.as_deref()),
        };

        let mut content = column![header, status_line, Space::with_height(10), main_view]
            .spacing(8)
            .align_x(Alignment::Start);

        if let Some(err) = &self.last_error {
            content = content.push(
                row![
                    text(format!("Error: {err}")).size(13),
                    button("Dismiss").on_press(Message::DismissError)
                ]
                .spacing(8),
            );
        }

        container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .padding(20)
            .into()
    }

    fn view_first_run(&self) -> Element<'_, Message> {
        let title = text("Connect to Spotify").size(20);

        let warning_notice: Element<Message> = if let Some(reason) = &self.auth_reason {
            container(
                row![
                    text(format!("Session Expired: {reason} — Please log in again.")).size(13)
                ]
            )
            .padding(10)
            .into()
        } else {
            Space::with_height(0).into()
        };

        let instructions = column![
            text("Setup instructions:").size(15),
            text("1. Open developer.spotify.com/dashboard and log in").size(13),
            text("2. Click 'Create App' and name it 'Halcyon Music'").size(13),
            text("3. Set Redirect URI to: http://127.0.0.1:8888/callback (never localhost)").size(13),
            text("4. Copy the Client ID, paste it below, and click Connect:").size(13),
        ]
        .spacing(6);

        let input_row = row![
            text_input("Paste Spotify Client ID here...", &self.client_id_input)
                .on_input(Message::ClientIdChanged)
                .padding(8)
                .width(Length::Fixed(360.0)),
            button("Connect with Spotify").on_press(Message::StartLogin),
        ]
        .spacing(10);

        let cached_fallback: Element<Message> = if !self.playlists.is_empty() {
            column![
                Space::with_height(14),
                text("Offline Cache available:").size(14),
                self.view_playlists_list(),
            ]
            .spacing(6)
            .into()
        } else {
            Space::with_height(0).into()
        };

        column![title, warning_notice, instructions, Space::with_height(8), input_row, cached_fallback]
            .spacing(10)
            .into()
    }

    fn view_logging_in(&self, auth_url: &str) -> Element<'_, Message> {
        let url_copy = auth_url.to_string();
        column![
            text("Connecting to Spotify...").size(20),
            text("A browser window should have opened for you to approve access.").size(14),
            text("If the browser did not open automatically, click the link below:").size(13),
            row![
                button("Open in Browser").on_press(Message::OpenBrowserAuth(url_copy)),
                button("Cancel").on_press(Message::CancelLogin),
            ]
            .spacing(10)
        ]
        .spacing(12)
        .into()
    }

    fn view_player_and_library(&self, user_id: Option<&str>) -> Element<'_, Message> {
        let user_label = user_id.unwrap_or("Spotify User");
        let user_bar = row![
            text(format!("Connected as: {user_label}")).size(14),
            button("Refresh").on_press(Message::RefreshLibrary),
            button("Log out").on_press(Message::Logout),
        ]
        .spacing(12);

        let now_playing: Element<Message> = match self.state.current_track() {
            Some(track) => column![
                text(track.title.clone()).size(20),
                text(format!("{} — {}", track.artist, track.album)).size(14),
                text(format!(
                    "{} / {}",
                    fmt_ms(self.state.position_ms),
                    fmt_ms(track.duration_ms)
                ))
                .size(14),
                row![
                    button("⏮").on_press(Message::Previous),
                    button(if self.state.playing { "⏸" } else { "▶" }).on_press(Message::Toggle),
                    button("⏭").on_press(Message::Next),
                    button("-5s").on_press(Message::SeekBack),
                    button("+5s").on_press(Message::SeekForward),
                ]
                .spacing(8),
            ]
            .spacing(6)
            .into(),
            None => text("Nothing playing. Playback control lands in Part 3.")
                .size(14)
                .into(),
        };

        let playlists_section = column![
            text("Your Playlists:").size(16),
            self.view_playlists_list(),
        ]
        .spacing(8);

        column![user_bar, Space::with_height(10), now_playing, Space::with_height(14), playlists_section]
            .spacing(10)
            .into()
    }

    fn view_playlists_list(&self) -> Element<'_, Message> {
        if self.playlists.is_empty() {
            return text("No playlists cached or found yet.").size(13).into();
        }

        let mut list_col = column![].spacing(6);
        for pl in &self.playlists {
            let row_item = row![
                text(format!("• {}", pl.name)).size(14),
                text(format!("({} tracks)", pl.total_tracks)).size(12),
            ]
            .spacing(8);
            list_col = list_col.push(row_item);
        }

        scrollable(list_col).height(Length::Fixed(200.0)).into()
    }
}

fn status_text(s: &ConnStatus) -> String {
    match s {
        ConnStatus::Connecting => "Connecting to daemon…".to_string(),
        ConnStatus::Connected { daemon_version } => {
            format!("Daemon {daemon_version}")
        }
        ConnStatus::SpawnedDaemon => "Started daemon; connecting…".to_string(),
        ConnStatus::Reconnecting { attempt } => {
            format!("Daemon restarted; reconnecting ({attempt})…")
        }
        ConnStatus::Failed(e) => format!("Connection problem: {e}"),
    }
}

fn fmt_ms(ms: u64) -> String {
    let total_secs = ms / 1000;
    format!("{}:{:02}", total_secs / 60, total_secs % 60)
}
