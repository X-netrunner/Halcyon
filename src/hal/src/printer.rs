//! hal printer [ARGS]: printer management helper. Opens system-config-printer when it is installed, otherwise the CUPS web
//! page (http://localhost:631), starting cups.service first when it is not running; says what to install when there is nothing.

use crate::util;
use std::os::unix::process::CommandExt;
use std::process::Command;

fn note(title: &str, body: &str, icon: &str) {
    util::notify_app("Printer Manager", title, body, Some(icon));
}

fn cups_active() -> bool {
    util::ok("systemctl", &["is-active", "--quiet", "cups.service"])
}

fn open_cups_web() {
    if !cups_active() {
        note(
            "Starting CUPS...",
            "Attempting to start local print service.",
            "printer",
        );
        // as the user first, then through sudo; -n: there is no terminal to ask on, so it must not wait for a password
        if !util::ok("systemctl", &["start", "cups.service"]) {
            let _ = util::ok("sudo", &["-n", "systemctl", "start", "cups.service"]);
        }
    }
    if !util::ok("xdg-open", &["http://localhost:631/admin"]) {
        let _ = util::ok("xdg-open", &["http://localhost:631/"]);
    }
}

pub fn run(args: &[String]) -> i32 {
    if util::command_exists("system-config-printer") {
        if !cups_active() {
            let _ = util::ok("systemctl", &["start", "cups.service"]);
        }
        let err = Command::new("system-config-printer").args(args).exec();
        eprintln!("printer: could not start system-config-printer: {}", err);
        return 1;
    }
    if util::command_exists("lpstat") {
        note(
            "Opening CUPS Print Manager",
            "Connecting to localhost:631 in your browser...",
            "printer",
        );
        open_cups_web();
    } else if util::out("systemctl", &["list-unit-files"]).contains("cups.service") {
        note(
            "Starting CUPS",
            "Starting cups.service and opening browser manager...",
            "printer",
        );
        open_cups_web();
    } else {
        // the \n is written out as two characters on purpose: notify-send turns it into a line break
        note(
            "Printer Tools Needed",
            "Install CUPS and graphical manager:\\nsudo pacman -S cups system-config-printer",
            "dialog-information",
        );
        println!("To configure printers in Halcyon, install CUPS and the GUI manager:");
        println!("  sudo pacman -S cups system-config-printer cups-pdf");
        println!("  sudo systemctl enable --now cups.service");
    }
    0
}
