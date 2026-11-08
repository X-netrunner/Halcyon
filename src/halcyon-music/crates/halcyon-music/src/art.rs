//! Cover art in the GUI.
//!
//! Flow: the app asks the daemon for covers (`GetArt`) whenever data arrives,
//! the daemon answers with `ArtReady { path }`, [`decode_task`] reads and
//! decodes the file on a blocking thread (never on the UI thread), and the
//! finished pixels are stored here under `(url, size)`. Views only ever call
//! [`cover`], which draws, in this order of preference:
//!
//! 1. the cover, fading in over [`FADE`] the first time it appears;
//! 2. a quiet placeholder block while the cover is on its way;
//! 3. a generated tile (colour from the title, plus an icon) when the item has
//!    no cover at all or the download failed.
//!
//! The store is a process-wide singleton so view functions stay pure
//! functions of their arguments; it is only touched from the UI thread.

use crate::icons::{icon, Icon};
use crate::theme::{extract_dominant_color, HalcyonPalette};
use halcyon_music_core::art::ArtSize;
use halcyon_music_core::models::{Album, Artist, HomeFeed, Playlist, Track};
use std::collections::HashSet;
use halcyon_music_core::protocol::CommandBody;
use iced::widget::image::Handle;
use iced::widget::{container, image as image_widget, Space};
use iced::{Color, ContentFit, Element, Length};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How long a cover takes to fade in.
pub const FADE: Duration = Duration::from_millis(360);
/// A failed cover is retried at most this often.
const RETRY_AFTER: Duration = Duration::from_secs(30);
/// Decoded pixels kept in memory (least recently drawn are dropped first).
const MAX_BYTES: usize = 160 * 1024 * 1024;
/// Largest edge we accept when decoding (guards against decompression bombs).
const MAX_DIMENSION: u32 = 4096;

type Key = (String, ArtSize);

enum Slot {
    /// `GetArt` sent, no answer yet.
    Requested,
    /// File is on disk, decode running.
    Decoding,
    Ready { handle: Handle, since: Instant, bytes: usize, dominant: Color },
    Failed(Instant),
}

struct Entry {
    slot: Slot,
    last_used: u64,
}

#[derive(Default)]
struct Store {
    entries: HashMap<Key, Entry>,
    clock: u64,
    ready_bytes: usize,
    fade_until: Option<Instant>,
    /// Covers drawn as circles (artist photos): corners are baked in at decode.
    circles: HashSet<String>,
}

/// What a view gets back for one cover.
enum Lookup {
    Ready { handle: Handle, fade_left: f32 },
    Pending,
    Failed,
    Missing,
}

impl Store {
    fn tick(&mut self) -> u64 {
        self.clock = self.clock.wrapping_add(1);
        self.clock
    }

    /// Reserve a cover for downloading. True means the caller must send `GetArt`.
    fn claim(&mut self, url: &str, size: ArtSize) -> bool {
        let key = (url.to_string(), size);
        let now = self.tick();
        match self.entries.get(&key) {
            None => {}
            Some(Entry { slot: Slot::Failed(at), .. }) if at.elapsed() >= RETRY_AFTER => {}
            Some(_) => return false,
        }
        self.entries.insert(key, Entry { slot: Slot::Requested, last_used: now });
        true
    }

    fn begin_decode(&mut self, url: &str, size: ArtSize) {
        let now = self.tick();
        self.entries.insert((url.to_string(), size), Entry { slot: Slot::Decoding, last_used: now });
    }

    fn fail(&mut self, url: &str, size: ArtSize) {
        let now = self.tick();
        if let Some(old) = self.entries.get(&(url.to_string(), size)) {
            if let Slot::Ready { bytes, .. } = old.slot {
                self.ready_bytes = self.ready_bytes.saturating_sub(bytes);
            }
        }
        self.entries.insert((url.to_string(), size), Entry { slot: Slot::Failed(Instant::now()), last_used: now });
    }

    fn finish(&mut self, url: &str, size: ArtSize, handle: Handle, bytes: usize, dominant: Color) {
        let now = self.tick();
        let since = Instant::now();
        // A little past the fade, so one last frame is drawn with the veil fully gone.
        self.fade_until = Some(since + FADE + Duration::from_millis(60));
        let key = (url.to_string(), size);
        if let Some(Entry { slot: Slot::Ready { bytes: old, .. }, .. }) = self.entries.get(&key) {
            self.ready_bytes = self.ready_bytes.saturating_sub(*old);
        }
        self.entries.insert(key, Entry { slot: Slot::Ready { handle, since, bytes, dominant }, last_used: now });
        self.ready_bytes += bytes;
        self.evict();
    }

    /// Drop the least recently drawn covers until under the memory budget.
    /// Dropped entries disappear completely, so the next data event asks again.
    fn evict(&mut self) {
        while self.ready_bytes > MAX_BYTES {
            let victim = self
                .entries
                .iter()
                .filter(|(_, e)| matches!(e.slot, Slot::Ready { .. }))
                .min_by_key(|(_, e)| e.last_used)
                .map(|(k, _)| k.clone());
            let Some(key) = victim else { break };
            if let Some(Entry { slot: Slot::Ready { bytes, .. }, .. }) = self.entries.remove(&key) {
                self.ready_bytes = self.ready_bytes.saturating_sub(bytes);
            }
        }
    }

    fn lookup(&mut self, url: &str, size: ArtSize) -> Lookup {
        let now = self.tick();
        match self.entries.get_mut(&(url.to_string(), size)) {
            None => Lookup::Missing,
            Some(entry) => {
                entry.last_used = now;
                match &entry.slot {
                    Slot::Ready { handle, since, .. } => {
                        let t = since.elapsed().as_secs_f32() / FADE.as_secs_f32();
                        Lookup::Ready { handle: handle.clone(), fade_left: (1.0 - t).clamp(0.0, 1.0) }
                    }
                    Slot::Requested | Slot::Decoding => Lookup::Pending,
                    Slot::Failed(_) => Lookup::Failed,
                }
            }
        }
    }

    fn dominant(&self, url: &str, size: ArtSize) -> Option<Color> {
        match self.entries.get(&(url.to_string(), size)) {
            Some(Entry { slot: Slot::Ready { dominant, .. }, .. }) => Some(*dominant),
            _ => None,
        }
    }

    /// Forget requests that can no longer be answered (daemon restarted).
    fn reset_pending(&mut self) {
        self.entries.retain(|_, e| !matches!(e.slot, Slot::Requested | Slot::Decoding));
    }
}

fn with_store<R>(f: impl FnOnce(&mut Store) -> R) -> R {
    static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
    let m = STORE.get_or_init(|| Mutex::new(Store::default()));
    let mut guard = m.lock().unwrap_or_else(|p| p.into_inner());
    f(&mut guard)
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

/// Turn (url, size) pairs into `GetArt` commands, skipping everything that is
/// already requested, decoding, cached in memory or recently failed.
pub fn commands_for<'a>(items: impl IntoIterator<Item = (Option<&'a str>, ArtSize)>) -> Vec<CommandBody> {
    with_store(|s| {
        items
            .into_iter()
            .filter_map(|(url, size)| {
                let url = url.filter(|u| !u.is_empty())?;
                s.claim(url, size)
                    .then(|| CommandBody::GetArt { url: url.to_string(), size })
            })
            .collect()
    })
}

pub fn track_row(t: &Track) -> (Option<&str>, ArtSize) {
    (t.art_url.as_deref(), ArtSize::Small)
}

/// Only what the Home page actually draws: quick-pick thumbnails and shelf cards.
pub fn home_items(feed: &HomeFeed) -> Vec<(Option<&str>, ArtSize)> {
    let mut v = Vec::new();
    v.extend(feed.quick_picks.iter().map(|p| (p.art_url.as_deref(), ArtSize::Small)));
    for shelf in [&feed.jump_back_in, &feed.new_releases, &feed.fresh_releases, &feed.popular_charts] {
        v.extend(shelf.iter().map(|i| (i.art_url.as_deref(), ArtSize::Medium)));
    }
    // Made-for-you cards cross-fade through their songs' covers, one after the other.
    for mix in &feed.made_for_you {
        v.push((mix.art_url.as_deref(), ArtSize::Small));
        v.extend(unique_covers(mix, crate::views::home::MIX_SLIDES).into_iter().map(|u| (Some(u), ArtSize::Medium)));
    }
    v
}

/// The first `max` different covers among a mix's songs, in order.
pub fn unique_covers(mix: &halcyon_music_core::models::MusicMix, max: usize) -> Vec<&str> {
    let mut uniq: Vec<&str> = Vec::new();
    for u in mix.tracks.iter().filter_map(|t| t.art_url.as_deref()).filter(|u| !u.is_empty()) {
        if !uniq.contains(&u) {
            uniq.push(u);
        }
        if uniq.len() == max {
            break;
        }
    }
    uniq
}

/// Every cover the Discover page draws.
pub fn discover_items(feed: &halcyon_music_core::models::DiscoverFeed) -> Vec<(Option<&str>, ArtSize)> {
    let mut v = Vec::new();
    for shelf in [&feed.new_albums, &feed.from_artists] {
        v.extend(shelf.iter().map(|i| (i.art_url.as_deref(), ArtSize::Medium)));
    }
    for list in [&feed.new_songs, &feed.trending] {
        v.extend(list.iter().map(|t| (t.art_url.as_deref(), ArtSize::Small)));
    }
    for mix in &feed.mixes {
        v.extend(mix.tracks.iter().map(|t| (t.art_url.as_deref(), ArtSize::Small)));
    }
    // Genre playlists are cards: one cover each (their songs load when a playlist is opened).
    v.extend(feed.genres.iter().map(|m| (m.art_url.as_deref(), ArtSize::Medium)));
    v
}

pub fn playlist_items(p: &[Playlist]) -> impl Iterator<Item = (Option<&str>, ArtSize)> {
    p.iter().map(|p| (p.art_url.as_deref(), ArtSize::Small))
}

pub fn album_items(a: &[Album]) -> impl Iterator<Item = (Option<&str>, ArtSize)> {
    a.iter().map(|a| (a.art_url.as_deref(), ArtSize::Medium))
}

pub fn artist_items(a: &[Artist]) -> Vec<(Option<&str>, ArtSize)> {
    with_store(|s| {
        for url in a.iter().filter_map(|a| a.image_url.as_deref()) {
            s.circles.insert(url.to_string());
        }
    });
    a.iter().map(|a| (a.image_url.as_deref(), ArtSize::Medium)).collect()
}

pub fn track_items(t: &[Track]) -> impl Iterator<Item = (Option<&str>, ArtSize)> {
    t.iter().map(track_row)
}

/// The cover of the playing track at every size the UI draws it.
pub fn now_playing_items(t: &Track) -> Vec<(Option<&str>, ArtSize)> {
    vec![
        (t.art_url.as_deref(), ArtSize::Small),
        (t.art_url.as_deref(), ArtSize::Large),
    ]
}

/// Call when the daemon connection (re)starts: answers in flight are lost.
pub fn connection_reset() {
    with_store(Store::reset_pending);
}

/// True while a cover is fading in; the app keeps a 60 fps tick during that.
pub fn is_fading() -> bool {
    with_store(|s| s.fade_until.is_some_and(|t| Instant::now() < t))
}

// ---------------------------------------------------------------------------
// Answers from the daemon
// ---------------------------------------------------------------------------

/// A decoded cover ready to store, plus its dominant colour (for the tint).
#[derive(Debug, Clone)]
pub struct Decoded {
    pub handle: Handle,
    pub bytes: usize,
    pub dominant: Color,
}

/// The daemon says the file exists: mark it and return the work to decode it.
pub fn decode_task(url: String, size: ArtSize, path: String) -> iced::Task<crate::Message> {
    let circle = with_store(|s| {
        s.begin_decode(&url, size);
        s.circles.contains(&url)
    });
    let (u, p) = (url.clone(), PathBuf::from(path));
    iced::Task::perform(
        async move {
            tokio::task::spawn_blocking(move || decode_file(&p, size, circle))
                .await
                .map_err(|e| e.to_string())
                .and_then(|r| r)
        },
        move |result| crate::Message::ArtDecoded { url: u.clone(), size, result: result.map(Box::new) },
    )
}

pub fn store_decoded(url: &str, size: ArtSize, d: Decoded) {
    with_store(|s| s.finish(url, size, d.handle, d.bytes, d.dominant));
}

/// Register `url` as a circular picture (corners baked in at decode) and give back the
/// request item for it. Used for the account picture.
pub fn avatar_items(url: &str) -> Vec<(Option<&str>, ArtSize)> {
    with_store(|s| {
        s.circles.insert(url.to_string());
    });
    vec![(Some(url), ArtSize::Small)]
}

/// Decode a picture that is a file on this machine (the Halcyon avatar) into the cover store under
/// `url` (see `avatar::local_url`), off the UI thread, as a circle. It goes through the same
/// `ArtDecoded` message as a cover from the daemon, so nothing else has to know about it.
pub fn local_decode_task(url: String, path: PathBuf) -> iced::Task<crate::Message> {
    let size = ArtSize::Small;
    with_store(|s| {
        s.circles.insert(url.clone());
        s.begin_decode(&url, size);
    });
    let u = url.clone();
    iced::Task::perform(
        async move {
            tokio::task::spawn_blocking(move || decode_file(&path, size, true))
                .await
                .map_err(|e| e.to_string())
                .and_then(|r| r)
        },
        move |result| crate::Message::ArtDecoded { url: u.clone(), size, result: result.map(Box::new) },
    )
}

/// True when the store has any entry for this cover (requested, decoding, ready or failed).
pub fn is_known(url: &str, size: ArtSize) -> bool {
    with_store(|s| s.entries.contains_key(&(url.to_string(), size)))
}

/// True when the cover is decoded and can be drawn right now.
pub fn is_ready(url: &str, size: ArtSize) -> bool {
    with_store(|s| matches!(s.entries.get(&(url.to_string(), size)), Some(Entry { slot: Slot::Ready { .. }, .. })))
}

/// Dominant colour of a cover that is already decoded (for the palette tint).
pub fn dominant(url: &str, size: ArtSize) -> Option<Color> {
    with_store(|s| s.dominant(url, size))
}

pub fn store_failed(url: &str, size: ArtSize) {
    with_store(|s| s.fail(url, size));
}

fn decode_file(path: &std::path::Path, size: ArtSize, circle: bool) -> Result<Decoded, String> {
    let mut reader = ::image::ImageReader::open(path)
        .map_err(|e| e.to_string())?
        .with_guessed_format()
        .map_err(|e| e.to_string())?;
    let mut limits = ::image::Limits::default();
    limits.max_image_width = Some(MAX_DIMENSION);
    limits.max_image_height = Some(MAX_DIMENSION);
    reader.limits(limits);
    let img = reader.decode().map_err(|e| e.to_string())?;

    // Covers are square; crop the middle of anything that is not.
    let side = img.width().min(img.height());
    if side == 0 {
        return Err("empty image".into());
    }
    let (x, y) = ((img.width() - side) / 2, (img.height() - side) / 2);
    let mut square = img.crop_imm(x, y, side, side);
    let target = size.px();
    if side > target {
        square = square.resize_exact(target, target, ::image::imageops::FilterType::Triangle);
    }

    let mut rgba = square.to_rgba8();
    let dominant = extract_dominant_color(rgba.as_raw());
    let (w, h) = (rgba.width(), rgba.height());
    let fraction = if circle { 0.5 } else { CORNER_FRACTION };
    round_corners(&mut rgba, w, h, w as f32 * fraction);
    let bytes = rgba.as_raw().len();
    Ok(Decoded { handle: Handle::from_rgba(w, h, rgba.into_raw()), bytes, dominant })
}

/// Corner radius as a fraction of the cover's edge, baked into the pixels so
/// covers look right without depending on widget clipping.
const CORNER_FRACTION: f32 = 0.07;

/// Multiply alpha by an anti-aliased rounded-rectangle mask. `px` is RGBA8.
pub fn round_corners(px: &mut [u8], w: u32, h: u32, radius: f32) {
    if radius < 1.0 || w == 0 || h == 0 {
        return;
    }
    let r = radius.min(w.min(h) as f32 / 2.0);
    let ri = r.ceil() as u32;
    for corner_y in 0..ri.min(h) {
        for corner_x in 0..ri.min(w) {
            // Mirror the one corner into all four.
            let (cx, cy) = (r, r);
            let (fx, fy) = (corner_x as f32 + 0.5, corner_y as f32 + 0.5);
            let dist = ((fx - cx).powi(2) + (fy - cy).powi(2)).sqrt();
            let coverage = (r - dist + 0.5).clamp(0.0, 1.0);
            if coverage >= 1.0 {
                continue;
            }
            for (px_x, px_y) in [
                (corner_x, corner_y),
                (w - 1 - corner_x, corner_y),
                (corner_x, h - 1 - corner_y),
                (w - 1 - corner_x, h - 1 - corner_y),
            ] {
                let idx = ((px_y as usize) * (w as usize) + px_x as usize) * 4 + 3;
                if let Some(a) = px.get_mut(idx) {
                    *a = (*a as f32 * coverage).round() as u8;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The widget
// ---------------------------------------------------------------------------

/// A cover of `px` x `px` logical pixels. `label` seeds the colour of the
/// generated tile; `fallback` is the glyph drawn on it.
pub fn cover<'a, M: 'a>(
    url: Option<&str>,
    size: ArtSize,
    px: f32,
    radius: f32,
    fallback: Icon,
    label: &str,
    palette: HalcyonPalette,
) -> Element<'a, M> {
    let lookup = match url.filter(|u| !u.is_empty()) {
        Some(u) => with_store(|s| s.lookup(u, size)),
        None => Lookup::Failed,
    };

    match lookup {
        Lookup::Ready { handle, fade_left } => {
            // The fade-in lowers the picture's own opacity over a placeholder-coloured
            // background, all in ONE draw layer. (It used to stack a veil over the picture;
            // a stacked layer is drawn after the whole window, so it could land on top of
            // the player bar while a card was scrolled partly out of view.)
            let opacity = if fade_left > 0.0 { (1.0 - fade_left).clamp(0.0, 1.0) } else { 1.0 };
            let pic: iced::widget::Image<Handle> = image_widget(handle)
                .width(Length::Fixed(px))
                .height(Length::Fixed(px))
                .content_fit(ContentFit::Cover)
                .opacity(opacity);
            let placeholder = palette.surface_variant;
            let fading = fade_left > 0.0;
            container(pic)
                .width(Length::Fixed(px))
                .height(Length::Fixed(px))
                .style(move |_t| container::Style {
                    background: fading.then(|| placeholder.into()),
                    border: iced::Border { radius: radius.into(), ..Default::default() },
                    shadow: iced::Shadow {
                        color: Color { a: if px >= 120.0 { 0.35 } else { 0.18 }, ..Color::BLACK },
                        offset: iced::Vector::new(0.0, if px >= 120.0 { 10.0 } else { 3.0 }),
                        blur_radius: if px >= 120.0 { 28.0 } else { 10.0 },
                    },
                    ..Default::default()
                })
                .into()
        }
        Lookup::Pending | Lookup::Missing => block(px, radius, palette.surface_variant, None),
        Lookup::Failed => {
            let (bg, fg) = tile_colors(label);
            block(px, radius, bg, Some(icon(fallback, (px * 0.42).max(10.0), fg)))
        }
    }
}

/// The cover drawn at `opacity` (0.0 ..= 1.0) with no shadow, for laying one cover over another
/// to cross-fade. `None` when the picture is not decoded yet: the caller then just keeps
/// showing what it has, so a slideshow never fades to a grey placeholder.
pub fn cover_overlay<'a, M: 'a>(url: &str, size: ArtSize, px: f32, radius: f32, opacity: f32) -> Option<Element<'a, M>> {
    match with_store(|s| s.lookup(url, size)) {
        Lookup::Ready { handle, .. } => {
            let pic: iced::widget::Image<Handle> = image_widget(handle)
                .width(Length::Fixed(px))
                .height(Length::Fixed(px))
                .content_fit(ContentFit::Cover)
                .opacity(opacity.clamp(0.0, 1.0));
            Some(
                container(pic)
                    .width(Length::Fixed(px))
                    .height(Length::Fixed(px))
                    .style(move |_t| container::Style {
                        border: iced::Border { radius: radius.into(), ..Default::default() },
                        ..Default::default()
                    })
                    .into(),
            )
        }
        _ => None,
    }
}

fn block<'a, M: 'a>(
    px: f32,
    radius: f32,
    bg: Color,
    glyph: Option<iced::widget::svg::Svg<'a>>,
) -> Element<'a, M> {
    let inner: Element<'a, M> = match glyph {
        Some(g) => g.into(),
        None => Space::new(Length::Shrink, Length::Shrink).into(),
    };
    container(inner)
        .width(Length::Fixed(px))
        .height(Length::Fixed(px))
        .center_x(Length::Fixed(px))
        .center_y(Length::Fixed(px))
        .style(move |_t| container::Style {
            background: Some(bg.into()),
            border: iced::Border { radius: radius.into(), ..Default::default() },
            ..Default::default()
        })
        .into()
}

/// Stable (background, glyph) colours derived from a title, so the same
/// playlist always gets the same tile.
pub fn tile_colors(label: &str) -> (Color, Color) {
    let mut h: u32 = 2166136261;
    for b in label.bytes() {
        h ^= b as u32;
        h = h.wrapping_mul(16777619);
    }
    let hue = (h % 360) as f32;
    (hsl(hue, 0.26, 0.30), hsl(hue, 0.50, 0.82))
}

fn hsl(h: f32, s: f32, l: f32) -> Color {
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let hp = h / 60.0;
    let x = c * (1.0 - (hp % 2.0 - 1.0).abs());
    let (r1, g1, b1) = match hp as u32 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = l - c / 2.0;
    Color::from_rgb(r1 + m, g1 + m, b1 + m)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dummy_handle() -> Handle {
        Handle::from_rgba(1, 1, vec![0u8, 0, 0, 255])
    }

    #[test]
    fn claim_is_once_per_cover_and_size() {
        let mut s = Store::default();
        assert!(s.claim("u", ArtSize::Small));
        assert!(!s.claim("u", ArtSize::Small), "already requested");
        assert!(s.claim("u", ArtSize::Large), "other size is a different cover");
    }

    #[test]
    fn failed_covers_are_retried_only_after_a_pause() {
        let mut s = Store::default();
        s.claim("u", ArtSize::Small);
        s.fail("u", ArtSize::Small);
        assert!(!s.claim("u", ArtSize::Small));
        assert!(matches!(s.lookup("u", ArtSize::Small), Lookup::Failed));
        // Pretend the failure is old.
        if let Some(e) = s.entries.get_mut(&("u".to_string(), ArtSize::Small)) {
            e.slot = Slot::Failed(Instant::now() - RETRY_AFTER - Duration::from_secs(1));
        }
        assert!(s.claim("u", ArtSize::Small));
    }

    #[test]
    fn lifecycle_requested_decoding_ready() {
        let mut s = Store::default();
        assert!(matches!(s.lookup("u", ArtSize::Small), Lookup::Missing));
        s.claim("u", ArtSize::Small);
        assert!(matches!(s.lookup("u", ArtSize::Small), Lookup::Pending));
        s.begin_decode("u", ArtSize::Small);
        assert!(matches!(s.lookup("u", ArtSize::Small), Lookup::Pending));
        s.finish("u", ArtSize::Small, dummy_handle(), 4, Color::BLACK);
        assert!(matches!(s.lookup("u", ArtSize::Small), Lookup::Ready { .. }));
        assert!(s.fade_until.is_some());
    }

    #[test]
    fn reset_pending_keeps_finished_covers() {
        let mut s = Store::default();
        s.claim("a", ArtSize::Small);
        s.claim("b", ArtSize::Small);
        s.finish("b", ArtSize::Small, dummy_handle(), 4, Color::BLACK);
        s.reset_pending();
        assert!(matches!(s.lookup("a", ArtSize::Small), Lookup::Missing));
        assert!(matches!(s.lookup("b", ArtSize::Small), Lookup::Ready { .. }));
    }

    #[test]
    fn eviction_drops_least_recently_drawn_first() {
        let mut s = Store::default();
        s.finish("old", ArtSize::Medium, dummy_handle(), MAX_BYTES / 2 + 1, Color::BLACK);
        s.finish("new", ArtSize::Medium, dummy_handle(), MAX_BYTES / 2 + 1, Color::BLACK);
        // Total now exceeds the budget: "old" goes, and can be requested again.
        assert!(matches!(s.lookup("old", ArtSize::Medium), Lookup::Missing));
        assert!(matches!(s.lookup("new", ArtSize::Medium), Lookup::Ready { .. }));
        assert!(s.ready_bytes <= MAX_BYTES);
        assert!(s.claim("old", ArtSize::Medium));
    }

    #[test]
    fn rounded_corners_clear_the_corner_but_not_the_middle() {
        let (w, h) = (40u32, 40u32);
        let mut px = vec![255u8; (w * h * 4) as usize];
        round_corners(&mut px, w, h, 10.0);
        let alpha = |x: u32, y: u32| px[((y * w + x) * 4 + 3) as usize];
        assert_eq!(alpha(0, 0), 0);
        assert_eq!(alpha(w - 1, 0), 0);
        assert_eq!(alpha(0, h - 1), 0);
        assert_eq!(alpha(w - 1, h - 1), 0);
        assert_eq!(alpha(w / 2, h / 2), 255);
        assert_eq!(alpha(w / 2, 0), 255, "edges between corners stay opaque");
    }

    #[test]
    fn a_circular_mask_leaves_transparent_corners_and_an_opaque_centre() {
        // The account picture is masked with radius = half the edge, at decode time.
        let (w, h) = (64u32, 64u32);
        let mut px = vec![255u8; (w * h * 4) as usize];
        round_corners(&mut px, w, h, w as f32 * 0.5);
        let alpha = |x: u32, y: u32| px[((y * w + x) * 4 + 3) as usize];
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
            assert_eq!(alpha(x, y), 0, "corner ({x},{y})");
        }
        assert_eq!(alpha(w / 2, h / 2), 255);
        // The middle of each edge touches the circle, so it stays (nearly) opaque.
        assert!(alpha(w / 2, 1) > 200);
    }

    #[test]
    fn tile_colors_are_stable_and_differ_by_title() {
        assert_eq!(tile_colors("Liked Songs"), tile_colors("Liked Songs"));
        assert_ne!(tile_colors("Liked Songs"), tile_colors("Road Trip"));
    }

    #[test]
    fn commands_skip_items_without_a_url() {
        let cmds = commands_for([(None, ArtSize::Small), (Some(""), ArtSize::Small), (Some("https://x/test-cmds"), ArtSize::Small)]);
        assert_eq!(cmds.len(), 1);
        assert!(matches!(cmds[0], CommandBody::GetArt { .. }));
    }
}
