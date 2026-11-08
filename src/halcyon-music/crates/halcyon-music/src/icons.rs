//! Embedded SVG icons (Lucide, ISC licence; see assets/icons/LICENSE).
//!
//! Icons are compiled into the binary, so they never depend on a system
//! font. They are tinted at draw time with the colour passed to [`icon`].

use iced::widget::svg::{self, Handle, Svg};
use iced::Color;
use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Icon {
    Album,
    ArrowLeft,
    ChevronLeft,
    ChevronRight,
    Check,
    Close,
    XCircle,
    RowsComfortable,
    RowsCompact,
    Copy,
    Trash,
    Flame,
    Maximize,
    Heart,
    HeartFilled,
    Home,
    Activity,
    Shield,
    Search,
    Lyrics,
    Plus,
    Chart,
    Pause,
    Play,
    Repeat,
    Repeat1,
    Settings,
    Shuffle,
    SkipForward,
    SkipBack,
    Queue,
    Sparkles,
    Volume2,
    Volume1,
    VolumeX,
    Music,
    Artist,
    Clock,
    Playlist,
    Library,
    Minus,
    Square,
    Star,
    StarFilled,
    ExternalLink,
    LogOut,
    Refresh,
}

impl Icon {
    const ALL: &'static [Icon] = &[
        Icon::Album,
        Icon::ArrowLeft,
        Icon::ChevronLeft,
        Icon::ChevronRight,
        Icon::Check,
        Icon::Close,
        Icon::XCircle,
        Icon::RowsComfortable,
        Icon::RowsCompact,
        Icon::Copy,
        Icon::Trash,
        Icon::Flame,
        Icon::Maximize,
        Icon::Heart,
        Icon::HeartFilled,
        Icon::Home,
        Icon::Activity,
        Icon::Shield,
        Icon::Search,
        Icon::Lyrics,
        Icon::Plus,
        Icon::Chart,
        Icon::Pause,
        Icon::Play,
        Icon::Repeat,
        Icon::Repeat1,
        Icon::Settings,
        Icon::Shuffle,
        Icon::SkipForward,
        Icon::SkipBack,
        Icon::Queue,
        Icon::Sparkles,
        Icon::Volume2,
        Icon::Volume1,
        Icon::VolumeX,
        Icon::Music,
        Icon::Artist,
        Icon::Clock,
        Icon::Playlist,
        Icon::Library,
        Icon::Minus,
        Icon::Square,
        Icon::Star,
        Icon::StarFilled,
        Icon::ExternalLink,
        Icon::LogOut,
        Icon::Refresh,
    ];

    fn bytes(self) -> &'static [u8] {
        match self {
            Icon::Album => include_bytes!("../assets/icons/disc-3.svg"),
            Icon::ArrowLeft => include_bytes!("../assets/icons/arrow-left.svg"),
            Icon::ChevronLeft => include_bytes!("../assets/icons/chevron-left.svg"),
            Icon::ChevronRight => include_bytes!("../assets/icons/chevron-right.svg"),
            Icon::Check => include_bytes!("../assets/icons/check.svg"),
            Icon::Close => include_bytes!("../assets/icons/x.svg"),
            Icon::XCircle => include_bytes!("../assets/icons/circle-x.svg"),
            Icon::RowsComfortable => include_bytes!("../assets/icons/rows-2.svg"),
            Icon::RowsCompact => include_bytes!("../assets/icons/rows-4.svg"),
            Icon::Copy => include_bytes!("../assets/icons/copy.svg"),
            Icon::Trash => include_bytes!("../assets/icons/trash-2.svg"),
            Icon::Flame => include_bytes!("../assets/icons/flame.svg"),
            Icon::Maximize => include_bytes!("../assets/icons/maximize-2.svg"),
            Icon::Heart => include_bytes!("../assets/icons/heart.svg"),
            Icon::HeartFilled => include_bytes!("../assets/icons/heart-filled.svg"),
            Icon::Home => include_bytes!("../assets/icons/house.svg"),
            Icon::Activity => include_bytes!("../assets/icons/activity.svg"),
            Icon::Shield => include_bytes!("../assets/icons/shield-check.svg"),
            Icon::Search => include_bytes!("../assets/icons/search.svg"),
            Icon::Lyrics => include_bytes!("../assets/icons/mic-vocal.svg"),
            Icon::Plus => include_bytes!("../assets/icons/plus.svg"),
            Icon::Chart => include_bytes!("../assets/icons/chart-column.svg"),
            Icon::Pause => include_bytes!("../assets/icons/pause.svg"),
            Icon::Play => include_bytes!("../assets/icons/play.svg"),
            Icon::Repeat => include_bytes!("../assets/icons/repeat.svg"),
            Icon::Repeat1 => include_bytes!("../assets/icons/repeat-1.svg"),
            Icon::Settings => include_bytes!("../assets/icons/settings.svg"),
            Icon::Shuffle => include_bytes!("../assets/icons/shuffle.svg"),
            Icon::SkipForward => include_bytes!("../assets/icons/skip-forward.svg"),
            Icon::SkipBack => include_bytes!("../assets/icons/skip-back.svg"),
            Icon::Queue => include_bytes!("../assets/icons/list-ordered.svg"),
            Icon::Sparkles => include_bytes!("../assets/icons/sparkles.svg"),
            Icon::Volume2 => include_bytes!("../assets/icons/volume-2.svg"),
            Icon::Volume1 => include_bytes!("../assets/icons/volume-1.svg"),
            Icon::VolumeX => include_bytes!("../assets/icons/volume-x.svg"),
            Icon::Music => include_bytes!("../assets/icons/music.svg"),
            Icon::Artist => include_bytes!("../assets/icons/user.svg"),
            Icon::Clock => include_bytes!("../assets/icons/clock.svg"),
            Icon::Playlist => include_bytes!("../assets/icons/list-music.svg"),
            Icon::Library => include_bytes!("../assets/icons/library.svg"),
            Icon::Minus => include_bytes!("../assets/icons/minus.svg"),
            Icon::Square => include_bytes!("../assets/icons/square.svg"),
            Icon::Star => include_bytes!("../assets/icons/star.svg"),
            Icon::StarFilled => include_bytes!("../assets/icons/star-filled.svg"),
            Icon::ExternalLink => include_bytes!("../assets/icons/external-link.svg"),
            Icon::LogOut => include_bytes!("../assets/icons/log-out.svg"),
            Icon::Refresh => include_bytes!("../assets/icons/refresh-cw.svg"),
        }
    }
}

fn handles() -> &'static HashMap<Icon, Handle> {
    static HANDLES: OnceLock<HashMap<Icon, Handle>> = OnceLock::new();
    HANDLES.get_or_init(|| {
        Icon::ALL
            .iter()
            .map(|&i| (i, Handle::from_memory(i.bytes())))
            .collect()
    })
}

/// A square icon of `size` logical pixels, tinted with `color`.
pub fn icon<'a>(which: Icon, size: f32, color: Color) -> Svg<'a> {
    let handle = handles()
        .get(&which)
        .cloned()
        .unwrap_or_else(|| Handle::from_memory(which.bytes()));
    Svg::new(handle)
        .width(size)
        .height(size)
        .style(move |_theme, _status| svg::Style { color: Some(color) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_icon_is_a_valid_svg() {
        for &i in Icon::ALL {
            let b = i.bytes();
            let s = std::str::from_utf8(b).unwrap_or("");
            assert!(s.trim_start().starts_with("<svg"), "{i:?} is not an svg");
            assert!(s.contains("</svg>"), "{i:?} is truncated");
        }
    }
}
