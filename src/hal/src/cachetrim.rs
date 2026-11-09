//! hal cache-trim [--force|--status]

use std::env;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

const ISLAND_DIRS: [&str; 4] = ["live-proxy", "live-thumbs", "clip-thumbs", "wpcolors"];
const ISLAND_MAX: u64 = 200 * 1024 * 1024;
const BUILD_MAX: u64 = 600 * 1024 * 1024;

fn state_dir() -> PathBuf {
    if let Ok(s) = env::var("HALCYON_STATE") {
        if !s.is_empty() {
            return PathBuf::from(s);
        }
    }
    crate::util::state_dir()
}

fn is_aggressive() -> bool {
    let settings_path = state_dir().join("settings.json");
    if let Ok(content) = fs::read_to_string(&settings_path) {
        if let Some(json) = crate::json::parse(&content) {
            if let Some(opt) = json.get("opt") {
                if opt.get("lazyLoad") == Some(&crate::json::Json::Bool(false)) {
                    return false;
                }
            }
        }
    }
    true
}

struct FileEntry {
    mtime: u64,
    size: u64,
    path: PathBuf,
}

fn collect_files_under(dir: &Path) -> Vec<FileEntry> {
    let mut out = Vec::new();
    if !dir.is_dir() {
        return out;
    }

    let mut stack = vec![dir.to_path_buf()];
    while let Some(current) = stack.pop() {
        if let Ok(entries) = fs::read_dir(&current) {
            for entry in entries.flatten() {
                let path = entry.path();
                if let Ok(meta) = fs::symlink_metadata(&path) {
                    if meta.is_dir() {
                        stack.push(path);
                    } else if meta.is_file() && !meta.file_type().is_symlink() {
                        let size = meta.len();
                        let mtime = meta
                            .modified()
                            .ok()
                            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                            .map(|d| d.as_secs())
                            .unwrap_or(0);
                        out.push(FileEntry { mtime, size, path });
                    }
                }
            }
        }
    }
    out
}

fn dir_size(dir: &Path) -> u64 {
    collect_files_under(dir).into_iter().map(|f| f.size).sum()
}

fn current_uid() -> u32 {
    fs::metadata("/proc/self").map(|m| m.uid()).unwrap_or(1000)
}

fn is_building() -> bool {
    let uid = current_uid().to_string();
    if crate::util::ok("pgrep", &["-u", &uid, "-x", "cargo|rustc|install.sh|update.sh"]) {
        return true;
    }
    crate::util::ok("pgrep", &["-u", &uid, "-f", "(^|/)(install|update)\\.sh( |$)"])
}

fn trim_island(island_cache: &Path) -> u64 {
    let mut files = Vec::new();
    for sub in &ISLAND_DIRS {
        let p = island_cache.join(sub);
        files.extend(collect_files_under(&p));
    }

    let total: u64 = files.iter().map(|f| f.size).sum();
    if total <= ISLAND_MAX {
        return 0;
    }

    files.sort_by_key(|f| f.mtime);
    let mut freed = 0u64;
    for f in files {
        if total.saturating_sub(freed) <= ISLAND_MAX {
            break;
        }
        if fs::remove_file(&f.path).is_ok() {
            freed += f.size;
        }
    }
    freed
}

fn trim_build(build_cache: &Path) -> u64 {
    if !build_cache.is_dir() || dir_size(build_cache) <= BUILD_MAX || is_building() {
        return 0;
    }

    let mut freed = 0u64;
    if let Ok(entries) = fs::read_dir(build_cache) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() && path.join("CACHEDIR.TAG").is_file() {
                let sz = dir_size(&path);
                if fs::remove_dir_all(&path).is_ok() {
                    freed += sz;
                }
            }
        }
    }
    freed
}

fn mb(bytes: u64) -> String {
    format!("{:.0} MB", bytes as f64 / 1_048_576.0)
}

pub fn run(args: &[String]) -> i32 {
    let home = crate::util::home();
    let cache_dir = PathBuf::from(&home).join(".cache");
    let island_cache = cache_dir.join("island");
    let build_cache = cache_dir.join("halcyon-build");

    let is_status = args.iter().any(|a| a == "--status");
    let is_force = args.iter().any(|a| a == "--force");

    if is_status {
        let island_size: u64 = ISLAND_DIRS
            .iter()
            .map(|d| dir_size(&island_cache.join(d)))
            .sum();
        let build_size = dir_size(&build_cache);
        println!(
            "island caches {} (limit {}), build cache {} (limit {}), Aggressive Memory Freeing {}",
            mb(island_size),
            mb(ISLAND_MAX),
            mb(build_size),
            mb(BUILD_MAX),
            if is_aggressive() { "on" } else { "off" }
        );
        return 0;
    }

    if !is_force && !is_aggressive() {
        return 0;
    }

    let freed = trim_island(&island_cache) + trim_build(&build_cache);
    if freed > 0 {
        println!("cache-trim: freed {}", mb(freed));
    }
    0
}
