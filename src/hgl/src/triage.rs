//! Crash triage: scan a game's log for known failure patterns and offer a fix the UI can apply with one button.

use crate::doctor;
use crate::store::Game;
use crate::util::*;
use std::fs;
use std::path::PathBuf;

#[derive(Clone, Debug, PartialEq)]
pub enum Fix {
    /// run `hgl doctor --fix`
    Doctor,
    /// set an environment variable on the game
    SetEnv(&'static str, &'static str),
    /// `hgl set <id> <key> <value>`
    SetKey(&'static str, &'static str),
    /// remove one wrapper (gamemode, mangohud) or the gamescope preset
    DropWrapper(&'static str),
    /// `hgl proton install latest`
    ProtonInstall,
    /// nothing to apply, advice only
    Hint,
}

#[derive(Clone, Debug)]
pub struct Finding {
    pub id: &'static str,
    pub title: &'static str,
    pub detail: &'static str,
    pub fix: Fix,
}

struct Rule {
    id: &'static str,
    /// any of these (lowercase) appearing in the log triggers the rule
    any: &'static [&'static str],
    title: &'static str,
    detail: &'static str,
    fix: Fix,
}

const RULES: &[Rule] = &[
    Rule {
        id: "vulkan-icd",
        any: &["no vulkan icd", "vk_error_incompatible_driver", "vkcreateinstance failed", "failed to create vulkan instance", "could not load vulkan", "no vulkan device", "unable to find a vulkan driver"],
        title: "No usable Vulkan driver",
        detail: "The game could not start Vulkan (DXVK needs it). The Doctor can install the missing driver packages.",
        fix: Fix::Doctor,
    },
    Rule {
        id: "gamemode-preload",
        any: &["libgamemodeauto", "libgamemode.so"],
        title: "32-bit gamemode library missing",
        detail: "gamemoderun could not preload its library for a 32-bit game. Install lib32-gamemode (Doctor), or switch the gamemode wrapper off for this game.",
        fix: Fix::DropWrapper("gamemode"),
    },
    Rule {
        id: "wayland-driver",
        any: &["no driver could be loaded", "winewayland.drv", "could not find a display driver"],
        title: "Wine could not open a window",
        detail: "Native Wayland mode did not work for this game/runtime. Switching it off falls back to XWayland.",
        fix: Fix::SetKey("wayland", "0"),
    },
    Rule {
        id: "d3d11",
        any: &["failed to create d3d11", "d3d11createdevice failed", "dxgi_error_unsupported", "d3d11: failed to", "failed to create dxgi factory", "dxvk: error"],
        title: "Direct3D 11 device failed",
        detail: "Usually the Vulkan driver. If the Doctor says Vulkan is fine, the fix tries the OpenGL-based WineD3D renderer instead.",
        fix: Fix::SetEnv("PROTON_USE_WINED3D", "1"),
    },
    Rule {
        id: "ntdll-32bit",
        any: &["could not load ntdll.so", "wine: failed to load ntdll", "libc.so.6: wrong elf class", "wrong elf class: elfclass32"],
        title: "32-bit libraries missing",
        detail: "Wine could not load its 32-bit side. The Doctor checks multilib and the lib32 packages.",
        fix: Fix::Doctor,
    },
    Rule {
        id: "umu-missing",
        any: &["umu-run: command not found", "no such file or directory: 'umu-run'", "umu-run: not found"],
        title: "umu-launcher is not installed",
        detail: "Every non-Steam game runs through umu-run.",
        fix: Fix::Doctor,
    },
    Rule {
        id: "proton-missing",
        any: &["proton: not found", "proton not found", "runtime not found", "protonpath is not", "protonpath does not"],
        title: "Proton runtime not found",
        detail: "The pinned Proton version is gone, or none is installed. Installing the latest one fixes the default.",
        fix: Fix::ProtonInstall,
    },
    Rule {
        id: "map-count",
        any: &["vm.max_map_count", "mmap: cannot allocate", "virtual memory exhausted", "unable to allocate virtual memory"],
        title: "Kernel memory-map limit too low",
        detail: "The game ran out of memory mappings (vm.max_map_count). The Doctor raises it.",
        fix: Fix::Doctor,
    },
    Rule {
        id: "gamescope",
        any: &["gamescope: error", "failed to initialize gamescope", "wlserver: failed", "vulkan: failed to find a suitable device for gamescope", "gamescope: unable"],
        title: "gamescope failed to start",
        detail: "Try the game without gamescope; Wayland-only compositors and some GPUs need different options.",
        fix: Fix::DropWrapper("gamescope"),
    },
    Rule {
        id: "vram",
        any: &["vk_error_out_of_device_memory", "out of video memory", "vk_error_out_of_host_memory"],
        title: "Ran out of GPU memory",
        detail: "Lower the game's texture quality or resolution; a gamescope preset with a lower render size also helps.",
        fix: Fix::Hint,
    },
    Rule {
        id: "missing-dll",
        any: &["library msvcp", "library vcruntime", "library xinput", "library d3dcompiler", "import_dll:library", "err:module:import_dll"],
        title: "A Windows runtime DLL is missing",
        detail: "Install the missing component into this game's prefix with protontricks/winetricks (vcrun2022, d3dcompiler_47, ...).",
        fix: Fix::Hint,
    },
    Rule {
        id: "anticheat",
        any: &["easyanticheat", "easy anti-cheat", "battleye", "eac_launcher", "beclient"],
        title: "Anti-cheat",
        detail: "Anti-cheat games only run on Linux when the developer enabled Proton support. No launcher setting changes that.",
        fix: Fix::Hint,
    },
];

pub fn latest_log(id: &str) -> Option<PathBuf> {
    let dir = logs_dir().join(id);
    let mut logs: Vec<PathBuf> = fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).filter(|p| p.extension().map(|x| x == "log").unwrap_or(false)).collect();
    logs.sort();
    logs.pop()
}

/// Match rules against log text. `vulkan_fine` turns the d3d11 fix into the WineD3D experiment; otherwise the Doctor comes first.
pub fn scan(text: &str, vulkan_fine: bool) -> Vec<Finding> {
    let low = text.to_ascii_lowercase();
    let mut out = Vec::new();
    for r in RULES {
        if r.any.iter().any(|p| low.contains(p)) {
            let mut fix = r.fix.clone();
            if r.id == "d3d11" && !vulkan_fine {
                fix = Fix::Doctor;
            }
            out.push(Finding { id: r.id, title: r.title, detail: r.detail, fix });
        }
    }
    out
}

pub fn scan_game(id: &str) -> Result<(Option<PathBuf>, Vec<Finding>), String> {
    let _ = Game::load(id)?;
    let Some(log) = latest_log(id) else { return Ok((None, vec![])) };
    let bytes = fs::read(&log).map_err(|e| format!("cannot read {}: {e}", log.display()))?;
    let tail = if bytes.len() > 2_000_000 { &bytes[bytes.len() - 2_000_000..] } else { &bytes[..] };
    let whole = String::from_utf8_lossy(tail).to_string();
    // the header hgl writes (command line, environment) is not game output: never match against it
    let text = match whole.split_once(crate::run::OUTPUT_MARK) {
        Some((_, rest)) => rest.to_string(),
        None => whole,
    };
    let wants_vk = RULES.iter().any(|r| r.id == "d3d11" && r.any.iter().any(|p| text.to_ascii_lowercase().contains(p)));
    let vk = if wants_vk { doctor::vulkan_ok() } else { true };
    Ok((Some(log), scan(&text, vk)))
}

pub fn fix_label(f: &Fix) -> String {
    match f {
        Fix::Doctor => "run the Doctor (hgl doctor --fix)".into(),
        Fix::SetEnv(k, v) => format!("set {k}={v} for this game"),
        Fix::SetKey(k, v) => format!("set {k} to {v}"),
        Fix::DropWrapper(w) => format!("turn off {w} for this game"),
        Fix::ProtonInstall => "install the latest Proton".into(),
        Fix::Hint => String::new(),
    }
}

pub fn fix_kind(f: &Fix) -> &'static str {
    match f {
        Fix::Doctor => "doctor",
        Fix::SetEnv(..) => "env",
        Fix::SetKey(..) => "set",
        Fix::DropWrapper(_) => "wrapper",
        Fix::ProtonInstall => "proton",
        Fix::Hint => "hint",
    }
}

pub fn print_json(log: &Option<PathBuf>, f: &[Finding]) {
    let items: Vec<String> = f
        .iter()
        .map(|x| {
            format!(
                "{{\"id\":{},\"title\":{},\"detail\":{},\"fix\":{},\"fixLabel\":{}}}",
                json_str(x.id),
                json_str(x.title),
                json_str(x.detail),
                json_str(fix_kind(&x.fix)),
                json_str(&fix_label(&x.fix))
            )
        })
        .collect();
    let lg = log.as_ref().map(|p| json_str(&p.to_string_lossy())).unwrap_or_else(|| "null".into());
    println!("{{\"log\":{lg},\"findings\":[{}]}}", items.join(","));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_patterns() {
        let f = scan("err:module:import_dll Library MSVCP140.dll not found\nvkCreateInstance failed", true);
        let ids: Vec<&str> = f.iter().map(|x| x.id).collect();
        assert!(ids.contains(&"vulkan-icd"));
        assert!(ids.contains(&"missing-dll"));
    }

    #[test]
    fn d3d11_fix_depends_on_vulkan() {
        let log = "Failed to create D3D11 device";
        assert_eq!(scan(log, false)[0].fix, Fix::Doctor);
        assert_eq!(scan(log, true)[0].fix, Fix::SetEnv("PROTON_USE_WINED3D", "1"));
    }

    #[test]
    fn clean_log_has_no_findings() {
        assert!(scan("fixme:thread:...\nGame started\nGame quit", true).is_empty());
    }

    #[test]
    fn rule_ids_unique() {
        for (i, a) in RULES.iter().enumerate() {
            for b in &RULES[i + 1..] {
                assert_ne!(a.id, b.id);
            }
        }
    }
}
