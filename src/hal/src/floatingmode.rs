//! hal floating-mode on | off | toggle | status

use std::fs;
use std::path::PathBuf;

fn paths() -> (PathBuf, PathBuf) {
    let state = crate::util::state_dir();
    let _ = fs::create_dir_all(&state);
    (state.join("float-all"), state.join("float-all.list"))
}

fn is_on() -> bool {
    let (flag, _) = paths();
    crate::util::first_line(&flag).as_deref() == Some("1")
}

struct ClientInfo {
    address: String,
    floating: bool,
    class: String,
    title: String,
    pinned: bool,
    ws_id: f64,
}

fn is_natural_floating(class: &str, title: &str) -> bool {
    const NATURAL_CLASSES: &[&str] = &[
        "mpv",
        "pavucontrol",
        "blueman-manager",
        "nm-connection-editor",
        "qalculate-gtk",
        "gnome-calculator",
        "org.gnome.Calculator",
        "file-roller",
        "org.gnome.FileRoller",
        "ark",
        "hyprland-share-picker",
        "xdg-desktop-portal-gtk",
        "zenity",
        "yad",
        "org.kde.polkit-kde-authentication-agent-1",
        "polkit-gnome-authentication-agent-1",
        "org.quickshell",
    ];
    if title.contains("Picture-in-Picture") || class.contains("pinentry") {
        return true;
    }
    NATURAL_CLASSES.contains(&class)
}

fn get_clients() -> Vec<ClientInfo> {
    let mut result = Vec::new();
    let json_text = crate::util::out("hyprctl", &["clients", "-j"]);
    if let Some(crate::json::Json::Arr(items)) = crate::json::parse(&json_text) {
        for item in items {
            let mapped = item.get("mapped") == Some(&crate::json::Json::Bool(true));
            let ws_id = item
                .get("workspace")
                .and_then(|w| w.num("id"))
                .unwrap_or(0.0);
            let pinned = item.get("pinned") == Some(&crate::json::Json::Bool(true));

            if mapped && ws_id > 0.0 && !pinned {
                if let Some(addr) = item.str("address") {
                    let floating = item.get("floating") == Some(&crate::json::Json::Bool(true));
                    let class = item.str("class").unwrap_or("").to_string();
                    let title = item.str("title").unwrap_or("").to_string();
                    result.push(ClientInfo {
                        address: addr.to_string(),
                        floating,
                        class,
                        title,
                        pinned,
                        ws_id,
                    });
                }
            }
        }
    }
    result
}

fn toggle_float(addr: &str) {
    let arg = format!("hl.dsp.window.float({{ window = \"address:{}\" }})", addr);
    let _ = crate::util::ok("hyprctl", &["dispatch", &arg]);
}

fn set_rule(enabled: bool) {
    let arg = format!(
        "if halcyon_float_all then halcyon_float_all:set_enabled({}) end",
        if enabled { "true" } else { "false" }
    );
    let _ = crate::util::ok("hyprctl", &["eval", &arg]);
}

fn mode_on() -> i32 {
    let (flag, list_file) = paths();
    let _ = fs::write(&flag, "1\n");
    set_rule(true);

    let mut saved = String::new();
    let clients = get_clients();
    for c in clients {
        if !c.floating && !c.pinned && c.ws_id > 0.0 {
            toggle_float(&c.address);
            saved.push_str(&format!("{}\n", c.address));
        }
    }
    let _ = fs::write(&list_file, saved);
    0
}

fn mode_off() -> i32 {
    let (flag, list_file) = paths();
    let _ = fs::write(&flag, "0\n");
    set_rule(false);

    let saved_text = fs::read_to_string(&list_file).unwrap_or_default();
    let saved_addrs: Vec<&str> = saved_text
        .lines()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .collect();

    let clients = get_clients();
    for c in clients {
        if c.floating && !c.pinned && c.ws_id > 0.0 {
            let should_unfloat = saved_addrs.contains(&c.address.as_str())
                || !is_natural_floating(&c.class, &c.title);
            if should_unfloat {
                toggle_float(&c.address);
            }
        }
    }

    let _ = fs::write(&list_file, "");
    0
}

pub fn run(args: &[String]) -> i32 {
    let action = args.first().map(|s| s.as_str()).unwrap_or("status");
    match action {
        "on" => mode_on(),
        "off" => mode_off(),
        "toggle" => {
            if is_on() {
                mode_off()
            } else {
                mode_on()
            }
        }
        "status" => {
            println!("{}", if is_on() { "on" } else { "off" });
            0
        }
        _ => {
            eprintln!("usage: hal floating-mode on|off|toggle|status");
            2
        }
    }
}
