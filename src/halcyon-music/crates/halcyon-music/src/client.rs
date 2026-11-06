//! GUI-side daemon client: connects to the control socket, speaks NDJSON,
//! reconnects automatically when the daemon restarts, and spawns the daemon
//! if it is not running at all.

use halcyon_music_core::paths;
use halcyon_music_core::protocol::{self, CommandBody, Event, EventBody};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::{mpsc, Mutex};
use tracing::{info, warn};

/// What the UI needs to know about the connection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnStatus {
    Connecting,
    Connected { daemon_version: String },
    /// Daemon was not running; we started it ourselves.
    SpawnedDaemon,
    Reconnecting { attempt: u32 },
    Failed(String),
}

/// Events flowing UI-ward.
#[derive(Debug, Clone)]
pub enum UiEvent {
    Status(ConnStatus),
    Protocol(Box<Event>),
    /// Plain-language daemon error, for a toast.
    DaemonError(String),
}

/// A live client: push commands, receive UI events.
pub struct DaemonClient {
    pub events: mpsc::Receiver<UiEvent>,
    pub commands: mpsc::Sender<CommandBody>,
}

/// Start the background connection loop and hand back both ends.
/// Reconnects forever; the GUI never dies because the daemon restarted.
pub fn connect() -> DaemonClient {
    let (ev_tx, ev_rx) = mpsc::channel(256);
    let (cmd_tx, cmd_rx) = mpsc::channel(64);
    let cmd_rx = Arc::new(Mutex::new(cmd_rx));
    tokio::spawn(async move {
        let mut attempt: u32 = 0;
        loop {
            let _ = ev_tx.send(UiEvent::Status(ConnStatus::Connecting)).await;
            match ensure_daemon_running().await {
                Ok(how) => {
                    if how == DaemonStart::Spawned {
                        let _ = ev_tx.send(UiEvent::Status(ConnStatus::SpawnedDaemon)).await;
                    }
                    attempt = attempt.saturating_add(1);
                    match connect_and_pump(&ev_tx, &cmd_rx).await {
                        Ok(()) => info!("daemon closed the connection; reconnecting"),
                        Err(e) => {
                            warn!(error = %e, "connection to daemon lost");
                            let _ = ev_tx
                                .send(UiEvent::Status(ConnStatus::Reconnecting { attempt }))
                                .await;
                        }
                    }
                }
                Err(e) => {
                    let _ = ev_tx
                        .send(UiEvent::Status(ConnStatus::Failed(format!(
                            "could not start the daemon: {e:#}"
                        ))))
                        .await;
                }
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    });
    DaemonClient { events: ev_rx, commands: cmd_tx }
}

/// How the daemon came to be running.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DaemonStart {
    AlreadyRunning,
    ViaSystemd,
    /// We spawned the binary ourselves (no systemd unit or it failed).
    Spawned,
}

/// Ensure a daemon is running: if the socket does not answer, start one.
pub async fn ensure_daemon_running() -> anyhow::Result<DaemonStart> {
    let sock = paths::ctl_socket();
    if UnixStream::connect(&sock).await.is_ok() {
        return Ok(DaemonStart::AlreadyRunning);
    }
    // Try systemd first (no-op if not installed), then spawn directly.
    let via_systemd = tokio::process::Command::new("systemctl")
        .args(["--user", "start", "halcyon-musicd.service"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .map(|s| s.success())
        .unwrap_or(false);
    if via_systemd {
        info!("started daemon via systemctl --user");
        return Ok(DaemonStart::ViaSystemd);
    }
    warn!("systemd start failed or unavailable; spawning halcyon-musicd directly");
    tokio::process::Command::new("halcyon-musicd")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;
    Ok(DaemonStart::Spawned)
}

async fn connect_and_pump(
    tx: &mpsc::Sender<UiEvent>,
    cmd_rx: &Arc<Mutex<mpsc::Receiver<CommandBody>>>,
) -> anyhow::Result<()> {
    let sock = paths::ctl_socket();
    let stream = UnixStream::connect(&sock).await?;
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    // Say hello and ask for a snapshot.
    for body in [CommandBody::Hello, CommandBody::GetState] {
        writer.write_all(&protocol::encode_line(&protocol::command(body))?).await?;
    }

    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else { return Ok(()) }; // daemon went away
                if line.trim().is_empty() {
                    continue;
                }
                let Ok(ev) = protocol::decode_line::<Event>(line.as_bytes()) else {
                    continue; // unknown kinds decode to EventBody::Unknown; garbage skipped
                };
                if ev.version > protocol::PROTOCOL_VERSION {
                    warn!(version = ev.version, "daemon speaks a newer protocol; ignoring unknown fields");
                }
                match &ev.body {
                    EventBody::Hello { daemon_version, .. } => {
                        let _ = tx.send(UiEvent::Status(ConnStatus::Connected {
                            daemon_version: daemon_version.clone(),
                        })).await;
                    }
                    EventBody::Error { message } => {
                        let _ = tx.send(UiEvent::DaemonError(message.clone())).await;
                    }
                    _ => {}
                }
                let _ = tx.send(UiEvent::Protocol(Box::new(ev))).await;
            }
            cmd = recv_cmd(cmd_rx) => {
                match cmd {
                    Some(body) => {
                        writer
                            .write_all(&protocol::encode_line(&protocol::command(body))?)
                            .await?;
                    }
                    // Command channel closed: keep listening for events.
                    None => {
                        let _ = tx.send(UiEvent::Status(ConnStatus::Failed(
                            "the interface closed its command channel".to_string(),
                        ))).await;
                    }
                }
            }
        }
    }
}

/// Lock the shared command receiver and pull one command. Kept as a helper
/// so `tokio::select!` never holds the guard across branches.
async fn recv_cmd(cmd_rx: &Arc<Mutex<mpsc::Receiver<CommandBody>>>) -> Option<CommandBody> {
    cmd_rx.lock().await.recv().await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conn_status_display_variants_are_stable() {
        // Snapshot the user-facing strings so Part 4's UI copy stays honest.
        assert_eq!(format!("{:?}", ConnStatus::Connecting), "Connecting");
        assert!(format!("{:?}", ConnStatus::Reconnecting { attempt: 3 }).contains('3'));
    }
}
