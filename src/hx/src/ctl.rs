//! `hx ctl`: volume / mute / microphone / brightness as one JSON line, printed the moment something changes.
//! Replaces the 2-second `ctl.sh` poll, so the sliders in the utilities panel follow touchpad gestures,
//! media keys and other apps with no visible delay.
//!   brightness  /sys/class/backlight is read every 60 ms (one tiny file read), `brightnessctl` is the fallback
//!   volume      `pactl subscribe` wakes us on every sink / server event, then `wpctl get-volume` reads it;
//!               without pactl it falls back to a 250 ms poll
use crate::util;
use std::io::{BufRead, BufReader, Write};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

fn backlight() -> Option<(String, f64)> {
    let mut best: Option<(String, f64)> = None;
    for e in std::fs::read_dir("/sys/class/backlight").ok()?.flatten() {
        let p = e.path().to_string_lossy().into_owned();
        let max: f64 = util::read(&format!("{}/max_brightness", p)).trim().parse().unwrap_or(0.0);
        if max > 0.0 && best.as_ref().map_or(true, |(_, m)| max > *m) {
            best = Some((p, max));
        }
    }
    best
}

fn bright(bl: &Option<(String, f64)>) -> i32 {
    if let Some((p, max)) = bl {
        if let Ok(v) = util::read(&format!("{}/brightness", p)).trim().parse::<f64>() {
            return (v * 100.0 / max).round() as i32;
        }
    }
    let o = util::run("brightnessctl", &["-m"], 2);
    o.lines().next().and_then(|l| l.split(',').nth(3)).map(|s| s.trim_end_matches('%').parse().unwrap_or(0)).unwrap_or(0)
}

fn volume(target: &str) -> (i32, bool) {
    let o = util::run("wpctl", &["get-volume", target], 2);
    let v = o.split_whitespace().nth(1).and_then(|s| s.parse::<f64>().ok()).unwrap_or(0.0);
    ((v * 100.0).round() as i32, o.contains("MUTED"))
}

pub fn run() {
    let dirty = Arc::new(AtomicBool::new(true));
    let have_pactl = {
        let d = dirty.clone();
        match Command::new("pactl").arg("subscribe").stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn() {
            Ok(mut child) => {
                let out = child.stdout.take();
                std::thread::spawn(move || {
                    if let Some(o) = out {
                        for line in BufReader::new(o).lines().map_while(Result::ok) {
                            if line.contains(" sink ") || line.contains(" source ") || line.contains("server") {
                                d.store(true, Ordering::Relaxed);
                            }
                        }
                    }
                    let _ = child.wait();
                });
                true
            }
            Err(_) => false,
        }
    };

    let bl = backlight();
    let mut last = String::new();
    let mut vol = (0, false);
    let mut mic = (0, false);
    let mut b = bright(&bl);
    let mut last_poll = Instant::now() - Duration::from_secs(1);
    let stdout = std::io::stdout();
    loop {
        let nb = bright(&bl);
        let poll = !have_pactl && last_poll.elapsed() > Duration::from_millis(250);
        let slow = last_poll.elapsed() > Duration::from_secs(3); // safety net if an event was missed
        if dirty.swap(false, Ordering::Relaxed) || poll || slow {
            vol = volume("@DEFAULT_AUDIO_SINK@");
            mic = volume("@DEFAULT_AUDIO_SOURCE@");
            last_poll = Instant::now();
        }
        b = if nb != b || last.is_empty() { nb } else { b };
        let line = format!("{{\"vol\":{},\"muted\":{},\"mic\":{},\"micMuted\":{},\"bright\":{}}}", vol.0, vol.1, mic.0, mic.1, b);
        if line != last {
            let mut o = stdout.lock();
            if writeln!(o, "{}", line).is_err() || o.flush().is_err() {
                return; // the island went away
            }
            last = line;
        }
        std::thread::sleep(Duration::from_millis(60));
    }
}
