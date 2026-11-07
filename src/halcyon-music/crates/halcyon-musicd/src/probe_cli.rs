//! `halcyon-musicd --probe`: a PASS/FAIL table of the Web API endpoints the app depends on,
//! run with the token of the current browsing mode (rework Part 4).
//!
//! It only reads (GET). Nothing here prints a token. IDs are never invented: the album check
//! uses an album returned by the artist check, and the artist is the one `probes.rs` already uses.

use crate::api::{ApiError, EndpointFamily, SpotifyClient};
use crate::token_store::{load_librespot_token, LIBRESPOT_SCOPES};
use halcyon_music_core::models::AuthMode;
use reqwest::Method;
use std::io::Write;
use std::time::Duration;

/// The longest one check may take. A call can otherwise sit for a long time inside the client's
/// retry loop (it honours a 429 `Retry-After` by sleeping), and a table that prints only at the
/// end then looks like a hang.
const CHECK_TIMEOUT: Duration = Duration::from_secs(30);

/// Same artist the endpoint probes use (`probes.rs`).
const ARTIST_ID: &str = "06HL4z0CvFAxyc27GXpf02";

struct Row {
    name: &'static str,
    pass: Option<bool>, // None = skipped
    detail: String,
}

fn describe(e: &ApiError) -> String {
    match e {
        ApiError::Http { status, .. } => format!("HTTP {status}"),
        ApiError::AuthRequired(_) => "not signed in".to_string(),
        ApiError::Timeout => "timed out".to_string(),
        ApiError::RateLimited(s) if *s >= 3600 => {
            format!("rate limited by Spotify for about {} h (Retry-After {s}s)", s / 3600)
        }
        ApiError::RateLimited(s) => format!("rate limited ({s}s)"),
        ApiError::CircuitOpen { .. } => "cooling down after errors".to_string(),
        ApiError::Network(_) | ApiError::Serialization(_) => "network/format error".to_string(),
    }
}

async fn check(
    client: &SpotifyClient,
    family: EndpointFamily,
    name: &'static str,
    endpoint: &str,
) -> (Row, Option<serde_json::Value>) {
    let call = client.request(family, Method::GET, endpoint, &[]);
    match tokio::time::timeout(CHECK_TIMEOUT, call).await {
        Ok(Ok(body)) => {
            let json = serde_json::from_str::<serde_json::Value>(&body).ok();
            (Row { name, pass: Some(true), detail: "ok".into() }, json)
        }
        Ok(Err(e)) => (Row { name, pass: Some(false), detail: describe(&e) }, None),
        Err(_) => (
            Row {
                name,
                pass: Some(false),
                detail: format!(
                    "no answer within {} s (a long rate-limit wait, or the network); see the log lines above",
                    CHECK_TIMEOUT.as_secs()
                ),
            },
            None,
        ),
    }
}

fn print_row(r: &Row) {
    let tag = match r.pass {
        Some(true) => "PASS",
        Some(false) => "FAIL",
        None => "SKIP",
    };
    println!("{:<34} {:<6} {}", r.name, tag, r.detail);
    let _ = std::io::stdout().flush();
}

/// Show a row the moment it is known, and keep it for the summary.
fn emit(rows: &mut Vec<Row>, row: Row) {
    print_row(&row);
    rows.push(row);
}

/// Warnings from the API client (endpoint + HTTP status of every failed call) go to stderr, so
/// they appear between the rows. `RUST_LOG` overrides the level.
fn init_logging() {
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .try_init();
}

/// What the stored streaming token says about itself: time left and granted scopes. Scope names
/// and a minute count are not secrets; the token text is never printed.
fn print_token_summary() {
    match load_librespot_token() {
        Ok(Some(t)) => {
            let missing: Vec<&str> = LIBRESPOT_SCOPES
                .iter()
                .copied()
                .filter(|wanted| !t.scopes.iter().any(|g| g.as_str() == *wanted))
                .collect();
            let missing_text = if missing.is_empty() {
                "none missing".to_string()
            } else {
                format!("missing: {}", missing.join(", "))
            };
            println!(
                "Streaming token: {} min left, {} scopes granted ({missing_text})",
                t.seconds_left() / 60,
                t.scopes.len()
            );
        }
        Ok(None) => println!("Streaming token: none stored"),
        Err(_) => println!("Streaming token: stored, but could not be read"),
    }
}

fn items_len(json: &Option<serde_json::Value>, key: &str) -> Option<usize> {
    json.as_ref()?
        .get(key)?
        .get("items")?
        .as_array()
        .map(|a| a.len())
}

pub async fn run() -> bool {
    init_logging();
    let client = SpotifyClient::new(None, None);
    let mode = match client.auth_mode() {
        AuthMode::Librespot => "librespot (default)",
        AuthMode::OwnClientId => "own-client-id (advanced)",
    };
    println!("Browsing token: {mode}");
    if client.auth_mode() == AuthMode::Librespot {
        print_token_summary();
    }
    if !client.is_authenticated().await {
        println!("Not signed in for this mode. Run `halcyon-musicd --login`, or sign in from the app.");
        return false;
    }

    println!("{:<34} {:<6} DETAIL", "ENDPOINT", "RESULT");
    let mut rows: Vec<Row> = Vec::new();

    // Does Spotify accept this token on the Web API at all?
    emit(&mut rows, check(&client, EndpointFamily::Other, "account (/me)", "/me").await.0);

    for (family, name, endpoint) in [
        (EndpointFamily::Playlists, "playlists", "/me/playlists?limit=1"),
        (EndpointFamily::UserLibrary, "liked songs", "/me/tracks?limit=1"),
        (EndpointFamily::UserLibrary, "saved albums", "/me/albums?limit=1"),
        (EndpointFamily::UserLibrary, "followed artists", "/me/following?type=artist&limit=1"),
    ] {
        emit(&mut rows, check(&client, family, name, endpoint).await.0);
    }

    // Search: ask for 50 and report what comes back (Spotify's Feb 2026 rules cap it at 10).
    let (mut search, json) = check(
        &client,
        EndpointFamily::Search,
        "search",
        "/search?q=daft%20punk&type=track&limit=50",
    )
    .await;
    if search.pass == Some(true) {
        let got = items_len(&json, "tracks").unwrap_or(0);
        search.detail = format!("limit 50 asked, {got} results returned");
    } else {
        let (retry, json10) = check(&client, EndpointFamily::Search, "search", "/search?q=daft%20punk&type=track&limit=10").await;
        search.detail = if retry.pass == Some(true) {
            format!(
                "limit 50 refused ({}); limit 10 works, {} results",
                search.detail,
                items_len(&json10, "tracks").unwrap_or(0)
            )
        } else {
            search.detail
        };
        search.pass = retry.pass;
    }
    emit(&mut rows, search);

    // Home feed, Capsule and suggestions are built from these calls.
    for (family, name, endpoint) in [
        (EndpointFamily::Player, "home feed (recently played)", "/me/player/recently-played?limit=1"),
        (EndpointFamily::UserLibrary, "capsule (top tracks)", "/me/top/tracks?limit=1"),
        (EndpointFamily::UserLibrary, "capsule (top artists)", "/me/top/artists?limit=1"),
        (EndpointFamily::Recommendations, "suggestions (recommendations)", "/recommendations?seed_genres=pop&limit=1"),
        (EndpointFamily::Artists, "suggestions (related artists)", "/artists/06HL4z0CvFAxyc27GXpf02/related-artists"),
    ] {
        emit(&mut rows, check(&client, family, name, endpoint).await.0);
    }

    let artist_endpoint = format!("/artists/{ARTIST_ID}");
    emit(&mut rows, check(&client, EndpointFamily::Artists, "artist detail", &artist_endpoint).await.0);

    let albums_endpoint = format!("/artists/{ARTIST_ID}/albums?limit=1");
    let (albums_row, albums_json) = check(&client, EndpointFamily::Albums, "artist albums", &albums_endpoint).await;
    let album_id = albums_json
        .as_ref()
        .and_then(|j| j.get("items"))
        .and_then(|i| i.as_array())
        .and_then(|a| a.first())
        .and_then(|first| first.get("id"))
        .and_then(|id| id.as_str())
        .map(str::to_string);
    emit(&mut rows, albums_row);
    match album_id {
        Some(id) => {
            let endpoint = format!("/albums/{id}");
            emit(&mut rows, check(&client, EndpointFamily::Albums, "album detail", &endpoint).await.0);
        }
        None => emit(
            &mut rows,
            Row {
                name: "album detail",
                pass: None,
                detail: "skipped (no album found to open)".into(),
            },
        ),
    }

    emit(
        &mut rows,
        Row {
            name: "lyrics",
            pass: None,
            detail: "not a Spotify call (LRCLIB), unaffected by the sign-in".into(),
        },
    );

    let passed = rows.iter().filter(|r| r.pass == Some(true)).count();
    let failed = rows.iter().filter(|r| r.pass == Some(false)).count();
    let skipped = rows.iter().filter(|r| r.pass.is_none()).count();
    println!("\n{passed} PASS, {failed} FAIL, {skipped} SKIP");
    failed == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failures_are_described_without_the_response_body() {
        let e = ApiError::Http { status: 403, message: "Bearer secret".into() };
        assert_eq!(describe(&e), "HTTP 403");
        assert_eq!(describe(&ApiError::RateLimited(7)), "rate limited (7s)");
        assert!(describe(&ApiError::RateLimited(86_400)).contains("24 h"));
    }

    #[test]
    fn items_len_reads_nested_items() {
        let json = serde_json::json!({ "tracks": { "items": [1, 2, 3] } });
        assert_eq!(items_len(&Some(json), "tracks"), Some(3));
        assert_eq!(items_len(&None, "tracks"), None);
    }
}
