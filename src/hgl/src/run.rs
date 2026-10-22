//! Running a game: command line, scope, Halcyon's gaming mode and priorities, supervision, restore, session report.
//!
//! Layers (see the plan): gamemode.sh on/off, the game in its own `systemd-run --user --scope` with a high CPU weight, Halcyon's own
//! units lowered while the game runs. Everything that was switched is written to a state file in /dev/shm first; a detached watchdog
//! (`hgl __watch`) restores it when the game is gone even if this process was killed.

use crate::epic;
use crate::proton;
use crate::steam;
use crate::store::{Conf, Game};
use crate::util::*;
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

pub const OUTPUT_MARK: &str = "=== game output ===\n";
/// Processes that make up Halcyon's shell while a game runs.
const HALCYON_COMMS: &[&str] = &["quickshell", "hx", "hal"];
const UNIT_HINTS: &[&str] = &["quickshell", "halcyon", "island"];
/// Linux USER_HZ: /proc tick counts are in 1/100 s on every architecture Linux supports.
const CLK_TCK: f64 = 100.0;

pub struct RunOpts {
    pub dry: bool,
    pub no_lean: bool,
    pub no_scope: bool,
}

// ------------------------------------------------------------------------------------------------ command line

pub struct Plan {
    pub argv: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<PathBuf>,
    /// scope unit name without the `.scope` suffix; empty when the game runs without a scope
    pub unit: String,
    pub notes: Vec<String>,
}

pub fn gamescope_args(preset: &str) -> Vec<String> {
    let w = |s: &[&str]| s.iter().map(|x| x.to_string()).collect::<Vec<_>>();
    match preset {
        "native" => w(&["-f"]),
        "1080p" => w(&["-W", "1920", "-H", "1080", "-f"]),
        "1440p" => w(&["-W", "2560", "-H", "1440", "-f"]),
        "fsr1080" => w(&["-w", "1280", "-h", "720", "-W", "1920", "-H", "1080", "-F", "fsr", "-f"]),
        "fsr1440" => w(&["-w", "1920", "-h", "1080", "-W", "2560", "-H", "1440", "-F", "fsr", "-f"]),
        raw => shell_split(raw),
    }
}

pub fn build_plan(g: &Game, cfg: &Conf, scope: bool) -> Result<Plan, String> {
    if g.exe.is_empty() {
        return Err(format!("{} has no .exe set (hgl set {} exe /path/to/game.exe)", g.name, g.id));
    }
    let exe = PathBuf::from(&g.exe);
    if !exe.is_file() {
        return Err(format!("the game file is gone: {}", g.exe));
    }
    if !have("umu-run") {
        return Err("umu-run is not installed (run: hgl doctor --fix)".into());
    }
    // Epic games start through legendary (it supplies the login parameters) with umu-run as its wrapper; GOG and plain games start umu-run directly
    let is_epic = g.source == "epic";
    if is_epic {
        if !have("legendary") {
            return Err("legendary is not installed (hgl doctor shows how)".into());
        }
        if g.appid.is_empty() {
            return Err(format!("{} has no Epic app name (run: hgl import epic)", g.name));
        }
    }
    let mut notes = Vec::new();
    let proton_path = match proton::resolve(&g.proton, cfg) {
        Some(r) => r.path.to_string_lossy().to_string(),
        None if !g.proton.is_empty() => return Err(format!("{} is pinned to {}, which is not installed (hgl proton install {})", g.name, g.proton, g.proton)),
        None => {
            notes.push("no Proton installed: umu will download its own GE-Proton (run: hgl proton install latest)".to_string());
            "GE-Proton".to_string()
        }
    };

    let prefix = g.prefix_path();
    let mut env: Vec<(String, String)> = vec![
        ("WINEPREFIX".into(), prefix.to_string_lossy().to_string()),
        ("PROTONPATH".into(), proton_path),
        ("GAMEID".into(), if g.umu_id.is_empty() { "0".into() } else { g.umu_id.clone() }),
    ];
    // umu looks a game up by store + id; with no id it still runs the game, just without the per-game fixes
    if !g.umu_id.is_empty() {
        match g.source.as_str() {
            "epic" => env.push(("STORE".into(), "egs".into())),
            "gog" => env.push(("STORE".into(), "gog".into())),
            _ => {}
        }
    }
    if is_epic {
        if let Some(kv) = epic::config_env(cfg) {
            env.push(kv);
        }
    }
    if g.wayland {
        env.push(("PROTON_ENABLE_WAYLAND".into(), "1".into()));
    }
    if g.debug {
        env.push(("PROTON_LOG".into(), "1".into()));
        env.push(("PROTON_LOG_DIR".into(), logs_dir().join(&g.id).to_string_lossy().to_string()));
    }
    for (k, v) in &g.env {
        env.retain(|(ek, _)| ek != k);
        env.push((k.clone(), v.clone()));
    }

    let mut argv: Vec<String> = Vec::new();
    let mut unit = String::new();
    if scope {
        unit = format!("hgl-{}-{}", g.id, std::process::id());
        let weight = cfg.num("game_weight", 800).clamp(1, 10000);
        for a in ["systemd-run", "--user", "--scope", "--quiet", "--unit"] {
            argv.push(a.into());
        }
        argv.push(unit.clone());
        argv.push("-p".into());
        argv.push(format!("CPUWeight={weight}"));
        argv.push("--".into());
    }
    let mango = g.wrapper_on("mangohud") && have("mangohud");
    // what goes in front of umu-run (for Epic: inside legendary's --wrapper)
    let mut wrap: Vec<String> = Vec::new();
    if !g.gamescope.is_empty() {
        if have("gamescope") {
            argv.push("gamescope".into());
            argv.extend(gamescope_args(&g.gamescope));
            if mango {
                argv.push("--mangoapp".into());
            }
            argv.push("--".into());
        } else {
            notes.push("gamescope is not installed: starting without it".into());
        }
    } else if mango {
        wrap.push("mangohud".into());
    }
    if g.wrapper_on("gamemode") {
        if have("gamemoderun") {
            wrap.push("gamemoderun".into());
        } else {
            notes.push("gamemoderun is not installed: starting without it".into());
        }
    }
    if is_epic {
        wrap.push("umu-run".into());
        let wrapper = wrap.iter().map(|a| quote(a)).collect::<Vec<String>>().join(" ");
        for a in ["legendary", "launch"] {
            argv.push(a.into());
        }
        argv.push(g.appid.clone());
        for a in ["--no-wine", "--wrapper"] {
            argv.push(a.into());
        }
        argv.push(wrapper);
    } else {
        argv.extend(wrap);
        argv.push("umu-run".into());
        argv.push(g.exe.clone());
    }
    argv.extend(shell_split(&g.args));

    Ok(Plan { argv, env, cwd: exe.parent().map(|p| p.to_path_buf()), unit, notes })
}

fn quote(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "/._-=:+,@%".contains(c)) {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

pub fn print_plan(p: &Plan) {
    if let Some(c) = &p.cwd {
        println!("cwd: {}", c.display());
    }
    let envs: Vec<String> = p.env.iter().map(|(k, v)| format!("{k}={}", quote(v))).collect();
    println!("env: {}", envs.join(" "));
    let cmd: Vec<String> = p.argv.iter().map(|a| quote(a)).collect();
    println!("cmd: {}", cmd.join(" "));
    for n in &p.notes {
        println!("note: {n}");
    }
}

// ------------------------------------------------------------------------------------------------ session state

#[derive(Default, Clone, Debug)]
pub struct Session {
    pub pid: u32,
    pub id: String,
    pub name: String,
    pub unit: String,
    pub appid: String,
    pub started: u64,
    pub gm: bool,
    pub throttled: Vec<String>,
    pub affinity: Vec<(u32, String)>,
    pub log: String,
}

fn state_path() -> PathBuf {
    PathBuf::from(format!("/dev/shm/halcyon-hgl-{}", uid()))
}

fn safe_unit(s: &str) -> bool {
    !s.is_empty() && s.len() < 200 && s.chars().all(|c| c.is_ascii_alphanumeric() || "@:._-".contains(c))
}

impl Session {
    fn serialize(&self) -> String {
        let aff: Vec<String> = self.affinity.iter().map(|(p, l)| format!("{p}:{l}")).collect();
        format!(
            "pid={}\nid={}\nname={}\nunit={}\nappid={}\nstarted={}\ngm={}\nthrottled={}\naffinity={}\nlog={}\n",
            self.pid,
            self.id,
            self.name.replace('\n', " "),
            self.unit,
            self.appid,
            self.started,
            self.gm as u8,
            self.throttled.join(" "),
            aff.join(";"),
            self.log.replace('\n', " ")
        )
    }

    /// The file lives in a directory every local user can write to: values are validated, never trusted.
    pub fn parse(text: &str) -> Session {
        let mut s = Session::default();
        for (k, v) in parse_kv(text) {
            match k.as_str() {
                "pid" => s.pid = v.parse().unwrap_or(0),
                "id" => {
                    if valid_id(&v) {
                        s.id = v
                    }
                }
                "name" => s.name = v,
                "unit" => {
                    if safe_unit(&v) {
                        s.unit = v
                    }
                }
                "appid" => {
                    if v.chars().all(|c| c.is_ascii_digit()) {
                        s.appid = v
                    }
                }
                "started" => s.started = v.parse().unwrap_or(0),
                "gm" => s.gm = v == "1",
                "throttled" => s.throttled = v.split_whitespace().filter(|u| safe_unit(u)).map(|u| u.to_string()).collect(),
                "affinity" => {
                    for e in v.split(';') {
                        if let Some((p, l)) = e.split_once(':') {
                            if let Ok(pid) = p.parse::<u32>() {
                                if !l.is_empty() && l.chars().all(|c| c.is_ascii_digit() || c == ',' || c == '-') {
                                    s.affinity.push((pid, l.to_string()));
                                }
                            }
                        }
                    }
                }
                "log" => s.log = v,
                _ => {}
            }
        }
        s
    }

    fn save(&self) {
        let _ = atomic_write(&state_path(), &self.serialize());
    }
}

fn state_safe() -> bool {
    match fs::symlink_metadata(state_path()) {
        Ok(m) => m.is_file() && m.uid() == uid(),
        Err(_) => false,
    }
}

pub fn read_state() -> Option<Session> {
    if !state_safe() {
        return None;
    }
    let t = fs::read_to_string(state_path()).ok()?;
    Some(Session::parse(&t))
}

/// Whoever renames the file first owns the restore (supervisor and watchdog can race).
fn take_state() -> Option<Session> {
    if !state_safe() {
        return None;
    }
    let mine = PathBuf::from(format!("{}.take.{}", state_path().display(), std::process::id()));
    fs::rename(state_path(), &mine).ok()?;
    let t = fs::read_to_string(&mine).ok();
    let _ = fs::remove_file(&mine);
    t.map(|t| Session::parse(&t))
}

fn claim(first: &Session) -> Result<(), String> {
    let p = state_path();
    let mut f = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&p).map_err(|e| {
        if e.kind() == std::io::ErrorKind::AlreadyExists {
            match read_state() {
                Some(s) if !s.name.is_empty() => format!("{} is already running (hgl stop {})", s.name, s.id),
                Some(_) => "a game session is already active".to_string(),
                None => format!("{} exists and is not yours: remove it as root", p.display()),
            }
        } else {
            format!("cannot create {}: {e}", p.display())
        }
    })?;
    f.write_all(first.serialize().as_bytes()).map_err(|e| e.to_string())
}

fn supervisor_alive(s: &Session) -> bool {
    s.pid != 0 && pid_alive(s.pid) && fs::read_to_string(format!("/proc/{}/comm", s.pid)).map(|c| c.trim() == "hgl").unwrap_or(false)
}

fn game_alive(s: &Session) -> bool {
    if !s.unit.is_empty() {
        run_quiet("systemctl", &["--user", "is-active", "--quiet", &format!("{}.scope", s.unit)], 5)
    } else if !s.appid.is_empty() {
        !steam::game_pids(&s.appid).is_empty()
    } else {
        false
    }
}

// ------------------------------------------------------------------------------------------------ Halcyon: gaming mode, priorities

fn gm_script() -> Option<PathBuf> {
    let p = gamemode_script();
    if p.is_file() {
        Some(p)
    } else {
        None
    }
}

/// Tell the island (Quickshell IPC, target `island`) what is going on: the "now playing" pill and the lean island. Silent and harmless
/// when the shell is not running (or is an older Halcyon without these calls).
fn island_call(func: &str, args: &[&str]) {
    if !have("quickshell") {
        return;
    }
    let dir = config_dir().join("quickshell").join("island");
    let dir = dir.to_string_lossy().to_string();
    let mut a: Vec<&str> = vec!["ipc", "-p", &dir, "call", "island", func];
    a.extend_from_slice(args);
    run_quiet("quickshell", &a, 5);
}

fn gm_on_now(script: &Path) -> bool {
    out("bash", &[&script.to_string_lossy(), "status"]).map(|s| s.trim() == "on").unwrap_or(false)
}

fn cgroup_unit(pid: u32) -> Option<String> {
    let t = fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()?;
    let line = t.lines().find(|l| l.starts_with("0::"))?;
    let last = line.trim_start_matches("0::").rsplit('/').next()?.to_string();
    if (last.ends_with(".service") || last.ends_with(".scope")) && safe_unit(&last) {
        Some(last)
    } else {
        None
    }
}

/// Only units that are clearly Halcyon's shell: never a session scope or the compositor's unit, which would slow the whole desktop.
fn unit_is_halcyon(unit: &str) -> bool {
    let l = unit.to_ascii_lowercase();
    !l.starts_with("session-") && !l.contains("hyprland") && UNIT_HINTS.iter().any(|h| l.contains(h))
}

fn halcyon_pids() -> Vec<u32> {
    processes().into_iter().filter(|(_, c)| HALCYON_COMMS.contains(&c.as_str())).map(|(p, _)| p).collect()
}

/// Lower the CPU weight of the units Halcyon's shell runs in (only units that are clearly Halcyon's: never the whole session).
fn throttle_halcyon(cfg: &Conf, s: &mut Session) {
    if !cfg.flag("halcyon_throttle", true) {
        return;
    }
    let weight = cfg.num("halcyon_weight", 20).clamp(1, 10000);
    let mut units: Vec<String> = Vec::new();
    for pid in halcyon_pids() {
        if let Some(u) = cgroup_unit(pid) {
            if unit_is_halcyon(&u) && !units.contains(&u) {
                units.push(u);
            }
        }
    }
    for u in units {
        if run_quiet("systemctl", &["--user", "set-property", "--runtime", &u, &format!("CPUWeight={weight}")], 8) {
            s.throttled.push(u);
        }
    }
    // opt-in: confine Halcyon's processes to one core
    if let Some(core) = cfg.get("halcyon_core") {
        if core.chars().all(|c| c.is_ascii_digit()) && have("taskset") {
            for pid in halcyon_pids() {
                let st = fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
                let cur = st.lines().find_map(|l| l.strip_prefix("Cpus_allowed_list:")).map(|v| v.trim().to_string()).unwrap_or_default();
                if !cur.is_empty() && run_quiet("taskset", &["-acp", core, &pid.to_string()], 5) {
                    s.affinity.push((pid, cur));
                }
            }
        }
    }
}

/// Put everything back. `stop_scope` is true when the game has ended and its leftovers (wineserver) should go with it.
pub fn restore(s: &Session, stop_scope: bool) {
    if stop_scope && !s.unit.is_empty() {
        run_quiet("systemctl", &["--user", "stop", &format!("{}.scope", s.unit)], 12);
    }
    for u in &s.throttled {
        // an empty value resets the property to the unit's own default
        run_quiet("systemctl", &["--user", "set-property", "--runtime", u, "CPUWeight="], 8);
    }
    for (pid, list) in &s.affinity {
        let comm = fs::read_to_string(format!("/proc/{pid}/comm")).unwrap_or_default();
        if HALCYON_COMMS.contains(&comm.trim()) {
            run_quiet("taskset", &["-acp", list, &pid.to_string()], 5);
        }
    }
    if s.gm {
        if let Some(sc) = gm_script() {
            run_quiet("bash", &[&sc.to_string_lossy(), "off"], 40);
        }
    }
    island_call("gameend", &[]);
}

// ------------------------------------------------------------------------------------------------ sampling Halcyon's own cost

#[derive(Default)]
pub struct Sampler {
    last: HashMap<u32, u64>,
    last_at: Option<Instant>,
    ticks: u64,
    span: f64,
    rss_sum_kb: u64,
    rss_peak_kb: u64,
    n: u64,
}

fn proc_ticks(pid: u32) -> Option<u64> {
    let t = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let rest = &t[t.rfind(')')? + 2..];
    let f: Vec<&str> = rest.split_whitespace().collect();
    // after the command name: state is f[0]; utime and stime are f[11] and f[12]
    Some(f.get(11)?.parse::<u64>().ok()? + f.get(12)?.parse::<u64>().ok()?)
}

fn proc_rss_kb(pid: u32) -> Option<u64> {
    let t = fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    t.lines().find_map(|l| l.strip_prefix("VmRSS:")).and_then(|v| v.split_whitespace().next()).and_then(|v| v.parse().ok())
}

impl Sampler {
    pub fn sample(&mut self) {
        let now = Instant::now();
        let mut rss = 0;
        let mut seen = HashMap::new();
        for pid in halcyon_pids() {
            if let Some(t) = proc_ticks(pid) {
                if let Some(prev) = self.last.get(&pid) {
                    self.ticks += t.saturating_sub(*prev);
                }
                seen.insert(pid, t);
            }
            rss += proc_rss_kb(pid).unwrap_or(0);
        }
        if let Some(at) = self.last_at {
            self.span += now.duration_since(at).as_secs_f64();
        }
        self.last = seen;
        self.last_at = Some(now);
        self.rss_sum_kb += rss;
        self.rss_peak_kb = self.rss_peak_kb.max(rss);
        self.n += 1;
    }
    pub fn avg_cpu_pct(&self) -> f64 {
        if self.span < 1.0 {
            0.0
        } else {
            self.ticks as f64 / CLK_TCK / self.span * 100.0
        }
    }
    pub fn avg_ram_mb(&self) -> f64 {
        if self.n == 0 {
            0.0
        } else {
            self.rss_sum_kb as f64 / self.n as f64 / 1024.0
        }
    }
    pub fn peak_ram_mb(&self) -> f64 {
        self.rss_peak_kb as f64 / 1024.0
    }
}

// ------------------------------------------------------------------------------------------------ logs

fn open_log(g: &Game, plan: Option<&Plan>) -> Result<(fs::File, PathBuf), String> {
    let dir = logs_dir().join(&g.id);
    fs::create_dir_all(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let path = dir.join(format!("{}.log", now()));
    let mut f = fs::File::create(&path).map_err(|e| format!("cannot create {}: {e}", path.display()))?;
    let mut head = format!("hgl {} — {} ({})\n", env!("CARGO_PKG_VERSION"), g.name, g.id);
    if let Some(p) = plan {
        if let Some(c) = &p.cwd {
            head.push_str(&format!("cwd: {}\n", c.display()));
        }
        for (k, v) in &p.env {
            head.push_str(&format!("env: {k}={v}\n"));
        }
        let cmd: Vec<String> = p.argv.iter().map(|a| quote(a)).collect();
        head.push_str(&format!("cmd: {}\n", cmd.join(" ")));
    }
    head.push_str(OUTPUT_MARK);
    let _ = f.write_all(head.as_bytes());
    // keep the newest 8 logs per game
    if let Ok(rd) = fs::read_dir(&dir) {
        let mut logs: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.extension().map(|x| x == "log").unwrap_or(false)).collect();
        logs.sort();
        while logs.len() > 8 {
            let old = logs.remove(0);
            let _ = fs::remove_file(old);
        }
    }
    Ok((f, path))
}

// ------------------------------------------------------------------------------------------------ run

pub fn run(id: &str, o: &RunOpts) -> Result<i32, String> {
    recover_stale();
    let g = Game::load(id)?;
    let cfg = Conf::load();
    let is_steam = g.source == "steam";

    let plan = if is_steam {
        if g.appid.is_empty() {
            return Err("this Steam entry has no appid (run: hgl import steam)".into());
        }
        if !have("steam") {
            return Err("steam is not installed".into());
        }
        None
    } else {
        let scope = !o.no_scope && have("systemd-run") && run_quiet("systemd-run", &["--user", "--scope", "--quiet", "-p", "CPUWeight=100", "true"], 8);
        let mut p = build_plan(&g, &cfg, scope)?;
        if !o.no_scope && !scope {
            p.notes.push("systemd user scopes are not available: starting without a scope".into());
        }
        Some(p)
    };

    if o.dry {
        match &plan {
            Some(p) => print_plan(p),
            None => println!("cmd: steam -silent steam://rungameid/{}", g.appid),
        }
        return Ok(0);
    }

    if let Some(p) = &plan {
        fs::create_dir_all(g.prefix_path()).map_err(|e| format!("cannot create the prefix folder: {e}"))?;
        for n in &p.notes {
            eprintln!("note: {n}");
        }
    }
    let (logfile, logpath) = open_log(&g, plan.as_ref())?;

    let started = now();
    let mut s = Session {
        pid: std::process::id(),
        id: g.id.clone(),
        name: g.name.clone(),
        unit: plan.as_ref().map(|p| p.unit.clone()).unwrap_or_default(),
        appid: if is_steam { g.appid.clone() } else { String::new() },
        started,
        log: logpath.to_string_lossy().to_string(),
        ..Session::default()
    };
    claim(&s)?;

    // layer 1: Halcyon's gaming mode (only when it was not already on, so a mode the user switched on stays on)
    let lean = g.lean && !o.no_lean;
    if lean {
        if let Some(sc) = gm_script() {
            if !gm_on_now(&sc) && run_quiet("bash", &[&sc.to_string_lossy(), "on"], 40) {
                s.gm = true;
            }
        }
        // layer 3: lower Halcyon's own units
        throttle_halcyon(&cfg, &mut s);
    }
    s.save();
    spawn_watchdog(s.pid, s.started);

    let since = started.to_string();
    island_call("gamestart", &[g.id.as_str(), g.name.as_str(), since.as_str(), if lean { "true" } else { "false" }]);

    println!("Launching {} ...\nlog: {}", g.name, logpath.display());
    let t0 = Instant::now();
    let mut sampler = Sampler::default();
    sampler.sample();

    let code: Option<i32> = if let Some(p) = &plan {
        match spawn_game(p, logfile) {
            Ok(child) => supervise_child(child, &mut sampler),
            Err(e) => {
                if let Some(taken) = take_state() {
                    restore(&taken, true);
                }
                return Err(format!("could not start the game: {e}"));
            }
        }
    } else {
        supervise_steam(&g, &mut sampler)
    };
    sampler.sample();

    let secs = t0.elapsed().as_secs();
    // game over: clear leftovers and put everything back
    if let Some(taken) = take_state() {
        restore(&taken, true);
    }
    finish(&g, secs, code, &sampler, s.gm, is_steam);
    Ok(0)
}

fn spawn_game(p: &Plan, log: fs::File) -> Result<Child, String> {
    let err = log.try_clone().map_err(|e| e.to_string())?;
    let mut cmd = Command::new(&p.argv[0]);
    cmd.args(&p.argv[1..]).envs(p.env.iter().map(|(k, v)| (k.as_str(), v.as_str())));
    if let Some(c) = &p.cwd {
        cmd.current_dir(c);
    }
    // own process group: closing the terminal or Ctrl-C on hgl does not take the game down; the watchdog restores afterwards
    cmd.stdin(Stdio::null()).stdout(Stdio::from(log)).stderr(Stdio::from(err)).process_group(0);
    cmd.spawn().map_err(|e| format!("{}: {e}", p.argv[0]))
}

fn supervise_child(mut child: Child, sampler: &mut Sampler) -> Option<i32> {
    let mut last = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(st)) => return Some(st.code().unwrap_or_else(|| 128 + st.signal().unwrap_or(0))),
            Ok(None) => {}
            Err(_) => return None,
        }
        if last.elapsed() >= Duration::from_secs(5) {
            sampler.sample();
            last = Instant::now();
        }
        sleep(Duration::from_millis(500));
    }
}

fn supervise_steam(g: &Game, sampler: &mut Sampler) -> Option<i32> {
    // hand the launch to Steam, headless; the Steam client keeps running after the game (cloud saves, DRM)
    let spawned = Command::new("steam")
        .args(["-silent", &format!("steam://rungameid/{}", g.appid)])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn();
    if let Err(e) = spawned {
        eprintln!("could not start steam: {e}");
        return None;
    }
    let t0 = Instant::now();
    let mut last = Instant::now();
    // wait for the game's processes to show up
    loop {
        if !steam::game_pids(&g.appid).is_empty() {
            break;
        }
        if t0.elapsed() > Duration::from_secs(180) {
            eprintln!("Steam did not start {} within 3 minutes (a dialog may be waiting in Steam: update, login, EULA).", g.name);
            return None;
        }
        sleep(Duration::from_secs(2));
    }
    // then until they are gone for 10 seconds (launchers hand over to the real game in between)
    let mut gone = 0;
    while gone < 5 {
        sleep(Duration::from_secs(2));
        if steam::game_pids(&g.appid).is_empty() {
            gone += 1;
        } else {
            gone = 0;
        }
        if last.elapsed() >= Duration::from_secs(6) {
            sampler.sample();
            last = Instant::now();
        }
    }
    None
}

fn finish(g: &Game, secs: u64, code: Option<i32>, sm: &Sampler, gm_by_us: bool, is_steam: bool) {
    // reload: settings may have been edited while the game ran
    if let Ok(mut fresh) = Game::load(&g.id) {
        fresh.last_played = now();
        fresh.playtime += secs;
        fresh.last_exit = code;
        fresh.last_run_secs = secs;
        let _ = fresh.save();
    }
    let crashed = looks_crashed(code, secs);
    println!("\nSession over: {}", g.name);
    println!("  Played: {}", fmt_duration(secs));
    println!(
        "  Halcyon while you played: CPU {:.1}% of one core on average, RAM {:.0} MB average (peak {:.0} MB)",
        sm.avg_cpu_pct(),
        sm.avg_ram_mb(),
        sm.peak_ram_mb()
    );
    println!("  Gaming mode: {}", if gm_by_us { "on during the session, restored" } else { "left as it was" });
    if crashed {
        println!("  The game exited with code {} after {}s. Run: hgl triage {}", code.unwrap_or(-1), secs, g.id);
    }
    let _ = is_steam;
    let json = format!(
        "{{\"id\":{},\"name\":{},\"playedSecs\":{secs},\"exit\":{},\"crashed\":{crashed},\"haCpuAvg\":{:.2},\"haRamAvgMB\":{:.1},\"haRamPeakMB\":{:.1},\"samples\":{},\"gamemodeByHgl\":{gm_by_us},\"ended\":{}}}",
        json_str(&g.id),
        json_str(&g.name),
        code.map(|c| c.to_string()).unwrap_or_else(|| "null".into()),
        sm.avg_cpu_pct(),
        sm.avg_ram_mb(),
        sm.peak_ram_mb(),
        sm.n,
        now()
    );
    let _ = atomic_write(&state_dir().join("last-session.json"), &format!("{json}\n"));
    let line = format!("{}\t{}\t{}s\texit={}\tha_cpu={:.2}%\tha_ram={:.0}MB\n", now(), g.id, secs, code.map(|c| c.to_string()).unwrap_or_else(|| "-".into()), sm.avg_cpu_pct(), sm.avg_ram_mb());
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(state_dir().join("sessions.log")) {
        let _ = f.write_all(line.as_bytes());
    }
}

/// A non-zero exit soon after the start. Exit codes from a deliberate stop (SIGINT / SIGKILL / SIGTERM) do not count, and a long
/// session never counts: Wine often returns odd codes on a normal quit.
pub fn looks_crashed(code: Option<i32>, secs: u64) -> bool {
    match code {
        Some(c) => c != 0 && !matches!(c, 130 | 137 | 143) && secs < 90,
        None => false,
    }
}

// ------------------------------------------------------------------------------------------------ watchdog, recover, stop, status

fn spawn_watchdog(pid: u32, started: u64) {
    if let Ok(exe) = std::env::current_exe() {
        let _ = Command::new(exe).args(["__watch", &pid.to_string(), &started.to_string()]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).process_group(0).spawn();
    }
}

/// `hgl __watch <pid> <started>`: detached, tied to ONE session. Ends when that session's state file is gone (normal end) or has been
/// replaced by another session's; restores after the supervisor died and the game is over.
pub fn watch(pid: u32, started: u64) {
    loop {
        sleep(Duration::from_secs(3));
        let Some(s) = read_state() else { return };
        if s.pid != pid || s.started != started {
            return;
        }
        if !supervisor_alive(&s) && !game_alive(&s) {
            if let Some(taken) = take_state() {
                restore(&taken, true);
            }
            return;
        }
    }
}

/// If a session file is left over from a crashed hgl and its game is gone, restore now. Returns true when something was restored.
pub fn recover_stale() -> bool {
    let Some(s) = read_state() else { return false };
    if supervisor_alive(&s) || game_alive(&s) {
        return false;
    }
    if let Some(taken) = take_state() {
        restore(&taken, true);
        eprintln!("Restored Halcyon after an earlier session ({}) that did not finish cleanly.", taken.name);
        return true;
    }
    false
}

pub fn stop(id: Option<&str>) -> Result<(), String> {
    let s = read_state().ok_or("no game is running")?;
    if let Some(want) = id {
        if want != s.id {
            return Err(format!("{want} is not running ({} is)", s.name));
        }
    }
    if !s.unit.is_empty() {
        if !run_quiet("systemctl", &["--user", "stop", &format!("{}.scope", s.unit)], 15) {
            return Err("could not stop the game's scope".into());
        }
        return Ok(());
    }
    if !s.appid.is_empty() {
        let pids = steam::game_pids(&s.appid);
        if pids.is_empty() {
            return Err("the game has no running processes".into());
        }
        let strs: Vec<String> = pids.iter().map(|p| p.to_string()).collect();
        let mut args: Vec<&str> = vec!["-TERM"];
        args.extend(strs.iter().map(|x| x.as_str()));
        run_quiet("kill", &args, 5);
        return Ok(());
    }
    Err("nothing to stop".into())
}

pub fn status_json() -> String {
    match read_state() {
        Some(s) if supervisor_alive(&s) => format!(
            "{{\"running\":true,\"id\":{},\"name\":{},\"since\":{},\"unit\":{},\"lean\":{},\"log\":{}}}",
            json_str(&s.id),
            json_str(&s.name),
            s.started,
            json_str(&s.unit),
            s.gm || !s.throttled.is_empty(),
            json_str(&s.log)
        ),
        _ => "{\"running\":false}".to_string(),
    }
}

pub fn running_id() -> Option<String> {
    read_state().filter(supervisor_alive).map(|s| s.id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_roundtrip_and_validation() {
        let s = Session {
            pid: 42,
            id: "hades".into(),
            name: "Hades".into(),
            unit: "hgl-hades-42".into(),
            appid: String::new(),
            started: 7,
            gm: true,
            throttled: vec!["app-quickshell.service".into()],
            affinity: vec![(10, "0-15".into()), (11, "0,2".into())],
            log: "/x/1.log".into(),
        };
        let t = Session::parse(&s.serialize());
        assert_eq!(t.id, "hades");
        assert_eq!(t.unit, "hgl-hades-42");
        assert!(t.gm);
        assert_eq!(t.throttled, vec!["app-quickshell.service"]);
        assert_eq!(t.affinity, vec![(10, "0-15".to_string()), (11, "0,2".to_string())]);
    }

    #[test]
    fn hostile_state_is_filtered() {
        let t = Session::parse("pid=1\nid=../../etc\nunit=a b;rm -rf\nthrottled=ok.service evil;x\naffinity=5:0-3;6:$(x)\nappid=12a\n");
        assert_eq!(t.id, "");
        assert_eq!(t.unit, "");
        assert_eq!(t.throttled, vec!["ok.service"]);
        assert_eq!(t.affinity, vec![(5, "0-3".to_string())]);
        assert_eq!(t.appid, "");
    }

    #[test]
    fn crash_heuristic() {
        assert!(looks_crashed(Some(1), 5));
        assert!(!looks_crashed(Some(0), 5));
        assert!(!looks_crashed(Some(143), 5));
        assert!(!looks_crashed(Some(1), 3600));
        assert!(!looks_crashed(None, 1));
    }

    #[test]
    fn only_halcyon_units_are_throttled() {
        assert!(unit_is_halcyon("app-quickshell@autostart.service"));
        assert!(unit_is_halcyon("halcyon-island.service"));
        assert!(!unit_is_halcyon("session-2.scope"));
        assert!(!unit_is_halcyon("app-hyprland-quickshell.scope"));
        assert!(!unit_is_halcyon("firefox.service"));
    }

    #[test]
    fn gamescope_presets() {
        assert_eq!(gamescope_args("1080p"), vec!["-W", "1920", "-H", "1080", "-f"]);
        assert_eq!(gamescope_args("-W 800 -H 600"), vec!["-W", "800", "-H", "600"]);
    }

    #[test]
    fn quoting() {
        assert_eq!(quote("a/b-c"), "a/b-c");
        assert_eq!(quote("a b"), "'a b'");
        assert_eq!(quote("it's"), "'it'\\''s'");
    }
}
