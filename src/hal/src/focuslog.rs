//! hal focus-log add MINUTES | json
//!
//! The Focus streak's memory: how many minutes you focused on each day, kept in ~/.local/state/island/focus-days.json
//! (the last 400 days). Replaces the python3 here-document that scripts/focus-log.sh used to carry.
//!   add MINUTES   add minutes (0 to 600) to today; the island calls this once a minute while a work phase runs
//!   json          print { "2026-10-16": 42, ... }

use crate::json::{self, Json};
use crate::util;
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::path::PathBuf;

const KEEP_DAYS: usize = 400;

fn store_path() -> PathBuf {
    let base = match env::var("XDG_STATE_HOME") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => PathBuf::from(util::home()).join(".local/state"),
    };
    base.join("island").join("focus-days.json")
}

/// The saved days. A damaged file, or one that is not a JSON object, counts as empty; entries that are not numbers are skipped.
fn load(text: &str) -> BTreeMap<String, i64> {
    let mut days = BTreeMap::new();
    if let Some(Json::Obj(members)) = json::parse(text) {
        for (k, v) in members {
            if let Json::Num(n) = v {
                days.insert(k, n as i64);
            }
        }
    }
    days
}

/// Only the newest KEEP_DAYS days (the keys sort as dates).
fn keep_last(days: BTreeMap<String, i64>) -> BTreeMap<String, i64> {
    let skip = days.len().saturating_sub(KEEP_DAYS);
    days.into_iter().skip(skip).collect()
}

fn esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o
}

fn render(days: &BTreeMap<String, i64>) -> String {
    let body: Vec<String> = days
        .iter()
        .map(|(k, v)| format!("\"{}\":{}", esc(k), v))
        .collect();
    format!("{{{}}}", body.join(","))
}

pub fn run(args: &[String]) -> i32 {
    let path = store_path();
    let text = fs::read_to_string(&path).unwrap_or_default();
    let mut days = load(&text);
    match args.first().map(|s| s.as_str()) {
        Some("add") => {
            let minutes = args
                .get(1)
                .and_then(|s| s.trim().parse::<i64>().ok())
                .unwrap_or(0)
                .clamp(0, 600);
            let today = util::out("date", &["+%F"]).trim().to_string();
            if today.is_empty() {
                return 1;
            }
            let before = days.get(&today).copied().unwrap_or(0);
            days.insert(today, before + minutes);
            let days = keep_last(days);
            if let Some(dir) = path.parent() {
                let _ = fs::create_dir_all(dir);
            }
            let tmp = path.with_extension("json.tmp");
            if fs::write(&tmp, render(&days)).is_err() || fs::rename(&tmp, &path).is_err() {
                return 1;
            }
            0
        }
        _ => {
            println!("{}", render(&keep_last(days)));
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn load_skips_junk() {
        let d = load(r#"{"2026-10-01": 30, "x": "no", "2026-10-02": 5.9}"#);
        assert_eq!(d.get("2026-10-01"), Some(&30));
        assert_eq!(d.get("x"), None);
        assert_eq!(d.get("2026-10-02"), Some(&5));
        assert!(load("not json").is_empty());
        assert!(load("[1,2]").is_empty());
    }

    #[test]
    fn keeps_the_newest_400() {
        let mut d = BTreeMap::new();
        for i in 0..450 {
            d.insert(format!("d{:04}", i), i as i64);
        }
        let k = keep_last(d);
        assert_eq!(k.len(), 400);
        assert_eq!(k.keys().next().map(|s| s.as_str()), Some("d0050"));
    }

    #[test]
    fn renders_sorted_and_escaped() {
        let mut d = BTreeMap::new();
        d.insert("b".to_string(), 2);
        d.insert("a\"x".to_string(), 1);
        assert_eq!(render(&d), r#"{"a\"x":1,"b":2}"#);
        assert_eq!(render(&BTreeMap::new()), "{}");
    }
}
