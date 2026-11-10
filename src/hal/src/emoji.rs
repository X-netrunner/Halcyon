//! hal emoji: SUPER+PERIOD, the emoji picker in fuzzel; the chosen emoji goes to the clipboard (needs bemoji).

use crate::util;
use std::os::unix::process::CommandExt;
use std::process::Command;

pub fn run() -> i32 {
    if !util::command_exists("bemoji") {
        util::notify_app("Halcyon", "Emoji picker", "bemoji is not installed (AUR: bemoji)", Some("dialog-warning"));
        return 1;
    }
    // the backslash before the two spaces is in the original script too; kept byte for byte
    let err = Command::new("bemoji")
        .arg("-c")
        .env("BEMOJI_PICKER_CMD", "fuzzel --dmenu --prompt=Emoji>\\  --width=40 --lines=12")
        .exec();
    eprintln!("emoji: could not start bemoji: {}", err);
    1
}
