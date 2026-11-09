//! hal clip-store: clipboard history storage guard

use std::env;
use std::io::{self, Read, Write};
use std::process::{Command, Stdio};

pub fn run() -> i32 {
    let guard = env::var("CLIP_GUARD").unwrap_or_else(|_| "1".to_string());
    if guard != "0" {
        let types = crate::util::out("wl-paste", &["--list-types"]).to_lowercase();
        if types.contains("passwordmanagerhint") {
            let mut buf = [0u8; 8192];
            let mut stdin = io::stdin();
            while let Ok(n) = stdin.read(&mut buf) {
                if n == 0 {
                    break;
                }
            }
            return 0;
        }
    }

    let mut child = match Command::new("cliphist")
        .arg("store")
        .stdin(Stdio::piped())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            eprintln!("clip-store: failed to run cliphist: {}", e);
            return 1;
        }
    };

    if let Some(mut child_stdin) = child.stdin.take() {
        let mut buf = [0u8; 8192];
        let mut stdin = io::stdin();
        while let Ok(n) = stdin.read(&mut buf) {
            if n == 0 {
                break;
            }
            if child_stdin.write_all(&buf[..n]).is_err() {
                break;
            }
        }
    }

    match child.wait() {
        Ok(status) => status.code().unwrap_or(0),
        Err(_) => 1,
    }
}
