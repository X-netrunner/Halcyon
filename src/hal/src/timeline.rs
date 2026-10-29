//! hal timeline [conf|status]

use std::collections::HashMap;
use std::env;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

fn island_state_dir() -> PathBuf {
    if let Ok(s) = env::var("XDG_STATE_HOME") {
        if !s.is_empty() {
            return PathBuf::from(s).join("island");
        }
    }
    crate::util::state_dir()
}

fn local_offset_secs() -> i64 {
    let s = crate::util::out("date", &["+%z"]);
    let s = s.trim();
    if s.len() == 5 {
        let sign = if &s[0..1] == "-" { -1 } else { 1 };
        let h: i64 = s[1..3].parse().unwrap_or(0);
        let m: i64 = s[3..5].parse().unwrap_or(0);
        sign * (h * 3600 + m * 60)
    } else {
        0
    }
}

fn now_epoch() -> f64 {
    if let Ok(v) = env::var("TIMELINE_NOW") {
        if let Ok(n) = v.parse::<f64>() {
            return n;
        }
    }
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn epoch_to_local_days(epoch: f64, offset: i64) -> i64 {
    let local = epoch + offset as f64;
    (local / 86400.0).floor() as i64
}

fn days_since(epoch: f64, now: f64, offset: i64) -> i64 {
    if epoch <= 0.0 {
        return -1;
    }
    let d_now = epoch_to_local_days(now, offset);
    let d_epoch = epoch_to_local_days(epoch, offset);
    (d_now - d_epoch).max(0)
}

fn ago(epoch: f64, now: f64, offset: i64) -> String {
    if epoch <= 0.0 {
        return "unknown".to_string();
    }
    let secs = (now - epoch).max(0.0);
    let d = days_since(epoch, now, offset);
    if d == 0 {
        if secs < 90.0 {
            return "just now".to_string();
        }
        if secs < 3600.0 {
            return format!("{:.0} min ago", (secs / 60.0).round());
        }
        return format!("{} h ago", (secs / 3600.0) as u64);
    }
    if d == 1 {
        return "yesterday".to_string();
    }
    format!("{} days ago", d)
}

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = y + (if m <= 2 { 1 } else { 0 });
    (y as i32, m, d)
}

fn days_from_civil(y: i32, m: u32, d: u32) -> i64 {
    let y = y as i64 - (if m <= 2 { 1 } else { 0 });
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = (y - era * 400) as u32;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe as i64 - 719468
}

fn stamp_text(epoch: f64, offset: i64) -> String {
    if epoch <= 0.0 {
        return String::new();
    }
    let local = (epoch + offset as f64).max(0.0);
    let days = (local / 86400.0).floor() as i64;
    let day_secs = (local as i64) % 86400;
    let hour = day_secs / 3600;
    let minute = (day_secs % 3600) / 60;
    let (year, month, day) = civil_from_days(days);
    let month_idx = (month.saturating_sub(1) as usize).min(11);
    format!("{} {} {}, {:02}:{:02}", day, MONTHS[month_idx], year, hour, minute)
}

fn file_mtime(path: &Path) -> f64 {
    fs::metadata(path)
        .ok()
        .and_then(|m| m.modified().ok())
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn wallpaper_epoch(island_dir: &Path, now: f64) -> (f64, &'static str) {
    let stamp_file = island_dir.join("wallpaper-changed");
    if let Ok(content) = fs::read_to_string(&stamp_file) {
        if let Some(token) = content.split_whitespace().next() {
            if let Ok(v) = token.parse::<f64>() {
                if v > 0.0 && v <= now + 86400.0 {
                    return (v, "stamp");
                }
            }
        }
    }
    let m = file_mtime(&island_dir.join("wallpaper"));
    if m > 0.0 {
        (m, "file")
    } else {
        (0.0, "none")
    }
}

fn parse_pacman_date(date_str: &str) -> f64 {
    let s = date_str.trim();
    let (date_part, time_part) = if let Some(pair) = s.split_once('T') {
        pair
    } else if let Some(pair) = s.split_once(' ') {
        pair
    } else {
        return 0.0;
    };

    let mut d_split = date_part.split('-');
    let y: i32 = match d_split.next().and_then(|v| v.parse().ok()) {
        Some(v) => v,
        None => return 0.0,
    };
    let m: u32 = match d_split.next().and_then(|v| v.parse().ok()) {
        Some(v) => v,
        None => return 0.0,
    };
    let d: u32 = match d_split.next().and_then(|v| v.parse().ok()) {
        Some(v) => v,
        None => return 0.0,
    };

    let mut tz_offset = 0i64;
    let clean_time = if let Some(idx) = time_part.find('+').or_else(|| time_part.rfind('-')) {
        if idx > 2 {
            let (tm, tz) = time_part.split_at(idx);
            let sign = if tz.starts_with('-') { -1 } else { 1 };
            let tz_digits = tz.trim_start_matches('+').trim_start_matches('-').replace(':', "");
            if tz_digits.len() >= 4 {
                let th: i64 = tz_digits[0..2].parse().unwrap_or(0);
                let tm_m: i64 = tz_digits[2..4].parse().unwrap_or(0);
                tz_offset = sign * (th * 3600 + tm_m * 60);
            }
            tm
        } else {
            time_part
        }
    } else {
        time_part
    };

    let mut t_split = clean_time.split(':');
    let hr: i64 = match t_split.next().and_then(|v| v.parse().ok()) {
        Some(v) => v,
        None => return 0.0,
    };
    let min: i64 = match t_split.next().and_then(|v| v.parse().ok()) {
        Some(v) => v,
        None => return 0.0,
    };
    let sec: i64 = t_split.next().and_then(|v| v.parse().ok()).unwrap_or(0);

    let days = days_from_civil(y, m, d);
    let epoch_utc = days * 86400 + hr * 3600 + min * 60 + sec - tz_offset;
    epoch_utc as f64
}

fn pacman_epoch() -> f64 {
    let log_path = env::var("HALCYON_PACMAN_LOG").unwrap_or_else(|_| "/var/log/pacman.log".to_string());
    let mut file = match File::open(&log_path) {
        Ok(f) => f,
        Err(_) => return 0.0,
    };
    let size = match file.metadata().map(|m| m.len()) {
        Ok(s) => s,
        Err(_) => return 0.0,
    };

    let max_read = 64 * 1024 * 1024;
    let mut pos = size;
    let mut carry = Vec::new();
    let mut full_upgrade = 0.0;

    while pos > 0 && (size - pos) < max_read {
        let step = (1024 * 1024).min(pos);
        pos -= step;
        if file.seek(SeekFrom::Start(pos)).is_err() {
            break;
        }
        let mut buf = vec![0u8; step as usize];
        if file.read_exact(&mut buf).is_err() {
            break;
        }
        buf.extend_from_slice(&carry);

        let mut slice = buf.as_slice();
        if pos > 0 {
            if let Some(first_nl) = slice.iter().position(|&b| b == b'\n') {
                carry = slice[..first_nl].to_vec();
                slice = &slice[first_nl + 1..];
            } else {
                carry = slice.to_vec();
                continue;
            }
        } else {
            carry.clear();
        }

        for line in slice.split(|&b| b == b'\n').rev() {
            if line.starts_with(b"[") {
                if let Some(close_idx) = line.iter().position(|&b| b == b']') {
                    let stamp = String::from_utf8_lossy(&line[1..close_idx]);
                    let rest = &line[close_idx + 1..];
                    if rest.starts_with(b" [ALPM] upgraded ") {
                        let t = parse_pacman_date(&stamp);
                        if t > 0.0 {
                            return t;
                        }
                    } else if full_upgrade == 0.0 && rest.starts_with(b" [PACMAN] starting full system upgrade") {
                        full_upgrade = parse_pacman_date(&stamp);
                    }
                }
            }
        }
    }
    full_upgrade
}

fn focus_goal(island_dir: &Path) -> i64 {
    let settings_file = island_dir.join("settings.json");
    if let Ok(c) = fs::read_to_string(settings_file) {
        if let Some(json) = crate::json::parse(&c) {
            if let Some(opt) = json.get("opt") {
                if let Some(desk) = opt.get("deskWidgets") {
                    for item in desk.get("items").map(|i| i.items()).unwrap_or(&[]) {
                        if item.str("type") == Some("focus") {
                            let off = item.get("off") == Some(&crate::json::Json::Bool(true));
                            if !off {
                                if let Some(opts) = item.get("opts") {
                                    if let Some(g) = opts.num("goal") {
                                        return (g.round() as i64).clamp(5, 180);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    25
}

struct FocusStats {
    goal: i64,
    tracked: bool,
    today: i64,
    streak: i64,
    best: i64,
    last: i64,
}

fn focus_stats(island_dir: &Path, now: f64, offset: i64) -> FocusStats {
    let goal = focus_goal(island_dir);
    let focus_file = island_dir.join("focus-days.json");
    let mut days_map: HashMap<i64, i64> = HashMap::new();

    if let Ok(c) = fs::read_to_string(&focus_file) {
        if let Some(crate::json::Json::Obj(entries)) = crate::json::parse(&c) {
            for (k, v) in entries {
                let parts: Vec<&str> = k.split('-').collect();
                if parts.len() == 3 {
                    if let (Ok(y), Ok(m), Ok(d)) = (parts[0].parse::<i32>(), parts[1].parse::<u32>(), parts[2].parse::<u32>()) {
                        let epoch_day = days_from_civil(y, m, d);
                        let mins = match v {
                            crate::json::Json::Num(n) => n as i64,
                            _ => 0,
                        };
                        days_map.insert(epoch_day, mins.max(0));
                    }
                }
            }
        }
    }

    let today_day = epoch_to_local_days(now, offset);
    let today_mins = days_map.get(&today_day).copied().unwrap_or(0);
    let tracked = !days_map.is_empty();

    if days_map.is_empty() {
        return FocusStats {
            goal,
            tracked: false,
            today: 0,
            streak: 0,
            best: 0,
            last: -1,
        };
    }

    let mut hit_days: Vec<i64> = days_map
        .iter()
        .filter(|(_, &m)| m >= goal)
        .map(|(&d, _)| d)
        .collect();
    hit_days.sort_unstable();

    let last = hit_days.last().map(|&ld| (today_day - ld).max(0)).unwrap_or(-1);

    let start_check = if today_mins >= goal { today_day } else { today_day - 1 };
    let mut streak = 0i64;
    let mut d = start_check;
    while days_map.get(&d).copied().unwrap_or(0) >= goal && streak < 4000 {
        streak += 1;
        d -= 1;
    }

    let mut best = 0i64;
    let mut run = 0i64;
    let mut prev: Option<i64> = None;
    for &cur in &hit_days {
        if let Some(p) = prev {
            if cur - p == 1 {
                run += 1;
            } else {
                run = 1;
            }
        } else {
            run = 1;
        }
        best = best.max(run);
        prev = Some(cur);
    }
    best = best.max(streak);

    FocusStats {
        goal,
        tracked,
        today: today_mins,
        streak,
        best,
        last,
    }
}

pub fn run(args: &[String]) -> i32 {
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("conf");
    let now = now_epoch();
    let offset = local_offset_secs();

    let island_dir = island_state_dir();
    let home = crate::util::home();
    let hal_commit = PathBuf::from(&home).join(".local/state/halcyon/installed-commit");

    let (wall_epoch, wall_src) = wallpaper_epoch(&island_dir, now);
    let pacman_time = pacman_epoch();
    let hal_time = file_mtime(&hal_commit);
    let focus = focus_stats(&island_dir, now, offset);

    let wall_since = days_since(wall_epoch, now, offset);
    let wall_ago_str = ago(wall_epoch, now, offset);
    let wall_at_str = stamp_text(wall_epoch, offset);

    let upd_since = days_since(pacman_time, now, offset);
    let upd_ago_str = ago(pacman_time, now, offset);
    let upd_at_str = stamp_text(pacman_time, offset);
    let upd_src = if pacman_time > 0.0 { "pacman" } else { "none" };

    let hal_since = days_since(hal_time, now, offset);
    let hal_ago_str = ago(hal_time, now, offset);
    let hal_at_str = stamp_text(hal_time, offset);

    if cmd == "conf" {
        println!(
            "{{\"wallSince\":{},\"wallAgo\":\"{}\",\"wallAt\":\"{}\",\"wallSource\":\"{}\",\
             \"updSince\":{},\"updAgo\":\"{}\",\"updAt\":\"{}\",\"updSource\":\"{}\",\
             \"halSince\":{},\"halAgo\":\"{}\",\"halAt\":\"{}\",\
             \"focusGoal\":{},\"focusTracked\":{},\"focusToday\":{},\"focusStreak\":{},\"focusBest\":{},\
             \"focusLast\":{}}}",
            wall_since, wall_ago_str, wall_at_str, wall_src,
            upd_since, upd_ago_str, upd_at_str, upd_src,
            hal_since, hal_ago_str, hal_at_str,
            focus.goal, focus.tracked, focus.today, focus.streak, focus.best,
            focus.last
        );
        0
    } else if cmd == "status" {
        println!("wallpaper changed : {} ({})", wall_ago_str, if wall_at_str.is_empty() { "no record" } else { &wall_at_str });
        println!("system updated    : {} ({})", upd_ago_str, if upd_at_str.is_empty() { "no readable pacman log" } else { &upd_at_str });
        println!("Halcyon updated   : {} ({})", hal_ago_str, if hal_at_str.is_empty() { "no record" } else { &hal_at_str });
        println!(
            "focus streak      : {} day(s), best {}, a day counts from {} min, today {} min",
            focus.streak, focus.best, focus.goal, focus.today
        );
        0
    } else {
        eprintln!("usage: hal timeline conf | status");
        2
    }
}
