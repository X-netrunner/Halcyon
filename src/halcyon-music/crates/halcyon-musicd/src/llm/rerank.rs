//! Feature 3: rerank the engine's own mixes.
//!
//! The engine still builds every mix and every song in it. For a personal mix with more than 15
//! songs, the model may put the songs it was given in a better order for this listener and drop
//! the weakest, down to 15-25. It sees the songs as `t1..t50` (never real ids) and answers with
//! aliases; every one is mapped back and checked against the mix's own songs, so a song the
//! catalogue did not return can never appear. If too few valid ids come back, or the model fails,
//! the engine's order stays. The result is a list of ids ([`MixOrder`]); the GUI reorders songs it
//! already holds and ignores any id it does not have.
//!
//! Only mixes the engine built from the listener's own history (`source == "Halcyon Local"`) are
//! reranked. Charts and other outside lists are left alone: trimming a "Top 200" to 25 would
//! change what it is.

use super::backend::{LlmError, TasteLlm};
use super::playlist::{PICK_MIN, PLAYLIST_MAX};
use super::prompts;
use super::taste::TasteSummary;
use super::validate::{self, filter_ids};
use super::{
    answer_key, call_with_retry, is_paused, mix_content_hash, set_pause, sha_hex, ANSWER_TTL_SECS,
};
use crate::cache::Cache;
use halcyon_music_core::models::{MusicMix, Track};
use std::time::Duration;

pub const FEATURE_RERANK: &str = "rerank";
/// The engine's personal mixes carry this source; charts and outside lists do not.
pub const PERSONAL_SOURCE: &str = "Halcyon Local";
/// A mix needs more songs than this to be worth trimming (the target is 15 to 25).
pub const MIN_TRACKS: usize = 16;
/// Mixes looked at per run (cached answers cost nothing).
pub const MAX_MIXES_PER_RUN: usize = 6;
/// Model calls per run: a small local model is asked about a few mixes at a time, not all of them.
pub const MAX_CALLS_PER_RUN: usize = 3;
/// "The model had nothing usable for this mix" is remembered this long, so a weak model is not
/// asked again on every visit to Home.
const NO_CHANGE_TTL_SECS: u64 = 86_400;

/// The best order for one mix: ids from that mix only, best first.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MixOrder {
    pub mix_id: String,
    pub track_ids: Vec<String>,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct RerankReport {
    pub from_cache: usize,
    pub reordered: usize,
    /// Mixes whose engine order was kept because the model's answer was not usable.
    pub kept: usize,
    pub asked: usize,
    pub paused: bool,
}

/// Is this mix one the model may reorder?
pub fn eligible(mix: &MusicMix) -> bool {
    mix.source == PERSONAL_SOURCE && mix.tracks.len() >= MIN_TRACKS
}

/// The songs the model is shown for a mix (and so the only ones it can pick): the first 50.
fn candidates(mix: &MusicMix) -> Vec<Track> {
    mix.tracks
        .iter()
        .take(prompts::MAX_CANDIDATES_PER_CALL)
        .cloned()
        .collect()
}

/// Check `ids` against the mix's own songs. `None` (keep the engine's order) when too few are valid.
fn checked_order(mix: &MusicMix, ids: &[String]) -> Option<MixOrder> {
    let allowed: Vec<String> = candidates(mix).into_iter().map(|t| t.id).collect();
    let picked = filter_ids(ids, &allowed, PICK_MIN.min(allowed.len()), PLAYLIST_MAX);
    (!picked.fell_back).then(|| MixOrder {
        mix_id: mix.id.clone(),
        track_ids: picked.ids,
    })
}

/// Reorder and trim the personal mixes among `mixes`. Pure of the daemon: it takes the cache, a
/// model and the taste summary, and hands every finished order to `emit`.
///
/// Answers already in the cache are emitted first and cost nothing. Only for mixes without one,
/// when `allow_model` is true and no recent failure paused this feature, up to `MAX_CALLS_PER_RUN`
/// calls ask the model, one per mix. A failed call pauses the feature and stops the run; unusable
/// answers leave that mix in the engine's order.
pub async fn rerank_mixes(
    cache: &Cache,
    llm: &dyn TasteLlm,
    taste: &TasteSummary,
    mixes: &[MusicMix],
    allow_model: bool,
    timeout: Duration,
    emit: &(dyn Fn(MixOrder) + Send + Sync),
) -> Result<RerankReport, LlmError> {
    let mut report = RerankReport::default();
    if taste.is_thin() {
        return Ok(report);
    }
    let fingerprint = taste.fingerprint();
    let version = prompts::RERANK_PROMPT_VERSION.to_string();
    let model = llm.model().to_string();

    let mut pending: Vec<(&MusicMix, String)> = Vec::new();
    for mix in mixes.iter().filter(|m| eligible(m)).take(MAX_MIXES_PER_RUN) {
        let content = mix_content_hash(mix);
        let input = sha_hex(&[content.as_str(), fingerprint.as_str(), version.as_str()]);
        let key = answer_key(FEATURE_RERANK, &input, &model);
        let cached = cache
            .kv_get(&key)
            .ok()
            .flatten()
            .filter(|item| !item.is_stale)
            .and_then(|item| serde_json::from_str::<Vec<String>>(&item.item).ok());
        match cached {
            Some(ids) => {
                report.from_cache += 1;
                if let Some(order) = checked_order(mix, &ids) {
                    emit(order);
                }
            }
            None => pending.push((mix, key)),
        }
    }

    if pending.is_empty() || !allow_model {
        return Ok(report);
    }
    if is_paused(cache, FEATURE_RERANK, &model) {
        report.paused = true;
        return Ok(report);
    }

    for (mix, key) in pending.into_iter().take(MAX_CALLS_PER_RUN) {
        let prompt = prompts::build_rerank(taste, &mix.title, &candidates(mix));
        report.asked += 1;
        let raw = match call_with_retry(llm, &prompt.request, timeout).await {
            Ok(text) => text,
            Err(e) => {
                set_pause(cache, FEATURE_RERANK, &model);
                return Err(e);
            }
        };
        let ids: Vec<String> = validate::parse_pick(&raw, &prompt.aliases)
            .map(|p| p.ids)
            .unwrap_or_default();
        match checked_order(mix, &ids) {
            Some(order) => {
                if let Ok(json) = serde_json::to_string(&order.track_ids) {
                    let _ = cache.kv_set(&key, &json, ANSWER_TTL_SECS);
                }
                emit(order);
                report.reordered += 1;
            }
            None => {
                let _ = cache.kv_set(&key, "[]", NO_CHANGE_TTL_SECS);
                report.kept += 1;
            }
        }
    }
    if report.reordered == 0 && report.kept > 0 {
        set_pause(cache, FEATURE_RERANK, &model);
        return Err(LlmError::BadResponse("no usable order".to_string()));
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mix(source: &str, n: usize) -> MusicMix {
        MusicMix {
            id: "m".into(),
            title: "On Repeat".into(),
            description: String::new(),
            source: source.into(),
            tracks: (0..n)
                .map(|i| {
                    Track::simple(
                        format!("id{i}"),
                        format!("S{i}"),
                        "A".into(),
                        "Al".into(),
                        1000,
                    )
                })
                .collect(),
            art_url: None,
        }
    }

    #[test]
    fn only_long_personal_mixes_are_eligible() {
        assert!(eligible(&mix(PERSONAL_SOURCE, 16)));
        assert!(!eligible(&mix(PERSONAL_SOURCE, 15)));
        assert!(!eligible(&mix("Deezer", 100)));
        assert!(!eligible(&mix("ListenBrainz", 100)));
    }

    #[test]
    fn checked_order_keeps_valid_ids_and_refuses_too_few() {
        let m = mix(PERSONAL_SOURCE, 20);
        let ids: Vec<String> = (0..12).rev().map(|i| format!("id{i}")).collect();
        let o = checked_order(&m, &ids).expect("twelve valid ids");
        assert_eq!(o.track_ids.first().map(String::as_str), Some("id11"));
        let mut few: Vec<String> = (0..5).map(|i| format!("id{i}")).collect();
        few.push("invented".into());
        assert!(checked_order(&m, &few).is_none());
        assert!(checked_order(&m, &[]).is_none());
    }

    #[test]
    fn ids_beyond_the_fifty_shown_cannot_be_picked() {
        let m = mix(PERSONAL_SOURCE, 80);
        let ids: Vec<String> = (40..80).map(|i| format!("id{i}")).collect();
        let o = checked_order(&m, &ids).expect("ten of them are among the first fifty");
        assert!(o.track_ids.iter().all(|id| id
            .trim_start_matches("id")
            .parse::<usize>()
            .map(|n| n < 50)
            .unwrap_or(false)));
    }
}
