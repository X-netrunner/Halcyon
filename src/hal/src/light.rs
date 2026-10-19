//! hal brightness / hal backlight: ports of scripts/brightness.sh and scripts/backlight.sh.
//!
//! Writing a brightness value is tried three ways, in this order (the touchpad-gestures service is NOT inside
//! your login session, so a plain `brightnessctl` often cannot write the backlight there):
//!   1. brightnessctl            works with the `video` group (udev rule) or when logind accepts the call
//!   2. a direct sysfs write     works when the brightness file is writable (the Halcyon udev rule makes it so)
//!   3. logind SetBrightness     over D-Bus, with your session named explicitly (needs no group)

use crate::util;
use std::fs;
use std::io::Write;
use std::path::Path;

fn read_i64(path: &Path) -> Option<i64> {
    fs::read_to_string(path).ok()?.trim().parse::<i64>().ok()
}

fn read_text(path: &Path) -> String {
    fs::read_to_string(path).map(|s| s.trim().to_string()).unwrap_or_default()
}

/// Names of the entries of a /sys/class/<class> directory, sorted like a shell glob would.
fn sorted_names(dir: &str) -> Vec<String> {
    let mut names: Vec<String> = match fs::read_dir(dir) {
        Ok(rd) => rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect(),
        Err(_) => Vec::new(),
    };
    names.sort();
    names
}

/// "device, current, max" of the screen backlight with the biggest range (same rule as `hx ctl`).
fn best_screen() -> Option<(String, i64, i64)> {
    let mut best: Option<(String, i64, i64)> = None;
    let mut bmax: i64 = 0;
    for name in sorted_names("/sys/class/backlight") {
        let dir = Path::new("/sys/class/backlight").join(&name);
        let m = match read_i64(&dir.join("max_brightness")) {
            Some(m) => m,
            None => continue,
        };
        if m > bmax {
            bmax = m;
            let cur = read_i64(&dir.join("brightness")).unwrap_or(0);
            best = Some((name.clone(), cur, m));
        }
    }
    best
}

/// Every keyboard backlight as "device current max", sorted, without duplicates.
fn kbd_list() -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    for name in sorted_names("/sys/class/leds") {
        // the shell globs: *kbd_backlight*  *kbd-backlight*  *keyboard*backlight*
        let keyboard_then_backlight = match name.find("keyboard") {
            Some(i) => name[i + "keyboard".len()..].contains("backlight"),
            None => false,
        };
        if !(name.contains("kbd_backlight") || name.contains("kbd-backlight") || keyboard_then_backlight) {
            continue;
        }
        let dir = Path::new("/sys/class/leds").join(&name);
        let max = match read_i64(&dir.join("max_brightness")) {
            Some(m) => m,
            None => continue,
        };
        lines.push(format!("{} {} {}", name, read_text(&dir.join("brightness")), max));
    }
    lines.sort();
    lines.dedup();
    lines
}

fn write_sysfs(path: &str, val: &str) -> bool {
    match fs::OpenOptions::new().write(true).open(path) {
        Ok(mut f) => f.write_all(format!("{}\n", val).as_bytes()).is_ok(),
        Err(_) => false,
    }
}

fn logind_set(class: &str, dev: &str, val: &str) -> bool {
    let user = std::env::var("USER").unwrap_or_default();
    let mut sess = util::out("loginctl", &["show-user", user.as_str(), "-p", "Display", "--value"]).trim().to_string();
    if sess.is_empty() {
        sess = String::from("auto");
    }
    let path = format!("/org/freedesktop/login1/session/{}", sess);
    util::ok(
        "busctl",
        &[
            "call",
            "org.freedesktop.login1",
            path.as_str(),
            "org.freedesktop.login1.Session",
            "SetBrightness",
            "ssu",
            class,
            dev,
            val,
        ],
    )
}

/// hal brightness up|down [percent]   (default step 5)
pub fn brightness(args: &[String]) -> i32 {
    let dir = args.get(0).map(|s| s.as_str()).unwrap_or("up");
    let step: i64 = args.get(1).and_then(|s| s.parse::<i64>().ok()).unwrap_or(5);
    let up = match dir {
        "up" => true,
        "down" => false,
        _ => {
            eprintln!("usage: hal brightness up|down [percent]");
            return 2;
        }
    };
    let arg = if up { format!("{}%+", step) } else { format!("{}%-", step) };

    if util::command_exists("brightnessctl") && util::ok("brightnessctl", &["-q", "--min-value=1", "set", arg.as_str()]) {
        return 0;
    }

    let (dev, cur, bmax) = match best_screen() {
        Some(b) => b,
        None => {
            eprintln!("hal brightness: no backlight device in /sys/class/backlight");
            return 1;
        }
    };
    let mut delta = bmax * step / 100;
    if delta < 1 {
        delta = 1;
    }
    let mut new = if up { cur + delta } else { cur - delta };
    if new > bmax {
        new = bmax;
    }
    if new < 1 {
        new = 1;
    }
    let val = new.to_string();

    if write_sysfs(&format!("/sys/class/backlight/{}/brightness", dev), &val) {
        return 0;
    }
    if logind_set("backlight", &dev, &val) {
        return 0;
    }
    eprintln!("hal brightness: cannot change brightness. Add yourself to the video group: sudo usermod -aG video $USER (then log in again)");
    1
}

/// hal backlight set <backlight|leds> <device> <raw> | best-screen | kbd
pub fn backlight(args: &[String]) -> i32 {
    match args.get(0).map(|s| s.as_str()) {
        Some("best-screen") => match best_screen() {
            Some((dev, cur, max)) => {
                println!("{} {} {}", dev, cur, max);
                0
            }
            None => 1,
        },
        Some("kbd") => {
            for line in kbd_list() {
                println!("{}", line);
            }
            0
        }
        Some("set") => backlight_set(&args[1..]),
        _ => {
            eprintln!("usage: hal backlight set <backlight|leds> <device> <raw> | best-screen | kbd");
            2
        }
    }
}

fn backlight_set(args: &[String]) -> i32 {
    let class = args.get(0).map(|s| s.as_str()).unwrap_or("");
    let dev = args.get(1).map(|s| s.as_str()).unwrap_or("");
    let val = args.get(2).map(|s| s.as_str()).unwrap_or("");
    if class != "backlight" && class != "leds" {
        eprintln!("class must be backlight or leds");
        return 2;
    }
    if dev.is_empty() || val.is_empty() {
        eprintln!("usage: hal backlight set <class> <device> <raw>");
        return 2;
    }
    // the device name becomes part of a path under /sys/class/<class>: it must be a plain name
    if dev.contains('/') || dev == ".." || dev == "." {
        eprintln!("hal backlight: bad device name: {}", dev);
        return 2;
    }

    if util::command_exists("brightnessctl") && util::ok("brightnessctl", &["-q", "-c", class, "-d", dev, "set", val]) {
        return 0;
    }
    if write_sysfs(&format!("/sys/class/{}/{}/brightness", class, dev), val) {
        return 0;
    }
    if logind_set(class, dev, val) {
        return 0;
    }
    eprintln!("hal backlight: cannot write {}/{}. Run: scripts/kbd-backlight.sh doctor   (groups input + video, udev rule)", class, dev);
    1
}

pub fn best_screen_info() -> Option<(String, i64, i64)> {
    best_screen()
}

pub fn kbd_list_info() -> Vec<(String, i64, i64)> {
    let mut list = Vec::new();
    for line in kbd_list() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 {
            let dev = parts[0].to_string();
            let cur = parts[1].parse::<i64>().unwrap_or(0);
            let max = parts[2].parse::<i64>().unwrap_or(0);
            list.push((dev, cur, max));
        }
    }
    list
}

pub fn backlight_set_direct(class: &str, dev: &str, val: &str) {
    if util::command_exists("brightnessctl") && util::ok("brightnessctl", &["-q", "-c", class, "-d", dev, "set", val]) {
        return;
    }
    if write_sysfs(&format!("/sys/class/{}/{}/brightness", class, dev), val) {
        return;
    }
    let _ = logind_set(class, dev, val);
}
