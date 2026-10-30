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
//!   hal hypr-values        <- quickshell/island/scripts/hypr-values.sh
//!   hal osd-watch          <- scripts/osd-watch.sh
//!   hal tools ...          <- scripts/halcyon-tools.py       (colour picker, measure, zoom, snippets, windows: the ones on a key)
//!   hal identity           <- quickshell/island/scripts/identity.sh
//!   hal avatar [path]      <- scripts/avatar.sh
//!   hal clip-store         <- scripts/clip-store.sh
//!   hal toggle-power       <- scripts/toggle_power.sh
//!   hal toggle-livewp ...  <- scripts/toggle_livewallpaper.sh
//!   hal login-status ...   <- scripts/login-status.sh
//!   hal login-watchdog     <- scripts/login-watchdog.sh
//!   hal reload             <- scripts/reload.sh
//!   hal cheatsheet         <- scripts/cheatsheet.sh
//!   hal power-manager ...  <- scripts/power_manager_select.sh
//!   hal floating-mode ...  <- scripts/floating-mode.sh
//!   hal audio-set ...      <- quickshell/island/scripts/audio-set.sh
//!   hal build-shader ...   <- quickshell/island/scripts/build-shader.sh
//!   hal mem [where [pid]]  <- scripts/halcyon-mem.sh, halcyon-mem-where.sh
//!   hal gpu-mode ...       <- scripts/gpu-mode.sh
//!   hal screenshot-area    <- scripts/screenshot-area.sh
//!   hal cache-trim ...     <- scripts/cache-trim.py
//!   hal timeline ...       <- scripts/timeline.py
//!   hal system-profile ... <- scripts/halcyon-control.py (deep system audit & knowledge engine)
//!   hal ping

mod audioset;
mod avatar;
mod btbattery;
mod buildshader;
mod cachetrim;
mod caffeine;
mod chargelimit;
mod cheatsheet;
mod clipstore;
mod close;
mod extradim;
mod filemap;
mod floatingmode;
mod gestures;
mod gpumode;
mod hyprvalues;
mod idledim;
mod identity;
mod input;
mod json;
pub mod light;
mod loginstatus;
mod loginwatchdog;
mod mem;
mod nightlight;
mod notifguard;
mod numlock;
mod osdwatch;
mod powermanagerselect;
mod reload;
mod screenshotarea;
mod supertap;
mod systemprofile;
mod timeline;
mod togglelivewp;
mod togglepower;
mod toolstate;
mod tools;
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
         \x20 tools colorpick [hex|rgb|hsl] | measure | zoom in|out|reset|toggle | snippets pick|list|copy|type | windows last|next|prev|pick|list\n\
         \x20 identity\n\
         \x20 avatar [path]\n\
         \x20 clip-store\n\
         \x20 toggle-power\n\
         \x20 toggle-livewallpaper [file|sky]\n\
         \x20 login-status [status|enable-lock|remove-lock]\n\
         \x20 login-watchdog\n\
         \x20 reload\n\
         \x20 cheatsheet\n\
         \x20 power-manager-select <mgr> [quiet]\n\
         \x20 floating-mode [on|off|toggle|status]\n\
         \x20 audio-set <sink|source> <name>\n\
         \x20 build-shader [branch|sky]\n\
         \x20 mem [where [pid]]\n\
         \x20 gpu-mode [dgpu|igpu|igpu-only|status]\n\
         \x20 screenshot-area\n\
         \x20 cache-trim [--force|--status]\n\
         \x20 timeline [conf|status]\n\
         \x20 system-profile [summary|json|learn|test]\n\
         \x20 system-test\n\
         \x20 filemap [generate|search <query>|locate <cat>|summary]\n\
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
        Some("hypr-values") | Some("hyprvalues") => hyprvalues::run(),
        Some("osd-watch") | Some("osdwatch") => osdwatch::run(),
        Some("tools") => tools::run(rest),
        Some("identity") => identity::run(),
        Some("avatar") => avatar::run(rest),
        Some("clip-store") | Some("clipstore") => clipstore::run(),
        Some("toggle-power") | Some("togglepower") => togglepower::run(),
        Some("toggle-livewallpaper") | Some("togglelivewp") => togglelivewp::run(rest),
        Some("login-status") | Some("loginstatus") => loginstatus::run(rest),
        Some("login-watchdog") | Some("loginwatchdog") => loginwatchdog::run(),
        Some("reload") => reload::run(),
        Some("cheatsheet") => cheatsheet::run(),
        Some("power-manager-select") | Some("powermanagerselect") => powermanagerselect::run(rest),
        Some("floating-mode") | Some("floatingmode") => floatingmode::run(rest),
        Some("audio-set") | Some("audioset") => audioset::run(rest),
        Some("build-shader") | Some("buildshader") => buildshader::run(rest),
        Some("mem") => mem::run(rest),
        Some("gpu-mode") | Some("gpumode") => gpumode::run(rest),
        Some("screenshot-area") | Some("screenshotarea") => screenshotarea::run(),
        Some("cache-trim") | Some("cachetrim") => cachetrim::run(rest),
        Some("timeline") => timeline::run(rest),
        Some("system-profile") | Some("systemprofile") => systemprofile::run(rest),
        Some("system-test") | Some("systemtest") | Some("test-system") => {
            let mut v = vec!["test".to_string()];
            v.extend_from_slice(rest);
            systemprofile::run(&v)
        }
        Some("filemap") | Some("system-filemap") => filemap::run(rest),
        Some("ping") => 0,
        _ => {
            usage();
            2
        }
    };
    std::process::exit(code);
}
