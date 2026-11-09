//! Part 5, rank: the tiny online logistic model, and the file it lives in.
//!
//! The model is the transparent score of `features.rs` with weights that move a little with every
//! finished song, skip and like. It predicts "will this be finished?" and its logit is the rank
//! score. It is small on purpose: 11 weights and a bias, bounded to +-4, pulled back towards the
//! prior by an L2 term, so a few odd days cannot wreck it. `reset` returns it to the prior.
//!
//! Training happens in two ways, both through the same `step`:
//! - **replay**: on first use (and in `--eval`) the last [`REPLAY_DAYS`] days are replayed day by
//!   day. For each day the profile is built from what came BEFORE it, the features of every play
//!   and skip of that day are taken against that profile, and the model learns finished-vs-skipped.
//!   Nothing from the future leaks into the features.
//! - **catch-up**: afterwards, every new play or skip the daemon sees is one more step.

use super::bandit::Bandit;
use super::features::{dot, extract, Features, FeatureCtx, NF, PRIOR_WEIGHTS};
use super::{Candidate, Source};
use crate::cache::PlayLogEntry;
use crate::eval::{label_play, Label};
use crate::taste::{artist_key, bucket_of, TagTable, TasteProfile};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

pub const REPLAY_DAYS: u64 = 21;
/// A day is only replayed when the profile before it has seen at least this many plays.
pub const REPLAY_MIN_PROFILE_PLAYS: usize = 10;
pub const LEARN_RATE: f64 = 0.05;
/// Pull towards [`PRIOR_WEIGHTS`] per step.
pub const L2: f64 = 0.02;
pub const WEIGHT_LIMIT: f64 = 4.0;
const DAY: u64 = 86_400;

pub fn sigmoid(x: f64) -> f64 {
    1.0 / (1.0 + (-x.clamp(-30.0, 30.0)).exp())
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OnlineModel {
    pub weights: Vec<f64>,
    pub bias: f64,
    /// Steps taken since the last reset.
    pub updates: u64,
}

impl Default for OnlineModel {
    fn default() -> Self {
        Self::prior()
    }
}

impl OnlineModel {
    /// The transparent starting point.
    pub fn prior() -> Self {
        OnlineModel { weights: PRIOR_WEIGHTS.to_vec(), bias: 0.0, updates: 0 }
    }

    pub fn reset(&mut self) {
        *self = Self::prior();
    }

    /// A model from an older build (another number of features) or with a broken number is not
    /// used: the caller falls back to the prior.
    pub fn is_valid(&self) -> bool {
        self.weights.len() == NF && self.weights.iter().all(|w| w.is_finite()) && self.bias.is_finite()
    }

    /// The rank score.
    pub fn logit(&self, f: &Features) -> f64 {
        dot(&self.weights, f) + self.bias
    }

    /// Chance the song is finished.
    pub fn probability(&self, f: &Features) -> f64 {
        sigmoid(self.logit(f))
    }

    /// One stochastic-gradient step. `y` is 1 for finished or liked, 0 for skipped;
    /// `sample_weight` says how much the example counts.
    pub fn step(&mut self, f: &Features, y: f64, sample_weight: f64) {
        let g = (self.probability(f) - y) * sample_weight;
        for (i, w) in self.weights.iter_mut().enumerate() {
            let x = f.get(i).copied().unwrap_or(0.0);
            let prior = PRIOR_WEIGHTS.get(i).copied().unwrap_or(0.0);
            *w -= LEARN_RATE * (g * x + L2 * (*w - prior));
            *w = w.clamp(-WEIGHT_LIMIT, WEIGHT_LIMIT);
        }
        self.bias = (self.bias - LEARN_RATE * g).clamp(-WEIGHT_LIMIT, WEIGHT_LIMIT);
        self.updates += 1;
    }

    /// Learn from one behaviour label.
    pub fn observe(&mut self, f: &Features, label: Label) {
        let (y, w) = label_target(label);
        self.step(f, y, w);
    }

    /// Replay the last [`REPLAY_DAYS`] days before `now` (see the module comment). Returns the
    /// number of examples used.
    pub fn train_replay(
        &mut self,
        plays: &[PlayLogEntry],
        liked: &HashSet<String>,
        now: u64,
        tags: &TagTable,
        cfg: &ReplayCfg,
    ) -> usize {
        let samples = replay_samples(plays, liked, now, tags, cfg);
        for _ in 0..cfg.epochs.max(1) {
            for s in &samples {
                self.step(&s.features, s.y, s.weight);
            }
        }
        samples.len()
    }
}

/// Target and weight of an example: a like counts more than a finish, a late leave less than a skip.
pub fn label_target(label: Label) -> (f64, f64) {
    match label {
        Label::Strong => (1.0, 1.5),
        Label::Positive => (1.0, 1.0),
        Label::WeakSkip => (0.0, 0.35),
        Label::Skipped => (0.0, 1.0),
    }
}

#[derive(Debug, Clone)]
pub struct ReplayCfg {
    pub tz_offset_secs: i64,
    /// Use the time of day of each play as a feature. Off in `--eval`, where the engine is asked
    /// at midnight and the time of day would mislead.
    pub use_time: bool,
    pub epochs: usize,
}

impl ReplayCfg {
    pub fn eval() -> Self {
        ReplayCfg { tz_offset_secs: 0, use_time: false, epochs: 1 }
    }

    pub fn live(tz_offset_secs: i64) -> Self {
        ReplayCfg { tz_offset_secs, use_time: true, epochs: 1 }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sample {
    pub features: Features,
    pub y: f64,
    pub weight: f64,
}

/// A play as a candidate (its artist's tags attached, when known).
pub fn candidate_of_play(e: &PlayLogEntry, tags: &TagTable) -> Candidate {
    let mut c = Candidate::from_play(e, Source::History);
    if let Some(t) = tags.get(&artist_key(&e.artist)) {
        c.tags = t.clone();
    }
    c
}

/// The training examples of a replay, oldest day first. `plays` holds plays and skips together.
pub fn replay_samples(
    plays: &[PlayLogEntry],
    liked: &HashSet<String>,
    now: u64,
    tags: &TagTable,
    cfg: &ReplayCfg,
) -> Vec<Sample> {
    let mut chron: Vec<PlayLogEntry> = plays.iter().filter(|p| p.started_at < now).cloned().collect();
    chron.sort_by_key(|p| (p.started_at, p.id));
    let from = now.saturating_sub(REPLAY_DAYS * DAY);
    let days: BTreeSet<u64> = chron
        .iter()
        .filter(|p| p.started_at >= from)
        .map(|p| p.started_at - p.started_at % DAY)
        .collect();
    let mut out = Vec::new();
    for d in days {
        let split = chron.partition_point(|p| p.started_at < d);
        let (past, rest) = chron.split_at(split);
        if past.len() < REPLAY_MIN_PROFILE_PLAYS {
            continue;
        }
        let profile = TasteProfile::build(past, liked, d, tags, cfg.tz_offset_secs);
        for e in rest.iter().take_while(|p| p.started_at < d + DAY) {
            let bucket = if cfg.use_time { Some(bucket_of(e.started_at, cfg.tz_offset_secs)) } else { None };
            let f = extract(&candidate_of_play(e, tags), &profile, &FeatureCtx { now: d, bucket });
            let (y, weight) = label_target(label_play(e, liked));
            out.push(Sample { features: f, y, weight });
        }
    }
    out
}

// ------------------------------------------------------------------ the state file

pub const STATE_VERSION: u32 = 1;

/// Everything Part 5 remembers between runs: the model, the exploration beliefs, and how far into
/// the play and skip logs it has already learned.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RecoState {
    pub version: u32,
    pub model: OnlineModel,
    pub bandit: Bandit,
    /// Highest `play_log` id and `skip_log` id already learned from.
    pub last_play_id: i64,
    pub last_skip_id: i64,
    /// The first replay of the history has been done (or was skipped by a reset).
    pub bootstrapped: bool,
}

impl Default for RecoState {
    fn default() -> Self {
        RecoState {
            version: STATE_VERSION,
            model: OnlineModel::prior(),
            bandit: Bandit::default(),
            last_play_id: 0,
            last_skip_id: 0,
            bootstrapped: false,
        }
    }
}

pub fn default_path() -> PathBuf {
    halcyon_music_core::paths::state_dir().join("reco-state.json")
}

impl RecoState {
    /// The saved state. A missing file is the default; one that cannot be read, has another
    /// version, or holds a model of the wrong size is moved aside (`.corrupt`) and replaced by the
    /// default. The flag says a recovery happened.
    pub fn load_or_default(path: &Path) -> (Self, bool) {
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(_) => return (RecoState::default(), false),
        };
        match serde_json::from_slice::<RecoState>(&bytes) {
            Ok(s) if s.version == STATE_VERSION && s.model.is_valid() => (s, false),
            _ => {
                let _ = std::fs::rename(path, path.with_extension("json.corrupt"));
                (RecoState::default(), true)
            }
        }
    }

    /// Atomic: write a temp file, then rename.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_vec(self).map_err(|e| e.to_string())?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, &json).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, path).map_err(|e| e.to_string())
    }

    /// The reset button: weights back to the prior and exploration beliefs forgotten. Learning
    /// carries on from the next new play; the history before now is NOT replayed again.
    pub fn reset(&mut self, last_play_id: i64, last_skip_id: i64) {
        self.model.reset();
        self.bandit = Bandit::default();
        self.last_play_id = last_play_id;
        self.last_skip_id = last_skip_id;
        self.bootstrapped = true;
    }
}

/// What one pass of learning did.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CatchUp {
    /// Examples used (replay examples on the first pass, new plays and skips afterwards).
    pub examples: usize,
    /// Exploration songs judged this pass.
    pub explored: usize,
    pub bootstrapped_now: bool,
}

/// Bring the state up to date with the logs. `plays` is the play log, `skips` the skip log (their
/// ids are separate counters). Pure: no clock (`now` is given), no file, no network.
///
/// - First pass: replay the history, remember how far the logs go, nothing else.
/// - Later passes: every entry above the watermarks is judged against the profile built from the
///   entries at or below them (so a new play never scores itself), then trained on, and
///   exploration songs update their arm.
pub fn catch_up(
    state: &mut RecoState,
    plays: &[PlayLogEntry],
    skips: &[PlayLogEntry],
    liked: &HashSet<String>,
    tags: &TagTable,
    now: u64,
    tz_offset_secs: i64,
) -> CatchUp {
    let max_play = plays.iter().map(|p| p.id).max().unwrap_or(0).max(state.last_play_id);
    let max_skip = skips.iter().map(|p| p.id).max().unwrap_or(0).max(state.last_skip_id);
    let mut report = CatchUp::default();

    if !state.bootstrapped {
        let mut all: Vec<PlayLogEntry> = plays.to_vec();
        all.extend(skips.iter().cloned());
        report.examples = state.model.train_replay(&all, liked, now, tags, &ReplayCfg::live(tz_offset_secs));
        state.bootstrapped = true;
        state.last_play_id = max_play;
        state.last_skip_id = max_skip;
        report.bootstrapped_now = true;
        return report;
    }

    let mut fresh: Vec<PlayLogEntry> = plays.iter().filter(|p| p.id > state.last_play_id).cloned().collect();
    fresh.extend(skips.iter().filter(|p| p.id > state.last_skip_id).cloned());
    if fresh.is_empty() {
        return report;
    }
    fresh.sort_by_key(|p| (p.started_at, p.id));

    let old: Vec<PlayLogEntry> = plays
        .iter()
        .filter(|p| p.id <= state.last_play_id)
        .chain(skips.iter().filter(|p| p.id <= state.last_skip_id))
        .cloned()
        .collect();
    let profile = TasteProfile::build(&old, liked, now, tags, tz_offset_secs);
    for e in &fresh {
        let label = label_play(e, liked);
        let f = extract(
            &candidate_of_play(e, tags),
            &profile,
            &FeatureCtx { now, bucket: Some(bucket_of(e.started_at, tz_offset_secs)) },
        );
        state.model.observe(&f, label);
        report.examples += 1;
        if state.bandit.settle(&e.track_id, !label.is_skip()) {
            report.explored += 1;
        }
    }
    state.last_play_id = max_play;
    state.last_skip_id = max_skip;
    report
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eval::{fixture, Listener, FIXTURE_NOW};

    const NOW: u64 = 1_800_000_000;

    fn play(id: i64, track: &str, artist: &str, days_ago: f64, ms: u64, done: bool) -> PlayLogEntry {
        PlayLogEntry {
            id,
            track_id: track.into(),
            title: "T".into(),
            artist: artist.into(),
            album: "A".into(),
            started_at: NOW - (days_ago * DAY as f64) as u64,
            ms_played: ms,
            completed: done,
        }
    }

    fn f_of(vals: &[(usize, f64)]) -> Features {
        let mut f = [0.0; NF];
        for (i, v) in vals {
            f[*i] = *v;
        }
        f
    }

    #[test]
    fn the_prior_model_is_valid_and_its_score_is_the_dot_product() {
        let m = OnlineModel::prior();
        assert!(m.is_valid());
        let f = f_of(&[(1, 1.0), (8, 0.5)]);
        assert!((m.logit(&f) - (PRIOR_WEIGHTS[1] + 0.5 * PRIOR_WEIGHTS[8])).abs() < 1e-12);
        let wrong = OnlineModel { weights: vec![0.0; NF - 1], bias: 0.0, updates: 0 };
        assert!(!wrong.is_valid());
        let nan = OnlineModel { weights: vec![f64::NAN; NF], bias: 0.0, updates: 0 };
        assert!(!nan.is_valid());
    }

    #[test]
    fn a_skip_pushes_the_feature_down_and_a_finish_pushes_it_up() {
        let mut m = OnlineModel::prior();
        let f = f_of(&[(0, 1.0)]);
        let before = m.logit(&f);
        for _ in 0..30 {
            m.observe(&f, Label::Skipped);
        }
        assert!(m.logit(&f) < before - 0.2, "after skips {} vs {}", m.logit(&f), before);
        let mut m2 = OnlineModel::prior();
        for _ in 0..30 {
            m2.observe(&f, Label::Positive);
        }
        assert!(m2.logit(&f) > before + 0.05);
        assert_eq!(m.updates, 30);
    }

    #[test]
    fn weights_stay_bounded_and_near_the_prior() {
        let mut m = OnlineModel::prior();
        let f = f_of(&[(2, 1.0), (3, 1.0), (7, 1.0)]);
        for _ in 0..5_000 {
            m.observe(&f, Label::Skipped);
        }
        assert!(m.weights.iter().all(|w| w.abs() <= WEIGHT_LIMIT + 1e-9));
        assert!(m.bias.abs() <= WEIGHT_LIMIT + 1e-9);
        // A weight whose feature never appears only drifts back to the prior.
        assert!((m.weights[1] - PRIOR_WEIGHTS[1]).abs() < 1e-6);
        assert!(m.is_valid());
    }

    #[test]
    fn reset_returns_to_the_prior() {
        let mut m = OnlineModel::prior();
        m.observe(&f_of(&[(0, 1.0)]), Label::Skipped);
        assert_ne!(m, OnlineModel::prior());
        m.reset();
        assert_eq!(m, OnlineModel::prior());
    }

    #[test]
    fn replay_uses_only_the_past_of_each_day() {
        // Ash is loved every day for 30 days; on the last day only Dust is played (skipped).
        let mut plays = Vec::new();
        let mut id = 0;
        for d in 2..=30 {
            for n in 0..3 {
                id += 1;
                plays.push(play(id, "ash-1", "Ash", d as f64 - n as f64 * 0.01, 200_000, true));
            }
        }
        id += 1;
        plays.push(play(id, "dust-1", "Dust", 0.5, 3_000, false));
        let s = replay_samples(&plays, &HashSet::new(), NOW, &TagTable::default(), &ReplayCfg::eval());
        assert!(!s.is_empty());
        // The Dust skip is the last sample; Dust was unknown before that day, so novelty is 1 and
        // the affinity features are 0: the replay did not look at the skip itself.
        let last = s.last().expect("a sample");
        assert_eq!(last.y, 0.0);
        assert_eq!(last.features[4], 1.0, "novelty");
        assert_eq!(last.features[0], 0.0);
        assert_eq!(last.features[1], 0.0);
    }

    #[test]
    fn replay_ignores_days_without_enough_history_and_the_far_past() {
        let few = vec![play(1, "a", "Ash", 1.0, 200_000, true), play(2, "b", "Ash", 0.9, 200_000, true)];
        assert!(replay_samples(&few, &HashSet::new(), NOW, &TagTable::default(), &ReplayCfg::eval()).is_empty());
        let mut old = Vec::new();
        for i in 0..40 {
            old.push(play(i + 1, "a", "Ash", 100.0 + i as f64 * 0.001, 200_000, true));
        }
        assert!(replay_samples(&old, &HashSet::new(), NOW, &TagTable::default(), &ReplayCfg::eval()).is_empty());
    }

    #[test]
    fn replay_training_teaches_a_listener_who_changed_taste() {
        let (plays, liked) = fixture(Listener::Shift);
        let mut m = OnlineModel::prior();
        let n = m.train_replay(&plays, &liked, FIXTURE_NOW, &TagTable::default(), &ReplayCfg::eval());
        assert!(n > 100, "{n} examples");
        assert_ne!(m, OnlineModel::prior());
        assert!(m.is_valid());
        // Being skipped lately must still count against an artist.
        assert!(m.weights[8] < 0.0, "skip-rate weight {}", m.weights[8]);
    }

    #[test]
    fn state_round_trips_and_recovers_from_a_broken_file() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("reco-state.json");
        let (fresh, recovered) = RecoState::load_or_default(&path);
        assert!(!recovered);
        assert_eq!(fresh, RecoState::default());
        let mut s = RecoState::default();
        s.model.observe(&f_of(&[(0, 1.0)]), Label::Skipped);
        s.bandit.reward("home", "similar", true);
        s.last_play_id = 7;
        s.bootstrapped = true;
        s.save(&path).expect("save");
        assert!(!path.with_extension("json.tmp").exists());
        let (back, recovered) = RecoState::load_or_default(&path);
        assert!(!recovered);
        assert_eq!(back, s);

        std::fs::write(&path, b"{ not json").expect("write");
        let (def, recovered) = RecoState::load_or_default(&path);
        assert!(recovered);
        assert_eq!(def, RecoState::default());
        assert!(path.with_extension("json.corrupt").exists());
        assert!(!path.exists());
    }

    #[test]
    fn a_state_with_the_wrong_number_of_weights_is_replaced() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("reco-state.json");
        let mut s = RecoState::default();
        s.model.weights.pop();
        std::fs::write(&path, serde_json::to_vec(&s).expect("json")).expect("write");
        let (def, recovered) = RecoState::load_or_default(&path);
        assert!(recovered);
        assert!(def.model.is_valid());
    }

    #[test]
    fn reset_keeps_learning_going_without_replaying_the_past() {
        let mut s = RecoState::default();
        s.model.observe(&f_of(&[(0, 1.0)]), Label::Skipped);
        s.bandit.reward("home", "chart", true);
        s.reset(40, 12);
        assert_eq!(s.model, OnlineModel::prior());
        assert_eq!(s.bandit, Bandit::default());
        assert!(s.bootstrapped && s.last_play_id == 40 && s.last_skip_id == 12);
    }

    fn history() -> (Vec<PlayLogEntry>, Vec<PlayLogEntry>) {
        let mut plays = Vec::new();
        let mut skips = Vec::new();
        for d in 2..=25 {
            for n in 0..4 {
                plays.push(play(d * 10 + n, &format!("ash-{n}"), "Ash", d as f64 - n as f64 * 0.01, 200_000, true));
            }
            skips.push(play(d * 10, &format!("dust-{d}"), "Dust", d as f64 - 0.3, 3_000, false));
        }
        (plays, skips)
    }

    #[test]
    fn the_first_pass_replays_and_marks_the_logs_as_learned() {
        let (plays, skips) = history();
        let mut state = RecoState::default();
        let r = catch_up(&mut state, &plays, &skips, &HashSet::new(), &TagTable::default(), NOW, 0);
        assert!(r.bootstrapped_now && r.examples > 20);
        assert!(state.bootstrapped);
        assert_eq!(state.last_play_id, plays.iter().map(|p| p.id).max().unwrap_or(0));
        assert_eq!(state.last_skip_id, skips.iter().map(|p| p.id).max().unwrap_or(0));
        // Nothing new: nothing happens.
        let before = state.clone();
        let again = catch_up(&mut state, &plays, &skips, &HashSet::new(), &TagTable::default(), NOW, 0);
        assert_eq!(again, CatchUp::default());
        assert_eq!(state, before);
    }

    #[test]
    fn later_passes_learn_only_what_is_new_and_settle_exploration_songs() {
        let (mut plays, mut skips) = history();
        let mut state = RecoState::default();
        catch_up(&mut state, &plays, &skips, &HashSet::new(), &TagTable::default(), NOW, 0);
        let updates = state.model.updates;
        state.bandit.note_served("new-song", "home", Source::Similar, NOW - 100);
        state.bandit.note_served("other-song", "home", Source::Chart, NOW - 100);
        plays.push(play(9_000, "new-song", "Newcomer", 0.01, 200_000, true));
        skips.push(play(9_001, "other-song", "Other", 0.005, 2_000, false));
        let r = catch_up(&mut state, &plays, &skips, &HashSet::new(), &TagTable::default(), NOW, 0);
        assert_eq!(r.examples, 2);
        assert_eq!(r.explored, 2);
        assert_eq!(state.model.updates, updates + 2);
        assert!(state.bandit.mean("home", Source::Similar) > 0.5);
        assert!(state.bandit.mean("home", Source::Chart) < 0.5);
        assert_eq!(state.last_play_id, 9_000);
        assert_eq!(state.last_skip_id, 9_001);
        assert!(state.bandit.served.is_empty());
    }
}
