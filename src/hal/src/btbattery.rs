//! hal bt-battery: battery percentage of first connected Bluetooth device

use crate::util;

pub fn run() -> i32 {
    let out = util::out("bluetoothctl", &["devices", "Connected"]);
    if out.is_empty() {
        return 0;
    }

    for line in out.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        // Typically: "Device XX:XX:XX:XX:XX:XX DeviceName"
        let mac = if parts.len() >= 2 && parts[0] == "Device" {
            parts[1]
        } else if !parts.is_empty() {
            parts[0]
        } else {
            continue;
        };

        let info = util::out("bluetoothctl", &["info", mac]);
        if info.is_empty() {
            continue;
        }

        for info_line in info.lines() {
            if info_line.contains("Battery Percentage") {
                // Extract number inside parentheses if present, e.g. "0x50 (80)"
                if let Some(open_pos) = info_line.rfind('(') {
                    if let Some(close_pos) = info_line[open_pos..].find(')') {
                        let pct_str = info_line[open_pos + 1..open_pos + close_pos].trim();
                        if !pct_str.is_empty() && pct_str.chars().all(|c| c.is_ascii_digit()) {
                            println!("{}", pct_str);
                            return 0;
                        }
                    }
                }
                // Fallback: extract last digits token
                let digits: String = info_line.chars().filter(|c| c.is_ascii_digit()).collect();
                if !digits.is_empty() {
                    println!("{}", digits);
                    return 0;
                }
            }
        }
    }

    0
}
