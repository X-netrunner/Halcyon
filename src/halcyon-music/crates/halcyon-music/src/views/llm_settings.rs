//! Settings card for the optional "Smart suggestions" (LLM) layer.
//!
//! Off by default. When on, a model on this computer (a built-in one, or Ollama) writes a better title and a short
//! reason for each Home mix; it never picks or invents songs. The card says what is sent and
//! shows, in plain words, whether the model can be reached and what to do if it cannot.

use crate::machine::Advice;
use crate::theme::{alpha, radius, space, type_size, HalcyonPalette};
use iced::widget::{column, container, row, text, text_input, Space};
use halcyon_music_core::models::LlmModelInfo;
use iced::{Alignment, Element, Length};

/// What the GUI knows about the connection to the model.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// Off, or no answer yet.
    Unknown,
    Ready,
    Trouble,
}

/// A model download in progress or just ended, as the daemon last reported it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Download {
    pub id: String,
    /// `downloading`, `verifying`, `done`, `cancelled` or `failed`.
    pub state: String,
    pub done: u64,
    pub total: u64,
    pub error: Option<String>,
}

impl Download {
    pub fn running(&self) -> bool {
        matches!(self.state.as_str(), "downloading" | "verifying")
    }
}

/// Everything the card shows.
pub struct Props<'a> {
    pub enabled: bool,
    /// `local` (built-in model) or `ollama`.
    pub backend: &'a str,
    pub ollama_model: &'a str,
    pub local_model: &'a str,
    pub models: &'a [LlmModelInfo],
    /// This daemon was built with the embedded engine.
    pub engine: bool,
    pub download: Option<&'a Download>,
    pub reach: Reach,
    pub hint: Option<&'a str>,
    /// "16 GB memory, 8 CPU threads" (what this computer has).
    pub machine: String,
    /// The suggested setup for that machine.
    pub advice: Advice,
    pub palette: HalcyonPalette,
}

/// What the buttons send.
pub struct Msgs<'a, M> {
    pub toggle: M,
    pub backend: Box<dyn Fn(&'static str) -> M + 'a>,
    pub ollama_model: Box<dyn Fn(String) -> M + 'a>,
    pub ollama_submit: M,
    pub test: M,
    pub pick: Box<dyn Fn(String) -> M + 'a>,
    pub download: Box<dyn Fn(String) -> M + 'a>,
    pub cancel: M,
    pub delete: Box<dyn Fn(String) -> M + 'a>,
    /// Switch to the suggested backend and model.
    pub apply_advice: M,
}

/// "491 MB" or "1.2 GB".
pub fn human_size(bytes: u64) -> String {
    if bytes >= 1_000_000_000 {
        format!("{:.1} GB", bytes as f64 / 1e9)
    } else {
        format!("{} MB", bytes / 1_000_000)
    }
}

/// How far a download is, as a whole percent (0 when the size is unknown).
pub fn percent(done: u64, total: u64) -> u64 {
    done.saturating_mul(100).checked_div(total).map_or(0, |p| p.min(100))
}

fn model_line(info: &LlmModelInfo) -> String {
    let mut s = format!("{} · {}", human_size(info.size_bytes), info.licence);
    match info.verified.as_str() {
        "" => {}
        "size" => s.push_str(" · size checked"),
        _ => s.push_str(" · checksum verified"),
    }
    if !info.installed && info.partial_bytes > 0 {
        s.push_str(&format!(" · {} already downloaded", human_size(info.partial_bytes)));
    }
    s
}

/// Built-in versus Ollama in plain words, then what suits this computer.
fn guide<'a, M: Clone + 'a>(p: &Props<'a>, apply: M) -> Element<'a, M> {
    let palette = p.palette;
    let side = |title: &'static str, good: &'static str, bad: &'static str| -> Element<'a, M> {
        column![
            text(title).size(type_size::BODY).color(palette.text),
            text(good).size(type_size::SMALL).color(palette.accent),
            text(bad).size(type_size::SMALL).color(palette.text_muted),
        ]
        .spacing(4)
        .width(Length::FillPortion(1))
        .into()
    };
    let already = p.advice.backend == p.backend
        && match p.advice.backend {
            "ollama" => p.advice.ollama_model.is_some_and(|m| m == p.ollama_model),
            _ => p.advice.local_model.is_some_and(|m| m == p.local_model),
        };
    let tag: Element<'a, M> = if already {
        text("In use").size(type_size::SMALL).color(palette.accent).into()
    } else {
        super::settings::action("Use this", None, palette, apply)
    };
    let suggestion = row![
        column![
            text(format!("Suggested for this computer ({}): {}", p.machine, p.advice.title)).size(type_size::BODY).color(palette.text),
            text(p.advice.why).size(type_size::SMALL).color(palette.text_muted),
            text("Sizes and hardware only: the models have not been timed on a real machine yet.").size(type_size::SMALL).color(palette.text_muted),
        ]
        .spacing(2)
        .width(Length::Fill),
        Space::with_width(space::MD),
        tag,
    ]
    .align_y(Alignment::Center);
    column![
        row![
            side(
                "Built-in",
                "+ Nothing else to install or keep running. Private: nothing leaves this computer after the one download (0.5 to 0.8 GB).",
                "- Small models (0.5 to 1 billion) write plainer titles. Uses the processor and 1 to 2 GB of memory while it works; the first answer is slower.",
            ),
            Space::with_width(space::LG),
            side(
                "Ollama",
                "+ Bigger models (3 billion and up) with better wording, and a GPU makes them fast. You choose the model.",
                "- Needs Ollama installed and running, more disk and memory, and it is a separate program to update.",
            ),
        ],
        Space::with_height(space::MD),
        suggestion,
    ]
    .into()
}

pub fn view<'a, M: Clone + 'a>(p: Props<'a>, m: Msgs<'a, M>) -> Element<'a, M> {
    let palette = p.palette;
    let local = p.backend != "ollama";
    let selected = p.models.iter().find(|i| i.id == p.local_model);

    let status: Element<'a, M> = if !p.enabled {
        text("Off. Nothing about your music is sent anywhere.").size(type_size::SMALL).color(palette.text_muted).into()
    } else if local && p.download.map(Download::running).unwrap_or(false) {
        let d = p.download.map(|d| format!("{} {}%…", if d.state == "verifying" { "Checking the file" } else { "Downloading" }, percent(d.done, d.total)));
        text(d.unwrap_or_default()).size(type_size::SMALL).color(palette.text_muted).into()
    } else {
        match p.reach {
            Reach::Unknown => text("Checking the connection…").size(type_size::SMALL).color(palette.text_muted).into(),
            Reach::Ready => text("Ready.").size(type_size::SMALL).color(palette.accent).into(),
            Reach::Trouble => text(p.hint.unwrap_or("Could not reach the model."))
                .size(type_size::SMALL)
                .color(palette.danger)
                .into(),
        }
    };

    let size_note = match (local, selected) {
        (true, Some(i)) if !i.installed => format!(
            "A small model on this computer writes a better title and a short reason for each Home mix. Turning this on downloads it once ({}).",
            human_size(i.size_bytes)
        ),
        _ => "A model on this computer writes a better title and a short reason for each Home mix.".to_string(),
    };
    let toggle_row = row![
        column![
            text("Smart suggestions").size(type_size::BODY).color(palette.text),
            text(size_note).size(type_size::SMALL).color(palette.text_muted),
        ]
        .spacing(2)
        .width(Length::Fill),
        Space::with_width(space::MD),
        super::settings::action(if p.enabled { "On" } else { "Off" }, None, palette, m.toggle.clone()),
    ]
    .align_y(Alignment::Center);

    let backend_row = row![
        column![
            text("Runs on").size(type_size::BODY).color(palette.text),
            text(if local { "The built-in model needs no other app." } else { "Your own Ollama server." })
                .size(type_size::SMALL)
                .color(palette.text_muted),
        ]
        .spacing(2),
        Space::with_width(Length::Fill),
        super::settings::action(if local { "Built-in ✓" } else { "Built-in" }, None, palette, (m.backend)("local")),
        Space::with_width(space::SM),
        super::settings::action(if local { "Ollama" } else { "Ollama ✓" }, None, palette, (m.backend)("ollama")),
    ]
    .align_y(Alignment::Center);

    let mut body = column![
        toggle_row,
        Space::with_height(space::LG),
        guide(&p, m.apply_advice.clone()),
        Space::with_height(space::LG),
        backend_row,
        Space::with_height(space::LG)
    ];

    if local {
        if !p.engine {
            body = body.push(
                text("This build has no built-in model engine. Rebuild with --features local-llm, or switch to Ollama.")
                    .size(type_size::SMALL)
                    .color(palette.danger),
            );
            body = body.push(Space::with_height(space::MD));
        }
        for info in p.models {
            let in_use = info.id == p.local_model;
            let busy_here = p.download.map(|d| d.running() && d.id == info.id).unwrap_or(false);
            let mut line = model_line(info);
            if let Some(d) = p.download {
                if d.id == info.id {
                    if d.running() {
                        line = format!("{} · {}%", line, percent(d.done, d.total));
                    } else if let Some(e) = d.error.as_deref().filter(|_| d.state == "failed") {
                        line = e.to_string();
                    }
                }
            }
            let mut buttons = row![].align_y(Alignment::Center).spacing(space::SM);
            if !in_use {
                buttons = buttons.push(super::settings::action("Use", None, palette, (m.pick)(info.id.clone())));
            }
            if busy_here {
                buttons = buttons.push(super::settings::action("Cancel", None, palette, m.cancel.clone()));
            } else if info.installed {
                buttons = buttons.push(super::settings::action("Delete", None, palette, (m.delete)(info.id.clone())));
            } else {
                buttons = buttons.push(super::settings::action("Download", None, palette, (m.download)(info.id.clone())));
            }
            let name = if in_use { format!("{} (in use)", info.name) } else { info.name.clone() };
            body = body.push(
                row![
                    column![
                        text(name).size(type_size::BODY).color(if in_use { palette.accent } else { palette.text }),
                        text(line).size(type_size::SMALL).color(if p.download.map(|d| d.id == info.id && d.state == "failed").unwrap_or(false) { palette.danger } else { palette.text_muted }),
                    ]
                    .spacing(2)
                    .width(Length::Fill),
                    buttons,
                ]
                .align_y(Alignment::Center),
            );
            body = body.push(Space::with_height(space::MD));
        }
    } else {
        let input = text_input("qwen2.5:3b", p.ollama_model)
            .on_input(m.ollama_model)
            .on_submit(m.ollama_submit.clone())
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
        body = body.push(
            row![
                column![
                    text("Model").size(type_size::BODY).color(palette.text),
                    text("Any model you have in Ollama. Press Enter to save.").size(type_size::SMALL).color(palette.text_muted),
                ]
                .spacing(2),
                Space::with_width(Length::Fill),
                input,
            ]
            .align_y(Alignment::Center),
        );
        body = body.push(Space::with_height(space::LG));
    }

    let test_row = row![
        container(status).width(Length::Fill),
        Space::with_width(space::MD),
        super::settings::action("Test connection", None, palette, m.test),
    ]
    .align_y(Alignment::Center);

    let privacy = text(
        "Only a short summary of your taste and the song list of each mix go to the model, never your listening history, and with the \
         built-in model nothing leaves this computer. The model chooses words, not songs. Downloading the model is the only network use.",
    )
    .size(type_size::SMALL)
    .color(palette.text_muted);

    super::settings::card("Smart suggestions", body.push(test_row).push(Space::with_height(space::MD)).push(privacy).into(), palette)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_read_naturally() {
        assert_eq!(human_size(491_000_000), "491 MB");
        assert_eq!(human_size(1_200_000_000), "1.2 GB");
        assert_eq!(human_size(0), "0 MB");
    }

    #[test]
    fn percent_is_safe() {
        assert_eq!(percent(0, 0), 0);
        assert_eq!(percent(50, 200), 25);
        assert_eq!(percent(300, 200), 100);
        assert_eq!(percent(u64::MAX, 1), 100);
    }

    #[test]
    fn model_line_says_how_it_was_checked_and_what_can_resume() {
        let mut i = LlmModelInfo { id: "a".into(), name: "A".into(), size_bytes: 491_000_000, licence: "Apache-2.0".into(), ..Default::default() };
        assert_eq!(model_line(&i), "491 MB · Apache-2.0");
        i.partial_bytes = 100_000_000;
        assert!(model_line(&i).contains("100 MB already downloaded"));
        i.installed = true;
        i.verified = "server".into();
        assert!(model_line(&i).ends_with("checksum verified"));
        i.verified = "size".into();
        assert!(model_line(&i).ends_with("size checked"));
    }

    #[test]
    fn running_states() {
        let d = |s: &str| Download { state: s.into(), ..Default::default() };
        assert!(d("downloading").running() && d("verifying").running());
        assert!(!d("done").running() && !d("failed").running() && !d("cancelled").running());
    }
}
