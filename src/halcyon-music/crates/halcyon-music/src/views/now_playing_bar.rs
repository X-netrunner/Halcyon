//! Bottom Now-Playing transport bar. It has no background of its own: it shares the frame
//! (see `HalcyonApp::view`) with the sidebar.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, HalcyonPalette};
use crate::visualizer::MiniPlacement;
use crate::viz::BANDS;
use halcyon_music_core::state::{PlayerState, RepeatMode};
use iced::widget::{button, container, row, slider, text, tooltip, Space};
use iced::{Alignment, Element, Length};

/// How the bar differs between layouts. `CLASSIC` is the bar as it always was.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BarOptions {
    /// Times under the progress bar (left and right ends) instead of beside it.
    pub times_below: bool,
    /// Whether the volume icon and slider are drawn. The layouts hide them in narrow windows.
    pub show_volume: bool,
    /// The mini visualizer's smoothed spectrum, when it is drawn (right after the song). `None`
    /// draws nothing and changes nothing else.
    pub mini: Option<[f32; BANDS]>,
    /// The calm look of the four new layouts: the accent is only on the play button and the
    /// progress fill. A lit toggle (like, shuffle, repeat, queue) is the text colour instead of the
    /// accent, and the cover has no accent ring or glow under the pointer. Classic keeps its look.
    pub calm: bool,
}

impl BarOptions {
    pub const CLASSIC: BarOptions = BarOptions {
        times_below: false,
        show_volume: true,
        mini: None,
        calm: false,
    };
}

/// The colour of a toggle that can be lit. Classic lights it with the accent; the calm layouts
/// light it with the text colour (muted when off), so the accent stays on the play button and the
/// progress fill only.
fn lit_colour(palette: HalcyonPalette, calm: bool, lit: bool) -> iced::Color {
    match (lit, calm) {
        (false, _) => palette.text_muted,
        (true, true) => palette.text,
        (true, false) => palette.accent,
    }
}

/// Song title length with and without the mini visualizer beside it: the strip and its gap take
/// room from the title, so it is cut a little sooner.
const TITLE_CHARS: usize = 40;
const TITLE_CHARS_WITH_MINI: usize = 26;

/// Height of the bar when the times sit under the progress bar.
const HEIGHT_TIMES_BELOW: f32 = 96.0;

#[allow(clippy::too_many_arguments)]
pub fn view_with<'a, Message: Clone + 'static>(
    options: BarOptions,
    state: &'a PlayerState,
    palette: HalcyonPalette,
    on_toggle_play: Message,
    on_next: Message,
    on_prev: Message,
    on_seek: impl Fn(u64) -> Message + 'a,
    on_volume: impl Fn(u8) -> Message + 'a,
    on_toggle_mute: Message,
    on_toggle_shuffle: Message,
    on_cycle_repeat: Message,
    on_toggle_queue: Message,
    _on_toggle_lyrics: Message,
    on_toggle_fullscreen: Message,
    on_toggle_like: Message,
    liked: bool,
    _lyrics_open: bool,
    queue_open: bool,
) -> Element<'a, Message> {
    let track = state.track.as_ref();
    let title = track
        .map(|t| t.title.as_str())
        .unwrap_or("No track playing");
    let artist = track.map(|t| t.artist.as_str()).unwrap_or("Halcyon");
    let duration_ms = track.map(|t| t.duration_ms).unwrap_or(0);
    let position_ms = state.position_ms.min(duration_ms);

    // --- Left Section: Cover, Title, Artist, Like ---
    let cover_btn = button(crate::art::cover(
        track.and_then(|t| t.art_url.as_deref()),
        halcyon_music_core::art::ArtSize::Small,
        52.0,
        18.0,
        Icon::Music,
        title,
        palette,
    ))
    .on_press(on_toggle_fullscreen.clone())
    .padding(0)
    .style(move |_theme, status| {
        // Calm: nothing lights up around the cover (no ring, no glow); pressing it still opens
        // full screen.
        let ring = status == button::Status::Hovered && !options.calm;
        button::Style {
            background: None,
            border: iced::Border {
                radius: 18.0.into(),
                width: if ring { 1.5 } else { 0.0 },
                color: crate::theme::alpha(palette.accent, 0.6),
            },
            shadow: if ring {
                palette.glow_shadow(0.35, 18.0)
            } else {
                iced::Shadow::default()
            },
            ..Default::default()
        }
    });

    let title_chars = if options.mini.is_some() {
        TITLE_CHARS_WITH_MINI
    } else {
        TITLE_CHARS
    };
    let meta = iced::widget::column![
        text(crate::views::ellipsize(title, title_chars))
            .size(15)
            .color(palette.text),
        text(crate::views::ellipsize(artist, title_chars))
            .size(12)
            .color(palette.text_muted),
    ]
    .spacing(2);

    let like_btn = button(if liked {
        icon(
            Icon::HeartFilled,
            16.0,
            lit_colour(palette, options.calm, true),
        )
    } else {
        icon(Icon::Heart, 16.0, palette.text_muted)
    })
    .on_press(on_toggle_like)
    .padding(4)
    .style(crate::views::ghost(palette));

    // The mini visualizer sits right after the song, before the like button (no label).
    let mut left = row![cover_btn, Space::with_width(12), meta].align_y(Alignment::Center);
    if let Some(bands) = options.mini {
        left = left
            .push(Space::with_width(12))
            .push(crate::views::viz_canvas::mini(
                MiniPlacement::Bar,
                bands,
                palette.accent,
            ));
    }
    // With the strip beside the song, the song gets a little more of the bar and the middle a
    // little less (the transport and progress bar still have plenty).
    let (left_portion, centre_portion) = if options.mini.is_some() {
        (4, 5)
    } else {
        (3, 6)
    };
    let left = left
        .push(Space::with_width(8))
        .push(like_btn)
        .width(Length::FillPortion(left_portion));

    // --- Center Section: Transport + Seek Bar ---
    let play_pause_icon = if state.playing {
        Icon::Pause
    } else {
        Icon::Play
    };
    let state_playing = state.playing;

    let shuffle_color = lit_colour(palette, options.calm, state.shuffle);
    let shuffle_btn = button(icon(Icon::Shuffle, 16.0, shuffle_color))
        .on_press(on_toggle_shuffle)
        .padding(6)
        .style(crate::views::ghost(palette));

    let prev_btn = button(icon(Icon::SkipBack, 18.0, palette.text))
        .on_press(on_prev)
        .padding(6)
        .style(crate::views::ghost(palette));

    let play_btn = button(
        container(icon(play_pause_icon, 20.0, palette.on_accent()))
            .width(40)
            .height(40)
            .center_x(40)
            .center_y(40),
    )
    .on_press(on_toggle_play)
    .padding(0)
    .style(move |_t, s| button::Style {
        background: Some(palette.accent_background()),
        border: iced::Border {
            radius: 26.0.into(),
            ..Default::default()
        },
        // Glows a little more while music plays and when hovered.
        shadow: if s == button::Status::Hovered {
            palette.glow_shadow(0.55, 26.0)
        } else if state_playing {
            palette.glow_shadow(0.38, 20.0)
        } else {
            palette.glow_shadow(0.20, 12.0)
        },
        ..Default::default()
    });

    let next_btn = button(icon(Icon::SkipForward, 18.0, palette.text))
        .on_press(on_next)
        .padding(6)
        .style(crate::views::ghost(palette));

    let repeat_icon = match state.repeat {
        RepeatMode::Off => Icon::Repeat,
        RepeatMode::All => Icon::Repeat,
        RepeatMode::One => Icon::Repeat1,
    };
    let repeat_color = lit_colour(palette, options.calm, state.repeat != RepeatMode::Off);
    let repeat_btn = button(icon(repeat_icon, 16.0, repeat_color))
        .on_press(on_cycle_repeat)
        .padding(6)
        .style(crate::views::ghost(palette));

    let transport_row = row![
        shuffle_btn,
        Space::with_width(8),
        prev_btn,
        Space::with_width(8),
        play_btn,
        Space::with_width(8),
        next_btn,
        Space::with_width(8),
        repeat_btn,
    ]
    .align_y(Alignment::Center);

    let elapsed_txt = text(format_duration(position_ms))
        .size(11)
        .color(palette.text_muted);
    let total_txt = text(format_duration(duration_ms))
        .size(11)
        .color(palette.text_muted);

    let dur_u32 = (duration_ms as u32).max(1);
    let pos_u32 = (position_ms as u32).min(dur_u32);
    let seek_slider = slider(0..=dur_u32, pos_u32, move |v| on_seek(v as u64))
        .width(Length::Fill)
        .step(1000u32)
        .style(crate::views::slider_style(palette));

    let center = if options.times_below {
        // The slider has the full width; the two times sit under its ends.
        let times = row![elapsed_txt, Space::with_width(Length::Fill), total_txt]
            .align_y(Alignment::Center)
            .width(Length::Fill);
        iced::widget::column![transport_row, Space::with_height(4), seek_slider, times]
            .align_x(Alignment::Center)
            .width(Length::FillPortion(centre_portion))
    } else {
        let progress_row = row![
            elapsed_txt,
            Space::with_width(8),
            seek_slider,
            Space::with_width(8),
            total_txt
        ]
        .align_y(Alignment::Center)
        .width(Length::Fill);
        iced::widget::column![transport_row, Space::with_height(4), progress_row]
            .align_x(Alignment::Center)
            .width(Length::FillPortion(centre_portion))
    };

    // --- Right Section: Volume & View Toggles ---
    let vol_icon = if state.volume == 0 {
        Icon::VolumeX
    } else if state.volume < 50 {
        Icon::Volume1
    } else {
        Icon::Volume2
    };
    let mute_btn = button(icon(vol_icon, 16.0, palette.text_muted))
        .on_press(on_toggle_mute)
        .padding(4)
        .style(crate::views::ghost(palette));

    let vol_slider = slider(0..=100, state.volume, on_volume)
        .width(120)
        .style(crate::views::slider_style(palette));

    let queue_btn = tooltip(
        button(icon(
            Icon::Queue,
            16.0,
            lit_colour(palette, options.calm, queue_open),
        ))
        .on_press(on_toggle_queue)
        .padding(6)
        .style(crate::views::ghost(palette)),
        text("Queue").size(12),
        tooltip::Position::Top,
    );

    let fs_btn = button(icon(Icon::Maximize, 16.0, palette.text_muted))
        .on_press(on_toggle_fullscreen)
        .padding(6)
        .style(crate::views::ghost(palette));

    let mut right = row![Space::with_width(Length::Fill)];
    if options.show_volume {
        right = right
            .push(mute_btn)
            .push(vol_slider)
            .push(Space::with_width(12));
    }
    let right = right
        .push(queue_btn)
        .push(fs_btn)
        .align_y(Alignment::Center)
        .width(Length::FillPortion(3));

    // No fill, border or shadow of its own: the bar sits on the same frame as the sidebar, so
    // the two read as one surface. The cover lines up with the sidebar's icon column.
    container(
        row![left, center, right]
            .align_y(Alignment::Center)
            .padding(iced::Padding {
                top: crate::theme::space::SM,
                right: crate::theme::space::XL,
                bottom: if options.times_below {
                    crate::theme::space::SM
                } else {
                    crate::theme::space::MD
                },
                left: 12.0,
            }),
    )
    .width(Length::Fill)
    .height(if options.times_below {
        HEIGHT_TIMES_BELOW
    } else {
        88.0
    })
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classic_options_are_the_bar_as_it_was() {
        assert!(!BarOptions::CLASSIC.times_below);
        assert!(BarOptions::CLASSIC.show_volume);
        assert!(
            BarOptions::CLASSIC.mini.is_none(),
            "Classic never gets the mini visualizer"
        );
        assert!(
            !BarOptions::CLASSIC.calm,
            "Classic keeps its accent-lit toggles"
        );
    }

    #[test]
    fn a_lit_toggle_is_the_accent_in_classic_and_the_text_colour_when_calm() {
        let p = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        assert_eq!(lit_colour(p, false, true), p.accent);
        assert_eq!(lit_colour(p, true, true), p.text);
        // Off is the same muted colour in both.
        assert_eq!(lit_colour(p, false, false), p.text_muted);
        assert_eq!(lit_colour(p, true, false), p.text_muted);
        // Calm never uses the accent for a toggle.
        for lit in [false, true] {
            assert_ne!(lit_colour(p, true, lit), p.accent);
        }
    }

    #[test]
    fn the_bar_builds_in_every_option_combination() {
        let palette = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        let state = PlayerState::default();
        let minis = [None, Some([0.0; BANDS]), Some([1.0; BANDS])];
        for times_below in [false, true] {
            for show_volume in [false, true] {
                for mini in minis {
                    for calm in [false, true] {
                        let _v: Element<'_, ()> = view_with(
                            BarOptions {
                                times_below,
                                show_volume,
                                mini,
                                calm,
                            },
                            &state,
                            palette,
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
                            (),
                            false,
                            false,
                            false,
                        );
                    }
                }
            }
        }
    }
}
