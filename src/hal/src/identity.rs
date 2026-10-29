//! hal identity: 5 lines for user identity
//! 1. username
//! 2. full name (from /etc/passwd)
//! 3. hostname
//! 4. OS pretty name
//! 5. laptop model

use std::env;
use std::fs;
use std::path::Path;

fn get_username() -> String {
    if let Ok(u) = env::var("USER") {
        if !u.is_empty() {
            return u;
        }
    }
    // Fallback: read /proc/self/loginuid or id -un
    crate::util::out("id", &["-un"]).trim().to_string()
}

fn get_full_name(user: &str) -> String {
    if let Ok(passwd) = fs::read_to_string("/etc/passwd") {
        for line in passwd.lines() {
            let fields: Vec<&str> = line.split(':').collect();
            if fields.first() == Some(&user) && fields.len() > 4 {
                let gecos = fields[4];
                return gecos.split(',').next().unwrap_or("").to_string();
            }
        }
    }
    String::new()
}

fn get_hostname() -> String {
    if let Ok(h) = fs::read_to_string("/etc/hostname") {
        let trimmed = h.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }
    crate::util::out("uname", &["-n"]).trim().to_string()
}

fn get_os_pretty_name() -> String {
    for p in &["/etc/os-release", "/usr/lib/os-release"] {
        if let Ok(content) = fs::read_to_string(Path::new(p)) {
            for line in content.lines() {
                if let Some(val) = line.strip_prefix("PRETTY_NAME=") {
                    let unquoted = val.trim_matches('"').trim_matches('\'');
                    if !unquoted.is_empty() {
                        return unquoted.to_string();
                    }
                }
            }
        }
    }
    "Arch Linux".to_string()
}

fn get_laptop_model() -> String {
    if let Ok(model) = fs::read_to_string("/sys/devices/virtual/dmi/id/product_name") {
        return model.trim().to_string();
    }
    String::new()
}

pub fn run() -> i32 {
    let u = get_username();
    let full = get_full_name(&u);
    let host = get_hostname();
    let os = get_os_pretty_name();
    let model = get_laptop_model();

    println!("{}", u);
    println!("{}", full);
    println!("{}", host);
    println!("{}", os);
    println!("{}", model);
    0
}
