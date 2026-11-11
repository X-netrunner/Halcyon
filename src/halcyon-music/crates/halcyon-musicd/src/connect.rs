//! Spotify Connect device (Part 2, Step A: the spike).
//!
//! `halcyon-musicd --connect-spike` registers Halcyon as a Connect device ("Halcyon (<host>)")
//! with a real software mixer, in its OWN session and player, so it cannot disturb the normal
//! daemon. It exists to answer one question on a real phone: does Halcyon show up in Devices,
//! accept a transfer, and follow the phone's volume? Step B (a `PlaybackBackend` that feeds the
//! GUI from Spirc) must not start before that is confirmed.
//!
//! Everything pure (names, volume mapping, the status file, the doctor verdict) is compiled and
//! tested without the `connect` feature; only the Spirc wiring needs `--features connect`.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Runtime switch for the spike path (and, later, the backend): `HALCYON_CONNECT=1`.
pub const ENV_FLAG: &str = "HALCYON_CONNECT";

/// Spotify Connect volume is 0..=65535.
const CONNECT_MAX: u32 = u16::MAX as u32;

/// Whether the env value turns Connect on. Anything but a clear "yes" is off.
pub fn enabled_from(value: Option<&str>) -> bool {
    matches!(
        value.map(|v| v.trim().to_ascii_lowercase()).as_deref(),
        Some("1" | "true" | "yes" | "on")
    )
}

/// What the Settings switch saved: `Some(true)` for `on`, `Some(false)` for `off`, `None` for no
/// file or anything unreadable (not chosen yet).
pub fn pref_from(text: Option<&str>) -> Option<bool> {
    match text.map(|t| t.trim().to_ascii_lowercase()).as_deref() {
        Some("on" | "1" | "true" | "yes") => Some(true),
        Some("off" | "0" | "false" | "no") => Some(false),
        _ => None,
    }
}

/// The final answer: a choice made in Settings wins; without one the environment decides
/// (`HALCYON_CONNECT`, which the installer sets for a build with Connect); otherwise off.
pub fn resolve(pref: Option<bool>, env: Option<&str>) -> bool {
    pref.unwrap_or_else(|| enabled_from(env))
}

/// The saved Settings choice, if any.
pub fn read_pref() -> Option<bool> {
    let text = std::fs::read_to_string(halcyon_music_core::paths::connect_pref_file()).ok();
    pref_from(text.as_deref())
}

/// Save the Settings choice. Written through a temporary file so a crash never leaves half a word.
pub fn write_pref(on: bool) -> std::io::Result<()> {
    let path = halcyon_music_core::paths::connect_pref_file();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, if on { "on\n" } else { "off\n" })?;
    std::fs::rename(&tmp, &path)
}

/// Connect is requested: by the Settings switch, else by this process's environment.
pub fn enabled() -> bool {
    resolve(read_pref(), std::env::var(ENV_FLAG).ok().as_deref())
}

/// True when this binary contains the Spirc code.
pub const fn compiled_in() -> bool {
    cfg!(feature = "connect")
}

/// "Halcyon (<hostname>)"; a blank or unreadable hostname gives plain "Halcyon".
pub fn device_name(hostname: &str) -> String {
    let host: String = hostname
        .trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(40)
        .collect();
    let host = host.trim();
    if host.is_empty() {
        "Halcyon".to_string()
    } else {
        format!("Halcyon ({host})")
    }
}

/// The machine's hostname, without running a program.
pub fn hostname() -> String {
    for path in ["/proc/sys/kernel/hostname", "/etc/hostname"] {
        if let Ok(text) = std::fs::read_to_string(path) {
            let name = text.trim();
            if !name.is_empty() {
                return name.to_string();
            }
        }
    }
    String::new()
}

/// Halcyon volume (0..=100 percent) to Connect's 0..=65535 scale.
pub fn percent_to_connect(percent: u8) -> u16 {
    let p = u32::from(percent.min(100));
    // Rounded; 100 maps to exactly 65535 and 0 to exactly 0.
    u16::try_from((p * CONNECT_MAX + 50) / 100).unwrap_or(u16::MAX)
}

/// Connect's 0..=65535 scale back to percent (rounded).
pub fn connect_to_percent(volume: u16) -> u8 {
    let v = u32::from(volume);
    u8::try_from(((v * 100) + CONNECT_MAX / 2) / CONNECT_MAX).unwrap_or(100)
}

/// What a running Connect device leaves behind so `--doctor` can see it without the Web API.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ConnectStatus {
    pub name: String,
    pub pid: u32,
    /// Unix seconds when the device registered.
    pub since: u64,
}

pub fn status_path() -> PathBuf {
    halcyon_music_core::paths::socket_dir().join("connect.json")
}

pub fn write_status(status: &ConnectStatus) -> std::io::Result<()> {
    let path = status_path();
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let json = serde_json::to_vec(status).map_err(std::io::Error::other)?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(&tmp, &path)
}

pub fn clear_status() {
    let _ = std::fs::remove_file(status_path());
}

pub fn read_status() -> Option<ConnectStatus> {
    let bytes = std::fs::read(status_path()).ok()?;
    serde_json::from_slice(&bytes).ok()
}

/// The device name while a registered backend is alive, else `None`. Used by the GUI's account
/// line; reads the status file, so it needs no Web API and no session.
pub fn registered_name() -> Option<String> {
    let status = read_status()?;
    pid_alive(status.pid).then_some(status.name)
}

/// Is a process with this pid running (Linux /proc)?
pub fn pid_alive(pid: u32) -> bool {
    pid != 0 && std::path::Path::new(&format!("/proc/{pid}")).exists()
}

/// The doctor's verdict, kept pure so it can be tested.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DoctorView {
    /// Registered and its process is alive.
    Registered { name: String },
    /// A status file exists but its process is gone.
    Stale { name: String },
    /// Not requested and nothing registered.
    Off { compiled: bool },
    /// Requested, but nothing is registered.
    RequestedNotRegistered { compiled: bool },
}

pub fn doctor_view(
    status: Option<&ConnectStatus>,
    alive: bool,
    requested: bool,
    compiled: bool,
) -> DoctorView {
    match status {
        Some(s) if alive => DoctorView::Registered {
            name: s.name.clone(),
        },
        Some(s) => DoctorView::Stale {
            name: s.name.clone(),
        },
        None if requested => DoctorView::RequestedNotRegistered { compiled },
        None => DoctorView::Off { compiled },
    }
}

#[cfg(feature = "connect")]
mod spike {
    use super::*;
    use crate::stream_auth::fresh_streaming_token;
    use crate::token_store::now_secs;
    use librespot_connect::{ConnectConfig, Spirc};
    use librespot_core::authentication::Credentials;
    use librespot_core::config::{DeviceType, SessionConfig};
    use librespot_core::session::Session;
    use librespot_playback::audio_backend;
    use librespot_playback::config::{AudioFormat, PlayerConfig};
    use librespot_playback::mixer::softmixer::SoftMixer;
    use librespot_playback::mixer::{Mixer, MixerConfig};
    use librespot_playback::player::{Player, PlayerEvent};
    use std::sync::Arc;
    use std::time::Duration;

    /// Register Halcyon as a Connect device until Ctrl+C. Prints what Spotify and the player do.
    pub async fn run(volume_percent: u8) -> Result<(), String> {
        let token = fresh_streaming_token().await.map_err(|e| e.to_string())?;
        let creds = Credentials::with_access_token(&token.access_token);

        let name = device_name(&hostname());
        let session = Session::new(SessionConfig::default(), None);

        // A real software mixer: the phone's volume changes land here (NoOpVolume ignores them).
        let mixer =
            Arc::new(SoftMixer::open(MixerConfig::default()).map_err(|e| format!("mixer: {e}"))?);

        let sink_fn =
            audio_backend::find(None).ok_or_else(|| "No audio backend found".to_string())?;
        let bus = crate::tap::audio_bus().clone();
        let sink_builder = move || -> Box<dyn audio_backend::Sink> {
            Box::new(crate::tap::TapSink::new(
                sink_fn(None, AudioFormat::F32),
                bus,
            ))
        };
        let player = Player::new(
            PlayerConfig {
                gapless: true,
                ..Default::default()
            },
            session.clone(),
            mixer.get_soft_volume(),
            sink_builder,
        );
        let mut events = player.get_player_event_channel();

        let config = ConnectConfig {
            name: name.clone(),
            device_type: DeviceType::Computer,
            initial_volume: percent_to_connect(volume_percent),
            ..Default::default()
        };

        // Spirc::new connects the session itself (after registering its listeners), so the
        // session must not be connected before this call.
        println!("Registering \"{name}\" as a Spotify Connect device...");
        let (spirc, task) = Spirc::new(config, session, creds, player, mixer.clone())
            .await
            .map_err(|e| {
                let text = e.to_string();
                let lower = text.to_lowercase();
                if lower.contains("free") || lower.contains("premium") {
                    format!("Spotify Free accounts cannot be Connect devices ({text})")
                } else {
                    format!("could not start Spotify Connect: {text}")
                }
            })?;
        let task = tokio::spawn(task);

        if let Err(e) = write_status(&ConnectStatus {
            name: name.clone(),
            pid: std::process::id(),
            since: now_secs(),
        }) {
            eprintln!("(could not write the status file: {e})");
        }
        println!("Registered. Open Spotify on your phone, tap Devices, pick \"{name}\".");
        println!("Try: transfer playback, pause, skip, change the volume. Ctrl+C stops.");

        let watcher = tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                match event {
                    PlayerEvent::Playing { position_ms, .. } => {
                        println!("player: playing at {position_ms} ms");
                    }
                    PlayerEvent::Paused { position_ms, .. } => {
                        println!("player: paused at {position_ms} ms");
                    }
                    PlayerEvent::TrackChanged { .. } => println!("player: track changed"),
                    PlayerEvent::VolumeChanged { volume } => {
                        println!(
                            "player: volume {} % (raw {volume})",
                            connect_to_percent(volume)
                        );
                    }
                    PlayerEvent::Stopped { .. } => println!("player: stopped"),
                    PlayerEvent::Unavailable { .. } => println!("player: track unavailable"),
                    _ => {}
                }
            }
        });

        let _ = tokio::signal::ctrl_c().await;
        println!("Stopping...");
        let _ = spirc.shutdown();
        let _ = tokio::time::timeout(Duration::from_secs(5), task).await;
        watcher.abort();
        clear_status();
        Ok(())
    }
}

/// Run the spike. `volume_percent` is the initial volume.
#[cfg(feature = "connect")]
pub async fn run_spike(volume_percent: u8) -> Result<(), String> {
    spike::run(volume_percent).await
}

/// Without the feature the spike cannot run; say how to build it.
#[cfg(not(feature = "connect"))]
pub async fn run_spike(_volume_percent: u8) -> Result<(), String> {
    Err("this build has no Spotify Connect code; rebuild with: cargo build --release -p halcyon-musicd --features connect".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_settings_choice_beats_the_environment() {
        assert_eq!(pref_from(Some("on\n")), Some(true));
        assert_eq!(pref_from(Some(" OFF ")), Some(false));
        assert_eq!(pref_from(Some("maybe")), None);
        assert_eq!(pref_from(None), None);
        // A choice wins both ways; no choice leaves the installer's environment in charge.
        assert!(!resolve(Some(false), Some("1")));
        assert!(resolve(Some(true), None));
        assert!(resolve(None, Some("1")));
        assert!(!resolve(None, None));
    }

    #[test]
    fn env_flag_needs_a_clear_yes() {
        for yes in ["1", "true", "TRUE", " yes ", "on"] {
            assert!(enabled_from(Some(yes)), "{yes}");
        }
        for no in ["", "0", "false", "off", "2", "maybe"] {
            assert!(!enabled_from(Some(no)), "{no}");
        }
        assert!(!enabled_from(None));
    }

    #[test]
    fn device_name_uses_host_and_survives_junk() {
        assert_eq!(device_name("arch-box\n"), "Halcyon (arch-box)");
        assert_eq!(device_name(""), "Halcyon");
        assert_eq!(device_name("  \n"), "Halcyon");
        assert_eq!(device_name("a\u{7}b"), "Halcyon (ab)");
        let long = "x".repeat(200);
        assert_eq!(device_name(&long).len(), "Halcyon ()".len() + 40);
    }

    #[test]
    fn volume_ends_and_round_trip() {
        assert_eq!(percent_to_connect(0), 0);
        assert_eq!(percent_to_connect(100), u16::MAX);
        assert_eq!(percent_to_connect(250), u16::MAX, "out of range is clamped");
        assert_eq!(connect_to_percent(0), 0);
        assert_eq!(connect_to_percent(u16::MAX), 100);
        for p in 0..=100u8 {
            assert_eq!(connect_to_percent(percent_to_connect(p)), p, "percent {p}");
        }
    }

    #[test]
    fn volume_is_monotonic() {
        let mut last = 0;
        for p in 0..=100u8 {
            let v = percent_to_connect(p);
            assert!(v >= last);
            last = v;
        }
    }

    #[test]
    fn status_round_trips_as_json() {
        let s = ConnectStatus {
            name: "Halcyon (x)".into(),
            pid: 42,
            since: 7,
        };
        let json = serde_json::to_string(&s).unwrap();
        assert_eq!(serde_json::from_str::<ConnectStatus>(&json).unwrap(), s);
        assert!(serde_json::from_str::<ConnectStatus>("{}").is_err());
    }

    #[test]
    fn pid_check() {
        assert!(pid_alive(std::process::id()));
        assert!(!pid_alive(0));
        assert!(!pid_alive(u32::MAX));
    }

    #[test]
    fn doctor_views() {
        let s = ConnectStatus {
            name: "Halcyon (x)".into(),
            pid: 1,
            since: 0,
        };
        assert_eq!(
            doctor_view(Some(&s), true, false, true),
            DoctorView::Registered {
                name: "Halcyon (x)".into()
            }
        );
        assert_eq!(
            doctor_view(Some(&s), false, true, true),
            DoctorView::Stale {
                name: "Halcyon (x)".into()
            }
        );
        assert_eq!(
            doctor_view(None, false, false, false),
            DoctorView::Off { compiled: false }
        );
        assert_eq!(
            doctor_view(None, false, true, true),
            DoctorView::RequestedNotRegistered { compiled: true }
        );
    }

    #[cfg(not(feature = "connect"))]
    #[tokio::test]
    async fn spike_without_the_feature_says_how_to_build() {
        let err = run_spike(50).await.unwrap_err();
        assert!(err.contains("--features connect"));
    }
}
