//! hal mem : what Halcyon really costs in RAM
//! hal mem-where [pid] : WHERE Quickshell's memory is (split by kind)

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};

fn proc_rss(pid: u32) -> Option<u64> {
    let path = format!("/proc/{}/status", pid);
    let file = File::open(path).ok()?;
    let reader = BufReader::new(file);
    for line in reader.lines().map_while(Result::ok) {
        if let Some(val) = line.strip_prefix("VmRSS:") {
            let kb: u64 = val.split_whitespace().next()?.parse().ok()?;
            return Some(kb / 1024);
        }
    }
    None
}

fn proc_pss(pid: u32) -> Option<u64> {
    let path = format!("/proc/{}/smaps_rollup", pid);
    let file = File::open(path).ok()?;
    let reader = BufReader::new(file);
    for line in reader.lines().map_while(Result::ok) {
        if let Some(val) = line.strip_prefix("Pss:") {
            let kb: u64 = val.split_whitespace().next()?.parse().ok()?;
            return Some(kb / 1024);
        }
    }
    None
}

struct DiscoveredProc {
    pid: u32,
    comm: String,
    cmdline: String,
}

fn scan_proc() -> Vec<DiscoveredProc> {
    let mut procs = Vec::new();
    if let Ok(entries) = fs::read_dir("/proc") {
        for entry in entries.flatten() {
            if let Some(name) = entry.file_name().to_str() {
                if let Ok(pid) = name.parse::<u32>() {
                    let base = entry.path();
                    let comm = fs::read_to_string(base.join("comm"))
                        .unwrap_or_default()
                        .trim()
                        .to_string();
                    let cmdline = fs::read_to_string(base.join("cmdline"))
                        .unwrap_or_default()
                        .replace('\0', " ");
                    procs.push(DiscoveredProc { pid, comm, cmdline });
                }
            }
        }
    }
    procs
}

fn run_mem() -> i32 {
    println!("{:<22} {:>6} {:>9} {:>9}", "process", "pid", "RSS MB", "PSS MB");
    let mut total_rss = 0u64;
    let mut total_pss = 0u64;

    let mut show = |label: &str, pid: u32| {
        if let Some(rss) = proc_rss(pid) {
            let pss_str = match proc_pss(pid) {
                Some(p) => {
                    total_pss += p;
                    p.to_string()
                }
                None => "?".to_string(),
            };
            total_rss += rss;
            println!("{:<22} {:>6} {:>9} {:>9}", label, pid, rss, pss_str);
        }
    };

    let all_procs = scan_proc();

    for p in &all_procs {
        if p.comm == "Hyprland" {
            show("Hyprland", p.pid);
        }
    }

    for p in &all_procs {
        if p.comm == "quickshell" || p.comm == "qs" {
            let sub = p.cmdline
                .split("quickshell/")
                .nth(1)
                .and_then(|s| s.split_whitespace().next())
                .unwrap_or("");
            let label = if sub.is_empty() {
                "quickshell".to_string()
            } else {
                format!("quickshell({})", sub)
            };
            show(&label, p.pid);
        }
    }

    let helpers = [
        "hx",
        "power-manager",
        "touchpad-gestures",
        "cava",
        "hypridle",
        "wl-paste",
        "polkit-kde-authent",
        "nm-applet",
        "blueman-applet",
    ];
    for n in &helpers {
        let mut count = 0;
        for p in &all_procs {
            if count >= 4 {
                break;
            }
            let is_match = p.comm == *n
                || (n.len() > 15 && p.comm.starts_with(&n[..15]))
                || p.cmdline.contains(&format!("/{}", n))
                || p.cmdline.starts_with(n);
            if is_match {
                show(n, p.pid);
                count += 1;
            }
        }
    }

    println!("{:<22} {:>6} {:>9} {:>9}", "TOTAL", "", total_rss, total_pss);
    0
}

fn classify_mapping(name: &str) -> &'static str {
    if name == "[anon]" || name == "[heap]" {
        "anon / heap (program data)"
    } else if name.contains("/memfd:")
        || name.contains("/dev/shm")
        || name.contains("wayland")
        || name.contains("/SYSV")
        || name.contains("(deleted)")
    {
        "shm / memfd (window buffers)"
    } else if name.contains("/dev/dri")
        || name.contains("/dev/nvidia")
        || name.contains("/dev/kfd")
        || name.contains("/dev/shm/nv")
    {
        "gpu device memory"
    } else if name.contains("mesa")
        || name.contains("radeon")
        || name.contains("amdgpu")
        || name.contains("vulkan")
        || name.contains("nvidia")
        || name.contains("libGL")
        || name.contains("libEGL")
        || name.contains("libgbm")
        || name.contains("libdrm")
        || name.contains("iris")
        || name.contains("llvm")
        || name.contains("libLLVM")
        || name.contains("dri/")
    {
        "gpu drivers (libraries)"
    } else if name.contains("libQt6") || name.contains("/qt6/") || name.contains("qml") {
        "Qt libraries and QML plugins"
    } else if name.ends_with(".ttf") || name.ends_with(".otf") || name.ends_with(".ttc") || name.contains("fonts") {
        "fonts"
    } else if name.contains(".so") {
        "other libraries"
    } else if name.contains("icons")
        || name.contains(".cache")
        || name.contains(".png")
        || name.contains(".svg")
    {
        "icons / cache files"
    } else {
        "other"
    }
}

fn run_mem_where(args: &[String]) -> i32 {
    let pid = match args.first().and_then(|s| s.parse::<u32>().ok()) {
        Some(p) => p,
        None => {
            let out = crate::util::out("pgrep", &["-x", "quickshell"]);
            match out.lines().next().and_then(|s| s.trim().parse::<u32>().ok()) {
                Some(p) => p,
                None => {
                    eprintln!("no quickshell process found (pass a pid)");
                    return 1;
                }
            }
        }
    };

    let smaps_path = format!("/proc/{}/smaps", pid);
    let file = match File::open(&smaps_path) {
        Ok(f) => f,
        Err(_) => {
            eprintln!("cannot read /proc/{}/smaps", pid);
            return 1;
        }
    };

    let cmdline = fs::read_to_string(format!("/proc/{}/cmdline", pid))
        .unwrap_or_default()
        .replace('\0', " ");
    let short_cmd: String = cmdline.chars().take(90).collect();
    println!("pid {}: {}", pid, short_cmd);

    let reader = BufReader::with_capacity(64 * 1024, file);
    let mut totals: HashMap<&'static str, f64> = HashMap::new();
    let mut total_pss = 0.0;
    let mut current_kind = "anon / heap (program data)";

    for line in reader.lines().map_while(Result::ok) {
        if line.contains('-') && line.contains(" 0") {
            let mut parts = line.split_whitespace();
            let name = parts.nth(5).unwrap_or("[anon]");
            current_kind = classify_mapping(name);
        } else if let Some(val) = line.strip_prefix("Pss:") {
            if let Some(kb_str) = val.split_whitespace().next() {
                if let Ok(kb) = kb_str.parse::<f64>() {
                    *totals.entry(current_kind).or_insert(0.0) += kb;
                    total_pss += kb;
                }
            }
        }
    }

    let mut list: Vec<(&'static str, f64)> = totals.into_iter().collect();
    list.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    for (k, kb) in list {
        println!("{:7.1} MB  {}", kb / 1024.0, k);
    }
    println!("{:7.1} MB  TOTAL (PSS)", total_pss / 1024.0);
    println!();
    let rss_mb = proc_rss(pid).unwrap_or(0);
    println!("RSS (counts shared pages in full): {} MB", rss_mb);

    0
}

pub fn run(args: &[String]) -> i32 {
    let sub = args.first().map(|s| s.as_str()).unwrap_or("");
    if sub == "where" {
        run_mem_where(&args[1..])
    } else {
        run_mem()
    }
}
