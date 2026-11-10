//! Proton runtime manager: GE-Proton (default) and Proton-CachyOS, checksum-verified, installed under $XDG_DATA_HOME/Halcyon/proton,
//! the newest few kept, never a version a game is pinned to.

use crate::store::{self, Conf};
use crate::util::*;
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Family {
    Ge,
    Cachy,
}

impl Family {
    pub fn parse(s: &str) -> Option<Family> {
        match s.to_ascii_lowercase().as_str() {
            "ge" | "ge-proton" | "proton-ge" => Some(Family::Ge),
            "cachyos" | "cachy" | "proton-cachyos" => Some(Family::Cachy),
            _ => None,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Family::Ge => "ge",
            Family::Cachy => "cachyos",
        }
    }
    fn repo(self) -> &'static str {
        match self {
            Family::Ge => "GloriousEggroll/proton-ge-custom",
            Family::Cachy => "CachyOS/proton-cachyos",
        }
    }
}

pub fn family_of(name: &str) -> Option<Family> {
    let l = name.to_ascii_lowercase();
    if l.starts_with("ge-proton") {
        Some(Family::Ge)
    } else if l.starts_with("proton-cachyos") {
        Some(Family::Cachy)
    } else {
        None
    }
}

#[derive(Clone, Debug)]
pub struct Runtime {
    pub name: String,
    pub path: PathBuf,
}

/// Installed runtimes, oldest first.
pub fn installed() -> Vec<Runtime> {
    let mut v = Vec::new();
    if let Ok(rd) = fs::read_dir(proton_dir()) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            let p = e.path();
            if p.join("proton").is_file() {
                v.push(Runtime { name, path: p });
            }
        }
    }
    v.sort_by(|a, b| natural_cmp(&a.name, &b.name));
    v
}

pub fn default_family(cfg: &Conf) -> Family {
    cfg.get("proton_family").and_then(Family::parse).unwrap_or(Family::Ge)
}

/// The runtime a game with this pin uses: its pin, else the default, else the newest of the default family, else the newest of any.
pub fn resolve(pin: &str, cfg: &Conf) -> Option<Runtime> {
    let all = installed();
    if !pin.is_empty() {
        return all.into_iter().find(|r| r.name == pin);
    }
    if let Some(d) = cfg.get("proton_default") {
        if let Some(r) = all.iter().find(|r| r.name == d) {
            return Some(r.clone());
        }
    }
    let fam = default_family(cfg);
    all.iter().rev().find(|r| family_of(&r.name) == Some(fam)).or_else(|| all.last()).cloned()
}

fn pinned_names() -> Vec<String> {
    store::all_games().into_iter().map(|g| g.proton).filter(|p| !p.is_empty()).collect()
}

// ---------------------------------------------------------------- GitHub releases

#[derive(Debug, Clone)]
pub struct Release {
    pub tag: String,
    pub tarball: String,
    pub tarball_url: String,
    pub sum_url: String,
}

/// Values of every `"key": "value"` in a JSON text, with their byte positions. The GitHub API answer is machine-written, so no escapes matter here.
fn json_values(text: &str, key: &str) -> Vec<(usize, String)> {
    let pat = format!("\"{key}\"");
    let mut v = Vec::new();
    let mut from = 0;
    while let Some(i) = text[from..].find(&pat) {
        let at = from + i;
        let rest = &text[at + pat.len()..];
        let r = rest.trim_start();
        if let Some(r) = r.strip_prefix(':') {
            let r = r.trim_start();
            if let Some(r) = r.strip_prefix('"') {
                if let Some(end) = r.find('"') {
                    v.push((at, r[..end].to_string()));
                }
            }
        }
        from = at + pat.len();
    }
    v
}

/// Releases with their assets, newest first, from the GitHub releases JSON.
pub fn parse_releases(json: &str, fam: Family, cpu_v3: bool) -> Vec<Release> {
    let tags = json_values(json, "tag_name");
    let urls = json_values(json, "browser_download_url");
    let mut out = Vec::new();
    for (i, (pos, tag)) in tags.iter().enumerate() {
        let end = tags.get(i + 1).map(|t| t.0).unwrap_or(usize::MAX);
        let assets: Vec<&String> = urls.iter().filter(|(p, _)| p > pos && *p < end).map(|(_, u)| u).collect();
        let base = |u: &str| u.rsplit('/').next().unwrap_or("").to_string();
        let tarballs: Vec<&&String> = assets
            .iter()
            .filter(|u| {
                let b = base(u);
                // GE-Proton 11 ships -aarch64 and -x86_64 tarballs side by side (CachyOS: -arm64): never the ARM one
                let arm = b.contains("aarch64") || b.contains("arm64");
                !arm && match fam {
                    Family::Ge => b.starts_with("GE-Proton") && b.ends_with(".tar.gz"),
                    Family::Cachy => b.starts_with("proton-cachyos") && b.ends_with(".tar.xz"),
                }
            })
            .collect();
        let pick = match fam {
            Family::Ge => tarballs.first().copied(),
            Family::Cachy => {
                let v3 = tarballs.iter().find(|u| base(u).contains("x86_64_v3"));
                let plain = tarballs.iter().find(|u| base(u).ends_with("-x86_64.tar.xz"));
                if cpu_v3 {
                    v3.or(plain).or(tarballs.first()).copied()
                } else {
                    plain.or(tarballs.first()).copied()
                }
            }
        };
        if let Some(t) = pick {
            let name = base(t);
            let sum = assets.iter().find(|u| base(u) == format!("{}.sha512sum", name.trim_end_matches(".tar.gz").trim_end_matches(".tar.xz")) || base(u) == format!("{name}.sha512sum"));
            out.push(Release {
                tag: tag.clone(),
                tarball: name,
                tarball_url: (*t).clone(),
                sum_url: sum.map(|s| (*s).clone()).unwrap_or_default(),
            });
        }
    }
    out
}

/// x86-64-v3 needs avx2, bmi1/2, fma, movbe (what the CachyOS v3 build assumes).
pub fn cpu_has_v3() -> bool {
    let info = fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let flags = info.lines().find(|l| l.starts_with("flags")).unwrap_or("");
    ["avx2", "bmi1", "bmi2", "fma", "movbe"].iter().all(|f| flags.split_whitespace().any(|x| x == *f))
}

fn curl_text(url: &str) -> Result<String, String> {
    if !have("curl") {
        return Err("curl is not installed (run: hgl doctor --fix)".into());
    }
    out("curl", &["-fsSL", "--max-time", "30", "-H", "Accept: application/vnd.github+json", "-A", "halcyon-hgl", url])
        .ok_or_else(|| format!("could not download {url} (offline, or GitHub's rate limit; try again later)"))
}

pub fn available(fam: Family, count: usize) -> Result<Vec<Release>, String> {
    available_for(fam, count, None)
}

/// A GitHub token, when there is one: GITHUB_TOKEN / GH_TOKEN, or the `gh` CLI's login. It lifts the API limit from 60 requests an
/// hour per address (shared by everyone behind the same router, so a campus network runs out fast) to 5000.
fn gh_token() -> Option<String> {
    let ok = |t: &str| !t.is_empty() && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '_');
    for v in ["GITHUB_TOKEN", "GH_TOKEN"] {
        if let Ok(t) = std::env::var(v) {
            if ok(t.trim()) {
                return Some(t.trim().to_string());
            }
        }
    }
    if have("gh") {
        return out("gh", &["auth", "token"]).map(|t| t.trim().to_string()).filter(|t| ok(t));
    }
    None
}

/// The releases JSON from the GitHub API (with the token if there is one; it goes in a 0600 header file, never on a command line).
fn api_releases(fam: Family, count: usize) -> Option<String> {
    let url = format!("https://api.github.com/repos/{}/releases?per_page={}", fam.repo(), count.clamp(1, 30));
    if let Some(t) = gh_token() {
        if let Some(b) = curl_run(&url, Some(&format!("Authorization: Bearer {t}")), None) {
            return Some(b);
        }
    }
    curl_run(&url, None, None)
}

/// The same releases from github.com's own pages, which the API limit does not cover: the tags from releases.atom, the files of
/// each from its expanded_assets page. Written out as the API's JSON shape so parse_releases reads both. `want`: a tag (only that one
/// is read), "latest" (stops at the first release with a usable file), or None (the newest `count`).
fn web_releases(fam: Family, count: usize, want: Option<&str>) -> Option<String> {
    let repo = fam.repo();
    let atom = curl_run(&format!("https://github.com/{repo}/releases.atom"), None, None)?;
    let mut tags: Vec<String> = Vec::new();
    for part in atom.split("/releases/tag/").skip(1) {
        let t: String = part.chars().take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+')).collect();
        if !t.is_empty() && !tags.contains(&t) {
            tags.push(t);
        }
    }
    let mut json = String::from("[");
    for tag in tags.iter().take(count.clamp(1, 30)) {
        if want.is_some_and(|w| w != "latest" && w != tag) {
            continue;
        }
        let Some(html) = curl_run(&format!("https://github.com/{repo}/releases/expanded_assets/{tag}"), None, None) else { continue };
        let prefix = format!("/{repo}/releases/download/{tag}/");
        let files: Vec<String> = html
            .split("href=\"")
            .skip(1)
            .filter_map(|h| h.split('"').next())
            .filter(|h| h.starts_with(&prefix) && !h.contains(['<', '>', ' ']))
            .map(|h| format!("{{\"browser_download_url\":\"https://github.com{h}\"}}"))
            .collect();
        json.push_str(&format!("{{\"tag_name\":\"{tag}\",\"assets\":[{}]}},", files.join(",")));
        if want == Some("latest") && !parse_releases(&format!("{}]", json.trim_end_matches(',')), fam, cpu_has_v3()).is_empty() {
            break;
        }
    }
    Some(format!("{}]", json.trim_end_matches(',')))
}

/// `want`: the tag being installed, or "latest" (the web pages are then read only as far as needed); None = the newest `count`.
fn available_for(fam: Family, count: usize, want: Option<&str>) -> Result<Vec<Release>, String> {
    let v3 = cpu_has_v3();
    if let Some(json) = api_releases(fam, count) {
        let r = parse_releases(&json, fam, v3);
        if !r.is_empty() {
            return Ok(r);
        }
    }
    // the API refused (its hourly limit) or had nothing usable: github.com's pages
    let json = web_releases(fam, count, want).ok_or("could not reach GitHub (offline?)")?;
    let r = parse_releases(&json, fam, v3);
    if r.is_empty() {
        return Err("GitHub answered, but no matching release files were found".into());
    }
    Ok(r)
}

// ---------------------------------------------------------------- install / remove

fn valid_runtime_name(n: &str) -> bool {
    !n.is_empty() && !n.starts_with('.') && n.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'))
}

fn sha512_of(path: &Path) -> Option<String> {
    let o = out("sha512sum", &[&path.to_string_lossy()])?;
    o.split_whitespace().next().map(|s| s.to_ascii_lowercase())
}

/// Install `spec` ("latest" or a release tag such as GE-Proton10-4). Returns the runtime name.
pub fn install(spec: &str, fam: Family, cfg: &mut Conf) -> Result<String, String> {
    for t in ["tar", "sha512sum"] {
        if !have(t) {
            return Err(format!("{t} is not installed"));
        }
    }
    // the newest only needs one release; a named tag is looked for among the newest 12
    let latest = spec == "latest" || spec.is_empty();
    let releases = available_for(fam, if latest { 5 } else { 12 }, Some(if latest { "latest" } else { spec }))?;
    let rel = if spec == "latest" || spec.is_empty() {
        releases.first()
    } else {
        releases.iter().find(|r| r.tag == spec)
    }
    .ok_or_else(|| format!("release '{spec}' not found among the newest {} (see: hgl proton available)", releases.len()))?;
    if rel.sum_url.is_empty() {
        return Err(format!("{} has no .sha512sum file: refusing to install an unchecked download", rel.tag));
    }

    let root = proton_dir();
    fs::create_dir_all(&root).map_err(|e| format!("cannot create {}: {e}", root.display()))?;
    let tmp = root.join(format!(".tmp-{}", std::process::id()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let result = install_into(rel, &root, &tmp);
    let _ = fs::remove_dir_all(&tmp);
    let name = result?;

    if cfg.get("proton_default").is_none() {
        cfg.set("proton_default", &name)?;
    }
    if cfg.flag("steam_link", false) {
        link_steam_one(&name);
    }
    prune(cfg)?;
    Ok(name)
}

fn install_into(rel: &Release, root: &Path, tmp: &Path) -> Result<String, String> {
    let file = tmp.join(&rel.tarball);
    let sums = tmp.join("sum");
    eprintln!("Downloading {} ...", rel.tarball);
    let prog = if is_tty() { "--progress-bar" } else { "-sS" };
    let ok = Command::new("curl")
        .args(["-fL", "--retry", "3", prog, "-A", "halcyon-hgl", "-o"])
        .arg(&file)
        .arg(&rel.tarball_url)
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        return Err("download failed".into());
    }
    let sum_text = curl_text(&rel.sum_url)?;
    let _ = fs::write(sums, sum_text.as_str());
    let want = sum_text.split_whitespace().next().unwrap_or("").to_ascii_lowercase();
    if want.len() != 128 || !want.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("the checksum file is not a SHA-512 sum".into());
    }
    let got = sha512_of(&file).ok_or("could not compute the checksum")?;
    if got != want {
        return Err(format!("checksum mismatch for {} (expected {}..., got {}...): download discarded", rel.tarball, &want[..12], &got[..12.min(got.len())]));
    }
    eprintln!("Checksum OK. Unpacking ...");
    let ex = tmp.join("x");
    fs::create_dir_all(&ex).map_err(|e| e.to_string())?;
    let st = Command::new("tar").arg("-xf").arg(&file).arg("-C").arg(&ex).status().map_err(|e| e.to_string())?;
    if !st.success() {
        return Err("unpacking failed (xz needed for CachyOS builds: run hgl doctor --fix)".into());
    }
    let mut dirs: Vec<PathBuf> = fs::read_dir(&ex).map_err(|e| e.to_string())?.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
    if dirs.len() != 1 {
        return Err("unexpected archive layout".into());
    }
    let top = dirs.remove(0);
    let name = top.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    if !valid_runtime_name(&name) || !top.join("proton").is_file() {
        return Err("the archive does not look like a Proton build".into());
    }
    let dest = root.join(&name);
    if dest.exists() {
        return Err(format!("{name} is already installed"));
    }
    fs::rename(&top, &dest).map_err(|e| format!("cannot move into place: {e}"))?;
    Ok(name)
}

/// Keep the newest `proton_keep` (default 3) per family. Never the default, never a pinned one.
pub fn prune(cfg: &Conf) -> Result<Vec<String>, String> {
    let keep = cfg.num("proton_keep", 3).max(1) as usize;
    let pinned = pinned_names();
    let def = cfg.get("proton_default").unwrap_or("").to_string();
    let all = installed();
    let mut removed = Vec::new();
    for fam in [Family::Ge, Family::Cachy] {
        let of: Vec<&Runtime> = all.iter().filter(|r| family_of(&r.name) == Some(fam)).collect();
        if of.len() <= keep {
            continue;
        }
        for r in &of[..of.len() - keep] {
            if pinned.contains(&r.name) || r.name == def {
                continue;
            }
            fs::remove_dir_all(&r.path).map_err(|e| format!("cannot remove {}: {e}", r.name))?;
            unlink_steam_one(&r.name);
            removed.push(r.name.clone());
        }
    }
    Ok(removed)
}

pub fn remove(name: &str, cfg: &Conf) -> Result<(), String> {
    if !valid_runtime_name(name) {
        return Err(format!("not a runtime name: {name}"));
    }
    let r = installed().into_iter().find(|r| r.name == name).ok_or_else(|| format!("{name} is not installed"))?;
    let users: Vec<String> = store::all_games().into_iter().filter(|g| g.proton == name).map(|g| g.name).collect();
    if !users.is_empty() {
        return Err(format!("{name} is pinned by: {} (change their runtime first)", users.join(", ")));
    }
    if cfg.get("proton_default") == Some(name) {
        return Err(format!("{name} is the default runtime (set another default first, or use: hgl proton rollback)"));
    }
    fs::remove_dir_all(r.path.as_path()).map_err(|e| e.to_string())?;
    unlink_steam_one(name);
    Ok(())
}

/// Make the previous version the default. Returns (from, to).
pub fn rollback(cfg: &mut Conf) -> Result<(String, String), String> {
    let all = installed();
    let cur = resolve("", cfg).ok_or("no runtime installed")?;
    let fam = family_of(&cur.name);
    let older: Vec<&Runtime> = all.iter().filter(|r| family_of(&r.name) == fam && natural_cmp(&r.name, &cur.name).is_lt()).collect();
    let prev = older.last().ok_or_else(|| format!("nothing older than {} is installed", cur.name))?;
    cfg.set("proton_default", &prev.name)?;
    Ok((cur.name, prev.name.clone()))
}

pub fn set_default(name: &str, cfg: &mut Conf) -> Result<(), String> {
    if !installed().iter().any(|r| r.name == name) {
        return Err(format!("{name} is not installed (see: hgl proton list)"));
    }
    cfg.set("proton_default", name)
}

// ---------------------------------------------------------------- Steam's compatibilitytools.d

fn steam_tool_dirs() -> Vec<PathBuf> {
    steam_roots_for_tools().into_iter().map(|r| r.join("compatibilitytools.d")).collect()
}

fn steam_roots_for_tools() -> Vec<PathBuf> {
    let h = home();
    let mut v = Vec::new();
    for c in [data_home().join("Steam"), h.join(".var/app/com.valvesoftware.Steam/.local/share/Steam")] {
        if c.join("steamapps").is_dir() && !v.contains(&c) {
            v.push(c);
        }
    }
    v
}

fn link_steam_one(name: &str) {
    let Some(r) = installed().into_iter().find(|r| r.name == name) else { return };
    for d in steam_tool_dirs() {
        if fs::create_dir_all(&d).is_ok() {
            let l = d.join(name);
            if fs::symlink_metadata(&l).is_err() {
                let _ = symlink(&r.path, &l);
            }
        }
    }
}

fn unlink_steam_one(name: &str) {
    for d in steam_tool_dirs() {
        let l = d.join(name);
        // only ever remove a symlink that points into our own runtime folder
        if let Ok(t) = fs::read_link(&l) {
            if t.starts_with(proton_dir()) {
                let _ = fs::remove_file(&l);
            }
        }
    }
}

pub fn link_steam_all() -> usize {
    let mut n = 0;
    for r in installed() {
        link_steam_one(&r.name);
        n += 1;
    }
    n
}

pub fn unlink_steam_all() {
    for r in installed() {
        unlink_steam_one(&r.name);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn ge_11_picks_the_x86_64_tarball_not_aarch64() {
        let j = r#"[{"tag_name":"GE-Proton11-11","assets":[
            {"browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-11/GE-Proton11-11-aarch64.sha512sum"},
            {"browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-11/GE-Proton11-11-aarch64.tar.gz"},
            {"browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-11/GE-Proton11-11-x86_64.sha512sum"},
            {"browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-11/GE-Proton11-11-x86_64.tar.gz"}]}]"#;
        let r = parse_releases(j, Family::Ge, true);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].tarball, "GE-Proton11-11-x86_64.tar.gz");
        assert!(r[0].sum_url.ends_with("GE-Proton11-11-x86_64.sha512sum"));
    }

    use super::*;

    const GE: &str = r#"[{"url":"x","tag_name":"GE-Proton10-4","assets":[{"name":"GE-Proton10-4.sha512sum","browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton10-4/GE-Proton10-4.sha512sum"},{"name":"GE-Proton10-4.tar.gz","browser_download_url":"https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton10-4/GE-Proton10-4.tar.gz"}]},{"tag_name":"GE-Proton10-3","assets":[{"browser_download_url":"https://x/GE-Proton10-3.tar.gz"},{"browser_download_url":"https://x/GE-Proton10-3.sha512sum"}]}]"#;

    #[test]
    fn ge_releases() {
        let r = parse_releases(GE, Family::Ge, false);
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].tag, "GE-Proton10-4");
        assert!(r[0].tarball_url.ends_with("GE-Proton10-4.tar.gz"));
        assert!(r[0].sum_url.ends_with("GE-Proton10-4.sha512sum"));
        assert_eq!(r[1].tarball, "GE-Proton10-3.tar.gz");
    }

    #[test]
    fn cachy_picks_cpu_level() {
        let j = r#"[{"tag_name":"cachyos-10.0-20251111-slr","assets":[{"browser_download_url":"https://x/proton-cachyos-10.0-20251111-slr-x86_64.tar.xz"},{"browser_download_url":"https://x/proton-cachyos-10.0-20251111-slr-x86_64.tar.xz.sha512sum"},{"browser_download_url":"https://x/proton-cachyos-10.0-20251111-slr-x86_64_v3.tar.xz"},{"browser_download_url":"https://x/proton-cachyos-10.0-20251111-slr-x86_64_v3.tar.xz.sha512sum"}]}]"#;
        let v3 = parse_releases(j, Family::Cachy, true);
        assert!(v3[0].tarball.contains("x86_64_v3"));
        assert!(v3[0].sum_url.ends_with("_v3.tar.xz.sha512sum"));
        let plain = parse_releases(j, Family::Cachy, false);
        assert!(plain[0].tarball.ends_with("-x86_64.tar.xz"));
        assert!(plain[0].sum_url.ends_with("-x86_64.tar.xz.sha512sum"));
    }

    #[test]
    fn families() {
        assert_eq!(family_of("GE-Proton10-4"), Some(Family::Ge));
        assert_eq!(family_of("proton-cachyos-10.0-20251111-slr-x86_64_v3"), Some(Family::Cachy));
        assert_eq!(family_of("Proton-9.0"), None);
        assert!(valid_runtime_name("GE-Proton10-4"));
        assert!(!valid_runtime_name("../evil"));
    }
}
