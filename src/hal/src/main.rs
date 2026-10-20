//! hal: Halcyon helpers, Rust ports of shell scripts.
//!
//!   hal input ...          <- scripts/input-conf.sh          (touchpad gestures + mouse buttons)
//!   hal wsnav ...          <- scripts/ws-nav.sh              (next / previous workspace)
//!   hal brightness ...     <- scripts/brightness.sh          (screen brightness from top-edge gesture)
//!   hal backlight ...      <- scripts/backlight.sh           (screen / keyboard light driver layer)
//!   hal caffeine ...       <- scripts/caffeine.sh            (screen wake inhibitor)
//!   hal extra-dim ...      <- scripts/extra-dim.sh           (minimum brightness toggle)
//!   hal tool-state         <- scripts/tool-state.sh          (live tool status JSON)
//!   hal supertap           <- scripts/super_tap.sh           (launcher open on Super tap)
//!   hal close              <- scripts/close.sh               (close top overlay or active window)
//!   hal gestures ...       <- scripts/toggle_gestures.sh     (toggle music gestures)
//!   hal nightlight ...     <- scripts/toggle_nightlight.sh   (toggle blue-light filter)
//!   hal wifips ...         <- scripts/toggle_wifi_powersave.sh (toggle Wi-Fi power saving)
//!   hal touchpad ...       <- scripts/toggle_touchpad.sh     (toggle touchpad device)
//!   hal idle-dim ...       <- scripts/idle-dim.sh            (idle dim / undim)
//!   hal numlock ...        <- scripts/numlock.sh             (numlock status / toggle)
//!   hal notif-guard        <- scripts/notif-guard.sh         (kill conflicting notification daemons)
//!   hal charge-limit ...   <- quickshell/island/scripts/charge-limit.sh
//!   hal bt-battery         <- quickshell/island/scripts/bt-battery.sh
//!   hal ping

mod btbattery;
mod caffeine;
mod chargelimit;
mod close;
mod extradim;
mod gestures;
mod idledim;
mod input;
pub mod light;
mod nightlight;
mod notifguard;
mod numlock;
mod supertap;
mod toolstate;
mod touchpad;
mod util;
mod wifips;
mod wsnav;

fn usage() {
    eprintln!(
        "hal: Halcyon helpers\n\
         \x20 input conf | mice | set ID ACTION [CMD] | reset [gestures|mouse|all] | run ID\n\
         \x20 wsnav next | prev | gesture-right | gesture-left | gesture4-right | gesture4-left | wheel-up | wheel-down\n\
         \x20 brightness up|down [percent]\n\
         \x20 backlight set <backlight|leds> <device> <raw> | best-screen | kbd\n\
         \x20 caffeine on [minutes] | off | toggle | status\n\
         \x20 extra-dim toggle | on | off | status\n\
         \x20 tool-state\n\
         \x20 supertap\n\
         \x20 close\n\
         \x20 gestures toggle | status\n\
         \x20 nightlight on | off | toggle | temp <K> | status\n\
         \x20 wifips on | off | toggle | status | apply\n\
         \x20 touchpad toggle | status\n\
         \x20 idle-dim dim | undim\n\
         \x20 numlock status | toggle | on | off\n\
         \x20 notif-guard\n\
         \x20 charge-limit status | toggle | on | off\n\
         \x20 bt-battery\n\
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
        Some("caffeine") => caffeine::run(rest),
        Some("extra-dim") | Some("extradim") => extradim::run(rest),
        Some("tool-state") | Some("toolstate") => toolstate::run(),
        Some("supertap") => supertap::run(),
        Some("close") => close::run(),
        Some("gestures") | Some("toggle-gestures") => gestures::run(rest),
        Some("nightlight") | Some("toggle-nightlight") => nightlight::run(rest),
        Some("wifips") | Some("wifi-powersave") => wifips::run(rest),
        Some("touchpad") | Some("toggle-touchpad") => touchpad::run(rest),
        Some("idle-dim") | Some("idledim") => idledim::run(rest),
        Some("numlock") => numlock::run(rest),
        Some("notif-guard") | Some("notifguard") => notifguard::run(),
        Some("charge-limit") | Some("chargelimit") => chargelimit::run(rest),
        Some("bt-battery") | Some("btbattery") => btbattery::run(),
        Some("ping") => 0,
        _ => {
            usage();
            2
        }
    };
    std::process::exit(code);
}
