//! GOG: login and install through `gogdl` (Heroic's downloader), your library through GOG's own web API, and importing what is
//! installed by reading the `goggame-<id>.info` file every GOG game carries (it names the main program). hgl starts the game itself
//! through umu: GOG games need no client for DRM.

use crate::json::{self, Json};
use crate::store::{games_root, Conf, Game, Imported};
use crate::util::*;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

// GOG Galaxy's public OAuth client, the same one Heroic and other third-party clients use.
const CLIENT_ID: &str = "46899977096215655";
const CLIENT_SECRET: &str = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9";

pub fn login_url() -> String {
    format!("https://auth.gog.com/auth?client_id={CLIENT_ID}&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy")
}

fn auth_path() -> PathBuf {
    config_dir().join("gog").join("auth.json")
}

fn gogdl() -> Result<String, String> {
    if let Some(c) = Conf::load().get("gogdl") {
        return Ok(c.to_string());
    }
    for n in ["gogdl", "heroic-gogdl"] {
        if have(n) {
            return Ok(n.to_string());
        }
    }
    Err("gogdl is not installed (it is Heroic's GOG downloader: github.com/Heroic-Games-Launcher/heroic-gogdl). Another name or path: hgl config gogdl /path/to/gogdl".into())
}

pub fn gogdl_present() -> bool {
    gogdl().is_ok()
}

/// The code from the address GOG redirects to (`...on_login_success?origin=client&code=XXXX`), or a bare code.
pub fn extract_code(input: &str) -> Option<String> {
    let t = input.trim();
    let raw = match t.find("code=") {
        Some(i) => &t[i + 5..],
        None => t,
    };
    let code: String = raw.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').collect();
    if code.len() >= 8 {
        Some(code)
    } else {
        None
    }
}

/// The tokens are secret: the folder and the file are for this user only.
fn make_private(p: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(p, fs::Permissions::from_mode(mode));
}

pub fn login(input: Option<&str>) -> Result<i32, String> {
    let Some(input) = input else {
        println!("1. Open this page and sign in to GOG:\n\n   {}\n\n2. You land on a page that may look empty. Copy its address (it contains code=...).\n3. Run:  hgl gog login '<that address>'", login_url());
        return Ok(0);
    };
    let code = extract_code(input).ok_or_else(|| "that is not a GOG address or code (the address contains code=...)".to_string())?;
    let bin = gogdl()?;
    let auth = auth_path();
    if let Some(d) = auth.parent() {
        fs::create_dir_all(d).map_err(|e| format!("cannot create {}: {e}", d.display()))?;
        make_private(d, 0o700);
    }
    let a = auth.to_string_lossy().to_string();
    let st = Command::new(&bin).args(["--auth-config-path", a.as_str(), "auth", "--code", code.as_str()]).status().map_err(|e| format!("{bin}: {e}"))?;
    if !st.success() {
        return Ok(st.code().unwrap_or(1));
    }
    if !logged_in() {
        return Err("gogdl finished, but no login was saved (the code is only valid for a few minutes: try again)".into());
    }
    make_private(&auth, 0o600);
    println!("Logged in to GOG.");
    Ok(0)
}

fn read_auth() -> Option<Json> {
    json::parse(&fs::read_to_string(auth_path()).ok()?)
}

/// gogdl writes `{ "<client id>": { access_token, refresh_token, ... } }`; a flat file is accepted too.
fn token_obj(j: &Json) -> Option<&Json> {
    if j.str("refresh_token").is_some() {
        return Some(j);
    }
    j.entries().iter().map(|(_, v)| v).find(|v| v.str("refresh_token").is_some())
}

pub fn logged_in() -> bool {
    match read_auth() {
        Some(j) => token_obj(&j).is_some(),
        None => false,
    }
}

/// A valid access token: the saved one while it lasts, else a new one from the refresh token (saved back in the same shape).
fn fresh_token() -> Result<String, String> {
    let root = read_auth().ok_or_else(|| "not logged in to GOG (hgl gog login)".to_string())?;
    let t = token_obj(&root).ok_or_else(|| "not logged in to GOG (hgl gog login)".to_string())?;
    let access = t.str("access_token").unwrap_or("");
    let at = t.num("loginTime").unwrap_or(0.0) + t.num("expires_in").unwrap_or(0.0);
    if !access.is_empty() && at > now() as f64 + 120.0 {
        return Ok(access.to_string());
    }
    let refresh = t.str("refresh_token").ok_or_else(|| "the GOG login has no refresh token (hgl gog login)".to_string())?;
    let url = format!("https://auth.gog.com/token?client_id={CLIENT_ID}&client_secret={CLIENT_SECRET}&grant_type=refresh_token&refresh_token={}", url_encode(refresh));
    let body = curl_run(&url, None, None).ok_or_else(|| "could not renew the GOG login (offline? or log in again: hgl gog login)".to_string())?;
    let nj = json::parse(&body).ok_or_else(|| "GOG answered something unreadable".to_string())?;
    let new_access = nj.str("access_token").ok_or_else(|| "GOG did not give a new token: log in again (hgl gog login)".to_string())?.to_string();
    let new_refresh = nj.str("refresh_token").unwrap_or(refresh).to_string();
    let expires = nj.num("expires_in").unwrap_or(3600.0) as u64;
    let mut saved = String::new();
    saved.push('{');
    saved.push_str(&json_str(CLIENT_ID));
    saved.push_str(":{\"access_token\":");
    saved.push_str(&json_str(&new_access));
    saved.push_str(&format!(",\"expires_in\":{expires},\"token_type\":\"bearer\",\"scope\":\"\",\"session_id\":"));
    saved.push_str(&json_str(nj.str("session_id").unwrap_or("")));
    saved.push_str(",\"refresh_token\":");
    saved.push_str(&json_str(&new_refresh));
    saved.push_str(",\"user_id\":");
    saved.push_str(&json_str(nj.str("user_id").unwrap_or("")));
    saved.push_str(&format!(",\"loginTime\":{}}}}}\n", now()));
    atomic_write(&auth_path(), &saved).map_err(|e| format!("cannot save the new GOG login: {e}"))?;
    make_private(&auth_path(), 0o600);
    Ok(new_access)
}

// ------------------------------------------------------------------------------------------------ installed games

pub struct Found {
    pub id: String,
    pub name: String,
    pub exe: PathBuf,
    pub args: String,
}

fn id_of(j: &Json) -> Option<String> {
    let s = match j {
        Json::Str(s) => s.clone(),
        Json::Num(n) => format!("{}", *n as u64),
        _ => return None,
    };
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_digit()) {
        Some(s)
    } else {
        None
    }
}

/// One `goggame-<id>.info` file: the game, and the program its primary play task starts. Add-ons (they have an info file too) are skipped.
pub fn parse_info(root: &Path, text: &str) -> Option<Found> {
    let j = json::parse(text)?;
    let gid = id_of(j.get("gameId")?)?;
    if let Some(r) = j.get("rootGameId") {
        if id_of(r).map(|x| x != gid).unwrap_or(false) {
            return None;
        }
    }
    let name = j.str("name")?.to_string();
    let tasks = j.get("playTasks")?.items();
    let task = tasks
        .iter()
        .find(|t| t.get("isPrimary") == Some(&Json::Bool(true)))
        .or_else(|| tasks.iter().find(|t| t.str("type") == Some("FileTask")))?;
    let exe = resolve_ci(root, task.str("path")?)?;
    if !exe.is_file() {
        return None;
    }
    Some(Found { id: gid, name, exe, args: task.str("arguments").unwrap_or("").to_string() })
}

/// Where GOG games are looked for: hgl's own install folder, Heroic's default, and `gog_dirs` (folders separated by `:`).
pub fn scan_dirs() -> Vec<PathBuf> {
    let cfg = Conf::load();
    let mut v = vec![games_root(&cfg).join("GOG"), home().join("Games").join("Heroic")];
    if let Some(extra) = cfg.get("gog_dirs") {
        for d in extra.split(':') {
            if !d.trim().is_empty() {
                v.push(expand_home(d.trim()));
            }
        }
    }
    v
}

fn look(dir: &Path, depth: u32, found: &mut Vec<Found>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut subs: Vec<PathBuf> = Vec::new();
    for e in rd.flatten() {
        let p = e.path();
        let n = e.file_name().to_string_lossy().to_string();
        if p.is_file() && n.starts_with("goggame-") && n.ends_with(".info") {
            if let Ok(text) = fs::read_to_string(&p) {
                if let Some(f) = parse_info(dir, &text) {
                    if !found.iter().any(|x| x.id == f.id) {
                        found.push(f);
                    }
                }
            }
        } else if p.is_dir() {
            subs.push(p);
        }
    }
    if depth > 0 {
        for s in subs {
            look(&s, depth - 1, found);
        }
    }
}

/// Every GOG game found below `dirs` (two levels deep: `<dir>/<game>/goggame-<id>.info`).
pub fn scan(dirs: &[PathBuf]) -> Vec<Found> {
    let mut found: Vec<Found> = Vec::new();
    for d in dirs {
        look(d, 2, &mut found);
    }
    found
}

/// Add the installed GOG games to the library (new ones get the program and arguments from their info file) and refresh names and paths.
pub fn import(extra: &[String]) -> Result<Imported, String> {
    let mut dirs = scan_dirs();
    for d in extra {
        dirs.push(expand_home(d));
    }
    let mut done = Imported::default();
    for f in scan(&dirs) {
        let id = format!("gog-{}", f.id);
        let exe = f.exe.to_string_lossy().to_string();
        match Game::load(&id) {
            Ok(mut g) => {
                let before = (g.name.clone(), g.exe.clone());
                g.name = f.name.clone();
                g.exe = exe;
                if before != (g.name.clone(), g.exe.clone()) {
                    done.updated += 1;
                }
                g.save()?;
            }
            Err(_) => {
                let mut g = Game::new(&id, &f.name, "gog");
                g.appid = f.id.clone();
                g.exe = exe;
                g.args = f.args.clone();
                g.save()?;
                done.added.push(id);
            }
        }
    }
    Ok(done)
}

// ------------------------------------------------------------------------------------------------ library, install

pub struct Owned {
    pub id: String,
    pub title: String,
    pub installed: bool,
}

/// Your GOG library (Windows games), from GOG's account API.
pub fn owned() -> Result<Vec<Owned>, String> {
    let token = fresh_token()?;
    let hdr = format!("Authorization: Bearer {token}");
    let mine: Vec<String> = scan(&scan_dirs()).into_iter().map(|f| f.id).collect();
    let mut out: Vec<Owned> = Vec::new();
    let mut page: u32 = 1;
    loop {
        let url = format!("https://embed.gog.com/account/getFilteredProducts?mediaType=1&page={page}");
        let body = curl_run(&url, Some(hdr.as_str()), None).ok_or_else(|| "could not read your GOG library (offline, or the login ran out: hgl gog login)".to_string())?;
        let j = json::parse(&body).ok_or_else(|| "GOG answered something unreadable".to_string())?;
        for p in j.get("products").map(|x| x.items()).unwrap_or(&[]) {
            let Some(id) = p.get("id").and_then(id_of) else { continue };
            if p.get("worksOn").and_then(|w| w.get("Windows")) != Some(&Json::Bool(true)) {
                continue;
            }
            let title = p.str("title").unwrap_or(id.as_str()).to_string();
            let installed = mine.contains(&id);
            out.push(Owned { id, title, installed });
        }
        let total = j.num("totalPages").unwrap_or(1.0) as u32;
        if page >= total.min(30) {
            break;
        }
        page += 1;
    }
    out.sort_by_cached_key(|a| a.title.to_lowercase());
    Ok(out)
}

pub fn titles_json() -> Result<String, String> {
    let items: Vec<String> = owned()?
        .iter()
        .map(|t| format!("{{\"id\":{},\"title\":{},\"installed\":{}}}", json_str(&t.id), json_str(&t.title), t.installed))
        .collect();
    Ok(format!("[{}]", items.join(",")))
}

/// Download and install (gogdl shows its own progress). `title` only names the folder.
pub fn install(id: &str, title: Option<&str>) -> Result<i32, String> {
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
        return Err(format!("not a GOG product id: {id} (hgl gog list shows them)"));
    }
    let bin = gogdl()?;
    if !logged_in() {
        return Err("not logged in to GOG (hgl gog login)".into());
    }
    let _ = fresh_token(); // renew first, so gogdl does not have to
    let folder = title.map(slugify).unwrap_or_else(|| format!("gog-{id}"));
    let dir = games_root(&Conf::load()).join("GOG").join(folder);
    fs::create_dir_all(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let a = auth_path().to_string_lossy().to_string();
    let d = dir.to_string_lossy().to_string();
    let st = Command::new(&bin)
        .args(["--auth-config-path", a.as_str(), "download", id, "--platform", "windows", "--path", d.as_str(), "--lang", "en-US"])
        .status()
        .map_err(|e| format!("{bin}: {e}"))?;
    if !st.success() {
        return Ok(st.code().unwrap_or(1));
    }
    // the same finishing step as `hgl import`: known fixes, then cover art for what was added
    let r = import(&[])?;
    crate::finish_import("GOG", &r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes() {
        assert_eq!(extract_code("https://embed.gog.com/on_login_success?origin=client&code=AbC123-xyz_9&x=1"), Some("AbC123-xyz_9".to_string()));
        assert_eq!(extract_code("  AbC123xyz9  "), Some("AbC123xyz9".to_string()));
        assert_eq!(extract_code("short"), None);
        assert_eq!(extract_code("code=; rm -rf"), None);
    }

    #[test]
    fn info_files() {
        let t = std::env::temp_dir().join(format!("hgl-gog-{}", std::process::id()));
        let _ = fs::remove_dir_all(&t);
        let _ = fs::create_dir_all(t.join("bin"));
        let _ = fs::write(t.join("bin/witcher3.exe"), "MZ");
        let info = r#"{"gameId":"1207664643","rootGameId":"1207664643","name":"The Witcher 3","playTasks":[
            {"type":"URLTask","path":"x"},
            {"isPrimary":true,"type":"FileTask","path":"Bin\\WITCHER3.EXE","arguments":"-windowed"}]}"#;
        let f = parse_info(&t, info);
        assert_eq!(f.as_ref().map(|f| f.id.as_str()), Some("1207664643"));
        assert_eq!(f.as_ref().map(|f| f.args.as_str()), Some("-windowed"));
        assert_eq!(f.map(|f| f.exe), Some(t.join("bin/witcher3.exe")));
        // an add-on names another game as its root
        let dlc = r#"{"gameId":"111","rootGameId":"1207664643","name":"DLC","playTasks":[{"isPrimary":true,"type":"FileTask","path":"bin/witcher3.exe"}]}"#;
        assert!(parse_info(&t, dlc).is_none());
        let _ = fs::remove_dir_all(&t);
    }

    #[test]
    fn token_shapes() {
        let keyed = json::parse(r#"{"4689":{"access_token":"a","refresh_token":"r"}}"#).unwrap_or(Json::Null);
        assert!(token_obj(&keyed).is_some());
        let flat = json::parse(r#"{"access_token":"a","refresh_token":"r"}"#).unwrap_or(Json::Null);
        assert!(token_obj(&flat).is_some());
        let none = json::parse(r#"{"x":{"y":1}}"#).unwrap_or(Json::Null);
        assert!(token_obj(&none).is_none());
    }
}
