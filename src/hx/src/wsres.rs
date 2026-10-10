//! CPU + memory per window and per workspace (port of wsres.py), one JSON line every N seconds.
//! Every process is charged to its nearest ancestor that owns a window; windows sharing one process split its cost.
use crate::util::run;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::time::{Duration, Instant};

type Procs = HashMap<i32, (i32, u64)>; // pid -> (ppid, cpu ticks)

// Cheap pass over /proc: only `stat` (parent + cpu ticks) for every process. The resident size (`statm`)
// is read later, and only for the processes that actually belong to a window (see `rss_pages`).
fn snapshot() -> Procs {
    use std::io::Read;
    let mut procs = HashMap::with_capacity(512);
    let mut buf = String::with_capacity(512);
    if let Ok(rd) = std::fs::read_dir("/proc") {
        for e in rd.flatten() {
            let pid: i32 = match e.file_name().to_str().and_then(|n| n.parse().ok()) { Some(p) => p, None => continue };
            buf.clear();
            let ok = std::fs::File::open(format!("/proc/{}/stat", pid)).and_then(|mut f| f.read_to_string(&mut buf)).is_ok();
            if !ok { continue; }
            let r = match buf.rfind(')') { Some(i) => &buf[i + 2..], None => continue };
            // fields after the comm: state(0) ppid(1) ... utime(11) stime(12)
            let mut it = r.split_whitespace();
            let ppid = match it.nth(1).and_then(|x| x.parse().ok()) { Some(v) => v, None => 0 };
            let ut = match it.nth(9) { Some(x) => x.parse::<u64>().unwrap_or(0), None => continue };
            let st = match it.next() { Some(x) => x.parse::<u64>().unwrap_or(0), None => continue };
            procs.insert(pid, (ppid, ut + st));
        }
    }
    procs
}

// Memory of one process in MB. Uses PSS (proportional set size, /proc/<pid>/smaps_rollup): pages shared between
// processes are split between the processes that map them. The plain resident size (statm / what `ps` shows)
// counts every shared page (libraries, Firefox's shared memory, GPU buffers) once per process, so summing it over
// a browser's many processes gave 3-4x the real figure. Falls back to RSS if smaps_rollup can't be read.
fn mem_mb(pid: i32, buf: &mut String, page_mb: f64) -> f64 {
    use std::io::Read;
    buf.clear();
    if std::fs::File::open(format!("/proc/{}/smaps_rollup", pid)).and_then(|mut f| f.read_to_string(buf)).is_ok() {
        for l in buf.lines() {
            if let Some(r) = l.strip_prefix("Pss:") {
                if let Some(kb) = r.split_whitespace().next().and_then(|x| x.parse::<f64>().ok()) { return kb / 1024.0; }
            }
        }
    }
    buf.clear();
    if std::fs::File::open(format!("/proc/{}/statm", pid)).and_then(|mut f| f.read_to_string(buf)).is_err() { return 0.0; }
    buf.split_whitespace().nth(1).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0) * page_mb
}

fn read_small(path: String) -> String {
    use std::io::Read;
    let mut b = String::new();
    let _ = std::fs::File::open(path).and_then(|mut f| f.read_to_string(&mut b));
    b
}

// Is this process part of Halcyon itself (the island / bar / wallpaper shells, the hx helper, the daemons)?
fn halcyon_name(pid: i32) -> Option<String> {
    let comm = read_small(format!("/proc/{}/comm", pid)).trim().to_string();
    let known = ["quickshell", "hx", "power-manager", "touchpad-gestures", "cava", "awww-daemon", "swww-daemon"];
    if known.contains(&comm.as_str()) { return Some(comm); }
    let cmd = read_small(format!("/proc/{}/cmdline", pid));
    if cmd.contains("/Halcyon/") || cmd.contains(".config/Halcyon") || cmd.contains("halcyon") { return Some(if comm.is_empty() { "script".into() } else { comm }); }
    None
}

fn owner_of(pid: i32, owners: &HashMap<i32, Vec<Value>>, procs: &Procs, memo: &mut HashMap<i32, Option<i32>>) -> Option<i32> {
    let mut chain = Vec::new();
    let mut cur = pid;
    let mut res = None;
    while cur != 0 && procs.contains_key(&cur) {
        if let Some(m) = memo.get(&cur) { res = *m; break; }
        if owners.contains_key(&cur) { res = Some(cur); break; }
        chain.push(cur);
        cur = procs[&cur].0;
        if chain.len() > 4096 { break; }
    }
    for c in chain { memo.insert(c, res); }
    res
}

fn clients() -> Vec<Value> {
    let v: Value = serde_json::from_str(&run("hyprctl", &["clients", "-j"], 3)).unwrap_or(Value::Null);
    v.as_array().cloned().unwrap_or_default().into_iter()
        .filter(|c| c["mapped"].as_bool().unwrap_or(true) && c["pid"].as_i64().unwrap_or(0) > 0)
        .collect()
}

// (MemTotal, MemAvailable) in MB
fn meminfo() -> (f64, f64) {
    let t = read_small("/proc/meminfo".into());
    let get = |k: &str| t.lines().find(|l| l.starts_with(k)).and_then(|l| l.split_whitespace().nth(1)).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0) / 1024.0;
    (get("MemTotal:").round(), get("MemAvailable:").round())
}

fn round1(x: f64) -> f64 { (x * 10.0).round() / 10.0 }

pub fn wsres(interval: f64) {
    let hz = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as f64;
    let page_mb = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as f64 / 1048576.0;
    let ncpu = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1) as f64;
    let mut prev = snapshot();
    let mut prev_t = Instant::now();
    std::thread::sleep(Duration::from_millis(500));
    loop {
        let cur = snapshot();
        let now = Instant::now();
        let dt = now.duration_since(prev_t).as_secs_f64().max(0.05);
        let wins = clients();
        let mut by_pid: HashMap<i32, Vec<Value>> = HashMap::new();
        for c in wins { by_pid.entry(c["pid"].as_i64().unwrap_or(0) as i32).or_default().push(c); }

        let mut per_owner: HashMap<i32, (f64, f64)> = by_pid.keys().map(|p| (*p, (0.0, 0.0))).collect();
        let mut memo = HashMap::new();
        let mut sbuf = String::with_capacity(4096);
        let mut hal: HashMap<String, (f64, f64, u32)> = HashMap::new();
        for (pid, (_, ticks)) in &cur {
            let owner = owner_of(*pid, &by_pid, &cur, &mut memo);
            if owner.is_none() {
                // not part of any window: is it Halcyon (or a child of a Halcyon process)?
                let mut name = halcyon_name(*pid);
                if name.is_none() {
                    // walk up a few parents so quickshell's helper scripts count too
                    let mut cur_pid = cur.get(pid).map(|x| x.0).unwrap_or(0);
                    let mut hops = 0;
                    while name.is_none() && cur_pid > 1 && hops < 6 {
                        if by_pid.contains_key(&cur_pid) { break; }
                        name = halcyon_name(cur_pid).map(|n| if n == "quickshell" { "scripts".to_string() } else { n });
                        cur_pid = cur.get(&cur_pid).map(|x| x.0).unwrap_or(0);
                        hops += 1;
                    }
                }
                if let Some(n) = name {
                    let d = prev.get(pid).map(|b| ticks.saturating_sub(b.1)).unwrap_or(0) as f64;
                    let c = d / hz / dt * 100.0 / ncpu;
                    let m = mem_mb(*pid, &mut sbuf, page_mb);
                    let e = hal.entry(n).or_insert((0.0, 0.0, 0));
                    e.0 += c; e.1 += m; e.2 += 1;
                }
            }
            if let Some(o) = owner {
                let d = prev.get(pid).map(|b| ticks.saturating_sub(b.1)).unwrap_or(0) as f64;
                let rss = mem_mb(*pid, &mut sbuf, page_mb);
                let e = per_owner.get_mut(&o).unwrap();
                e.0 += d / hz / dt * 100.0 / ncpu;
                e.1 += rss;
            }
        }
        let mut ws: Map<String, Value> = Map::new();
        let mut win: Map<String, Value> = Map::new();
        for (pid, group) in &by_pid {
            let (cpu, mem) = per_owner[pid];
            let n = group.len() as f64;
            for c in group {
                let addr = c["address"].as_str().unwrap_or("").to_lowercase().replacen("0x", "", 1);
                win.insert(addr, json!({ "cpu": round1(cpu / n), "mem": (mem / n).round() }));
                let name = match &c["workspace"]["name"] { Value::String(s) => s.clone(), o => o.to_string() };
                let e = ws.entry(name).or_insert(json!({ "cpu": 0.0, "mem": 0.0 }));
                let (c0, m0) = (e["cpu"].as_f64().unwrap_or(0.0), e["mem"].as_f64().unwrap_or(0.0));
                *e = json!({ "cpu": round1(c0 + cpu / n), "mem": (m0 + mem / n).round() });
            }
        }
        let (mut hc, mut hm, mut hn) = (0.0, 0.0, 0u32);
        let mut parts: Vec<(String, f64, f64)> = Vec::new();
        for (n, (c, m, k)) in &hal { hc += c; hm += m; hn += k; parts.push((n.clone(), *c, *m)); }
        parts.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));
        let top: Vec<Value> = parts.iter().take(4).map(|(n, c, m)| json!({ "name": n, "cpu": round1(*c), "mem": m.round() })).collect();
        let (mt, ma) = meminfo();
        println!("{}", json!({
            "ws": ws, "win": win,
            "hal": { "cpu": round1(hc), "mem": hm.round(), "n": hn, "top": top },
            "sys": { "total": mt, "avail": ma }
        }));
        prev = cur;
        prev_t = now;
        std::thread::sleep(Duration::from_secs_f64(interval.max(0.2)));
    }
}
