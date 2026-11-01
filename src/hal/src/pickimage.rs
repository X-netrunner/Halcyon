//! hal pick-image [START]: open a graphical file browser for an image and print the chosen path (nothing if cancelled).
//! START = a folder or file to start from (default ~/Pictures). Used by Settings for the profile picture.

use crate::util;
use std::path::Path;
use std::process::{Command, Stdio};

const IMAGES: &str = "*.png *.jpg *.jpeg *.webp *.gif *.bmp *.svg";

/// "~" and "~/x" mean the home folder (the shell did that for the bash script, but the island passes the text as it is typed).
fn expand_tilde(s: &str, home: &str) -> String {
    match s.strip_prefix('~') {
        Some(rest) => format!("{}{}", home, rest),
        None => s.to_string(),
    }
}

fn dialog(cmd: &str, args: &[&str]) {
    // stdout is the answer (the chosen path) and goes straight through; the dialog's own noise is dropped
    let _ = Command::new(cmd).args(args).stdin(Stdio::null()).stderr(Stdio::null()).status();
}

pub fn run(args: &[String]) -> i32 {
    let home = util::home();
    let pictures = format!("{}/Pictures", home);
    let mut start = match args.first() {
        Some(a) if !a.is_empty() => expand_tilde(a, &home),
        _ => pictures.clone(),
    };
    if !Path::new(&start).exists() {
        start = pictures;
    }
    if !Path::new(&start).exists() {
        start = home;
    }
    if Path::new(&start).is_dir() {
        start = format!("{}/", start.strip_suffix('/').unwrap_or(&start));
    }
    let title = "--title=Choose a profile picture";
    if util::command_exists("zenity") {
        dialog(
            "zenity",
            &[
                "--file-selection",
                title,
                &format!("--filename={}", start),
                &format!("--file-filter=Images | {}", IMAGES),
                "--file-filter=All files | *",
            ],
        );
    } else if util::command_exists("kdialog") {
        dialog("kdialog", &["--getopenfilename", &start, &format!("{}|Images", IMAGES)]);
    } else if util::command_exists("yad") {
        dialog("yad", &["--file", title, &format!("--filename={}", start)]);
    } else {
        util::notify("Halcyon", "No file browser found (sudo pacman -S zenity)", None, 5000);
    }
    0
}

#[cfg(test)]
mod tests {
    use super::expand_tilde;

    #[test]
    fn tilde_becomes_home() {
        assert_eq!(expand_tilde("~", "/home/u"), "/home/u");
        assert_eq!(expand_tilde("~/Pictures/a.png", "/home/u"), "/home/u/Pictures/a.png");
        assert_eq!(expand_tilde("/tmp/x", "/home/u"), "/tmp/x");
    }
}
