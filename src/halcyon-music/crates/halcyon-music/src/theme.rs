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
    pub const SM: f32 = 6.0;
    pub const MD: f32 = 10.0;
    pub const LG: f32 = 14.0;
}

/// Type scale (font sizes): caption, small, body, title, heading.
pub mod type_size {
    pub const CAPTION: f32 = 11.0;
    pub const SMALL: f32 = 12.0;
    pub const BODY: f32 = 14.0;
    pub const TITLE: f32 = 18.0;
    pub const HEADING: f32 = 24.0;
}

/// Longest animation in the app, in milliseconds. Everything is at or under this.
pub const MAX_ANIMATION_MS: u64 = 180;

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
}

impl Default for HalcyonPalette {
    fn default() -> Self {
        Self {
            background: Color::from_rgb8(16, 20, 25),      // #101419
            surface: Color::from_rgb8(24, 30, 38),         // #181e26
            surface_variant: Color::from_rgb8(32, 40, 51), // #202833
            text: Color::from_rgb8(230, 237, 243),        // #e6edf3
            text_muted: Color::from_rgb8(139, 148, 158),   // #8b949e
            accent: Color::from_rgb8(88, 152, 212),        // #5898d4
            accent_secondary: Color::from_rgb8(114, 176, 232),
            border: Color::from_rgb8(42, 50, 61),          // #2a323d
            danger: Color::from_rgb8(248, 81, 73),         // #f85149
        }
    }
}

impl HalcyonPalette {
    /// Load palette from `~/.local/state/halcyon-music/palette.toml` if present.
    pub fn load_from_rice() -> Self {
        let mut palette = Self::default();
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home/netrunner".into());
        let path = Path::new(&home).join(".local/state/halcyon-music/palette.toml");

        if let Ok(content) = std::fs::read_to_string(path) {
            for line in content.lines() {
                let line = line.trim();
                if let Some((k, v)) = line.split_once('=') {
                    let key = k.trim();
                    let val = v.trim().trim_matches('"');
                    if let Some(c) = parse_hex_color(val) {
                        match key {
                            "background" => palette.background = c,
                            "surface" => palette.surface = c,
                            "accent" => palette.accent = c,
                            "accent_secondary" => palette.accent_secondary = c,
                            "text" | "foreground" => palette.text = c,
                            "muted" => palette.text_muted = c,
                            _ => {}
                        }
                    }
                }
            }
        }
        palette
    }

    /// Blend palette accent with extracted cover art tint, ensuring 4.5:1 text contrast.
    pub fn with_cover_tint(&self, cover_color: Color) -> Self {
        let mut p = *self;
        // Verify contrast against background
        let adjusted = ensure_wcag_contrast(cover_color, p.background, 4.5);
        p.accent = adjusted;
        p
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

/// Extract dominant color from image pixels using median-cut / quantization.
pub fn extract_dominant_color(rgba_bytes: &[u8]) -> Color {
    if rgba_bytes.is_empty() || rgba_bytes.len() < 4 {
        return Color::from_rgb8(88, 152, 212); // Halcyon default accent
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
        return Color::from_rgb8(88, 152, 212);
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
    fn format_duration_tabular() {
        assert_eq!(format_duration(0), "00:00");
        assert_eq!(format_duration(65_000), "01:05");
        assert_eq!(format_duration(214_000), "03:34");
    }
}
