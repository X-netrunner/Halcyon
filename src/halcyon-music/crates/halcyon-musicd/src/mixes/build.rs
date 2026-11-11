//! Part 6, the daemon side: build the mixes that are due, rebuild one on request, apply "Less like
//! this" / "Not my taste", start a radio, start Smart Shuffle.
//!
//! Every function here is best effort: a source that does not answer, a song that is not on
//! Spotify or a lookup that is paused leaves the old mix in place and never blanks a shelf.
//! Nothing here calls the Spotify Web API.

use super::clock::local_utc_offset_secs;
use super::plan::{daylist_tag, smart_shuffle, wanted_mixes, PoolPlan, MIN_POOL};
use super::store::{default_path, MixStore, StoredMix};
use super::{
    cover_hue, cover_urls, daily_mix_title, daylist_title, is_due, lead_artists, mix_id,
    mix_reason, next_refresh_at, parse_mix_id, period_key, MixKind, RADIO_BATCH,
};
use crate::daemon::DaemonContext;
use crate::reco::bandit::shelf_seed;
use crate::reco::engine::{prepare, shelf_from, Extras, Prepared, ShelfResult, ShelfSpec};
use crate::reco::rerank::RerankCfg;
use crate::reco::retrieve::{radio_candidates, RetrieveEnv};
use crate::reco::Candidate;
use crate::taste::{artist_key, bucket_of};
use crate::token_store::now_secs;
use halcyon_music_core::models::{MixMeta, MusicMix};
use halcyon_music_core::protocol::{self, EventBody, MixFeedbackAction};
use halcyon_music_core::state::Track;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tracing::{info, warn};

/// Automatic rebuild checks are at least this far apart (a refresh the listener asks for is not).
const AUTO_EVERY_SECS: u64 = 30 * 60;
/// A skip row written for "less like this" / "not my taste": long enough not to be ignored as a
/// mis-click, short enough to count as a skip.
const FEEDBACK_SKIP_MS: u64 = 1_500;

static BUSY: AtomicBool = AtomicBool::new(false);
static LAST_AUTO: AtomicU64 = AtomicU64::new(0);
static RADIO_GEN: AtomicU64 = AtomicU64::new(0);

struct BusyGuard;
impl Drop for BusyGuard {
    fn drop(&mut self) {
        BUSY.store(false, Ordering::SeqCst);
    }
}

fn send(ctx: &DaemonContext, body: EventBody) {
    let _ = ctx.events_tx.send(protocol::event(body));
}

/// The stored mixes, as the event the GUI understands.
pub fn updated_event(store: &MixStore) -> EventBody {
    let (mixes, meta) = store.to_wire();
    EventBody::MixesUpdated { mixes, meta }
}

fn load_store() -> MixStore {
    MixStore::load_or_default(&default_path()).0
}

fn save_store(store: &MixStore) {
    if let Err(e) = store.save(&default_path()) {
        warn!("mixes: could not save the mixes: {e}");
    }
}

/// Put the stored mixes into a Home feed (instant, from the file): mixes with the same id are
/// replaced (the old engine's On Repeat), the rest of `made_for_you` is kept after them.
pub fn attach(feed: &mut halcyon_music_core::models::HomeFeed) {
    let store = load_store();
    let (mixes, meta) = store.to_wire();
    if mixes.is_empty() {
        return;
    }
    let ids: HashSet<String> = mixes.iter().map(|m| m.id.clone()).collect();
    feed.made_for_you
        .retain(|m| !ids.contains(&m.id) && parse_mix_id(&m.id).is_none());
    let mut all = mixes;
    all.append(&mut feed.made_for_you);
    feed.made_for_you = all;
    feed.mix_meta = meta;
}

// ------------------------------------------------------------------ one mix

fn rerank_for(kind: MixKind, n: usize) -> RerankCfg {
    match kind {
        MixKind::OnRepeat | MixKind::RepeatRewind => RerankCfg::repeat_list(n),
        MixKind::DailyMix => RerankCfg {
            explore_share: 0.15,
            ..RerankCfg::shelf(n)
        },
        MixKind::DiscoverWeekly => RerankCfg {
            explore_share: 0.5,
            ..RerankCfg::shelf(n)
        },
        MixKind::ReleaseRadar => RerankCfg {
            explore_share: 0.0,
            ..RerankCfg::shelf(n)
        },
        MixKind::Daylist => RerankCfg::shelf(n),
    }
}

/// What one mix is built from: the plans (widest last), the least pool size, and the word that
/// names the Daylist.
fn extras_for(
    kind: MixKind,
    cluster: Option<u32>,
    daylist_tag: Option<&str>,
    feedback: &super::store::Feedback,
) -> (Extras, usize) {
    let (plans, min_pool): (Vec<PoolPlan>, usize) = match kind {
        MixKind::DailyMix => (cluster.map(PoolPlan::Cluster).into_iter().collect(), 0),
        MixKind::DiscoverWeekly => (vec![PoolPlan::Unheard], 0),
        MixKind::ReleaseRadar => (vec![PoolPlan::NewReleases], 0),
        MixKind::OnRepeat => (
            vec![
                PoolPlan::OnRepeat { min_plays: 2 },
                PoolPlan::OnRepeat { min_plays: 1 },
            ],
            MIN_POOL,
        ),
        MixKind::RepeatRewind => (vec![PoolPlan::Rewind], 0),
        MixKind::Daylist => match daylist_tag {
            Some(t) => (vec![PoolPlan::Tag(t.to_string()), PoolPlan::All], MIN_POOL),
            None => (vec![PoolPlan::All], 0),
        },
    };
    (
        Extras {
            plans,
            min_pool,
            feedback: feedback.clone(),
            ..Default::default()
        },
        0,
    )
}

/// Build one mix and put it in the store. False when nothing came out (the old mix stays).
#[allow(clippy::too_many_arguments)]
async fn build_one(
    ctx: &DaemonContext,
    prep: &mut Prepared,
    store: &mut MixStore,
    kind: MixKind,
    slot: usize,
    cluster: Option<u32>,
    label: &str,
    bump_epoch: bool,
) -> bool {
    let id = mix_id(kind, slot);
    let now = prep.now;
    let tz = prep.tz;
    let old_epoch = store.get(&id).map_or(0, |m| m.epoch);
    let epoch = if bump_epoch { old_epoch + 1 } else { old_epoch };
    let tag = if kind == MixKind::Daylist {
        daylist_tag(&prep.profile, &prep.tags, bucket_of(now, tz))
    } else {
        None
    };
    let (extras, _) = extras_for(kind, cluster, tag.as_deref(), &store.feedback);
    let n = kind.songs();
    let spec = ShelfSpec {
        id: id.clone(),
        n,
        rerank: rerank_for(kind, n),
        epoch,
    };
    let result: ShelfResult = shelf_from(prep, &ctx.spotify, &ctx.cache, &spec, &extras).await;
    if result.tracks.is_empty() {
        info!("mixes: {id} came out empty, keeping the old one");
        return false;
    }
    let tag_used = if result.plan_used == 0 {
        tag.clone()
    } else {
        None
    };
    let word = if kind == MixKind::Daylist {
        tag_used.clone().unwrap_or_default()
    } else {
        label.to_string()
    };
    let title = match kind {
        MixKind::DailyMix => daily_mix_title(slot, label),
        MixKind::DiscoverWeekly => "Discover Weekly".to_string(),
        MixKind::ReleaseRadar => "Release Radar".to_string(),
        MixKind::OnRepeat => "On Repeat".to_string(),
        MixKind::RepeatRewind => "Repeat Rewind".to_string(),
        MixKind::Daylist => daylist_title(now, tz, tag_used.as_deref()),
    };
    let top = prep.profile.top_artists(50);
    let leads = lead_artists(&result.tracks, &top, 2);
    store.put(StoredMix {
        id,
        kind: kind.name().to_string(),
        title,
        reason: mix_reason(kind, &leads, &word),
        period: period_key(kind, now, tz),
        built_at: now,
        next_refresh_at: next_refresh_at(kind, now, tz),
        epoch,
        cluster_id: cluster,
        label: word,
        tracks: result.tracks,
        reasons: result.reasons,
        explore: result.explore,
    });
    true
}

// ------------------------------------------------------------------ refresh

/// Rebuild what is due (or the mixes named in `force`), then tell the GUI after each one that
/// came out. One run at a time; an automatic run (empty `force`) at most every half hour.
pub async fn refresh(ctx: Arc<DaemonContext>, force: Vec<String>) {
    let manual = !force.is_empty();
    let now = now_secs();
    if !manual && now.saturating_sub(LAST_AUTO.load(Ordering::Relaxed)) < AUTO_EVERY_SECS {
        return;
    }
    if BUSY.swap(true, Ordering::SeqCst) {
        return;
    }
    let _guard = BusyGuard;
    if !manual {
        LAST_AUTO.store(now, Ordering::Relaxed);
    }
    let tz = local_utc_offset_secs(now);
    let mut store = load_store();
    let mut prep = prepare(&ctx.cache, &ctx.http, tz).await;
    let cluster_ids: Vec<u32> = {
        let mut cs: Vec<&crate::taste::Cluster> = prep.profile.clusters.iter().collect();
        cs.sort_by(|a, b| {
            b.share
                .partial_cmp(&a.share)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.id.cmp(&b.id))
        });
        cs.into_iter().map(|c| c.id).collect()
    };
    let slots = if prep.phase == crate::reco::Phase::Personal {
        store.assign_slots(&cluster_ids, super::MAX_DAILY_MIXES)
    } else {
        Vec::new()
    };
    // A cluster that went away takes its Daily Mix with it.
    let live: HashSet<String> = slots.iter().map(|(s, _)| super::daily_mix_id(*s)).collect();
    store
        .mixes
        .retain(|id, m| m.kind != MixKind::DailyMix.name() || live.contains(id));

    for (kind, slot, cluster, label) in wanted_mixes(&prep.profile, &slots) {
        let id = mix_id(kind, slot);
        let forced = force.contains(&id);
        if manual && !forced {
            continue;
        }
        let have = store.get(&id);
        let due = is_due(kind, have.map(|m| m.period.as_str()), now, tz)
            || have.is_none_or(|m| m.tracks.is_empty());
        if !forced && !due {
            continue;
        }
        if build_one(
            &ctx, &mut prep, &mut store, kind, slot, cluster, &label, forced,
        )
        .await
        {
            save_store(&store);
            send(&ctx, updated_event(&store));
        }
    }
    save_store(&store);
    send(&ctx, updated_event(&store));
}

// ------------------------------------------------------------------ feedback

/// "Less like this" / "Not my taste". Reaches the taste model at once (skip rows the next profile
/// build reads), the blocklist at once, and the stored mixes at once. A whole-mix answer also
/// rebuilds that mix.
pub async fn feedback(
    ctx: Arc<DaemonContext>,
    mix_id: String,
    track_id: Option<String>,
    action: MixFeedbackAction,
) {
    let mut store = load_store();
    let now = now_secs();
    let strong = !matches!(action, MixFeedbackAction::LessLikeThis);
    let rows: Vec<(Track, bool)> = match &track_id {
        Some(tid) => {
            let from_mix = store
                .get(&mix_id)
                .and_then(|m| m.tracks.iter().find(|t| t.id == *tid).cloned());
            let found = match from_mix {
                Some(t) => Some(t),
                None => ctx
                    .player
                    .snapshot()
                    .await
                    .queue
                    .into_iter()
                    .find(|t| t.id == *tid),
            };
            found.into_iter().map(|t| (t, true)).collect()
        }
        // The whole mix: the songs by artists you had not played are what was wrong with it.
        None => store
            .get(&mix_id)
            .map(|m| {
                m.tracks
                    .iter()
                    .zip(m.explore.iter().chain(std::iter::repeat(&false)))
                    .filter(|(_, ex)| **ex)
                    .map(|(t, _)| (t.clone(), false))
                    .collect()
            })
            .unwrap_or_default(),
    };
    for (t, single) in &rows {
        let times = if strong && *single { 3 } else { 1 };
        for _ in 0..times {
            let _ = ctx
                .cache
                .log_skip(&t.id, &t.title, &t.artist, &t.album, now, FEEDBACK_SKIP_MS);
        }
        if strong {
            if *single {
                store.feedback.block_track(&t.id, &t.artist, &t.title);
            } else {
                store.feedback.block_artist(&t.artist);
            }
        }
        store.feedback.less_like(&t.artist);
    }
    store.purge_blocked();
    save_store(&store);
    send(&ctx, updated_event(&store));
    // The queue of a Smart Shuffle: a rejected suggestion leaves it at once.
    if let (Some(tid), true) = (&track_id, strong) {
        let tid = tid.clone();
        ctx.player.mutate(|s| remove_from_queue(s, &tid)).await;
    }
    if track_id.is_none() && parse_mix_id(&mix_id).is_some() {
        refresh(ctx, vec![mix_id]).await;
    }
}

/// Take a song out of the queue without moving the current song.
fn remove_from_queue(s: &mut halcyon_music_core::state::PlayerState, track_id: &str) {
    let Some(pos) = s.queue.iter().position(|t| t.id == track_id) else {
        return;
    };
    if pos == s.queue_pos && s.track.as_ref().is_some_and(|t| t.id == track_id) {
        return; // it is playing right now: let it finish
    }
    s.queue.remove(pos);
    if pos < s.queue_pos {
        s.queue_pos = s.queue_pos.saturating_sub(1);
    }
}

// ------------------------------------------------------------------ radio

/// Start a radio from one song: build a first batch, play it, and keep adding songs while it
/// plays. A new radio, `StopRadio`, or someone else replacing the queue ends the old one.
pub async fn start_radio(ctx: Arc<DaemonContext>, seed: Track) {
    let gen = RADIO_GEN.fetch_add(1, Ordering::SeqCst) + 1;
    let tz = local_utc_offset_secs(now_secs());
    let mut prep = prepare(&ctx.cache, &ctx.http, tz).await;
    let mut avoid: HashSet<String> = HashSet::new();
    avoid.insert(seed.id.clone());
    let batch = radio_batch(&ctx, &mut prep, &seed, &avoid, 0).await;
    if batch.tracks.is_empty() {
        send(
            &ctx,
            EventBody::RadioStopped {
                reason: "Could not find songs like that one right now. Try again in a moment."
                    .to_string(),
            },
        );
        return;
    }
    let mut queue = vec![seed.clone()];
    queue.extend(batch.tracks.iter().cloned());
    let first = seed.clone();
    let q = queue.clone();
    ctx.player
        .mutate(|s| {
            s.queue = q;
            s.queue_pos = 0;
            s.track = Some(first);
            s.playing = true;
            s.position_ms = 0;
        })
        .await;
    let id = format!("radio-{}", seed.id);
    let meta = MixMeta {
        mix_id: id.clone(),
        kind: "radio".into(),
        reason: format!("Songs like {} by {}", seed.title, seed.artist),
        reasons: std::iter::once("Where this radio started".to_string())
            .chain(batch.reasons.iter().cloned())
            .collect(),
        explore: std::iter::once(false)
            .chain(batch.explore.iter().copied())
            .collect(),
        built_at: now_secs(),
        next_refresh_at: 0,
        cover_urls: cover_urls(&queue),
        cover_hue: cover_hue(&id),
    };
    let mix = MusicMix {
        id,
        title: format!("{} radio", seed.title),
        description: meta.reason.clone(),
        source: "Halcyon Local".into(),
        art_url: queue.iter().find_map(|t| t.art_url.clone()),
        tracks: queue,
    };
    send(&ctx, EventBody::RadioStarted { mix, meta });
    tokio::spawn(radio_loop(ctx, seed, gen, prep));
}

pub fn stop_radio() {
    RADIO_GEN.fetch_add(1, Ordering::SeqCst);
}

async fn radio_batch(
    ctx: &DaemonContext,
    prep: &mut Prepared,
    seed: &Track,
    avoid: &HashSet<String>,
    epoch: u64,
) -> ShelfResult {
    let mut seed_c = Candidate::new(&seed.artist, &seed.title, crate::reco::Source::History);
    seed_c.track_id = Some(seed.id.clone());
    if let Some(t) = prep.tags.get(&artist_key(&seed.artist)) {
        seed_c.tags = t.clone();
    }
    let mut extra = {
        let env = RetrieveEnv {
            cache: &ctx.cache,
            http: &ctx.http,
            profile: &prep.profile,
            tags: &prep.tags,
            now: prep.now,
        };
        radio_candidates(&env, &seed.artist, &seed_c.tags).await
    };
    for c in &mut extra {
        if c.tags.is_empty() {
            if let Some(t) = prep.tags.get(&artist_key(&c.artist)) {
                c.tags = t.clone();
            }
        }
    }
    let id = format!("radio-{}", seed.id);
    let spec = ShelfSpec {
        id,
        n: RADIO_BATCH,
        rerank: RerankCfg {
            max_per_artist: 3,
            ..RerankCfg::shelf(RADIO_BATCH)
        },
        epoch,
    };
    let feedback = load_store().feedback;
    let extras = Extras {
        feedback,
        seed: Some(seed_c),
        extra_pool: extra,
        avoid: avoid.clone(),
        ..Default::default()
    };
    shelf_from(prep, &ctx.spotify, &ctx.cache, &spec, &extras).await
}

/// Keep the radio going: when three songs are left, add a batch. Ends when the queue is no longer
/// the radio's (it does not start with the seed) or another radio/stop took over.
async fn radio_loop(ctx: Arc<DaemonContext>, seed: Track, gen: u64, mut prep: Prepared) {
    let mut epoch = 1u64;
    let mut empty_runs = 0;
    loop {
        tokio::time::sleep(Duration::from_secs(5)).await;
        if RADIO_GEN.load(Ordering::SeqCst) != gen {
            return;
        }
        let snap = ctx.player.snapshot().await;
        if snap.queue.first().map(|t| t.id.as_str()) != Some(seed.id.as_str()) {
            send(
                &ctx,
                EventBody::RadioStopped {
                    reason: "Radio ended because the queue was replaced.".to_string(),
                },
            );
            return;
        }
        let left = snap.queue.len().saturating_sub(snap.queue_pos + 1);
        if left > 3 {
            continue;
        }
        let avoid: HashSet<String> = snap.queue.iter().map(|t| t.id.clone()).collect();
        let batch = radio_batch(&ctx, &mut prep, &seed, &avoid, epoch).await;
        epoch += 1;
        if batch.tracks.is_empty() {
            empty_runs += 1;
            if empty_runs >= 3 {
                send(
                    &ctx,
                    EventBody::RadioStopped {
                        reason: "Radio ran out of songs to add.".to_string(),
                    },
                );
                return;
            }
            continue;
        }
        empty_runs = 0;
        let first_id = seed.id.clone();
        let add = batch.tracks;
        ctx.player
            .mutate(|s| {
                if s.queue.first().is_some_and(|t| t.id == first_id) {
                    s.queue.extend(add);
                }
            })
            .await;
    }
}

// ------------------------------------------------------------------ Smart Shuffle

/// Smart Shuffle for a list of your own: suggestions come from a radio seeded by the list's most
/// played artists' neighbours; one is put after every three of your songs.
pub async fn start_smart_shuffle(ctx: Arc<DaemonContext>, name: String, tracks: Vec<Track>) {
    stop_radio();
    if tracks.is_empty() {
        return;
    }
    let tz = local_utc_offset_secs(now_secs());
    let mut prep = prepare(&ctx.cache, &ctx.http, tz).await;
    let own_ids: HashSet<String> = tracks.iter().map(|t| t.id.clone()).collect();
    // Seed the suggestions from the list itself: one song, spread by the day's seed.
    let seed_pos = (shelf_seed(&name, prep.now, 0) % tracks.len() as u64) as usize;
    let suggestions: Vec<Track> = match tracks.get(seed_pos) {
        Some(seed) => {
            let want = tracks.len() / 3 + 3;
            let mut spec_rerank = RerankCfg::shelf(want);
            spec_rerank.max_per_artist = 2;
            let mut seed_c =
                Candidate::new(&seed.artist, &seed.title, crate::reco::Source::History);
            seed_c.track_id = Some(seed.id.clone());
            if let Some(t) = prep.tags.get(&artist_key(&seed.artist)) {
                seed_c.tags = t.clone();
            }
            let extra = {
                let env = RetrieveEnv {
                    cache: &ctx.cache,
                    http: &ctx.http,
                    profile: &prep.profile,
                    tags: &prep.tags,
                    now: prep.now,
                };
                radio_candidates(&env, &seed.artist, &seed_c.tags).await
            };
            let spec = ShelfSpec {
                id: format!("smart-shuffle:{name}"),
                n: want,
                rerank: spec_rerank,
                epoch: 0,
            };
            let extras = Extras {
                feedback: load_store().feedback,
                seed: Some(seed_c),
                extra_pool: extra,
                avoid: own_ids,
                ..Default::default()
            };
            shelf_from(&mut prep, &ctx.spotify, &ctx.cache, &spec, &extras)
                .await
                .tracks
        }
        None => Vec::new(),
    };
    let out = smart_shuffle(&tracks, &suggestions, shelf_seed(&name, prep.now, 1), 3);
    let Some(first) = out.tracks.first().cloned() else {
        return;
    };
    let q = out.tracks.clone();
    ctx.player
        .mutate(|s| {
            s.queue = q;
            s.queue_pos = 0;
            s.track = Some(first);
            s.playing = true;
            s.position_ms = 0;
        })
        .await;
    send(
        &ctx,
        EventBody::SmartShuffleStarted {
            name,
            suggested: out.suggested,
        },
    );
}
