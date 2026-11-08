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
        let (w, h) = (bounds.width, bounds.height);
        let (left, right) = (EAR, w - EAR);
        let p = Point::new;

        // The edge only (what gets the outline): left ear, left side, bottom, right side, right ear.
        let edge = |b: &mut canvas::path::Builder| {
            b.move_to(p(0.0, 0.0));
            b.quadratic_curve_to(p(left, 0.0), p(left, EAR));
            b.line_to(p(left, h - CORNER));
            b.quadratic_curve_to(p(left, h), p(left + CORNER, h));
            b.line_to(p(right - CORNER, h));
            b.quadratic_curve_to(p(right, h), p(right, h - CORNER));
            b.line_to(p(right, EAR));
            b.quadratic_curve_to(p(right, 0.0), p(w, 0.0));
        };
        // The fill adds a strip above the page's edge so its own outline is covered there.
        let shape = Path::new(|b| {
            edge(b);
            b.line_to(p(w, -3.0));
            b.line_to(p(0.0, -3.0));
            b.close();
        });
        frame.fill(&shape, self.fill);
        frame.stroke(&Path::new(|b| edge(b)), Stroke::default().with_width(1.0).with_color(self.outline));
        vec![frame.into_geometry()]
    }
}

/// The notch shape, `width` x `height` px, including the two ears.
pub fn view<'a, M: 'a>(width: f32, height: f32, fill: Color, outline: Color) -> Element<'a, M> {
    Canvas::new(Notch { fill, outline }).width(Length::Fixed(width)).height(Length::Fixed(height)).into()
}
