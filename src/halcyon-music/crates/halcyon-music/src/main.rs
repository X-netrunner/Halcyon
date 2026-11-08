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
use theme::{Density, HalcyonPalette, Mood};
use views::library::{LibraryTab, LikedSort};
use views::search::SearchCategory;
use views::sidebar::NavPage;

use iced::widget::{button, column, container, mouse_area, row, scrollable, text, text_input, Space};
use iced::{Alignment, Element, Length, Task, Theme};
use std::time::{Duration, Instant};

/// Space between the page card and the right edge of the window.
const PAGE_MARGIN: f32 = 12.0;

/// Height of the search strip that floats over the top of the page (16 px, the 44 px search
/// box, 16 px). The page's content starts below it; the strip's fade lives in `view`.
const TOP_STRIP_H: f32 = 84.0;
/// Room left at the top of pages that have no search (Capsule, Settings, details, ...).
const TOP_STRIP_H_BARE: f32 = 16.0;
/// Height of the haze at the bottom edge of the page, and the room left under the last row.
const BOTTOM_FADE_H: f32 = 24.0;

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
        size: WINDOW_DEFAULT,
        min_size: Some(WINDOW_MIN),
        // Our own slim title bar replaces the system one.
        decorations: false,
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
    /// The sidebar is collapsed (icons only) until the pointer is over it.
    sidebar_hovered: bool,
    /// The sidebar row the active pill is on (`None` on pages with no row, such as Settings).
    pill_slot: Option<usize>,
    /// When `palette.toml` was last read; a newer file means the wallpaper changed.
    rice_stamp: Option<std::time::SystemTime>,
    /// Playlist id whose first page of tracks should start playing as soon as it arrives.
    pending_play_playlist: Option<String>,
    density: Density,
    /// The colour mood (Dusk, Dawn, Forest, Ocean); remembered between launches.
    mood: Mood,
    show_fullscreen: bool,
    show_queue: bool,
    /// What the queue drawer is currently animating toward (follows `show_queue`).
    queue_target: bool,
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
    /// Bumped on every keystroke in the top search box; a delayed search only runs if it is still the latest.
    search_gen: u64,
    /// The "best results" list under the top search box.
    search_dropdown_open: bool,
    library_tab: LibraryTab,
    library_filter: String,
    /// The filter typed in the header search while on the Recently played page.
    recent_filter: String,
    /// Set while a Home feed is being built by the daemon (cleared when it arrives).
    home_loading_since: Option<Instant>,
    /// Automatic retries done while outside mixes are still missing (reset on success / refresh).
    home_retries: u8,
    home_retry_pending: bool,
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
    // Shell
    window_id: Option<iced::window::Id>,
    window_size: iced::Size,
    cursor: iced::Point,
    scroll: ScrollInfo,
    last_click: Option<(String, Instant)>,
    last_title_press: Option<Instant>,
    account_menu_open: bool,
    profile_name: Option<String>,
    profile_image: Option<String>,
    track_menu: Option<TrackMenu>,
    playlist_page: PlaylistPage,
    /// Where Lyrics was opened from, so closing it goes back there.
    page_before_lyrics: NavPage,
    /// Bumped whenever a fresh (non-cached) answer arrives; see `OfflineCheck`.
    fresh_counter: u64,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
enum Message {
    // Window / shell
    WindowId(Option<iced::window::Id>),
    WindowResized(iced::Size),
    CursorMoved(iced::Point),
    TitleBarPress,
    WindowMinimize,
    WindowToggleMaximize,
    WindowClose,
    ToggleAccountMenu,
    CloseMenus,
    OpenSettings,
    OpenSpotifyAccount,
    ContentScrolled(ScrollInfo),
    OfflineCheck(u64),
    // Playlist page
    PlaylistRowClick(usize),
    PlaylistRowPlay(usize),
    PlaylistRowMenu(usize),
    PlaylistPlayAll,
    PlaylistShuffle,
    PlaylistAddToQueue,
    PlaylistPlayNext,
    PlaylistRetry,
    PlaylistTimeout { id: String, generation: u64 },
    // Track context menu
    TrackMenuPlay,
    TrackMenuPlayNext,
    TrackMenuEnqueue,
    TrackMenuGoToAlbum,
    UiEvent(Box<UiEvent>),
    Shortcut(ShortcutAction),
    NavSelected(NavPage),
    SidebarHover(bool),
    ToggleFullscreen,
    ToggleQueue,
    /// Time to look at whether the wallpaper colours changed.
    PaletteCheck,
    ToggleLyrics,
    ToggleHelp,
    ToggleDiagnostics,
    CopyDiagnostics,
    ToggleDensity,
    CycleMood,
    SetMood(Mood),
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
    /// The pause after typing is over: run the search for generation `.0` if it is still the latest.
    SearchDebounced(u64),
    /// Enter in the top search box: open the full Search page.
    TopSearchSubmit,
    SearchPick(views::search_dropdown::Pick),
    CloseSearchDropdown,
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
    /// Play a whole playlist we only know the id of (Home tiles): fetch its tracks, then play.
    PlayPlaylist(String),
    PlayMix(Vec<Track>, String),
    SaveMix(String, Vec<String>),
    // Part 6 Messages
    SearchCategorySelected(SearchCategory),
    SearchClickRecent(String),
    SearchClearRecent,
    SearchLoadMore,
    LibraryTabSelected(LibraryTab),
    LibraryFilterChanged(String),
    RecentFilterChanged(String),
    /// The Refresh button next to the Home status chip.
    RefreshHome,
    /// Time to try again: outside mixes were still missing after the last build.
    HomeAutoRetry,
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
    /// A Made-for-you mix (by its id), opened as a playlist page.
    OpenMix(String),
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
/// Default and minimum window size.
const WINDOW_DEFAULT: iced::Size = iced::Size::new(1440.0, 900.0);
const WINDOW_MIN: iced::Size = iced::Size::new(960.0, 600.0);
/// Two presses closer than this count as a double click.
const DOUBLE_CLICK: Duration = Duration::from_millis(400);
/// Seconds a cached answer may stand alone before the "offline" banner appears.
const OFFLINE_GRACE: Duration = Duration::from_secs(4);
/// Seconds to wait for a page of playlist songs before calling it failed.
const PLAYLIST_TIMEOUT: Duration = Duration::from_secs(12);
/// Songs asked for per page of a playlist.
const PLAYLIST_PAGE: u32 = 50;
/// Id of the scroll area around the page, so pages can be reset to the top.
const CONTENT_SCROLL_ID: &str = "content-scroll";

/// How far the page scroll area is scrolled and how tall it is.
#[derive(Debug, Clone, Copy, Default)]
struct ScrollInfo {
    y: f32,
    viewport_h: f32,
    content_h: f32,
}

/// State of the open playlist page (the songs themselves live in `active_playlist`).
#[derive(Debug, Clone, Default)]
struct PlaylistPage {
    /// Total songs Spotify says the playlist has (0 until known).
    total: usize,
    /// First page asked for, nothing back yet.
    loading: bool,
    /// A later page is on its way.
    loading_more: bool,
    /// The first page never arrived (shows Retry).
    failed: bool,
    /// A later page never arrived.
    more_failed: bool,
    /// A non-cached answer arrived, so "no songs" really means none.
    fresh: bool,
    /// Bumped on every request; a timeout only counts for the request it was started for.
    generation: u64,
    selected: Option<usize>,
}

/// Right-click menu: which song and where on screen.
#[derive(Debug, Clone)]
struct TrackMenu {
    track: Track,
    at: iced::Point,
}

/// Opened by "Spotify Settings" in the account menu.
const SPOTIFY_ACCOUNT_URL: &str = "https://www.spotify.com/account";

/// True when two presses of the title bar are close enough to be a double click.
fn is_double_press(previous: Option<Instant>, now: Instant) -> bool {
    previous.is_some_and(|p| now.saturating_duration_since(p) <= DOUBLE_CLICK)
}

/// True when this press and the previous one hit the same target in time.
fn is_double_click(previous: &Option<(String, Instant)>, key: &str, now: Instant) -> bool {
    previous
        .as_ref()
        .is_some_and(|(k, t)| k == key && now.saturating_duration_since(*t) <= DOUBLE_CLICK)
}

/// The songs in a random order (Fisher-Yates with a small xorshift; no dependency needed).
fn shuffled(tracks: &[Track], seed: u64) -> Vec<Track> {
    let mut out = tracks.to_vec();
    let mut x = seed | 1;
    for i in (1..out.len()).rev() {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        out.swap(i, (x % (i as u64 + 1)) as usize);
    }
    out
}

const TOP_SEARCH_ID: &str = "top-search";

/// A short message at the bottom right. `ok` picks the colour: accent for
/// something that worked, red for something that did not.
struct Toast {
    text: String,
    ok: bool,
    until: Instant,
}

impl HalcyonApp {
    /// True while Home is showing its grey loading blocks (they pulse).
    fn skeleton_visible(&self) -> bool {
        if self.active_nav == NavPage::PlaylistDetail {
            return !self.animations.reduce_motion
                && (self.playlist_page.loading || self.playlist_page.loading_more);
        }
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

        let mood = Mood::load();
        let base_palette = HalcyonPalette::load_for_mood(mood);
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
            sidebar_hovered: false,
            pill_slot: None,
            rice_stamp: HalcyonPalette::rice_file_stamp(),
            pending_play_playlist: None,
            density: Density::Comfortable,
            mood,
            show_fullscreen: false,
            show_queue: false,
            queue_target: false,
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
            search_gen: 0,
            search_dropdown_open: false,
            library_tab: LibraryTab::Playlists,
            library_filter: String::new(),
            recent_filter: String::new(),
            home_loading_since: None,
            home_retries: 0,
            home_retry_pending: false,
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
            window_id: None,
            window_size: WINDOW_DEFAULT,
            cursor: iced::Point::ORIGIN,
            scroll: ScrollInfo::default(),
            last_click: None,
            last_title_press: None,
            account_menu_open: false,
            profile_name: None,
            profile_image: None,
            track_menu: None,
            playlist_page: PlaylistPage::default(),
            page_before_lyrics: NavPage::Home,
            fresh_counter: 0,
        };
        let window_task = iced::window::get_oldest().map(Message::WindowId);
        (app, Task::batch([task, window_task]))
    }

    fn send(&self, body: CommandBody) {
        let _ = self.commands.try_send(body);
    }

    fn subscription(&self) -> iced::Subscription<Message> {
        // Esc is seen even when a text box has taken it (that is how Esc clears the search);
        // every other shortcut only when no widget used the key (typing never triggers them).
        let key_sub = iced::event::listen_with(|event, status, _window| match event {
            iced::Event::Keyboard(iced::keyboard::Event::KeyPressed { key, modifiers, .. }) => {
                if key == iced::keyboard::Key::Named(iced::keyboard::key::Named::Escape) {
                    Some(Message::Shortcut(ShortcutAction::BackOrClose))
                } else if status == iced::event::Status::Ignored {
                    shortcuts::match_shortcut(&key, modifiers).map(Message::Shortcut)
                } else {
                    None
                }
            }
            _ => None,
        });

        let resize_sub = iced::window::resize_events().map(|(_, size)| Message::WindowResized(size));

        // The cursor position is only followed on pages with right-clickable songs.
        let cursor_sub = if matches!(self.active_nav, NavPage::PlaylistDetail) {
            iced::event::listen_with(|event, _status, _window| match event {
                iced::Event::Mouse(iced::mouse::Event::CursorMoved { position }) => {
                    Some(Message::CursorMoved(position))
                }
                _ => None,
            })
        } else {
            iced::Subscription::none()
        };

        // The full-screen glow breathes slowly: 30 frames a second, only while it is visible,
        // music plays and motion is allowed. Everywhere else the app still idles at ~0% CPU.
        let ambient = self.state.playing && !self.animations.reduce_motion;
        let anim_sub = if self.animations.is_animating() || art::is_fading() || self.skeleton_visible() {
            iced::time::every(Duration::from_millis(16)).map(|_| Message::AnimationTick)
        } else if ambient {
            iced::time::every(Duration::from_millis(33)).map(|_| Message::AnimationTick)
        } else {
            iced::Subscription::none()
        };

        let toast_sub = if self.toast.is_some() {
            iced::time::every(Duration::from_millis(500)).map(|_| Message::ToastExpire)
        } else {
            iced::Subscription::none()
        };

        // While the app follows the wallpaper, look every few seconds for a new colour file.
        let palette_sub = if self.mood == Mood::Wallpaper {
            iced::time::every(Duration::from_secs(3)).map(|_| Message::PaletteCheck)
        } else {
            iced::Subscription::none()
        };

        iced::Subscription::batch([key_sub, resize_sub, cursor_sub, anim_sub, toast_sub, palette_sub])
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        let sync_art = needs_art_sync(&message);
        let task = self.update_inner(message);
        // Any way of opening or closing the queue (button, shortcut, Esc) slides the drawer.
        if self.show_queue != self.queue_target {
            self.queue_target = self.show_queue;
            self.animations.animate_queue(self.show_queue);
        }
        self.follow_active_page();
        if sync_art {
            for cmd in self.art_requests() {
                self.send(cmd);
            }
        }
        task
    }

    /// Keep the sidebar's active pill on the row of the page that is open. It slides between
    /// rows; coming back from a page with no row, it appears in place instead of flying in.
    fn follow_active_page(&mut self) {
        let slot = self.active_nav.slot();
        if slot == self.pill_slot {
            return;
        }
        match (self.pill_slot, slot) {
            (Some(_), Some(to)) => self.animations.animate_sidebar_pill(to as f32),
            (None, Some(to)) => self.animations.set_sidebar_pill(to as f32),
            _ => {}
        }
        self.pill_slot = slot;
    }

    /// Ask for the covers of the playlist rows that are on screen (cheap; skips ones already asked).
    fn request_playlist_art(&self) {
        if let Some((_, tracks)) = &self.active_playlist {
            let (a, b) = views::playlist::visible_range(self.scroll.y, self.scroll.viewport_h.max(700.0), tracks.len());
            for cmd in art::commands_for(art::track_items(&tracks[a..b])) {
                self.send(cmd);
            }
        }
    }

    /// Ask for one page of the open playlist and start the clock that decides it failed.
    fn request_playlist_page(&mut self, offset: usize) -> Task<Message> {
        let Some((pl, _)) = &self.active_playlist else { return Task::none() };
        let id = pl.id.clone();
        self.playlist_page.generation += 1;
        let generation = self.playlist_page.generation;
        self.send(CommandBody::GetPlaylistTracks {
            id: id.clone(),
            limit: Some(PLAYLIST_PAGE),
            offset: Some(offset as u32),
        });
        Task::perform(
            async move {
                tokio::time::sleep(PLAYLIST_TIMEOUT).await;
                (id, generation)
            },
            |(id, generation)| Message::PlaylistTimeout { id, generation },
        )
    }

    /// Load the next page when the user is close to the end of what is loaded.
    fn maybe_load_more_playlist(&mut self) -> Task<Message> {
        let loaded = match &self.active_playlist {
            Some((_, tracks)) => tracks.len(),
            None => return Task::none(),
        };
        let pp = &self.playlist_page;
        if pp.loading || pp.loading_more || pp.failed || pp.more_failed || loaded == 0 || loaded >= pp.total {
            return Task::none();
        }
        if !views::playlist::near_end(self.scroll.y, self.scroll.viewport_h, self.scroll.content_h, 600.0) {
            return Task::none();
        }
        self.playlist_page.loading_more = true;
        self.request_playlist_page(loaded)
    }

    /// A cached answer started the "maybe offline" clock; a fresh one stops it.
    fn note_answer(&mut self, is_cached: bool) -> Task<Message> {
        if is_cached {
            let seen = self.fresh_counter;
            Task::perform(
                async move {
                    tokio::time::sleep(OFFLINE_GRACE).await;
                    seen
                },
                Message::OfflineCheck,
            )
        } else {
            self.fresh_counter += 1;
            self.is_offline = false;
            Task::none()
        }
    }

    fn close_menus(&mut self) {
        self.search_dropdown_open = false;
        self.account_menu_open = false;
        self.track_menu = None;
    }

    /// Ask the daemon who is signed in (name and picture). Sent on connect and after sign-in.
    fn ask_profile(&self) {
        self.send(CommandBody::GetProfile);
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
            if let Some((playlist, tracks)) = &app.active_playlist {
                v.push((playlist.art_url.as_deref(), ArtSize::Medium));
                let (a, b) = views::playlist::visible_range(app.scroll.y, app.scroll.viewport_h.max(700.0), tracks.len());
                v.extend(art::track_items(&tracks[a..b]));
            }
            v
        }

        let mut cmds = Vec::new();
        if let Some(url) = self.profile_image.as_deref() {
            push(&mut cmds, art::avatar_items(url));
        }
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
                        self.ask_profile();
                        // An older daemon answers this with "not supported by this daemon version".
                        self.send(CommandBody::GetStreamingAuth);
                        self.request_home_feed();
                        self.send(CommandBody::GetLikedTracks { limit: Some(50), offset: Some(0) });
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
                            self.ask_profile();
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
                        self.note_answer(is_cached)
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
                        self.home_loading_since = None;
                        // Mixes from outside sources (Deezer, ListenBrainz) need Spotify lookups, which
                        // Spotify may rate limit. While they are missing, try again now and then.
                        if self.home_outside_missing() {
                            if self.active_nav == NavPage::Home && self.home_retries < 6 && !self.home_retry_pending {
                                self.home_retries += 1;
                                self.home_retry_pending = true;
                                return Task::perform(
                                    async {
                                        tokio::time::sleep(Duration::from_secs(75)).await;
                                    },
                                    |_| Message::HomeAutoRetry,
                                );
                            }
                        } else {
                            self.home_retries = 0;
                        }
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
                        self.note_answer(is_cached)
                    }
                    EventBody::SavedAlbumsResult { albums } => {
                        self.saved_albums = albums;
                        Task::none()
                    }
                    EventBody::FollowedArtistsResult { artists } => {
                        self.followed_artists = artists;
                        Task::none()
                    }
                    EventBody::Profile { display_name, image_url } => {
                        // Never let a late, empty answer wipe a name or picture we already have.
                        if display_name.is_some() {
                            self.profile_name = display_name;
                        }
                        if image_url.is_some() {
                            self.profile_image = image_url;
                        }
                        Task::none()
                    }
                    EventBody::PlaylistTracksResult { playlist_id, tracks, offset, total, is_cached } => {
                        let mut task = self.note_answer(is_cached);
                        if offset == 0 && self.pending_play_playlist.as_deref() == Some(playlist_id.as_str()) {
                            if !tracks.is_empty() {
                                self.pending_play_playlist = None;
                                self.send(CommandBody::PlayContext { tracks: tracks.clone(), start_index: 0 });
                            } else if !is_cached {
                                // A fresh answer with nothing in it: the playlist is empty.
                                self.pending_play_playlist = None;
                                self.notify("That playlist has no playable tracks".to_string(), false);
                                self.animations.animate_toast_show();
                            }
                        }
                        let is_open = self.active_playlist.as_ref().is_some_and(|(pl, _)| pl.id == playlist_id);
                        if is_open {
                            let got = tracks.len();
                            let mut gap = false;
                            if let Some((_, list)) = self.active_playlist.as_mut() {
                                gap = !views::playlist::merge_page(list, offset, tracks);
                            }
                            let loaded = self.active_playlist.as_ref().map_or(0, |(_, l)| l.len());
                            let pp = &mut self.playlist_page;
                            pp.total = pp.total.max(total).max(loaded);
                            if !is_cached {
                                pp.fresh = true;
                            }
                            if got > 0 || !is_cached {
                                pp.loading = false;
                                pp.failed = false;
                                pp.loading_more = false;
                                pp.more_failed = false;
                            }
                            if gap {
                                // Pages arrived out of order: ask again for the one that is missing.
                                task = Task::batch([task, self.request_playlist_page(loaded)]);
                            }
                            self.request_playlist_art();
                        }
                        task
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
            Message::WindowId(id) => {
                self.window_id = id;
                // Open big, like Spotify: fill the screen. The default size is what
                // un-maximising returns to.
                match id {
                    Some(id) => iced::window::maximize(id, true),
                    None => Task::none(),
                }
            }
            Message::WindowResized(size) => {
                self.window_size = size;
                Task::none()
            }
            Message::CursorMoved(p) => {
                self.cursor = p;
                Task::none()
            }
            Message::TitleBarPress => {
                let now = Instant::now();
                let double = is_double_press(self.last_title_press, now);
                self.last_title_press = if double { None } else { Some(now) };
                match self.window_id {
                    Some(id) if double => iced::window::toggle_maximize(id),
                    Some(id) => iced::window::drag(id),
                    None => Task::none(),
                }
            }
            Message::WindowMinimize => match self.window_id {
                Some(id) => iced::window::minimize(id, true),
                None => Task::none(),
            },
            Message::WindowToggleMaximize => match self.window_id {
                Some(id) => iced::window::toggle_maximize(id),
                None => Task::none(),
            },
            Message::WindowClose => match self.window_id {
                Some(id) => iced::window::close(id),
                None => Task::none(),
            },
            Message::ToggleAccountMenu => {
                self.track_menu = None;
                self.account_menu_open = !self.account_menu_open;
                Task::none()
            }
            Message::CloseMenus => {
                self.close_menus();
                Task::none()
            }
            Message::OpenSettings => {
                self.close_menus();
                self.update_inner(Message::NavSelected(NavPage::Settings))
            }
            Message::OpenSpotifyAccount => {
                self.close_menus();
                let _ = tokio::process::Command::new("xdg-open")
                    .arg(SPOTIFY_ACCOUNT_URL)
                    .spawn();
                Task::none()
            }
            Message::ContentScrolled(info) => {
                self.scroll = info;
                if self.active_nav == NavPage::PlaylistDetail {
                    self.request_playlist_art();
                    return self.maybe_load_more_playlist();
                }
                Task::none()
            }
            Message::OfflineCheck(seen) => {
                // Still no fresh answer since the cached one: Spotify is not answering.
                if self.fresh_counter == seen {
                    self.is_offline = true;
                }
                Task::none()
            }
            Message::PlaylistRowClick(idx) => {
                let key = format!("pl:{idx}");
                let now = Instant::now();
                let double = is_double_click(&self.last_click, &key, now);
                self.last_click = if double { None } else { Some((key, now)) };
                self.playlist_page.selected = Some(idx);
                if double {
                    return self.update_inner(Message::PlaylistRowPlay(idx));
                }
                Task::none()
            }
            Message::PlaylistRowPlay(idx) => {
                if let Some((_, tracks)) = &self.active_playlist {
                    if idx < tracks.len() {
                        self.send(CommandBody::PlayContext { tracks: tracks.clone(), start_index: idx });
                    }
                }
                Task::none()
            }
            Message::PlaylistRowMenu(idx) => {
                let track = self.active_playlist.as_ref().and_then(|(_, t)| t.get(idx).cloned());
                if let Some(track) = track {
                    self.account_menu_open = false;
                    self.playlist_page.selected = Some(idx);
                    self.track_menu = Some(TrackMenu { track, at: self.cursor });
                }
                Task::none()
            }
            Message::PlaylistPlayAll => {
                if let Some((_, tracks)) = &self.active_playlist {
                    if !tracks.is_empty() {
                        self.send(CommandBody::PlayContext { tracks: tracks.clone(), start_index: 0 });
                    }
                }
                Task::none()
            }
            Message::PlaylistShuffle => {
                if let Some((_, tracks)) = &self.active_playlist {
                    if !tracks.is_empty() {
                        let seed = std::time::SystemTime::now()
                            .duration_since(std::time::UNIX_EPOCH)
                            .map(|d| d.as_nanos() as u64)
                            .unwrap_or(1);
                        self.send(CommandBody::PlayContext { tracks: shuffled(tracks, seed), start_index: 0 });
                    }
                }
                Task::none()
            }
            Message::PlaylistAddToQueue => {
                if let Some((_, tracks)) = &self.active_playlist {
                    let n = tracks.len();
                    let list = tracks.clone();
                    for track in list {
                        self.send(CommandBody::Enqueue { track });
                    }
                    if n > 0 {
                        self.notify(format!("Added {n} songs to the queue"), true);
                        self.animations.animate_toast_show();
                    }
                }
                Task::none()
            }
            Message::PlaylistPlayNext => {
                if let Some((_, tracks)) = &self.active_playlist {
                    let n = tracks.len();
                    let list = tracks.clone();
                    // Last first, so the playlist ends up in its own order right after the current song.
                    for track in list.into_iter().rev() {
                        self.send(CommandBody::PlayNext { track });
                    }
                    if n > 0 {
                        self.notify(format!("{n} songs play next"), true);
                        self.animations.animate_toast_show();
                    }
                }
                Task::none()
            }
            Message::PlaylistRetry => {
                let loaded = self.active_playlist.as_ref().map_or(0, |(_, l)| l.len());
                if loaded == 0 {
                    self.playlist_page.failed = false;
                    self.playlist_page.loading = true;
                    self.request_playlist_page(0)
                } else {
                    self.playlist_page.more_failed = false;
                    self.playlist_page.loading_more = true;
                    self.request_playlist_page(loaded)
                }
            }
            Message::PlaylistTimeout { id, generation } => {
                let current = self.active_playlist.as_ref().is_some_and(|(pl, _)| pl.id == id)
                    && self.playlist_page.generation == generation;
                if current {
                    let loaded = self.active_playlist.as_ref().map_or(0, |(_, l)| l.len());
                    let pp = &mut self.playlist_page;
                    if loaded == 0 && pp.loading {
                        pp.loading = false;
                        pp.failed = true;
                    } else if pp.loading_more {
                        pp.loading_more = false;
                        pp.more_failed = true;
                    }
                }
                Task::none()
            }
            Message::TrackMenuPlay => {
                if let Some(m) = self.track_menu.take() {
                    self.send(CommandBody::PlayTrack { track: m.track });
                }
                Task::none()
            }
            Message::TrackMenuPlayNext => {
                if let Some(m) = self.track_menu.take() {
                    self.notify(format!("\"{}\" plays next", views::ellipsize(&m.track.title, 40)), true);
                    self.send(CommandBody::PlayNext { track: m.track });
                }
                Task::none()
            }
            Message::TrackMenuEnqueue => {
                if let Some(m) = self.track_menu.take() {
                    self.notify(format!("Added \"{}\" to the queue", views::ellipsize(&m.track.title, 40)), true);
                    self.send(CommandBody::Enqueue { track: m.track });
                }
                Task::none()
            }
            Message::TrackMenuGoToAlbum => {
                let album = self.track_menu.take().and_then(|m| m.track.album_id);
                match album {
                    Some(id) => self.update_inner(Message::OpenAlbum(id)),
                    None => Task::none(),
                }
            }
            Message::Shortcut(action) => self.handle_shortcut(action),
            Message::NavSelected(page) => {
                self.close_menus();
                if page == NavPage::Lyrics && self.active_nav != NavPage::Lyrics {
                    self.page_before_lyrics = self.active_nav;
                }
                self.scroll = ScrollInfo::default();
                if page != NavPage::Recent {
                    self.recent_filter.clear();
                }
                if !matches!(page, NavPage::Library | NavPage::Liked) {
                    self.library_filter.clear();
                }
                self.active_nav = page;
                if page == NavPage::Home || page == NavPage::Recent {
                    self.request_home_feed();
                    // The pinned Liked Songs card on Home needs the songs.
                    self.send(CommandBody::GetLikedTracks { limit: Some(50), offset: Some(0) });
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
                scrollable::snap_to(scrollable::Id::new(CONTENT_SCROLL_ID), scrollable::RelativeOffset::START)
            }
            Message::SidebarHover(hovered) => {
                if self.sidebar_hovered != hovered {
                    self.sidebar_hovered = hovered;
                    self.animations.animate_sidebar(hovered);
                }
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
                self.close_menus();
                if self.active_nav == NavPage::Lyrics {
                    self.active_nav = self.page_before_lyrics;
                } else {
                    self.page_before_lyrics = self.active_nav;
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
            Message::CycleMood => {
                self.mood = self.mood.next();
                self.mood.save();
                self.base_palette = HalcyonPalette::load_for_mood(self.mood);
                self.rice_stamp = HalcyonPalette::rice_file_stamp();
                self.retint();
                Task::none()
            }
            Message::SetMood(mood) => {
                self.mood = mood;
                self.mood.save();
                self.base_palette = HalcyonPalette::load_for_mood(self.mood);
                self.rice_stamp = HalcyonPalette::rice_file_stamp();
                self.retint();
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
                self.search_query = val.clone();
                self.search_offset = 0;
                self.search_category = SearchCategory::Top;
                self.search_gen = self.search_gen.wrapping_add(1);
                if val.trim().is_empty() {
                    self.search_results = None;
                    self.search_dropdown_open = false;
                    return Task::none();
                }
                // Show the best results under the box instead of jumping to the Search page.
                self.search_dropdown_open = self.active_nav != NavPage::Search;
                // Wait for a short pause in typing, so one request is made per word, not per key.
                let generation = self.search_gen;
                Task::perform(
                    async move {
                        tokio::time::sleep(Duration::from_millis(250)).await;
                        generation
                    },
                    Message::SearchDebounced,
                )
            }
            Message::SearchDebounced(generation) => {
                if generation == self.search_gen && !self.search_query.trim().is_empty() {
                    self.send(CommandBody::DetailedSearch {
                        query: self.search_query.clone(),
                        search_type: SearchCategory::Top.api_type().to_string(),
                        limit: 10,
                        offset: 0,
                    });
                }
                Task::none()
            }
            Message::TopSearchSubmit => {
                if self.search_query.trim().is_empty() {
                    return Task::none();
                }
                self.search_dropdown_open = false;
                if self.active_nav != NavPage::Search {
                    return self.update_inner(Message::NavSelected(NavPage::Search));
                }
                Task::none()
            }
            Message::SearchPick(pick) => {
                self.search_dropdown_open = false;
                match pick {
                    views::search_dropdown::Pick::Track(track) => self.update_inner(Message::PlayTrack(track)),
                    views::search_dropdown::Pick::Artist(id) => self.update_inner(Message::OpenArtist(id)),
                    views::search_dropdown::Pick::Album(id) => self.update_inner(Message::OpenAlbum(id)),
                    views::search_dropdown::Pick::Playlist(id) => self.update_inner(Message::OpenPlaylist(id)),
                }
            }
            Message::CloseSearchDropdown => {
                self.search_dropdown_open = false;
                Task::none()
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
            Message::PaletteCheck => {
                let stamp = HalcyonPalette::rice_file_stamp();
                if stamp != self.rice_stamp {
                    self.rice_stamp = stamp;
                    self.base_palette = HalcyonPalette::load_for_mood(self.mood);
                    self.retint();
                }
                Task::none()
            }
            Message::LibraryTabSelected(tab) => {
                self.library_tab = tab;
                // On the Liked Songs page the tabs double as the way back to the library.
                if self.active_nav == NavPage::Liked {
                    return self.update_inner(Message::NavSelected(NavPage::Library));
                }
                Task::none()
            }
            Message::LibraryFilterChanged(text) => {
                self.library_filter = text;
                Task::none()
            }
            Message::RefreshHome => {
                self.home_retries = 0;
                self.refresh_home();
                Task::none()
            }
            Message::HomeAutoRetry => {
                self.home_retry_pending = false;
                if self.active_nav == NavPage::Home && self.home_loading_since.is_none() {
                    self.request_home_feed();
                }
                Task::none()
            }
            Message::RecentFilterChanged(text) => {
                self.recent_filter = text;
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
                let found = self
                    .playlists
                    .iter()
                    .find(|p| p.id == id)
                    .or_else(|| self.home_feed.playlists.iter().find(|p| p.id == id))
                    .or_else(|| self.search_results.as_ref().and_then(|r| r.playlists.iter().find(|p| p.id == id)))
                    .cloned();
                let Some(pl) = found else { return Task::none() };
                self.close_menus();
                self.active_playlist = Some((pl, vec![]));
                self.playlist_page = PlaylistPage { loading: true, ..Default::default() };
                self.scroll = ScrollInfo::default();
                self.active_nav = NavPage::PlaylistDetail;
                self.animations.animate_page_switch();
                let first_page = self.request_playlist_page(0);
                Task::batch([
                    first_page,
                    scrollable::snap_to(scrollable::Id::new(CONTENT_SCROLL_ID), scrollable::RelativeOffset::START),
                ])
            }
            Message::OpenMix(id) => {
                let Some(mix) = self.home_feed.made_for_you.iter().find(|m| m.id == id).cloned() else {
                    return Task::none();
                };
                self.close_menus();
                // A mix is not a Spotify playlist: its songs are already here, so the page is
                // built from them and never asks the daemon for pages.
                let pl = Playlist {
                    id: format!("mix:{}", mix.id),
                    name: mix.title.clone(),
                    owner: format!("Halcyon · {}", mix.source),
                    snapshot_id: None,
                    art_url: mix.art_url.clone(),
                    total_tracks: mix.tracks.len() as u32,
                    uri: format!("halcyon:mix:{}", mix.id),
                };
                self.playlist_page = PlaylistPage { total: mix.tracks.len(), fresh: true, ..Default::default() };
                self.active_playlist = Some((pl, mix.tracks));
                self.scroll = ScrollInfo::default();
                self.active_nav = NavPage::PlaylistDetail;
                self.animations.animate_page_switch();
                scrollable::snap_to(scrollable::Id::new(CONTENT_SCROLL_ID), scrollable::RelativeOffset::START)
            }
            Message::BackFromDetail => {
                // A mix came from Home, so Back goes home; real playlists go back to the library.
                let from_mix = self
                    .active_playlist
                    .as_ref()
                    .is_some_and(|(pl, _)| pl.id.starts_with("mix:"));
                self.active_nav = if self.active_nav == NavPage::PlaylistDetail && from_mix {
                    NavPage::Home
                } else {
                    NavPage::Library
                };
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
                self.profile_name = None;
                self.profile_image = None;
                self.close_menus();
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
                self.refresh_home();
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
            Message::PlayPlaylist(id) => {
                self.pending_play_playlist = Some(id.clone());
                self.send(CommandBody::GetPlaylistTracks {
                    id,
                    limit: Some(PLAYLIST_PAGE),
                    offset: Some(0),
                });
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
                // One layer per press, the topmost first.
                if self.search_dropdown_open {
                    self.search_dropdown_open = false;
                } else if self.track_menu.is_some() || self.account_menu_open {
                    self.close_menus();
                } else if self.show_diagnostics {
                    self.show_diagnostics = false;
                } else if self.show_help {
                    self.show_help = false;
                } else if self.show_fullscreen {
                    self.show_fullscreen = false;
                } else if self.show_queue {
                    self.show_queue = false;
                } else if self.active_nav == NavPage::Lyrics {
                    self.active_nav = self.page_before_lyrics;
                } else if !self.search_query.is_empty() {
                    self.search_query.clear();
                    self.search_results = None;
                    self.search_offset = 0;
                }
                Task::none()
            }
            ShortcutAction::PlaySelected => Task::none(),
            ShortcutAction::PlayNextSelected => Task::none(),
            ShortcutAction::EnqueueSelected => Task::none(),
        }
    }

    /// The name shown in the account menu: Spotify's, else what the daemon said at sign-in.
    fn account_name(&self) -> String {
        if let Some(n) = self.profile_name.as_deref().filter(|n| !n.trim().is_empty()) {
            return n.to_string();
        }
        match &self.auth_status {
            AuthStatus::LoggedIn { display_name: Some(n), .. } if !n.trim().is_empty() => n.clone(),
            _ => "Spotify user".to_string(),
        }
    }

    fn view(&self) -> Element<'_, Message> {
        let pal = self.palette;
        let connected = matches!(self.status, ConnStatus::Connected { .. });
        let logged_in = matches!(self.auth_status, AuthStatus::LoggedIn { .. });
        let titlebar = views::titlebar::view(
            connected,
            pal,
            Message::TitleBarPress,
            Message::WindowMinimize,
            Message::WindowToggleMaximize,
            Message::WindowClose,
        );

        // 1. Fullscreen Now Playing overlay (keeps the title bar so the window can still be moved)
        if self.show_fullscreen {
            return column![
                titlebar,
                views::fullscreen::view(
                    &self.state,
                    &self.palette,
                    self.animations.breath(),
                    self.animations.clock(),
                    self.lyrics.as_ref(),
                    Message::TogglePlay,
                    Message::Next,
                    Message::Previous,
                    Message::Seek,
                    Message::ToggleFullscreen,
                )
            ]
            .into();
        }

        // 2. Sidebar Navigation, with the account circle at its top
        let account_name = self.account_name();
        let account_header: Element<Message> = if logged_in {
            views::account::avatar_button(
                &account_name,
                self.profile_image.as_deref(),
                self.account_menu_open,
                pal,
                Message::ToggleAccountMenu,
            )
        } else {
            Space::with_height(views::account::AVATAR_SIZE + 4.0).into()
        };
        // The sidebar's width follows an animation: it opens under the pointer and pushes the
        // page aside rather than covering it.
        let sidebar_w = views::sidebar::width_for(self.animations.sidebar_progress());
        let sidebar = views::sidebar::view(
            self.active_nav,
            self.animations.sidebar_progress(),
            self.pill_slot.map(|_| self.animations.sidebar_pill.peek()),
            self.palette,
            self.density,
            Message::NavSelected,
            Message::SidebarHover,
            self.show_queue,
            Message::ToggleQueue,
            self.animations.clock(),
            self.state.playing,
            self.state
                .track
                .as_ref()
                .map(|t| t.id.bytes().fold(0u32, |a, b| a.wrapping_mul(31).wrapping_add(b as u32)) as f32 % 97.0)
                .unwrap_or(0.0),
            account_header,
        );

        // 3. Center Content Page
        let content_area: Element<Message> = match self.auth_status {
            AuthStatus::LoggedOut | AuthStatus::Error { .. } => {
                container(self.view_first_run()).padding(theme::space::XL).into()
            }
            AuthStatus::LoggingIn { ref auth_url } => {
                container(self.view_logging_in(auth_url)).padding(theme::space::XL).into()
            }
            AuthStatus::LoggedIn { ref user_id, .. } => {
                column![
                    self.view_playback_prompt(),
                    self.view_page_content(user_id.as_deref())
                ]
                .spacing(theme::space::MD)
                .into()
            }
        };

        // A new page floats up 18 px into place as it appears. The search strip is drawn *over*
        // the page (not above it), so the page starts under a fade and content that scrolls up
        // melts into a haze instead of being cut by a hard line.
        let rise = (1.0 - self.animations.page_progress()) * 18.0;
        let banner = self.view_banner();
        let banner_room = if banner.is_some() { 44.0 } else { 0.0 };
        let page = scrollable(
            container(content_area)
                .width(Length::Fill)
                .padding(iced::Padding {
                    top: rise + self.top_strip_h() + banner_room,
                    right: theme::space::XL,
                    bottom: BOTTOM_FADE_H,
                    left: theme::space::XL,
                }),
        )
            .id(scrollable::Id::new(CONTENT_SCROLL_ID))
            // The scrollbar is invisible (wheel and trackpad still scroll).
            .direction(scrollable::Direction::Vertical(
                scrollable::Scrollbar::new().width(0).scroller_width(0).margin(0),
            ))
            .on_scroll(|v| {
                Message::ContentScrolled(ScrollInfo {
                    y: v.absolute_offset().y,
                    viewport_h: v.bounds().height,
                    content_h: v.content_bounds().height,
                })
            })
            .height(Length::Fill)
            .width(Length::Fill);

        // The search sits in a notch that hangs from the top edge of the page; the page scrolls
        // under it. No fades, no blur.
        let mut top_strip = column![self.view_top_header()].width(Length::Fill);
        if let Some(banner) = banner {
            top_strip = top_strip.push(banner);
        }
        let center_with_header = iced::widget::stack![page, container(top_strip).width(Length::Fill)]
            .width(Length::Fill)
            .height(Length::Fill);

        // 4. The page is one rounded card. The queue drawer is *not* inside it: it sits on the
        // window frame beside it, like the sidebar and the player bar, and slides open.
        let page_card = container(center_with_header)
            .width(Length::Fill)
            .height(Length::Fill)
            .clip(true)
            .style(move |_t| container::Style {
                // A slow wash of colour that follows the wallpaper and the album cover.
                background: Some(self.palette.page_background()),
                border: iced::Border {
                    color: self.palette.soft_border(),
                    width: 1.0,
                    radius: theme::radius::XL.into(),
                },
                ..Default::default()
            });
        let queue_open_amount = self.animations.queue_progress();
        let drawer: Element<Message> = if queue_open_amount > 0.001 || self.show_queue {
            container(views::queue_drawer::view(
                &self.state,
                self.palette,
                self.animations.clock(),
                Message::ToggleQueue,
                Message::Dequeue,
            ))
            .width(views::queue_drawer::QUEUE_DRAWER_WIDTH * queue_open_amount)
            .height(Length::Fill)
            .clip(true)
            .into()
        } else {
            Space::with_width(0).into()
        };
        let main_row = row![
            sidebar,
            container(page_card)
                .width(Length::Fill)
                .height(Length::Fill)
                .padding(iced::Padding { top: 0.0, right: PAGE_MARGIN, bottom: 0.0, left: 0.0 }),
            drawer,
        ]
        .width(Length::Fill)
        .height(Length::Fill);

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
            self.active_nav == NavPage::Lyrics,
            self.show_queue,
        );

        let layout = column![titlebar, main_row, bottom_bar]
            .width(Length::Fill)
            .height(Length::Fill);

        // One frame under the title bar, the sidebar and the player bar, so they are a single
        // surface (not separate islands). Its colours come from the wallpaper palette.
        let base = container(layout)
            .width(Length::Fill)
            .height(Length::Fill)
            .style(move |_t| container::Style {
                background: Some(self.palette.chrome_background()),
                ..Default::default()
            });

        // 6. Layers on top, lowest first
        let mut layers: Vec<Element<Message>> = vec![base.into()];

        if self.show_diagnostics {
            layers.push(views::diagnostics::view(
                &self.status,
                &self.auth_status,
                &self.state,
                self.last_error.as_deref(),
                self.palette,
                Message::CopyDiagnostics,
                Message::ToggleDiagnostics,
            ));
        }
        if self.show_help {
            layers.push(views::help_modal::view(self.palette, Message::ToggleHelp));
        }
        if self.account_menu_open && logged_in {
            let card = views::account::menu_card(
                account_name.clone(),
                self.profile_image.as_deref(),
                pal,
                Message::OpenSettings,
                Message::OpenSpotifyAccount,
                Message::Logout,
            );
            let top = views::titlebar::HEIGHT + theme::space::SM + views::account::AVATAR_SIZE + theme::space::SM;
            layers.push(views::account::overlay(card, theme::space::LG, top, Message::CloseMenus));
        }
        if self.search_dropdown_open && logged_in && !self.search_query.trim().is_empty() {
            let side = sidebar_w;
            // The search box is centred on the window (like the name in the title bar), so
            // the list is too, as long as it still clears the sidebar.
            let left = ((self.window_size.width - views::search_dropdown::WIDTH) / 2.0).max(side);
            // Title bar + header padding + the search box itself.
            let top = views::titlebar::HEIGHT + theme::space::LG + 44.0;
            let card = views::search_dropdown::view(
                &self.search_query,
                self.search_results.as_ref(),
                pal,
                Message::SearchPick,
                Message::TopSearchSubmit,
            );
            layers.push(
                iced::widget::stack![
                    // Clicking anywhere below the box (but not on the sidebar) closes the list.
                    container(
                        mouse_area(Space::new(Length::Fill, Length::Fill))
                            .on_press(Message::CloseSearchDropdown)
                            .on_right_press(Message::CloseSearchDropdown)
                    )
                    .width(Length::Fill)
                    .height(Length::Fill)
                    .padding(iced::Padding { top: top - 4.0, left: side, right: 0.0, bottom: 0.0 }),
                    container(card)
                        .width(Length::Fill)
                        .height(Length::Fill)
                        .padding(iced::Padding { top, left, right: 0.0, bottom: 0.0 }),
                ]
                .into(),
            );
        }
        if let Some(menu) = &self.track_menu {
            let (x, y) = views::track_menu::place(menu.at, self.window_size);
            let card = views::track_menu::card(
                pal,
                Message::TrackMenuPlay,
                Message::TrackMenuPlayNext,
                Message::TrackMenuEnqueue,
                menu.track.album_id.is_some().then_some(Message::TrackMenuGoToAlbum),
            );
            layers.push(views::account::overlay(card, x, y, Message::CloseMenus));
        }

        if let Some(toast) = &self.toast {
            let tint = if toast.ok { pal.accent } else { pal.danger };
            let card = container(
                row![
                    icon(if toast.ok { Icon::Check } else { Icon::XCircle }, 15.0, tint),
                    Space::with_width(8),
                    text(views::ellipsize(&toast.text, 80)).size(13).color(pal.text),
                ]
                .align_y(Alignment::Center),
            )
            .padding([12, 20])
            .style(move |_t| container::Style {
                background: Some(pal.surface_variant.into()),
                border: iced::Border { color: theme::alpha(tint, 0.6), width: 1.0, radius: theme::radius::PILL.into() },
                shadow: pal.glow_shadow(0.25, 24.0),
                ..Default::default()
            });
            layers.push(
                container(card)
                    .width(Length::Fill)
                    .height(Length::Fill)
                    .align_x(iced::alignment::Horizontal::Right)
                    .align_y(iced::alignment::Vertical::Bottom)
                    .padding([96, 24])
                    .into(),
            );
        }

        iced::widget::stack(layers).into()
    }

    /// A gentle one-line notice when the daemon is away or Spotify is not answering.
    fn view_banner(&self) -> Option<Element<'_, Message>> {
        let connected = matches!(self.status, ConnStatus::Connected { .. });
        let (msg, tint) = if !connected {
            ("Can't reach the Halcyon daemon. Trying again…", self.palette.accent_secondary)
        } else if self.is_offline {
            (
                "Spotify isn't answering right now (it may be rate limiting). Showing saved data; Ctrl+R tries again.",
                self.palette.accent_secondary,
            )
        } else {
            return None;
        };
        let pal = self.palette;
        Some(
            container(text(msg).size(theme::type_size::SMALL + 1.0).color(pal.text))
                .padding([theme::space::SM, theme::space::LG])
                .width(Length::Fill)
                .style(move |_t| container::Style {
                    background: Some(iced::Color { a: 0.12, ..tint }.into()),
                    border: iced::Border { color: iced::Color { a: 0.4, ..tint }, width: 1.0, radius: theme::radius::MD.into() },
                    ..Default::default()
                })
                .into(),
        )
        .map(|b: Element<'_, Message>| container(b).padding([0.0, theme::space::XL]).width(Length::Fill).into())
    }

    /// Ask the daemon for a fresh Home feed and remember that one is on its way.
    fn request_home_feed(&mut self) {
        self.home_loading_since = Some(Instant::now());
        self.send(CommandBody::GetHomeFeed);
    }

    /// A manual refresh. Ignored while a build is under way (it would only queue more Spotify
    /// searches); a build that has run for over 90 s is treated as lost and may be repeated.
    fn refresh_home(&mut self) {
        if let Some(since) = self.home_loading_since {
            if since.elapsed() < Duration::from_secs(90) {
                return;
            }
        }
        self.request_home_feed();
    }

    /// True while no mix from an outside source (Deezer, ListenBrainz) is on Home.
    fn home_outside_missing(&self) -> bool {
        self.home_feed.made_for_you.iter().all(|m| m.source == "Halcyon Local")
    }

    /// Height reserved at the top of the page: tall where the header search shows, slim elsewhere.
    fn top_strip_h(&self) -> f32 {
        if !matches!(self.auth_status, AuthStatus::LoggedIn { .. }) {
            return TOP_STRIP_H_BARE;
        }
        match self.active_nav {
            NavPage::Home | NavPage::Search | NavPage::Library | NavPage::Liked | NavPage::Recent => TOP_STRIP_H,
            _ => TOP_STRIP_H_BARE,
        }
    }

    /// The top strip: the search box, centred on the window (so it lines up with the name in
    /// the title bar), with the frame-time readout on the right when `--perf` is on.
    fn view_top_header(&self) -> Element<'_, Message> {
        let pal = self.palette;
        let logged_in = matches!(self.auth_status, AuthStatus::LoggedIn { .. });

        let perf_element: Element<Message> = if self.perf_overlay {
            let ms = self.animations.last_frame_time.as_secs_f32() * 1000.0;
            let fps = if ms > 0.0 { 1000.0 / ms } else { 60.0 };
            text(format!("{ms:.1}ms | {fps:.0} FPS")).size(11).color(pal.accent).into()
        } else {
            Space::with_width(0).into()
        };

        // Which search the header carries: the global one on Home and Search, a filter on Library
        // and Recently played, none anywhere else.
        let mode: Option<(&'static str, &str, fn(String) -> Message, Option<Message>)> = match self.active_nav {
            NavPage::Home | NavPage::Search => Some((
                "What do you want to play?",
                self.search_query.as_str(),
                Message::TopSearchChanged as fn(String) -> Message,
                Some(Message::TopSearchSubmit),
            )),
            NavPage::Library => Some((
                "Search playlists, albums and artists",
                self.library_filter.as_str(),
                Message::LibraryFilterChanged as fn(String) -> Message,
                None,
            )),
            NavPage::Liked => Some((
                "Search liked songs",
                self.library_filter.as_str(),
                Message::LibraryFilterChanged as fn(String) -> Message,
                None,
            )),
            NavPage::Recent => Some((
                "Search recently played",
                self.recent_filter.as_str(),
                Message::RecentFilterChanged as fn(String) -> Message,
                None,
            )),
            _ => None,
        };

        let search: Element<Message> = if let (true, Some((placeholder, value, on_input, on_submit))) = (logged_in, mode) {
            let input = text_input(placeholder, value)
                .id(text_input::Id::new(TOP_SEARCH_ID))
                .on_input(on_input)
                .on_submit_maybe(on_submit)
                .size(theme::type_size::BODY + 1.0)
                .padding(iced::Padding { top: 11.0, bottom: 11.0, left: 46.0, right: theme::space::LG })
                .width(Length::Fill)
                .style(move |_t, status| text_input::Style {
                    background: theme::alpha(pal.surface_variant, 0.55).into(),
                    border: iced::Border {
                        radius: 999.0.into(),
                        width: 1.0,
                        color: if matches!(status, text_input::Status::Focused) {
                            pal.accent
                        } else {
                            theme::alpha(pal.border, 0.45)
                        },
                    },
                    icon: pal.text_muted,
                    placeholder: pal.text_muted,
                    value: pal.text,
                    selection: iced::Color { a: 0.3, ..pal.accent },
                });
            // The notch: the frame's colour, square at the top where it joins the title bar,
            // rounded at the bottom, with the search box inside it.
            let notch_color = theme::mix(theme::mix(pal.background, pal.surface, 0.75), pal.glow, 0.10);
            container(
                container(iced::widget::stack![
                    input,
                    container(icon(Icon::Search, 16.0, pal.text_muted))
                        .height(Length::Fill)
                        .padding([0.0, theme::space::LG])
                        .align_y(iced::alignment::Vertical::Center),
                ])
                .width(views::search_dropdown::WIDTH),
            )
            .padding(iced::Padding { top: 10.0, right: 22.0, bottom: 14.0, left: 22.0 })
            .style(move |_t| container::Style {
                background: Some(notch_color.into()),
                border: iced::Border {
                    radius: iced::border::Radius {
                        top_left: 0.0,
                        top_right: 0.0,
                        bottom_right: 28.0,
                        bottom_left: 28.0,
                    },
                    ..Default::default()
                },
                shadow: iced::Shadow {
                    color: theme::alpha(iced::Color::BLACK, 0.28),
                    offset: iced::Vector::new(0.0, 6.0),
                    blur_radius: 18.0,
                },
                ..Default::default()
            })
            .into()
        } else {
            Space::with_width(0).into()
        };

        // The page card does not start at the window's left edge (the sidebar is there) or end
        // at its right edge (queue drawer, margin). Centring inside the card would put the
        // search off the window's middle, so the difference is taken up with padding: the box
        // stays under the "Halcyon" in the title bar, also while the sidebar opens.
        let sidebar_w = views::sidebar::width_for(self.animations.sidebar_progress());
        let drawer_w = views::queue_drawer::QUEUE_DRAWER_WIDTH * self.animations.queue_progress();
        let shift = PAGE_MARGIN + drawer_w - sidebar_w;
        let pad_left = theme::space::XL + shift.max(0.0);
        let pad_right = theme::space::XL + (-shift).max(0.0);

        let search_row = container(search)
            .width(Length::Fill)
            .center_x(Length::Fill)
            .padding(iced::Padding {
                top: 0.0,
                right: pad_right,
                bottom: 0.0,
                left: pad_left,
            });

        if !self.perf_overlay {
            return search_row.into();
        }
        iced::widget::stack![
            search_row,
            container(perf_element)
                .width(Length::Fill)
                .height(Length::Fill)
                .align_x(iced::alignment::Horizontal::Right)
                .align_y(iced::alignment::Vertical::Center)
                .padding([0.0, theme::space::XL]),
        ]
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
                &self.liked_tracks,
                Message::PlayTrack,
                Message::PlayContext,
                Message::PlayPlaylist,
                Message::OpenPlaylist,
                Message::PlayMix,
                Message::SaveMix,
                Message::OpenMix,
                Message::NavSelected,
                self.animations.shimmer_phase,
                self.animations.page_progress(),
                if self.home_loading_since.is_some() {
                    views::home::HomeStatus::Loading
                } else if self.home_outside_missing() && !self.home_feed.made_for_you.is_empty() {
                    if self.is_offline {
                        views::home::HomeStatus::WaitingOnSpotify
                    } else {
                        views::home::HomeStatus::Partial
                    }
                } else {
                    views::home::HomeStatus::Live
                },
                Message::RefreshHome,
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
                Message::LibraryFilterChanged as fn(String) -> Message,
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
                Message::NavSelected(NavPage::Liked),
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
                Message::LibraryFilterChanged as fn(String) -> Message,
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
                Message::NavSelected(NavPage::Liked),
            ),
            NavPage::Capsule => views::capsule::view(
                &self.capsule,
                self.capsule_month_offset,
                self.palette,
                self.density,
                &self.account_name(),
                self.profile_image.as_deref(),
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
                    let pp = &self.playlist_page;
                    let phase = if pp.failed {
                        views::playlist::Phase::Failed
                    } else if !tracks.is_empty() {
                        views::playlist::Phase::Ready
                    } else if pp.fresh && !pp.loading {
                        views::playlist::Phase::Empty
                    } else {
                        views::playlist::Phase::Loading
                    };
                    views::playlist::view(
                        views::playlist::Page {
                            playlist: pl,
                            tracks,
                            total: pp.total,
                            phase,
                            loading_more: pp.loading_more,
                            more_failed: pp.more_failed,
                            selected: pp.selected,
                            scroll_y: self.scroll.y,
                            viewport_h: self.scroll.viewport_h.max(700.0),
                            shimmer: self.animations.shimmer_phase,
                            palette: self.palette,
                        },
                        views::playlist::Actions {
                            back: Message::BackFromDetail,
                            play_all: Message::PlaylistPlayAll,
                            shuffle: Message::PlaylistShuffle,
                            add_to_queue: Message::PlaylistAddToQueue,
                            play_next: Message::PlaylistPlayNext,
                            retry: Message::PlaylistRetry,
                            delete: (!pl.id.starts_with("mix:")).then(|| Message::DeletePlaylist(pl.id.clone())),
                            save: pl.id.starts_with("mix:").then(|| {
                                Message::SaveMix(pl.name.clone(), tracks.iter().map(|t| t.uri.clone()).collect())
                            }),
                            row_click: Message::PlaylistRowClick,
                            row_play: Message::PlaylistRowPlay,
                            row_menu: Message::PlaylistRowMenu,
                        },
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
                &self.recent_filter,
                self.palette,
                Message::PlayTrack,
                Message::PlayContext,
            ),
            NavPage::Settings => views::settings::view(
                account_label.clone(),
                self.density,
                self.mood,
                self.palette,
                Message::ToggleDensity,
                Message::SetMood,
                Message::Logout,
                Message::OpenSpotifyAccount,
                self.last_error.is_some(),
                Message::ToggleDiagnostics,
                Message::CopyDiagnostics,
            ),
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
        | Message::OpenMix(_)
        | Message::BackFromDetail => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_quick_title_presses_are_a_double_click() {
        let t0 = Instant::now();
        assert!(is_double_press(Some(t0), t0 + Duration::from_millis(250)));
        assert!(!is_double_press(Some(t0), t0 + Duration::from_millis(900)));
        assert!(!is_double_press(None, t0));
    }

    #[test]
    fn a_double_click_needs_the_same_row() {
        let t0 = Instant::now();
        let prev = Some(("pl:3".to_string(), t0));
        assert!(is_double_click(&prev, "pl:3", t0 + Duration::from_millis(200)));
        assert!(!is_double_click(&prev, "pl:4", t0 + Duration::from_millis(200)));
        assert!(!is_double_click(&prev, "pl:3", t0 + Duration::from_secs(2)));
        assert!(!is_double_click(&None, "pl:3", t0));
    }

    fn track(i: usize) -> Track {
        Track::simple(format!("id{i}"), format!("t{i}"), "a".into(), "b".into(), 1000)
    }

    #[test]
    fn shuffle_keeps_every_song_and_depends_on_the_seed() {
        let list: Vec<Track> = (0..50).map(track).collect();
        let a = shuffled(&list, 7);
        let b = shuffled(&list, 7);
        let c = shuffled(&list, 8);
        assert_eq!(a, b, "same seed, same order");
        assert_ne!(a, c, "another seed gives another order");
        let mut ids: Vec<_> = a.iter().map(|t| t.id.clone()).collect();
        ids.sort();
        let mut want: Vec<_> = list.iter().map(|t| t.id.clone()).collect();
        want.sort();
        assert_eq!(ids, want);
        assert!(shuffled(&[], 1).is_empty());
    }

    #[test]
    fn window_sizes_match_the_spec() {
        assert_eq!((WINDOW_DEFAULT.width, WINDOW_DEFAULT.height), (1440.0, 900.0));
        assert_eq!((WINDOW_MIN.width, WINDOW_MIN.height), (960.0, 600.0));
    }

    #[test]
    fn animations_stay_under_half_a_second() {
        // The calm redesign trades the old 180 ms snap for slow, soft motion (still under half a second).
        assert!(theme::MAX_ANIMATION_MS < 500);
        assert!(art::FADE.as_millis() as u64 <= theme::MAX_ANIMATION_MS);
    }

    #[test]
    fn lyrics_is_not_in_the_sidebar() {
        assert!(!NavPage::all().contains(&NavPage::Lyrics));
    }
}
