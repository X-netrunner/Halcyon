//! The floating dock of the Dock layout: one centred pill at the bottom of the window.
//!
//! Left to right: the account circle, Home / Library / Discover (the page you are on sits in a
//! small rounded square), a divider, the round cover with title and artist, the transport, a short
//! progress bar, a divider, volume (wide windows only), the queue button and the full-screen
//! button. The pill is one slightly lighter step of the frame colour: no border, no shadow, no
//! glow. Accent colour is only on the play button and the progress fill, as everywhere else.
//!
//! The pill has a width worked out from the window (`width_for`), so the account menu can open
//! above the circle without knowing how wide the content turned out.

use crate::icons::{icon, Icon};
use crate::theme::{self, format_duration, HalcyonPalette};
use crate::views::sidebar::NavPage;
use crate::views::tabs::Tab;
use crate::visualizer::MiniPlacement;
use crate::viz::BANDS;
use halcyon_music_core::state::{PlayerState, RepeatMode};
use iced::widget::{button, container, row, slider, text, tooltip, Space};
use iced::{Alignment, Element, Length, Padding};

/// Height of the pill.
pub const HEIGHT: f32 = 56.0;
/// Height of the strip the pill floats in: the pill plus air above and below it.
pub const STRIP_HEIGHT: f32 = 76.0;
/// Air under the pill (the rest of the strip is above it).
pub const BOTTOM_GAP: f32 = 12.0;
/// The pill never grows wider than this, however wide the window is.
pub const MAX_WIDTH: f32 = 1000.0;
/// Air between the pill and the window's left and right edges.
pub const SIDE_GAP: f32 = 24.0;
/// Space inside the pill, left of the account circle and right of the last button.
pub const PAD: f32 = 12.0;

const COVER_PX: f32 = 36.0;
const NAV_BOX: f32 = 32.0;
const NAV_RADIUS: f32 = 10.0;
const ICON_BTN: f32 = 28.0;
const PLAY_PX: f32 = 36.0;
const DIVIDER_H: f32 = 22.0;
const VOLUME_SLIDER_W: f32 = 72.0;
/// The progress bar never gets longer than this; "short" is the point.
const PROGRESS_MAX_W: f32 = 220.0;
const TITLE_CHARS: usize = 24;
/// With the mini visualizer beside the song the title is cut sooner.
const TITLE_CHARS_WITH_MINI: usize = 18;
/// Air between the song's text and the mini visualizer.
const MINI_GAP: f32 = 8.0;

/// Width of the pill for a window of this width.
pub fn width_for(window_width: f32) -> f32 {
    (window_width - 2.0 * SIDE_GAP).clamp(0.0, MAX_WIDTH)
}

/// Where the left edge of the account circle is, from the window's left edge.
pub fn account_left(window_width: f32) -> f32 {
    (window_width - width_for(window_width)) / 2.0 + PAD
}

/// Width of everything in the pill that does not stretch (volume hidden): the padding, the
/// account circle, the three page buttons, the transport, the queue and full-screen buttons, the
/// two dividers and the gaps between the groups. The two stretching parts (the song and the
/// progress bar) share what is left; the tests check each keeps at least `MIN_STRETCH` at the
/// smallest window.
#[cfg(test)]
pub const FIXED_WIDTH: f32 = 2.0 * PAD
    + (36.0 + 8.0 + 3.0 * NAV_BOX + 2.0 * 4.0) // account circle, gap, three pages
    + 2.0 * (10.0 + 1.0 + 10.0) // each divider with its gaps
    + 8.0 // before the transport
    + (4.0 * ICON_BTN + PLAY_PX + 4.0 * 4.0) // transport
    + 12.0 // before the progress bar
    + (2.0 * ICON_BTN + 4.0); // queue and full screen
#[cfg(test)]
pub const MIN_STRETCH: f32 = 140.0;

fn divider<'a, M: 'a>(palette: HalcyonPalette) -> Element<'a, M> {
    container(Space::new(1, DIVIDER_H))
        .style(move |_t| container::Style {
            background: Some(theme::alpha(palette.text, 0.12).into()),
            ..Default::default()
        })
        .into()
}

fn nav_icon(tab: Tab) -> Icon {
    match tab {
        Tab::Home => Icon::Home,
        Tab::Library => Icon::Library,
        Tab::Discover => Icon::Sparkles,
    }
}

fn nav_button<'a, M: Clone + 'a>(
    tab: Tab,
    lit: bool,
    palette: HalcyonPalette,
    msg: M,
) -> Element<'a, M> {
    let colour = if lit {
        palette.text
    } else {
        palette.text_muted
    };
    let b = button(
        container(icon(nav_icon(tab), 16.0, colour))
            .width(NAV_BOX)
            .height(NAV_BOX)
            .center_x(NAV_BOX)
            .center_y(NAV_BOX),
    )
    .on_press(msg)
    .padding(0)
    .style(move |_t, status| button::Style {
        background: if lit {
            Some(theme::alpha(palette.text, 0.10).into())
        } else if matches!(status, button::Status::Hovered | button::Status::Pressed) {
            Some(theme::alpha(palette.text, 0.06).into())
        } else {
            None
        },
        text_color: colour,
        border: iced::Border {
            radius: NAV_RADIUS.into(),
            ..Default::default()
        },
        ..Default::default()
    });
    // The buttons have no visible name, so the name is the tooltip.
    tooltip(
        b,
        crate::views::titlebar::tip(tab.label(), palette),
        tooltip::Position::Top,
    )
    .into()
}

fn plain_button<'a, M: Clone + 'a>(
    glyph: Icon,
    size: f32,
    colour: iced::Color,
    palette: HalcyonPalette,
    msg: M,
) -> iced::widget::Button<'a, M> {
    button(
        container(icon(glyph, size, colour))
            .width(ICON_BTN)
            .height(ICON_BTN)
            .center_x(ICON_BTN)
            .center_y(ICON_BTN),
    )
    .on_press(msg)
    .padding(0)
    .style(crate::views::ghost(palette))
}

/// The round cover: the picture, or the calm tint with a note when there is none.
fn cover<'a, M: Clone + 'a>(
    state: &PlayerState,
    palette: HalcyonPalette,
    on_press: M,
) -> Element<'a, M> {
    let track = state.track.as_ref();
    let has_art = track
        .and_then(|t| t.art_url.as_deref())
        .is_some_and(|u| !u.is_empty());
    let face: Element<'a, M> = if has_art {
        crate::art::cover(
            track.and_then(|t| t.art_url.as_deref()),
            halcyon_music_core::art::ArtSize::Small,
            COVER_PX,
            COVER_PX / 2.0,
            Icon::Music,
            track.map(|t| t.title.as_str()).unwrap_or(""),
            palette,
        )
    } else {
        let tint = palette.dim_tint();
        container(icon(Icon::Music, COVER_PX * 0.42, palette.text))
            .width(COVER_PX)
            .height(COVER_PX)
            .center_x(COVER_PX)
            .center_y(COVER_PX)
            .style(move |_t| container::Style {
                background: Some(tint.into()),
                border: iced::Border {
                    radius: (COVER_PX / 2.0).into(),
                    ..Default::default()
                },
                ..Default::default()
            })
            .into()
    };
    button(face)
        .on_press(on_press)
        .padding(0)
        .style(|_t, _s| button::Style::default())
        .into()
}

/// The pill, in its strip. `account` is the account circle (or a blank of the same size).
#[allow(clippy::too_many_arguments)]
pub fn view<'a, M: Clone + 'static>(
    state: &'a PlayerState,
    active: NavPage,
    window_width: f32,
    show_volume: bool,
    mini: Option<[f32; BANDS]>,
    queue_open: bool,
    palette: HalcyonPalette,
    account: Element<'a, M>,
    on_select: impl Fn(NavPage) -> M + 'a,
    on_toggle_play: M,
    on_next: M,
    on_prev: M,
    on_seek: impl Fn(u64) -> M + 'a,
    on_volume: impl Fn(u8) -> M + 'a,
    on_toggle_mute: M,
    on_toggle_shuffle: M,
    on_cycle_repeat: M,
    on_toggle_queue: M,
    on_toggle_fullscreen: M,
) -> Element<'a, M> {
    let track = state.track.as_ref();
    let title = track
        .map(|t| t.title.as_str())
        .unwrap_or("No track playing");
    let artist = track.map(|t| t.artist.as_str()).unwrap_or("Halcyon");
    let duration_ms = track.map(|t| t.duration_ms).unwrap_or(0);
    let position_ms = state.position_ms.min(duration_ms);

    // --- Left: account, the three pages ---
    let lit = Tab::for_page(active);
    let mut nav = row![].spacing(4).align_y(Alignment::Center);
    for tab in Tab::ALL {
        nav = nav.push(nav_button(
            tab,
            lit == Some(tab),
            palette,
            on_select(tab.page()),
        ));
    }
    let left = row![account, Space::with_width(8), nav].align_y(Alignment::Center);

    // --- The song ---
    let title_chars = if mini.is_some() {
        TITLE_CHARS_WITH_MINI
    } else {
        TITLE_CHARS
    };
    let meta = iced::widget::column![
        text(crate::views::ellipsize(title, title_chars))
            .size(13)
            .color(palette.text),
        text(crate::views::ellipsize(artist, title_chars))
            .size(11)
            .color(palette.text_muted),
    ]
    .spacing(1);
    let mut song = row![
        cover(state, palette, on_toggle_fullscreen.clone()),
        Space::with_width(10),
        meta
    ]
    .align_y(Alignment::Center);
    // The mini visualizer sits between the song and the transport (no label).
    if let Some(bands) = mini {
        song = song
            .push(Space::with_width(MINI_GAP))
            .push(crate::views::viz_canvas::mini(
                MiniPlacement::Dock,
                bands,
                palette.accent,
            ));
    }
    let song = song.width(Length::FillPortion(1));

    // --- Transport ---
    let on_colour = |on: bool| if on { palette.text } else { palette.text_muted };
    let shuffle = plain_button(
        Icon::Shuffle,
        15.0,
        on_colour(state.shuffle),
        palette,
        on_toggle_shuffle,
    );
    let prev = plain_button(Icon::SkipBack, 16.0, palette.text, palette, on_prev);
    let next = plain_button(Icon::SkipForward, 16.0, palette.text, palette, on_next);
    let (repeat_icon, repeat_on) = match state.repeat {
        RepeatMode::Off => (Icon::Repeat, false),
        RepeatMode::All => (Icon::Repeat, true),
        RepeatMode::One => (Icon::Repeat1, true),
    };
    let repeat = plain_button(
        repeat_icon,
        15.0,
        on_colour(repeat_on),
        palette,
        on_cycle_repeat,
    );
    let play_icon = if state.playing {
        Icon::Pause
    } else {
        Icon::Play
    };
    let play = button(
        container(icon(play_icon, 18.0, palette.on_accent()))
            .width(PLAY_PX)
            .height(PLAY_PX)
            .center_x(PLAY_PX)
            .center_y(PLAY_PX),
    )
    .on_press(on_toggle_play)
    .padding(0)
    .style(move |_t, _status| button::Style {
        background: Some(palette.accent_background()),
        text_color: palette.on_accent(),
        border: iced::Border {
            radius: (PLAY_PX / 2.0).into(),
            ..Default::default()
        },
        // Calm: no glow and no shadow.
        shadow: iced::Shadow::default(),
    });
    let transport = row![shuffle, prev, play, next, repeat]
        .spacing(4)
        .align_y(Alignment::Center);

    // --- Progress ---
    let dur = (duration_ms as u32).max(1);
    let pos = (position_ms as u32).min(dur);
    let seek = slider(0..=dur, pos, move |v| on_seek(v as u64))
        .width(Length::Fill)
        .step(1000u32)
        .style(crate::views::slider_style(palette));
    let progress = container(
        row![
            text(format_duration(position_ms))
                .size(10)
                .color(palette.text_muted),
            Space::with_width(8),
            seek,
            Space::with_width(8),
            text(format_duration(duration_ms))
                .size(10)
                .color(palette.text_muted),
        ]
        .align_y(Alignment::Center),
    )
    .max_width(PROGRESS_MAX_W)
    .width(Length::FillPortion(1));

    // --- Right: volume (wide windows), queue, full screen ---
    let mut right = row![].spacing(4).align_y(Alignment::Center);
    if show_volume {
        let vol_icon = if state.volume == 0 {
            Icon::VolumeX
        } else if state.volume < 50 {
            Icon::Volume1
        } else {
            Icon::Volume2
        };
        right = right
            .push(plain_button(
                vol_icon,
                16.0,
                palette.text_muted,
                palette,
                on_toggle_mute,
            ))
            .push(
                slider(0..=100, state.volume, on_volume)
                    .width(VOLUME_SLIDER_W)
                    .style(crate::views::slider_style(palette)),
            )
            .push(Space::with_width(8));
    }
    right = right
        .push(tooltip(
            plain_button(
                Icon::Queue,
                16.0,
                on_colour(queue_open),
                palette,
                on_toggle_queue,
            ),
            crate::views::titlebar::tip("Queue", palette),
            tooltip::Position::Top,
        ))
        .push(plain_button(
            Icon::Maximize,
            16.0,
            palette.text_muted,
            palette,
            on_toggle_fullscreen,
        ));

    // The pill: one step lighter than the frame under it. No border, no shadow.
    let fill = theme::mix(palette.chrome_at(1.0), palette.text, 0.07);
    let pill = container(
        row![
            left,
            Space::with_width(10),
            divider(palette),
            Space::with_width(10),
            song,
            Space::with_width(8),
            transport,
            Space::with_width(12),
            progress,
            Space::with_width(10),
            divider(palette),
            Space::with_width(10),
            right,
        ]
        .align_y(Alignment::Center),
    )
    .width(width_for(window_width))
    .height(HEIGHT)
    .padding(Padding {
        top: 0.0,
        right: PAD,
        bottom: 0.0,
        left: PAD,
    })
    .align_y(iced::alignment::Vertical::Center)
    .style(move |_t| container::Style {
        background: Some(fill.into()),
        border: iced::Border {
            radius: theme::radius::PILL.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    container(pill)
        .width(Length::Fill)
        .height(STRIP_HEIGHT)
        .center_x(Length::Fill)
        .padding(Padding {
            top: STRIP_HEIGHT - HEIGHT - BOTTOM_GAP,
            right: 0.0,
            bottom: BOTTOM_GAP,
            left: 0.0,
        })
        .into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use halcyon_music_core::Track;

    #[allow(clippy::type_complexity)]
    fn build<'a>(
        state: &'a PlayerState,
        active: NavPage,
        window_width: f32,
        show_volume: bool,
        queue_open: bool,
    ) -> Element<'a, ()> {
        build_with(state, active, window_width, show_volume, queue_open, None)
    }

    #[allow(clippy::type_complexity)]
    fn build_with<'a>(
        state: &'a PlayerState,
        active: NavPage,
        window_width: f32,
        show_volume: bool,
        queue_open: bool,
        mini: Option<[f32; BANDS]>,
    ) -> Element<'a, ()> {
        let palette = HalcyonPalette::for_mood(theme::Mood::Dusk);
        view(
            state,
            active,
            window_width,
            show_volume,
            mini,
            queue_open,
            palette,
            Space::new(36, 36).into(),
            |_| (),
            (),
            (),
            (),
            |_| (),
            |_| (),
            (),
            (),
            (),
            (),
            (),
        )
    }

    #[test]
    fn the_pill_is_the_window_minus_its_side_gaps_and_never_wider_than_the_maximum() {
        assert_eq!(width_for(960.0), 960.0 - 2.0 * SIDE_GAP);
        assert_eq!(width_for(1100.0), MAX_WIDTH);
        assert_eq!(width_for(3000.0), MAX_WIDTH);
        assert_eq!(width_for(10.0), 0.0);
        assert_eq!(width_for(0.0), 0.0);
    }

    #[test]
    fn the_account_circle_sits_inside_the_pill() {
        for w in [960.0, 1100.0, 1500.0, 2560.0] {
            let left = account_left(w);
            assert!(left >= SIDE_GAP.min(w) - 0.001, "{w}: {left}");
            assert!((left - ((w - width_for(w)) / 2.0 + PAD)).abs() < 0.001);
        }
        // Wider than the maximum: the pill stays centred, so the circle moves with it.
        assert!(account_left(2000.0) > account_left(1100.0));
    }

    #[test]
    fn the_two_stretching_parts_keep_room_at_the_smallest_window() {
        // 960 px wide, no volume (it is hidden below 1100): song and progress share the rest.
        let rest = width_for(960.0) - FIXED_WIDTH;
        assert!(
            rest / 2.0 >= MIN_STRETCH,
            "each stretching part would get {}",
            rest / 2.0
        );
    }

    #[test]
    fn the_song_keeps_room_with_the_mini_visualizer_at_the_narrowest_width_that_shows_it() {
        // The strip is hidden below 1000 px, so 1000 px is the tightest case (no volume yet).
        use crate::visualizer::{mini_shown, MiniPlacement, MINI_HIDE_BELOW_WIDTH};
        assert!(mini_shown(
            Some(MiniPlacement::Dock),
            MINI_HIDE_BELOW_WIDTH,
            true,
            false
        ));
        let rest = width_for(MINI_HIDE_BELOW_WIDTH) - FIXED_WIDTH;
        let (mini_w, _) = MiniPlacement::Dock.size();
        // The song part shares `rest` with the progress bar, and also holds the strip.
        let song_text = rest / 2.0 - COVER_PX - 10.0 - MINI_GAP - mini_w;
        assert!(
            song_text >= 100.0,
            "only {song_text} px left for the title and artist"
        );
        // The progress bar keeps its minimum.
        assert!(rest / 2.0 >= MIN_STRETCH);
    }

    #[test]
    fn the_dock_builds_with_the_mini_visualizer_on_and_off() {
        let state = PlayerState {
            playing: true,
            ..Default::default()
        };
        for mini in [None, Some([0.0; BANDS]), Some([1.0; BANDS])] {
            for width in [1000.0, 1100.0, 1920.0] {
                let _: Element<'_, ()> =
                    build_with(&state, NavPage::Home, width, width >= 1100.0, false, mini);
            }
        }
    }

    #[test]
    fn every_tab_has_its_own_icon() {
        let icons: Vec<Icon> = Tab::ALL.iter().map(|t| nav_icon(*t)).collect();
        assert_eq!(icons, [Icon::Home, Icon::Library, Icon::Sparkles]);
    }

    #[test]
    fn the_dock_builds_with_no_track_playing_paused_and_with_everything_on() {
        let none = PlayerState::default();
        let _: Element<'_, ()> = build(&none, NavPage::Home, 960.0, false, false);
        let mut state = PlayerState {
            track: Some(Track::simple(
                "t".into(),
                "A very long song title that must be cut".into(),
                "Artist".into(),
                "Album".into(),
                200_000,
            )),
            position_ms: 500_000, // past the end: clamped, not a panic
            playing: true,
            shuffle: true,
            repeat: RepeatMode::One,
            volume: 0,
            ..Default::default()
        };
        let _: Element<'_, ()> = build(&state, NavPage::Library, 1100.0, true, true);
        state.playing = false;
        state.volume = 80;
        let _: Element<'_, ()> = build(&state, NavPage::Lyrics, 960.0, false, false);
    }

    #[test]
    fn the_dock_builds_for_every_page() {
        let state = PlayerState::default();
        for page in [
            NavPage::Home,
            NavPage::Library,
            NavPage::Settings,
            NavPage::Search,
            NavPage::Discover,
            NavPage::Recent,
            NavPage::Liked,
            NavPage::PlaylistDetail,
            NavPage::Lyrics,
            NavPage::Capsule,
        ] {
            let _: Element<'_, ()> = build(&state, page, 1280.0, true, false);
        }
    }
}
