//! The left panel of the Player panel layout: the whole player, on the frame surface, about 190 px
//! wide. There is no bottom bar in this layout.
//!
//! Top to bottom: the account circle (left) and the full-screen button (right, plain and muted,
//! as quiet as the volume icon), a large rounded cover, title and artist with a like button, the
//! progress bar with the times under it, the transport, and a last row with volume (wide windows
//! only) and the queue button. The queue button opens the full queue as a drawer.
//!
//! No fill, border, shadow or glow: the frame draws the surface. Accent colour is only on the play
//! button and the progress fill, as everywhere else; shuffle, repeat, like and queue "on" are text
//! colour.
//!
//! The cover is the one part that gives way when the window is short: `cover_size` shrinks it
//! (down to `MIN_COVER`) before anything else changes. The mini visualizer's strip (150 x 26 px,
//! no label) is centred above the progress bar, in the room the title leaves; when it is drawn
//! the cover has to make room for it too.

use crate::icons::{icon, Icon};
use crate::theme::{self, format_duration, space, HalcyonPalette};
use crate::views::account::AVATAR_SIZE;
use crate::views::titlebar;
use crate::viz::BANDS;
use crate::visualizer::MiniPlacement;
use halcyon_music_core::art::ArtSize;
use halcyon_music_core::state::{PlayerState, RepeatMode};
use iced::widget::{button, column, container, row, slider, text, tooltip, Space};
use iced::{Alignment, Element, Length, Padding};

/// Width of the panel.
pub const WIDTH: f32 = 190.0;
/// Space left and right of the content (the account circle is this far from the window's left edge).
pub const PAD: f32 = 12.0;
/// The cover is never wider than the panel's content.
pub const MAX_COVER: f32 = WIDTH - 2.0 * PAD;
/// The cover never shrinks below this, however short the window is.
pub const MIN_COVER: f32 = 72.0;

const ICON_BTN: f32 = 26.0;
const PLAY_PX: f32 = 36.0;
const TITLE_CHARS: usize = 17;
const ARTIST_CHARS: usize = 20;

// Heights of everything that is not the cover, so the cover can take what is left.
const TOP_ROW_H: f32 = AVATAR_SIZE;
const META_H: f32 = 40.0;
const PROGRESS_H: f32 = 34.0;
const TRANSPORT_H: f32 = PLAY_PX;
const BOTTOM_ROW_H: f32 = ICON_BTN + 2.0;
const GAP: f32 = 10.0;
/// Five gaps: under the top row, the cover, the title, the progress bar and the transport.
const GAPS: f32 = 5.0 * GAP;
const PAD_TOP: f32 = space::SM;
const PAD_BOTTOM: f32 = space::MD;

/// Height of everything in the panel except the cover.
pub const FIXED_HEIGHT: f32 =
    TOP_ROW_H + META_H + PROGRESS_H + TRANSPORT_H + BOTTOM_ROW_H + GAPS + PAD_TOP + PAD_BOTTOM;

/// Height of the mini visualizer's strip plus the gap under it; the cover gives this up first.
pub fn mini_height() -> f32 {
    MiniPlacement::Panel.size().1 + GAP
}

/// Width of the transport (five buttons and their gaps); it has to fit the panel's content.
pub const TRANSPORT_W: f32 = 4.0 * ICON_BTN + PLAY_PX + 4.0 * 4.0;

/// Edge of the cover for a window of this height: what is left under the title bar after the
/// controls (and the mini visualizer's strip when `mini` is true), kept between `MIN_COVER` and
/// `MAX_COVER`. Pure, so the 960x600 rule is tested.
pub fn cover_size(window_height: f32, mini: bool) -> f32 {
    if !window_height.is_finite() {
        return MAX_COVER;
    }
    let available = window_height - titlebar::HEIGHT;
    let strip = if mini { mini_height() } else { 0.0 };
    (available - FIXED_HEIGHT - strip).clamp(MIN_COVER, MAX_COVER)
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

/// The large cover: the picture, or the calm tint with a note when there is none.
fn cover<'a, M: Clone + 'a>(
    state: &PlayerState,
    px: f32,
    palette: HalcyonPalette,
    on_press: M,
) -> Element<'a, M> {
    let track = state.track.as_ref();
    let has_art = track.and_then(|t| t.art_url.as_deref()).is_some_and(|u| !u.is_empty());
    let face: Element<'a, M> = if has_art {
        crate::art::cover(
            track.and_then(|t| t.art_url.as_deref()),
            if px > 100.0 { ArtSize::Medium } else { ArtSize::Small },
            px,
            theme::radius::COVER,
            Icon::Music,
            track.map(|t| t.title.as_str()).unwrap_or(""),
            palette,
        )
    } else {
        let tint = palette.dim_tint();
        container(icon(Icon::Music, px * 0.34, palette.text))
            .width(px)
            .height(px)
            .center_x(px)
            .center_y(px)
            .style(move |_t| container::Style {
                background: Some(tint.into()),
                border: iced::Border { radius: theme::radius::COVER.into(), ..Default::default() },
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

/// The panel. `account` is the account circle (or a blank of the same size).
#[allow(clippy::too_many_arguments)]
pub fn view<'a, M: Clone + 'static>(
    state: &'a PlayerState,
    window_height: f32,
    show_volume: bool,
    mini: Option<[f32; BANDS]>,
    queue_open: bool,
    liked: bool,
    palette: HalcyonPalette,
    account: Element<'a, M>,
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
    on_toggle_like: M,
) -> Element<'a, M> {
    let track = state.track.as_ref();
    let title = track.map(|t| t.title.as_str()).unwrap_or("No track playing");
    let artist = track.map(|t| t.artist.as_str()).unwrap_or("Halcyon");
    let duration_ms = track.map(|t| t.duration_ms).unwrap_or(0);
    let position_ms = state.position_ms.min(duration_ms);
    let on_colour = |on: bool| if on { palette.text } else { palette.text_muted };

    // --- Top: account circle, full-screen button (plain and muted, like the volume icon) ---
    let top = row![
        account,
        Space::with_width(Length::Fill),
        plain_button(Icon::Maximize, 16.0, palette.text_muted, palette, on_toggle_fullscreen.clone()),
    ]
    .align_y(Alignment::Center)
    .height(TOP_ROW_H);

    // --- The cover (it shrinks first when the window is short) ---
    let cover_px = cover_size(window_height, mini.is_some());
    let cover = container(cover(state, cover_px, palette, on_toggle_fullscreen))
        .width(Length::Fill)
        .center_x(Length::Fill);

    // --- Title and artist, with the like button ---
    let meta = column![
        text(crate::views::ellipsize(title, TITLE_CHARS)).size(14).color(palette.text),
        text(crate::views::ellipsize(artist, ARTIST_CHARS)).size(12).color(palette.text_muted),
    ]
    .spacing(2)
    .width(Length::Fill);
    let like = button(if liked {
        icon(Icon::HeartFilled, 16.0, palette.text)
    } else {
        icon(Icon::Heart, 16.0, palette.text_muted)
    })
    .on_press_maybe(track.map(|_| on_toggle_like))
    .padding(4)
    .style(crate::views::ghost(palette));
    let song = row![meta, like].align_y(Alignment::Center).height(META_H);

    // --- Progress, with the times under it ---
    let dur = (duration_ms as u32).max(1);
    let pos = (position_ms as u32).min(dur);
    let seek = slider(0..=dur, pos, move |v| on_seek(v as u64))
        .width(Length::Fill)
        .step(1000u32)
        .style(crate::views::slider_style(palette));
    let progress = column![
        seek,
        row![
            text(format_duration(position_ms)).size(10).color(palette.text_muted),
            Space::with_width(Length::Fill),
            text(format_duration(duration_ms)).size(10).color(palette.text_muted),
        ],
    ]
    .spacing(2)
    .height(PROGRESS_H);

    // --- Transport: the same buttons as the dock, play is the only accent ---
    let shuffle = plain_button(Icon::Shuffle, 15.0, on_colour(state.shuffle), palette, on_toggle_shuffle);
    let prev = plain_button(Icon::SkipBack, 16.0, palette.text, palette, on_prev);
    let next = plain_button(Icon::SkipForward, 16.0, palette.text, palette, on_next);
    let (repeat_icon, repeat_on) = match state.repeat {
        RepeatMode::Off => (Icon::Repeat, false),
        RepeatMode::All => (Icon::Repeat, true),
        RepeatMode::One => (Icon::Repeat1, true),
    };
    let repeat = plain_button(repeat_icon, 15.0, on_colour(repeat_on), palette, on_cycle_repeat);
    let play_icon = if state.playing { Icon::Pause } else { Icon::Play };
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
        border: iced::Border { radius: (PLAY_PX / 2.0).into(), ..Default::default() },
        // Calm: no glow and no shadow.
        shadow: iced::Shadow::default(),
    });
    let transport = container(row![shuffle, prev, play, next, repeat].spacing(4).align_y(Alignment::Center))
        .width(Length::Fill)
        .center_x(Length::Fill)
        .height(TRANSPORT_H);

    // --- Last row: volume (wide windows only) and the queue button ---
    let mut bottom = row![].spacing(4).align_y(Alignment::Center).height(BOTTOM_ROW_H);
    if show_volume {
        let vol_icon = if state.volume == 0 {
            Icon::VolumeX
        } else if state.volume < 50 {
            Icon::Volume1
        } else {
            Icon::Volume2
        };
        bottom = bottom
            .push(plain_button(vol_icon, 16.0, palette.text_muted, palette, on_toggle_mute))
            .push(
                slider(0..=100, state.volume, on_volume)
                    .width(Length::Fill)
                    .style(crate::views::slider_style(palette)),
            );
    } else {
        bottom = bottom.push(Space::with_width(Length::Fill));
    }
    bottom = bottom.push(tooltip(
        plain_button(Icon::Queue, 16.0, on_colour(queue_open), palette, on_toggle_queue),
        titlebar::tip("Queue", palette),
        tooltip::Position::Top,
    ));

    // The mini visualizer's strip: centred, just above the progress bar. Nothing at all when off.
    let strip: Element<'a, M> = match mini {
        Some(bands) => {
            let (_, h) = MiniPlacement::Panel.size();
            // The strip on top, then the gap above the progress bar.
            container(crate::views::viz_canvas::mini(MiniPlacement::Panel, bands, palette.accent))
                .width(Length::Fill)
                .height(h + GAP)
                .center_x(Length::Fill)
                .align_y(iced::alignment::Vertical::Top)
                .into()
        }
        None => Space::with_height(0).into(),
    };

    container(
        column![
            top,
            Space::with_height(GAP),
            cover,
            Space::with_height(GAP),
            song,
            // Whatever height is left goes here, so the controls stay at the foot of the panel.
            Space::with_height(Length::Fill),
            strip,
            progress,
            Space::with_height(GAP),
            transport,
            Space::with_height(GAP),
            bottom,
        ]
        .width(Length::Fill),
    )
    .width(WIDTH)
    .height(Length::Fill)
    .padding(Padding { top: PAD_TOP, right: PAD, bottom: PAD_BOTTOM, left: PAD })
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use halcyon_music_core::Track;

    #[allow(clippy::type_complexity)]
    fn build<'a>(
        state: &'a PlayerState,
        window_height: f32,
        show_volume: bool,
        queue_open: bool,
        liked: bool,
    ) -> Element<'a, ()> {
        build_with(state, window_height, show_volume, queue_open, liked, None)
    }

    #[allow(clippy::type_complexity)]
    fn build_with<'a>(
        state: &'a PlayerState,
        window_height: f32,
        show_volume: bool,
        queue_open: bool,
        liked: bool,
        mini: Option<[f32; BANDS]>,
    ) -> Element<'a, ()> {
        let palette = HalcyonPalette::for_mood(theme::Mood::Dusk);
        view(
            state,
            window_height,
            show_volume,
            mini,
            queue_open,
            liked,
            palette,
            Space::new(32, 32).into(),
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
            (),
        )
    }

    #[test]
    fn the_cover_is_as_wide_as_the_content_at_960_by_600() {
        // 960x600 is the smallest window: the controls fit and the cover keeps its full size.
        let cover = cover_size(600.0, false);
        assert_eq!(cover, MAX_COVER);
        assert!(titlebar::HEIGHT + FIXED_HEIGHT + cover <= 600.0, "the panel is taller than the window");
    }

    #[test]
    fn the_strip_fits_at_960_by_600_without_shrinking_the_cover() {
        // The mini visualizer is 150 wide, the cover 166: the strip fits the panel's content,
        // and at the smallest window there is height enough for both.
        let strip = MiniPlacement::Panel.size();
        assert!(strip.0 <= MAX_COVER, "the strip is wider than the panel's content");
        let cover = cover_size(600.0, true);
        assert_eq!(cover, MAX_COVER, "the cover must not shrink at 960x600");
        assert!(
            titlebar::HEIGHT + FIXED_HEIGHT + mini_height() + cover <= 600.0,
            "panel plus strip is taller than the window"
        );
    }

    #[test]
    fn with_the_strip_the_cover_gives_up_exactly_its_height_and_never_goes_below_the_minimum() {
        // Short enough that the cover is shrinking: it is smaller by the strip's height.
        let without = cover_size(420.0, false);
        let with = cover_size(420.0, true);
        assert!(without > MIN_COVER && with >= MIN_COVER);
        assert!((without - with - mini_height()).abs() < 0.001 || with == MIN_COVER);
        for h in [600.0, 480.0, 400.0, 300.0, 0.0, f32::NAN, f32::INFINITY] {
            let c = cover_size(h, true);
            assert!(c.is_finite() && (MIN_COVER..=MAX_COVER).contains(&c), "{h}: {c}");
            assert!(c <= cover_size(h, false) + 0.001 || !h.is_finite());
        }
    }

    #[test]
    fn the_cover_shrinks_first_when_the_window_is_short_and_never_below_the_minimum() {
        let mut last = f32::MAX;
        for h in [600.0, 520.0, 480.0, 440.0, 400.0, 360.0, 300.0, 100.0, 0.0] {
            let c = cover_size(h, false);
            assert!(c <= last + 0.001, "{h}: {c} grew");
            assert!((MIN_COVER..=MAX_COVER).contains(&c), "{h}: {c}");
            last = c;
        }
        assert_eq!(cover_size(0.0, false), MIN_COVER);
        assert!(cover_size(440.0, false) < MAX_COVER, "a short window should have shrunk the cover");
        // Taller than needed: the cover stops at the width of the panel's content.
        assert_eq!(cover_size(2000.0, false), MAX_COVER);
    }

    #[test]
    fn the_cover_size_is_never_nan() {
        assert!(cover_size(f32::NAN, false).is_finite());
        assert!(cover_size(f32::INFINITY, false).is_finite());
        assert!(cover_size(f32::NEG_INFINITY, false).is_finite());
    }

    #[test]
    fn the_transport_fits_the_panel() {
        assert!(TRANSPORT_W <= WIDTH - 2.0 * PAD, "{TRANSPORT_W} does not fit");
    }

    #[test]
    fn the_account_circle_row_matches_the_menu_position_inputs() {
        // `frame::account_menu_place` opens the menu under the circle: it relies on these two.
        assert_eq!(PAD_TOP, space::SM);
        assert_eq!(TOP_ROW_H, AVATAR_SIZE);
    }

    #[test]
    fn the_panel_builds_with_the_mini_visualizer_at_every_height() {
        let state = PlayerState { playing: true, ..PlayerState::default() };
        for mini in [None, Some([0.0; BANDS]), Some([1.0; BANDS])] {
            for height in [0.0, 400.0, 600.0, 1440.0] {
                for volume in [false, true] {
                    let _: Element<'_, ()> = build_with(&state, height, volume, false, false, mini);
                }
            }
        }
    }

    #[test]
    fn the_panel_builds_with_no_track_paused_and_with_everything_on() {
        let none = PlayerState::default();
        for volume in [false, true] {
            let _: Element<'_, ()> = build(&none, 600.0, volume, false, false);
        }
        let state = PlayerState {
            track: Some(Track::simple(
                "t".into(),
                "A very long song title that must be cut".into(),
                "An artist with a long name too".into(),
                "Album".into(),
                200_000,
            )),
            position_ms: 500_000, // past the end: clamped, not a panic
            playing: true,
            shuffle: true,
            repeat: RepeatMode::One,
            ..PlayerState::default()
        };
        for height in [0.0, 400.0, 600.0, 1440.0] {
            let _: Element<'_, ()> = build(&state, height, true, true, true);
            let _: Element<'_, ()> = build(&state, height, false, false, false);
        }
    }
}
