//! hal build-shader [branch|sky]

use std::fs;
use std::path::{Path, PathBuf};

fn find_qsb() -> Option<PathBuf> {
    if crate::util::command_exists("qsb") {
        return Some(PathBuf::from("qsb"));
    }
    if crate::util::command_exists("qsb-qt6") {
        return Some(PathBuf::from("qsb-qt6"));
    }
    let static_paths = [
        "/usr/lib/qt6/bin/qsb",
        "/usr/lib64/qt6/bin/qsb",
        "/usr/lib/x86_64-linux-gnu/qt6/bin/qsb",
        "/usr/lib/aarch64-linux-gnu/qt6/bin/qsb",
    ];
    for p in &static_paths {
        let path = Path::new(p);
        if path.is_file() {
            return Some(path.to_path_buf());
        }
    }
    None
}

pub fn run(args: &[String]) -> i32 {
    let name = args.first().map(|s| s.as_str()).unwrap_or("branch");
    if name != "branch" && name != "sky" {
        eprintln!("usage: hal build-shader [branch|sky]");
        return 2;
    }

    let home = crate::util::home();
    let src = PathBuf::from(&home).join(format!(".config/Halcyon/quickshell/island/{}.frag", name));
    let dir = PathBuf::from(&home).join(".cache/halcyon");
    let out = dir.join(format!("{}.frag.qsb", name));

    let _ = fs::create_dir_all(&dir);

    if let (Ok(out_meta), Ok(src_meta)) = (fs::metadata(&out), fs::metadata(&src)) {
        if out_meta.len() > 0 {
            if let (Ok(out_time), Ok(src_time)) = (out_meta.modified(), src_meta.modified()) {
                if src_time <= out_time {
                    println!("{}", out.display());
                    return 0;
                }
            }
        }
    }

    let qsb = match find_qsb() {
        Some(q) => q,
        None => return 1,
    };

    let ok = crate::util::ok(
        &qsb.to_string_lossy(),
        &["--qt6", "-o", &out.to_string_lossy(), &src.to_string_lossy()],
    );

    if ok && out.is_file() {
        if let Ok(meta) = fs::metadata(&out) {
            if meta.len() > 0 {
                println!("{}", out.display());
                return 0;
            }
        }
    }

    1
}
