//! Integration test: start the real daemon on a real Unix socket (in a temp
//! XDG_RUNTIME_DIR), speak the protocol to it, and check events flow.
//!
//! This is the only test in its binary, so mutating process env is safe.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use halcyon_music_core::protocol::{self, CommandBody, EventBody};

fn wait_for(path: &std::path::Path, timeout: Duration) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

#[test]
fn daemon_speaks_the_protocol_over_its_socket() {
    let tmp = tempfile::tempdir().expect("tempdir");
    std::env::set_var("XDG_RUNTIME_DIR", tmp.path().join("rt"));
    std::env::set_var("HOME", tmp.path().join("home"));
    std::env::set_var("XDG_STATE_HOME", tmp.path().join("state"));
    std::env::remove_var("NOTIFY_SOCKET"); // not under systemd here

    std::thread::spawn(|| {
        // Daemon blocks forever; the test process exit reaps it.
        let _ = halcyon_musicd::daemon_run_for_test();
    });

    let sock = halcyon_music_core::paths::ctl_socket();
    assert!(wait_for(&sock, Duration::from_secs(10)), "daemon never created its socket");

    let mut stream = UnixStream::connect(&sock).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .expect("set_read_timeout");

    // 1. Server should greet us with Hello + a State snapshot.
    let mut reader = BufReader::new(stream.try_clone().expect("clone"));
    let mut line = String::new();
    reader.read_line(&mut line).expect("read hello");
    let ev: protocol::Event = protocol::decode_line(line.as_bytes()).expect("decode hello");
    assert!(matches!(ev.body, EventBody::Hello { .. }), "first event must be Hello");

    line.clear();
    reader.read_line(&mut line).expect("read state");
    let ev: protocol::Event = protocol::decode_line(line.as_bytes()).expect("decode state");
    assert!(matches!(ev.body, EventBody::State { .. }), "second event must be State");

    // 2. Send GetState, expect a State reply.
    let cmd = protocol::command(CommandBody::GetState);
    let bytes = protocol::encode_line(&cmd).expect("encode");
    stream.write_all(&bytes).expect("write");

    let mut saw_state = false;
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline && !saw_state {
        line.clear();
        reader.read_line(&mut line).expect("read reply");
        if line.is_empty() {
            break;
        }
        let ev: protocol::Event = protocol::decode_line(line.as_bytes()).expect("decode reply");
        if matches!(ev.body, EventBody::State { .. }) {
            saw_state = true;
        }
    }
    assert!(saw_state, "daemon answered GetState with a State event");

    // 3. State file must have appeared in the (temp) state dir by now or
    //    shortly after a change; force a change then wait for the save.
    let cmd = protocol::command(CommandBody::SetVolume { volume: 42 });
    stream
        .write_all(&protocol::encode_line(&cmd).expect("encode"))
        .expect("write");

    // The persistence loop debounces bursts, so poll until the save with our
    // volume lands instead of racing the first (default) save.
    let state_file = halcyon_music_core::paths::state_file();
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut parsed: Option<halcyon_music_core::PlayerState> = None;
    while Instant::now() < deadline {
        if let Ok(text) = std::fs::read_to_string(&state_file) {
            if let Ok(state) = serde_json::from_str::<halcyon_music_core::PlayerState>(&text) {
                if state.volume == 42 {
                    parsed = Some(state);
                    break;
                }
            }
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(parsed.is_some(), "state file was persisted with volume 42 after a change");
}
