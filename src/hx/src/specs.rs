//! Static hardware info for the performance page (port of specs.py): one JSON line.
//! GPU names come from sysfs ids + pci.ids, never nvidia-smi and never lspci unless pci.ids is missing,
//! because reading PCI config space wakes a runtime-suspended dGPU.
use crate::util::{home, read, run};
use regex::Regex;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

fn cpu() -> (String, usize, usize) {
    let mut name = String::new();
    for l in read("/proc/cpuinfo").lines() {
        if l.starts_with("model name") {
            name = l.splitn(2, ':').nth(1).unwrap_or("").trim().to_string();
            break;
        }
    }
    for junk in ["(R)", "(TM)", "(tm)", " CPU", " Processor"] {
        name = name.replace(junk, "");
    }
    for (re, rep) in [
        (r"\s+(with|w/)\s+Radeon.*$", ""),
        (r"\s*@\s*[\d.]+\s*GHz", ""),
        (r"\s+\d+-Core", ""),
        (r"\s+", " "),
    ] {
        name = Regex::new(re).unwrap().replace_all(&name, rep).into_owned();
    }
    let name = name.trim().to_string();
    let cores: HashSet<String> = run("lscpu", &["-p=core,socket"], 4)
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| l.to_string())
        .collect();
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0);
    (if name.is_empty() { "CPU".into() } else { name }, cores.len(), threads)
}

fn tidy(vendor: &str, model: &str) -> String {
    let v = if vendor.contains("NVIDIA") {
        "NVIDIA"
    } else if vendor.contains("AMD") || vendor.contains("ATI") {
        "AMD"
    } else if vendor.contains("Intel") {
        "Intel"
    } else {
        vendor
    };
    let re = Regex::new(r"\[(.+)\]").unwrap();
    let mut m = re.captures(model).map(|c| c[1].to_string()).unwrap_or_else(|| model.to_string());
    if m.starts_with(v) {
        m = m[v.len()..].trim().to_string();
    }
    format!("{} {}", v, m).trim().to_string()
}

fn pci_names(wanted: &HashSet<(String, String)>) -> HashMap<(String, Option<String>), String> {
    let mut out = HashMap::new();
    let env = std::env::var("PCI_IDS").ok();
    let paths: Vec<String> = match env {
        Some(p) => vec![p],
        None => vec!["/usr/share/hwdata/pci.ids".into(), "/usr/share/misc/pci.ids".into(), "/usr/share/pci.ids".into()],
    };
    let path = match paths.iter().find(|p| std::path::Path::new(p).exists()) {
        Some(p) => p,
        None => return out,
    };
    let text = String::from_utf8_lossy(&std::fs::read(path).unwrap_or_default()).into_owned();
    let vendors: HashSet<&String> = wanted.iter().map(|(v, _)| v).collect();
    let mut cur: Option<String> = None;
    for line in text.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        if !line.starts_with('\t') {
            if line.starts_with("C ") {
                break;
            }
            let id = line.get(..4).unwrap_or("").to_lowercase();
            cur = if vendors.contains(&id) { Some(id) } else { None };
            if let Some(c) = &cur {
                out.insert((c.clone(), None), line[4..].trim().to_string());
            }
        } else if let Some(c) = &cur {
            if !line.starts_with("\t\t") {
                let t = line.trim();
                let dev = t.get(..4).unwrap_or("").to_lowercase();
                if wanted.contains(&(c.clone(), dev.clone())) {
                    out.insert((c.clone(), Some(dev)), t[4..].trim().to_string());
                }
            }
        }
    }
    out
}

fn gpus() -> Vec<String> {
    let root = std::env::var("PCI_ROOT").unwrap_or_else(|_| "/sys/bus/pci/devices".into());
    let mut found: Vec<(String, String)> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&root) {
        let mut names: Vec<_> = rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        for d in names {
            let base = format!("{}/{}", root, d);
            if read(&format!("{}/class", base)).trim().starts_with("0x03") {
                let v = read(&format!("{}/vendor", base)).trim().trim_start_matches("0x").to_lowercase();
                let dv = read(&format!("{}/device", base)).trim().trim_start_matches("0x").to_lowercase();
                found.push((v, dv));
            }
        }
    }
    if !found.is_empty() {
        let set: HashSet<(String, String)> = found.iter().cloned().collect();
        let names = pci_names(&set);
        let mut out = Vec::new();
        for (v, d) in &found {
            if let (Some(vn), Some(dn)) = (names.get(&(v.clone(), None)), names.get(&(v.clone(), Some(d.clone())))) {
                out.push(tidy(vn, dn));
            }
        }
        if out.len() == found.len() {
            return out;
        }
    }
    // fallback: lspci (may wake a sleeping dGPU once)
    let q = Regex::new(r#""([^"]*)""#).unwrap();
    let mut out = Vec::new();
    for line in run("lspci", &["-mm"], 4).lines() {
        let parts: Vec<String> = q.captures_iter(line).map(|c| c[1].to_string()).collect();
        if parts.len() >= 3 && ["VGA", "3D", "Display"].iter().any(|k| parts[0].contains(k)) {
            out.push(tidy(&parts[1], &parts[2]));
        }
    }
    out
}

fn ram() -> Value {
    let kb: f64 = Regex::new(r"MemTotal:\s+(\d+)")
        .unwrap()
        .captures(&read("/proc/meminfo"))
        .and_then(|c| c[1].parse().ok())
        .unwrap_or(0.0);
    let gb = kb / 1048576.0;
    let total = if gb < 8.0 { gb.ceil() as i64 } else { ((gb / 2.0).ceil() * 2.0) as i64 };
    let mut info = json!({ "total": format!("{}G", total), "type": "", "speed": "", "modules": 0, "channels": "", "detail": "" });

    // per-user cache first, then the system-wide one written at boot by halcyon-ram.service (see install.sh)
    let mut text = read(&format!("{}/.cache/island/dmi-memory.txt", home()));
    if !text.contains("Memory Device") {
        text = read("/var/lib/halcyon/dmi-memory.txt");
    }
    if text.is_empty() {
        return info;
    }
    struct Module { mb: i64, ty: String, form: String, speed: String, loc: String }
    let kv = Regex::new(r"(?m)^\s*([A-Za-z /]+?):\s*(.+?)\s*$").unwrap();
    let sz = Regex::new(r"^(\d+)\s*(MB|GB)").unwrap();
    let mut mods: Vec<Module> = Vec::new();
    for block in text.split("Memory Device").skip(1) {
        let f: HashMap<String, String> = kv.captures_iter(block).map(|c| (c[1].to_string(), c[2].to_string())).collect();
        let size = f.get("Size").cloned().unwrap_or_default();
        let m = match sz.captures(&size) {
            Some(m) => m,
            None => continue,
        };
        let mb = m[1].parse::<i64>().unwrap_or(0) * if &m[2] == "GB" { 1024 } else { 1 };
        let g = |k: &str| f.get(k).cloned().unwrap_or_default();
        let speed = ["Configured Memory Speed", "Configured Clock Speed", "Speed"]
            .iter()
            .map(|k| g(k))
            .find(|s| !s.is_empty())
            .unwrap_or_default();
        mods.push(Module { mb, ty: g("Type"), form: g("Form Factor"), speed, loc: format!("{} {}", g("Locator"), g("Bank Locator")) });
    }
    if mods.is_empty() {
        return info;
    }
    let t = mods[0].ty.clone();
    info["type"] = json!(if !t.is_empty() && t != "Unknown" { t.clone() } else { String::new() });
    let sp = Regex::new(r"^(\d+)").unwrap().captures(&mods[0].speed).map(|c| format!("{} MT/s", &c[1])).unwrap_or_default();
    info["speed"] = json!(sp);
    info["modules"] = json!(mods.len());
    let sums: i64 = mods.iter().map(|m| m.mb).sum::<i64>() / 1024;
    if sums > 0 {
        info["total"] = json!(format!("{}G", sums));
    }
    let each = mods[0].mb / 1024;
    info["detail"] = json!(if mods.len() > 1 { format!("{}×{}G", mods.len(), each) } else { format!("{}G", each) });
    let soldered = mods[0].form.to_lowercase().contains("chip") || t.starts_with("LP");
    if soldered {
        info["channels"] = json!("soldered");
    } else {
        let ch = Regex::new(r"(?i)(controller\s*\d+)?[-\s]*channel\s*([A-Da-d0-9])").unwrap();
        let mut chans: HashSet<(String, String)> = HashSet::new();
        for m in &mods {
            if let Some(c) = ch.captures(&m.loc) {
                chans.insert((c.get(1).map(|x| x.as_str().to_string()).unwrap_or_default(), c[2].to_uppercase()));
            }
        }
        let n = if chans.is_empty() { mods.len().min(2) } else { chans.len() };
        info["channels"] = json!(match n { 1 => "single".to_string(), 2 => "dual".into(), 3 => "triple".into(), 4 => "quad".into(), n => format!("{}-channel", n) });
    }
    info
}

fn disks() -> Vec<Value> {
    let v: Value = serde_json::from_str(&run("lsblk", &["-J", "-d", "-b", "-o", "NAME,MODEL,SIZE,TYPE,ROTA,TRAN"], 4)).unwrap_or(Value::Null);
    let mut out = Vec::new();
    for d in v["blockdevices"].as_array().cloned().unwrap_or_default() {
        let name = d["name"].as_str().unwrap_or("").to_string();
        let size: i64 = match &d["size"] {
            Value::String(s) => s.parse().unwrap_or(0),
            Value::Number(n) => n.as_i64().unwrap_or(0),
            _ => 0,
        };
        if d["type"].as_str() != Some("disk") || ["loop", "zram", "ram", "sr"].iter().any(|p| name.starts_with(p)) || size < 1_000_000_000 {
            continue;
        }
        let tran = d["tran"].as_str().unwrap_or("");
        let rota = match &d["rota"] {
            Value::Bool(b) => *b,
            Value::String(s) => s != "0" && s != "False" && s != "false",
            Value::Number(n) => n.as_i64() != Some(0),
            _ => true,
        };
        let kind = if tran == "nvme" || name.starts_with("nvme") { "NVMe" } else if !rota { "SSD" } else { "HDD" };
        out.push(json!({
            "name": name, "model": d["model"].as_str().unwrap_or("").trim(), "kind": kind,
            "size": format!("{}G", (size as f64 / 1e9).round() as i64),
        }));
    }
    out
}

pub fn run_specs() {
    let c = cpu();
    println!("{}", json!({ "cpu": c.0, "cores": c.1, "threads": c.2, "gpus": gpus(), "ram": ram(), "disks": disks() }));
}
