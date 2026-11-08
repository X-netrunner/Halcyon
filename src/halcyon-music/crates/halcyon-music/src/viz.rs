//! What the GUI knows about the beat right now.
//!
//! The daemon sends about 43 small frames a second while the queue drawer is open (a spectrum
//! and a beat flag, see `AudioLevels` in the protocol). The drawer shows no bars: only the
//! beat. [`AudioViz`] keeps the recent beats and turns them into a soft swell of the cover and
//! a few ripples that spread from it and fade. Views ask for a [`VizFrame`] snapshot and draw
//! from that; nothing here touches the window.
//!
//! Without real audio (an older daemon, or the stream has not started) there is no swell and no
//! ripples: the cover simply rests. Nothing is ever faked.

// Band indices are bounded by the fixed band count.
#![allow(clippy::indexing_slicing)]

use std::collections::VecDeque;
use std::time::{Duration, Instant};

pub const BANDS: usize = 24;
/// Ripples drawn at once, at most.
pub const MAX_RIPPLES: usize = 6;

/// A frame older than this means "no live audio".
const LIVE_FOR: Duration = Duration::from_millis(450);
/// Bass follower: rises in about 80 ms, falls in about 400 ms.
const ATTACK: f32 = 0.08;
const RELEASE: f32 = 0.4;
/// The swell eases in over this long and fades with this time constant (seconds).
const PULSE_RISE: f32 = 0.09;
const PULSE_DECAY: f32 = 0.30;
/// A ripple spreads and fades over this long.
const RIPPLE_SECS: f32 = 2.0;
/// Beats closer together than this make no new ripple: it keeps a busy song calm.
const MIN_BEAT_GAP: Duration = Duration::from_millis(380);

#[derive(Debug, Clone)]
pub struct AudioViz {
    target: [f32; BANDS],
    shown: [f32; BANDS],
    last_frame: Option<Instant>,
    /// Recent accepted beats and their strength, oldest first.
    beats: VecDeque<(Instant, f32)>,
    last_tick: Instant,
}

/// One ripple: `progress` runs 0.0 (just left the cover) to 1.0 (gone).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Ripple {
    pub progress: f32,
    pub strength: f32,
}

/// Everything a view needs to draw one frame of the beat.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct VizFrame {
    /// 0.0 ..= 1.0: eases up on a beat, then fades. Always 0.0 without real audio.
    pub pulse: f32,
    /// A slow swell that follows the bass line (0.0 ..= 1.0).
    pub bass: f32,
    /// Ripples still on their way out, newest first.
    pub ripples: [Option<Ripple>; MAX_RIPPLES],
    /// True when this comes from the real audio.
    pub live: bool,
}

impl VizFrame {
    /// A resting frame: no swell, no ripples (paused, motion reduced, or no audio).
    pub fn still() -> Self {
        Self { pulse: 0.0, bass: 0.0, ripples: [None; MAX_RIPPLES], live: false }
    }
}

impl Default for AudioViz {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioViz {
    pub fn new() -> Self {
        Self {
            target: [0.0; BANDS],
            shown: [0.0; BANDS],
            last_frame: None,
            beats: VecDeque::with_capacity(MAX_RIPPLES + 1),
            last_tick: Instant::now(),
        }
    }

    /// A frame arrived from the daemon.
    pub fn push(&mut self, bands: &[u8], beat: u8, now: Instant) {
        for (slot, &b) in self.target.iter_mut().zip(bands) {
            *slot = f32::from(b) / 255.0;
        }
        if beat > 0 {
            let spaced = self.beats.back().is_none_or(|(at, _)| now.saturating_duration_since(*at) >= MIN_BEAT_GAP);
            if spaced {
                self.beats.push_back((now, f32::from(beat) / 255.0));
                while self.beats.len() > MAX_RIPPLES {
                    self.beats.pop_front();
                }
            }
        }
        self.last_frame = Some(now);
    }

    /// True while frames keep arriving.
    pub fn is_live(&self, now: Instant) -> bool {
        self.last_frame.is_some_and(|t| now.saturating_duration_since(t) <= LIVE_FOR)
    }

    /// Move the smoothed bass toward the latest frame. Call once per animation tick.
    pub fn tick(&mut self, now: Instant, playing: bool) {
        let dt = now.saturating_duration_since(self.last_tick).as_secs_f32().min(0.1);
        self.last_tick = now;
        let silent = !playing || !self.is_live(now);
        let attack = 1.0 - (-dt / ATTACK).exp();
        let release = 1.0 - (-dt / RELEASE).exp();
        for (shown, &target) in self.shown.iter_mut().zip(&self.target) {
            let goal = if silent { 0.0 } else { target };
            let k = if goal > *shown { attack } else { release };
            *shown += (goal - *shown) * k;
        }
        if silent {
            self.target = [0.0; BANDS];
        }
    }

    /// The newest beat's swell at `now`: a soft rise, then a slow fade.
    fn pulse_at(&self, now: Instant) -> f32 {
        let Some(&(at, strength)) = self.beats.back() else { return 0.0 };
        let age = now.saturating_duration_since(at).as_secs_f32();
        let rise = (age / PULSE_RISE).min(1.0);
        let rise = rise * rise * (3.0 - 2.0 * rise);
        let v = 0.8 * strength * rise * (-age / PULSE_DECAY).exp();
        if v < 0.01 {
            0.0
        } else {
            v
        }
    }

    /// Snapshot for drawing.
    pub fn frame(&self, now: Instant, playing: bool, reduce_motion: bool) -> VizFrame {
        if reduce_motion || !playing || !self.is_live(now) {
            return VizFrame::still();
        }
        let mut ripples = [None; MAX_RIPPLES];
        for (slot, &(at, strength)) in ripples.iter_mut().zip(self.beats.iter().rev()) {
            let progress = now.saturating_duration_since(at).as_secs_f32() / RIPPLE_SECS;
            if progress < 1.0 {
                *slot = Some(Ripple { progress, strength });
            }
        }
        let bass = self.shown[..4].iter().sum::<f32>() / 4.0;
        VizFrame { pulse: self.pulse_at(now), bass, ripples, live: true }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ms(base: Instant, n: u64) -> Instant {
        base + Duration::from_millis(n)
    }

    fn live_count(f: &VizFrame) -> usize {
        f.ripples.iter().flatten().count()
    }

    #[test]
    fn a_beat_swells_softly_then_fades() {
        let t0 = Instant::now();
        let mut v = AudioViz::new();
        v.push(&[200; BANDS], 255, t0);
        let start = v.frame(t0, true, false);
        let peak = v.frame(ms(t0, 100), true, false);
        let later = v.frame(ms(t0, 700), true, false);
        assert_eq!(start.pulse, 0.0, "it must not snap on");
        assert!(peak.pulse > 0.3 && peak.pulse <= 0.8, "peak {}", peak.pulse);
        assert!(later.pulse < peak.pulse * 0.3, "later {}", later.pulse);
    }

    #[test]
    fn each_beat_makes_a_ripple_that_ends() {
        let t0 = Instant::now();
        let mut v = AudioViz::new();
        v.push(&[0; BANDS], 255, t0);
        v.push(&[0; BANDS], 255, ms(t0, 600));
        v.push(&[0; BANDS], 0, ms(t0, 1500));
        assert_eq!(live_count(&v.frame(ms(t0, 1500), true, false)), 2);
        // The first is gone after 2 s; the second is still travelling.
        v.push(&[0; BANDS], 0, ms(t0, 2100));
        let f = v.frame(ms(t0, 2100), true, false);
        assert_eq!(live_count(&f), 1);
        let r = f.ripples[0].expect("newest first");
        assert!(r.progress > 0.7 && r.progress < 0.8, "{}", r.progress);
    }

    #[test]
    fn beats_too_close_together_are_one_ripple() {
        let t0 = Instant::now();
        let mut v = AudioViz::new();
        v.push(&[0; BANDS], 255, t0);
        v.push(&[0; BANDS], 255, ms(t0, 250));
        assert_eq!(live_count(&v.frame(ms(t0, 260), true, false)), 1);
    }

    #[test]
    fn no_frames_paused_or_reduced_motion_means_rest() {
        let t0 = Instant::now();
        let mut v = AudioViz::new();
        v.push(&[255; BANDS], 255, t0);
        assert_eq!(v.frame(ms(t0, 2000), true, false), VizFrame::still(), "stale frames");
        assert_eq!(v.frame(ms(t0, 10), false, false), VizFrame::still(), "paused");
        assert_eq!(v.frame(ms(t0, 10), true, true), VizFrame::still(), "reduced motion");
        assert!(v.frame(ms(t0, 10), true, false).live);
    }

    #[test]
    fn bass_rises_and_falls_gently() {
        let t0 = Instant::now();
        let mut v = AudioViz::new();
        v.last_tick = t0;
        v.push(&[255; BANDS], 0, t0);
        v.tick(ms(t0, 60), true);
        let risen = v.shown[1];
        assert!(risen > 0.3 && risen < 0.8, "rose to {risen}");
        v.push(&[0; BANDS], 0, ms(t0, 60));
        v.tick(ms(t0, 160), true);
        assert!(v.shown[1] > risen * 0.6, "fell too fast");
    }
}
