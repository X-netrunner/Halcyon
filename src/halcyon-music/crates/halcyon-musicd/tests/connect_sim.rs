//! Part 2, Step B: the GUI and a phone controlling one Connect device, simulated.
//!
//! `SimDevice` behaves like a Spotify Connect device is expected to: it holds a list, obeys
//! commands, and reports what it does as events (with a small delay, so "late events about the
//! track we just left" really happen). The test drives it from both sides and checks that the
//! GUI's `PlayerState` and the device never fight (no ping-pong, no echoed commands).
//!
//! This proves OUR side of the protocol. It cannot prove what real Spotify does; that is the
//! manual phone checklist in docs/connect.md.

use halcyon_music_core::state::RepeatMode;
use halcyon_music_core::{PlayerState, Track};
use halcyon_musicd::backend::{
    adopt_foreign, apply_edit, event_to_edit, reconcile, ConnectTransport, DeviceEvent, Mirror,
    TransportCmd,
};
use halcyon_musicd::connect::connect_to_percent;
use std::collections::VecDeque;

fn track(id: &str) -> Track {
    Track {
        id: id.into(),
        title: format!("Song {id}"),
        artist: "Artist".into(),
        artists: vec!["Artist".into()],
        album: "Album".into(),
        album_id: None,
        duration_ms: 200_000,
        art_url: None,
        uri: format!("spotify:track:{id}"),
    }
}

/// A pretend Connect device. Events it produces are delivered `lag` ticks later.
struct SimDevice {
    list: Vec<String>,
    index: usize,
    playing: bool,
    position_ms: u64,
    volume_raw: u16,
    active: bool,
    outbox: VecDeque<(u32, DeviceEvent)>,
    tick: u32,
    lag: u32,
    commands_seen: Vec<TransportCmd>,
}

impl SimDevice {
    fn new(lag: u32) -> Self {
        Self {
            list: Vec::new(),
            index: 0,
            playing: false,
            position_ms: 0,
            volume_raw: 32_768,
            active: false,
            outbox: VecDeque::new(),
            tick: 0,
            lag,
            commands_seen: Vec::new(),
        }
    }

    fn current(&self) -> Option<String> {
        self.list
            .get(self.index)
            .and_then(|u| u.rsplit(':').next())
            .map(str::to_string)
    }

    fn say(&mut self, ev: DeviceEvent) {
        self.outbox.push_back((self.tick + self.lag, ev));
    }

    fn announce(&mut self) {
        if let Some(id) = self.current() {
            let ev = if self.playing {
                DeviceEvent::Playing {
                    track_id: id,
                    position_ms: self.position_ms,
                }
            } else {
                DeviceEvent::Paused {
                    track_id: id,
                    position_ms: self.position_ms,
                }
            };
            self.say(ev);
        }
    }

    /// Something the PHONE does.
    fn phone_pause(&mut self) {
        self.playing = false;
        self.announce();
    }
    fn phone_resume(&mut self) {
        self.playing = true;
        self.announce();
    }
    fn phone_skip_to(&mut self, index: usize) {
        self.index = index;
        self.position_ms = 0;
        self.announce();
    }
    fn phone_volume(&mut self, raw: u16) {
        self.volume_raw = raw;
        self.say(DeviceEvent::Volume(raw));
    }
    fn phone_plays_own_music(&mut self, id: &str) {
        self.list = vec![format!("spotify:track:{id}")];
        self.index = 0;
        self.playing = true;
        self.active = true;
        self.announce();
    }

    /// Events that are due now.
    fn due(&mut self) -> Vec<DeviceEvent> {
        let mut out = Vec::new();
        while let Some((at, _)) = self.outbox.front() {
            if *at > self.tick {
                break;
            }
            if let Some((_, ev)) = self.outbox.pop_front() {
                out.push(ev);
            }
        }
        out
    }
}

impl ConnectTransport for SimDevice {
    fn send(&mut self, cmd: &TransportCmd) -> Result<(), String> {
        self.commands_seen.push(cmd.clone());
        match cmd {
            TransportCmd::Activate => self.active = true,
            TransportCmd::Load {
                uris,
                index,
                start_playing,
                position_ms,
            } => {
                if !self.active {
                    return Err("load before activate".into());
                }
                self.list = uris.clone();
                self.index = *index;
                self.playing = *start_playing;
                self.position_ms = u64::from(*position_ms);
                self.announce();
            }
            TransportCmd::Play => {
                self.playing = true;
                self.announce();
            }
            TransportCmd::Pause => {
                self.playing = false;
                self.announce();
            }
            TransportCmd::Next => {
                self.index = (self.index + 1).min(self.list.len().saturating_sub(1));
                self.position_ms = 0;
                self.announce();
            }
            TransportCmd::Prev => {
                self.index = self.index.saturating_sub(1);
                self.position_ms = 0;
                self.announce();
            }
            TransportCmd::Seek(ms) => {
                self.position_ms = u64::from(*ms);
                self.say(DeviceEvent::Position {
                    track_id: self.current().unwrap_or_default(),
                    position_ms: self.position_ms,
                });
            }
            TransportCmd::SetVolume(v) => {
                self.volume_raw = *v;
                self.say(DeviceEvent::Volume(*v));
            }
            TransportCmd::Shuffle(_) | TransportCmd::Repeat(_) => {}
        }
        Ok(())
    }
}

/// The daemon's loop body, minus the network: deliver due events, then reconcile.
struct Rig {
    state: PlayerState,
    mirror: Mirror,
    dev: SimDevice,
    now_ms: u64,
}

impl Rig {
    fn new(lag: u32) -> Self {
        let state = PlayerState::default();
        let mirror = Mirror::new(state.volume);
        Self {
            state,
            mirror,
            dev: SimDevice::new(lag),
            now_ms: 0,
        }
    }

    /// One 250 ms tick.
    fn step(&mut self) -> Vec<TransportCmd> {
        self.now_ms += 250;
        self.dev.tick += 1;
        for ev in self.dev.due() {
            let mut edit = event_to_edit(&self.state, &mut self.mirror, &ev, self.now_ms);
            if let Some(unknown) = edit.unknown.take() {
                // stands in for the metadata lookup
                edit = adopt_foreign(
                    &self.state,
                    &mut self.mirror,
                    track(&unknown.track_id),
                    &unknown,
                );
            }
            apply_edit(&mut self.state, &edit);
        }
        reconcile(&self.state, &mut self.mirror, &mut self.dev, self.now_ms)
    }

    fn run(&mut self, ticks: u32) -> Vec<TransportCmd> {
        let mut all = Vec::new();
        for _ in 0..ticks {
            all.extend(self.step());
        }
        all
    }

    fn id(&self) -> Option<&str> {
        self.state.track.as_ref().map(|t| t.id.as_str())
    }
}

#[test]
fn gui_play_then_phone_pause_and_resume() {
    let mut rig = Rig::new(1);
    rig.state
        .play_context(vec![track("a"), track("b"), track("c")], 0);
    rig.run(4);
    assert!(rig.dev.playing && rig.dev.active);
    assert_eq!(rig.dev.current().as_deref(), Some("a"));

    rig.dev.phone_pause();
    rig.run(4);
    assert!(!rig.state.playing, "GUI follows the phone's pause");
    let cmds = rig.run(4);
    assert!(cmds.is_empty(), "nothing echoed back: {cmds:?}");

    rig.dev.phone_resume();
    rig.run(4);
    assert!(rig.state.playing);
}

#[test]
fn gui_next_does_not_ping_pong_with_late_events() {
    let mut rig = Rig::new(3); // events arrive 750 ms late
    rig.state
        .play_context(vec![track("a"), track("b"), track("c")], 0);
    rig.run(6);
    assert!(rig.state.advance_next());
    let cmds = rig.run(12);
    assert_eq!(
        cmds.iter()
            .filter(|c| matches!(c, TransportCmd::Next | TransportCmd::Prev))
            .count(),
        1,
        "exactly one skip, no Prev: {cmds:?}"
    );
    assert_eq!(rig.id(), Some("b"));
    assert_eq!(rig.dev.current().as_deref(), Some("b"));
}

#[test]
fn rapid_gui_skips_settle_on_the_last_track() {
    let mut rig = Rig::new(2);
    rig.state
        .play_context((0..6).map(|i| track(&format!("t{i}"))).collect(), 0);
    rig.run(6);
    for _ in 0..3 {
        assert!(rig.state.advance_next());
        rig.run(1);
    }
    rig.run(20);
    assert_eq!(rig.id(), Some("t3"));
    assert_eq!(rig.dev.current().as_deref(), Some("t3"));
}

#[test]
fn phone_skip_moves_the_gui_without_commands() {
    let mut rig = Rig::new(1);
    rig.state
        .play_context(vec![track("a"), track("b"), track("c"), track("d")], 0);
    rig.run(4);
    rig.dev.phone_skip_to(3);
    let cmds = rig.run(6);
    assert_eq!(rig.id(), Some("d"));
    assert_eq!(rig.state.queue_pos, 3);
    assert!(cmds.is_empty(), "{cmds:?}");
}

#[test]
fn volume_goes_both_ways_without_looping() {
    let mut rig = Rig::new(1);
    rig.state.play_context(vec![track("a")], 0);
    rig.run(4);

    rig.state.volume = 80;
    let cmds = rig.run(4);
    assert_eq!(
        cmds.iter()
            .filter(|c| matches!(c, TransportCmd::SetVolume(_)))
            .count(),
        1
    );
    assert_eq!(connect_to_percent(rig.dev.volume_raw), 80);

    rig.dev.phone_volume(16_384);
    let cmds = rig.run(6);
    assert!(cmds.is_empty(), "{cmds:?}");
    assert_eq!(rig.state.volume, connect_to_percent(16_384));
}

#[test]
fn enqueue_while_playing_keeps_the_track_and_the_position() {
    let mut rig = Rig::new(1);
    rig.state.play_context(vec![track("a"), track("b")], 0);
    rig.run(4);
    rig.state.position_ms = 60_000;
    rig.dev.position_ms = 60_000;
    rig.mirror.position_ms = 60_000;
    rig.state.enqueue(track("z"));
    rig.run(6);
    assert_eq!(rig.dev.list.len(), 3);
    assert_eq!(rig.dev.current().as_deref(), Some("a"));
    assert_eq!(rig.dev.position_ms, 60_000);
    assert!(rig.state.playing);
}

#[test]
fn music_started_on_the_phone_appears_in_the_gui_and_stays_quiet() {
    let mut rig = Rig::new(1);
    rig.state.play_context(vec![track("a"), track("b")], 0);
    rig.state.playing = false; // user paused before the phone took over
    rig.run(2);

    rig.dev.phone_plays_own_music("zzz");
    let cmds = rig.run(8);
    assert_eq!(rig.id(), Some("zzz"));
    assert!(rig.state.playing);
    assert_eq!(rig.state.queue.len(), 1);
    assert!(
        cmds.is_empty(),
        "adopting phone music must not send a load back: {cmds:?}"
    );
}

#[test]
fn app_start_with_a_saved_queue_stays_silent_until_play() {
    let mut rig = Rig::new(1);
    rig.state.play_context(vec![track("a"), track("b")], 0);
    rig.state.playing = false;
    let cmds = rig.run(8);
    assert!(cmds.is_empty(), "{cmds:?}");
    assert!(!rig.dev.active);
    rig.state.playing = true;
    rig.run(4);
    assert!(rig.dev.active && rig.dev.playing);
}

#[test]
fn shuffle_and_repeat_are_forwarded_after_the_device_is_active() {
    let mut rig = Rig::new(1);
    rig.state.play_context(vec![track("a"), track("b")], 0);
    rig.run(3);
    rig.state.shuffle = true;
    rig.state.repeat = RepeatMode::All;
    let cmds = rig.run(3);
    assert!(cmds.contains(&TransportCmd::Shuffle(true)));
    assert!(cmds.contains(&TransportCmd::Repeat(RepeatMode::All)));
}
