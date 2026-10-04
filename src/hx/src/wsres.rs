//! CPU + memory per window and per workspace (port of wsres.py), one JSON line every N seconds.
//! Every process is charged to its nearest ancestor that owns a window; windows sharing one process split its cost.
use crate::util::run;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::time::{Duration, Instant};

type Procs = HashMap<i32, (i32, u64, u64)>; // pid -> (ppid, cpu ticks, rss pages)

fn snapshot() -> Procs {
    let mut procs = HashMap::new();
    if let Ok(rd) = std::fs::read_dir("/proc") {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            let pid: i32 = match name.parse() { Ok(p) => p, Err(_) => continue };
            let s = match std::fs::read_to_string(format!("/proc/{}/stat", pid)) { Ok(s) => s, Err(_) => continue };
            let r = match s.rfind(')') { Some(i) => &s[i + 2..], None => continue };
            let rest: Vec<&str> = r.split_whitespace().collect();
            if rest.len() < 13 { continue; }
            let (ppid, ut, st) = (rest[1].parse().unwrap_or(0), rest[11].parse::<u64>().unwrap_or(0), rest[12].parse::<u64>().unwrap_or(0));
            let rss = std::fs::read_to_string(format!("/proc/{}/statm", pid))
                .ok()
                .and_then(|m| m.split_whitespace().nth(1).and_then(|x| x.parse().ok()))
                .unwrap_or(0);
            procs.insert(pid, (ppid, ut + st, rss));
        }
    }
    procs
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
        for (pid, (_, ticks, rss)) in &cur {
            if let Some(o) = owner_of(*pid, &by_pid, &cur, &mut memo) {
                let d = prev.get(pid).map(|b| ticks.saturating_sub(b.1)).unwrap_or(0) as f64;
                let e = per_owner.get_mut(&o).unwrap();
                e.0 += d / hz / dt * 100.0 / ncpu;
                e.1 += *rss as f64 * page_mb;
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
        println!("{}", json!({ "ws": ws, "win": win }));
        prev = cur;
        prev_t = now;
        std::thread::sleep(Duration::from_secs_f64(interval.max(0.2)));
    }
}
