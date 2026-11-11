use crate::json::{self, Json};
use std::io::Read;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const TABLE: &str = include_str!("../../../design/components.json");
const STATUS_SCHEMA: &str = "halcyon.status/1";
const CONTRACT: u32 = 1;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Level {
    Ok,
    Info,
    Warn,
    Fail,
}

impl Level {
    fn tag(self) -> &'static str {
        match self {
            Level::Ok => "ok",
            Level::Info => "info",
            Level::Warn => "warn",
            Level::Fail => "fail",
        }
    }
}

#[derive(Debug)]
pub struct Check {
    pub component: String,
    pub what: String,
    pub level: Level,
    pub detail: String,
}

fn check(component: &str, what: &str, level: Level, detail: impl Into<String>) -> Check {
    Check {
        component: component.into(),
        what: what.into(),
        level,
        detail: detail.into(),
    }
}

fn expand(path: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    let runtime =
        std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| format!("/run/user/{}", uid()));
    let config = std::env::var("XDG_CONFIG_HOME").unwrap_or_else(|_| format!("{home}/.config"));
    PathBuf::from(
        path.replace("$XDG_RUNTIME_DIR", &runtime)
            .replace("$XDG_CONFIG_HOME", &config),
    )
}

fn uid() -> u32 {
    std::fs::metadata("/proc/self")
        .map(|m| m.uid())
        .unwrap_or(0)
}

fn find_bin(name: &str) -> Option<PathBuf> {
    let path = std::env::var("PATH").unwrap_or_default();
    let home = std::env::var("HOME").unwrap_or_default();
    path.split(':')
        .map(PathBuf::from)
        .chain([
            PathBuf::from(format!("{home}/.local/bin")),
            PathBuf::from("/usr/local/bin"),
        ])
        .map(|d| d.join(name))
        .find(|p| {
            p.metadata()
                .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
        })
}

pub fn run_with_timeout(cmd: &Path, args: &[&str], limit: Duration) -> Option<(bool, String)> {
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let mut out = String::new();
                child.stdout.take()?.read_to_string(&mut out).ok()?;
                return Some((status.success(), out));
            }
            Ok(None) if started.elapsed() < limit => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

pub fn judge_status(component: &str, min_contract: u32, out: &str) -> Check {
    let Some(v) = json::parse(out.trim()) else {
        return check(
            component,
            "health",
            Level::Warn,
            "no health endpoint: this version is older than the contract, update it",
        );
    };
    if v.str("schema") != Some(STATUS_SCHEMA) {
        return check(
            component,
            "health",
            Level::Warn,
            "unknown status format: update it",
        );
    }
    let contract = v.num("contract").unwrap_or(0.0) as u32;
    let version = v.str("version").unwrap_or("?");
    if contract < min_contract {
        return check(
            component,
            "health",
            Level::Warn,
            format!(
                "{version} speaks contract {contract}, Halcyon needs {min_contract}: update it"
            ),
        );
    }
    if contract > CONTRACT {
        return check(component, "health", Level::Warn, format!("{version} speaks contract {contract}, newer than this Halcyon ({CONTRACT}): update Halcyon"));
    }
    let detail = v.str("detail").unwrap_or("");
    let level = match v.str("state") {
        Some("ok") => Level::Ok,
        Some("degraded") => Level::Warn,
        _ => Level::Fail,
    };
    check(
        component,
        "health",
        level,
        format!(
            "{version}: {}",
            if detail.is_empty() {
                v.str("state").unwrap_or("unknown")
            } else {
                detail
            }
        ),
    )
}

fn service(component: &str, unit: &str, user: bool) -> Check {
    let mut args = vec!["is-active"];
    if user {
        args.insert(0, "--user");
    }
    args.push(unit);
    let state = Command::new("systemctl")
        .args(&args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_else(|_| "unknown".into());
    let level = match state.as_str() {
        "active" => Level::Ok,
        "activating" | "reloading" => Level::Warn,
        "inactive" => Level::Warn,
        _ => Level::Fail,
    };
    check(component, unit, level, state)
}

pub fn socket(component: &str, path: &Path) -> Check {
    let what = path.display().to_string();
    match std::fs::symlink_metadata(path) {
        Err(_) => check(
            component,
            &what,
            Level::Warn,
            "missing (the daemon is not running)",
        ),
        Ok(m) if !m.file_type().is_socket() => {
            check(component, &what, Level::Fail, "exists but is not a socket")
        }
        Ok(m) if m.permissions().mode() & 0o002 != 0 => {
            check(component, &what, Level::Fail, "world-writable socket")
        }
        Ok(_) => check(component, &what, Level::Ok, "present"),
    }
}

pub fn private_file(component: &str, path: &Path) -> Check {
    let what = path.display().to_string();
    match std::fs::metadata(path) {
        Err(_) => check(component, &what, Level::Info, "not created yet"),
        Ok(m) if m.permissions().mode() & 0o077 != 0 => check(
            component,
            &what,
            Level::Fail,
            format!(
                "readable by others (mode {:o}); run: chmod 600 {}",
                m.permissions().mode() & 0o777,
                path.display()
            ),
        ),
        Ok(_) => check(component, &what, Level::Ok, "private"),
    }
}

pub fn runtime_dir(path: &Path) -> Check {
    let what = path.display().to_string();
    match std::fs::metadata(path) {
        Err(_) => check(
            "halcyon",
            &what,
            Level::Info,
            "not created yet (made on login)",
        ),
        Ok(m) if m.permissions().mode() & 0o077 != 0 => check(
            "halcyon",
            &what,
            Level::Fail,
            "shared runtime dir must be 0700",
        ),
        Ok(m) if m.uid() != uid() => check("halcyon", &what, Level::Fail, "owned by another user"),
        Ok(_) => check("halcyon", &what, Level::Ok, "0700, yours"),
    }
}

fn strings(v: &Json, key: &str) -> Vec<String> {
    v.get(key)
        .map(|a| {
            a.items()
                .iter()
                .filter_map(|i| match i {
                    Json::Str(s) => Some(s.clone()),
                    _ => None,
                })
                .collect()
        })
        .unwrap_or_default()
}

pub fn collect() -> Vec<Check> {
    let mut checks = Vec::new();
    let Some(table) = json::parse(TABLE) else {
        return vec![check(
            "halcyon",
            "components table",
            Level::Fail,
            "design/components.json does not parse",
        )];
    };
    let runtime = expand(&format!(
        "$XDG_RUNTIME_DIR/{}",
        table.str("runtime_dir").unwrap_or("halcyon")
    ));
    checks.push(runtime_dir(&runtime));
    for c in table.get("components").map(Json::items).unwrap_or(&[]) {
        let id = c.str("id").unwrap_or("?");
        let bins = strings(c, "bins");
        let found: Vec<PathBuf> = bins.iter().filter_map(|b| find_bin(b)).collect();
        let Some(bin) = found.first() else {
            checks.push(check(
                id,
                "installed",
                Level::Info,
                "not installed: Halcyon works without it",
            ));
            continue;
        };
        checks.push(check(id, "installed", Level::Ok, bin.display().to_string()));
        let health = strings(c, "health");
        if health.len() > 1 {
            let args: Vec<&str> = health[1..].iter().map(String::as_str).collect();
            let min = c.num("min_contract").unwrap_or(1.0) as u32;
            checks.push(match run_with_timeout(bin, &args, Duration::from_secs(3)) {
                Some((_, out)) => judge_status(id, min, &out),
                None => check(id, "health", Level::Fail, "did not answer within 3 s"),
            });
        }
        for u in strings(c, "user_services") {
            checks.push(service(id, &u, true));
        }
        for u in strings(c, "services") {
            checks.push(service(id, &u, false));
        }
        for s in strings(c, "sockets") {
            checks.push(socket(id, &expand(&s)));
        }
        for f in strings(c, "private_files") {
            checks.push(private_file(id, &expand(&f)));
        }
    }
    checks
}

fn esc(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', " ")
}

pub fn run(args: &[String]) -> i32 {
    let checks = collect();
    if args.iter().any(|a| a == "--json") {
        let rows: Vec<String> = checks
            .iter()
            .map(|c| {
                format!(
                    r#"{{"component":"{}","check":"{}","level":"{}","detail":"{}"}}"#,
                    esc(&c.component),
                    esc(&c.what),
                    c.level.tag(),
                    esc(&c.detail)
                )
            })
            .collect();
        println!("[{}]", rows.join(","));
    } else {
        for c in &checks {
            println!(
                "[{:<4}] {:<14} {:<34} {}",
                c.level.tag(),
                c.component,
                c.what,
                c.detail
            );
        }
        let worst = checks.iter().map(|c| c.level).max().unwrap_or(Level::Ok);
        println!(
            "\n{}",
            match worst {
                Level::Fail => "Something needs fixing: see the [fail] lines.",
                Level::Warn => "Working, with warnings.",
                _ => "Everything is in order.",
            }
        );
    }
    if checks.iter().any(|c| c.level == Level::Fail) {
        1
    } else {
        0
    }
}

pub fn health(args: &[String]) -> i32 {
    let rice = crate::util::rice_dir();
    let (state, detail) = if !rice.join("quickshell/island/shell.qml").exists() {
        (
            "degraded",
            format!("the shell is not installed in {}", rice.display()),
        )
    } else {
        ("ok", "desktop files in place".to_string())
    };
    let record = format!(
        r#"{{"schema":"{STATUS_SCHEMA}","component":"halcyon","version":"{}","contract":{CONTRACT},"state":"{state}","detail":"{}"}}"#,
        env!("CARGO_PKG_VERSION"),
        esc(&detail)
    );
    if args.iter().any(|a| a == "--json") {
        println!("{record}");
    } else {
        println!("halcyon {}: {state} ({detail})", env!("CARGO_PKG_VERSION"));
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_table_parses_and_names_every_component() {
        let t = json::parse(TABLE).expect("components.json");
        let ids: Vec<&str> = t
            .get("components")
            .unwrap()
            .items()
            .iter()
            .filter_map(|c| c.str("id"))
            .collect();
        assert_eq!(
            ids,
            [
                "halcyon",
                "halcyon-music",
                "luna",
                "ai-antivirus",
                "ai-firewall",
                "halcyon-fm"
            ]
        );
    }

    #[test]
    fn status_records_are_judged_by_state_and_contract() {
        let ok = r#"{"schema":"halcyon.status/1","component":"x","version":"1.0","contract":1,"state":"ok","detail":"fine"}"#;
        assert_eq!(judge_status("x", 1, ok).level, Level::Ok);
        assert_eq!(
            judge_status("x", 1, &ok.replace(r#""ok""#, r#""degraded""#)).level,
            Level::Warn
        );
        assert_eq!(
            judge_status("x", 1, &ok.replace(r#""ok""#, r#""down""#)).level,
            Level::Fail
        );
        assert_eq!(
            judge_status("x", 2, ok).level,
            Level::Warn,
            "too old for this Halcyon"
        );
        assert_eq!(
            judge_status("x", 1, &ok.replace(r#""contract":1"#, r#""contract":9"#)).level,
            Level::Warn,
            "newer than Halcyon"
        );
        assert_eq!(
            judge_status("x", 1, "usage: x [run]").level,
            Level::Warn,
            "no endpoint is a warning, not a failure"
        );
    }

    #[test]
    fn private_files_must_not_be_readable_by_others() {
        let dir = std::env::temp_dir().join(format!("hal-doctor-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("secrets.toml");
        std::fs::write(&f, "k = 1").unwrap();
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(private_file("luna", &f).level, Level::Fail);
        std::fs::set_permissions(&f, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(private_file("luna", &f).level, Level::Ok);
        assert_eq!(private_file("luna", &dir.join("none")).level, Level::Info);
        assert_eq!(
            socket("x", &f).level,
            Level::Fail,
            "a plain file is not a socket"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_hung_endpoint_times_out() {
        let started = Instant::now();
        assert!(
            run_with_timeout(Path::new("/bin/sleep"), &["5"], Duration::from_millis(200)).is_none()
        );
        assert!(started.elapsed() < Duration::from_secs(2));
    }
}
