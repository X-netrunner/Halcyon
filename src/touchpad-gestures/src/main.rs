use std::collections::HashMap;
use std::fs;
use std::process::Command;
use std::time::Duration;
use std::path::Path;
use evdev::{Device, AbsoluteAxisType, EventType};

/// Run a helper without blocking the event loop (a slow playerctl must never freeze the gestures),
/// and say so on stderr (journalctl --user -u touchpad-gestures) when it is missing or fails.
fn fire(cmd: &'static str, args: Vec<String>) {
    std::thread::spawn(move || match Command::new(cmd).args(&args).output() {
        Ok(o) if o.status.success() => {}
        Ok(o) => eprintln!("{} {:?} failed: {}", cmd, args, String::from_utf8_lossy(&o.stderr).trim()),
        Err(e) => eprintln!("cannot run {}: {} (is it installed and in PATH?)", cmd, e),
    });
}
fn fire_s(cmd: &'static str, args: &[&str]) {
    fire(cmd, args.iter().map(|a| a.to_string()).collect());
}

/// Brightness goes through scripts/brightness.sh: this daemon is a systemd user service, outside the login session,
/// where a bare `brightnessctl` often cannot write the backlight. The script tries brightnessctl, a direct sysfs write
/// and logind, and prints why it failed (journalctl --user -u touchpad-gestures -e).
fn brightness(dir: &str) {
    let home = std::env::var("HOME").unwrap_or_default();
    fire(
        "bash",
        vec![format!("{}/.config/Halcyon/scripts/brightness.sh", home), dir.to_string(), "5".to_string()],
    );
}

/// A touchpad is a device that reports multitouch X/Y and is named like one. Reports why it found
/// nothing (the usual cause is not being in the `input` group) instead of silently exiting.
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
        let is_event = path.file_name().and_then(|n| n.to_str()).map_or(false, |s| s.starts_with("event"));
        if !is_event {
            continue;
        }
        match Device::open(&path) {
            Ok(device) => {
                let name = device.name().unwrap_or("").to_lowercase();
                let named = name.contains("touchpad") || name.contains("touch pad") || name.contains("trackpad");
                let has_mt = device
                    .supported_absolute_axes()
                    .map_or(false, |a| a.contains(AbsoluteAxisType::ABS_MT_POSITION_X) && a.contains(AbsoluteAxisType::ABS_MT_POSITION_Y));
                if named && has_mt {
                    return Some(device);
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => denied += 1,
            Err(_) => {}
        }
    }
    if denied > 0 {
        eprintln!("{} input devices are not readable: add yourself to the input group (sudo usermod -aG input $USER) and log in again", denied);
    }
    None
}

/// toggle_touchpad.sh disables the device in Hyprland, but we read evdev directly and would
/// still see the fingers, so honour its status file too.
fn touchpad_disabled() -> bool {
    std::env::var("XDG_RUNTIME_DIR")
        .ok()
        .and_then(|d| fs::read_to_string(format!("{}/touchpad.status", d)).ok())
        .map(|s| s.trim() == "disabled")
        .unwrap_or(false)
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

    // Retrieve boundary info
    let max_x = abs_state[AbsoluteAxisType::ABS_MT_POSITION_X.0 as usize].maximum;
    let max_y = abs_state[AbsoluteAxisType::ABS_MT_POSITION_Y.0 as usize].maximum;

    if max_x == 0 || max_y == 0 {
        eprintln!("Error: Could not retrieve valid touchpad dimensions.");
        std::process::exit(1);
    }

    println!("Touchpad dimensions: X [0, {}], Y [0, {}]", max_x, max_y);

    let left_edge = (0.04 * max_x as f64) as i32;
    let right_edge = (0.96 * max_x as f64) as i32;
    // the top strip is a bit taller than the side strips: a finger rarely starts in the first 3 mm of a touchpad
    let top_edge = (0.10 * max_y as f64) as i32;

    let v_threshold = (0.025 * max_y as f64) as i32;
    let h_threshold = (0.08 * max_x as f64) as i32;
    // brightness steps are small (5 %), so it needs a shorter slide per step than the other gestures
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
                                    // A new single touch gesture has started.
                                    // Clean reset all gesture parameters!
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
                                    
                                    // Initialize starting coordinates once both components are available
                                    if start_x.is_none() && slot_y.is_some() {
                                        let sy = slot_y.unwrap();
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

                                    // Initialize starting coordinates once both components are available
                                    if start_y.is_none() && slot_x.is_some() {
                                        let sx = slot_x.unwrap();
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
                                            // Right-edge vertical swipe -> Volume!
                                            if delta_y.abs() >= v_threshold {
                                                if delta_y < 0 { // Up (y decreases)
                                                    println!("Gesture: Volume Up");
                                                    fire_s("wpctl", &["set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", "2%+"]);
                                                } else { // Down
                                                    println!("Gesture: Volume Down");
                                                    fire_s("wpctl", &["set-volume", "@DEFAULT_AUDIO_SINK@", "2%-"]);
                                                }
                                                last_trigger_y = Some(y);
                                            }
                                        } else if is_left_edge {
                                            // Left-edge vertical swipe -> Playerctl! (only once per swipe)
                                            if !music_disabled && !triggered_action && delta_y.abs() >= v_threshold * 2 {
                                                if delta_y < 0 { // Up -> Next track
                                                    println!("Gesture: Media Next");
                                                    fire_s("playerctl", &["next"]);
                                                } else { // Down -> Prev track
                                                    println!("Gesture: Media Prev");
                                                    fire_s("playerctl", &["previous"]);
                                                }
                                                triggered_action = true;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Err(e) => {
                eprintln!("Error reading events: {:?}", e);
                // ENODEV: the device node went away. Exit so the service restarts and re-finds it.
                if e.raw_os_error() == Some(19) {
                    std::process::exit(1);
                }
                std::thread::sleep(Duration::from_secs(1));
            }
        }
    }
}
