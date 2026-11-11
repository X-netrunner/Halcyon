//! Draws the full-screen visualizer (Aurora or Silk) on an iced canvas.
//!
//! All numbers come from `crate::visualizer`; this file only turns them into paths and fills
//! them with the palette accent. No glow, no gradient, no shadow. It is drawn behind the
//! lyrics, so it never carries text.
//!
//! The same file draws the mini visualizer (a few capsules in the player): `mini`.

use crate::layout::VisualizerKind;
use crate::theme;
use crate::viz::BANDS;
use crate::visualizer::{
    aurora_points, mini_bars, silk_bars, smooth_segments, MiniPlacement, Seg, AURORA_FILL_ALPHA, AURORA_LAYERS,
    AURORA_STROKE_ALPHA, AURORA_STROKE_WIDTH, MINI_BAR_WIDTH, SILK_BAR_WIDTH,
};
use iced::widget::canvas::{self, Canvas, Frame, Geometry, LineCap, LineJoin, Path, Stroke};
use iced::{mouse, Color, Element, Length, Point, Rectangle, Renderer, Size, Theme};

/// What to draw this frame. Cheap to build: the bands are 24 floats.
#[derive(Debug, Clone, Copy)]
pub struct Look {
    pub kind: VisualizerKind,
    /// The smoothed spectrum (all zeros = the resting shape).
    pub bands: [f32; BANDS],
    /// The animation clock in seconds; 0 when motion is reduced.
    pub clock: f32,
    /// Lyrics fill the right half: Silk keeps its alpha down there.
    pub lyrics_on_right: bool,
    pub accent: Color,
}

struct Visualizer {
    look: Look,
}

fn point((x, y): (f32, f32)) -> Point {
    Point::new(x, y)
}

fn add_segments(b: &mut canvas::path::Builder, segs: &[Seg]) {
    for seg in segs {
        match *seg {
            Seg::Move(p) => b.move_to(point(p)),
            Seg::Line(p) => b.line_to(point(p)),
            Seg::Quad { control, to } => b.quadratic_curve_to(point(control), point(to)),
        }
    }
}

impl<M> canvas::Program<M> for Visualizer {
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
        let (w, h) = (bounds.width, bounds.height);
        let look = self.look;

        match look.kind {
            VisualizerKind::Aurora => {
                // Back to front, so the front wave is drawn on top.
                for layer in 0..AURORA_LAYERS {
                    let pts = aurora_points(&look.bands, layer, w, h, look.clock);
                    let (Some(&first), Some(&last)) = (pts.first(), pts.last()) else { continue };
                    let segs = smooth_segments(&pts);
                    let top = Path::new(|b| add_segments(b, &segs));
                    let body = Path::new(|b| {
                        add_segments(b, &segs);
                        b.line_to(Point::new(last.0, h));
                        b.line_to(Point::new(first.0, h));
                        b.close();
                    });
                    let fill_alpha = AURORA_FILL_ALPHA.get(layer).copied().unwrap_or(0.1);
                    let stroke_alpha = AURORA_STROKE_ALPHA.get(layer).copied().unwrap_or(0.3);
                    frame.fill(&body, theme::alpha(look.accent, fill_alpha));
                    frame.stroke(
                        &top,
                        Stroke::default()
                            .with_width(AURORA_STROKE_WIDTH)
                            .with_color(theme::alpha(look.accent, stroke_alpha))
                            .with_line_join(LineJoin::Round)
                            .with_line_cap(LineCap::Round),
                    );
                }
            }
            VisualizerKind::Silk => {
                let max_height = (h * 0.30).clamp(60.0, 200.0);
                let lyrics_from = look.lyrics_on_right.then_some(w * 0.5);
                let mid = h / 2.0;
                for bar in silk_bars(&look.bands, w, max_height, lyrics_from) {
                    let capsule = Path::rounded_rectangle(
                        Point::new(bar.x, mid - bar.height / 2.0),
                        Size::new(SILK_BAR_WIDTH, bar.height),
                        (SILK_BAR_WIDTH / 2.0).into(),
                    );
                    frame.fill(&capsule, theme::alpha(look.accent, bar.alpha));
                }
            }
            VisualizerKind::None => {}
        }

        vec![frame.into_geometry()]
    }
}

/// The visualizer, filling whatever area it is given. `VisualizerKind::None` draws nothing, but
/// callers should not build it at all then.
pub fn view<'a, M: 'a>(look: Look) -> Element<'a, M> {
    Canvas::new(Visualizer { look }).width(Length::Fill).height(Length::Fill).into()
}

/// The small row of capsules in the player. `bands` is the smoothed spectrum (all zeros draws
/// the flat resting line); the area is exactly the placement's size. Each capsule is centred on
/// the middle line with round caps, in the accent at the alpha the geometry says. No label,
/// border, glow, gradient or shadow.
struct Mini {
    bands: [f32; BANDS],
    accent: Color,
}

impl<M> canvas::Program<M> for Mini {
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
        let mid = bounds.height / 2.0;
        for bar in mini_bars(&self.bands, bounds.width, bounds.height) {
            // A capsule is a rounded rectangle whose radius is half of the narrower side.
            let radius = (MINI_BAR_WIDTH.min(bar.height) / 2.0).max(0.0);
            let capsule = Path::rounded_rectangle(
                Point::new(bar.x, mid - bar.height / 2.0),
                Size::new(MINI_BAR_WIDTH, bar.height),
                radius.into(),
            );
            frame.fill(&capsule, theme::alpha(self.accent, bar.alpha));
        }
        vec![frame.into_geometry()]
    }
}

/// The mini visualizer at the size of `placement`.
pub fn mini<'a, M: 'a>(placement: MiniPlacement, bands: [f32; BANDS], accent: Color) -> Element<'a, M> {
    let (w, h) = placement.size();
    Canvas::new(Mini { bands, accent }).width(Length::Fixed(w)).height(Length::Fixed(h)).into()
}
