//! audio / bt / wifi / disk: the JSON feeds the island panels read (ports of audio.py bt.py wifi.py disk.py).
use crate::util::{run, spawn_quiet};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::ffi::CString;
use std::time::Duration;

fn emit(v: Value) {
    println!("{}", v);
}

// ---------------------------------------------------------------- audio
fn pactl(args: &[&str]) -> String {
    run("pactl", args, 3).trim().to_string()
}

fn devices(kind: &str, default: &str, skip_monitors: bool) -> Vec<Value> {
    let raw = pactl(&["-f", "json", "list", kind]);
    let data: Vec<Value> = serde_json::from_str(if raw.is_empty() { "[]" } else { &raw }).unwrap_or_default();
    let mut out = Vec::new();
    for d in data {
        let name = d["name"].as_str().unwrap_or("").to_string();
        if skip_monitors && name.ends_with(".monitor") {
            continue;
        }
        let desc = d["description"].as_str().unwrap_or("").to_string();
        let props = &d["properties"];
        let port = match &d["active_port"] {
            Value::Null => String::new(),
            Value::String(s) => s.clone(),
            other => other.to_string(),
        };
        let low = format!("{} {} {}", name, desc, port).to_lowercase();
        let form = props["device.form_factor"].as_str().unwrap_or("").to_lowercase();
        let k = if name.starts_with("bluez") || props["device.bus"].as_str() == Some("bluetooth") {
            "bluetooth"
        } else if low.contains("hdmi") || low.contains("displayport") {
            "hdmi"
        } else if ["headphone", "headset", "hands-free"].contains(&form.as_str()) || low.contains("headphone") {
            "headphones"
        } else if kind == "sources" {
            "mic"
        } else {
            "speaker"
        };
        out.push(json!({
            "name": name,
            "desc": if desc.is_empty() { name.clone() } else { desc },
            "kind": k,
            "default": name == default,
            "muted": d["mute"].as_bool().unwrap_or(false),
        }));
    }
    out
}

pub fn audio() {
    let ds = pactl(&["get-default-sink"]);
    let dsrc = pactl(&["get-default-source"]);
    emit(json!({ "sinks": devices("sinks", &ds, false), "sources": devices("sources", &dsrc, true) }));
}

// ---------------------------------------------------------------- bluetooth
fn btctl(args: &[&str]) -> String {
    run("bluetoothctl", args, 5)
}

pub fn bt() {
    let on = btctl(&["show"]).contains("Powered: yes");
    let mut devs: Vec<Value> = Vec::new();
    if on {
        let mut listing = btctl(&["devices", "Paired"]);
        if listing.trim().is_empty() {
            listing = btctl(&["paired-devices"]);
        }
        for line in listing.lines() {
            let line = line.trim();
            let rest = match line.strip_prefix("Device") {
                Some(r) => r.trim_start(),
                None => continue,
            };
            if rest.len() < 17 {
                continue;
            }
            let (mac, name) = rest.split_at(17);
            let ok = mac.chars().enumerate().all(|(i, c)| if i % 3 == 2 { c == ':' } else { c.is_ascii_hexdigit() });
            if !ok {
                continue;
            }
            let info = btctl(&["info", mac]);
            let icon = info
                .lines()
                .find_map(|l| l.trim().strip_prefix("Icon:").map(|v| v.trim().to_string()))
                .unwrap_or_default();
            devs.push(json!({
                "mac": mac, "name": name.trim(),
                "connected": info.contains("Connected: yes"), "icon": icon,
            }));
        }
    }
    devs.sort_by_key(|d| (!d["connected"].as_bool().unwrap_or(false), d["name"].as_str().unwrap_or("").to_lowercase()));
    emit(json!({ "on": on, "devs": devs }));
}

// ---------------------------------------------------------------- wifi
/// terse nmcli output: ':' separates fields, '\:' is a literal colon inside one
fn fields(line: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut it = line.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            '\\' => match it.peek() {
                Some(':') | Some('\\') => out.last_mut().unwrap().push(it.next().unwrap()),
                _ => out.last_mut().unwrap().push('\\'),
            },
            ':' => out.push(String::new()),
            _ => out.last_mut().unwrap().push(c),
        }
    }
    out
}

pub fn wifi() {
    let on = run("nmcli", &["radio", "wifi"], 6).trim() == "enabled";
    spawn_quiet("nmcli", &["device", "wifi", "rescan"]);

    let mut saved = std::collections::HashSet::new();
    for line in run("nmcli", &["-t", "-f", "NAME,TYPE", "connection", "show"], 6).lines() {
        let f = fields(line);
        if f.len() >= 2 && f[1] == "802-11-wireless" {
            saved.insert(f[0].clone());
        }
    }

    let mut best: HashMap<String, (bool, bool, i64, bool)> = HashMap::new(); // active, saved, signal, secure
    if on {
        for line in run("nmcli", &["-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list"], 6).lines() {
            let f = fields(line);
            if f.len() < 4 || f[1].is_empty() {
                continue;
            }
            let signal = f[2].parse::<i64>().unwrap_or(0);
            let net = (f[0] == "*", saved.contains(&f[1]), signal, !(f[3].is_empty() || f[3] == "--"));
            match best.get(&f[1]) {
                Some(old) if !(net.0 || (!old.0 && net.2 > old.2)) => {}
                _ => {
                    best.insert(f[1].clone(), net);
                }
            }
        }
    }
    let mut nets: Vec<(String, (bool, bool, i64, bool))> = best.into_iter().collect();
    nets.sort_by_key(|(_, n)| (!n.0, !n.1, -n.2));
    let nets: Vec<Value> = nets
        .into_iter()
        .take(30)
        .map(|(ssid, n)| json!({ "ssid": ssid, "signal": n.2, "secure": n.3, "active": n.0, "saved": n.1 }))
        .collect();
    emit(json!({ "on": on, "nets": nets }));
}

// ---------------------------------------------------------------- disk
const SKIP_FS: &[&str] = &[
    "tmpfs", "devtmpfs", "efivarfs", "squashfs", "overlay", "proc", "sysfs", "cgroup2", "ramfs", "fuse.portal",
];

fn unescape_mount(s: &str) -> String {
    // /proc/mounts writes space, tab, newline and backslash as \040 \011 \012 \134
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 3 < b.len() && b[i + 1..i + 4].iter().all(|c| (b'0'..=b'7').contains(c)) {
            let v = (b[i + 1] - b'0') * 64 + (b[i + 2] - b'0') * 8 + (b[i + 3] - b'0');
            out.push(v);
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn disks_once() -> Value {
    let mut seen: HashMap<String, (String, u64, u64, String)> = HashMap::new();
    for line in crate::util::read("/proc/self/mounts").lines() {
        let p: Vec<&str> = line.split_whitespace().collect();
        if p.len() < 3 {
            continue;
        }
        let (src, tgt, fs) = (p[0].to_string(), unescape_mount(p[1]), p[2].to_string());
        if SKIP_FS.contains(&fs.as_str()) || !src.starts_with("/dev/") {
            continue;
        }
        if ["/boot", "/efi", "/var/lib", "/run/user", "/snap"].iter().any(|x| tgt.starts_with(x)) {
            continue;
        }
        if let Some(old) = seen.get(&src) {
            if tgt.len() >= old.0.len() {
                continue;
            }
        }
        let c = match CString::new(tgt.clone()) {
            Ok(c) => c,
            Err(_) => continue,
        };
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
            continue;
        }
        let fr = st.f_frsize as u64;
        let size = st.f_blocks as u64 * fr;
        let used = (st.f_blocks as u64).saturating_sub(st.f_bfree as u64) * fr;
        seen.insert(src, (tgt, used, size, fs));
    }
    let mut v: Vec<_> = seen.into_values().collect();
    v.sort_by(|a, b| (a.0 != "/", &a.0).cmp(&(b.0 != "/", &b.0)));
    let disks: Vec<Value> = v
        .into_iter()
        .map(|(m, used, size, fs)| json!({ "mount": m, "used": used, "size": size, "fs": fs }))
        .collect();
    json!({ "disks": disks })
}

/// one JSON line every `iv` seconds (default 10), only while the performance page is open
pub fn disk(iv: f64) {
    loop {
        emit(disks_once());
        std::thread::sleep(Duration::from_secs_f64(iv.max(0.5)));
    }
}
