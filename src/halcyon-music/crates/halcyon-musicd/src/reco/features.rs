//! Part 5, rank: what the ranker looks at, and the transparent score.
//!
//! Eleven numbers per candidate, each roughly in -1..=1. The score is their dot product with a
//! weight vector. The starting weights ([`PRIOR_WEIGHTS`]) are written down here so anyone can
//! read why a song ranks where it does; `model.rs` nudges them from your skips and likes and keeps
//! them close to this prior.

use super::Candidate;
use crate::taste::{AffinityCtx, TasteProfile};

pub const NF: usize = 11;

/// Names, in the order of [`Features`].
pub const FEATURE_NAMES: [&str; NF] = [
    "slow affinity",
    "fast affinity",
    "cluster fit",
    "time of day",
    "novelty",
    "release recency",
    "source trust",
    "popularity",
    "recent skip rate",
    "track history",
    "comeback",
];

/// The transparent starting weights.
///
/// - the fast scale leads the slow one (what you play this week beats what you played in spring);
/// - a recent skip rate and a skipped track pull hard down;
/// - cluster fit, release recency and source trust only matter for songs you have not played;
/// - novelty is 0 on purpose: surprise comes from the exploration share in the reranker, not from
///   ranking unknown artists higher.
pub const PRIOR_WEIGHTS: [f64; NF] = [
    0.10,  // slow affinity
    0.90,  // fast affinity
    0.30,  // cluster fit
    0.10,  // time of day
    0.00,  // novelty
    0.30,  // release recency
    0.25,  // source trust
    0.10,  // popularity
    -0.60, // recent skip rate
    0.50,  // track history
    0.12,  // comeback
];

/// Where "recent skip rate" sits in [`Features`]. Its weight may never turn positive (see `model.rs`).
pub const SKIP_RATE: usize = 8;

pub type Features = [f64; NF];

/// When the list is for.
#[derive(Debug, Clone, Copy)]
pub struct FeatureCtx {
    pub now: u64,
    /// The listener's `taste::bucket_of` now, or `None` to ignore the time of day.
    pub bucket: Option<usize>,
}

const DAY: f64 = 86_400.0;
/// A release loses half its freshness every 30 days.
const RECENCY_HALF_LIFE_DAYS: f64 = 30.0;

/// 1 for a release today, 0.5 after 30 days, 0 when the date is unknown.
pub fn release_recency(released: Option<u64>, now: u64) -> f64 {
    match released {
        Some(t) => 0.5f64.powf(now.saturating_sub(t) as f64 / DAY / RECENCY_HALF_LIFE_DAYS),
        None => 0.0,
    }
}

/// The features of one candidate for this listener.
pub fn extract(c: &Candidate, profile: &TasteProfile, ctx: &FeatureCtx) -> Features {
    let actx = AffinityCtx { now: ctx.now, bucket: ctx.bucket };
    let v = profile.artist_view(&c.artist, &actx);
    let cluster = if !c.tags.is_empty() {
        profile.cluster_fit(&c.tags).map_or(0.0, |(_, sim)| sim)
    } else if v.in_cluster {
        0.5
    } else {
        0.0
    };
    let track = c.track_id.as_deref().map_or(0.0, |id| profile.track_view(id).0);
    [
        v.slow,
        v.fast,
        cluster,
        v.time_fit,
        if v.known { 0.0 } else { 1.0 },
        release_recency(c.released, ctx.now),
        c.best_trust(),
        c.popularity.unwrap_or(0.0).clamp(0.0, 1.0),
        v.skip_rate,
        track,
        if v.comeback { 1.0 } else { 0.0 },
    ]
}

/// Whether the listener has ever played this artist (the reranker's "unheard").
pub fn is_unheard(c: &Candidate, profile: &TasteProfile) -> bool {
    !profile.artist_view(&c.artist, &AffinityCtx { now: 0, bucket: None }).known
}

pub fn dot(weights: &[f64], f: &Features) -> f64 {
    weights.iter().zip(f.iter()).map(|(w, x)| w * x).sum()
}

/// One row of the explanation of a score.
#[derive(Debug, Clone, PartialEq)]
pub struct Contribution {
    pub name: &'static str,
    pub value: f64,
    pub weight: f64,
}

impl Contribution {
    /// What this feature added to the score.
    pub fn part(&self) -> f64 {
        self.value * self.weight
    }
}

pub fn contributions(weights: &[f64], f: &Features) -> Vec<Contribution> {
    FEATURE_NAMES
        .iter()
        .zip(f.iter())
        .enumerate()
        .map(|(i, (name, value))| Contribution { name, value: *value, weight: weights.get(i).copied().unwrap_or(0.0) })
        .collect()
}

/// The debug view: one line per feature (value, weight now, weight at the start, what it added)
/// and the total. Plain text, for `halcyon-musicd --reco-explain`.
pub fn explain_text(weights: &[f64], bias: f64, f: &Features) -> String {
    let mut s = String::new();
    s.push_str(&format!("{:<18} {:>7} {:>8} {:>8} {:>8}\n", "feature", "value", "weight", "prior", "adds"));
    let mut total = bias;
    for (i, c) in contributions(weights, f).iter().enumerate() {
        let prior = PRIOR_WEIGHTS.get(i).copied().unwrap_or(0.0);
        total += c.part();
        s.push_str(&format!("{:<18} {:>7.3} {:>8.3} {:>8.3} {:>+8.3}\n", c.name, c.value, c.weight, prior, c.part()));
    }
    s.push_str(&format!("{:<18} {:>7} {:>8} {:>8} {:>+8.3}\n", "bias", "", "", "", bias));
    s.push_str(&format!("{:<18} {:>7} {:>8} {:>8} {:>+8.3}\n", "score", "", "", "", total));
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::PlayLogEntry;
    use crate::reco::Source;
    use crate::taste::TagTable;
    use std::collections::HashSet;

    const NOW: u64 = 1_800_000_000;
    const D: u64 = 86_400;

    fn play(id: i64, track: &str, artist: &str, days_ago: f64, ms: u64, done: bool) -> PlayLogEntry {
        PlayLogEntry {
            id,
            track_id: track.into(),
            title: format!("title {track}"),
            artist: artist.into(),
            album: "A".into(),
            started_at: NOW - (days_ago * D as f64) as u64,
            ms_played: ms,
            completed: done,
        }
    }

    fn profile(plays: &[PlayLogEntry]) -> TasteProfile {
        TasteProfile::build(plays, &HashSet::new(), NOW, &TagTable::default(), 0)
    }

    fn ctx() -> FeatureCtx {
        FeatureCtx { now: NOW, bucket: None }
    }

    #[test]
    fn prior_weights_and_names_line_up() {
        assert_eq!(FEATURE_NAMES.len(), NF);
        assert_eq!(PRIOR_WEIGHTS.len(), NF);
        assert_eq!(FEATURE_NAMES.get(SKIP_RATE), Some(&"recent skip rate"));
        let skip = FEATURE_NAMES.iter().position(|n| *n == "recent skip rate");
        assert!(skip.and_then(|i| PRIOR_WEIGHTS.get(i)).is_some_and(|w| *w < 0.0), "a skip rate must count against");
    }

    #[test]
    fn an_unheard_artist_is_novel_and_has_no_affinity() {
        let p = profile(&[play(1, "a", "Ash", 1.0, 200_000, true)]);
        let c = Candidate::new("Nobody", "Song", Source::Similar);
        let f = extract(&c, &p, &ctx());
        assert_eq!(f[0], 0.0);
        assert_eq!(f[1], 0.0);
        assert_eq!(f[4], 1.0, "novelty");
        assert!((f[6] - 0.7).abs() < 1e-9, "source trust of Similar");
        assert!(is_unheard(&c, &p));
    }

    #[test]
    fn what_you_play_now_beats_what_you_skip() {
        let plays = vec![
            play(1, "a1", "Ash", 1.0, 200_000, true),
            play(2, "a2", "Ash", 1.5, 200_000, true),
            play(3, "d1", "Dust", 1.0, 3_000, false),
            play(4, "d2", "Dust", 1.2, 3_000, false),
            play(5, "d3", "Dust", 1.4, 3_000, false),
        ];
        let p = profile(&plays);
        let w = PRIOR_WEIGHTS;
        let mut ash = Candidate::new("Ash", "t", Source::History);
        ash.track_id = Some("a1".into());
        let mut dust = Candidate::new("Dust", "t", Source::History);
        dust.track_id = Some("d1".into());
        let sa = dot(&w, &extract(&ash, &p, &ctx()));
        let sd = dot(&w, &extract(&dust, &p, &ctx()));
        assert!(sa > sd + 0.5, "ash {sa} vs dust {sd}");
        assert!(extract(&dust, &p, &ctx())[8] > 0.5, "skip rate of an artist you keep skipping");
        assert!(extract(&dust, &p, &ctx())[9] < 0.0, "a track you only skipped");
    }

    #[test]
    fn a_skip_from_two_months_ago_has_faded() {
        // Dune was skipped 60 days ago, finished 3 times this week: the skip rate is tiny.
        let mut plays = vec![
            play(1, "x1", "Dune", 60.0, 3_000, false),
            play(2, "x2", "Dune", 61.0, 3_000, false),
        ];
        for (i, d) in [1.0, 2.0, 3.0].iter().enumerate() {
            plays.push(play(10 + i as i64, "x3", "Dune", *d, 200_000, true));
        }
        let p = profile(&plays);
        let f = extract(&Candidate::new("Dune", "t", Source::History), &p, &ctx());
        assert!(f[8] < 0.1, "recent skip rate {}", f[8]);
    }

    #[test]
    fn release_recency_halves_every_thirty_days() {
        assert!((release_recency(Some(NOW), NOW) - 1.0).abs() < 1e-9);
        assert!((release_recency(Some(NOW - 30 * D), NOW) - 0.5).abs() < 1e-9);
        assert!((release_recency(Some(NOW - 60 * D), NOW) - 0.25).abs() < 1e-9);
        assert_eq!(release_recency(None, NOW), 0.0);
        assert!((release_recency(Some(NOW + 5 * D), NOW) - 1.0).abs() < 1e-9, "a future date is not older than today");
    }

    #[test]
    fn popularity_is_clamped_and_unknown_is_zero() {
        let p = profile(&[]);
        let mut c = Candidate::new("A", "T", Source::Chart);
        c.popularity = Some(7.0);
        assert_eq!(extract(&c, &p, &ctx())[7], 1.0);
        c.popularity = None;
        assert_eq!(extract(&c, &p, &ctx())[7], 0.0);
    }

    #[test]
    fn tags_that_fit_a_cluster_raise_cluster_fit() {
        let mut tags = TagTable::default();
        let mut plays = Vec::new();
        for (i, a) in ["a1", "a2", "a3", "a4", "b1", "b2", "b3", "b4"].iter().enumerate() {
            let t: &[(&str, f64)] = if a.starts_with('a') { &[("lo-fi", 1.0), ("chillhop", 0.8)] } else { &[("metal", 1.0), ("thrash", 0.7)] };
            tags.insert(a, t);
            plays.push(play(i as i64 + 1, a, a, 1.0, 200_000, true));
        }
        let p = TasteProfile::build(&plays, &HashSet::new(), NOW, &tags, 0);
        assert!(!p.clusters.is_empty(), "clusters needed for this test");
        let mut near = Candidate::new("New", "T", Source::Similar);
        near.tags = vec![("lo-fi".into(), 1.0)];
        let mut far = Candidate::new("Other", "T", Source::Similar);
        far.tags = vec![("polka".into(), 1.0)];
        assert!(extract(&near, &p, &ctx())[2] > 0.5);
        assert_eq!(extract(&far, &p, &ctx())[2], 0.0);
    }

    #[test]
    fn explanation_adds_up_to_the_score() {
        let p = profile(&[play(1, "a", "Ash", 1.0, 200_000, true)]);
        let mut c = Candidate::new("Ash", "t", Source::History);
        c.track_id = Some("a".into());
        let f = extract(&c, &p, &ctx());
        let text = explain_text(&PRIOR_WEIGHTS, 0.25, &f);
        let total = dot(&PRIOR_WEIGHTS, &f) + 0.25;
        assert!(text.contains("fast affinity"));
        assert!(text.contains(&format!("{total:+.3}")), "{text}");
        let sum: f64 = contributions(&PRIOR_WEIGHTS, &f).iter().map(Contribution::part).sum();
        assert!((sum + 0.25 - total).abs() < 1e-12);
    }
}
