//! hal input: port of scripts/input-conf.sh (Settings > Touchpad gestures / Mouse buttons).
//!
//!   hal input conf                  one line of JSON: every gesture, every mouse button, and the mice that are connected
//!   hal input mice                  JSON list of the connected mice (touchpads and virtual devices left out)
//!   hal input set ID ACTION [CMD]   assign an action (CMD is the command for the actions "app" and "cmd")
//!   hal input reset [gestures|mouse|all]
//!   hal input run ID                what a gesture / button does (called by Hyprland: hyprland/gestures.lua, hyprland/mouse.lua)
//!
//! IDs:  g3-left g3-right g3-up g3-down g3-pinchin g3-pinchout   (3 fingers; g4-... is the same with 4 fingers)
//!       m274 (middle) m275 (back) m276 (forward) m277 m278 m279 (more buttons, gaming mice)
//!
//! The choices live in ~/.local/state/island/gestures.conf, one `id=action` line each (and `id.cmd=...` for a command).
//! An id that is not in the file has its default (default_of below). hyprland/inputconf.lua reads the same file and
//! has the same defaults, and so does touchpad-gestures: keep the three in step.

use crate::{util, wsnav};
use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

const FINGER_COUNTS: [&str; 2] = ["3", "4"];
const DIRS: [&str; 6] = ["left", "right", "up", "down", "pinchin", "pinchout"];
const MOUSE_IDS: [&str; 6] = ["m274", "m275", "m276", "m277", "m278", "m279"];

fn gesture_ids() -> Vec<String> {
    let mut v: Vec<String> = Vec::new();
    for f in FINGER_COUNTS.iter() {
        for d in DIRS.iter() {
            v.push(format!("g{}-{}", f, d));
        }
    }
    v
}

fn mouse_ids() -> Vec<String> {
    MOUSE_IDS.iter().map(|s| s.to_string()).collect()
}

fn conf_path() -> PathBuf {
    util::state_dir().join("gestures.conf")
}

/// What an id does until Settings changes it (the way Halcyon always behaved: 4 fingers = workspaces,
/// 3 fingers up / down = scratch, pinch = tree view ...).
fn default_of(id: &str) -> &'static str {
    let right4 = util::first_line(&util::state_dir().join("ws-swipe4")).map_or(false, |s| s == "right");
    match id {
        "g3-up" | "g3-down" => "scratch",
        "g3-pinchin" | "g3-pinchout" => "overview",
        "g4-left" => {
            if right4 {
                "ws-prev"
            } else {
                "ws-next"
            }
        }
        "g4-right" => {
            if right4 {
                "ws-next"
            } else {
                "ws-prev"
            }
        }
        "g4-down" => "sleep",
        _ => "none",
    }
}

struct Conf {
    /// every id, gestures first and then the mouse buttons (the order they are saved and printed in)
    ids: Vec<String>,
    act: HashMap<String, String>,
    cmd: HashMap<String, String>,
}

fn all_ids() -> Vec<String> {
    let mut ids = gesture_ids();
    ids.extend(mouse_ids());
    ids
}

/// Applies the lines of a gestures.conf on top of the defaults already in `act` / `cmd`. Unknown ids are ignored.
fn apply_conf(raw: &str, act: &mut HashMap<String, String>, cmd: &mut HashMap<String, String>) {
    for line in raw.lines() {
        if let Some(pos) = line.find('=') {
            let k = &line[..pos];
            let v = &line[pos + 1..];
            if let Some(id) = k.strip_suffix(".cmd") {
                if let Some(slot) = cmd.get_mut(id) {
                    *slot = v.to_string();
                }
            } else if let Some(slot) = act.get_mut(k) {
                *slot = v.to_string();
            }
        }
    }
}

fn load() -> Conf {
    let ids = all_ids();
    let mut act: HashMap<String, String> = HashMap::new();
    let mut cmd: HashMap<String, String> = HashMap::new();
    for id in &ids {
        act.insert(id.clone(), default_of(id).to_string());
        cmd.insert(id.clone(), String::new());
    }
    if let Ok(raw) = fs::read_to_string(conf_path()) {
        apply_conf(&raw, &mut act, &mut cmd);
    }
    Conf { ids, act, cmd }
}

fn save(c: &Conf) -> bool {
    let dir = util::state_dir();
    if fs::create_dir_all(&dir).is_err() {
        return false;
    }
    let mut out = String::new();
    for id in &c.ids {
        out.push_str(&format!("{}={}\n", id, c.act[id]));
        let cmd = &c.cmd[id];
        if !cmd.is_empty() {
            out.push_str(&format!("{}.cmd={}\n", id, cmd));
        }
    }
    // write next to the real file and rename: a half-written gestures.conf can never be read
    let tmp = dir.join(format!(".gestures.{}", std::process::id()));
    if fs::write(&tmp, out).is_err() {
        return false;
    }
    fs::rename(&tmp, conf_path()).is_ok()
}

fn valid_id(c: &Conf, id: &str) -> bool {
    c.act.contains_key(id)
}

// ---- JSON by hand: ids and actions are plain [a-z0-9-], only a command or a device name needs escaping
fn jesc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for ch in s.chars() {
        match ch {
            '\\' => o.push_str("\\\\"),
            '"' => o.push_str("\\\""),
            '\t' => o.push_str("\\t"),
            '\r' => {}
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o
}

/// Names the mice section of `hyprctl devices -j` lists, still JSON-escaped (they are cut out of Hyprland's own JSON).
fn mice_names(json: &str) -> BTreeSet<String> {
    let mut names: BTreeSet<String> = BTreeSet::new();
    let mut in_mice = false;
    for line in json.lines() {
        if let Some(i) = line.find("\"mice\":") {
            let rest = line[i + "\"mice\":".len()..].trim_start();
            if rest.starts_with('[') {
                // `"mice": [],` on one line is an empty list: nothing to read, and the section is already closed
                in_mice = !rest.contains(']');
                continue;
            }
        }
        if !in_mice {
            continue;
        }
        let t = line.trim();
        if t == "]" || t == "]," {
            in_mice = false;
            continue;
        }
        if let Some(j) = line.find("\"name\":") {
            let rest = line[j + "\"name\":".len()..].trim_start();
            if let Some(r) = rest.strip_prefix('"') {
                let r = r.trim_end();
                let r = r.strip_suffix(',').unwrap_or(r);
                let r = r.strip_suffix('"').unwrap_or(r);
                names.insert(r.to_string());
            }
        }
    }
    names
}

/// What Hyprland calls a mouse includes the touchpad and a few virtual devices; those are not mice.
fn is_real_mouse(name: &str) -> bool {
    let n = name.to_lowercase();
    let skip = [
        "touchpad",
        "trackpad",
        "synaptics",
        "glidepoint",
        "virtual",
        "ydotool",
        "uinput",
        "keyboard",
        "kbd",
        "power-button",
        "video-bus",
        "stylus",
    ];
    if skip.iter().any(|s| n.contains(*s)) {
        return false;
    }
    !n.ends_with("pen")
}

fn mice_json() -> String {
    let json = util::out("timeout", &["2", "hyprctl", "devices", "-j"]);
    let list: Vec<String> = mice_names(&json)
        .into_iter()
        .filter(|n| is_real_mouse(n))
        .map(|n| format!("\"{}\"", n))
        .collect();
    format!("[{}]", list.join(","))
}

fn print_conf() {
    let c = load();
    let part = |ids: &[String]| -> String {
        ids.iter()
            .map(|id| format!("\"{}\":{{\"a\":\"{}\",\"c\":\"{}\"}}", id, jesc(&c.act[id]), jesc(&c.cmd[id])))
            .collect::<Vec<String>>()
            .join(",")
    };
    let g = part(&gesture_ids());
    let m = part(&mouse_ids());
    println!("{{\"gestures\":{{{}}},\"mouse\":{{{}}},\"mice\":{}}}", g, m, mice_json());
}

fn cmd_set(args: &[String]) -> i32 {
    let id = args.get(0).map(|s| s.as_str()).unwrap_or("");
    let act = args.get(1).map(|s| s.as_str()).unwrap_or("");
    let cmd = args.get(2).map(|s| s.replace('\n', " ")).unwrap_or_default();
    let mut c = load();
    if !valid_id(&c, id) {
        eprintln!("unknown id: {}", id);
        return 2;
    }
    if act.is_empty() || !act.chars().all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '-') {
        eprintln!("bad action: {}", act);
        return 2;
    }
    c.act.insert(id.to_string(), act.to_string());
    let keep_cmd = act == "app" || act == "cmd";
    c.cmd.insert(id.to_string(), if keep_cmd { cmd } else { String::new() });
    if save(&c) {
        0
    } else {
        1
    }
}

fn cmd_reset(args: &[String]) -> i32 {
    let what = args.get(0).map(|s| s.as_str()).unwrap_or("all");
    let mut c = load();
    if what == "gestures" || what == "all" {
        for id in gesture_ids() {
            c.act.insert(id.clone(), default_of(&id).to_string());
            c.cmd.insert(id, String::new());
        }
    }
    if what == "mouse" || what == "all" {
        for id in mouse_ids() {
            c.act.insert(id.clone(), String::from("none"));
            c.cmd.insert(id, String::new());
        }
    }
    if save(&c) {
        0
    } else {
        1
    }
}

// ---- what an action does

fn ipc(h: &str, name: &str) {
    let island = format!("{}/quickshell/island", h);
    util::ok("quickshell", &["ipc", "-p", island.as_str(), "call", "island", name]);
}

fn hd(arg: &str) {
    util::ok("hyprctl", &["dispatch", arg]);
}

/// Replaces this process with the command (like the shell's `exec`). Only returns when it could not start.
fn exec(cmd: &str, args: &[&str]) -> i32 {
    let err = Command::new(cmd).args(args).exec();
    eprintln!("hal: cannot run {}: {}", cmd, err);
    127
}

fn spawn_detached(cmd: &str) {
    let _ = Command::new("setsid")
        .args(["sh", "-c", cmd])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

fn do_action(action: &str, cmd: &str) -> i32 {
    let h = util::rice_dir().to_string_lossy().to_string();
    let script = |name: &str| format!("{}/scripts/{}", h, name);
    match action {
        "" | "none" => 0,
        "ws-next" => wsnav::run(&[String::from("next")]),
        "ws-prev" => wsnav::run(&[String::from("prev")]),
        "scratch" => {
            hd("hl.dsp.workspace.toggle_special(\"special\")");
            0
        }
        "sysmon" => {
            hd("hl.dsp.workspace.toggle_special(\"sysmon\")");
            0
        }
        "todo" => {
            // was the Todoist workspace; now the Halcyon calendar
            ipc(&h, "calendar");
            0
        }
        "music" => exec(&script("special.sh"), &["music"]),
        "comm" => exec(&script("special.sh"), &["communication"]),
        "overview" | "launcher" | "settings" | "cheatsheet" | "notifcenter" | "quickterm" | "lock" | "dnd" | "clearnotifs" | "gaming"
        | "caffeine" | "focus" => {
            ipc(&h, action);
            0
        }
        "sleep" => exec("systemctl", &["suspend"]),
        "fullscreen" => {
            hd("hl.dsp.window.fullscreen()");
            0
        }
        "float" => {
            hd("hl.dsp.window.float()");
            0
        }
        "pin" => {
            hd("hl.dsp.window.pin()");
            0
        }
        "close" => exec(&script("close.sh"), &[]),
        "focus-left" => {
            hd("hl.dsp.focus({ direction = \"left\" })");
            0
        }
        "focus-right" => {
            hd("hl.dsp.focus({ direction = \"right\" })");
            0
        }
        "screenshot" => exec(&script("screenshot-area.sh"), &[]),
        "playpause" => exec("playerctl", &["play-pause"]),
        "nexttrack" => exec("playerctl", &["next"]),
        "prevtrack" => exec("playerctl", &["previous"]),
        "volup" => exec("wpctl", &["set-volume", "-l", "1", "@DEFAULT_AUDIO_SINK@", "5%+"]),
        "voldown" => exec("wpctl", &["set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"]),
        "mute" => exec("wpctl", &["set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"]),
        "brightup" => exec("brightnessctl", &["set", "10%+"]),
        "brightdown" => exec("brightnessctl", &["set", "10%-"]),
        "terminal" | "browser" | "files" | "editor" => exec(&script("apps.sh"), &["run", action]),
        "app" | "cmd" => {
            if !cmd.is_empty() {
                spawn_detached(cmd);
            }
            0
        }
        _ => 0,
    }
}

fn cmd_run(args: &[String]) -> i32 {
    let id = args.get(0).map(|s| s.as_str()).unwrap_or("");
    let c = load();
    if !valid_id(&c, id) {
        return 2;
    }
    // tail -f ~/.cache/island/gesture-run.log while you gesture: no line = Hyprland never fired it (the live tracker may still have)
    if id.starts_with('g') {
        util::trace("gesture-run.log", &format!("{} -> {}", id, c.act[id]));
    }
    do_action(&c.act[id], &c.cmd[id])
}

fn usage() {
    eprintln!(
        "hal input conf | mice | set ID ACTION [CMD] | reset [gestures|mouse|all] | run ID\n\
         IDs: g3-left g3-right g3-up g3-down g3-pinchin g3-pinchout (g4-... the same with 4 fingers), m274 .. m279"
    );
}

pub fn run(args: &[String]) -> i32 {
    let rest: &[String] = if args.is_empty() { &[] } else { &args[1..] };
    match args.get(0).map(|s| s.as_str()).unwrap_or("conf") {
        "conf" => {
            print_conf();
            0
        }
        "mice" => {
            println!("{}", mice_json());
            0
        }
        "set" => cmd_set(rest),
        "reset" => cmd_reset(rest),
        "run" => cmd_run(rest),
        _ => {
            usage();
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn defaults() -> (HashMap<String, String>, HashMap<String, String>) {
        let mut act = HashMap::new();
        let mut cmd = HashMap::new();
        for id in all_ids() {
            act.insert(id.clone(), String::from("none"));
            cmd.insert(id, String::new());
        }
        (act, cmd)
    }

    #[test]
    fn there_are_12_gestures_and_6_buttons_in_the_saved_order() {
        let ids = all_ids();
        assert_eq!(ids.len(), 18);
        assert_eq!(ids[0], "g3-left");
        assert_eq!(ids[5], "g3-pinchout");
        assert_eq!(ids[6], "g4-left");
        assert_eq!(ids[12], "m274");
    }

    #[test]
    fn conf_lines_override_defaults_and_unknown_ids_are_ignored() {
        let (mut act, mut cmd) = defaults();
        apply_conf("g3-up=app\ng3-up.cmd=firefox --private-window\nbogus=x\nm275=playpause\n", &mut act, &mut cmd);
        assert_eq!(act["g3-up"], "app");
        assert_eq!(cmd["g3-up"], "firefox --private-window");
        assert_eq!(act["m275"], "playpause");
        assert!(!act.contains_key("bogus"));
    }

    #[test]
    fn a_command_may_contain_equals_signs() {
        let (mut act, mut cmd) = defaults();
        apply_conf("g3-down=cmd\ng3-down.cmd=env A=1 B=2 foo\n", &mut act, &mut cmd);
        assert_eq!(cmd["g3-down"], "env A=1 B=2 foo");
    }

    #[test]
    fn json_escaping() {
        assert_eq!(jesc("a\"b\\c\td"), "a\\\"b\\\\c\\td");
        assert_eq!(jesc("x\r\ny"), "x\\u000ay");
    }

    #[test]
    fn mice_come_from_the_mice_section_only() {
        let json = "{\n  \"mice\": [\n    {\n      \"address\": \"0x1\",\n      \"name\": \"logitech-g502\",\n      \"defaultSpeed\": 0.0\n    },\n    {\n      \"name\": \"asup1207:00-093a:3017-touchpad\"\n    }\n  ],\n  \"keyboards\": [\n    {\n      \"name\": \"at-translated-set-2-keyboard\"\n    }\n  ]\n}\n";
        let names = mice_names(json);
        assert_eq!(names.len(), 2);
        assert!(names.contains("logitech-g502"));
        assert!(names.contains("asup1207:00-093a:3017-touchpad"));
        assert!(is_real_mouse("logitech-g502"));
        assert!(!is_real_mouse("asup1207:00-093a:3017-touchpad"));
        assert!(!is_real_mouse("wacom-intuos-pen"));
        assert!(!is_real_mouse("Virtual Mouse"));
    }

    #[test]
    fn an_empty_mice_list_does_not_leak_the_keyboards_in() {
        let json = "{\n  \"mice\": [],\n  \"keyboards\": [\n    {\n      \"name\": \"some-keyboard\"\n    }\n  ]\n}\n";
        assert!(mice_names(json).is_empty());
    }
}
