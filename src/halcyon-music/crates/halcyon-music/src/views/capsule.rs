//! Halcyon Sound Capsule View.
//!
//! Monthly summary cards computed 100% locally from the offline SQLite play log:
//! - Minutes listened, total plays, top 5 tracks with play counts, top 5 artists with minutes,
//!   top genres, 24-hour listening distribution bar chart, longest daily streak,
//!   most replayed song in a single day, and month-over-month listening growth percentage.
//! - Clear UI disclosure explaining local computation privacy.

use crate::icons::{icon, Icon};
use crate::theme::{format_duration, Density, HalcyonPalette};
use halcyon_music_core::models::{FullCapsule, Track};
use iced::widget::{button, column, container, row, text, Space};
use iced::{Alignment, Element, Length};

pub fn view<'a, Message: Clone + 'static>(
    capsule: &'a FullCapsule,
    month_offset: u32,
    palette: HalcyonPalette,
    _density: Density,
    on_prev_month: Message,
    on_next_month: Message,
    on_play_track: impl Fn(Track) -> Message + 'a + Copy,
) -> Element<'a, Message> {
    let mut page = column![].spacing(20).padding(24).width(Length::Fill);

    // 1. Header & Month Navigation
    let next_btn = button(icon(Icon::ChevronRight, 16.0, if month_offset > 0 {
        palette.text
    } else {
        palette.text_muted
    }))
    .on_press(on_next_month)
    .padding([6, 12])
    .style(move |_t, _s| button::Style {
        background: Some(palette.card_background()),
        border: iced::Border {
            radius: 12.0.into(),
            color: palette.soft_border(),
            width: 0.5,
        },
        ..Default::default()
    });

    let prev_btn = button(icon(Icon::ChevronLeft, 16.0, palette.text))
        .on_press(on_prev_month)
        .padding([6, 12])
        .style(move |_t, _s| button::Style {
            background: Some(palette.card_background()),
            border: iced::Border {
                radius: 12.0.into(),
                color: palette.soft_border(),
                width: 0.5,
            },
            ..Default::default()
        });

    let month_title = format!("{} {}", capsule.month_name, capsule.year);

    let header = row![
        column![
            text("Sound Capsule").size(22).color(palette.text),
            Space::with_height(4),
            text("Your monthly listening statistics, habits, and trends")
                .size(13)
                .color(palette.text_muted),
        ],
        Space::with_width(Length::Fill),
        row![
            prev_btn,
            Space::with_width(8),
            container(text(month_title).size(14).color(palette.text))
                .padding([6, 14])
                .style(move |_t| container::Style {
                    background: Some(palette.surface_variant.into()),
                    border: iced::Border {
                        radius: 12.0.into(),
                        ..Default::default()
                    },
                    ..Default::default()
                }),
            Space::with_width(8),
            next_btn,
        ]
        .align_y(Alignment::Center),
    ]
    .align_y(Alignment::Center);

    page = page.push(header);

    // 2. Local Privacy Disclosure Banner
    let privacy_banner = container(
        row![
            icon(Icon::Shield, 18.0, palette.accent),
            Space::with_width(10),
            column![
                text("100% Offline & Private Local Computation").size(13).color(palette.text),
                text("All statistics and trends are computed entirely from your local Halcyon SQLite database. Zero telemetry or listening history is ever uploaded.")
                    .size(11)
                    .color(palette.text_muted),
            ],
        ]
        .align_y(Alignment::Center),
    )
    .padding([10, 16])
    .width(Length::Fill)
    .style(move |_t| container::Style {
        background: Some(palette.card_background()),
        border: iced::Border {
            color: palette.accent,
            width: 1.0,
            radius: 12.0.into(),
        },
        ..Default::default()
    });

    page = page.push(privacy_banner);

    // 3. Four Metric Highlight Cards
    let hours = (capsule.total_minutes as f64) / 60.0;
    let mom_text = if capsule.mom_change_percent >= 0 {
        format!("+{}% vs last month", capsule.mom_change_percent)
    } else {
        format!("{}% vs last month", capsule.mom_change_percent)
    };

    let card_time = view_metric_card(
        Icon::Clock,
        "Listening Time",
        format!("{:.1} hrs", hours),
        format!("{} mins · {}", capsule.total_minutes, mom_text),
        palette,
    );

    let card_plays = view_metric_card(
        Icon::Music,
        "Total Plays",
        format!("{}", capsule.total_plays),
        "Tracks logged this month".to_string(),
        palette,
    );

    let card_streak = view_metric_card(
        Icon::Flame,
        "Longest Streak",
        format!("{} days", capsule.longest_streak_days),
        "Consecutive days listening".to_string(),
        palette,
    );

    let (most_rep_title, most_rep_sub) = if let Some((ref tr, count)) = capsule.most_replayed_track {
        (
            tr.title.clone(),
            format!("{} plays in a single day", count),
        )
    } else {
        ("None yet".to_string(), "Play more music to unlock".to_string())
    };

    let card_replayed = view_metric_card(
        Icon::Repeat,
        "Most Replayed",
        most_rep_title,
        most_rep_sub,
        palette,
    );

    let metrics_row = row![
        card_time,
        Space::with_width(12),
        card_plays,
        Space::with_width(12),
        card_streak,
        Space::with_width(12),
        card_replayed,
    ]
    .width(Length::Fill);

    page = page.push(metrics_row);

    // 4. 24-Hour Listening Distribution Bar Chart
    let chart_section = view_hourly_chart(&capsule.hourly_distribution, palette);
    page = page.push(chart_section);

    // 5. Top 5 Tracks & Top 5 Artists Columns
    let mut tracks_col = column![
        text("Top 5 Tracks").size(16).color(palette.text),
        Space::with_height(10),
    ]
    .spacing(8)
    .width(Length::FillPortion(1));

    if capsule.top_tracks.is_empty() {
        tracks_col = tracks_col.push(
            text("No track plays logged for this period.")
                .size(13)
                .color(palette.text_muted),
        );
    } else {
        for (idx, (track, count)) in capsule.top_tracks.iter().enumerate() {
            let tr_clone = track.clone();
            let row_item = button(
                row![
                    container(text(format!("#{}", idx + 1)).size(12).color(palette.accent))
                        .width(28)
                        .center_x(28),
                    Space::with_width(8),
                    crate::art::cover(
                        track.art_url.as_deref(),
                        halcyon_music_core::art::ArtSize::Small,
                        36.0,
                        6.0,
                        Icon::Music,
                        &track.title,
                        palette,
                    ),
                    Space::with_width(10),
                    column![
                        text(super::ellipsize(&track.title, 56)).size(13).color(palette.text),
                        text(super::ellipsize(&track.artist, 44)).size(11).color(palette.text_muted),
                    ]
                    .width(Length::Fill),
                    text(format!("{} plays", count)).size(12).color(palette.text_muted),
                    Space::with_width(10),
                    text(format_duration(track.duration_ms)).size(11).color(palette.text_muted),
                    Space::with_width(8),
                    icon(Icon::Play, 15.0, palette.accent),
                ]
                .align_y(Alignment::Center)
                .padding([6, 8]),
            )
            .width(Length::Fill)
            .on_press(on_play_track(tr_clone))
            .style(move |_t, s| button::Style {
                background: Some(
                    if s == button::Status::Hovered { crate::theme::mix(palette.surface, palette.accent, 0.16) } else { crate::theme::alpha(palette.surface, 0.62) }
                    .into(),
                ),
                border: iced::Border {
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

            tracks_col = tracks_col.push(row_item);
        }
    }

    let mut artists_col = column![
        text("Top 5 Artists").size(16).color(palette.text),
        Space::with_height(10),
    ]
    .spacing(8)
    .width(Length::FillPortion(1));

    if capsule.top_artists.is_empty() {
        artists_col = artists_col.push(
            text("No artist data available for this period.")
                .size(13)
                .color(palette.text_muted),
        );
    } else {
        for (idx, (artist, minutes)) in capsule.top_artists.iter().enumerate() {
            let row_item = container(
                row![
                    container(text(format!("#{}", idx + 1)).size(12).color(palette.accent))
                        .width(28)
                        .center_x(28),
                    Space::with_width(8),
                    container(icon(Icon::Artist, 16.0, palette.accent))
                        .width(32)
                        .height(32)
                        .center_x(32)
                        .center_y(32)
                        .style(move |_t| container::Style {
                            background: Some(palette.surface_variant.into()),
                            border: iced::Border {
                                radius: 20.0.into(),
                                ..Default::default()
                            },
                            ..Default::default()
                        }),
                    Space::with_width(10),
                    text(artist).size(13).color(palette.text).width(Length::Fill),
                    text(format!("{} mins", minutes)).size(12).color(palette.text_muted),
                ]
                .align_y(Alignment::Center)
                .padding([6, 8]),
            )
            .width(Length::Fill)
            .style(move |_t| container::Style {
                background: Some(palette.card_background()),
                border: iced::Border {
                    radius: 12.0.into(),
                    ..Default::default()
                },
                ..Default::default()
            });

            artists_col = artists_col.push(row_item);
        }
    }

    let split_row = row![
        container(tracks_col)
            .padding(16)
            .width(Length::FillPortion(1))
            .style(move |_t| container::Style {
                background: Some(palette.card_background()),
                border: iced::Border {
                    radius: 14.0.into(),
                    color: palette.soft_border(),
                    width: 0.5,
                },
                ..Default::default()
            }),
        Space::with_width(16),
        container(artists_col)
            .padding(16)
            .width(Length::FillPortion(1))
            .style(move |_t| container::Style {
                background: Some(palette.card_background()),
                border: iced::Border {
                    radius: 14.0.into(),
                    color: palette.soft_border(),
                    width: 0.5,
                },
                ..Default::default()
            }),
    ]
    .width(Length::Fill);

    page = page.push(split_row);

    // 6. Top Genres (Pills)
    if !capsule.top_genres.is_empty() {
        let mut genres_sec = column![
            text("Top Genres").size(16).color(palette.text),
            Space::with_height(10),
        ]
        .spacing(8);

        let mut pills_row = row![].spacing(10).align_y(Alignment::Center);
        for (g, count) in &capsule.top_genres {
            let pill = container(
                row![
                    icon(Icon::Music, 12.0, palette.accent),
                    Space::with_width(6),
                    text(g).size(12).color(palette.text),
                    Space::with_width(6),
                    text(format!("({})", count)).size(11).color(palette.text_muted),
                ]
                .align_y(Alignment::Center),
            )
            .padding([6, 12])
            .style(move |_t| container::Style {
                background: Some(palette.surface_variant.into()),
                border: iced::Border {
                    radius: 20.0.into(),
                    color: palette.soft_border(),
                    width: 0.5,
                },
                ..Default::default()
            });

            pills_row = pills_row.push(pill);
        }

        genres_sec = genres_sec.push(pills_row);
        page = page.push(genres_sec);
    }

    container(page).width(Length::Fill).into()
}

fn view_metric_card<'a, Message: 'static>(
    which: Icon,
    title: &'static str,
    value: String,
    subtitle: String,
    palette: HalcyonPalette,
) -> Element<'a, Message> {
    container(
        column![
            row![
                icon(which, 18.0, palette.accent),
                Space::with_width(8),
                text(title).size(12).color(palette.text_muted),
            ]
            .align_y(Alignment::Center),
            Space::with_height(10),
            text(value).size(18).color(palette.text),
            Space::with_height(4),
            text(subtitle).size(11).color(palette.text_muted),
        ]
        .padding(14),
    )
    .width(Length::FillPortion(1))
    .style(move |_t| container::Style {
        background: Some(palette.card_background()),
        border: iced::Border {
            radius: 14.0.into(),
            color: palette.soft_border(),
            width: 0.5,
        },
        ..Default::default()
    })
    .into()
}

fn view_hourly_chart<'a, Message: 'static>(
    hours: &[u32; 24],
    palette: HalcyonPalette,
) -> Element<'a, Message> {
    let max_val = *hours.iter().max().unwrap_or(&1);
    let max_val = max_val.max(1);

    // Peak hour
    let mut peak_hour = 0;
    let mut peak_count = 0;
    for (h, count) in hours.iter().enumerate() {
        if *count > peak_count {
            peak_count = *count;
            peak_hour = h;
        }
    }

    let mut bars_row = row![].spacing(6).align_y(Alignment::End).height(100);

    for (h, count) in hours.iter().enumerate() {
        let fraction = (*count as f32) / (max_val as f32);
        let bar_height = (fraction * 80.0).max(4.0);
        let is_peak = h == peak_hour && peak_count > 0;

        let bar_container = column![
            container(Space::new(Length::Fixed(14.0), Length::Fixed(bar_height)))
                .style(move |_t| container::Style {
                    background: Some(
                        if is_peak {
                            palette.accent
                        } else {
                            palette.surface_variant
                        }
                        .into(),
                    ),
                    border: iced::Border {
                        radius: 3.0.into(),
                        ..Default::default()
                    },
                    ..Default::default()
                }),
            Space::with_height(4),
            text(format!("{:02}", h)).size(9).color(if is_peak {
                palette.accent
            } else {
                palette.text_muted
            }),
        ]
        .align_x(Alignment::Center);

        bars_row = bars_row.push(bar_container);
    }

    let peak_desc = if peak_count > 0 {
        format!("Peak listening window: {:02}:00 - {:02}:59 ({} plays)", peak_hour, peak_hour, peak_count)
    } else {
        "Start listening to build your hourly activity map".to_string()
    };

    container(
        column![
            row![
                text("24-Hour Listening Distribution").size(15).color(palette.text),
                Space::with_width(Length::Fill),
                text(peak_desc).size(12).color(palette.accent),
            ]
            .align_y(Alignment::Center),
            Space::with_height(14),
            bars_row,
        ]
        .padding(16),
    )
    .width(Length::Fill)
    .style(move |_t| container::Style {
        background: Some(palette.card_background()),
        border: iced::Border {
            radius: 14.0.into(),
            color: palette.soft_border(),
            width: 0.5,
        },
        ..Default::default()
    })
    .into()
}
