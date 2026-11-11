//! Geometry of the full-screen visualizers, and the one rule for when the daemon should send
//! audio frames.
//!
//! Everything here is a pure function of the smoothed spectrum (`viz::AudioViz::bands`), a
//! width and a height, so it is unit-tested without a display. `views::viz_canvas` only turns
//! the numbers into iced canvas paths.
//!
//! Nothing is invented: with all bands at zero (paused, no stream, reduced motion) the shapes
//! are their resting shape, a low, calm line that does not move.
//!
//! The mini visualizer (a few quiet capsules in the player) shares `interpolate` and lives at the
//! end of this file with the rules for where it shows and when it needs audio frames.

use crate::layout::VisualizerKind;
use crate::viz::BANDS;
use std::f32::consts::{PI, TAU};

// ----- Spectrum -----------------------------------------------------------------------------

/// Stretch (or squeeze) `bands` to `n` values by linear interpolation. Every output is in
/// 0.0 ..= 1.0, whatever came in; NaN counts as 0.
pub fn interpolate(bands: &[f32], n: usize) -> Vec<f32> {
    if n == 0 {
        return Vec::new();
    }
    let clean = |v: f32| if v.is_finite() { v.clamp(0.0, 1.0) } else { 0.0 };
    match bands.len() {
        0 => vec![0.0; n],
        1 => vec![clean(bands.first().copied().unwrap_or(0.0)); n],
        len => (0..n)
            .map(|i| {
                let t = if n == 1 { 0.5 } else { i as f32 / (n - 1) as f32 };
                let at = t * (len - 1) as f32;
                let lo = (at.floor() as usize).min(len - 1);
                let hi = (lo + 1).min(len - 1);
                let frac = at - lo as f32;
                let a = clean(bands.get(lo).copied().unwrap_or(0.0));
                let b = clean(bands.get(hi).copied().unwrap_or(0.0));
                clean(a + (b - a) * frac)
            })
            .collect(),
    }
}

fn mean(values: &[f32]) -> f32 {
    if values.is_empty() {
        0.0
    } else {
        values.iter().map(|v| if v.is_finite() { *v } else { 0.0 }).sum::<f32>() / values.len() as f32
    }
}

// ----- Aurora -------------------------------------------------------------------------------

/// Three layered waves, back (0) to front (2).
pub const AURORA_LAYERS: usize = 3;
/// A point of a wave every this many pixels (at most; the row is spread evenly).
pub const AURORA_PITCH: f32 = 36.0;
/// Each layer sits this far above the one in front of it.
pub const AURORA_LAYER_OFFSET: f32 = 10.0;
pub const AURORA_FILL_ALPHA: [f32; AURORA_LAYERS] = [0.06, 0.11, 0.16];
pub const AURORA_STROKE_ALPHA: [f32; AURORA_LAYERS] = [0.22, 0.34, 0.46];
pub const AURORA_STROKE_WIDTH: f32 = 2.0;
/// Tallest a layer gets: `38 + 14 * layer` pixels above its baseline.
pub fn aurora_max_height(layer: usize) -> f32 {
    38.0 + 14.0 * layer as f32
}
/// Height of a layer at rest (silence), before its small static swell.
fn aurora_rest_height(layer: usize) -> f32 {
    6.0 + 2.0 * layer as f32
}
/// Which bands drive a layer: low for the front, mid for the back.
fn aurora_band_range(layer: usize) -> (usize, usize) {
    match layer {
        0 => (8, 20),
        1 => (4, 14),
        _ => (0, 8),
    }
}
/// Drift speed: one slow cycle in about 8 seconds (`clock` is in seconds).
pub const AURORA_DRIFT_HZ: f32 = 0.125;

/// How many points a wave of this width has. Two extra points beyond each edge keep the
/// curve's end pieces outside the window.
pub fn aurora_point_count(width: f32) -> usize {
    if !(width.is_finite() && width > 0.0) {
        return 4;
    }
    (width / AURORA_PITCH).ceil() as usize + 3
}

/// The top line of one wave as (x, y) points in a `width` x `height` area. `bands` are the
/// smoothed spectrum, `clock` the animation clock in seconds (0 when motion is reduced: the
/// drift then never moves). Deterministic for the same input. Every y is inside 0 ..= height.
pub fn aurora_points(bands: &[f32; BANDS], layer: usize, width: f32, height: f32, clock: f32) -> Vec<(f32, f32)> {
    let layer = layer.min(AURORA_LAYERS - 1);
    let width = if width.is_finite() { width.max(1.0) } else { 1.0 };
    let height = if height.is_finite() { height.max(1.0) } else { 1.0 };
    let clock = if clock.is_finite() { clock } else { 0.0 };
    let n = aurora_point_count(width);
    let span = width + 2.0 * AURORA_PITCH;
    let step = span / (n - 1) as f32;

    let (lo, hi) = aurora_band_range(layer);
    let slice = bands.get(lo..hi).unwrap_or(&[]);
    let local = interpolate(slice, n);
    let slice_mean = mean(slice).clamp(0.0, 1.0);

    let baseline = height - AURORA_LAYER_OFFSET * (AURORA_LAYERS - 1 - layer) as f32;
    let rest = aurora_rest_height(layer);
    let max = aurora_max_height(layer);
    let phase = clock * AURORA_DRIFT_HZ * TAU;

    (0..n)
        .map(|i| {
            let x = -AURORA_PITCH + step * i as f32;
            let here = local.get(i).copied().unwrap_or(0.0);
            // Half the layer's overall level, half the local band: smooth, never spiky.
            let level = (0.5 * slice_mean + 0.5 * here).clamp(0.0, 1.0).powf(0.85);
            // The resting shape: a small fixed swell, the same every time.
            let swell = 0.8 + 0.4 * (i as f32 * 0.55 + layer as f32 * 1.3).sin();
            // Drift is scaled by the level, so it is gone when the music is.
            let drift = 3.0 * level * (phase + i as f32 * 0.9 + layer as f32 * 1.7).sin();
            let h = (rest * swell + (max - rest) * level + drift).clamp(1.0, max + 4.0);
            (x, (baseline - h).clamp(0.0, height))
        })
        .collect()
}

/// One piece of a path.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Seg {
    Move((f32, f32)),
    Line((f32, f32)),
    Quad { control: (f32, f32), to: (f32, f32) },
}

/// Join `points` with quadratic curves through the midpoints: each point is a control point,
/// each midpoint a place the curve passes. Only the first and last half-span are straight,
/// and the wave's points reach beyond the window so those are never seen.
pub fn smooth_segments(points: &[(f32, f32)]) -> Vec<Seg> {
    let mut out = Vec::with_capacity(points.len());
    let Some(&first) = points.first() else { return out };
    out.push(Seg::Move(first));
    let mid = |a: (f32, f32), b: (f32, f32)| ((a.0 + b.0) / 2.0, (a.1 + b.1) / 2.0);
    if points.len() == 1 {
        return out;
    }
    if let Some(&second) = points.get(1) {
        out.push(Seg::Line(mid(first, second)));
    }
    for w in points.windows(3) {
        if let [_, b, c] = *w {
            out.push(Seg::Quad { control: b, to: mid(b, c) });
        }
    }
    if let Some(&last) = points.last() {
        out.push(Seg::Line(last));
    }
    out
}

// ----- Silk ---------------------------------------------------------------------------------

pub const SILK_BAR_WIDTH: f32 = 6.0;
pub const SILK_PITCH: f32 = 11.0;
/// Free space left and right of the row.
pub const SILK_MARGIN: f32 = 30.0;
/// Even in silence a bar is this tall, so the row reads as a calm line.
pub const SILK_MIN_HEIGHT: f32 = 3.0;
pub const SILK_MIN_ALPHA: f32 = 0.10;
pub const SILK_MAX_ALPHA: f32 = 0.44;
/// Where bars overlap the lyrics they are never more opaque than this.
pub const SILK_LYRICS_ALPHA_CAP: f32 = 0.26;

/// A capsule of the Silk row, centred on the middle line: `x` is its left edge.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SilkBar {
    pub x: f32,
    pub height: f32,
    pub alpha: f32,
}

/// How many capsules fit across `width` between the margins.
pub fn silk_bar_count(width: f32) -> usize {
    if !width.is_finite() {
        return 0;
    }
    let usable = width - 2.0 * SILK_MARGIN;
    if usable < SILK_BAR_WIDTH {
        return 0;
    }
    ((usable - SILK_BAR_WIDTH) / SILK_PITCH).floor() as usize + 1
}

/// The capsules for a `width` wide area. `max_height` is the tallest a bar may get.
/// `lyrics_from_x`: bars at or beyond this x are lyrics' neighbours and are capped in alpha.
/// The row is centred, spread evenly, and fades to the minimum at both ends (an envelope of
/// `sin(position * pi) ^ 0.8`). All zero bands give the resting row: every bar at the
/// minimum height, the same every time.
pub fn silk_bars(bands: &[f32; BANDS], width: f32, max_height: f32, lyrics_from_x: Option<f32>) -> Vec<SilkBar> {
    let count = silk_bar_count(width);
    if count == 0 {
        return Vec::new();
    }
    let max_height = if max_height.is_finite() { max_height.max(SILK_MIN_HEIGHT) } else { SILK_MIN_HEIGHT };
    let levels = interpolate(bands, count);
    let row_width = SILK_BAR_WIDTH + SILK_PITCH * (count - 1) as f32;
    let left = (width - row_width) / 2.0;
    (0..count)
        .map(|k| {
            let pos = if count == 1 { 0.5 } else { k as f32 / (count - 1) as f32 };
            let envelope = (pos * PI).sin().max(0.0).powf(0.8);
            let level = levels.get(k).copied().unwrap_or(0.0);
            let height = (level * envelope * max_height).clamp(SILK_MIN_HEIGHT, max_height);
            let t = ((height - SILK_MIN_HEIGHT) / (max_height - SILK_MIN_HEIGHT).max(1.0)).clamp(0.0, 1.0);
            let mut alpha = SILK_MIN_ALPHA + (SILK_MAX_ALPHA - SILK_MIN_ALPHA) * t;
            let x = left + SILK_PITCH * k as f32;
            if lyrics_from_x.is_some_and(|from| x + SILK_BAR_WIDTH >= from) {
                alpha = alpha.min(SILK_LYRICS_ALPHA_CAP);
            }
            SilkBar { x, height, alpha }
        })
        .collect()
}

// ----- Mini visualizer ----------------------------------------------------------------------

/// Where the mini visualizer sits. Classic never gets one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MiniPlacement {
    /// Full-width bar (Top tabs, Library list): left, right after the song.
    Bar,
    /// Dock pill: between the song and the transport.
    Dock,
    /// Player panel: a strip above the progress bar.
    Panel,
}

impl MiniPlacement {
    /// Width and height of the drawing area.
    pub fn size(&self) -> (f32, f32) {
        match self {
            MiniPlacement::Bar => (44.0, 22.0),
            MiniPlacement::Dock => (34.0, 20.0),
            MiniPlacement::Panel => (150.0, 26.0),
        }
    }
}

/// Below this window width the mini visualizer goes in the bar and dock layouts (the panel's
/// strip is a fixed size and stays).
pub const MINI_HIDE_BELOW_WIDTH: f32 = 1000.0;

/// Whether the mini visualizer is drawn at all right now. It hides when full screen is open
/// (full screen has its own), when there is no track, and, in the bar and dock layouts, below
/// `MINI_HIDE_BELOW_WIDTH`. `placement` is `None` for Classic.
pub fn mini_shown(placement: Option<MiniPlacement>, window_width: f32, has_track: bool, fullscreen_open: bool) -> bool {
    let Some(placement) = placement else { return false };
    if !has_track || fullscreen_open {
        return false;
    }
    match placement {
        MiniPlacement::Panel => true,
        MiniPlacement::Bar | MiniPlacement::Dock => window_width.is_finite() && window_width >= MINI_HIDE_BELOW_WIDTH,
    }
}

/// A window with no area (some platforms report a minimised window this way) is not visible.
pub fn window_is_visible(width: f32, height: f32) -> bool {
    width.is_finite() && height.is_finite() && width >= 1.0 && height >= 1.0
}

pub const MINI_BAR_WIDTH: f32 = 3.0;
pub const MINI_PITCH: f32 = 9.0;
/// Under `MINI_NARROW_BELOW` px of width the bars sit closer together.
pub const MINI_PITCH_NARROW: f32 = 6.0;
pub const MINI_NARROW_BELOW: f32 = 40.0;
/// Even in silence a bar is this tall: a flat, quiet line.
pub const MINI_MIN_HEIGHT: f32 = 1.5;
/// Bars at both ends are this much of the middle ones.
pub const MINI_END_FACTOR: f32 = 0.55;
pub const MINI_MIN_ALPHA: f32 = 0.35;
pub const MINI_MAX_ALPHA: f32 = 0.80;

/// One capsule, centred on the middle line: `x` is its left edge.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MiniBar {
    pub x: f32,
    pub height: f32,
    pub alpha: f32,
}

pub fn mini_pitch(width: f32) -> f32 {
    if width < MINI_NARROW_BELOW {
        MINI_PITCH_NARROW
    } else {
        MINI_PITCH
    }
}

/// Bars that fit: the width divided by the pitch, rounded down.
pub fn mini_bar_count(width: f32) -> usize {
    if !(width.is_finite() && width > 0.0) {
        return 0;
    }
    (width / mini_pitch(width)).floor() as usize
}

/// Tallest a bar gets: `height / 2 - 2`, never below the minimum.
pub fn mini_max_height(area_height: f32) -> f32 {
    if !area_height.is_finite() {
        return MINI_MIN_HEIGHT;
    }
    (area_height / 2.0 - 2.0).max(MINI_MIN_HEIGHT)
}

/// The capsules for a `width` x `height` area. The row is centred. Heights follow the spectrum
/// (stretched to the bar count) and a soft envelope: the ends are `MINI_END_FACTOR` of the
/// middle. All zero bands give a flat line: every bar at the minimum height, the same every
/// time. Colour alpha runs `MINI_MIN_ALPHA` to `MINI_MAX_ALPHA` by height.
pub fn mini_bars(bands: &[f32; BANDS], width: f32, height: f32) -> Vec<MiniBar> {
    let count = mini_bar_count(width);
    if count == 0 {
        return Vec::new();
    }
    let max = mini_max_height(height);
    let pitch = mini_pitch(width);
    let levels = interpolate(bands, count);
    let row_width = MINI_BAR_WIDTH + pitch * (count - 1) as f32;
    let left = (width - row_width) / 2.0;
    (0..count)
        .map(|k| {
            let pos = if count == 1 { 0.5 } else { k as f32 / (count - 1) as f32 };
            let envelope = MINI_END_FACTOR + (1.0 - MINI_END_FACTOR) * (pos * PI).sin().max(0.0);
            let level = levels.get(k).copied().unwrap_or(0.0);
            let h = (MINI_MIN_HEIGHT + (max - MINI_MIN_HEIGHT) * level * envelope).clamp(MINI_MIN_HEIGHT, max);
            let t = ((h - MINI_MIN_HEIGHT) / (max - MINI_MIN_HEIGHT).max(0.001)).clamp(0.0, 1.0);
            MiniBar {
                x: left + pitch * k as f32,
                height: h,
                alpha: MINI_MIN_ALPHA + (MINI_MAX_ALPHA - MINI_MIN_ALPHA) * t,
            }
        })
        .collect()
}

// ----- Audio stream ownership ---------------------------------------------------------------

/// Everything that can want the daemon's live audio frames.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StreamWants {
    /// The queue drawer's cover pulses on the beat while it is open.
    pub queue_drawer_open: bool,
    pub fullscreen_open: bool,
    /// Full-screen with `None` draws no visualizer, so it needs no frames.
    pub fullscreen_visualizer: VisualizerKind,
    /// The Settings switch for the mini visualizer.
    pub mini_on: bool,
    /// `mini_shown` is true: a layout with a place for it, a track, wide enough.
    pub mini_shown: bool,
    /// A track is playing (not paused).
    pub playing: bool,
    /// The window has an area (see `window_is_visible`).
    pub window_visible: bool,
    /// Motion is allowed (not reduced by the person or by GTK). With reduced motion the mini
    /// visualizer draws its flat line once, so it needs no frames.
    pub motion_allowed: bool,
}

impl StreamWants {
    /// Nothing wants frames.
    #[cfg(test)]
    pub const NONE: StreamWants = StreamWants {
        queue_drawer_open: false,
        fullscreen_open: false,
        fullscreen_visualizer: VisualizerKind::None,
        mini_on: false,
        mini_shown: false,
        playing: false,
        window_visible: true,
        motion_allowed: true,
    };

    /// The mini visualizer alone needs frames: it is On, drawn, a track is playing, the window
    /// is visible, motion is allowed and full screen is not open (full screen has its own).
    pub fn mini_wants(&self) -> bool {
        self.mini_on
            && self.mini_shown
            && self.playing
            && self.window_visible
            && self.motion_allowed
            && !self.fullscreen_open
    }
}

/// True when any consumer needs the daemon to send audio frames. Turning one consumer off
/// must not stop the others, so this is an OR over all of them and nothing else decides.
pub fn audio_stream_wanted(wants: &StreamWants) -> bool {
    wants.queue_drawer_open
        || (wants.fullscreen_open && wants.fullscreen_visualizer != VisualizerKind::None)
        || wants.mini_wants()
}

/// `Some(on)` only when the daemon has to be told something: the wanted value differs from
/// what was last sent.
pub fn stream_change(sent: bool, wanted: bool) -> Option<bool> {
    (sent != wanted).then_some(wanted)
}

/// What can need the 30 fps redraw clock while music plays.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AmbientNeeds {
    /// A track is playing (not paused).
    pub playing: bool,
    /// Motion is allowed (not reduced by the person or by GTK).
    pub motion_allowed: bool,
    /// The window has an area (see `window_is_visible`).
    pub window_visible: bool,
    /// Full screen is open (its visualizer and glow move with the clock).
    pub fullscreen_open: bool,
    /// The queue drawer is open (its cover pulses on the beat).
    pub queue_open: bool,
    /// The mini visualizer is drawn right now (`mini_shown` and the switch On).
    pub mini_drawn: bool,
    /// Classic's sidebar rail is on screen: its little equaliser bars run off the clock.
    pub classic_sidebar_bars: bool,
}

/// Whether to keep the 30 fps redraw clock running while music plays. Every other screen idles
/// at about 0 percent CPU: a Settings or Library page in the four new layouts, with the mini
/// visualizer Off, needs no redraws just because a song is playing (the progress bar moves with
/// the daemon's position events, not with this clock).
pub fn ambient_tick_wanted(n: &AmbientNeeds) -> bool {
    n.playing
        && n.motion_allowed
        && n.window_visible
        && (n.fullscreen_open || n.queue_open || n.mini_drawn || n.classic_sidebar_bars)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ZERO: [f32; BANDS] = [0.0; BANDS];
    const FULL: [f32; BANDS] = [1.0; BANDS];

    fn ramp() -> [f32; BANDS] {
        let mut b = [0.0; BANDS];
        for (i, v) in b.iter_mut().enumerate() {
            *v = i as f32 / (BANDS - 1) as f32;
        }
        b
    }

    // ----- interpolate -----

    #[test]
    fn interpolation_stays_inside_zero_to_one() {
        for n in [1, 2, 7, 24, 25, 90, 400] {
            for src in [ZERO, FULL, ramp()] {
                let out = interpolate(&src, n);
                assert_eq!(out.len(), n);
                assert!(out.iter().all(|v| (0.0..=1.0).contains(v)), "n={n}");
            }
        }
        let wild = interpolate(&[f32::NAN, 7.0, -3.0, f32::INFINITY], 9);
        assert!(wild.iter().all(|v| (0.0..=1.0).contains(v)));
        assert!(interpolate(&ZERO, 0).is_empty());
        assert_eq!(interpolate(&[], 3), vec![0.0; 3]);
    }

    #[test]
    fn interpolation_keeps_the_ends_and_the_order() {
        let out = interpolate(&ramp(), 50);
        assert_eq!(out.first().copied(), Some(0.0));
        assert!((out.last().copied().unwrap_or(0.0) - 1.0).abs() < 1e-5);
        assert!(out.windows(2).all(|w| w[0] <= w[1] + 1e-6), "a rising ramp stays rising");
    }

    // ----- Aurora -----

    #[test]
    fn aurora_has_the_expected_points_inside_the_bounds() {
        for (w, h) in [(960.0, 600.0), (1440.0, 900.0), (300.0, 200.0), (1.0, 1.0)] {
            for layer in 0..AURORA_LAYERS {
                for bands in [ZERO, FULL, ramp()] {
                    let pts = aurora_points(&bands, layer, w, h, 12.3);
                    assert_eq!(pts.len(), aurora_point_count(w));
                    assert!(pts.iter().all(|&(x, y)| x.is_finite() && y.is_finite() && (0.0..=h).contains(&y)));
                    // Spread evenly, never wider apart than the pitch, reaching past both edges.
                    assert!(pts.windows(2).all(|p| p[1].0 - p[0].0 <= AURORA_PITCH + 1e-3));
                    assert!(pts.first().map(|p| p.0).unwrap_or(1.0) < 0.0);
                    assert!(pts.last().map(|p| p.0).unwrap_or(0.0) > w);
                }
            }
        }
    }

    #[test]
    fn aurora_is_deterministic() {
        let a = aurora_points(&ramp(), 1, 960.0, 600.0, 3.5);
        let b = aurora_points(&ramp(), 1, 960.0, 600.0, 3.5);
        assert_eq!(a, b);
    }

    #[test]
    fn aurora_rests_low_with_zero_bands_and_does_not_drift() {
        for layer in 0..AURORA_LAYERS {
            let a = aurora_points(&ZERO, layer, 960.0, 600.0, 0.0);
            let b = aurora_points(&ZERO, layer, 960.0, 600.0, 55.0);
            assert_eq!(a, b, "silence must not move with the clock");
            let baseline = 600.0 - AURORA_LAYER_OFFSET * (AURORA_LAYERS - 1 - layer) as f32;
            let tallest = a.iter().map(|p| baseline - p.1).fold(0.0_f32, f32::max);
            assert!(tallest < aurora_max_height(layer) * 0.5, "layer {layer} rests at {tallest}");
            assert!(tallest > 1.0, "the resting shape is a soft line, not nothing");
        }
    }

    #[test]
    fn aurora_rises_with_the_music_and_the_front_follows_the_low_bands() {
        // Only the low bands are loud: the front layer (low bands) rises, the back one does not.
        let mut low = ZERO;
        for v in low.iter_mut().take(8) {
            *v = 1.0;
        }
        let top = |bands: &[f32; BANDS], layer: usize| {
            let baseline = 600.0 - AURORA_LAYER_OFFSET * (AURORA_LAYERS - 1 - layer) as f32;
            aurora_points(bands, layer, 960.0, 600.0, 0.0).iter().map(|p| baseline - p.1).fold(0.0_f32, f32::max)
        };
        assert!(top(&low, 2) > top(&ZERO, 2) + 10.0);
        assert!(top(&low, 0) < top(&FULL, 0));
        assert!(top(&FULL, 2) <= aurora_max_height(2) + 4.0 + 1e-3);
    }

    #[test]
    fn aurora_layers_are_offset_from_each_other() {
        let base = |layer: usize| 600.0 - AURORA_LAYER_OFFSET * (AURORA_LAYERS - 1 - layer) as f32;
        assert_eq!(base(2) - base(1), AURORA_LAYER_OFFSET);
        assert_eq!(base(1) - base(0), AURORA_LAYER_OFFSET);
    }

    #[test]
    fn aurora_survives_nonsense_sizes() {
        for (w, h, c) in [(f32::NAN, 100.0, 0.0), (0.0, 0.0, f32::NAN), (-5.0, -5.0, 1.0), (f32::INFINITY, 50.0, 2.0)] {
            let pts = aurora_points(&FULL, 2, w, h, c);
            assert!(pts.iter().all(|&(x, y)| x.is_finite() && y.is_finite()));
        }
    }

    #[test]
    fn smooth_segments_curve_through_the_midpoints() {
        let pts = [(0.0, 0.0), (10.0, 10.0), (20.0, 0.0), (30.0, 10.0)];
        let segs = smooth_segments(&pts);
        assert_eq!(segs.first(), Some(&Seg::Move((0.0, 0.0))));
        let quads = segs.iter().filter(|s| matches!(s, Seg::Quad { .. })).count();
        assert_eq!(quads, pts.len() - 2, "one curve per inner point");
        assert!(segs.contains(&Seg::Quad { control: (10.0, 10.0), to: (15.0, 5.0) }));
        assert_eq!(segs.last(), Some(&Seg::Line((30.0, 10.0))));
        // Only the two end pieces are straight.
        assert_eq!(segs.iter().filter(|s| matches!(s, Seg::Line(_))).count(), 2);
        assert!(smooth_segments(&[]).is_empty());
        assert_eq!(smooth_segments(&[(1.0, 2.0)]), vec![Seg::Move((1.0, 2.0))]);
    }

    // ----- Silk -----

    #[test]
    fn silk_bar_count_follows_width_and_margins() {
        assert_eq!(silk_bar_count(0.0), 0);
        assert_eq!(silk_bar_count(2.0 * SILK_MARGIN + SILK_BAR_WIDTH - 0.1), 0);
        assert_eq!(silk_bar_count(2.0 * SILK_MARGIN + SILK_BAR_WIDTH), 1);
        assert_eq!(silk_bar_count(f32::NAN), 0);
        // 960 wide: (960 - 60 - 6) / 11 = 81.27 -> 81 gaps -> 82 bars.
        assert_eq!(silk_bar_count(960.0), 82);
    }

    #[test]
    fn silk_row_is_centred_and_inside_the_margins() {
        for w in [400.0, 960.0, 1440.0, 1921.0] {
            let bars = silk_bars(&FULL, w, 120.0, None);
            let first = bars.first().map(|b| b.x).unwrap_or(0.0);
            let last = bars.last().map(|b| b.x + SILK_BAR_WIDTH).unwrap_or(w);
            assert!(first >= SILK_MARGIN - 1e-3, "w={w} first={first}");
            assert!(last <= w - SILK_MARGIN + 1e-3, "w={w} last={last}");
            assert!(((first) - (w - last)).abs() < 1e-3, "centred: left gap {first}, right gap {}", w - last);
        }
    }

    #[test]
    fn silk_heights_and_alpha_stay_in_range_and_never_nan() {
        for bands in [ZERO, FULL, ramp()] {
            for max in [3.0, 60.0, 200.0, f32::NAN] {
                for b in silk_bars(&bands, 960.0, max, Some(480.0)) {
                    assert!(b.height.is_finite() && b.height >= SILK_MIN_HEIGHT);
                    assert!(b.alpha.is_finite() && b.alpha >= SILK_MIN_ALPHA && b.alpha <= SILK_MAX_ALPHA);
                }
            }
        }
    }

    #[test]
    fn silk_fades_at_both_ends_and_is_full_in_the_middle() {
        let bars = silk_bars(&FULL, 960.0, 120.0, None);
        let n = bars.len();
        let mid = bars.get(n / 2).map(|b| b.height).unwrap_or(0.0);
        let end_a = bars.first().map(|b| b.height).unwrap_or(f32::MAX);
        let end_b = bars.last().map(|b| b.height).unwrap_or(f32::MAX);
        assert!(mid > 110.0, "middle {mid}");
        assert!(end_a <= SILK_MIN_HEIGHT + 1e-3 && end_b <= SILK_MIN_HEIGHT + 1e-3);
        // Rises toward the middle from either side.
        let quarter = bars.get(n / 4).map(|b| b.height).unwrap_or(0.0);
        assert!(end_a < quarter && quarter < mid);
    }

    #[test]
    fn silk_rests_as_a_calm_line_and_is_deterministic() {
        let a = silk_bars(&ZERO, 960.0, 120.0, Some(480.0));
        let b = silk_bars(&ZERO, 960.0, 120.0, Some(480.0));
        assert_eq!(a, b);
        assert!(a.iter().all(|bar| (bar.height - SILK_MIN_HEIGHT).abs() < 1e-3));
        assert!(a.iter().all(|bar| bar.alpha <= SILK_MIN_ALPHA + 1e-3 || bar.alpha <= SILK_LYRICS_ALPHA_CAP));
    }

    #[test]
    fn silk_alpha_is_capped_where_it_meets_the_lyrics() {
        let open = silk_bars(&FULL, 960.0, 120.0, None);
        let capped = silk_bars(&FULL, 960.0, 120.0, Some(480.0));
        let loudest = |bars: &[SilkBar]| bars.iter().map(|b| b.alpha).fold(0.0_f32, f32::max);
        assert!(loudest(&open) > SILK_LYRICS_ALPHA_CAP, "the open row reaches {}", loudest(&open));
        for (o, c) in open.iter().zip(&capped) {
            assert_eq!(o.height, c.height, "the cap changes colour only, never height");
            if c.x + SILK_BAR_WIDTH >= 480.0 {
                assert!(c.alpha <= SILK_LYRICS_ALPHA_CAP + 1e-6);
            } else {
                assert_eq!(c.alpha, o.alpha);
            }
        }
    }

    // ----- Audio stream ownership -----

    #[test]
    fn the_stream_is_off_when_nothing_wants_it() {
        assert!(!audio_stream_wanted(&StreamWants::NONE));
        // Full-screen open with the visualizer Off wants nothing.
        let w = StreamWants { fullscreen_open: true, ..StreamWants::NONE };
        assert!(!audio_stream_wanted(&w));
    }

    #[test]
    fn each_consumer_alone_turns_it_on() {
        let drawer = StreamWants { queue_drawer_open: true, ..StreamWants::NONE };
        assert!(audio_stream_wanted(&drawer));
        for kind in [VisualizerKind::Aurora, VisualizerKind::Silk] {
            let full = StreamWants { fullscreen_open: true, fullscreen_visualizer: kind, ..StreamWants::NONE };
            assert!(audio_stream_wanted(&full), "{kind:?}");
        }
        // A visualizer chosen but full-screen closed does not want it.
        let closed = StreamWants { fullscreen_visualizer: VisualizerKind::Aurora, ..StreamWants::NONE };
        assert!(!audio_stream_wanted(&closed));
    }

    #[test]
    fn one_consumer_stopping_does_not_stop_the_other() {
        let both = StreamWants {
            queue_drawer_open: true,
            fullscreen_open: true,
            fullscreen_visualizer: VisualizerKind::Silk,
            ..StreamWants::NONE
        };
        assert!(audio_stream_wanted(&both));
        let drawer_closed = StreamWants { queue_drawer_open: false, ..both };
        assert!(audio_stream_wanted(&drawer_closed), "full-screen still wants it");
        let full_closed = StreamWants { fullscreen_open: false, ..both };
        assert!(audio_stream_wanted(&full_closed), "the drawer still wants it");
        let neither = StreamWants { queue_drawer_open: false, fullscreen_open: false, ..both };
        assert!(!audio_stream_wanted(&neither));
    }

    #[test]
    fn the_command_is_sent_only_when_the_value_changes() {
        assert_eq!(stream_change(false, false), None);
        assert_eq!(stream_change(true, true), None);
        assert_eq!(stream_change(false, true), Some(true));
        assert_eq!(stream_change(true, false), Some(false));
        // Walk a session: drawer on, full-screen on, drawer off, full-screen off.
        let steps = [
            (StreamWants { queue_drawer_open: true, ..StreamWants::NONE }, Some(true)),
            (
                StreamWants {
                    queue_drawer_open: true,
                    fullscreen_open: true,
                    fullscreen_visualizer: VisualizerKind::Aurora,
                    ..StreamWants::NONE
                },
                None,
            ),
            (
                StreamWants {
                    fullscreen_open: true,
                    fullscreen_visualizer: VisualizerKind::Aurora,
                    ..StreamWants::NONE
                },
                None,
            ),
            (StreamWants::NONE, Some(false)),
        ];
        let mut sent = false;
        for (wants, expect) in steps {
            let change = stream_change(sent, audio_stream_wanted(&wants));
            assert_eq!(change, expect, "{wants:?}");
            if let Some(on) = change {
                sent = on;
            }
        }
        assert!(!sent);
    }

    // ----- Mini visualizer: geometry -----

    #[test]
    fn mini_bar_count_is_the_width_over_the_pitch() {
        // 44 px: not under 40, so the 9 px pitch: 4 bars. 34 px: narrow, 6 px pitch: 5 bars.
        assert_eq!(mini_bar_count(44.0), 4);
        assert_eq!(mini_bar_count(34.0), 5);
        // 150 px / 9 = 16.67 -> 16.
        assert_eq!(mini_bar_count(150.0), 16);
        assert_eq!(mini_bar_count(0.0), 0);
        assert_eq!(mini_bar_count(-4.0), 0);
        assert_eq!(mini_bar_count(f32::NAN), 0);
        assert_eq!(mini_pitch(39.9), MINI_PITCH_NARROW);
        assert_eq!(mini_pitch(40.0), MINI_PITCH);
        // The sizes in the plan give those counts.
        for (placement, count) in [(MiniPlacement::Bar, 4), (MiniPlacement::Dock, 5), (MiniPlacement::Panel, 16)] {
            assert_eq!(mini_bar_count(placement.size().0), count, "{placement:?}");
        }
    }

    #[test]
    fn mini_heights_stay_between_the_minimum_and_the_maximum() {
        for placement in [MiniPlacement::Bar, MiniPlacement::Dock, MiniPlacement::Panel] {
            let (w, h) = placement.size();
            let max = mini_max_height(h);
            assert_eq!(max, h / 2.0 - 2.0);
            for bands in [ZERO, FULL, ramp()] {
                for bar in mini_bars(&bands, w, h) {
                    assert!(bar.height.is_finite() && bar.height >= MINI_MIN_HEIGHT - 1e-4, "{placement:?}");
                    assert!(bar.height <= max + 1e-4, "{placement:?}: {} > {max}", bar.height);
                    assert!(bar.alpha >= MINI_MIN_ALPHA - 1e-4 && bar.alpha <= MINI_MAX_ALPHA + 1e-4);
                }
            }
        }
        // A tiny area never goes below the minimum.
        assert_eq!(mini_max_height(0.0), MINI_MIN_HEIGHT);
        assert_eq!(mini_max_height(f32::NAN), MINI_MIN_HEIGHT);
    }

    #[test]
    fn mini_bars_are_lower_at_the_ends_than_in_the_middle() {
        let bars = mini_bars(&FULL, 150.0, 26.0);
        let n = bars.len();
        let mid = bars.get(n / 2).map(|b| b.height).unwrap_or(0.0);
        let first = bars.first().map(|b| b.height).unwrap_or(f32::MAX);
        let last = bars.last().map(|b| b.height).unwrap_or(f32::MAX);
        assert!(first < mid && last < mid, "ends {first}/{last}, middle {mid}");
        // About 55 percent of the middle (heights above the minimum scale with the envelope).
        let max = mini_max_height(26.0);
        let share = (first - MINI_MIN_HEIGHT) / (max - MINI_MIN_HEIGHT);
        assert!((share - MINI_END_FACTOR).abs() < 0.03, "end share {share}");
    }

    #[test]
    fn mini_bars_with_zero_bands_are_a_flat_line_and_the_same_every_time() {
        for placement in [MiniPlacement::Bar, MiniPlacement::Dock, MiniPlacement::Panel] {
            let (w, h) = placement.size();
            let a = mini_bars(&ZERO, w, h);
            assert_eq!(a, mini_bars(&ZERO, w, h));
            assert!(!a.is_empty());
            assert!(a.iter().all(|b| (b.height - MINI_MIN_HEIGHT).abs() < 1e-4));
            assert!(a.iter().all(|b| (b.alpha - MINI_MIN_ALPHA).abs() < 1e-4));
        }
    }

    #[test]
    fn mini_row_is_centred_and_inside_the_area() {
        for placement in [MiniPlacement::Bar, MiniPlacement::Dock, MiniPlacement::Panel] {
            let (w, h) = placement.size();
            let bars = mini_bars(&FULL, w, h);
            let first = bars.first().map(|b| b.x).unwrap_or(-1.0);
            let last = bars.last().map(|b| b.x + MINI_BAR_WIDTH).unwrap_or(w + 1.0);
            assert!(first >= -1e-3 && last <= w + 1e-3, "{placement:?}: {first}..{last} of {w}");
            assert!((first - (w - last)).abs() < 1e-3, "{placement:?} is not centred");
        }
    }

    #[test]
    fn mini_bars_never_produce_nan() {
        let wild = [f32::NAN; BANDS];
        for (w, h) in [(44.0, 22.0), (0.0, 0.0), (f32::NAN, f32::NAN), (-3.0, 5.0), (f32::INFINITY, 20.0), (150.0, 1.0)] {
            for bands in [ZERO, FULL, wild] {
                for bar in mini_bars(&bands, w, h) {
                    assert!(bar.x.is_finite() && bar.height.is_finite() && bar.alpha.is_finite());
                }
            }
        }
    }

    #[test]
    fn mini_bars_follow_the_music() {
        let quiet = mini_bars(&ZERO, 150.0, 26.0);
        let loud = mini_bars(&FULL, 150.0, 26.0);
        assert!(loud.iter().zip(&quiet).all(|(l, q)| l.height > q.height));
        assert_eq!(mini_bars(&ramp(), 150.0, 26.0), mini_bars(&ramp(), 150.0, 26.0));
    }

    // ----- Mini visualizer: where it shows -----

    #[test]
    fn mini_hides_without_a_place_a_track_or_when_full_screen_is_open() {
        for p in [MiniPlacement::Bar, MiniPlacement::Dock, MiniPlacement::Panel] {
            assert!(mini_shown(Some(p), 1400.0, true, false), "{p:?}");
            assert!(!mini_shown(Some(p), 1400.0, false, false), "{p:?}: no track");
            assert!(!mini_shown(Some(p), 1400.0, true, true), "{p:?}: full screen");
        }
        // Classic has no place for it.
        assert!(!mini_shown(None, 1400.0, true, false));
    }

    #[test]
    fn mini_hides_below_1000_in_the_bar_and_dock_but_not_in_the_panel() {
        for p in [MiniPlacement::Bar, MiniPlacement::Dock] {
            assert!(!mini_shown(Some(p), 999.9, true, false), "{p:?}");
            assert!(mini_shown(Some(p), 1000.0, true, false), "{p:?}");
            assert!(!mini_shown(Some(p), f32::NAN, true, false), "{p:?}");
        }
        assert!(mini_shown(Some(MiniPlacement::Panel), 960.0, true, false));
    }

    #[test]
    fn a_window_without_area_is_not_visible() {
        assert!(window_is_visible(960.0, 600.0));
        assert!(!window_is_visible(0.0, 0.0));
        assert!(!window_is_visible(960.0, 0.0));
        assert!(!window_is_visible(f32::NAN, 600.0));
    }

    // ----- Mini visualizer: audio stream -----

    fn mini_running() -> StreamWants {
        StreamWants { mini_on: true, mini_shown: true, playing: true, ..StreamWants::NONE }
    }

    #[test]
    fn the_mini_visualizer_alone_turns_the_stream_on() {
        assert!(audio_stream_wanted(&mini_running()));
    }

    #[test]
    fn the_mini_visualizer_wants_nothing_unless_every_condition_holds() {
        let w = mini_running();
        assert!(!audio_stream_wanted(&StreamWants { mini_on: false, ..w }), "switch Off");
        assert!(!audio_stream_wanted(&StreamWants { mini_shown: false, ..w }), "hidden");
        assert!(!audio_stream_wanted(&StreamWants { playing: false, ..w }), "paused");
        assert!(!audio_stream_wanted(&StreamWants { window_visible: false, ..w }), "window not visible");
        assert!(!audio_stream_wanted(&StreamWants { motion_allowed: false, ..w }), "motion reduced");
        // Full screen with the visualizer Off: the mini one must not keep the stream alive.
        assert!(!audio_stream_wanted(&StreamWants {
            fullscreen_open: true,
            fullscreen_visualizer: VisualizerKind::None,
            ..w
        }));
    }

    #[test]
    fn the_mini_visualizer_hands_over_to_full_screen_and_takes_it_back() {
        let w = mini_running();
        let full = StreamWants { fullscreen_open: true, fullscreen_visualizer: VisualizerKind::Aurora, ..w };
        assert!(audio_stream_wanted(&full), "full screen wants it for itself");
        assert!(!full.mini_wants(), "and the mini one does not count while it is open");
        // Leaving full screen: the mini one still wants it, so the stream stays on.
        let back = StreamWants { fullscreen_open: false, ..full };
        assert!(audio_stream_wanted(&back));
    }

    #[test]
    fn the_mini_visualizer_stopping_does_not_stop_the_queue_drawer() {
        let both = StreamWants { queue_drawer_open: true, ..mini_running() };
        assert!(audio_stream_wanted(&both));
        assert!(audio_stream_wanted(&StreamWants { mini_on: false, ..both }), "the drawer keeps it");
        assert!(audio_stream_wanted(&StreamWants { playing: false, ..both }), "the drawer keeps it");
        // And the drawer closing leaves the mini one running.
        assert!(audio_stream_wanted(&StreamWants { queue_drawer_open: false, ..both }));
        assert!(!audio_stream_wanted(&StreamWants { queue_drawer_open: false, mini_on: false, ..both }));
    }

    #[test]
    fn a_session_with_the_mini_visualizer_sends_the_command_only_on_changes() {
        let play = mini_running();
        let steps = [
            (StreamWants::NONE, None),                                   // nothing yet
            (play, Some(true)),                                          // mini on, playing
            (StreamWants { queue_drawer_open: true, ..play }, None),     // drawer joins
            (StreamWants { playing: false, queue_drawer_open: true, ..play }, None), // paused, drawer keeps it
            (StreamWants { playing: false, ..play }, Some(false)),       // drawer closes: all off
            (play, Some(true)),                                          // resumed
            (StreamWants { mini_on: false, ..play }, Some(false)),       // switch off
        ];
        let mut sent = false;
        for (wants, expect) in steps {
            let change = stream_change(sent, audio_stream_wanted(&wants));
            assert_eq!(change, expect, "{wants:?}");
            if let Some(on) = change {
                sent = on;
            }
        }
        assert!(!sent);
    }
    fn nothing_moves() -> AmbientNeeds {
        AmbientNeeds {
            playing: true,
            motion_allowed: true,
            window_visible: true,
            fullscreen_open: false,
            queue_open: false,
            mini_drawn: false,
            classic_sidebar_bars: false,
        }
    }

    #[test]
    fn a_playing_song_alone_does_not_start_the_redraw_clock() {
        assert!(!ambient_tick_wanted(&nothing_moves()));
    }

    #[test]
    fn each_thing_that_moves_starts_the_clock_while_music_plays() {
        for n in [
            AmbientNeeds { fullscreen_open: true, ..nothing_moves() },
            AmbientNeeds { queue_open: true, ..nothing_moves() },
            AmbientNeeds { mini_drawn: true, ..nothing_moves() },
            AmbientNeeds { classic_sidebar_bars: true, ..nothing_moves() },
        ] {
            assert!(ambient_tick_wanted(&n), "{n:?}");
        }
    }

    #[test]
    fn paused_reduced_motion_or_no_window_stop_the_clock_whatever_moves() {
        let busy = AmbientNeeds {
            fullscreen_open: true,
            queue_open: true,
            mini_drawn: true,
            classic_sidebar_bars: true,
            ..nothing_moves()
        };
        assert!(ambient_tick_wanted(&busy));
        assert!(!ambient_tick_wanted(&AmbientNeeds { playing: false, ..busy }));
        assert!(!ambient_tick_wanted(&AmbientNeeds { motion_allowed: false, ..busy }));
        assert!(!ambient_tick_wanted(&AmbientNeeds { window_visible: false, ..busy }));
    }
}
