//! Part 5, retrieve: many cheap sources, merged and de-duplicated.
//!
//! Every source runs alone: a source that fails, times out or is rate limited is recorded in the
//! report and the rest carry on. Nothing here needs the Spotify Web API. The candidates are NOT
//! matched on Spotify yet (that is the expensive step and only the winners get it, see `engine.rs`).
//!
//! Outside calls: Deezer (open), iTunes (open), ListenBrainz (open; collaborative recommendations
//! only with the opt-in). Results are kept in the cache's key-value table for hours, so a rebuild
//! right after another costs no requests. Endpoint shapes marked VERIFY come from memory and were
//! NOT checked against the live services (no network in the session that wrote this); run
//! `halcyon-musicd --reco-probe`.

use super::{Candidate, Phase, Source};
use crate::cache::Cache;
use crate::taste::{artist_key, TagTable, TasteProfile};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::collections::HashMap;
use std::future::Future;
use std::time::Duration;

/// One source may take this long before it is given up on.
pub const SOURCE_TIMEOUT: Duration = Duration::from_secs(25);
/// Pause between requests to the same service.
const POLITE_PAUSE: Duration = Duration::from_millis(150);
const SIMILAR_TTL: u64 = 12 * 3600;
const ALBUMS_TTL: u64 = 12 * 3600;
const LB_TTL: u64 = 6 * 3600;
/// A release older than this is not "new".
pub const NEW_RELEASE_DAYS: u64 = 120;
/// Tag neighbours must be at least this close to a taste cluster.
pub const NEIGHBOUR_MIN_SIM: f64 = 0.5;

#[derive(Debug, Clone)]
pub struct RetrieveCfg {
    /// Cap per source.
    pub per_source: usize,
    /// How many of your favourite artists seed similar-artist and new-release lookups.
    pub seed_artists: usize,
    /// ListenBrainz account for collaborative recommendations. `None` = the opt-in is off.
    pub listenbrainz: Option<ListenBrainzConfig>,
}

impl Default for RetrieveCfg {
    fn default() -> Self {
        RetrieveCfg { per_source: 80, seed_artists: 5, listenbrainz: None }
    }
}

/// The user's own ListenBrainz account. Collaborative recommendations are computed from the
/// listens that account has on ListenBrainz; nothing is sent to ListenBrainz by this code.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListenBrainzConfig {
    pub user: String,
}

/// `listenbrainz.json` in the state directory: `{"enabled": true, "user": "name"}`. Off unless
/// the file says otherwise. (The settings screen for it comes with Part 8.)
pub fn load_listenbrainz_config() -> Option<ListenBrainzConfig> {
    listenbrainz_config_in(&halcyon_music_core::paths::state_dir())
}

pub fn listenbrainz_config_in(dir: &std::path::Path) -> Option<ListenBrainzConfig> {
    #[derive(Deserialize)]
    struct File {
        #[serde(default)]
        enabled: bool,
        #[serde(default)]
        user: String,
    }
    let bytes = std::fs::read(dir.join("listenbrainz.json")).ok()?;
    let f: File = serde_json::from_slice(&bytes).ok()?;
    let user = f.user.trim().to_string();
    if f.enabled && !user.is_empty() {
        Some(ListenBrainzConfig { user })
    } else {
        None
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct SourceReport {
    pub source: Source,
    pub count: usize,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct Pool {
    pub candidates: Vec<Candidate>,
    pub reports: Vec<SourceReport>,
}

pub struct RetrieveEnv<'a> {
    pub cache: &'a Cache,
    pub http: &'a reqwest::Client,
    pub profile: &'a TasteProfile,
    pub tags: &'a TagTable,
    pub now: u64,
}

// ------------------------------------------------------------------ pure parts

/// Merge candidates that are the same song: sources are united (most trusted first), the Spotify
/// id and the first reason are kept, tags and popularity are filled in from whichever has them.
/// The order of first appearance is kept, so the result is deterministic.
pub fn merge(batches: Vec<Vec<Candidate>>) -> Vec<Candidate> {
    let mut out: Vec<Candidate> = Vec::new();
    let mut index: HashMap<String, usize> = HashMap::new();
    for c in batches.into_iter().flatten() {
        let key = c.key();
        match index.get(&key).copied().and_then(|i| out.get_mut(i)) {
            Some(have) => {
                for s in c.sources {
                    if !have.sources.contains(&s) {
                        have.sources.push(s);
                    }
                }
                if have.track_id.is_none() {
                    have.track_id = c.track_id;
                }
                if have.tags.is_empty() {
                    have.tags = c.tags;
                }
                have.popularity = match (have.popularity, c.popularity) {
                    (Some(a), Some(b)) => Some(a.max(b)),
                    (a, b) => a.or(b),
                };
                have.released = have.released.or(c.released);
                have.duration_ms = have.duration_ms.or(c.duration_ms);
                if have.because.is_none() {
                    have.because = c.because;
                }
            }
            None => {
                index.insert(key, out.len());
                out.push(c);
            }
        }
    }
    for c in &mut out {
        c.sources.sort_by(|a, b| b.trust().partial_cmp(&a.trust()).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.cmp(b)));
    }
    out
}

/// Keep only what the phase allows. A candidate offered by several sources stays if any of them is
/// allowed, and then only with the allowed ones.
pub fn gate(candidates: Vec<Candidate>, phase: Phase) -> Vec<Candidate> {
    candidates
        .into_iter()
        .filter_map(|mut c| {
            c.sources.retain(|s| phase.allows(*s));
            if c.sources.is_empty() {
                None
            } else {
                Some(c)
            }
        })
        .collect()
}

/// `YYYY-MM-DD` (or a longer ISO timestamp) to unix seconds at 00:00 UTC.
pub fn parse_iso_date(s: &str) -> Option<u64> {
    let head = s.get(..10)?;
    let mut parts = head.split('-');
    let y: i64 = parts.next()?.parse().ok()?;
    let m: i64 = parts.next()?.parse().ok()?;
    let d: i64 = parts.next()?.parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) || !(1970..=2200).contains(&y) {
        return None;
    }
    // days from civil (Howard Hinnant)
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    u64::try_from(days).ok().map(|d| d * 86_400)
}

/// Chart rows (best first) as candidates with a popularity from their position.
pub fn chart_candidates(rows: &[(String, String, Option<u64>)], source: Source, cap: usize) -> Vec<Candidate> {
    let n = rows.len().max(1) as f64;
    rows.iter()
        .take(cap)
        .enumerate()
        .map(|(i, (artist, title, dur))| {
            let mut c = Candidate::new(artist, title, source);
            c.duration_ms = *dur;
            if source == Source::Chart {
                c.popularity = Some(1.0 - i as f64 / n);
            }
            c
        })
        .collect()
}

/// ListenBrainz `cf/recommendation/user/<user>/recording` answer: the recording MBIDs with scores,
/// best first. VERIFY: shape from memory, `{"payload": {"mbids": [{"recording_mbid", "score"}]}}`.
pub fn parse_lb_recommendations(v: &serde_json::Value) -> Vec<(String, f64)> {
    v["payload"]["mbids"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|r| Some((r["recording_mbid"].as_str()?.to_string(), r["score"].as_f64().unwrap_or(0.0))))
                .collect()
        })
        .unwrap_or_default()
}

/// ListenBrainz `metadata/recording` answer for a set of MBIDs: `{mbid: {"recording": {"name"},
/// "artist": {"name"}}}`. VERIFY. Returns `(mbid, artist, title)`.
pub fn parse_lb_metadata(v: &serde_json::Value) -> Vec<(String, String, String)> {
    let Some(obj) = v.as_object() else { return Vec::new() };
    let mut rows: Vec<(String, String, String)> = obj
        .iter()
        .filter_map(|(mbid, m)| {
            let title = m["recording"]["name"].as_str()?.to_string();
            let artist = m["artist"]["name"].as_str()?.to_string();
            Some((mbid.clone(), artist, title))
        })
        .collect();
    rows.sort();
    rows
}

// ------------------------------------------------------------------ cached fetching

async fn cached<T, F, Fut>(cache: &Cache, key: &str, ttl: u64, fetch: F) -> Option<T>
where
    T: Serialize + DeserializeOwned,
    F: FnOnce() -> Fut,
    Fut: Future<Output = Option<T>>,
{
    if let Ok(Some(hit)) = cache.kv_get(key) {
        if !hit.is_stale {
            if let Ok(v) = serde_json::from_str::<T>(&hit.item) {
                return Some(v);
            }
        }
    }
    let fresh = fetch().await?;
    if let Ok(json) = serde_json::to_string(&fresh) {
        let _ = cache.kv_set(key, &json, ttl);
    }
    Some(fresh)
}

type Song = (String, String, Option<u64>);

async fn similar_songs(env: &RetrieveEnv<'_>, seed: &str) -> Vec<Song> {
    let key = format!("reco.similar.v1.{}", artist_key(seed));
    cached(env.cache, &key, SIMILAR_TTL, || async {
        let id = crate::suggestions::deezer_artist_id(env.http, seed).await?;
        let mut songs: Vec<Song> = Vec::new();
        for rid in crate::suggestions::deezer_related_artists(env.http, id, 6).await.into_iter().take(3) {
            tokio::time::sleep(POLITE_PAUSE).await;
            songs.extend(crate::suggestions::deezer_artist_top(env.http, rid, 3).await);
        }
        Some(songs)
    })
    .await
    .unwrap_or_default()
}

async fn recent_albums(env: &RetrieveEnv<'_>, seed: &str) -> Vec<(String, String, String)> {
    let key = format!("reco.albums.v1.{}", artist_key(seed));
    cached(env.cache, &key, ALBUMS_TTL, || async {
        let albums = crate::suggestions::fetch_itunes_artist_albums(env.http, seed).await;
        Some(albums.into_iter().map(|a| (a.artist, a.title, a.release_date)).collect::<Vec<_>>())
    })
    .await
    .unwrap_or_default()
}

async fn artist_top_songs(env: &RetrieveEnv<'_>, name: &str, want: u32) -> Vec<Song> {
    let key = format!("reco.top.v1.{}", artist_key(name));
    cached(env.cache, &key, SIMILAR_TTL, || async {
        let id = crate::suggestions::deezer_artist_id(env.http, name).await?;
        Some(crate::suggestions::deezer_artist_top(env.http, id, want).await)
    })
    .await
    .unwrap_or_default()
}

// ------------------------------------------------------------------ the sources

fn history_and_likes(env: &RetrieveEnv<'_>, cfg: &RetrieveCfg) -> (Vec<Candidate>, Vec<Candidate>) {
    let mut seen = std::collections::HashSet::new();
    let mut history = Vec::new();
    for p in env.cache.get_recent_plays(3_000).unwrap_or_default() {
        if seen.insert(p.track_id.clone()) {
            let mut c = Candidate::from_play(&p, Source::History);
            if let Some(t) = env.tags.get(&artist_key(&p.artist)) {
                c.tags = t.clone();
            }
            history.push(c);
            if history.len() >= cfg.per_source * 5 {
                break;
            }
        }
    }
    let mut liked = Vec::new();
    for t in env.cache.get_liked_tracks(cfg.per_source * 4, 0).map(|(t, _)| t).unwrap_or_default() {
        let mut c = Candidate::new(&t.artist, &t.title, Source::Liked);
        c.track_id = Some(t.id);
        c.duration_ms = Some(t.duration_ms);
        if let Some(tags) = env.tags.get(&artist_key(&t.artist)) {
            c.tags = tags.clone();
        }
        liked.push(c);
    }
    (history, liked)
}

async fn similar_source(env: &RetrieveEnv<'_>, cfg: &RetrieveCfg) -> Vec<Candidate> {
    let mut out = Vec::new();
    for seed in env.profile.top_artists(cfg.seed_artists) {
        for (artist, title, dur) in similar_songs(env, &seed).await {
            let mut c = Candidate::new(&artist, &title, Source::Similar);
            c.duration_ms = dur;
            c.because = Some(format!("Because you play {seed}"));
            out.push(c);
        }
        tokio::time::sleep(POLITE_PAUSE).await;
        if out.len() >= cfg.per_source {
            break;
        }
    }
    out.truncate(cfg.per_source);
    out
}

async fn new_release_source(env: &RetrieveEnv<'_>, cfg: &RetrieveCfg) -> Vec<Candidate> {
    let cutoff = env.now.saturating_sub(NEW_RELEASE_DAYS * 86_400);
    let mut out = Vec::new();
    for seed in env.profile.top_artists(cfg.seed_artists + 1) {
        for (artist, title, date) in recent_albums(env, &seed).await {
            let Some(released) = parse_iso_date(&date) else { continue };
            if released < cutoff || released > env.now + 7 * 86_400 {
                continue;
            }
            let mut c = Candidate::new(&artist, &title, Source::NewRelease);
            c.is_album = true;
            c.released = Some(released);
            c.because = Some(format!("New from {artist}"));
            out.push(c);
        }
        tokio::time::sleep(POLITE_PAUSE).await;
    }
    out.truncate(cfg.per_source);
    out
}

/// Unheard artists whose cached tags are close to a taste cluster, with their best songs.
async fn tag_neighbour_source(env: &RetrieveEnv<'_>, cfg: &RetrieveCfg) -> Vec<Candidate> {
    let mut ranked: Vec<(String, f64, String)> = Vec::new();
    for key in env.tags.keys() {
        if env.profile.artists.contains_key(&key) {
            continue;
        }
        let Some(tags) = env.tags.get(&key) else { continue };
        if let Some((cid, sim)) = env.profile.cluster_fit(tags) {
            if sim >= NEIGHBOUR_MIN_SIM {
                let label = env.profile.clusters.iter().find(|c| c.id == cid).map(|c| c.label.clone()).unwrap_or_default();
                ranked.push((key, sim, label));
            }
        }
    }
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then_with(|| a.0.cmp(&b.0)));
    let mut out = Vec::new();
    for (key, _, label) in ranked.into_iter().take(8) {
        for (artist, title, dur) in artist_top_songs(env, &key, 3).await.into_iter().take(2) {
            let mut c = Candidate::new(&artist, &title, Source::TagNeighbour);
            c.duration_ms = dur;
            if let Some(t) = env.tags.get(&key) {
                c.tags = t.clone();
            }
            if !label.is_empty() {
                c.because = Some(format!("Sounds like your {label}"));
            }
            out.push(c);
        }
        tokio::time::sleep(POLITE_PAUSE).await;
    }
    out.truncate(cfg.per_source);
    out
}

async fn listenbrainz_source(env: &RetrieveEnv<'_>, cfg: &RetrieveCfg, lb: &ListenBrainzConfig) -> Result<Vec<Candidate>, String> {
    let key = format!("reco.lb.v1.{}", lb.user.to_lowercase());
    let songs: Vec<Song> = cached(env.cache, &key, LB_TTL, || async {
        let url = format!("https://api.listenbrainz.org/1/cf/recommendation/user/{}/recording", lb.user);
        let res = env.http.get(url).query(&[("count", "50")]).timeout(Duration::from_secs(8)).send().await.ok()?;
        if !res.status().is_success() {
            return None;
        }
        let recs = parse_lb_recommendations(&res.json::<serde_json::Value>().await.ok()?);
        if recs.is_empty() {
            return Some(Vec::new());
        }
        let ids: Vec<String> = recs.iter().take(50).map(|(m, _)| m.clone()).collect();
        let meta = env
            .http
            .get("https://api.listenbrainz.org/1/metadata/recording/")
            .query(&[("recording_mbids", ids.join(",")), ("inc", "artist".to_string())])
            .timeout(Duration::from_secs(8))
            .send()
            .await
            .ok()?;
        if !meta.status().is_success() {
            return None;
        }
        let rows = parse_lb_metadata(&meta.json::<serde_json::Value>().await.ok()?);
        let by_mbid: HashMap<String, (String, String)> = rows.into_iter().map(|(m, a, t)| (m, (a, t))).collect();
        Some(
            recs.iter()
                .filter_map(|(m, _)| by_mbid.get(m).map(|(a, t)| (a.clone(), t.clone(), None)))
                .collect::<Vec<Song>>(),
        )
    })
    .await
    .ok_or_else(|| "ListenBrainz did not answer".to_string())?;
    let mut out: Vec<Candidate> = songs
        .into_iter()
        .map(|(a, t, d)| {
            let mut c = Candidate::new(&a, &t, Source::ListenBrainz);
            c.duration_ms = d;
            c.because = Some("Listeners like you play this".to_string());
            c
        })
        .collect();
    out.truncate(cfg.per_source);
    Ok(out)
}

/// Run one source with a time limit; an error or a timeout becomes a report line.
async fn guarded<F>(source: Source, fut: F, reports: &mut Vec<SourceReport>) -> Vec<Candidate>
where
    F: Future<Output = Result<Vec<Candidate>, String>>,
{
    match tokio::time::timeout(SOURCE_TIMEOUT, fut).await {
        Ok(Ok(v)) => {
            reports.push(SourceReport { source, count: v.len(), error: None });
            v
        }
        Ok(Err(e)) => {
            reports.push(SourceReport { source, count: 0, error: Some(e) });
            Vec::new()
        }
        Err(_) => {
            reports.push(SourceReport { source, count: 0, error: Some("timed out".to_string()) });
            Vec::new()
        }
    }
}

/// Gather the candidates the phase allows. Never fails: a source that does not answer is reported
/// and skipped.
pub async fn gather(env: &RetrieveEnv<'_>, cfg: &RetrieveCfg, phase: Phase) -> Pool {
    let mut reports = Vec::new();
    let mut batches: Vec<Vec<Candidate>> = Vec::new();

    if phase.allows(Source::History) {
        let (h, l) = history_and_likes(env, cfg);
        reports.push(SourceReport { source: Source::History, count: h.len(), error: None });
        reports.push(SourceReport { source: Source::Liked, count: l.len(), error: None });
        batches.push(h);
        batches.push(l);
        batches.push(guarded(Source::Similar, async { Ok(similar_source(env, cfg).await) }, &mut reports).await);
        batches.push(guarded(Source::NewRelease, async { Ok(new_release_source(env, cfg).await) }, &mut reports).await);
        batches.push(guarded(Source::TagNeighbour, async { Ok(tag_neighbour_source(env, cfg).await) }, &mut reports).await);
        if let Some(lb) = &cfg.listenbrainz {
            batches.push(guarded(Source::ListenBrainz, listenbrainz_source(env, cfg, lb), &mut reports).await);
        }
    }
    batches.push(
        guarded(
            Source::Chart,
            async {
                let rows = crate::suggestions::fetch_chart_pool(env.http).await;
                if rows.is_empty() {
                    Err("no chart answered".to_string())
                } else {
                    Ok(chart_candidates(&rows, Source::Chart, cfg.per_source * 2))
                }
            },
            &mut reports,
        )
        .await,
    );
    batches.push(
        guarded(
            Source::Editorial,
            async { Ok(chart_candidates(&crate::suggestions::all_time_candidates(), Source::Editorial, cfg.per_source)) },
            &mut reports,
        )
        .await,
    );
    Pool { candidates: gate(merge(batches), phase), reports }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(artist: &str, title: &str, source: Source) -> Candidate {
        Candidate::new(artist, title, source)
    }

    #[test]
    fn merge_unites_sources_and_keeps_what_is_known() {
        let mut chart = c("Daft Punk", "Get Lucky", Source::Chart);
        chart.popularity = Some(0.9);
        let mut hist = c("daft punk", "Get Lucky (Radio Edit)", Source::History);
        hist.track_id = Some("sp1".into());
        hist.tags = vec![("electronic".into(), 1.0)];
        let other = c("Someone", "Else", Source::Similar);
        let out = merge(vec![vec![chart, other], vec![hist]]);
        assert_eq!(out.len(), 2);
        let m = &out[0];
        assert_eq!(m.sources, vec![Source::History, Source::Chart], "most trusted first");
        assert_eq!(m.track_id.as_deref(), Some("sp1"));
        assert_eq!(m.popularity, Some(0.9));
        assert_eq!(m.tags.len(), 1);
    }

    #[test]
    fn merge_keeps_first_appearance_order_and_the_first_reason() {
        let mut a = c("A", "1", Source::Similar);
        a.because = Some("first".into());
        let mut a2 = c("A", "1", Source::Chart);
        a2.because = Some("second".into());
        let out = merge(vec![vec![c("Z", "z", Source::Chart), a], vec![a2, c("Y", "y", Source::Chart)]]);
        let names: Vec<&str> = out.iter().map(|x| x.artist.as_str()).collect();
        assert_eq!(names, vec!["Z", "A", "Y"]);
        assert_eq!(out[1].because.as_deref(), Some("first"));
    }

    #[test]
    fn a_song_and_an_album_of_the_same_name_stay_apart() {
        let song = c("A", "Same", Source::Similar);
        let mut album = c("A", "Same", Source::NewRelease);
        album.is_album = true;
        assert_eq!(merge(vec![vec![song, album]]).len(), 2);
    }

    #[test]
    fn cold_start_keeps_only_charts_and_editorial() {
        let mut both = c("A", "1", Source::History);
        both.sources.push(Source::Chart);
        let pool = vec![both, c("B", "2", Source::Similar), c("C", "3", Source::Editorial), c("D", "4", Source::ListenBrainz)];
        let cold = gate(pool.clone(), Phase::ColdStart);
        let names: Vec<&str> = cold.iter().map(|x| x.artist.as_str()).collect();
        assert_eq!(names, vec!["A", "C"]);
        assert_eq!(cold[0].sources, vec![Source::Chart], "the personal source is dropped from a shared candidate");
        assert_eq!(gate(pool, Phase::Personal).len(), 4);
    }

    #[test]
    fn dates_parse_to_unix_midnight_and_bad_ones_to_none() {
        assert_eq!(parse_iso_date("1970-01-01"), Some(0));
        assert_eq!(parse_iso_date("2000-03-01"), Some(951_868_800));
        assert_eq!(parse_iso_date("2026-10-30T07:00:00Z"), parse_iso_date("2026-10-30"));
        assert_eq!(parse_iso_date("2027"), None);
        assert_eq!(parse_iso_date("not-a-date"), None);
        assert_eq!(parse_iso_date("2026-13-01"), None);
        assert_eq!(parse_iso_date("1960-01-01"), None);
        assert_eq!(parse_iso_date("2024-02-29").map(|t| t / 86_400), Some(19_782));
    }

    #[test]
    fn chart_rows_get_a_popularity_from_their_place() {
        let rows: Vec<(String, String, Option<u64>)> = (0..4).map(|i| (format!("A{i}"), format!("T{i}"), Some(200_000))).collect();
        let chart = chart_candidates(&rows, Source::Chart, 3);
        assert_eq!(chart.len(), 3);
        assert_eq!(chart[0].popularity, Some(1.0));
        assert!(chart[2].popularity.is_some_and(|p| p < chart[1].popularity.unwrap_or(0.0)));
        let ed = chart_candidates(&rows, Source::Editorial, 10);
        assert!(ed.iter().all(|c| c.popularity.is_none()));
    }

    #[test]
    fn listenbrainz_answers_parse_and_broken_ones_do_not_panic() {
        let recs = serde_json::json!({"payload": {"mbids": [
            {"recording_mbid": "m1", "score": 0.9}, {"recording_mbid": "m2", "score": 0.5}, {"nope": 1}]}});
        assert_eq!(parse_lb_recommendations(&recs), vec![("m1".to_string(), 0.9), ("m2".to_string(), 0.5)]);
        assert!(parse_lb_recommendations(&serde_json::json!({"error": "x"})).is_empty());
        let meta = serde_json::json!({"m1": {"recording": {"name": "Song"}, "artist": {"name": "Band"}}, "m2": {"recording": {}}});
        assert_eq!(parse_lb_metadata(&meta), vec![("m1".to_string(), "Band".to_string(), "Song".to_string())]);
        assert!(parse_lb_metadata(&serde_json::json!([1, 2])).is_empty());
    }

    #[test]
    fn the_listenbrainz_opt_in_is_off_unless_the_file_turns_it_on() {
        let dir = tempfile::tempdir().expect("tempdir");
        assert_eq!(listenbrainz_config_in(dir.path()), None, "no file: off");
        let file = dir.path().join("listenbrainz.json");
        std::fs::write(&file, r#"{"enabled": true, "user": " me "}"#).expect("write");
        assert_eq!(listenbrainz_config_in(dir.path()), Some(ListenBrainzConfig { user: "me".into() }));
        std::fs::write(&file, r#"{"enabled": false, "user": "me"}"#).expect("write");
        assert_eq!(listenbrainz_config_in(dir.path()), None);
        std::fs::write(&file, r#"{"enabled": true, "user": "  "}"#).expect("write");
        assert_eq!(listenbrainz_config_in(dir.path()), None, "no user name: off");
        std::fs::write(&file, b"nonsense").expect("write");
        assert_eq!(listenbrainz_config_in(dir.path()), None);
    }

    #[tokio::test]
    async fn a_failing_source_is_reported_and_does_not_stop_the_others() {
        let mut reports = Vec::new();
        let bad = guarded(Source::Similar, async { Err::<Vec<Candidate>, String>("boom".into()) }, &mut reports).await;
        let good = guarded(Source::Chart, async { Ok(vec![c("A", "1", Source::Chart)]) }, &mut reports).await;
        assert!(bad.is_empty() && good.len() == 1);
        assert_eq!(reports[0].error.as_deref(), Some("boom"));
        assert_eq!(reports[1], SourceReport { source: Source::Chart, count: 1, error: None });
    }
}
