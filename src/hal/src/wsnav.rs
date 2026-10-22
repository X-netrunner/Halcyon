//! hal wsnav: port of scripts/ws-nav.sh. Same behaviour, same state files (~/.local/state/island/):
//!
//!   ws-end    new | wrap | stay   what "next" does on the last workspace   (default new)
//!   ws-start  wrap | stay         what "previous" does on the first one   (default wrap)
//!   ws-swipe4 left | right        which 4-finger swipe means "next"       (default left); ignores ws-invert
//!   ws-invert 0 | 1               reverse the direction of swipes and the wheel
//!   ws-max    2..10               highest workspace number "next" may create (default 9)
//!
//! The shell version started `hyprctl` three times plus awk and sort; this one starts it three times and nothing else.

use crate::util;
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::PathBuf;

fn flag(name: &str) -> String {
    util::first_line(&util::state_dir().join(name)).unwrap_or_default()
}

/// tail -f ~/.cache/island/ws-nav.log while you swipe: no line = Hyprland never fired the gesture
fn trace(dir: &str) {
    let cache = PathBuf::from(util::home()).join(".cache/island");
    let _ = fs::create_dir_all(&cache);
    let log = cache.join("ws-nav.log");
    let stamp = util::out("date", &["+%T"]);
    let line = format!("{} {}\n", stamp.trim(), dir);
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&log) {
        let _ = f.write_all(line.as_bytes());
    }
    if let Ok(text) = fs::read_to_string(&log) {
        let lines: Vec<&str> = text.lines().collect();
        if lines.len() > 200 {
            let keep = lines[lines.len() - 50..].join("\n") + "\n";
            let tmp = cache.join("ws-nav.log.t");
            if fs::write(&tmp, keep).is_ok() {
                let _ = fs::rename(&tmp, &log);
            }
        }
    }
}

/// Every normal workspace that exists right now as (id, windows), lowest id first.
/// Reads the text output of `hyprctl workspaces`; special workspaces have negative ids and are left out.
fn parse_workspaces(text: &str) -> Vec<(i64, i64)> {
    let mut list: Vec<(i64, i64)> = Vec::new();
    let mut cur_id: i64 = 0;
    for line in text.lines() {
        if line.starts_with("workspace ID") {
            cur_id = line.split_whitespace().nth(2).and_then(|x| x.parse::<i64>().ok()).unwrap_or(0);
        } else if line.trim_start().starts_with("windows:") {
            if cur_id > 0 {
                let n = line.split_whitespace().nth(1).and_then(|x| x.parse::<i64>().ok()).unwrap_or(0);
                list.push((cur_id, n));
            }
            cur_id = 0;
        }
    }
    list.sort();
    list
}

/// Which workspace to go to. `ids` is sorted, lowest first, and never empty. None = stay where you are.
fn decide(ids: &[i64], wins: &HashMap<i64, i64>, cur: i64, go_prev: bool, end: &str, start: &str, max: i64) -> Option<i64> {
    let first = ids[0];
    let last = ids[ids.len() - 1];
    let mut target: Option<i64> = None;

    if go_prev {
        // the highest one below this one
        for &id in ids {
            if id < cur {
                target = Some(id);
            }
        }
        if target.is_none() && start == "wrap" && last != cur {
            target = Some(last);
        }
    } else {
        // the lowest one above this one
        target = ids.iter().copied().find(|&id| id > cur);
        if target.is_none() {
            match end {
                "new" => {
                    // a new workspace only after one that has something on it, and never past the limit
                    let w = wins.get(&cur).copied().unwrap_or(0);
                    if w > 0 && cur < max {
                        target = Some(cur + 1);
                    } else if cur >= max && first != cur {
                        target = Some(first);
                    }
                }
                "wrap"
                    if first != cur => {
                        target = Some(first);
                    }
                _ => {}
            }
        }
    }

    match target {
        Some(t) if t != cur => Some(t),
        _ => None,
    }
}

pub fn run(args: &[String]) -> i32 {
    let mut dir: String = args.first().cloned().unwrap_or_else(|| "next".to_string());
    if dir.starts_with("gesture") {
        trace(&dir);
    }

    // swipes and the wheel honour the "invert" option; plain next / prev (keybinds) never change
    let mut inv = flag("ws-invert");
    let swipe4_right = flag("ws-swipe4") == "right";
    let requested = dir.clone();
    match requested.as_str() {
        "gesture-right" => dir = String::from("next"),
        "gesture-left" => dir = String::from("prev"),
        "gesture4-left" => {
            dir = String::from(if swipe4_right { "prev" } else { "next" });
            inv = String::from("0");
        }
        "gesture4-right" => {
            dir = String::from(if swipe4_right { "next" } else { "prev" });
            inv = String::from("0");
        }
        "wheel-down" => dir = String::from("next"),
        "wheel-up" => dir = String::from("prev"),
        _ => inv = String::from("0"),
    }
    if inv == "1" {
        dir = if dir == "next" { String::from("prev") } else { String::from("next") };
    }

    let end_raw = flag("ws-end");
    let end: &str = match end_raw.as_str() {
        "new" => "new",
        "wrap" => "wrap",
        "stay" => "stay",
        _ => "new",
    };
    let start_raw = flag("ws-start");
    let start: &str = match start_raw.as_str() {
        "wrap" => "wrap",
        "stay" => "stay",
        _ => "wrap",
    };
    let max_raw = flag("ws-max");
    let mut max: i64 = if !max_raw.is_empty() && max_raw.chars().all(|c| c.is_ascii_digit()) {
        max_raw.parse::<i64>().unwrap_or(9)
    } else {
        9
    };
    if max < 2 {
        max = 2;
    }
    if max > 10 {
        max = 10;
    }

    let list = parse_workspaces(&util::out("hyprctl", &["workspaces"]));
    let mut wins: HashMap<i64, i64> = HashMap::new();
    let mut ids: Vec<i64> = Vec::new();
    for (id, n) in &list {
        ids.push(*id);
        wins.insert(*id, *n);
    }
    if ids.is_empty() {
        ids.push(1);
    }

    let active = util::out("hyprctl", &["activeworkspace"]);
    let mut cur: i64 = active
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(2))
        .and_then(|x| x.parse::<i64>().ok())
        .unwrap_or(ids[0]);
    if cur <= 0 {
        cur = ids[0];
    }

    if let Some(target) = decide(&ids, &wins, cur, dir == "prev", end, start, max) {
        let arg = format!("hl.dsp.focus({{ workspace = {} }})", target);
        util::ok("hyprctl", &["dispatch", arg.as_str()]);
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wins(pairs: &[(i64, i64)]) -> HashMap<i64, i64> {
        pairs.iter().copied().collect()
    }

    #[test]
    fn parses_hyprctl_text_and_skips_special_workspaces() {
        let text = "workspace ID 1 (1) on monitor eDP-1:\n\tmonitorID: 0\n\twindows: 2\n\thasfullscreen: 0\n\n\
                    workspace ID -98 (special:special) on monitor eDP-1:\n\tmonitorID: 0\n\twindows: 1\n\n\
                    workspace ID 3 (3) on monitor eDP-1:\n\twindows: 0\n";
        assert_eq!(parse_workspaces(text), vec![(1, 2), (3, 0)]);
    }

    #[test]
    fn next_skips_to_the_next_existing_workspace() {
        let ids = [1, 3, 4];
        let w = wins(&[(1, 1), (3, 1), (4, 0)]);
        assert_eq!(decide(&ids, &w, 1, false, "new", "wrap", 9), Some(3));
        assert_eq!(decide(&ids, &w, 3, false, "new", "wrap", 9), Some(4));
    }

    #[test]
    fn next_on_the_last_one_opens_a_new_one_only_when_it_has_windows() {
        let ids = [1, 2];
        assert_eq!(decide(&ids, &wins(&[(1, 1), (2, 1)]), 2, false, "new", "wrap", 9), Some(3));
        assert_eq!(decide(&ids, &wins(&[(1, 1), (2, 0)]), 2, false, "new", "wrap", 9), None);
    }

    #[test]
    fn next_at_the_limit_wraps_to_the_first() {
        let ids = [1, 9];
        assert_eq!(decide(&ids, &wins(&[(1, 1), (9, 1)]), 9, false, "new", "wrap", 9), Some(1));
    }

    #[test]
    fn end_wrap_and_stay() {
        let ids = [1, 2];
        let w = wins(&[(1, 1), (2, 1)]);
        assert_eq!(decide(&ids, &w, 2, false, "wrap", "wrap", 9), Some(1));
        assert_eq!(decide(&ids, &w, 2, false, "stay", "wrap", 9), None);
    }

    #[test]
    fn prev_goes_down_and_wraps_to_the_last_from_the_first() {
        let ids = [1, 2, 3];
        let w = wins(&[(1, 1), (2, 1), (3, 1)]);
        assert_eq!(decide(&ids, &w, 3, true, "new", "wrap", 9), Some(2));
        assert_eq!(decide(&ids, &w, 1, true, "new", "wrap", 9), Some(3));
        assert_eq!(decide(&ids, &w, 1, true, "new", "stay", 9), None);
    }

    #[test]
    fn single_workspace_never_moves() {
        let ids = [1];
        let w = wins(&[(1, 0)]);
        assert_eq!(decide(&ids, &w, 1, true, "new", "wrap", 9), None);
        assert_eq!(decide(&ids, &w, 1, false, "new", "wrap", 9), None);
    }
}
