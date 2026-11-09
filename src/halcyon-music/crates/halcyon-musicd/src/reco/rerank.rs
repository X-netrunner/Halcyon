//! Part 5, rerank: turn a ranked pool into a list that feels varied and intentional.
//!
//! Rules, in the order they act:
//! 1. **Recently played songs are dropped** (default: the last 6 hours), except on lists that are
//!    meant to repeat (On Repeat).
//! 2. **Exploration share**: about 20% of the slots are reserved for artists you have never played.
//!    The *source* that fills each of those slots is chosen by Thompson sampling per shelf
//!    (`bandit.rs`), so the list keeps testing new music and learns what works.
//! 3. The other slots are filled one by one with **maximal marginal relevance**: a song's rank
//!    score, minus how much it resembles what is already on the list (same artist = 1, otherwise
//!    tag similarity), minus a small penalty for a big jump in energy from the previous song.
//! 4. Hard limits: **at most `max_per_artist` songs per artist** (2 for shelves, 3 for prompt mixes)
//!    and **never the same artist twice in a row** (relaxed only when nothing else is left).
//!
//! A prefix of a valid list is a valid list, so the engine can ask for more picks than it needs
//! and keep the first ones that match on Spotify.

use super::bandit::{Bandit, Rng};
use super::{Candidate, Source};
use crate::cache::PlayLogEntry;
use crate::suggestions::normalize_string;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct Scored {
    pub cand: Candidate,
    /// The rank score (a logit; only the order and the gaps matter).
    pub score: f64,
    /// The listener has never played this artist.
    pub unheard: bool,
}

#[derive(Debug, Clone)]
pub struct RerankCfg {
    /// Length of the list.
    pub n: usize,
    pub max_per_artist: usize,
    /// 1 = rank score only, lower = more variety.
    pub lambda: f64,
    /// Share of the list reserved for unheard artists (0 to 1).
    pub explore_share: f64,
    /// Songs played less than this long ago are dropped. 0 = keep them.
    pub suppress_secs: u64,
    /// Weight of the energy-jump penalty.
    pub flow_weight: f64,
    /// How many top-ranked candidates the exploit slots choose from.
    pub window: usize,
}

impl RerankCfg {
    /// A shelf on Home.
    pub fn shelf(n: usize) -> Self {
        RerankCfg {
            n,
            max_per_artist: 2,
            lambda: 0.85,
            explore_share: 0.20,
            suppress_secs: 6 * 3600,
            flow_weight: 0.15,
            window: (n * 4).max(40),
        }
    }

    /// A "describe a mood" playlist: one more song per artist is allowed.
    pub fn prompt_mix(n: usize) -> Self {
        RerankCfg { max_per_artist: 3, ..Self::shelf(n) }
    }

    /// A list that is meant to repeat what you play (On Repeat): nothing is suppressed, no exploration.
    pub fn repeat_list(n: usize) -> Self {
        RerankCfg { suppress_secs: 0, explore_share: 0.0, ..Self::shelf(n) }
    }

    /// What `--eval` uses. The offline replay has no outside candidates, so there is nothing to
    /// explore, and its catalogue is only the tracks you played, so nothing is suppressed. Three per
    /// artist as in prompt mixes: a listener with three favourite artists cannot fill ten slots
    /// with two each from their own history.
    pub fn eval(n: usize) -> Self {
        RerankCfg { n, max_per_artist: 3, lambda: 0.90, explore_share: 0.0, suppress_secs: 0, flow_weight: 0.0, window: (n * 4).max(40) }
    }
}

/// One slot of the result.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pick {
    /// Index into the `scored` slice.
    pub index: usize,
    /// The slot was an exploration slot (an unheard artist chosen through the bandit).
    pub explore: bool,
}

/// Songs played lately, keyed by Spotify id and by `Candidate::key`, with the time they started.
pub fn recent_map(plays: &[PlayLogEntry]) -> HashMap<String, u64> {
    let mut m: HashMap<String, u64> = HashMap::new();
    for p in plays {
        let by_id = m.entry(p.track_id.clone()).or_insert(0);
        *by_id = (*by_id).max(p.started_at);
        let name = format!("{}|{}", normalize_string(&p.artist), normalize_string(&p.title));
        let by_name = m.entry(name).or_insert(0);
        *by_name = (*by_name).max(p.started_at);
    }
    m
}

fn is_suppressed(c: &Candidate, recent: &HashMap<String, u64>, now: u64, secs: u64) -> bool {
    if secs == 0 {
        return false;
    }
    let fresh = |t: Option<&u64>| t.is_some_and(|at| *at <= now && now - *at < secs);
    c.track_id.as_deref().is_some_and(|id| fresh(recent.get(id))) || fresh(recent.get(&c.key()))
}

// ------------------------------------------------------------------ similarity and energy

fn tag_cosine(a: &[(String, f64)], b: &[(String, f64)]) -> f64 {
    let bm: HashMap<&str, f64> = b.iter().map(|(t, w)| (t.as_str(), *w)).collect();
    let dot: f64 = a.iter().filter_map(|(t, w)| bm.get(t.as_str()).map(|x| w * x)).sum();
    let na = a.iter().map(|(_, w)| w * w).sum::<f64>().sqrt();
    let nb = b.iter().map(|(_, w)| w * w).sum::<f64>().sqrt();
    if na > 1e-12 && nb > 1e-12 {
        (dot / (na * nb)).clamp(0.0, 1.0)
    } else {
        0.0
    }
}

/// How alike two candidates are, 0 to 1: the same artist is 1, otherwise 0.6 times the tag cosine.
pub fn similarity(a: &Candidate, b: &Candidate) -> f64 {
    if normalize_string(&a.artist) == normalize_string(&b.artist) {
        1.0
    } else {
        0.6 * tag_cosine(&a.tags, &b.tags)
    }
}

const LOW_ENERGY: &[&str] = &[
    "ambient", "chill", "chillout", "lo-fi", "lofi", "acoustic", "sleep", "downtempo", "classical", "piano", "folk",
    "soft", "calm", "meditation", "slow", "singer-songwriter",
];
const HIGH_ENERGY: &[&str] = &[
    "metal", "hardcore", "punk", "techno", "dance", "edm", "drum and bass", "dnb", "thrash", "trap", "hardstyle",
    "house", "rave", "industrial", "electro", "hard rock", "uptempo",
];

/// A rough energy from tags, 0 (calm) to 1 (intense). `None` when no tag says anything: the song
/// is then neutral for the flow rule, never penalised.
pub fn energy_of(tags: &[(String, f64)]) -> Option<f64> {
    let (mut sum, mut weight) = (0.0, 0.0);
    for (tag, w) in tags {
        let t = tag.to_lowercase();
        let e = if HIGH_ENERGY.iter().any(|k| t == *k || t.contains(k)) {
            0.9
        } else if LOW_ENERGY.iter().any(|k| t == *k || t.contains(k)) {
            0.15
        } else {
            continue;
        };
        sum += e * w;
        weight += w;
    }
    if weight > 1e-12 {
        Some(sum / weight)
    } else {
        None
    }
}

/// A jump of up to 0.3 in energy is free; beyond that it costs `flow_weight` per unit.
fn flow_penalty(prev: Option<&Candidate>, next: &Candidate, weight: f64) -> f64 {
    let (Some(p), Some(n)) = (prev.and_then(|c| energy_of(&c.tags)), energy_of(&next.tags)) else {
        return 0.0;
    };
    weight * ((p - n).abs() - 0.3).max(0.0)
}

// ------------------------------------------------------------------ the reranker

/// Slots (0-based) reserved for exploration, spread evenly over the list.
pub fn explore_positions(n: usize, k: usize) -> Vec<bool> {
    let mut v = vec![false; n];
    if n == 0 || k == 0 {
        return v;
    }
    let k = k.min(n);
    for j in 0..k {
        let pos = (((j as f64 + 0.5) * n as f64) / k as f64).floor() as usize;
        if let Some(slot) = v.get_mut(pos.min(n - 1)) {
            *slot = true;
        }
    }
    v
}

struct Run<'a> {
    scored: &'a [Scored],
    cfg: &'a RerankCfg,
    picks: Vec<Pick>,
    used: HashSet<usize>,
    per_artist: HashMap<String, usize>,
}

impl Run<'_> {
    fn artist(&self, i: usize) -> String {
        self.scored.get(i).map(|s| normalize_string(&s.cand.artist)).unwrap_or_default()
    }

    fn last_artist(&self) -> Option<String> {
        self.picks.last().map(|p| self.artist(p.index))
    }

    /// The hard rules. `strict` also forbids the same artist as the previous slot.
    fn allowed(&self, i: usize, strict: bool) -> bool {
        if self.used.contains(&i) {
            return false;
        }
        let a = self.artist(i);
        if self.per_artist.get(&a).copied().unwrap_or(0) >= self.cfg.max_per_artist {
            return false;
        }
        if strict && self.last_artist().as_deref() == Some(a.as_str()) {
            return false;
        }
        true
    }

    fn push(&mut self, i: usize, explore: bool) {
        let a = self.artist(i);
        *self.per_artist.entry(a).or_insert(0) += 1;
        self.used.insert(i);
        self.picks.push(Pick { index: i, explore });
    }

    fn unheard_so_far(&self) -> usize {
        self.picks.iter().filter(|p| self.scored.get(p.index).is_some_and(|s| s.unheard)).count()
    }
}

/// Build the list. `order` holds the indices of the eligible candidates, best rank score first.
pub fn rerank(
    scored: &[Scored],
    recent: &HashMap<String, u64>,
    now: u64,
    cfg: &RerankCfg,
    shelf: &str,
    bandit: &Bandit,
    seed: u64,
) -> Vec<Pick> {
    // 1. drop what was just played
    let mut order: Vec<usize> =
        (0..scored.len()).filter(|&i| scored.get(i).is_some_and(|s| !is_suppressed(&s.cand, recent, now, cfg.suppress_secs))).collect();
    order.sort_by(|&a, &b| {
        let (sa, sb) = (scored.get(a), scored.get(b));
        let (xa, xb) = (sa.map_or(f64::MIN, |s| s.score), sb.map_or(f64::MIN, |s| s.score));
        xb.partial_cmp(&xa)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| sa.map(|s| s.cand.key()).cmp(&sb.map(|s| s.cand.key())))
    });
    if order.is_empty() || cfg.n == 0 {
        return Vec::new();
    }
    let window: Vec<usize> = order.iter().copied().take(cfg.window.max(cfg.n)).collect();
    let (lo, hi) = window.iter().filter_map(|&i| scored.get(i)).fold((f64::MAX, f64::MIN), |(lo, hi), s| (lo.min(s.score), hi.max(s.score)));
    let span = if hi > lo { hi - lo } else { 1.0 };

    let explore_target = ((cfg.n as f64) * cfg.explore_share.clamp(0.0, 1.0)).round() as usize;
    let planned = explore_positions(cfg.n, explore_target);
    let mut rng = Rng::new(seed);
    let mut run = Run { scored, cfg, picks: Vec::new(), used: HashSet::new(), per_artist: HashMap::new() };

    for pos in 0..cfg.n {
        let need = explore_target.saturating_sub(run.unheard_so_far());
        let left = cfg.n - pos;
        let want_explore = need > 0 && (planned.get(pos).copied().unwrap_or(false) || left <= need);
        let mut chosen: Option<(usize, bool)> = None;
        if want_explore {
            chosen = pick_explore(&run, &order, shelf, bandit, &mut rng, true).map(|i| (i, true));
            if chosen.is_none() {
                chosen = pick_explore(&run, &order, shelf, bandit, &mut rng, false).map(|i| (i, true));
            }
        }
        if chosen.is_none() {
            chosen = pick_exploit(&run, &window, lo, span, true).or_else(|| pick_exploit(&run, &window, lo, span, false)).map(|i| (i, false));
        }
        match chosen {
            Some((i, ex)) => run.push(i, ex),
            None => break,
        }
    }
    run.picks
}

/// MMR over the window.
fn pick_exploit(run: &Run<'_>, window: &[usize], lo: f64, span: f64, strict: bool) -> Option<usize> {
    let prev = run.picks.last().and_then(|p| run.scored.get(p.index)).map(|s| &s.cand);
    let mut best: Option<(usize, f64)> = None;
    for &i in window {
        if !run.allowed(i, strict) {
            continue;
        }
        let Some(s) = run.scored.get(i) else { continue };
        let rel = (s.score - lo) / span;
        let redundancy = run
            .picks
            .iter()
            .filter_map(|p| run.scored.get(p.index))
            .map(|chosen| similarity(&s.cand, &chosen.cand))
            .fold(0.0, f64::max);
        let value = run.cfg.lambda * rel - (1.0 - run.cfg.lambda) * redundancy - flow_penalty(prev, &s.cand, run.cfg.flow_weight);
        // Strictly greater: on a tie the earlier (better ranked) candidate stays.
        if best.is_none_or(|(_, b)| value > b + 1e-12) {
            best = Some((i, value));
        }
    }
    best.map(|(i, _)| i)
}

/// An exploration slot: Thompson-sample the source, then take the best unheard song of it.
fn pick_explore(run: &Run<'_>, order: &[usize], shelf: &str, bandit: &Bandit, rng: &mut Rng, strict: bool) -> Option<usize> {
    // The best allowed unheard candidate of each source (order is best first).
    let mut best_of: Vec<(Source, usize)> = Vec::new();
    for &i in order {
        let Some(s) = run.scored.get(i) else { continue };
        if !s.unheard || !run.allowed(i, strict) {
            continue;
        }
        let Some(src) = s.cand.primary_source() else { continue };
        if !best_of.iter().any(|(b, _)| *b == src) {
            best_of.push((src, i));
        }
    }
    // Sorted by source so the draw order, and with it the result, does not depend on the pool.
    best_of.sort_by_key(|(src, _)| *src);
    let mut pick: Option<(usize, f64)> = None;
    for (src, i) in best_of {
        let draw = bandit.sample(shelf, src, rng);
        if pick.is_none_or(|(_, d)| draw > d) {
            pick = Some((i, draw));
        }
    }
    pick.map(|(i, _)| i)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: u64 = 1_800_000_000;

    fn cand(artist: &str, title: &str, source: Source) -> Candidate {
        Candidate::new(artist, title, source)
    }

    fn sc(artist: &str, title: &str, score: f64, unheard: bool, source: Source) -> Scored {
        Scored { cand: cand(artist, title, source), score, unheard }
    }

    fn cfg(n: usize) -> RerankCfg {
        RerankCfg { explore_share: 0.0, suppress_secs: 0, flow_weight: 0.0, ..RerankCfg::shelf(n) }
    }

    fn run(scored: &[Scored], cfg: &RerankCfg) -> Vec<Pick> {
        rerank(scored, &HashMap::new(), NOW, cfg, "home", &Bandit::default(), 1)
    }

    fn artists(scored: &[Scored], picks: &[Pick]) -> Vec<String> {
        picks.iter().filter_map(|p| scored.get(p.index)).map(|s| s.cand.artist.clone()).collect()
    }

    #[test]
    fn at_most_two_per_artist_and_never_back_to_back() {
        let mut pool = Vec::new();
        // Ash dominates the scores; Birch and Cedar trail.
        for i in 0..8 {
            pool.push(sc("Ash", &format!("a{i}"), 10.0 - i as f64 * 0.1, false, Source::History));
        }
        for i in 0..4 {
            pool.push(sc("Birch", &format!("b{i}"), 5.0 - i as f64 * 0.1, false, Source::History));
            pool.push(sc("Cedar", &format!("c{i}"), 4.0 - i as f64 * 0.1, false, Source::History));
        }
        let picks = run(&pool, &cfg(6));
        let names = artists(&pool, &picks);
        assert_eq!(names.len(), 6, "{names:?}");
        for a in ["Ash", "Birch", "Cedar"] {
            assert!(names.iter().filter(|n| *n == a).count() <= 2, "{a} more than twice in {names:?}");
        }
        for w in names.windows(2) {
            assert_ne!(w[0], w[1], "back to back in {names:?}");
        }
    }

    #[test]
    fn the_cap_is_a_hard_limit_the_list_is_shorter_rather_than_break_it() {
        let pool: Vec<Scored> = (0..6).map(|i| sc("Ash", &format!("a{i}"), 5.0 - i as f64, false, Source::History)).collect();
        let picks = run(&pool, &cfg(5));
        assert_eq!(picks.len(), 2, "one artist, cap 2");
        let mix = RerankCfg { explore_share: 0.0, suppress_secs: 0, flow_weight: 0.0, ..RerankCfg::prompt_mix(5) };
        assert_eq!(run(&pool, &mix).len(), 3, "prompt mixes allow 3");
    }

    #[test]
    fn back_to_back_is_only_relaxed_when_nothing_else_is_left() {
        let pool = vec![sc("Ash", "a1", 3.0, false, Source::History), sc("Ash", "a2", 2.0, false, Source::History)];
        let picks = run(&pool, &cfg(2));
        assert_eq!(picks.len(), 2, "better two in a row than a short list");
    }

    #[test]
    fn without_ties_the_order_follows_the_score() {
        let pool = vec![
            sc("A", "1", 1.0, false, Source::History),
            sc("B", "2", 3.0, false, Source::History),
            sc("C", "3", 2.0, false, Source::History),
        ];
        let picks = run(&pool, &RerankCfg { lambda: 1.0, ..cfg(3) });
        assert_eq!(artists(&pool, &picks), vec!["B", "C", "A"]);
    }

    #[test]
    fn mmr_prefers_a_different_sound_when_scores_are_close() {
        let mut a1 = sc("Ash", "a1", 1.00, false, Source::History);
        a1.cand.tags = vec![("lo-fi".into(), 1.0)];
        let mut b1 = sc("Birch", "b1", 0.98, false, Source::History);
        b1.cand.tags = vec![("lo-fi".into(), 1.0)];
        let mut c1 = sc("Cedar", "c1", 0.96, false, Source::History);
        c1.cand.tags = vec![("metal".into(), 1.0)];
        let pool = vec![a1, b1, c1];
        let picks = run(&pool, &RerankCfg { lambda: 0.6, ..cfg(2) });
        assert_eq!(artists(&pool, &picks), vec!["Ash", "Cedar"], "the second pick should not sound like the first");
    }

    #[test]
    fn songs_played_in_the_last_hours_are_dropped_unless_the_list_repeats() {
        let mut pool = vec![sc("Ash", "fresh", 9.0, false, Source::History), sc("Birch", "old", 1.0, false, Source::History)];
        pool[0].cand.track_id = Some("t-fresh".into());
        pool[1].cand.track_id = Some("t-old".into());
        let plays = vec![
            PlayLogEntry { id: 1, track_id: "t-fresh".into(), title: "fresh".into(), artist: "Ash".into(), album: "A".into(), started_at: NOW - 3_600, ms_played: 200_000, completed: true },
            PlayLogEntry { id: 2, track_id: "t-old".into(), title: "old".into(), artist: "Birch".into(), album: "A".into(), started_at: NOW - 3 * 86_400, ms_played: 200_000, completed: true },
        ];
        let recent = recent_map(&plays);
        let shelf = RerankCfg { explore_share: 0.0, flow_weight: 0.0, ..RerankCfg::shelf(2) };
        let picks = rerank(&pool, &recent, NOW, &shelf, "home", &Bandit::default(), 1);
        assert_eq!(artists(&pool, &picks), vec!["Birch"]);
        let repeat = RerankCfg { flow_weight: 0.0, ..RerankCfg::repeat_list(2) };
        let picks = rerank(&pool, &recent, NOW, &repeat, "on-repeat", &Bandit::default(), 1);
        assert_eq!(picks.len(), 2, "On Repeat keeps recent songs");
    }

    #[test]
    fn a_song_without_an_id_is_matched_by_name() {
        let pool = vec![sc("Ash", "Same Song (Live)", 9.0, false, Source::Similar)];
        let plays = vec![PlayLogEntry { id: 1, track_id: "x".into(), title: "Same Song".into(), artist: "ash".into(), album: "A".into(), started_at: NOW - 60, ms_played: 1, completed: true }];
        let picks = rerank(&pool, &recent_map(&plays), NOW, &RerankCfg::shelf(1), "home", &Bandit::default(), 1);
        assert!(picks.is_empty());
    }

    #[test]
    fn about_a_fifth_of_a_list_is_unheard_artists_spread_out() {
        let mut pool = Vec::new();
        for i in 0..20 {
            pool.push(sc(&format!("Known{}", i % 10), &format!("k{i}"), 10.0 - i as f64 * 0.05, false, Source::History));
        }
        for i in 0..10 {
            pool.push(sc(&format!("New{i}"), &format!("n{i}"), -1.0 - i as f64 * 0.1, true, if i % 2 == 0 { Source::Similar } else { Source::Chart }));
        }
        let c = RerankCfg { suppress_secs: 0, flow_weight: 0.0, ..RerankCfg::shelf(10) };
        let picks = rerank(&pool, &HashMap::new(), NOW, &c, "home", &Bandit::default(), 11);
        assert_eq!(picks.len(), 10);
        let explored: Vec<usize> = picks.iter().enumerate().filter(|(_, p)| p.explore).map(|(i, _)| i).collect();
        assert_eq!(explored.len(), 2, "20% of 10");
        assert!(explored.iter().all(|i| pool.get(picks[*i].index).is_some_and(|s| s.unheard)));
        assert!(explored[1] - explored[0] >= 3, "spread out: {explored:?}");
        assert_eq!(picks.iter().filter(|p| pool[p.index].unheard).count(), 2, "no more unheard than planned here");
    }

    #[test]
    fn exploration_follows_the_source_that_has_worked() {
        let mut pool = Vec::new();
        for i in 0..12 {
            pool.push(sc(&format!("Known{i}"), &format!("k{i}"), 5.0 - i as f64 * 0.1, false, Source::History));
        }
        for i in 0..6 {
            pool.push(sc(&format!("Sim{i}"), &format!("s{i}"), 0.0, true, Source::Similar));
            pool.push(sc(&format!("Chart{i}"), &format!("c{i}"), 0.0, true, Source::Chart));
        }
        let mut bandit = Bandit::default();
        for _ in 0..25 {
            bandit.reward("home", "similar", true);
            bandit.reward("home", "chart", false);
        }
        let c = RerankCfg { suppress_secs: 0, flow_weight: 0.0, explore_share: 0.3, ..RerankCfg::shelf(10) };
        let mut from_similar = 0;
        let mut total = 0;
        for seed in 0..40u64 {
            let picks = rerank(&pool, &HashMap::new(), NOW, &c, "home", &bandit, seed);
            for p in picks.iter().filter(|p| p.explore) {
                total += 1;
                if pool[p.index].cand.primary_source() == Some(Source::Similar) {
                    from_similar += 1;
                }
            }
        }
        assert!(total >= 100, "{total} exploration slots");
        assert!(from_similar as f64 > 0.8 * total as f64, "{from_similar} of {total} came from the source that works");
    }

    #[test]
    fn the_list_is_stable_for_a_seed_and_can_change_with_another() {
        let mut pool = Vec::new();
        for i in 0..15 {
            pool.push(sc(&format!("K{i}"), "t", 3.0 - i as f64 * 0.01, false, Source::History));
        }
        for i in 0..8 {
            pool.push(sc(&format!("U{i}"), "t", 0.0, true, if i % 2 == 0 { Source::Similar } else { Source::TagNeighbour }));
        }
        let c = RerankCfg { suppress_secs: 0, ..RerankCfg::shelf(10) };
        let a = rerank(&pool, &HashMap::new(), NOW, &c, "home", &Bandit::default(), 5);
        let b = rerank(&pool, &HashMap::new(), NOW, &c, "home", &Bandit::default(), 5);
        assert_eq!(a, b);
        let others: Vec<Vec<Pick>> = (6..30).map(|s| rerank(&pool, &HashMap::new(), NOW, &c, "home", &Bandit::default(), s)).collect();
        assert!(others.iter().any(|o| *o != a), "no seed changes the exploration at all");
    }

    #[test]
    fn with_nothing_unheard_the_exploration_slots_go_to_the_best_songs() {
        let pool: Vec<Scored> = (0..6).map(|i| sc(&format!("K{i}"), "t", 6.0 - i as f64, false, Source::History)).collect();
        let c = RerankCfg { suppress_secs: 0, flow_weight: 0.0, ..RerankCfg::shelf(5) };
        let picks = rerank(&pool, &HashMap::new(), NOW, &c, "home", &Bandit::default(), 1);
        assert_eq!(picks.len(), 5);
        assert!(picks.iter().all(|p| !p.explore));
    }

    #[test]
    fn a_big_energy_jump_costs_but_a_missing_tag_never_does() {
        let mut calm = sc("Calm", "1", 1.0, false, Source::History);
        calm.cand.tags = vec![("ambient".into(), 1.0)];
        let mut loud = sc("Loud", "2", 0.99, false, Source::History);
        loud.cand.tags = vec![("thrash metal".into(), 1.0)];
        let mut mellow = sc("Mellow", "3", 0.95, false, Source::History);
        mellow.cand.tags = vec![("chillout".into(), 1.0)];
        let plain = sc("Plain", "4", 0.90, false, Source::History);
        let pool = vec![calm.clone(), loud.clone(), mellow.clone(), plain.clone()];
        let c = RerankCfg { lambda: 0.95, flow_weight: 1.0, explore_share: 0.0, suppress_secs: 0, ..RerankCfg::shelf(3) };
        let names = artists(&pool, &rerank(&pool, &HashMap::new(), NOW, &c, "home", &Bandit::default(), 1));
        assert_eq!(names.first().map(String::as_str), Some("Calm"));
        assert_eq!(names.get(1).map(String::as_str), Some("Mellow"), "calm to mellow, not calm to metal: {names:?}");
        assert_eq!(energy_of(&[]), None);
        assert_eq!(energy_of(&[("indie".into(), 1.0)]), None);
        assert!(energy_of(&[("deep house".into(), 1.0)]).is_some_and(|e| e > 0.8));
    }

    #[test]
    fn explore_positions_are_even_and_bounded() {
        assert_eq!(explore_positions(10, 2), vec![false, false, true, false, false, false, false, true, false, false]);
        assert!(explore_positions(0, 3).is_empty());
        assert_eq!(explore_positions(4, 0), vec![false; 4]);
        assert_eq!(explore_positions(3, 9).iter().filter(|b| **b).count(), 3);
    }

    #[test]
    fn empty_pool_and_zero_length_give_an_empty_list() {
        assert!(run(&[], &cfg(5)).is_empty());
        let pool = vec![sc("A", "1", 1.0, false, Source::History)];
        assert!(run(&pool, &cfg(0)).is_empty());
    }

    #[test]
    fn a_prefix_of_the_list_obeys_the_same_rules() {
        let mut pool = Vec::new();
        for i in 0..30 {
            pool.push(sc(&format!("A{}", i % 7), &format!("t{i}"), 5.0 - i as f64 * 0.05, i % 5 == 0, if i % 2 == 0 { Source::History } else { Source::Similar }));
        }
        let c = RerankCfg { suppress_secs: 0, flow_weight: 0.0, ..RerankCfg::shelf(15) };
        let long = rerank(&pool, &HashMap::new(), NOW, &c, "home", &Bandit::default(), 3);
        let names = artists(&pool, &long);
        for take in 1..=names.len() {
            let head = &names[..take];
            for w in head.windows(2) {
                assert_ne!(w[0], w[1]);
            }
            for a in head {
                assert!(head.iter().filter(|x| *x == a).count() <= 2);
            }
        }
    }
}
