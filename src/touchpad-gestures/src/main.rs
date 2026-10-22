mod classify;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{self, Sender};
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use evdev::{AbsoluteAxisType, Device, EventType};

/// Fingers land one after the other and jitter for a moment: movement in the first few milliseconds after the
/// last finger touches down is not counted as a swipe or a pinch.
const SETTLE_MS: u64 = 60;

static CMD_CHANNEL: OnceLock<Sender<(&'static str, Vec<String>)>> = OnceLock::new();

fn cmd_sender() -> &'static Sender<(&'static str, Vec<String>)> {
    CMD_CHANNEL.get_or_init(|| {
        let (tx, rx) = mpsc::channel::<(&'static str, Vec<String>)>();
        std::thread::spawn(move || {
            while let Ok((cmd, args)) = rx.recv() {
                match Command::new(cmd).args(&args).output() {
                    Ok(o) if o.status.success() => {}
                    Ok(o) => eprintln!("{} {:?} failed: {}", cmd, args, String::from_utf8_lossy(&o.stderr).trim()),
                    Err(e) => eprintln!("cannot run {}: {} (is it installed and in PATH?)", cmd, e),
                }
            }
        });
        tx
    })
}

/// Run a helper via the dedicated worker thread without blocking the event loop
fn fire(cmd: &'static str, args: Vec<String>) {
    let _ = cmd_sender().send((cmd, args));
}
fn fire_s(cmd: &'static str, args: &[&str]) {
    fire(cmd, args.iter().map(|a| a.to_string()).collect());
}

/// Brightness goes through scripts/brightness.sh
fn brightness(dir: &str) {
    let home = std::env::var("HOME").unwrap_or_default();
    fire(
        "bash",
        vec![format!("{}/.config/Halcyon/scripts/brightness.sh", home), dir.to_string(), "5".to_string()],
    );
}

/// How many /dev/input devices could not be opened for lack of permission (set by find_touchpad).
static DENIED_DEVICES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
/// Exit status for "this cannot work until the user fixes their setup" (EX_CONFIG). touchpad-gestures.service lists it in
/// RestartPreventExitStatus, so a missing `input` group stops the service instead of restarting it forever.
const EXIT_NEEDS_SETUP: i32 = 78;

/// A touchpad is a device that reports multitouch X/Y and is named like one.
fn find_touchpad() -> Option<Device> {
    let entries = match fs::read_dir("/dev/input") {
        Ok(e) => e,
        Err(e) => {
            eprintln!("cannot read /dev/input: {}", e);
            return None;
        }
    };
    let mut denied = 0;
    for entry in entries.flatten() {
        let path = entry.path();
        let is_event = path.file_name().and_then(|n| n.to_str()).is_some_and(|s| s.starts_with("event"));
        if !is_event {
            continue;
        }
        match Device::open(&path) {
            Ok(device) => {
                let name = device.name().unwrap_or("").to_lowercase();
                let named = name.contains("touchpad") || name.contains("touch pad") || name.contains("trackpad");
                let has_mt = device
                    .supported_absolute_axes()
                    .is_some_and(|a| a.contains(AbsoluteAxisType::ABS_MT_POSITION_X) && a.contains(AbsoluteAxisType::ABS_MT_POSITION_Y));
                if named && has_mt {
                    return Some(device);
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => denied += 1,
            Err(_) => {}
        }
    }
    if denied > 0 {
        DENIED_DEVICES.store(denied, std::sync::atomic::Ordering::Relaxed);
        eprintln!("{} input devices are not readable: add yourself to the input group (sudo usermod -aG input $USER) and log in again", denied);
    }
    None
}

fn touchpad_disabled() -> bool {
    std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .and_then(|d| fs::read_to_string(format!("{}/touchpad.status", d)).ok())
        .map(|s| s.trim() == "disabled")
        .unwrap_or(false)
}

/// Reads ~/.local/state/island/gestures.conf (written by scripts/input-conf.sh)
/// and returns the map of g3-* and g4-* gesture IDs to their configured action names.
fn load_gestures_conf(last_load: &mut Instant, map: &mut HashMap<String, String>) {
    if last_load.elapsed() < Duration::from_secs(3) && !map.is_empty() {
        return;
    }
    *last_load = Instant::now();
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let state_dir = PathBuf::from(&home).join(".local/state/island");
    let swipe4_right = fs::read_to_string(state_dir.join("ws-swipe4"))
        .map(|s| s.trim() == "right")
        .unwrap_or(false);

    let mut out = HashMap::new();
    out.insert("g3-up".into(), "scratch".into());
    out.insert("g3-down".into(), "scratch".into());
    out.insert("g3-pinchin".into(), "overview".into());
    out.insert("g3-pinchout".into(), "overview".into());
    out.insert("g4-left".into(), if swipe4_right { "ws-prev".into() } else { "ws-next".into() });
    out.insert("g4-right".into(), if swipe4_right { "ws-next".into() } else { "ws-prev".into() });
    out.insert("g4-down".into(), "sleep".into());

    if let Ok(raw) = fs::read_to_string(state_dir.join("gestures.conf")) {
        for line in raw.lines() {
            if let Some((k, v)) = line.trim().split_once('=') {
                if !k.ends_with(".cmd") {
                    out.insert(k.trim().to_string(), v.trim().to_string());
                }
            }
        }
    }
    *map = out;
}

fn gesture_state_path() -> PathBuf {
    let dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(dir).join("halcyon-gesture.json")
}

/// JSON string escape: the action name comes from gestures.conf, so a quote or backslash must not break the file.
fn json_esc(s: &str) -> String {
    let mut o = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 => o.push(' '),
            c => o.push(c),
        }
    }
    o
}

/// Streams live 3-finger / 4-finger normalized displacement & pinch scale to $XDG_RUNTIME_DIR/halcyon-gesture.json
/// so Quickshell overlays (Overview tree, Launcher, Calendar, Notifications) follow the user's fingers 1:1 in real time.
fn write_gesture_state(phase: &str, fingers: usize, dx: f32, dy: f32, scale: f32, dir: &str, action: &str) {
    let p = gesture_state_path();
    let tmp = p.with_extension("json.tmp");
    let payload = format!(
        r#"{{"phase":"{}","fingers":{},"dx":{:.4},"dy":{:.4},"scale":{:.4},"dir":"{}","action":"{}"}}"#,
        phase,
        fingers,
        dx.clamp(-1.5, 1.5),
        dy.clamp(-1.5, 1.5),
        scale.clamp(0.25, 2.5),
        json_esc(dir),
        json_esc(action)
    );
    if fs::write(&tmp, payload).is_ok() {
        let _ = fs::rename(&tmp, &p);
    }
}

struct SlotState {
    x: Option<i32>,
    y: Option<i32>,
}

fn main() {
    println!("Searching for touchpad device...");
    let mut device = match find_touchpad() {
        Some(d) => d,
        None => {
            eprintln!("Error: Touchpad device not found.");
            // devices exist but none could be opened: restarting cannot help, only the input group can
            if DENIED_DEVICES.load(std::sync::atomic::Ordering::Relaxed) > 0 {
                std::process::exit(EXIT_NEEDS_SETUP);
            }
            std::process::exit(1);
        }
    };

    println!(
        "Found touchpad: {} at {:?}",
        device.name().unwrap_or("Unknown"),
        device.physical_path().unwrap_or("Unknown")
    );

    let abs_state = match device.get_abs_state() {
        Ok(state) => state,
        Err(e) => {
            eprintln!("Error getting absolute state: {:?}", e);
            std::process::exit(1);
        }
    };

    let max_x = abs_state[AbsoluteAxisType::ABS_MT_POSITION_X.0 as usize].maximum;
    let max_y = abs_state[AbsoluteAxisType::ABS_MT_POSITION_Y.0 as usize].maximum;

    if max_x == 0 || max_y == 0 {
        eprintln!("Error: Could not retrieve valid touchpad dimensions.");
        std::process::exit(1);
    }

    println!("Touchpad dimensions: X [0, {}], Y [0, {}]", max_x, max_y);

    let left_edge = (0.04 * max_x as f64) as i32;
    let right_edge = (0.96 * max_x as f64) as i32;
    let top_edge = (0.10 * max_y as f64) as i32;

    let v_threshold = (0.025 * max_y as f64) as i32;
    let h_threshold = (0.08 * max_x as f64) as i32;
    let b_threshold = (0.04 * max_x as f64) as i32;

    println!("Left Edge (< {}), Right Edge (> {}), Top Edge (< {})", left_edge, right_edge, top_edge);
    println!("Thresholds: Vertical Delta={}, Horizontal Delta={}, Brightness Delta={}", v_threshold, h_threshold, b_threshold);

    let mut active_slots: HashMap<i32, SlotState> = HashMap::new();
    let mut current_slot: i32 = 0;

    let mut is_left_edge = false;
    let mut is_right_edge = false;
    let mut is_top_edge = false;
    let mut music_disabled = false;
    let mut pad_disabled = false;
    let mut triggered_action = false;

    let mut start_x: Option<i32> = None;
    let mut start_y: Option<i32> = None;
    let mut last_trigger_x: Option<i32> = None;
    let mut last_trigger_y: Option<i32> = None;
    let mut multi_finger_detected = false;

    // Multi-finger (3 / 4 finger) continuous 1:1 tracking state
    let mut mf_fingers: usize = 0;
    let mut mf_start_cx: f32 = 0.0;
    let mut mf_start_cy: f32 = 0.0;
    let mut mf_start_spread: f32 = 0.1;
    let mut mf_dx: f32 = 0.0;
    let mut mf_dy: f32 = 0.0;
    let mut mf_scale: f32 = 1.0;
    let mut mf_dir = String::new();
    let mut mf_action = String::new();
    let mut mf_last_emit = Instant::now();
    let mut mf_settle_until = Instant::now();
    let thresholds = classify::Thresholds::from_env();
    let debug = std::env::var("HALCYON_GESTURE_DEBUG").is_ok();
    if debug {
        eprintln!("gesture thresholds: {:?}", thresholds);
    }
    let mut gestures_conf: HashMap<String, String> = HashMap::new();
    let mut last_conf_load = Instant::now() - Duration::from_secs(10);
    load_gestures_conf(&mut last_conf_load, &mut gestures_conf);

    loop {
        match device.fetch_events() {
            Ok(events) => {
                for event in events {
                    if event.event_type() == EventType::ABSOLUTE {
                        let code = event.code();
                        let value = event.value();

                        if code == AbsoluteAxisType::ABS_MT_SLOT.0 {
                            current_slot = value;
                        } else if code == AbsoluteAxisType::ABS_MT_TRACKING_ID.0 {
                            if value != -1 {
                                active_slots.insert(current_slot, SlotState { x: None, y: None });
                                if active_slots.len() == 1 {
                                    is_left_edge = false;
                                    is_right_edge = false;
                                    is_top_edge = false;
                                    start_x = None;
                                    start_y = None;
                                    last_trigger_x = None;
                                    last_trigger_y = None;
                                    multi_finger_detected = false;
                                    triggered_action = false;
                                    music_disabled = Path::new("/dev/shm/touchpad_music_gestures_disabled").exists();
                                    pad_disabled = touchpad_disabled();
                                } else if active_slots.len() > 1 {
                                    multi_finger_detected = true;
                                }
                            } else {
                                active_slots.remove(&current_slot);
                                if active_slots.is_empty() {
                                    if mf_fingers >= 3 {
                                        write_gesture_state("end", mf_fingers, mf_dx, mf_dy, mf_scale, &mf_dir, &mf_action);
                                        mf_fingers = 0;
                                        mf_dir.clear();
                                        mf_action.clear();
                                    }
                                    is_left_edge = false;
                                    is_right_edge = false;
                                    is_top_edge = false;
                                    start_x = None;
                                    start_y = None;
                                    last_trigger_x = None;
                                    last_trigger_y = None;
                                    multi_finger_detected = false;
                                    triggered_action = false;
                                }
                            }
                        } else if code == AbsoluteAxisType::ABS_MT_POSITION_X.0 {
                            let len = active_slots.len();
                            if let Some(slot) = active_slots.get_mut(&current_slot) {
                                slot.x = Some(value);
                                if len == 1 && !multi_finger_detected && !pad_disabled {
                                    let x = value;
                                    let slot_y = slot.y;

                                    if let (None, Some(sy)) = (start_x, slot_y) {
                                        start_x = Some(x);
                                        start_y = Some(sy);
                                        last_trigger_x = Some(x);
                                        last_trigger_y = Some(sy);
                                        is_left_edge = x < left_edge;
                                        is_right_edge = x > right_edge;
                                        is_top_edge = sy < top_edge;
                                    }

                                    if is_top_edge {
                                        if let Some(lx) = last_trigger_x {
                                            let delta_x = x - lx;
                                            if delta_x.abs() >= b_threshold {
                                                if delta_x > 0 {
                                                    println!("Gesture: Brightness Up");
                                                    brightness("up");
                                                } else {
                                                    println!("Gesture: Brightness Down");
                                                    brightness("down");
                                                }
                                                last_trigger_x = Some(x);
                                            }
                                        }
                                    }
                                }
                            }
                        } else if code == AbsoluteAxisType::ABS_MT_POSITION_Y.0 {
                            let len = active_slots.len();
                            if let Some(slot) = active_slots.get_mut(&current_slot) {
                                slot.y = Some(value);
                                if len == 1 && !multi_finger_detected && !pad_disabled {
                                    let y = value;
                                    let slot_x = slot.x;

                                    if let (None, Some(sx)) = (start_y, slot_x) {
                                        start_x = Some(sx);
                                        start_y = Some(y);
                                        last_trigger_x = Some(sx);
                                        last_trigger_y = Some(y);
                                        is_left_edge = sx < left_edge;
                                        is_right_edge = sx > right_edge;
                                        is_top_edge = y < top_edge;
                                    }

                                    if let Some(ly) = last_trigger_y {
                                        let delta_y = y - ly;
                                        if is_right_edge {
                                            if delta_y.abs() >= v_threshold {
                                                if delta_y < 0 {
                                                    println!("Gesture: Volume Up");
                                                    fire_s("wpctl", &["set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "2%+"]);
                                                } else {
                                                    println!("Gesture: Volume Down");
                                                    fire_s("wpctl", &["set-volume", "@DEFAULT_AUDIO_SINK@", "2%-"]);
                                                }
                                                last_trigger_y = Some(y);
                                            }
                                        } else if is_left_edge
                                            && !music_disabled && !triggered_action && delta_y.abs() >= v_threshold * 2 {
                                                if delta_y < 0 {
                                                    println!("Gesture: Media Next");
                                                    fire_s("playerctl", &["next"]);
                                                } else {
                                                    println!("Gesture: Media Prev");
                                                    fire_s("playerctl", &["previous"]);
                                                }
                                                triggered_action = true;
                                            }
                                    }
                                }
                            }
                        }
                    } else if event.event_type() == EventType::SYNCHRONIZATION && event.code() == 0 && !pad_disabled {
                        // Real-time 3-finger & 4-finger tracking on SYN_REPORT
                        let pts: Vec<(f32, f32)> = active_slots
                            .values()
                            .filter_map(|s| match (s.x, s.y) {
                                (Some(vx), Some(vy)) => Some((vx as f32 / max_x as f32, vy as f32 / max_y as f32)),
                                _ => None,
                            })
                            .collect();

                        let n = pts.len();
                        if n == 3 || n == 4 {
                            load_gestures_conf(&mut last_conf_load, &mut gestures_conf);
                            let cx = pts.iter().map(|p| p.0).sum::<f32>() / n as f32;
                            let cy = pts.iter().map(|p| p.1).sum::<f32>() / n as f32;
                            let spread = (pts
                                .iter()
                                .map(|p| ((p.0 - cx).powi(2) + (p.1 - cy).powi(2)).sqrt())
                                .sum::<f32>()
                                / n as f32)
                                .max(0.04);

                            if mf_fingers != n {
                                mf_fingers = n;
                                mf_start_cx = cx;
                                mf_start_cy = cy;
                                mf_start_spread = spread;
                                mf_dx = 0.0;
                                mf_dy = 0.0;
                                mf_scale = 1.0;
                                mf_dir.clear();
                                mf_action.clear();
                                write_gesture_state("begin", n, 0.0, 0.0, 1.0, "", "");
                                mf_last_emit = Instant::now();
                                mf_settle_until = Instant::now() + Duration::from_millis(SETTLE_MS);
                                continue;
                            }

                            if Instant::now() < mf_settle_until {
                                // fingers are still landing: keep re-basing so touch-down jitter is not movement
                                mf_start_cx = cx;
                                mf_start_cy = cy;
                                mf_start_spread = spread;
                                continue;
                            }

                            // Normalized finger travel (1.0 == 26% of touchpad span)
                            mf_dx = (cx - mf_start_cx) / 0.26;
                            mf_dy = (cy - mf_start_cy) / 0.26;
                            mf_scale = (spread / mf_start_spread).clamp(0.35, 2.2);

                            if mf_dir.is_empty() {
                                // pinch or swipe? see classify.rs: a pinch wins whenever the fingers moved against
                                // each other by a fair share of the movement, so hand drift no longer turns it into a swipe
                                let radial = spread - mf_start_spread;
                                let kind = classify::classify(&thresholds, radial, cx - mf_start_cx, cy - mf_start_cy);
                                if let Some(name) = kind.name() {
                                    mf_dir = name.to_string();
                                    let key = format!("g{}-{}", n, name);
                                    mf_action = gestures_conf.get(&key).cloned().unwrap_or_else(|| "none".into());
                                    if debug {
                                        eprintln!(
                                            "{} fingers: {} (radial {:.3}, drift {:.3},{:.3}) -> {}",
                                            n, name, radial, cx - mf_start_cx, cy - mf_start_cy, mf_action
                                        );
                                    }
                                }
                            }

                            if mf_last_emit.elapsed() >= Duration::from_millis(16) {
                                write_gesture_state("update", n, mf_dx, mf_dy, mf_scale, &mf_dir, &mf_action);
                                mf_last_emit = Instant::now();
                            }
                        } else if mf_fingers >= 3 && active_slots.is_empty() {
                            write_gesture_state("end", mf_fingers, mf_dx, mf_dy, mf_scale, &mf_dir, &mf_action);
                            mf_fingers = 0;
                            mf_dir.clear();
                            mf_action.clear();
                        }
                    }
                }
            }
            Err(e) => {
                eprintln!("Error reading events: {:?}", e);
                if e.raw_os_error() == Some(19) {
                    std::process::exit(1);
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    }
}
