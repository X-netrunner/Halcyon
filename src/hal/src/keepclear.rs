//! hal keep-clear : keeps floating windows (Picture-in-Picture, pop-ups, "No tiling" windows) out of the screen border and the bar.
//!
//! Tiled windows already stop at the border and the bar (they reserve room with layer-shell zones), but a floating window can be
//! dragged anywhere, over both. This watcher moves such a window back into the free area of its monitor (the monitor's
//! `reserved` edges = the border + the bar). It runs from the Hyprland event socket, so it costs nothing while nothing floats:
//!   - a window that opens, changes mode or moves is checked once;
//!   - while the focused window is floating (that is what a drag looks like) it checks every 150 ms, and moves the window only
//!     once it has STOPPED moving (the drag ended), so it never fights the pointer; Hyprland animates the move back.
//! Fullscreen windows and tiled windows are left alone. `~/.local/state/island/keep-clear` containing 0 switches it off.
//!   hal keep-clear          run the watcher (started by hyprland/execs.lua through scripts/keep-clear.sh; one copy only)

use crate::json::{self, Json};
use crate::util;
use std::io::Read;
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

struct Mon {
    id: f64,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
}

struct Win {
    addr: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    mon: f64,
}

fn enabled() -> bool {
    util::first_line(&util::state_dir().join("keep-clear")).as_deref() != Some("0")
}

fn pair(j: &Json, key: &str) -> Option<(f64, f64)> {
    match j.get(key)? {
        Json::Arr(v) if v.len() >= 2 => match (&v[0], &v[1]) {
            (Json::Num(a), Json::Num(b)) => Some((*a, *b)),
            _ => None,
        },
        _ => None,
    }
}

/// The free area of every monitor, in layout coordinates: the monitor minus its reserved edges (border + bar).
fn monitors() -> Vec<Mon> {
    let mut v = Vec::new();
    if let Some(Json::Arr(items)) = json::parse(&util::out("hyprctl", &["monitors", "-j"])) {
        for m in items {
            let (Some(id), Some(x), Some(y), Some(w), Some(h)) = (m.num("id"), m.num("x"), m.num("y"), m.num("width"), m.num("height")) else { continue };
            let scale = m.num("scale").filter(|s| *s > 0.0).unwrap_or(1.0);
            let turned = matches!(m.num("transform"), Some(t) if (t as i64) % 2 == 1);
            let (w, h) = if turned { (h, w) } else { (w, h) };
            let r = match m.get("reserved") {
                Some(Json::Arr(a)) if a.len() >= 4 => {
                    let n = |i: usize| if let Json::Num(x) = &a[i] { *x } else { 0.0 };
                    (n(0), n(1), n(2), n(3)) // left, top, right, bottom
                }
                _ => (0.0, 0.0, 0.0, 0.0),
            };
            v.push(Mon { id, x0: x + r.0, y0: y + r.1, x1: x + w / scale - r.2, y1: y + h / scale - r.3 });
        }
    }
    v
}

fn to_win(c: &Json) -> Option<Win> {
    if c.get("floating") != Some(&Json::Bool(true)) || c.get("mapped") == Some(&Json::Bool(false)) {
        return None;
    }
    if c.num("fullscreen").unwrap_or(0.0) > 0.0 || c.get("fullscreen") == Some(&Json::Bool(true)) {
        return None;
    }
    let (x, y) = pair(c, "at")?;
    let (w, h) = pair(c, "size")?;
    Some(Win { addr: c.str("address")?.to_string(), x, y, w, h, mon: c.num("monitor")? })
}

fn clamp(v: f64, lo: f64, hi: f64) -> f64 {
    if hi < lo { lo } else { v.max(lo).min(hi) }
}

/// Where the window has to be so that it lies inside the free area (None = it already does).
fn target(w: &Win, mons: &[Mon]) -> Option<(i64, i64)> {
    let m = mons.iter().find(|m| m.id == w.mon)?;
    let nx = clamp(w.x, m.x0, m.x1 - w.w);
    let ny = clamp(w.y, m.y0, m.y1 - w.h);
    if (nx - w.x).abs() < 1.5 && (ny - w.y).abs() < 1.5 {
        return None;
    }
    Some((nx.round() as i64, ny.round() as i64))
}

fn move_to(addr: &str, x: i64, y: i64, lua: &mut bool) {
    if *lua {
        let arg = format!("hl.dsp.window.move({{ x = {}, y = {}, window = \"address:{}\" }})", x, y, addr);
        if util::out("hyprctl", &["dispatch", &arg]).trim() == "ok" {
            return;
        }
        *lua = false; // an older Hyprland without the Lua dispatchers
    }
    let arg = format!("exact {} {},address:{}", x, y, addr);
    let _ = util::ok("hyprctl", &["dispatch", "movewindowpixel", &arg]);
}

fn all_floating() -> Vec<Win> {
    match json::parse(&util::out("hyprctl", &["clients", "-j"])) {
        Some(Json::Arr(items)) => items.iter().filter_map(to_win).collect(),
        _ => Vec::new(),
    }
}

fn active_floating() -> Option<Win> {
    to_win(&json::parse(&util::out("hyprctl", &["activewindow", "-j"]))?)
}

fn socket2() -> Option<UnixStream> {
    let rt = std::env::var("XDG_RUNTIME_DIR").ok()?;
    let sig = std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?;
    UnixStream::connect(format!("{}/hypr/{}/.socket2.sock", rt, sig)).ok()
}

/// One copy only: true when another watcher is already running.
fn already_running() -> bool {
    let rt = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    let pidf = format!("{}/halcyon-keep-clear.pid", rt);
    if let Ok(s) = std::fs::read_to_string(&pidf) {
        if let Ok(p) = s.trim().parse::<u32>() {
            if p != std::process::id() {
                if let Ok(cmd) = std::fs::read(format!("/proc/{}/cmdline", p)) {
                    if String::from_utf8_lossy(&cmd).contains("keep-clear") {
                        return true;
                    }
                }
            }
        }
    }
    let _ = std::fs::write(&pidf, std::process::id().to_string());
    false
}

pub fn run() -> i32 {
    if already_running() {
        return 0;
    }
    let Some(mut sock) = socket2() else { return 1 };
    let mut lua = true;
    let mut mons: Vec<Mon> = Vec::new();
    let mut last: Option<(String, i64, i64)> = None; // the focused floating window and where it was at the last check
    let mut drag = false; // the focused window floats: poll quickly
    let mut dirty = true;
    let mut buf = [0u8; 4096];
    loop {
        let wait = if drag { Duration::from_millis(150) } else { Duration::from_secs(30) };
        let _ = sock.set_read_timeout(Some(wait));
        match sock.read(&mut buf) {
            Ok(0) => return 0, // Hyprland ended
            Ok(n) => {
                let ev = String::from_utf8_lossy(&buf[..n]);
                if ev.lines().any(|l| {
                    ["openwindow>>", "movewindow", "changefloatingmode>>", "fullscreen>>", "activewindowv2>>", "monitoradded", "monitorremoved", "configreloaded", "workspace"]
                        .iter()
                        .any(|k| l.starts_with(k))
                }) {
                    dirty = true;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => {}
            Err(_) => return 0,
        }
        if !enabled() {
            drag = false;
            continue;
        }
        let t0 = Instant::now();
        // the focused window: a drag is a floating window that keeps changing place; fix it once it rests
        let act = active_floating();
        drag = act.is_some();
        if let Some(w) = &act {
            let now = (w.addr.clone(), w.x.round() as i64, w.y.round() as i64);
            let still = last.as_ref() == Some(&now);
            last = Some(now);
            if still {
                if mons.is_empty() || dirty {
                    mons = monitors();
                }
                if let Some((x, y)) = target(w, &mons) {
                    move_to(&w.addr, x, y, &mut lua);
                    last = None;
                }
            }
        } else {
            last = None;
        }
        if dirty {
            dirty = false;
            mons = monitors();
            for w in all_floating() {
                if act.as_ref().map(|a| a.addr == w.addr).unwrap_or(false) {
                    continue; // the focused one is handled above, once it rests
                }
                if let Some((x, y)) = target(&w, &mons) {
                    move_to(&w.addr, x, y, &mut lua);
                }
            }
        }
        // never spin: a tick (and its hyprctl calls) took long, give the compositor some air
        if t0.elapsed() > Duration::from_millis(120) {
            std::thread::sleep(Duration::from_millis(100));
        }
    }
}
