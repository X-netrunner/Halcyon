//! Epic Games Store through `legendary`: login, your library, install, and importing what is installed. hgl starts the game itself:
//! `legendary launch <app> --no-wine --wrapper "umu-run"` gives the game its login parameters and hands the process to umu (see run.rs).

use crate::json::{self, Json};
use crate::store::{self, games_root, Conf, Game, Imported};
use crate::util::*;
use std::collections::HashMap;
use std::process::{Command, Stdio};

fn need_legendary() -> Result<(), String> {
    if have("legendary") {
        Ok(())
    } else {
        Err("legendary is not installed (Arch: yay -S legendary, otherwise: pipx install legendary-gl; hgl doctor shows the state)".into())
    }
}

/// An Epic app name ends up in command lines and file names.
fn good_app(s: &str) -> bool {
    valid_id(s) && s.len() <= 60
}

/// The environment legendary needs when its config is not in the default place (for example Heroic's).
pub fn config_env(cfg: &Conf) -> Option<(String, String)> {
    cfg.get("epic_config").map(|p| ("LEGENDARY_CONFIG_PATH".to_string(), expand_home(p).to_string_lossy().to_string()))
}

fn leg(args: &[&str]) -> Command {
    let mut c = Command::new("legendary");
    c.args(args);
    if let Some((k, v)) = config_env(&Conf::load()) {
        c.env(k, v);
    }
    c
}

fn leg_json(args: &[&str]) -> Result<Json, String> {
    need_legendary()?;
    let o = leg(args).stdin(Stdio::null()).stderr(Stdio::null()).output().map_err(|e| format!("legendary: {e}"))?;
    if !o.status.success() {
        return Err(format!("legendary {} failed (logged in? hgl epic login)", args.join(" ")));
    }
    json::parse(&String::from_utf8_lossy(&o.stdout)).ok_or_else(|| "legendary printed something hgl could not read".to_string())
}

pub struct Status {
    pub installed: bool,
    pub logged_in: bool,
    pub account: String,
}

pub fn status() -> Status {
    if !have("legendary") {
        return Status { installed: false, logged_in: false, account: String::new() };
    }
    let acct = leg_json(&["status", "--json"]).ok().and_then(|j| j.str("account").map(|s| s.to_string())).unwrap_or_default();
    // legendary writes "<not logged in>" when there is no login
    let logged_in = !acct.is_empty() && !acct.starts_with('<');
    Status { installed: true, logged_in, account: if logged_in { acct } else { String::new() } }
}

/// Interactive: legendary shows the Epic sign-in page and asks for the code it gives you. Needs a terminal (the Game Center opens one).
pub fn login() -> Result<i32, String> {
    need_legendary()?;
    println!("Epic login: sign in on the page legendary shows, then paste the authorizationCode it gives you here.");
    let st = leg(&["auth"]).status().map_err(|e| format!("legendary: {e}"))?;
    Ok(st.code().unwrap_or(1))
}

pub fn logout() -> Result<i32, String> {
    need_legendary()?;
    let st = leg(&["auth", "--delete"]).status().map_err(|e| format!("legendary: {e}"))?;
    Ok(st.code().unwrap_or(1))
}

pub struct Installed {
    pub app: String,
    pub title: String,
    pub exe: String,
}

/// Installed Windows games, from `legendary list-installed --json` (it reads local files, no login needed).
pub fn installed() -> Result<Vec<Installed>, String> {
    let j = leg_json(&["list-installed", "--json"])?;
    let mut v = Vec::new();
    for g in j.items() {
        let (Some(app), Some(root), Some(exe)) = (g.str("app_name"), g.str("install_path"), g.str("executable")) else { continue };
        if !good_app(app) {
            continue;
        }
        if let Some(p) = g.str("platform") {
            if !p.eq_ignore_ascii_case("windows") {
                continue;
            }
        }
        let base = std::path::Path::new(root);
        // the exact file when it can be found (case differences are common), else the path as written
        let path = resolve_ci(base, exe).unwrap_or_else(|| base.join(exe.replace('\\', "/")));
        let title = g.str("title").or(g.str("app_title")).unwrap_or(app);
        v.push(Installed { app: app.to_string(), title: title.to_string(), exe: path.to_string_lossy().to_string() });
    }
    Ok(v)
}

pub struct Title {
    pub app: String,
    pub title: String,
    pub installed: bool,
}

/// Your Epic library (online), with what is installed marked.
pub fn owned() -> Result<Vec<Title>, String> {
    let all = leg_json(&["list", "--json"])?;
    let have_apps: Vec<String> = installed().map(|v| v.into_iter().map(|i| i.app).collect()).unwrap_or_default();
    let mut out: Vec<Title> = Vec::new();
    for g in all.items() {
        let Some(app) = g.str("app_name") else { continue };
        if !good_app(app) {
            continue;
        }
        // add-ons name their game; they are not games of their own
        if let Some(m) = g.get("metadata") {
            if let Some(x) = m.get("mainGameItem") {
                if *x != Json::Null {
                    continue;
                }
            }
        }
        let title = g.str("app_title").unwrap_or(app).to_string();
        out.push(Title { app: app.to_string(), title, installed: have_apps.iter().any(|a| a == app) });
    }
    out.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    Ok(out)
}

pub fn titles_json() -> Result<String, String> {
    let items: Vec<String> = owned()?
        .iter()
        .map(|t| format!("{{\"app\":{},\"title\":{},\"installed\":{}}}", json_str(&t.app), json_str(&t.title), t.installed))
        .collect();
    Ok(format!("[{}]", items.join(",")))
}

/// app name -> portrait cover URL, from the key images in `legendary list --json`.
pub fn cover_map() -> HashMap<String, String> {
    let mut m = HashMap::new();
    if let Ok(all) = leg_json(&["list", "--json"]) {
        for g in all.items() {
            let Some(app) = g.str("app_name") else { continue };
            let Some(imgs) = g.get("metadata").and_then(|x| x.get("keyImages")) else { continue };
            for want in ["DieselGameBoxTall", "OfferImageTall", "Thumbnail"] {
                if let Some(u) = imgs.items().iter().find(|i| i.str("type") == Some(want)).and_then(|i| i.str("url")) {
                    m.insert(app.to_string(), u.to_string());
                    break;
                }
            }
        }
    }
    m
}

/// Add what legendary has installed to the library; refresh names and paths; drop games that were uninstalled.
pub fn import() -> Result<Imported, String> {
    let list = installed()?;
    let mut done = Imported::default();
    for it in &list {
        let id = format!("epic-{}", slugify(&it.app));
        match Game::load(&id) {
            Ok(mut g) => {
                let before = (g.name.clone(), g.exe.clone());
                g.name = it.title.clone();
                g.exe = it.exe.clone();
                if before != (g.name.clone(), g.exe.clone()) {
                    done.updated += 1;
                }
                g.save()?;
            }
            Err(_) => {
                let mut g = Game::new(&id, &it.title, "epic");
                g.appid = it.app.clone();
                g.exe = it.exe.clone();
                g.save()?;
                done.added.push(id);
            }
        }
    }
    for g in store::all_games() {
        if g.source == "epic" && !list.iter().any(|it| it.app == g.appid) {
            Game::remove(&g.id)?;
            done.removed += 1;
        }
    }
    Ok(done)
}

/// Download and install a game (legendary shows its own progress). Windows version, under the games folder.
pub fn install(app: &str) -> Result<i32, String> {
    need_legendary()?;
    if !good_app(app) {
        return Err(format!("not an Epic app name: {app} (hgl epic list shows them)"));
    }
    let base = games_root(&Conf::load()).join("Epic");
    std::fs::create_dir_all(&base).map_err(|e| format!("cannot create {}: {e}", base.display()))?;
    let base_s = base.to_string_lossy().to_string();
    let st = leg(&["install", app, "--base-path", base_s.as_str(), "--platform", "Windows", "-y"]).status().map_err(|e| format!("legendary: {e}"))?;
    if !st.success() {
        return Ok(st.code().unwrap_or(1));
    }
    // the same finishing step as `hgl import`: known fixes, then cover art for what was added
    let r = import()?;
    crate::finish_import("Epic", &r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_names() {
        assert!(good_app("Fortnite"));
        assert!(good_app("5ecc1d1d7a354f7c8ac3a7b0b5bb4d29"));
        assert!(!good_app("a b"));
        assert!(!good_app("../x"));
        assert!(!good_app(&"a".repeat(61)));
    }
}
