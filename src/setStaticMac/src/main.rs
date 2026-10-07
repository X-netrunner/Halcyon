use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::Duration;

const GREEN: &str = "\x1b[1;32m";
const RED: &str = "\x1b[1;31m";
const YELLOW: &str = "\x1b[1;33m";
const BLUE: &str = "\x1b[1;34m";
const CYAN: &str = "\x1b[1;36m";
const BOLD: &str = "\x1b[1m";
const RESET: &str = "\x1b[0m";

fn print_banner() {
    println!(
        "\n{BLUE}┌────────────────────────────────────────┐\n\
         │  {CYAN}{BOLD}Network MAC Address Manager (makeStatic){RESET}{BLUE}  │\n\
         └────────────────────────────────────────┘{RESET}\n"
    );
}

fn run_cmd(cmd: &str) -> (String, String, i32) {
    let output = match Command::new("sh").arg("-c").arg(cmd).output() {
        Ok(o) => o,
        Err(e) => return ("".to_string(), e.to_string(), -1),
    };
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    let code = output.status.code().unwrap_or(-1);
    (stdout, stderr, code)
}

struct WifiInfo {
    name: String,
    uuid: String,
    ssid: String,
    device: String,
}

fn get_active_wifi_info() -> Option<WifiInfo> {
    let (stdout, _, code) = run_cmd("nmcli -t -f ACTIVE,TYPE,NAME,UUID connection show");
    if code != 0 {
        return None;
    }

    let mut active_name = None;
    let mut active_uuid = None;
    for line in stdout.lines() {
        let parts: Vec<&str> = line.split(':').collect();
        if parts.len() >= 4 {
            let active = parts[0];
            let conn_type = parts[1];
            let uuid = parts[parts.len() - 1];
            let name = parts[2..parts.len() - 1].join(":");
            if active == "yes" && conn_type == "802-11-wireless" {
                active_name = Some(name);
                active_uuid = Some(uuid.to_string());
                break;
            }
        }
    }

    let (active_name, active_uuid) = match (active_name, active_uuid) {
        (Some(n), Some(u)) => (n, u),
        _ => return None,
    };

    let (stdout_dev, _, code_dev) = run_cmd("nmcli -t -f DEVICE,TYPE,STATE device");
    let mut device = "wlan0".to_string();
    if code_dev == 0 {
        for line in stdout_dev.lines() {
            let parts: Vec<&str> = line.split(':').collect();
            if parts.len() >= 3 {
                let dev = parts[0];
                let dev_type = parts[1];
                let state = parts[2];
                if dev_type == "wifi" && state == "connected" {
                    device = dev.to_string();
                    break;
                }
            }
        }
    }

    let (stdout_ssid, _, code_ssid) =
        run_cmd(&format!("nmcli -g 802-11-wireless.ssid connection show '{}'", active_uuid));
    let ssid = if code_ssid == 0 && !stdout_ssid.is_empty() {
        stdout_ssid
    } else {
        active_name.clone()
    };

    Some(WifiInfo {
        name: active_name,
        uuid: active_uuid,
        ssid,
        device,
    })
}

fn resolve_connection(conn_identifier: &str) -> Option<(String, String, String)> {
    let (stdout, _, code) = run_cmd("nmcli -t -f NAME,UUID,TYPE connection show");
    if code != 0 {
        return None;
    }
    for line in stdout.lines() {
        let parts: Vec<&str> = line.split(':').collect();
        if parts.len() >= 3 {
            let conn_type = parts[parts.len() - 1];
            let uuid = parts[parts.len() - 2];
            let name = parts[..parts.len() - 2].join(":");
            if conn_type == "802-11-wireless"
                && (name == conn_identifier || uuid == conn_identifier)
            {
                let (stdout_ssid, _, code_ssid) =
                    run_cmd(&format!("nmcli -g 802-11-wireless.ssid connection show '{}'", uuid));
                let ssid = if code_ssid == 0 && !stdout_ssid.is_empty() {
                    stdout_ssid
                } else {
                    name.clone()
                };
                return Some((name, uuid.to_string(), ssid));
            }
        }
    }
    None
}

fn get_permanent_mac(device: &str) -> Option<String> {
    let (stdout, _, code) = run_cmd(&format!("ip link show {}", device));
    if code != 0 {
        return None;
    }
    let perm_regex = Regex::new(r"permaddr\s+([0-9a-fA-F:]{17})").unwrap();
    if let Some(caps) = perm_regex.captures(&stdout) {
        return Some(caps[1].to_lowercase());
    }
    let ether_regex = Regex::new(r"link/ether\s+([0-9a-fA-F:]{17})").unwrap();
    if let Some(caps) = ether_regex.captures(&stdout) {
        return Some(caps[1].to_lowercase());
    }
    None
}

fn get_current_mac(device: &str) -> Option<String> {
    let (stdout, _, code) = run_cmd(&format!("ip link show {}", device));
    if code != 0 {
        return None;
    }
    let ether_regex = Regex::new(r"link/ether\s+([0-9a-fA-F:]{17})").unwrap();
    if let Some(caps) = ether_regex.captures(&stdout) {
        return Some(caps[1].to_lowercase());
    }
    None
}

fn find_iwd_config_file(ssid: &str) -> Option<PathBuf> {
    let iwd_dir = Path::new("/var/lib/iwd");
    if !iwd_dir.exists() {
        return None;
    }
    for ext in [".psk", ".open", ".8021x"] {
        let path = iwd_dir.join(format!("{}{}", ssid, ext));
        if path.exists() {
            return Some(path);
        }
    }
    None
}

fn modify_iwd_config(file_path: &Path, mac_address: Option<&str>) {
    let content = match fs::read_to_string(file_path) {
        Ok(c) => c,
        Err(_) => return,
    };

    let mut new_lines = Vec::new();
    let mut in_settings = false;
    let mut settings_found = false;
    let mut override_set = false;

    for line in content.lines() {
        let stripped = line.trim();
        if stripped.starts_with('[') && stripped.ends_with(']') {
            let section = &stripped[1..stripped.len() - 1].trim();
            if *section == "Settings" {
                in_settings = true;
                settings_found = true;
            } else {
                if in_settings {
                    if let Some(mac) = mac_address {
                        if !override_set {
                            new_lines.push(format!("AddressOverride={}", mac));
                            override_set = true;
                        }
                    }
                }
                in_settings = false;
            }
        }

        if in_settings && stripped.starts_with("AddressOverride") {
            if let Some(mac) = mac_address {
                new_lines.push(format!("AddressOverride={}", mac));
                override_set = true;
            }
            continue;
        }

        new_lines.push(line.to_string());
    }

    if !settings_found {
        if let Some(mac) = mac_address {
            new_lines.push("".to_string());
            new_lines.push("[Settings]".to_string());
            new_lines.push(format!("AddressOverride={}", mac));
        }
    } else if let Some(mac) = mac_address {
        if !override_set {
            new_lines.push(format!("AddressOverride={}", mac));
        }
    }

    let mut out = new_lines.join("\n");
    if !out.ends_with('\n') {
        out.push('\n');
    }
    let _ = fs::write(file_path, out);
}

fn show_status() {
    println!("{BOLD}Checking connection status...{RESET}\n");
    let wifi_info = match get_active_wifi_info() {
        Some(w) => w,
        None => {
            println!("{YELLOW}No active Wi-Fi connection detected via nmcli.{RESET}");
            return;
        }
    };

    let ssid = &wifi_info.ssid;
    let device = &wifi_info.device;
    let filepath = match find_iwd_config_file(ssid) {
        Some(p) => p,
        None => {
            println!(
                "{YELLOW}Connected to SSID '{ssid}' (profile: {name}) but no iwd configuration found in /var/lib/iwd/.{RESET}",
                ssid = ssid,
                name = wifi_info.name
            );
            return;
        }
    };

    let mut override_mac = None;
    if let Ok(content) = fs::read_to_string(&filepath) {
        let mut in_settings = false;
        for line in content.lines() {
            let stripped = line.trim();
            if stripped.starts_with('[') && stripped.ends_with(']') {
                in_settings = &stripped[1..stripped.len() - 1].trim() == &"Settings";
            } else if in_settings && stripped.starts_with("AddressOverride") {
                let parts: Vec<&str> = stripped.split('=').collect();
                if parts.len() >= 2 {
                    override_mac = Some(parts[1].trim().to_string());
                }
            }
        }
    }

    let current_mac = get_current_mac(device).unwrap_or_else(|| "Unknown".to_string());
    let perm_mac = get_permanent_mac(device).unwrap_or_else(|| "Unknown".to_string());

    println!("{BOLD}Active Wi-Fi SSID:    {RESET} {GREEN}{}{RESET}", ssid);
    println!("{BOLD}Profile Name:          {RESET} {}", wifi_info.name);
    println!("{BOLD}Interface Device:      {RESET} {}", device);
    println!("{BOLD}Current MAC Address:   {RESET} {YELLOW}{}{RESET}", current_mac);
    println!("{BOLD}Permanent MAC Address: {RESET} {CYAN}{}{RESET}", perm_mac);

    if let Some(ref override_val) = override_mac {
        println!("{BOLD}Configured Policy:     {RESET} {GREEN}Static Override ({}){RESET}", override_val);
        if current_mac.eq_ignore_ascii_case(override_val) {
            println!("\n{GREEN}✓ Connection is currently using the configured STATIC MAC address.{RESET}");
        } else {
            println!(
                "\n{YELLOW}! Connection is using MAC {}, expected {}. A reconnect might be required.{RESET}",
                current_mac, override_val
            );
        }
    } else {
        println!("{BOLD}Configured Policy:     {RESET} {YELLOW}Randomized (default){RESET}");
        println!("\n{YELLOW}! Connection is currently using a DYNAMIC/RANDOMIZED MAC address.{RESET}");
    }
}

fn list_connections() {
    println!("{BOLD}Listing all Wi-Fi Connection Profiles (iwd):{RESET}\n");
    let iwd_dir = Path::new("/var/lib/iwd");
    if !iwd_dir.exists() {
        println!("{RED}Error: /var/lib/iwd directory not found.{RESET}");
        return;
    }

    println!(
        "{BOLD}{:<40} {:<15} {:<25}{RESET}",
        "SSID", "PROFILE TYPE", "MAC OVERRIDE POLICY"
    );
    println!("{}", "-".repeat(85));

    let wifi_info = get_active_wifi_info();
    let active_ssid = wifi_info.as_ref().map(|w| w.ssid.as_str());

    let mut entries = Vec::new();
    if let Ok(rd) = fs::read_dir(iwd_dir) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            entries.push(name);
        }
    }
    entries.sort();

    for filename in entries {
        let (name, ext) = match filename.rsplit_once('.') {
            Some((n, e)) => (n, format!(".{}", e)),
            None => continue,
        };

        if ext == ".psk" || ext == ".open" || ext == ".8021x" {
            let filepath = iwd_dir.join(&filename);
            let mut override_val = None;
            if let Ok(content) = fs::read_to_string(&filepath) {
                let mut in_settings = false;
                for line in content.lines() {
                    let stripped = line.trim();
                    if stripped.starts_with('[') && stripped.ends_with(']') {
                        in_settings = &stripped[1..stripped.len() - 1].trim() == &"Settings";
                    } else if in_settings && stripped.starts_with("AddressOverride") {
                        let parts: Vec<&str> = stripped.split('=').collect();
                        if parts.len() >= 2 {
                            override_val = Some(parts[1].trim().to_string());
                        }
                    }
                }
            }

            let is_active = active_ssid == Some(name);
            let prefix = if is_active { "* " } else { "  " };
            let name_padded = format!("{}{}", prefix, name);
            let name_formatted = format!("{:<40}", name_padded);
            let name_display = if is_active {
                format!("{}{}{}", GREEN, name_formatted, RESET)
            } else {
                name_formatted
            };

            let policy = if let Some(ref o) = override_val {
                format!("Static ({})", o)
            } else {
                "Randomized (default)".to_string()
            };
            let policy_color = if override_val.is_some() { GREEN } else { YELLOW };

            println!(
                "{} {:<15} {}{:<25}{}",
                name_display,
                &ext[1..],
                policy_color,
                policy,
                RESET
            );
        }
    }
}

fn print_usage() {
    println!(
        "Usage: sudo setStaticMac [options]\n\n\
         Manage static/randomized MAC addresses for Wi-Fi networks in iwd.\n\n\
         Options:\n\
           -h, --help            Show this help message and exit\n\
           -r, --restore         Restore active/specified connection to default/random MAC address behavior\n\
           -s, --status          Show current MAC address configuration and status\n\
           -l, --list            List all Wi-Fi profiles and their MAC address settings\n\
           -c, --connection SSID Specify a target SSID/connection profile name instead of the active one\n\
           -m, --mac MAC         Set a specific custom static MAC address (e.g. XX:XX:XX:XX:XX:XX)"
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "-h" || a == "--help") {
        print_banner();
        print_usage();
        return;
    }

    let is_root = unsafe { libc::geteuid() == 0 };
    if !is_root {
        println!("{RED}Error: This script must be run with sudo/root privileges.{RESET}");
        println!("Please run: {BOLD}sudo setStaticMac [options]{RESET}");
        std::process::exit(1);
    }

    print_banner();

    let mut restore = false;
    let mut status = false;
    let mut list = false;
    let mut connection_arg: Option<String> = None;
    let mut mac_arg: Option<String> = None;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-r" | "--restore" => restore = true,
            "-s" | "--status" => status = true,
            "-l" | "--list" => list = true,
            "-h" | "--help" => {
                print_usage();
                return;
            }
            "-c" | "--connection" => {
                if i + 1 < args.len() {
                    connection_arg = Some(args[i + 1].clone());
                    i += 1;
                }
            }
            "-m" | "--mac" => {
                if i + 1 < args.len() {
                    mac_arg = Some(args[i + 1].clone());
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }

    if status {
        show_status();
        return;
    }

    if list {
        list_connections();
        return;
    }

    let (target_ssid, target_uuid) = if let Some(conn) = connection_arg {
        if let Some((_, uuid, ssid)) = resolve_connection(&conn) {
            (ssid, Some(uuid))
        } else {
            (conn, None)
        }
    } else if let Some(info) = get_active_wifi_info() {
        (info.ssid, Some(info.uuid))
    } else {
        println!("{RED}Error: No active Wi-Fi connection found to modify.{RESET}\n");
        println!("Please connect to a Wi-Fi network first, or specify one using --connection.");
        std::process::exit(1);
    };

    let filepath = match find_iwd_config_file(&target_ssid) {
        Some(p) => p,
        None => {
            println!(
                "{RED}Error: Profile for SSID '{}' not found in /var/lib/iwd/.{RESET}",
                target_ssid
            );
            println!("Please verify the SSID name or connect to it once to create a profile.");
            std::process::exit(1);
        }
    };

    let mut device = "wlan0".to_string();
    if let Some(info) = get_active_wifi_info() {
        device = info.device;
    }

    if restore {
        println!(
            "Modifying profile for {GREEN}'{}'{RESET} to remove MAC override...",
            target_ssid
        );
        modify_iwd_config(&filepath, None);
        println!("{GREEN}✓ Successfully removed MAC override policy.{RESET}");
    } else {
        let mac_regex = Regex::new(r"^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$").unwrap();
        let target_mac = if let Some(ref m) = mac_arg {
            if !mac_regex.is_match(m) {
                println!("{RED}Error: Invalid MAC address format. Expected XX:XX:XX:XX:XX:XX.{RESET}");
                std::process::exit(1);
            }
            m.to_lowercase()
        } else if let Some(perm) = get_permanent_mac(&device) {
            perm
        } else {
            println!(
                "{RED}Error: Could not retrieve permanent hardware MAC address for device {}.{RESET}",
                device
            );
            std::process::exit(1);
        };

        println!(
            "Modifying profile for {GREEN}'{}'{RESET} to use static MAC {YELLOW}{}{RESET}...",
            target_ssid, target_mac
        );
        modify_iwd_config(&filepath, Some(&target_mac));
        println!("{GREEN}✓ Successfully set static MAC override policy.{RESET}");
    }

    if let Some(info) = get_active_wifi_info() {
        if info.ssid == target_ssid {
            let reconnect_uuid = target_uuid.unwrap_or(info.uuid);
            println!(
                "\nReconnecting to {GREEN}'{}'{RESET} to apply the MAC changes...",
                target_ssid
            );
            let _ = run_cmd(&format!("nmcli connection down '{}'", reconnect_uuid));
            thread::sleep(Duration::from_secs(1));
            let (_, err, code) = run_cmd(&format!("nmcli connection up '{}'", reconnect_uuid));
            if code != 0 {
                println!("{RED}Error reconnecting to '{}': {}{RESET}", target_ssid, err);
                println!("{YELLOW}Please reconnect manually using your network manager.{RESET}");
            } else {
                let new_mac = get_current_mac(&device).unwrap_or_else(|| "Unknown".to_string());
                println!("{GREEN}✓ Successfully reconnected!{RESET}");
                println!("Current MAC address is now: {YELLOW}{}{RESET}", new_mac);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mac_regex() {
        let mac_regex = Regex::new(r"^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$").unwrap();
        assert!(mac_regex.is_match("00:11:22:33:44:55"));
        assert!(mac_regex.is_match("AA:BB:CC:DD:EE:FF"));
        assert!(mac_regex.is_match("aa-bb-cc-dd-ee-ff"));
        assert!(!mac_regex.is_match("invalid-mac"));
        assert!(!mac_regex.is_match("00:11:22:33:44"));
    }
}
