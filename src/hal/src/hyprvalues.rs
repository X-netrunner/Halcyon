//! hal hyprvalues: fast single-batch query of Hyprland options for Settings.qml / shell.qml.
//! Replaces 20 sequential `hyprctl getoption` calls with subshells in scripts/hypr-values.sh.

use crate::util::out;
use std::collections::HashMap;

const OPTIONS: &[(&str, &str)] = &[
    ("borderSize", "general:border_size"),
    ("resizeOnBorder", "general:resize_on_border"),
    ("layout", "general:layout"),
    ("activeOpacity", "decoration:active_opacity"),
    ("inactiveOpacity", "decoration:inactive_opacity"),
    ("dimInactive", "decoration:dim_inactive"),
    ("dimStrength", "decoration:dim_strength"),
    ("blurSize", "decoration:blur:size"),
    ("blurPasses", "decoration:blur:passes"),
    ("followMouse", "input:follow_mouse"),
    ("repeatDelay", "input:repeat_delay"),
    ("repeatRate", "input:repeat_rate"),
    ("sensitivity", "input:sensitivity"),
    ("accelProfile", "input:accel_profile"),
    ("leftHanded", "input:left_handed"),
    ("naturalScroll", "input:touchpad:natural_scroll"),
    ("tapToClick", "input:touchpad:tap_to_click"),
    ("disableTyping", "input:touchpad:disable_while_typing"),
    ("focusOnActivate", "misc:focus_on_activate"),
    ("resizeAnim", "misc:animate_manual_resizes"),
];

fn clean_num(n: &str) -> String {
    if n.contains('.') {
        let trimmed = n.trim_end_matches('0').trim_end_matches('.');
        trimmed.to_string()
    } else {
        n.to_string()
    }
}

pub fn parse_hypr_batch(raw: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for chunk in raw.split("\n\n") {
        let chunk = chunk.trim();
        if chunk.is_empty() {
            continue;
        }
        let opt_name = match extract_string(chunk, "\"option\":") {
            Some(o) => o,
            None => continue,
        };

        if let Some(val) = extract_num(chunk, "\"int\":") {
            map.insert(opt_name, clean_num(&val));
        } else if let Some(val) = extract_num(chunk, "\"float\":") {
            map.insert(opt_name, clean_num(&val));
        } else if let Some(val) = extract_bool(chunk, "\"bool\":") {
            map.insert(opt_name, val);
        } else if let Some(val) = extract_string(chunk, "\"str\":") {
            map.insert(opt_name, format!("\"{}\"", val));
        }
    }
    map
}

fn extract_string(s: &str, key: &str) -> Option<String> {
    let idx = s.find(key)?;
    let rem = &s[idx + key.len()..];
    let start_quote = rem.find('"')? + 1;
    let end_quote = rem[start_quote..].find('"')? + start_quote;
    Some(rem[start_quote..end_quote].to_string())
}

fn extract_bool(s: &str, key: &str) -> Option<String> {
    let idx = s.find(key)?;
    let rem = s[idx + key.len()..].trim_start();
    if rem.starts_with("true") {
        Some("true".to_string())
    } else if rem.starts_with("false") {
        Some("false".to_string())
    } else {
        None
    }
}

fn extract_num(s: &str, key: &str) -> Option<String> {
    let idx = s.find(key)?;
    let rem = s[idx + key.len()..].trim_start();
    let mut end = 0;
    for (i, c) in rem.char_indices() {
        if c.is_ascii_digit() || c == '.' || (i == 0 && c == '-') {
            end = i + c.len_utf8();
        } else if i > 0 {
            break;
        }
    }
    if end > 0 {
        Some(rem[..end].to_string())
    } else {
        None
    }
}

pub fn run() -> i32 {
    let batch_cmd = OPTIONS
        .iter()
        .map(|(_, opt)| format!("getoption {}", opt))
        .collect::<Vec<_>>()
        .join(" ; ");

    let raw = out("hyprctl", &["-j", "--batch", &batch_cmd]);
    if raw.trim().is_empty() {
        println!("{{}}");
        return 0;
    }

    let parsed = parse_hypr_batch(&raw);
    let mut parts = Vec::new();
    for (json_key, opt_name) in OPTIONS {
        if let Some(val) = parsed.get(*opt_name) {
            parts.push(format!("\"{}\":{}", json_key, val));
        }
    }

    println!("{{{}}}", parts.join(","));
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clean_num() {
        assert_eq!(clean_num("1.000000"), "1");
        assert_eq!(clean_num("0.900000"), "0.9");
        assert_eq!(clean_num("0.070000"), "0.07");
        assert_eq!(clean_num("250"), "250");
        assert_eq!(clean_num("-1.500"), "-1.5");
    }

    #[test]
    fn test_parse_hypr_batch() {
        let sample = r#"
{"option": "general:border_size", "int": 2, "set": true }

{"option": "general:layout", "str": "dwindle", "set": true }

{"option": "general:resize_on_border", "bool": true, "set": true }

{"option": "decoration:active_opacity", "float": 0.850000, "set": true }
"#;
        let map = parse_hypr_batch(sample);
        assert_eq!(map.get("general:border_size").unwrap(), "2");
        assert_eq!(map.get("general:layout").unwrap(), "\"dwindle\"");
        assert_eq!(map.get("general:resize_on_border").unwrap(), "true");
        assert_eq!(map.get("decoration:active_opacity").unwrap(), "0.85");
    }
}
