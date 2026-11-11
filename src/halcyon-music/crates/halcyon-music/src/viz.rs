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
/// The full-screen Aurora lets go a little slower still, so its waves settle instead of dropping.
const CALM_RELEASE: f32 = 0.7;
/// Below this a smoothed band counts as at rest (the animation can stop).
const SETTLED: f32 = 0.004;
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
    /// Same follower with a slower release (Aurora).
    calm: [f32; BANDS],
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
        Self {
            pulse: 0.0,
            bass: 0.0,
            ripples: [None; MAX_RIPPLES],
            live: false,
        }
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
            calm: [0.0; BANDS],
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
            let spaced = self
                .beats
                .back()
                .is_none_or(|(at, _)| now.saturating_duration_since(*at) >= MIN_BEAT_GAP);
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
        self.last_frame
            .is_some_and(|t| now.saturating_duration_since(t) <= LIVE_FOR)
    }

    /// Move the smoothed bass toward the latest frame. Call once per animation tick.
    pub fn tick(&mut self, now: Instant, playing: bool) {
        let dt = now
            .saturating_duration_since(self.last_tick)
            .as_secs_f32()
            .min(0.1);
        self.last_tick = now;
        let silent = !playing || !self.is_live(now);
        let attack = 1.0 - (-dt / ATTACK).exp();
        let release = 1.0 - (-dt / RELEASE).exp();
        for (shown, &target) in self.shown.iter_mut().zip(&self.target) {
            let goal = if silent { 0.0 } else { target };
            let k = if goal > *shown { attack } else { release };
            *shown += (goal - *shown) * k;
        }
        let calm_release = 1.0 - (-dt / CALM_RELEASE).exp();
        for (calm, &target) in self.calm.iter_mut().zip(&self.target) {
            let goal = if silent { 0.0 } else { target };
            let k = if goal > *calm { attack } else { calm_release };
            *calm += (goal - *calm) * k;
        }
        if silent {
            self.target = [0.0; BANDS];
        }
    }

    /// The smoothed spectrum, 0.0 ..= 1.0 per band, for the full-screen visualizers. `calm`
    /// picks the slower-release follower. All zeros when motion is reduced. When playback
    /// stops or frames stop arriving the values are not cut to zero here: `tick` lets them
    /// fall, so a pause settles softly instead of jumping.
    pub fn bands(&self, reduce_motion: bool, calm: bool) -> [f32; BANDS] {
        if reduce_motion {
            return [0.0; BANDS];
        }
        let src = if calm { &self.calm } else { &self.shown };
        let mut out = [0.0; BANDS];
        for (o, &v) in out.iter_mut().zip(src) {
            *o = if v.is_finite() {
                v.clamp(0.0, 1.0)
            } else {
                0.0
            };
        }
        out
    }

    /// True while the smoothed bands have not yet fallen to rest: the animation must keep
    /// ticking so the shape finishes settling.
    pub fn is_settling(&self) -> bool {
        self.shown.iter().chain(&self.calm).any(|&v| v > SETTLED)
    }

    /// The newest beat's swell at `now`: a soft rise, then a slow fade.
    fn pulse_at(&self, now: Instant) -> f32 {
        let Some(&(at, strength)) = self.beats.back() else {
            return 0.0;
        };
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
        VizFrame {
            pulse: self.pulse_at(now),
            bass,
            ripples,
            live: true,
        }
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
        assert_eq!(
            v.frame(ms(t0, 2000), true, false),
            VizFrame::still(),
            "stale frames"
        );
        assert_eq!(
            v.frame(ms(t0, 10), false, false),
            VizFrame::still(),
            "paused"
        );
        assert_eq!(
            v.frame(ms(t0, 10), true, true),
            VizFrame::still(),
            "reduced motion"
        );
        assert!(v.frame(ms(t0, 10), true, false).live);
    }

    #[test]
    fn calm_bands_let_go_more_slowly_than_the_plain_ones() {
        let t0 = Instant::now();
        let mut v = AudioViz::new();
        v.last_tick = t0;
        v.push(&[255; BANDS], 0, t0);
        v.tick(ms(t0, 100), true);
        v.push(&[0; BANDS], 0, ms(t0, 100));
        v.tick(ms(t0, 300), true);
        let plain = v.bands(false, false);
        let calm = v.bands(false, true);
        assert!(calm[3] > plain[3], "calm {} plain {}", calm[3], plain[3]);
    }

    #[test]
    fn bands_are_zero_with_reduced_motion_and_always_in_range() {
        let t0 = Instant::now();
        let mut v = AudioViz::new();
        v.last_tick = t0;
        v.push(&[255; BANDS], 0, t0);
        v.tick(ms(t0, 100), true);
        assert!(v.bands(true, false).iter().all(|&b| b == 0.0));
        assert!(v.bands(true, true).iter().all(|&b| b == 0.0));
        assert!(v
            .bands(false, false)
            .iter()
            .all(|&b| (0.0..=1.0).contains(&b)));
    }

    #[test]
    fn a_pause_settles_and_then_stops_asking_for_ticks() {
        let t0 = Instant::now();
        let mut v = AudioViz::new();
        v.last_tick = t0;
        v.push(&[200; BANDS], 0, t0);
        v.tick(ms(t0, 100), true);
        assert!(v.is_settling());
        // Paused: each tick pulls the bands toward zero until they are at rest.
        let mut at = 100;
        for _ in 0..200 {
            at += 33;
            v.tick(ms(t0, at), false);
        }
        assert!(!v.is_settling(), "still settling after {at} ms");
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
