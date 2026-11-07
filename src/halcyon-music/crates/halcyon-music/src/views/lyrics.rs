//! Synced lyrics view with line tracking, click-to-seek, manual offset tuning,
//! auto-scroll, and local .lrc file loading.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, HalcyonPalette};
use halcyon_music_core::models::{LyricLine, Lyrics, Track};
use iced::widget::{button, column, container, row, text, text_input, Space};
use iced::{Alignment, Element, Length};

#[allow(clippy::too_many_arguments)]
pub fn view<'a, Message: Clone + 'static>(
    track: Option<&'a Track>,
    lyrics: Option<&'a Lyrics>,
    position_ms: u64,
    palette: HalcyonPalette,
    show_load_lrc_input: bool,
    lrc_input: &'a str,
    on_seek: impl Fn(u64) -> Message + 'a + Copy,
    on_offset_change: impl Fn(i64) -> Message + 'a + Copy,
    on_search_again: Message,
    on_toggle_lrc_input: Message,
    on_lrc_input_change: impl Fn(String) -> Message + 'a,
    on_submit_lrc: Message,
) -> Element<'a, Message> {
    let mut page = column![].spacing(16).padding(20).width(Length::Fill);

    let (track_title, track_artist, duration_ms) = if let Some(t) = track {
        (t.title.as_str(), t.artist.as_str(), t.duration_ms)
    } else {
        ("No track playing", "Play a song to view synced lyrics", 0)
    };

    // 1. Top Header & Manual Offset Controls
    let offset_ms = lyrics.map(|l| l.offset_ms).unwrap_or(0);
    let offset_display = if offset_ms > 0 {
        format!("+{offset_ms} ms")
    } else {
        format!("{offset_ms} ms")
    };

    let minus_offset_btn = button(text("–100ms").size(11).color(palette.text_muted))
        .on_press(on_offset_change(offset_ms.saturating_sub(100)))
        .padding([4, 8])
        .style(|_t, _s| button::Style::default());

    let plus_offset_btn = button(text("+100ms").size(11).color(palette.text_muted))
        .on_press(on_offset_change(offset_ms.saturating_add(100)))
        .padding([4, 8])
        .style(|_t, _s| button::Style::default());

    let reset_offset_btn = button(text("Reset").size(11).color(palette.text_muted))
        .on_press(on_offset_change(0))
        .padding([4, 8])
        .style(|_t, _s| button::Style::default());

    let offset_badge = container(
        row![
            text("Sync Offset:").size(11).color(palette.text_muted),
            Space::with_width(6),
            minus_offset_btn,
            text(offset_display).size(11).color(palette.accent),
            plus_offset_btn,
            reset_offset_btn,
        ]
        .align_y(Alignment::Center),
    )
    .padding([3, 8])
    .style(move |_t| container::Style {
        background: Some(palette.surface_variant.into()),
        border: iced::Border {
            radius: 12.0.into(),
            color: palette.soft_border(),
            width: 0.5,
        },
        ..Default::default()
    });

    let header_cover = crate::art::cover(
        track.and_then(|t| t.art_url.as_deref()),
        halcyon_music_core::art::ArtSize::Small,
        56.0,
        8.0,
        Icon::Music,
        track_title,
        palette,
    );
    let header = row![
        header_cover,
        Space::with_width(14),
        column![
            text(track_title).size(20).color(palette.text),
            Space::with_height(2),
            text(track_artist).size(13).color(palette.text_muted),
        ],
        Space::with_width(Length::Fill),
        offset_badge,
    ]
    .align_y(Alignment::Center);

    page = page.push(header);

    // 2. Lyrics Content
    if let Some(lrc) = lyrics {
        if lrc.lines.is_empty() {
            page = page.push(view_empty_state(
                track_title,
                track_artist,
                palette,
                show_load_lrc_input,
                lrc_input,
                on_search_again,
                on_toggle_lrc_input,
                on_lrc_input_change,
                on_submit_lrc,
            ));
        } else if lrc.synced {
            page = page.push(view_synced_lines(
                &lrc.lines,
                position_ms,
                lrc.offset_ms,
                palette,
                on_seek,
            ));
        } else {
            page = page.push(view_plain_lines(&lrc.lines, palette));
        }
    } else {
        page = page.push(view_empty_state(
            track_title,
            track_artist,
            palette,
            show_load_lrc_input,
            lrc_input,
            on_search_again,
            on_toggle_lrc_input,
            on_lrc_input_change,
            on_submit_lrc,
        ));
    }

    let _ = duration_ms;
    container(page).width(Length::Fill).into()
}

fn view_synced_lines<'a, Message: Clone + 'static>(
    lines: &'a [LyricLine],
    position_ms: u64,
    offset_ms: i64,
    palette: HalcyonPalette,
    on_seek: impl Fn(u64) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let effective_pos = (position_ms as i64).saturating_add(offset_ms).max(0) as u64;

    // Find currently active line index
    let mut active_idx = 0;
    for (i, line) in lines.iter().enumerate() {
        if line.start_ms <= effective_pos {
            active_idx = i;
        } else {
            break;
        }
    }

    let mut lines_col = column![].spacing(8).width(Length::Fill);

    for (idx, line) in lines.iter().enumerate() {
        let is_active = idx == active_idx;
        let distance = (idx as i64 - active_idx as i64).abs();

        let (font_size, text_color) = if is_active {
            (20, palette.accent)
        } else if distance == 1 {
            (16, palette.text)
        } else if distance == 2 {
            (15, palette.text_muted)
        } else {
            (14, iced::Color { a: 0.35, ..palette.text_muted })
        };

        let start_ms = line.start_ms;
        let seek_time_str = format_duration(start_ms);

        let line_btn = button(
            row![
                text(seek_time_str)
                    .size(10)
                    .color(if is_active {
                        palette.accent
                    } else {
                        iced::Color { a: 0.3, ..palette.text_muted }
                    })
                    .width(42),
                Space::with_width(12),
                text(&line.text)
                    .size(font_size)
                    .color(text_color)
                    .width(Length::Fill),
            ]
            .align_y(Alignment::Center),
        )
        .on_press(on_seek(start_ms))
        .padding([6, 12])
        .width(Length::Fill)
        .style(move |_t, s| button::Style {
            background: Some(
                if is_active {
                    palette.surface_variant
                } else if s == button::Status::Hovered {
                    palette.surface
                } else {
                    iced::Color::TRANSPARENT
                }
                .into(),
            ),
            border: iced::Border {
                radius: 12.0.into(),
                ..Default::default()
            },
            ..Default::default()
        });

        lines_col = lines_col.push(line_btn);
    }

    container(lines_col)
        .padding([12, 0])
        .width(Length::Fill)
        .into()
}

fn view_plain_lines<'a, Message: 'static>(
    lines: &'a [LyricLine],
    palette: HalcyonPalette,
) -> Element<'a, Message> {
    let mut col = column![].spacing(10).width(Length::Fill);

    col = col.push(
        container(
            row![
                icon(Icon::Lyrics, 14.0, palette.accent),
                Space::with_width(8),
                text("Plain lyrics (unsynced timestamps)").size(12).color(palette.text_muted),
            ]
            .align_y(Alignment::Center),
        )
        .padding([4, 10])
        .style(move |_t| container::Style {
            background: Some(palette.surface_variant.into()),
            border: iced::Border {
                radius: 10.0.into(),
                ..Default::default()
            },
            ..Default::default()
        }),
    );

    for line in lines {
        col = col.push(
            text(&line.text)
                .size(15)
                .color(palette.text)
                .width(Length::Fill),
        );
    }

    container(col).padding(16).width(Length::Fill).into()
}

#[allow(clippy::too_many_arguments)]
fn view_empty_state<'a, Message: Clone + 'static>(
    title: &str,
    artist: &str,
    palette: HalcyonPalette,
    show_load_input: bool,
    lrc_input: &'a str,
    on_search_again: Message,
    on_toggle_load: Message,
    on_lrc_input: impl Fn(String) -> Message + 'a,
    on_submit_lrc: Message,
) -> Element<'a, Message> {
    let mut col = column![
        Space::with_height(40),
        icon(Icon::Lyrics, 48.0, palette.text_muted),
        Space::with_height(14),
        text("No lyrics found").size(18).color(palette.text),
        Space::with_height(6),
        text(format!("Couldn't find lyrics for \"{title}\" by {artist}"))
            .size(13)
            .color(palette.text_muted),
        Space::with_height(18),
        row![
            button(
                row![
                    icon(Icon::Search, 14.0, palette.background),
                    Space::with_width(6),
                    text("Search LRCLIB Again").size(12).color(palette.background),
                ]
                .align_y(Alignment::Center),
            )
            .on_press(on_search_again)
            .padding([8, 14])
            .style(move |_t, _s| button::Style {
                background: Some(palette.accent_background()),
                border: iced::Border {
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            }),
            Space::with_width(12),
            button(
                row![
                    icon(Icon::Plus, 14.0, palette.text),
                    Space::with_width(6),
                    text("Load Local .lrc").size(12).color(palette.text),
                ]
                .align_y(Alignment::Center),
            )
            .on_press(on_toggle_load)
            .padding([8, 14])
            .style(move |_t, _s| button::Style {
                background: Some(palette.card_background()),
                border: iced::Border {
                    radius: 12.0.into(),
                    color: palette.soft_border(),
                    width: 0.5,
                },
                ..Default::default()
            }),
        ]
        .align_y(Alignment::Center),
    ]
    .align_x(Alignment::Center)
    .width(Length::Fill);

    if show_load_input {
        let input_box = text_input("Paste [mm:ss.xx] LRC formatted text here...", lrc_input)
            .on_input(on_lrc_input)
            .padding(10)
            .size(13)
            .width(Length::Fixed(400.0));

        let submit_btn = button(text("Apply Lyrics").size(12).color(palette.background))
            .on_press(on_submit_lrc)
            .padding([8, 16])
            .style(move |_t, _s| button::Style {
                background: Some(palette.accent_background()),
                border: iced::Border {
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

        col = col.push(Space::with_height(16));
        col = col.push(row![input_box, Space::with_width(8), submit_btn].align_y(Alignment::Center));
    }

    container(col).width(Length::Fill).center_x(Length::Fill).into()
}
