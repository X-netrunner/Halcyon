//! hal gpu-mode dgpu | igpu | igpu-only | status

use std::fs;
use std::path::{Path, PathBuf};

fn conf_file() -> PathBuf {
    let home = crate::util::home();
    let dir = PathBuf::from(&home).join(".config/Halcyon");
    let _ = fs::create_dir_all(&dir);
    dir.join("gpu-mode")
}

pub fn run(args: &[String]) -> i32 {
    let mode = args.first().map(|s| s.as_str()).unwrap_or("status");
    let file = conf_file();

    match mode {
        "dgpu" | "igpu" | "igpu-only" => {
            let _ = fs::write(&file, format!("{}\n", mode));
            println!("GPU mode: {} (log out and back in to apply)", mode);
            0
        }
        "status" => {
            let cur = crate::util::first_line(&file).unwrap_or_else(|| "igpu".to_string());
            println!("GPU mode: {}", cur);

            if Path::new("/proc/driver/nvidia/version").exists() {
                println!("NVIDIA driver: loaded");
            } else {
                println!("NVIDIA driver: NOT loaded (dgpu mode is ignored without it)");
            }

            let hypr_pids = crate::util::out("pgrep", &["-x", "Hyprland"]);
            for line in hypr_pids.lines() {
                if let Ok(pid) = line.trim().parse::<u32>() {
                    let env_path = format!("/proc/{}/environ", pid);
                    if let Ok(data) = fs::read(env_path) {
                        for item in data.split(|&b| b == 0) {
                            if let Ok(s) = std::str::from_utf8(item) {
                                if s.starts_with("AQ_DRM_DEVICES=") {
                                    println!("{}", s);
                                }
                            }
                        }
                    }
                }
            }
            0
        }
        _ => {
            eprintln!("usage: hal gpu-mode dgpu|igpu|igpu-only|status");
            2
        }
    }
}
