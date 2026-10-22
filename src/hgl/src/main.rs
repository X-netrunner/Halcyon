//! hgl — Halcyon game launcher core.
//!
//! Library, Steam / Epic / GOG, Proton runtimes, doctor, scoped runs, logs, crash triage, cover art and known fixes. The Game Center in the island (and the `>games`
//! commands) call this binary; everything also works from a terminal. `--json` output is for the UI.

mod art;
mod class;
mod doctor;
mod epic;
mod fixes;
mod flatpak;
mod gog;
mod json;
mod proton;
mod run;
mod steam;
mod store;
mod triage;
mod util;
mod vdf;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::exit;
use store::{Conf, Game};
use util::*;

const USAGE: &str = "hgl — Halcyon game launcher

Library
  hgl list [--json]                       games, last played first
  hgl show <id> [--json]                  one game's profile
  hgl add <game.exe> [--name N] [--proton V] [--prefix DIR] [--args STR] [--umu-id ID] [--wayland] [--no-icon]
  hgl set <id> <key> <value>              name exe proton prefix args wrappers gamescope wayland lean debug umu_id cover env.NAME
  hgl remove <id> [--prefix]              forget a game (--prefix also deletes its Wine prefix)
  hgl import steam                        read the Steam library (appmanifests, cover art)
  hgl import epic                         add the games legendary has installed
  hgl import gog [<folder> ...]           add the GOG games found in the install folders (and any folder you name)
  hgl import flatpak                      add the installed Flatpak apps that are games (Sober ...)
  hgl art [<id>] [--force]                fetch cover art (Steam CDN, Epic, GOG; SteamGridDB with your key)
  hgl fixes <id> [--apply]                known notes and fixes for a game (see fixes.db)

Stores
  hgl epic login | logout | status [--json] | list [--json] | install <app name>      (needs legendary)
  hgl gog login [<address or code>] | status [--json] | list [--json] | install <id> [--title T]   (needs gogdl)

Run
  hgl run <id> [--dry-run] [--no-lean] [--no-scope]
  hgl stop [<id>]                         stop the running game (its whole scope: no stray wineserver)
  hgl status                              running game, as JSON
  hgl recover                             restore Halcyon after a session that did not finish cleanly
  hgl logs <id> [--list]                  newest log (path; with no flag, its last lines)
  hgl triage <id> [--json]                look for known crash causes in the newest log
  hgl fix <id> <finding>                  apply the fix triage offers

Runtimes
  hgl proton list [--json]                installed runtimes
  hgl proton available [--family ge|cachyos]
  hgl proton install [latest|<tag>] [--family ge|cachyos]
  hgl proton remove <name>
  hgl proton default <name>               hgl proton rollback
  hgl proton prune                        keep the newest 3 per family (never a pinned or default one)
  hgl proton link-steam [--off]           also show them in Steam's compatibility tool list

Machine
  hgl doctor [--fix] [--yes] [--json]     check Vulkan, 32-bit libraries, umu, gamemode, gamescope, mangohud
  hgl class [--json]                      this machine's gaming class: A high end, B mid range, C entry, D integrated graphics
  hgl suggest <id> [--apply] [--json]     the settings suggested for a game on this class (what hgl sets, and what to set in the game)
  hgl config [<key> <value>]              global options (proton_family, proton_keep, game_weight, halcyon_weight, halcyon_core,
                                          games_dir, steamgriddb_key, epic_config, gogdl, gog_dirs ...)
";

struct Args {
    pos: Vec<String>,
    flags: HashMap<String, String>,
}

impl Args {
    /// `value_flags` take a value; every other `--flag` is on/off.
    fn parse(raw: &[String], value_flags: &[&str]) -> Args {
        let mut pos = Vec::new();
        let mut flags = HashMap::new();
        let mut i = 0;
        while i < raw.len() {
            let a = &raw[i];
            if let Some(f) = a.strip_prefix("--") {
                if let Some((k, v)) = f.split_once('=') {
                    flags.insert(k.to_string(), v.to_string());
                } else if value_flags.contains(&f) && i + 1 < raw.len() {
                    flags.insert(f.to_string(), raw[i + 1].clone());
                    i += 1;
                } else {
                    flags.insert(f.to_string(), String::new());
                }
            } else if a == "-y" {
                flags.insert("yes".to_string(), String::new());
            } else {
                pos.push(a.clone());
            }
            i += 1;
        }
        Args { pos, flags }
    }
    fn has(&self, f: &str) -> bool {
        self.flags.contains_key(f)
    }
    fn val(&self, f: &str) -> Option<&str> {
        self.flags.get(f).map(|s| s.as_str()).filter(|s| !s.is_empty())
    }
    fn need(&self, n: usize, what: &str) -> Result<&str, String> {
        self.pos.get(n).map(|s| s.as_str()).ok_or_else(|| format!("missing {what}\n\n{USAGE}"))
    }
}

fn die(msg: &str) -> ! {
    eprintln!("hgl: {msg}");
    exit(1)
}

fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = raw.first().cloned() else {
        print!("{USAGE}");
        return;
    };
    let rest = &raw[1..];
    let res: Result<i32, String> = match cmd.as_str() {
        "list" | "ls" => cmd_list(rest),
        "show" => cmd_show(rest),
        "add" => cmd_add(rest),
        "set" => cmd_set(rest),
        "remove" | "rm" => cmd_remove(rest),
        "import" => cmd_import(rest),
        "run" | "launch" => cmd_run(rest),
        "stop" => cmd_stop(rest),
        "status" => {
            run::recover_stale();
            println!("{}", run::status_json());
            Ok(0)
        }
        "recover" => {
            if !run::recover_stale() {
                println!("Nothing to restore.");
            }
            Ok(0)
        }
        "logs" => cmd_logs(rest),
        "triage" => cmd_triage(rest),
        "fix" => cmd_fix(rest),
        "proton" => cmd_proton(rest),
        "doctor" => cmd_doctor(rest),
        "class" => cmd_class(rest),
        "suggest" => cmd_suggest(rest),
        "config" => cmd_config(rest),
        "epic" => cmd_epic(rest),
        "gog" => cmd_gog(rest),
        "art" => cmd_art(rest),
        "fixes" => cmd_fixes(rest),
        "__watch" => {
            let n = |i: usize| rest.get(i).and_then(|s| s.parse::<u64>().ok()).unwrap_or(0);
            run::watch(n(0) as u32, n(1));
            Ok(0)
        }
        "-h" | "--help" | "help" => {
            print!("{USAGE}");
            Ok(0)
        }
        "-V" | "--version" | "version" => {
            println!("hgl {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        other => Err(format!("unknown command '{other}'\n\n{USAGE}")),
    };
    match res {
        Ok(0) => {}
        Ok(c) => exit(c),
        Err(e) => die(&e),
    }
}

// ------------------------------------------------------------------------------------------------ library

/// "ready" or "attention" with the reason the badge shows.
fn game_status(g: &Game, cfg: &Conf, have_umu: bool, have_runtime: bool) -> (&'static str, String) {
    if g.source == "steam" {
        if !have("steam") {
            return ("attention", "Steam is not installed".into());
        }
        return ("ready", String::new());
    }
    if g.source == "flatpak" {
        if !have("flatpak") {
            return ("attention", "flatpak is not installed".into());
        }
        if run::looks_crashed(g.last_exit, g.last_run_secs) {
            return ("attention", format!("last run ended with code {} after {}s", g.last_exit.unwrap_or(-1), g.last_run_secs));
        }
        return ("ready", String::new());
    }
    if g.source == "epic" && !have("legendary") {
        return ("attention", "legendary is not installed (Doctor)".into());
    }
    if g.exe.is_empty() || !Path::new(&g.exe).is_file() {
        return ("attention", "game file not found".into());
    }
    if !have_umu {
        return ("attention", "umu-run is not installed (Doctor)".into());
    }
    if !g.proton.is_empty() && proton::resolve(&g.proton, cfg).is_none() {
        return ("attention", format!("pinned Proton {} is not installed", g.proton));
    }
    if g.proton.is_empty() && !have_runtime {
        return ("attention", "no Proton runtime installed".into());
    }
    if run::looks_crashed(g.last_exit, g.last_run_secs) {
        return ("attention", format!("last run ended with code {} after {}s", g.last_exit.unwrap_or(-1), g.last_run_secs));
    }
    ("ready", String::new())
}

fn game_json(g: &Game, status: (&str, &str), running: bool, known: &str) -> String {
    let wr: Vec<String> = g.wrappers.iter().map(|w| json_str(w)).collect();
    let env: Vec<String> = g.env.iter().map(|(k, v)| format!("{}:{}", json_str(k), json_str(v))).collect();
    let cover = if !g.cover.is_empty() && Path::new(&g.cover).is_file() { g.cover.as_str() } else { "" };
    format!(
        "{{\"id\":{},\"name\":{},\"source\":{},\"exe\":{},\"appid\":{},\"proton\":{},\"prefix\":{},\"args\":{},\"wrappers\":[{}],\"gamescope\":{},\"wayland\":{},\"lean\":{},\"debug\":{},\"umuId\":{},\"env\":{{{}}},\"cover\":{},\"lastPlayed\":{},\"playtime\":{},\"lastExit\":{},\"status\":{},\"statusReason\":{},\"running\":{},\"known\":{}}}",
        json_str(&g.id),
        json_str(&g.name),
        json_str(&g.source),
        json_str(&g.exe),
        json_str(&g.appid),
        json_str(&g.proton),
        json_str(&g.prefix_path().to_string_lossy()),
        json_str(&g.args),
        wr.join(","),
        json_str(&g.gamescope),
        g.wayland,
        g.lean,
        g.debug,
        json_str(&g.umu_id),
        env.join(","),
        json_str(cover),
        g.last_played,
        g.playtime,
        g.last_exit.map(|c| c.to_string()).unwrap_or_else(|| "null".into()),
        json_str(status.0),
        json_str(status.1),
        running,
        json_str(known)
    )
}

fn cmd_list(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let cfg = Conf::load();
    let have_umu = have("umu-run");
    let have_rt = proton::resolve("", &cfg).is_some();
    let running = run::running_id();
    let games = store::all_games();
    if a.has("json") {
        let db = fixes::Db::load();
        let items: Vec<String> = games
            .iter()
            .map(|g| {
                let (st, why) = game_status(g, &cfg, have_umu, have_rt);
                game_json(g, (st, &why), running.as_deref() == Some(g.id.as_str()), &db.note_for(g))
            })
            .collect();
        println!("[{}]", items.join(","));
        return Ok(0);
    }
    if games.is_empty() {
        println!("No games yet. Add one: hgl add /path/to/game.exe   or   hgl import steam");
        return Ok(0);
    }
    for g in &games {
        let (st, why) = game_status(g, &cfg, have_umu, have_rt);
        let when = if g.last_played == 0 { "never".to_string() } else { format!("{} ago", fmt_duration(now().saturating_sub(g.last_played))) };
        let flag = if running.as_deref() == Some(g.id.as_str()) { " [running]" } else { "" };
        let note = if st == "attention" { format!("  ! {why}") } else { String::new() };
        println!("{:<28} {:<7} {:<26} played {:>9}  last {}{}{}", g.id, g.source, g.name, fmt_duration(g.playtime), when, flag, note);
    }
    Ok(0)
}

fn cmd_show(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let g = Game::load(a.need(0, "game id")?)?;
    let cfg = Conf::load();
    let (st, why) = game_status(&g, &cfg, have("umu-run"), proton::resolve("", &cfg).is_some());
    let known = fixes::Db::load().note_for(&g);
    if a.has("json") {
        println!("{}", game_json(&g, (st, &why), run::running_id().as_deref() == Some(g.id.as_str()), &known));
    } else {
        print!("{}", g.serialize());
        let rt = proton::resolve(&g.proton, &cfg).map(|r| r.name).unwrap_or_else(|| "(none)".into());
        println!("# runtime in use: {rt}\n# prefix: {}\n# status: {st} {why}", g.prefix_path().display());
        if !known.is_empty() {
            println!("# known: {known}");
        }
    }
    Ok(0)
}

fn name_from_exe(p: &Path) -> String {
    let stem = p.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "Game".into());
    let spaced = stem.replace(['_', '-'], " ");
    let mut out = String::new();
    let mut prev_lower = false;
    for c in spaced.chars() {
        if c.is_ascii_uppercase() && prev_lower {
            out.push(' ');
        }
        prev_lower = c.is_ascii_lowercase();
        out.push(c);
    }
    out.trim().to_string()
}

/// Best-effort offline icon: wrestool pulls the icon group out of the exe, icotool converts the largest to PNG.
fn extract_icon(exe: &Path, id: &str) -> Option<PathBuf> {
    if !have("wrestool") || !have("icotool") {
        return None;
    }
    let tmp = std::env::temp_dir().join(format!("hgl-icon-{}-{}", std::process::id(), id));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).ok()?;
    let result = (|| {
        let ex = exe.to_string_lossy().to_string();
        let t = tmp.to_string_lossy().to_string();
        if !run_quiet("wrestool", &["-x", "--type=14", "-o", &t, &ex], 20) {
            return None;
        }
        let mut icos: Vec<PathBuf> = fs::read_dir(&tmp).ok()?.flatten().map(|e| e.path()).filter(|p| p.extension().map(|x| x == "ico").unwrap_or(false)).collect();
        icos.sort();
        let ico = icos.first()?.to_string_lossy().to_string();
        if !run_quiet("icotool", &["-x", "-o", &t, &ico], 20) {
            return None;
        }
        let mut pngs: Vec<PathBuf> = fs::read_dir(&tmp).ok()?.flatten().map(|e| e.path()).filter(|p| p.extension().map(|x| x == "png").unwrap_or(false)).collect();
        pngs.sort_by_key(|p| fs::metadata(p).map(|m| m.len()).unwrap_or(0));
        let best = pngs.pop()?;
        let dest = covers_dir().join(format!("{id}.png"));
        fs::create_dir_all(covers_dir()).ok()?;
        fs::copy(best, &dest).ok()?;
        Some(dest)
    })();
    let _ = fs::remove_dir_all(&tmp);
    result
}

fn cmd_add(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &["name", "proton", "prefix", "args", "umu-id"]);
    let exe_arg = a.need(0, "path to the game's .exe")?;
    let exe = fs::canonicalize(exe_arg).map_err(|e| format!("{exe_arg}: {e}"))?;
    if !exe.is_file() {
        return Err(format!("{} is not a file", exe.display()));
    }
    let name = a.val("name").map(|s| s.to_string()).unwrap_or_else(|| name_from_exe(&exe));
    let id = store::unique_id(&name);
    let mut g = Game::new(&id, &name, "exe");
    g.exe = exe.to_string_lossy().to_string();
    if let Some(p) = a.val("proton") {
        g.set("proton", p)?;
    }
    if let Some(p) = a.val("prefix") {
        g.set("prefix", p)?;
    }
    if let Some(p) = a.val("args") {
        g.set("args", p)?;
    }
    if let Some(p) = a.val("umu-id") {
        g.set("umu_id", p)?;
    }
    if a.has("wayland") {
        g.wayland = true;
    }
    if !a.has("no-icon") {
        if let Some(p) = extract_icon(&exe, &id) {
            g.cover = p.to_string_lossy().to_string();
        }
    }
    let applied = fixes::Db::load().apply(&mut g, false);
    g.save()?;
    println!("Added {name} as '{id}'{}", if g.cover.is_empty() { "" } else { " (icon extracted)" });
    for c in &applied {
        println!("Known fix applied: {c}");
    }
    // SteamGridDB art only when you gave a key: otherwise adding a game never touches the network
    if !a.has("no-icon") && Conf::load().get("steamgriddb_key").is_some() {
        let (found, _) = art::fetch_ids(&[id.clone()], false);
        if found > 0 {
            println!("Cover art found.");
        }
    }
    println!("Run it: hgl run {id}");
    Ok(0)
}

fn cmd_set(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let mut g = Game::load(a.need(0, "game id")?)?;
    let key = a.need(1, "key")?;
    let val = a.pos.get(2).map(|s| s.as_str()).unwrap_or("");
    g.set(key, val)?;
    g.save()?;
    println!("{}: {key} = {}", g.id, if val.is_empty() { "(cleared)" } else { val });
    Ok(0)
}

fn cmd_remove(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let id = a.need(0, "game id")?;
    let g = Game::load(id)?;
    if run::running_id().as_deref() == Some(id) {
        return Err("it is running: hgl stop first".into());
    }
    Game::remove(id)?;
    if a.has("prefix") && g.prefix.is_empty() {
        // only the prefix hgl created itself; a custom prefix path is never deleted
        let p = prefixes_dir().join(id);
        if p.is_dir() {
            fs::remove_dir_all(&p).map_err(|e| format!("cannot remove {}: {e}", p.display()))?;
        }
    }
    println!("Removed {}.", g.name);
    Ok(0)
}

fn cmd_import(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    match a.need(0, "source (steam)")? {
        "steam" => {
            let (added, updated, removed) = steam::import()?;
            println!("Steam: {added} added, {updated} updated, {removed} no longer installed (removed from the library)");
            Ok(0)
        }
        "epic" => {
            let r = epic::import()?;
            finish_import("Epic", &r)
        }
        "flatpak" => {
            let (added, updated, removed) = flatpak::import()?;
            println!("Flatpak: {added} added, {updated} updated, {removed} no longer installed (removed from the library)");
            Ok(0)
        }
        "gog" => {
            let extra: Vec<String> = a.pos.iter().skip(1).cloned().collect();
            let r = gog::import(&extra)?;
            finish_import("GOG", &r)
        }
        other => Err(format!("cannot import '{other}' (steam, epic or gog; Heroic and Lutris libraries are not read yet)")),
    }
}

/// After an Epic / GOG import: the known fixes for the new games, then their cover art.
fn finish_import(label: &str, r: &store::Imported) -> Result<i32, String> {
    let db = fixes::Db::load();
    for id in &r.added {
        if let Ok(mut g) = Game::load(id) {
            let _ = db.apply(&mut g, false);
            let _ = g.save();
        }
    }
    let (found, _) = art::fetch_ids(&r.added, false);
    let art_note = if found > 0 { format!(", art for {found}") } else { String::new() };
    println!("{label}: {} added, {} updated, {} no longer installed (removed from the library){art_note}", r.added.len(), r.updated, r.removed);
    Ok(0)
}

// ------------------------------------------------------------------------------------------------ stores, art, fixes

fn cmd_epic(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    match a.need(0, "an Epic subcommand (login, logout, status, list, install)")? {
        "login" => epic::login(),
        "logout" => epic::logout(),
        "status" => {
            let s = epic::status();
            if a.has("json") {
                println!("{{\"installed\":{},\"loggedIn\":{},\"account\":{}}}", s.installed, s.logged_in, json_str(&s.account));
            } else if !s.installed {
                println!("legendary is not installed (see: hgl doctor)");
            } else if s.logged_in {
                println!("Logged in to Epic as {}", s.account);
            } else {
                println!("Not logged in. Run: hgl epic login");
            }
            Ok(0)
        }
        "list" => {
            if a.has("json") {
                println!("{}", epic::titles_json()?);
            } else {
                for t in epic::owned()? {
                    println!("{:<34} {}{}", t.app, t.title, if t.installed { "  [installed]" } else { "" });
                }
            }
            Ok(0)
        }
        "install" => epic::install(a.need(1, "the Epic app name (hgl epic list)")?),
        other => Err(format!("unknown epic subcommand '{other}'")),
    }
}

fn cmd_gog(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &["title"]);
    match a.need(0, "a GOG subcommand (login, status, list, install)")? {
        "login" => gog::login(a.pos.get(1).map(|s| s.as_str())),
        "status" => {
            let present = gog::gogdl_present();
            let logged = gog::logged_in();
            if a.has("json") {
                println!("{{\"installed\":{present},\"loggedIn\":{logged},\"url\":{}}}", json_str(&gog::login_url()));
            } else if !present {
                println!("gogdl is not installed (see: hgl doctor)");
            } else if logged {
                println!("Logged in to GOG.");
            } else {
                println!("Not logged in. Run: hgl gog login");
            }
            Ok(0)
        }
        "list" => {
            if a.has("json") {
                println!("{}", gog::titles_json()?);
            } else {
                for t in gog::owned()? {
                    println!("{:<12} {}{}", t.id, t.title, if t.installed { "  [installed]" } else { "" });
                }
            }
            Ok(0)
        }
        "install" => gog::install(a.need(1, "the GOG product id (hgl gog list)")?, a.val("title")),
        other => Err(format!("unknown gog subcommand '{other}'")),
    }
}

fn cmd_art(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let ids: Vec<String> = match a.pos.first() {
        Some(id) => {
            Game::load(id)?;
            vec![id.clone()]
        }
        None => store::list_ids(),
    };
    let (found, tried) = art::fetch_ids(&ids, a.has("force"));
    println!("Cover art: {found} found, {} of {tried} still without", tried - found);
    if tried > found && !art::Ctx::new().has_key() {
        println!("Games from other sources get art from SteamGridDB: get a free key at steamgriddb.com/profile/preferences/api, then: hgl config steamgriddb_key <key>");
    }
    Ok(0)
}

fn cmd_fixes(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let mut g = Game::load(a.need(0, "game id")?)?;
    let db = fixes::Db::load();
    if a.has("apply") {
        let done = db.apply(&mut g, true);
        g.save()?;
        if done.is_empty() {
            println!("Nothing to change for {}.", g.name);
        }
        for c in done {
            println!("Applied: {c}");
        }
        return Ok(0);
    }
    let note = db.note_for(&g);
    let changes = db.changes_for(&g);
    if note.is_empty() && changes.is_empty() {
        println!("No known fixes or warnings for {}.", g.name);
        return Ok(0);
    }
    if !note.is_empty() {
        println!("{note}");
    }
    for c in &changes {
        println!("  would set: {c}");
    }
    if !changes.is_empty() {
        println!("Apply them: hgl fixes {} --apply", g.id);
    }
    Ok(0)
}

// ------------------------------------------------------------------------------------------------ run

fn cmd_run(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let id = a.need(0, "game id")?;
    run::run(id, &run::RunOpts { dry: a.has("dry-run"), no_lean: a.has("no-lean"), no_scope: a.has("no-scope") })
}

fn cmd_stop(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    run::stop(a.pos.first().map(|s| s.as_str()))?;
    println!("Stopping.");
    Ok(0)
}

fn cmd_logs(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let id = a.need(0, "game id")?;
    Game::load(id)?;
    if a.has("list") {
        let dir = logs_dir().join(id);
        let mut v: Vec<PathBuf> = fs::read_dir(dir).map(|rd| rd.flatten().map(|e| e.path()).collect()).unwrap_or_default();
        v.sort();
        for p in v.iter().rev() {
            println!("{}", p.display());
        }
        return Ok(0);
    }
    let Some(p) = triage::latest_log(id) else { return Err(format!("no log yet for {id}")) };
    println!("{}", p.display());
    let text = fs::read_to_string(&p).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    for l in &lines[lines.len().saturating_sub(40)..] {
        println!("{l}");
    }
    Ok(0)
}

fn cmd_triage(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let (log, found) = triage::scan_game(a.need(0, "game id")?)?;
    if a.has("json") {
        triage::print_json(&log, &found);
        return Ok(0);
    }
    match &log {
        None => println!("No log yet."),
        Some(p) => println!("Log: {}", p.display()),
    }
    if found.is_empty() {
        println!("No known problem found in the log.");
    }
    for f in &found {
        println!("\n* {} [{}]\n  {}", f.title, f.id, f.detail);
        let l = triage::fix_label(&f.fix);
        if !l.is_empty() {
            println!("  Fix it: hgl fix {} {}   ({l})", a.pos[0], f.id);
        }
    }
    Ok(0)
}

fn cmd_fix(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let id = a.need(0, "game id")?;
    let fid = a.need(1, "finding id (see: hgl triage <id>)")?;
    let (_, found) = triage::scan_game(id)?;
    let f = found.iter().find(|f| f.id == fid).ok_or_else(|| format!("'{fid}' was not found in the newest log of {id}"))?;
    let mut g = Game::load(id)?;
    match &f.fix {
        triage::Fix::Doctor => {
            let checks = doctor::run_checks();
            doctor::print_human(&checks);
            return Ok(if doctor::fix(&checks, a.has("yes")) { 0 } else { 1 });
        }
        triage::Fix::SetEnv(k, v) => {
            g.set(&format!("env.{k}"), v)?;
        }
        triage::Fix::SetKey(k, v) => {
            g.set(k, v)?;
        }
        triage::Fix::DropWrapper(w) => {
            if *w == "gamescope" {
                g.gamescope.clear();
            } else {
                g.wrappers.retain(|x| x != w);
            }
        }
        triage::Fix::ProtonInstall => {
            let mut cfg = Conf::load();
            let fam = proton::default_family(&cfg);
            let n = proton::install("latest", fam, &mut cfg)?;
            println!("Installed {n}");
            return Ok(0);
        }
        triage::Fix::Hint => return Err(format!("{}: there is nothing hgl can change for this one. {}", f.title, f.detail)),
    }
    g.save()?;
    println!("Done: {}. Launch again.", triage::fix_label(&f.fix));
    Ok(0)
}

// ------------------------------------------------------------------------------------------------ runtimes

fn cmd_proton(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &["family"]);
    let sub = a.need(0, "proton subcommand")?;
    let mut cfg = Conf::load();
    let fam = match a.val("family") {
        Some(f) => proton::Family::parse(f).ok_or_else(|| format!("unknown family '{f}' (ge or cachyos)"))?,
        None => proton::default_family(&cfg),
    };
    match sub {
        "list" => {
            let def = proton::resolve("", &cfg).map(|r| r.name);
            let pinned: Vec<String> = store::all_games().into_iter().map(|g| g.proton).filter(|p| !p.is_empty()).collect();
            let all = proton::installed();
            if a.has("json") {
                let items: Vec<String> = all
                    .iter()
                    .map(|r| {
                        format!(
                            "{{\"name\":{},\"path\":{},\"default\":{},\"pinned\":{},\"family\":{}}}",
                            json_str(&r.name),
                            json_str(&r.path.to_string_lossy()),
                            def.as_deref() == Some(r.name.as_str()),
                            pinned.contains(&r.name),
                            json_str(proton::family_of(&r.name).map(|f| f.label()).unwrap_or("other"))
                        )
                    })
                    .collect();
                println!("[{}]", items.join(","));
            } else if all.is_empty() {
                println!("No Proton installed. Run: hgl proton install latest");
            } else {
                for r in all.iter().rev() {
                    let d = if def.as_deref() == Some(r.name.as_str()) { "  (default)" } else { "" };
                    let p = if pinned.contains(&r.name) { "  (pinned by a game)" } else { "" };
                    println!("{}{d}{p}", r.name);
                }
            }
        }
        "available" => {
            for r in proton::available(fam, 10)? {
                let have = proton::installed().iter().any(|i| r.tarball.starts_with(&i.name));
                println!("{}{}", r.tag, if have { "  (installed)" } else { "" });
            }
        }
        "install" => {
            let spec = a.pos.get(1).map(|s| s.as_str()).unwrap_or("latest");
            let name = proton::install(spec, fam, &mut cfg)?;
            println!("Installed {name}");
        }
        "remove" => {
            let n = a.need(1, "runtime name")?;
            proton::remove(n, &cfg)?;
            println!("Removed {n}");
        }
        "default" => {
            let n = a.need(1, "runtime name")?;
            proton::set_default(n, &mut cfg)?;
            println!("Default runtime: {n}");
        }
        "rollback" => {
            let (from, to) = proton::rollback(&mut cfg)?;
            println!("Default runtime: {from} -> {to}");
        }
        "prune" => {
            let gone = proton::prune(&cfg)?;
            if gone.is_empty() {
                println!("Nothing to remove.");
            }
            for g in gone {
                println!("Removed {g}");
            }
        }
        "link-steam" => {
            if a.has("off") {
                proton::unlink_steam_all();
                cfg.set("steam_link", "0")?;
                println!("Removed hgl's links from Steam's compatibilitytools.d");
            } else {
                cfg.set("steam_link", "1")?;
                let n = proton::link_steam_all();
                println!("{n} runtime(s) linked. Restart Steam to see them in its compatibility list.");
            }
        }
        other => return Err(format!("unknown proton subcommand '{other}'")),
    }
    Ok(0)
}

// ------------------------------------------------------------------------------------------------ machine

fn cmd_class(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let m = class::detect();
    if a.has("json") {
        println!("{}", class::machine_json(&m));
    } else {
        class::print_human(&m);
    }
    Ok(0)
}

fn cmd_suggest(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let mut g = Game::load(a.need(0, "game id")?)?;
    let m = class::detect();
    let changes = class::suggest(&g, &m);
    let game_tips = class::in_game(m.class, class::nvidia_rtx(&m));
    let cfg = Conf::load();
    let names: Vec<String> = proton::installed().into_iter().map(|r| r.name).collect();
    let cur = proton::resolve(&g.proton, &cfg).map(|r| r.name);
    let ptip = class::proton_tip(&g, &m, &names, cur.as_deref(), proton::cpu_has_v3());
    if a.has("apply") {
        for c in &changes {
            g.set(&c.key, &c.value)?;
        }
        g.save()?;
    }
    if a.has("json") {
        let ch: Vec<String> = changes
            .iter()
            .map(|c| format!("{{\"key\":{},\"value\":{},\"why\":{}}}", json_str(&c.key), json_str(&c.value), json_str(&c.why)))
            .collect();
        let tips: Vec<String> = game_tips.iter().map(|t| json_str(t)).collect();
        let pj = ptip
            .as_ref()
            .map(|t| format!("{{\"family\":{},\"action\":{},\"current\":{},\"why\":{},\"alt\":{}}}", json_str(&t.family), json_str(&t.action), json_str(&t.current), json_str(&t.why), json_str(&t.alt)))
            .unwrap_or_else(|| "null".into());
        println!(
            "{{\"machine\":{},\"changes\":[{}],\"inGame\":[{}],\"proton\":{},\"applied\":{}}}",
            class::machine_json(&m),
            ch.join(","),
            tips.join(","),
            pj,
            a.has("apply")
        );
        return Ok(0);
    }
    println!("{} on a class {} machine ({})", g.name, m.class, class::class_label(m.class));
    if changes.is_empty() {
        println!("  hgl settings: nothing to change");
    } else {
        println!("  hgl settings{}:", if a.has("apply") { " (applied)" } else { " (hgl suggest <id> --apply sets them)" });
        for c in &changes {
            println!("    {} = {}    {}", c.key, if c.value.is_empty() { "(off)" } else { &c.value }, c.why);
        }
    }
    if let Some(t) = &ptip {
        println!("  Proton: {}{}", t.why, if t.action == "install" { format!("  (hgl proton install latest --family {})", t.family) } else { String::new() });
        if !t.alt.is_empty() {
            println!("          {}", t.alt);
        }
    }
    println!("  In the game:");
    for t in &game_tips {
        println!("    {t}");
    }
    Ok(0)
}

fn cmd_doctor(rest: &[String]) -> Result<i32, String> {
    let a = Args::parse(rest, &[]);
    let checks = doctor::run_checks();
    if a.has("json") {
        doctor::print_json(&checks);
        return Ok(0);
    }
    doctor::print_human(&checks);
    if a.has("fix") {
        let ok = doctor::fix(&checks, a.has("yes"));
        let after = doctor::run_checks();
        println!("After the fixes:");
        doctor::print_human(&after);
        return Ok(if ok { 0 } else { 1 });
    }
    let bad = checks.iter().filter(|c| c.level == doctor::Level::Fail).count();
    if checks.iter().any(|c| c.level != doctor::Level::Ok && (!c.pkgs.is_empty() || c.cmd.is_some())) {
        println!("\nRun: hgl doctor --fix");
    }
    Ok(if bad > 0 { 1 } else { 0 })
}

fn cmd_config(rest: &[String]) -> Result<i32, String> {
    let mut cfg = Conf::load();
    let keys = [
        "proton_family",
        "proton_default",
        "proton_keep",
        "steam_link",
        "game_weight",
        "halcyon_weight",
        "halcyon_throttle",
        "halcyon_core",
        "games_dir",
        "steamgriddb_key",
        "epic_config",
        "gogdl",
        "gog_dirs",
    ];
    match rest.len() {
        0 => {
            for k in keys {
                // an API key is not printed in full
                let v = cfg.get(k).unwrap_or("");
                println!("{k} = {}", if k.ends_with("_key") && !v.is_empty() { "(set)" } else { v });
            }
        }
        1 => println!("{}", cfg.get(&rest[0]).unwrap_or("")),
        _ => {
            if !keys.contains(&rest[0].as_str()) {
                return Err(format!("unknown option '{}' (known: {})", rest[0], keys.join(", ")));
            }
            if rest[1].contains('\n') {
                return Err("a value cannot contain a line break".into());
            }
            cfg.set(&rest[0], &rest[1])?;
            println!("{} = {}", rest[0], rest[1]);
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exe_names() {
        assert_eq!(name_from_exe(Path::new("/g/HadesII.exe")), "Hades II");
        assert_eq!(name_from_exe(Path::new("/g/my_cool-game.exe")), "my cool game");
    }

    #[test]
    fn arg_parsing() {
        let raw: Vec<String> = ["a.exe", "--name", "X Y", "--wayland", "-y"].iter().map(|s| s.to_string()).collect();
        let a = Args::parse(&raw, &["name"]);
        assert_eq!(a.pos, vec!["a.exe"]);
        assert_eq!(a.val("name"), Some("X Y"));
        assert!(a.has("wayland") && a.has("yes"));
    }
}
