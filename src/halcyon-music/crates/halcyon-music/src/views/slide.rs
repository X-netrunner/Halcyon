//! A container that can retract upward out of sight.
//!
//! iced's own containers squash their content when they are made shorter than it, so a plain
//! `container(..).height(..)` cannot slide something away. `Slide` lays its content out at full
//! size and then shows only the lower `shown` part of it (1.0 = all, 0.0 = nothing), clipped,
//! so the content moves up and out like a retracting drawer. It takes no room when hidden,
//! ignores clicks outside the visible strip, and still passes focus operations through.

use iced::advanced::layout::{self, Layout};
use iced::advanced::renderer;
use iced::advanced::widget::{tree::Tree, Operation, Widget};
use iced::advanced::{Clipboard, Shell};
use iced::{event, mouse, Element, Event, Length, Point, Rectangle, Size};

pub struct Slide<'a, M, T, R> {
    content: Element<'a, M, T, R>,
    shown: f32,
}

impl<'a, M, T, R> Slide<'a, M, T, R> {
    pub fn new(content: impl Into<Element<'a, M, T, R>>, shown: f32) -> Self {
        Self { content: content.into(), shown: shown.clamp(0.0, 1.0) }
    }
}

impl<'a, M, T, R> Widget<M, T, R> for Slide<'a, M, T, R>
where
    R: renderer::Renderer,
{
    fn size(&self) -> Size<Length> {
        Size::new(self.content.as_widget().size().width, Length::Shrink)
    }

    fn children(&self) -> Vec<Tree> {
        vec![Tree::new(&self.content)]
    }

    fn diff(&self, tree: &mut Tree) {
        tree.diff_children(std::slice::from_ref(&self.content));
    }

    fn layout(&self, tree: &mut Tree, renderer: &R, limits: &layout::Limits) -> layout::Node {
        let Some(child_tree) = tree.children.first_mut() else {
            return layout::Node::new(Size::ZERO);
        };
        let child = self.content.as_widget().layout(child_tree, renderer, limits);
        let full = child.size();
        let visible = Size::new(full.width, full.height * self.shown);
        // The content keeps its size; it just sits higher by however much is hidden.
        let child = child.move_to(Point::new(0.0, visible.height - full.height));
        layout::Node::with_children(visible, vec![child])
    }

    fn draw(
        &self,
        tree: &Tree,
        renderer: &mut R,
        theme: &T,
        style: &renderer::Style,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        viewport: &Rectangle,
    ) {
        let bounds = layout.bounds();
        // Clip to what the parent lets through as well, so nothing is drawn over a scroll area's edge.
        let Some(clip) = bounds.intersection(viewport) else { return };
        if clip.height < 0.5 {
            return;
        }
        let (Some(child_tree), Some(child)) = (tree.children.first(), layout.children().next()) else {
            return;
        };
        let cursor = if cursor.is_over(bounds) { cursor } else { mouse::Cursor::Unavailable };
        renderer.with_layer(clip, |renderer| {
            self.content.as_widget().draw(child_tree, renderer, theme, style, child, cursor, &clip);
        });
    }

    fn operate(&self, tree: &mut Tree, layout: Layout<'_>, renderer: &R, operation: &mut dyn Operation) {
        let (Some(child_tree), Some(child)) = (tree.children.first_mut(), layout.children().next()) else {
            return;
        };
        self.content.as_widget().operate(child_tree, child, renderer, operation);
    }

    fn on_event(
        &mut self,
        tree: &mut Tree,
        event: Event,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        renderer: &R,
        clipboard: &mut dyn Clipboard,
        shell: &mut Shell<'_, M>,
        _viewport: &Rectangle,
    ) -> event::Status {
        if self.shown < 0.02 {
            return event::Status::Ignored;
        }
        let bounds = layout.bounds();
        let (Some(child_tree), Some(child)) = (tree.children.first_mut(), layout.children().next()) else {
            return event::Status::Ignored;
        };
        // Pointer events outside the visible strip belong to whatever is under it.
        let cursor = if cursor.is_over(bounds) { cursor } else { mouse::Cursor::Unavailable };
        self.content
            .as_widget_mut()
            .on_event(child_tree, event, child, cursor, renderer, clipboard, shell, &bounds)
    }

    fn mouse_interaction(
        &self,
        tree: &Tree,
        layout: Layout<'_>,
        cursor: mouse::Cursor,
        _viewport: &Rectangle,
        renderer: &R,
    ) -> mouse::Interaction {
        let bounds = layout.bounds();
        if self.shown < 0.02 || !cursor.is_over(bounds) {
            return mouse::Interaction::None;
        }
        let (Some(child_tree), Some(child)) = (tree.children.first(), layout.children().next()) else {
            return mouse::Interaction::None;
        };
        self.content.as_widget().mouse_interaction(child_tree, child, cursor, &bounds, renderer)
    }
}

impl<'a, M: 'a, T: 'a, R: renderer::Renderer + 'a> From<Slide<'a, M, T, R>> for Element<'a, M, T, R> {
    fn from(slide: Slide<'a, M, T, R>) -> Self {
        Element::new(slide)
    }
}
