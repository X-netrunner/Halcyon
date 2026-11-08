//! Full-screen Now Playing: a big cover that gently pulses with the music, spotlight lyrics,
//! and an animated visualizer above the transport controls.
//!
//! Lyrics follow a spotlight: the line being sung is large and bright, the lines around it
//! shrink and dim with distance, and when the next line starts the whole stack glides up into
//! place instead of jumping. Long songs stay cheap because only a dozen lines around the active
//! one are built.

use crate::animation::Easing;
use crate::icons::{icon, Icon};
use crate::theme::{self, format_duration, HalcyonPalette};
use halcyon_music_core::models::{LyricLine, Lyrics};
use halcyon_music_core::state::PlayerState;
use iced::widget::{button, column, container, row, scrollable, slider, text, Space};
use iced::{Alignment, Element, Length};

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
        return no_lyrics(palette);
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

/// Message shown instead of lyrics.
fn no_lyrics<'a, Message: 'a>(palette: HalcyonPalette) -> Element<'a, Message> {
    container(
        column![
            icon(Icon::Lyrics, 30.0, theme::alpha(palette.text_muted, 0.7)),
            Space::with_height(12),
            text("No lyrics for this song").size(16).color(palette.text_muted),
            text("Enjoy the visuals instead.").size(13).color(theme::alpha(palette.text_muted, 0.7)),
        ]
        .spacing(2)
        .align_x(Alignment::Center),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .center_x(Length::Fill)
    .center_y(Length::Fill)
    .into()
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    state: &'a PlayerState,
    palette: &'a HalcyonPalette,
    breath: f32,
    clock: f32,
    lyrics: Option<&'a Lyrics>,
    on_toggle_play: Message,
    on_next: Message,
    on_prev: Message,
    on_seek: impl Fn(u64) -> Message + 'a + Copy,
    on_exit_fullscreen: Message,
) -> Element<'a, Message> {
    let pal = *palette;
    let track = state.track.as_ref();
    let title = track.map(|t| t.title.as_str()).unwrap_or("No track playing");
    let artist = track.map(|t| t.artist.as_str()).unwrap_or("Halcyon");
    let album = track.map(|t| t.album.as_str()).unwrap_or("");
    let duration_ms = track.map(|t| t.duration_ms).unwrap_or(0);
    let position_ms = state.position_ms.min(duration_ms);
    // Stable per-song number so every song dances a little differently.
    let seed = track
        .map(|t| t.id.bytes().fold(0u32, |a, b| a.wrapping_mul(31).wrapping_add(b as u32)) as f32 % 97.0)
        .unwrap_or(0.0);

    // Top bar: a small label on the left, a quiet close button on the right.
    let top_bar = row![
        text("NOW PLAYING").size(11).color(pal.accent),
        Space::with_width(Length::Fill),
        crate::views::icon_action(Icon::Close, "Close (Esc)", pal, Some(on_exit_fullscreen)),
    ]
    .align_y(Alignment::Center)
    .width(Length::Fill)
    .padding([16, 28]);

    // Cover: it swells a few pixels on the low notes inside a fixed box, so nothing around it moves.
    let bass = crate::views::spectrum_level(1, 48, clock, seed, state.playing);
    let cover_px = 296.0 + 24.0 * bass;
    let big_art = crate::art::cover(
        track.and_then(|t| t.art_url.as_deref()),
        halcyon_music_core::art::ArtSize::Large,
        cover_px,
        28.0,
        Icon::Music,
        title,
        pal,
    );
    let halo = container(big_art).style(move |_t| container::Style {
        border: iced::Border { radius: 36.0.into(), ..Default::default() },
        shadow: iced::Shadow {
            color: theme::alpha(pal.glow, 0.22 + 0.22 * breath + 0.12 * bass),
            offset: iced::Vector::new(0.0, 0.0),
            blur_radius: 50.0 + 40.0 * breath,
        },
        ..Default::default()
    });
    let cover_box = container(halo).width(336).height(336).center_x(336).center_y(336);

    let left_info = column![
        cover_box,
        Space::with_height(20),
        text(title).size(26).color(pal.text),
        text(artist).size(18).color(pal.accent),
        text(album).size(14).color(pal.text_muted),
    ]
    .spacing(2)
    .align_x(Alignment::Center)
    .width(Length::FillPortion(1));

    // Lyrics: spotlight when synced, a calm scroll when plain, a message when missing.
    let lyrics_body: Element<Message> = match lyrics {
        Some(lrc) if !lrc.lines.is_empty() && lrc.synced => spotlight(lrc, position_ms, pal, on_seek),
        Some(lrc) if !lrc.lines.is_empty() => {
            let mut col = column![].spacing(14).padding([60, 10]);
            for line in &lrc.lines {
                col = col.push(text(line.text.clone()).size(20).color(theme::alpha(pal.text, 0.9)));
            }
            scrollable(col).height(Length::Fill).width(Length::Fill).into()
        }
        _ => no_lyrics(pal),
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
    let right_lyrics = container(iced::widget::stack![lyrics_body, top_haze, bottom_haze])
        .width(Length::FillPortion(1))
        .height(Length::Fill);

    let main_content = row![
        container(left_info).height(Length::Fill).center_y(Length::Fill).width(Length::FillPortion(1)),
        Space::with_width(48),
        right_lyrics,
    ]
    .height(Length::Fill)
    .align_y(Alignment::Center)
    .padding([0, 48]);

    // Visualizer: mirrored bars that dance while music plays and settle when it is paused.
    let visualizer = container(crate::views::equalizer(84, 4.0, 5.0, 72.0, clock, seed, state.playing, true, pal))
        .width(Length::Fill)
        .center_x(Length::Fill);

    // Transport
    let play_pause_icon = if state.playing { Icon::Pause } else { Icon::Play };
    let prev_btn = button(icon(Icon::SkipBack, 24.0, pal.text))
        .on_press(on_prev)
        .padding(10)
        .style(crate::views::ghost(pal));
    let next_btn = button(icon(Icon::SkipForward, 24.0, pal.text))
        .on_press(on_next)
        .padding(10)
        .style(crate::views::ghost(pal));
    let play_btn = crate::views::play_orb(play_pause_icon, 64.0, pal, Some(on_toggle_play));
    let transport_row = row![prev_btn, Space::with_width(18), play_btn, Space::with_width(18), next_btn]
        .align_y(Alignment::Center);

    let dur_u32 = (duration_ms as u32).max(1);
    let pos_u32 = (position_ms as u32).min(dur_u32);
    let seek_slider = slider(0..=dur_u32, pos_u32, move |v| on_seek(v as u64))
        .width(520)
        .style(crate::views::slider_style(pal));
    let times = row![
        text(format_duration(position_ms)).size(13).color(pal.text_muted),
        Space::with_width(Length::Fill),
        text(format_duration(duration_ms)).size(13).color(pal.text_muted),
    ]
    .width(520);

    let bottom_controls = column![seek_slider, times, Space::with_height(10), transport_row]
        .align_x(Alignment::Center)
        .padding(iced::Padding { top: 6.0, right: 24.0, bottom: 22.0, left: 24.0 });

    container(
        column![top_bar, main_content, visualizer, bottom_controls].align_x(Alignment::Center),
    )
    .width(Length::Fill)
    .height(Length::Fill)
    .style(move |_t| container::Style {
        // A deeper, cover-tinted gradient than the normal pages, with the glow near the top.
        background: Some(theme::gradient3(
            theme::mix(pal.bg_top, pal.glow, 0.10 + 0.05 * breath),
            theme::mix(pal.background, pal.glow, 0.04),
            pal.bg_bottom,
        )),
        ..Default::default()
    })
    .into()
}
