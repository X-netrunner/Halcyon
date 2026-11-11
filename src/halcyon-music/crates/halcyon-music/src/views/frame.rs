//! The window frame: where the five slots go.
//!
//! A layout is only an arrangement. `main.rs` builds each slot once (title bar, navigation, page,
//! queue, player) and hands them here; this file decides where they sit. Pages are never
//! duplicated per layout, and the frame owns the single surface fill (the caller wraps the result
//! in `palette.chrome_background()`), so the slots draw no background of their own.
//!
//! All five layouts are drawn. Library list puts its sidebar and its
//! right panel in the same slots Classic uses for the rail and the queue, so it shares
//! Classic's arrangement function; what differs is what `main.rs` puts in the slots.
//!
//! The width rules (volume hidden below 1100 px, the queue column becoming a drawer below
//! 1000 px) and the sizes the page needs to centre the search box live here as pure functions,
//! so `main.rs` and the tests use the same numbers.

use crate::layout::LayoutKind;
use crate::views::now_playing_bar::BarOptions;
use crate::views::{
    dock, library_sidebar, player_panel, queue_column, queue_drawer, side_panel, sidebar, tabs,
    titlebar,
};
use crate::visualizer::MiniPlacement;
use iced::widget::{column, row, stack};
use iced::{Element, Length};

/// Below this window width the new layouts hide the volume control.
pub const VOLUME_MIN_WIDTH: f32 = 1100.0;
/// Below this window width the queue column is a drawer opened by the queue button.
pub const QUEUE_COLUMN_MIN_WIDTH: f32 = 1000.0;

/// Whether the volume control is drawn. Classic always draws it (it is today's bar).
pub fn show_volume(layout: LayoutKind, window_width: f32) -> bool {
    match layout {
        LayoutKind::Classic => true,
        _ => window_width >= VOLUME_MIN_WIDTH,
    }
}

/// Whether the compact queue is a permanent column on the right (and not only a drawer).
pub fn queue_is_column(layout: LayoutKind, window_width: f32) -> bool {
    matches!(arrangement_for(layout), LayoutKind::TopTabs) && window_width >= QUEUE_COLUMN_MIN_WIDTH
}

/// Whether the Queue / Lyrics panel is a permanent column on the right (Library list). Below the
/// same width as the queue column it goes, and the queue button opens the drawer.
pub fn has_side_panel(layout: LayoutKind, window_width: f32) -> bool {
    matches!(arrangement_for(layout), LayoutKind::LibraryList)
        && window_width >= QUEUE_COLUMN_MIN_WIDTH
}

/// How the player bar is drawn in a layout. Classic gets exactly today's bar.
pub fn bar_options(layout: LayoutKind, window_width: f32) -> BarOptions {
    match arrangement_for(layout) {
        LayoutKind::TopTabs | LayoutKind::LibraryList => BarOptions {
            times_below: true,
            show_volume: show_volume(layout, window_width),
            mini: None,
            calm: true,
        },
        _ => BarOptions::CLASSIC,
    }
}

/// Whether the layout follows the calm rules (accent only on the play button, the progress fill,
/// the active tab underline and the star). Every layout but Classic does; Classic is kept as it
/// was.
pub fn is_calm(layout: LayoutKind) -> bool {
    arrangement_for(layout) != LayoutKind::Classic
}

/// Which layouts show the calm shelf Home (`home::view_shelf`) instead of Classic's Home, and
/// whether it has the Liked Songs hero: Top tabs `Some(true)`, Library list `Some(false)`
/// ("greeting and one shelf"). Dock and Player panel have their own Home pages (`None` here);
/// Classic keeps its Home.
pub fn shelf_home(layout: LayoutKind) -> Option<bool> {
    match arrangement_for(layout) {
        LayoutKind::TopTabs => Some(true),
        LayoutKind::LibraryList => Some(false),
        _ => None,
    }
}

/// Where the layout draws the mini visualizer, if it has a place for it. Classic has none: it
/// is the bar as it always was. Whether it is drawn right now also depends on the switch, the
/// track, the width and full screen (`visualizer::mini_shown`); `bar_options` leaves `mini`
/// empty and `main.rs` fills it in when that says so.
pub fn mini_placement(layout: LayoutKind) -> Option<MiniPlacement> {
    match arrangement_for(layout) {
        LayoutKind::Classic => None,
        LayoutKind::Dock => Some(MiniPlacement::Dock),
        LayoutKind::PlayerPanel => Some(MiniPlacement::Panel),
        // Top tabs and Library list share the full-width bar.
        LayoutKind::TopTabs | LayoutKind::LibraryList => Some(MiniPlacement::Bar),
    }
}

/// Whether the layout has the sidebar rail (icons that open into names) on the left.
pub fn has_sidebar(layout: LayoutKind) -> bool {
    matches!(arrangement_for(layout), LayoutKind::Classic)
}

/// Whether the layout has the library list on the left instead of the rail.
pub fn has_library_sidebar(layout: LayoutKind) -> bool {
    matches!(arrangement_for(layout), LayoutKind::LibraryList)
}

/// Whether the layout has back and forward arrows in the title bar.
pub fn has_history_arrows(layout: LayoutKind) -> bool {
    matches!(
        arrangement_for(layout),
        LayoutKind::TopTabs | LayoutKind::Dock | LayoutKind::PlayerPanel | LayoutKind::LibraryList
    )
}

/// Whether the layout has the tabs row under the title bar.
pub fn has_tabs_row(layout: LayoutKind) -> bool {
    matches!(arrangement_for(layout), LayoutKind::TopTabs)
}

/// Whether the layout has the floating dock at the bottom instead of the full-width bar.
pub fn has_dock(layout: LayoutKind) -> bool {
    matches!(arrangement_for(layout), LayoutKind::Dock)
}

/// Whether the player is the left panel (Player panel) instead of a bar along the bottom.
pub fn has_player_panel(layout: LayoutKind) -> bool {
    matches!(arrangement_for(layout), LayoutKind::PlayerPanel)
}

/// Whether the queue drawer opens over the page edge (Dock, Player panel) instead of pushing the
/// page aside. In the Player panel layout the panel already takes 190 px, so at 960 px a pushing
/// drawer would leave the page about 400 px.
pub fn queue_overlays_page(layout: LayoutKind) -> bool {
    has_dock(layout) || has_player_panel(layout)
}

/// Air between the page card and the window edges: (left, right). The other layouts have a
/// column or a sidebar at the left, so only Dock has a margin there.
pub fn page_margins(layout: LayoutKind, right: f32) -> (f32, f32) {
    if has_dock(layout) {
        (right, right)
    } else {
        (0.0, right)
    }
}

/// Where the account menu card opens. It opens next to the account circle, wherever the layout
/// puts the circle: under it, or (in the dock, at the bottom of the window) above it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MenuPlace {
    /// `left` and `top` from the window's top left corner.
    Below { left: f32, top: f32 },
    /// `left` from the window's left edge and `bottom` from its bottom edge.
    Above { left: f32, bottom: f32 },
}

pub fn account_menu_place(layout: LayoutKind, window_width: f32) -> MenuPlace {
    use crate::theme::space;
    use crate::views::account::AVATAR_SIZE;
    match arrangement_for(layout) {
        // Under the circle at the top of the rail.
        LayoutKind::Classic => MenuPlace::Below {
            left: space::LG,
            top: titlebar::HEIGHT + space::SM + AVATAR_SIZE + space::SM,
        },
        // Under the tabs row (the circle is at its left end).
        LayoutKind::TopTabs => MenuPlace::Below {
            left: space::LG,
            top: top_height(layout) + space::SM,
        },
        // Above the circle at the left end of the dock, clear of the pill.
        LayoutKind::Dock => MenuPlace::Above {
            left: dock::account_left(window_width),
            bottom: dock::STRIP_HEIGHT,
        },
        // Under the circle at the top of the player panel (its top padding is `SM`).
        LayoutKind::PlayerPanel => MenuPlace::Below {
            left: player_panel::PAD,
            top: titlebar::HEIGHT + space::SM + AVATAR_SIZE + space::SM,
        },
        // Under the circle at the top of the library list.
        _ => MenuPlace::Below {
            left: library_sidebar::PAD,
            top: titlebar::HEIGHT + space::SM + AVATAR_SIZE + space::SM,
        },
    }
}

/// Height of what sits between the title bar and the page card (the tabs row), 0 if nothing.
pub fn row_under_titlebar(layout: LayoutKind) -> f32 {
    match arrangement_for(layout) {
        LayoutKind::TopTabs => tabs::HEIGHT,
        _ => 0.0,
    }
}

/// How far down the frame colour runs before the page card starts: title bar plus any row under it.
/// The search notch hangs from here, so it takes its colour from the frame at this depth.
pub fn top_height(layout: LayoutKind) -> f32 {
    titlebar::HEIGHT + row_under_titlebar(layout)
}

/// Width of the left column: the rail (while `sidebar_progress` says how open it is), the library
/// list, the player panel, or nothing (Top tabs, Dock).
pub fn left_width(layout: LayoutKind, sidebar_progress: f32) -> f32 {
    if has_sidebar(layout) {
        sidebar::width_for(sidebar_progress)
    } else if has_library_sidebar(layout) {
        library_sidebar::WIDTH
    } else if has_player_panel(layout) {
        player_panel::WIDTH
    } else {
        0.0
    }
}

/// Width of the right column right now. `drawer_progress` is the queue drawer's open amount
/// (0.0 closed, 1.0 open). While the drawer is open or moving it takes the column's place.
pub fn right_width(
    layout: LayoutKind,
    window_width: f32,
    drawer_progress: f32,
    drawer_open: bool,
) -> f32 {
    // The dock's drawer lies over the page and takes no room from it.
    if queue_overlays_page(layout) {
        return 0.0;
    }
    let drawer_visible = drawer_open || drawer_progress > 0.001;
    if drawer_visible {
        queue_drawer::QUEUE_DRAWER_WIDTH * drawer_progress.clamp(0.0, 1.0)
    } else if queue_is_column(layout, window_width) {
        queue_column::WIDTH
    } else if has_side_panel(layout, window_width) {
        side_panel::WIDTH
    } else {
        0.0
    }
}

/// The already-built pieces of the window.
pub struct Slots<'a, M> {
    /// The title bar: back/forward, star and name, search, window buttons.
    pub titlebar: Element<'a, M>,
    /// Navigation: the sidebar rail in Classic. Layouts without a sidebar get `Space` here.
    pub nav: Element<'a, M>,
    /// The page card, with its outer margin.
    pub page: Element<'a, M>,
    /// The queue drawer (zero width while closed).
    pub queue: Element<'a, M>,
    /// The player: the full-width bar in Classic, the dock pill in Dock, the left panel in Player
    /// panel.
    pub player: Element<'a, M>,
}

/// Which arrangement is really drawn for a layout. Layouts without their own arrangement yet fall
/// back to Classic, so choosing one never leaves the window empty.
pub fn arrangement_for(layout: LayoutKind) -> LayoutKind {
    if layout.is_drawn() {
        layout
    } else {
        LayoutKind::Classic
    }
}

/// Put the slots where the layout wants them.
pub fn arrange<'a, M: 'a>(layout: LayoutKind, slots: Slots<'a, M>) -> Element<'a, M> {
    // Each later part adds a `match` arm for its own layout and a function beside `classic`.
    match arrangement_for(layout) {
        LayoutKind::TopTabs => top_tabs(slots),
        LayoutKind::Dock => dock_layout(slots),
        LayoutKind::PlayerPanel => panel_layout(slots),
        // Library list: sidebar | page | right panel, then the bar. The same slots as Classic.
        _ => classic(slots),
    }
}

/// Top tabs: title bar, the tabs row (in the `nav` slot), then page | queue column, then the
/// player bar. No sidebar.
fn top_tabs<'a, M: 'a>(slots: Slots<'a, M>) -> Element<'a, M> {
    let main_row = row![slots.page, slots.queue]
        .width(Length::Fill)
        .height(Length::Fill);
    column![slots.titlebar, slots.nav, main_row, slots.player]
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

/// Dock: title bar, then the page over the full width, then the dock strip. The queue is a drawer
/// laid over the page's right edge (the `queue` slot is drawn on top of the page, and is empty
/// while the drawer is shut). No sidebar and no tabs row: the pages are in the dock.
fn dock_layout<'a, M: 'a>(slots: Slots<'a, M>) -> Element<'a, M> {
    let page_area = stack![slots.page, slots.queue]
        .width(Length::Fill)
        .height(Length::Fill);
    column![slots.titlebar, page_area, slots.player]
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

/// Player panel: title bar on top, then the player panel on the left and the page beside it. There
/// is no bottom bar. As in Dock, the queue (the `queue` slot, empty while the drawer is shut) is
/// laid over the page's right edge, so the page keeps its width. The `nav` slot is not used: the
/// pages are tabs inside the page card.
fn panel_layout<'a, M: 'a>(slots: Slots<'a, M>) -> Element<'a, M> {
    let page_area = stack![slots.page, slots.queue]
        .width(Length::Fill)
        .height(Length::Fill);
    let main_row = row![slots.player, page_area]
        .width(Length::Fill)
        .height(Length::Fill);
    column![slots.titlebar, main_row]
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

/// Today's arrangement: title bar on top, then sidebar | page | queue, then the player bar.
fn classic<'a, M: 'a>(slots: Slots<'a, M>) -> Element<'a, M> {
    let main_row = row![slots.nav, slots.page, slots.queue]
        .width(Length::Fill)
        .height(Length::Fill);
    column![slots.titlebar, main_row, slots.player]
        .width(Length::Fill)
        .height(Length::Fill)
        .into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use iced::widget::Space;

    fn slots<'a>() -> Slots<'a, ()> {
        Slots {
            titlebar: Space::new(Length::Fill, 44).into(),
            nav: Space::new(60, Length::Fill).into(),
            page: Space::new(Length::Fill, Length::Fill).into(),
            queue: Space::new(0, Length::Fill).into(),
            player: Space::new(Length::Fill, 88).into(),
        }
    }

    #[test]
    fn every_layout_gets_an_arrangement_that_is_drawn() {
        for l in LayoutKind::ALL {
            assert!(
                arrangement_for(l).is_drawn(),
                "{l:?} has no drawn arrangement"
            );
        }
    }

    #[test]
    fn only_top_tabs_has_the_tabs_row_and_only_classic_has_the_rail() {
        for l in LayoutKind::ALL {
            let a = arrangement_for(l);
            assert_eq!(has_sidebar(l), a == LayoutKind::Classic);
            assert_eq!(has_library_sidebar(l), a == LayoutKind::LibraryList);
            assert_eq!(has_history_arrows(l), a != LayoutKind::Classic);
            assert_eq!(has_player_panel(l), a == LayoutKind::PlayerPanel);
            assert_eq!(has_tabs_row(l), a == LayoutKind::TopTabs);
            assert_eq!(has_dock(l), a == LayoutKind::Dock);
            assert_eq!(row_under_titlebar(l) > 0.0, a == LayoutKind::TopTabs);
        }
    }

    #[test]
    fn the_side_panel_is_a_column_from_1000_and_only_in_library_list() {
        assert!(!has_side_panel(LayoutKind::LibraryList, 999.0));
        assert!(has_side_panel(LayoutKind::LibraryList, 1000.0));
        assert!(!has_side_panel(LayoutKind::TopTabs, 1440.0));
        assert!(!has_side_panel(LayoutKind::Classic, 1440.0));
        // The compact queue column stays a Top tabs thing.
        assert!(!queue_is_column(LayoutKind::LibraryList, 1440.0));
    }

    #[test]
    fn library_list_widths_follow_the_sidebar_and_the_panel() {
        assert_eq!(
            left_width(LayoutKind::LibraryList, 0.0),
            library_sidebar::WIDTH
        );
        assert_eq!(
            left_width(LayoutKind::LibraryList, 1.0),
            library_sidebar::WIDTH
        );
        assert_eq!(
            right_width(LayoutKind::LibraryList, 1200.0, 0.0, false),
            side_panel::WIDTH
        );
        assert_eq!(right_width(LayoutKind::LibraryList, 960.0, 0.0, false), 0.0);
        assert_eq!(
            right_width(LayoutKind::LibraryList, 1200.0, 1.0, true),
            queue_drawer::QUEUE_DRAWER_WIDTH
        );
    }

    #[test]
    fn library_list_has_the_same_bar_as_top_tabs() {
        assert_eq!(
            bar_options(LayoutKind::LibraryList, 1300.0),
            bar_options(LayoutKind::TopTabs, 1300.0)
        );
        assert_eq!(
            bar_options(LayoutKind::LibraryList, 1000.0),
            bar_options(LayoutKind::TopTabs, 1000.0)
        );
        assert!(!show_volume(LayoutKind::LibraryList, 1099.0));
        assert!(show_volume(LayoutKind::LibraryList, 1100.0));
    }

    #[test]
    fn the_account_menu_opens_next_to_the_circle_of_each_layout() {
        match account_menu_place(LayoutKind::Classic, 1200.0) {
            MenuPlace::Below { left, top } => {
                assert_eq!(left, crate::theme::space::LG);
                assert!(top > titlebar::HEIGHT);
            }
            other => panic!("Classic: {other:?}"),
        }
        match account_menu_place(LayoutKind::TopTabs, 1200.0) {
            MenuPlace::Below { top, .. } => {
                assert_eq!(
                    top,
                    top_height(LayoutKind::TopTabs) + crate::theme::space::SM
                )
            }
            other => panic!("Top tabs: {other:?}"),
        }
        match account_menu_place(LayoutKind::PlayerPanel, 1200.0) {
            MenuPlace::Below { left, top } => {
                assert_eq!(left, player_panel::PAD);
                // Under the circle: the panel's top padding, the circle, and a gap.
                assert_eq!(
                    top,
                    titlebar::HEIGHT
                        + crate::theme::space::SM
                        + crate::views::account::AVATAR_SIZE
                        + crate::theme::space::SM
                );
            }
            other => panic!("Player panel: {other:?}"),
        }
        match account_menu_place(LayoutKind::LibraryList, 1200.0) {
            MenuPlace::Below { left, top } => {
                assert_eq!(left, library_sidebar::PAD);
                assert!(top > titlebar::HEIGHT);
            }
            other => panic!("Library list: {other:?}"),
        }
    }

    #[test]
    fn the_dock_menu_opens_above_the_dock_at_the_circle() {
        for w in [960.0, 1280.0, 2560.0] {
            assert_eq!(
                account_menu_place(LayoutKind::Dock, w),
                MenuPlace::Above {
                    left: dock::account_left(w),
                    bottom: dock::STRIP_HEIGHT
                }
            );
        }
    }

    #[test]
    fn the_dock_has_no_column_no_rail_and_its_drawer_takes_no_room() {
        let l = LayoutKind::Dock;
        assert!(has_dock(l) && !has_sidebar(l) && !has_library_sidebar(l) && !has_tabs_row(l));
        assert!(!queue_is_column(l, 1600.0) && !has_side_panel(l, 1600.0));
        assert_eq!(left_width(l, 1.0), 0.0);
        assert_eq!(row_under_titlebar(l), 0.0);
        assert_eq!(top_height(l), titlebar::HEIGHT);
        // The drawer lies over the page: open, closed or halfway, the page keeps its width.
        assert_eq!(right_width(l, 1200.0, 1.0, true), 0.0);
        assert_eq!(right_width(l, 1200.0, 0.5, true), 0.0);
        assert_eq!(right_width(l, 960.0, 0.0, false), 0.0);
        assert!(queue_overlays_page(l));
        for other in [
            LayoutKind::Classic,
            LayoutKind::TopTabs,
            LayoutKind::LibraryList,
        ] {
            assert!(!queue_overlays_page(other));
        }
    }

    #[test]
    fn the_player_panel_is_the_left_column_and_its_drawer_lies_over_the_page() {
        let l = LayoutKind::PlayerPanel;
        assert!(has_player_panel(l) && !has_dock(l) && !has_sidebar(l) && !has_library_sidebar(l));
        assert!(!has_tabs_row(l) && !queue_is_column(l, 1600.0) && !has_side_panel(l, 1600.0));
        // The panel is the left column, at every window width and however open the rail "is".
        for progress in [0.0, 0.5, 1.0] {
            assert_eq!(left_width(l, progress), player_panel::WIDTH);
        }
        assert_eq!(row_under_titlebar(l), 0.0);
        assert_eq!(top_height(l), titlebar::HEIGHT);
        // No column on the right; the drawer lies over the page and takes no room from it.
        assert!(queue_overlays_page(l));
        assert_eq!(right_width(l, 960.0, 0.0, false), 0.0);
        assert_eq!(right_width(l, 1400.0, 0.0, false), 0.0);
        assert_eq!(right_width(l, 960.0, 1.0, true), 0.0);
        assert_eq!(right_width(l, 960.0, 0.5, true), 0.0);
        // Only the panel takes room from the page at 960 px, and plenty is left.
        const _: () = assert!(960.0 - player_panel::WIDTH - 2.0 * 12.0 >= 700.0);
    }

    #[test]
    fn the_player_panel_hides_the_volume_below_1100_and_has_no_bar_options_of_its_own() {
        assert!(!show_volume(LayoutKind::PlayerPanel, 1099.0));
        assert!(show_volume(LayoutKind::PlayerPanel, 1100.0));
        assert_eq!(
            bar_options(LayoutKind::PlayerPanel, 1300.0),
            BarOptions::CLASSIC
        );
    }

    #[test]
    fn only_the_dock_has_a_page_margin_at_the_left() {
        assert_eq!(page_margins(LayoutKind::Dock, 12.0), (12.0, 12.0));
        for other in [
            LayoutKind::Classic,
            LayoutKind::TopTabs,
            LayoutKind::PlayerPanel,
            LayoutKind::LibraryList,
        ] {
            assert_eq!(page_margins(other, 12.0), (0.0, 12.0));
        }
    }

    #[test]
    fn the_dock_hides_the_volume_below_1100_like_the_other_new_layouts() {
        assert!(!show_volume(LayoutKind::Dock, 1099.0));
        assert!(show_volume(LayoutKind::Dock, 1100.0));
        // The dock draws its own bar; the shared bar options stay Classic's.
        assert_eq!(bar_options(LayoutKind::Dock, 1300.0), BarOptions::CLASSIC);
    }

    #[test]
    fn volume_hides_below_1100_in_the_new_layouts_but_never_in_classic() {
        assert!(show_volume(LayoutKind::Classic, 960.0));
        assert!(!show_volume(LayoutKind::TopTabs, 1099.0));
        assert!(show_volume(LayoutKind::TopTabs, 1100.0));
        assert!(show_volume(LayoutKind::TopTabs, 1440.0));
    }

    #[test]
    fn the_queue_is_a_column_from_1000_and_only_in_top_tabs() {
        assert!(!queue_is_column(LayoutKind::TopTabs, 999.0));
        assert!(queue_is_column(LayoutKind::TopTabs, 1000.0));
        assert!(!queue_is_column(LayoutKind::Classic, 1440.0));
    }

    #[test]
    fn right_width_is_the_column_the_drawer_or_nothing() {
        // Top tabs, wide window, drawer shut: the compact column.
        assert_eq!(
            right_width(LayoutKind::TopTabs, 1200.0, 0.0, false),
            queue_column::WIDTH
        );
        // Narrow window, drawer shut: nothing.
        assert_eq!(right_width(LayoutKind::TopTabs, 960.0, 0.0, false), 0.0);
        // Drawer open: its full width replaces the column.
        assert_eq!(
            right_width(LayoutKind::TopTabs, 1200.0, 1.0, true),
            queue_drawer::QUEUE_DRAWER_WIDTH
        );
        // Halfway through opening or closing.
        let half = right_width(LayoutKind::TopTabs, 1200.0, 0.5, true);
        assert!(half > 0.0 && half < queue_drawer::QUEUE_DRAWER_WIDTH);
        // Classic never has a column: shut means 0.
        assert_eq!(right_width(LayoutKind::Classic, 1440.0, 0.0, false), 0.0);
    }

    #[test]
    fn left_width_is_zero_without_a_sidebar() {
        assert_eq!(left_width(LayoutKind::TopTabs, 1.0), 0.0);
        assert_eq!(
            left_width(LayoutKind::Classic, 0.0),
            sidebar::SIDEBAR_COLLAPSED_WIDTH
        );
        assert_eq!(
            left_width(LayoutKind::Classic, 1.0),
            sidebar::SIDEBAR_EXPANDED_WIDTH
        );
    }

    #[test]
    fn the_bar_options_follow_the_layout_and_the_width() {
        assert_eq!(bar_options(LayoutKind::Classic, 800.0), BarOptions::CLASSIC);
        let wide = bar_options(LayoutKind::TopTabs, 1300.0);
        assert!(wide.times_below && wide.show_volume);
        let narrow = bar_options(LayoutKind::TopTabs, 1000.0);
        assert!(narrow.times_below && !narrow.show_volume);
        // The shared options never carry the mini visualizer: main fills that in.
        assert!(wide.mini.is_none() && narrow.mini.is_none());
        // The new bar layouts are calm (accent only on play and the progress fill); Classic is not.
        assert!(wide.calm && narrow.calm);
        assert!(bar_options(LayoutKind::LibraryList, 1300.0).calm);
        assert!(!bar_options(LayoutKind::Classic, 1300.0).calm);
    }

    #[test]
    fn each_layout_has_its_own_place_for_the_mini_visualizer_and_classic_has_none() {
        assert_eq!(mini_placement(LayoutKind::Classic), None);
        assert_eq!(
            mini_placement(LayoutKind::TopTabs),
            Some(MiniPlacement::Bar)
        );
        assert_eq!(
            mini_placement(LayoutKind::LibraryList),
            Some(MiniPlacement::Bar)
        );
        assert_eq!(mini_placement(LayoutKind::Dock), Some(MiniPlacement::Dock));
        assert_eq!(
            mini_placement(LayoutKind::PlayerPanel),
            Some(MiniPlacement::Panel)
        );
        for l in LayoutKind::ALL {
            assert_eq!(
                mini_placement(l).is_none(),
                l == LayoutKind::Classic,
                "{l:?}"
            );
        }
    }

    #[test]
    fn only_top_tabs_and_library_list_use_the_shelf_home_and_only_top_tabs_has_the_hero() {
        assert_eq!(shelf_home(LayoutKind::TopTabs), Some(true));
        assert_eq!(shelf_home(LayoutKind::LibraryList), Some(false));
        for l in [
            LayoutKind::Classic,
            LayoutKind::Dock,
            LayoutKind::PlayerPanel,
        ] {
            assert_eq!(shelf_home(l), None, "{l:?}");
        }
    }

    #[test]
    fn every_layout_but_classic_is_calm() {
        assert!(!is_calm(LayoutKind::Classic));
        for l in LayoutKind::ALL {
            assert_eq!(is_calm(l), l != LayoutKind::Classic, "{l:?}");
        }
    }

    #[test]
    fn top_height_is_the_title_bar_plus_the_row_under_it() {
        assert_eq!(top_height(LayoutKind::Classic), titlebar::HEIGHT);
        assert_eq!(
            top_height(LayoutKind::TopTabs),
            titlebar::HEIGHT + tabs::HEIGHT
        );
    }

    #[test]
    fn classic_stays_classic() {
        assert_eq!(arrangement_for(LayoutKind::Classic), LayoutKind::Classic);
    }

    #[test]
    fn every_layout_builds_a_view_from_the_slots() {
        // Pure element construction: no window or renderer is needed.
        for l in LayoutKind::ALL {
            let _view: Element<'_, ()> = arrange(l, slots());
        }
    }
}
