//! Part 5, rerank: the part that keeps testing new music (Thompson sampling) and the small seeded
//! random generator it needs.
//!
//! Every shelf keeps, for each source, a Beta(alpha, beta) belief about "if I put a song of this
//! source into an exploration slot, do you finish it?". Choosing the source of the next
//! exploration slot means drawing one sample from each belief and taking the highest, so a source
//! that has worked gets picked more often and a source that has not still gets an occasional try.
//! When you finish or skip an exploration song, the belief of its (shelf, source) is updated.
//!
//! No clock and no global random state: the generator is seeded by the caller (shelf and day), so
//! a list does not reshuffle on every launch.

use super::Source;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// splitmix64: tiny, fast, good enough for sampling.
#[derive(Debug, Clone)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    /// Uniform in the open interval (0, 1): never exactly 0 or 1, so `ln` is always finite.
    pub fn uniform(&mut self) -> f64 {
        ((self.next_u64() >> 11) as f64 + 0.5) / (1u64 << 53) as f64
    }

    /// Standard normal (Box-Muller).
    pub fn normal(&mut self) -> f64 {
        let u1 = self.uniform();
        let u2 = self.uniform();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }

    /// Gamma(shape, 1), Marsaglia and Tsang. At most 64 tries, then the mean.
    pub fn gamma(&mut self, shape: f64) -> f64 {
        if !shape.is_finite() || shape <= 0.0 {
            return 0.0;
        }
        if shape < 1.0 {
            let u = self.uniform();
            return self.gamma(shape + 1.0) * u.powf(1.0 / shape);
        }
        let d = shape - 1.0 / 3.0;
        let c = 1.0 / (9.0 * d).sqrt();
        for _ in 0..64 {
            let x = self.normal();
            let t = 1.0 + c * x;
            if t <= 0.0 {
                continue;
            }
            let v = t * t * t;
            let u = self.uniform();
            if u.ln() < 0.5 * x * x + d - d * v + d * v.ln() {
                return d * v;
            }
        }
        shape
    }

    /// Beta(a, b) in 0..=1.
    pub fn beta(&mut self, a: f64, b: f64) -> f64 {
        let x = self.gamma(a);
        let y = self.gamma(b);
        if x + y <= 0.0 {
            0.5
        } else {
            x / (x + y)
        }
    }
}

/// A stable 64-bit hash (FNV-1a) for seeds.
pub fn fnv64(text: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// The seed of a shelf: the same for a whole day, changed by `epoch` (a refresh the user asked for).
pub fn shelf_seed(shelf: &str, now: u64, epoch: u64) -> u64 {
    fnv64(shelf) ^ (now / 86_400).wrapping_mul(0x9e37_79b9) ^ epoch.wrapping_mul(0x85eb_ca6b)
}

/// Belief about one (shelf, source): successes and failures, both starting at 1 (no opinion).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Arm {
    pub alpha: f64,
    pub beta: f64,
}

impl Default for Arm {
    fn default() -> Self {
        Arm {
            alpha: 1.0,
            beta: 1.0,
        }
    }
}

/// An exploration song handed out and not yet judged.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Served {
    pub shelf: String,
    pub source: String,
    pub at: u64,
}

/// How much evidence an arm keeps. Beyond this the counts shrink, so a taste change is noticed.
const MAX_PSEUDO_COUNT: f64 = 60.0;
const SHRINK: f64 = 0.8;
/// Songs remembered as "handed out as exploration".
const MAX_SERVED: usize = 400;
/// An exploration song not judged within this time is forgotten (no reward either way).
const SERVED_TTL_SECS: u64 = 14 * 86_400;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Bandit {
    pub arms: BTreeMap<String, Arm>,
    pub served: BTreeMap<String, Served>,
}

pub fn arm_key(shelf: &str, source_name: &str) -> String {
    format!("{shelf}|{source_name}")
}

impl Bandit {
    pub fn arm(&self, shelf: &str, source: Source) -> Arm {
        self.arms
            .get(&arm_key(shelf, source.name()))
            .cloned()
            .unwrap_or_default()
    }

    /// One draw from the belief about (shelf, source).
    pub fn sample(&self, shelf: &str, source: Source, rng: &mut Rng) -> f64 {
        let a = self.arm(shelf, source);
        rng.beta(a.alpha, a.beta)
    }

    /// Expected success rate, for the debug view.
    pub fn mean(&self, shelf: &str, source: Source) -> f64 {
        let a = self.arm(shelf, source);
        a.alpha / (a.alpha + a.beta)
    }

    /// A song of `source` was finished (`true`) or skipped (`false`) in an exploration slot.
    pub fn reward(&mut self, shelf: &str, source_name: &str, success: bool) {
        let arm = self.arms.entry(arm_key(shelf, source_name)).or_default();
        if success {
            arm.alpha += 1.0;
        } else {
            arm.beta += 1.0;
        }
        if arm.alpha + arm.beta > MAX_PSEUDO_COUNT {
            arm.alpha = (arm.alpha * SHRINK).max(1.0);
            arm.beta = (arm.beta * SHRINK).max(1.0);
        }
    }

    /// Remember that `track_id` was put on `shelf` as an exploration song of `source`.
    pub fn note_served(&mut self, track_id: &str, shelf: &str, source: Source, at: u64) {
        self.served.insert(
            track_id.to_string(),
            Served {
                shelf: shelf.to_string(),
                source: source.name().to_string(),
                at,
            },
        );
        self.prune(at);
    }

    /// The listener finished or skipped `track_id`. If it was an exploration song, update the belief
    /// and forget it. Returns whether it was one.
    pub fn settle(&mut self, track_id: &str, success: bool) -> bool {
        match self.served.remove(track_id) {
            Some(s) => {
                self.reward(&s.shelf, &s.source, success);
                true
            }
            None => false,
        }
    }

    fn prune(&mut self, now: u64) {
        self.served
            .retain(|_, s| now.saturating_sub(s.at) <= SERVED_TTL_SECS);
        while self.served.len() > MAX_SERVED {
            let oldest = self
                .served
                .iter()
                .min_by(|a, b| a.1.at.cmp(&b.1.at).then_with(|| a.0.cmp(b.0)))
                .map(|(k, _)| k.clone());
            match oldest {
                Some(k) => {
                    self.served.remove(&k);
                }
                None => break,
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_generator_is_deterministic_and_stays_inside_the_open_interval() {
        let mut a = Rng::new(7);
        let mut b = Rng::new(7);
        for _ in 0..1000 {
            let (x, y) = (a.uniform(), b.uniform());
            assert_eq!(x, y);
            assert!(x > 0.0 && x < 1.0);
        }
        assert_ne!(Rng::new(1).next_u64(), Rng::new(2).next_u64());
    }

    #[test]
    fn beta_samples_have_the_right_mean() {
        let mut rng = Rng::new(42);
        for (a, b) in [(1.0, 1.0), (8.0, 2.0), (2.0, 8.0), (0.5, 0.5)] {
            let n = 4000;
            let mean: f64 = (0..n).map(|_| rng.beta(a, b)).sum::<f64>() / n as f64;
            let want = a / (a + b);
            assert!(
                (mean - want).abs() < 0.03,
                "Beta({a},{b}): mean {mean}, want {want}"
            );
        }
    }

    #[test]
    fn normal_samples_are_centred() {
        let mut rng = Rng::new(9);
        let n = 5000;
        let xs: Vec<f64> = (0..n).map(|_| rng.normal()).collect();
        let mean = xs.iter().sum::<f64>() / n as f64;
        let var = xs.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n as f64;
        assert!(mean.abs() < 0.05, "mean {mean}");
        assert!((var - 1.0).abs() < 0.08, "variance {var}");
    }

    #[test]
    fn a_source_that_works_is_chosen_more_often() {
        let mut bandit = Bandit::default();
        for _ in 0..20 {
            bandit.reward("home", "similar", true);
            bandit.reward("home", "chart", false);
        }
        let mut rng = Rng::new(3);
        let mut similar_wins = 0;
        for _ in 0..500 {
            let s = bandit.sample("home", Source::Similar, &mut rng);
            let c = bandit.sample("home", Source::Chart, &mut rng);
            if s > c {
                similar_wins += 1;
            }
        }
        assert!(similar_wins > 450, "similar won only {similar_wins} of 500");
        assert!(bandit.mean("home", Source::Similar) > 0.8);
        assert!(bandit.mean("home", Source::Chart) < 0.2);
    }

    #[test]
    fn a_source_with_no_evidence_still_gets_tried() {
        let mut bandit = Bandit::default();
        for _ in 0..10 {
            bandit.reward("home", "similar", true);
        }
        let mut rng = Rng::new(5);
        let tries = (0..500)
            .filter(|_| {
                bandit.sample("home", Source::TagNeighbour, &mut rng)
                    > bandit.sample("home", Source::Similar, &mut rng)
            })
            .count();
        assert!(tries > 20, "the unknown source never won ({tries})");
    }

    #[test]
    fn beliefs_are_per_shelf() {
        let mut bandit = Bandit::default();
        bandit.reward("daily", "similar", false);
        assert!(bandit.mean("daily", Source::Similar) < 0.5);
        assert!((bandit.mean("weekly", Source::Similar) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn evidence_is_bounded_so_a_change_of_taste_is_noticed() {
        let mut bandit = Bandit::default();
        for _ in 0..500 {
            bandit.reward("s", "similar", true);
        }
        let a = bandit.arm("s", Source::Similar);
        assert!(a.alpha + a.beta <= MAX_PSEUDO_COUNT + 1.0, "{a:?}");
        for _ in 0..40 {
            bandit.reward("s", "similar", false);
        }
        assert!(
            bandit.mean("s", Source::Similar) < 0.7,
            "slow to react: {}",
            bandit.mean("s", Source::Similar)
        );
    }

    #[test]
    fn a_served_song_rewards_its_arm_once() {
        let mut bandit = Bandit::default();
        bandit.note_served("t1", "home", Source::Similar, 1_000);
        assert!(bandit.settle("t1", true));
        assert!(bandit.mean("home", Source::Similar) > 0.5);
        assert!(!bandit.settle("t1", true), "a song is judged once");
        assert!(!bandit.settle("never-served", false));
    }

    #[test]
    fn the_served_list_is_bounded_and_forgets_old_entries() {
        let mut bandit = Bandit::default();
        for i in 0..(MAX_SERVED + 50) {
            bandit.note_served(&format!("t{i}"), "home", Source::Chart, 1_000 + i as u64);
        }
        assert_eq!(bandit.served.len(), MAX_SERVED);
        assert!(!bandit.served.contains_key("t0"), "the oldest goes first");
        bandit.note_served(
            "late",
            "home",
            Source::Chart,
            1_000 + SERVED_TTL_SECS + 10_000,
        );
        assert_eq!(
            bandit.served.len(),
            1,
            "everything older than the TTL is dropped"
        );
    }

    #[test]
    fn the_seed_is_stable_within_a_day_and_changes_with_shelf_day_and_refresh() {
        let t = 1_800_000_000;
        // 1_800_000_000 is 08:00 UTC; 50 minutes later is the same day.
        assert_eq!(shelf_seed("daily", t, 0), shelf_seed("daily", t + 3_000, 0));
        assert_ne!(shelf_seed("daily", t, 0), shelf_seed("weekly", t, 0));
        assert_ne!(
            shelf_seed("daily", t, 0),
            shelf_seed("daily", t + 86_400, 0)
        );
        assert_ne!(shelf_seed("daily", t, 0), shelf_seed("daily", t, 1));
    }
}
