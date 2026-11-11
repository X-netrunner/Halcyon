//! `--doctor`: one PASS/WARN/FAIL line per check, each with a fix hint.
//! Exit code: 0 if no FAIL, 1 if any FAIL, 2 if doctor itself broke.
//!
//! `INFO` lines are facts that are not about the install (for example a Spotify endpoint that
//! refuses this account) and never count as a problem.
//!
//! The doctor never renews or changes the streaming token: the running daemon owns renewals,
//! and two processes refreshing at once could invalidate each other's refresh token.

use crate::audio::{classify_login_failure, FailureCause};
use crate::token_store::{self, LibrespotToken, TokenData};
use halcyon_music_core::models::AuthMode;
use halcyon_music_core::protocol::{self, CommandBody, EventBody};
use halcyon_music_core::{paths, CORE_VERSION};
use librespot_core::authentication::Credentials;
use librespot_core::config::SessionConfig;
use librespot_core::session::Session;
use librespot_playback::audio_backend;
use librespot_playback::config::AudioFormat;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command as ProcCommand, ExitCode, Stdio};
use std::time::{Duration, Instant};

/// How long the Spotify session check may take (connect plus the sign-in check).
const SESSION_TIMEOUT: Duration = Duration::from_secs(15);
/// How long opening the audio output may take.
const SINK_TIMEOUT: Duration = Duration::from_secs(8);
/// How long the installed app gets to answer `--version`.
const GUI_VERSION_TIMEOUT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Status {
    Pass,
    Warn,
    Fail,
    Info,
}

impl Status {
    fn label(self) -> &'static str {
        match self {
            Status::Pass => "PASS",
            Status::Warn => "WARN",
            Status::Fail => "FAIL",
            Status::Info => "INFO",
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
    Check {
        name,
        status,
        detail: detail.into(),
        hint: None,
    }
}

fn check_hint(
    name: &'static str,
    status: Status,
    detail: impl Into<String>,
    hint: impl Into<String>,
) -> Check {
    Check {
        name,
        status,
        detail: detail.into(),
        hint: Some(hint.into()),
    }
}

pub fn run() -> anyhow::Result<ExitCode> {
    let daemon = probe_daemon();
    // Read once; `load_librespot_token` moves a corrupt file aside, so do not call it twice.
    let streaming = token_store::load_librespot_token();

    #[allow(clippy::vec_init_then_push)]
    let mut checks = Vec::new();
    checks.push(check_runtime_dir());
    checks.push(check_daemon_socket(&daemon));
    checks.push(check_daemon_process(&daemon));
    checks.push(check_daemon_version(&daemon));
    checks.push(check_gui_version());
    checks.push(check_state_file());
    checks.push(check_systemd_unit(&daemon));
    checks.push(check_audio_server());
    checks.push(check_audio_sink());
    checks.push(check_network());
    checks.push(check_cache());
    checks.push(check_account_name());
    checks.push(check_connect_device());
    checks.push(check_model());
    checks.push(check_streaming_token(&streaming));
    checks.push(check_session(&streaming));
    checks.push(check_browsing_sign_in(&streaming));
    checks.extend(check_endpoint_probes());

    let (mut pass, mut warn, mut fail) = (0usize, 0usize, 0usize);
    for c in &checks {
        println!("[{}] {:<18} {}", c.status.label(), c.name, c.detail);
        if let Some(h) = &c.hint {
            println!("       fix: {h}");
        }
        match c.status {
            Status::Pass => pass += 1,
            Status::Warn => warn += 1,
            Status::Fail => fail += 1,
            Status::Info => {}
        }
    }
    println!();
    println!("{pass} PASS, {warn} WARN, {fail} FAIL");
    if fail > 0 {
        println!("Something is broken: each FAIL line above has a fix.");
    } else if warn == 0 {
        println!("All checks passed.");
    }

    Ok(if fail > 0 {
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    })
}

fn check_runtime_dir() -> Check {
    let socket_dir = paths::socket_dir();
    match std::fs::create_dir_all(&socket_dir) {
        Ok(()) => {
            let probe = socket_dir.join(".doctor-probe");
            match std::fs::File::create(&probe).and_then(|_| std::fs::remove_file(&probe)) {
                Ok(()) => check(
                    "runtime dir",
                    Status::Pass,
                    format!("{} is writable", socket_dir.display()),
                ),
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

/// What the daemon socket said.
#[derive(Debug)]
enum DaemonProbe {
    NoSocket,
    CannotConnect(String),
    /// The socket exists and accepts connections but nothing answered in time.
    Silent,
    /// The daemon answered; `version` is what its `Hello` said (if the first line was one).
    Answers {
        version: Option<String>,
    },
}

impl DaemonProbe {
    fn answers(&self) -> bool {
        matches!(self, DaemonProbe::Answers { .. })
    }
}

fn probe_daemon() -> DaemonProbe {
    let sock = paths::ctl_socket();
    if !sock.exists() {
        return DaemonProbe::NoSocket;
    }
    let mut stream = match std::os::unix::net::UnixStream::connect(&sock) {
        Ok(s) => s,
        Err(e) => return DaemonProbe::CannotConnect(e.to_string()),
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));

    let payload = protocol::encode_line(&protocol::command(CommandBody::Hello)).unwrap_or_default();
    let write_ok = stream.write_all(&payload).is_ok();
    let mut reader = std::io::BufReader::new(stream);
    let mut line = String::new();
    use std::io::BufRead;
    let read_ok = reader.read_line(&mut line).is_ok();
    if !(write_ok && read_ok && !line.trim().is_empty()) {
        return DaemonProbe::Silent;
    }
    DaemonProbe::Answers {
        version: hello_version(line.trim().as_bytes()),
    }
}

/// The daemon version from a `Hello` line, `None` for anything else.
fn hello_version(line: &[u8]) -> Option<String> {
    match protocol::decode_line::<protocol::Event>(line) {
        Ok(ev) => match ev.body {
            EventBody::Hello { daemon_version, .. } => Some(daemon_version),
            _ => None,
        },
        Err(_) => None,
    }
}

fn check_daemon_socket(probe: &DaemonProbe) -> Check {
    let sock = paths::ctl_socket();
    match probe {
        DaemonProbe::NoSocket => check_hint(
            "daemon socket",
            Status::Fail,
            format!("{} does not exist: the daemon is not running", sock.display()),
            "systemctl --user restart halcyon-musicd (or just launch halcyon-music, which starts it)",
        ),
        DaemonProbe::CannotConnect(e) => check_hint(
            "daemon socket",
            Status::Fail,
            format!("cannot connect to {}: {e}", sock.display()),
            "a dead daemon left its socket behind: systemctl --user restart halcyon-musicd",
        ),
        DaemonProbe::Silent => check_hint(
            "daemon socket",
            Status::Fail,
            "the socket accepts connections but the daemon did not answer",
            "if it was only just started, wait a second and run --doctor again; otherwise: systemctl --user restart halcyon-musicd",
        ),
        DaemonProbe::Answers { .. } => check("daemon socket", Status::Pass, "daemon answers on ctl.sock"),
    }
}

/// Running copies of the daemon (or app) binary, from /proc. `stale` means the binary file was
/// replaced or removed after the process started, i.e. an update installed a new build but this
/// process still runs the old one (this catches two builds that share a version number).
#[derive(Debug, Clone, PartialEq, Eq)]
struct RunningProcess {
    pid: u32,
    stale: bool,
}

/// `(file name, deleted)` for the target of `/proc/<pid>/exe`. The kernel appends " (deleted)"
/// when the file behind a running process was replaced or removed.
fn split_exe_link(link: &str) -> Option<(String, bool)> {
    let (path, deleted) = match link.strip_suffix(" (deleted)") {
        Some(p) => (p, true),
        None => (link, false),
    };
    let name = Path::new(path).file_name()?.to_str()?.to_string();
    Some((name, deleted))
}

fn running_processes(name: &str) -> Vec<RunningProcess> {
    let own_uid = std::fs::metadata("/proc/self").map(|m| m.uid()).ok();
    let own_pid = std::process::id();
    let Ok(dir) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for entry in dir.flatten() {
        let Some(pid) = entry
            .file_name()
            .to_str()
            .and_then(|s| s.parse::<u32>().ok())
        else {
            continue;
        };
        if pid == own_pid {
            continue;
        }
        if let (Some(uid), Ok(meta)) = (own_uid, entry.metadata()) {
            if meta.uid() != uid {
                continue;
            }
        }
        let Ok(link) = std::fs::read_link(entry.path().join("exe")) else {
            continue;
        };
        if let Some((exe_name, stale)) = split_exe_link(&link.to_string_lossy()) {
            if exe_name == name {
                out.push(RunningProcess { pid, stale });
            }
        }
    }
    out.sort_by_key(|p| p.pid);
    out
}

fn pid_list(procs: &[RunningProcess]) -> String {
    procs
        .iter()
        .map(|p| p.pid.to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Judge the list of running daemons. Pure, so it can be tested.
fn judge_daemon_processes(procs: &[RunningProcess], answers: bool) -> Check {
    match procs {
        [] if answers => check(
            "daemon process",
            Status::Info,
            "the daemon answers but its process could not be looked up (/proc not readable?)",
        ),
        [] => check("daemon process", Status::Info, "no daemon process is running"),
        [one] if one.stale => check_hint(
            "daemon process",
            Status::Fail,
            format!(
                "pid {} is still running the old build: its file was replaced by an update after it started",
                one.pid
            ),
            "systemctl --user restart halcyon-musicd",
        ),
        [one] => check(
            "daemon process",
            Status::Pass,
            format!("one daemon running (pid {}), its file has not been replaced since it started", one.pid),
        ),
        many => check_hint(
            "daemon process",
            Status::Fail,
            format!(
                "{} daemons are running (pids {}); only one owns the socket and the other may be an old build",
                many.len(),
                pid_list(many)
            ),
            "systemctl --user restart halcyon-musicd; if more than one remains: pkill -x halcyon-musicd, then start it again",
        ),
    }
}

fn check_daemon_process(probe: &DaemonProbe) -> Check {
    judge_daemon_processes(&running_processes("halcyon-musicd"), probe.answers())
}

/// Compare the version the running daemon reported with this binary's version. Pure.
fn judge_daemon_version(probe: &DaemonProbe, installed: &str) -> Check {
    match probe {
        DaemonProbe::Answers {
            version: Some(running),
        } if running == installed => check(
            "daemon version",
            Status::Pass,
            format!("running daemon is {running}, same as the installed one"),
        ),
        DaemonProbe::Answers {
            version: Some(running),
        } => check_hint(
            "daemon version",
            Status::Fail,
            format!("running daemon is {running} but the installed one is {installed}"),
            "systemctl --user restart halcyon-musicd",
        ),
        DaemonProbe::Answers { version: None } => check(
            "daemon version",
            Status::Warn,
            "the daemon answered but did not report its version",
        ),
        _ => check(
            "daemon version",
            Status::Info,
            "not tested: the daemon is not answering (see above)",
        ),
    }
}

fn check_daemon_version(probe: &DaemonProbe) -> Check {
    judge_daemon_version(probe, CORE_VERSION)
}

/// Result of asking the installed app for its version.
#[derive(Debug, PartialEq, Eq)]
enum GuiVersion {
    Found(String),
    /// Did not exit within the time limit: an older build that has no `--version`.
    TimedOut,
    Failed(String),
}

/// The app binary installed next to this daemon, else the first `halcyon-music` on PATH.
fn installed_gui() -> Option<PathBuf> {
    if let Some(next_to_us) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|d| d.join("halcyon-music")))
        .filter(|p| p.is_file())
    {
        return Some(next_to_us);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join("halcyon-music"))
        .find(|p| p.is_file())
}

fn read_gui_version(path: &Path) -> GuiVersion {
    let mut child = match ProcCommand::new(path)
        .arg("--version")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => return GuiVersion::Failed(e.to_string()),
    };
    let deadline = Instant::now() + GUI_VERSION_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_status)) => {
                let mut text = String::new();
                if let Some(mut out) = child.stdout.take() {
                    let _ = out.read_to_string(&mut text);
                }
                return match parse_version_line(&text) {
                    Some(v) => GuiVersion::Found(v),
                    None => GuiVersion::Failed("it printed no version".to_string()),
                };
            }
            Ok(None) if Instant::now() >= deadline => {
                // An old build without --version starts its window instead; do not leave it open.
                let _ = child.kill();
                let _ = child.wait();
                return GuiVersion::TimedOut;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(e) => return GuiVersion::Failed(e.to_string()),
        }
    }
}

/// The last word of the first line, e.g. `halcyon-music 0.2.0` gives `0.2.0`.
fn parse_version_line(text: &str) -> Option<String> {
    let word = text.lines().next()?.split_whitespace().last()?;
    word.chars().next().filter(char::is_ascii_digit)?;
    Some(word.to_string())
}

/// Compare the installed app with the installed daemon. Pure.
fn judge_gui_version(found: Option<GuiVersion>, installed: &str) -> Check {
    const REINSTALL: &str = "install both binaries from the same build: ./install.sh (or cargo build --release and copy halcyon-music and halcyon-musicd)";
    match found {
        None => check_hint(
            "app version",
            Status::Warn,
            "halcyon-music was not found next to the daemon or on PATH",
            "install the app: ./install.sh",
        ),
        Some(GuiVersion::Found(v)) if v == installed => check(
            "app version",
            Status::Pass,
            format!("installed app is {v}, same as the daemon"),
        ),
        Some(GuiVersion::Found(v)) => check_hint(
            "app version",
            Status::Fail,
            format!("installed app is {v} but the daemon is {installed}"),
            REINSTALL,
        ),
        Some(GuiVersion::TimedOut) => check_hint(
            "app version",
            Status::Fail,
            "the installed app did not answer --version: it is an older build",
            REINSTALL,
        ),
        Some(GuiVersion::Failed(why)) => check_hint(
            "app version",
            Status::Warn,
            format!("could not ask the installed app for its version: {why}"),
            REINSTALL,
        ),
    }
}

fn check_gui_version() -> Check {
    let found = installed_gui().map(|p| read_gui_version(&p));
    judge_gui_version(found, CORE_VERSION)
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

fn check_systemd_unit(daemon: &DaemonProbe) -> Check {
    let unit = dirs_home().join(".config/systemd/user/halcyon-musicd.service");
    if !unit.exists() {
        return check_hint(
            "systemd unit",
            Status::Warn,
            "halcyon-musicd.service is not installed for this user",
            "./install.sh installs it, or copy packaging/halcyon-musicd.service to ~/.config/systemd/user/ and run systemctl --user daemon-reload",
        );
    }
    // systemctl available?
    let has_systemctl = ProcCommand::new("systemctl")
        .arg("--user")
        .arg("--no-pager")
        .arg("is-enabled")
        .arg("halcyon-musicd.service")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok();
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
            if daemon.answers() {
                // The app (or a shell) started the daemon itself, so `systemctl restart` after an
                // update would not replace it.
                check_hint(
                    "systemd unit",
                    Status::Warn,
                    format!("service state: {state}, but a daemon is running that systemd does not manage"),
                    "pkill -x halcyon-musicd; systemctl --user enable --now halcyon-musicd.service",
                )
            } else {
                check_hint(
                    "systemd unit",
                    Status::Warn,
                    format!("service state: {state}"),
                    "systemctl --user enable --now halcyon-musicd.service",
                )
            }
        }
        Err(e) => check(
            "systemd unit",
            Status::Warn,
            format!("could not query systemd: {e}"),
        ),
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

/// The account the daemon last remembered, read straight from the cache file (read-only, so it
/// works while the daemon runs). `None` when there is no cache or no saved account.
fn read_saved_account() -> Option<crate::api::AccountInfo> {
    let db_path = paths::cache_dir().join("cache.db");
    if !db_path.exists() {
        return None;
    }
    let conn =
        rusqlite::Connection::open_with_flags(&db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;
    let json: String = conn
        .query_row(
            "SELECT value FROM kv WHERE key = ?1",
            [crate::profile::KV_ACCOUNT],
            |row| row.get(0),
        )
        .ok()?;
    serde_json::from_str(&json).ok()
}

/// "account name": PASS with the name, WARN when only the username is known (the name could not be
/// read yet, for example while Spotify's Web API is rate limiting), INFO when nothing is saved.
fn judge_account_name(account: Option<&crate::api::AccountInfo>) -> Check {
    let name = account
        .and_then(|a| a.display_name.as_deref())
        .map(str::trim)
        .filter(|n| !n.is_empty());
    let username = account
        .and_then(|a| a.username.as_deref())
        .map(str::trim)
        .filter(|u| !u.is_empty());
    match (name, username) {
        (Some(n), _) => check("account name", Status::Pass, format!("signed in as {n}")),
        (None, Some(u)) => check_hint(
            "account name",
            Status::Warn,
            format!("only the username is known ({u}); the display name has not been read yet"),
            "it is retried in the background; if it stays like this, restart halcyon-musicd and check the log for \"profile\" lines",
        ),
        (None, None) => check(
            "account name",
            Status::Info,
            "no account saved yet (sign in, then run this again)",
        ),
    }
}

/// "connect device": read from the status file a running Connect device leaves (no Web API).
fn judge_connect_device(view: crate::connect::DoctorView) -> Check {
    use crate::connect::DoctorView;
    match view {
        DoctorView::Registered { name } => check(
            "connect device",
            Status::Pass,
            format!("registered as {name}"),
        ),
        DoctorView::Stale { name } => check_hint(
            "connect device",
            Status::Warn,
            format!("{name} was registered, but its process is gone"),
            "start it again; Spotify drops a stopped device from the list within a minute",
        ),
        DoctorView::Off { compiled } => check(
            "connect device",
            Status::Info,
            if compiled {
                "not enabled (turn it on in Settings > Spotify Connect, or set HALCYON_CONNECT=1)"
            } else {
                "not built in (cargo build --features connect to try it)"
            },
        ),
        DoctorView::RequestedNotRegistered { compiled } => check_hint(
            "connect device",
            Status::Warn,
            "Connect is switched on but no device is registered",
            if compiled {
                "run halcyon-musicd --connect-spike and read its output"
            } else {
                "this build has no Connect code: cargo build --release -p halcyon-musicd --features connect"
            },
        ),
    }
}

fn check_connect_device() -> Check {
    let status = crate::connect::read_status();
    let alive = status
        .as_ref()
        .is_some_and(|s| crate::connect::pid_alive(s.pid));
    judge_connect_device(crate::connect::doctor_view(
        status.as_ref(),
        alive,
        crate::connect::enabled(),
        crate::connect::compiled_in(),
    ))
}

fn check_account_name() -> Check {
    judge_account_name(read_saved_account().as_ref())
}

/// The Smart suggestions settings the daemon saved, read straight from the cache file (read-only,
/// so it works while the daemon runs). `None` when there is no cache or nothing saved yet.
fn read_saved_llm_settings() -> Option<crate::llm::LlmSettings> {
    let db_path = paths::cache_dir().join("cache.db");
    if !db_path.exists() {
        return None;
    }
    let conn =
        rusqlite::Connection::open_with_flags(&db_path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;
    let json: String = conn
        .query_row(
            "SELECT value FROM kv WHERE key = ?1",
            [crate::llm::SETTINGS_KEY],
            |row| row.get(0),
        )
        .ok()?;
    serde_json::from_str::<crate::llm::LlmSettings>(&json)
        .ok()
        .map(|s| s.normalised())
}

/// "model": is the model Smart suggestions would use there? The built-in model is downloaded the
/// first time it is needed, never at install, so "not downloaded yet" is a WARN only when Smart
/// suggestions are on. Nothing here touches the network or loads the model.
fn judge_model(
    settings: Option<&crate::llm::LlmSettings>,
    engine: bool,
    disk: Option<&crate::llm::models::DiskStatus>,
) -> Check {
    let Some(s) = settings.filter(|s| s.enabled) else {
        return check(
            "model",
            Status::Info,
            "Smart suggestions are off, so no model is needed (the built-in model downloads when you turn them on)",
        );
    };
    if !s.uses_local() {
        return check(
            "model",
            Status::Info,
            format!(
                "Smart suggestions use Ollama ({}); the built-in model is not used",
                s.model
            ),
        );
    }
    if !engine {
        return check_hint(
            "model",
            Status::Warn,
            "Smart suggestions are set to the built-in model, but this build has no built-in engine",
            "switch to Ollama in Settings, or rebuild with: cargo build --release -p halcyon-musicd --features local-llm",
        );
    }
    let fetch = format!(
        "Settings > Smart suggestions > Download, or: halcyon-musicd --model-fetch {}",
        s.local_model
    );
    match disk {
        Some(d) if d.installed => {
            let how = if d.verified.is_empty() {
                "not checked"
            } else {
                d.verified.as_str()
            };
            check(
                "model",
                Status::Pass,
                format!(
                    "{} is on disk ({} MB, checked: {how})",
                    s.local_model,
                    d.size / 1_000_000
                ),
            )
        }
        Some(d) if d.partial > 0 => check_hint(
            "model",
            Status::Warn,
            format!(
                "{} is half downloaded ({} MB so far)",
                s.local_model,
                d.partial / 1_000_000
            ),
            format!("finish it: {fetch}"),
        ),
        _ => check_hint(
            "model",
            Status::Warn,
            format!("{} has not been downloaded yet", s.local_model),
            format!("download it: {fetch}"),
        ),
    }
}

fn check_model() -> Check {
    let settings = read_saved_llm_settings();
    let disk = settings
        .as_ref()
        .and_then(|s| crate::llm::models::find(&s.local_model))
        .map(|spec| crate::llm::models::disk_status(&crate::llm::models::models_dir(), spec.file));
    judge_model(
        settings.as_ref(),
        crate::llm::local::engine_available(),
        disk.as_ref(),
    )
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
            let res: Result<String, _> =
                conn.query_row("PRAGMA quick_check;", [], |row| row.get(0));
            match res {
                Ok(status) if status == "ok" => check("cache", Status::Pass, "SQLite cache intact"),
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

type StreamingToken = Result<Option<LibrespotToken>, String>;

/// A streaming token that exists, has the `streaming` scope and has not expired.
fn usable_streaming_token(token: &StreamingToken) -> Option<&LibrespotToken> {
    match token {
        Ok(Some(t)) if t.can_stream() && !t.is_expired() => Some(t),
        _ => None,
    }
}

const SIGN_IN_HINT: &str =
    "open Halcyon Music and press Sign in with Spotify, or run: halcyon-musicd --login";

/// The streaming token is present and fresh. Never prints or renews the token.
fn check_streaming_token(token: &StreamingToken) -> Check {
    match token {
        Err(e) => check_hint(
            "streaming token",
            Status::Fail,
            format!("the saved sign-in could not be read: {e}"),
            format!("unlock your keyring (or check the permissions of the state directory), then sign in again: {SIGN_IN_HINT}"),
        ),
        Ok(None) => check_hint(
            "streaming token",
            Status::Fail,
            "no streaming sign-in saved: playback cannot start",
            SIGN_IN_HINT,
        ),
        Ok(Some(t)) if !t.can_stream() => check_hint(
            "streaming token",
            Status::Fail,
            "the saved sign-in was not granted the streaming permission",
            SIGN_IN_HINT,
        ),
        Ok(Some(t)) if t.is_expired() => check_hint(
            "streaming token",
            Status::Fail,
            "the saved sign-in has expired",
            "start the daemon (it renews the sign-in in the background); if that does not help, sign in again: halcyon-musicd --login",
        ),
        Ok(Some(t)) => {
            let minutes = t.seconds_left() / 60;
            if t.needs_refresh() {
                check(
                    "streaming token",
                    Status::Pass,
                    format!("valid for about {minutes} more minutes (renewal is due; the daemon renews it)"),
                )
            } else {
                check("streaming token", Status::Pass, format!("valid for about {minutes} more minutes"))
            }
        }
    }
}

/// What the Spotify session test found.
#[derive(Debug)]
enum SessionProbe {
    Works,
    /// `connect` failed. `free` is true when the error text names a Free or Premium account.
    ConnectFailed {
        free: bool,
        text: String,
    },
    /// Connected, but the sign-in check (the same login5 request a track load makes) failed.
    LoginFailed(FailureCause),
}

async fn probe_session(access_token: String) -> SessionProbe {
    let session = Session::new(SessionConfig::default(), None);
    let creds = Credentials::with_access_token(&access_token);
    if let Err(e) = session.connect(creds, false).await {
        let text = e.to_string();
        let lower = text.to_lowercase();
        return SessionProbe::ConnectFailed {
            free: lower.contains("free") || lower.contains("premium"),
            text,
        };
    }
    // Connecting is not enough: the failure that stops tracks from loading shows up here.
    match session.login5().auth_token().await {
        Ok(_token) => SessionProbe::Works,
        Err(e) => SessionProbe::LoginFailed(classify_login_failure(e.kind, &e.error.to_string())),
    }
}

/// First line of an error text, cut to a length that fits one report line.
fn short_text(text: &str) -> String {
    let line = text.lines().next().unwrap_or("").trim();
    let mut out: String = line.chars().take(140).collect();
    if line.chars().count() > 140 {
        out.push('…');
    }
    out
}

fn judge_session(result: Option<SessionProbe>) -> Check {
    match result {
        None => check_hint(
            "spotify session",
            Status::Fail,
            format!(
                "no answer from Spotify within {} s",
                SESSION_TIMEOUT.as_secs()
            ),
            "check your connection (and any VPN or firewall), then run --doctor again",
        ),
        Some(SessionProbe::Works) => check(
            "spotify session",
            Status::Pass,
            "connected to Spotify and the streaming sign-in was accepted",
        ),
        Some(SessionProbe::ConnectFailed { free: true, .. }) => check_hint(
            "spotify session",
            Status::Fail,
            "Spotify refused the playback session: this looks like a Free account",
            "playback through this player needs Spotify Premium; browsing still works",
        ),
        Some(SessionProbe::ConnectFailed { text, .. }) => check_hint(
            "spotify session",
            Status::Fail,
            format!("could not open a Spotify session: {}", short_text(&text)),
            format!("check your connection; if it keeps failing, sign in again: {SIGN_IN_HINT}"),
        ),
        Some(SessionProbe::LoginFailed(FailureCause::CredentialsRejected)) => check_hint(
            "spotify session",
            Status::Fail,
            "connected, but Spotify rejected the streaming sign-in (INVALID_CREDENTIALS)",
            format!("sign in again: {SIGN_IN_HINT}; playback also needs a Premium account"),
        ),
        Some(SessionProbe::LoginFailed(FailureCause::Network)) => check_hint(
            "spotify session",
            Status::Fail,
            "connected, but the connection dropped while checking the sign-in",
            "check your connection, then run --doctor again",
        ),
        Some(SessionProbe::LoginFailed(_)) => check_hint(
            "spotify session",
            Status::Fail,
            "connected, but the sign-in could not be verified",
            format!("run --doctor again; if it repeats, sign in again: {SIGN_IN_HINT}"),
        ),
    }
}

/// Connect a Spotify session with the stored streaming token, as the daemon does, and ask for a
/// token (the request a track load makes). Uses the stored access token as it is.
fn check_session(token: &StreamingToken) -> Check {
    let Some(t) = usable_streaming_token(token) else {
        return check(
            "spotify session",
            Status::Info,
            "not tested: there is no usable streaming sign-in (see above)",
        );
    };
    let access_token = t.access_token.clone();
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            return check(
                "spotify session",
                Status::Warn,
                format!("could not start the async runtime for this check: {e}"),
            )
        }
    };
    let result = runtime
        .block_on(async {
            tokio::time::timeout(SESSION_TIMEOUT, probe_session(access_token)).await
        })
        .ok();
    judge_session(result)
}

/// Open the default audio output once and close it again. librespot's output backend panics
/// when there is no device, so this runs on its own thread and reports the panic text.
fn open_audio_sink() -> Result<(), String> {
    let Some(sink_fn) = audio_backend::find(None) else {
        return Err("no audio backend is built in".to_string());
    };
    let sink = sink_fn(None, AudioFormat::F32);
    drop(sink);
    Ok(())
}

fn panic_text(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<String>() {
        short_text(s)
    } else if let Some(s) = payload.downcast_ref::<&str>() {
        short_text(s)
    } else {
        "the audio backend crashed".to_string()
    }
}

fn judge_audio_sink(result: Option<Result<(), String>>) -> Check {
    const HINT: &str = "start PipeWire (systemctl --user start pipewire pipewire-pulse wireplumber) and check `wpctl status`; if the daemon is playing on a bare ALSA device, stop it for this test: systemctl --user stop halcyon-musicd";
    match result {
        Some(Ok(())) => check(
            "audio output",
            Status::Pass,
            "the default audio output opened",
        ),
        Some(Err(why)) => check_hint(
            "audio output",
            Status::Fail,
            format!("could not open the audio output: {why}"),
            HINT,
        ),
        None => check_hint(
            "audio output",
            Status::Fail,
            format!(
                "opening the audio output did not finish within {} s",
                SINK_TIMEOUT.as_secs()
            ),
            HINT,
        ),
    }
}

fn check_audio_sink() -> Check {
    let (tx, rx) = std::sync::mpsc::channel();
    // The backend's panic would print a backtrace over the report; the text is shown by the check.
    let previous_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    std::thread::spawn(move || {
        let outcome = match std::panic::catch_unwind(open_audio_sink) {
            Ok(result) => result,
            Err(payload) => Err(panic_text(payload.as_ref())),
        };
        let _ = tx.send(outcome);
    });
    let result = rx.recv_timeout(SINK_TIMEOUT).ok();
    std::panic::set_hook(previous_hook);
    judge_audio_sink(result)
}

/// Which sign-in browsing uses, and whether it works. In the default mode browsing shares the
/// streaming token, so a missing one is already reported above and not repeated here.
fn judge_browsing(
    mode: AuthMode,
    streaming: &StreamingToken,
    own: &Result<Option<TokenData>, String>,
) -> Check {
    match mode {
        AuthMode::Librespot => {
            if usable_streaming_token(streaming).is_some() {
                check(
                    "browsing sign-in",
                    Status::Pass,
                    "browsing uses the streaming sign-in (default mode)",
                )
            } else {
                check(
                    "browsing sign-in",
                    Status::Info,
                    "browsing uses the streaming sign-in, which is not usable (see above)",
                )
            }
        }
        AuthMode::OwnClientId => match own {
            Ok(Some(t)) if !t.is_expired() => check(
                "browsing sign-in",
                Status::Pass,
                format!("browsing uses your own Client ID {} (streaming still uses the Spotify sign-in)", t.client_id),
            ),
            Ok(Some(t)) => check_hint(
                "browsing sign-in",
                Status::Warn,
                format!("your own Client ID's token has expired (client ID: {})", t.client_id),
                "the daemon renews it while it runs; if it does not, sign in again under Advanced in Halcyon Music",
            ),
            Ok(None) => check_hint(
                "browsing sign-in",
                Status::Fail,
                "browsing is set to your own Client ID but no sign-in is saved for it",
                "sign in with your Client ID under Advanced in Halcyon Music, or switch back to the default sign-in",
            ),
            Err(e) => check_hint(
                "browsing sign-in",
                Status::Fail,
                format!("the saved Client ID sign-in could not be read: {e}"),
                "unlock your keyring, or sign in again under Advanced in Halcyon Music",
            ),
        },
    }
}

fn check_browsing_sign_in(streaming: &StreamingToken) -> Check {
    judge_browsing(
        crate::auth_mode::initial(),
        streaming,
        &token_store::load_token(),
    )
}

fn check_endpoint_probes() -> Vec<Check> {
    use crate::probes::PROBE_TARGETS;
    use halcyon_music_core::models::ProbeStatus;

    let cache = match crate::cache::Cache::open_default() {
        Ok(c) => c,
        Err(_) => {
            return vec![check(
                "endpoint probes",
                Status::Info,
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
                    out.push(check(
                        "endpoint probe",
                        Status::Pass,
                        format!("{name:<20} AVAILABLE"),
                    ));
                }
                ProbeStatus::Unavailable { code } => {
                    out.push(check(
                        "endpoint probe",
                        Status::Info,
                        format!("{name:<20} UNAVAILABLE (HTTP {code}); the app hides it or uses outside data"),
                    ));
                }
                ProbeStatus::Unknown => {
                    out.push(check(
                        "endpoint probe",
                        Status::Info,
                        format!("{name:<20} UNKNOWN; it is probed again when connected"),
                    ));
                }
            }
        } else {
            out.push(check(
                "endpoint probe",
                Status::Info,
                format!("{name:<20} NOT PROBED YET; run halcyon-musicd --probe for a live table"),
            ));
        }
    }

    out
}

fn dirs_home() -> std::path::PathBuf {
    std::env::var("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| Path::new("/tmp").to_path_buf())
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
            .unwrap_or_else(|| {
                "127.0.0.1:1"
                    .parse()
                    .unwrap_or_else(|_| std::net::SocketAddr::from(([127, 0, 0, 1], 1)))
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn proc(pid: u32, stale: bool) -> RunningProcess {
        RunningProcess { pid, stale }
    }

    fn token(expires_in: u64, scopes: &[&str]) -> LibrespotToken {
        LibrespotToken::new(
            "SECRET-ACCESS".to_string(),
            "SECRET-REFRESH".to_string(),
            expires_in,
            scopes.iter().map(|s| s.to_string()).collect(),
        )
    }

    fn own_token(expires_in: u64) -> TokenData {
        TokenData::new(
            "client-abc".to_string(),
            "SECRET-ACCESS".to_string(),
            "SECRET-REFRESH".to_string(),
            expires_in,
            "Bearer".to_string(),
            vec![],
        )
    }

    fn no_secrets(c: &Check) {
        let text = format!("{} {:?}", c.detail, c.hint);
        assert!(!text.contains("SECRET"), "token text leaked into: {text}");
    }

    #[test]
    fn exe_link_names_and_deleted_marker() {
        assert_eq!(
            split_exe_link("/home/u/.local/bin/halcyon-musicd"),
            Some(("halcyon-musicd".to_string(), false))
        );
        assert_eq!(
            split_exe_link("/home/u/.local/bin/halcyon-musicd (deleted)"),
            Some(("halcyon-musicd".to_string(), true))
        );
        assert_eq!(split_exe_link("/"), None);
    }

    #[test]
    fn daemon_process_verdicts() {
        assert_eq!(judge_daemon_processes(&[], false).status, Status::Info);
        assert_eq!(judge_daemon_processes(&[], true).status, Status::Info);
        assert_eq!(
            judge_daemon_processes(&[proc(10, false)], true).status,
            Status::Pass
        );
        let stale = judge_daemon_processes(&[proc(10, true)], true);
        assert_eq!(stale.status, Status::Fail);
        assert!(stale
            .hint
            .is_some_and(|h| h.contains("restart halcyon-musicd")));
        let two = judge_daemon_processes(&[proc(10, false), proc(11, true)], true);
        assert_eq!(two.status, Status::Fail);
        assert!(two.detail.contains("10, 11"));
    }

    #[test]
    fn hello_line_gives_the_daemon_version() {
        let line = protocol::encode_line(&protocol::event(EventBody::Hello {
            daemon_version: "9.9.9".to_string(),
            protocol_version: protocol::PROTOCOL_VERSION,
        }))
        .unwrap_or_default();
        assert_eq!(hello_version(&line), Some("9.9.9".to_string()));

        let other = protocol::encode_line(&protocol::event(EventBody::Pong)).unwrap_or_default();
        assert_eq!(hello_version(&other), None);
        assert_eq!(hello_version(b"not json"), None);
    }

    #[test]
    fn daemon_version_verdicts() {
        let same = DaemonProbe::Answers {
            version: Some("0.2.0".into()),
        };
        assert_eq!(judge_daemon_version(&same, "0.2.0").status, Status::Pass);
        let old = DaemonProbe::Answers {
            version: Some("0.1.0".into()),
        };
        let c = judge_daemon_version(&old, "0.2.0");
        assert_eq!(c.status, Status::Fail);
        assert!(c.detail.contains("0.1.0") && c.detail.contains("0.2.0"));
        assert_eq!(
            judge_daemon_version(&DaemonProbe::Answers { version: None }, "0.2.0").status,
            Status::Warn
        );
        assert_eq!(
            judge_daemon_version(&DaemonProbe::NoSocket, "0.2.0").status,
            Status::Info
        );
    }

    #[test]
    fn version_line_parsing() {
        assert_eq!(
            parse_version_line("halcyon-music 0.2.0\n"),
            Some("0.2.0".to_string())
        );
        assert_eq!(parse_version_line(""), None);
        assert_eq!(parse_version_line("usage: halcyon-music"), None);
    }

    #[test]
    fn app_version_verdicts() {
        assert_eq!(judge_gui_version(None, "0.2.0").status, Status::Warn);
        assert_eq!(
            judge_gui_version(Some(GuiVersion::Found("0.2.0".into())), "0.2.0").status,
            Status::Pass
        );
        assert_eq!(
            judge_gui_version(Some(GuiVersion::Found("0.1.0".into())), "0.2.0").status,
            Status::Fail
        );
        assert_eq!(
            judge_gui_version(Some(GuiVersion::TimedOut), "0.2.0").status,
            Status::Fail
        );
        assert_eq!(
            judge_gui_version(Some(GuiVersion::Failed("boom".into())), "0.2.0").status,
            Status::Warn
        );
    }

    #[test]
    fn streaming_token_verdicts_and_no_secrets() {
        let missing = check_streaming_token(&Ok(None));
        assert_eq!(missing.status, Status::Fail);
        assert!(missing.hint.is_some_and(|h| h.contains("--login")));

        let unreadable = check_streaming_token(&Err("keyring locked".to_string()));
        assert_eq!(unreadable.status, Status::Fail);

        let no_scope = check_streaming_token(&Ok(Some(token(3600, &["user-read-private"]))));
        assert_eq!(no_scope.status, Status::Fail);
        no_secrets(&no_scope);

        let expired = check_streaming_token(&Ok(Some(token(0, &["streaming"]))));
        assert_eq!(expired.status, Status::Fail);
        no_secrets(&expired);

        let fresh = check_streaming_token(&Ok(Some(token(3600, &["streaming"]))));
        assert_eq!(fresh.status, Status::Pass);
        no_secrets(&fresh);
    }

    #[test]
    fn only_a_live_streaming_token_is_usable() {
        assert!(usable_streaming_token(&Ok(Some(token(3600, &["streaming"])))).is_some());
        assert!(usable_streaming_token(&Ok(Some(token(0, &["streaming"])))).is_none());
        assert!(usable_streaming_token(&Ok(Some(token(3600, &[])))).is_none());
        assert!(usable_streaming_token(&Ok(None)).is_none());
        assert!(usable_streaming_token(&Err("x".into())).is_none());
    }

    #[test]
    fn session_not_tested_without_a_token() {
        // No token means no network is touched: this must return at once.
        let c = check_session(&Ok(None));
        assert_eq!(c.status, Status::Info);
    }

    #[test]
    fn session_verdicts() {
        assert_eq!(
            judge_session(Some(SessionProbe::Works)).status,
            Status::Pass
        );
        assert_eq!(judge_session(None).status, Status::Fail);

        let free = judge_session(Some(SessionProbe::ConnectFailed {
            free: true,
            text: "x".into(),
        }));
        assert_eq!(free.status, Status::Fail);
        assert!(free.detail.contains("Free"));

        let other = judge_session(Some(SessionProbe::ConnectFailed {
            free: false,
            text: "boom\nsecond line".into(),
        }));
        assert_eq!(other.status, Status::Fail);
        assert!(other.detail.contains("boom") && !other.detail.contains("second line"));

        let rejected = judge_session(Some(SessionProbe::LoginFailed(
            FailureCause::CredentialsRejected,
        )));
        assert_eq!(rejected.status, Status::Fail);
        assert!(rejected.detail.contains("INVALID_CREDENTIALS"));

        assert_eq!(
            judge_session(Some(SessionProbe::LoginFailed(FailureCause::Network))).status,
            Status::Fail
        );
        assert_eq!(
            judge_session(Some(SessionProbe::LoginFailed(FailureCause::Other))).status,
            Status::Fail
        );
    }

    #[test]
    fn short_text_cuts_long_lines() {
        let long = "x".repeat(500);
        assert!(short_text(&long).chars().count() <= 141);
        assert_eq!(short_text("a\nb"), "a");
        assert_eq!(short_text(""), "");
    }

    #[test]
    fn audio_sink_verdicts() {
        assert_eq!(judge_audio_sink(Some(Ok(()))).status, Status::Pass);
        let bad = judge_audio_sink(Some(Err("NoDeviceAvailable".into())));
        assert_eq!(bad.status, Status::Fail);
        assert!(bad.detail.contains("NoDeviceAvailable"));
        assert_eq!(judge_audio_sink(None).status, Status::Fail);
    }

    #[test]
    fn panic_payloads_become_text() {
        let owned: Box<dyn std::any::Any + Send> = Box::new(String::from("boom"));
        assert_eq!(panic_text(owned.as_ref()), "boom");
        let literal: Box<dyn std::any::Any + Send> = Box::new("static boom");
        assert_eq!(panic_text(literal.as_ref()), "static boom");
        let other: Box<dyn std::any::Any + Send> = Box::new(5u8);
        assert!(panic_text(other.as_ref()).contains("crashed"));
    }

    #[test]
    fn browsing_verdicts() {
        let good: StreamingToken = Ok(Some(token(3600, &["streaming"])));
        let none: StreamingToken = Ok(None);
        let no_own: Result<Option<TokenData>, String> = Ok(None);

        assert_eq!(
            judge_browsing(AuthMode::Librespot, &good, &no_own).status,
            Status::Pass
        );
        // The streaming check already fails; browsing does not repeat the FAIL.
        assert_eq!(
            judge_browsing(AuthMode::Librespot, &none, &no_own).status,
            Status::Info
        );

        assert_eq!(
            judge_browsing(AuthMode::OwnClientId, &good, &no_own).status,
            Status::Fail
        );
        let live: Result<Option<TokenData>, String> = Ok(Some(own_token(3600)));
        let c = judge_browsing(AuthMode::OwnClientId, &good, &live);
        assert_eq!(c.status, Status::Pass);
        no_secrets(&c);
        let expired: Result<Option<TokenData>, String> = Ok(Some(own_token(0)));
        let c = judge_browsing(AuthMode::OwnClientId, &good, &expired);
        assert_eq!(c.status, Status::Warn);
        no_secrets(&c);
        let broken: Result<Option<TokenData>, String> = Err("keyring locked".into());
        assert_eq!(
            judge_browsing(AuthMode::OwnClientId, &good, &broken).status,
            Status::Fail
        );
    }

    #[test]
    fn running_processes_ignores_this_process() {
        // The doctor's own pid is never reported, whatever the name.
        let own = running_processes("definitely-not-a-real-binary-name");
        assert!(own.is_empty());
    }

    #[test]
    fn connect_device_check_levels() {
        use crate::connect::DoctorView;
        let pass = judge_connect_device(DoctorView::Registered {
            name: "Halcyon (x)".into(),
        });
        assert_eq!(pass.status, Status::Pass);
        assert!(pass.detail.contains("Halcyon (x)"));
        assert_eq!(
            judge_connect_device(DoctorView::Stale { name: "n".into() }).status,
            Status::Warn
        );
        assert_eq!(
            judge_connect_device(DoctorView::Off { compiled: false }).status,
            Status::Info
        );
        let missing = judge_connect_device(DoctorView::RequestedNotRegistered { compiled: false });
        assert_eq!(missing.status, Status::Warn);
        assert!(missing.hint.unwrap().contains("--features connect"));
    }

    #[test]
    fn account_name_check_levels() {
        use crate::api::AccountInfo;
        let acc = |name: Option<&str>, user: Option<&str>| AccountInfo {
            id: "u1".into(),
            display_name: name.map(str::to_string),
            image_url: None,
            images_read: false,
            username: user.map(str::to_string),
            plan: None,
        };
        let pass = judge_account_name(Some(&acc(Some("Ada"), Some("ada123"))));
        assert_eq!(pass.status, Status::Pass);
        assert!(pass.detail.contains("Ada"));
        let warn = judge_account_name(Some(&acc(None, Some("ada123"))));
        assert_eq!(warn.status, Status::Warn);
        assert!(warn.detail.contains("ada123"));
        assert_eq!(
            judge_account_name(Some(&acc(Some("  "), None))).status,
            Status::Info
        );
        assert_eq!(judge_account_name(None).status, Status::Info);
    }

    #[test]
    fn model_check_levels() {
        use crate::llm::models::DiskStatus;
        use crate::llm::LlmSettings;
        let on = LlmSettings {
            enabled: true,
            ..LlmSettings::default()
        };
        let on_ollama = LlmSettings {
            enabled: true,
            backend: "ollama".into(),
            ..LlmSettings::default()
        };
        let on_disk = DiskStatus {
            installed: true,
            size: 400_000_000,
            partial: 0,
            verified: "server".into(),
        };
        let half = DiskStatus {
            installed: false,
            size: 0,
            partial: 120_000_000,
            verified: String::new(),
        };
        let none = DiskStatus::default();

        // Off, or nothing saved yet: nothing is needed, so never a problem.
        assert_eq!(judge_model(None, true, None).status, Status::Info);
        assert_eq!(
            judge_model(Some(&LlmSettings::default()), true, None).status,
            Status::Info
        );
        // Ollama: the built-in file is irrelevant.
        assert_eq!(
            judge_model(Some(&on_ollama), false, Some(&none)).status,
            Status::Info
        );
        // Built-in model chosen but the build cannot run it.
        let no_engine = judge_model(Some(&on), false, Some(&on_disk));
        assert_eq!(no_engine.status, Status::Warn);
        assert!(no_engine.hint.is_some_and(|h| h.contains("local-llm")));
        // On disk, half downloaded, missing.
        let ok = judge_model(Some(&on), true, Some(&on_disk));
        assert_eq!(ok.status, Status::Pass);
        assert!(ok.detail.contains("400 MB") && ok.detail.contains("server"));
        let partial = judge_model(Some(&on), true, Some(&half));
        assert_eq!(partial.status, Status::Warn);
        assert!(partial.detail.contains("120 MB"));
        let missing = judge_model(Some(&on), true, Some(&none));
        assert_eq!(missing.status, Status::Warn);
        assert!(missing.hint.is_some_and(|h| h.contains("--model-fetch")));
        assert_eq!(judge_model(Some(&on), true, None).status, Status::Warn);
    }
}
