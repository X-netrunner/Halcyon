//! hal: Halcyon helpers, Rust ports of a few shell scripts.
//!
//!   hal input ...       <- scripts/input-conf.sh   (touchpad gestures + mouse buttons: what they do)
//!   hal wsnav ...       <- scripts/ws-nav.sh       (next / previous workspace)
//!   hal brightness ...  <- scripts/brightness.sh   (screen brightness from the top-edge gesture)
//!   hal backlight ...   <- scripts/backlight.sh    (screen / keyboard light driver layer)
//!
//! The scripts are still there: each one runs `hal` when it is built and falls back to its own shell
//! code when it is not, so nothing breaks before the helpers are (re)built.

mod input;
mod light;
mod util;
mod wsnav;

fn usage() {
    eprintln!(
        "hal: Halcyon helpers\n\
         \x20 input conf | mice | set ID ACTION [CMD] | reset [gestures|mouse|all] | run ID\n\
         \x20 wsnav next | prev | gesture-right | gesture-left | gesture4-right | gesture4-left | wheel-up | wheel-down\n\
         \x20 brightness up|down [percent]\n\
         \x20 backlight set <backlight|leds> <device> <raw> | best-screen | kbd\n\
         \x20 ping"
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rest: &[String] = if args.is_empty() { &[] } else { &args[1..] };
    let code = match args.first().map(|s| s.as_str()) {
        Some("input") => input::run(rest),
        Some("wsnav") => wsnav::run(rest),
        Some("brightness") => light::brightness(rest),
        Some("backlight") => light::backlight(rest),
        Some("ping") => 0,
        _ => {
            usage();
            2
        }
    };
    std::process::exit(code);
}
