//! hal idle-dim dim | undim

use crate::light;
use std::fs;
use std::path::Path;
use std::thread::sleep;
use std::time::Duration;

const FLAG_FILE: &str = "/dev/shm/halcyon-dim";

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("dim");
    let flag = Path::new(FLAG_FILE);

    match cmd {
        "dim" => {
            if flag.exists() {
                return 0;
            }
            let (sdev, scur, _) = light::best_screen_info().unwrap_or_default();
            let mut record = String::new();
            if !sdev.is_empty() {
                record.push_str(&format!("screen {} {}\n", sdev, scur));
            }
            let kbds = light::kbd_list_info();
            for (kdev, kcur, _) in &kbds {
                record.push_str(&format!("kbd {} {}\n", kdev, kcur));
            }
            if record.is_empty() {
                return 0;
            }
            let _ = fs::write(flag, &record);

            // Turn off keyboard lights
            for (kdev, kcur, _) in &kbds {
                if *kcur > 0 {
                    light::backlight_set_direct("leds", kdev, "0");
                }
            }

            // Fade screen down to 1
            if !sdev.is_empty() && scur > 1 {
                let steps = 8;
                for i in 1..=steps {
                    let v = scur + (1 - scur) * i / steps;
                    light::backlight_set_direct("backlight", &sdev, &v.to_string());
                    sleep(Duration::from_millis(50));
                }
            }
            0
        }
        "undim" => {
            if !flag.exists() {
                return 0;
            }
            if let Ok(body) = fs::read_to_string(flag) {
                for line in body.lines() {
                    let parts: Vec<&str> = line.split_whitespace().collect();
                    if parts.len() >= 3 {
                        let kind = parts[0];
                        let dev = parts[1];
                        let val = parts[2];
                        match kind {
                            "screen" => light::backlight_set_direct("backlight", dev, val),
                            "kbd" => light::backlight_set_direct("leds", dev, val),
                            _ => {}
                        }
                    }
                }
            }
            let _ = fs::remove_file(flag);
            0
        }
        _ => {
            eprintln!("usage: hal idle-dim dim | undim");
            2
        }
    }
}
