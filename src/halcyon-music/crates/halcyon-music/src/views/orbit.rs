//! The beat around the playing cover: on each beat a thin ring leaves the cover's rounded-square
//! outline, and as it spreads it relaxes into a circle and fades away, so what starts as a
//! square ripple ends as a soft curving line. No bars, no spectrum: only the beat.

use crate::theme::{self, HalcyonPalette};
use crate::viz::VizFrame;
use iced::widget::canvas::{self, Canvas, Frame, Geometry, Path, Stroke};
use iced::{mouse, Element, Length, Point, Rectangle, Renderer, Theme};
use std::f32::consts::TAU;

/// Squareness of the outline at the cover (a softly rounded square) and at the far end (a circle).
const N_START: f32 = 7.0;
const N_END: f32 = 2.0;
/// Space between the cover's edge and where a ripple starts.
const GAP: f32 = 6.0;
/// Points per ring.
const STEPS: usize = 120;

/// A point of the unit "squircle" with exponent `n` in the direction `psi` (n = 2 is a circle).
fn outline_point(psi: f32, n: f32) -> (f32, f32) {
    let (dx, dy) = (psi.sin(), psi.cos());
    let r = 1.0 / (dx.abs().powf(n) + dy.abs().powf(n)).powf(1.0 / n);
    (dx * r, dy * r)
}

/// Slow start, slow finish.
fn ease(t: f32) -> f32 {
    let t = t.clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

struct Orbit {
    viz: VizFrame,
    cover_px: f32,
    palette: HalcyonPalette,
}

impl<M> canvas::Program<M> for Orbit {
    type State = ();

    fn draw(
        &self,
        _state: &(),
        renderer: &Renderer,
        _theme: &Theme,
        bounds: Rectangle,
        _cursor: mouse::Cursor,
    ) -> Vec<Geometry> {
        let mut frame = Frame::new(renderer, bounds.size());
        let centre = Point::new(bounds.width / 2.0, bounds.height / 2.0);
        let start = self.cover_px / 2.0 + GAP;
        let end = (bounds.width.min(bounds.height) / 2.0 - 2.0).max(start + 1.0);
        let pal = self.palette;

        // Oldest first, so the newest ripple is drawn on top.
        for ripple in self.viz.ripples.iter().rev().flatten() {
            let p = ease(ripple.progress);
            let reach = start + p * (end - start);
            let n = N_START + (N_END - N_START) * p;
            let fade = (1.0 - ripple.progress).powf(1.6) * (0.10 + 0.32 * ripple.strength);
            let colour = theme::alpha(theme::mix(pal.accent, pal.accent_secondary, p), fade);
            let path = Path::new(|b| {
                for k in 0..=STEPS {
                    let (x, y) = outline_point(TAU * k as f32 / STEPS as f32, n);
                    let at = Point::new(centre.x + x * reach, centre.y + y * reach);
                    if k == 0 {
                        b.move_to(at);
                    } else {
                        b.line_to(at);
                    }
                }
                b.close();
            });
            frame.stroke(&path, Stroke::default().with_width(1.6 - 0.7 * p).with_color(colour));
        }

        vec![frame.into_geometry()]
    }
}

/// The ripples, `size` px square. Put the cover (`cover_px` wide) on top of its centre.
pub fn view<'a, M: 'a>(viz: VizFrame, cover_px: f32, size: f32, palette: HalcyonPalette) -> Element<'a, M> {
    Canvas::new(Orbit { viz, cover_px, palette })
        .width(Length::Fixed(size))
        .height(Length::Fixed(size))
        .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outline_relaxes_from_square_to_circle() {
        // Diagonal direction: far out for a square, exactly 1.0 for a circle.
        let diag = std::f32::consts::FRAC_PI_4;
        let (sx, sy) = outline_point(diag, N_START);
        let (cx, cy) = outline_point(diag, N_END);
        let square = (sx * sx + sy * sy).sqrt();
        let circle = (cx * cx + cy * cy).sqrt();
        assert!(square > 1.2, "corner reach {square}");
        assert!((circle - 1.0).abs() < 1e-4);
        // Straight down it is 1.0 either way, so the ring stays centred on the cover's edge.
        assert!((outline_point(0.0, N_START).1 - 1.0).abs() < 1e-4);
    }

    #[test]
    fn ease_is_soft_at_both_ends() {
        assert_eq!(ease(0.0), 0.0);
        assert_eq!(ease(1.0), 1.0);
        assert!(ease(0.1) < 0.1 && ease(0.9) > 0.9);
    }
}
