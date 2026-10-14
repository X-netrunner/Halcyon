//! Adaptive limits sampler and status (Rust port of startup-view.py adapt-*).
//! Replaces running python3 every 5 minutes in the background.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const ADAPT_DAYS: f64 = 3.0;
const ADAPT_MIN_SAMPLES: usize = 150;
const ADAPT_KEEP_DAYS: f64 = 14.0;
const ADAPT_RAM_HEADROOM: f64 = 1.25;
const ADAPT_CPU_HEADROOM: f64 = 1.5;
const ADAPT_RAM_RANGE: (i32, i32) = (300, 1500);
const ADAPT_CPU_RANGE: (i32, i32) = (3, 30);

fn state_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".local/state/island")
}

fn adapt_log_path() -> PathBuf {
    state_dir().join("adaptive.tsv")
}

fn is_halcyon_proc(pid: i32) -> bool {
    let mut b = String::with_capacity(256);
    if let Ok(mut f) = File::open(format!("/proc/{}/comm", pid)) {
        if f.read_to_string(&mut b).is_ok() {
            let comm = b.trim();
            if matches!(comm, "quickshell" | "Hyprland" | "hx" | "power-manager" | "touchpad-gestures" | "cava" | "swww-daemon" | "awww-daemon") {
                return true;
            }
        }
    }
    b.clear();
    if let Ok(mut f) = File::open(format!("/proc/{}/cmdline", pid)) {
        if f.read_to_string(&mut b).is_ok() {
            if b.contains("/Halcyon/") || b.contains(".config/Halcyon") || b.contains("halcyon") {
                return true;
            }
        }
    }
    false
}

fn read_proc_ticks(pid: i32) -> Option<u64> {
    let mut buf = String::with_capacity(512);
    let mut f = File::open(format!("/proc/{}/stat", pid)).ok()?;
    f.read_to_string(&mut buf).ok()?;
    let r = buf.rfind(')')?;
    let rest = &buf[r + 2..];
    let mut it = rest.split_whitespace();
    let ut: u64 = it.nth(11)?.parse().ok()?;
    let st: u64 = it.next()?.parse().ok()?;
    Some(ut + st)
}

fn read_proc_pss_mb(pid: i32, page_mb: f64) -> f64 {
    let mut buf = String::with_capacity(1024);
    if let Ok(mut f) = File::open(format!("/proc/{}/smaps_rollup", pid)) {
        if f.read_to_string(&mut buf).is_ok() {
            for l in buf.lines() {
                if let Some(r) = l.strip_prefix("Pss:") {
                    if let Some(kb) = r.split_whitespace().next().and_then(|x| x.parse::<f64>().ok()) {
                        return kb / 1024.0;
                    }
                }
            }
        }
    }
    buf.clear();
    if let Ok(mut f) = File::open(format!("/proc/{}/statm", pid)) {
        if f.read_to_string(&mut buf).is_ok() {
            if let Some(pages) = buf.split_whitespace().nth(1).and_then(|x| x.parse::<f64>().ok()) {
                return pages * page_mb;
            }
        }
    }
    0.0
}

pub fn sample() {
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    let page_mb = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as f64 / 1048576.0;
    let ncpu = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1) as f64;

    let mut hal_pids = Vec::new();
    if let Ok(rd) = std::fs::read_dir("/proc") {
        for e in rd.flatten() {
            if let Some(pid) = e.file_name().to_str().and_then(|n| n.parse::<i32>().ok()) {
                if is_halcyon_proc(pid) {
                    hal_pids.push(pid);
                }
            }
        }
    }

    let mut t0_ticks = HashMap::new();
    for &pid in &hal_pids {
        if let Some(ticks) = read_proc_ticks(pid) {
            t0_ticks.insert(pid, ticks);
        }
    }

    let t0 = Instant::now();
    std::thread::sleep(Duration::from_millis(400));
    let dt = t0.elapsed().as_secs_f64().max(0.05);

    let mut total_cpu_ticks = 0u64;
    let mut total_pss_mb = 0.0;

    for &pid in &hal_pids {
        if let Some(t1) = read_proc_ticks(pid) {
            if let Some(&t0) = t0_ticks.get(&pid) {
                total_cpu_ticks += t1.saturating_sub(t0);
            }
            total_pss_mb += read_proc_pss_mb(pid, page_mb);
        }
    }

    let cpu_pct = (total_cpu_ticks as f64 / hz / dt * 100.0) / ncpu;
    let ram_mb = total_pss_mb;

    let now_ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);

    let path = adapt_log_path();
    std::fs::create_dir_all(state_dir()).ok();

    // Prune if too large
    let mut rows = read_rows();
    if rows.len() > 4500 {
        let keep_from = rows.len().saturating_sub(4000);
        let trimmed = &rows[keep_from..];
        let mut tmp_path = path.clone();
        tmp_path.set_extension("tmp");
        if let Ok(mut f) = File::create(&tmp_path) {
            for (t, r, c) in trimmed {
                let _ = writeln!(f, "{:.0}\t{:.1}\t{:.1}", t, r, c);
            }
            std::fs::rename(&tmp_path, &path).ok();
        }
    }

    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{:.0}\t{:.1}\t{:.1}", now_ts, ram_mb, cpu_pct);
    }
}

fn read_rows() -> Vec<(f64, f64, f64)> {
    let mut rows = Vec::new();
    let now_ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let path = adapt_log_path();
    if let Ok(mut f) = File::open(path) {
        let mut buf = String::new();
        if f.read_to_string(&mut buf).is_ok() {
            for ln in buf.lines() {
                let mut parts = ln.split('\t');
                if let (Some(t_str), Some(r_str), Some(c_str)) = (parts.next(), parts.next(), parts.next()) {
                    if let (Ok(t), Ok(r), Ok(c)) = (t_str.parse::<f64>(), r_str.parse::<f64>(), c_str.parse::<f64>()) {
                        if now_ts - t <= ADAPT_KEEP_DAYS * 86400.0 {
                            rows.push((t, r, c));
                        }
                    }
                }
            }
        }
    }
    rows
}

fn pct95(mut vals: Vec<f64>) -> f64 {
    if vals.is_empty() {
        return 0.0;
    }
    vals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let idx = ((vals.len() as f64) * 0.95) as usize;
    vals[idx.min(vals.len() - 1)]
}

pub fn status() {
    let rows = read_rows();
    if rows.is_empty() {
        println!("{}", serde_json::json!({
            "state": "learning",
            "need_days": ADAPT_DAYS,
            "days": 0.0,
            "samples": 0,
            "ram_limit": serde_json::Value::Null,
            "cpu_limit": serde_json::Value::Null,
            "base_ram": serde_json::Value::Null,
            "base_cpu": serde_json::Value::Null
        }));
        return;
    }

    let days = ((rows.last().unwrap().0 - rows.first().unwrap().0) / 86400.0 * 100.0).round() / 100.0;
    let samples = rows.len();

    if days >= ADAPT_DAYS && samples >= ADAPT_MIN_SAMPLES {
        let br = pct95(rows.iter().map(|r| r.1).collect());
        let bc = pct95(rows.iter().map(|r| r.2).collect());
        let ram_target = ((-(-br * ADAPT_RAM_HEADROOM / 50.0).floor()) * 50.0) as i32;
        let cpu_target = (-(-(bc * ADAPT_CPU_HEADROOM + 1.0).floor())) as i32;

        let ram_limit = ram_target.clamp(ADAPT_RAM_RANGE.0, ADAPT_RAM_RANGE.1);
        let cpu_limit = cpu_target.clamp(ADAPT_CPU_RANGE.0, ADAPT_CPU_RANGE.1);

        println!("{}", serde_json::json!({
            "state": "ready",
            "need_days": ADAPT_DAYS,
            "days": days,
            "samples": samples,
            "base_ram": br.round(),
            "base_cpu": (bc * 10.0).round() / 10.0,
            "ram_limit": ram_limit,
            "cpu_limit": cpu_limit
        }));
    } else {
        println!("{}", serde_json::json!({
            "state": "learning",
            "need_days": ADAPT_DAYS,
            "days": days,
            "samples": samples,
            "ram_limit": serde_json::Value::Null,
            "cpu_limit": serde_json::Value::Null,
            "base_ram": serde_json::Value::Null,
            "base_cpu": serde_json::Value::Null
        }));
    }
}

pub fn reset() {
    let path = adapt_log_path();
    let _ = std::fs::remove_file(path);
    println!("{{\"ok\": true}}");
}
