//! The shape behind the search box: the window frame reaching down into the page.
//!
//! It is filled with the frame's own colour and the page's top edge runs into it through two
//! concave curves (like a browser tab), so the search reads as part of the title bar instead of
//! a box laid on the page. The card's 1 px outline follows the shape.

use iced::widget::canvas::{self, Canvas, Frame, Geometry, Path, Stroke};
use iced::{mouse, Color, Element, Length, Point, Rectangle, Renderer, Theme};

/// Radius of the concave curves where the notch meets the page's top edge.
pub const EAR: f32 = 18.0;
/// Radius of the notch's lower corners.
const CORNER: f32 = 26.0;

struct Notch {
    fill: Color,
    outline: Color,
}

/// Control-point distance for a quarter circle drawn as one cubic curve (0.5523 of the radius).
const K: f32 = 0.5523;

impl<M> canvas::Program<M> for Notch {
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
        let w = bounds.width;
        // The line is 1 px wide and centred on its path. Paths run half a pixel inside the
        // canvas (top and bottom) so no half of the line is cut off by the canvas edge, which is
        // what made the old outline look thin and broken where it met the page.
        let top = 0.5;
        let bottom = bounds.height - 0.5;
        let (left, right) = (EAR, w - EAR);
        let p = Point::new;
        let ear_k = EAR * (1.0 - K);
        let corner_k = CORNER * (1.0 - K);

        // The edge only (what gets the outline): left ear, left wall, bottom, right wall, right
        // ear. Every bend is a true quarter circle, so the line has no flat or pinched spots.
        let edge = |b: &mut canvas::path::Builder| {
            b.move_to(p(-1.0, top));
            b.line_to(p(0.0, top));
            // Left ear: from the page's top edge, curving down into the wall.
            b.bezier_curve_to(p(EAR * K, top), p(left, top + ear_k), p(left, top + EAR));
            b.line_to(p(left, bottom - CORNER));
            // Left lower corner.
            b.bezier_curve_to(p(left, bottom - corner_k), p(left + corner_k, bottom), p(left + CORNER, bottom));
            b.line_to(p(right - CORNER, bottom));
            // Right lower corner.
            b.bezier_curve_to(p(right - corner_k, bottom), p(right, bottom - corner_k), p(right, bottom - CORNER));
            b.line_to(p(right, top + EAR));
            // Right ear: from the wall, curving out along the page's top edge.
            b.bezier_curve_to(p(right, top + ear_k), p(w - EAR * K, top), p(w, top));
            b.line_to(p(w + 1.0, top));
        };
        // The fill adds a strip above the page's edge so its own outline is covered there.
        let shape = Path::new(|b| {
            edge(b);
            b.line_to(p(w + 1.0, -3.0));
            b.line_to(p(-1.0, -3.0));
            b.close();
        });
        frame.fill(&shape, self.fill);
        frame.stroke(
            &Path::new(|b| edge(b)),
            Stroke::default()
                .with_width(1.0)
                .with_color(self.outline)
                .with_line_cap(canvas::LineCap::Round)
                .with_line_join(canvas::LineJoin::Round),
        );
        vec![frame.into_geometry()]
    }
}

/// The notch shape, `width` x `height` px, including the two ears.
pub fn view<'a, M: 'a>(width: f32, height: f32, fill: Color, outline: Color) -> Element<'a, M> {
    Canvas::new(Notch { fill, outline }).width(Length::Fixed(width)).height(Length::Fixed(height)).into()
}
