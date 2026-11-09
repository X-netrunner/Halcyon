//! The library on disk: one `key=value` file per game in ~/.config/Halcyon/games/<id>.conf, plus hgl.conf for global options.

use crate::util::*;
use std::fs;
use std::path::PathBuf;

pub const WRAPPERS: &[&str] = &["gamemode", "mangohud"];

#[derive(Clone, Debug, Default)]
pub struct Game {
    pub id: String,
    pub name: String,
    /// exe | steam | epic | gog
    pub source: String,
    pub exe: String,
    pub appid: String,
    pub umu_id: String,
    pub proton: String,
    pub prefix: String,
    pub args: String,
    pub wrappers: Vec<String>,
    pub gamescope: String,
    pub wayland: bool,
    pub lean: bool,
    /// Hyprland fullscreen for the game's windows while it runs (`hgl run` watches for them)
    pub fullscreen: bool,
    pub debug: bool,
    /// favourite: listed first (Game Center, `>game` in the launcher)
    pub fav: bool,
    pub cover: String,
    pub last_played: u64,
    pub playtime: u64,
    pub last_exit: Option<i32>,
    pub last_run_secs: u64,
    pub env: Vec<(String, String)>,
    pub unknown: Vec<(String, String)>,
}

impl Game {
    pub fn new(id: &str, name: &str, source: &str) -> Game {
        Game {
            id: id.to_string(),
            name: name.to_string(),
            source: source.to_string(),
            wrappers: vec!["gamemode".to_string()],
            lean: true,
            ..Game::default()
        }
    }

    pub fn path(id: &str) -> PathBuf {
        games_dir().join(format!("{id}.conf"))
    }

    pub fn parse(id: &str, text: &str) -> Game {
        let mut g = Game::new(id, id, "exe");
        g.wrappers.clear();
        for (k, v) in parse_kv(text) {
            if let Some(name) = k.strip_prefix("env.") {
                if valid_env_name(name) {
                    g.env.push((name.to_string(), v));
                }
                continue;
            }
            match k.as_str() {
                "name" => g.name = v,
                "source" => g.source = v,
                "exe" => g.exe = v,
                "appid" => g.appid = v,
                "umu_id" => g.umu_id = v,
                "proton" => g.proton = v,
                "prefix" => g.prefix = v,
                "args" => g.args = v,
                "wrappers" => g.wrappers = v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect(),
                "gamescope" => g.gamescope = v,
                "wayland" => g.wayland = parse_bool(&v).unwrap_or(false),
                "lean" => g.lean = parse_bool(&v).unwrap_or(true),
                "fullscreen" => g.fullscreen = parse_bool(&v).unwrap_or(false),
                "debug" => g.debug = parse_bool(&v).unwrap_or(false),
                "fav" => g.fav = parse_bool(&v).unwrap_or(false),
                "cover" => g.cover = v,
                "last_played" => g.last_played = v.parse().unwrap_or(0),
                "playtime" => g.playtime = v.parse().unwrap_or(0),
                "last_exit" => g.last_exit = v.parse().ok(),
                "last_run_secs" => g.last_run_secs = v.parse().unwrap_or(0),
                _ => g.unknown.push((k, v)),
            }
        }
        g
    }

    pub fn serialize(&self) -> String {
        let mut s = String::from("# Halcyon game profile (edit with `hgl set`, or by hand)\n");
        let mut put = |k: &str, v: &str| {
            if !v.is_empty() {
                s.push_str(&format!("{k}={v}\n"));
            }
        };
        put("name", &self.name);
        put("source", &self.source);
        put("exe", &self.exe);
        put("appid", &self.appid);
        put("umu_id", &self.umu_id);
        put("proton", &self.proton);
        put("prefix", &self.prefix);
        put("args", &self.args);
        put("gamescope", &self.gamescope);
        put("cover", &self.cover);
        let wr = self.wrappers.join(",");
        s.push_str(&format!("wrappers={wr}\n"));
        s.push_str(&format!("wayland={}\n", self.wayland as u8));
        s.push_str(&format!("lean={}\n", self.lean as u8));
        if self.fullscreen {
            s.push_str("fullscreen=1\n");
        }
        s.push_str(&format!("debug={}\n", self.debug as u8));
        if self.fav {
            s.push_str("fav=1\n");
        }
        s.push_str(&format!("last_played={}\n", self.last_played));
        s.push_str(&format!("playtime={}\n", self.playtime));
        if let Some(c) = self.last_exit {
            s.push_str(&format!("last_exit={c}\n"));
        }
        s.push_str(&format!("last_run_secs={}\n", self.last_run_secs));
        for (k, v) in &self.env {
            s.push_str(&format!("env.{k}={v}\n"));
        }
        for (k, v) in &self.unknown {
            s.push_str(&format!("{k}={v}\n"));
        }
        s
    }

    pub fn load(id: &str) -> Result<Game, String> {
        if !valid_id(id) {
            return Err(format!("not a valid game id: {id}"));
        }
        match fs::read_to_string(Game::path(id)) {
            Ok(t) => Ok(Game::parse(id, &t)),
            Err(_) => Err(format!("no game with id '{id}' (see: hgl list)")),
        }
    }

    pub fn save(&self) -> Result<(), String> {
        if !valid_id(&self.id) {
            return Err(format!("not a valid game id: {}", self.id));
        }
        atomic_write(&Game::path(&self.id), &self.serialize()).map_err(|e| format!("cannot write {}: {e}", Game::path(&self.id).display()))
    }

    pub fn remove(id: &str) -> Result<(), String> {
        if !valid_id(id) {
            return Err(format!("not a valid game id: {id}"));
        }
        fs::remove_file(Game::path(id)).map_err(|e| format!("cannot remove {id}: {e}"))
    }

    pub fn prefix_path(&self) -> PathBuf {
        if self.prefix.is_empty() {
            prefixes_dir().join(&self.id)
        } else {
            PathBuf::from(&self.prefix)
        }
    }

    /// `hgl set <id> <key> <value>`
    pub fn set(&mut self, key: &str, val: &str) -> Result<(), String> {
        if val.contains('\n') || val.contains('\r') {
            return Err("a value cannot contain a line break".into());
        }
        if let Some(name) = key.strip_prefix("env.") {
            if !valid_env_name(name) {
                return Err(format!("not a valid environment variable name: {name}"));
            }
            self.env.retain(|(k, _)| k != name);
            if !val.is_empty() {
                self.env.push((name.to_string(), val.to_string()));
            }
            return Ok(());
        }
        let b = || parse_bool(val).ok_or_else(|| format!("{key} takes on/off (got '{val}')"));
        match key {
            "name" => {
                if val.is_empty() {
                    return Err("the name cannot be empty".into());
                }
                self.name = val.into()
            }
            "exe" => self.exe = val.into(),
            "umu_id" => self.umu_id = val.into(),
            "proton" => self.proton = val.into(),
            "prefix" => self.prefix = val.into(),
            "args" => self.args = val.into(),
            "gamescope" => self.gamescope = val.into(),
            "cover" => self.cover = val.into(),
            "wayland" => self.wayland = b()?,
            "lean" => self.lean = b()?,
            "fullscreen" => self.fullscreen = b()?,
            "debug" => self.debug = b()?,
            "fav" => self.fav = b()?,
            "wrappers" => {
                let list: Vec<String> = val.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
                for w in &list {
                    if !WRAPPERS.contains(&w.as_str()) {
                        return Err(format!("unknown wrapper '{w}' (known: {})", WRAPPERS.join(", ")));
                    }
                }
                self.wrappers = list;
            }
            _ => return Err(format!("unknown key '{key}' (name, exe, proton, prefix, args, wrappers, gamescope, wayland, lean, fullscreen, debug, umu_id, cover, env.NAME)")),
        }
        Ok(())
    }

    pub fn wrapper_on(&self, w: &str) -> bool {
        self.wrappers.iter().any(|x| x == w)
    }
}

/// What an import (Epic, GOG) did: the ids of new games, how many were refreshed, how many left the library.
#[derive(Default, Debug)]
pub struct Imported {
    pub added: Vec<String>,
    pub updated: usize,
    pub removed: usize,
}

/// Where Epic and GOG games are installed: `games_dir` in hgl.conf, else ~/Games/Halcyon.
pub fn games_root(cfg: &Conf) -> PathBuf {
    match cfg.get("games_dir").map(expand_home) {
        Some(p) if p.is_absolute() => p,
        _ => home().join("Games").join("Halcyon"),
    }
}

pub fn list_ids() -> Vec<String> {
    let mut ids = Vec::new();
    if let Ok(rd) = fs::read_dir(games_dir()) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if let Some(id) = n.strip_suffix(".conf") {
                if valid_id(id) {
                    ids.push(id.to_string());
                }
            }
        }
    }
    ids
}

/// Favourites first, then last played, then by name.
pub fn all_games() -> Vec<Game> {
    let mut v: Vec<Game> = list_ids().iter().filter_map(|id| Game::load(id).ok()).collect();
    v.sort_by(|a, b| b.fav.cmp(&a.fav).then_with(|| b.last_played.cmp(&a.last_played).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))));
    v
}

/// A free id for this name (`name`, `name-2`, ...).
pub fn unique_id(name: &str) -> String {
    let base = slugify(name);
    if !Game::path(&base).exists() {
        return base;
    }
    let mut n = 2;
    loop {
        let id = format!("{base}-{n}");
        if !Game::path(&id).exists() {
            return id;
        }
        n += 1;
    }
}

/// Global options: ~/.config/Halcyon/hgl.conf
pub struct Conf {
    pairs: Vec<(String, String)>,
}

impl Conf {
    fn path() -> PathBuf {
        config_dir().join("hgl.conf")
    }
    pub fn load() -> Conf {
        Conf { pairs: fs::read_to_string(Conf::path()).map(|t| parse_kv(&t)).unwrap_or_default() }
    }
    pub fn get(&self, k: &str) -> Option<&str> {
        self.pairs.iter().rev().find(|(key, _)| key == k).map(|(_, v)| v.as_str()).filter(|v| !v.is_empty())
    }
    pub fn flag(&self, k: &str, default: bool) -> bool {
        self.get(k).and_then(parse_bool).unwrap_or(default)
    }
    pub fn num(&self, k: &str, default: u64) -> u64 {
        self.get(k).and_then(|v| v.parse().ok()).unwrap_or(default)
    }
    pub fn set(&mut self, k: &str, v: &str) -> Result<(), String> {
        self.pairs.retain(|(key, _)| key != k);
        self.pairs.push((k.to_string(), v.to_string()));
        let mut s = String::from("# Halcyon game launcher options\n# proton_family=ge|cachyos  proton_default=<runtime>  proton_keep=3  steam_link=0|1\n# game_weight=800  halcyon_weight=20  halcyon_throttle=1  halcyon_core=<cpu number, empty = off>\n# games_dir=<where Epic and GOG games install>  steamgriddb_key=<API key for cover art>  epic_config=<legendary config folder>\n# gogdl=<gogdl program>  gog_dirs=<extra folders with GOG games, separated by :>\n");
        for (k, v) in &self.pairs {
            if !v.is_empty() {
                s.push_str(&format!("{k}={v}\n"));
            }
        }
        atomic_write(&Conf::path(), &s).map_err(|e| format!("cannot write {}: {e}", Conf::path().display()))?;
        // the file may hold an API key: only this user reads it
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(Conf::path(), fs::Permissions::from_mode(0o600));
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let mut g = Game::new("hades", "Hades", "exe");
        g.exe = "/games/Hades/Hades.exe".into();
        g.set("env.DXVK_HUD", "fps").unwrap_or(());
        g.set("wrappers", "gamemode,mangohud").unwrap_or(());
        g.set("wayland", "on").unwrap_or(());
        g.unknown.push(("future_key".into(), "x".into()));
        let t = g.serialize();
        let h = Game::parse("hades", &t);
        assert_eq!(h.name, "Hades");
        assert_eq!(h.exe, "/games/Hades/Hades.exe");
        assert_eq!(h.env, vec![("DXVK_HUD".to_string(), "fps".to_string())]);
        assert_eq!(h.wrappers, vec!["gamemode", "mangohud"]);
        assert!(h.wayland && h.lean && !h.fav);
        g.set("fav", "on").unwrap_or(());
        assert!(Game::parse("hades", &g.serialize()).fav);
        assert!(!h.fullscreen);
        g.set("fullscreen", "on").unwrap_or(());
        assert!(Game::parse("hades", &g.serialize()).fullscreen);
        assert_eq!(h.unknown, vec![("future_key".to_string(), "x".to_string())]);
    }

    #[test]
    fn set_validation() {
        let mut g = Game::new("a", "A", "exe");
        assert!(g.set("wrappers", "gamemode,evil").is_err());
        assert!(g.set("wayland", "maybe").is_err());
        assert!(g.set("args", "a\nb").is_err());
        assert!(g.set("env.1BAD", "x").is_err());
        assert!(g.set("nope", "x").is_err());
        g.set("env.A", "1").unwrap_or(());
        g.set("env.A", "").unwrap_or(());
        assert!(g.env.is_empty());
    }
}
