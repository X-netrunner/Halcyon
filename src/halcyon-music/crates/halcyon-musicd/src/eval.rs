//! `halcyon-musicd --eval` (Part 3): score a ranking engine against a listening history.
//!
//! No network and no Spotify: it replays the play log. For each test day D the engine is trained
//! on plays BEFORE D only, ranks the whole catalogue (every track seen anywhere in the log), and is
//! compared with what was really played and skipped on D.
//!
//! Honest limits, also printed in the report:
//! - The log has no track length, so "completed" is the log's own `completed` flag.
//! - Skips are logged since Part 4 (the `skip_log` table, merged into the history by `--eval`), but
//!   a history recorded before that has none: the skip AUC is `None` there until skips accumulate.
//!   The fixtures contain skips, so the harness itself is exercised.
//! - No genre/tag data is stored, so diversity and novelty are measured on artists.

use crate::cache::PlayLogEntry;
use halcyon_music_core::Track;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

/// List length the metrics are computed at.
pub const K: usize = 10;
/// A play dropped before this is a clear skip.
pub const SKIP_EARLY_MS: u64 = 30_000;
/// A track played this many times on the test day counts as repeated (positive).
pub const REPEAT_MIN: usize = 2;
/// Gains for NDCG: liked is stronger than merely played to the end.
pub const GAIN_POSITIVE: f64 = 1.0;
pub const GAIN_STRONG: f64 = 2.0;
/// A test day needs this many plays on the day and this many plays before it.
pub const MIN_DAY_PLAYS: usize = 5;
pub const MIN_TRAIN_PLAYS: usize = 30;
/// How many of the most recent days are replayed.
pub const TEST_DAYS: usize = 14;
/// "Repeat rate" looks this many days back from the test day.
pub const REPEAT_WINDOW_DAYS: u64 = 7;
const DAY: u64 = 86_400;

/// What a play (or a track on a day) means.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Label {
    /// Dropped before [`SKIP_EARLY_MS`].
    Skipped,
    /// Left after [`SKIP_EARLY_MS`] without finishing: weakly negative.
    WeakSkip,
    /// Played to the end, or repeated.
    Positive,
    /// Liked.
    Strong,
}

impl Label {
    pub fn gain(self) -> f64 {
        match self {
            Label::Strong => GAIN_STRONG,
            Label::Positive => GAIN_POSITIVE,
            Label::WeakSkip | Label::Skipped => 0.0,
        }
    }
    pub fn is_skip(self) -> bool {
        matches!(self, Label::Skipped | Label::WeakSkip)
    }
}

/// Label of a single play.
pub fn label_play(p: &PlayLogEntry, liked: &HashSet<String>) -> Label {
    if liked.contains(&p.track_id) && (p.completed || p.ms_played >= SKIP_EARLY_MS) {
        Label::Strong
    } else if p.completed {
        Label::Positive
    } else if p.ms_played < SKIP_EARLY_MS {
        Label::Skipped
    } else {
        Label::WeakSkip
    }
}

/// A candidate the engine ranks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Item {
    pub track_id: String,
    pub artist: String,
}

/// Everything an engine may look at: the past only.
pub struct TrainCtx<'a> {
    pub plays: &'a [PlayLogEntry],
    pub liked: &'a HashSet<String>,
    /// Start of the test day: "now" for the engine.
    pub now: u64,
}

/// A ranking engine under test. Higher score = recommended earlier. Must be deterministic.
pub trait Ranker {
    fn name(&self) -> &'static str;
    fn scores(&self, ctx: &TrainCtx<'_>, items: &[Item]) -> Vec<f64>;
}

/// The engine that exists today: `suggestions::learn_taste` (play-weighted songs, then artists).
pub struct CurrentEngine;

impl Ranker for CurrentEngine {
    fn name(&self) -> &'static str {
        "current (suggestions::learn_taste)"
    }
    fn scores(&self, ctx: &TrainCtx<'_>, items: &[Item]) -> Vec<f64> {
        // The engine wants `Track`s for the liked list; only id and artist matter to it.
        let mut artist_of: HashMap<&str, &str> = HashMap::new();
        for p in ctx.plays {
            artist_of.insert(p.track_id.as_str(), p.artist.as_str());
        }
        let liked: Vec<Track> = ctx
            .liked
            .iter()
            .map(|id| {
                let artist = artist_of.get(id.as_str()).copied().unwrap_or("");
                Track::simple(id.clone(), String::new(), artist.to_string(), String::new(), 0)
            })
            .collect();
        let taste = crate::suggestions::learn_taste(ctx.plays, &liked, ctx.now);
        let n_songs = taste.songs.len().max(1) as f64;
        let song_pos: HashMap<&str, usize> =
            taste.songs.iter().enumerate().map(|(i, s)| (s.as_str(), i)).collect();
        let n_art = taste.artists.len().max(1) as f64;
        let artist_pos: HashMap<String, usize> = taste
            .artists
            .iter()
            .enumerate()
            .map(|(i, a)| (crate::suggestions::normalize_string(a), i))
            .collect();
        items
            .iter()
            .map(|it| {
                if let Some(&i) = song_pos.get(it.track_id.as_str()) {
                    // Songs you listen to come first, best first.
                    2.0 + (1.0 - i as f64 / n_songs)
                } else if let Some(&i) = artist_pos.get(&crate::suggestions::normalize_string(&it.artist)) {
                    // Then songs by artists you listen to.
                    1.0 + (1.0 - i as f64 / n_art)
                } else {
                    0.0
                }
            })
            .collect()
    }
}

/// Sanity baseline: how often each track was completed. Beaten by anything with taste.
pub struct MostPlayed;

impl Ranker for MostPlayed {
    fn name(&self) -> &'static str {
        "most played (baseline)"
    }
    fn scores(&self, ctx: &TrainCtx<'_>, items: &[Item]) -> Vec<f64> {
        let mut n: HashMap<&str, f64> = HashMap::new();
        for p in ctx.plays.iter().filter(|p| p.completed) {
            *n.entry(p.track_id.as_str()).or_insert(0.0) += 1.0;
        }
        items.iter().map(|it| n.get(it.track_id.as_str()).copied().unwrap_or(0.0)).collect()
    }
}

/// Sanity baseline: a fixed pseudo-random order (seeded, so it is reproducible).
pub struct SeededRandom(pub u64);

impl Ranker for SeededRandom {
    fn name(&self) -> &'static str {
        "random (seeded, baseline)"
    }
    fn scores(&self, ctx: &TrainCtx<'_>, items: &[Item]) -> Vec<f64> {
        items
            .iter()
            .map(|it| {
                let mut h = self.0 ^ ctx.now;
                for b in it.track_id.bytes() {
                    h = h.wrapping_mul(0x100_0000_01b3).wrapping_add(u64::from(b));
                }
                // splitmix finaliser
                h = (h ^ (h >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
                h = (h ^ (h >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
                (h ^ (h >> 31)) as f64 / u64::MAX as f64
            })
            .collect()
    }
}

/// Metrics averaged over the replayed days. `None` = not computable (for example no skips).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Metrics {
    pub days: usize,
    pub recall_at_k: Option<f64>,
    pub ndcg_at_k: Option<f64>,
    pub skip_auc: Option<f64>,
    /// 1 - share of same-artist pairs in the top-k (1 = every track a different artist).
    pub diversity: Option<f64>,
    /// Share of top-k tracks whose artist was never played before the test day.
    pub novelty: Option<f64>,
    /// Distinct artists in all top-k lists / artists in the catalogue.
    pub coverage: Option<f64>,
    /// Share of top-k tracks already played in the last [`REPEAT_WINDOW_DAYS`] days.
    pub repeat_rate: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Report {
    pub engine: String,
    pub k: usize,
    pub metrics: Metrics,
}

/// Mean of the defined values, `None` when there are none.
fn mean(values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        None
    } else {
        Some(values.iter().sum::<f64>() / values.len() as f64)
    }
}

/// Probability a random non-skipped item outscores a random skipped one (ties count half).
pub fn auc(positives: &[f64], negatives: &[f64]) -> Option<f64> {
    if positives.is_empty() || negatives.is_empty() {
        return None;
    }
    let mut wins = 0.0;
    for p in positives {
        for n in negatives {
            wins += if p > n {
                1.0
            } else if (p - n).abs() < f64::EPSILON {
                0.5
            } else {
                0.0
            };
        }
    }
    Some(wins / (positives.len() * negatives.len()) as f64)
}

/// NDCG@k with graded gains. `ranked_gains` is in the engine's order; `ideal` are all gains of the day.
pub fn ndcg(ranked_gains: &[f64], ideal: &[f64], k: usize) -> Option<f64> {
    let dcg = |g: &[f64]| -> f64 {
        g.iter().take(k).enumerate().map(|(i, g)| g / ((i + 2) as f64).log2()).sum()
    };
    let mut best: Vec<f64> = ideal.to_vec();
    best.sort_by(|a, b| b.partial_cmp(a).unwrap_or(std::cmp::Ordering::Equal));
    let idcg = dcg(&best);
    if idcg <= 0.0 {
        None
    } else {
        Some(dcg(ranked_gains) / idcg)
    }
}

fn day_start(t: u64) -> u64 {
    t - t % DAY
}

/// Replay `plays` (any order) day by day and score `ranker`.
pub fn evaluate(ranker: &dyn Ranker, plays: &[PlayLogEntry], liked: &HashSet<String>) -> Report {
    let mut sorted: Vec<&PlayLogEntry> = plays.iter().collect();
    sorted.sort_by_key(|p| (p.started_at, p.id));
    let chronological: Vec<PlayLogEntry> = sorted.into_iter().cloned().collect();

    // Catalogue: every track seen anywhere, with its artist (first seen wins).
    let mut catalogue: BTreeMap<String, String> = BTreeMap::new();
    for p in &chronological {
        catalogue.entry(p.track_id.clone()).or_insert_with(|| p.artist.clone());
    }
    let items: Vec<Item> = catalogue
        .iter()
        .map(|(id, artist)| Item { track_id: id.clone(), artist: artist.clone() })
        .collect();
    let all_artists: BTreeSet<&str> = items.iter().map(|i| i.artist.as_str()).collect();

    // Candidate test days: the most recent days with enough data.
    let mut days: BTreeSet<u64> = chronological.iter().map(|p| day_start(p.started_at)).collect();
    days.retain(|d| {
        let on_day = chronological.iter().filter(|p| day_start(p.started_at) == *d).count();
        let before = chronological.iter().filter(|p| p.started_at < *d).count();
        on_day >= MIN_DAY_PLAYS && before >= MIN_TRAIN_PLAYS
    });
    let test_days: Vec<u64> = days.into_iter().rev().take(TEST_DAYS).collect();

    let (mut recalls, mut ndcgs, mut aucs, mut divs, mut novs, mut reps) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new(), Vec::new());
    let mut shown_artists: BTreeSet<String> = BTreeSet::new();

    for &d in &test_days {
        let split = chronological.partition_point(|p| p.started_at < d);
        let (train, rest) = chronological.split_at(split);
        let today: Vec<&PlayLogEntry> =
            rest.iter().take_while(|p| p.started_at < d + DAY).collect();

        // Best label per track on the day; repeats on the day are positive.
        let mut per_track: BTreeMap<&str, (Label, usize)> = BTreeMap::new();
        for p in &today {
            let l = label_play(p, liked);
            let e = per_track.entry(p.track_id.as_str()).or_insert((l, 0));
            e.0 = e.0.max(l);
            e.1 += 1;
        }
        for (label, n) in per_track.values_mut() {
            if *n >= REPEAT_MIN && *label < Label::Positive {
                *label = Label::Positive;
            }
        }

        let ctx = TrainCtx { plays: train, liked, now: d };
        let scores = ranker.scores(&ctx, &items);
        if scores.len() != items.len() {
            continue;
        }
        let mut order: Vec<usize> = (0..items.len()).collect();
        order.sort_by(|&a, &b| {
            let sa = scores.get(a).copied().unwrap_or(0.0);
            let sb = scores.get(b).copied().unwrap_or(0.0);
            sb.partial_cmp(&sa)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| items.get(a).map(|i| &i.track_id).cmp(&items.get(b).map(|i| &i.track_id)))
        });
        let top: Vec<&Item> = order.iter().take(K).filter_map(|&i| items.get(i)).collect();

        // Recall@k and NDCG@k over the day's positives.
        let relevant: HashSet<&str> = per_track
            .iter()
            .filter(|(_, (l, _))| l.gain() > 0.0)
            .map(|(id, _)| *id)
            .collect();
        if !relevant.is_empty() {
            let hit = top.iter().filter(|i| relevant.contains(i.track_id.as_str())).count();
            recalls.push(hit as f64 / relevant.len().min(K) as f64);
            let gains: Vec<f64> = top
                .iter()
                .map(|i| per_track.get(i.track_id.as_str()).map_or(0.0, |(l, _)| l.gain()))
                .collect();
            let ideal: Vec<f64> = per_track.values().map(|(l, _)| l.gain()).collect();
            if let Some(v) = ndcg(&gains, &ideal, K) {
                ndcgs.push(v);
            }
        }

        // Predicted-skip AUC over tracks played that day.
        let score_of: HashMap<&str, f64> = items
            .iter()
            .zip(scores.iter())
            .map(|(it, s)| (it.track_id.as_str(), *s))
            .collect();
        let (mut pos, mut neg) = (Vec::new(), Vec::new());
        for (id, (l, _)) in &per_track {
            if let Some(s) = score_of.get(id) {
                if l.is_skip() {
                    neg.push(*s);
                } else {
                    pos.push(*s);
                }
            }
        }
        if let Some(a) = auc(&pos, &neg) {
            aucs.push(a);
        }

        // List-shape metrics.
        if top.len() >= 2 {
            let mut same = 0usize;
            let mut pairs = 0usize;
            for (i, a) in top.iter().enumerate() {
                for b in top.iter().skip(i + 1) {
                    pairs += 1;
                    if crate::suggestions::normalize_string(&a.artist)
                        == crate::suggestions::normalize_string(&b.artist)
                    {
                        same += 1;
                    }
                }
            }
            divs.push(1.0 - same as f64 / pairs.max(1) as f64);
        }
        if !top.is_empty() {
            let heard: HashSet<String> =
                train.iter().map(|p| crate::suggestions::normalize_string(&p.artist)).collect();
            let unheard = top
                .iter()
                .filter(|i| !heard.contains(&crate::suggestions::normalize_string(&i.artist)))
                .count();
            novs.push(unheard as f64 / top.len() as f64);
            let recent: HashSet<&str> = train
                .iter()
                .filter(|p| p.started_at + REPEAT_WINDOW_DAYS * DAY >= d)
                .map(|p| p.track_id.as_str())
                .collect();
            let repeated = top.iter().filter(|i| recent.contains(i.track_id.as_str())).count();
            reps.push(repeated as f64 / top.len() as f64);
            for i in &top {
                shown_artists.insert(i.artist.clone());
            }
        }
    }

    let coverage = if test_days.is_empty() || all_artists.is_empty() {
        None
    } else {
        Some(shown_artists.len() as f64 / all_artists.len() as f64)
    };
    Report {
        engine: ranker.name().to_string(),
        k: K,
        metrics: Metrics {
            days: test_days.len(),
            recall_at_k: mean(&recalls),
            ndcg_at_k: mean(&ndcgs),
            skip_auc: mean(&aucs),
            diversity: mean(&divs),
            novelty: mean(&novs),
            coverage,
            repeat_rate: mean(&reps),
        },
    }
}

// ------------------------------------------------------------------ fixtures

/// Three deterministic synthetic listeners (no clock, no randomness beyond a fixed seed).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Listener {
    /// Few artists, heavy repeats, skips everything else.
    Narrow,
    /// Many artists, even spread, a few disliked.
    Broad,
    /// Loves A-C for 60 days, then switches to D-F.
    Shift,
}

impl Listener {
    pub const ALL: [Listener; 3] = [Listener::Narrow, Listener::Broad, Listener::Shift];
    pub fn name(self) -> &'static str {
        match self {
            Listener::Narrow => "narrow taste",
            Listener::Broad => "broad taste",
            Listener::Shift => "recent taste shift",
        }
    }
}

/// Fixed "now" of every fixture (a UTC midnight).
pub const FIXTURE_NOW: u64 = 1_800_000_000 - 1_800_000_000 % DAY;

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }
    fn below(&mut self, n: u64) -> u64 {
        if n == 0 { 0 } else { self.next() % n }
    }
}

/// The play log and liked set of a synthetic listener, 80 days ending at [`FIXTURE_NOW`].
pub fn fixture(kind: Listener) -> (Vec<PlayLogEntry>, HashSet<String>) {
    let mut rng = Lcg(match kind {
        Listener::Narrow => 11,
        Listener::Broad => 22,
        Listener::Shift => 33,
    });
    // (artist, tracks, liked: loved?) per phase.
    let artists = |names: &[&str]| -> Vec<String> { names.iter().map(|s| (*s).to_string()).collect() };
    let mut plays = Vec::new();
    let mut liked = HashSet::new();
    let mut id = 0i64;
    for day in 0..80u64 {
        let d0 = FIXTURE_NOW - (80 - day) * DAY;
        let (loved, hated): (Vec<String>, Vec<String>) = match kind {
            Listener::Narrow => (artists(&["Ash", "Birch", "Cedar"]), artists(&["Dust", "Ember", "Flint", "Gale"])),
            Listener::Broad => (
                artists(&["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8", "A9", "A10", "A11", "A12", "A13", "A14", "A15", "A16", "A17", "A18"]),
                artists(&["Z1", "Z2"]),
            ),
            Listener::Shift => {
                if day < 60 {
                    (artists(&["Ash", "Birch", "Cedar"]), artists(&["Dune", "Elm", "Fern"]))
                } else {
                    (artists(&["Dune", "Elm", "Fern"]), artists(&["Ash", "Birch", "Cedar"]))
                }
            }
        };
        for n in 0..12u64 {
            id += 1;
            let hate = rng.below(100) < 18;
            let pool = if hate { &hated } else { &loved };
            let artist = pool.get(rng.below(pool.len() as u64) as usize).cloned().unwrap_or_default();
            // Few tracks per artist, so tracks repeat over the weeks.
            let track_id = format!("{artist}-{}", rng.below(6));
            let (ms, done) = if hate { (4_000 + rng.below(20_000), false) } else { (200_000, true) };
            if !hate && rng.below(100) < 15 {
                liked.insert(track_id.clone());
            }
            plays.push(PlayLogEntry {
                id,
                track_id,
                title: format!("Song {id}"),
                artist,
                album: "Album".to_string(),
                started_at: d0 + 8 * 3600 + n * 600,
                ms_played: ms,
                completed: done,
            });
        }
    }
    (plays, liked)
}

/// Evaluate the engines on one set of plays.
pub fn run_engines(plays: &[PlayLogEntry], liked: &HashSet<String>) -> Vec<Report> {
    let engines: [&dyn Ranker; 4] =
        [&CurrentEngine, &MostPlayed, &SeededRandom(7), &crate::taste::TasteV2];
    engines.iter().map(|e| evaluate(*e, plays, liked)).collect()
}

/// Reports for the three fixtures: (listener name, reports).
pub fn run_fixtures() -> Vec<(String, Vec<Report>)> {
    Listener::ALL
        .iter()
        .map(|l| {
            let (plays, liked) = fixture(*l);
            (l.name().to_string(), run_engines(&plays, &liked))
        })
        .collect()
}

/// One row of the markdown table.
fn fmt(v: Option<f64>) -> String {
    v.map_or("n/a".to_string(), |x| format!("{x:.3}"))
}

pub fn markdown_section(title: &str, reports: &[Report]) -> String {
    let mut s = format!(
        "### {title}\n\n| engine | days | Recall@{K} | NDCG@{K} | skip AUC | diversity | novelty | coverage | repeat rate |\n|---|---|---|---|---|---|---|---|---|\n"
    );
    for r in reports {
        let m = &r.metrics;
        s.push_str(&format!(
            "| {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
            r.engine, m.days, fmt(m.recall_at_k), fmt(m.ndcg_at_k), fmt(m.skip_auc),
            fmt(m.diversity), fmt(m.novelty), fmt(m.coverage), fmt(m.repeat_rate)
        ));
    }
    s.push('\n');
    s
}

pub const LIMITS: &str = "Limits: the play log has no track length (\"completed\" is its own flag); \
skips are logged only since Part 4 (direct engine), so an older real history has none and skip AUC is n/a there; \
tags are not part of the replay, so diversity and novelty are per artist; candidates are the tracks seen in the log, \
so novelty only counts artists first heard after the test day.\n";

pub fn fixtures_markdown(results: &[(String, Vec<Report>)]) -> String {
    let mut s = format!(
        "# Eval baseline (fixtures)\n\nGenerated by `halcyon-musicd --eval`. Deterministic: three synthetic listeners, {TEST_DAYS} test days, k = {K}. Later parts must not regress the `current` rows.\n\n"
    );
    for (name, reports) in results {
        s.push_str(&markdown_section(name, reports));
    }
    s.push_str(LIMITS);
    s
}

/// Dispatch for the CLI. `real` is the user's own history (never written next to the repo docs).
pub struct EvalOutput {
    pub fixtures_md: String,
    pub fixtures_json: String,
    pub real_md: Option<String>,
    pub real_json: Option<String>,
}

pub fn build_output(real: Option<(&[PlayLogEntry], &HashSet<String>)>) -> Result<EvalOutput, String> {
    let fixtures = run_fixtures();
    let fixtures_json = serde_json::to_string_pretty(&fixtures).map_err(|e| e.to_string())?;
    let (real_md, real_json) = match real {
        Some((plays, liked)) => {
            let reports = run_engines(plays, liked);
            let json = serde_json::to_string_pretty(&reports).map_err(|e| e.to_string())?;
            let md = format!(
                "# Eval on my history\n\n{} plays, {} liked tracks.\n\n{}{LIMITS}",
                plays.len(),
                liked.len(),
                markdown_section("my history", &reports)
            );
            (Some(md), Some(json))
        }
        None => (None, None),
    };
    Ok(EvalOutput { fixtures_md: fixtures_markdown(&fixtures), fixtures_json, real_md, real_json })
}

/// Write the fixture report next to the docs and the real-history report under the state dir
/// (the latter holds numbers about the user's own listening and is never written into the repo).
pub fn write_all(
    out: &OutputDirs,
    result: &EvalOutput,
    write_baseline: bool,
) -> std::io::Result<Vec<std::path::PathBuf>> {
    let mut written = Vec::new();
    let mut put = |dir: &std::path::Path, name: &str, text: &str| -> std::io::Result<()> {
        std::fs::create_dir_all(dir)?;
        let path = dir.join(name);
        std::fs::write(&path, text)?;
        written.push(path);
        Ok(())
    };
    put(&out.docs, "eval-latest.md", &result.fixtures_md)?;
    put(&out.docs, "eval-latest.json", &result.fixtures_json)?;
    if write_baseline {
        put(&out.docs, "eval-baseline.json", &result.fixtures_json)?;
    }
    if let (Some(md), Some(json)) = (&result.real_md, &result.real_json) {
        put(&out.private, "eval-real.md", md)?;
        put(&out.private, "eval-real.json", json)?;
    }
    Ok(written)
}

/// Where the reports go.
pub struct OutputDirs {
    /// Fixture reports and the baseline (committed).
    pub docs: std::path::PathBuf,
    /// Reports about the user's own history (not committed).
    pub private: std::path::PathBuf,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(id: i64, track: &str, artist: &str, t: u64, ms: u64, done: bool) -> PlayLogEntry {
        PlayLogEntry {
            id,
            track_id: track.into(),
            title: String::new(),
            artist: artist.into(),
            album: String::new(),
            started_at: t,
            ms_played: ms,
            completed: done,
        }
    }

    #[test]
    fn labels_follow_the_rules() {
        let liked: HashSet<String> = ["l".to_string()].into();
        assert_eq!(label_play(&e(1, "a", "x", 0, 200_000, true), &liked), Label::Positive);
        assert_eq!(label_play(&e(1, "l", "x", 0, 200_000, true), &liked), Label::Strong);
        assert_eq!(label_play(&e(1, "a", "x", 0, 5_000, false), &liked), Label::Skipped);
        assert_eq!(label_play(&e(1, "a", "x", 0, 90_000, false), &liked), Label::WeakSkip);
        assert_eq!(label_play(&e(1, "l", "x", 0, 5_000, false), &liked), Label::Skipped, "a like does not save a skip");
        assert!(Label::Skipped.is_skip() && Label::WeakSkip.is_skip() && !Label::Positive.is_skip());
    }

    #[test]
    fn auc_cases() {
        assert_eq!(auc(&[3.0], &[1.0]), Some(1.0));
        assert_eq!(auc(&[1.0], &[3.0]), Some(0.0));
        assert_eq!(auc(&[1.0], &[1.0]), Some(0.5));
        assert_eq!(auc(&[], &[1.0]), None);
        assert_eq!(auc(&[1.0], &[]), None);
    }

    #[test]
    fn ndcg_cases() {
        assert_eq!(ndcg(&[1.0, 1.0], &[1.0, 1.0], 10), Some(1.0));
        let worse = ndcg(&[0.0, 1.0], &[1.0], 10).unwrap_or(9.0);
        assert!(worse > 0.0 && worse < 1.0);
        assert_eq!(ndcg(&[0.0], &[0.0], 10), None);
    }

    #[test]
    fn evaluation_trains_only_on_the_past() {
        // A ranker that panics if it is shown any play from the test day or later.
        struct Spy;
        impl Ranker for Spy {
            fn name(&self) -> &'static str { "spy" }
            fn scores(&self, ctx: &TrainCtx<'_>, items: &[Item]) -> Vec<f64> {
                assert!(ctx.plays.iter().all(|p| p.started_at < ctx.now), "future play leaked");
                vec![0.0; items.len()]
            }
        }
        let (plays, liked) = fixture(Listener::Broad);
        let r = evaluate(&Spy, &plays, &liked);
        assert_eq!(r.metrics.days, TEST_DAYS);
    }

    #[test]
    fn too_little_history_gives_no_days_and_no_numbers() {
        let plays: Vec<PlayLogEntry> = (0..10).map(|i| e(i, "t", "a", 1000 + i as u64, 200_000, true)).collect();
        let r = evaluate(&CurrentEngine, &plays, &HashSet::new());
        assert_eq!(r.metrics.days, 0);
        assert_eq!(r.metrics.recall_at_k, None);
        assert_eq!(r.metrics.coverage, None);
        let none = evaluate(&CurrentEngine, &[], &HashSet::new());
        assert_eq!(none.metrics.days, 0);
    }

    #[test]
    fn fixtures_are_deterministic_and_non_trivial() {
        for l in Listener::ALL {
            let (a, la) = fixture(l);
            let (b, lb) = fixture(l);
            assert_eq!(a, b);
            assert_eq!(la, lb);
            assert_eq!(a.len(), 80 * 12);
            assert!(a.iter().any(|p| !p.completed) && a.iter().any(|p| p.completed));
        }
        assert_eq!(serde_json::to_string(&run_fixtures()).ok(), serde_json::to_string(&run_fixtures()).ok());
    }

    #[test]
    fn taste_beats_random_and_knows_skips_on_the_narrow_listener() {
        let (plays, liked) = fixture(Listener::Narrow);
        let cur = evaluate(&CurrentEngine, &plays, &liked).metrics;
        let rnd = evaluate(&SeededRandom(7), &plays, &liked).metrics;
        assert!(cur.recall_at_k > rnd.recall_at_k, "{cur:?} vs {rnd:?}");
        assert!(cur.skip_auc.unwrap_or(0.0) > 0.7, "{cur:?}");
        assert!(rnd.skip_auc.unwrap_or(0.0) < 0.7, "{rnd:?}");
    }

    #[test]
    fn real_style_history_without_skips_has_no_skip_auc() {
        let (plays, liked) = fixture(Listener::Broad);
        let only_done: Vec<PlayLogEntry> = plays.into_iter().filter(|p| p.completed).collect();
        assert_eq!(evaluate(&CurrentEngine, &only_done, &liked).metrics.skip_auc, None);
    }

    #[test]
    fn write_all_keeps_real_numbers_out_of_the_docs_dir() {
        let (plays, liked) = fixture(Listener::Shift);
        let out = build_output(Some((&plays, &liked))).unwrap_or_else(|e| panic!("{e}"));
        let tmp = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let dirs = OutputDirs { docs: tmp.path().join("docs"), private: tmp.path().join("private") };
        let files = write_all(&dirs, &out, true).unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(files.len(), 5);
        assert!(dirs.docs.join("eval-baseline.json").exists());
        assert!(dirs.private.join("eval-real.md").exists());
        assert!(!dirs.docs.join("eval-real.md").exists());
    }

    #[test]
    fn output_has_both_formats_and_keeps_real_data_out_of_fixtures() {
        let (plays, liked) = fixture(Listener::Shift);
        let out = build_output(Some((&plays, &liked))).unwrap_or_else(|e| panic!("{e}"));
        assert!(out.fixtures_md.contains("narrow taste") && out.fixtures_md.contains("Limits:"));
        assert!(out.real_md.as_deref().unwrap_or("").contains("my history"));
        assert!(!out.fixtures_md.contains("my history"));
        assert!(serde_json::from_str::<serde_json::Value>(&out.fixtures_json).is_ok());
        assert!(build_output(None).map(|o| o.real_md.is_none()).unwrap_or(false));
    }
}
