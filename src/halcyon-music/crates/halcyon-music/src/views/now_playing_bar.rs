//! Bottom Now-Playing transport bar.

use crate::theme::{format_duration, HalcyonPalette};
use halcyon_music_core::state::{PlayerState, RepeatMode};
use iced::widget::{button, container, row, slider, text, Space};
use iced::{Alignment, Element, Length};

pub fn view<'a, Message: Clone + 'static>(
    state: &PlayerState,
    palette: &HalcyonPalette,
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
) -> Element<'a, Message> {
    let track = state.track.as_ref();
    let title = track.map(|t| t.title.as_str()).unwrap_or("No track playing");
    let artist = track.map(|t| t.artist.as_str()).unwrap_or("Halcyon");
    let duration_ms = track.map(|t| t.duration_ms).unwrap_or(0);
    let position_ms = state.position_ms.min(duration_ms);

    // --- Left Section: Cover, Title, Artist, Like ---
    let cover_btn = button(
        container(text("󰝚").size(24).color(palette.accent))
            .width(48)
            .height(48)
            .center_x(48)
            .center_y(48),
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
        text(title).size(14).color(palette.text),
        text(artist).size(12).color(palette.text_muted),
    ]
    .spacing(2);

    let like_btn = button(text("󰋑").size(16).color(palette.text_muted))
        .on_press(on_toggle_like)
        .padding(4)
        .style(|_t, _s| button::Style::default());

    let left = row![cover_btn, Space::with_width(12), meta, Space::with_width(8), like_btn]
        .align_y(Alignment::Center)
        .width(Length::FillPortion(1));

    // --- Center Section: Transport + Seek Bar ---
    let play_pause_icon = if state.playing { "󰏤" } else { "󰐊" };

    let shuffle_color = if state.shuffle {
        palette.accent
    } else {
        palette.text_muted
    };
    let shuffle_btn = button(text("󰒝").size(16).color(shuffle_color))
        .on_press(on_toggle_shuffle)
        .padding(6)
        .style(|_t, _s| button::Style::default());

    let prev_btn = button(text("󰒮").size(18).color(palette.text))
        .on_press(on_prev)
        .padding(6)
        .style(|_t, _s| button::Style::default());

    let play_btn = button(
        container(text(play_pause_icon).size(20).color(palette.background))
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

    let next_btn = button(text("󰒭").size(18).color(palette.text))
        .on_press(on_next)
        .padding(6)
        .style(|_t, _s| button::Style::default());

    let repeat_icon = match state.repeat {
        RepeatMode::Off => "󰑗",
        RepeatMode::All => "󰑖",
        RepeatMode::One => "󰑘",
    };
    let repeat_color = match state.repeat {
        RepeatMode::Off => palette.text_muted,
        _ => palette.accent,
    };
    let repeat_btn = button(text(repeat_icon).size(16).color(repeat_color))
        .on_press(on_cycle_repeat)
        .padding(6)
        .style(|_t, _s| button::Style::default());

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

    let seek_slider = slider(0..=duration_ms.max(1), position_ms, on_seek)
        .width(Length::Fill)
        .step(1000);

    let progress_row = row![elapsed_txt, Space::with_width(8), seek_slider, Space::with_width(8), total_txt]
        .align_y(Alignment::Center)
        .width(Length::Fill);

    let center = iced::widget::column![transport_row, Space::with_height(4), progress_row]
        .align_x(Alignment::Center)
        .width(Length::FillPortion(2));

    // --- Right Section: Volume & View Toggles ---
    let vol_icon = if state.volume == 0 {
        "󰝟"
    } else if state.volume < 50 {
        "󰕿"
    } else {
        "󰕾"
    };
    let mute_btn = button(text(vol_icon).size(16).color(palette.text_muted))
        .on_press(on_toggle_mute)
        .padding(4)
        .style(|_t, _s| button::Style::default());

    let vol_slider = slider(0..=100, state.volume, on_volume).width(80);

    let lyrics_btn = button(text("󰎆").size(16).color(palette.text_muted))
        .on_press(on_toggle_lyrics)
        .padding(6)
        .style(|_t, _s| button::Style::default());

    let queue_btn = button(text("󰒯").size(16).color(palette.text_muted))
        .on_press(on_toggle_queue)
        .padding(6)
        .style(|_t, _s| button::Style::default());

    let fs_btn = button(text("󰊓").size(16).color(palette.text_muted))
        .on_press(on_toggle_fullscreen)
        .padding(6)
        .style(|_t, _s| button::Style::default());

    let right = row![
        mute_btn,
        vol_slider,
        Space::with_width(12),
        lyrics_btn,
        queue_btn,
        fs_btn,
    ]
    .align_y(Alignment::Center)
    .width(Length::FillPortion(1));

    container(
        row![left, center, right]
            .align_y(Alignment::Center)
            .padding([8, 16]),
    )
    .width(Length::Fill)
    .height(72)
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
