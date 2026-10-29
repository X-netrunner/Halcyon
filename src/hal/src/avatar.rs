//! hal avatar [path]: print the path of the user's profile picture or nothing

use std::env;
use std::fs;
use std::path::PathBuf;

fn expand_home(p: &str, home: &str) -> PathBuf {
    if p.starts_with('~') {
        PathBuf::from(home).join(p.trim_start_matches('~').trim_start_matches('/'))
    } else {
        PathBuf::from(p)
    }
}

pub fn run(args: &[String]) -> i32 {
    let home = crate::util::home();
    let mut candidates = Vec::new();

    if let Some(arg) = args.first() {
        if !arg.trim().is_empty() {
            candidates.push(expand_home(arg.trim(), &home));
        }
    }

    let h = PathBuf::from(&home);
    candidates.push(h.join(".face"));
    candidates.push(h.join(".face.icon"));

    let user = env::var("USER").unwrap_or_else(|_| crate::util::out("id", &["-un"]).trim().to_string());
    if !user.is_empty() {
        candidates.push(PathBuf::from(format!("/var/lib/AccountsService/icons/{}", user)));
    }

    let extensions = ["png", "jpg", "jpeg", "webp"];
    for ext in &extensions {
        candidates.push(h.join(format!(".config/Halcyon/avatar.{}", ext)));
    }
    for ext in &extensions {
        candidates.push(h.join(format!("Pictures/avatar.{}", ext)));
    }

    for path in candidates {
        if path.is_file() {
            if let Ok(meta) = fs::metadata(&path) {
                if meta.len() > 0 {
                    println!("{}", path.display());
                    return 0;
                }
            }
        }
    }

    0
}
