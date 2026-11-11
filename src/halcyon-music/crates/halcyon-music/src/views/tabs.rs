//! The tabs row of the Top tabs layout: Home, Library and Discover, centred on the window, with
//! a small Halcyon star after them that slides out the pages kept out of the way (Recent and
//! Capsule). Settings is not a tab: it lives in the account menu.
//!
//! The active tab has a short accent bar under its name; the others are muted text. The account
//! circle sits at the left end (the Classic sidebar carries it, and this layout has no sidebar).
//! The row is three zones: a left one, the tabs, and a right one. The left and right zones share
//! the free width equally, so the tabs stay exactly centred on the window whatever the right zone
//! holds, and the star and the pages it reveals grow into the right zone without moving them.

use crate::icons::{icon, Icon};
use crate::theme::{self, type_size, HalcyonPalette};
use crate::views::sidebar::NavPage;
use crate::views::slide::Slide;
use iced::widget::{button, column, container, row, text, Space};
use iced::{Alignment, Element, Length, Padding};

/// Height of the whole row (the account circle is 36 px with its ring).
pub const HEIGHT: f32 = 40.0;
/// Width of the little bar under the active tab.
const BAR_WIDTH: f32 = 18.0;
const BAR_HEIGHT: f32 = 2.0;
/// The star button is a circle this wide.
const MORE_SIZE: f32 = 28.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    Home,
    Library,
    Discover,
}

impl Tab {
    pub const ALL: [Tab; 3] = [Tab::Home, Tab::Library, Tab::Discover];

    /// The pages the star slides out, in order.
    pub const MORE: [NavPage; 2] = [NavPage::Recent, NavPage::Capsule];

    pub fn label(&self) -> &'static str {
        match self {
            Tab::Home => "Home",
            Tab::Library => "Library",
            Tab::Discover => "Discover",
        }
    }

    /// The page a click on the tab opens.
    pub fn page(&self) -> NavPage {
        match self {
            Tab::Home => NavPage::Home,
            Tab::Library => NavPage::Library,
            Tab::Discover => NavPage::Discover,
        }
    }

    /// Which tab is lit for a page. Pages that belong to Home or Library keep that tab lit, the
    /// same way Liked Songs keeps Library lit in the sidebar. A page with no tab (Lyrics,
    /// Settings, and the pages behind the star) lights none.
    pub fn for_page(page: NavPage) -> Option<Tab> {
        match page {
            NavPage::Home | NavPage::Search => Some(Tab::Home),
            NavPage::Discover => Some(Tab::Discover),
            NavPage::Library
            | NavPage::Liked
            | NavPage::AlbumDetail
            | NavPage::ArtistDetail
            | NavPage::PlaylistDetail => Some(Tab::Library),
            NavPage::Settings | NavPage::Lyrics | NavPage::Capsule | NavPage::Recent => None,
        }
    }

    /// Whether a page is one of those behind the star.
    pub fn in_more(page: NavPage) -> bool {
        Self::MORE.contains(&page)
    }
}

/// The label for a page behind the star (short, the sidebar's long names do not fit a row).
fn more_label(page: NavPage) -> &'static str {
    match page {
        NavPage::Recent => "Recent",
        NavPage::Capsule => "Capsule",
        other => other.label(),
    }
}

/// One name in the row. The lit one has a short accent bar under it. The bar has a fixed width,
/// so the button is exactly as wide as its name (a bar that fills would stretch every tab across
/// the window).
fn label_button<'a, M: Clone + 'a>(
    label: &'static str,
    page: NavPage,
    active: bool,
    palette: HalcyonPalette,
    on_select: &impl Fn(NavPage) -> M,
) -> Element<'a, M> {
    let colour = if active { palette.text } else { palette.text_muted };
    let bar = container(Space::new(BAR_WIDTH, BAR_HEIGHT)).style(move |_t| container::Style {
        background: if active { Some(palette.accent.into()) } else { None },
        border: iced::Border { radius: (BAR_HEIGHT / 2.0).into(), ..Default::default() },
        ..Default::default()
    });
    button(
        column![text(label).size(type_size::BODY).color(colour), bar]
            .spacing(5)
            .align_x(Alignment::Center),
    )
    .on_press(on_select(page))
    .padding([4, 6])
    .style(move |_t, status| button::Style {
        background: None,
        text_color: if matches!(status, button::Status::Hovered) { palette.text } else { colour },
        border: iced::Border::default(),
        ..Default::default()
    })
    .into()
}

/// The Halcyon star: opens and closes the pages kept behind it.
fn more_button<'a, M: Clone + 'a>(lit: bool, palette: HalcyonPalette, on_toggle: M) -> Element<'a, M> {
    button(
        container(icon(
            if lit { Icon::StarFilled } else { Icon::Star },
            15.0,
            if lit { palette.accent } else { palette.text_muted },
        ))
        .width(MORE_SIZE)
        .height(MORE_SIZE)
        .center_x(MORE_SIZE)
        .center_y(MORE_SIZE),
    )
    .on_press(on_toggle)
    .padding(0)
    .style(move |_t, status| button::Style {
        background: if matches!(status, button::Status::Hovered | button::Status::Pressed) {
            Some(theme::alpha(palette.text, 0.08).into())
        } else {
            None
        },
        text_color: palette.text,
        border: iced::Border { radius: (MORE_SIZE / 2.0).into(), ..Default::default() },
        ..Default::default()
    })
    .into()
}

/// The row itself: `left` (the account circle, or nothing), the tabs in the middle, the star and
/// what it reveals at the right. `more` is how far the star has slid its pages out (0.0 to 1.0).
fn bar<'a, M: Clone + 'a>(
    left: Element<'a, M>,
    active: NavPage,
    palette: HalcyonPalette,
    more: f32,
    on_toggle_more: M,
    on_select: &impl Fn(NavPage) -> M,
) -> Element<'a, M> {
    let lit = Tab::for_page(active);
    let mut tabs = row![].spacing(theme::space::XL).align_y(Alignment::Center);
    for tab in Tab::ALL {
        tabs = tabs.push(label_button(tab.label(), tab.page(), lit == Some(tab), palette, on_select));
    }

    let mut extras = row![].spacing(theme::space::XL).align_y(Alignment::Center);
    for page in Tab::MORE {
        extras = extras.push(label_button(more_label(page), page, active == page, palette, on_select));
    }
    let extras = Slide::horizontal(
        container(extras).padding(Padding { top: 0.0, right: 0.0, bottom: 0.0, left: theme::space::LG }),
        more,
    );
    let right = row![
        Space::with_width(theme::space::MD),
        more_button(more > 0.5 || Tab::in_more(active), palette, on_toggle_more),
        extras,
    ]
    .align_y(Alignment::Center);

    container(
        row![
            container(left).width(Length::FillPortion(1)).align_y(iced::alignment::Vertical::Center),
            tabs,
            container(right).width(Length::FillPortion(1)).align_y(iced::alignment::Vertical::Center),
        ]
        .align_y(Alignment::Center),
    )
    .width(Length::Fill)
    .height(HEIGHT)
    .align_y(iced::alignment::Vertical::Center)
    .into()
}

/// The row: account circle at the left end, the tabs in the middle, the star at the right. The
/// circle is lined up with the back arrow above it.
pub fn view<'a, M: Clone + 'a>(
    active: NavPage,
    palette: HalcyonPalette,
    account: Element<'a, M>,
    more: f32,
    on_toggle_more: M,
    on_select: impl Fn(NavPage) -> M + 'a,
) -> Element<'a, M> {
    // The account button is the circle plus a 2 px ring on each side.
    let button_w = crate::views::account::AVATAR_SIZE + 4.0;
    let left = container(account).padding(Padding {
        top: 0.0,
        right: 0.0,
        bottom: 0.0,
        left: crate::views::titlebar::arrow_centre_x() - button_w / 2.0,
    });
    bar(left.into(), active, palette, more, on_toggle_more, &on_select)
}

/// The tabs alone, centred in whatever width they are given. The Player panel layout puts them at
/// the top of the page card (its account circle is in the panel, so there is nothing else here).
pub fn inline<'a, M: Clone + 'a>(
    active: NavPage,
    palette: HalcyonPalette,
    more: f32,
    on_toggle_more: M,
    on_select: impl Fn(NavPage) -> M + 'a,
) -> Element<'a, M> {
    bar(Space::with_width(0).into(), active, palette, more, on_toggle_more, &on_select)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_page_lights_at_most_one_tab_and_the_tabs_open_their_own_page() {
        for tab in Tab::ALL {
            assert_eq!(Tab::for_page(tab.page()), Some(tab));
        }
    }

    #[test]
    fn pages_inside_home_and_library_keep_their_tab_lit() {
        assert_eq!(Tab::for_page(NavPage::Liked), Some(Tab::Library));
        assert_eq!(Tab::for_page(NavPage::PlaylistDetail), Some(Tab::Library));
        assert_eq!(Tab::for_page(NavPage::Search), Some(Tab::Home));
        assert_eq!(Tab::for_page(NavPage::Discover), Some(Tab::Discover));
        assert_eq!(Tab::for_page(NavPage::Settings), None);
        assert!(Tab::in_more(NavPage::Recent) && Tab::in_more(NavPage::Capsule));
        assert_eq!(Tab::for_page(NavPage::Recent), None);
        assert_eq!(Tab::for_page(NavPage::Lyrics), None);
    }

    #[test]
    fn the_row_builds_for_every_page() {
        let palette = crate::theme::HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        for page in [
            NavPage::Home,
            NavPage::Library,
            NavPage::Settings,
            NavPage::Lyrics,
            NavPage::Capsule,
            NavPage::Recent,
            NavPage::Discover,
        ] {
            let _v: Element<'_, NavPage> = view(page, palette, Space::new(32, 32).into(), 0.5, NavPage::Home, |p| p);
            let _w: Element<'_, NavPage> = inline(page, palette, 1.0, NavPage::Home, |p| p);
        }
    }
}
