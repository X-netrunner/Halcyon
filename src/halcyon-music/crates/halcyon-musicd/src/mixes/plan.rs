//! Part 6, the pure half of building a mix: which candidates a kind of mix may use, what the
//! listener has ruled out, the artist caps, and how Smart Shuffle and radio put songs in order.
//!
//! No clock, no network, no SQLite: everything takes its input as arguments, so the same input
//! always gives the same list and a test can check each rule alone.

use super::store::Feedback;
use super::{MixKind, MAX_DAILY_MIXES};
use crate::cache::PlayLogEntry;
use crate::reco::bandit::Rng;
use crate::reco::engine::ShelfResult;
use crate::reco::features::is_unheard;
use crate::reco::rerank::similarity;
use crate::reco::retrieve::NEIGHBOUR_MIN_SIM;
use crate::reco::{phase_for, Candidate, Phase, Source};
use crate::suggestions::normalize_string;
use crate::taste::{artist_key, AffinityCtx, TagTable, TasteProfile};
use halcyon_music_core::state::Track;
use std::collections::{HashMap, HashSet};

const DAY: u64 = 86_400;
/// On Repeat looks at this many days.
pub const ON_REPEAT_DAYS: u64 = 30;
/// Repeat Rewind wants songs not played for this long.
pub const REWIND_AFTER_DAYS: u64 = 60;
/// A pool smaller than this is not enough for a mix; the next, wider plan is tried.
pub const MIN_POOL: usize = 12;
/// Tags that say nothing about the music.
pub const GENERIC_TAGS: &[&str] = &[
    "seen live", "favorites", "favourites", "favorite", "favourite", "awesome", "love", "good", "best", "amazing", "my music", "cool", "male vocalists",
    "female vocalists", "under 2000 listeners",
];

/// Which of the retrieved candidates a mix may use.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum PoolPlan {
    /// Everything (the shelf on Home, a Daylist with nothing better, a cold start).
    #[default]
    All,
    /// A Daily Mix: songs by artists of this taste cluster, and unheard artists whose tags fit it.
    Cluster(u32),
    /// Discover Weekly: artists you have never played.
    Unheard,
    /// Release Radar: new releases by artists you play.
    NewReleases,
    /// On Repeat: your own songs finished at least this often in the last 30 days.
    OnRepeat { min_plays: u32 },
    /// Repeat Rewind: your own songs by artists you like that you have not played for two months.
    Rewind,
    /// Daylist: songs whose artist is tagged with this mood or genre.
    Tag(String),
}

/// How often and how lately each of your songs was played (finished), by Spotify id.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PlayStats {
    pub plays_30d: u32,
    pub last_played: u64,
}

pub fn play_stats(plays: &[PlayLogEntry], now: u64) -> HashMap<String, PlayStats> {
    let cutoff = now.saturating_sub(ON_REPEAT_DAYS * DAY);
    let mut m: HashMap<String, PlayStats> = HashMap::new();
    for p in plays.iter().filter(|p| p.completed) {
        let e = m.entry(p.track_id.clone()).or_default();
        e.last_played = e.last_played.max(p.started_at);
        if p.started_at >= cutoff && p.started_at <= now {
            e.plays_30d = e.plays_30d.saturating_add(1);
        }
    }
    m
}

pub struct PlanCtx<'a> {
    pub profile: &'a TasteProfile,
    pub now: u64,
    pub stats: &'a HashMap<String, PlayStats>,
}

fn is_own(c: &Candidate) -> bool {
    c.sources.iter().any(|s| matches!(s, Source::History | Source::Liked))
}

fn in_cluster(c: &Candidate, id: u32, p: &TasteProfile) -> bool {
    if p.artist_cluster.get(&artist_key(&c.artist)) == Some(&id) {
        return true;
    }
    !c.tags.is_empty() && matches!(p.cluster_fit(&c.tags), Some((cid, sim)) if cid == id && sim >= NEIGHBOUR_MIN_SIM)
}

/// Keep only what `plan` allows. Order is kept.
pub fn filter_pool(plan: &PoolPlan, pool: Vec<Candidate>, ctx: &PlanCtx<'_>) -> Vec<Candidate> {
    let keep = |c: &Candidate| -> bool {
        match plan {
            PoolPlan::All => true,
            PoolPlan::Cluster(id) => in_cluster(c, *id, ctx.profile),
            PoolPlan::Unheard => is_unheard(c, ctx.profile) && !is_own(c),
            PoolPlan::NewReleases => c.sources.contains(&Source::NewRelease) && !is_unheard(c, ctx.profile),
            PoolPlan::OnRepeat { min_plays } => {
                is_own(c) && c.track_id.as_ref().and_then(|id| ctx.stats.get(id)).is_some_and(|s| s.plays_30d >= *min_plays)
            }
            PoolPlan::Rewind => {
                let old = c
                    .track_id
                    .as_ref()
                    .is_none_or(|id| ctx.stats.get(id).is_none_or(|s| s.last_played < ctx.now.saturating_sub(REWIND_AFTER_DAYS * DAY)));
                is_own(c) && old && ctx.profile.artist_view(&c.artist, &AffinityCtx { now: ctx.now, bucket: None }).slow > 0.0
            }
            PoolPlan::Tag(t) => c.tags.iter().take(4).any(|(name, _)| name.eq_ignore_ascii_case(t)),
        }
    };
    pool.into_iter().filter(|c| keep(c)).collect()
}

/// The first plan whose filtered pool is big enough (`min`), else the last plan's pool, else
/// nothing. Returns the index of the plan used with the pool.
pub fn first_big_enough(plans: &[PoolPlan], pool: &[Candidate], ctx: &PlanCtx<'_>, min: usize) -> Option<(usize, Vec<Candidate>)> {
    let mut last: Option<(usize, Vec<Candidate>)> = None;
    for (i, plan) in plans.iter().enumerate() {
        let filtered = filter_pool(plan, pool.to_vec(), ctx);
        if filtered.len() >= min {
            return Some((i, filtered));
        }
        last = Some((i, filtered));
    }
    last
}

/// Drop what the listener ruled out: blocked songs (by id and by name) and blocked artists.
pub fn apply_feedback(pool: Vec<Candidate>, fb: &Feedback) -> Vec<Candidate> {
    if fb.is_empty() {
        return pool;
    }
    pool.into_iter().filter(|c| !fb.is_track_blocked(c.track_id.as_deref(), &c.artist, &c.title) && !fb.is_artist_blocked(&c.artist)).collect()
}

/// Which mixes to build for a profile: `(kind, slot, cluster id, cluster label)`. Cold start (fewer
/// than 50 plays) has no clusters and no history to repeat, so only Discover Weekly (from charts
/// and editorial picks) and the Daylist are made.
pub fn wanted_mixes(profile: &TasteProfile, slots: &[(usize, u32)]) -> Vec<(MixKind, usize, Option<u32>, String)> {
    let mut out = Vec::new();
    let personal = phase_for(profile.plays_seen) == Phase::Personal;
    if personal {
        for (slot, cid) in slots.iter().take(MAX_DAILY_MIXES) {
            let label = profile.clusters.iter().find(|c| c.id == *cid).map(|c| c.label.clone()).unwrap_or_default();
            out.push((MixKind::DailyMix, *slot, Some(*cid), label));
        }
    }
    out.push((MixKind::DiscoverWeekly, 0, None, String::new()));
    if personal {
        out.push((MixKind::ReleaseRadar, 0, None, String::new()));
        out.push((MixKind::OnRepeat, 0, None, String::new()));
        out.push((MixKind::RepeatRewind, 0, None, String::new()));
    }
    out.push((MixKind::Daylist, 0, None, String::new()));
    out
}

/// The mood or genre word that goes with this time of day: the tag that the artists you play in
/// this slot (weekday/weekend and night/morning/afternoon/evening) carry most.
pub fn daylist_tag(profile: &TasteProfile, tags: &TagTable, bucket: usize) -> Option<String> {
    let mut acc: HashMap<String, f64> = HashMap::new();
    for (artist, parts) in &profile.buckets {
        let w = parts.get(bucket).copied().unwrap_or(0.0);
        if w <= 0.0 {
            continue;
        }
        let Some(ts) = tags.get(artist) else { continue };
        for (tag, tw) in ts.iter().filter(|(t, _)| !GENERIC_TAGS.contains(&t.as_str())).take(3) {
            *acc.entry(tag.clone()).or_insert(0.0) += w * tw;
        }
    }
    let mut ranked: Vec<(String, f64)> = acc.into_iter().collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.0.cmp(&b.0)));
    ranked.into_iter().next().map(|(t, _)| t)
}

// ------------------------------------------------------------------ caps and order

/// Keep the parallel vectors of a result in step with `keep` (true = stay).
fn retain_parallel(r: &mut ShelfResult, keep: &[bool]) {
    fn go<T>(v: &mut Vec<T>, keep: &[bool]) {
        if v.len() != keep.len() {
            return;
        }
        let mut i = 0;
        v.retain(|_| {
            let k = keep.get(i).copied().unwrap_or(true);
            i += 1;
            k
        });
    }
    go(&mut r.tracks, keep);
    go(&mut r.reasons, keep);
    go(&mut r.explore, keep);
    go(&mut r.origins, keep);
}

/// The last word on artist caps, after songs were matched on Spotify (a matched song can carry an
/// artist the pick did not): at most `usual` songs per artist, one for an artist you said "less
/// like this" about, none for a blocked artist or song. Order is kept.
pub fn enforce_caps(r: &mut ShelfResult, usual: usize, fb: &Feedback) {
    let mut counts: HashMap<String, usize> = HashMap::new();
    let keep: Vec<bool> = r
        .tracks
        .iter()
        .map(|t| {
            if fb.is_track_blocked(Some(&t.id), &t.artist, &t.title) {
                return false;
            }
            let cap = fb.artist_cap(&t.artist, usual);
            let n = counts.entry(artist_key(&t.artist)).or_insert(0);
            if *n >= cap {
                return false;
            }
            *n += 1;
            true
        })
        .collect();
    retain_parallel(r, &keep);
}

/// After songs were removed, two songs by one artist may be neighbours. When that happens the
/// list is rebuilt greedily: each place takes the earliest remaining song whose artist differs
/// from the one before. A list with no neighbours is not touched, and one that cannot be
/// separated (only one artist left) keeps what order is left.
pub fn separate_neighbours(r: &mut ShelfResult) {
    let keys: Vec<String> = r.tracks.iter().map(|t| artist_key(&t.artist)).collect();
    if !keys.windows(2).any(|w| w.first() == w.get(1)) {
        return;
    }
    let mut remaining: Vec<usize> = (0..keys.len()).collect();
    let mut order: Vec<usize> = Vec::with_capacity(keys.len());
    while !remaining.is_empty() {
        let prev = order.last().and_then(|&k| keys.get(k));
        let pos = remaining.iter().position(|&k| keys.get(k) != prev).unwrap_or(0);
        order.push(remaining.remove(pos));
    }
    fn permute<T: Clone>(v: &mut Vec<T>, order: &[usize]) {
        if v.len() != order.len() {
            return;
        }
        let new: Vec<T> = order.iter().filter_map(|&k| v.get(k).cloned()).collect();
        if new.len() == v.len() {
            *v = new;
        }
    }
    permute(&mut r.tracks, &order);
    permute(&mut r.reasons, &order);
    permute(&mut r.explore, &order);
    permute(&mut r.origins, &order);
}

// ------------------------------------------------------------------ Smart Shuffle

/// A list of your own with one suggestion after every `every` of your songs.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Shuffled {
    pub tracks: Vec<Track>,
    /// Ids of the suggestions that were put in.
    pub suggested: Vec<String>,
}

fn fisher_yates<T>(v: &mut [T], rng: &mut Rng) {
    for i in (1..v.len()).rev() {
        let j = (rng.next_u64() % (i as u64 + 1)) as usize;
        v.swap(i, j);
    }
}

/// Shuffle `own` (never the same artist twice in a row when it can be helped), then put one of
/// `suggestions` after every `every` songs. A suggestion that is already in your list is left out,
/// and so is a second one by the same artist as the song before it.
pub fn smart_shuffle(own: &[Track], suggestions: &[Track], seed: u64, every: usize) -> Shuffled {
    let every = every.max(1);
    let mut rng = Rng::new(seed);
    let mut mine: Vec<Track> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for t in own {
        if seen.insert(t.id.clone()) {
            mine.push(t.clone());
        }
    }
    fisher_yates(&mut mine, &mut rng);
    // Pull apart same-artist neighbours: swap with the next song by someone else.
    for i in 1..mine.len() {
        let same = matches!((mine.get(i - 1), mine.get(i)), (Some(a), Some(b)) if artist_key(&a.artist) == artist_key(&b.artist));
        if same {
            if let Some(j) = (i + 1..mine.len()).find(|&j| mine.get(j).is_some_and(|c| mine.get(i - 1).is_some_and(|p| artist_key(&c.artist) != artist_key(&p.artist)))) {
                mine.swap(i, j);
            }
        }
    }
    let own_names: HashSet<String> = mine.iter().map(|t| format!("{}|{}", normalize_string(&t.artist), normalize_string(&t.title))).collect();
    let mut pool: Vec<&Track> = suggestions
        .iter()
        .filter(|s| !seen.contains(&s.id) && !own_names.contains(&format!("{}|{}", normalize_string(&s.artist), normalize_string(&s.title))))
        .collect();
    let mut out = Shuffled::default();
    let mut used: HashSet<String> = HashSet::new();
    for (i, t) in mine.iter().enumerate() {
        out.tracks.push(t.clone());
        if (i + 1) % every != 0 {
            continue;
        }
        let prev = artist_key(&t.artist);
        let next = mine.get(i + 1).map(|n| artist_key(&n.artist));
        let pick = pool.iter().position(|s| !used.contains(&s.id) && artist_key(&s.artist) != prev && Some(artist_key(&s.artist)) != next);
        if let Some(p) = pick {
            let s = pool.remove(p);
            used.insert(s.id.clone());
            out.suggested.push(s.id.clone());
            out.tracks.push(s.clone());
        }
    }
    out
}

// ------------------------------------------------------------------ radio

/// Radio: keep what is close to the seed song (the same artist, or sharing tags with it) and
/// everything in `keep` (candidates gathered around the seed on purpose).
pub fn near_seed(pool: Vec<Candidate>, seed: &Candidate, keep: &HashSet<String>) -> Vec<Candidate> {
    pool.into_iter().filter(|c| keep.contains(&c.key()) || similarity(c, seed) > 0.0).collect()
}

/// How far a refresh may move a score. The ranker is deterministic and the seed only steers the
/// exploration slots, so without this a Refresh could give the very same list.
pub const REFRESH_JITTER: f64 = 0.6;

/// A repeatable nudge in -`REFRESH_JITTER`/2 to +`REFRESH_JITTER`/2 for one candidate, from the
/// list's seed. `epoch` 0 (the normal scheduled list) gets none, so a list is stable for its period.
pub fn refresh_jitter(epoch: u64, seed: u64, key: &str) -> f64 {
    if epoch == 0 {
        return 0.0;
    }
    let h = crate::reco::bandit::fnv64(key) ^ seed.rotate_left(17);
    let u = Rng::new(h).uniform();
    (u - 0.5) * REFRESH_JITTER
}

/// How much a candidate looks like the seed of a radio: added to the rank score so the list stays
/// close to the song it started from. Same artist counts fully; otherwise 0.6 times the tag cosine.
pub fn seed_boost(c: &Candidate, seed: &Candidate) -> f64 {
    1.5 * similarity(c, seed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::taste::TagTable;

    fn cand(artist: &str, title: &str, source: Source) -> Candidate {
        let mut c = Candidate::new(artist, title, source);
        if matches!(source, Source::History | Source::Liked) {
            c.track_id = Some(format!("id-{artist}-{title}"));
        }
        c
    }

    fn with_tags(mut c: Candidate, tags: &[(&str, f64)]) -> Candidate {
        c.tags = tags.iter().map(|(t, w)| (t.to_string(), *w)).collect();
        c
    }

    fn play(id: &str, artist: &str, at: u64, completed: bool) -> PlayLogEntry {
        PlayLogEntry { id: 0, track_id: id.into(), title: "t".into(), artist: artist.into(), album: String::new(), started_at: at, ms_played: 1000, completed }
    }

    fn profile_with(plays: &[PlayLogEntry], now: u64, tags: &TagTable) -> TasteProfile {
        TasteProfile::build(plays, &HashSet::new(), now, tags, 0)
    }

    fn track(id: &str, artist: &str, title: &str) -> Track {
        Track::simple(id.into(), title.into(), artist.into(), "Album".into(), 1000)
    }

    fn result(tracks: Vec<Track>) -> ShelfResult {
        let n = tracks.len();
        ShelfResult { reasons: (0..n).map(|i| format!("r{i}")).collect(), explore: vec![false; n], origins: (0..n).collect(), tracks, ..Default::default() }
    }

    const NOW: u64 = 1_794_182_400;

    #[test]
    fn play_stats_count_finished_plays_in_the_last_30_days() {
        let plays = vec![
            play("a", "A", NOW - DAY, true),
            play("a", "A", NOW - 5 * DAY, true),
            play("a", "A", NOW - 40 * DAY, true),
            play("a", "A", NOW - 2 * DAY, false),
            play("b", "B", NOW - 90 * DAY, true),
        ];
        let m = play_stats(&plays, NOW);
        assert_eq!(m.get("a"), Some(&PlayStats { plays_30d: 2, last_played: NOW - DAY }));
        assert_eq!(m.get("b"), Some(&PlayStats { plays_30d: 0, last_played: NOW - 90 * DAY }));
    }

    #[test]
    fn on_repeat_wants_songs_finished_often_lately_and_can_relax() {
        let plays = vec![play("id-A-x", "A", NOW - DAY, true), play("id-A-x", "A", NOW - 2 * DAY, true), play("id-B-y", "B", NOW - 3 * DAY, true)];
        let stats = play_stats(&plays, NOW);
        let profile = profile_with(&plays, NOW, &TagTable::default());
        let ctx = PlanCtx { profile: &profile, now: NOW, stats: &stats };
        let pool = vec![cand("A", "x", Source::History), cand("B", "y", Source::History), cand("C", "z", Source::Chart)];
        let twice = filter_pool(&PoolPlan::OnRepeat { min_plays: 2 }, pool.clone(), &ctx);
        assert_eq!(twice.len(), 1);
        assert_eq!(twice.first().map(|c| c.artist.as_str()), Some("A"));
        let once = filter_pool(&PoolPlan::OnRepeat { min_plays: 1 }, pool.clone(), &ctx);
        assert_eq!(once.len(), 2, "a chart song is never on repeat");
        // The wider plan is tried when the first is too small.
        let plans = [PoolPlan::OnRepeat { min_plays: 2 }, PoolPlan::OnRepeat { min_plays: 1 }];
        let (i, got) = first_big_enough(&plans, &pool, &ctx, 2).expect("a plan");
        assert_eq!((i, got.len()), (1, 2));
        let (i, got) = first_big_enough(&plans, &pool, &ctx, 1).expect("a plan");
        assert_eq!((i, got.len()), (0, 1));
    }

    #[test]
    fn discover_weekly_is_only_artists_you_never_played() {
        let plays = vec![play("id-A-x", "A", NOW - DAY, true)];
        let profile = profile_with(&plays, NOW, &TagTable::default());
        let stats = play_stats(&plays, NOW);
        let ctx = PlanCtx { profile: &profile, now: NOW, stats: &stats };
        let pool = vec![cand("A", "x", Source::History), cand("A", "other", Source::Similar), cand("New", "n", Source::Similar), cand("Fresh", "f", Source::TagNeighbour)];
        let got = filter_pool(&PoolPlan::Unheard, pool, &ctx);
        let names: Vec<&str> = got.iter().map(|c| c.artist.as_str()).collect();
        assert_eq!(names, vec!["New", "Fresh"]);
    }

    #[test]
    fn release_radar_is_new_releases_of_artists_you_play() {
        let plays = vec![play("id-A-x", "A", NOW - DAY, true)];
        let profile = profile_with(&plays, NOW, &TagTable::default());
        let stats = play_stats(&plays, NOW);
        let ctx = PlanCtx { profile: &profile, now: NOW, stats: &stats };
        let pool = vec![cand("A", "New Album", Source::NewRelease), cand("Stranger", "Album", Source::NewRelease), cand("A", "x", Source::History)];
        let got = filter_pool(&PoolPlan::NewReleases, pool, &ctx);
        assert_eq!(got.len(), 1);
        assert_eq!(got.first().map(|c| c.title.as_str()), Some("New Album"));
    }

    #[test]
    fn rewind_is_old_favourites_not_recent_ones() {
        let mut plays = Vec::new();
        for i in 0..4 {
            plays.push(play("id-Old-song", "Old", NOW - (120 + i) * DAY, true));
            plays.push(play("id-Now-song", "Now", NOW - (i + 1) * DAY, true));
        }
        let profile = profile_with(&plays, NOW, &TagTable::default());
        let stats = play_stats(&plays, NOW);
        let ctx = PlanCtx { profile: &profile, now: NOW, stats: &stats };
        let pool = vec![cand("Old", "song", Source::History), cand("Now", "song", Source::History), cand("Nobody", "song", Source::Chart)];
        let got = filter_pool(&PoolPlan::Rewind, pool, &ctx);
        let names: Vec<&str> = got.iter().map(|c| c.artist.as_str()).collect();
        assert_eq!(names, vec!["Old"]);
    }

    #[test]
    fn a_daily_mix_is_its_own_cluster_and_close_neighbours() {
        let mut tags = TagTable::default();
        let mut plays = Vec::new();
        for (i, a) in ["lofi1", "lofi2", "lofi3", "lofi4", "lofi5"].iter().enumerate() {
            tags.insert(a, &[("lo-fi", 1.0), ("chillhop", 0.7)]);
            for k in 0..4 {
                plays.push(play(&format!("id-{a}-s"), a, NOW - ((i as u64) * 2 + k + 1) * DAY, true));
            }
        }
        for (i, a) in ["metal1", "metal2", "metal3", "metal4", "metal5"].iter().enumerate() {
            tags.insert(a, &[("metal", 1.0), ("thrash", 0.7)]);
            for k in 0..4 {
                plays.push(play(&format!("id-{a}-s"), a, NOW - ((i as u64) * 2 + k + 1) * DAY, true));
            }
        }
        let profile = profile_with(&plays, NOW, &tags);
        let lofi_cluster = profile.artist_cluster.get("lofi1").copied().expect("lofi1 is in a cluster");
        let metal_cluster = profile.artist_cluster.get("metal1").copied().expect("metal1 is in a cluster");
        assert_ne!(lofi_cluster, metal_cluster);
        let stats = play_stats(&plays, NOW);
        let ctx = PlanCtx { profile: &profile, now: NOW, stats: &stats };
        let pool = vec![
            cand("lofi1", "s", Source::History),
            cand("metal1", "s", Source::History),
            with_tags(cand("Newcomer", "n", Source::Similar), &[("lo-fi", 1.0), ("chillhop", 0.5)]),
            with_tags(cand("Elsewhere", "n", Source::Similar), &[("polka", 1.0)]),
            cand("Untagged", "n", Source::Similar),
        ];
        let got = filter_pool(&PoolPlan::Cluster(lofi_cluster), pool, &ctx);
        let names: Vec<&str> = got.iter().map(|c| c.artist.as_str()).collect();
        assert_eq!(names, vec!["lofi1", "Newcomer"]);
    }

    #[test]
    fn the_daylist_tag_follows_the_time_of_day() {
        let mut tags = TagTable::default();
        tags.insert("night owl", &[("synthwave", 1.0), ("seen live", 5.0)]);
        tags.insert("early bird", &[("acoustic", 1.0)]);
        let mut plays = Vec::new();
        // Weekday late-night (bucket 0) and weekday morning (bucket 1) listening, UTC. 2026-11-09 is a Monday.
        for k in 0..5u64 {
            plays.push(play("n", "night owl", NOW + k * DAY + 2 * 3600, true));
            plays.push(play("e", "early bird", NOW + k * DAY + 8 * 3600, true));
        }
        let profile = profile_with(&plays, NOW + 10 * DAY, &tags);
        assert_eq!(daylist_tag(&profile, &tags, 0).as_deref(), Some("synthwave"), "generic tags are ignored");
        assert_eq!(daylist_tag(&profile, &tags, 1).as_deref(), Some("acoustic"));
        assert_eq!(daylist_tag(&profile, &tags, 3), None, "nothing played on weekday evenings");
    }

    #[test]
    fn feedback_removes_blocked_songs_and_artists_from_the_pool() {
        let mut fb = Feedback::default();
        fb.block_track("id-A-x", "A", "x");
        fb.block_artist("Bad");
        let pool = vec![cand("A", "x", Source::History), cand("A", "y", Source::History), cand("Bad", "z", Source::Similar), cand("a", "X (Remastered)", Source::Chart)];
        let got = apply_feedback(pool, &fb);
        assert_eq!(got.iter().map(|c| c.title.as_str()).collect::<Vec<_>>(), vec!["y"]);
    }

    #[test]
    fn cold_start_makes_only_discover_and_daylist() {
        let cold = TasteProfile::default();
        let kinds: Vec<MixKind> = wanted_mixes(&cold, &[(1, 5)]).into_iter().map(|m| m.0).collect();
        assert_eq!(kinds, vec![MixKind::DiscoverWeekly, MixKind::Daylist]);
    }

    #[test]
    fn a_personal_profile_gets_every_kind() {
        let mut profile = TasteProfile::default();
        profile.plays_seen = 500;
        let all = wanted_mixes(&profile, &[(1, 10), (2, 20)]);
        let kinds: Vec<MixKind> = all.iter().map(|m| m.0).collect();
        assert_eq!(
            kinds,
            vec![MixKind::DailyMix, MixKind::DailyMix, MixKind::DiscoverWeekly, MixKind::ReleaseRadar, MixKind::OnRepeat, MixKind::RepeatRewind, MixKind::Daylist]
        );
        assert_eq!(all.first().map(|m| (m.1, m.2)), Some((1, Some(10))));
    }

    #[test]
    fn caps_never_let_an_artist_past_the_limit() {
        let mut r = result(vec![track("1", "A", "a"), track("2", "B", "b"), track("3", "A", "c"), track("4", "A", "d"), track("5", "B", "e"), track("6", "B", "f")]);
        enforce_caps(&mut r, 2, &Feedback::default());
        let ids: Vec<&str> = r.tracks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, vec!["1", "2", "3", "5"]);
        assert_eq!(r.reasons, vec!["r0", "r1", "r2", "r4"], "the parallel vectors stay in step");
        assert_eq!(r.origins, vec![0, 1, 2, 4]);
    }

    #[test]
    fn less_like_this_and_blocks_tighten_the_caps() {
        let mut fb = Feedback::default();
        fb.less_like("A");
        fb.block_artist("C");
        fb.block_track("5", "B", "e");
        let mut r = result(vec![track("1", "A", "a"), track("2", "B", "b"), track("3", "A", "c"), track("4", "C", "d"), track("5", "B", "e"), track("6", "B", "f")]);
        enforce_caps(&mut r, 2, &fb);
        let ids: Vec<&str> = r.tracks.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, vec!["1", "2", "6"]);
    }

    #[test]
    fn neighbours_by_the_same_artist_are_pulled_apart() {
        let mut r = result(vec![track("1", "A", "a"), track("2", "B", "b"), track("3", "B", "c"), track("4", "C", "d"), track("5", "A", "e")]);
        separate_neighbours(&mut r);
        for w in r.tracks.windows(2) {
            assert_ne!(artist_key(&w[0].artist), artist_key(&w[1].artist), "{:?}", r.tracks.iter().map(|t| &t.id).collect::<Vec<_>>());
        }
        assert_eq!(r.tracks.len(), 5);
        assert_eq!(r.reasons.len(), 5);
        let mut ids: Vec<&str> = r.tracks.iter().map(|t| t.id.as_str()).collect();
        ids.sort_unstable();
        assert_eq!(ids, vec!["1", "2", "3", "4", "5"], "nothing lost");
    }

    #[test]
    fn a_list_that_cannot_be_separated_is_left_alone() {
        let mut r = result(vec![track("1", "A", "a"), track("2", "A", "b")]);
        separate_neighbours(&mut r);
        assert_eq!(r.tracks.len(), 2);
    }

    fn own(n: usize) -> Vec<Track> {
        (0..n).map(|i| track(&format!("own{i}"), &format!("Artist{}", i % 7), &format!("Song{i}"))).collect()
    }

    fn sugg(n: usize) -> Vec<Track> {
        (0..n).map(|i| track(&format!("sg{i}"), &format!("New{i}"), &format!("Fresh{i}"))).collect()
    }

    #[test]
    fn smart_shuffle_puts_one_suggestion_after_every_third_song() {
        let out = smart_shuffle(&own(9), &sugg(10), 7, 3);
        assert_eq!(out.tracks.len(), 12);
        assert_eq!(out.suggested.len(), 3);
        for (i, t) in out.tracks.iter().enumerate() {
            let is_sugg = out.suggested.contains(&t.id);
            assert_eq!(is_sugg, i % 4 == 3, "position {i}: every fourth entry is a suggestion");
        }
        let mine: HashSet<&str> = out.tracks.iter().filter(|t| !out.suggested.contains(&t.id)).map(|t| t.id.as_str()).collect();
        assert_eq!(mine.len(), 9, "all of your songs are there, once");
    }

    #[test]
    fn smart_shuffle_is_repeatable_and_a_new_seed_reorders() {
        let a = smart_shuffle(&own(12), &sugg(6), 1, 3);
        let b = smart_shuffle(&own(12), &sugg(6), 1, 3);
        let c = smart_shuffle(&own(12), &sugg(6), 2, 3);
        assert_eq!(a, b);
        assert_ne!(a.tracks, c.tracks);
    }

    #[test]
    fn smart_shuffle_skips_suggestions_you_already_have_and_copes_with_few() {
        let mut s = sugg(2);
        s.insert(0, track("copy", "Artist0", "Song0"));
        s.insert(0, track("own1", "Whoever", "Else"));
        let out = smart_shuffle(&own(9), &s, 3, 3);
        assert!(!out.suggested.contains(&"copy".to_string()), "same song by name");
        assert!(!out.suggested.contains(&"own1".to_string()), "same id");
        assert_eq!(out.suggested.len(), 2, "only two usable suggestions for three slots");
        assert_eq!(smart_shuffle(&[], &sugg(3), 1, 3), Shuffled::default());
        let none = smart_shuffle(&own(6), &[], 1, 3);
        assert_eq!(none.tracks.len(), 6);
        assert!(none.suggested.is_empty());
    }

    #[test]
    fn a_suggestion_never_follows_a_song_by_its_own_artist() {
        let mine = vec![track("a1", "X", "1"), track("a2", "Y", "2"), track("a3", "Z", "3"), track("a4", "W", "4")];
        let s = vec![track("s1", "Z", "same artist as the third"), track("s2", "Q", "fine")];
        for seed in 0..20 {
            let out = smart_shuffle(&mine, &s, seed, 3);
            for w in out.tracks.windows(2) {
                if out.suggested.contains(&w[1].id) {
                    assert_ne!(artist_key(&w[0].artist), artist_key(&w[1].artist));
                }
            }
        }
    }

    #[test]
    fn the_radio_boost_prefers_the_seed_artist_and_similar_tags() {
        let seed = with_tags(cand("Seed", "s", Source::History), &[("jazz", 1.0)]);
        let same = cand("Seed", "other", Source::Similar);
        let close = with_tags(cand("Near", "n", Source::Similar), &[("jazz", 1.0)]);
        let far = with_tags(cand("Far", "f", Source::Similar), &[("metal", 1.0)]);
        assert!((seed_boost(&same, &seed) - 1.5).abs() < 1e-9);
        assert!(seed_boost(&close, &seed) > seed_boost(&far, &seed));
        assert_eq!(seed_boost(&far, &seed), 0.0);
    }

    fn scored_pool(n_artists: usize, per: usize) -> Vec<Candidate> {
        let mut v = Vec::new();
        for a in 0..n_artists {
            for k in 0..per {
                v.push(cand(&format!("Artist{a}"), &format!("Song{k}"), Source::Similar));
            }
        }
        v
    }

    fn pick_artists(pool: Vec<Candidate>, epoch: u64) -> Vec<String> {
        use crate::reco::bandit::shelf_seed;
        use crate::reco::rerank::{rerank, RerankCfg, Scored};
        let seed = shelf_seed("daily-mix-1", NOW, epoch);
        let scored: Vec<Scored> = pool.iter().enumerate().map(|(i, c)| Scored { cand: c.clone(), score: 5.0 - i as f64 * 0.01 + refresh_jitter(epoch, seed, &c.key()), unheard: true }).collect();
        let cfg = RerankCfg::shelf(20);
        let picks = rerank(&scored, &HashMap::new(), NOW, &cfg, "daily-mix-1", &Default::default(), shelf_seed("daily-mix-1", NOW, epoch));
        picks.iter().filter_map(|p| scored.get(p.index)).map(|s| s.cand.artist.clone()).collect()
    }

    #[test]
    fn not_my_taste_changes_the_next_rebuild() {
        let pool = scored_pool(12, 3);
        let before = pick_artists(pool.clone(), 0);
        assert!(before.iter().any(|a| a == "Artist0"), "the top artist is on the list at first");
        let mut fb = Feedback::default();
        fb.block_artist("Artist0");
        fb.block_track("none", "Artist1", "Song0");
        let after = pick_artists(apply_feedback(pool, &fb), 0);
        assert!(!after.iter().any(|a| a == "Artist0"), "a blocked artist is gone");
        assert_ne!(before, after);
    }

    #[test]
    fn a_rebuilt_list_never_passes_the_artist_cap_whatever_the_seed() {
        let pool = scored_pool(15, 6);
        for epoch in 0..30 {
            let artists = pick_artists(pool.clone(), epoch);
            let mut counts: HashMap<&str, usize> = HashMap::new();
            for a in &artists {
                *counts.entry(a.as_str()).or_insert(0) += 1;
            }
            assert!(counts.values().all(|n| *n <= 2), "epoch {epoch}: {counts:?}");
            assert!(artists.windows(2).all(|w| w[0] != w[1]), "epoch {epoch}: back to back");
        }
    }

    #[test]
    fn a_refresh_gives_a_different_list_but_the_same_day_gives_the_same_one() {
        let pool = scored_pool(15, 6);
        assert_eq!(pick_artists(pool.clone(), 0), pick_artists(pool.clone(), 0));
        assert!((1..10).any(|e| pick_artists(pool.clone(), e) != pick_artists(pool.clone(), 0)));
    }
}
