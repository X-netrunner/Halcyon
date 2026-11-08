//! Who is signed in, found without depending on the Spotify Web API.
//!
//! The Web API's `GET /v1/me` is rate limited on the default sign-in (a 429 with a very long wait),
//! and before this module that call was the only source of the account name. The order now is:
//!
//! 1. what is cached (the caller shows it at once, even when old);
//! 2. the streaming session: the canonical username and the plan come from the session itself, and
//!    the name and picture from Spotify's profile service over `spclient` (no Web API quota);
//! 3. `GET /v1/me`, only when 1 and 2 gave no name and no rate-limit wait is running.
//!
//! The functions here are pure (or take the two sources as closures) so the order and the
//! "an empty late answer never wipes a good name" rule are unit-tested without a network.
//! See `docs/profile.md` for what is and is not verified about Spotify's internal endpoint.

use crate::api::AccountInfo;
use std::future::Future;

/// Key of the remembered account in the cache's key/value table.
pub const KV_ACCOUNT: &str = "account.me";

/// What the session could tell us. Every field may be missing.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SessionProfile {
    /// Spotify's canonical user id (`session.username()`).
    pub username: Option<String>,
    pub display_name: Option<String>,
    pub image_url: Option<String>,
    /// "Premium" or "Free".
    pub plan: Option<String>,
}

fn clean(s: &str) -> Option<String> {
    let t = s.trim();
    (!t.is_empty()).then(|| t.to_string())
}

/// Map the session's `type` attribute to the label the GUI shows. Unknown values give `None`
/// (the plan is then left out rather than guessed).
pub fn plan_from_attribute(value: Option<&str>) -> Option<String> {
    match value?.trim().to_ascii_lowercase().as_str() {
        "premium" => Some("Premium".to_string()),
        "free" | "open" => Some("Free".to_string()),
        _ => None,
    }
}

/// Read the name and picture out of the profile service's JSON. The shape is Spotify's internal
/// one and can change, so several spellings are accepted and anything else gives `None` fields.
/// Only an `https://` picture is kept.
pub fn parse_profile_json(body: &str) -> SessionProfile {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else {
        return SessionProfile::default();
    };
    let text = |ptr: &str| v.pointer(ptr).and_then(|x| x.as_str()).and_then(clean);
    let display_name = text("/name").or_else(|| text("/display_name"));
    let image_url = ["/image_url", "/images/0/url", "/image/url"]
        .iter()
        .find_map(|p| text(p))
        .filter(|u| u.starts_with("https://"));
    let username = text("/uri").and_then(|u| u.strip_prefix("spotify:user:").and_then(clean));
    SessionProfile { username, display_name, image_url, plan: None }
}

/// Combine what was cached with what was just learned. A fresh non-empty value wins; an empty or
/// missing one never replaces a value we already hold. `web` is the `/v1/me` answer, if it was
/// asked for. Returns `None` when nothing at all is known.
pub fn merge(
    old: Option<&AccountInfo>,
    session: Option<&SessionProfile>,
    web: Option<&AccountInfo>,
) -> Option<AccountInfo> {
    let pick = |fresh_a: Option<&String>, fresh_b: Option<&String>, old_v: Option<&String>| -> Option<String> {
        [fresh_a, fresh_b, old_v]
            .into_iter()
            .flatten()
            .find_map(|s| clean(s))
    };
    let username = pick(
        session.and_then(|s| s.username.as_ref()),
        web.and_then(|w| w.username.as_ref()),
        old.and_then(|o| o.username.as_ref()),
    );
    let display_name = pick(
        session.and_then(|s| s.display_name.as_ref()),
        web.and_then(|w| w.display_name.as_ref()),
        old.and_then(|o| o.display_name.as_ref()),
    );
    let image_url = pick(
        session.and_then(|s| s.image_url.as_ref()),
        web.and_then(|w| w.image_url.as_ref()),
        old.and_then(|o| o.image_url.as_ref()),
    );
    let plan = pick(
        session.and_then(|s| s.plan.as_ref()),
        web.and_then(|w| w.plan.as_ref()),
        old.and_then(|o| o.plan.as_ref()),
    );
    let id = pick(
        web.map(|w| &w.id),
        old.map(|o| &o.id),
        username.as_ref(),
    )?;
    let looked_up = web.is_some() || session.is_some_and(|s| s.display_name.is_some() || s.image_url.is_some());
    Some(AccountInfo {
        id,
        display_name,
        image_url,
        images_read: old.is_some_and(|o| o.images_read) || looked_up,
        username,
        plan,
    })
}

/// True when the account already has a name worth showing.
pub fn has_name(a: Option<&AccountInfo>) -> bool {
    a.and_then(|a| a.display_name.as_deref()).is_some_and(|n| !n.trim().is_empty())
}

/// Resolve the account in the order described at the top of this file. `session` and `web` are
/// the two sources as closures (so tests can script them); `web_allowed` is false while a Spotify
/// rate-limit wait is running. Neither source failing is an error: the cached account (merged with
/// whatever did arrive) is returned, and `None` only when nothing is known at all.
pub async fn resolve_with<S, SF, W, WF>(
    old: Option<AccountInfo>,
    web_allowed: bool,
    session: S,
    web: W,
) -> Option<AccountInfo>
where
    S: FnOnce() -> SF,
    SF: Future<Output = Result<SessionProfile, String>>,
    W: FnOnce() -> WF,
    WF: Future<Output = Result<AccountInfo, String>>,
{
    let from_session = session().await.ok();
    let session_has_name = from_session.as_ref().and_then(|s| s.display_name.as_ref()).is_some();
    let mut from_web = None;
    if !session_has_name && !has_name(old.as_ref()) && web_allowed {
        from_web = web().await.ok();
    }
    merge(old.as_ref(), from_session.as_ref(), from_web.as_ref())
}

/// Seconds to wait before each further background attempt while the name is still unknown.
pub const RETRY_DELAYS_SECS: [u64; 3] = [10, 60, 600];

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    fn account(id: &str, name: Option<&str>) -> AccountInfo {
        AccountInfo {
            id: id.into(),
            display_name: name.map(str::to_string),
            image_url: None,
            images_read: false,
            username: None,
            plan: None,
        }
    }

    fn session_profile(name: Option<&str>) -> SessionProfile {
        SessionProfile {
            username: Some("ada123".into()),
            display_name: name.map(str::to_string),
            image_url: None,
            plan: Some("Premium".into()),
        }
    }

    #[test]
    fn plan_labels() {
        assert_eq!(plan_from_attribute(Some("premium")).as_deref(), Some("Premium"));
        assert_eq!(plan_from_attribute(Some(" Free ")).as_deref(), Some("Free"));
        assert_eq!(plan_from_attribute(Some("open")).as_deref(), Some("Free"));
        assert_eq!(plan_from_attribute(Some("family-duo")), None);
        assert_eq!(plan_from_attribute(None), None);
    }

    #[test]
    fn parses_the_known_shapes_and_survives_junk() {
        let a = parse_profile_json(r#"{"uri":"spotify:user:ada123","name":" Ada L ","image_url":"https://i.scdn.co/image/x"}"#);
        assert_eq!(a.display_name.as_deref(), Some("Ada L"));
        assert_eq!(a.image_url.as_deref(), Some("https://i.scdn.co/image/x"));
        assert_eq!(a.username.as_deref(), Some("ada123"));
        let b = parse_profile_json(r#"{"display_name":"Ada","images":[{"url":"https://i.scdn.co/image/y"}]}"#);
        assert_eq!(b.display_name.as_deref(), Some("Ada"));
        assert_eq!(b.image_url.as_deref(), Some("https://i.scdn.co/image/y"));
        // A picture over plain http is not kept; an empty name is no name.
        let c = parse_profile_json(r#"{"name":"  ","image_url":"http://example.com/a.png"}"#);
        assert_eq!(c, SessionProfile::default());
        assert_eq!(parse_profile_json("not json"), SessionProfile::default());
        assert_eq!(parse_profile_json("[]"), SessionProfile::default());
    }

    #[test]
    fn an_empty_late_answer_does_not_wipe_the_name() {
        let old = AccountInfo {
            image_url: Some("https://i.scdn.co/image/keep".into()),
            username: Some("ada123".into()),
            plan: Some("Premium".into()),
            ..account("u1", Some("Ada"))
        };
        let empty = SessionProfile::default();
        let merged = merge(Some(&old), Some(&empty), None).expect("known");
        assert_eq!(merged.display_name.as_deref(), Some("Ada"));
        assert_eq!(merged.image_url.as_deref(), Some("https://i.scdn.co/image/keep"));
        assert_eq!(merged.username.as_deref(), Some("ada123"));
        assert_eq!(merged.plan.as_deref(), Some("Premium"));
        assert_eq!(merged.id, "u1");
        // A blank name from the web is also ignored.
        let blank = account("u1", Some("   "));
        let merged = merge(Some(&old), None, Some(&blank)).expect("known");
        assert_eq!(merged.display_name.as_deref(), Some("Ada"));
    }

    #[test]
    fn a_fresh_name_replaces_an_old_one_and_nothing_known_is_none() {
        let old = account("u1", Some("Old Name"));
        let merged = merge(Some(&old), Some(&session_profile(Some("New Name"))), None).expect("known");
        assert_eq!(merged.display_name.as_deref(), Some("New Name"));
        assert!(merged.images_read, "the picture was looked up");
        assert_eq!(merge(None, None, None), None);
        assert_eq!(merge(None, Some(&SessionProfile::default()), None), None);
        // Only the username is known: the account exists, with no name.
        let only_user = merge(None, Some(&SessionProfile { username: Some("ada123".into()), ..Default::default() }), None)
            .expect("username alone is enough");
        assert_eq!(only_user.id, "ada123");
        assert_eq!(only_user.display_name, None);
    }

    fn counting_resolve(
        old: Option<AccountInfo>,
        web_allowed: bool,
        session: Result<SessionProfile, String>,
        web: Result<AccountInfo, String>,
    ) -> (Option<AccountInfo>, usize, usize) {
        let session_calls = Arc::new(AtomicUsize::new(0));
        let web_calls = Arc::new(AtomicUsize::new(0));
        let (sc, wc) = (session_calls.clone(), web_calls.clone());
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("runtime");
        let out = rt.block_on(resolve_with(
            old,
            web_allowed,
            move || async move {
                sc.fetch_add(1, Ordering::SeqCst);
                session
            },
            move || async move {
                wc.fetch_add(1, Ordering::SeqCst);
                web
            },
        ));
        (out, session_calls.load(Ordering::SeqCst), web_calls.load(Ordering::SeqCst))
    }

    #[test]
    fn the_session_name_is_used_and_the_web_api_is_never_asked() {
        let (out, s, w) = counting_resolve(
            None,
            true,
            Ok(session_profile(Some("Ada"))),
            Err("must not be called".into()),
        );
        assert_eq!(out.expect("known").display_name.as_deref(), Some("Ada"));
        assert_eq!((s, w), (1, 0));
    }

    #[test]
    fn the_web_api_is_the_last_resort_and_respects_the_cooldown() {
        // Session knows only the username: with no cooldown, /me is asked.
        let (out, _, w) = counting_resolve(
            None,
            true,
            Ok(session_profile(None)),
            Ok(account("u1", Some("From Web"))),
        );
        assert_eq!(out.expect("known").display_name.as_deref(), Some("From Web"));
        assert_eq!(w, 1);
        // Rate-limited: /me is not asked, and the username still shows.
        let (out, _, w) = counting_resolve(None, false, Ok(session_profile(None)), Ok(account("u1", Some("X"))));
        let out = out.expect("username known");
        assert_eq!(w, 0);
        assert_eq!(out.display_name, None);
        assert_eq!(out.username.as_deref(), Some("ada123"));
    }

    #[test]
    fn a_cached_name_survives_both_sources_failing() {
        let old = account("u1", Some("Ada"));
        let (out, _, w) = counting_resolve(Some(old), true, Err("session down".into()), Err("429".into()));
        assert_eq!(out.expect("cached").display_name.as_deref(), Some("Ada"));
        assert_eq!(w, 0, "a cached name means /me is not needed");
    }
}
