//! Bottom Now-Playing transport bar.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, HalcyonPalette};
use halcyon_music_core::state::{PlayerState, RepeatMode};
use iced::widget::{button, container, row, slider, text, tooltip, Space};
use iced::{Alignment, Element, Length};

#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
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
    on_toggle_lyrics: Message,
    on_toggle_fullscreen: Message,
    on_toggle_like: Message,
    lyrics_open: bool,
    queue_open: bool,
) -> Element<'a, Message> {
    let track = state.track.as_ref();
    let title = track.map(|t| t.title.as_str()).unwrap_or("No track playing");
    let artist = track.map(|t| t.artist.as_str()).unwrap_or("Halcyon");
    let duration_ms = track.map(|t| t.duration_ms).unwrap_or(0);
    let position_ms = state.position_ms.min(duration_ms);

    // --- Left Section: Cover, Title, Artist, Like ---
    let cover_btn = button(
        crate::art::cover(
            track.and_then(|t| t.art_url.as_deref()),
            halcyon_music_core::art::ArtSize::Small,
            48.0,
            6.0,
            Icon::Music,
            title,
            palette,
        ),
    )
    .on_press(on_toggle_fullscreen.clone())
    .padding(0)
    .style(move |_theme, status| button::Style {
        background: Some(
            if status == button::Status::Hovered {
                palette.surface_variant
            } else {
                palette.border
            }
            .into(),
        ),
        border: iced::Border {
            radius: 8.0.into(),
            ..Default::default()
        },
        ..Default::default()
    });

    let meta = iced::widget::column![
        text(crate::views::ellipsize(title, 40)).size(14).color(palette.text),
        text(crate::views::ellipsize(artist, 40)).size(12).color(palette.text_muted),
    ]
    .spacing(2);

    let like_btn = button(icon(Icon::Heart, 16.0, palette.text_muted))
        .on_press(on_toggle_like)
        .padding(4)
        .style(crate::views::ghost(palette));

    let left = row![cover_btn, Space::with_width(12), meta, Space::with_width(8), like_btn]
        .align_y(Alignment::Center)
        .width(Length::FillPortion(3));

    // --- Center Section: Transport + Seek Bar ---
    let play_pause_icon = if state.playing { Icon::Pause } else { Icon::Play };

    let shuffle_color = if state.shuffle {
        palette.accent
    } else {
        palette.text_muted
    };
    let shuffle_btn = button(icon(Icon::Shuffle, 16.0, shuffle_color))
        .on_press(on_toggle_shuffle)
        .padding(6)
        .style(crate::views::ghost(palette));

    let prev_btn = button(icon(Icon::SkipBack, 18.0, palette.text))
        .on_press(on_prev)
        .padding(6)
        .style(crate::views::ghost(palette));

    let play_btn = button(
        container(icon(play_pause_icon, 20.0, palette.background))
            .width(36)
            .height(36)
            .center_x(36)
            .center_y(36),
    )
    .on_press(on_toggle_play)
    .padding(0)
    .style(move |_t, _s| button::Style {
        background: Some(palette.accent.into()),
        border: iced::Border {
            radius: 18.0.into(),
            ..Default::default()
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
    let repeat_color = match state.repeat {
        RepeatMode::Off => palette.text_muted,
        _ => palette.accent,
    };
    let repeat_btn = button(icon(repeat_icon, 16.0, repeat_color))
        .on_press(on_cycle_repeat)
        .padding(6)
        .style(crate::views::ghost(palette));

    let lyrics_btn = tooltip(
        button(icon(Icon::Lyrics, 16.0, if lyrics_open { palette.accent } else { palette.text_muted }))
            .on_press(on_toggle_lyrics)
            .padding(6)
            .style(crate::views::ghost(palette)),
        text("Lyrics").size(12),
        tooltip::Position::Top,
    );

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
        Space::with_width(crate::theme::space::LG),
        lyrics_btn,
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
        .step(1000u32);

    let progress_row = row![elapsed_txt, Space::with_width(8), seek_slider, Space::with_width(8), total_txt]
        .align_y(Alignment::Center)
        .width(Length::Fill);

    let center = iced::widget::column![transport_row, Space::with_height(4), progress_row]
        .align_x(Alignment::Center)
        .width(Length::FillPortion(6));

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

    let vol_slider = slider(0..=100, state.volume, on_volume).width(120);

    let queue_btn = tooltip(
        button(icon(Icon::Queue, 16.0, if queue_open { palette.accent } else { palette.text_muted }))
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

    let right = row![
        Space::with_width(Length::Fill),
        mute_btn,
        vol_slider,
        Space::with_width(12),
        queue_btn,
        fs_btn,
    ]
    .align_y(Alignment::Center)
    .width(Length::FillPortion(3));

    container(
        row![left, center, right]
            .align_y(Alignment::Center)
            .padding([crate::theme::space::MD, crate::theme::space::XL]),
    )
    .width(Length::Fill)
    .height(84)
    .style(move |_theme| container::Style {
        background: Some(palette.surface.into()),
        border: iced::Border {
            color: palette.border,
            width: 1.0,
            ..Default::default()
        },
        ..Default::default()
    })
    .into()
}
