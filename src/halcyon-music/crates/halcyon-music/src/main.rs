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
mod art;
mod client;
mod icons;
mod shortcuts;
mod theme;
mod views;

use crate::icons::{icon, Icon};
use animation::AnimationManager;
use client::{ConnStatus, UiEvent};
use halcyon_music_core::art::ArtSize;
use halcyon_music_core::models::{
    Album, Artist, AuthMode, AuthStatus, DetailedSearchResults, FullCapsule, HomeFeed, Lyrics, Playlist, Track,
};
use halcyon_music_core::protocol::{CommandBody, EventBody};
use halcyon_music_core::state::PlayerState;
use shortcuts::ShortcutAction;
use theme::{Density, HalcyonPalette};
use views::library::{LibraryTab, LikedSort};
use views::search::SearchCategory;
use views::sidebar::NavPage;

use iced::widget::{button, column, container, row, scrollable, text, text_input, tooltip, Space};
use iced::{Alignment, Element, Length, Task, Theme};
use std::time::{Duration, Instant};

pub fn main() -> iced::Result {
    let args: Vec<String> = std::env::args().collect();
    // `--version` must answer before any window or daemon work: `halcyon-musicd --doctor` and the
    // installer run it to compare the installed app with the installed daemon.
    if args.iter().skip(1).any(|a| a == "--version" || a == "-V") {
        println!("halcyon-music {}", halcyon_music_core::CORE_VERSION);
        return Ok(());
    }
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
    toast: Option<Toast>,
    // Part 2 state
    auth_status: AuthStatus,
    client_id_input: String,
    auth_reason: Option<String>,
    // Rework Part 5: sign-in screen state
    /// Which token browsing uses (the daemon tells us; default until it does).
    auth_mode: AuthMode,
    /// `None` until the daemon has said whether a streaming sign-in exists.
    streaming_signed_in: Option<bool>,
    show_advanced_login: bool,
    playback_prompt_dismissed: bool,
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
    show_diagnostics: bool,
    /// Palette from the rice; `palette` is this tinted by the current cover.
    base_palette: HalcyonPalette,
    palette: HalcyonPalette,
    animations: AnimationManager,
    saved_volume: u8,
    search_query: String,
    perf_overlay: bool,
    home_feed: HomeFeed,
    // Part 6 State
    search_category: SearchCategory,
    search_results: Option<DetailedSearchResults>,
    recent_searches: Vec<String>,
    search_offset: u32,
    library_tab: LibraryTab,
    library_filter: String,
    liked_sort: LikedSort,
    liked_tracks: Vec<Track>,
    saved_albums: Vec<Album>,
    followed_artists: Vec<Artist>,
    new_playlist_name: String,
    show_new_playlist_input: bool,
    capsule: FullCapsule,
    capsule_month_offset: u32,
    active_album: Option<(Album, Vec<Track>)>,
    active_artist: Option<(Artist, Vec<Track>, Vec<Album>)>,
    active_playlist: Option<(Playlist, Vec<Track>)>,
    // Part 7 Lyrics State
    lyrics: Option<Lyrics>,
    show_load_lrc_input: bool,
    lrc_input: String,
    last_fetched_lyrics_track_id: Option<String>,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
enum Message {
    UiEvent(Box<UiEvent>),
    Shortcut(ShortcutAction),
    NavSelected(NavPage),
    ToggleSidebar,
    ToggleFullscreen,
    ToggleQueue,
    OpenPlaylistsTab,
    ToggleLyrics,
    ToggleHelp,
    ToggleDiagnostics,
    CopyDiagnostics,
    ToggleDensity,
    AnimationTick,
    ToastExpire,
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
    TopSearchChanged(String),
    StartLogin,
    /// Default sign-in: librespot's own browser flow.
    SignInSpotify,
    ToggleAdvancedLogin,
    DismissPlaybackPrompt,
    /// Advanced users: go back to browsing with the Spotify sign-in.
    UseSpotifySignInForBrowsing,
    CancelLogin,
    Logout,
    OpenBrowserAuth(String),
    RefreshLibrary,
    PlayTrack(Track),
    PlayContext(Vec<Track>, usize),
    PlayMix(Vec<Track>, String),
    SaveMix(String, Vec<String>),
    // Part 6 Messages
    SearchCategorySelected(SearchCategory),
    SearchClickRecent(String),
    SearchClearRecent,
    SearchLoadMore,
    LibraryTabSelected(LibraryTab),
    LibraryFilterChanged(String),
    LibrarySortChanged(LikedSort),
    ToggleNewPlaylistInput,
    NewPlaylistNameChanged(String),
    CreateNewPlaylist,
    DeletePlaylist(String),
    CapsulePrevMonth,
    CapsuleNextMonth,
    OpenAlbum(String),
    OpenArtist(String),
    OpenPlaylist(String),
    BackFromDetail,
    // Part 7 Lyrics Messages
    LyricOffsetChanged(i64),
    SearchLyricsAgain,
    ToggleLoadLrcInput,
    LrcInputChanged(String),
    SubmitCustomLrc,
    // Cover art
    ArtDecoded {
        url: String,
        size: ArtSize,
        result: Result<Box<art::Decoded>, String>,
    },
}

/// Id of the header search box, so `/` and Ctrl+K can focus it.
const TOP_SEARCH_ID: &str = "top-search";

/// A short message at the bottom right. `ok` picks the colour: accent for
/// something that worked, red for something that did not.
struct Toast {
    text: String,
    ok: bool,
    until: Instant,
}

/// A header icon button: lights up on hover and names itself in a tooltip.
fn header_button<'a>(
    pal: HalcyonPalette,
    content: Element<'a, Message>,
    tip: &'static str,
    msg: Message,
) -> Element<'a, Message> {
    tooltip(
        button(content).on_press(msg).padding(6).style(views::ghost(pal)),
        container(text(tip).size(12).color(pal.text))
            .padding([4, 8])
            .style(move |_t| container::Style {
                background: Some(pal.surface_variant.into()),
                border: iced::Border {
                    color: pal.border,
                    width: 1.0,
                    radius: 6.0.into(),
                },
                ..Default::default()
            }),
        tooltip::Position::Bottom,
    )
    .into()
}

impl HalcyonApp {
    /// True while Home is showing its grey loading blocks (they pulse).
    fn skeleton_visible(&self) -> bool {
        !self.animations.reduce_motion
            && self.active_nav == NavPage::Home
            && matches!(self.auth_status, AuthStatus::LoggedIn { .. })
            && self.home_feed.quick_picks.is_empty()
            && self.home_feed.jump_back_in.is_empty()
            && self.home_feed.made_for_you.is_empty()
    }

    /// Show a toast for 4 s. Failures are also kept in `last_error` for the
    /// Diagnostics window; good news is not an error and is not.
    fn notify(&mut self, text: String, ok: bool) {
        if !ok {
            self.last_error = Some(text.clone());
        }
        self.toast = Some(Toast {
            text,
            ok,
            until: Instant::now() + Duration::from_secs(4),
        });
        self.animations.animate_toast_show();
    }

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

        let base_palette = HalcyonPalette::load_from_rice();
        let app = Self {
            status: ConnStatus::Connecting,
            state: PlayerState::default(),
            commands: client.commands,
            last_error: None,
            toast: None,
            auth_status: AuthStatus::LoggedOut,
            client_id_input: String::new(),
            auth_reason: None,
            auth_mode: AuthMode::default(),
            streaming_signed_in: None,
            show_advanced_login: false,
            playback_prompt_dismissed: false,
            playlists: Vec::new(),
            is_offline: false,
            active_nav: NavPage::Home,
            sidebar_collapsed: false,
            density: Density::Comfortable,
            show_fullscreen: false,
            show_queue: false,
            show_lyrics: false,
            show_help: false,
            show_diagnostics: false,
            base_palette,
            palette: base_palette,
            animations,
            saved_volume: 50,
            search_query: String::new(),
            perf_overlay: perf_flag,
            home_feed: HomeFeed::default(),
            search_category: SearchCategory::Top,
            search_results: None,
            recent_searches: Vec::new(),
            search_offset: 0,
            library_tab: LibraryTab::Liked,
            library_filter: String::new(),
            liked_sort: LikedSort::Title,
            liked_tracks: Vec::new(),
            saved_albums: Vec::new(),
            followed_artists: Vec::new(),
            new_playlist_name: String::new(),
            show_new_playlist_input: false,
            capsule: FullCapsule::default(),
            capsule_month_offset: 0,
            active_album: None,
            active_artist: None,
            active_playlist: None,
            lyrics: None,
            show_load_lrc_input: false,
            lrc_input: String::new(),
            last_fetched_lyrics_track_id: None,
        };
        (app, task)
    }

    fn send(&self, body: CommandBody) {
        let _ = self.commands.try_send(body);
    }

    fn subscription(&self) -> iced::Subscription<Message> {
        let key_sub = iced::keyboard::on_key_press(|key, modifiers| {
            shortcuts::match_shortcut(&key, modifiers).map(Message::Shortcut)
        });

        let anim_sub = if self.animations.is_animating() || art::is_fading() || self.skeleton_visible() {
            iced::time::every(Duration::from_millis(16)).map(|_| Message::AnimationTick)
        } else {
            iced::Subscription::none()
        };

        let toast_sub = if self.toast.is_some() {
            iced::time::every(Duration::from_millis(500)).map(|_| Message::ToastExpire)
        } else {
            iced::Subscription::none()
        };

        iced::Subscription::batch([key_sub, anim_sub, toast_sub])
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        let sync_art = needs_art_sync(&message);
        let task = self.update_inner(message);
        if sync_art {
            for cmd in self.art_requests() {
                self.send(cmd);
            }
        }
        task
    }

    /// Ask the daemon for every cover the app holds data for and has not
    /// asked for yet. The visible page goes first so it is not queued behind
    /// the rest. Cheap to call: already requested covers are skipped.
    fn art_requests(&self) -> Vec<CommandBody> {
        fn push<'a>(
            cmds: &mut Vec<CommandBody>,
            items: impl IntoIterator<Item = (Option<&'a str>, ArtSize)>,
        ) {
            cmds.extend(art::commands_for(items));
        }
        fn search_items(r: &DetailedSearchResults) -> Vec<(Option<&str>, ArtSize)> {
            let mut v: Vec<(Option<&str>, ArtSize)> = art::track_items(&r.tracks).collect();
            v.extend(art::artist_items(&r.artists));
            v.extend(art::album_items(&r.albums));
            v.extend(r.playlists.iter().map(|p| (p.art_url.as_deref(), ArtSize::Medium)));
            v
        }
        fn library_items<'a>(app: &'a HalcyonApp) -> Vec<(Option<&'a str>, ArtSize)> {
            let mut v: Vec<(Option<&'a str>, ArtSize)> = art::track_items(&app.liked_tracks).collect();
            v.extend(art::playlist_items(&app.playlists));
            v.extend(art::album_items(&app.saved_albums));
            v.extend(art::artist_items(&app.followed_artists));
            v
        }
        fn detail_items<'a>(app: &'a HalcyonApp) -> Vec<(Option<&'a str>, ArtSize)> {
            let mut v: Vec<(Option<&'a str>, ArtSize)> = Vec::new();
            if let Some((album, _)) = &app.active_album {
                v.push((album.art_url.as_deref(), ArtSize::Medium));
            }
            if let Some((artist, _, albums)) = &app.active_artist {
                v.extend(art::artist_items(std::slice::from_ref(artist)));
                v.extend(art::album_items(albums));
            }
            if let Some((playlist, _)) = &app.active_playlist {
                v.push((playlist.art_url.as_deref(), ArtSize::Medium));
            }
            v
        }

        let mut cmds = Vec::new();
        if let Some(track) = &self.state.track {
            push(&mut cmds, art::now_playing_items(track));
        }
        // Visible page first.
        match self.active_nav {
            NavPage::Home => push(&mut cmds, art::home_items(&self.home_feed)),
            NavPage::Search => {
                if let Some(r) = &self.search_results {
                    push(&mut cmds, search_items(r));
                }
            }
            NavPage::Capsule => push(
                &mut cmds,
                self.capsule
                    .top_tracks
                    .iter()
                    .map(|(t, _)| (t.art_url.as_deref(), ArtSize::Small))
                    .collect::<Vec<_>>(),
            ),
            NavPage::Library | NavPage::Liked => push(&mut cmds, library_items(self)),
            NavPage::AlbumDetail | NavPage::ArtistDetail | NavPage::PlaylistDetail => {
                push(&mut cmds, detail_items(self))
            }
            _ => {}
        }
        // Then everything else we hold data for.
        push(&mut cmds, art::track_items(&self.state.queue));
        push(&mut cmds, art::home_items(&self.home_feed));
        push(&mut cmds, library_items(self));
        if let Some(r) = &self.search_results {
            push(&mut cmds, search_items(r));
        }
        push(&mut cmds, detail_items(self));
        cmds
    }

    /// Palette for the current track: the rice palette tinted by its cover
    /// when that cover is already decoded, the plain rice palette otherwise.
    fn retint(&mut self) {
        let tint = self
            .state
            .track
            .as_ref()
            .and_then(|t| t.art_url.as_deref())
            .and_then(|url| art::dominant(url, ArtSize::Small));
        self.palette = match tint {
            Some(c) => self.base_palette.with_cover_tint(c),
            None => self.base_palette,
        };
    }

    fn update_inner(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::UiEvent(ev) => match *ev {
                UiEvent::Status(s) => {
                    self.status = s;
                    if let ConnStatus::Connected { .. } = &self.status {
                        art::connection_reset();
                        self.send(CommandBody::GetAuthStatus);
                        // An older daemon answers this with "not supported by this daemon version".
                        self.send(CommandBody::GetStreamingAuth);
                        self.send(CommandBody::GetHomeFeed);
                    }
                    Task::none()
                }
                UiEvent::DaemonError(msg) => {
                    self.notify(msg, false);
                    self.animations.animate_toast_show();
                    Task::none()
                }
                UiEvent::Protocol(boxed_ev) => match boxed_ev.body {
                    EventBody::State { state } => {
                        let track_changed = self.state.track.as_ref().map(|t| &t.id) != state.track.as_ref().map(|t| &t.id);
                        self.state = state;
                        if track_changed {
                            self.retint();
                            if let Some(track) = &self.state.track {
                                self.send(CommandBody::GetLyrics {
                                    track_id: track.id.clone(),
                                    artist: track.artist.clone(),
                                    title: track.title.clone(),
                                    album: track.album.clone(),
                                    duration_ms: track.duration_ms,
                                });
                                self.last_fetched_lyrics_track_id = Some(track.id.clone());
                            } else {
                                self.lyrics = None;
                                self.last_fetched_lyrics_track_id = None;
                            }
                        }
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
                            // Empty: the daemon opened the browser itself (streaming sign-in).
                            if url.is_empty() {
                                return Task::none();
                            }
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
                    EventBody::Hello { daemon_version, .. } => {
                        if daemon_version != halcyon_music_core::CORE_VERSION {
                            self.notify(
                                format!(
                                    "The daemon is version {daemon_version} but this app is {}. Restart it: systemctl --user restart halcyon-musicd",
                                    halcyon_music_core::CORE_VERSION
                                ),
                                false,
                            );
                        }
                        Task::none()
                    }
                    EventBody::Error { message } => {
                        // A daemon from before this version does not know the newer commands
                        // (same version number, older build): say what to do about it.
                        if message.contains("not supported by this daemon version") {
                            self.notify(
                                "The running daemon is out of date. Restart it: systemctl --user restart halcyon-musicd".to_string(),
                                false,
                            );
                        } else {
                            self.notify(message, false);
                        }
                        Task::none()
                    }
                    EventBody::StreamingAuth { signed_in, .. } => {
                        self.streaming_signed_in = Some(signed_in);
                        Task::none()
                    }
                    EventBody::AuthModeChanged { mode } => {
                        self.auth_mode = mode;
                        Task::none()
                    }
                    EventBody::AuthSuccess { .. } => {
                        self.auth_reason = None;
                        self.send(CommandBody::GetAuthStatus);
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
                        self.notify(reason, false);
                        self.animations.animate_toast_show();
                        Task::none()
                    }
                    EventBody::TrackUnavailable { title, reason, .. } => {
                        self.notify(format!("\"{title}\" unavailable: {reason}"), false);
                        self.animations.animate_toast_show();
                        Task::none()
                    }
                    EventBody::HomeFeedResult(feed) => {
                        self.home_feed = *feed;
                        Task::none()
                    }
                    EventBody::LikedTracksResult { tracks, offset, is_cached, total } => {
                        let page_len = tracks.len();
                        if !is_cached && page_len > 0 {
                            // Fetch the rest of the library in the background, 50 at a time, up to 1000 songs.
                            let next = offset + page_len;
                            if next < total && next < 1000 {
                                self.send(CommandBody::GetLikedTracks {
                                    limit: Some(50),
                                    offset: Some(next as u32),
                                });
                            }
                        }
                        if offset == 0 {
                            self.liked_tracks = tracks;
                        } else {
                            for t in tracks {
                                if !self.liked_tracks.iter().any(|x| x.id == t.id) {
                                    self.liked_tracks.push(t);
                                }
                            }
                        }
                        self.is_offline = is_cached;
                        Task::none()
                    }
                    EventBody::SavedAlbumsResult { albums } => {
                        self.saved_albums = albums;
                        Task::none()
                    }
                    EventBody::FollowedArtistsResult { artists } => {
                        self.followed_artists = artists;
                        Task::none()
                    }
                    EventBody::PlaylistTracksResult { playlist_id, tracks, offset, .. } => {
                        if let Some((pl, list)) = self.active_playlist.as_mut() {
                            if pl.id == playlist_id {
                                if offset == 0 {
                                    *list = tracks;
                                } else {
                                    for t in tracks {
                                        if !list.iter().any(|x| x.id == t.id) {
                                            list.push(t);
                                        }
                                    }
                                }
                            }
                        }
                        Task::none()
                    }
                    EventBody::PlaylistCreated { name, .. } => {
                        self.notify(format!("Mix saved to Spotify as \"{name}\""), true);
                        self.animations.animate_toast_show();
                        Task::none()
                    }
                    EventBody::DetailedSearchResults(results) => {
                        if results.query != self.search_query
                            || (!results.search_type.is_empty()
                                && results.search_type != self.search_category.api_type())
                            || results.offset != self.search_offset
                        {
                            return Task::none();
                        }
                        if self.search_offset > 0 {
                            if let Some(existing) = self.search_results.as_mut() {
                                existing.tracks.extend(results.tracks.clone());
                                existing.artists.extend(results.artists.clone());
                                existing.albums.extend(results.albums.clone());
                                existing.playlists.extend(results.playlists.clone());
                                existing.total_tracks = results.total_tracks;
                                existing.total_artists = results.total_artists;
                                existing.total_albums = results.total_albums;
                                existing.total_playlists = results.total_playlists;
                            } else {
                                self.search_results = Some(*results);
                            }
                        } else {
                            self.search_results = Some(*results);
                        }
                        Task::none()
                    }
                    EventBody::RecentSearchesResult { searches } => {
                        self.recent_searches = searches;
                        Task::none()
                    }
                    EventBody::CapsuleResult(cap) => {
                        self.capsule = *cap;
                        Task::none()
                    }
                    EventBody::AlbumDetailResult { album, tracks } => {
                        self.active_album = Some((album, tracks));
                        self.active_nav = NavPage::AlbumDetail;
                        Task::none()
                    }
                    EventBody::ArtistDetailResult { artist, top_tracks, albums } => {
                        self.active_artist = Some((artist, top_tracks, albums));
                        self.active_nav = NavPage::ArtistDetail;
                        Task::none()
                    }
                    EventBody::PlaylistUpdated { .. } => {
                        self.send(CommandBody::GetPlaylists {
                            limit: Some(50),
                            offset: Some(0),
                        });
                        Task::none()
                    }
                    EventBody::ArtReady { url, size, path } => art::decode_task(url, size, path),
                    EventBody::ArtFailed { url, size, reason } => {
                        tracing::debug!(%url, ?size, %reason, "cover unavailable");
                        art::store_failed(&url, size);
                        Task::none()
                    }
                    EventBody::LyricsResult { track_id, lyrics } => {
                        if self.state.track.as_ref().map(|t| &t.id) == Some(&track_id) {
                            self.lyrics = lyrics.map(|b| *b);
                        }
                        Task::none()
                    }
                    _ => Task::none(),
                },
            },
            Message::ArtDecoded { url, size, result } => {
                match result {
                    Ok(decoded) => {
                        art::store_decoded(&url, size, *decoded);
                        let is_current = size == ArtSize::Small
                            && self.state.track.as_ref().and_then(|t| t.art_url.as_deref()) == Some(url.as_str());
                        if is_current {
                            self.retint();
                        }
                    }
                    Err(e) => {
                        tracing::warn!(%url, ?size, error = %e, "could not decode cover");
                        art::store_failed(&url, size);
                    }
                }
                Task::none()
            }
            Message::Shortcut(action) => self.handle_shortcut(action),
            Message::NavSelected(page) => {
                let current_idx = self.active_nav as usize as f32;
                let target_idx = page as usize as f32;
                self.active_nav = page;
                if page == NavPage::Home || page == NavPage::Recent {
                    self.send(CommandBody::GetHomeFeed);
                } else if page == NavPage::Search {
                    self.send(CommandBody::GetRecentSearches);
                } else if page == NavPage::Capsule {
                    self.send(CommandBody::GetCapsule {
                        month_offset: self.capsule_month_offset,
                    });
                } else if page == NavPage::Library || page == NavPage::Liked {
                    self.send(CommandBody::GetPlaylists {
                        limit: Some(50),
                        offset: Some(0),
                    });
                    self.send(CommandBody::GetLikedTracks {
                        limit: Some(50),
                        offset: Some(0),
                    });
                    self.send(CommandBody::GetSavedAlbums);
                    self.send(CommandBody::GetFollowedArtists);
                } else if page == NavPage::Lyrics {
                    if let Some(track) = &self.state.track {
                        if self.last_fetched_lyrics_track_id.as_deref() != Some(&track.id) {
                            self.send(CommandBody::GetLyrics {
                                track_id: track.id.clone(),
                                artist: track.artist.clone(),
                                title: track.title.clone(),
                                album: track.album.clone(),
                                duration_ms: track.duration_ms,
                            });
                            self.last_fetched_lyrics_track_id = Some(track.id.clone());
                        }
                    }
                }
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
                if self.active_nav == NavPage::Lyrics {
                    self.active_nav = NavPage::Home;
                } else {
                    self.active_nav = NavPage::Lyrics;
                    if let Some(track) = &self.state.track {
                        if self.last_fetched_lyrics_track_id.as_deref() != Some(&track.id) {
                            self.send(CommandBody::GetLyrics {
                                track_id: track.id.clone(),
                                artist: track.artist.clone(),
                                title: track.title.clone(),
                                album: track.album.clone(),
                                duration_ms: track.duration_ms,
                            });
                            self.last_fetched_lyrics_track_id = Some(track.id.clone());
                        }
                    }
                }
                Task::none()
            }
            Message::ToggleHelp => {
                self.show_help = !self.show_help;
                Task::none()
            }
            Message::ToggleDiagnostics => {
                self.show_diagnostics = !self.show_diagnostics;
                Task::none()
            }
            Message::CopyDiagnostics => {
                let diag = format!(
                    "### Halcyon Music Diagnostics\n- Daemon Status: {:?}\n- Spotify Auth: {:?}\n- Track: {}\n- Position: {} ms\n- Queue Length: {} tracks\n- Volume: {}%\n- Last Error: {:?}\n- Control Socket: $XDG_RUNTIME_DIR/halcyon-music/ctl.sock\n- Self-healing Watchdog: Active\n",
                    self.status,
                    self.auth_status,
                    self.state.track.as_ref().map(|t| format!("\"{}\" by {}", t.title, t.artist)).unwrap_or_else(|| "None".to_string()),
                    self.state.position_ms,
                    self.state.queue.len(),
                    self.state.volume,
                    self.last_error
                );
                self.notify("Diagnostics copied to clipboard!".to_string(), true);
                self.animations.animate_toast_show();
                iced::clipboard::write(diag)
            }
            Message::ToggleDensity => {
                self.density = match self.density {
                    Density::Comfortable => Density::Compact,
                    Density::Compact => Density::Comfortable,
                };
                Task::none()
            }
            Message::ToastExpire => {
                if self.toast.as_ref().is_some_and(|t| Instant::now() >= t.until) {
                    self.toast = None;
                }
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
                if let Some(ref cur) = self.state.track {
                    if let Some(pos) = self.liked_tracks.iter().position(|t| t.id == cur.id) {
                        self.liked_tracks.remove(pos);
                        self.notify(format!("Removed \"{}\" from Liked Songs", cur.title), true);
                    } else {
                        self.liked_tracks.insert(0, cur.clone());
                        self.notify(format!("Saved \"{}\" to Liked Songs", cur.title), true);
                    }
                    self.animations.animate_toast_show();
                }
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
            Message::TopSearchChanged(val) => {
                if self.active_nav != NavPage::Search {
                    self.active_nav = NavPage::Search;
                    self.send(CommandBody::GetRecentSearches);
                }
                self.update_inner(Message::SearchInputChanged(val))
            }
            Message::SearchInputChanged(val) => {
                self.search_query = val.clone();
                self.search_offset = 0;
                if !val.trim().is_empty() {
                    self.send(CommandBody::DetailedSearch {
                        query: val,
                        search_type: self.search_category.api_type().to_string(),
                        limit: 10,
                        offset: 0,
                    });
                } else {
                    self.search_results = None;
                }
                Task::none()
            }
            Message::SearchCategorySelected(cat) => {
                self.search_category = cat;
                self.search_offset = 0;
                if !self.search_query.trim().is_empty() {
                    self.send(CommandBody::DetailedSearch {
                        query: self.search_query.clone(),
                        search_type: self.search_category.api_type().to_string(),
                        limit: 10,
                        offset: 0,
                    });
                }
                Task::none()
            }
            Message::SearchClickRecent(q) => {
                self.search_query = q.clone();
                self.search_offset = 0;
                self.send(CommandBody::DetailedSearch {
                    query: q,
                    search_type: self.search_category.api_type().to_string(),
                    limit: 10,
                    offset: 0,
                });
                Task::none()
            }
            Message::SearchClearRecent => {
                self.recent_searches.clear();
                self.send(CommandBody::ClearRecentSearches);
                Task::none()
            }
            Message::SearchLoadMore => {
                self.search_offset = self.search_offset.saturating_add(10);
                self.send(CommandBody::DetailedSearch {
                    query: self.search_query.clone(),
                    search_type: self.search_category.api_type().to_string(),
                    limit: 10,
                    offset: self.search_offset,
                });
                Task::none()
            }
            Message::OpenPlaylistsTab => {
                self.library_tab = LibraryTab::Playlists;
                self.update_inner(Message::NavSelected(NavPage::Library))
            }
            Message::LibraryTabSelected(tab) => {
                self.library_tab = tab;
                Task::none()
            }
            Message::LibraryFilterChanged(text) => {
                self.library_filter = text;
                Task::none()
            }
            Message::LibrarySortChanged(sort) => {
                self.liked_sort = sort;
                Task::none()
            }
            Message::ToggleNewPlaylistInput => {
                self.show_new_playlist_input = !self.show_new_playlist_input;
                Task::none()
            }
            Message::NewPlaylistNameChanged(name) => {
                self.new_playlist_name = name;
                Task::none()
            }
            Message::CreateNewPlaylist => {
                if !self.new_playlist_name.trim().is_empty() {
                    self.send(CommandBody::CreatePlaylist {
                        name: self.new_playlist_name.trim().to_string(),
                        description: Some("Created in Halcyon Music".to_string()),
                    });
                    self.new_playlist_name.clear();
                    self.show_new_playlist_input = false;
                }
                Task::none()
            }
            Message::DeletePlaylist(id) => {
                self.send(CommandBody::DeletePlaylist { id: id.clone() });
                self.playlists.retain(|p| p.id != id);
                if let Some((ref pl, _)) = self.active_playlist {
                    if pl.id == id {
                        self.active_playlist = None;
                        self.active_nav = NavPage::Library;
                    }
                }
                Task::none()
            }
            Message::CapsulePrevMonth => {
                self.capsule_month_offset = self.capsule_month_offset.saturating_add(1);
                self.send(CommandBody::GetCapsule {
                    month_offset: self.capsule_month_offset,
                });
                Task::none()
            }
            Message::CapsuleNextMonth => {
                if self.capsule_month_offset > 0 {
                    self.capsule_month_offset -= 1;
                    self.send(CommandBody::GetCapsule {
                        month_offset: self.capsule_month_offset,
                    });
                }
                Task::none()
            }
            Message::OpenAlbum(id) => {
                self.send(CommandBody::GetAlbumDetail { id });
                Task::none()
            }
            Message::OpenArtist(id) => {
                self.send(CommandBody::GetArtistDetail { id });
                Task::none()
            }
            Message::OpenPlaylist(id) => {
                if let Some(pl) = self.playlists.iter().find(|p| p.id == id).cloned() {
                    self.active_playlist = Some((pl, vec![]));
                    self.active_nav = NavPage::PlaylistDetail;
                    self.send(CommandBody::GetPlaylistTracks {
                        id: id.clone(),
                        limit: Some(100),
                        offset: Some(0),
                    });
                }
                Task::none()
            }
            Message::BackFromDetail => {
                self.active_nav = NavPage::Library;
                Task::none()
            }
            Message::StartLogin => {
                let id = self.client_id_input.trim().to_string();
                if !id.is_empty() {
                    self.send(CommandBody::LoginStart { client_id: id });
                }
                Task::none()
            }
            Message::SignInSpotify => {
                self.auth_reason = None;
                self.send(CommandBody::LoginStartLibrespot);
                Task::none()
            }
            Message::ToggleAdvancedLogin => {
                self.show_advanced_login = !self.show_advanced_login;
                Task::none()
            }
            Message::DismissPlaybackPrompt => {
                self.playback_prompt_dismissed = true;
                Task::none()
            }
            Message::UseSpotifySignInForBrowsing => {
                self.send(CommandBody::SetAuthMode { mode: AuthMode::Librespot });
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
            Message::OpenBrowserAuth(url) if url.is_empty() => Task::none(),
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
            Message::PlayContext(tracks, start_index) => {
                self.send(CommandBody::PlayContext { tracks, start_index });
                Task::none()
            }
            Message::PlayMix(tracks, name) => {
                self.send(CommandBody::PlayMix { tracks, name });
                Task::none()
            }
            Message::SaveMix(name, track_uris) => {
                self.send(CommandBody::SaveMixAsPlaylist { name, track_uris });
                Task::none()
            }
            Message::LyricOffsetChanged(offset) => {
                if let Some(ref track) = self.state.track {
                    if let Some(ref mut lrc) = self.lyrics {
                        lrc.offset_ms = offset;
                    }
                    self.send(CommandBody::SetLyricOffset {
                        track_id: track.id.clone(),
                        offset_ms: offset,
                    });
                }
                Task::none()
            }
            Message::SearchLyricsAgain => {
                if let Some(ref track) = self.state.track {
                    self.send(CommandBody::SearchLyricsAgain {
                        track_id: track.id.clone(),
                        artist: track.artist.clone(),
                        title: track.title.clone(),
                    });
                }
                Task::none()
            }
            Message::ToggleLoadLrcInput => {
                self.show_load_lrc_input = !self.show_load_lrc_input;
                Task::none()
            }
            Message::LrcInputChanged(val) => {
                self.lrc_input = val;
                Task::none()
            }
            Message::SubmitCustomLrc => {
                if let Some(ref track) = self.state.track {
                    let content = self.lrc_input.trim().to_string();
                    if !content.is_empty() {
                        self.send(CommandBody::LoadLocalLrc {
                            track_id: track.id.clone(),
                            lrc_content: content,
                        });
                        self.lrc_input.clear();
                        self.show_load_lrc_input = false;
                    }
                }
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
            ShortcutAction::OpenSearch => Task::batch([
                self.update(Message::NavSelected(NavPage::Search)),
                text_input::focus(text_input::Id::new(TOP_SEARCH_ID)),
            ]),
            ShortcutAction::ToggleLyrics => self.update(Message::ToggleLyrics),
            ShortcutAction::ToggleQueue => self.update(Message::ToggleQueue),
            ShortcutAction::ToggleFullscreen => self.update(Message::ToggleFullscreen),
            ShortcutAction::ToggleHelp => self.update(Message::ToggleHelp),
            ShortcutAction::OffsetLyricsMinus => {
                let cur = self.lyrics.as_ref().map(|l| l.offset_ms).unwrap_or(0);
                self.update(Message::LyricOffsetChanged(cur.saturating_sub(100)))
            }
            ShortcutAction::OffsetLyricsPlus => {
                let cur = self.lyrics.as_ref().map(|l| l.offset_ms).unwrap_or(0);
                self.update(Message::LyricOffsetChanged(cur.saturating_add(100)))
            }
            ShortcutAction::Refresh => self.update(Message::RefreshLibrary),
            ShortcutAction::NavigatePage(idx) => {
                if let Some(&page) = NavPage::all().get(idx) {
                    self.update(Message::NavSelected(page))
                } else {
                    Task::none()
                }
            }
            ShortcutAction::BackOrClose => {
                if self.show_diagnostics {
                    self.show_diagnostics = false;
                } else if self.show_help {
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
                self.lyrics.as_ref(),
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
            self.palette,
            self.density,
            Message::NavSelected,
            Message::ToggleSidebar,
            self.show_queue,
            Message::ToggleQueue,
            Message::OpenPlaylistsTab,
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
                column![
                    self.view_playback_prompt(),
                    self.view_page_content(user_id.as_deref())
                ]
                .spacing(10)
                .into()
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
                self.palette,
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
            self.palette,
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

        // 6. Floating Modals (Diagnostics, Help `?` or Toast)
        if self.show_diagnostics {
            return container(
                iced::widget::stack![
                    layout,
                    views::diagnostics::view(
                        &self.status,
                        &self.auth_status,
                        &self.state,
                        self.last_error.as_deref(),
                        self.palette,
                        Message::CopyDiagnostics,
                        Message::ToggleDiagnostics,
                    )
                ],
            )
            .into();
        }

        if self.show_help {
            return container(
                iced::widget::stack![layout, views::help_modal::view(self.palette, Message::ToggleHelp)],
            )
            .into();
        }

        let base = container(layout)
            .width(Length::Fill)
            .height(Length::Fill)
            .style(move |_t| container::Style {
                background: Some(self.palette.background.into()),
                ..Default::default()
            });

        if let Some(toast) = &self.toast {
            let pal = self.palette;
            let tint = if toast.ok { pal.accent } else { pal.danger };
            let card = container(
                row![
                    icon(if toast.ok { Icon::Check } else { Icon::XCircle }, 15.0, tint),
                    Space::with_width(8),
                    text(views::ellipsize(&toast.text, 80)).size(13).color(pal.text),
                ]
                .align_y(Alignment::Center),
            )
            .padding([10, 16])
            .style(move |_t| container::Style {
                background: Some(pal.surface_variant.into()),
                border: iced::Border {
                    color: tint,
                    width: 1.0,
                    radius: 10.0.into(),
                },
                ..Default::default()
            });
            let placed = container(card)
                .width(Length::Fill)
                .height(Length::Fill)
                .align_x(iced::alignment::Horizontal::Right)
                .align_y(iced::alignment::Vertical::Bottom)
                .padding([88, 20]);
            return iced::widget::stack![base, placed].into();
        }

        base.into()
    }

    fn view_top_header(&self) -> Element<'_, Message> {
        let title_str = match self.active_nav {
            NavPage::Home => "Home",
            NavPage::Search => "Search",
            NavPage::Library => "Your Library",
            NavPage::Liked => "Liked Songs",
            NavPage::Capsule => "Capsule",
            NavPage::Settings => "Settings",
            NavPage::AlbumDetail => "Album",
            NavPage::ArtistDetail => "Artist",
            NavPage::PlaylistDetail => "Playlist",
            NavPage::Lyrics => "Lyrics",
            NavPage::Recent => "Recently played",
        };

        let connected = matches!(self.status, ConnStatus::Connected { .. });
        let badge_txt = if !connected { "Reconnecting" } else if self.is_offline { "Cached library" } else { "Connected" };
        let badge_color = if !connected || self.is_offline {
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
            Density::Comfortable => Icon::RowsComfortable,
            Density::Compact => Icon::RowsCompact,
        };
        let pal = self.palette;
        let density_btn = header_button(
            pal,
            icon(density_icon, 15.0, pal.text_muted).into(),
            "Row density",
            Message::ToggleDensity,
        );
        let help_btn = header_button(
            pal,
            text("?").size(15).color(pal.text_muted).into(),
            "Keyboard shortcuts",
            Message::ToggleHelp,
        );
        let diag_color = if self.last_error.is_some() {
            pal.danger
        } else {
            pal.text_muted
        };
        let diag_btn = header_button(
            pal,
            icon(Icon::Activity, 15.0, diag_color).into(),
            "Diagnostics",
            Message::ToggleDiagnostics,
        );

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

        let palette = self.palette;
        let top_search = text_input("Search  (/ or Ctrl+K)", &self.search_query)
            .id(text_input::Id::new(TOP_SEARCH_ID))
            .on_input(Message::TopSearchChanged)
            .size(13)
            .padding([6, 12])
            .width(280)
            .style(move |_t, status| text_input::Style {
                background: palette.surface_variant.into(),
                border: iced::Border {
                    radius: 16.0.into(),
                    width: 1.0,
                    color: if matches!(status, text_input::Status::Focused) {
                        palette.accent
                    } else {
                        palette.border
                    },
                },
                icon: palette.text_muted,
                placeholder: palette.text_muted,
                value: palette.text,
                selection: iced::Color { a: 0.3, ..palette.accent },
            });

        container(
            row![
                text(title_str).size(self.density.heading_size()).color(self.palette.text),
                Space::with_width(12),
                badge,
                Space::with_width(Length::Fill),
                top_search,
                Space::with_width(12),
                perf_element,
                Space::with_width(8),
                density_btn,
                help_btn,
                diag_btn,
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

    fn view_page_content(&self, _user_id: Option<&str>) -> Element<'_, Message> {
        // The account name when Spotify told us, otherwise a plain "Signed in".
        let account_label = match &self.auth_status {
            AuthStatus::LoggedIn { display_name: Some(name), .. } if !name.trim().is_empty() => name.clone(),
            AuthStatus::LoggedIn { .. } => "Signed in".to_string(),
            _ => "Not signed in".to_string(),
        };
        match self.active_nav {
            NavPage::Home => views::home::view(
                &self.home_feed,
                self.palette,
                self.density,
                Message::PlayTrack,
                Message::PlayContext,
                Message::PlayMix,
                Message::SaveMix,
                Message::NavSelected,
                self.animations.shimmer_phase,
            ),
            NavPage::Search => views::search::view(
                &self.search_query,
                self.search_category,
                self.search_results.as_ref(),
                &self.recent_searches,
                self.palette,
                self.density,
                Message::SearchInputChanged,
                Message::SearchCategorySelected,
                Message::SearchClickRecent,
                Message::SearchClearRecent,
                Message::SearchLoadMore,
                Message::PlayTrack,
                Message::PlayContext,
                Message::OpenArtist,
                Message::OpenAlbum,
                Message::OpenPlaylist,
            ),
            NavPage::Library => views::library::view(
                self.library_tab,
                &self.library_filter,
                self.liked_sort,
                &self.liked_tracks,
                &self.playlists,
                &self.saved_albums,
                &self.followed_artists,
                &self.new_playlist_name,
                self.show_new_playlist_input,
                self.palette,
                self.density,
                Message::LibraryTabSelected,
                Message::LibraryFilterChanged,
                Message::LibrarySortChanged,
                Message::PlayTrack,
                Message::PlayContext,
                Message::OpenPlaylist,
                Message::OpenAlbum,
                Message::OpenArtist,
                Message::ToggleNewPlaylistInput,
                Message::NewPlaylistNameChanged,
                Message::CreateNewPlaylist,
                Message::DeletePlaylist,
            ),
            NavPage::Liked => views::library::view(
                LibraryTab::Liked,
                &self.library_filter,
                self.liked_sort,
                &self.liked_tracks,
                &self.playlists,
                &self.saved_albums,
                &self.followed_artists,
                &self.new_playlist_name,
                self.show_new_playlist_input,
                self.palette,
                self.density,
                Message::LibraryTabSelected,
                Message::LibraryFilterChanged,
                Message::LibrarySortChanged,
                Message::PlayTrack,
                Message::PlayContext,
                Message::OpenPlaylist,
                Message::OpenAlbum,
                Message::OpenArtist,
                Message::ToggleNewPlaylistInput,
                Message::NewPlaylistNameChanged,
                Message::CreateNewPlaylist,
                Message::DeletePlaylist,
            ),
            NavPage::Capsule => views::capsule::view(
                &self.capsule,
                self.capsule_month_offset,
                self.palette,
                self.density,
                Message::CapsulePrevMonth,
                Message::CapsuleNextMonth,
                Message::PlayTrack,
            ),
            NavPage::AlbumDetail => {
                if let Some((ref alb, ref tracks)) = self.active_album {
                    views::detail::view_album(
                        alb,
                        tracks,
                        self.palette,
                        self.density,
                        Message::BackFromDetail,
                        Message::PlayTrack,
                        Message::PlayContext,
                        Message::OpenArtist,
                    )
                } else {
                    column![
                        text("No album selected.").size(14).color(self.palette.text_muted),
                        Space::with_height(10),
                        button(text("Go to Library").size(13)).padding([8, 16]).style(views::solid(self.palette)).on_press(Message::BackFromDetail),
                    ]
                    .padding(20)
                    .into()
                }
            }
            NavPage::ArtistDetail => {
                if let Some((ref art, ref top_tracks, ref albums)) = self.active_artist {
                    views::detail::view_artist(
                        art,
                        top_tracks,
                        albums,
                        self.palette,
                        self.density,
                        Message::BackFromDetail,
                        Message::PlayTrack,
                        Message::PlayContext,
                        Message::OpenAlbum,
                    )
                } else {
                    column![
                        text("No artist selected.").size(14).color(self.palette.text_muted),
                        Space::with_height(10),
                        button(text("Go to Library").size(13)).padding([8, 16]).style(views::solid(self.palette)).on_press(Message::BackFromDetail),
                    ]
                    .padding(20)
                    .into()
                }
            }
            NavPage::PlaylistDetail => {
                if let Some((ref pl, ref tracks)) = self.active_playlist {
                    let del_id = pl.id.clone();
                    views::detail::view_playlist(
                        pl,
                        tracks,
                        self.palette,
                        self.density,
                        Message::BackFromDetail,
                        Message::PlayTrack,
                        Message::PlayContext,
                        Message::DeletePlaylist(del_id),
                    )
                } else {
                    column![
                        text("No playlist selected.").size(14).color(self.palette.text_muted),
                        Space::with_height(10),
                        button(text("Go to Library").size(13)).padding([8, 16]).style(views::solid(self.palette)).on_press(Message::BackFromDetail),
                    ]
                    .padding(20)
                    .into()
                }
            }
            NavPage::Recent => views::recent::view(
                &self.home_feed,
                self.palette,
                Message::PlayTrack,
                Message::PlayContext,
            ),
            NavPage::Settings => column![
                text("Settings").size(18).color(self.palette.text),
                Space::with_height(16),
                row![
                    text("Connected Account:").size(14).color(self.palette.text),
                    Space::with_width(8),
                    text(account_label).size(14).color(self.palette.accent),
                    Space::with_width(16),
                    button(text("Log out").size(13)).padding([8, 16]).style(views::solid(self.palette)).on_press(Message::Logout),
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
            NavPage::Lyrics => views::lyrics::view(
                self.state.track.as_ref(),
                self.lyrics.as_ref(),
                self.state.position_ms,
                self.palette,
                self.show_load_lrc_input,
                &self.lrc_input,
                Message::Seek,
                Message::LyricOffsetChanged,
                Message::SearchLyricsAgain,
                Message::ToggleLoadLrcInput,
                Message::LrcInputChanged,
                Message::SubmitCustomLrc,
            ),
        }
    }

    /// First run / signed out: one button. The own-Client-ID setup lives under Advanced.
    fn view_first_run(&self) -> Element<'_, Message> {
        let pal = self.palette;
        let title = text("Sign in with Spotify").size(22).color(pal.text);

        // Why we are here: an expired sign-in, or a failed attempt.
        let notice: Element<Message> = if let AuthStatus::Error { message } = &self.auth_status {
            container(text(message.clone()).size(13).color(pal.danger)).padding(10).into()
        } else if let Some(reason) = &self.auth_reason {
            container(text(reason.clone()).size(13).color(pal.danger)).padding(10).into()
        } else {
            Space::with_height(0).into()
        };

        let intro = column![
            text("One sign-in in your browser gives Halcyon your library and lets it play music.")
                .size(14)
                .color(pal.text),
            text("Playback needs Spotify Premium. With a Free account you can still browse your library and playlists.")
                .size(13)
                .color(pal.text_muted),
        ]
        .spacing(6);

        let main_button = button(text("Sign in with Spotify").size(15))
            .padding([10, 22])
            .style(views::solid(pal))
            .on_press(Message::SignInSpotify);

        let advanced_toggle = button(
            text(if self.show_advanced_login { "Advanced  ▾" } else { "Advanced  ▸" })
                .size(13)
                .color(pal.text_muted),
        )
        .padding([4, 0])
        .style(button::text)
        .on_press(Message::ToggleAdvancedLogin);

        let switch_back: Element<Message> =
            if self.streaming_signed_in == Some(true) && self.auth_mode == AuthMode::OwnClientId {
                button(text("Browse with the Spotify sign-in instead").size(13))
                    .padding([8, 16])
                    .style(views::solid(pal))
                    .on_press(Message::UseSpotifySignInForBrowsing)
                    .into()
            } else {
                Space::with_height(0).into()
            };

        let advanced: Element<Message> = if self.show_advanced_login {
            column![
                text("Use my own Client ID (browsing only)").size(15).color(pal.accent),
                text("Playback always uses the Spotify sign-in above; a custom Client ID cannot stream. Since February 2026 Spotify requires the app's owner to have Premium, allows one Development Mode Client ID per developer and five users, and limits search to 10 results.")
                    .size(12)
                    .color(pal.text_muted),
                text("1. Open developer.spotify.com/dashboard and log in").size(13).color(pal.text),
                text("2. Click 'Create App' and name it 'Halcyon Music'").size(13).color(pal.text),
                text("3. Set Redirect URI to: http://127.0.0.1:8888/callback (never localhost)").size(13).color(pal.text),
                text("4. Copy the Client ID, paste it below, and click Connect:").size(13).color(pal.text),
                row![
                    text_input("Paste Spotify Client ID here...", &self.client_id_input)
                        .on_input(Message::ClientIdChanged)
                        .padding(8)
                        .width(Length::Fixed(360.0)),
                    button(text("Connect with my Client ID").size(13))
                        .padding([8, 16])
                        .style(views::solid(pal))
                        .on_press(Message::StartLogin),
                ]
                .spacing(10),
                switch_back,
            ]
            .spacing(6)
            .into()
        } else {
            Space::with_height(0).into()
        };

        let cached_fallback: Element<Message> = if !self.playlists.is_empty() {
            column![
                Space::with_height(14),
                text("Offline Cache available:").size(14).color(pal.accent_secondary),
                self.view_playlists_list(),
            ]
            .spacing(6)
            .into()
        } else {
            Space::with_height(0).into()
        };

        column![
            title,
            notice,
            intro,
            Space::with_height(4),
            main_button,
            Space::with_height(8),
            advanced_toggle,
            advanced,
            cached_fallback,
        ]
        .spacing(10)
        .into()
    }

    /// Existing users who browse with their own Client ID but have no streaming sign-in yet:
    /// one dismissible prompt. Nothing is shown otherwise.
    fn view_playback_prompt(&self) -> Element<'_, Message> {
        let pal = self.palette;
        let needs_prompt = self.auth_mode == AuthMode::OwnClientId
            && self.streaming_signed_in == Some(false)
            && !self.playback_prompt_dismissed;
        if !needs_prompt {
            return Space::with_height(0).into();
        }
        container(
            row![
                column![
                    text("Sign in again to enable playback").size(14).color(pal.text),
                    text("Your library works, but playing music needs one Spotify sign-in (Premium required).")
                        .size(12)
                        .color(pal.text_muted),
                ]
                .spacing(2),
                Space::with_width(Length::Fill),
                button(text("Sign in").size(13))
                    .padding([6, 14])
                    .style(views::solid(pal))
                    .on_press(Message::SignInSpotify),
                button(text("Not now").size(13).color(pal.text_muted))
                    .padding([6, 10])
                    .style(button::text)
                    .on_press(Message::DismissPlaybackPrompt),
            ]
            .spacing(10)
            .align_y(Alignment::Center),
        )
        .padding(12)
        .width(Length::Fill)
        .into()
    }

    fn view_logging_in(&self, auth_url: &str) -> Element<'_, Message> {
        let pal = self.palette;
        let url_copy = auth_url.to_string();
        let has_link = !auth_url.is_empty();

        let hint: Element<Message> = if has_link {
            text("If the browser did not open automatically, use the button below:")
                .size(13)
                .color(pal.text_muted)
                .into()
        } else {
            text("If no browser window appeared, the sign-in link is in the daemon log: journalctl --user -u halcyon-musicd -n 20")
                .size(13)
                .color(pal.text_muted)
                .into()
        };

        let mut buttons = row![].spacing(10);
        if has_link {
            buttons = buttons.push(
                button(text("Open in Browser").size(13))
                    .padding([8, 16])
                    .style(views::solid(pal))
                    .on_press(Message::OpenBrowserAuth(url_copy)),
            );
        }
        buttons = buttons.push(
            button(text("Cancel").size(13))
                .padding([8, 16])
                .style(views::solid(pal))
                .on_press(Message::CancelLogin),
        );

        column![
            text("Connecting to Spotify...").size(20).color(pal.accent),
            text("A browser window should have opened for you to approve access.").size(14).color(pal.text),
            hint,
            buttons,
        ]
        .spacing(12)
        .into()
    }

    #[allow(dead_code)]
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
                    icon(Icon::Playlist, 16.0, self.palette.accent),
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

/// Which messages can change the set of covers the app should ask for.
/// Progress ticks and animation frames arrive constantly and never do.
fn needs_art_sync(message: &Message) -> bool {
    match message {
        Message::UiEvent(ev) => match &**ev {
            UiEvent::Protocol(body) => !matches!(body.body, EventBody::Progress { .. } | EventBody::Pong),
            UiEvent::Status(_) => true,
            UiEvent::DaemonError(_) => false,
        },
        Message::NavSelected(_)
        | Message::OpenAlbum(_)
        | Message::OpenArtist(_)
        | Message::OpenPlaylist(_)
        | Message::BackFromDetail => true,
        _ => false,
    }
}
