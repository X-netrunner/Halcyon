//! Settings card for Spotify Connect: whether Halcyon shows up in the Devices list of the Spotify
//! app on a phone. The daemon owns the setting; this is only a switch and a plain-words status.

use crate::theme::{space, type_size, HalcyonPalette};
use iced::widget::{column, row, text, Space};
use iced::{Alignment, Element, Length};

pub struct Props<'a> {
    /// `false` until the daemon has answered.
    pub known: bool,
    pub enabled: bool,
    /// The daemon build contains the Connect code.
    pub available: bool,
    /// The name Halcyon is registered under right now, if it is.
    pub device: Option<&'a str>,
    pub palette: HalcyonPalette,
}

/// The one line under the switch.
pub fn status_line(p: &Props<'_>) -> String {
    if !p.known {
        "Waiting for the music service…".to_string()
    } else if !p.available {
        "This build has no Connect code. Reinstall with HALCYON_MUSIC_CONNECT=1 ./install.sh --yes to get it.".to_string()
    } else if p.enabled {
        match p.device.map(str::trim).filter(|n| !n.is_empty()) {
            Some(name) => format!("On. Listed in Spotify as \"{name}\"."),
            None => "On. Registering with Spotify… (it can take a few seconds)".to_string(),
        }
    } else {
        "Off. Halcyon plays by itself and does not appear in Spotify's Devices list.".to_string()
    }
}

pub fn view<'a, M: Clone + 'a>(p: Props<'a>, on_toggle: M) -> Element<'a, M> {
    let palette = p.palette;
    let bad = p.known && !p.available;
    let toggle: Element<'a, M> = if p.known && p.available {
        super::settings::action(
            if p.enabled { "On" } else { "Off" },
            None,
            palette,
            on_toggle,
        )
    } else {
        Space::with_width(Length::Shrink).into()
    };
    let body = column![
        row![
            column![
                text("Show Halcyon in Spotify's Devices list").size(type_size::BODY).color(palette.text),
                text(status_line(&p)).size(type_size::SMALL).color(if bad { palette.danger } else { palette.text_muted }),
            ]
            .spacing(2)
            .width(Length::Fill),
            Space::with_width(space::MD),
            toggle,
        ]
        .align_y(Alignment::Center),
        Space::with_height(space::MD),
        text(
            "On: pick Halcyon in the Spotify app on your phone to play here, and the phone's volume and buttons control this computer. \
             Off: the app plays on its own, with one less thing running. Switching restarts the music service, so the song stops for a second or two.",
        )
        .size(type_size::SMALL)
        .color(palette.text_muted),
    ];
    super::settings::card("Spotify Connect", body.into(), palette)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn props(
        known: bool,
        enabled: bool,
        available: bool,
        device: Option<&'static str>,
    ) -> Props<'static> {
        Props {
            known,
            enabled,
            available,
            device,
            palette: HalcyonPalette::default(),
        }
    }

    #[test]
    fn the_status_line_says_what_is_going_on() {
        assert!(status_line(&props(false, false, false, None)).starts_with("Waiting"));
        assert!(status_line(&props(true, true, false, None)).contains("no Connect code"));
        assert_eq!(
            status_line(&props(true, true, true, Some("Halcyon (box)"))),
            "On. Listed in Spotify as \"Halcyon (box)\"."
        );
        assert!(status_line(&props(true, true, true, None)).starts_with("On. Registering"));
        assert!(status_line(&props(true, false, true, Some("Halcyon (box)"))).starts_with("Off."));
    }
}
