# Spotify Connect (Part 2)

Status: **Step A (spike) works on a real phone (reported by the owner). Step B (the backend) is
written; its pure logic is tested, but the Spirc glue has NOT been compiled** (no Rust toolchain in
the sandbox that wrote it). Run `cargo check -p halcyon-musicd --features connect` first and paste
any errors; they will be in `connect_backend.rs`, see "Where a compile error can come from".

## What was verified (by reading librespot 0.8.0 source and by compiling)

- `librespot-connect 0.8.0` exports `Spirc`, `ConnectConfig`, `LoadRequest`. It needs Rust 1.85
  (edition 2024), like the other librespot 0.8 crates.
- `Spirc::new(config, session, credentials, player, mixer)` registers listeners on the session's
  **dealer** (`hm://connect-state/v1/cluster`, `.../player/command`, `.../connect/volume`, ...),
  then calls `session.connect(credentials, true)` itself. So: the device registers over the normal
  authenticated dealer connection with the **access-token credentials we already use**; no mDNS or
  zeroconf is involved. The `Session` must **not** be connected before `Spirc::new`.
- `ConnectConfig { name, device_type, is_group, initial_volume (0..=65535), disable_volume, volume_steps }`.
  We use `DeviceType::Computer` and the name "Halcyon (<hostname>)".
- Volume: `SoftMixer` (`librespot_playback::mixer::softmixer`) is a real mixer; its
  `get_soft_volume()` goes to `Player::new`. `NoOpVolume` (used by the normal engine today) ignores
  volume, which is why phone volume could never work.
- `LoadRequest::from_tracks(Vec<String>, LoadRequestOptions)` exists: this is the hook for Halcyon's
  own lists (mixes, prompt playlists) in Step B. `from_context_uri` is for real Spotify contexts.
- The code compiles with and without `--features connect`.

## NOT verified (needs a real Premium session)

- That "Halcyon (<host>)" appears under Devices on a phone and accepts a transfer.
- That a phone's volume change reaches the mixer (the spike prints `player: volume N %`).
- Whether a **Free** account fails in `Spirc::new` (the spike maps an error mentioning free/premium
  to a clear message; the real error text is unknown).
- Reconnect after network loss, and removal from the device list after the process dies.

## Try it

```
cd src/halcyon-music
cargo build --release -p halcyon-musicd --features connect
./target/release/halcyon-musicd --connect-spike --volume 40     # Ctrl+C stops
```

Stop the normal daemon first if it is playing (two sessions on one account fight over audio):
`systemctl --user stop halcyon-musicd`. Then on the phone: Spotify > Devices > "Halcyon (<host>)".
Check: transfer in, pause, skip, change volume, transfer away, Ctrl+C (device should vanish within
about a minute). While it runs, `halcyon-musicd --doctor` shows `[PASS] connect device ...`
(read from `$XDG_RUNTIME_DIR/halcyon-music/connect.json`; no Web API).

## Step B: the playback backend

### Turning it on

Default builds and default behaviour are unchanged: the daemon uses the direct engine (`audio.rs`).
To register as a Connect device you need BOTH:

    cargo build --release -p halcyon-musicd --features connect
    HALCYON_CONNECT=1 halcyon-musicd            # or, for the service:
    systemctl --user edit halcyon-musicd        # add:  [Service]  Environment=HALCYON_CONNECT=1

A build without the feature, or without the variable, uses the direct engine. A Free account (or any
"free/premium" start error) falls back to the direct engine too, with the usual message, so the app
still plays. Stop `--connect-spike` before starting the daemon in this mode (one device per name).

### How it works

`backend.rs` (no Spotify types, fully tested) has the `PlaybackBackend` trait with `DirectBackend`
(the old engine, untouched) and `SpircBackend`. The daemon's supervised "player" task asks
`select_backend` once per (re)start. The GUI protocol is unchanged: `PlayerState` is still the one
thing the GUI reads and writes. A `Mirror` remembers what the device is doing:

- GUI -> device, every 250 ms: `plan_commands(state, mirror)` returns the few commands that close the
  gap (`Activate`, `Load` with the whole list and the start index, `Play`, `Pause`, `Next`, `Prev`,
  `Seek`, `SetVolume`, `Shuffle`, `Repeat`).
- device -> GUI: player events become a `DeviceEvent`, then an `Edit` of the state. The mirror is
  updated in the same step, so an event never comes back as a command.
- Late events about a track Halcyon just skipped away from are ignored for 4 s (otherwise the GUI
  would jump back and send a second skip).
- The device is only woken (Activate + Load) when the user really plays, not when the app opens with
  a saved queue.
- Music the phone starts that Halcyon never queued is looked up (cache, then the session) and becomes
  the queue; the tracks that follow are appended (history, at most 200).
- Our own hooks keep working: lyrics line events, progress, MPRIS (reads the state), the audio tap
  for the visuals (same `TapSink`), cover prefetch (reads the state), and the play log (finished
  tracks only, same rule as the direct engine).
- `connect.json` (status file) and the new `connect_device` event carry the device name; the account
  line shows "Connected as Halcyon (<host>)" while registered, else "This computer". `--doctor`
  reads the same file.
- If the Connect session ends (network loss), the player task returns an error and the supervisor
  re-registers with its usual backoff (250 ms doubling to 30 s). A changed bitrate or normalisation
  re-registers once (librespot fixes them when the player is built).

### What was tested (really run)

Nothing from this step was run against Rust: **there was no compiler**. What exists:

- `backend.rs` unit tests and `tests/connect_sim.rs` (a simulated device with delayed events, GUI and
  "phone" both acting). Their LOGIC was checked by porting the planner, the event mapper and the
  simulator to Python and running the nine simulated scenarios (all pass). That finds logic bugs, not
  Rust compile errors.
- Not compiled: `backend.rs`, `connect_backend.rs`, the GUI change, the new protocol event.

### Where a compile error can come from

Every librespot call is in two places of `connect_backend.rs`: `SpircTransport::send` and
`map_player_event`. Written from memory of the 0.8 API (marked `VERIFY`): `Spirc::activate`,
`set_position_ms`, `set_volume`, `repeat`, `repeat_track`, `shuffle`, `load`, `LoadRequestOptions`
fields, `PlayingTrack::Index`, and that `LoadRequest`, `LoadRequestOptions`, `PlayingTrack` are
exported at the crate root. The player events used are the ones `audio.rs` and the spike already
compile against.

### Known limits (not hidden)

- **The queue drawer cannot show items added from the phone's queue.** Spirc 0.8 does not expose its
  queue to us. What the drawer shows is the list Halcyon loaded, or the history of what the phone
  played. No "From your phone" tag yet (it needs a protocol field; not done).
- Changing the queue (enqueue, play next, remove, reorder) while playing reloads the list on the
  device at the same position: expect a brief gap. Cheaper paths (`add_to_queue`) differ in order
  semantics, so they were not used before parity is proven.
- Skips are still not written to the play log (Part 3's open decision).
- Huge queues (thousands of rows) are sent whole; no windowing yet.
- When playback is transferred away from Halcyon, the GUI shows paused; pressing play loads again.
- Phone-side shuffle/repeat changes are not reflected in the GUI (those events are not used yet).
- Quality change drops the device for a moment.
- `DirectBackend` stays; the old path was not removed.

### Phone checklist (acceptance, manual)

1. `cargo check -p halcyon-musicd --features connect`, then build and start with `HALCYON_CONNECT=1`.
2. `halcyon-musicd --doctor`: `connect device` is PASS; the app's account menu says "Connected as Halcyon (<host>)".
3. Phone: Halcyon is in Devices; transfer to it, audio plays, GUI shows the same track and position.
4. Phone: pause, skip, seek, volume; the GUI follows. GUI: pause, next, seek, volume; the phone follows.
5. Play an album from the GUI: it plays; the phone shows Halcyon as the device. Pick a song, skip five
   times fast: ends on the right track, no jumping back.
6. Close the GUI: music keeps playing, the device stays listed.
7. Kill the daemon: the device disappears within about a minute; restart: it comes back.
8. Turn off wifi for 20 s and on again: the device re-registers by itself.
