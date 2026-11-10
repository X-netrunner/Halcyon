//! hal extra-dim toggle | on | off | status

use crate::light;
use crate::util;
use std::fs;
use std::path::PathBuf;

fn state_path() -> PathBuf {
    util::state_dir().join("extra_dim.state")
}

fn get_current_brightness() -> String {
    if util::command_exists("brightnessctl") {
        let out = util::out("brightnessctl", &["get"]);
        let t = out.trim();
        if !t.is_empty() {
            return t.to_string();
        }
    }
    // Fallback: sysfs
    if let Ok(entries) = fs::read_dir("/sys/class/backlight") {
        for entry in entries.flatten() {
            let p = entry.path().join("brightness");
            if let Ok(s) = fs::read_to_string(&p) {
                let t = s.trim();
                if !t.is_empty() {
                    return t.to_string();
                }
            }
        }
    }
    "100".to_string()
}

fn set_brightness(val: &str) {
    if util::command_exists("brightnessctl") {
        let _ = util::ok("brightnessctl", &["set", val]);
    }
}

/// Fade to `target` (a raw value, or "N%") instead of jumping: Extra dim used to cut the backlight in one step.
fn fade_to(target: &str) {
    if let Some((dev, cur, max)) = light::best_screen_info() {
        let raw = match target.strip_suffix('%') {
            Some(p) => max * p.parse::<i64>().unwrap_or(35) / 100,
            None => target.parse::<i64>().unwrap_or(cur),
        }
        .clamp(1, max.max(1));
        light::fade_screen(&dev, cur, raw, max, 500);
        return;
    }
    set_brightness(target);
}

fn status() -> i32 {
    let p = state_path();
    if p.exists() {
        println!("on");
    } else {
        println!("off");
    }
    0
}

fn on() -> i32 {
    let p = state_path();
    let _ = fs::create_dir_all(util::state_dir());
    if !p.exists() {
        let cur = get_current_brightness();
        let _ = fs::write(&p, format!("{}\n", cur));
    }
    fade_to("1%");
    util::notify("Extra Dim", "Screen brightness dimmed to minimum", None, 2000);
    println!("on");
    0
}

fn off() -> i32 {
    let p = state_path();
    if p.exists() {
        let saved = fs::read_to_string(&p).unwrap_or_else(|_| "35%".to_string());
        let _ = fs::remove_file(&p);
        let saved = saved.trim();
        if saved.chars().all(|c| c.is_ascii_digit()) && !saved.is_empty() {
            fade_to(saved);
        } else {
            fade_to("35%");
        }
    } else {
        fade_to("35%");
    }
    util::notify("Extra Dim", "Screen brightness restored", None, 2000);
    println!("off");
    0
}

fn toggle() -> i32 {
    let p = state_path();
    if p.exists() {
        off()
    } else {
        on()
    }
}

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("toggle");
    match cmd {
        "on" => on(),
        "off" => off(),
        "toggle" => toggle(),
        "status" => status(),
        _ => {
            eprintln!("usage: hal extra-dim toggle | on | off | status");
            2
        }
    }
}
