//! Live audio analysis for the GUI's beat-synced visuals.
//!
//! The daemon owns playback, so it is the only place that hears the real samples. This module
//! turns them into small frames the GUI can draw: a 24-band spectrum, a bass level and a beat
//! flag. It has no dependencies (own FFT) and does no I/O, so it is easy to test with
//! synthetic signals.
//!
//! How a beat is found: for every hop (1024 samples, ~23 ms at 44.1 kHz) the low end of the
//! spectrum (kick, bass) and a lighter low-mid part (snare, clap) are compared with the hop
//! before. Only *rises* count (spectral flux). A beat fires when that rise stands clearly above
//! the last second of rises (mean + 1.4 standard deviations), and never twice within 250 ms.
//! That follows the music's own accents, so it keeps working on songs whose tempo drifts.

use std::collections::VecDeque;
use std::f32::consts::PI;

/// Bars the GUI gets per frame.
pub const BANDS: usize = 24;
/// Spotify streams are 44.1 kHz stereo.
pub const SAMPLE_RATE: f32 = 44_100.0;
pub const FFT_SIZE: usize = 2048;
/// New samples per frame (about 43 frames a second).
pub const HOP: usize = 1024;

const BINS: usize = FFT_SIZE / 2;
const BIN_HZ: f32 = SAMPLE_RATE / FFT_SIZE as f32;
const F_LOW: f32 = 50.0;
const F_HIGH: f32 = 14_000.0;
/// Onset history for the adaptive threshold, about one second.
const FLUX_HISTORY: usize = 43;
/// Fewer rises than this and the threshold is not trustworthy yet.
const FLUX_WARMUP: usize = 8;
/// Shortest gap between two beats: 250 ms (240 bpm).
const MIN_BEAT_GAP_HOPS: usize = 10;
/// Quieter than this (dBFS, loudest band) counts as silence.
const SILENCE_DB: f32 = -66.0;
/// Decibels between a full bar and an empty one.
const RANGE_DB: f32 = 44.0;
/// Bins used for the kick / bass onset (about 40 .. 150 Hz) and for the snare-ish onset
/// (about 150 .. 500 Hz).
const BASS_BINS: std::ops::RangeInclusive<usize> = 2..=7;
const MID_BINS: std::ops::RangeInclusive<usize> = 8..=23;

/// One frame of analysis. `beat` is 0 when nothing hit, otherwise the strength 1..=255.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Frame {
    pub bands: [u8; BANDS],
    pub bass: u8,
    pub beat: u8,
}

pub struct Analyzer {
    window: Vec<f32>,
    tw_cos: Vec<f32>,
    tw_sin: Vec<f32>,
    bit_rev: Vec<usize>,
    /// The last `FFT_SIZE` mono samples.
    buf: Vec<f32>,
    /// Mono samples waiting for a full hop.
    pending: Vec<f32>,
    re: Vec<f32>,
    im: Vec<f32>,
    mag: Vec<f32>,
    /// Log magnitude of the previous frame, for the flux.
    prev_log: Vec<f32>,
    /// Fractional bin range of every band.
    band_bins: [(f32, f32); BANDS],
    /// Pink-ish tilt so the treble is not always lower than the bass.
    tilt_db: [f32; BANDS],
    flux_hist: VecDeque<f32>,
    prev_flux: f32,
    hops_since_beat: usize,
    /// Slowly falling loudest level, so quiet and loud songs both fill the bars.
    ref_db: f32,
}

impl Default for Analyzer {
    fn default() -> Self {
        Self::new()
    }
}

impl Analyzer {
    pub fn new() -> Self {
        let n = FFT_SIZE;
        let window = (0..n).map(|i| 0.5 - 0.5 * (2.0 * PI * i as f32 / n as f32).cos()).collect();
        let tw_cos = (0..n / 2).map(|k| (2.0 * PI * k as f32 / n as f32).cos()).collect();
        let tw_sin = (0..n / 2).map(|k| (2.0 * PI * k as f32 / n as f32).sin()).collect();
        let bits = n.trailing_zeros();
        let bit_rev = (0..n).map(|i| i.reverse_bits() >> (usize::BITS - bits)).collect();

        let mut band_bins = [(0.0, 0.0); BANDS];
        let mut tilt_db = [0.0; BANDS];
        let ratio = F_HIGH / F_LOW;
        for b in 0..BANDS {
            let lo = F_LOW * ratio.powf(b as f32 / BANDS as f32);
            let hi = F_LOW * ratio.powf((b + 1) as f32 / BANDS as f32);
            band_bins[b] = (lo / BIN_HZ, hi / BIN_HZ);
            let centre = (lo * hi).sqrt();
            tilt_db[b] = 3.0 * (centre / 200.0).log2();
        }

        Self {
            window,
            tw_cos,
            tw_sin,
            bit_rev,
            buf: vec![0.0; n],
            pending: Vec::with_capacity(HOP * 4),
            re: vec![0.0; n],
            im: vec![0.0; n],
            mag: vec![0.0; BINS],
            prev_log: vec![0.0; BINS],
            band_bins,
            tilt_db,
            flux_hist: VecDeque::with_capacity(FLUX_HISTORY + 1),
            prev_flux: 0.0,
            hops_since_beat: MIN_BEAT_GAP_HOPS,
            ref_db: -36.0,
        }
    }

    /// Forget everything heard so far (a pause, a new track).
    pub fn reset(&mut self) {
        self.buf.iter_mut().for_each(|s| *s = 0.0);
        self.pending.clear();
        self.prev_log.iter_mut().for_each(|s| *s = 0.0);
        self.flux_hist.clear();
        self.prev_flux = 0.0;
        self.hops_since_beat = MIN_BEAT_GAP_HOPS;
        self.ref_db = -36.0;
    }

    /// Feed interleaved stereo samples (-1.0 ..= 1.0). Every full hop appends one [`Frame`].
    pub fn push_interleaved(&mut self, samples: &[f64], out: &mut Vec<Frame>) {
        for pair in samples.chunks_exact(2) {
            self.pending.push(((pair[0] + pair[1]) * 0.5) as f32);
        }
        while self.pending.len() >= HOP {
            self.buf.copy_within(HOP.., 0);
            self.buf[FFT_SIZE - HOP..].copy_from_slice(&self.pending[..HOP]);
            self.pending.drain(..HOP);
            out.push(self.analyze());
        }
    }

    fn fft(&mut self) {
        let n = FFT_SIZE;
        for i in 0..n {
            let j = self.bit_rev[i];
            if j > i {
                self.re.swap(i, j);
                self.im.swap(i, j);
            }
        }
        let mut len = 2;
        while len <= n {
            let half = len / 2;
            let step = n / len;
            for start in (0..n).step_by(len) {
                for k in 0..half {
                    let wr = self.tw_cos[k * step];
                    let wi = -self.tw_sin[k * step];
                    let (a, b) = (start + k, start + k + half);
                    let tr = self.re[b] * wr - self.im[b] * wi;
                    let ti = self.re[b] * wi + self.im[b] * wr;
                    self.re[b] = self.re[a] - tr;
                    self.im[b] = self.im[a] - ti;
                    self.re[a] += tr;
                    self.im[a] += ti;
                }
            }
            len *= 2;
        }
    }

    fn analyze(&mut self) -> Frame {
        for i in 0..FFT_SIZE {
            self.re[i] = self.buf[i] * self.window[i];
            self.im[i] = 0.0;
        }
        self.fft();
        // A full-scale sine comes out near 1.0 (Hann window: coherent gain 0.5, two halves).
        let scale = 4.0 / FFT_SIZE as f32;
        for k in 0..BINS {
            self.mag[k] = (self.re[k] * self.re[k] + self.im[k] * self.im[k]).sqrt() * scale;
        }

        let mut raw_max = f32::MIN;
        let mut db = [0.0f32; BANDS];
        for b in 0..BANDS {
            let (lo, hi) = self.band_bins[b];
            let amp = band_amplitude(&self.mag, lo, hi);
            let d = 20.0 * amp.max(1e-9).log10();
            raw_max = raw_max.max(d);
            db[b] = d + self.tilt_db[b];
        }

        let silent = raw_max < SILENCE_DB;
        let mut frame = Frame::default();

        if !silent {
            let peak = db.iter().copied().fold(f32::MIN, f32::max);
            self.ref_db = if peak > self.ref_db { peak } else { (self.ref_db - 0.12).max(-36.0) };
            for b in 0..BANDS {
                let level = ((db[b] - (self.ref_db - RANGE_DB)) / RANGE_DB).clamp(0.0, 1.0);
                frame.bands[b] = (level.powf(1.2) * 255.0).round() as u8;
            }
            let bass: f32 = frame.bands[..6].iter().map(|&v| v as f32).sum::<f32>() / 6.0;
            frame.bass = bass.round() as u8;
        }

        // Onset strength: how much the low end rose since the last hop.
        let mut bass_flux = 0.0;
        let mut mid_flux = 0.0;
        for k in BASS_BINS {
            let l = (1.0 + 400.0 * self.mag[k]).ln();
            bass_flux += (l - self.prev_log[k]).max(0.0);
            self.prev_log[k] = l;
        }
        for k in MID_BINS {
            let l = (1.0 + 400.0 * self.mag[k]).ln();
            mid_flux += (l - self.prev_log[k]).max(0.0);
            self.prev_log[k] = l;
        }
        let flux = bass_flux / BASS_BINS.clone().count() as f32
            + 0.5 * mid_flux / MID_BINS.clone().count() as f32;

        self.hops_since_beat = self.hops_since_beat.saturating_add(1);
        if !silent && self.flux_hist.len() >= FLUX_WARMUP {
            let n = self.flux_hist.len() as f32;
            let mean = self.flux_hist.iter().sum::<f32>() / n;
            let var = self.flux_hist.iter().map(|f| (f - mean) * (f - mean)).sum::<f32>() / n;
            let threshold = mean + 1.4 * var.sqrt() + 0.04;
            let recent_peak = self.flux_hist.iter().copied().fold(0.0f32, f32::max).max(flux);
            if flux > threshold && flux > self.prev_flux && self.hops_since_beat >= MIN_BEAT_GAP_HOPS {
                let strength = 0.35 + 0.65 * (flux / recent_peak);
                frame.beat = (strength.clamp(0.0, 1.0) * 255.0).round().max(1.0) as u8;
                self.hops_since_beat = 0;
            }
        }
        self.prev_flux = flux;
        self.flux_hist.push_back(flux);
        if self.flux_hist.len() > FLUX_HISTORY {
            self.flux_hist.pop_front();
        }

        frame
    }
}

/// Amplitude of one band. Wide bands average the power of their bins; a band narrower than a
/// bin (the lowest ones) reads the spectrum at its middle, interpolated between two bins.
fn band_amplitude(mag: &[f32], lo: f32, hi: f32) -> f32 {
    let last = mag.len() - 1;
    if hi - lo < 1.0 {
        let centre = 0.5 * (lo + hi);
        let i = (centre.floor() as usize).min(last);
        let f = centre - i as f32;
        return mag[i] * (1.0 - f) + mag[(i + 1).min(last)] * f;
    }
    let first = (lo.floor() as usize).max(1);
    let end = (hi.ceil() as usize).min(last);
    let (mut sum, mut n) = (0.0f32, 0usize);
    for &m in &mag[first..=end.max(first)] {
        sum += m * m;
        n += 1;
    }
    (sum / n.max(1) as f32).sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(signal: &[f64]) -> Vec<Frame> {
        let mut a = Analyzer::new();
        let mut out = Vec::new();
        // Feed in odd-sized chunks, like decoder packets.
        for chunk in signal.chunks(2 * 1500) {
            a.push_interleaved(chunk, &mut out);
        }
        out
    }

    fn stereo(mono: impl Iterator<Item = f64>) -> Vec<f64> {
        mono.flat_map(|s| [s, s]).collect()
    }

    /// A kick drum every `period` samples: a 55 Hz sine with a 60 ms decay.
    fn kick_train(seconds: f64, period: usize) -> Vec<f64> {
        let total = (seconds * SAMPLE_RATE as f64) as usize;
        stereo((0..total).map(|i| {
            let t = (i % period) as f64 / SAMPLE_RATE as f64;
            0.8 * (2.0 * std::f64::consts::PI * 55.0 * t).sin() * (-t / 0.06).exp()
        }))
    }

    #[test]
    fn fft_puts_a_sine_in_the_right_bin() {
        // A sine exactly on bin 40 must peak there.
        let freq = 40.0 * BIN_HZ as f64;
        let sig = stereo(
            (0..FFT_SIZE * 2).map(|i| 0.5 * (2.0 * std::f64::consts::PI * freq * i as f64 / SAMPLE_RATE as f64).sin()),
        );
        let mut a = Analyzer::new();
        let mut out = Vec::new();
        a.push_interleaved(&sig, &mut out);
        let (peak_bin, peak) = a
            .mag
            .iter()
            .copied()
            .enumerate()
            .fold((0, 0.0f32), |acc, (i, m)| if m > acc.1 { (i, m) } else { acc });
        assert_eq!(peak_bin, 40);
        assert!((peak - 0.5).abs() < 0.03, "amplitude {peak}");
    }

    #[test]
    fn silence_gives_empty_frames_and_no_beats() {
        let frames = run(&vec![0.0; 2 * 44_100 * 3]);
        assert!(frames.len() > 100);
        assert!(frames.iter().all(|f| f.beat == 0 && f.bass == 0 && f.bands.iter().all(|&b| b == 0)));
    }

    #[test]
    fn a_steady_tone_is_not_a_beat() {
        let sig = stereo((0..44_100 * 6).map(|i| {
            0.4 * (2.0 * std::f64::consts::PI * 1000.0 * i as f64 / SAMPLE_RATE as f64).sin()
        }));
        let frames = run(&sig);
        let beats = frames.iter().filter(|f| f.beat > 0).count();
        assert!(beats <= 1, "{beats} beats on a steady tone");
        // The 1 kHz band (and not the lowest) carries the energy.
        let last = frames.last().unwrap();
        let loudest = last.bands.iter().enumerate().max_by_key(|(_, v)| **v).unwrap().0;
        assert!((12..=16).contains(&loudest), "loudest band {loudest}");
        assert!(last.bands[0] < 40);
    }

    #[test]
    fn kicks_at_120_bpm_are_found_on_time() {
        let period = 22_050; // 0.5 s
        let frames = run(&kick_train(14.0, period));
        let hop_s = HOP as f32 / SAMPLE_RATE;
        let beats: Vec<f32> = frames
            .iter()
            .enumerate()
            .filter(|(_, f)| f.beat > 0)
            .map(|(i, _)| (i + 1) as f32 * hop_s) // a frame covers the audio up to its end
            .collect();
        // 28 kicks in 14 s; the first second is warm-up.
        assert!((20..=29).contains(&beats.len()), "found {} beats", beats.len());
        for pair in beats.windows(2) {
            assert!(pair[1] - pair[0] >= 0.24, "two beats {:.3}s apart", pair[1] - pair[0]);
        }
        // Every beat after warm-up lands within 70 ms of a kick.
        for &t in beats.iter().filter(|&&t| t > 2.0) {
            let nearest = (t / 0.5).round() * 0.5;
            assert!((t - nearest).abs() < 0.07, "beat at {t:.3}s is {:.0} ms from a kick", (t - nearest).abs() * 1000.0);
        }
    }

    #[test]
    fn reset_clears_state() {
        let mut a = Analyzer::new();
        let mut out = Vec::new();
        a.push_interleaved(&kick_train(3.0, 22_050), &mut out);
        a.reset();
        assert!(a.pending.is_empty() && a.flux_hist.is_empty());
        assert_eq!(a.hops_since_beat, MIN_BEAT_GAP_HOPS);
    }
}
