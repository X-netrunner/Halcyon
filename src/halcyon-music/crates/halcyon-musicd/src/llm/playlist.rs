//! Feature 2: prompt to playlist.
//!
//! The listener types a mood ("rainy night coding, no lyrics"). The flow is:
//!
//! 1. the model turns the words into a small search plan (seed artists, genres, energy,
//!    instrumental or not, era), checked field by field ([`validate::parse_query`]);
//! 2. the plan is run against the real catalogue, deterministically: one search per seed artist
//!    and per genre, results merged round-robin, at most three songs per artist;
//! 3. the model may pick and order from those candidates, by alias, and write a title and a
//!    reason; every id is checked against the candidate list and the engine's own order is used
//!    when too few survive.
//!
//! The model never supplies a song. Every track in the finished mix came out of the catalogue.
//! Failure of step 3 is silent (the mix is simply ordered by the engine); failure of steps 1 or 2
//! is reported in plain language with something to try.

use super::backend::{BoxFuture, LlmError, TasteLlm};
use super::taste::TasteSummary;
use super::validate::{self, clean_meta, clean_output, filter_ids, QuerySpec, MAX_REASON_CHARS, MAX_TITLE_CHARS};
use super::{answer_key, call_with_retry, load_settings, make_backend, sha_hex, taste_from_cache, LlmSettings, CALL_TIMEOUT};
use super::prompts;
use crate::api::SpotifyClient;
use crate::cache::Cache;
use crate::daemon::DaemonContext;
use crate::suggestions::{filter_mix_tracks, normalize_string, token_similarity};
use halcyon_music_core::models::{MusicMix, Track};
use halcyon_music_core::protocol::{self, EventBody};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tracing::{debug, info};

pub const FEATURE_QUERY: &str = "prompt-query";
pub const FEATURE_PLAYLIST: &str = "prompt-playlist";

/// Progress steps sent while a request is worked on.
pub const STEP_UNDERSTANDING: &str = "understanding";
pub const STEP_SEARCHING: &str = "searching";
pub const STEP_CHOOSING: &str = "choosing";

/// A search plan is kept for a week: it only depends on the words and the taste.
const QUERY_TTL_SECS: u64 = 7 * 86_400;
/// A finished mix is kept for three days: the catalogue can change under it.
const PLAYLIST_TTL_SECS: u64 = 3 * 86_400;
/// Fewest letters and digits a request needs.
pub const MIN_REQUEST_CHARS: usize = 3;
/// Most catalogue searches one request makes.
pub const MAX_SEARCHES: usize = 8;
/// Fewest candidate songs worth making a mix from.
pub const MIN_CANDIDATES: usize = 8;
/// With this many candidates or fewer the model is not asked to choose: there is nothing to trim.
const PICK_ONLY_ABOVE: usize = 12;
/// A model's pick with fewer valid songs than this is not trusted; the engine's order is used.
pub const PICK_MIN: usize = 10;
/// Most songs in the finished mix.
pub const PLAYLIST_MAX: usize = 25;
/// Most songs by one artist among the candidates. (Engine mixes use 2; a listener who names an
/// artist wants a little more of them.)
const PER_ARTIST: usize = 3;
/// Pause between catalogue searches, so a burst does not get the account rate limited.
const SEARCH_SPACING: Duration = Duration::from_millis(250);
/// All catalogue searches of one request must finish within this; what arrived by then is used.
const GATHER_TIMEOUT: Duration = Duration::from_secs(20);
/// The whole request, from the first model call to the finished mix.
pub const DEADLINE: Duration = Duration::from_secs(75);

// ---------------------------------------------------------------- errors

/// Why a request could not be answered. Every message is plain language with something to try.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum PromptError {
    #[error("Describe the mood in a few words, for example \"rainy night coding, no lyrics\".")]
    TooShort,
    #[error("Smart suggestions are off. Turn them on in Settings to describe a mood.")]
    Off,
    #[error("Halcyon couldn't turn that into a search. Try naming an artist or a genre.")]
    NotUnderstood,
    #[error("Halcyon couldn't search Spotify just now. Check that you're signed in and online, then try again.")]
    CatalogueDown,
    #[error("Halcyon couldn't find enough songs for that. Try naming an artist or a genre.")]
    TooFewSongs,
    #[error("That took too long. Try again in a moment, or choose a smaller model in Settings.")]
    TooSlow,
    #[error("Another mood is still being made. Wait for it to finish, then try again.")]
    Busy,
    #[error("Something went wrong while making that mix. Try again; if it keeps happening, turn Smart suggestions off and on in Settings.")]
    Crashed,
    #[error(transparent)]
    Llm(#[from] LlmError),
}

// ---------------------------------------------------------------- the catalogue

/// The real song catalogue, as far as this feature needs it. The engine owns what Spotify says;
/// this is only the seam that lets tests use a scripted one.
pub trait Catalogue: Send + Sync {
    /// Songs the catalogue returns for a text query (about 10). `None`: it could not be asked
    /// (offline, signed out, lookups paused). `Some(vec![])`: it answered with nothing.
    fn search_songs<'a>(&'a self, query: &'a str) -> BoxFuture<'a, Option<Vec<Track>>>;
}

/// Spotify, through the same search the Search page uses (the librespot session in the default
/// sign-in, so no Web API quota).
pub struct SpotifyCatalogue {
    spotify: SpotifyClient,
}

impl SpotifyCatalogue {
    pub fn new(spotify: SpotifyClient) -> Self {
        Self { spotify }
    }
}

impl Catalogue for SpotifyCatalogue {
    fn search_songs<'a>(&'a self, query: &'a str) -> BoxFuture<'a, Option<Vec<Track>>> {
        Box::pin(async move {
            // The engine pauses lookups after Spotify rate limits it; honour that.
            if crate::suggestions::search_pause_remaining() > 0 {
                return None;
            }
            match self.spotify.search_detailed(query, "songs", 10, 0).await {
                Ok(found) => Some(found.tracks),
                Err(e) => {
                    // The query is the listener's own words; keep it out of the log.
                    debug!("a catalogue search for a prompt playlist failed: {e}");
                    None
                }
            }
        })
    }
}

// ---------------------------------------------------------------- candidates (deterministic)

/// One catalogue search the plan asks for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchKind {
    /// Songs by this artist; results by anyone else are dropped.
    Artist(String),
    /// Songs for this genre or mood tag.
    Tag(String),
}

/// The searches a plan asks for: seed artists first, then tags, at most `MAX_SEARCHES`, with at
/// least two slots kept for tags when the plan has any (so a request is never only artists).
pub fn plan_searches(spec: &QuerySpec) -> Vec<SearchKind> {
    let tag_slots = spec.genres.len().min(2);
    let artist_slots = MAX_SEARCHES.saturating_sub(tag_slots);
    let mut out: Vec<SearchKind> = spec.seed_artists.iter().take(artist_slots).cloned().map(SearchKind::Artist).collect();
    let room = MAX_SEARCHES.saturating_sub(out.len());
    out.extend(spec.genres.iter().take(room).cloned().map(SearchKind::Tag));
    out
}

/// The text sent to the catalogue for one search.
pub fn query_text(kind: &SearchKind, spec: &QuerySpec) -> String {
    match kind {
        SearchKind::Artist(name) => name.clone(),
        SearchKind::Tag(tag) => {
            if spec.instrumental == Some(true) && !tag.contains("instrumental") {
                format!("{tag} instrumental")
            } else {
                tag.clone()
            }
        }
    }
}

fn without_the(s: &str) -> &str {
    s.strip_prefix("the ").unwrap_or(s)
}

/// Is this song by the artist that was asked for? The song's main artist and its other credited
/// artists are all considered; "The Prodigy" matches "Prodigy".
pub fn artist_matches(track: &Track, wanted: &str) -> bool {
    let wanted_norm = normalize_string(wanted);
    let want = without_the(&wanted_norm);
    if want.is_empty() {
        return false;
    }
    std::iter::once(track.artist.as_str()).chain(track.artists.iter().map(String::as_str)).any(|name| {
        let name_norm = normalize_string(name);
        let have = without_the(&name_norm);
        have == want || token_similarity(have, want) >= 0.6
    })
}

/// The lower-case words of `s`, split on anything that is not a letter or a digit.
fn words_of(s: &str) -> Vec<String> {
    s.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_lowercase).collect()
}

/// A catalogue text search for a genre word also returns songs that merely have the word in their
/// title ("Downtempo" by four different artists, "Paparazzi (Dubstep)"). That says nothing about
/// how the song sounds, so such songs are dropped from a genre or mood search.
pub fn title_only_matches_tag(track: &Track, tag: &str) -> bool {
    let want = words_of(tag);
    if want.is_empty() {
        return false;
    }
    words_of(&track.title).windows(want.len()).any(|w| w == want.as_slice())
}

/// Take one song from each list in turn, skipping songs already taken, until every list is empty.
/// Keeps the candidate list from being all one artist's songs.
pub fn merge_round_robin(lists: Vec<Vec<Track>>) -> Vec<Track> {
    let mut iters: Vec<std::vec::IntoIter<Track>> = lists.into_iter().map(Vec::into_iter).collect();
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    loop {
        let mut progressed = false;
        for it in iters.iter_mut() {
            for t in it.by_ref() {
                progressed = true;
                if t.id.is_empty() || t.title.trim().is_empty() {
                    continue;
                }
                if seen.insert(t.id.clone()) {
                    out.push(t);
                    break;
                }
            }
        }
        if !progressed {
            break;
        }
    }
    out
}

/// What the catalogue gave back for a plan.
#[derive(Debug, Default)]
pub struct Gathered {
    pub tracks: Vec<Track>,
    /// Searches that were made.
    pub asked: usize,
    /// Searches the catalogue answered (an empty answer counts).
    pub answered: usize,
}

/// Run the plan against the catalogue. Deterministic: the same answers always give the same
/// list. Stops early when the catalogue is clearly not answering, and at `GATHER_TIMEOUT` keeps
/// what has arrived.
pub async fn gather_candidates(catalogue: &dyn Catalogue, spec: &QuerySpec) -> Gathered {
    let plan = plan_searches(spec);
    let deadline = tokio::time::Instant::now() + GATHER_TIMEOUT;
    let mut out = Gathered::default();
    let mut lists: Vec<Vec<Track>> = Vec::new();
    for (i, kind) in plan.iter().enumerate() {
        if i > 0 {
            tokio::time::sleep(SEARCH_SPACING).await;
        }
        // Two searches in a row that nobody answered: it is down, do not keep knocking.
        if out.asked >= 2 && out.answered == 0 {
            break;
        }
        out.asked += 1;
        let query = query_text(kind, spec);
        let found = match tokio::time::timeout_at(deadline, catalogue.search_songs(&query)).await {
            Ok(found) => found,
            Err(_) => break,
        };
        let Some(found) = found else {
            continue;
        };
        out.answered += 1;
        let kept: Vec<Track> = match kind {
            SearchKind::Artist(name) => found.into_iter().filter(|t| artist_matches(t, name)).collect(),
            SearchKind::Tag(tag) => found.into_iter().filter(|t| !title_only_matches_tag(t, tag)).collect(),
        };
        lists.push(kept);
    }
    let merged = merge_round_robin(lists);
    let mut seen_ids: HashSet<String> = HashSet::new();
    out.tracks =
        filter_mix_tracks(merged, PER_ARTIST, &mut seen_ids, &HashSet::new(), true, prompts::MAX_CANDIDATES_PER_CALL);
    out
}

// ---------------------------------------------------------------- the words

fn capitalised(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// A title when the model gave none worth showing: the plan's, else the first words of the request.
pub fn fallback_title(spec: &QuerySpec, request: &str) -> String {
    let from_plan = clean_output(&spec.title, MAX_TITLE_CHARS);
    if from_plan.chars().count() >= 3 {
        return from_plan;
    }
    let first_words: Vec<&str> = request.split_whitespace().take(4).collect();
    let from_request = clean_output(&first_words.join(" "), MAX_TITLE_CHARS);
    if from_request.chars().count() >= 3 {
        capitalised(&from_request)
    } else {
        "Your Mix".to_string()
    }
}

fn fallback_reason(request: &str) -> String {
    clean_output(&format!("Made from your words: {request}"), MAX_REASON_CHARS)
}

// ---------------------------------------------------------------- the whole request

#[derive(Debug, Default, PartialEq, Eq)]
pub struct PromptReport {
    pub from_cache: bool,
    /// The model's pick was used (valid, not a fallback).
    pub ordered_by_model: bool,
    /// The model was asked to choose but its answer could not be used (or it failed), so the
    /// engine's order was used. Such a mix is not cached, so the next try can do better.
    pub degraded: bool,
    pub candidates: usize,
}

#[derive(Debug)]
pub struct PromptOutcome {
    pub mix: MusicMix,
    pub report: PromptReport,
}

fn load_cached_plan(cache: &Cache, key: &str) -> Option<QuerySpec> {
    let item = cache.kv_get(key).ok().flatten().filter(|i| !i.is_stale)?;
    let spec = serde_json::from_str::<QuerySpec>(&item.item).ok()?;
    (!spec.seed_artists.is_empty() || !spec.genres.is_empty()).then_some(spec)
}

fn load_cached_mix(cache: &Cache, key: &str) -> Option<MusicMix> {
    let item = cache.kv_get(key).ok().flatten().filter(|i| !i.is_stale)?;
    let mix = serde_json::from_str::<MusicMix>(&item.item).ok()?;
    (!mix.tracks.is_empty()).then_some(mix)
}

/// Turn a typed mood into a mix. Pure of the daemon: it takes the cache, a model, a catalogue and
/// the taste summary. `progress` is told which step is running. `timeout` is the limit of each
/// single model call (there is one retry); the caller puts `DEADLINE` around the whole thing.
///
/// A warm cache answers with no model call and no search. The model's only jobs are the plan and
/// the pick; the songs come from the catalogue, so the worst outcome of a bad model answer is a
/// mix in the engine's order or a plain-language "try again".
pub async fn build_prompt_playlist(
    cache: &Cache,
    llm: &dyn TasteLlm,
    catalogue: &dyn Catalogue,
    taste: &TasteSummary,
    text: &str,
    timeout: Duration,
    progress: &(dyn Fn(&str) + Send + Sync),
) -> Result<PromptOutcome, PromptError> {
    let request = clean_meta(text, prompts::MAX_REQUEST_CHARS);
    if request.chars().filter(|c| c.is_alphanumeric()).count() < MIN_REQUEST_CHARS {
        return Err(PromptError::TooShort);
    }

    let model = llm.model().to_string();
    let fingerprint = taste.fingerprint();
    let words = request.to_lowercase();
    let query_version = prompts::QUERY_PROMPT_VERSION.to_string();
    let pick_version = prompts::PICK_PROMPT_VERSION.to_string();

    let plan_hash = sha_hex(&[words.as_str(), fingerprint.as_str(), query_version.as_str()]);
    let plan_key = answer_key(FEATURE_QUERY, &plan_hash, &model);
    let mix_hash = sha_hex(&[words.as_str(), fingerprint.as_str(), query_version.as_str(), pick_version.as_str()]);
    let mix_key = answer_key(FEATURE_PLAYLIST, &mix_hash, &model);

    // Warm cache: no model, no search.
    if let Some(mix) = load_cached_mix(cache, &mix_key) {
        let candidates = mix.tracks.len();
        return Ok(PromptOutcome {
            mix,
            report: PromptReport { from_cache: true, ordered_by_model: true, degraded: false, candidates },
        });
    }

    // 1. What does the listener want?
    progress(STEP_UNDERSTANDING);
    let spec = match load_cached_plan(cache, &plan_key) {
        Some(spec) => spec,
        None => {
            let raw = call_with_retry(llm, &prompts::build_query(taste, &request), timeout).await?;
            let spec = validate::parse_query(&raw).ok_or(PromptError::NotUnderstood)?;
            if let Ok(json) = serde_json::to_string(&spec) {
                let _ = cache.kv_set(&plan_key, &json, QUERY_TTL_SECS);
            }
            spec
        }
    };

    // 2. Real songs for it, from the catalogue.
    progress(STEP_SEARCHING);
    let gathered = gather_candidates(catalogue, &spec).await;
    if gathered.answered == 0 {
        return Err(PromptError::CatalogueDown);
    }
    if gathered.tracks.len() < MIN_CANDIDATES {
        return Err(PromptError::TooFewSongs);
    }
    let candidates = gathered.tracks;
    let candidate_ids: Vec<String> = candidates.iter().map(|t| t.id.clone()).collect();

    // 3. Choose and order. Any failure here falls back to the engine's order.
    let mut report = PromptReport { candidates: candidates.len(), ..PromptReport::default() };
    let mut answer: Option<validate::PickAnswer> = None;
    let ids: Vec<String> = if candidates.len() > PICK_ONLY_ABOVE {
        progress(STEP_CHOOSING);
        let prompt = prompts::build_pick(taste, &request, &spec, &candidates);
        let parsed = match call_with_retry(llm, &prompt.request, timeout).await {
            Ok(raw) => validate::parse_pick(&raw, &prompt.aliases),
            Err(e) => {
                debug!("choosing songs for a prompt playlist failed, using the engine's order: {e}");
                None
            }
        };
        match parsed {
            Some(pick) => {
                let min_valid = PICK_MIN.min(candidate_ids.len());
                let picked = filter_ids(&pick.ids, &candidate_ids, min_valid, PLAYLIST_MAX);
                report.degraded = picked.fell_back;
                report.ordered_by_model = !picked.fell_back;
                answer = Some(pick);
                picked.ids
            }
            None => {
                report.degraded = true;
                candidate_ids.iter().take(PLAYLIST_MAX).cloned().collect()
            }
        }
    } else {
        candidate_ids.iter().take(PLAYLIST_MAX).cloned().collect()
    };

    // Only songs the catalogue returned can get in: look each id up in the candidate list.
    let by_id: HashMap<&str, &Track> = candidates.iter().map(|t| (t.id.as_str(), t)).collect();
    let tracks: Vec<Track> = ids.iter().filter_map(|id| by_id.get(id.as_str()).map(|t| (*t).clone())).collect();
    if tracks.len() < MIN_CANDIDATES.min(candidates.len()) || tracks.is_empty() {
        return Err(PromptError::TooFewSongs);
    }

    let title = answer
        .as_ref()
        .map(|a| a.title.clone())
        .filter(|t| t.chars().count() >= 3)
        .unwrap_or_else(|| fallback_title(&spec, &request));
    let reason = answer
        .as_ref()
        .map(|a| a.reason.clone())
        .filter(|r| r.chars().count() >= 8)
        .unwrap_or_else(|| fallback_reason(&request));
    let art_url = tracks.iter().find_map(|t| t.art_url.clone());
    let short_hash: String = mix_hash.chars().take(12).collect();
    let mix = MusicMix {
        id: format!("prompt-{short_hash}"),
        title,
        description: reason,
        source: "Halcyon Local".to_string(),
        tracks,
        art_url,
    };

    if !report.degraded {
        if let Ok(json) = serde_json::to_string(&mix) {
            let _ = cache.kv_set(&mix_key, &json, PLAYLIST_TTL_SECS);
        }
    }
    Ok(PromptOutcome { mix, report })
}

// ---------------------------------------------------------------- daemon glue

/// True while one request is being made. A second request is told to wait instead of queueing
/// more work for a small local model.
static RUNNING: AtomicBool = AtomicBool::new(false);

struct RunGuard;

impl Drop for RunGuard {
    fn drop(&mut self) {
        RUNNING.store(false, Ordering::SeqCst);
    }
}

fn send_failed(ctx: &DaemonContext, request: &str, error: &PromptError) {
    let _ = ctx.events_tx.send(protocol::event(EventBody::PromptPlaylistFailed {
        request: request.to_string(),
        reason: error.to_string(),
    }));
}

async fn run_request(ctx: Arc<DaemonContext>, settings: LlmSettings, text: String, finished: Arc<AtomicBool>) {
    let llm = make_backend(&settings, &ctx.http);
    let catalogue = SpotifyCatalogue::new(ctx.spotify.clone());
    let taste = taste_from_cache(&ctx.cache);
    let tx = ctx.events_tx.clone();
    let progress = {
        let tx = tx.clone();
        let echo = text.clone();
        move |step: &str| {
            let _ = tx.send(protocol::event(EventBody::PromptPlaylistProgress {
                request: echo.clone(),
                step: step.to_string(),
            }));
        }
    };
    let result = tokio::time::timeout(
        DEADLINE,
        build_prompt_playlist(&ctx.cache, llm.as_ref(), &catalogue, &taste, &text, CALL_TIMEOUT, &progress),
    )
    .await;
    match result {
        Ok(Ok(outcome)) => {
            // Same as Search: remember the songs so the rest of the app can show them offline.
            let _ = ctx.cache.put_tracks(&outcome.mix.tracks);
            debug!(
                from_cache = outcome.report.from_cache,
                ordered_by_model = outcome.report.ordered_by_model,
                candidates = outcome.report.candidates,
                "prompt playlist done"
            );
            let _ = tx.send(protocol::event(EventBody::PromptPlaylistResult { request: text, mix: outcome.mix }));
        }
        Ok(Err(e)) => {
            info!("Smart suggestions could not make that playlist: {e}");
            send_failed(&ctx, &text, &e);
        }
        Err(_) => {
            info!("Smart suggestions took too long to make a playlist");
            send_failed(&ctx, &text, &PromptError::TooSlow);
        }
    }
    finished.store(true, Ordering::SeqCst);
}

/// Start making a playlist from the listener's words. Returns at once; the answer arrives as
/// events. Exactly one of `PromptPlaylistResult` or `PromptPlaylistFailed` is sent for every call,
/// even when the layer is off, another request is running, or the background job panics.
pub fn spawn_prompt_playlist(ctx: Arc<DaemonContext>, text: String) {
    let text: String = text.chars().take(prompts::MAX_REQUEST_CHARS * 2).collect();
    let settings = load_settings(&ctx.cache);
    if !settings.enabled {
        send_failed(&ctx, &text, &PromptError::Off);
        return;
    }
    if RUNNING.swap(true, Ordering::SeqCst) {
        send_failed(&ctx, &text, &PromptError::Busy);
        return;
    }
    let finished = Arc::new(AtomicBool::new(false));
    let job = crate::supervisor::run_guarded("llm-prompt-playlist", run_request(ctx.clone(), settings, text.clone(), finished.clone()));
    tokio::spawn(async move {
        let _guard = RunGuard;
        let _ = job.await;
        if !finished.load(Ordering::SeqCst) {
            // The job panicked (it was caught and logged); the listener must not wait forever.
            send_failed(&ctx, &text, &PromptError::Crashed);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(id: &str, artist: &str, title: &str) -> Track {
        Track::simple(id.to_string(), title.to_string(), artist.to_string(), "Album".to_string(), 200_000)
    }

    fn spec(artists: &[&str], genres: &[&str]) -> QuerySpec {
        QuerySpec {
            title: String::new(),
            seed_artists: artists.iter().map(|s| s.to_string()).collect(),
            genres: genres.iter().map(|s| s.to_string()).collect(),
            energy: None,
            instrumental: None,
            era: None,
        }
    }

    #[test]
    fn searches_are_artists_first_then_tags_and_capped() {
        let s = spec(&["A", "B", "C"], &["x", "y"]);
        assert_eq!(
            plan_searches(&s),
            vec![
                SearchKind::Artist("A".into()),
                SearchKind::Artist("B".into()),
                SearchKind::Artist("C".into()),
                SearchKind::Tag("x".into()),
                SearchKind::Tag("y".into())
            ]
        );
        let many = spec(&["1", "2", "3", "4", "5"], &["a", "b", "c", "d"]);
        let p = plan_searches(&many);
        assert_eq!(p.len(), MAX_SEARCHES);
        let tags = p.iter().filter(|k| matches!(k, SearchKind::Tag(_))).count();
        assert!(tags >= 2, "two slots stay free for tags");
        assert!(plan_searches(&spec(&[], &[])).is_empty());
    }

    #[test]
    fn a_song_that_only_has_the_genre_word_in_its_title_is_not_a_match() {
        assert!(title_only_matches_tag(&track("1", "D", "Downtempo"), "downtempo"));
        assert!(title_only_matches_tag(&track("2", "Alximo", "Paparazzi (Dubstep)"), "dubstep"));
        assert!(title_only_matches_tag(&track("3", "X", "Sad Songs for Rainy Days"), "sad"));
        assert!(!title_only_matches_tag(&track("4", "RudyWade", "Trapped in a Dream"), "trap"), "a different word");
        assert!(!title_only_matches_tag(&track("5", "Massive Attack", "Angel"), "downtempo"));
        assert!(!title_only_matches_tag(&track("6", "X", "Anything"), ""), "an empty tag matches nothing");
    }

    #[test]
    fn instrumental_requests_add_the_word_to_tag_searches_only() {
        let mut s = spec(&["Nova"], &["ambient", "instrumental rock"]);
        s.instrumental = Some(true);
        assert_eq!(query_text(&SearchKind::Tag("ambient".into()), &s), "ambient instrumental");
        assert_eq!(query_text(&SearchKind::Tag("instrumental rock".into()), &s), "instrumental rock");
        assert_eq!(query_text(&SearchKind::Artist("Nova".into()), &s), "Nova");
        s.instrumental = None;
        assert_eq!(query_text(&SearchKind::Tag("ambient".into()), &s), "ambient");
    }

    #[test]
    fn artist_matching_is_forgiving_about_the_and_credits_but_not_about_other_artists() {
        let t = track("1", "Prodigy", "Firestarter");
        assert!(artist_matches(&t, "The Prodigy"));
        assert!(artist_matches(&track("2", "The Prodigy", "x"), "prodigy"));
        let mut collab = track("3", "Someone", "x");
        collab.artists = vec!["Someone".into(), "Nova".into()];
        assert!(artist_matches(&collab, "Nova"));
        assert!(!artist_matches(&track("4", "Nova Twins", "x"), "Nova"), "a different artist sharing one word");
        assert!(!artist_matches(&track("5", "Completely Different", "x"), "Nova"));
        assert!(!artist_matches(&track("6", "Nova", "x"), ""));
    }

    #[test]
    fn round_robin_mixes_lists_and_skips_repeats_and_blank_songs() {
        let a = vec![track("a1", "A", "1"), track("a2", "A", "2"), track("a3", "A", "3")];
        let b = vec![track("b1", "B", "1"), track("a2", "A", "2")];
        let c = vec![track("", "C", "x"), track("c1", "C", "1"), track("c2", "C", " ")];
        let ids: Vec<String> = merge_round_robin(vec![a, b, c]).into_iter().map(|t| t.id).collect();
        assert_eq!(ids, vec!["a1", "b1", "c1", "a2", "a3"]);
        assert!(merge_round_robin(Vec::new()).is_empty());
        assert!(merge_round_robin(vec![Vec::new(), Vec::new()]).is_empty());
    }

    #[test]
    fn fallback_title_prefers_the_plan_then_the_request_then_a_default() {
        let mut s = spec(&["A"], &[]);
        s.title = "Rainy Night Code".into();
        assert_eq!(fallback_title(&s, "whatever"), "Rainy Night Code");
        s.title = String::new();
        assert_eq!(fallback_title(&s, "rainy night coding with no lyrics please"), "Rainy night coding with");
        assert_eq!(fallback_title(&s, "ab"), "Your Mix");
        assert_eq!(fallback_title(&s, ""), "Your Mix");
    }

    #[test]
    fn fallback_reason_is_short_and_has_no_markup() {
        let r = fallback_reason("<b>rainy</b> night http://evil.example");
        assert!(r.chars().count() <= MAX_REASON_CHARS);
        assert!(!r.contains('<') && !r.contains("http"));
    }

    #[test]
    fn every_error_message_is_plain_language() {
        for e in [
            PromptError::TooShort,
            PromptError::Off,
            PromptError::NotUnderstood,
            PromptError::CatalogueDown,
            PromptError::TooFewSongs,
            PromptError::TooSlow,
            PromptError::Busy,
            PromptError::Crashed,
            PromptError::Llm(LlmError::Timeout),
        ] {
            let m = e.to_string();
            assert!(m.ends_with('.'), "{m}");
            assert!(!m.contains("Error") && !m.contains("error:"), "{m}");
        }
        assert!(PromptError::Off.to_string().contains("Settings"));
    }
}
