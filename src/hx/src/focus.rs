//! Halcyon focus mode (port of scripts/focus.py): an advanced do-not-disturb with a timer and an app block list.
//!
//!   hx focus start [MINUTES] [pomo]   start a session (no MINUTES = the saved length)
//!   hx focus stop | toggle            end it (everything goes back to how it was)
//!   hx focus pause | resume           lift the app block for a moment, the timer stands still
//!   hx focus add MINUTES              make the running phase longer
//!   hx focus skip                     end the running phase now
//!   hx focus status | conf | apps     JSON for the island
//!   hx focus set KEY VALUE            save an option
//!   hx focus block CLASS [CLASS...] | unblock CLASS
//!   hx focus daemon                   the helper process of a running session (started by `start`, never by hand)
//!   hx focus ping                     exit 0: lets scripts/focus.sh know this build has focus mode
//!
//! The files and the JSON it prints are the same as the Python version's, so the island needs no change. What changes is
//! the helper: a small native process instead of a Python interpreter that sits in RAM for the whole session.

use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::Duration;

use crate::util;

const UNIT: &str = "halcyon-focus";
const FLAGS: [&str; 6] = ["POMODORO", "DND", "CAFFEINE", "BLOCK", "CLOSE_RUNNING", "BREAK_FREE"];

// ------------------------------------------------------------------ paths
fn rt() -> String {
    std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }))
}
fn state_path() -> String { format!("{}/halcyon-focus.json", rt()) }                              // the live session (gone at logout)
fn marker_path() -> String { format!("{}/.local/state/island/focus-restore.json", util::home()) } // what to put back after a crash
fn conf_path() -> String { format!("{}/.config/Halcyon/focus.conf", util::home()) }
fn apps_path() -> String { format!("{}/.config/Halcyon/focus-apps.conf", util::home()) }
fn settings_path() -> String { format!("{}/.local/state/island/settings.json", util::home()) }
fn island_dir() -> String { format!("{}/.config/Halcyon/quickshell/island", util::home()) }
fn scripts_dir() -> String {
    // <rice>/bin/hx  ->  <rice>/scripts ; fall back to the installed rice
    if let Ok(exe) = std::env::current_exe() {
        if let Some(rice) = exe.parent().and_then(|p| p.parent()) {
            let s = rice.join("scripts");
            if s.join("caffeine.sh").exists() {
                return s.to_string_lossy().into_owned();
            }
        }
    }
    format!("{}/.config/Halcyon/scripts", util::home())
}

// ------------------------------------------------------------------ small helpers
fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|x| x != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}
fn ni(v: &Value) -> i64 { v.as_i64().or_else(|| v.as_f64().map(|x| x as i64)).unwrap_or(0) }
fn nf(v: &Value) -> f64 { v.as_f64().unwrap_or(0.0) }

fn island(args: &[&str]) {
    let isl = island_dir();
    let mut v: Vec<&str> = vec!["ipc", "-p", isl.as_str(), "call", "island"];
    v.extend_from_slice(args);
    util::run("quickshell", &v, 4);
}

fn notify(title: &str, body: &str, critical: bool, icon: &str) {
    let mut v: Vec<&str> = vec!["-a", "Halcyon", "-i", icon, "-t", "6000"];
    if critical {
        v.push("-u");
        v.push("critical"); // critical ones are the only popups Do not disturb lets through
    }
    v.push(title);
    v.push(body);
    util::run("notify-send", &v, 3);
}

fn chime() {
    for f in ["/usr/share/sounds/freedesktop/stereo/complete.oga", "/usr/share/sounds/freedesktop/stereo/message.oga"] {
        if std::path::Path::new(f).exists() {
            for player in ["paplay", "pw-play"] {
                if let Ok(mut c) = Command::new(player).arg(f).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
                    std::thread::spawn(move || {
                        let _ = c.wait();
                    });
                    return;
                }
            }
            return;
        }
    }
}

fn caffeine(args: &[&str]) -> String {
    let p = format!("{}/caffeine.sh", scripts_dir());
    let mut v: Vec<&str> = vec![p.as_str()];
    v.extend_from_slice(args);
    util::run("bash", &v, 6).trim().to_string()
}

fn dnd_is_on() -> bool {
    read_json(&settings_path()).map(|v| truthy(&v["dnd"])).unwrap_or(false)
}

fn write_json(path: &str, data: &Value) {
    if let Some(dir) = std::path::Path::new(path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = format!("{}.tmp{}", path, std::process::id());
    let f = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp);
    if let Ok(mut f) = f {
        use std::io::Write;
        if f.write_all(data.to_string().as_bytes()).is_ok() {
            drop(f);
            let _ = std::fs::rename(&tmp, path);
            return;
        }
    }
    let _ = std::fs::remove_file(&tmp);
}

fn read_json(path: &str) -> Option<Value> {
    let s = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&s).ok()
}

// ------------------------------------------------------------------ saved options + blocked apps
type Conf = Vec<(&'static str, i64)>;

fn defaults() -> Conf {
    vec![
        ("LENGTH", 25), ("POMODORO", 0), ("BREAK", 5), ("LONG_BREAK", 15), ("CYCLES", 4),
        ("DND", 1), ("CAFFEINE", 1), ("BLOCK", 1), ("CLOSE_RUNNING", 1), ("BREAK_FREE", 1),
    ]
}
fn cget(c: &Conf, k: &str) -> i64 { c.iter().find(|e| e.0 == k).map(|e| e.1).unwrap_or(0) }
fn cset(c: &mut Conf, k: &str, v: i64) {
    for e in c.iter_mut() {
        if e.0 == k {
            e.1 = v;
        }
    }
}
fn limits(k: &str) -> Option<(i64, i64)> {
    match k {
        "LENGTH" => Some((1, 480)),
        "BREAK" => Some((1, 60)),
        "LONG_BREAK" => Some((1, 120)),
        "CYCLES" => Some((1, 12)),
        _ => None,
    }
}

fn clean(k: &str, v: &str, fallback: i64) -> i64 {
    let v = v.trim().to_lowercase();
    if FLAGS.contains(&k) {
        return match v.as_str() {
            "1" | "true" | "on" | "yes" => 1,
            "0" | "false" | "off" | "no" => 0,
            _ => fallback,
        };
    }
    match (limits(k), v.parse::<f64>()) {
        (Some((lo, hi)), Ok(f)) if f.is_finite() => (f as i64).clamp(lo, hi),
        _ => fallback,
    }
}

fn load_conf() -> Conf {
    let mut c = defaults();
    if let Ok(text) = std::fs::read_to_string(conf_path()) {
        for line in text.lines() {
            if let Some((k, v)) = line.trim().split_once('=') {
                let found = c.iter().find(|e| e.0 == k).map(|e| (e.0, e.1));
                if let Some((name, cur)) = found {
                    cset(&mut c, name, clean(name, v, cur));
                }
            }
        }
    }
    c
}

fn save_conf(c: &Conf) {
    let path = conf_path();
    if let Some(dir) = std::path::Path::new(&path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = format!("{}.tmp", path);
    let mut out = String::new();
    for (k, v) in c {
        out.push_str(&format!("{}={}\n", k, v));
    }
    if std::fs::write(&tmp, out).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

/// a window class: letters, digits and _ . - + * (the * is a wildcard)
fn class_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= 80 && s.chars().all(|c| c.is_ascii_alphanumeric() || "_.-+*".contains(c))
}

fn blocked_list() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Ok(text) = std::fs::read_to_string(apps_path()) {
        for line in text.lines() {
            let l = line.split('#').next().unwrap_or("").trim();
            if !l.is_empty() && class_ok(l) && !out.iter().any(|x| x.eq_ignore_ascii_case(l)) {
                out.push(l.to_string());
            }
        }
    }
    out
}

fn save_blocked(items: &[String]) {
    let path = apps_path();
    if let Some(dir) = std::path::Path::new(&path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = format!("{}.tmp", path);
    let mut out = String::from(
        "# Window classes Focus mode closes while a session runs: one per line, * is a wildcard, case does not matter.\n\
         # Find a class with:  hyprctl clients | grep class      (or add it from Settings > Focus)\n",
    );
    for x in items {
        out.push_str(x);
        out.push('\n');
    }
    if std::fs::write(&tmp, out).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

/// shell-style match where * stands for any run of characters (both sides already lower case)
fn glob(p: &[u8], n: &[u8]) -> bool {
    let (mut pi, mut ni_, mut star, mut mark) = (0usize, 0usize, usize::MAX, 0usize);
    while ni_ < n.len() {
        if pi < p.len() && p[pi] == b'*' {
            star = pi;
            mark = ni_;
            pi += 1;
        } else if pi < p.len() && p[pi] == n[ni_] {
            pi += 1;
            ni_ += 1;
        } else if star != usize::MAX {
            pi = star + 1;
            mark += 1;
            ni_ = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == b'*' {
        pi += 1;
    }
    pi == p.len()
}

fn matches(patterns: &[String], names: &[&str]) -> bool {
    for n in names {
        let n = n.to_lowercase();
        if n.is_empty() {
            continue;
        }
        for p in patterns {
            if glob(p.to_lowercase().as_bytes(), n.as_bytes()) {
                return true;
            }
        }
    }
    false
}

// ------------------------------------------------------------------ Hyprland
fn clients() -> Vec<Value> {
    let out = util::run("hyprctl", &["-j", "clients"], 4);
    match serde_json::from_str::<Value>(&out) {
        Ok(Value::Array(a)) => a,
        _ => Vec::new(),
    }
}

fn close_window(addr: &str) {
    let arg = format!("hl.dsp.window.close({{ window = \"address:{}\" }})", addr);
    let out = util::run("hyprctl", &["dispatch", arg.as_str()], 4);
    if out.trim() != "ok" {
        // an older Hyprland without the Lua dispatchers
        let a = format!("address:{}", addr);
        util::run("hyprctl", &["dispatch", "closewindow", a.as_str()], 4);
    }
}

fn hypr_socket() -> Option<UnixStream> {
    let mut paths: Vec<String> = Vec::new();
    if let Ok(sig) = std::env::var("HYPRLAND_INSTANCE_SIGNATURE") {
        paths.push(format!("{}/hypr/{}/.socket2.sock", rt(), sig));
    }
    if let Ok(rd) = std::fs::read_dir(format!("{}/hypr", rt())) {
        let mut v: Vec<(std::time::SystemTime, String)> = rd
            .flatten()
            .filter_map(|d| {
                let p = d.path().join(".socket2.sock");
                let m = std::fs::metadata(&p).ok()?.modified().ok()?;
                Some((m, p.to_string_lossy().into_owned()))
            })
            .collect();
        v.sort_by(|a, b| b.0.cmp(&a.0));
        paths.extend(v.into_iter().map(|x| x.1));
    }
    for p in paths {
        if std::path::Path::new(&p).exists() {
            if let Ok(s) = UnixStream::connect(&p) {
                let _ = s.set_read_timeout(Some(Duration::from_secs(1)));
                return Some(s);
            }
        }
    }
    None
}

// ------------------------------------------------------------------ session state
fn alive(st: &Value) -> bool {
    let pid = ni(&st["pid"]);
    if pid == 0 {
        return util::epoch() - nf(&st["t0"]) < 8.0; // the helper is still starting
    }
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

fn live() -> Option<Value> {
    let st = read_json(&state_path())?;
    if truthy(&st["on"]) {
        if alive(&st) {
            return Some(st);
        }
        finish(&st, false, true); // the helper died: put everything back
    }
    None
}

/// A session that died with the machine (logout, crash): its Do not disturb / Caffeine are still on.
fn reap_stale() {
    if read_json(&state_path()).is_some() {
        return;
    }
    if let Some(m) = read_json(&marker_path()) {
        restore(&m);
        let _ = std::fs::remove_file(marker_path());
    }
}

fn restore(m: &Value) {
    if truthy(&m["caf"]) && !truthy(&m["prev_caf"]) {
        caffeine(&["off"]);
    }
    if truthy(&m["dnd"]) && !truthy(&m["prev_dnd"]) {
        island(&["dndset", "false"]);
    }
}

fn finish(st: &Value, completed: bool, quiet: bool) {
    restore(&json!({
        "dnd": st["dnd"], "prev_dnd": st["prev"]["dnd"],
        "caf": st["caf"], "prev_caf": st["prev"]["caf"],
    }));
    let _ = std::fs::remove_file(state_path());
    let _ = std::fs::remove_file(marker_path());
    if quiet {
        return;
    }
    if completed {
        chime();
        let done = if st.get("done_min").is_some() { ni(&st["done_min"]) } else { ni(&st["mins"]) };
        let closed = ni(&st["closed"]);
        let extra = if closed > 0 { format!(", {} apps kept out", closed) } else { String::new() };
        notify("Focus session complete", &format!("{} min focused{}. Do not disturb is off again.", done, extra), false, "emblem-ok-symbolic");
    } else {
        notify("Focus stopped", "Everything is back to normal.", false, "emblem-ok-symbolic");
    }
}

fn blocking_now(st: &Value, conf: &Conf) -> bool {
    if cget(conf, "BLOCK") == 0 || truthy(&st["paused"]) {
        return false;
    }
    st["phase"].as_str() == Some("work") || cget(conf, "BREAK_FREE") == 0
}

fn public(st: &Value) -> Value {
    let now = util::epoch();
    let paused = truthy(&st["paused"]);
    let left: i64 = if paused { ni(&st["left"]) } else { (nf(&st["end"]) - now).round().max(0.0) as i64 };
    json!({
        "on": true, "phase": st["phase"], "paused": paused, "left": left,
        "end": st["end"], "total": st["total"], "cycle": st["cycle"], "cycles": st["cycles"],
        "pomodoro": truthy(&st["pomodoro"]), "mins": st["mins"], "closed": ni(&st["closed"]),
        "blocking": blocking_now(st, &load_conf()),
    })
}

// ------------------------------------------------------------------ commands
fn cmd_start(args: &[String]) -> i32 {
    reap_stale();
    if live().is_some() {
        println!("already running");
        return 1;
    }
    let conf = load_conf();
    let mut mins = cget(&conf, "LENGTH");
    let mut pomo = cget(&conf, "POMODORO") != 0;
    for a in args {
        let a = a.to_lowercase();
        if !a.is_empty() && a.chars().all(|c| c.is_ascii_digit()) {
            mins = clean("LENGTH", &a, mins);
        } else if ["pomo", "pomodoro", "true", "on"].contains(&a.as_str()) {
            pomo = true;
        } else if ["single", "nopomo", "false", "off"].contains(&a.as_str()) {
            pomo = false;
        }
    }
    let prev_dnd = dnd_is_on();
    let prev_caf = caffeine(&["status"]) == "on";
    let now = util::epoch();
    let secs = (mins * 60) as f64;
    let dnd = cget(&conf, "DND") != 0;
    let caf = cget(&conf, "CAFFEINE") != 0;
    let cycles: i64 = if pomo { cget(&conf, "CYCLES") } else { 1 };
    let st = json!({
        "on": true, "phase": "work", "paused": false, "t0": now, "start": now, "end": now + secs,
        "left": mins * 60, "total": mins * 60, "cycle": 1, "cycles": cycles,
        "pomodoro": pomo, "mins": mins, "done_min": 0, "prev": { "dnd": prev_dnd, "caf": prev_caf }, "closed": 0,
        "dnd": dnd, "caf": caf,
    });
    write_json(&state_path(), &st);
    write_json(&marker_path(), &json!({ "dnd": dnd, "prev_dnd": prev_dnd, "caf": caf, "prev_caf": prev_caf }));
    if dnd {
        island(&["dndset", "true"]);
    }
    if caf && !prev_caf {
        caffeine(&["on"]);
    }
    start_daemon();
    0
}

fn start_daemon() {
    let svc = format!("{}.service", UNIT);
    util::run("systemctl", &["--user", "stop", svc.as_str()], 4);
    let exe = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| "hx".into());
    let mut args: Vec<String> = vec!["--user".into(), "--quiet".into(), "--collect".into(), format!("--unit={}", UNIT)];
    for k in ["HYPRLAND_INSTANCE_SIGNATURE", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "XDG_CURRENT_DESKTOP", "DISPLAY"] {
        if let Ok(v) = std::env::var(k) {
            args.push(format!("--setenv={}={}", k, v));
        }
    }
    args.push(exe.clone());
    args.push("focus".into());
    args.push("daemon".into());
    let ok = Command::new("systemd-run")
        .args(&args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if ok {
        return;
    }
    // no systemd user manager: run the helper on its own
    let mut c = Command::new(&exe);
    c.args(["focus", "daemon"]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    unsafe {
        c.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let _ = c.spawn();
}

fn cmd_stop() -> i32 {
    match read_json(&state_path()) {
        Some(mut st) if truthy(&st["on"]) => {
            let mut spent = nf(&st["done_min"]);
            if st["phase"].as_str() == Some("work") {
                let left = if truthy(&st["paused"]) { nf(&st["left"]) } else { (nf(&st["end"]) - util::epoch()).max(0.0) };
                spent += (nf(&st["total"]) - left).max(0.0) / 60.0;
            }
            st["done_min"] = json!(spent as i64);
            finish(&st, false, false);
        }
        _ => reap_stale(),
    }
    let svc = format!("{}.service", UNIT);
    util::run("systemctl", &["--user", "stop", svc.as_str()], 4);
    0
}

fn edit<F: FnOnce(&mut Value)>(f: F) -> i32 {
    match live() {
        None => {
            println!("no session");
            1
        }
        Some(mut st) => {
            f(&mut st);
            write_json(&state_path(), &st);
            0
        }
    }
}

fn cmd_pause() -> i32 {
    edit(|st| {
        if !truthy(&st["paused"]) {
            let left = ((nf(&st["end"]) - util::epoch()) as i64).max(1);
            st["left"] = json!(left);
            st["paused"] = json!(true);
        }
    })
}

fn cmd_resume() -> i32 {
    edit(|st| {
        if truthy(&st["paused"]) {
            st["end"] = json!(util::epoch() + nf(&st["left"]));
            st["paused"] = json!(false);
            st["sweep"] = json!(true); // apps opened during the pause get closed again
        }
    })
}

fn cmd_add(args: &[String]) -> i32 {
    let mins: i64 = args.first().and_then(|a| a.parse::<i64>().ok()).unwrap_or(5);
    edit(|st| {
        if truthy(&st["paused"]) {
            st["left"] = json!((ni(&st["left"]) + mins * 60).max(30));
        } else {
            st["end"] = json!((util::epoch() + 30.0).max(nf(&st["end"]) + (mins * 60) as f64));
        }
        st["total"] = json!((ni(&st["total"]) + mins * 60).max(60));
    })
}

fn cmd_skip() -> i32 {
    edit(|st| {
        st["end"] = json!(util::epoch());
        st["paused"] = json!(false);
    })
}

fn cmd_status() -> i32 {
    reap_stale();
    match live() {
        Some(st) => println!("{}", public(&st)),
        None => println!("{}", json!({ "on": false })),
    }
    0
}

fn cmd_conf() -> i32 {
    let mut m = Map::new();
    for (k, v) in load_conf() {
        m.insert(k.to_string(), if FLAGS.contains(&k) { Value::Bool(v != 0) } else { json!(v) });
    }
    m.insert("apps".into(), json!(blocked_list()));
    println!("{}", Value::Object(m));
    0
}

fn cmd_set(args: &[String]) -> i32 {
    let known = defaults();
    let key = args.first().and_then(|k| known.iter().find(|e| e.0 == k.as_str()).map(|e| e.0));
    match (key, args.get(1)) {
        (Some(k), Some(v)) => {
            let mut c = load_conf();
            let cur = cget(&c, k);
            cset(&mut c, k, clean(k, v, cur));
            save_conf(&c);
            0
        }
        _ => {
            println!("usage: focus.sh set KEY VALUE");
            2
        }
    }
}

fn cmd_apps() -> i32 {
    let blocked = blocked_list();
    let mut seen: HashSet<String> = HashSet::new();
    let mut opened: Vec<Value> = Vec::new();
    for c in clients() {
        let cls = c["class"].as_str().filter(|s| !s.is_empty()).or_else(|| c["initialClass"].as_str()).unwrap_or("");
        let low = cls.to_lowercase();
        if cls.is_empty() || seen.contains(&low) || low.contains("quickshell") || !class_ok(cls) {
            continue;
        }
        seen.insert(low);
        let title: String = c["title"].as_str().unwrap_or("").chars().take(60).collect();
        opened.push(json!({ "class": cls, "title": title, "blocked": matches(&blocked, &[cls]) }));
    }
    opened.sort_by_key(|x| x["class"].as_str().unwrap_or("").to_lowercase());
    println!("{}", json!({ "blocked": blocked, "open": opened }));
    0
}

fn cmd_block(args: &[String]) -> i32 {
    // one or more classes (Settings sends an app's class plus its program name in ONE call: the list is read-modify-written once)
    let good: Vec<&String> = args.iter().filter(|a| class_ok(a)).collect();
    if good.is_empty() {
        println!("not a window class");
        return 2;
    }
    let mut items = blocked_list();
    let mut changed = false;
    for a in good {
        if !items.iter().any(|x| x.eq_ignore_ascii_case(a)) {
            items.push(a.clone());
            changed = true;
        }
    }
    if changed {
        save_blocked(&items);
    }
    0
}

fn cmd_unblock(args: &[String]) -> i32 {
    match args.first() {
        None => 2,
        Some(a) => {
            let left: Vec<String> = blocked_list().into_iter().filter(|x| !x.eq_ignore_ascii_case(a)).collect();
            save_blocked(&left);
            0
        }
    }
}

// ------------------------------------------------------------------ the helper process
struct Blocker {
    last: HashMap<String, f64>,         // class -> when we last told you
    asked: HashMap<String, (u32, f64)>, // address -> (times asked to close, when)
    spare: HashSet<String>,             // windows that were already open when the block began (CLOSE_RUNNING = 0)
}

impl Blocker {
    fn new() -> Self {
        Blocker { last: HashMap::new(), asked: HashMap::new(), spare: HashSet::new() }
    }

    fn check(&mut self, st: &mut Value, addr: &str, cls: &str, init_cls: &str) -> bool {
        let patterns = blocked_list();
        if patterns.is_empty() || self.spare.contains(addr) || !matches(&patterns, &[cls, init_cls]) {
            return false;
        }
        let (n, t) = self.asked.get(addr).copied().unwrap_or((0, 0.0));
        if n >= 3 || util::epoch() - t < 4.0 {
            return true;
        }
        self.asked.insert(addr.to_string(), (n + 1, util::epoch()));
        close_window(addr);
        if n == 0 {
            st["closed"] = json!(ni(&st["closed"]) + 1);
            write_json(&state_path(), st);
            let key = cls.to_lowercase();
            let now = util::epoch();
            if now - self.last.get(&key).copied().unwrap_or(0.0) > 20.0 {
                self.last.insert(key, now);
                let mins = (((nf(&st["end"]) - now) / 60.0) as i64).max(1);
                notify("Focus", &format!("{} was closed. Focus ends in {} min.", cls, mins), false, "dialog-information");
            }
        }
        true
    }

    fn sweep(&mut self, st: &mut Value) {
        if blocked_list().is_empty() {
            return;
        }
        for c in clients() {
            if c["mapped"].as_bool().unwrap_or(true) {
                self.check(st, c["address"].as_str().unwrap_or(""), c["class"].as_str().unwrap_or(""), c["initialClass"].as_str().unwrap_or(""));
            }
        }
    }
}

/// The running phase is over: returns true when the whole session is over.
fn next_phase(st: &mut Value, conf: &Conf) -> bool {
    let now = util::epoch();
    let phase = st["phase"].as_str().unwrap_or("work").to_string();
    if phase == "work" {
        st["done_min"] = json!(ni(&st["done_min"]) + ni(&st["mins"]));
        if !truthy(&st["pomodoro"]) {
            return true;
        }
        let long = ni(&st["cycle"]) >= ni(&st["cycles"]);
        let mins = if long { cget(conf, "LONG_BREAK") } else { cget(conf, "BREAK") };
        st["phase"] = json!(if long { "long" } else { "break" });
        st["start"] = json!(now);
        st["end"] = json!(now + (mins * 60) as f64);
        st["total"] = json!(mins * 60);
        st["left"] = json!(mins * 60);
        chime();
        let body = format!("{} min off{}.", mins, if cget(conf, "BREAK_FREE") != 0 { "" } else { " (apps stay blocked)" });
        notify(if long { "Last round done" } else { "Break time" }, &body, true, "appointment-soon");
        return false;
    }
    if phase == "long" {
        return true;
    }
    let mins = ni(&st["mins"]);
    st["phase"] = json!("work");
    st["cycle"] = json!(ni(&st["cycle"]) + 1);
    st["start"] = json!(now);
    st["end"] = json!(now + (mins * 60) as f64);
    st["total"] = json!(mins * 60);
    st["left"] = json!(mins * 60);
    st["sweep"] = json!(true);
    chime();
    notify("Back to focus", &format!("Round {} of {}, {} min.", ni(&st["cycle"]), ni(&st["cycles"]), mins), true, "appointment-soon");
    false
}

extern "C" fn bye(_sig: libc::c_int) {
    // `hx focus stop` has already put everything back. At logout the island is gone too, so nothing is touched here:
    // the restore marker stays, and the next status / start (or the next login) puts Do not disturb / Caffeine back
    unsafe { libc::_exit(0) }
}

fn daemon() -> i32 {
    let mut st = match read_json(&state_path()) {
        Some(s) if truthy(&s["on"]) => s,
        _ => return 0,
    };
    let me = std::process::id() as i64;
    st["pid"] = json!(me);
    write_json(&state_path(), &st);
    unsafe {
        libc::signal(libc::SIGTERM, bye as extern "C" fn(libc::c_int) as libc::sighandler_t);
        libc::signal(libc::SIGINT, bye as extern "C" fn(libc::c_int) as libc::sighandler_t);
    }

    let mut blocker = Blocker::new();
    let mut sock = hypr_socket();
    let mut buf: Vec<u8> = Vec::new();
    let mut last_sweep = 0.0f64;
    let mut last_conf = 0.0f64;
    let mut conf = load_conf();
    let mut was_blocking = false;
    let mut chunk = [0u8; 8192];

    loop {
        let mut st = match read_json(&state_path()) {
            Some(s) if truthy(&s["on"]) => s,
            _ => return 0,
        };
        if ni(&st["pid"]) != me {
            return 0; // another helper took over
        }
        let now = util::epoch();
        if now - last_conf > 5.0 {
            conf = load_conf();
            last_conf = now;
        }
        if !truthy(&st["paused"]) && now >= nf(&st["end"]) {
            if next_phase(&mut st, &conf) {
                finish(&st, true, false);
                return 0;
            }
            write_json(&state_path(), &st);
        }
        let active = blocking_now(&st, &conf);
        if active {
            if !was_blocking && cget(&conf, "CLOSE_RUNNING") == 0 {
                blocker.spare = clients().iter().map(|c| c["address"].as_str().unwrap_or("").to_string()).collect();
            }
            if !was_blocking || truthy(&st["sweep"]) || now - last_sweep > 3.0 {
                // the 3 s sweep catches windows that name their class late
                blocker.sweep(&mut st);
                last_sweep = now;
                let had_sweep = st.as_object_mut().and_then(|o| o.remove("sweep")).map(|v| truthy(&v)).unwrap_or(false);
                if had_sweep {
                    write_json(&state_path(), &st);
                }
            }
        }
        was_blocking = active;

        let s = match sock.as_mut() {
            Some(s) => s,
            None => {
                std::thread::sleep(Duration::from_secs(1));
                if (now as u64) % 10 == 0 {
                    sock = hypr_socket();
                }
                continue;
            }
        };
        match s.read(&mut chunk) {
            Ok(0) => {
                sock = None;
                continue;
            }
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut | std::io::ErrorKind::Interrupted) => continue,
            Err(_) => {
                sock = None;
                continue;
            }
        }
        if buf.len() > (1 << 20) {
            buf.clear();
        }
        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = buf.drain(..=pos).collect();
            if !active || !line.starts_with(b"openwindow>>") {
                continue;
            }
            let text = String::from_utf8_lossy(&line["openwindow>>".len()..]).trim_end().to_string();
            let parts: Vec<&str> = text.splitn(4, ',').collect();
            if parts.len() >= 3 {
                blocker.check(&mut st, &format!("0x{}", parts[0]), parts[2], "");
            }
        }
    }
}

fn usage() {
    eprintln!(
        "hx focus start [MIN] [pomo] | stop | toggle | pause | resume | add MIN | skip | status | conf | apps\n\
         hx focus set KEY VALUE | block CLASS [CLASS...] | unblock CLASS | daemon | ping"
    );
}

pub fn run(args: &[String]) -> i32 {
    let rest: &[String] = if args.is_empty() { &[] } else { &args[1..] };
    match args.first().map(|s| s.as_str()) {
        None | Some("-h") | Some("--help") | Some("help") => {
            usage();
            0
        }
        Some("ping") => 0,
        Some("daemon") => daemon(),
        Some("start") => cmd_start(rest),
        Some("stop") => cmd_stop(),
        Some("toggle") => {
            if live().is_some() {
                cmd_stop()
            } else {
                cmd_start(rest)
            }
        }
        Some("pause") => cmd_pause(),
        Some("resume") => cmd_resume(),
        Some("add") => cmd_add(rest),
        Some("skip") => cmd_skip(),
        Some("status") => cmd_status(),
        Some("conf") => cmd_conf(),
        Some("set") => cmd_set(rest),
        Some("apps") => cmd_apps(),
        Some("block") => cmd_block(rest),
        Some("unblock") => cmd_unblock(rest),
        Some(other) => {
            println!("unknown command: {}", other);
            2
        }
    }
}
