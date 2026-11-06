//! halcyon-music — the GUI client.
//!
//! Part 4:
//! - Collapsible sidebar with active sliding pill
//! - Bottom now-playing bar with tabular seek time, volume, lyrics and queue toggles
//! - Full-screen Now Playing view with large cover, blurred & cover-tinted background, and lyrics
//! - Median-cut dominant cover color extraction with WCAG 4.5:1 contrast checking
//! - Density setting: Comfortable vs Compact
//! - Display refresh animation engine with ~0% idle CPU
//! - Global keyboard shortcuts & modal overlay (`?`)
//! - Performance overlay (`--perf`)

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

mod animation;
mod client;
mod shortcuts;
mod theme;
mod views;

use animation::AnimationManager;
use client::{ConnStatus, UiEvent};
use halcyon_music_core::models::{AuthStatus, Playlist, Track};
use halcyon_music_core::protocol::{CommandBody, EventBody};
use halcyon_music_core::state::{PlayerState, RepeatMode};
use shortcuts::ShortcutAction;
use theme::{Density, HalcyonPalette};
use views::sidebar::NavPage;

use iced::widget::{button, column, container, row, scrollable, text, text_input, Space};
use iced::{Alignment, Element, Length, Task, Theme};
use std::time::Duration;

pub fn main() -> iced::Result {
    let args: Vec<String> = std::env::args().collect();
    let perf_flag = args.iter().any(|a| a == "--perf");

    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt().with_env_filter(filter).try_init();

    let window_settings = iced::window::Settings {
        platform_specific: iced::window::settings::PlatformSpecific {
            application_id: "halcyon-music".to_string(),
            ..Default::default()
        },
        size: iced::Size::new(1040.0, 680.0),
        min_size: Some(iced::Size::new(800.0, 520.0)),
        ..Default::default()
    };

    iced::application("Halcyon Music", HalcyonApp::update, HalcyonApp::view)
        .window(window_settings)
        .subscription(HalcyonApp::subscription)
        .theme(|_| Theme::Dark)
        .run_with(move || HalcyonApp::new(perf_flag))
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
    // Part 4 UI Shell State
    active_nav: NavPage,
    sidebar_collapsed: bool,
    density: Density,
    show_fullscreen: bool,
    show_queue: bool,
    show_lyrics: bool,
    show_help: bool,
    palette: HalcyonPalette,
    animations: AnimationManager,
    lyrics_lines: Vec<String>,
    saved_volume: u8,
    search_query: String,
    perf_overlay: bool,
}

#[derive(Debug, Clone)]
enum Message {
    UiEvent(Box<UiEvent>),
    Shortcut(ShortcutAction),
    NavSelected(NavPage),
    ToggleSidebar,
    ToggleFullscreen,
    ToggleQueue,
    ToggleLyrics,
    ToggleHelp,
    ToggleDensity,
    AnimationTick,
    // Playback Controls
    TogglePlay,
    Next,
    Previous,
    Seek(u64),
    SeekBy(i64),
    Volume(u8),
    ToggleMute,
    ToggleShuffle,
    CycleRepeat,
    ToggleLike,
    Dequeue(usize),
    DismissError,
    // Auth & Data actions
    ClientIdChanged(String),
    SearchInputChanged(String),
    StartLogin,
    CancelLogin,
    Logout,
    OpenBrowserAuth(String),
    RefreshLibrary,
    PlayTrack(Track),
}

impl HalcyonApp {
    fn new(perf_flag: bool) -> (Self, Task<Message>) {
        let mut client = client::connect();

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

        let mut animations = AnimationManager::default();
        animations.perf_overlay = perf_flag;

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
            active_nav: NavPage::Home,
            sidebar_collapsed: false,
            density: Density::Comfortable,
            show_fullscreen: false,
            show_queue: false,
            show_lyrics: false,
            show_help: false,
            palette: HalcyonPalette::load_from_rice(),
            animations,
            lyrics_lines: Vec::new(),
            saved_volume: 50,
            search_query: String::new(),
            perf_overlay: perf_flag,
        };
        (app, task)
    }

    fn send(&self, body: CommandBody) {
        let _ = self.commands.try_send(body);
    }

    fn subscription(&self) -> iced::Subscription<Message> {
        let key_sub = iced::keyboard::on_key_press(|key, modifiers| {
            let fake_ev = iced::keyboard::Event::KeyPressed {
                key,
                modifiers,
                text: None,
                location: iced::keyboard::Location::Standard,
            };
            shortcuts::match_shortcut(&fake_ev, modifiers).map(Message::Shortcut)
        });

        let anim_sub = if self.animations.is_animating() {
            iced::time::every(Duration::from_millis(16)).map(|_| Message::AnimationTick)
        } else {
            iced::Subscription::none()
        };

        iced::Subscription::batch([key_sub, anim_sub])
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
                    self.animations.animate_toast_show();
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
                    EventBody::PlaybackFailed { reason, .. } => {
                        self.last_error = Some(reason);
                        self.animations.animate_toast_show();
                        Task::none()
                    }
                    EventBody::TrackUnavailable { title, reason, .. } => {
                        self.last_error = Some(format!("\"{title}\" unavailable: {reason}"));
                        self.animations.animate_toast_show();
                        Task::none()
                    }
                    _ => Task::none(),
                },
            },
            Message::Shortcut(action) => self.handle_shortcut(action),
            Message::NavSelected(page) => {
                let current_idx = self.active_nav as usize as f32;
                let target_idx = page as usize as f32;
                self.active_nav = page;
                self.animations.animate_page_switch();
                self.animations.animate_sidebar_pill(current_idx, target_idx);
                Task::none()
            }
            Message::ToggleSidebar => {
                self.sidebar_collapsed = !self.sidebar_collapsed;
                Task::none()
            }
            Message::ToggleFullscreen => {
                self.show_fullscreen = !self.show_fullscreen;
                Task::none()
            }
            Message::ToggleQueue => {
                self.show_queue = !self.show_queue;
                Task::none()
            }
            Message::ToggleLyrics => {
                self.show_lyrics = !self.show_lyrics;
                Task::none()
            }
            Message::ToggleHelp => {
                self.show_help = !self.show_help;
                Task::none()
            }
            Message::ToggleDensity => {
                self.density = match self.density {
                    Density::Comfortable => Density::Compact,
                    Density::Compact => Density::Comfortable,
                };
                Task::none()
            }
            Message::AnimationTick => {
                self.animations.tick();
                Task::none()
            }
            Message::TogglePlay => {
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
            Message::Seek(pos) => {
                self.send(CommandBody::Seek { position_ms: pos });
                Task::none()
            }
            Message::SeekBy(delta) => {
                self.send(CommandBody::SeekBy { delta_ms: delta });
                Task::none()
            }
            Message::Volume(v) => {
                self.send(CommandBody::SetVolume { volume: v });
                Task::none()
            }
            Message::ToggleMute => {
                if self.state.volume > 0 {
                    self.saved_volume = self.state.volume;
                    self.send(CommandBody::SetVolume { volume: 0 });
                } else {
                    self.send(CommandBody::SetVolume {
                        volume: self.saved_volume.max(20),
                    });
                }
                Task::none()
            }
            Message::ToggleShuffle => {
                self.send(CommandBody::SetShuffle {
                    shuffle: !self.state.shuffle,
                });
                Task::none()
            }
            Message::CycleRepeat => {
                self.send(CommandBody::CycleRepeat);
                Task::none()
            }
            Message::ToggleLike => {
                // Like or unlike current track
                Task::none()
            }
            Message::Dequeue(idx) => {
                self.send(CommandBody::Dequeue { index: idx });
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
            Message::SearchInputChanged(val) => {
                self.search_query = val.clone();
                if !val.trim().is_empty() {
                    self.send(CommandBody::Search {
                        query: val,
                        limit: Some(10),
                        offset: Some(0),
                    });
                }
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
                self.auth_status = AuthStatus::LoggedOut;
                Task::none()
            }
            Message::Logout => {
                self.send(CommandBody::Logout);
                self.auth_status = AuthStatus::LoggedOut;
                self.playlists.clear();
                Task::none()
            }
            Message::OpenBrowserAuth(url) => {
                let _ = tokio::process::Command::new("xdg-open")
                    .arg(&url)
                    .spawn();
                Task::none()
            }
            Message::RefreshLibrary => {
                self.send(CommandBody::GetPlaylists {
                    limit: Some(20),
                    offset: Some(0),
                });
                self.send(CommandBody::ProbeEndpoints);
                Task::none()
            }
            Message::PlayTrack(track) => {
                self.send(CommandBody::PlayTrack { track });
                Task::none()
            }
        }
    }

    fn handle_shortcut(&mut self, action: ShortcutAction) -> Task<Message> {
        match action {
            ShortcutAction::PlayPause => self.update(Message::TogglePlay),
            ShortcutAction::Next => self.update(Message::Next),
            ShortcutAction::Previous => self.update(Message::Previous),
            ShortcutAction::SeekBackShort => self.update(Message::SeekBy(-5_000)),
            ShortcutAction::SeekForwardShort => self.update(Message::SeekBy(5_000)),
            ShortcutAction::SeekBackLong => self.update(Message::SeekBy(-30_000)),
            ShortcutAction::SeekForwardLong => self.update(Message::SeekBy(30_000)),
            ShortcutAction::VolumeUp => {
                let v = self.state.volume.saturating_add(5).min(100);
                self.update(Message::Volume(v))
            }
            ShortcutAction::VolumeDown => {
                let v = self.state.volume.saturating_sub(5);
                self.update(Message::Volume(v))
            }
            ShortcutAction::ToggleMute => self.update(Message::ToggleMute),
            ShortcutAction::ToggleShuffle => self.update(Message::ToggleShuffle),
            ShortcutAction::CycleRepeat => self.update(Message::CycleRepeat),
            ShortcutAction::ToggleLike => self.update(Message::ToggleLike),
            ShortcutAction::OpenSearch => self.update(Message::NavSelected(NavPage::Search)),
            ShortcutAction::ToggleLyrics => self.update(Message::ToggleLyrics),
            ShortcutAction::ToggleQueue => self.update(Message::ToggleQueue),
            ShortcutAction::ToggleFullscreen => self.update(Message::ToggleFullscreen),
            ShortcutAction::ToggleHelp => self.update(Message::ToggleHelp),
            ShortcutAction::Refresh => self.update(Message::RefreshLibrary),
            ShortcutAction::NavigatePage(idx) => {
                if let Some(&page) = NavPage::all().get(idx) {
                    self.update(Message::NavSelected(page))
                } else {
                    Task::none()
                }
            }
            ShortcutAction::BackOrClose => {
                if self.show_help {
                    self.show_help = false;
                } else if self.show_fullscreen {
                    self.show_fullscreen = false;
                } else if self.show_queue {
                    self.show_queue = false;
                } else if self.show_lyrics {
                    self.show_lyrics = false;
                }
                Task::none()
            }
            ShortcutAction::PlaySelected => Task::none(),
            ShortcutAction::PlayNextSelected => Task::none(),
            ShortcutAction::EnqueueSelected => Task::none(),
        }
    }

    fn view(&self) -> Element<'_, Message> {
        // 1. Fullscreen Now Playing overlay
        if self.show_fullscreen {
            return views::fullscreen::view(
                &self.state,
                &self.palette,
                &self.lyrics_lines,
                Message::TogglePlay,
                Message::Next,
                Message::Previous,
                Message::Seek,
                Message::ToggleFullscreen,
            );
        }

        // 2. Sidebar Navigation
        let sidebar = views::sidebar::view(
            self.active_nav,
            self.sidebar_collapsed,
            &self.palette,
            self.density,
            Message::NavSelected,
            Message::ToggleSidebar,
        );

        // 3. Center Content Page
        let content_area: Element<Message> = match self.auth_status {
            AuthStatus::LoggedOut | AuthStatus::Error { .. } => {
                container(self.view_first_run()).padding(24).into()
            }
            AuthStatus::LoggingIn { ref auth_url } => {
                container(self.view_logging_in(auth_url)).padding(24).into()
            }
            AuthStatus::LoggedIn { ref user_id, .. } => {
                self.view_page_content(user_id.as_deref())
            }
        };

        let center_with_header = column![
            self.view_top_header(),
            scrollable(container(content_area).width(Length::Fill).padding(16))
                .height(Length::Fill)
                .width(Length::Fill),
        ]
        .width(Length::Fill)
        .height(Length::Fill);

        // 4. Right Queue Drawer (if toggled)
        let main_row = if self.show_queue {
            let queue_drawer = views::queue_drawer::view(
                &self.state,
                &self.palette,
                Message::ToggleQueue,
                Message::Dequeue,
            );
            row![sidebar, center_with_header, queue_drawer]
        } else {
            row![sidebar, center_with_header]
        };

        // 5. Bottom Transport Bar
        let bottom_bar = views::now_playing_bar::view(
            &self.state,
            &self.palette,
            Message::TogglePlay,
            Message::Next,
            Message::Previous,
            Message::Seek,
            Message::Volume,
            Message::ToggleMute,
            Message::ToggleShuffle,
            Message::CycleRepeat,
            Message::ToggleQueue,
            Message::ToggleLyrics,
            Message::ToggleFullscreen,
            Message::ToggleLike,
        );

        let layout = column![main_row, bottom_bar]
            .width(Length::Fill)
            .height(Length::Fill);

        // 6. Floating Modals (Help `?` or Toast)
        if self.show_help {
            return container(
                iced::widget::stack![layout, views::help_modal::view(&self.palette, Message::ToggleHelp)],
            )
            .into();
        }

        container(layout)
            .width(Length::Fill)
            .height(Length::Fill)
            .style(move |_t| container::Style {
                background: Some(self.palette.background.into()),
                ..Default::default()
            })
            .into()
    }

    fn view_top_header(&self) -> Element<'_, Message> {
        let title_str = match self.active_nav {
            NavPage::Home => "Home",
            NavPage::Search => "Search",
            NavPage::Library => "Your Library",
            NavPage::Liked => "Liked Songs",
            NavPage::Capsule => "Capsule",
            NavPage::Settings => "Settings",
        };

        let badge_txt = if self.is_offline { "Offline (cached)" } else { "Online" };
        let badge_color = if self.is_offline {
            self.palette.accent_secondary
        } else {
            self.palette.accent
        };

        let badge = container(text(badge_txt).size(11).color(badge_color))
            .padding([3, 8])
            .style(move |_t| container::Style {
                background: Some(iced::Color { a: 0.1, ..badge_color }.into()),
                border: iced::Border {
                    radius: 10.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

        let density_icon = match self.density {
            Density::Comfortable => "󰆊",
            Density::Compact => "󰆋",
        };
        let density_btn = button(text(density_icon).size(15).color(self.palette.text_muted))
            .on_press(Message::ToggleDensity)
            .padding(6)
            .style(|_t, _s| button::Style::default());

        let help_btn = button(text("?").size(15).color(self.palette.text_muted))
            .on_press(Message::ToggleHelp)
            .padding(6)
            .style(|_t, _s| button::Style::default());

        let perf_element: Element<Message> = if self.perf_overlay {
            let ms = self.animations.last_frame_time.as_secs_f32() * 1000.0;
            let fps = if ms > 0.0 { 1000.0 / ms } else { 60.0 };
            text(format!("{ms:.1}ms | {fps:.0} FPS"))
                .size(11)
                .color(self.palette.accent)
                .into()
        } else {
            Space::with_width(0).into()
        };

        container(
            row![
                text(title_str).size(self.density.heading_size()).color(self.palette.text),
                Space::with_width(12),
                badge,
                Space::with_width(Length::Fill),
                perf_element,
                Space::with_width(8),
                density_btn,
                help_btn,
            ]
            .align_y(Alignment::Center)
            .padding([12, 20]),
        )
        .width(Length::Fill)
        .style(move |_t| container::Style {
            border: iced::Border {
                color: self.palette.border,
                width: 0.5,
                ..Default::default()
            },
            ..Default::default()
        })
        .into()
    }

    fn view_page_content(&self, user_id: Option<&str>) -> Element<'_, Message> {
        match self.active_nav {
            NavPage::Home => self.view_player_and_library(user_id),
            NavPage::Search => column![
                text_input("Search songs, artists, albums...", &self.search_query)
                    .on_input(Message::SearchInputChanged)
                    .padding(10)
                    .width(Length::Fixed(400.0)),
                Space::with_height(16),
                text("Type to search Spotify library.").size(13).color(self.palette.text_muted),
            ]
            .into(),
            NavPage::Library => column![
                text("Your Playlists & Albums").size(18).color(self.palette.text),
                Space::with_height(12),
                self.view_playlists_list(),
            ]
            .into(),
            NavPage::Liked => column![
                text("Liked Songs").size(18).color(self.palette.text),
                Space::with_height(12),
                text("Your saved tracks will appear here.").size(13).color(self.palette.text_muted),
            ]
            .into(),
            NavPage::Capsule => column![
                text("Your Halcyon Capsule").size(18).color(self.palette.text),
                Space::with_height(12),
                text("Listening statistics and suggestions land in Part 5 & 6.")
                    .size(13)
                    .color(self.palette.text_muted),
            ]
            .into(),
            NavPage::Settings => column![
                text("Settings").size(18).color(self.palette.text),
                Space::with_height(16),
                row![
                    text("Connected Account:").size(14).color(self.palette.text),
                    Space::with_width(8),
                    text(user_id.unwrap_or("Unknown")).size(14).color(self.palette.accent),
                    Space::with_width(16),
                    button("Log out").on_press(Message::Logout),
                ]
                .align_y(Alignment::Center),
                Space::with_height(16),
                row![
                    text("Display Density:").size(14).color(self.palette.text),
                    Space::with_width(8),
                    button(match self.density {
                        Density::Comfortable => "Comfortable",
                        Density::Compact => "Compact",
                    })
                    .on_press(Message::ToggleDensity),
                ]
                .align_y(Alignment::Center),
            ]
            .into(),
        }
    }

    fn view_first_run(&self) -> Element<'_, Message> {
        let title = text("Connect to Spotify").size(22).color(self.palette.text);

        let warning_notice: Element<Message> = if let Some(reason) = &self.auth_reason {
            container(
                text(format!("Session Expired: {reason} — Please log in again."))
                    .size(13)
                    .color(self.palette.danger),
            )
            .padding(10)
            .into()
        } else {
            Space::with_height(0).into()
        };

        let instructions = column![
            text("Setup instructions:").size(15).color(self.palette.accent),
            text("1. Open developer.spotify.com/dashboard and log in").size(13).color(self.palette.text),
            text("2. Click 'Create App' and name it 'Halcyon Music'").size(13).color(self.palette.text),
            text("3. Set Redirect URI to: http://127.0.0.1:8888/callback (never localhost)").size(13).color(self.palette.text),
            text("4. Copy the Client ID, paste it below, and click Connect:").size(13).color(self.palette.text),
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
                text("Offline Cache available:").size(14).color(self.palette.accent_secondary),
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
            text("Connecting to Spotify...").size(20).color(self.palette.accent),
            text("A browser window should have opened for you to approve access.").size(14).color(self.palette.text),
            text("If the browser did not open automatically, click the link below:").size(13).color(self.palette.text_muted),
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
            text(format!("Connected as: {user_label}")).size(13).color(self.palette.text_muted),
            Space::with_width(Length::Fill),
            button("Refresh").on_press(Message::RefreshLibrary),
        ]
        .align_y(Alignment::Center);

        let playlists_section = column![
            text("Your Playlists").size(16).color(self.palette.text),
            Space::with_height(6),
            self.view_playlists_list(),
        ]
        .spacing(8);

        column![user_bar, Space::with_height(14), playlists_section]
            .spacing(10)
            .into()
    }

    fn view_playlists_list(&self) -> Element<'_, Message> {
        if self.playlists.is_empty() {
            return text("No playlists cached or found yet.")
                .size(13)
                .color(self.palette.text_muted)
                .into();
        }

        let mut list_col = column![].spacing(6);
        for pl in &self.playlists {
            let row_item = container(
                row![
                    text("󰲸").size(16).color(self.palette.accent),
                    Space::with_width(10),
                    text(&pl.name).size(14).color(self.palette.text),
                    Space::with_width(Length::Fill),
                    text(format!("{} tracks", pl.total_tracks))
                        .size(12)
                        .color(self.palette.text_muted),
                ]
                .align_y(Alignment::Center),
            )
            .padding(8)
            .style(move |_t| container::Style {
                background: Some(self.palette.surface.into()),
                border: iced::Border {
                    radius: 8.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

            list_col = list_col.push(row_item);
        }

        scrollable(list_col).height(Length::Fixed(280.0)).into()
    }
}
