//! Full-screen Now Playing: the song, the visualizer and the lyrics, and nothing else.
//!
//! No title bar, navigation, queue or player bar. A quiet, invisible strip along the top still
//! drags the window; the window buttons and an "Esc" hint show only while the pointer is near
//! it. The small transport (previous, play or pause, next, the time) sits at the bottom and
//! fades in when the pointer moves and out after a few seconds of stillness. The visualizer
//! (Aurora or Silk, drawn by `views::viz_canvas`) lies behind everything and only ever shows
//! the real spectrum.
//!
//! Lyrics follow a spotlight: the line being sung is large and bright, the lines around it
//! shrink and dim with distance, and when the next line starts the whole stack glides up into
//! place instead of jumping. Long songs stay cheap because only a dozen lines around the active
//! one are built.

use crate::animation::Easing;
use crate::icons::{icon, Icon};
use crate::layout::VisualizerKind;
use crate::theme::{self, format_duration, HalcyonPalette};
use crate::views::viz_canvas;
use crate::viz::BANDS;
use halcyon_music_core::models::{LyricLine, Lyrics};
use halcyon_music_core::state::PlayerState;
use iced::widget::{button, column, container, mouse_area, row, scrollable, stack, text, Space};
use iced::{Alignment, Element, Length};
use std::time::Duration;

/// Rough distance in pixels between two neighbouring lyric lines; the glide between lines
/// starts this far down and eases to zero.
const LINE_PITCH: f32 = 46.0;
/// How long the glide to the next line takes.
const GLIDE_MS: f32 = 420.0;

/// One lyric line. `focus` is the (fractional) index of the line in the spotlight: a line right
/// on it is large and bright, one step away is smaller and dimmer, and so on.
fn lyric_line<'a, Message: Clone + 'static>(
    line: &LyricLine,
    k: usize,
    focus: f32,
    palette: HalcyonPalette,
    on_seek: impl Fn(u64) -> Message + 'a,
) -> Element<'a, Message> {
    let dist = (k as f32 - focus).abs();
    let w = (1.0 - dist).clamp(0.0, 1.0);
    let size = 17.0 + 15.0 * w;
    let alpha = if w > 0.0 {
        0.30 + 0.70 * w
    } else {
        (0.30 - 0.06 * (dist - 1.0)).max(0.07)
    };
    // Far lines are muted, the one in the spotlight is the text colour warmed with the accent.
    let base = theme::mix(
        palette.text_muted,
        theme::mix(palette.text, palette.accent, 0.55),
        w,
    );
    let shown = if line.text.trim().is_empty() { "♪".to_string() } else { line.text.clone() };
    button(text(shown).size(size).color(theme::alpha(base, alpha)).width(Length::Fill))
        .on_press(on_seek(line.start_ms))
        .padding([2, 10])
        .width(Length::Fill)
        .style(|_t, _s| button::Style::default())
        .into()
}

/// The spotlight stack for synced lyrics.
fn spotlight<'a, Message: Clone + 'static>(
    lrc: &'a Lyrics,
    position_ms: u64,
    palette: HalcyonPalette,
    on_seek: impl Fn(u64) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let lines = &lrc.lines;
    let eff = (position_ms as i64).saturating_add(lrc.offset_ms).max(0) as u64;

    let mut active: Option<usize> = None;
    for (i, l) in lines.iter().enumerate() {
        if l.start_ms <= eff {
            active = Some(i);
        } else {
            break;
        }
    }

    // `focus`: which line the spotlight is on, moving smoothly from the previous line to the new
    // one for a moment after it starts. `shift`: how far down the stack still has to glide.
    let (center, focus, shift) = match active {
        Some(0) => (0usize, 0.0f32, 0.0f32),
        Some(i) => {
            let start = lines.get(i).map(|l| l.start_ms).unwrap_or(0);
            let t = (eff.saturating_sub(start) as f32 / GLIDE_MS).clamp(0.0, 1.0);
            let e = Easing::EaseOutCubic.apply(t);
            (i, (i as f32 - 1.0) + e, (1.0 - e) * LINE_PITCH)
        }
        None => (0usize, -0.6f32, 0.0f32),
    };

    let from = center.saturating_sub(6);
    let to = (center + 7).min(lines.len());

    let mut above = column![].spacing(16).width(Length::Fill);
    for (k, line) in lines.iter().enumerate().take(center).skip(from) {
        above = above.push(lyric_line(line, k, focus, palette, on_seek));
    }
    let Some(center_line) = lines.get(center) else {
        return Space::new(Length::Fill, Length::Fill).into();
    };
    let mid = lyric_line(center_line, center, focus, palette, on_seek);
    let mut below = column![].spacing(16).width(Length::Fill);
    for (k, line) in lines.iter().enumerate().take(to).skip(center + 1) {
        below = below.push(lyric_line(line, k, focus, palette, on_seek));
    }

    // Equal flexible space above and below keeps the spotlight line on the vertical middle
    // whatever its size; the spacer on top pushes everything down while a glide is under way.
    column![
        Space::with_height(shift * 2.0),
        container(above)
            .width(Length::Fill)
            .height(Length::Fill)
            .padding(iced::Padding { top: 0.0, right: 0.0, bottom: 16.0, left: 0.0 })
            .align_y(iced::alignment::Vertical::Bottom),
        mid,
        container(below)
            .width(Length::Fill)
            .height(Length::Fill)
            .padding(iced::Padding { top: 16.0, right: 0.0, bottom: 0.0, left: 0.0 })
            .align_y(iced::alignment::Vertical::Top),
    ]
    .width(Length::Fill)
    .height(Length::Fill)
    .into()
}

// ----- Controls that fade ------------------------------------------------------------------

/// The transport stays fully visible this long after the pointer last moved.
pub const CONTROLS_IDLE: Duration = Duration::from_secs(3);
/// Then it fades out over this long.
pub const CONTROLS_FADE: Duration = Duration::from_millis(400);
/// The pointer counts as "near the top" within this many pixels of the window's top edge.
pub const TOP_ZONE: f32 = 56.0;
/// Height of the invisible drag strip along the top: as tall as the window buttons it can show.
pub const DRAG_STRIP: f32 = crate::views::titlebar::CONTROLS_HEIGHT;
/// Height of the area the transport sits in at the bottom.
const TRANSPORT_AREA: f32 = 76.0;

/// 1.0 while the pointer has moved recently, then a fade to 0.0. With reduced motion there is no
/// fade: visible, then gone.
pub fn controls_alpha(since_move: Duration, reduce_motion: bool) -> f32 {
    if since_move <= CONTROLS_IDLE {
        return 1.0;
    }
    if reduce_motion {
        return 0.0;
    }
    let into_fade = (since_move - CONTROLS_IDLE).as_secs_f32();
    (1.0 - into_fade / CONTROLS_FADE.as_secs_f32()).clamp(0.0, 1.0)
}

/// True while the controls are visible or still fading: the screen must keep redrawing.
pub fn controls_changing(since_move: Duration) -> bool {
    since_move < CONTROLS_IDLE + CONTROLS_FADE
}

/// Whether the pointer is close enough to the top edge to show the window buttons.
pub fn near_top(cursor_y: f32) -> bool {
    cursor_y.is_finite() && (0.0..=TOP_ZONE).contains(&cursor_y)
}

/// A small icon button that fades with `alpha`. Fully faded it is not a button at all (an empty
/// space of the same size), so nothing invisible can be clicked.
fn fade_icon<'a, M: Clone + 'a>(glyph: Icon, size: f32, alpha: f32, pal: HalcyonPalette, msg: M) -> Element<'a, M> {
    let box_px = size + 20.0;
    if alpha <= 0.02 {
        return Space::new(box_px, box_px).into();
    }
    button(
        container(icon(glyph, size, theme::alpha(pal.text_muted, alpha)))
            .width(box_px)
            .height(box_px)
            .center_x(box_px)
            .center_y(box_px),
    )
    .padding(0)
    .on_press(msg)
    .style(move |_t, status| {
        let hot = matches!(status, button::Status::Hovered | button::Status::Pressed);
        button::Style {
            background: Some(
                if hot { theme::alpha(pal.text, 0.08 * alpha) } else { iced::Color::TRANSPARENT }.into(),
            ),
            border: iced::Border { radius: (box_px / 2.0).into(), ..Default::default() },
            ..Default::default()
        }
    })
    .into()
}

/// The round play or pause button, accent filled, fading with `alpha`.
fn fade_play<'a, M: Clone + 'a>(glyph: Icon, alpha: f32, pal: HalcyonPalette, msg: M) -> Element<'a, M> {
    const PX: f32 = 44.0;
    if alpha <= 0.02 {
        return Space::new(PX, PX).into();
    }
    button(
        container(icon(glyph, PX * 0.42, theme::alpha(pal.on_accent(), alpha)))
            .width(PX)
            .height(PX)
            .center_x(PX)
            .center_y(PX),
    )
    .padding(0)
    .on_press(msg)
    .style(move |_t, _status| button::Style {
        background: Some(theme::alpha(pal.accent, alpha).into()),
        border: iced::Border { radius: (PX / 2.0).into(), ..Default::default() },
        ..Default::default()
    })
    .into()
}

/// What the screen is told to draw this frame.
#[derive(Debug, Clone, Copy)]
pub struct Look {
    pub visualizer: VisualizerKind,
    /// The smoothed spectrum for the chosen visualizer (zeros = the resting shape).
    pub bands: [f32; BANDS],
    /// The animation clock in seconds; 0 when motion is reduced.
    pub clock: f32,
    /// 0.0 ..= 1.0, see [`controls_alpha`].
    pub controls_alpha: f32,
    /// The pointer is near the top edge: show the window buttons and the Esc hint.
    pub near_top: bool,
}

/// The messages the screen can send.
pub struct Actions<M> {
    pub toggle_play: M,
    pub next: M,
    pub previous: M,
    /// Leave full screen (Esc does the same): the plain icon at the end of the transport.
    pub exit: M,
    /// A press on the drag strip: move the window, or maximise on a double press.
    pub press_bar: M,
    pub minimize: M,
    pub toggle_maximize: M,
    pub close: M,
}

fn has_lyrics(lyrics: Option<&Lyrics>) -> bool {
    lyrics.is_some_and(|l| !l.lines.is_empty())
}

pub fn view<'a, Message: Clone + 'static>(
    state: &'a PlayerState,
    palette: &'a HalcyonPalette,
    lyrics: Option<&'a Lyrics>,
    look: Look,
    actions: Actions<Message>,
    on_seek: impl Fn(u64) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let pal = *palette;
    let track = state.track.as_ref();
    let title = track.map(|t| t.title.as_str()).unwrap_or("No track playing");
    let artist = track.map(|t| t.artist.as_str()).unwrap_or("");
    let duration_ms = track.map(|t| t.duration_ms).unwrap_or(0);
    let position_ms = state.position_ms.min(duration_ms);
    let lyrics_shown = has_lyrics(lyrics);

    // Top: an invisible strip that moves the window. The window buttons and the Esc hint appear
    // only while the pointer is near it.
    let strip_content: Element<'a, Message> = if look.near_top {
        row![
            Space::with_width(Length::Fill),
            text("Esc").size(theme::type_size::SMALL).color(theme::alpha(pal.text_muted, 0.8)),
            Space::with_width(12),
            crate::views::titlebar::window_controls(
                pal,
                actions.minimize.clone(),
                actions.toggle_maximize.clone(),
                actions.close.clone(),
            ),
            Space::with_width(8),
        ]
        .align_y(Alignment::Center)
        .into()
    } else {
        Space::new(Length::Fill, Length::Fill).into()
    };
    let drag_strip = mouse_area(container(strip_content).width(Length::Fill).height(DRAG_STRIP))
        .on_press(actions.press_bar.clone());

    // Left: the cover with the title and the artist under it.
    let cover = crate::art::cover(
        track.and_then(|t| t.art_url.as_deref()),
        halcyon_music_core::art::ArtSize::Large,
        170.0,
        26.0,
        Icon::Music,
        title,
        pal,
    );
    let mut song = column![cover, Space::with_height(18), text(title).size(22).color(pal.text)]
        .spacing(2)
        .align_x(Alignment::Center);
    if !artist.is_empty() {
        song = song.push(text(artist).size(15).color(pal.text_muted));
    }

    // Right: the lyrics. Without lyrics the song is centred on its own and the visualizer stays.
    let body: Element<'a, Message> = if lyrics_shown {
        let lyrics_body: Element<'a, Message> = match lyrics {
            Some(lrc) if lrc.synced => spotlight(lrc, position_ms, pal, on_seek),
            Some(lrc) => {
                let mut col = column![].spacing(14).padding([60, 10]);
                for line in &lrc.lines {
                    col = col.push(text(line.text.clone()).size(20).color(theme::alpha(pal.text, 0.9)));
                }
                scrollable(col).height(Length::Fill).width(Length::Fill).into()
            }
            None => Space::new(Length::Fill, Length::Fill).into(),
        };

        // The lyrics melt into the page at the top and bottom instead of ending on a line.
        let haze = theme::mix(pal.background, pal.glow, 0.04);
        let top_haze = container(
            container(Space::new(Length::Fill, 90))
                .width(Length::Fill)
                .style(move |_t| container::Style {
                    background: Some(theme::fade_edge(haze, true, 1.0)),
                    ..Default::default()
                }),
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .align_y(iced::alignment::Vertical::Top);
        let bottom_haze = container(
            container(Space::new(Length::Fill, 90))
                .width(Length::Fill)
                .style(move |_t| container::Style {
                    background: Some(theme::fade_edge(haze, false, 1.0)),
                    ..Default::default()
                }),
        )
        .width(Length::Fill)
        .height(Length::Fill)
        .align_y(iced::alignment::Vertical::Bottom);
        let right_lyrics = container(stack![lyrics_body, top_haze, bottom_haze])
            .width(Length::FillPortion(1))
            .height(Length::Fill);

        row![
            container(song).height(Length::Fill).center_y(Length::Fill).width(Length::FillPortion(1)),
            Space::with_width(48),
            right_lyrics,
        ]
        .height(Length::Fill)
        .align_y(Alignment::Center)
        .padding([0, 48])
        .into()
    } else {
        container(song).width(Length::Fill).height(Length::Fill).center_x(Length::Fill).center_y(Length::Fill).into()
    };

    // Bottom: the small transport, centred. It fades; the area keeps its height so nothing
    // above it moves when it goes.
    let a = look.controls_alpha.clamp(0.0, 1.0);
    let glyph = if state.playing { Icon::Pause } else { Icon::Play };
    let time = format!("{} / {}", format_duration(position_ms), format_duration(duration_ms));
    let transport = row![
        fade_icon(Icon::SkipBack, 18.0, a, pal, actions.previous.clone()),
        Space::with_width(10),
        fade_play(glyph, a, pal, actions.toggle_play.clone()),
        Space::with_width(10),
        fade_icon(Icon::SkipForward, 18.0, a, pal, actions.next.clone()),
        Space::with_width(18),
        text(time).size(theme::type_size::SMALL).color(theme::alpha(pal.text_muted, a)),
        Space::with_width(14),
        // The same plain muted icon as the other layouts' full-screen button; here it leaves.
        fade_icon(Icon::Maximize, 16.0, a, pal, actions.exit.clone()),
    ]
    .align_y(Alignment::Center);
    let bottom = container(transport)
        .width(Length::Fill)
        .height(TRANSPORT_AREA)
        .center_x(Length::Fill)
        .center_y(TRANSPORT_AREA);

    let content = column![drag_strip, container(body).width(Length::Fill).height(Length::Fill), bottom]
        .width(Length::Fill)
        .height(Length::Fill);

    // The visualizer lies behind everything; "Off" builds no canvas at all.
    let mut layers = stack![container(Space::new(Length::Fill, Length::Fill))
        .width(Length::Fill)
        .height(Length::Fill)
        .style(move |_t| container::Style {
            // A deeper, cover-tinted gradient than the normal pages.
            background: Some(theme::gradient3(
                theme::mix(pal.bg_top, pal.glow, 0.10),
                theme::mix(pal.background, pal.glow, 0.04),
                pal.bg_bottom,
            )),
            ..Default::default()
        })];
    if look.visualizer != VisualizerKind::None {
        layers = layers.push(viz_canvas::view(viz_canvas::Look {
            kind: look.visualizer,
            bands: look.bands,
            clock: look.clock,
            lyrics_on_right: lyrics_shown,
            accent: pal.accent,
        }));
    }
    layers = layers.push(content);

    container(layers).width(Length::Fill).height(Length::Fill).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use halcyon_music_core::models::Track;

    fn secs(s: f32) -> Duration {
        Duration::from_secs_f32(s)
    }

    #[test]
    fn controls_are_fully_visible_for_three_seconds_after_a_move() {
        assert_eq!(controls_alpha(Duration::ZERO, false), 1.0);
        assert_eq!(controls_alpha(secs(2.9), false), 1.0);
        assert_eq!(controls_alpha(CONTROLS_IDLE, false), 1.0);
    }

    #[test]
    fn controls_fade_out_smoothly_then_stay_gone() {
        let early = controls_alpha(secs(3.1), false);
        let late = controls_alpha(secs(3.3), false);
        assert!(early < 1.0 && early > late && late > 0.0, "{early} {late}");
        assert_eq!(controls_alpha(secs(3.4), false), 0.0);
        assert_eq!(controls_alpha(secs(60.0), false), 0.0);
    }

    #[test]
    fn controls_do_not_fade_with_reduced_motion_they_just_go() {
        assert_eq!(controls_alpha(secs(2.0), true), 1.0);
        assert_eq!(controls_alpha(secs(3.05), true), 0.0);
    }

    #[test]
    fn controls_ask_for_redraws_only_until_they_are_gone() {
        assert!(controls_changing(Duration::ZERO));
        assert!(controls_changing(secs(3.2)));
        assert!(!controls_changing(secs(3.4)));
        assert!(!controls_changing(secs(100.0)));
    }

    #[test]
    fn window_buttons_show_only_near_the_top_edge() {
        assert!(near_top(0.0));
        assert!(near_top(TOP_ZONE));
        assert!(!near_top(TOP_ZONE + 0.1));
        assert!(!near_top(400.0));
        assert!(!near_top(-1.0));
        assert!(!near_top(f32::NAN));
        // The strip is smaller than the zone, so the buttons stay while the pointer is on them.
        assert!(DRAG_STRIP < TOP_ZONE);
    }

    #[test]
    fn the_drag_strip_is_about_28_px_like_the_spec() {
        assert_eq!(DRAG_STRIP, 28.0);
    }

    #[derive(Debug, Clone)]
    struct Msg;

    fn actions() -> Actions<Msg> {
        Actions {
            toggle_play: Msg,
            next: Msg,
            previous: Msg,
            exit: Msg,
            press_bar: Msg,
            minimize: Msg,
            toggle_maximize: Msg,
            close: Msg,
        }
    }

    fn look(kind: VisualizerKind, alpha: f32, near_top: bool) -> Look {
        Look { visualizer: kind, bands: [0.5; BANDS], clock: 1.0, controls_alpha: alpha, near_top }
    }

    fn lyric_lines(n: usize) -> Lyrics {
        Lyrics {
            lines: (0..n)
                .map(|i| LyricLine { start_ms: i as u64 * 2000, text: format!("line {i}"), ..LyricLine::default() })
                .collect(),
            synced: true,
            ..Lyrics::default()
        }
    }

    #[test]
    fn the_screen_builds_for_every_visualizer_with_and_without_lyrics_or_a_track() {
        let pal = HalcyonPalette::default();
        let mut state = PlayerState::default();
        for kind in VisualizerKind::ALL {
            for alpha in [0.0, 0.4, 1.0] {
                for near in [false, true] {
                    // No track, no lyrics.
                    let _: Element<'_, Msg> = view(&state, &pal, None, look(kind, alpha, near), actions(), |_| Msg);
                    // Empty lyrics.
                    let empty = lyric_lines(0);
                    let _: Element<'_, Msg> =
                        view(&state, &pal, Some(&empty), look(kind, alpha, near), actions(), |_| Msg);
                }
            }
        }
        state.track = Some(Track::simple(
            "t".into(),
            "A very long song title ".repeat(8),
            "An artist with a long name too".into(),
            "Album".into(),
            200_000,
        ));
        state.position_ms = 500_000; // past the end: clamped, not a panic
        state.playing = true;
        let lrc = lyric_lines(40);
        for kind in VisualizerKind::ALL {
            let _: Element<'_, Msg> = view(&state, &pal, Some(&lrc), look(kind, 1.0, true), actions(), |_| Msg);
        }
    }
}
