//! The left column of the Library list layout (~160 px, on the frame surface, no fill of its own).
//!
//! Top: the account circle, then Home and Discover. Under them three small chips (Playlists,
//! Albums, Artists) pick what the list below shows. The list is the person's own library, taken
//! from the same data the Library page draws (`HalcyonApp::playlists`, `saved_albums`,
//! `followed_artists`): names and small covers only. Liked Songs is always the first row of
//! Playlists, with a heart cover. Opening a row sends the same message the Library page sends, so
//! the existing playlist, album and artist pages open.
//!
//! Calm: no accent anywhere. The lit row is text colour on the row tint; everything else is muted.

use crate::icons::{icon, Icon};
use crate::theme::{self, type_size, HalcyonPalette};
use crate::views::library::LibraryTab;
use crate::views::sidebar::NavPage;
use crate::views::tabs::Tab;
use halcyon_music_core::art::ArtSize;
use halcyon_music_core::models::{Album, Artist, Playlist};
use iced::widget::{button, column, container, row, scrollable, text, text_input, Space};
use iced::{Alignment, Element, Length};

pub const WIDTH: f32 = 160.0;
/// Space kept left and right of the rows, and above the account circle (`SM`).
pub const PAD: f32 = 8.0;
const COVER_PX: f32 = 30.0;
/// Chip text. Three chips have to fit in `WIDTH - 2 * PAD`, so it is a little under the caption size.
const CHIP_TEXT: f32 = 10.0;
/// Characters of a name before it is cut with an ellipsis (a row is about 90 px of text).
const NAME_CHARS: usize = 14;

/// The tab the chips show as lit. Liked Songs is the first row of Playlists, so that page keeps
/// the Playlists chip.
pub fn chip_tab(tab: LibraryTab) -> LibraryTab {
    if tab == LibraryTab::Liked {
        LibraryTab::Playlists
    } else {
        tab
    }
}

/// How many rows the list has for a chip. Playlists counts Liked Songs as its first row.
pub fn row_count(tab: LibraryTab, playlists: usize, albums: usize, artists: usize) -> usize {
    match chip_tab(tab) {
        LibraryTab::Albums => albums,
        LibraryTab::Artists => artists,
        _ => playlists + 1,
    }
}

/// A small pill that is lit (text colour on the row tint) when selected. Used for the three
/// library chips here and for Queue / Lyrics in the side panel.
pub fn chip<'a, M: Clone + 'a>(
    label: &'static str,
    selected: bool,
    text_size: f32,
    palette: HalcyonPalette,
    on_press: M,
) -> Element<'a, M> {
    let colour = if selected { palette.text } else { palette.text_muted };
    button(text(label).size(text_size).color(colour))
        .on_press(on_press)
        .padding([3, 3])
        .style(row_style(palette, selected, theme::radius::PILL))
        .into()
}

/// Button look for rows and chips: no fill, the row tint when lit, half of it under the pointer.
/// (The row tint, not the cover's dim tint: text sits on it and keeps 7:1.)
fn row_style(
    palette: HalcyonPalette,
    lit: bool,
    radius: f32,
) -> impl Fn(&iced::Theme, button::Status) -> button::Style + Copy {
    move |_t, status| {
        let hovered = matches!(status, button::Status::Hovered | button::Status::Pressed);
        let tint = palette.row_tint();
        button::Style {
            background: if lit {
                Some(tint.into())
            } else if hovered {
                Some(theme::alpha(tint, 0.5).into())
            } else {
                None
            },
            text_color: if lit || hovered { palette.text } else { palette.text_muted },
            border: iced::Border { radius: radius.into(), ..Default::default() },
            ..Default::default()
        }
    }
}

/// The Liked Songs cover: a heart on the dim tint (not the accent gradient of the Home card).
fn liked_cover<'a, M: 'a>(palette: HalcyonPalette) -> Element<'a, M> {
    let tint = palette.dim_tint();
    container(icon(Icon::Heart, COVER_PX * 0.45, palette.text))
        .width(COVER_PX)
        .height(COVER_PX)
        .center_x(COVER_PX)
        .center_y(COVER_PX)
        .style(move |_t| container::Style {
            background: Some(tint.into()),
            border: iced::Border { radius: theme::radius::ROW_COVER.into(), ..Default::default() },
            ..Default::default()
        })
        .into()
}

/// Home or Discover: icon and name.
fn nav_row<'a, M: Clone + 'a>(
    glyph: Icon,
    label: &'static str,
    lit: bool,
    palette: HalcyonPalette,
    on_press: M,
) -> Element<'a, M> {
    let colour = if lit { palette.text } else { palette.text_muted };
    button(
        row![icon(glyph, 16.0, colour), Space::with_width(10), text(label).size(type_size::BODY - 1.0).color(colour)]
            .align_y(Alignment::Center),
    )
    .on_press(on_press)
    .padding([6, 8])
    .width(Length::Fill)
    .style(row_style(palette, lit, theme::radius::SM))
    .into()
}

/// One row of the list: small cover and name.
fn list_row<'a, M: Clone + 'a>(
    cover: Element<'a, M>,
    name: &str,
    lit: bool,
    palette: HalcyonPalette,
    on_press: M,
) -> Element<'a, M> {
    let colour = if lit { palette.text } else { palette.text_muted };
    button(
        row![cover, Space::with_width(8), text(super::ellipsize(name, NAME_CHARS)).size(type_size::SMALL).color(colour)]
            .align_y(Alignment::Center),
    )
    .on_press(on_press)
    .padding([4, 6])
    .width(Length::Fill)
    .style(row_style(palette, lit, theme::radius::SM))
    .into()
}

/// What the column needs to know besides the data.
pub struct Context<'a> {
    pub active: NavPage,
    /// The playlist page that is open, if any (its row is lit).
    pub active_playlist: Option<&'a str>,
    pub tab: LibraryTab,
    pub show_new_input: bool,
    pub new_name: &'a str,
}

#[allow(clippy::too_many_arguments)]
pub fn view<'a, M: Clone + 'a>(
    ctx: Context<'a>,
    playlists: &'a [Playlist],
    albums: &'a [Album],
    artists: &'a [Artist],
    palette: HalcyonPalette,
    account: Element<'a, M>,
    on_nav: impl Fn(NavPage) -> M + 'a + Copy,
    on_tab: impl Fn(LibraryTab) -> M + 'a + Copy,
    on_open_playlist: impl Fn(String) -> M + 'a + Copy,
    on_open_album: impl Fn(String) -> M + 'a + Copy,
    on_open_artist: impl Fn(String) -> M + 'a + Copy,
    on_toggle_new: M,
    on_new_input: impl Fn(String) -> M + 'a,
    on_create: M,
) -> Element<'a, M> {
    let lit = Tab::for_page(ctx.active);
    let tab = chip_tab(ctx.tab);

    let mut col = column![
        account,
        Space::with_height(theme::space::SM),
        nav_row(Icon::Home, "Home", lit == Some(Tab::Home), palette, on_nav(NavPage::Home)),
        nav_row(Icon::Sparkles, "Discover", lit == Some(Tab::Discover), palette, on_nav(NavPage::Discover)),
        Space::with_height(theme::space::MD),
    ]
    .width(Length::Fill);

    // The chips. The plus (new playlist) sits on its own line, only while Playlists is shown.
    let mut chips = row![].spacing(2).align_y(Alignment::Center);
    for t in LibraryTab::all() {
        chips = chips.push(chip(t.label(), tab == *t, CHIP_TEXT, palette, on_tab(*t)));
    }
    col = col.push(chips);
    if tab == LibraryTab::Playlists {
        let plus = button(icon(Icon::Plus, 14.0, palette.text_muted))
            .on_press(on_toggle_new)
            .padding(4)
            .style(row_style(palette, false, theme::radius::PILL));
        col = col.push(row![Space::with_width(Length::Fill), plus].align_y(Alignment::Center));
        if ctx.show_new_input {
            col = col.push(
                text_input("Name your playlist", ctx.new_name)
                    .on_input(on_new_input)
                    .on_submit(on_create)
                    .padding([5, 8])
                    .size(type_size::SMALL),
            );
        }
    } else {
        col = col.push(Space::with_height(4));
    }

    // The list itself.
    let mut list = column![].spacing(2).width(Length::Fill).padding(iced::Padding {
        top: 2.0,
        right: 0.0,
        bottom: 16.0,
        left: 0.0,
    });
    match tab {
        LibraryTab::Albums => {
            for a in albums {
                let cover = crate::art::cover(
                    a.art_url.as_deref(),
                    ArtSize::Small,
                    COVER_PX,
                    theme::radius::ROW_COVER,
                    Icon::Album,
                    &a.title,
                    palette,
                );
                list = list.push(list_row(cover, &a.title, false, palette, on_open_album(a.id.clone())));
            }
        }
        LibraryTab::Artists => {
            for a in artists {
                let cover = crate::art::cover(
                    a.image_url.as_deref(),
                    ArtSize::Small,
                    COVER_PX,
                    COVER_PX / 2.0,
                    Icon::Artist,
                    &a.name,
                    palette,
                );
                list = list.push(list_row(cover, &a.name, false, palette, on_open_artist(a.id.clone())));
            }
        }
        _ => {
            list = list.push(list_row(
                liked_cover(palette),
                "Liked Songs",
                ctx.active == NavPage::Liked,
                palette,
                on_nav(NavPage::Liked),
            ));
            for p in playlists {
                let cover = crate::art::cover(
                    p.art_url.as_deref(),
                    ArtSize::Small,
                    COVER_PX,
                    theme::radius::ROW_COVER,
                    Icon::Playlist,
                    &p.name,
                    palette,
                );
                let is_open = ctx.active == NavPage::PlaylistDetail && ctx.active_playlist == Some(p.id.as_str());
                list = list.push(list_row(cover, &p.name, is_open, palette, on_open_playlist(p.id.clone())));
            }
        }
    }
    col = col.push(
        scrollable(list)
            .direction(scrollable::Direction::Vertical(
                scrollable::Scrollbar::new().width(0).scroller_width(0).margin(0),
            ))
            .height(Length::Fill)
            .width(Length::Fill),
    );

    container(col)
        .width(WIDTH)
        .height(Length::Fill)
        .padding(iced::Padding { top: theme::space::SM, right: PAD, bottom: 0.0, left: PAD })
        .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pl(id: &str) -> Playlist {
        Playlist { id: id.into(), name: format!("List {id}"), owner: "me".into(), snapshot_id: None, art_url: None, total_tracks: 3, uri: String::new() }
    }

    #[test]
    fn liked_songs_keeps_the_playlists_chip_lit() {
        assert_eq!(chip_tab(LibraryTab::Liked), LibraryTab::Playlists);
        assert_eq!(chip_tab(LibraryTab::Albums), LibraryTab::Albums);
        assert_eq!(chip_tab(LibraryTab::Artists), LibraryTab::Artists);
    }

    #[test]
    fn playlists_count_liked_songs_as_their_first_row() {
        assert_eq!(row_count(LibraryTab::Playlists, 0, 5, 6), 1);
        assert_eq!(row_count(LibraryTab::Liked, 4, 5, 6), 5);
        assert_eq!(row_count(LibraryTab::Albums, 4, 5, 6), 5);
        assert_eq!(row_count(LibraryTab::Artists, 4, 5, 6), 6);
    }

    #[test]
    fn the_column_builds_for_every_chip_with_and_without_data() {
        let palette = HalcyonPalette::for_mood(crate::theme::Mood::Dusk);
        let playlists = vec![pl("a"), pl("b")];
        let albums = vec![Album {
            id: "al".into(),
            title: "Album".into(),
            artist: "Artist".into(),
            art_url: None,
            release_date: None,
            total_tracks: 1,
            uri: String::new(),
        }];
        let artists = vec![Artist { id: "ar".into(), name: "Artist".into(), image_url: None, genres: vec![], uri: String::new() }];
        let no_playlists: Vec<Playlist> = Vec::new();
        let no_albums: Vec<Album> = Vec::new();
        let no_artists: Vec<Artist> = Vec::new();
        for tab in [LibraryTab::Playlists, LibraryTab::Albums, LibraryTab::Artists, LibraryTab::Liked] {
            for show_new_input in [false, true] {
                let sets: [(&[Playlist], &[Album], &[Artist]); 2] = [
                    (&playlists, &albums, &artists),
                    (&no_playlists, &no_albums, &no_artists),
                ];
                for (p, al, ar) in sets {
                    let _v: Element<'_, String> = view(
                        Context { active: NavPage::PlaylistDetail, active_playlist: Some("a"), tab, show_new_input, new_name: "" },
                        p,
                        al,
                        ar,
                        palette,
                        Space::new(32, 32).into(),
                        |_| "nav".to_string(),
                        |_| "tab".to_string(),
                        |id| id,
                        |id| id,
                        |id| id,
                        "toggle".to_string(),
                        |s| s,
                        "create".to_string(),
                    );
                }
            }
        }
    }
}
