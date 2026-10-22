//! Cover art, best effort and only when asked for (`hgl art`, or right after an Epic / GOG import): Steam's CDN, Epic's key images, GOG's
//! box art, and SteamGridDB (needs your own key: `hgl config steamgriddb_key KEY`) for everything else. Nothing is fetched without
//! a game that lacks art, and nothing here can fail a launch.

use crate::epic;
use crate::json::{self, Json};
use crate::store::{Conf, Game};
use crate::util::*;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// True when the game has a picture that is not just the icon hgl took out of its .exe.
pub fn has_art(g: &Game) -> bool {
    if g.cover.is_empty() || !Path::new(&g.cover).is_file() {
        return false;
    }
    !g.cover.ends_with(&format!("/{}.png", g.id))
}

fn ext_of(url: &str) -> &'static str {
    let path = url.split(|c: char| c == '?' || c == '#').next().unwrap_or(url).to_ascii_lowercase();
    if path.ends_with(".png") {
        "png"
    } else if path.ends_with(".webp") {
        "webp"
    } else {
        "jpg"
    }
}

/// Download one picture into the covers folder. A failed or empty download leaves nothing behind.
fn grab(url: &str, id: &str) -> Option<PathBuf> {
    let dir = covers_dir();
    fs::create_dir_all(&dir).ok()?;
    let dest = dir.join(format!("{id}-art.{}", ext_of(url)));
    let tmp = dir.join(format!(".{id}-art.tmp{}", std::process::id()));
    if curl_run(url, None, Some(&tmp)).is_none() {
        let _ = fs::remove_file(&tmp);
        return None;
    }
    let size = fs::metadata(&tmp).map(|m| m.len()).unwrap_or(0);
    if size == 0 {
        let _ = fs::remove_file(&tmp);
        return None;
    }
    if fs::rename(&tmp, &dest).is_err() {
        let _ = fs::remove_file(&tmp);
        return None;
    }
    Some(dest)
}

fn digits(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_digit())
}

/// Portrait art first, the wide header as the fallback, on both of Valve's CDN hosts.
fn steam_urls(appid: &str) -> Vec<String> {
    let mut v = Vec::new();
    if !digits(appid) {
        return v;
    }
    for f in ["library_600x900.jpg", "header.jpg"] {
        v.push(format!("https://cdn.cloudflare.steamstatic.com/steam/apps/{appid}/{f}"));
        v.push(format!("https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/{appid}/{f}"));
    }
    v
}

/// GOG's box art, from the public product API (no login).
fn gog_url(id: &str) -> Option<String> {
    if !digits(id) {
        return None;
    }
    let body = curl_run(&format!("https://api.gog.com/v2/games/{id}"), None, None)?;
    let j = json::parse(&body)?;
    let links = j.get("_links")?;
    for k in ["boxArtImage", "iconSquare"] {
        if let Some(u) = links.get(k).and_then(|x| x.str("href")) {
            if u.starts_with("https://") {
                return Some(u.to_string());
            }
        }
    }
    None
}

/// SteamGridDB: search by name, then the first portrait grid of the first match.
fn sgdb_url(name: &str, key: &str) -> Option<String> {
    let hdr = format!("Authorization: Bearer {key}");
    let s = curl_run(&format!("https://www.steamgriddb.com/api/v2/search/autocomplete/{}", url_encode(name)), Some(hdr.as_str()), None)?;
    let j = json::parse(&s)?;
    let first = j.get("data")?.items().first()?;
    let gid = match first.get("id")? {
        Json::Num(n) => format!("{}", *n as u64),
        _ => return None,
    };
    let g = curl_run(&format!("https://www.steamgriddb.com/api/v2/grids/game/{gid}?dimensions=600x900&types=static"), Some(hdr.as_str()), None)?;
    let gj = json::parse(&g)?;
    let url = gj.get("data")?.items().first()?.str("url")?;
    if url.starts_with("https://") {
        Some(url.to_string())
    } else {
        None
    }
}

/// Things looked up once per run: the SteamGridDB key, and Epic's image list (one `legendary list`, not one per game).
pub struct Ctx {
    key: Option<String>,
    epic: Option<HashMap<String, String>>,
}

impl Ctx {
    pub fn new() -> Ctx {
        Ctx { key: Conf::load().get("steamgriddb_key").map(|s| s.to_string()), epic: None }
    }
    pub fn has_key(&self) -> bool {
        self.key.is_some()
    }
    fn epic_url(&mut self, app: &str) -> Option<String> {
        if self.epic.is_none() {
            self.epic = Some(epic::cover_map());
        }
        self.epic.as_ref().and_then(|m| m.get(app)).cloned()
    }
}

impl Default for Ctx {
    fn default() -> Ctx {
        Ctx::new()
    }
}

/// Look for art for this game and set `g.cover` (the caller saves). True when new art was found.
pub fn fetch(g: &mut Game, force: bool, cx: &mut Ctx) -> bool {
    if !force && has_art(g) {
        return false;
    }
    let mut urls: Vec<String> = Vec::new();
    match g.source.as_str() {
        "steam" => urls.extend(steam_urls(&g.appid)),
        "epic" => {
            if let Some(u) = cx.epic_url(&g.appid) {
                urls.push(u);
            }
        }
        "gog" => {
            if let Some(u) = gog_url(&g.appid) {
                urls.push(u);
            }
        }
        _ => {}
    }
    let mut got: Option<PathBuf> = None;
    for u in &urls {
        if let Some(p) = grab(u, &g.id) {
            got = Some(p);
            break;
        }
    }
    if got.is_none() {
        if let Some(key) = cx.key.clone() {
            if let Some(u) = sgdb_url(&g.name, &key) {
                got = grab(&u, &g.id);
            }
        }
    }
    match got {
        Some(p) => {
            g.cover = p.to_string_lossy().to_string();
            true
        }
        None => false,
    }
}

/// Fetch art for these games. Returns (found, tried). Each game is re-read before saving, so a setting changed meanwhile is kept.
pub fn fetch_ids(ids: &[String], force: bool) -> (usize, usize) {
    let mut cx = Ctx::new();
    let (mut found, mut tried) = (0, 0);
    for id in ids {
        let Ok(mut g) = Game::load(id) else { continue };
        if !force && has_art(&g) {
            continue;
        }
        tried += 1;
        if fetch(&mut g, force, &mut cx) {
            if let Ok(mut fresh) = Game::load(id) {
                fresh.cover = g.cover.clone();
                if fresh.save().is_ok() {
                    found += 1;
                }
            }
        }
    }
    (found, tried)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extensions() {
        assert_eq!(ext_of("https://x/a/b.PNG?v=2"), "png");
        assert_eq!(ext_of("https://x/a/b.webp"), "webp");
        assert_eq!(ext_of("https://x/a/b"), "jpg");
    }

    #[test]
    fn steam_urls_need_a_numeric_id() {
        assert_eq!(steam_urls("1145360").len(), 4);
        assert!(steam_urls("12;rm").is_empty());
    }

    #[test]
    fn the_extracted_icon_is_not_art() {
        let mut g = Game::new("hades", "Hades", "exe");
        let dir = std::env::temp_dir().join(format!("hgl-art-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        let icon = dir.join("hades.png");
        let _ = fs::write(&icon, "x");
        g.cover = icon.to_string_lossy().to_string();
        assert!(!has_art(&g));
        let art = dir.join("hades-art.jpg");
        let _ = fs::write(&art, "x");
        g.cover = art.to_string_lossy().to_string();
        assert!(has_art(&g));
        let _ = fs::remove_dir_all(&dir);
    }
}
