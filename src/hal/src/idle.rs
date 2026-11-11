//! hal idle start | apply LOCK SLEEP [DIM [AV_AI]]: idle behaviour.
//! Dim the screen (and switch the keyboard light off) after a while, lock after a while, sleep after a long while.
//! All of it is set in the island's Settings > Sleep & lock. It writes a hypridle config of its own
//! (~/.local/state/island/hypridle.conf) and runs hypridle with it, so your own ~/.config/hypr/hypridle.conf is not touched.
//! hypridle honours Caffeine (systemd-inhibit), so a caffeinated session never locks or sleeps.
//!   start                              write the config from the saved values and (re)start hypridle (autostart runs this)
//!   apply LOCK SLEEP [DIM] [AV_AI]     minutes, 0 = never; restarts hypridle only when something changed
//! Anything else returns 2 without a word: the bash original (the fallback of idle.sh) prints the usage.

use crate::util;
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq)]
struct Idle {
    lock: u64,
    sleep: u64,
    dim: u64,
    av: u64,
}

/// Whole number, or the default (empty, text, "-3" and "1.5" all count as "not set").
fn num(v: Option<&str>, default: u64) -> u64 {
    match v {
        Some(s) if !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) => {
            s.parse::<u64>().unwrap_or(default)
        }
        _ => default,
    }
}

/// idle.env as Settings wrote it: IDLE_LOCK=5 IDLE_SLEEP=30 IDLE_DIM=3 AV_AI_IDLE=5
fn load(text: &str) -> Idle {
    Idle {
        lock: num(util::conf_value(text, "IDLE_LOCK").as_deref(), 5),
        sleep: num(util::conf_value(text, "IDLE_SLEEP").as_deref(), 30),
        dim: num(util::conf_value(text, "IDLE_DIM").as_deref(), 3),
        av: num(util::conf_value(text, "AV_AI_IDLE").as_deref(), 5),
    }
}

/// The hypridle config. `scripts` is the folder with lock.sh, idle-dim.sh and av-ai-idle.sh.
fn conf_text(scripts: &str, v: Idle) -> String {
    let mut sleep = v.sleep;
    // sleep is counted from when you stop touching the computer, so it has to come after the lock
    if v.lock > 0 && sleep > 0 && sleep <= v.lock {
        sleep = v.lock + 1;
    }
    let lockcmd = format!("{}/lock.sh", scripts);
    let mut s = String::new();
    s.push_str(&format!(
        "general {{\n    lock_cmd = {}\n    before_sleep_cmd = {}\n}}\n",
        lockcmd, lockcmd
    ));
    if v.dim > 0 {
        s.push_str(&format!(
            "\nlistener {{\n    timeout = {}\n    on-timeout = {}/idle-dim.sh dim\n    on-resume = {}/idle-dim.sh undim\n}}\n",
            v.dim * 60,
            scripts,
            scripts
        ));
    }
    // AI Antivirus analyzer (local model): paused while you work, runs once the computer has been idle this long (0 = always runs)
    if v.av > 0 {
        s.push_str(&format!(
            "\nlistener {{\n    timeout = {}\n    on-timeout = {}/av-ai-idle.sh idle\n    on-resume = {}/av-ai-idle.sh active\n}}\n",
            v.av * 60,
            scripts,
            scripts
        ));
    }
    if v.lock > 0 {
        s.push_str(&format!(
            "\nlistener {{\n    timeout = {}\n    on-timeout = {}\n}}\n",
            v.lock * 60,
            lockcmd
        ));
    }
    if sleep > 0 {
        s.push_str(&format!(
            "\nlistener {{\n    timeout = {}\n    on-timeout = systemctl suspend\n}}\n",
            sleep * 60
        ));
    }
    s
}

/// (Re)starts hypridle with the config. false = hypridle is not installed.
fn restart(conf: &Path) -> bool {
    if !util::command_exists("hypridle") {
        eprintln!("hypridle is not installed (pacman -S hypridle)");
        return false;
    }
    let _ = util::ok("pkill", &["-x", "hypridle"]);
    thread::sleep(Duration::from_millis(300));
    let conf = conf.to_string_lossy().to_string();
    // setsid -f: hypridle keeps running when this helper is gone
    let _ = util::ok("setsid", &["-f", "hypridle", "-c", &conf]);
    true
}

/// The antivirus analyzer follows the idle state; it is told "active" now (in the background, nothing waits for it).
fn tell_av_active() {
    let script = util::scripts_dir().join("av-ai-idle.sh");
    let _ = Command::new("bash")
        .arg(script)
        .arg("active")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

pub fn run(args: &[String]) -> i32 {
    let state = util::state_dir();
    let _ = fs::create_dir_all(&state);
    let envf = state.join("idle.env");
    let conf = state.join("hypridle.conf");
    let scripts = util::rice_dir()
        .join("scripts")
        .to_string_lossy()
        .to_string();
    let saved = load(&fs::read_to_string(&envf).unwrap_or_default());

    match args.first().map(|s| s.as_str()) {
        Some("start") => {
            let _ = fs::write(&conf, conf_text(&scripts, saved));
            if !restart(&conf) {
                return 1;
            }
            tell_av_active();
            0
        }
        Some("apply") => {
            let arg = |i: usize| args.get(i).map(|s| s.as_str());
            let v = Idle {
                lock: num(arg(1), 5),
                sleep: num(arg(2), 30),
                dim: num(arg(3), saved.dim),
                av: num(arg(4), saved.av),
            };
            let _ = fs::write(
                &envf,
                format!(
                    "IDLE_LOCK={}\nIDLE_SLEEP={}\nIDLE_DIM={}\nAV_AI_IDLE={}\n",
                    v.lock, v.sleep, v.dim, v.av
                ),
            );
            let text = conf_text(&scripts, v);
            let unchanged = fs::read_to_string(&conf)
                .map(|old| old == text)
                .unwrap_or(false);
            if !unchanged || !util::ok("pgrep", &["-x", "hypridle"]) {
                let _ = fs::write(&conf, &text);
                if !restart(&conf) {
                    return 1;
                }
            }
            tell_av_active();
            0
        }
        _ => 2,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn num_accepts_whole_numbers_only() {
        assert_eq!(num(Some("12"), 5), 12);
        assert_eq!(num(Some("0"), 5), 0);
        assert_eq!(num(Some(""), 5), 5);
        assert_eq!(num(Some("-3"), 5), 5);
        assert_eq!(num(Some("1.5"), 5), 5);
        assert_eq!(num(Some("x"), 5), 5);
        assert_eq!(num(None, 7), 7);
    }

    #[test]
    fn load_uses_defaults_for_missing_keys() {
        assert_eq!(
            load(""),
            Idle {
                lock: 5,
                sleep: 30,
                dim: 3,
                av: 5
            }
        );
        assert_eq!(
            load("IDLE_LOCK=10\nIDLE_SLEEP=0\nIDLE_DIM=bad\n"),
            Idle {
                lock: 10,
                sleep: 0,
                dim: 3,
                av: 5
            }
        );
    }

    #[test]
    fn sleep_always_comes_after_the_lock() {
        let t = conf_text(
            "/s",
            Idle {
                lock: 10,
                sleep: 10,
                dim: 0,
                av: 0,
            },
        );
        assert!(t.contains("timeout = 600\n    on-timeout = /s/lock.sh"));
        assert!(t.contains("timeout = 660\n    on-timeout = systemctl suspend"));
    }

    #[test]
    fn zero_means_never() {
        let t = conf_text(
            "/s",
            Idle {
                lock: 0,
                sleep: 0,
                dim: 0,
                av: 0,
            },
        );
        assert_eq!(
            t,
            "general {\n    lock_cmd = /s/lock.sh\n    before_sleep_cmd = /s/lock.sh\n}\n"
        );
    }

    #[test]
    fn listeners_come_in_the_old_order() {
        let t = conf_text(
            "/s",
            Idle {
                lock: 5,
                sleep: 30,
                dim: 3,
                av: 5,
            },
        );
        let dim = t.find("idle-dim.sh dim").unwrap_or(usize::MAX);
        let av = t.find("av-ai-idle.sh idle").unwrap_or(usize::MAX);
        let lock = t.find("on-timeout = /s/lock.sh").unwrap_or(usize::MAX);
        let sleep = t.find("systemctl suspend").unwrap_or(usize::MAX);
        assert!(dim < av && av < lock && lock < sleep);
        assert!(t.contains("timeout = 180\n    on-timeout = /s/idle-dim.sh dim\n    on-resume = /s/idle-dim.sh undim\n"));
    }
}
