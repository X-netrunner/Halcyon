//! `halcyon-musicd --probe`: a PASS/FAIL table of the Web API endpoints the app depends on,
//! run with the token of the current browsing mode (rework Part 4).
//!
//! It only reads (GET). Nothing here prints a token. IDs are never invented: the album check
//! uses an album returned by the artist check, and the artist is the one `probes.rs` already uses.

use crate::api::{ApiError, EndpointFamily, SpotifyClient};
use halcyon_music_core::models::AuthMode;
use reqwest::Method;

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
    match client.request(family, Method::GET, endpoint, &[]).await {
        Ok(body) => {
            let json = serde_json::from_str::<serde_json::Value>(&body).ok();
            (Row { name, pass: Some(true), detail: "ok".into() }, json)
        }
        Err(e) => (Row { name, pass: Some(false), detail: describe(&e) }, None),
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
    let client = SpotifyClient::new(None, None);
    let mode = match client.auth_mode() {
        AuthMode::Librespot => "librespot (default)",
        AuthMode::OwnClientId => "own-client-id (advanced)",
    };
    println!("Browsing token: {mode}");
    if !client.is_authenticated().await {
        println!("Not signed in for this mode. Run `halcyon-musicd --login`, or sign in from the app.");
        return false;
    }

    let mut rows: Vec<Row> = Vec::new();

    for (family, name, endpoint) in [
        (EndpointFamily::Playlists, "playlists", "/me/playlists?limit=1"),
        (EndpointFamily::UserLibrary, "liked songs", "/me/tracks?limit=1"),
        (EndpointFamily::UserLibrary, "saved albums", "/me/albums?limit=1"),
        (EndpointFamily::UserLibrary, "followed artists", "/me/following?type=artist&limit=1"),
    ] {
        rows.push(check(&client, family, name, endpoint).await.0);
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
    rows.push(search);

    // Home feed, Capsule and suggestions are built from these calls.
    for (family, name, endpoint) in [
        (EndpointFamily::Player, "home feed (recently played)", "/me/player/recently-played?limit=1"),
        (EndpointFamily::UserLibrary, "capsule (top tracks)", "/me/top/tracks?limit=1"),
        (EndpointFamily::UserLibrary, "capsule (top artists)", "/me/top/artists?limit=1"),
        (EndpointFamily::Recommendations, "suggestions (recommendations)", "/recommendations?seed_genres=pop&limit=1"),
        (EndpointFamily::Artists, "suggestions (related artists)", "/artists/06HL4z0CvFAxyc27GXpf02/related-artists"),
    ] {
        rows.push(check(&client, family, name, endpoint).await.0);
    }

    let artist_endpoint = format!("/artists/{ARTIST_ID}");
    rows.push(check(&client, EndpointFamily::Artists, "artist detail", &artist_endpoint).await.0);

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
    rows.push(albums_row);
    match album_id {
        Some(id) => {
            let endpoint = format!("/albums/{id}");
            rows.push(check(&client, EndpointFamily::Albums, "album detail", &endpoint).await.0);
        }
        None => rows.push(Row {
            name: "album detail",
            pass: None,
            detail: "skipped (no album found to open)".into(),
        }),
    }

    rows.push(Row {
        name: "lyrics",
        pass: None,
        detail: "not a Spotify call (LRCLIB), unaffected by the sign-in".into(),
    });

    println!("{:<34} {:<6} DETAIL", "ENDPOINT", "RESULT");
    let mut all_ok = true;
    for r in &rows {
        let tag = match r.pass {
            Some(true) => "PASS",
            Some(false) => {
                all_ok = false;
                "FAIL"
            }
            None => "SKIP",
        };
        println!("{:<34} {:<6} {}", r.name, tag, r.detail);
    }
    all_ok
}
