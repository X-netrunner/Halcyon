//! Back and forward through the places the person has been (the title bar's two arrows in the
//! layouts that have them).
//!
//! This is only the list and a cursor, so it is tested without a window. `main.rs` records a
//! place when the person opens it and replays one by sending the same message the click would
//! have sent. A place is a page, or one album, artist, playlist or mix on the pages that show
//! one thing.

use crate::views::sidebar::NavPage;

/// How many places are kept. Older ones fall off the start.
pub const MAX_PLACES: usize = 50;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Place {
    Page(NavPage),
    Album(String),
    Artist(String),
    Playlist(String),
    Mix(String),
}

#[derive(Debug, Clone)]
pub struct NavHistory {
    places: Vec<Place>,
    /// Index of the place the person is on now.
    at: usize,
}

impl NavHistory {
    pub fn new(start: Place) -> Self {
        Self {
            places: vec![start],
            at: 0,
        }
    }

    #[allow(dead_code)]
    pub fn current(&self) -> Option<&Place> {
        self.places.get(self.at)
    }

    pub fn can_back(&self) -> bool {
        self.at > 0
    }

    pub fn can_forward(&self) -> bool {
        self.at + 1 < self.places.len()
    }

    /// The person went somewhere new. Going to the place they are already on changes nothing;
    /// otherwise whatever lay ahead (after a Back) is dropped, like a browser.
    pub fn record(&mut self, place: Place) {
        if self.places.get(self.at) == Some(&place) {
            return;
        }
        self.places.truncate(self.at + 1);
        self.places.push(place);
        if self.places.len() > MAX_PLACES {
            self.places.remove(0);
        }
        self.at = self.places.len() - 1;
    }

    /// Step back. Returns the place to show, or `None` at the start.
    pub fn back(&mut self) -> Option<Place> {
        if !self.can_back() {
            return None;
        }
        self.at -= 1;
        self.places.get(self.at).cloned()
    }

    /// Step forward. Returns the place to show, or `None` at the end.
    pub fn forward(&mut self) -> Option<Place> {
        if !self.can_forward() {
            return None;
        }
        self.at += 1;
        self.places.get(self.at).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn page(p: NavPage) -> Place {
        Place::Page(p)
    }

    #[test]
    fn a_new_history_cannot_go_anywhere() {
        let mut h = NavHistory::new(page(NavPage::Home));
        assert!(!h.can_back() && !h.can_forward());
        assert_eq!(h.back(), None);
        assert_eq!(h.forward(), None);
        assert_eq!(h.current(), Some(&page(NavPage::Home)));
    }

    #[test]
    fn back_and_forward_walk_the_places_in_order() {
        let mut h = NavHistory::new(page(NavPage::Home));
        h.record(page(NavPage::Library));
        h.record(Place::Playlist("p1".into()));
        assert_eq!(h.back(), Some(page(NavPage::Library)));
        assert_eq!(h.back(), Some(page(NavPage::Home)));
        assert_eq!(h.back(), None);
        assert_eq!(h.forward(), Some(page(NavPage::Library)));
        assert_eq!(h.forward(), Some(Place::Playlist("p1".into())));
        assert_eq!(h.forward(), None);
    }

    #[test]
    fn recording_the_place_you_are_on_changes_nothing() {
        let mut h = NavHistory::new(page(NavPage::Home));
        h.record(page(NavPage::Home));
        assert!(!h.can_back());
        h.record(page(NavPage::Settings));
        h.record(page(NavPage::Settings));
        assert_eq!(h.back(), Some(page(NavPage::Home)));
        assert_eq!(h.back(), None);
    }

    #[test]
    fn going_somewhere_new_after_back_drops_what_was_ahead() {
        let mut h = NavHistory::new(page(NavPage::Home));
        h.record(page(NavPage::Library));
        h.record(page(NavPage::Settings));
        h.back();
        h.back();
        h.record(page(NavPage::Discover));
        assert!(!h.can_forward());
        assert_eq!(h.back(), Some(page(NavPage::Home)));
    }

    #[test]
    fn two_albums_are_two_places() {
        let mut h = NavHistory::new(page(NavPage::Home));
        h.record(Place::Album("a".into()));
        h.record(Place::Album("b".into()));
        assert_eq!(h.back(), Some(Place::Album("a".into())));
    }

    #[test]
    fn the_list_is_capped_and_the_cursor_stays_on_the_newest() {
        let mut h = NavHistory::new(page(NavPage::Home));
        for i in 0..(MAX_PLACES + 20) {
            h.record(Place::Album(format!("a{i}")));
        }
        assert!(h.places.len() <= MAX_PLACES);
        assert_eq!(
            h.current(),
            Some(&Place::Album(format!("a{}", MAX_PLACES + 19)))
        );
        assert!(!h.can_forward());
        let mut steps = 0;
        while h.back().is_some() {
            steps += 1;
        }
        assert_eq!(steps, MAX_PLACES - 1);
    }
}
