//! hal osd-watch: native watcher for screen and keyboard brightness.
//! Emits JSON lines `{"k":"bright","p":N}` or `{"k":"kbd","p":N}` when values change.
//! Replaces scripts/osd-watch.sh running continuous Bash loops.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::Duration;

fn find_screen() -> Option<(PathBuf, i64)> {
    let base = Path::new("/sys/class/backlight");
    let mut best: Option<(PathBuf, i64)> = None;
    if let Ok(entries) = fs::read_dir(base) {
        for entry in entries.filter_map(|e| e.ok()) {
            let p = entry.path();
            if let Ok(s) = fs::read_to_string(p.join("max_brightness")) {
                if let Ok(m) = s.trim().parse::<i64>() {
                    if m > best.as_ref().map(|b| b.1).unwrap_or(0) {
                        best = Some((p, m));
                    }
                }
            }
        }
    }
    best
}

fn find_kbd() -> Option<(PathBuf, i64)> {
    let base = Path::new("/sys/class/leds");
    if let Ok(entries) = fs::read_dir(base) {
        for entry in entries.filter_map(|e| e.ok()) {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.contains("kbd_backlight")
                || name.contains("kbd-backlight")
                || (name.contains("keyboard") && name.contains("backlight"))
            {
                let p = entry.path();
                if let Ok(s) = fs::read_to_string(p.join("max_brightness")) {
                    if let Ok(m) = s.trim().parse::<i64>() {
                        return Some((p, m));
                    }
                }
            }
        }
    }
    None
}

fn read_val(p: &Path) -> Option<i64> {
    fs::read_to_string(p.join("brightness")).ok()?.trim().parse().ok()
}

pub fn run() -> i32 {
    let screen = find_screen();
    let kbd = find_kbd();
    if screen.is_none() && kbd.is_none() {
        return 0;
    }

    let mut lb: i64 = -1;
    let mut lk: i64 = -1;
    let mut quiet: i32 = 0;
    let mut idle: u32 = 0;

    loop {
        let mut chg = false;
        if Path::new("/dev/shm/halcyon-dim").exists() {
            quiet = 8;
        } else if quiet > 0 {
            quiet -= 1;
        }

        if let Some((ref spath, bmax)) = screen {
            if let Some(b) = read_val(spath) {
                if b != lb {
                    if lb != -1 && quiet == 0 && bmax > 0 {
                        let pct = (b * 100) / bmax;
                        println!("{{\"k\":\"bright\",\"p\":{}}}", pct);
                        if std::io::stdout().flush().is_err() {
                            break;
                        }
                    }
                    lb = b;
                    chg = true;
                }
            }
        }

        if let Some((ref kpath, kmax)) = kbd {
            if let Some(k) = read_val(kpath) {
                if k != lk {
                    if lk != -1 && quiet == 0 && kmax > 0 {
                        let pct = (k * 100) / kmax;
                        println!("{{\"k\":\"kbd\",\"p\":{}}}", pct);
                        if std::io::stdout().flush().is_err() {
                            break;
                        }
                    }
                    lk = k;
                    chg = true;
                }
            }
        }

        let w = if chg {
            idle = 0;
            0.25
        } else if idle < 40 {
            idle += 1;
            0.25
        } else if idle < 140 {
            idle += 1;
            0.50
        } else {
            1.00
        };

        sleep(Duration::from_secs_f64(w));
    }

    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_find_screen_and_kbd_does_not_panic() {
        let _ = find_screen();
        let _ = find_kbd();
    }
}
