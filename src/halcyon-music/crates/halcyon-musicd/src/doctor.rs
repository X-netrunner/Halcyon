//! `--doctor`: one PASS/WARN/FAIL line per check, each with a fix hint.
//! Exit code: 0 if no FAIL, 1 if any FAIL, 2 if doctor itself broke.

use halcyon_music_core::paths;
use std::io::Write;
use std::net::TcpStream;
use std::path::Path;
use std::process::{Command as ProcCommand, ExitCode, Stdio};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    Pass,
    Warn,
    Fail,
}

impl Status {
    fn label(self) -> &'static str {
        match self {
            Status::Pass => "PASS",
            Status::Warn => "WARN",
            Status::Fail => "FAIL",
        }
    }
}

#[derive(Debug)]
struct Check {
    name: &'static str,
    status: Status,
    detail: String,
    hint: Option<String>,
}

fn check(name: &'static str, status: Status, detail: impl Into<String>) -> Check {
    Check { name, status, detail: detail.into(), hint: None }
}

fn check_hint(name: &'static str, status: Status, detail: impl Into<String>, hint: impl Into<String>) -> Check {
    Check { name, status, detail: detail.into(), hint: Some(hint.into()) }
}

pub fn run() -> anyhow::Result<ExitCode> {
    let mut checks = Vec::new();
    checks.push(check_runtime_dir());
    checks.extend(check_socket());
    checks.push(check_state_file());
    checks.push(check_systemd_unit());
    checks.push(check_audio_server());
    checks.push(check_network());
    checks.push(check_cache());
    checks.extend(check_credentials());
    checks.extend(check_endpoint_probes());

    let mut any_fail = false;
    for c in &checks {
        println!("[{}] {:<18} {}", c.status.label(), c.name, c.detail);
        if let Some(h) = &c.hint {
            println!("       fix: {h}");
        }
        if c.status == Status::Fail {
            any_fail = true;
        }
    }

    Ok(if any_fail { ExitCode::FAILURE } else { ExitCode::SUCCESS })
}

fn check_runtime_dir() -> Check {
    let socket_dir = paths::socket_dir();
    match std::fs::create_dir_all(&socket_dir) {
        Ok(()) => {
            let probe = socket_dir.join(".doctor-probe");
            match std::fs::File::create(&probe).and_then(|_| std::fs::remove_file(&probe)) {
                Ok(()) => check("runtime dir", Status::Pass, format!("{} is writable", socket_dir.display())),
                Err(e) => check_hint(
                    "runtime dir",
                    Status::Fail,
                    format!("{} not writable: {e}", socket_dir.display()),
                    "make sure XDG_RUNTIME_DIR is set and owned by you (systemd user session)",
                ),
            }
        }
        Err(e) => check_hint(
            "runtime dir",
            Status::Fail,
            format!("cannot create {}: {e}", socket_dir.display()),
            "start a systemd user session (loginctl enable-linger $USER)",
        ),
    }
}

fn check_socket() -> Vec<Check> {
    let sock = paths::ctl_socket();
    let mut out = Vec::new();
    if !sock.exists() {
        out.push(check_hint(
            "daemon socket",
            Status::Warn,
            format!("{} does not exist (daemon not running?)", sock.display()),
            "start the daemon: systemctl --user start halcyon-musicd, or just launch halcyon-music",
        ));
        return out;
    }
    // The socket file exists — see if something answers on it.
    match std::os::unix::net::UnixStream::connect(&sock) {
        Ok(mut stream) => {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
            let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));

            let payload = halcyon_music_core::protocol::encode_line(
                &halcyon_music_core::protocol::command(
                    halcyon_music_core::protocol::CommandBody::Hello,
                ),
            )
            .unwrap_or_default();

            let write_ok = stream.write_all(&payload).is_ok();
            let mut reader = std::io::BufReader::new(stream);
            let mut line = String::new();
            use std::io::BufRead;
            let read_ok = reader.read_line(&mut line).is_ok();

            if write_ok && read_ok && !line.trim().is_empty() {
                out.push(check("daemon socket", Status::Pass, "daemon answers on ctl.sock"));
            } else {
                out.push(check_hint(
                    "daemon socket",
                    Status::Warn,
                    "socket exists but nothing answered; daemon may be starting",
                    "wait a second, then: systemctl --user restart halcyon-musicd",
                ));
            }
        }
        Err(e) => out.push(check_hint(
            "daemon socket",
            Status::Warn,
            format!("cannot connect to {}: {e}", sock.display()),
            format!("start or restart daemon: systemctl --user restart halcyon-musicd"),
        )),
    }
    out
}

fn check_state_file() -> Check {
    let path = paths::state_file();
    if !path.exists() {
        return check("state file", Status::Pass, "no saved state yet (first run)");
    }
    match std::fs::read_to_string(&path) {
        Ok(text) => match serde_json::from_str::<halcyon_music_core::PlayerState>(&text) {
            Ok(_) => check("state file", Status::Pass, "parses cleanly"),
            Err(e) => check_hint(
                "state file",
                Status::Warn,
                format!("corrupt ({e}); it will be moved aside on next start"),
                "just start the app — it recovers by itself; old file is kept next to it",
            ),
        },
        Err(e) => check("state file", Status::Warn, format!("unreadable: {e}")),
    }
}

fn check_systemd_unit() -> Check {
    let unit = dirs_home().join(".config/systemd/user/halcyon-musicd.service");
    if !unit.exists() {
        return check_hint(
            "systemd unit",
            Status::Warn,
            "halcyon-musicd.service not installed for this user",
            "install.sh (Part 8) installs it; for now: cargo build --release && copy the unit from packaging/",
        );
    }
    // systemctl available?
    let has_systemctl = ProcCommand::new("systemctl").arg("--user").arg("--no-pager").arg("is-enabled").arg("halcyon-musicd.service").stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok();
    if !has_systemctl {
        return check(
            "systemd unit",
            Status::Warn,
            "unit file present, but no systemd user session in this environment (container/SSH?)",
        );
    }
    let status = ProcCommand::new("systemctl")
        .args(["--user", "is-active", "halcyon-musicd.service"])
        .output();
    match status {
        Ok(o) if o.status.success() => check("systemd unit", Status::Pass, "service is active"),
        Ok(o) => {
            let state = String::from_utf8_lossy(&o.stdout).trim().to_string();
            check_hint(
                "systemd unit",
                Status::Warn,
                format!("service state: {state}"),
                "systemctl --user enable --now halcyon-musicd.service",
            )
        }
        Err(e) => check("systemd unit", Status::Warn, format!("could not query systemd: {e}")),
    }
}

fn check_audio_server() -> Check {
    // Look for PipeWire's well-known socket or a PulseAudio server.
    let runtime = paths::runtime_dir();
    let pipewire = runtime.join("pipewire-0");
    if pipewire.exists() {
        return check("audio server", Status::Pass, "PipeWire socket found");
    }
    if std::env::var_os("PULSE_SERVER").is_some() || std::env::var_os("PULSE_COOKIE").is_some() {
        return check("audio server", Status::Pass, "PULSE_SERVER is set");
    }
    // pactl as a last resort (only if it answers quickly).
    if let Ok(output) = ProcCommand::new("pactl").arg("info").output() {
        if output.status.success() {
            return check("audio server", Status::Pass, "pactl info answered");
        }
    }
    check_hint(
        "audio server",
        Status::Warn,
        "no PipeWire/PulseAudio socket found (yet)",
        "playback needs PipeWire or PulseAudio; if audio works otherwise, ignore this in weird sessions (SSH, containers)",
    )
}

fn check_network() -> Check {
    // 8 s timeout per Part 0 rules, done on a thread so doctor stays sync.
    let result = std::thread::spawn(|| {
        TcpStream::connect_timeout(
            &"api.spotify.com:443".to_socket_addrs_best(),
            Duration::from_secs(8),
        )
    })
    .join();
    match result {
        Ok(Ok(_)) => check("network", Status::Pass, "api.spotify.com:443 reachable"),
        Ok(Err(e)) => check_hint(
            "network",
            Status::Warn,
            format!("cannot reach api.spotify.com: {e}"),
            "the app still opens from cache offline; check your connection for fresh data",
        ),
        Err(_) => check("network", Status::Warn, "network check thread failed"),
    }
}

fn check_cache() -> Check {
    let cache_dir = paths::cache_dir();
    let db_path = cache_dir.join("cache.db");
    if !db_path.exists() {
        return check(
            "cache",
            Status::Pass,
            format!("cache directory ready ({})", cache_dir.display()),
        );
    }

    match rusqlite::Connection::open(&db_path) {
        Ok(conn) => {
            let res: Result<String, _> = conn.query_row("PRAGMA quick_check;", [], |row| row.get(0));
            match res {
                Ok(status) if status == "ok" => {
                    check("cache", Status::Pass, "SQLite cache intact")
                }
                Ok(other) => check_hint(
                    "cache",
                    Status::Warn,
                    format!("SQLite cache warning: {other}"),
                    "corrupt files will be moved aside automatically on launch",
                ),
                Err(e) => check_hint(
                    "cache",
                    Status::Warn,
                    format!("SQLite cache error: {e}"),
                    "corrupt files will be moved aside automatically on launch",
                ),
            }
        }
        Err(e) => check_hint(
            "cache",
            Status::Warn,
            format!("cannot open SQLite cache: {e}"),
            "daemon will create a clean cache on start",
        ),
    }
}

fn check_credentials() -> Vec<Check> {
    match crate::token_store::load_token() {
        Ok(Some(token)) => {
            if token.is_expired() {
                vec![check_hint(
                    "spotify login",
                    Status::Warn,
                    format!("token expired (client ID: {})", token.client_id),
                    "open halcyon-music to re-authenticate or allow daemon to refresh",
                )]
            } else {
                let scope_count = token.scopes.len();
                vec![check(
                    "spotify login",
                    Status::Pass,
                    format!(
                        "authenticated with client ID {} ({} scopes)",
                        token.client_id, scope_count
                    ),
                )]
            }
        }
        Ok(None) => {
            vec![check_hint(
                "spotify login",
                Status::Warn,
                "not logged in yet",
                "paste your Spotify Client ID in Halcyon Music to log in via PKCE",
            )]
        }
        Err(e) => {
            vec![check_hint(
                "spotify login",
                Status::Warn,
                format!("keyring/file error: {e}"),
                "paste your Spotify Client ID in Halcyon Music to log in",
            )]
        }
    }
}

fn check_endpoint_probes() -> Vec<Check> {
    use crate::probes::PROBE_TARGETS;
    use halcyon_music_core::models::ProbeStatus;

    let cache = match crate::cache::Cache::open_default() {
        Ok(c) => c,
        Err(_) => {
            return vec![check(
                "endpoint probes",
                Status::Warn,
                "not probed yet (cache not open)",
            )];
        }
    };

    let probes = cache.get_probes().unwrap_or_default();
    let probe_map: std::collections::HashMap<String, _> = probes
        .into_iter()
        .map(|p| (p.endpoint.clone(), p))
        .collect();

    let mut out = Vec::new();
    for target in PROBE_TARGETS {
        let name = target.name;
        if let Some(p) = probe_map.get(name) {
            match p.status {
                ProbeStatus::Available => {
                    out.push(check("endpoint probe", Status::Pass, format!("{name:<20} AVAILABLE")));
                }
                ProbeStatus::Unavailable { code } => {
                    out.push(check_hint(
                        "endpoint probe",
                        Status::Warn,
                        format!("{name:<20} UNAVAILABLE (HTTP {code})"),
                        "Part 5 will automatically route to outside data fallback (Deezer/ListenBrainz)",
                    ));
                }
                ProbeStatus::Unknown => {
                    out.push(check_hint(
                        "endpoint probe",
                        Status::Warn,
                        format!("{name:<20} UNKNOWN"),
                        "probe will retry when connected",
                    ));
                }
            }
        } else {
            out.push(check_hint(
                "endpoint probe",
                Status::Warn,
                format!("{name:<20} NOT PROBED YET"),
                "auto-probes on startup when authenticated",
            ));
        }
    }

    out
}

fn dirs_home() -> std::path::PathBuf {
    std::env::var("HOME").map(std::path::PathBuf::from).unwrap_or_else(|_| Path::new("/tmp").to_path_buf())
}

/// Resolve with a short internal timeout so a broken DNS cannot hang doctor.
trait ToSocketAddrsBest {
    fn to_socket_addrs_best(&self) -> std::net::SocketAddr;
}

impl ToSocketAddrsBest for &str {
    fn to_socket_addrs_best(&self) -> std::net::SocketAddr {
        use std::net::ToSocketAddrs;
        // Best effort: first address, else a dummy that will fail fast.
        self.to_socket_addrs()
            .ok()
            .and_then(|mut it| it.next())
            .unwrap_or_else(|| "127.0.0.1:1".parse().unwrap_or_else(|_| std::net::SocketAddr::from(([127, 0, 0, 1], 1))))
    }
}
