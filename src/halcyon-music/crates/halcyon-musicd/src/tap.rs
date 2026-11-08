//! A listening post between librespot and the real audio sink.
//!
//! [`TapSink`] wraps the sink librespot would use anyway. Every packet is handed to the
//! [`Analyzer`] first and then passed on untouched, so the sound itself is never altered.
//!
//! Timing is what makes the visuals feel in sync. A sink is written ahead of the speakers
//! (the device buffers a few hundred milliseconds), so frames made at write time would arrive
//! early. A small thread therefore holds every frame back until the moment its audio is due
//! at the speakers: the first frame after a start is anchored to "now + device latency" and the
//! rest follow the sample clock from there. If the stream stalls and runs behind, it anchors
//! again. `HALCYON_VIZ_LATENCY_MS` shifts the whole thing if a setup needs it (default 90 ms;
//! raise it when the visuals run ahead of the sound, lower it when they lag).
//!
//! Nothing is analysed or sent while no GUI has asked for frames
//! (`SetAudioStream { enabled: true }`).

use crate::beat::{Analyzer, Frame, HOP, SAMPLE_RATE};
use halcyon_music_core::protocol::{self, EventBody};
use librespot_playback::audio_backend::{Sink, SinkResult};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;
use std::collections::VecDeque;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tokio::sync::broadcast;
use tracing::debug;

/// Where timed frames go: a channel of their own, so about 43 messages a second can never push
/// an important event (a state change, a search result) out of the main event channel.
pub type AudioBus = broadcast::Sender<protocol::Event>;

/// The one audio channel of this daemon. A process-wide handle keeps the sink builder and the
/// client handler apart from `DaemonContext` and `AudioEngine::new`, whose shapes other code
/// (and the tests) build by hand.
pub fn audio_bus() -> &'static AudioBus {
    static BUS: OnceLock<AudioBus> = OnceLock::new();
    BUS.get_or_init(|| broadcast::channel(64).0)
}

/// How long after a packet is handed to the sink it is heard, when nothing says otherwise.
const DEFAULT_LATENCY_MS: u64 = 90;
/// Running this far behind the sample clock means the stream stalled: anchor again.
const RESYNC_AFTER: Duration = Duration::from_millis(250);
/// Never hold more than this much audio back (a runaway queue would mean wrong timing).
const MAX_QUEUED: usize = 128;

fn latency() -> Duration {
    let ms = std::env::var("HALCYON_VIZ_LATENCY_MS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .map(|v| v.min(1_000))
        .unwrap_or(DEFAULT_LATENCY_MS);
    Duration::from_millis(ms)
}

enum Msg {
    /// A frame and its position on the sample clock, counted in hops.
    Frame(u64, Frame),
    /// Playback stopped or restarted: forget the timing and show silence.
    Reset,
}

pub struct TapSink {
    inner: Box<dyn Sink>,
    analyzer: Analyzer,
    scratch: Vec<Frame>,
    tx: mpsc::Sender<Msg>,
    bus: AudioBus,
    hop_index: u64,
}

impl TapSink {
    /// Wrap `inner` and start the pacing thread (it ends when the sink is dropped).
    pub fn new(inner: Box<dyn Sink>, bus: AudioBus) -> Self {
        let (tx, rx) = mpsc::channel();
        let thread_bus = bus.clone();
        let spawned = std::thread::Builder::new()
            .name("halcyon-viz-pacer".into())
            .spawn(move || pace(rx, thread_bus, latency()));
        if let Err(e) = spawned {
            // Without the thread the sink still plays; only the visuals are lost.
            debug!("could not start the audio pacing thread: {e}");
        }
        Self { inner, analyzer: Analyzer::new(), scratch: Vec::new(), tx, bus, hop_index: 0 }
    }

    fn reset(&mut self) {
        self.analyzer.reset();
        self.hop_index = 0;
        let _ = self.tx.send(Msg::Reset);
    }
}

impl Sink for TapSink {
    fn start(&mut self) -> SinkResult<()> {
        self.reset();
        self.inner.start()
    }

    fn stop(&mut self) -> SinkResult<()> {
        self.reset();
        self.inner.stop()
    }

    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        // Only analyse while a GUI is listening, and never let analysis get in playback's way.
        if self.bus.receiver_count() > 0 {
            if let AudioPacket::Samples(samples) = &packet {
                self.scratch.clear();
                self.analyzer.push_interleaved(samples, &mut self.scratch);
                for frame in self.scratch.drain(..) {
                    let _ = self.tx.send(Msg::Frame(self.hop_index, frame));
                    self.hop_index += 1;
                }
            }
        } else if self.hop_index != 0 {
            // Everyone stopped listening: start clean when they come back.
            self.analyzer.reset();
            self.hop_index = 0;
            let _ = self.tx.send(Msg::Reset);
        }
        self.inner.write(packet, converter)
    }
}

fn level_event(frame: &Frame) -> protocol::Event {
    protocol::event(EventBody::AudioLevels {
        bands: frame.bands.to_vec(),
        bass: frame.bass,
        beat: frame.beat,
    })
}

/// Release frames at the moment their audio reaches the speakers.
fn pace(rx: mpsc::Receiver<Msg>, bus: AudioBus, latency: Duration) {
    let hop = Duration::from_secs_f64(HOP as f64 / f64::from(SAMPLE_RATE));
    let mut queue: VecDeque<(Instant, Frame)> = VecDeque::new();
    // (when the anchor frame is heard, its hop index)
    let mut anchor: Option<(Instant, u64)> = None;

    loop {
        let wait = match queue.front() {
            Some((due, _)) => due.saturating_duration_since(Instant::now()),
            None => Duration::from_millis(500),
        };
        match rx.recv_timeout(wait) {
            Ok(Msg::Frame(index, frame)) => {
                let now = Instant::now();
                let (anchor_at, anchor_index) = *anchor.get_or_insert((now + latency, index));
                let steps = u32::try_from(index.saturating_sub(anchor_index)).unwrap_or(u32::MAX);
                let mut due = anchor_at + hop.saturating_mul(steps);
                if due + RESYNC_AFTER < now {
                    anchor = Some((now + latency, index));
                    due = now + latency;
                }
                if queue.len() >= MAX_QUEUED {
                    queue.pop_front();
                }
                queue.push_back((due, frame));
            }
            Ok(Msg::Reset) => {
                queue.clear();
                anchor = None;
                // One silent frame lets the visuals settle instead of freezing mid-bar.
                let _ = bus.send(level_event(&Frame::default()));
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        let now = Instant::now();
        while queue.front().is_some_and(|(due, _)| *due <= now) {
            if let Some((_, frame)) = queue.pop_front() {
                // No receivers is fine: the GUI turned the stream off.
                let _ = bus.send(level_event(&frame));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_are_released_in_order_and_on_time() {
        let (tx, rx) = mpsc::channel();
        let (bus, mut listener) = broadcast::channel(64);
        let handle = std::thread::spawn(move || pace(rx, bus, Duration::from_millis(40)));

        let start = Instant::now();
        for i in 0..5u64 {
            let frame = Frame { beat: (i + 1) as u8, ..Frame::default() };
            tx.send(Msg::Frame(i, frame)).expect("send");
        }
        let mut seen = Vec::new();
        while seen.len() < 5 {
            match listener.try_recv() {
                Ok(ev) => {
                    if let EventBody::AudioLevels { beat, .. } = ev.body {
                        seen.push((beat, start.elapsed()));
                    }
                }
                Err(_) => std::thread::sleep(Duration::from_millis(2)),
            }
            assert!(start.elapsed() < Duration::from_secs(2), "frames never arrived");
        }
        let order: Vec<u8> = seen.iter().map(|(b, _)| *b).collect();
        assert_eq!(order, vec![1, 2, 3, 4, 5]);
        // The first is held back by roughly the latency, the last by latency + 4 hops (~93 ms).
        assert!(seen[0].1 >= Duration::from_millis(35), "first frame too early: {:?}", seen[0].1);
        assert!(seen[4].1 >= Duration::from_millis(120), "last frame too early: {:?}", seen[4].1);
        drop(tx);
        let _ = handle.join();
    }

    #[test]
    fn reset_drops_what_is_waiting_and_sends_silence() {
        let (tx, rx) = mpsc::channel();
        let (bus, mut listener) = broadcast::channel(64);
        let handle = std::thread::spawn(move || pace(rx, bus, Duration::from_millis(500)));
        tx.send(Msg::Frame(0, Frame { beat: 9, ..Frame::default() })).expect("send");
        tx.send(Msg::Reset).expect("send");
        let first = loop {
            if let Ok(ev) = listener.try_recv() {
                break ev;
            }
            std::thread::sleep(Duration::from_millis(2));
        };
        match first.body {
            EventBody::AudioLevels { beat, bass, bands } => {
                assert_eq!((beat, bass), (0, 0));
                assert!(bands.iter().all(|b| *b == 0));
            }
            other => panic!("unexpected {other:?}"),
        }
        drop(tx);
        let _ = handle.join();
    }
}
