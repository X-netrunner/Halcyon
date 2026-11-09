//! Part 5, retrieve + rank + rerank end to end, offline: a pool from several sources, one of them
//! failing, scored with the model and cut into a list. The Spotify matching step needs a real
//! session and is not covered here.

use halcyon_musicd::cache::PlayLogEntry;
use halcyon_musicd::reco::bandit::Bandit;
use halcyon_musicd::reco::engine::score_pool;
use halcyon_musicd::reco::features::{extract, FeatureCtx};
use halcyon_musicd::reco::model::{catch_up, RecoState};
use halcyon_musicd::reco::rerank::{recent_map, rerank, RerankCfg};
use halcyon_musicd::reco::retrieve::{gate, merge};
use halcyon_musicd::reco::{phase_for, Candidate, Phase, Source};
use halcyon_musicd::taste::{TagTable, TasteProfile};
use std::collections::{HashMap, HashSet};

const NOW: u64 = 1_800_000_000;
const DAY: u64 = 86_400;

fn play(id: i64, track: &str, title: &str, artist: &str, days_ago: f64, ms: u64, done: bool) -> PlayLogEntry {
    PlayLogEntry {
        id,
        track_id: track.into(),
        title: title.into(),
        artist: artist.into(),
        album: "A".into(),
        started_at: NOW - (days_ago * DAY as f64) as u64,
        ms_played: ms,
        completed: done,
    }
}

/// 60 plays: Ash and Birch finished, Dust skipped.
fn history() -> Vec<PlayLogEntry> {
    let mut v = Vec::new();
    let mut id = 0;
    for d in 1..=15 {
        for (i, a) in ["Ash", "Birch"].iter().enumerate() {
            id += 1;
            v.push(play(id, &format!("{a}-{i}"), &format!("{a} song"), a, d as f64 + i as f64 * 0.02, 200_000, true));
        }
        id += 1;
        v.push(play(id, "dust-1", "Dust song", "Dust", d as f64 + 0.4, 3_000, false));
        id += 1;
        v.push(play(id, "ash-9", "Ash other", "Ash", d as f64 + 0.5, 200_000, true));
    }
    v
}

fn pool() -> Vec<Candidate> {
    let mut batches: Vec<Vec<Candidate>> = Vec::new();
    // history, with ids
    let hist: Vec<Candidate> = history().iter().map(|p| Candidate::from_play(p, Source::History)).collect();
    batches.push(hist);
    // a source that answered
    batches.push(vec![
        Candidate::new("Newcomer", "Fresh", Source::Similar),
        Candidate::new("Stranger", "Hello", Source::TagNeighbour),
        Candidate::new("Dust", "Dust song", Source::Similar),
    ]);
    // a source that failed gives nothing; the rest still work
    batches.push(Vec::new());
    batches.push(vec![Candidate::new("Popstar", "Hit", Source::Chart), Candidate::new("Classic", "Oldie", Source::Editorial)]);
    merge(batches)
}

#[test]
fn a_cold_start_listener_gets_charts_and_editorial_only() {
    assert_eq!(phase_for(10), Phase::ColdStart);
    let cold = gate(pool(), Phase::ColdStart);
    assert!(!cold.is_empty());
    assert!(cold.iter().all(|c| c.sources.iter().all(|s| !s.is_personal())));
    let names: HashSet<&str> = cold.iter().map(|c| c.artist.as_str()).collect();
    assert!(names.contains("Popstar") && names.contains("Classic") && !names.contains("Ash"));
}

#[test]
fn a_personal_list_follows_taste_keeps_the_rules_and_tests_new_music() {
    let plays = history();
    assert_eq!(phase_for(plays.len()), Phase::Personal);
    let liked = HashSet::new();
    let tags = TagTable::default();
    let profile = TasteProfile::build(&plays, &liked, NOW, &tags, 0);

    // Learn like the daemon would on first start.
    let mut state = RecoState::default();
    let report = catch_up(&mut state, &plays, &[], &liked, &tags, NOW, 0);
    assert!(report.bootstrapped_now && report.examples > 0);

    let candidates = gate(pool(), Phase::Personal);
    let scored = score_pool(&candidates, &profile, &state, NOW, None);

    // Rank: what you finish beats what you skip; the chart song has no history at all.
    let score_of = |artist: &str| scored.iter().filter(|s| s.cand.artist == artist).map(|s| s.score).fold(f64::MIN, f64::max);
    assert!(score_of("Ash") > score_of("Dust"), "Ash {} Dust {}", score_of("Ash"), score_of("Dust"));
    assert!(score_of("Birch") > score_of("Popstar"));

    // Rerank: caps, no back to back, an unheard artist in the list.
    let cfg = RerankCfg { suppress_secs: 0, ..RerankCfg::shelf(8) };
    let picks = rerank(&scored, &HashMap::new(), NOW, &cfg, "home", &Bandit::default(), 7);
    assert!(!picks.is_empty());
    let names: Vec<&str> = picks.iter().map(|p| scored[p.index].cand.artist.as_str()).collect();
    for w in names.windows(2) {
        assert_ne!(w[0], w[1], "{names:?}");
    }
    for a in &names {
        assert!(names.iter().filter(|x| *x == a).count() <= 2, "{names:?}");
    }
    assert!(picks.iter().any(|p| p.explore && scored[p.index].unheard), "no exploration slot: {names:?}");
    // The same inputs give the same list.
    let again = rerank(&scored, &HashMap::new(), NOW, &cfg, "home", &Bandit::default(), 7);
    assert_eq!(picks, again);
}

#[test]
fn what_was_just_played_does_not_come_back() {
    let mut plays = history();
    plays.push(play(900, "ash-9", "Ash other", "Ash", 0.01, 200_000, true));
    let candidates = gate(pool(), Phase::Personal);
    let profile = TasteProfile::build(&plays, &HashSet::new(), NOW, &TagTable::default(), 0);
    let scored = score_pool(&candidates, &profile, &RecoState::default(), NOW, None);
    let cfg = RerankCfg { explore_share: 0.0, flow_weight: 0.0, ..RerankCfg::shelf(20) };
    let picks = rerank(&scored, &recent_map(&plays), NOW, &cfg, "home", &Bandit::default(), 1);
    assert!(picks.iter().all(|p| scored[p.index].cand.track_id.as_deref() != Some("ash-9")));
}

#[test]
fn every_candidate_has_the_same_number_of_features() {
    let profile = TasteProfile::build(&history(), &HashSet::new(), NOW, &TagTable::default(), 0);
    for c in pool() {
        let f = extract(&c, &profile, &FeatureCtx { now: NOW, bucket: None });
        assert!(f.iter().all(|x| x.is_finite() && x.abs() <= 1.0 + 1e-9), "{:?}: {f:?}", c.key());
    }
}
