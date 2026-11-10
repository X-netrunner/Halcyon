//! Known per-game fixes: a small text database (fixes.db, built in; ~/.config/Halcyon/hgl-fixes.conf, yours) of notes, environment
//! variables and settings for games that need them. Settings are applied once, when a game is added or imported.

use crate::store::Game;
use crate::util::*;

const BUILTIN: &str = include_str!("../fixes.db");

/// The `hgl set` keys a fix may change. Never `exe`, `proton`, `prefix`: a database entry must not point a game somewhere else.
const SETTABLE: &[&str] = &["wrappers", "args", "wayland", "gamescope", "umu_id", "lean", "debug"];

#[derive(Clone, Debug, Default)]
pub struct Fix {
    /// lowercase selectors: `steam:1085660`, `epic:fortnite`, `gog:123`, `name:text`
    pub keys: Vec<String>,
    pub note: String,
    pub env: Vec<(String, String)>,
    pub sets: Vec<(String, String)>,
}

pub fn parse(text: &str) -> Vec<Fix> {
    let mut v: Vec<Fix> = Vec::new();
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        if let Some(inner) = t.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
            let keys: Vec<String> = inner.split(',').map(|s| s.trim().to_ascii_lowercase()).filter(|s| !s.is_empty()).collect();
            v.push(Fix { keys, ..Fix::default() });
            continue;
        }
        let Some(cur) = v.last_mut() else { continue };
        let Some((k, val)) = t.split_once('=') else { continue };
        let (k, val) = (k.trim(), val.trim());
        if k == "note" {
            cur.note = val.to_string();
        } else if let Some(n) = k.strip_prefix("env.") {
            if valid_env_name(n) {
                cur.env.push((n.to_string(), val.to_string()));
            }
        } else if let Some(s) = k.strip_prefix("set.") {
            if SETTABLE.contains(&s) {
                cur.sets.push((s.to_string(), val.to_string()));
            }
        }
    }
    v
}

pub struct Db {
    fixes: Vec<Fix>,
}

impl Db {
    pub fn load() -> Db {
        let mut fixes = parse(BUILTIN);
        if let Ok(t) = std::fs::read_to_string(config_dir().join("hgl-fixes.conf")) {
            fixes.extend(parse(&t));
        }
        Db { fixes }
    }

    fn matches(&self, g: &Game) -> Vec<&Fix> {
        let appid = g.appid.to_ascii_lowercase();
        let name = g.name.to_ascii_lowercase();
        let src = g.source.to_ascii_lowercase();
        self.fixes
            .iter()
            .filter(|f| {
                f.keys.iter().any(|k| match k.split_once(':') {
                    Some(("name", t)) => !t.is_empty() && name.contains(t),
                    Some((store, id)) => store == src && !appid.is_empty() && id == appid,
                    None => false,
                })
            })
            .collect()
    }

    /// The warnings that apply to this game, in one line.
    pub fn note_for(&self, g: &Game) -> String {
        self.matches(g).iter().map(|f| f.note.clone()).filter(|n| !n.is_empty()).collect::<Vec<String>>().join(" ")
    }

    /// What applying would change (for `hgl fixes`).
    pub fn changes_for(&self, g: &Game) -> Vec<String> {
        let mut v = Vec::new();
        for f in self.matches(g) {
            for (k, val) in &f.env {
                v.push(format!("env {k}={val}"));
            }
            for (k, val) in &f.sets {
                v.push(format!("{k} = {val}"));
            }
        }
        v
    }

    /// Apply the settings once (`force` = again). Returns what was changed. The caller saves.
    pub fn apply(&self, g: &mut Game, force: bool) -> Vec<String> {
        let mut done = Vec::new();
        let marked = g.unknown.iter().any(|(k, _)| k == "fixes_applied");
        if marked && !force {
            return done;
        }
        let found: Vec<Fix> = self.matches(g).into_iter().cloned().collect();
        for f in found {
            for (k, v) in &f.env {
                if !g.env.iter().any(|(ek, _)| ek == k) {
                    g.env.push((k.clone(), v.clone()));
                    done.push(format!("env {k}={v}"));
                }
            }
            for (k, v) in &f.sets {
                if g.set(k, v).is_ok() {
                    done.push(format!("{k} = {v}"));
                }
            }
        }
        g.unknown.retain(|(k, _)| k != "fixes_applied");
        g.unknown.push(("fixes_applied".to_string(), "1".to_string()));
        done
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "# c\n[steam:42, Name:old game]\nnote = careful\nenv.PROTON_USE_WINED3D = 1\nset.wayland = off\nset.exe = /evil\nenv.1BAD = x\n\n[epic:Fortnite]\nnote = no\n";

    #[test]
    fn parsing() {
        let f = parse(SAMPLE);
        assert_eq!(f.len(), 2);
        assert_eq!(f[0].keys, vec!["steam:42", "name:old game"]);
        assert_eq!(f[0].env, vec![("PROTON_USE_WINED3D".to_string(), "1".to_string())]);
        // exe is not settable from a database, and a bad variable name is dropped
        assert_eq!(f[0].sets, vec![("wayland".to_string(), "off".to_string())]);
    }

    #[test]
    fn builtin_parses() {
        let f = parse(BUILTIN);
        assert!(f.iter().all(|x| !x.keys.is_empty() && !x.note.is_empty()));
        assert!(f.iter().any(|x| x.keys.iter().any(|k| k == "epic:fortnite")));
    }

    #[test]
    fn matching_and_applying_once() {
        let db = Db { fixes: parse(SAMPLE) };
        let mut g = Game::new("steam-42", "Whatever", "steam");
        g.appid = "42".into();
        assert_eq!(db.note_for(&g), "careful");
        g.wayland = true;
        let done = db.apply(&mut g, false);
        assert!(done.contains(&"wayland = off".to_string()));
        assert!(!g.wayland);
        assert_eq!(g.env.len(), 1);
        // a second apply changes nothing, even after the user turned Wayland on
        g.wayland = true;
        assert!(db.apply(&mut g, false).is_empty());
        assert!(g.wayland);
        // by name, and Epic's app name is matched without case
        let n = Game::new("x", "The OLD Game II", "exe");
        assert_eq!(db.note_for(&n), "careful");
        let mut e = Game::new("epic-fortnite", "Fortnite", "epic");
        e.appid = "Fortnite".into();
        assert_eq!(db.note_for(&e), "no");
        // another store's id does not match
        let mut other = Game::new("gog-42", "Other", "gog");
        other.appid = "42".into();
        assert_eq!(db.note_for(&other), "");
    }
}
