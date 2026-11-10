//! The optional LLM layer: makes suggestions feel personal without replacing the engine.
//!
//! The deterministic engine (`suggestions.rs`) still builds every mix and every candidate
//! list. This layer only *reads* what the engine produced and writes words about it: a
//! better title and a short reason per mix. It never invents a song. It is off by default,
//! talks to a model on this machine by default, sends aggregates instead of the play log, and
//! never sits on a path the user is waiting for: Home shows the engine's mixes at once and the
//! words arrive later as [`EventBody::MixEnriched`]. Any failure is a log line and nothing else.
//!
//! See `docs/llm-layer.md` for the data flow, the privacy table and the failure modes.

pub mod backend;
pub mod bench;
pub mod grammar;
pub mod local;
pub mod models;
pub mod mock;
pub mod playlist;
pub mod prompts;
pub mod rerank;
pub mod taste;
pub mod validate;

use crate::cache::Cache;
use crate::daemon::DaemonContext;
use crate::suggestions::normalize_string;
use crate::token_store::now_secs;
use backend::{LlmError, LlmRequest, OllamaBackend, TasteLlm};
use local::LocalGgufBackend;
use halcyon_music_core::models::{MusicMix, Track};
use halcyon_music_core::protocol::{self, EventBody};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use taste::TasteSummary;
use tracing::{debug, info, warn};
use validate::MixBlurb;

/// Ollama on this machine. Nothing leaves the computer with the default backend.
pub const DEFAULT_ENDPOINT: &str = "http://127.0.0.1:11434";
/// Small, quick and good enough at JSON. The user can pick another in Settings.
pub const DEFAULT_MODEL: &str = "qwen2.5:3b";
/// How long one call may take before it counts as failed.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(20);
const RETRY_PAUSE: Duration = Duration::from_millis(400);

const SETTINGS_KEY: &str = "llm.settings.v1";
const FOREVER_SECS: u64 = 10 * 365 * 86_400;
/// Answers are kept for a month; they also stop matching as soon as the mix, the taste or the
/// prompt wording changes, because all three are part of the key.
const ANSWER_TTL_SECS: u64 = 30 * 86_400;
/// After a failed call, leave the model alone this long so a down backend is not retried on
/// every visit to Home.
const FAIL_PAUSE_SECS: u64 = 600;
const FEATURE_WHY_MIX: &str = "why-mix";

// ---------------------------------------------------------------- settings

/// The two ways to run the model. `local` is the built-in one (a small downloaded model, no other
/// app needed); `ollama` talks to an Ollama server.
pub const BACKEND_LOCAL: &str = "local";
pub const BACKEND_OLLAMA: &str = "ollama";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct LlmSettings {
    /// Off by default: nothing is sent anywhere until the user turns this on.
    pub enabled: bool,
    /// `local` (built-in model) or `ollama`.
    pub backend: String,
    /// The Ollama model name (used when `backend` is `ollama`).
    pub model: String,
    /// The built-in model's id from `models::CATALOGUE` (used when `backend` is `local`).
    pub local_model: String,
    /// Where Ollama listens. Only used with the `ollama` backend.
    pub ollama_endpoint: String,
}

impl Default for LlmSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            backend: BACKEND_LOCAL.to_string(),
            model: DEFAULT_MODEL.to_string(),
            local_model: models::DEFAULT_LOCAL_MODEL.to_string(),
            ollama_endpoint: DEFAULT_ENDPOINT.to_string(),
        }
    }
}

/// An Ollama address that is safe to use: `http(s)://host[:port]` with nothing else.
pub fn clean_endpoint(raw: &str) -> Option<String> {
    let t = raw.trim().trim_end_matches('/');
    let rest = t.strip_prefix("http://").or_else(|| t.strip_prefix("https://"))?;
    let ok = !rest.is_empty()
        && rest.len() <= 100
        && rest.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':' | '[' | ']'))
        && !rest.starts_with(|c: char| c == '.' || c == '-' || c == ':');
    ok.then(|| t.to_string())
}

impl LlmSettings {
    /// Make the settings safe to store and use: the backend is one of the two known ones, model
    /// names keep only the characters model names use, and the Ollama address is a plain http(s) one.
    pub fn normalised(mut self) -> Self {
        if self.backend != BACKEND_OLLAMA {
            self.backend = BACKEND_LOCAL.to_string();
        }
        let model: String = self
            .model
            .trim()
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | ':' | '_' | '-' | '/'))
            .take(80)
            .collect();
        self.model = if model.is_empty() { DEFAULT_MODEL.to_string() } else { model };
        if !models::is_known(&self.local_model) {
            self.local_model = models::DEFAULT_LOCAL_MODEL.to_string();
        }
        self.ollama_endpoint = clean_endpoint(&self.ollama_endpoint).unwrap_or_else(|| DEFAULT_ENDPOINT.to_string());
        self
    }

    /// The model of the chosen backend: what answers are cached under and what Settings shows.
    pub fn active_model(&self) -> &str {
        if self.backend == BACKEND_OLLAMA {
            &self.model
        } else {
            &self.local_model
        }
    }

    pub fn uses_local(&self) -> bool {
        self.backend != BACKEND_OLLAMA
    }
}

pub fn load_settings(cache: &Cache) -> LlmSettings {
    cache
        .kv_get(SETTINGS_KEY)
        .ok()
        .flatten()
        .and_then(|item| serde_json::from_str::<LlmSettings>(&item.item).ok())
        .unwrap_or_default()
        .normalised()
}

pub fn save_settings(cache: &Cache, settings: &LlmSettings) {
    match serde_json::to_string(settings) {
        Ok(json) => {
            if let Err(e) = cache.kv_set(SETTINGS_KEY, &json, FOREVER_SECS) {
                warn!("could not save the Smart suggestions settings: {e}");
            }
        }
        Err(e) => warn!("could not encode the Smart suggestions settings: {e}"),
    }
}

pub fn status_event(settings: &LlmSettings, reachable: bool, hint: Option<String>) -> protocol::Event {
    protocol::event(EventBody::LlmStatus {
        enabled: settings.enabled,
        backend: settings.backend.clone(),
        model: settings.active_model().to_string(),
        reachable,
        hint,
    })
}

pub fn make_backend(settings: &LlmSettings, http: &reqwest::Client) -> Box<dyn TasteLlm> {
    if settings.uses_local() {
        Box::new(LocalGgufBackend::production(&settings.local_model))
    } else {
        Box::new(OllamaBackend::new(http.clone(), &settings.ollama_endpoint, &settings.model))
    }
}

/// Reachable or not, with a plain-language fix when not.
pub async fn check_connection(llm: &dyn TasteLlm) -> (bool, Option<String>) {
    match llm.probe().await {
        Ok(()) => (true, None),
        Err(e) => (false, Some(e.to_string())),
    }
}

// ---------------------------------------------------------------- cache keys

fn sha_hex(parts: &[&str]) -> String {
    let mut h = Sha256::new();
    for p in parts {
        h.update(p.as_bytes());
        h.update([0u8]);
    }
    let hex = format!("{:x}", h.finalize());
    hex.chars().take(32).collect()
}

/// A hash of what a mix *contains* (its id and its songs, in any order). A mix that is
/// reshuffled but holds the same songs keeps its hash and so keeps its cached words.
pub fn mix_content_hash(mix: &MusicMix) -> String {
    let mut ids: Vec<&str> = mix.tracks.iter().map(|t| t.id.as_str()).collect();
    ids.sort_unstable();
    let joined = ids.join(",");
    sha_hex(&[mix.id.as_str(), joined.as_str()])
}

fn answer_key(feature: &str, input_hash: &str, model: &str) -> String {
    format!("llm.v1.{feature}.{model}.{input_hash}")
}

fn pause_key(feature: &str, model: &str) -> String {
    format!("llm.v1.pause.{feature}.{model}")
}

fn is_paused(cache: &Cache, feature: &str, model: &str) -> bool {
    cache.kv_get(&pause_key(feature, model)).ok().flatten().map(|i| !i.is_stale).unwrap_or(false)
}

fn set_pause(cache: &Cache, feature: &str, model: &str) {
    let _ = cache.kv_set(&pause_key(feature, model), "1", FAIL_PAUSE_SECS);
}

/// Forget a failure pause (the user changed a setting or the connection test succeeded).
pub fn clear_pause(cache: &Cache, model: &str) {
    // A zero-second lifetime is stale at once.
    for feature in [FEATURE_WHY_MIX, rerank::FEATURE_RERANK] {
        let _ = cache.kv_set(&pause_key(feature, model), "0", 0);
    }
}

#[derive(Serialize, Deserialize)]
struct StoredBlurb {
    title: String,
    reason: String,
}

// ---------------------------------------------------------------- calling the model

/// One call with a timeout and a single retry. A missing model is not retried: asking again
/// cannot install it.
pub async fn call_with_retry(llm: &dyn TasteLlm, req: &LlmRequest, timeout: Duration) -> Result<String, LlmError> {
    let mut last = LlmError::Timeout;
    for attempt in 0..2 {
        if attempt > 0 {
            tokio::time::sleep(RETRY_PAUSE).await;
        }
        match tokio::time::timeout(timeout, llm.complete(req)).await {
            Ok(Ok(text)) => return Ok(text),
            Ok(Err(e)) if e.is_permanent() => return Err(e),
            Ok(Err(e)) => last = e,
            Err(_) => last = LlmError::Timeout,
        }
    }
    Err(last)
}

// ---------------------------------------------------------------- feature 1: why this mix

#[derive(Debug, Default, PartialEq, Eq)]
pub struct EnrichReport {
    pub from_cache: usize,
    pub generated: usize,
    pub asked_model: bool,
    /// The model was skipped because a recent call failed.
    pub paused: bool,
}

/// Give each mix a better title and a reason. Pure of the daemon: it takes the cache, a
/// model, the taste summary and the mixes, and hands every finished blurb to `emit`.
///
/// Answers already in the cache are emitted first and cost nothing. Only if some mixes have
/// no cached answer, `allow_model` is true and no recent failure paused the layer, one call
/// asks the model about all of them. The model's answer is checked field by field; whatever
/// does not check out is dropped, so the worst case is that a mix keeps its own title.
pub async fn enrich_mixes(
    cache: &Cache,
    llm: &dyn TasteLlm,
    taste: &TasteSummary,
    mixes: &[MusicMix],
    allow_model: bool,
    timeout: Duration,
    emit: &(dyn Fn(MixBlurb) + Send + Sync),
) -> Result<EnrichReport, LlmError> {
    let mut report = EnrichReport::default();
    if taste.is_thin() {
        return Ok(report);
    }
    let fingerprint = taste.fingerprint();
    let version = prompts::PROMPT_VERSION.to_string();
    let model = llm.model().to_string();

    let eligible: Vec<&MusicMix> =
        mixes.iter().filter(|m| m.tracks.len() >= 3).take(prompts::MAX_MIXES_PER_CALL).collect();
    let mut pending: Vec<&MusicMix> = Vec::new();
    let mut keys: HashMap<String, String> = HashMap::new();

    for mix in eligible {
        let content = mix_content_hash(mix);
        let input = sha_hex(&[content.as_str(), fingerprint.as_str(), version.as_str()]);
        let key = answer_key(FEATURE_WHY_MIX, &input, &model);
        let cached = cache
            .kv_get(&key)
            .ok()
            .flatten()
            .and_then(|item| serde_json::from_str::<StoredBlurb>(&item.item).ok())
            .and_then(|b| validate::check_blurb(&mix.id, &mix.title, &b.title, &b.reason));
        match cached {
            Some(blurb) => {
                emit(blurb);
                report.from_cache += 1;
            }
            None => {
                keys.insert(mix.id.clone(), key);
                pending.push(mix);
            }
        }
    }

    if pending.is_empty() || !allow_model {
        return Ok(report);
    }
    if is_paused(cache, FEATURE_WHY_MIX, &model) {
        report.paused = true;
        return Ok(report);
    }

    let prompt = prompts::build_why_mix(taste, &pending);
    report.asked_model = true;
    let raw = match call_with_retry(llm, &prompt.request, timeout).await {
        Ok(text) => text,
        Err(e) => {
            set_pause(cache, FEATURE_WHY_MIX, &model);
            return Err(e);
        }
    };
    let blurbs = validate::parse_why_mix(&raw, &prompt.aliases);
    if blurbs.is_empty() {
        set_pause(cache, FEATURE_WHY_MIX, &model);
        return Err(LlmError::BadResponse("no usable titles or reasons".to_string()));
    }
    for blurb in blurbs {
        if let Some(key) = keys.get(&blurb.mix_id) {
            let stored = StoredBlurb { title: blurb.title.clone(), reason: blurb.reason.clone() };
            if let Ok(json) = serde_json::to_string(&stored) {
                let _ = cache.kv_set(key, &json, ANSWER_TTL_SECS);
            }
        }
        emit(blurb);
        report.generated += 1;
    }
    Ok(report)
}

// ---------------------------------------------------------------- the taste summary, from the cache

/// Local hour of day (0..=23) for a unix time.
pub fn local_hour(secs: u64) -> u8 {
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    let t = secs as libc::time_t;
    unsafe {
        libc::localtime_r(&t, &mut tm);
    }
    u8::try_from(tm.tm_hour.clamp(0, 23)).unwrap_or(0)
}

/// Read the play log and likes from the cache and boil them down. Only the summary leaves
/// this function's caller; the raw log never does.
pub fn taste_from_cache(cache: &Cache) -> TasteSummary {
    let plays = cache.get_recent_plays(5000).unwrap_or_default();
    let liked: Vec<Track> = cache.get_liked_tracks(1000, 0).map(|(t, _)| t).unwrap_or_default();
    let mut genres: HashMap<String, Vec<String>> = HashMap::new();
    let mut seen: HashSet<String> = HashSet::new();
    for p in &plays {
        let key = normalize_string(&p.artist);
        if key.is_empty() || !seen.insert(key.clone()) {
            continue;
        }
        if seen.len() > 60 {
            break;
        }
        if let Ok(Some(artist)) = cache.get_artist_by_name(&p.artist) {
            if !artist.genres.is_empty() {
                genres.insert(key, artist.genres);
            }
        }
    }
    taste::summarise(&plays, &liked, &genres, now_secs(), &local_hour)
}

// ---------------------------------------------------------------- daemon glue

/// True while one background call to the model is running; a second request only serves cached
/// answers instead of queueing more work for a small local model.
static RUNNING: AtomicBool = AtomicBool::new(false);

struct RunGuard;

impl Drop for RunGuard {
    fn drop(&mut self) {
        RUNNING.store(false, Ordering::SeqCst);
    }
}

/// Start the enrichment of these mixes in the background. Returns at once. Does nothing when
/// the layer is off. Runs in a task of its own so a panic is caught and logged.
pub fn spawn_enrichment(ctx: Arc<DaemonContext>, mixes: Vec<MusicMix>) {
    if mixes.is_empty() {
        return;
    }
    let settings = load_settings(&ctx.cache);
    if !settings.enabled {
        return;
    }
    crate::supervisor::run_guarded("llm-why-mix", async move {
        let allow_model = !RUNNING.swap(true, Ordering::SeqCst);
        let _guard = allow_model.then_some(RunGuard);
        let llm = make_backend(&settings, &ctx.http);
        let taste = taste_from_cache(&ctx.cache);
        let tx = ctx.events_tx.clone();
        let tx_orders = ctx.events_tx.clone();
        let emit = move |b: MixBlurb| {
            let _ = tx.send(protocol::event(EventBody::MixEnriched {
                mix_id: b.mix_id,
                title: b.title,
                reason: b.reason,
            }));
        };
        let timeout = llm.call_timeout();
        match enrich_mixes(&ctx.cache, llm.as_ref(), &taste, &mixes, allow_model, timeout, &emit).await {
            Ok(r) => {
                debug!(from_cache = r.from_cache, generated = r.generated, paused = r.paused, "mix words done");
                // Feature 3, in the same task so the model is only ever used by one job at a time.
                // Skipped when the words just failed: the backend is probably down.
                let emit_order = move |o: rerank::MixOrder| {
                    let _ = tx_orders.send(protocol::event(EventBody::MixReranked {
                        mix_id: o.mix_id,
                        track_ids: o.track_ids,
                    }));
                };
                match rerank::rerank_mixes(&ctx.cache, llm.as_ref(), &taste, &mixes, allow_model, timeout, &emit_order)
                    .await
                {
                    Ok(r) => debug!(
                        from_cache = r.from_cache,
                        reordered = r.reordered,
                        kept = r.kept,
                        paused = r.paused,
                        "mix order done"
                    ),
                    Err(e) => info!("Smart suggestions skipped reordering this time: {e}"),
                }
            }
            Err(e) => info!("Smart suggestions skipped this time: {e}"),
        }
    });
}

/// Tell every client the current settings (without contacting the model).
pub fn announce_status(ctx: &DaemonContext) {
    let settings = load_settings(&ctx.cache);
    let _ = ctx.events_tx.send(status_event(&settings, false, None));
}

/// Check the backend in the background and tell every client the result. When it answers and
/// the layer is on, a failure pause is forgotten and `then_enrich` is enriched right away.
pub fn spawn_connection_test(ctx: Arc<DaemonContext>, then_enrich: Vec<MusicMix>) {
    crate::supervisor::run_guarded("llm-probe", async move {
        let settings = load_settings(&ctx.cache);
        let llm = make_backend(&settings, &ctx.http);
        let (reachable, hint) = check_connection(llm.as_ref()).await;
        if reachable {
            clear_pause(&ctx.cache, settings.active_model());
        }
        let _ = ctx.events_tx.send(status_event(&settings, reachable, hint));
        if reachable && settings.enabled {
            spawn_enrichment(ctx.clone(), then_enrich);
        }
    });
}

/// The Home mixes the daemon last saved (what Smart suggestions writes words about).
fn home_mixes(ctx: &DaemonContext) -> Vec<MusicMix> {
    crate::daemon::load_home_mixes(&ctx.cache)
}

/// Settings after a client's change: only the chosen backend's model is replaced, so switching
/// back and forth keeps each backend's own choice.
pub fn merged_settings(old: LlmSettings, enabled: bool, backend: &str, model: &str, endpoint: &str) -> LlmSettings {
    let mut s = old;
    s.enabled = enabled;
    s.backend = backend.to_string();
    let model = model.trim();
    if !model.is_empty() {
        if backend == BACKEND_OLLAMA {
            s.model = model.to_string();
        } else {
            s.local_model = model.to_string();
        }
    }
    if !endpoint.trim().is_empty() {
        s.ollama_endpoint = endpoint.to_string();
    }
    s.normalised()
}

/// Apply new settings from the GUI: store them, tell everyone, and check the connection. Turning
/// Smart suggestions on with the built-in backend starts the one-time model download when the
/// model is not on disk yet (Settings shows its size next to the switch).
pub fn apply_settings(ctx: &Arc<DaemonContext>, enabled: bool, backend: &str, model: &str, endpoint: &str) {
    let settings = merged_settings(load_settings(&ctx.cache), enabled, backend, model, endpoint);
    save_settings(&ctx.cache, &settings);
    clear_pause(&ctx.cache, settings.active_model());
    let _ = ctx.events_tx.send(status_event(&settings, false, None));
    models::announce_models(ctx);
    if settings.enabled && settings.uses_local() && local::engine_available() {
        if let Some(spec) = models::find(&settings.local_model) {
            if !models::disk_status(&models::models_dir(), spec.file).installed {
                models::spawn_download(ctx.clone(), spec.id.to_string());
                return;
            }
        }
    }
    if settings.enabled {
        spawn_connection_test(ctx.clone(), home_mixes(ctx));
    }
}

/// A model download finished: if it is the one Smart suggestions uses, check it and write the words now.
pub fn model_ready(ctx: Arc<DaemonContext>, id: &str) {
    let settings = load_settings(&ctx.cache);
    if settings.enabled && settings.uses_local() && settings.local_model == id {
        let mixes = home_mixes(&ctx);
        spawn_connection_test(ctx, mixes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mix(id: &str, ids: &[&str]) -> MusicMix {
        MusicMix {
            id: id.to_string(),
            title: "T".to_string(),
            description: String::new(),
            source: "Halcyon Local".to_string(),
            tracks: ids
                .iter()
                .map(|i| Track::simple(i.to_string(), "S".into(), "A".into(), "Al".into(), 1000))
                .collect(),
            art_url: None,
        }
    }

    #[test]
    fn defaults_are_off_and_local() {
        let s = LlmSettings::default();
        assert!(!s.enabled);
        assert_eq!(s.backend, "local");
        assert!(DEFAULT_ENDPOINT.starts_with("http://127.0.0.1"));
        assert_eq!(s.ollama_endpoint, DEFAULT_ENDPOINT);
        assert_eq!(s.active_model(), models::DEFAULT_LOCAL_MODEL);
    }

    #[test]
    fn settings_normalise_model_names_and_backend() {
        let s = LlmSettings {
            enabled: true,
            backend: "somewhere-else".into(),
            model: "  qwen2.5:3b; rm -rf /  ".into(),
            ..LlmSettings::default()
        }
        .normalised();
        assert_eq!(s.backend, "local");
        assert_eq!(s.model, "qwen2.5:3brm-rf/");
        let o = LlmSettings { backend: "ollama".into(), ..LlmSettings::default() }.normalised();
        assert_eq!(o.backend, "ollama");
        let empty = LlmSettings { enabled: true, backend: String::new(), model: "   ".into(), ..LlmSettings::default() }.normalised();
        assert_eq!(empty.model, DEFAULT_MODEL);
        let long = LlmSettings { enabled: true, backend: String::new(), model: "a".repeat(500), ..LlmSettings::default() }.normalised();
        assert_eq!(long.model.len(), 80);
    }

    #[test]
    fn mix_hash_ignores_song_order_but_not_content() {
        let a = mix("m", &["1", "2", "3"]);
        let b = mix("m", &["3", "1", "2"]);
        let c = mix("m", &["1", "2", "4"]);
        let d = mix("other", &["1", "2", "3"]);
        assert_eq!(mix_content_hash(&a), mix_content_hash(&b));
        assert_ne!(mix_content_hash(&a), mix_content_hash(&c));
        assert_ne!(mix_content_hash(&a), mix_content_hash(&d));
    }

    #[test]
    fn answer_keys_separate_feature_model_and_input() {
        let k1 = answer_key("why-mix", "abc", "qwen2.5:3b");
        assert_ne!(k1, answer_key("rerank", "abc", "qwen2.5:3b"));
        assert_ne!(k1, answer_key("why-mix", "abc", "llama3"));
        assert_ne!(k1, answer_key("why-mix", "abd", "qwen2.5:3b"));
    }

    #[test]
    fn old_stored_settings_keep_their_ollama_choice() {
        // What the layer stored before the built-in model existed.
        let stored = r#"{"enabled":true,"backend":"ollama","model":"llama3:8b"}"#;
        let s = serde_json::from_str::<LlmSettings>(stored).expect("decode").normalised();
        assert!(s.enabled);
        assert_eq!(s.backend, "ollama");
        assert_eq!(s.active_model(), "llama3:8b");
        assert_eq!(s.ollama_endpoint, DEFAULT_ENDPOINT);
        assert_eq!(s.local_model, models::DEFAULT_LOCAL_MODEL);
        // and an empty store is the new default
        let fresh = serde_json::from_str::<LlmSettings>("{}").expect("decode").normalised();
        assert_eq!(fresh.backend, "local");
        assert!(!fresh.enabled);
    }

    #[test]
    fn each_backend_keeps_its_own_model_choice() {
        let start = LlmSettings::default();
        let a = merged_settings(start, true, "ollama", "mistral:7b", "");
        assert_eq!((a.backend.as_str(), a.active_model()), ("ollama", "mistral:7b"));
        let b = merged_settings(a, true, "local", "qwen3-0.6b", "");
        assert_eq!((b.backend.as_str(), b.active_model()), ("local", "qwen3-0.6b"));
        assert_eq!(b.model, "mistral:7b");
        // switching back finds the Ollama model again
        let c = merged_settings(b, true, "ollama", "", "");
        assert_eq!(c.active_model(), "mistral:7b");
        // an unknown built-in id falls back to the default
        let d = merged_settings(c, true, "local", "not-a-model", "");
        assert_eq!(d.active_model(), models::DEFAULT_LOCAL_MODEL);
    }

    #[test]
    fn ollama_endpoint_is_a_plain_http_address() {
        assert_eq!(clean_endpoint("http://127.0.0.1:11434/"), Some("http://127.0.0.1:11434".to_string()));
        assert_eq!(clean_endpoint(" https://ollama.lan:8443 "), Some("https://ollama.lan:8443".to_string()));
        for bad in ["", "127.0.0.1:11434", "ftp://x", "http://", "http://a b", "http://x/y?z=1", "http://x;rm", "http://:80", "javascript:alert(1)"] {
            assert_eq!(clean_endpoint(bad), None, "{bad:?}");
        }
        let s = merged_settings(LlmSettings::default(), true, "ollama", "", "http://192.168.1.5:11434");
        assert_eq!(s.ollama_endpoint, "http://192.168.1.5:11434");
        let bad = merged_settings(s, true, "ollama", "", "file:///etc/passwd");
        assert_eq!(bad.ollama_endpoint, DEFAULT_ENDPOINT);
    }

    #[test]
    fn answers_are_cached_per_backend_model() {
        let ollama = LlmSettings { backend: "ollama".into(), ..LlmSettings::default() };
        let local = LlmSettings::default();
        assert_ne!(
            answer_key("why-mix", "abc", ollama.active_model()),
            answer_key("why-mix", "abc", local.active_model())
        );
    }
}
