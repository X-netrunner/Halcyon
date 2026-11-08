//! Settings card for the optional "Smart suggestions" (LLM) layer.
//!
//! Off by default. When on, a model on this computer (Ollama) writes a better title and a short
//! reason for each Home mix; it never picks or invents songs. The card says what is sent and
//! shows, in plain words, whether the model can be reached and what to do if it cannot.

use crate::theme::{alpha, radius, space, type_size, HalcyonPalette};
use iced::widget::{column, container, row, text, text_input, Space};
use iced::{Alignment, Element, Length};

/// What the GUI knows about the connection to the model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// Off, or no answer yet.
    Unknown,
    Ready,
    Trouble,
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, M: Clone + 'a>(
    enabled: bool,
    model: &'a str,
    reach: Reach,
    hint: Option<&'a str>,
    palette: HalcyonPalette,
    on_toggle: M,
    on_model: impl Fn(String) -> M + 'a,
    on_model_submit: M,
    on_test: M,
) -> Element<'a, M> {
    let status: Element<'a, M> = if !enabled {
        text("Off. Nothing about your music is sent anywhere.").size(type_size::SMALL).color(palette.text_muted).into()
    } else {
        match reach {
            Reach::Unknown => text("Checking the connection…").size(type_size::SMALL).color(palette.text_muted).into(),
            Reach::Ready => text("Connected. The model is ready.").size(type_size::SMALL).color(palette.accent).into(),
            Reach::Trouble => text(hint.unwrap_or("Could not reach the model. Is Ollama running?"))
                .size(type_size::SMALL)
                .color(palette.danger)
                .into(),
        }
    };

    let toggle_row = row![
        column![
            text("Smart suggestions").size(type_size::BODY).color(palette.text),
            text("A model on this computer writes a better title and a short reason for each Home mix.")
                .size(type_size::SMALL)
                .color(palette.text_muted),
        ]
        .spacing(2),
        Space::with_width(Length::Fill),
        super::settings::action(if enabled { "On" } else { "Off" }, None, palette, on_toggle),
    ]
    .align_y(Alignment::Center);

    let input = text_input("qwen2.5:3b", model)
        .on_input(on_model)
        .on_submit(on_model_submit)
        .size(type_size::BODY)
        .padding([space::SM, space::MD])
        .width(Length::Fixed(240.0))
        .style(move |_t, status| text_input::Style {
            background: alpha(palette.text, 0.06).into(),
            border: iced::Border {
                radius: radius::MD.into(),
                width: 1.0,
                color: if matches!(status, text_input::Status::Focused) { palette.accent } else { alpha(palette.border, 0.30) },
            },
            icon: palette.text_muted,
            placeholder: palette.text_muted,
            value: palette.text,
            selection: iced::Color { a: 0.3, ..palette.accent },
        });

    let model_row = row![
        column![
            text("Model").size(type_size::BODY).color(palette.text),
            text("Any model you have in Ollama. Press Enter to save.").size(type_size::SMALL).color(palette.text_muted),
        ]
        .spacing(2),
        Space::with_width(Length::Fill),
        input,
    ]
    .align_y(Alignment::Center);

    let test_row = row![
        container(status).width(Length::Fill),
        Space::with_width(space::MD),
        super::settings::action("Test connection", None, palette, on_test),
    ]
    .align_y(Alignment::Center);

    let privacy = text(
        "Only a short summary of your taste and the song list of each mix are sent, never your listening history. \
         The model chooses words, not songs.",
    )
    .size(type_size::SMALL)
    .color(palette.text_muted);

    super::settings::card(
        "Smart suggestions",
        column![toggle_row, Space::with_height(space::LG), model_row, Space::with_height(space::LG), test_row, Space::with_height(space::MD), privacy]
            .into(),
        palette,
    )
}
