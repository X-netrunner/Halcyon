//! hal switch-user list | to ID | greeter: what the lock screen's "Switch user" button runs. It uses systemd-logind, so it needs no root.
//!
//!   list       other sessions on this seat, one per line:  SESSION_ID <TAB> USER <TAB> TTY
//!   to ID      bring that session to the front (it stays logged in; this screen stays locked)
//!   greeter    a login screen for someone else: lightdm's greeter if there is one, otherwise the next free
//!              text console (Ctrl+Alt+F2 ... F6) where getty asks for a login
//!
//! Switching users never unlocks THIS session: the lock screen stays up here, and you come back to it with the same password.
//! Help, a bad session id and unknown commands return 2 without a word: the bash original (the fallback of switch-user.sh) answers.

use crate::util;
use std::env;

fn say(msg: &str) {
    util::notify_app("Halcyon", "Switch user", msg, None);
    eprintln!("{}", msg);
}

/// One property of a login session (loginctl show-session ID -p NAME --value).
fn prop(session: &str, name: &str) -> String {
    util::out(
        "loginctl",
        &["show-session", session, "-p", name, "--value"],
    )
    .trim()
    .to_string()
}

/// This session's id: XDG_SESSION_ID, else the first word of `loginctl session-status`.
fn my_session() -> String {
    if let Ok(v) = env::var("XDG_SESSION_ID") {
        if !v.is_empty() {
            return v;
        }
    }
    if !util::command_exists("loginctl") {
        return String::new();
    }
    let status = util::out("loginctl", &["session-status"]);
    let first = status
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().next())
        .unwrap_or("")
        .to_string();
    first
}

/// The ids in the first column of `loginctl list-sessions --no-legend`.
fn session_ids() -> Vec<String> {
    util::out("loginctl", &["list-sessions", "--no-legend"])
        .lines()
        .filter_map(|l| l.split_whitespace().next().map(|s| s.to_string()))
        .collect()
}

fn list(me: &str) -> i32 {
    if !util::command_exists("loginctl") {
        return 0;
    }
    let sessions = util::out("loginctl", &["list-sessions", "--no-legend"]);
    for line in sessions.lines() {
        // ID UID USER SEAT TTY
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 4 {
            continue;
        }
        let (id, user, seat) = (f[0], f[2], f[3]);
        let tty = f.get(4).copied().unwrap_or("");
        if seat != "seat0" || id == me {
            continue;
        }
        if prop(id, "Class") != "user" {
            continue;
        }
        let state = prop(id, "State");
        if state != "active" && state != "online" {
            continue;
        }
        println!("{}\t{}\t{}", id, user, tty);
    }
    0
}

fn to(id: &str) -> i32 {
    let valid = !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    if !valid {
        return 2;
    }
    if !util::command_exists("loginctl") {
        say("loginctl is not installed.");
        return 1;
    }
    if !util::ok("loginctl", &["activate", id]) {
        say(&format!("Could not switch to session {}.", id));
        return 1;
    }
    0
}

fn greeter(me: &str) -> i32 {
    if util::command_exists("dm-tool") && util::ok("dm-tool", &["switch-to-greeter"]) {
        return 0;
    }
    if !(util::command_exists("busctl") && util::command_exists("loginctl")) {
        say("Press Ctrl+Alt+F2 to reach a login prompt.");
        return 1;
    }
    // consoles (VT numbers) that some session already uses
    let mut taken: Vec<String> = Vec::new();
    let cur = prop(me, "VTNr");
    if !cur.is_empty() {
        taken.push(cur);
    }
    for id in session_ids() {
        let v = prop(&id, "VTNr");
        if !v.is_empty() && v != "0" {
            taken.push(v);
        }
    }
    for n in 2..=6u32 {
        let ns = n.to_string();
        if taken.contains(&ns) {
            continue;
        }
        if util::ok(
            "busctl",
            &[
                "call",
                "org.freedesktop.login1",
                "/org/freedesktop/login1/seat/seat0",
                "org.freedesktop.login1.Seat",
                "SwitchTo",
                "u",
                &ns,
            ],
        ) {
            return 0;
        }
        say(&format!(
            "Could not open a login screen. Press Ctrl+Alt+F{} instead.",
            n
        ));
        return 1;
    }
    say("Every text console is in use. Press Ctrl+Alt+F2 to reach one.");
    1
}

pub fn run(args: &[String]) -> i32 {
    match args.first().map(|s| s.as_str()) {
        Some("list") => list(&my_session()),
        Some("to") => to(args.get(1).map(|s| s.as_str()).unwrap_or("")),
        Some("greeter") => greeter(&my_session()),
        _ => 2,
    }
}
