//! Design system, typography, density, and cover-tinted palette.
//!
//! Halcyon Music adopts the desktop rice palette from `palette.toml`,
//! dynamically tinted by the current track's album cover art (via median-cut
//! extraction and WCAG 4.5:1 contrast checking).

#![allow(dead_code)]

use iced::Color;
use std::path::Path;

/// Spacing scale (logical pixels). Use these instead of ad-hoc numbers.
pub mod space {
    pub const XS: f32 = 4.0;
    pub const SM: f32 = 8.0;
    pub const MD: f32 = 12.0;
    pub const LG: f32 = 16.0;
    pub const XL: f32 = 24.0;
    pub const XXL: f32 = 32.0;
}

/// Corner radii.
pub mod radius {
    pub const SM: f32 = 12.0;
    pub const MD: f32 = 20.0;
    pub const LG: f32 = 28.0;
    pub const XL: f32 = 36.0;
    pub const PILL: f32 = 999.0;
}

/// Type scale (font sizes): caption, small, body, title, heading.
pub mod type_size {
    pub const CAPTION: f32 = 11.0;
    pub const SMALL: f32 = 12.0;
    pub const BODY: f32 = 14.0;
    pub const TITLE: f32 = 18.0;
    pub const HEADING: f32 = 24.0;
}

/// Longest one-shot animation in the app, in milliseconds. Everything is at or under this.
/// The calm redesign uses slower, softer motion than the old 180 ms snap.
pub const MAX_ANIMATION_MS: u64 = 420;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Density {
    Comfortable,
    Compact,
}

impl Density {
    pub fn row_padding(&self) -> u16 {
        match self {
            Density::Comfortable => 12,
            Density::Compact => 6,
        }
    }

    pub fn row_height(&self) -> f32 {
        match self {
            Density::Comfortable => 48.0,
            Density::Compact => 34.0,
        }
    }

    pub fn body_size(&self) -> f32 {
        match self {
            Density::Comfortable => 14.0,
            Density::Compact => 12.0,
        }
    }

    pub fn heading_size(&self) -> f32 {
        match self {
            Density::Comfortable => 22.0,
            Density::Compact => 18.0,
        }
    }
}

/// A named colour mood. Every mood is a soft, low-contrast-glare palette;
/// the album cover still tints the accent and the background glow on top.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mood {
    /// Follows the desktop: the colours the rice writes to `palette.toml` whenever the
    /// wallpaper or theme changes. Falls back to Dusk when that file is missing.
    Wallpaper,
    /// Warm plum-indigo evening with peach light.
    Dusk,
    /// Cream and rose morning light.
    Dawn,
    /// Deep moss with sage and honey.
    Forest,
    /// Quiet blue-teal night water.
    Ocean,
    /// The whole page is coloured by the song that is playing.
    Song,
    /// Pitch black, with an ambient glow in the colour of the song.
    Ambient,
}

impl Mood {
    pub fn label(&self) -> &'static str {
        match self {
            Mood::Wallpaper => "Wallpaper",
            Mood::Dusk => "Dusk",
            Mood::Dawn => "Dawn",
            Mood::Forest => "Forest",
            Mood::Ocean => "Ocean",
            Mood::Song => "Song colours",
            Mood::Ambient => "Pitch black",
        }
    }

    pub fn next(&self) -> Mood {
        match self {
            Mood::Wallpaper => Mood::Song,
            Mood::Song => Mood::Ambient,
            Mood::Ambient => Mood::Dusk,
            Mood::Dusk => Mood::Dawn,
            Mood::Dawn => Mood::Forest,
            Mood::Forest => Mood::Ocean,
            Mood::Ocean => Mood::Wallpaper,
        }
    }

    pub fn key(&self) -> &'static str {
        match self {
            Mood::Wallpaper => "wallpaper",
            Mood::Dusk => "dusk",
            Mood::Dawn => "dawn",
            Mood::Forest => "forest",
            Mood::Ocean => "ocean",
            Mood::Song => "song",
            Mood::Ambient => "ambient",
        }
    }

    pub fn from_key(key: &str) -> Option<Mood> {
        match key.trim() {
            "wallpaper" => Some(Mood::Wallpaper),
            "dusk" => Some(Mood::Dusk),
            "dawn" => Some(Mood::Dawn),
            "forest" => Some(Mood::Forest),
            "ocean" => Some(Mood::Ocean),
            "song" => Some(Mood::Song),
            "ambient" => Some(Mood::Ambient),
            _ => None,
        }
    }

    fn file() -> std::path::PathBuf {
        let home = std::env::var("HOME").unwrap_or_default();
        Path::new(&home).join(".local/state/halcyon-music/mood")
    }

    /// The mood saved last time. With nothing saved the app follows the wallpaper when the rice
    /// has written its colours, and is Dusk otherwise.
    pub fn load() -> Mood {
        std::fs::read_to_string(Self::file())
            .ok()
            .and_then(|k| Mood::from_key(&k))
            .unwrap_or_else(|| {
                if HalcyonPalette::rice_file().exists() {
                    Mood::Wallpaper
                } else {
                    Mood::Dusk
                }
            })
    }

    /// Remember the mood for next launch. Failure is harmless, so it is ignored.
    pub fn save(&self) {
        let path = Self::file();
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(path, self.key());
    }
}

/// How strongly the playing song's cover colours the palette.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TintMode {
    /// A gentle wash on the accent and glow (the fixed rooms and Wallpaper).
    Soft,
    /// The page itself takes the song's colour (Song colours).
    Deep,
    /// The page stays black; only the glow and accent take the song's colour (Pitch black).
    Ambient,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HalcyonPalette {
    pub background: Color,
    pub surface: Color,
    pub surface_variant: Color,
    pub text: Color,
    pub text_muted: Color,
    pub accent: Color,
    pub accent_secondary: Color,
    pub border: Color,
    pub danger: Color,
    /// Top of the page gradient (a little lighter / warmer than `background`).
    pub bg_top: Color,
    /// Bottom of the page gradient (deepest).
    pub bg_bottom: Color,
    /// Soft light used for glows and gradient highlights.
    pub glow: Color,
    /// How the cover of the playing song tints this palette.
    pub tint: TintMode,
}

impl Default for HalcyonPalette {
    fn default() -> Self {
        Self::for_mood(Mood::Dusk)
    }
}

impl HalcyonPalette {
    /// The built-in palette for a mood.
    pub fn for_mood(mood: Mood) -> Self {
        let mut p = Self::base_for(mood);
        if mood == Mood::Song {
            p.tint = TintMode::Deep;
        }
        p
    }

    fn base_for(mood: Mood) -> Self {
        let c = Color::from_rgb8;
        match mood {
            Mood::Dusk | Mood::Wallpaper | Mood::Song => Self {
                background: c(27, 22, 36),       // #1b1624
                surface: c(38, 31, 50),          // #261f32
                surface_variant: c(52, 43, 68),  // #342b44
                text: c(243, 234, 226),          // #f3eae2 warm cream
                text_muted: c(172, 160, 176),    // #aca0b0
                accent: c(244, 178, 148),        // #f4b294 soft peach
                accent_secondary: c(226, 150, 176), // #e296b0 dusty rose
                border: c(70, 58, 88),
                danger: c(236, 120, 112),
                bg_top: c(44, 33, 58),
                bg_bottom: c(20, 17, 28),
                glow: c(240, 160, 140),
                tint: TintMode::Soft,
            },
            Mood::Ambient => Self {
                background: c(0, 0, 0),
                surface: c(12, 12, 16),
                surface_variant: c(26, 26, 34),
                text: c(238, 240, 246),
                text_muted: c(152, 158, 172),
                accent: c(124, 172, 255),        // ambient blue until a song colours it
                accent_secondary: c(150, 132, 255),
                border: c(38, 40, 52),
                danger: c(240, 120, 116),
                bg_top: c(8, 10, 20),
                bg_bottom: c(0, 0, 0),
                glow: c(90, 140, 255),
                tint: TintMode::Ambient,
            },
            Mood::Dawn => Self {
                background: c(246, 238, 230),    // #f6eee6
                surface: c(255, 250, 244),       // #fffaf4
                surface_variant: c(240, 226, 216),
                text: c(66, 50, 58),             // #42323a
                text_muted: c(110, 90, 98),
                accent: c(168, 72, 90),          // #a8485a deep rose
                accent_secondary: c(196, 112, 76),
                border: c(226, 208, 198),
                danger: c(190, 70, 70),
                bg_top: c(252, 238, 226),
                bg_bottom: c(238, 226, 236),
                glow: c(244, 190, 160),
                tint: TintMode::Soft,
            },
            Mood::Forest => Self {
                background: c(19, 28, 24),       // #131c18
                surface: c(27, 40, 34),
                surface_variant: c(38, 55, 47),
                text: c(232, 238, 226),
                text_muted: c(150, 168, 156),
                accent: c(168, 205, 156),        // #a8cd9c sage
                accent_secondary: c(226, 190, 120), // honey
                border: c(52, 74, 64),
                danger: c(226, 120, 104),
                bg_top: c(30, 46, 38),
                bg_bottom: c(14, 21, 18),
                glow: c(150, 200, 150),
                tint: TintMode::Soft,
            },
            Mood::Ocean => Self {
                background: c(16, 24, 34),       // #101822
                surface: c(24, 36, 49),
                surface_variant: c(34, 50, 66),
                text: c(228, 238, 242),
                text_muted: c(144, 164, 176),
                accent: c(136, 205, 205),        // #88cdcd seafoam
                accent_secondary: c(160, 176, 232), // periwinkle
                border: c(46, 66, 84),
                danger: c(240, 124, 116),
                bg_top: c(26, 44, 60),
                bg_bottom: c(11, 17, 26),
                glow: c(120, 190, 220),
                tint: TintMode::Soft,
            },
        }
    }

    /// Where the rice writes the wallpaper colours.
    pub fn rice_file() -> std::path::PathBuf {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/netrunner".into());
        Path::new(&home).join(".local/state/halcyon-music/palette.toml")
    }

    /// When the rice last rewrote its colours (`None` when there is no file). The app compares
    /// this to notice a wallpaper change without watching the file all the time.
    pub fn rice_file_stamp() -> Option<std::time::SystemTime> {
        std::fs::metadata(Self::rice_file()).and_then(|m| m.modified()).ok()
    }

    /// Load the palette: the saved mood.
    pub fn load_from_rice() -> Self {
        Self::load_for_mood(Mood::load())
    }

    pub fn load_for_mood(mood: Mood) -> Self {
        let base = Self::for_mood(mood);
        if mood != Mood::Wallpaper {
            return base;
        }
        match std::fs::read_to_string(Self::rice_file()) {
            Ok(content) => Self::from_rice_text(&content, base),
            Err(_) => base,
        }
    }

    /// Build a palette from the text of `palette.toml`. Anything missing or unreadable keeps
    /// the value of `base`, so a half-written file can never leave the app unreadable.
    pub fn from_rice_text(content: &str, base: Self) -> Self {
        let mut p = base;
        let mut found_background = false;
        let mut highlight: Option<Color> = None;
        let mut surface: Option<Color> = None;
        let mut glow_hint: Option<Color> = None;
        for line in content.lines() {
            let line = line.trim();
            if let Some((k, v)) = line.split_once('=') {
                let key = k.trim();
                let val = v.trim().trim_matches('"');
                if let Some(c) = parse_hex_color(val) {
                    match key {
                        "background" => {
                            p.background = c;
                            found_background = true;
                        }
                        "surface" => surface = Some(c),
                        "highlight" => highlight = Some(c),
                        "accent" => p.accent = c,
                        "accent_secondary" => p.accent_secondary = c,
                        "text" | "foreground" => p.text = c,
                        "muted" => p.text_muted = c,
                        "red" => p.danger = c,
                        "magenta" => glow_hint = Some(c),
                        _ => {}
                    }
                }
            }
        }
        if !found_background {
            return base;
        }
        let bg = p.background;
        // Panels are the wallpaper's own surface when the rice wrote one, else the background
        // nudged toward the text colour so they still stand off the page.
        let lift = if relative_luminance(bg) > 0.5 { Color::BLACK } else { Color::WHITE };
        p.surface = surface.unwrap_or_else(|| mix(bg, lift, 0.06));
        p.surface_variant = highlight.unwrap_or_else(|| mix(bg, lift, 0.12));
        p.border = mix(p.surface_variant, p.text_muted, 0.35);
        p.glow = mix(p.accent, glow_hint.unwrap_or(p.accent_secondary), 0.35);
        // The page wash is the wallpaper colour itself, lighter at the top and deep at the bottom.
        p.bg_top = mix(bg, p.accent, 0.12);
        p.bg_bottom = mix(bg, Color::BLACK, if relative_luminance(bg) > 0.5 { 0.06 } else { 0.30 });
        // Keep everything readable whatever the wallpaper looks like.
        if contrast_ratio(p.text, bg) < 7.0 {
            p.text = if relative_luminance(bg) > 0.5 { Color::from_rgb8(30, 24, 30) } else { Color::from_rgb8(243, 238, 232) };
        }
        if contrast_ratio(p.text_muted, bg) < 4.5 {
            p.text_muted = mix(p.text, bg, 0.30);
        }
        p.accent = ensure_wcag_contrast(p.accent, bg, 4.5);
        p.accent_secondary = ensure_wcag_contrast(p.accent_secondary, bg, 3.0);
        p
    }

    /// Blend the palette with the colour of the playing song's cover. How far depends on
    /// `tint`: a gentle wash, the whole page, or only the glow over pitch black. Accents always
    /// keep 4.5:1 contrast against the page.
    pub fn with_cover_tint(&self, cover_color: Color) -> Self {
        let mut p = *self;
        match self.tint {
            TintMode::Soft => {
                // Soften the cover colour toward the mood accent so every song still feels like
                // the same calm room, then make sure text in the accent stays readable.
                let softened = mix(cover_color, self.accent, 0.35);
                p.accent = ensure_wcag_contrast(softened, p.background, 4.5);
                // The page gradient and glow breathe in the cover's colour.
                p.glow = mix(self.glow, cover_color, 0.7);
                p.bg_top = mix(self.bg_top, cover_color, 0.16);
                p.bg_bottom = mix(self.bg_bottom, cover_color, 0.05);
            }
            TintMode::Deep => {
                // The song's colour, darkened so text stays readable, floods the page.
                let deep = mix(cover_color, Color::BLACK, 0.40);
                p.background = mix(self.background, deep, 0.35);
                p.surface = mix(self.surface, deep, 0.30);
                p.surface_variant = mix(self.surface_variant, deep, 0.34);
                p.border = mix(self.border, deep, 0.30);
                p.bg_top = mix(self.bg_top, deep, 0.55);
                p.bg_bottom = mix(self.bg_bottom, deep, 0.20);
                p.glow = mix(self.glow, cover_color, 0.85);
                p.accent = ensure_wcag_contrast(mix(cover_color, Color::WHITE, 0.25), p.background, 4.5);
                p.accent_secondary =
                    ensure_wcag_contrast(mix(cover_color, self.accent_secondary, 0.40), p.background, 3.0);
                if contrast_ratio(p.text, p.background) < 7.0 {
                    p.text = Color::from_rgb8(243, 238, 232);
                }
                if contrast_ratio(p.text_muted, p.background) < 4.5 {
                    p.text_muted = mix(p.text, p.background, 0.30);
                }
            }
            TintMode::Ambient => {
                // Black stays black. Only a halo at the top and the accents take the colour.
                p.glow = cover_color;
                p.bg_top = mix(self.bg_top, cover_color, 0.30);
                p.surface = mix(self.surface, cover_color, 0.05);
                p.surface_variant = mix(self.surface_variant, cover_color, 0.08);
                p.border = mix(self.border, cover_color, 0.12);
                p.accent = ensure_wcag_contrast(mix(cover_color, Color::WHITE, 0.15), p.background, 4.5);
                p.accent_secondary =
                    ensure_wcag_contrast(mix(cover_color, self.accent_secondary, 0.45), p.background, 3.0);
            }
        }
        p
    }

    /// Whether the page is a light mood (dark text on a pale page).
    pub fn is_light(&self) -> bool {
        relative_luminance(self.background) > 0.5
    }
}

/// Parse `#RRGGBB` hex string into `iced::Color`.
pub fn parse_hex_color(hex: &str) -> Option<Color> {
    let hex = hex.trim_start_matches('#');
    if hex.len() == 6 {
        let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
        let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
        let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
        Some(Color::from_rgb8(r, g, b))
    } else {
        None
    }
}

/// Format milliseconds as `mm:ss` with tabular formatting.
pub fn format_duration(ms: u64) -> String {
    let total_secs = ms / 1000;
    let mins = total_secs / 60;
    let secs = total_secs % 60;
    format!("{mins:02}:{secs:02}")
}

/// Calculate relative luminance according to WCAG 2.1 specs.
fn relative_luminance(c: Color) -> f32 {
    let to_linear = |v: f32| {
        if v <= 0.03928 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    };
    0.2126 * to_linear(c.r) + 0.7152 * to_linear(c.g) + 0.0722 * to_linear(c.b)
}

/// Contrast ratio between two colors: `(L1 + 0.05) / (L2 + 0.05)`.
pub fn contrast_ratio(c1: Color, c2: Color) -> f32 {
    let l1 = relative_luminance(c1);
    let l2 = relative_luminance(c2);
    let lighter = l1.max(l2);
    let darker = l1.min(l2);
    (lighter + 0.05) / (darker + 0.05)
}

/// Adjust color brightness until it satisfies minimum contrast ratio against target.
pub fn ensure_wcag_contrast(color: Color, background: Color, target_ratio: f32) -> Color {
    let mut adjusted = color;
    let bg_lum = relative_luminance(background);

    // If background is dark (standard Halcyon), brighten accent until ratio is met
    if bg_lum < 0.5 {
        for _ in 0..10 {
            if contrast_ratio(adjusted, background) >= target_ratio {
                break;
            }
            adjusted.r = (adjusted.r * 1.15 + 0.05).min(1.0);
            adjusted.g = (adjusted.g * 1.15 + 0.05).min(1.0);
            adjusted.b = (adjusted.b * 1.15 + 0.05).min(1.0);
        }
    } else {
        for _ in 0..10 {
            if contrast_ratio(adjusted, background) >= target_ratio {
                break;
            }
            adjusted.r *= 0.85;
            adjusted.g *= 0.85;
            adjusted.b *= 0.85;
        }
    }
    adjusted
}

/// Linear blend of two colours: `t = 0` is `a`, `t = 1` is `b`. Alpha is kept from `a`.
pub fn mix(a: Color, b: Color, t: f32) -> Color {
    let t = t.clamp(0.0, 1.0);
    Color {
        r: a.r + (b.r - a.r) * t,
        g: a.g + (b.g - a.g) * t,
        b: a.b + (b.b - a.b) * t,
        a: a.a,
    }
}

/// Same colour with a new alpha.
pub fn alpha(c: Color, a: f32) -> Color {
    Color { a, ..c }
}

/// A two-stop linear gradient background. `vertical = true` runs top to bottom.
/// (If a gradient ever looks flipped on a different iced version, this is the one
/// place to change the angle.)
pub fn gradient2(top_left: Color, bottom_right: Color, vertical: bool) -> iced::Background {
    let angle = if vertical {
        std::f32::consts::FRAC_PI_2
    } else {
        0.0
    };
    let linear = iced::gradient::Linear::new(iced::Radians(angle))
        .add_stop(0.0, top_left)
        .add_stop(1.0, bottom_right);
    iced::Background::Gradient(iced::Gradient::Linear(linear))
}

/// A three-stop diagonal gradient, used for the page background.
pub fn gradient3(a: Color, b: Color, c: Color) -> iced::Background {
    let linear = iced::gradient::Linear::new(iced::Radians(std::f32::consts::FRAC_PI_2 * 0.82))
        .add_stop(0.0, a)
        .add_stop(0.55, b)
        .add_stop(1.0, c);
    iced::Background::Gradient(iced::Gradient::Linear(linear))
}

/// A soft fade edge: `color` covers the content on the side it hides behind and melts to nothing
/// on the other, so scrolling content dissolves instead of being cut by a line. `from_top = true`
/// is opaque at the top. `strength` (0..=1) scales it, so it can vanish when nothing is scrolled
/// under it.
pub fn fade_edge(color: Color, from_top: bool, strength: f32) -> iced::Background {
    let k = strength.clamp(0.0, 1.0);
    let stops = [(0.0, 1.0), (0.55, 0.93), (0.82, 0.45), (1.0, 0.0)];
    let mut linear = iced::gradient::Linear::new(iced::Radians(std::f32::consts::FRAC_PI_2));
    for (offset, a) in stops {
        let (o, a) = if from_top { (offset, a) } else { (1.0 - offset, a) };
        linear = linear.add_stop(o, alpha(color, a * k));
    }
    iced::Background::Gradient(iced::Gradient::Linear(linear))
}

/// Three-stop gradient that runs exactly top to bottom (the page behind everything), so the
/// colour at any height is known and the fades above and below can match it.
pub fn gradient3_vertical(a: Color, b: Color, c: Color) -> iced::Background {
    let linear = iced::gradient::Linear::new(iced::Radians(std::f32::consts::FRAC_PI_2))
        .add_stop(0.0, a)
        .add_stop(0.55, b)
        .add_stop(1.0, c);
    iced::Background::Gradient(iced::Gradient::Linear(linear))
}

impl HalcyonPalette {
    /// The page behind everything: a slow vertical wash from `bg_top` to `bg_bottom`.
    pub fn page_background(&self) -> iced::Background {
        gradient3_vertical(self.bg_top, self.background, self.bg_bottom)
    }

    /// The one surface the sidebar, the title bar and the player bar share. It is the page
    /// colour lifted toward the surface with a little of the wallpaper's glow at the top, so
    /// it reads as a frame around the page and follows the wallpaper like everything else.
    pub fn chrome_background(&self) -> iced::Background {
        gradient2(
            mix(mix(self.background, self.surface, 0.75), self.glow, 0.10),
            mix(self.background, self.surface, 0.55),
            true,
        )
    }

    /// The frame colour `t` of the way down the window (0.0 top, 1.0 bottom). The search notch
    /// is drawn in this colour so it reads as the frame reaching into the page.
    pub fn chrome_at(&self, t: f32) -> Color {
        mix(
            mix(mix(self.background, self.surface, 0.75), self.glow, 0.10),
            mix(self.background, self.surface, 0.55),
            t,
        )
    }

    /// The page colour right under the search strip (what the top fade melts from).
    pub fn page_top_tone(&self) -> Color {
        mix(self.bg_top, self.background, 0.15)
    }

    /// The page colour at its bottom edge (what the bottom fade melts into).
    pub fn page_bottom_tone(&self) -> Color {
        mix(self.background, self.bg_bottom, 0.93)
    }

    /// Frosted card fill: surface with a faint glow at the top.
    pub fn card_background(&self) -> iced::Background {
        gradient2(
            mix(self.surface, self.glow, if self.is_light() { 0.10 } else { 0.07 }),
            self.surface,
            true,
        )
    }

    /// Fill for the accent buttons (play, sign in): accent melting into the secondary colour.
    pub fn accent_background(&self) -> iced::Background {
        gradient2(self.accent, mix(self.accent, self.accent_secondary, 0.85), false)
    }

    /// Text colour that sits on top of the accent fill.
    pub fn on_accent(&self) -> Color {
        if contrast_ratio(self.background, self.accent) >= contrast_ratio(Color::WHITE, self.accent) {
            self.background
        } else {
            Color::WHITE
        }
    }

    /// Hairline border that melts into the surface instead of outlining it.
    pub fn soft_border(&self) -> Color {
        alpha(self.border, 0.55)
    }

    /// A very soft coloured shadow under raised things.
    pub fn glow_shadow(&self, strength: f32, blur: f32) -> iced::Shadow {
        iced::Shadow {
            color: alpha(self.glow, strength),
            offset: iced::Vector::new(0.0, 6.0),
            blur_radius: blur,
        }
    }
}

/// Extract dominant color from image pixels using median-cut / quantization.
pub fn extract_dominant_color(rgba_bytes: &[u8]) -> Color {
    if rgba_bytes.is_empty() || rgba_bytes.len() < 4 {
        return Color::from_rgb8(244, 178, 148); // Halcyon default accent (soft peach)
    }

    // Sample pixels at regular intervals to be near-instantaneous (< 1ms)
    let step = (rgba_bytes.len() / (4 * 128)).max(1) * 4;
    let mut r_sum = 0u64;
    let mut g_sum = 0u64;
    let mut b_sum = 0u64;
    let mut count = 0u64;

    let mut i = 0;
    while i + 3 < rgba_bytes.len() {
        let r = *rgba_bytes.get(i).unwrap_or(&0) as u64;
        let g = *rgba_bytes.get(i + 1).unwrap_or(&0) as u64;
        let b = *rgba_bytes.get(i + 2).unwrap_or(&0) as u64;

        // Skip near-black and near-white pixels for better vibrance
        let max_val = r.max(g).max(b);
        let min_val = r.min(g).min(b);
        if max_val > 40 && min_val < 240 && (max_val - min_val) > 15 {
            r_sum += r;
            g_sum += g;
            b_sum += b;
            count += 1;
        }
        i += step;
    }

    if count == 0 {
        return Color::from_rgb8(244, 178, 148);
    }

    Color::from_rgb8(
        (r_sum / count) as u8,
        (g_sum / count) as u8,
        (b_sum / count) as u8,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wcag_contrast_adjustment_achieves_ratio() {
        let bg = Color::from_rgb8(16, 20, 25);
        let dark_blue = Color::from_rgb8(20, 30, 60); // Low contrast
        let adjusted = ensure_wcag_contrast(dark_blue, bg, 4.5);
        let ratio = contrast_ratio(adjusted, bg);
        assert!(ratio >= 4.5, "Contrast ratio {ratio} should be >= 4.5");
    }

    #[test]
    fn every_mood_keeps_text_readable() {
        for mood in [Mood::Wallpaper, Mood::Song, Mood::Ambient, Mood::Dusk, Mood::Dawn, Mood::Forest, Mood::Ocean] {
            let p = HalcyonPalette::for_mood(mood);
            assert!(contrast_ratio(p.text, p.background) >= 7.0, "{mood:?} text");
            assert!(contrast_ratio(p.text_muted, p.background) >= 4.5, "{mood:?} muted");
            assert!(contrast_ratio(p.accent, p.background) >= 4.5, "{mood:?} accent");
        }
    }

    #[test]
    fn mood_keys_round_trip() {
        for mood in [Mood::Wallpaper, Mood::Song, Mood::Ambient, Mood::Dusk, Mood::Dawn, Mood::Forest, Mood::Ocean] {
            assert_eq!(Mood::from_key(mood.key()), Some(mood));
        }
        assert_eq!(Mood::Dusk.next().next().next().next().next().next().next(), Mood::Dusk);
    }

    #[test]
    fn rice_colours_become_a_readable_palette() {
        let base = HalcyonPalette::for_mood(Mood::Wallpaper);
        let text = "[colors]\nbackground = \"#10202a\"\nforeground = \"#dde9ee\"\naccent = \"#3a6f8a\"\naccent_secondary = \"#c08a50\"\nmuted = \"#33444c\"\n";
        let p = HalcyonPalette::from_rice_text(text, base);
        assert_eq!(p.background, Color::from_rgb8(0x10, 0x20, 0x2a));
        assert!(contrast_ratio(p.text, p.background) >= 7.0);
        assert!(contrast_ratio(p.text_muted, p.background) >= 4.5);
        assert!(contrast_ratio(p.accent, p.background) >= 4.5);
    }

    #[test]
    fn a_rice_file_without_a_background_changes_nothing() {
        let base = HalcyonPalette::for_mood(Mood::Wallpaper);
        let p = HalcyonPalette::from_rice_text("accent = \"#ff0000\"\n", base);
        assert_eq!(p, base);
    }

    #[test]
    fn format_duration_tabular() {
        assert_eq!(format_duration(0), "00:00");
        assert_eq!(format_duration(65_000), "01:05");
        assert_eq!(format_duration(214_000), "03:34");
    }
}
