//! Steam library: read libraryfolders.vdf + appmanifest_*.acf, find cover art in Steam's local cache, import into the library.

use crate::store::{self, Game};
use crate::util::*;
use crate::vdf;
use std::fs;
use std::path::{Path, PathBuf};

pub struct SteamApp {
    pub appid: String,
    pub name: String,
    pub last_played: u64,
}

/// Steam install roots that exist on this machine (native, the ~/.steam symlinks, Flatpak).
pub fn roots() -> Vec<PathBuf> {
    let h = home();
    let cands = [
        data_home().join("Steam"),
        h.join(".steam/steam"),
        h.join(".steam/root"),
        h.join(".var/app/com.valvesoftware.Steam/.local/share/Steam"),
    ];
    let mut out: Vec<PathBuf> = Vec::new();
    for c in cands {
        if c.join("steamapps").is_dir() {
            let real = fs::canonicalize(&c).unwrap_or(c);
            if !out.contains(&real) {
                out.push(real);
            }
        }
    }
    out
}

/// Every library folder (the Steam root itself plus the extra drives in libraryfolders.vdf).
pub fn libraries() -> Vec<PathBuf> {
    let mut libs: Vec<PathBuf> = Vec::new();
    for root in roots() {
        if !libs.contains(&root) {
            libs.push(root.clone());
        }
        let text = fs::read_to_string(root.join("steamapps/libraryfolders.vdf")).unwrap_or_default();
        let v = vdf::parse(&text);
        if let Some(lf) = v.get("libraryfolders") {
            for (_, f) in lf.entries() {
                if let Some(p) = f.str("path") {
                    let p = PathBuf::from(p);
                    if p.is_absolute() && p.join("steamapps").is_dir() && !libs.contains(&p) {
                        libs.push(p);
                    }
                }
            }
        }
    }
    libs
}

/// Steam's own tools show up as "apps": not games.
fn is_tool(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    n.starts_with("proton ")
        || n == "proton"
        || n.starts_with("steam linux runtime")
        || n.starts_with("steamworks common")
        || n.starts_with("steam controller")
        || n.contains("redistributable")
}

pub fn parse_manifest(text: &str) -> Option<SteamApp> {
    let v = vdf::parse(text);
    let a = v.get("AppState")?;
    let appid = a.str("appid")?.to_string();
    if appid.is_empty() || !appid.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let name = a.str("name")?.to_string();
    // StateFlags bit 4 = fully installed
    let flags: u64 = a.str("StateFlags").and_then(|s| s.parse().ok()).unwrap_or(0);
    if flags & 4 == 0 || is_tool(&name) {
        return None;
    }
    Some(SteamApp { appid, name, last_played: a.str("LastPlayed").and_then(|s| s.parse().ok()).unwrap_or(0) })
}

pub fn installed_apps() -> Vec<SteamApp> {
    let mut apps: Vec<SteamApp> = Vec::new();
    for lib in libraries() {
        if let Ok(rd) = fs::read_dir(lib.join("steamapps")) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().to_string();
                if n.starts_with("appmanifest_") && n.ends_with(".acf") {
                    if let Ok(t) = fs::read_to_string(e.path()) {
                        if let Some(a) = parse_manifest(&t) {
                            if !apps.iter().any(|x| x.appid == a.appid) {
                                apps.push(a);
                            }
                        }
                    }
                }
            }
        }
    }
    apps.sort_by_cached_key(|a| a.name.to_lowercase());
    apps
}

/// Portrait art from Steam's local library cache. Old layout: <appid>_library_600x900.jpg; new layout: <appid>/<hash>/library_600x900.jpg.
pub fn find_cover(appid: &str) -> Option<PathBuf> {
    if !appid.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    for root in roots() {
        let cache = root.join("appcache/librarycache");
        for name in [format!("{appid}_library_600x900.jpg"), format!("{appid}_library_capsule.jpg"), format!("{appid}_header.jpg")] {
            let p = cache.join(&name);
            if p.is_file() {
                return Some(p);
            }
        }
        let dir = cache.join(appid);
        if dir.is_dir() {
            for want in ["library_600x900.jpg", "library_capsule.jpg", "header.jpg"] {
                if let Some(p) = find_file(&dir, want, 2) {
                    return Some(p);
                }
            }
        }
    }
    None
}

fn find_file(dir: &Path, name: &str, depth: u32) -> Option<PathBuf> {
    let rd = fs::read_dir(dir).ok()?;
    let mut subs = Vec::new();
    for e in rd.flatten() {
        let p = e.path();
        if p.is_file() && p.file_name().map(|n| n == name).unwrap_or(false) {
            return Some(p);
        }
        if p.is_dir() {
            subs.push(p);
        }
    }
    if depth > 0 {
        for s in subs {
            if let Some(f) = find_file(&s, name, depth - 1) {
                return Some(f);
            }
        }
    }
    None
}

pub fn id_for(appid: &str) -> String {
    format!("steam-{appid}")
}

/// Add new Steam games, refresh names and art, drop entries whose game was uninstalled. Own settings are kept.
pub fn import() -> Result<(usize, usize, usize), String> {
    if roots().is_empty() {
        return Err("no Steam installation found (looked in ~/.local/share/Steam, ~/.steam, Flatpak)".into());
    }
    let apps = installed_apps();
    let (mut added, mut updated, mut removed) = (0, 0, 0);
    for a in &apps {
        let id = id_for(&a.appid);
        let cover = find_cover(&a.appid).map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
        match Game::load(&id) {
            Ok(mut g) => {
                let before = (g.name.clone(), g.cover.clone());
                g.name = a.name.clone();
                // Steam's cache has no art for this game: keep the art `hgl art` fetched earlier instead of wiping it
                let keep = cover.is_empty() && !g.cover.is_empty() && Path::new(&g.cover).is_file();
                if !keep {
                    g.cover = cover;
                }
                g.last_played = g.last_played.max(a.last_played);
                if before != (g.name.clone(), g.cover.clone()) {
                    updated += 1;
                }
                g.save()?;
            }
            Err(_) => {
                let mut g = Game::new(&id, &a.name, "steam");
                g.appid = a.appid.clone();
                g.cover = cover;
                g.last_played = a.last_played;
                g.wrappers.clear();
                g.save()?;
                added += 1;
            }
        }
    }
    for g in store::all_games() {
        if g.source == "steam" && !apps.iter().any(|a| a.appid == g.appid) {
            Game::remove(&g.id)?;
            removed += 1;
        }
    }
    Ok((added, updated, removed))
}

/// The wine/game processes Steam started for this app: they carry SteamGameId in their environment.
pub fn game_pids(appid: &str) -> Vec<u32> {
    let want = format!("SteamGameId={appid}");
    let mut v = Vec::new();
    for (pid, _) in processes() {
        if let Ok(env) = fs::read(format!("/proc/{pid}/environ")) {
            if env.split(|b| *b == 0).any(|e| e == want.as_bytes()) {
                v.push(pid);
            }
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifests() {
        let ok = "\"AppState\" { \"appid\" \"1145360\" \"name\" \"Hades\" \"StateFlags\" \"4\" \"LastPlayed\" \"1700000000\" }";
        let a = parse_manifest(ok);
        assert!(a.is_some());
        assert_eq!(a.map(|a| a.last_played), Some(1_700_000_000));
        // still downloading
        assert!(parse_manifest("\"AppState\" { \"appid\" \"1\" \"name\" \"X\" \"StateFlags\" \"1026\" }").is_none());
        // Steam's own tools are not games
        assert!(parse_manifest("\"AppState\" { \"appid\" \"1493710\" \"name\" \"Proton Experimental\" \"StateFlags\" \"4\" }").is_none());
        assert!(parse_manifest("\"AppState\" { \"appid\" \"1628350\" \"name\" \"Steam Linux Runtime 3.0 (sniper)\" \"StateFlags\" \"4\" }").is_none());
        // appid must be numeric: it ends up in a command line and a file name
        assert!(parse_manifest("\"AppState\" { \"appid\" \"1;rm\" \"name\" \"X\" \"StateFlags\" \"4\" }").is_none());
    }
}
