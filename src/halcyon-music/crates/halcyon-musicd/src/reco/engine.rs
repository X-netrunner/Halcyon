//! Part 5: the pieces put together.
//!
//! - [`Part5Ranker`] and [`Part5Pipeline`]: the engine as `--eval` rankers (offline, no network).
//! - [`build_shelf`]: retrieve, rank, rerank and match on Spotify, for one list.
//! - [`learner_loop`]: the daemon task that keeps the online model and the exploration beliefs
//!   up to date with new plays and skips.
//! - [`explain`]: the debug view for `halcyon-musicd --reco-explain`.

use super::bandit::shelf_seed;
use super::features::{explain_text, extract, is_unheard, FeatureCtx, Features};
use super::model::{catch_up, default_path, RecoState, ReplayCfg};
use super::rerank::{recent_map, rerank, Pick, RerankCfg, Scored};
use super::retrieve::{gather, load_listenbrainz_config, Pool, RetrieveCfg, RetrieveEnv, SourceReport};
use super::tags::{ensure_tags, TAGS_PER_BUILD};
use super::{phase_for, Candidate, Phase, Source};
use crate::api::SpotifyClient;
use crate::cache::{Cache, PlayLogEntry};
use crate::eval::{Item, Ranker, TrainCtx, K};
use crate::taste::{bucket_of, TagTable, TasteProfile};
use crate::token_store::now_secs;
use halcyon_music_core::models::Track;
use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

// ------------------------------------------------------------------ in the evaluation harness

fn eval_candidates(items: &[Item]) -> Vec<Candidate> {
    items
        .iter()
        .map(|it| Candidate { artist: it.artist.clone(), track_id: Some(it.track_id.clone()), sources: vec![Source::History], ..Default::default() })
        .collect()
}

/// The feature ranker with the online model trained by replaying the days before the test day.
/// No reranking: this row isolates what the features and the model add over Part 4.
pub struct Part5Ranker;

/// [`Part5Ranker`] plus the reranker (`RerankCfg::eval`): what the whole pipeline puts in a list.
pub struct Part5Pipeline;

fn rank_scores(ctx: &TrainCtx<'_>, items: &[Item]) -> (Vec<Candidate>, Vec<f64>, TasteProfile) {
    let tags = TagTable::default();
    let profile = TasteProfile::build(ctx.plays, ctx.liked, ctx.now, &tags, 0);
    let mut model = super::model::OnlineModel::prior();
    model.train_replay(ctx.plays, ctx.liked, ctx.now, &tags, &ReplayCfg::eval());
    let fctx = FeatureCtx { now: ctx.now, bucket: None };
    let cands = eval_candidates(items);
    let raw: Vec<f64> = cands.iter().map(|c| model.logit(&extract(c, &profile, &fctx))).collect();
    (cands, raw, profile)
}

impl Ranker for Part5Ranker {
    fn name(&self) -> &'static str {
        "part 5 ranker (features + online model)"
    }

    fn scores(&self, ctx: &TrainCtx<'_>, items: &[Item]) -> Vec<f64> {
        rank_scores(ctx, items).1
    }
}

/// Scores that make the harness's sort reproduce `picks`: the picked songs above everything else,
/// in pick order; the rest keep their rank score.
pub fn picks_to_scores(raw: &[f64], picks: &[Pick]) -> Vec<f64> {
    let top = raw.iter().copied().fold(f64::MIN, f64::max).max(0.0) + 10.0;
    let mut out = raw.to_vec();
    let n = picks.len() as f64;
    for (pos, p) in picks.iter().enumerate() {
        if let Some(slot) = out.get_mut(p.index) {
            *slot = top + (n - pos as f64);
        }
    }
    out
}

impl Ranker for Part5Pipeline {
    fn name(&self) -> &'static str {
        "part 5 pipeline (ranker + rerank)"
    }

    fn scores(&self, ctx: &TrainCtx<'_>, items: &[Item]) -> Vec<f64> {
        let (cands, raw, profile) = rank_scores(ctx, items);
        let scored: Vec<Scored> = cands
            .into_iter()
            .zip(raw.iter())
            .map(|(cand, score)| {
                let unheard = is_unheard(&cand, &profile);
                Scored { cand, score: *score, unheard }
            })
            .collect();
        let picks = rerank(&scored, &Default::default(), ctx.now, &RerankCfg::eval(K), "eval", &Default::default(), 0);
        picks_to_scores(&raw, &picks)
    }
}

// ------------------------------------------------------------------ one list

/// What a list is.
#[derive(Debug, Clone)]
pub struct ShelfSpec {
    /// Stable id: it keys the exploration beliefs and the seed.
    pub id: String,
    /// How many songs.
    pub n: usize,
    pub rerank: RerankCfg,
    /// Bump to ask for a fresh list today (the "Refresh" button).
    pub epoch: u64,
}

impl ShelfSpec {
    pub fn shelf(id: &str, n: usize) -> Self {
        ShelfSpec { id: id.to_string(), n, rerank: RerankCfg::shelf(n), epoch: 0 }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ShelfResult {
    pub tracks: Vec<Track>,
    /// One line per track: why it is there.
    pub reasons: Vec<String>,
    /// Which tracks are exploration slots.
    pub explore: Vec<bool>,
    /// Position of each track in the reranker's pick list (for the exploration bookkeeping).
    pub origins: Vec<usize>,
    pub reports: Vec<SourceReport>,
    pub phase: Option<PhaseTag>,
    /// How many uncached Spotify lookups were still needed (0 = a rebuild from caches only).
    pub lookups_used: usize,
}

/// `Phase` without the dependency on its derive set, for printing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhaseTag {
    ColdStart,
    Personal,
}

impl From<Phase> for PhaseTag {
    fn from(p: Phase) -> Self {
        match p {
            Phase::ColdStart => PhaseTag::ColdStart,
            Phase::Personal => PhaseTag::Personal,
        }
    }
}

/// Uncached Spotify searches one list may start (the existing budget also applies).
const LOOKUPS_PER_SHELF: u32 = 24;
/// Ask the reranker for this many times the wanted length, because not every pick is on Spotify.
const OVERSHOOT_NUM: usize = 3;
const OVERSHOOT_DEN: usize = 2;

pub struct History {
    pub plays: Vec<PlayLogEntry>,
    pub skips: Vec<PlayLogEntry>,
    pub liked: HashSet<String>,
}

pub fn load_history(cache: &Cache) -> History {
    History {
        plays: cache.get_recent_plays(1_000_000).unwrap_or_default(),
        skips: cache.get_skips(1_000_000).unwrap_or_default(),
        liked: cache.get_liked_tracks(100_000, 0).map(|(t, _)| t.into_iter().map(|t| t.id).collect()).unwrap_or_default(),
    }
}

pub fn tag_table(cache: &Cache, now: u64) -> TagTable {
    TagTable::from_rows(cache.all_artist_tags().unwrap_or_default(), now)
}

impl History {
    pub fn merged(&self) -> Vec<PlayLogEntry> {
        let mut all = self.plays.clone();
        all.extend(self.skips.iter().cloned());
        all
    }
}

/// Score candidates with the current model.
pub fn score_pool(pool: &[Candidate], profile: &TasteProfile, state: &RecoState, now: u64, bucket: Option<usize>) -> Vec<Scored> {
    let ctx = FeatureCtx { now, bucket };
    pool.iter()
        .map(|c| {
            let f: Features = extract(c, profile, &ctx);
            Scored { cand: c.clone(), score: state.model.logit(&f), unheard: is_unheard(c, profile) }
        })
        .collect()
}

/// Build one list. Never fails: a source that does not answer is in `reports`, a pick that cannot
/// be matched on Spotify is skipped, and with nothing at all the result is empty.
pub async fn build_shelf(
    spotify: &SpotifyClient,
    cache: &Cache,
    http: &reqwest::Client,
    spec: &ShelfSpec,
    tz_offset_secs: i64,
) -> ShelfResult {
    let now = now_secs();
    let history = load_history(cache);
    let mut tags = tag_table(cache, now);
    let merged = history.merged();
    let profile = TasteProfile::build(&merged, &history.liked, now, &tags, tz_offset_secs);
    let phase = phase_for(profile.plays_seen);

    let path = default_path();
    let (mut state, _) = RecoState::load_or_default(&path);
    if !state.bootstrapped {
        catch_up(&mut state, &history.plays, &history.skips, &history.liked, &tags, now, tz_offset_secs);
        let _ = state.save(&path);
    }

    let cfg = RetrieveCfg { listenbrainz: load_listenbrainz_config(), ..Default::default() };
    let env = RetrieveEnv { cache, http, profile: &profile, tags: &tags, now };
    let Pool { mut candidates, reports } = gather(&env, &cfg, phase).await;

    // Tags for the artists the pool brought in, a few per build, then attach what is known.
    if phase == Phase::Personal {
        let wanted: Vec<String> = candidates.iter().filter(|c| c.tags.is_empty()).map(|c| c.artist.clone()).collect();
        if !ensure_tags(cache, http, &tags, &wanted, now, TAGS_PER_BUILD).await.is_empty() {
            tags = tag_table(cache, now);
        }
    }
    for c in &mut candidates {
        if c.tags.is_empty() {
            if let Some(t) = tags.get(&crate::taste::artist_key(&c.artist)) {
                c.tags = t.clone();
            }
        }
    }

    let bucket = Some(bucket_of(now, tz_offset_secs));
    let scored = score_pool(&candidates, &profile, &state, now, bucket);
    let mut rcfg = spec.rerank.clone();
    rcfg.n = spec.n * OVERSHOOT_NUM / OVERSHOOT_DEN;
    let picks = rerank(&scored, &recent_map(&merged), now, &rcfg, &spec.id, &state.bandit, shelf_seed(&spec.id, now, spec.epoch));

    crate::suggestions::grant_search_budget(LOOKUPS_PER_SHELF);
    let mut result = resolve_picks(spotify, cache, &scored, &picks, spec.n).await;
    result.reports = reports;
    result.phase = Some(phase.into());

    // Remember which songs were exploration slots, so a finish or a skip teaches the bandit.
    let mut changed = false;
    for (track, ex) in result.tracks.iter().zip(result.explore.iter()) {
        if *ex {
            if let Some(src) = picks_source(&scored, &picks, &track.id, &result) {
                state.bandit.note_served(&track.id, &spec.id, src, now);
                changed = true;
            }
        }
    }
    if changed {
        let _ = state.save(&path);
    }
    result
}

/// The source of the exploration pick that became `track_id` (looked up by position).
fn picks_source(scored: &[Scored], picks: &[Pick], track_id: &str, result: &ShelfResult) -> Option<Source> {
    let pos = result.tracks.iter().position(|t| t.id == track_id)?;
    let origin = *result.origins.get(pos)?;
    let pick = picks.get(origin)?;
    scored.get(pick.index)?.cand.primary_source()
}

async fn resolve_picks(spotify: &SpotifyClient, cache: &Cache, scored: &[Scored], picks: &[Pick], want: usize) -> ShelfResult {
    let mut out = ShelfResult::default();
    let mut seen: HashSet<String> = HashSet::new();
    for (pick_pos, p) in picks.iter().enumerate() {
        if out.tracks.len() >= want {
            break;
        }
        let Some(s) = scored.get(p.index) else { continue };
        let c = &s.cand;
        let track = match &c.track_id {
            Some(id) => Some(cache.get_track(id).ok().flatten().unwrap_or_else(|| {
                Track::simple(id.clone(), c.title.clone(), c.artist.clone(), String::new(), c.duration_ms.unwrap_or(0))
            })),
            None => {
                let before = crate::suggestions::search_pause_remaining();
                let t = if c.is_album {
                    crate::suggestions::resolve_outside_album(spotify, cache, &c.artist, &c.title).await
                } else {
                    crate::suggestions::resolve_outside_track(spotify, cache, &c.artist, &c.title, c.duration_ms).await
                };
                if t.is_some() || crate::suggestions::search_pause_remaining() != before {
                    out.lookups_used += 1;
                }
                t
            }
        };
        let Some(track) = track else { continue };
        if !seen.insert(track.id.clone()) {
            continue;
        }
        out.reasons.push(reason_of(c, p.explore));
        out.explore.push(p.explore);
        out.origins.push(pick_pos);
        out.tracks.push(track);
    }
    out
}

fn reason_of(c: &Candidate, explore: bool) -> String {
    if let Some(b) = &c.because {
        return b.clone();
    }
    match c.primary_source() {
        Some(Source::History) | Some(Source::Liked) => "From your own listening".to_string(),
        Some(Source::Chart) => "Popular right now".to_string(),
        Some(Source::Editorial) => "A well-known pick".to_string(),
        Some(Source::NewRelease) => format!("New from {}", c.artist),
        _ if explore => "Something new for you".to_string(),
        _ => "Picked for you".to_string(),
    }
}

// ------------------------------------------------------------------ the daemon task

const LEARN_FIRST_DELAY: Duration = Duration::from_secs(90);
const LEARN_EVERY: Duration = Duration::from_secs(300);

/// One pass: bring `path`'s state up to date with the cache. Returns what was learned.
pub fn learn_once(cache: &Cache, path: &Path, tz_offset_secs: i64) -> Result<super::model::CatchUp, String> {
    let now = now_secs();
    let history = load_history(cache);
    let tags = tag_table(cache, now);
    let (mut state, _) = RecoState::load_or_default(path);
    let report = catch_up(&mut state, &history.plays, &history.skips, &history.liked, &tags, now, tz_offset_secs);
    if report.examples > 0 || report.bootstrapped_now {
        state.save(path)?;
    }
    Ok(report)
}

/// Supervised daemon task: learn from new plays and skips every few minutes. Cheap when nothing
/// is new (two small queries).
pub async fn learner_loop(cache: Cache) -> anyhow::Result<()> {
    tokio::time::sleep(LEARN_FIRST_DELAY).await;
    let mut tick = tokio::time::interval(LEARN_EVERY);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tick.tick().await;
        let cache = cache.clone();
        let path = default_path();
        // SQLite and a few thousand rows: off the async threads.
        let outcome = tokio::task::spawn_blocking(move || learn_once(&cache, &path, 0)).await;
        match outcome {
            Ok(Ok(r)) if r.examples > 0 => tracing::info!("reco: learned from {} new plays/skips ({} exploration songs judged)", r.examples, r.explored),
            Ok(Ok(_)) => {}
            Ok(Err(e)) => tracing::warn!("reco: could not save the learned state: {e}"),
            Err(e) => tracing::warn!("reco: learner task failed: {e}"),
        }
    }
}

// ------------------------------------------------------------------ debug view

/// The text of `--reco-explain "<artist>" [<title>]`: the features and what each added, for a
/// candidate as the engine would see it today.
pub fn explain(cache: &Cache, artist: &str, title: &str, tz_offset_secs: i64) -> String {
    let now = now_secs();
    let history = load_history(cache);
    let tags = tag_table(cache, now);
    let merged = history.merged();
    let profile = TasteProfile::build(&merged, &history.liked, now, &tags, tz_offset_secs);
    let (state, recovered) = RecoState::load_or_default(&default_path());
    let mut cand = Candidate::new(artist, title, Source::History);
    if let Some(p) = merged.iter().find(|p| crate::taste::artist_key(&p.artist) == crate::taste::artist_key(artist) && (title.is_empty() || p.title.eq_ignore_ascii_case(title))) {
        cand.track_id = Some(p.track_id.clone());
        if title.is_empty() {
            cand.title = p.title.clone();
        }
    }
    if let Some(t) = tags.get(&crate::taste::artist_key(artist)) {
        cand.tags = t.clone();
    }
    let f = extract(&cand, &profile, &FeatureCtx { now, bucket: Some(bucket_of(now, tz_offset_secs)) });
    let mut s = String::new();
    s.push_str(&format!(
        "{} - {}  ({} plays seen, {}, model updates: {}{})\n\n",
        cand.artist,
        if cand.title.is_empty() { "(any song)" } else { cand.title.as_str() },
        profile.plays_seen,
        match phase_for(profile.plays_seen) {
            Phase::ColdStart => "cold start: charts and editorial only",
            Phase::Personal => "personal",
        },
        state.model.updates,
        if recovered { ", the saved model was unreadable and was reset" } else { "" },
    ));
    s.push_str(&explain_text(&state.model.weights, state.model.bias, &f));
    s.push_str(&format!("\nchance of being finished: {:.0}%\n", state.model.probability(&f) * 100.0));
    s
}

// ------------------------------------------------------------------ source probe

/// One line of `--reco-probe`: a source, whether it answered with something usable, and what.
pub struct ProbeRow {
    pub name: &'static str,
    pub ok: bool,
    pub detail: String,
}

/// Ask every outside source one small question and say whether the answer has the shape the
/// code expects. This is how the VERIFY marks in `retrieve.rs` and `tags.rs` get checked on a
/// machine with a network. Uses a well-known artist; sends nothing about the listener.
pub async fn probe_sources(http: &reqwest::Client) -> Vec<ProbeRow> {
    let mut rows = Vec::new();
    let t = Duration::from_secs(20);

    let mb = tokio::time::timeout(t, super::tags::fetch_artist_tags(http, "Radiohead")).await;
    rows.push(match mb {
        Ok(Ok(tags)) if !tags.is_empty() => ProbeRow { name: "MusicBrainz artist tags", ok: true, detail: format!("{} tags, first: {}", tags.len(), tags.first().map_or("", |t| t.0.as_str())) },
        Ok(Ok(_)) => ProbeRow { name: "MusicBrainz artist tags", ok: false, detail: "answered, but no tags were found (the response shape may differ from the one assumed)".into() },
        Ok(Err(e)) => ProbeRow { name: "MusicBrainz artist tags", ok: false, detail: e },
        Err(_) => ProbeRow { name: "MusicBrainz artist tags", ok: false, detail: "timed out".into() },
    });

    let dz = tokio::time::timeout(t, async {
        let id = crate::suggestions::deezer_artist_id(http, "Radiohead").await?;
        let related = crate::suggestions::deezer_related_artists(http, id, 6).await;
        let top = crate::suggestions::deezer_artist_top(http, id, 3).await;
        Some((related.len(), top.len()))
    })
    .await;
    rows.push(match dz {
        Ok(Some((r, s))) if r > 0 && s > 0 => ProbeRow { name: "Deezer related + top songs", ok: true, detail: format!("{r} related artists, {s} songs") },
        Ok(Some((r, s))) => ProbeRow { name: "Deezer related + top songs", ok: false, detail: format!("{r} related artists, {s} songs") },
        _ => ProbeRow { name: "Deezer related + top songs", ok: false, detail: "no answer".into() },
    });

    let it = tokio::time::timeout(t, crate::suggestions::fetch_itunes_artist_albums(http, "Radiohead")).await;
    rows.push(match it {
        Ok(a) if !a.is_empty() => ProbeRow { name: "iTunes albums", ok: true, detail: format!("{} albums", a.len()) },
        _ => ProbeRow { name: "iTunes albums", ok: false, detail: "no answer".into() },
    });

    let ch = tokio::time::timeout(t, crate::suggestions::fetch_chart_pool(http)).await;
    rows.push(match ch {
        Ok(c) if !c.is_empty() => ProbeRow { name: "charts", ok: true, detail: format!("{} songs", c.len()) },
        _ => ProbeRow { name: "charts", ok: false, detail: "no answer".into() },
    });

    rows.push(match load_listenbrainz_config() {
        None => ProbeRow { name: "ListenBrainz recommendations", ok: true, detail: "opt-in is off (listenbrainz.json), nothing was asked".into() },
        Some(cfg) => {
            let url = format!("https://api.listenbrainz.org/1/cf/recommendation/user/{}/recording", cfg.user);
            match tokio::time::timeout(t, http.get(url).query(&[("count", "5")]).send()).await {
                Ok(Ok(r)) if r.status().is_success() => match r.json::<serde_json::Value>().await {
                    Ok(v) => {
                        let n = super::retrieve::parse_lb_recommendations(&v).len();
                        ProbeRow { name: "ListenBrainz recommendations", ok: n > 0, detail: format!("{n} recommendations parsed") }
                    }
                    Err(e) => ProbeRow { name: "ListenBrainz recommendations", ok: false, detail: e.to_string() },
                },
                Ok(Ok(r)) => ProbeRow { name: "ListenBrainz recommendations", ok: false, detail: format!("HTTP {}", r.status()) },
                _ => ProbeRow { name: "ListenBrainz recommendations", ok: false, detail: "no answer".into() },
            }
        }
    });
    rows
}
