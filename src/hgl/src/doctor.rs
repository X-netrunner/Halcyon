//! `hgl doctor [--fix]`: is this machine ready to run Windows games the way hgl runs them?
//! Checks Vulkan, multilib / 32-bit libraries, umu, gamemode and the optional extras. `--fix` installs what is missing after one confirmation.

use crate::proton;
use crate::store::Conf;
use crate::util::*;
use std::fs;
use std::process::Command;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Level {
    Ok,
    Warn,
    Fail,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mgr {
    Pacman,
    Apt,
    None,
}

pub struct Check {
    pub id: &'static str,
    pub label: String,
    pub level: Level,
    pub detail: String,
    /// packages that would fix it, for this machine's package manager
    pub pkgs: Vec<String>,
    /// a shell command (run with sudo) that would fix it
    pub cmd: Option<String>,
    /// what only the user can do
    pub manual: Option<String>,
    pub optional: bool,
}

impl Check {
    fn ok(id: &'static str, label: &str, detail: &str) -> Check {
        Check { id, label: label.into(), level: Level::Ok, detail: detail.into(), pkgs: vec![], cmd: None, manual: None, optional: false }
    }
    fn bad(id: &'static str, label: &str, level: Level, detail: &str) -> Check {
        Check { id, label: label.into(), level, detail: detail.into(), pkgs: vec![], cmd: None, manual: None, optional: false }
    }
    fn pkgs(mut self, p: Vec<String>) -> Check {
        self.pkgs = p;
        self
    }
    fn cmd(mut self, c: &str) -> Check {
        self.cmd = Some(c.into());
        self
    }
    fn manual(mut self, m: &str) -> Check {
        self.manual = Some(m.into());
        self
    }
    fn optional(mut self) -> Check {
        self.optional = true;
        self
    }
}

pub fn mgr() -> Mgr {
    if have("pacman") {
        Mgr::Pacman
    } else if have("apt-get") && have("dpkg") {
        Mgr::Apt
    } else {
        Mgr::None
    }
}

fn pkg_installed(m: Mgr, p: &str) -> bool {
    match m {
        Mgr::Pacman => run_quiet("pacman", &["-Qq", p], 10),
        Mgr::Apt => out("dpkg-query", &["-W", "-f=${Status}", p]).map(|s| s.contains("install ok installed")).unwrap_or(false),
        Mgr::None => false,
    }
}

fn names(m: Mgr, arch: &[&str], apt: &[&str]) -> Vec<String> {
    match m {
        Mgr::Pacman => arch.iter().map(|s| s.to_string()).collect(),
        Mgr::Apt => apt.iter().map(|s| s.to_string()).collect(),
        Mgr::None => vec![],
    }
}

/// PCI vendor ids of the GPUs: 0x1002 AMD, 0x10de NVIDIA, 0x8086 Intel.
fn gpu_vendors() -> Vec<String> {
    let mut v = Vec::new();
    if let Ok(rd) = fs::read_dir("/sys/class/drm") {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if n.starts_with("card") && !n.contains('-') {
                if let Ok(t) = fs::read_to_string(e.path().join("device/vendor")) {
                    let t = t.trim().to_ascii_lowercase();
                    if !v.contains(&t) {
                        v.push(t);
                    }
                }
            }
        }
    }
    v
}

fn icd_files() -> Vec<String> {
    let mut v = Vec::new();
    for d in ["/usr/share/vulkan/icd.d", "/etc/vulkan/icd.d", "/usr/local/share/vulkan/icd.d"] {
        if let Ok(rd) = fs::read_dir(d) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().to_ascii_lowercase();
                if n.ends_with(".json") {
                    v.push(n);
                }
            }
        }
    }
    if let Ok(rd) = fs::read_dir(data_home().join("vulkan/icd.d")) {
        for e in rd.flatten() {
            v.push(e.file_name().to_string_lossy().to_ascii_lowercase());
        }
    }
    v
}

fn ldconfig_p() -> String {
    for p in ["ldconfig", "/sbin/ldconfig", "/usr/sbin/ldconfig", "/usr/bin/ldconfig"] {
        if let Some(o) = out(p, &["-p"]) {
            return o;
        }
    }
    String::new()
}

pub fn run_checks() -> Vec<Check> {
    let m = mgr();
    let mut c: Vec<Check> = Vec::new();

    // tools hgl itself needs
    let missing: Vec<&str> = ["curl", "tar", "sha512sum", "systemd-run", "systemctl"].into_iter().filter(|t| !have(t)).collect();
    if missing.is_empty() {
        c.push(Check::ok("tools", "Basic tools (curl, tar, sha512sum, systemd-run)", "present"));
    } else {
        let mut ch = Check::bad("tools", "Basic tools (curl, tar, sha512sum, systemd-run)", Level::Fail, &format!("missing: {}", missing.join(", ")));
        let mut p = vec![];
        for t in &missing {
            match *t {
                "curl" => p.push("curl"),
                "tar" => p.push("tar"),
                "sha512sum" => p.push("coreutils"),
                _ => p.push("systemd"),
            }
        }
        p.dedup();
        ch = ch.pkgs(p.iter().map(|s| s.to_string()).collect());
        c.push(ch);
    }
    if !have("xz") {
        c.push(Check::bad("xz", "xz (needed to unpack Proton-CachyOS)", Level::Warn, "missing").pkgs(names(m, &["xz"], &["xz-utils"])).optional());
    }

    // 32-bit support
    match m {
        Mgr::Pacman => {
            let conf = fs::read_to_string("/etc/pacman.conf").unwrap_or_default();
            if conf.lines().any(|l| l.trim() == "[multilib]") {
                c.push(Check::ok("multilib", "multilib repository (32-bit libraries)", "enabled"));
            } else {
                c.push(
                    Check::bad("multilib", "multilib repository (32-bit libraries)", Level::Fail, "not enabled in /etc/pacman.conf")
                        .manual("Uncomment the [multilib] section (two lines) in /etc/pacman.conf, then run: sudo pacman -Syu   (hgl does not edit pacman.conf)"),
                );
            }
        }
        Mgr::Apt => {
            let fa = out("dpkg", &["--print-foreign-architectures"]).unwrap_or_default();
            if fa.split_whitespace().any(|a| a == "i386") {
                c.push(Check::ok("multilib", "i386 architecture (32-bit libraries)", "enabled"));
            } else {
                c.push(
                    Check::bad("multilib", "i386 architecture (32-bit libraries)", Level::Fail, "not enabled")
                        .cmd("dpkg --add-architecture i386 && apt-get update"),
                );
            }
        }
        Mgr::None => {}
    }
    let have_multilib = c.iter().find(|x| x.id == "multilib").map(|x| x.level == Level::Ok).unwrap_or(true);

    // Vulkan
    let ldc = ldconfig_p();
    let has64 = ldc.lines().any(|l| l.contains("libvulkan.so.1") && l.contains("x86-64"));
    let has32 = ldc.lines().any(|l| l.contains("libvulkan.so.1") && !l.contains("x86-64"));
    let icds = icd_files();
    let vendors = gpu_vendors();
    let mut vk_pkgs: Vec<String> = Vec::new();
    let mut vk_notes: Vec<String> = Vec::new();
    let mut vk_manual: Option<String> = None;
    if !has64 {
        vk_notes.push("Vulkan loader (64-bit) not found".into());
        vk_pkgs.extend(names(m, &["vulkan-icd-loader"], &["libvulkan1"]));
    }
    if !has32 {
        vk_notes.push("Vulkan loader (32-bit) not found".into());
        vk_pkgs.extend(names(m, &["lib32-vulkan-icd-loader"], &["libvulkan1:i386"]));
    }
    for v in &vendors {
        match v.as_str() {
            "0x1002" => {
                if !icds.iter().any(|f| f.contains("radeon")) {
                    vk_notes.push("no AMD Vulkan driver".into());
                    vk_pkgs.extend(names(m, &["vulkan-radeon"], &["mesa-vulkan-drivers"]));
                }
                if m == Mgr::Pacman && !pkg_installed(m, "lib32-vulkan-radeon") {
                    vk_notes.push("no 32-bit AMD Vulkan driver".into());
                    vk_pkgs.push("lib32-vulkan-radeon".into());
                }
                if m == Mgr::Apt && !pkg_installed(m, "mesa-vulkan-drivers:i386") {
                    vk_pkgs.push("mesa-vulkan-drivers:i386".into());
                }
            }
            "0x8086" => {
                if !icds.iter().any(|f| f.contains("intel")) {
                    vk_notes.push("no Intel Vulkan driver".into());
                    vk_pkgs.extend(names(m, &["vulkan-intel"], &["mesa-vulkan-drivers"]));
                }
                if m == Mgr::Pacman && !pkg_installed(m, "lib32-vulkan-intel") {
                    vk_notes.push("no 32-bit Intel Vulkan driver".into());
                    vk_pkgs.push("lib32-vulkan-intel".into());
                }
                if m == Mgr::Apt && !pkg_installed(m, "mesa-vulkan-drivers:i386") {
                    vk_pkgs.push("mesa-vulkan-drivers:i386".into());
                }
            }
            "0x10de" => {
                if !icds.iter().any(|f| f.contains("nvidia")) {
                    vk_notes.push("no NVIDIA Vulkan driver".into());
                    vk_manual = Some("Install the NVIDIA driver for your card (Arch: nvidia / nvidia-open + nvidia-utils; Debian/Ubuntu: nvidia-driver-XXX) — hgl does not pick a driver for you".into());
                }
                if m == Mgr::Pacman && !pkg_installed(m, "lib32-nvidia-utils") && icds.iter().any(|f| f.contains("nvidia")) {
                    vk_notes.push("no 32-bit NVIDIA libraries".into());
                    vk_pkgs.push("lib32-nvidia-utils".into());
                }
            }
            _ => {}
        }
    }
    if vendors.is_empty() && icds.is_empty() {
        vk_notes.push("no GPU and no Vulkan driver found".into());
    }
    vk_pkgs.sort();
    vk_pkgs.dedup();
    if !have_multilib {
        vk_pkgs.retain(|p| !p.starts_with("lib32-") && !p.ends_with(":i386"));
    }
    if vk_notes.is_empty() && !icds.is_empty() {
        c.push(Check::ok("vulkan", "Vulkan (64-bit and 32-bit)", &format!("{} driver file(s)", icds.len())));
    } else {
        let mut ch = Check::bad("vulkan", "Vulkan (64-bit and 32-bit)", Level::Fail, &vk_notes.join("; ")).pkgs(vk_pkgs);
        if let Some(mn) = vk_manual {
            ch = ch.manual(&mn);
        }
        c.push(ch);
    }

    // umu
    if have("umu-run") {
        c.push(Check::ok("umu", "umu-launcher (umu-run)", "present"));
        if crate::run::umu_runtime_ready() {
            c.push(Check::ok("umu-runtime", "Steam Runtime for umu", "downloaded"));
        } else {
            c.push(Check::bad("umu-runtime", "Steam Runtime for umu", Level::Warn, "not downloaded yet: the first game start downloads it (a few hundred MB, a few minutes); let that first start finish"));
        }
    } else {
        let mut ch = Check::bad("umu", "umu-launcher (umu-run)", Level::Fail, "umu-run not found");
        match m {
            Mgr::Pacman => ch = ch.pkgs(vec!["umu-launcher".into()]),
            _ => ch = ch.manual("Install umu-launcher from https://github.com/Open-Wine-Components/umu-launcher/releases (a .deb is published there)"),
        }
        c.push(ch);
    }

    // gamemode
    let gm_ok = have("gamemoderun");
    let gm32 = match m {
        Mgr::Pacman => pkg_installed(m, "lib32-gamemode"),
        Mgr::Apt => pkg_installed(m, "libgamemode0:i386"),
        Mgr::None => true,
    };
    if gm_ok && gm32 {
        c.push(Check::ok("gamemode", "gamemode (64-bit and 32-bit)", "present"));
    } else {
        let mut p = vec![];
        if !gm_ok {
            p.extend(names(m, &["gamemode"], &["gamemode"]));
        }
        if !gm32 && have_multilib {
            p.extend(names(m, &["lib32-gamemode"], &["libgamemode0:i386", "libgamemodeauto0:i386"]));
        }
        c.push(Check::bad("gamemode", "gamemode (64-bit and 32-bit)", Level::Warn, "missing (games run without it, but lose the per-game boost)").pkgs(p));
    }

    // optional extras
    if have("gamescope") {
        c.push(Check::ok("gamescope", "gamescope (optional)", "present").optional());
    } else {
        c.push(Check::bad("gamescope", "gamescope (optional)", Level::Warn, "not installed").pkgs(names(m, &["gamescope"], &["gamescope"])).optional());
    }
    if have("mangohud") {
        c.push(Check::ok("mangohud", "mangohud (optional)", "present").optional());
    } else {
        let mut p = names(m, &["mangohud"], &["mangohud"]);
        if have_multilib {
            p.extend(names(m, &["lib32-mangohud"], &["mangohud:i386"]));
        }
        c.push(Check::bad("mangohud", "mangohud (optional)", Level::Warn, "not installed").pkgs(p).optional());
    }
    if have("wrestool") && have("icotool") {
        c.push(Check::ok("icoutils", "icoutils (icons for added .exe games, optional)", "present").optional());
    } else {
        c.push(Check::bad("icoutils", "icoutils (icons for added .exe games, optional)", Level::Warn, "not installed").pkgs(names(m, &["icoutils"], &["icoutils"])).optional());
    }

    // kernel limit many games hit
    let mmc: u64 = fs::read_to_string("/proc/sys/vm/max_map_count").ok().and_then(|s| s.trim().parse().ok()).unwrap_or(0);
    if mmc >= 1_048_576 {
        c.push(Check::ok("max_map_count", "vm.max_map_count", &mmc.to_string()));
    } else {
        c.push(
            Check::bad("max_map_count", "vm.max_map_count", Level::Warn, &format!("{mmc} (some games crash below 1048576)"))
                .cmd("sh -c 'echo \"vm.max_map_count = 1048576\" > /etc/sysctl.d/80-halcyon-games.conf && sysctl -p /etc/sysctl.d/80-halcyon-games.conf'"),
        );
    }

    // scoped runs
    if have("systemd-run") && run_quiet("systemd-run", &["--user", "--scope", "--quiet", "-p", "CPUWeight=100", "true"], 8) {
        c.push(Check::ok("scope", "Per-game systemd scope (CPU priority, wineserver cleanup)", "works"));
    } else {
        c.push(Check::bad("scope", "Per-game systemd scope (CPU priority, wineserver cleanup)", Level::Warn, "systemd-run --user --scope failed: games still run, without their own scope").manual("Needs a systemd user session (log in through your normal session, not su/sudo)"));
    }

    // runtimes
    let cfg = Conf::load();
    match proton::resolve("", &cfg) {
        Some(r) => c.push(Check::ok("proton", "Proton runtime", &r.name)),
        None => c.push(Check::bad("proton", "Proton runtime", Level::Fail, "none installed").cmd("@hgl-proton-install")),
    }

    if have("steam") {
        c.push(Check::ok("steam", "Steam (optional, for the Steam library)", "present").optional());
    }

    // downloads (Proton, cover art, the GOG library) go through curl
    if have("curl") {
        c.push(Check::ok("curl", "curl (downloads: Proton, cover art)", "present").optional());
    } else {
        c.push(Check::bad("curl", "curl (downloads: Proton, cover art)", Level::Warn, "not installed").pkgs(names(m, &["curl"], &["curl"])).optional());
    }

    // stores: neither is needed for Steam or plain .exe games
    if have("legendary") {
        c.push(Check::ok("legendary", "legendary (Epic Games, optional)", "present").optional());
    } else {
        c.push(
            Check::bad("legendary", "legendary (Epic Games, optional)", Level::Warn, "not installed: Epic login and install are off")
                .manual("Arch: yay -S legendary (AUR). Any distribution: pipx install legendary-gl")
                .optional(),
        );
    }
    if crate::gog::gogdl_present() {
        c.push(Check::ok("gogdl", "gogdl (GOG, optional)", "present").optional());
    } else {
        c.push(
            Check::bad("gogdl", "gogdl (GOG, optional)", Level::Warn, "not installed: GOG install is off (games you installed some other way still import)")
                .manual("gogdl is Heroic's GOG downloader: github.com/Heroic-Games-Launcher/heroic-gogdl. If it is installed under another name: hgl config gogdl /path/to/gogdl")
                .optional(),
        );
    }
    c
}

fn symbol(l: Level, opt: bool) -> &'static str {
    match (l, opt) {
        (Level::Ok, _) => "ok  ",
        (Level::Warn, _) => "warn",
        (Level::Fail, _) => "FAIL",
    }
}

pub fn print_human(checks: &[Check]) {
    for ch in checks {
        let d = if ch.detail.is_empty() { String::new() } else { format!(" — {}", ch.detail) };
        println!("[{}] {}{}", symbol(ch.level, ch.optional), ch.label, d);
        if ch.level != Level::Ok {
            if !ch.pkgs.is_empty() {
                println!("       fix: install {}", ch.pkgs.join(" "));
            }
            if let Some(c) = &ch.cmd {
                if c != "@hgl-proton-install" {
                    println!("       fix: sudo {c}");
                } else {
                    println!("       fix: hgl proton install latest");
                }
            }
            if let Some(m) = &ch.manual {
                println!("       you: {m}");
            }
        }
    }
}

pub fn print_json(checks: &[Check]) {
    let mut parts = Vec::new();
    for ch in checks {
        let lvl = match ch.level {
            Level::Ok => "ok",
            Level::Warn => "warn",
            Level::Fail => "fail",
        };
        let pk: Vec<String> = ch.pkgs.iter().map(|p| json_str(p)).collect();
        parts.push(format!(
            "{{\"id\":{},\"label\":{},\"level\":\"{lvl}\",\"detail\":{},\"optional\":{},\"packages\":[{}],\"manual\":{}}}",
            json_str(ch.id),
            json_str(&ch.label),
            json_str(&ch.detail),
            ch.optional,
            pk.join(","),
            ch.manual.as_deref().map(json_str).unwrap_or_else(|| "null".into())
        ));
    }
    println!("[{}]", parts.join(","));
}

/// Install what is missing, after one confirmation. Returns true when nothing is left that hgl could have fixed.
pub fn fix(checks: &[Check], yes: bool) -> bool {
    let m = mgr();
    let todo: Vec<&Check> = checks.iter().filter(|c| c.level != Level::Ok && (!c.pkgs.is_empty() || c.cmd.is_some())).collect();
    if todo.is_empty() {
        println!("Nothing hgl can fix by itself.");
        return true;
    }
    println!("\nPlanned changes (run with sudo):");
    for c in &todo {
        if !c.pkgs.is_empty() {
            let tool = match m {
                Mgr::Pacman => "pacman -S --needed",
                Mgr::Apt => "apt-get install",
                Mgr::None => "(install)",
            };
            println!("  {tool} {}   [{}]", c.pkgs.join(" "), c.id);
        }
        if let Some(cmd) = &c.cmd {
            if cmd == "@hgl-proton-install" {
                println!("  hgl proton install latest   [{}] (no sudo)", c.id);
            } else {
                println!("  {cmd}   [{}]", c.id);
            }
        }
    }
    if !yes && !ask_yes_no("Go ahead?") {
        println!("Cancelled.");
        return false;
    }
    let sudo = if uid() == 0 { None } else if have("sudo") { Some("sudo") } else { None };
    if uid() != 0 && sudo.is_none() {
        eprintln!("sudo is not installed: run the commands above as root.");
        return false;
    }
    let mut all_ok = true;
    for c in todo {
        if !c.pkgs.is_empty() {
            let (prog, args): (&str, Vec<String>) = match m {
                Mgr::Pacman => ("pacman", vec!["-S".into(), "--needed".into(), "--noconfirm".into()]),
                Mgr::Apt => ("apt-get", vec!["install".into(), "-y".into()]),
                Mgr::None => continue,
            };
            let mut cmd = match sudo {
                Some(s) => {
                    let mut x = Command::new(s);
                    x.arg(prog);
                    x
                }
                None => Command::new(prog),
            };
            cmd.args(&args).args(&c.pkgs);
            let ok = cmd.status().map(|s| s.success()).unwrap_or(false);
            if !ok {
                eprintln!("  could not install for [{}]: {} (if the package is not found, run a full system update and try again)", c.id, c.pkgs.join(" "));
                all_ok = false;
            }
        }
        if let Some(sh) = &c.cmd {
            if sh == "@hgl-proton-install" {
                let mut cfg = Conf::load();
                let fam = proton::default_family(&cfg);
                match proton::install("latest", fam, &mut cfg) {
                    Ok(n) => println!("  installed {n}"),
                    Err(e) => {
                        eprintln!("  Proton install failed: {e}");
                        all_ok = false;
                    }
                }
                continue;
            }
            let mut cmd = match sudo {
                Some(s) => {
                    let mut x = Command::new(s);
                    x.arg("sh").arg("-c").arg(sh);
                    x
                }
                None => {
                    let mut x = Command::new("sh");
                    x.arg("-c").arg(sh);
                    x
                }
            };
            if !cmd.status().map(|s| s.success()).unwrap_or(false) {
                eprintln!("  command failed for [{}]", c.id);
                all_ok = false;
            }
        }
    }
    println!();
    all_ok
}

/// Only the Vulkan check, for crash triage.
pub fn vulkan_ok() -> bool {
    run_checks().iter().find(|c| c.id == "vulkan").map(|c| c.level == Level::Ok).unwrap_or(false)
}
