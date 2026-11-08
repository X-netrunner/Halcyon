//! Two same-size pictures laid over each other for a cross-fade.
//!
//! `iced::widget::stack` is not used for this: a stacked layer is not clipped by the scroll
//! area around it, so while a card was changing its cover the new picture was drawn over the
//! player bar. This widget draws both pictures in one layer that is cut to the visible part of
//! the card (its own bounds crossed with the viewport the parent passes down).

use iced::advanced::layout::{self, Layout};
use iced::advanced::renderer;
use iced::advanced::widget::{tree::Tree, Widget};
use iced::{mouse, Element, Length, Rectangle, Size};

pub struct Crossfade<'a, M, T, R> {
    below: Element<'a, M, T, R>,
    above: Element<'a, M, T, R>,
}

impl<'a, M, T, R> Crossfade<'a, M, T, R> {
    /// `above` is drawn over `below` and should already carry its own opacity.
    pub fn new(below: impl Into<Element<'a, M, T, R>>, above: impl Into<Element<'a, M, T, R>>) -> Self {
        Self { below: below.into(), above: above.into() }
    }
}

impl<'a, M, T, R> Widget<M, T, R> for Crossfade<'a, M, T, R>
where
    R: renderer::Renderer,
{
    fn size(&self) -> Size<Length> {
        self.below.as_widget().size()
    }

    fn children(&self) -> Vec<Tree> {
        vec![Tree::new(&self.below), Tree::new(&self.above)]
    }

    fn diff(&self, tree: &mut Tree) {
        tree.diff_children(&[&self.below, &self.above]);
    }

    fn layout(&self, tree: &mut Tree, renderer: &R, limits: &layout::Limits) -> layout::Node {
        let mut children = tree.children.iter_mut();
        let (Some(a_tree), Some(b_tree)) = (children.next(), children.next()) else {
            return layout::Node::new(Size::ZERO);
        };
        let below = self.below.as_widget().layout(a_tree, renderer, limits);
        let size = below.size();
        // The picture above is held to the same size and place.
        let above = self.above.as_widget().layout(b_tree, renderer, &layout::Limits::new(size, size));
        layout::Node::with_children(size, vec![below, above])
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
        let Some(clip) = layout.bounds().intersection(viewport) else { return };
        let mut kids = layout.children();
        let (Some(a_layout), Some(b_layout)) = (kids.next(), kids.next()) else { return };
        let mut trees = tree.children.iter();
        let (Some(a_tree), Some(b_tree)) = (trees.next(), trees.next()) else { return };
        renderer.with_layer(clip, |renderer| {
            self.below.as_widget().draw(a_tree, renderer, theme, style, a_layout, cursor, &clip);
            self.above.as_widget().draw(b_tree, renderer, theme, style, b_layout, cursor, &clip);
        });
    }
}

impl<'a, M: 'a, T: 'a, R: renderer::Renderer + 'a> From<Crossfade<'a, M, T, R>> for Element<'a, M, T, R> {
    fn from(c: Crossfade<'a, M, T, R>) -> Self {
        Element::new(c)
    }
}
