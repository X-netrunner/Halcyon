//! Part 4: taste model v2. Deterministic, no network, no LLM.
//!
//! What it knows, from the play log (completed plays) and the skip log (tracks left early):
//! - two time scales: SLOW (half-life about 60 days: what you always like) and FAST (about 3 days:
//!   what you like now), kept per artist and per track;
//! - behaviour labels from Part 3 (`eval::label_play`): finished or repeated adds, liked adds more,
//!   a skip subtracts;
//! - context: which part of the day and weekday/weekend an artist is played in;
//! - taste clusters: 4 to 8 groups of artists with similar tags (seeded k-means, so the same input
//!   always gives the same clusters), each with a stable id and a label from its top tags;
//! - staleness: an old love you stopped playing is a "comeback"; an artist you keep skipping is
//!   demoted.
//!
//! `TasteProfile::affinity` scores one item, `fingerprint` is the cache key the LLM layer needs.
//! `TasteV2` plugs the whole thing into the Part 3 harness (`halcyon-musicd --eval`).
//!
//! Artist tags come from outside (MusicBrainz / ListenBrainz / Deezer). They are cached in SQLite
//! (`Cache::put_artist_tags`) and read through [`TagTable`]. NOT built here: the fetcher. Confirm
//! the endpoints with `--probe` first (master plan, Part 4), then add it. An artist without tags is
//! neutral for clustering, never an error.

use crate::cache::PlayLogEntry;
use crate::eval::{label_play, Item, Label, Ranker, TrainCtx};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Path, PathBuf};

/// Half-lives, in days.
pub const SLOW_HALF_LIFE_DAYS: f64 = 60.0;
pub const FAST_HALF_LIFE_DAYS: f64 = 3.0;
/// Half-life of the "recent skip rate" (Part 5): how often you skip this artist lately.
pub const RECENT_HALF_LIFE_DAYS: f64 = 14.0;

/// What one play is worth, by label (Part 3 labels).
pub const W_STRONG: f64 = 2.5;
pub const W_POSITIVE: f64 = 1.0;
pub const W_WEAK_SKIP: f64 = -0.35;
pub const W_SKIP: f64 = -1.0;

/// How the two scales are mixed. Tuned on the three fixture listeners only (see CHANGELOG): the
/// fast scale leads, because "what I play this week" is what the next list should follow.
const W_SLOW: f64 = 0.1;
const W_FAST: f64 = 0.9;
/// Share of the per-track signal (a song you keep finishing, or one you keep skipping).
const W_TRACK: f64 = 0.1;
const TRACK_SKIPPED_PENALTY: f64 = 0.5;

/// An old love not played for this long is a comeback candidate.
pub const COMEBACK_AFTER_DAYS: u64 = 21;
const COMEBACK_BONUS: f64 = 0.12;
const DEMOTE_PENALTY: f64 = 0.3;
const TIME_SCALE: f64 = 0.6;
const TIME_CAP: f64 = 0.1;
const CLUSTER_BONUS: f64 = 0.1;

/// Day part (night, morning, afternoon, evening) times weekday/weekend.
pub const BUCKETS: usize = 8;

pub const MAX_CLUSTERS: usize = 8;
pub const MIN_CLUSTER_ARTISTS: usize = 4;
const CLUSTER_POOL: usize = 60;
const CLUSTER_MEMBERS_KEPT: usize = 20;
const CENTROID_TAGS_KEPT: usize = 12;
const KMEANS_ROUNDS: usize = 20;
const FINGERPRINT_ARTISTS: usize = 12;

/// Cached tags older than this are ignored (and should be fetched again).
pub const TAG_TTL_SECS: u64 = 90 * DAY;
const DAY: u64 = 86_400;

/// Where the profile is kept between runs.
pub fn default_path() -> PathBuf {
    halcyon_music_core::paths::state_dir().join("taste-v2.json")
}

/// The key under which an artist is stored: case and spacing do not matter.
pub fn artist_key(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

/// Day part and weekday/weekend of a moment. `tz_offset_secs` moves UTC to the listener's clock.
/// 0 to 3: night, morning, afternoon, evening on a weekday; 4 to 7: the same on Saturday/Sunday.
pub fn bucket_of(ts: u64, tz_offset_secs: i64) -> usize {
    let local = (ts as i64).saturating_add(tz_offset_secs).max(0) as u64;
    let hour = (local % DAY) / 3600;
    let day = local / DAY;
    // 1970-01-01 was a Thursday. Monday = 0.
    let weekday = (day + 3) % 7;
    let part = (hour / 6) as usize;
    part + if weekday >= 5 { 4 } else { 0 }
}

fn weight_of(l: Label) -> f64 {
    match l {
        Label::Strong => W_STRONG,
        Label::Positive => W_POSITIVE,
        Label::WeakSkip => W_WEAK_SKIP,
        Label::Skipped => W_SKIP,
    }
}

// ------------------------------------------------------------------ tags

/// Artist tags, from the SQLite cache. Unknown artist = no entry = neutral.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct TagTable {
    by_artist: BTreeMap<String, Vec<(String, f64)>>,
}

impl TagTable {
    /// Add or replace the tags of an artist. Tags are lower-cased and merged; at most 12 are kept.
    pub fn insert(&mut self, artist: &str, tags: &[(&str, f64)]) {
        let owned: Vec<(String, f64)> = tags.iter().map(|(t, w)| ((*t).to_string(), *w)).collect();
        self.insert_owned(artist, &owned);
    }

    fn insert_owned(&mut self, artist: &str, tags: &[(String, f64)]) {
        let mut merged: BTreeMap<String, f64> = BTreeMap::new();
        for (t, w) in tags {
            let name = t.trim().to_lowercase();
            if name.is_empty() || !w.is_finite() || *w <= 0.0 {
                continue;
            }
            *merged.entry(name).or_insert(0.0) += *w;
        }
        let mut v: Vec<(String, f64)> = merged.into_iter().collect();
        v.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(Ordering::Equal).then_with(|| a.0.cmp(&b.0)));
        v.truncate(CENTROID_TAGS_KEPT);
        if !v.is_empty() {
            self.by_artist.insert(artist_key(artist), v);
        }
    }

    pub fn get(&self, artist_key: &str) -> Option<&Vec<(String, f64)>> {
        self.by_artist.get(artist_key)
    }

    pub fn len(&self) -> usize {
        self.by_artist.len()
    }

    /// The artist keys that have tags, in order.
    pub fn keys(&self) -> Vec<String> {
        self.by_artist.keys().cloned().collect()
    }

    pub fn is_empty(&self) -> bool {
        self.by_artist.is_empty()
    }

    /// From `Cache::all_artist_tags`; rows older than [`TAG_TTL_SECS`] are dropped.
    pub fn from_rows(rows: Vec<(String, Vec<(String, f64)>, u64)>, now: u64) -> Self {
        let mut t = TagTable::default();
        for (key, tags, fetched_at) in rows {
            if now.saturating_sub(fetched_at) <= TAG_TTL_SECS {
                t.insert_owned(&key, &tags);
            }
        }
        t
    }
}

// ------------------------------------------------------------------ the profile

/// What is known about one artist or one track.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Signal {
    pub slow: f64,
    pub fast: f64,
    pub positives: u32,
    pub skips: u32,
    /// Unix seconds of the last positive play, 0 if none.
    pub last_positive: u64,
    /// Part 5: finished plays and skips with a 14-day half-life, so "you skipped this artist a lot
    /// two months ago" fades. Old saved profiles do not have them (they read as 0).
    #[serde(default)]
    pub recent_pos: f64,
    #[serde(default)]
    pub recent_skip: f64,
}

impl Signal {
    fn add(&mut self, w: f64, decay_slow: f64, decay_fast: f64, decay_recent: f64, at: u64) {
        self.slow += w * decay_slow;
        self.fast += w * decay_fast;
        if w > 0.0 {
            self.positives += 1;
            self.last_positive = self.last_positive.max(at);
            self.recent_pos += decay_recent;
        } else if w < 0.0 {
            self.skips += 1;
            // A weak skip (left late) counts for less than a skip.
            self.recent_skip += (-w).min(1.0) * decay_recent;
        }
    }
}

/// A group of artists with similar tags.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Cluster {
    /// Stable: a hash of the label, so the same kind of cluster keeps its id between rebuilds.
    pub id: u32,
    /// The top tags, for example "lo-fi, chillhop".
    pub label: String,
    /// Artist keys, heaviest first (at most 20 are listed).
    pub artists: Vec<String>,
    /// Share of your listening (all clusters add up to 1).
    pub share: f64,
    /// The tags that define it, strongest first.
    pub centroid: Vec<(String, f64)>,
}

/// The listener's taste at a moment.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct TasteProfile {
    pub built_at: u64,
    pub plays_seen: usize,
    pub artists: BTreeMap<String, Signal>,
    pub tracks: BTreeMap<String, Signal>,
    /// Positive weight per artist by [`bucket_of`].
    pub buckets: BTreeMap<String, [f64; BUCKETS]>,
    pub clusters: Vec<Cluster>,
    pub artist_cluster: BTreeMap<String, u32>,
    slow_max: f64,
    fast_max: f64,
    track_slow_max: f64,
    track_fast_max: f64,
}

/// A read-only summary of one artist for the Part 5 ranker.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct ArtistView {
    /// The listener has played (or skipped) this artist.
    pub known: bool,
    /// Slow and fast affinity, -1 to 1.
    pub slow: f64,
    pub fast: f64,
    /// Loved once, not played for [`COMEBACK_AFTER_DAYS`].
    pub comeback: bool,
    /// Share of recent plays of this artist that were skipped, 0 to 1 (about 14-day memory).
    pub skip_rate: f64,
    /// How much more this artist is played at the current time of day than evenly, -1 to 1.
    pub time_fit: f64,
    /// The artist belongs to one of the taste clusters.
    pub in_cluster: bool,
}

/// What the item is scored for.
#[derive(Debug, Clone, Copy)]
pub struct AffinityCtx {
    pub now: u64,
    /// The listener's current [`bucket_of`], or `None` to ignore the time of day.
    pub bucket: Option<usize>,
}

impl TasteProfile {
    /// Build the profile from the past. Plays after `now` are ignored. `tz_offset_secs` is the
    /// listener's UTC offset (0 = UTC).
    pub fn build(
        plays: &[PlayLogEntry],
        liked: &HashSet<String>,
        now: u64,
        tags: &TagTable,
        tz_offset_secs: i64,
    ) -> Self {
        let mut p = TasteProfile { built_at: now, ..Default::default() };
        for e in plays {
            if e.started_at > now {
                continue;
            }
            p.plays_seen += 1;
            let w = weight_of(label_play(e, liked));
            let age_days = (now - e.started_at) as f64 / DAY as f64;
            let ds = 0.5f64.powf(age_days / SLOW_HALF_LIFE_DAYS);
            let df = 0.5f64.powf(age_days / FAST_HALF_LIFE_DAYS);
            let dr = 0.5f64.powf(age_days / RECENT_HALF_LIFE_DAYS);
            let key = artist_key(&e.artist);
            p.artists.entry(key.clone()).or_default().add(w, ds, df, dr, e.started_at);
            p.tracks.entry(e.track_id.clone()).or_default().add(w, ds, df, dr, e.started_at);
            if w > 0.0 {
                let b = bucket_of(e.started_at, tz_offset_secs);
                let parts = p.buckets.entry(key).or_insert([0.0; BUCKETS]);
                if let Some(slot) = parts.get_mut(b) {
                    *slot += w * ds;
                }
            }
        }
        p.slow_max = p.artists.values().map(|s| s.slow).fold(1e-9, f64::max);
        p.fast_max = p.artists.values().map(|s| s.fast).fold(1e-9, f64::max);
        p.track_slow_max = p.tracks.values().map(|s| s.slow).fold(1e-9, f64::max);
        p.track_fast_max = p.tracks.values().map(|s| s.fast).fold(1e-9, f64::max);
        p.build_clusters(tags);
        p
    }

    /// True for an artist you loved, have not played for [`COMEBACK_AFTER_DAYS`], and did not skip.
    pub fn is_comeback(&self, artist: &str, now: u64) -> bool {
        match self.artists.get(&artist_key(artist)) {
            Some(a) => self.comeback(a, now),
            None => false,
        }
    }

    fn comeback(&self, a: &Signal, now: u64) -> bool {
        a.last_positive > 0
            && now.saturating_sub(a.last_positive) > COMEBACK_AFTER_DAYS * DAY
            && a.slow >= 0.3 * self.slow_max
            && a.skips <= a.positives / 4
    }

    /// How much this listener wants this item now. 0 = no opinion (an unknown artist), above 0 =
    /// wanted, below 0 = unwanted. Not bounded; only the order matters.
    pub fn affinity(&self, artist: &str, track_id: &str, ctx: &AffinityCtx) -> f64 {
        let key = artist_key(artist);
        let mut score = 0.0;
        if let Some(a) = self.artists.get(&key) {
            let s = (a.slow / self.slow_max).clamp(-1.0, 1.0);
            let f = (a.fast / self.fast_max).clamp(-1.0, 1.0);
            score += W_SLOW * s + W_FAST * f;
            if self.comeback(a, ctx.now) {
                score += COMEBACK_BONUS;
            }
            if a.skips >= 3 && a.skips > a.positives {
                score -= DEMOTE_PENALTY;
            }
            if let (Some(b), Some(parts)) = (ctx.bucket, self.buckets.get(&key)) {
                let total: f64 = parts.iter().sum();
                if total > 1e-9 {
                    if let Some(part) = parts.get(b) {
                        let share = part / total;
                        score += (TIME_SCALE * (share - 1.0 / BUCKETS as f64)).clamp(-TIME_CAP, TIME_CAP);
                    }
                }
            }
            if let Some(cid) = self.artist_cluster.get(&key) {
                if let Some(c) = self.clusters.iter().find(|c| c.id == *cid) {
                    score += CLUSTER_BONUS * c.share;
                }
            }
        }
        if let Some(t) = self.tracks.get(track_id) {
            let ts = (t.slow / self.track_slow_max).clamp(-1.0, 1.0);
            let tf = (t.fast / self.track_fast_max).clamp(-1.0, 1.0);
            score += W_TRACK * (0.5 * ts + 0.5 * tf);
            if t.skips > 0 && t.positives == 0 {
                score -= TRACK_SKIPPED_PENALTY;
            }
        }
        score
    }

    /// Part 5: what the profile knows about an artist, as plain numbers for the ranker. Every field
    /// is 0 for an artist the listener has not played (`known == false`).
    pub fn artist_view(&self, artist: &str, ctx: &AffinityCtx) -> ArtistView {
        let key = artist_key(artist);
        let mut v = ArtistView::default();
        let Some(a) = self.artists.get(&key) else {
            return v;
        };
        v.known = true;
        v.slow = (a.slow / self.slow_max).clamp(-1.0, 1.0);
        v.fast = (a.fast / self.fast_max).clamp(-1.0, 1.0);
        v.comeback = self.comeback(a, ctx.now);
        v.skip_rate = a.recent_skip / (a.recent_pos + a.recent_skip + 1.0);
        // Same rule as `affinity`'s demotion, so a hated artist is never rated better than before.
        if a.skips >= 3 && a.skips > a.positives {
            v.skip_rate = v.skip_rate.max(0.6);
        }
        if let (Some(b), Some(parts)) = (ctx.bucket, self.buckets.get(&key)) {
            let total: f64 = parts.iter().sum();
            if total > 1e-9 {
                if let Some(part) = parts.get(b) {
                    // 1/8 of the listening in this slot is "no preference" (0); all of it is 1.
                    v.time_fit = ((part / total - 1.0 / BUCKETS as f64) / (1.0 - 1.0 / BUCKETS as f64)).clamp(-1.0, 1.0);
                }
            }
        }
        v.in_cluster = self.artist_cluster.contains_key(&key);
        v
    }

    /// Part 5: the per-track signal in -1..=1 (a track you keep finishing is up, one you only ever
    /// skipped is at the bottom), and whether the track is known at all.
    pub fn track_view(&self, track_id: &str) -> (f64, bool) {
        let Some(t) = self.tracks.get(track_id) else {
            return (0.0, false);
        };
        let ts = (t.slow / self.track_slow_max).clamp(-1.0, 1.0);
        let tf = (t.fast / self.track_fast_max).clamp(-1.0, 1.0);
        let mut v = 0.5 * ts + 0.5 * tf;
        if t.skips > 0 && t.positives == 0 {
            v -= 1.0;
        }
        (v.clamp(-1.0, 1.0), true)
    }

    /// Part 5: the artists you like most right now, best first (slow and fast scale together), as
    /// stored keys. Used to pick seeds for "similar artists" and new releases.
    pub fn top_artists(&self, n: usize) -> Vec<String> {
        let mut ranked: Vec<(&String, f64)> = self
            .artists
            .iter()
            .map(|(k, s)| (k, s.slow.max(0.0) / self.slow_max + s.fast.max(0.0) / self.fast_max))
            .filter(|(_, w)| *w > 0.0)
            .collect();
        ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(Ordering::Equal).then_with(|| a.0.cmp(b.0)));
        ranked.into_iter().take(n).map(|(k, _)| k.clone()).collect()
    }

    /// Which cluster the given tags fit best, and how well (cosine, 0 to 1). `None` when there are
    /// no clusters or nothing fits. For artists the profile has not heard (Part 5 candidates).
    pub fn cluster_fit(&self, tags: &[(String, f64)]) -> Option<(u32, f64)> {
        let mut best: Option<(u32, f64)> = None;
        for c in &self.clusters {
            let sim = cosine(tags, &c.centroid);
            if sim > 0.0 && best.map_or(true, |(_, b)| sim > b) {
                best = Some((c.id, sim));
            }
        }
        best
    }

    /// A short stable text that changes when the taste really moves (a new top artist, a new
    /// cluster) and not when counts grow. The LLM layer's cache key.
    pub fn fingerprint(&self) -> String {
        let mut ranked: Vec<(&String, f64)> = self
            .artists
            .iter()
            .map(|(k, s)| (k, s.slow.max(0.0) / self.slow_max + s.fast.max(0.0) / self.fast_max))
            .filter(|(_, w)| *w > 0.0)
            .collect();
        ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(Ordering::Equal).then_with(|| a.0.cmp(b.0)));
        let mut text = String::new();
        for (k, _) in ranked.iter().take(FINGERPRINT_ARTISTS) {
            text.push_str(k);
            text.push('\n');
        }
        let ids: BTreeSet<u32> = self.clusters.iter().map(|c| c.id).collect();
        for id in ids {
            text.push_str(&format!("c{id}\n"));
        }
        format!("{:016x}", fnv64(text.as_bytes()))
    }

    // ------------------------------------------------------------ clusters

    fn build_clusters(&mut self, tags: &TagTable) {
        self.clusters.clear();
        self.artist_cluster.clear();
        // Artists you are into (or were) that have tags, heaviest first.
        let mut pool: Vec<(String, f64)> = self
            .artists
            .iter()
            .filter(|(k, s)| (s.slow > 0.0 || s.fast > 0.0) && tags.get(k.as_str()).is_some())
            .map(|(k, s)| {
                let w = s.slow.max(0.0) / self.slow_max + s.fast.max(0.0) / self.fast_max + 1e-6;
                (k.clone(), w)
            })
            .collect();
        pool.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(Ordering::Equal).then_with(|| a.0.cmp(&b.0)));
        pool.truncate(CLUSTER_POOL);
        if pool.len() < MIN_CLUSTER_ARTISTS {
            return;
        }

        let mut vocab: BTreeSet<&str> = BTreeSet::new();
        for (k, _) in &pool {
            if let Some(ts) = tags.get(k.as_str()) {
                for (t, _) in ts {
                    vocab.insert(t.as_str());
                }
            }
        }
        let vocab: Vec<&str> = vocab.into_iter().collect();
        let index: BTreeMap<&str, usize> = vocab.iter().enumerate().map(|(i, t)| (*t, i)).collect();
        let vecs: Vec<Vec<f64>> = pool
            .iter()
            .map(|(k, _)| {
                let mut v = vec![0.0; vocab.len()];
                if let Some(ts) = tags.get(k.as_str()) {
                    for (t, w) in ts {
                        if let Some(&i) = index.get(t.as_str()) {
                            if let Some(slot) = v.get_mut(i) {
                                *slot += *w;
                            }
                        }
                    }
                }
                normalise(&mut v);
                v
            })
            .collect();
        let weights: Vec<f64> = pool.iter().map(|(_, w)| *w).collect();
        let k = (pool.len() / 3).clamp(1, MAX_CLUSTERS);
        let assign = kmeans(&vecs, &weights, k);

        let mut used_ids: BTreeSet<u32> = BTreeSet::new();
        let mut built: Vec<(f64, Cluster, Vec<String>)> = Vec::new();
        for c in 0..k {
            let members: Vec<usize> = (0..pool.len()).filter(|&i| assign.get(i) == Some(&c)).collect();
            if members.is_empty() {
                continue;
            }
            let mut tag_score: Vec<f64> = vec![0.0; vocab.len()];
            let mut total = 0.0;
            for &i in &members {
                let w = weights.get(i).copied().unwrap_or(0.0);
                total += w;
                if let Some(v) = vecs.get(i) {
                    for (slot, x) in tag_score.iter_mut().zip(v.iter()) {
                        *slot += w * x;
                    }
                }
            }
            let mut ranked: Vec<(usize, f64)> =
                tag_score.iter().copied().enumerate().filter(|(_, s)| *s > 1e-12).collect();
            ranked.sort_by(|a, b| {
                b.1.partial_cmp(&a.1)
                    .unwrap_or(Ordering::Equal)
                    .then_with(|| vocab.get(a.0).cmp(&vocab.get(b.0)))
            });
            let names: Vec<&str> = ranked.iter().take(2).filter_map(|(i, _)| vocab.get(*i).copied()).collect();
            let label = if names.is_empty() { "mixed".to_string() } else { names.join(", ") };
            let mut id = fnv64(label.as_bytes()) as u32;
            while !used_ids.insert(id) {
                id = id.wrapping_add(1);
            }
            let centroid: Vec<(String, f64)> = ranked
                .iter()
                .take(CENTROID_TAGS_KEPT)
                .filter_map(|(i, s)| vocab.get(*i).map(|t| ((*t).to_string(), *s)))
                .collect();
            let mut member_keys: Vec<(String, f64)> =
                members.iter().filter_map(|&i| pool.get(i).cloned()).collect();
            member_keys.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(Ordering::Equal).then_with(|| a.0.cmp(&b.0)));
            let all_keys: Vec<String> = member_keys.iter().map(|(k, _)| k.clone()).collect();
            let listed: Vec<String> = all_keys.iter().take(CLUSTER_MEMBERS_KEPT).cloned().collect();
            built.push((total, Cluster { id, label, artists: listed, share: 0.0, centroid }, all_keys));
        }
        let grand: f64 = built.iter().map(|(t, _, _)| *t).sum();
        built.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(Ordering::Equal).then_with(|| a.1.id.cmp(&b.1.id)));
        for (total, mut cluster, all_keys) in built {
            cluster.share = if grand > 0.0 { total / grand } else { 0.0 };
            for key in all_keys {
                self.artist_cluster.insert(key, cluster.id);
            }
            self.clusters.push(cluster);
        }
    }

    // ------------------------------------------------------------ files

    /// Write atomically (temp file, then rename) so a crash never leaves half a profile.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_vec(self).map_err(|e| e.to_string())?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, &json).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, path).map_err(|e| e.to_string())
    }

    /// The saved profile. A missing file is the empty profile; a file that cannot be read is moved
    /// aside (`.corrupt`) and replaced by the empty profile. The flag says a recovery happened.
    pub fn load_or_default(path: &Path) -> (Self, bool) {
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(_) => return (TasteProfile::default(), false),
        };
        match serde_json::from_slice::<TasteProfile>(&bytes) {
            Ok(p) => (p, false),
            Err(_) => {
                let _ = std::fs::rename(path, path.with_extension("json.corrupt"));
                (TasteProfile::default(), true)
            }
        }
    }
}

// ------------------------------------------------------------------ the engine in the harness

/// Taste model v2 as a [`Ranker`], so `--eval` scores it next to the current engine.
pub struct TasteV2;

impl Ranker for TasteV2 {
    fn name(&self) -> &'static str {
        "taste v2 (fast + slow)"
    }

    fn scores(&self, ctx: &TrainCtx<'_>, items: &[Item]) -> Vec<f64> {
        let profile = TasteProfile::build(ctx.plays, ctx.liked, ctx.now, &TagTable::default(), 0);
        let actx = AffinityCtx { now: ctx.now, bucket: None };
        items.iter().map(|it| profile.affinity(&it.artist, &it.track_id, &actx)).collect()
    }
}

// ------------------------------------------------------------------ small maths

fn fnv64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= u64::from(*b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn normalise(v: &mut [f64]) {
    let n = v.iter().map(|x| x * x).sum::<f64>().sqrt();
    if n > 1e-12 {
        for x in v.iter_mut() {
            *x /= n;
        }
    }
}

fn dist_sq(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b.iter()).map(|(x, y)| (x - y) * (x - y)).sum()
}

fn cosine(a: &[(String, f64)], b: &[(String, f64)]) -> f64 {
    let bm: BTreeMap<&str, f64> = b.iter().map(|(t, w)| (t.as_str(), *w)).collect();
    let dot: f64 = a.iter().filter_map(|(t, w)| bm.get(t.as_str()).map(|x| w * x)).sum();
    let na = a.iter().map(|(_, w)| w * w).sum::<f64>().sqrt();
    let nb = b.iter().map(|(_, w)| w * w).sum::<f64>().sqrt();
    if na > 1e-12 && nb > 1e-12 {
        dot / (na * nb)
    } else {
        0.0
    }
}

/// Seeded k-means: the first centre is the heaviest artist, each next one the artist farthest from
/// the centres so far, then a fixed number of rounds. No randomness, so the result only depends
/// on the input. Returns the cluster index of every vector.
fn kmeans(vecs: &[Vec<f64>], weights: &[f64], k: usize) -> Vec<usize> {
    let n = vecs.len();
    if n == 0 || k == 0 {
        return Vec::new();
    }
    let dim = vecs.first().map_or(0, Vec::len);
    let mut first = 0usize;
    for i in 1..n {
        if weights.get(i).copied().unwrap_or(0.0) > weights.get(first).copied().unwrap_or(0.0) + 1e-12 {
            first = i;
        }
    }
    let mut centers: Vec<Vec<f64>> = vec![vecs.get(first).cloned().unwrap_or_default()];
    while centers.len() < k.min(n) {
        let mut best = 0usize;
        let mut best_d = -1.0f64;
        for (i, v) in vecs.iter().enumerate() {
            let d = centers.iter().map(|c| dist_sq(v, c)).fold(f64::MAX, f64::min);
            if d > best_d + 1e-12 {
                best_d = d;
                best = i;
            }
        }
        centers.push(vecs.get(best).cloned().unwrap_or_default());
    }
    let mut assign = vec![0usize; n];
    for _ in 0..KMEANS_ROUNDS {
        let mut changed = false;
        for (i, v) in vecs.iter().enumerate() {
            let mut best_c = 0usize;
            let mut best_d = f64::MAX;
            for (c, centre) in centers.iter().enumerate() {
                let d = dist_sq(v, centre);
                if d < best_d - 1e-12 {
                    best_d = d;
                    best_c = c;
                }
            }
            if assign.get(i) != Some(&best_c) {
                if let Some(slot) = assign.get_mut(i) {
                    *slot = best_c;
                }
                changed = true;
            }
        }
        for (c, centre) in centers.iter_mut().enumerate() {
            let mut sum = vec![0.0; dim];
            let mut total = 0.0;
            for (i, v) in vecs.iter().enumerate() {
                if assign.get(i) == Some(&c) {
                    let w = weights.get(i).copied().unwrap_or(0.0);
                    for (s, x) in sum.iter_mut().zip(v.iter()) {
                        *s += x * w;
                    }
                    total += w;
                }
            }
            if total > 0.0 {
                for s in sum.iter_mut() {
                    *s /= total;
                }
                *centre = sum;
            }
        }
        if !changed {
            break;
        }
    }
    assign
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::eval::{evaluate, fixture, CurrentEngine, Listener};

    const NOW: u64 = 1_800_000_000;

    fn play(id: i64, track: &str, artist: &str, days_ago: f64, ms: u64, done: bool) -> PlayLogEntry {
        PlayLogEntry {
            id,
            track_id: track.to_string(),
            title: "T".to_string(),
            artist: artist.to_string(),
            album: "A".to_string(),
            started_at: NOW - (days_ago * DAY as f64) as u64,
            ms_played: ms,
            completed: done,
        }
    }

    fn done(id: i64, track: &str, artist: &str, days_ago: f64) -> PlayLogEntry {
        play(id, track, artist, days_ago, 200_000, true)
    }

    fn skipped(id: i64, track: &str, artist: &str, days_ago: f64) -> PlayLogEntry {
        play(id, track, artist, days_ago, 4_000, false)
    }

    fn ctx() -> AffinityCtx {
        AffinityCtx { now: NOW, bucket: None }
    }

    fn build(plays: &[PlayLogEntry]) -> TasteProfile {
        TasteProfile::build(plays, &HashSet::new(), NOW, &TagTable::default(), 0)
    }

    #[test]
    fn fast_forgets_in_days_and_slow_in_months() {
        let p = build(&[done(1, "t", "Ash", 3.0)]);
        let a = p.artists.get("ash").unwrap_or_else(|| panic!("no artist"));
        assert!((a.fast - 0.5).abs() < 1e-9, "fast after one half-life: {}", a.fast);
        assert!(a.slow > 0.95, "slow barely moved: {}", a.slow);
        let old = build(&[done(1, "t", "Ash", 60.0)]);
        let a = old.artists.get("ash").unwrap_or_else(|| panic!("no artist"));
        assert!((a.slow - 0.5).abs() < 1e-9);
        assert!(a.fast < 1e-5);
    }

    #[test]
    fn plays_from_the_future_are_ignored() {
        let mut later = done(1, "t", "Ash", 1.0);
        later.started_at = NOW + 10;
        let p = build(&[later]);
        assert_eq!(p.plays_seen, 0);
        assert!(p.artists.is_empty());
    }

    #[test]
    fn a_skip_subtracts_and_a_skipped_artist_falls_below_an_unknown_one() {
        let liked_once = build(&[done(1, "a", "Ash", 1.0)]);
        let mixed = build(&[done(1, "a", "Ash", 1.0), skipped(2, "b", "Ash", 1.0), skipped(3, "c", "Ash", 1.0)]);
        assert!(mixed.affinity("Ash", "zz", &ctx()) < liked_once.affinity("Ash", "zz", &ctx()));
        let hated = build(&[skipped(1, "a", "Dust", 1.0), skipped(2, "b", "Dust", 1.0), skipped(3, "c", "Dust", 2.0), skipped(4, "d", "Dust", 2.0)]);
        assert!(hated.affinity("Dust", "zz", &ctx()) < 0.0, "worse than not knowing the artist");
        assert!(hated.affinity("Dust", "a", &ctx()) < hated.affinity("Dust", "zz", &ctx()), "a skipped song is lower still");
    }

    #[test]
    fn an_unknown_artist_has_no_opinion() {
        let p = build(&[done(1, "a", "Ash", 1.0)]);
        assert_eq!(p.affinity("Nobody", "never-heard", &ctx()), 0.0);
        let empty = TasteProfile::default();
        assert_eq!(empty.affinity("Ash", "a", &ctx()), 0.0);
        assert_eq!(empty.fingerprint(), TasteProfile::default().fingerprint());
    }

    #[test]
    fn what_you_play_now_beats_what_you_played_for_months() {
        // Ash every day from 60 to 15 days ago, then Dune every day for the last 6 days.
        let mut plays = Vec::new();
        let mut id = 0;
        for d in 15..=60 {
            id += 1;
            plays.push(done(id, "ash-1", "Ash", d as f64));
        }
        for d in 1..=6 {
            id += 1;
            plays.push(done(id, "dune-1", "Dune", d as f64));
        }
        let p = build(&plays);
        assert!(p.affinity("Dune", "x", &ctx()) > p.affinity("Ash", "y", &ctx()));
    }

    #[test]
    fn an_old_love_that_went_quiet_is_a_comeback_but_a_skipped_one_is_not() {
        let mut plays = Vec::new();
        for (i, d) in (40..=60).enumerate() {
            plays.push(done(i as i64, "ash-1", "Ash", d as f64));
        }
        // Someone you play now, so the old love is not simply the maximum.
        plays.push(done(100, "dune-1", "Dune", 1.0));
        let p = build(&plays);
        assert!(p.is_comeback("Ash", NOW));
        assert!(!p.is_comeback("Dune", NOW));
        assert!(!p.is_comeback("Nobody", NOW));
        let mut dropped = plays.clone();
        for i in 0..8 {
            dropped.push(skipped(200 + i, "ash-1", "Ash", 30.0 + i as f64));
        }
        assert!(!build(&dropped).is_comeback("Ash", NOW));
    }

    #[test]
    fn the_time_of_day_nudges_but_never_dominates() {
        // Always played at the same hour on a weekday.
        let mut plays = Vec::new();
        for d in 1..=10u64 {
            let mut p = done(d as i64, "a", "Ash", d as f64);
            p.started_at = NOW - d * DAY;
            plays.push(p);
        }
        let prof = build(&plays);
        let home = bucket_of(NOW - DAY, 0);
        let other = (home + 2) % BUCKETS;
        let at_home = prof.affinity("Ash", "zz", &AffinityCtx { now: NOW, bucket: Some(home) });
        let elsewhere = prof.affinity("Ash", "zz", &AffinityCtx { now: NOW, bucket: Some(other) });
        let neutral = prof.affinity("Ash", "zz", &ctx());
        assert!(at_home > neutral && neutral > elsewhere);
        assert!(at_home - elsewhere <= 2.0 * TIME_CAP + 1e-9);
    }

    #[test]
    fn day_parts_and_weekends() {
        // Friday 2027-01-15 08:00 UTC.
        assert_eq!(bucket_of(1_800_000_000, 0), 1);
        // The same moment in India (+5:30) is 13:30: afternoon.
        assert_eq!(bucket_of(1_800_000_000, 19_800), 2);
        // The next day is a Saturday.
        assert_eq!(bucket_of(1_800_000_000 + DAY, 0), 5);
        // Tuesday 22:13 UTC: evening on a weekday.
        assert_eq!(bucket_of(1_700_000_000, 0), 3);
        // A negative offset before 1970 does not underflow.
        assert!(bucket_of(0, -86_400) < BUCKETS);
    }

    fn tagged_history() -> (Vec<PlayLogEntry>, TagTable) {
        let mut tags = TagTable::default();
        let mut plays = Vec::new();
        let mut id = 0;
        for name in ["Mellow", "Dusk", "Haze", "Loom"] {
            tags.insert(name, &[("lo-fi", 1.0), ("chillhop", 0.8)]);
            for d in 1..=5 {
                id += 1;
                plays.push(done(id, &format!("{name}-1"), name, d as f64));
            }
        }
        for name in ["Anvil", "Forge", "Rust", "Steel"] {
            tags.insert(name, &[("thrash", 1.0), ("metal", 0.9)]);
            for d in 1..=5 {
                id += 1;
                plays.push(done(id, &format!("{name}-1"), name, d as f64));
            }
        }
        (plays, tags)
    }

    #[test]
    fn two_kinds_of_music_make_two_clusters_with_names() {
        let (plays, tags) = tagged_history();
        let p = TasteProfile::build(&plays, &HashSet::new(), NOW, &tags, 0);
        assert_eq!(p.clusters.len(), 2);
        let labels: Vec<&str> = p.clusters.iter().map(|c| c.label.as_str()).collect();
        assert!(labels.iter().any(|l| l.contains("lo-fi")), "{labels:?}");
        assert!(labels.iter().any(|l| l.contains("thrash")), "{labels:?}");
        let share: f64 = p.clusters.iter().map(|c| c.share).sum();
        assert!((share - 1.0).abs() < 1e-9);
        // Same cluster for the same kind of artist.
        assert_eq!(p.artist_cluster.get("mellow"), p.artist_cluster.get("haze"));
        assert_ne!(p.artist_cluster.get("mellow"), p.artist_cluster.get("anvil"));
        // Every member is somewhere.
        assert_eq!(p.artist_cluster.len(), 8);
    }

    #[test]
    fn clusters_are_deterministic_and_keep_their_ids() {
        let (plays, tags) = tagged_history();
        let a = TasteProfile::build(&plays, &HashSet::new(), NOW, &tags, 0);
        let b = TasteProfile::build(&plays, &HashSet::new(), NOW, &tags, 0);
        assert_eq!(a, b);
        // One more play of one artist: the same clusters keep the same ids.
        let mut more = plays.clone();
        more.push(done(999, "Mellow-1", "Mellow", 0.5));
        let c = TasteProfile::build(&more, &HashSet::new(), NOW, &tags, 0);
        let ids = |p: &TasteProfile| p.clusters.iter().map(|c| c.id).collect::<BTreeSet<u32>>();
        assert_eq!(ids(&a), ids(&c));
    }

    #[test]
    fn without_tags_or_with_too_few_artists_there_are_no_clusters_and_no_error() {
        let (plays, _) = tagged_history();
        let none = TasteProfile::build(&plays, &HashSet::new(), NOW, &TagTable::default(), 0);
        assert!(none.clusters.is_empty() && none.artist_cluster.is_empty());
        let mut few = TagTable::default();
        few.insert("Mellow", &[("lo-fi", 1.0)]);
        few.insert("Dusk", &[("lo-fi", 1.0)]);
        let p = TasteProfile::build(&plays, &HashSet::new(), NOW, &few, 0);
        assert!(p.clusters.is_empty());
        // Scoring still works.
        assert!(p.affinity("Mellow", "x", &ctx()) > 0.0);
    }

    #[test]
    fn a_new_artist_is_matched_to_the_closest_cluster() {
        let (plays, tags) = tagged_history();
        let p = TasteProfile::build(&plays, &HashSet::new(), NOW, &tags, 0);
        let metal = vec![("metal".to_string(), 1.0), ("doom".to_string(), 0.4)];
        let (id, sim) = p.cluster_fit(&metal).unwrap_or_else(|| panic!("no fit"));
        assert_eq!(Some(&id), p.artist_cluster.get("anvil"));
        assert!(sim > 0.5);
        assert!(p.cluster_fit(&[("opera".to_string(), 1.0)]).is_none());
    }

    #[test]
    fn tags_are_cleaned_and_expire() {
        let mut t = TagTable::default();
        t.insert("  Some   Artist ", &[(" Lo-Fi ", 1.0), ("lo-fi", 0.5), ("", 3.0), ("bad", f64::NAN), ("neg", -1.0)]);
        let got = t.get("some artist").unwrap_or_else(|| panic!("no tags"));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, "lo-fi");
        assert!((got[0].1 - 1.5).abs() < 1e-9);
        let rows = vec![
            ("fresh".to_string(), vec![("rock".to_string(), 1.0)], NOW - DAY),
            ("stale".to_string(), vec![("rock".to_string(), 1.0)], NOW - TAG_TTL_SECS - 1),
        ];
        let table = TagTable::from_rows(rows, NOW);
        assert!(table.get("fresh").is_some() && table.get("stale").is_none());
    }

    #[test]
    fn the_fingerprint_ignores_counts_but_notices_a_new_favourite() {
        let base = vec![done(1, "a", "Ash", 1.0), done(2, "a", "Ash", 2.0), done(3, "b", "Birch", 3.0)];
        let f0 = build(&base).fingerprint();
        let mut more = base.clone();
        more.push(done(4, "a", "Ash", 1.5));
        assert_eq!(build(&more).fingerprint(), f0, "one more play of the same favourite");
        let mut changed = base.clone();
        for i in 0..6 {
            changed.push(done(10 + i, "d", "Dune", 0.5));
        }
        assert_ne!(build(&changed).fingerprint(), f0);
        assert_eq!(f0.len(), 16);
    }

    #[test]
    fn the_profile_survives_a_restart_and_a_corrupt_file_is_moved_aside() {
        let dir = tempfile::tempdir().unwrap_or_else(|e| panic!("{e}"));
        let path = dir.path().join("state").join("taste-v2.json");
        let (plays, tags) = tagged_history();
        let p = TasteProfile::build(&plays, &HashSet::new(), NOW, &tags, 0);
        p.save(&path).unwrap_or_else(|e| panic!("{e}"));
        let (back, recovered) = TasteProfile::load_or_default(&path);
        assert!(!recovered);
        assert_eq!(back, p);
        // Missing file: empty, not a recovery.
        let (empty, recovered) = TasteProfile::load_or_default(&dir.path().join("nope.json"));
        assert!(!recovered && empty == TasteProfile::default());
        // Truncated file: recovered.
        std::fs::write(&path, b"{\"built_at\": 12, \"artists\": {").unwrap_or_else(|e| panic!("{e}"));
        let (rebuilt, recovered) = TasteProfile::load_or_default(&path);
        assert!(recovered && rebuilt == TasteProfile::default());
        assert!(path.with_extension("json.corrupt").exists());
        assert!(!path.exists());
    }

    #[test]
    fn five_thousand_plays_build_in_well_under_a_second() {
        let mut plays = Vec::new();
        for i in 0..5_000i64 {
            let artist = format!("Artist {}", i % 120);
            plays.push(done(i, &format!("t{}", i % 900), &artist, (i % 90) as f64 + 0.1));
        }
        let mut tags = TagTable::default();
        for a in 0..120 {
            let genre = format!("genre{}", a % 7);
            let mood = format!("mood{}", a % 5);
            tags.insert(&format!("Artist {a}"), &[(genre.as_str(), 1.0), (mood.as_str(), 0.5)]);
        }
        let t = std::time::Instant::now();
        let p = TasteProfile::build(&plays, &HashSet::new(), NOW, &tags, 0);
        assert!(t.elapsed() < std::time::Duration::from_secs(1), "{:?}", t.elapsed());
        assert!(!p.clusters.is_empty() && p.clusters.len() <= MAX_CLUSTERS);
    }

    #[test]
    fn it_beats_the_current_engine_on_a_listener_whose_taste_moved() {
        let (plays, liked) = fixture(Listener::Shift);
        let now = evaluate(&TasteV2, &plays, &liked).metrics;
        let before = evaluate(&CurrentEngine, &plays, &liked).metrics;
        let (r_now, r_before) = (now.recall_at_k.unwrap_or(0.0), before.recall_at_k.unwrap_or(1.0));
        assert!(r_now > r_before + 0.2, "recall {r_now:.3} against {r_before:.3}");
        assert!(now.skip_auc.unwrap_or(0.0) > 0.6, "skip auc {:?}", now.skip_auc);
    }

    #[test]
    fn it_is_not_worse_than_chance_on_the_steady_listeners() {
        for kind in [Listener::Narrow, Listener::Broad] {
            let (plays, liked) = fixture(kind);
            let m = evaluate(&TasteV2, &plays, &liked).metrics;
            assert!(m.skip_auc.unwrap_or(0.0) > 0.9, "{kind:?}: skip auc {:?}", m.skip_auc);
        }
    }
}
