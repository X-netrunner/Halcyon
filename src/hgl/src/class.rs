//! The machine's gaming class (A, B, C, D) and the settings suggested for a game on it.
//!
//! `hgl class` reads the GPUs (/sys/class/drm, `lspci`, `nvidia-smi`), the CPU threads and the memory, scores the best GPU by its
//! name (RTX 4050, RX 7600, Arc A750, Radeon 780M ...; by its video memory when the name is not known) and caps the score when the
//! CPU, the memory or the video memory would hold it back:
//!   A  high end      RTX 4070 / 3080, RX 7800 / 6800 and up     1440p, high to ultra
//!   B  mid range     RTX 4050 / 4060 / 3060, RX 6600 / 7600      1080p, high textures, medium heavy effects
//!   C  entry         GTX 1650 / 1060, RX 6500, Arc A380, 780M   1080p low to medium, or upscaled from 720p
//!   D  integrated    Intel UHD / Iris Xe, older Radeon iGPUs    720p low, upscaled
//! `hgl suggest <id>` turns the class into changes hgl can make (gamescope preset, wrappers, lean island, environment) and into
//! what to set inside the game (hgl cannot reach in-game menus). `--apply` writes the changes; nothing is changed without it.
//! A laptop with Intel or AMD graphics next to an NVIDIA card also gets the PRIME offload variables, so the game runs on the NVIDIA
//! card instead of the integrated one.

use crate::store::Game;
use crate::util::*;
use std::fs;

#[derive(Clone, Debug, PartialEq)]
pub struct Gpu {
    /// nvidia | amd | intel | other
    pub vendor: String,
    pub name: String,
    /// 0 = unknown (integrated GPUs share the system memory)
    pub vram_mb: u64,
    pub discrete: bool,
    pub score: f32,
}

#[derive(Clone, Debug)]
pub struct Machine {
    pub gpus: Vec<Gpu>,
    /// index into gpus of the one games should use
    pub best: Option<usize>,
    pub threads: usize,
    pub ram_mb: u64,
    /// an NVIDIA card next to an integrated GPU: games need PRIME offload to land on the NVIDIA card
    pub hybrid_nvidia: bool,
    pub class: char,
    /// why the class is what it is (the GPU, and any cap)
    pub why: Vec<String>,
}

// ------------------------------------------------------------------------------------------------ scoring
/// How strong a GPU is, from its name: 5 = top end, 0 = old integrated. None = a name this table does not know.
pub fn score_name(name: &str) -> Option<f32> {
    let n = name.to_ascii_lowercase();
    let mobile = n.contains("laptop") || n.contains("mobile") || n.contains("max-q") || n.ends_with('m') && n.contains("rtx");
    let mob = if mobile { 0.5 } else { 0.0 };
    // NVIDIA RTX 2050 ... 5090: the first two digits are the generation, the last two the tier
    if let Some(d) = digits_after(&n, "rtx") {
        if d.len() == 4 {
            let gen: u32 = d[..2].parse().ok()?;
            let tier: u32 = d[2..].parse().ok()?;
            let base = match tier {
                90 | 80 => 5.0,
                70 => 4.0,
                60 => 3.0,
                _ => 2.5,
            };
            let g = match gen {
                20 => -1.0,
                30 => -0.5,
                40 => 0.0,
                _ => 0.5,
            };
            return Some(f32::max(1.0, base + g - mob));
        }
    }
    // GTX 1050 ... 1080, 1630 ... 1660
    if let Some(d) = digits_after(&n, "gtx") {
        if d.len() == 4 {
            let s = match &d[..2] {
                "16" => 1.5,
                "10" => match &d[2..] {
                    "80" | "70" => 1.5,
                    "60" => 1.0,
                    _ => 0.5,
                },
                _ => 0.5,
            };
            return Some(s - mob / 2.0);
        }
    }
    // AMD RX 5500 ... 7900, RX 9060 / 9070: the tier is the second digit, the third one for the 9000 series
    if let Some(d) = digits_after(&n, "rx") {
        if d.len() == 4 {
            let b = d.as_bytes();
            let tier = if b[0] == b'9' { b[2] } else { b[1] } as char;
            let base = match tier {
                '9' | '8' => 4.5,
                '7' => 4.0,
                '6' => 3.0,
                '5' => 1.5,
                _ => 0.5,
            };
            let g = if b[0] == b'5' { -1.0 } else { 0.0 };
            return Some(f32::max(0.5, base + g - mob));
        }
    }
    // Intel Arc A380 ... A770, B570 / B580, and the Arc iGPUs of Core Ultra
    if n.contains("arc") {
        if let Some(d) = n.split(|c: char| !c.is_ascii_alphanumeric()).find(|w| w.len() == 4 && (w.starts_with('a') || w.starts_with('b')) && w[1..].chars().all(|c| c.is_ascii_digit())) {
            return Some(match &d[..2] {
                "a7" | "b5" => 3.0,
                "a5" => 2.0,
                _ => 1.0,
            });
        }
        return Some(1.0);
    }
    // AMD iGPUs that can game: 680M / 760M / 780M / 880M / 890M
    for (m, s) in [("890m", 1.5), ("880m", 1.0), ("780m", 1.0), ("760m", 0.8), ("680m", 0.8)] {
        if n.contains(m) {
            return Some(s);
        }
    }
    if n.contains("uhd") || n.contains("iris") || n.contains("hd graphics") || n.contains("vega") || n.contains("radeon graphics") {
        return Some(0.3);
    }
    None
}

/// "geforce rtx 4050 laptop" after "rtx" -> "4050"
fn digits_after(n: &str, word: &str) -> Option<String> {
    let i = n.find(word)? + word.len();
    let d: String = n[i..].trim_start().chars().take_while(|c| c.is_ascii_digit()).collect();
    if d.is_empty() {
        None
    } else {
        Some(d)
    }
}

/// A dedicated GPU this table does not know: go by its video memory.
fn score_vram(vram_mb: u64) -> f32 {
    match vram_mb {
        v if v >= 12_000 => 4.0,
        v if v >= 7_500 => 3.0,
        v if v >= 5_500 => 2.0,
        v if v >= 3_500 => 1.0,
        _ => 0.5,
    }
}

/// The class from the best GPU's score, capped by what would hold it back. Pure, so it is tested without hardware.
pub fn classify(gpu: Option<&Gpu>, threads: usize, ram_mb: u64) -> (char, Vec<String>) {
    let mut why = Vec::new();
    let mut s = match gpu {
        Some(g) => {
            why.push(format!("{} ({})", g.name, if g.vram_mb > 0 { format!("{} GB video memory", (g.vram_mb + 512) / 1024) } else { "shared memory".into() }));
            g.score
        }
        None => {
            why.push("no GPU found".into());
            0.0
        }
    };
    let cap = |s: &mut f32, to: f32, why: &mut Vec<String>, msg: String| {
        if *s > to {
            *s = to;
            why.push(msg);
        }
    };
    if let Some(g) = gpu {
        if g.discrete && g.vram_mb > 0 && g.vram_mb < 3_500 {
            cap(&mut s, 1.0, &mut why, "held back: under 4 GB of video memory".into());
        } else if g.discrete && g.vram_mb > 0 && g.vram_mb < 7_500 {
            cap(&mut s, 3.0, &mut why, "held back: under 8 GB of video memory (textures above High do not fit)".into());
        }
    }
    if threads > 0 && threads < 6 {
        cap(&mut s, 1.0, &mut why, format!("held back: the CPU has {threads} threads"));
    } else if threads > 0 && threads < 8 {
        cap(&mut s, 2.0, &mut why, format!("held back: the CPU has {threads} threads"));
    }
    if ram_mb > 0 && ram_mb < 7_000 {
        cap(&mut s, 0.5, &mut why, "held back: under 8 GB of memory".into());
    } else if ram_mb > 0 && ram_mb < 14_000 {
        cap(&mut s, 2.0, &mut why, "held back: under 16 GB of memory".into());
    }
    let class = if s >= 4.0 {
        'A'
    } else if s >= 2.0 {
        'B'
    } else if s >= 1.0 {
        'C'
    } else {
        'D'
    };
    (class, why)
}

pub fn class_label(c: char) -> &'static str {
    match c {
        'A' => "High end",
        'B' => "Mid range",
        'C' => "Entry",
        _ => "Integrated graphics",
    }
}

// ------------------------------------------------------------------------------------------------ detection
pub fn detect() -> Machine {
    let mut gpus = read_gpus();
    for g in gpus.iter_mut() {
        g.score = score_name(&g.name).unwrap_or_else(|| if g.discrete { score_vram(g.vram_mb) } else { 0.3 });
    }
    let best = (0..gpus.len()).max_by(|&a, &b| gpus[a].score.total_cmp(&gpus[b].score));
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0);
    let ram_mb = fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|t| t.lines().find(|l| l.starts_with("MemTotal:")).and_then(|l| l.split_whitespace().nth(1)).and_then(|k| k.parse::<u64>().ok()))
        .map(|kb| kb / 1024)
        .unwrap_or(0);
    let hybrid_nvidia = gpus.iter().any(|g| g.vendor == "nvidia") && gpus.iter().any(|g| g.vendor != "nvidia" && !g.discrete);
    let (class, why) = classify(best.map(|i| &gpus[i]), threads, ram_mb);
    Machine { gpus, best, threads, ram_mb, hybrid_nvidia, class, why }
}

/// GPUs from /sys/class/drm (vendor, AMD's video memory), named by `lspci` and, for NVIDIA, `nvidia-smi` (name and memory).
fn read_gpus() -> Vec<Gpu> {
    let lspci = out("lspci", &["-nn"]).unwrap_or_default();
    let smi = out("nvidia-smi", &["--query-gpu=name,memory.total", "--format=csv,noheader,nounits"]).unwrap_or_default();
    let mut smi_rows = smi.lines().filter_map(|l| l.rsplit_once(',')).map(|(n, m)| (n.trim().to_string(), m.trim().parse::<u64>().unwrap_or(0)));
    let mut v = Vec::new();
    let Ok(rd) = fs::read_dir("/sys/class/drm") else { return v };
    let mut cards: Vec<_> = rd.flatten().map(|e| e.path()).filter(|p| p.file_name().map(|n| { let n = n.to_string_lossy(); n.starts_with("card") && !n.contains('-') }).unwrap_or(false)).collect();
    cards.sort();
    for c in cards {
        let dev = c.join("device");
        let rd = |f: &str| fs::read_to_string(dev.join(f)).map(|s| s.trim().to_ascii_lowercase()).unwrap_or_default();
        let (vid, did) = (rd("vendor"), rd("device"));
        let vendor = match vid.as_str() {
            "0x10de" => "nvidia",
            "0x1002" => "amd",
            "0x8086" => "intel",
            _ => "other",
        };
        // lspci -nn names the device: "... [10de:28a1] (rev a1)" -> the text in the last [...] before the ids
        let ids = format!("[{}:{}]", vid.trim_start_matches("0x"), did.trim_start_matches("0x"));
        let mut name = lspci.lines().find(|l| l.contains(&ids)).map(lspci_name).unwrap_or_default();
        let mut vram_mb = rd("mem_info_vram_total").parse::<u64>().unwrap_or(0) / 1_048_576;
        if vendor == "nvidia" {
            if let Some((n, m)) = smi_rows.next() {
                name = n;
                vram_mb = m;
            }
        }
        // AMD reports a small carve-out for its iGPUs too: under 2 GB is integrated
        let discrete = match vendor {
            "nvidia" => true,
            "amd" => vram_mb >= 2_048 || name.to_ascii_lowercase().contains("rx "),
            "intel" => name.to_ascii_lowercase().contains("arc a") || name.to_ascii_lowercase().contains("arc b"),
            _ => false,
        };
        if name.is_empty() {
            name = format!("{vendor} GPU");
        }
        v.push(Gpu { vendor: vendor.into(), name, vram_mb, discrete, score: 0.0 });
    }
    v
}

/// "01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD107M [GeForce RTX 4050 Max-Q / Mobile] [10de:28a1] (rev a1)"
/// -> "GeForce RTX 4050 Max-Q / Mobile";  "... Intel Corporation Raptor Lake-P [Intel Graphics] [8086:a7a0]" -> "Intel Graphics"
fn lspci_name(line: &str) -> String {
    let after = line.split_once("]: ").map(|x| x.1).unwrap_or(line);
    let brackets: Vec<&str> = after.split('[').skip(1).filter_map(|s| s.split_once(']').map(|x| x.0)).collect();
    // the last bracket is the vendor:device id; the one before it (if any) is the marketing name
    if brackets.len() >= 2 {
        return brackets[brackets.len() - 2].to_string();
    }
    after.split(" [").next().unwrap_or(after).trim().to_string()
}

// ------------------------------------------------------------------------------------------------ suggestions
#[derive(Clone, Debug, PartialEq)]
pub struct Change {
    pub key: String,
    pub value: String,
    pub why: String,
}

/// In-game settings for a class (hgl cannot set these: they are shown so you can set them once in the game's menu).
pub fn in_game(class: char, nvidia_rtx: bool) -> Vec<String> {
    let up = if nvidia_rtx { "DLSS" } else { "FSR or XeSS" };
    let v: Vec<String> = match class {
        'A' => vec![
            "Resolution: native (1440p or your screen's)".into(),
            "Preset: High to Ultra; ray tracing only with upscaling on".into(),
            format!("Upscaling: {up} Quality, only if you are under your screen's refresh rate"),
            "Frame cap: your screen's refresh rate".into(),
        ],
        'B' => vec![
            "Resolution: 1080p (or native with upscaling)".into(),
            "Preset: High; textures High, not Ultra (they need more than 6 to 8 GB of video memory)".into(),
            "Turn down first: shadows, volumetric fog and clouds, ray tracing (off)".into(),
            format!("Upscaling: {up} Quality"),
            "Frame cap: 60, or your refresh rate if it holds steady".into(),
        ],
        'C' => vec![
            "Resolution: 1080p with upscaling, or 900p".into(),
            "Preset: Low to Medium; textures Medium".into(),
            "Off: ray tracing, motion blur, volumetric effects, screen-space reflections".into(),
            format!("Upscaling: {up} Balanced"),
            "Frame cap: 60 (45 in demanding games keeps it smooth)".into(),
        ],
        _ => vec![
            "Resolution: 720p (Halcyon upscales it to your screen with FSR)".into(),
            "Preset: Low; textures Low to Medium".into(),
            "Off: shadows quality high, ambient occlusion, anti-aliasing other than FXAA, every post effect".into(),
            "Frame cap: 30 to 45 for steady frames, and keep the laptop plugged in".into(),
        ],
    };
    v
}

/// What hgl would change on this game for this machine. Only things that differ from the game's current profile are listed.
pub fn suggest(g: &Game, m: &Machine) -> Vec<Change> {
    let mut v = Vec::new();
    let mut want = |key: &str, value: &str, cur: &str, why: &str| {
        if cur != value {
            v.push(Change { key: key.into(), value: value.into(), why: why.into() });
        }
    };
    // Lean island: every class gains from Halcyon resting, the weaker ones most
    want("lean", "on", if g.lean { "on" } else { "off" }, "Halcyon pauses its feeds, widgets and animations while you play");
    if g.source == "steam" {
        return v; // Steam starts its games: Proton, wrappers, gamescope and the environment are set in Steam
    }
    let mut wr = g.wrappers.clone();
    if !wr.iter().any(|w| w == "gamemode") {
        wr.insert(0, "gamemode".into());
    }
    // MangoHud costs a little; on the weakest machines leave it to the player
    if m.class == 'D' {
        wr.retain(|w| w != "mangohud");
    }
    want("wrappers", &wr.join(","), &g.wrappers.join(","), "gamemode asks the CPU and GPU for their performance mode");
    // gamescope: render at 720p and upscale with FSR only where the GPU needs it; elsewhere it only adds latency
    let scope = if m.class == 'D' { "fsr1080" } else { "" };
    let scope_why = if m.class == 'D' {
        "renders at 720p and upscales to 1080p with FSR: about twice the frames on integrated graphics"
    } else {
        "the GPU is fast enough to render at full resolution; gamescope would only add a little latency"
    };
    if !(scope.is_empty() && !["", "native", "1080p", "1440p", "fsr1080", "fsr1440"].contains(&g.gamescope.as_str())) {
        // custom gamescope options are yours: left alone
        want("gamescope", scope, &g.gamescope, scope_why);
    }
    let env = |k: &str| g.env.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str()).unwrap_or("");
    let best = m.best.map(|i| &m.gpus[i]);
    let nvidia = best.map(|b| b.vendor == "nvidia").unwrap_or(false);
    if m.hybrid_nvidia && nvidia {
        let why = "this laptop also has integrated graphics: these make the game run on the NVIDIA card";
        want("env.__NV_PRIME_RENDER_OFFLOAD", "1", env("__NV_PRIME_RENDER_OFFLOAD"), why);
        want("env.__VK_LAYER_NV_optimus", "NVIDIA_only", env("__VK_LAYER_NV_optimus"), why);
        want("env.__GLX_VENDOR_LIBRARY_NAME", "nvidia", env("__GLX_VENDOR_LIBRARY_NAME"), why);
    }
    if nvidia && best.map(|b| b.name.to_ascii_lowercase().contains("rtx")).unwrap_or(false) {
        want("env.PROTON_ENABLE_NVAPI", "1", env("PROTON_ENABLE_NVAPI"), "lets games offer DLSS and NVIDIA Reflex");
    }
    v
}

pub fn nvidia_rtx(m: &Machine) -> bool {
    m.best.map(|i| m.gpus[i].vendor == "nvidia" && m.gpus[i].name.to_ascii_lowercase().contains("rtx")).unwrap_or(false)
}

// ------------------------------------------------------------------------------------------------ output
pub fn machine_json(m: &Machine) -> String {
    let gpus: Vec<String> = m
        .gpus
        .iter()
        .enumerate()
        .map(|(i, g)| {
            format!(
                "{{\"vendor\":{},\"name\":{},\"vramMB\":{},\"discrete\":{},\"score\":{:.1},\"used\":{}}}",
                json_str(&g.vendor),
                json_str(&g.name),
                g.vram_mb,
                g.discrete,
                g.score,
                m.best == Some(i)
            )
        })
        .collect();
    let why: Vec<String> = m.why.iter().map(|w| json_str(w)).collect();
    format!(
        "{{\"class\":\"{}\",\"label\":{},\"gpus\":[{}],\"threads\":{},\"ramMB\":{},\"hybridNvidia\":{},\"why\":[{}]}}",
        m.class,
        json_str(class_label(m.class)),
        gpus.join(","),
        m.threads,
        m.ram_mb,
        m.hybrid_nvidia,
        why.join(",")
    )
}

pub fn print_human(m: &Machine) {
    println!("Class {}: {}", m.class, class_label(m.class));
    for w in &m.why {
        println!("  {w}");
    }
    for (i, g) in m.gpus.iter().enumerate() {
        let mem = if g.vram_mb > 0 { format!(", {} MB", g.vram_mb) } else { String::new() };
        println!("  GPU: {}{mem}{}{}", g.name, if g.discrete { ", dedicated" } else { ", integrated" }, if m.best == Some(i) { "  <- games use this one" } else { "" });
    }
    println!("  CPU: {} threads   Memory: {} GB", m.threads, (m.ram_mb + 512) / 1024);
    if m.hybrid_nvidia {
        println!("  Hybrid graphics: hgl suggest <id> adds the variables that put a game on the NVIDIA card");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gpu(name: &str, vendor: &str, vram: u64, discrete: bool) -> Gpu {
        Gpu { vendor: vendor.into(), name: name.into(), vram_mb: vram, discrete, score: score_name(name).unwrap_or(score_vram(vram)) }
    }

    #[test]
    fn classes_of_known_machines() {
        // this author's laptop: RTX 4050 Laptop 6 GB, 16 threads, 16 GB
        assert_eq!(classify(Some(&gpu("NVIDIA GeForce RTX 4050 Laptop GPU", "nvidia", 6141, true)), 16, 15_700).0, 'B');
        assert_eq!(classify(Some(&gpu("NVIDIA GeForce RTX 4070 Ti", "nvidia", 12_282, true)), 16, 32_000).0, 'A');
        assert_eq!(classify(Some(&gpu("NVIDIA GeForce RTX 3060", "nvidia", 12_288, true)), 12, 16_000).0, 'B');
        assert_eq!(classify(Some(&gpu("Radeon RX 7800 XT", "amd", 16_368, true)), 16, 32_000).0, 'A');
        assert_eq!(classify(Some(&gpu("Radeon RX 6600", "amd", 8_176, true)), 12, 16_000).0, 'B');
        assert_eq!(classify(Some(&gpu("NVIDIA GeForce GTX 1650", "nvidia", 4_096, true)), 8, 16_000).0, 'C');
        assert_eq!(classify(Some(&gpu("Radeon 780M", "amd", 512, false)), 16, 16_000).0, 'C');
        assert_eq!(classify(Some(&gpu("Intel Iris Xe Graphics", "intel", 0, false)), 8, 16_000).0, 'D');
        assert_eq!(classify(None, 8, 8_000).0, 'D');
    }

    #[test]
    fn caps_hold_a_strong_gpu_back() {
        let g = gpu("NVIDIA GeForce RTX 4080", "nvidia", 16_000, true);
        assert_eq!(classify(Some(&g), 4, 32_000).0, 'C'); // 4 threads
        assert_eq!(classify(Some(&g), 16, 8_000).0, 'B'); // 8 GB of memory
        assert_eq!(classify(Some(&gpu("Some New GPU", "other", 6_000, true)), 16, 32_000).0, 'B'); // by video memory
    }

    #[test]
    fn rx_9000_and_arc_names() {
        assert_eq!(score_name("AMD Radeon RX 9070 XT"), Some(4.0));
        assert_eq!(score_name("Intel Arc B580"), Some(3.0));
        assert_eq!(score_name("Intel Arc A380"), Some(1.0));
    }

    #[test]
    fn lspci_names() {
        assert_eq!(lspci_name("01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD107M [GeForce RTX 4050 Max-Q / Mobile] [10de:28a1] (rev a1)"), "GeForce RTX 4050 Max-Q / Mobile");
        assert_eq!(lspci_name("00:02.0 VGA compatible controller [0300]: Intel Corporation Raptor Lake-P [Intel Graphics] [8086:a7a0] (rev 04)"), "Intel Graphics");
    }

    #[test]
    fn suggestions_for_a_hybrid_laptop() {
        let g4050 = gpu("NVIDIA GeForce RTX 4050 Laptop GPU", "nvidia", 6141, true);
        let igpu = gpu("Intel Graphics", "intel", 0, false);
        let m = Machine { gpus: vec![igpu, g4050], best: Some(1), threads: 16, ram_mb: 15_700, hybrid_nvidia: true, class: 'B', why: vec![] };
        let mut g = Game::new("hades", "Hades", "exe");
        g.gamescope = "fsr1080".into();
        let s = suggest(&g, &m);
        let keys: Vec<&str> = s.iter().map(|c| c.key.as_str()).collect();
        assert!(keys.contains(&"env.__NV_PRIME_RENDER_OFFLOAD"));
        assert!(keys.contains(&"env.PROTON_ENABLE_NVAPI"));
        assert!(keys.contains(&"gamescope")); // class B renders natively
        assert!(!keys.contains(&"lean")); // already on
        // Steam games: only the lean island
        let st = Game::new("steam-1", "X", "steam");
        assert!(suggest(&st, &m).is_empty());
        // custom gamescope options are left alone
        g.gamescope = "-w 1600 -h 900 -f".into();
        assert!(!suggest(&g, &m).iter().any(|c| c.key == "gamescope"));
    }
}
