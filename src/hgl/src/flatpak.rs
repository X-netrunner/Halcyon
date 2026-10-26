//! Flatpak games: installed Flatpak apps whose desktop entry says Categories=...Game... (Sober, PrismLauncher, RetroArch ...).
//!
//! `hgl import flatpak` adds them (id `flatpak-<app id slug>`, source `flatpak`, the Flatpak app id in `appid`, the app's own icon
//! as art) and drops the ones that were uninstalled. They start with `flatpak run <app id>` and the game's launch options; Flatpak
//! gives each app its own sandbox and scope, so there is no Proton, prefix or wrapper. Lean island, Halcyon's gaming mode and the
//! environment variables (PRIME offload on a hybrid laptop) still apply.

use crate::store::{self, Game};
use crate::util::*;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq)]
pub struct App {
    pub id: String,
    pub name: String,
    pub icon: String,
}

pub fn id_for(app: &str) -> String {
    format!("flatpak-{}", slugify(app))
}

/// A Flatpak app id: reverse-DNS, letters, digits, dots, dashes and underscores only (it goes on a command line).
pub fn valid_app_id(s: &str) -> bool {
    s.contains('.') && !s.starts_with('.') && s.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// Name and Categories of a desktop entry ([Desktop Entry] section only).
fn desktop_fields(text: &str) -> (String, bool, String) {
    let (mut name, mut game, mut icon, mut main) = (String::new(), false, String::new(), false);
    for l in text.lines() {
        let l = l.trim();
        if l.starts_with('[') {
            main = l == "[Desktop Entry]";
            continue;
        }
        if !main {
            continue;
        }
        if let Some(v) = l.strip_prefix("Name=") {
            name = v.to_string();
        } else if let Some(v) = l.strip_prefix("Categories=") {
            game = v.split(';').any(|c| c == "Game");
        } else if let Some(v) = l.strip_prefix("Icon=") {
            icon = v.to_string();
        }
    }
    (name, game, icon)
}

/// The biggest icon the app exports (scalable first).
fn icon_path(loc: &Path, icon: &str) -> String {
    let base = loc.join("export/share/icons/hicolor");
    let mut best: Option<(u32, PathBuf)> = None;
    if let Ok(rd) = fs::read_dir(&base) {
        for e in rd.flatten() {
            let size = e.file_name().to_string_lossy().to_string();
            let rank = if size == "scalable" { 10_000 } else { size.split('x').next().and_then(|n| n.parse().ok()).unwrap_or(0) };
            for ext in ["svg", "png"] {
                let p = e.path().join("apps").join(format!("{icon}.{ext}"));
                if p.is_file() && best.as_ref().map(|b| rank > b.0).unwrap_or(true) {
                    best = Some((rank, p));
                }
            }
        }
    }
    best.map(|b| b.1.to_string_lossy().to_string()).unwrap_or_default()
}

/// Installed Flatpak games (user and system installations).
pub fn games() -> Vec<App> {
    let Some(list) = out("flatpak", &["list", "--app", "--columns=application"]) else { return vec![] };
    let mut v: Vec<App> = Vec::new();
    for id in list.lines().map(str::trim).filter(|s| valid_app_id(s)) {
        if v.iter().any(|a| a.id == id) {
            continue;
        }
        let Some(loc) = out("flatpak", &["info", "--show-location", id]) else { continue };
        let loc = PathBuf::from(loc.trim());
        let Ok(text) = fs::read_to_string(loc.join(format!("export/share/applications/{id}.desktop"))) else { continue };
        let (name, game, icon) = desktop_fields(&text);
        if game {
            v.push(App { id: id.to_string(), name: if name.is_empty() { id.to_string() } else { name }, icon: icon_path(&loc, if icon.is_empty() { id } else { &icon }) });
        }
    }
    v
}

/// Add new Flatpak games, refresh names, drop the uninstalled ones. Own settings are kept.
pub fn import() -> Result<(usize, usize, usize), String> {
    if !have("flatpak") {
        return Err("flatpak is not installed".into());
    }
    let apps = games();
    let (mut added, mut updated, mut removed) = (0, 0, 0);
    for a in &apps {
        let id = id_for(&a.id);
        match Game::load(&id) {
            Ok(mut g) => {
                let before = (g.name.clone(), g.cover.clone());
                g.name = a.name.clone();
                // art fetched later (hgl art) wins over the app icon
                if g.cover.is_empty() || !std::path::Path::new(&g.cover).is_file() {
                    g.cover = a.icon.clone();
                }
                if before != (g.name.clone(), g.cover.clone()) {
                    updated += 1;
                }
                g.save()?;
            }
            Err(_) => {
                let mut g = Game::new(&id, &a.name, "flatpak");
                g.appid = a.id.clone();
                g.cover = a.icon.clone();
                g.wrappers.clear();
                g.save()?;
                added += 1;
            }
        }
    }
    for g in store::all_games() {
        if g.source == "flatpak" && !apps.iter().any(|a| a.id == g.appid) {
            Game::remove(&g.id)?;
            removed += 1;
        }
    }
    Ok((added, updated, removed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn desktop_entry() {
        let t = "[Desktop Entry]\nName=Sober\nIcon=org.vinegarhq.Sober\nCategories=GNOME;GTK;Game;\n[Desktop Action Settings]\nName=Settings\n";
        assert_eq!(desktop_fields(t), ("Sober".into(), true, "org.vinegarhq.Sober".into()));
        assert!(!desktop_fields("[Desktop Entry]\nName=Files\nCategories=GNOME;Utility;\n").1);
        assert!(!desktop_fields("[Desktop Entry]\nName=X\nCategories=GameDev;\n").1);
    }

    #[test]
    fn app_ids() {
        assert!(valid_app_id("org.vinegarhq.Sober"));
        assert!(!valid_app_id("org.x; rm -rf ~"));
        assert!(!valid_app_id("noDots"));
        assert_eq!(id_for("org.vinegarhq.Sober"), "flatpak-org-vinegarhq-sober");
    }
}
