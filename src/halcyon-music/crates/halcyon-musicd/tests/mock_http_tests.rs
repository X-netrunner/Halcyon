//! Part 2 Acceptance Tests with a Mock HTTP Server.
//!
//! Tests:
//! 1. 401 refresh (expired token triggers refresh, retry succeeds)
//! 2. 429 backoff (Retry-After header observed, delay, retry succeeds)
//! 3. pagination (multi-page fetching)
//! 4. timeout (request exceeding timeout fails with ApiError::Timeout)
//! 5. circuit breaker (3 consecutive failures trip circuit for that family)
//! 6. cache expiry (stale-while-revalidate)
//! 7. corrupt DB recovery (corrupted database moved aside, clean start)

use halcyon_music_core::models::Track;
use halcyon_musicd::api::{ApiError, EndpointFamily, SpotifyClient};
use halcyon_musicd::cache::Cache;
use halcyon_musicd::token_store::TokenData;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Lightweight mock HTTP server for integration testing.
struct MockServer {
    addr: SocketAddr,
    request_count: Arc<AtomicUsize>,
    shutdown_tx: Option<tokio::sync::oneshot::Sender<()>>,
}

impl MockServer {
    async fn start<F, Fut>(handler: F) -> Self
    where
        F: Fn(String, usize) -> Fut + Send + Sync + 'static,
        Fut: std::future::Future<Output = (u16, Vec<(String, String)>, String)> + Send + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind mock");
        let addr = listener.local_addr().expect("local_addr");
        let count = Arc::new(AtomicUsize::new(0));
        let count_clone = count.clone();
        let (shutdown_tx, mut shutdown_rx) = tokio::sync::oneshot::channel();
        let handler = Arc::new(handler);

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut shutdown_rx => break,
                    accepted = listener.accept() => {
                        let Ok((mut socket, _)) = accepted else { break };
                        let count = count_clone.clone();
                        let handler = handler.clone();
                        tokio::spawn(async move {
                            let mut buf = [0u8; 4096];
                            let n = socket.read(&mut buf).await.unwrap_or(0);
                            let req = String::from_utf8_lossy(&buf[..n]).to_string();
                            let req_idx = count.fetch_add(1, Ordering::SeqCst);

                            let (status, headers, body) = handler(req, req_idx).await;

                            let status_text = match status {
                                200 => "200 OK",
                                401 => "401 Unauthorized",
                                429 => "429 Too Many Requests",
                                500 => "500 Internal Server Error",
                                _ => "400 Bad Request",
                            };

                            let mut resp = format!("HTTP/1.1 {status_text}\r\nContent-Length: {}\r\nConnection: close\r\n", body.len());
                            for (k, v) in headers {
                                resp.push_str(&format!("{k}: {v}\r\n"));
                            }
                            resp.push_str("\r\n");
                            resp.push_str(&body);

                            let _ = socket.write_all(resp.as_bytes()).await;
                            let _ = socket.flush().await;
                        });
                    }
                }
            }
        });

        Self {
            addr,
            request_count: count,
            shutdown_tx: Some(shutdown_tx),
        }
    }

    fn url(&self, path: &str) -> String {
        format!("http://{}{path}", self.addr)
    }
}

impl Drop for MockServer {
    fn drop(&mut self) {
        if let Some(tx) = self.shutdown_tx.take() {
            let _ = tx.send(());
        }
    }
}

fn sample_token() -> TokenData {
    TokenData::new(
        "test_client".into(),
        "initial_access_token".into(),
        "test_refresh_token".into(),
        3600,
        "Bearer".into(),
        vec!["playlist-read-private".into()],
    )
}

#[tokio::test]
async fn test_401_refresh_and_retry() {
    let server = MockServer::start(|req, idx| async move {
        if req.contains("/api/token") {
            // Token refresh endpoint
            (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"access_token":"refreshed_token","token_type":"Bearer","expires_in":3600,"refresh_token":"test_refresh_token"}"#.into(),
            )
        } else if idx == 0 {
            // First call -> 401
            (
                401,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"error":{"status":401,"message":"The access token expired"}}"#.into(),
            )
        } else {
            // Second call with refreshed token -> 200 OK
            assert!(req.contains("Bearer refreshed_token"), "request did not use refreshed token");
            (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"items":[{"id":"pl1","name":"My Playlist","owner":{"id":"user1"},"snapshot_id":"s1","total_tracks":10}],"total":1,"limit":20,"offset":0,"next":null,"previous":null}"#.into(),
            )
        }
    }).await;

    let client = SpotifyClient::new(
        Some(server.url("/v1")),
        Some(server.url("/api/token")),
    );
    client.set_token(sample_token()).await;

    let res = client.get_playlists(20, 0).await.expect("playlists after refresh");
    assert_eq!(res.items.len(), 1);
    assert_eq!(res.items[0].name, "My Playlist");
    assert!(server.request_count.load(Ordering::SeqCst) >= 2);
}

#[tokio::test]
async fn test_429_rate_limit_backoff() {
    let server = MockServer::start(|_req, idx| async move {
        if idx == 0 {
            // Return 429 with 1s Retry-After
            (
                429,
                vec![
                    ("Retry-After".into(), "1".into()),
                    ("Content-Type".into(), "application/json".into()),
                ],
                r#"{"error":{"status":429,"message":"Rate limit exceeded"}}"#.into(),
            )
        } else {
            // Second call succeeds
            (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"items":[],"total":0,"limit":20,"offset":0,"next":null,"previous":null}"#.into(),
            )
        }
    }).await;

    let client = SpotifyClient::new(
        Some(server.url("/v1")),
        None,
    );
    client.set_token(sample_token()).await;

    let start = std::time::Instant::now();
    let res = client.get_playlists(20, 0).await.expect("playlists after 429 retry");
    assert_eq!(res.total, 0);
    assert!(start.elapsed() >= Duration::from_millis(900), "must respect Retry-After header");
}

#[tokio::test]
async fn test_pagination_multiple_pages() {
    let server = MockServer::start(|req, _idx| async move {
        if req.contains("offset=0") {
            (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"items":[{"id":"pl1","name":"Page 1","owner":{"id":"u1"}}],"total":2,"limit":1,"offset":0,"next":"next","previous":null}"#.into(),
            )
        } else {
            (
                200,
                vec![("Content-Type".into(), "application/json".into())],
                r#"{"items":[{"id":"pl2","name":"Page 2","owner":{"id":"u1"}}],"total":2,"limit":1,"offset":1,"next":null,"previous":"prev"}"#.into(),
            )
        }
    }).await;

    let client = SpotifyClient::new(Some(server.url("/v1")), None);
    client.set_token(sample_token()).await;

    let page1 = client.get_playlists(1, 0).await.expect("page 1");
    assert_eq!(page1.items.len(), 1);
    assert_eq!(page1.items[0].name, "Page 1");

    let page2 = client.get_playlists(1, 1).await.expect("page 2");
    assert_eq!(page2.items.len(), 1);
    assert_eq!(page2.items[0].name, "Page 2");
}

#[tokio::test]
async fn test_circuit_breaker_trips_after_failures() {
    let server = MockServer::start(|_req, _idx| async move {
        (
            500,
            vec![("Content-Type".into(), "application/json".into())],
            r#"{"error":"Internal Server Error"}"#.into(),
        )
    }).await;

    let client = SpotifyClient::new(Some(server.url("/v1")), None);
    client.set_token(sample_token()).await;

    // Fail 3 times
    let _ = client.get_playlists(10, 0).await;
    let _ = client.get_playlists(10, 0).await;
    let _ = client.get_playlists(10, 0).await;

    // 4th request must immediately fail with CircuitOpen without hitting server!
    let err = client.get_playlists(10, 0).await.expect_err("should trip circuit breaker");
    assert!(
        matches!(err, ApiError::CircuitOpen { family: EndpointFamily::Playlists }),
        "expected CircuitOpen, got {err:?}"
    );
}

#[tokio::test]
async fn test_request_timeout() {
    let server = MockServer::start(|_req, _idx| async move {
        // Sleep past the client timeout
        tokio::time::sleep(Duration::from_millis(600)).await;
        (200, vec![], "{}".into())
    }).await;

    // Use 200ms timeout for fast unit testing
    let client = SpotifyClient::with_timeout(Some(server.url("/v1")), None, Duration::from_millis(200));
    client.set_token(sample_token()).await;

    let res = client.get_playlists(1, 0).await;
    assert!(
        matches!(res, Err(ApiError::Timeout) | Err(ApiError::Network(_))),
        "expected Timeout or Network error, got {res:?}"
    );
}

#[test]
fn test_cache_expiry_and_stale_while_revalidate() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let cache = Cache::open(&tmp.path().join("c.db"), &tmp.path().join("imgs"), 1024 * 1024).expect("cache open");

    // Put fresh item with 10s TTL
    cache.kv_set("artist_meta", "fresh_data", 10).expect("kv_set");
    let item = cache.kv_get("artist_meta").expect("get").expect("exists");
    assert_eq!(item.item, "fresh_data");
    assert!(!item.is_stale, "item should be fresh within TTL");

    // Put item with 0s TTL (already expired)
    cache.kv_set("artist_meta_old", "stale_data", 0).expect("kv_set");
    let stale_item = cache.kv_get("artist_meta_old").expect("get").expect("exists");
    assert_eq!(stale_item.item, "stale_data");
    assert!(stale_item.is_stale, "item should be stale when TTL expired");
}

#[test]
fn test_corrupt_database_recovers_without_crashing() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let db_path = tmp.path().join("cache.db");
    let img_dir = tmp.path().join("imgs");

    // Corrupt the database file with garbage
    std::fs::write(&db_path, b"CORRUPTED BY AN ACCIDENTAL PROCESS TERMINATION OR DISK ERROR").expect("write garbage");

    // Opening must automatically move aside corrupt file and initialize clean DB
    let cache = Cache::open(&db_path, &img_dir, 1024 * 1024).expect("must recover cleanly");

    // Verify operations succeed on recovered database
    let t = Track::simple("t1".into(), "Phoenix".into(), "Daft Punk".into(), "Homework".into(), 240_000);
    cache.put_tracks(std::slice::from_ref(&t)).expect("put_tracks");
    let loaded = cache.get_track("t1").expect("get_track").expect("exists");
    assert_eq!(loaded.title, "Phoenix");
}

#[tokio::test]
async fn test_fetch_account_reads_profile_picture() {
    let server = MockServer::start(|req, _idx| async move {
        assert!(req.contains("/v1/me"), "unexpected path: {req}");
        (
            200,
            vec![("Content-Type".into(), "application/json".into())],
            r#"{"id":"u1","display_name":"Ada","images":[{"url":"https://i.scdn.co/image/small","width":64,"height":64},{"url":"https://i.scdn.co/image/big","width":300,"height":300}]}"#.into(),
        )
    })
    .await;
    let client = SpotifyClient::new(Some(server.url("/v1")), None);
    client.set_token(sample_token()).await;

    let account = client.fetch_account().await.expect("account");
    assert_eq!(account.display_name.as_deref(), Some("Ada"));
    assert_eq!(account.image_url.as_deref(), Some("https://i.scdn.co/image/big"));
    assert!(account.images_read);
    assert_eq!(client.cached_account().await, Some(account));
}

#[tokio::test]
async fn test_fetch_account_without_images_still_works() {
    let server = MockServer::start(|_req, _idx| async move {
        (200, vec![("Content-Type".into(), "application/json".into())], r#"{"id":"u1","display_name":"Ada"}"#.into())
    })
    .await;
    let client = SpotifyClient::new(Some(server.url("/v1")), None);
    client.set_token(sample_token()).await;
    let account = client.fetch_account().await.expect("account");
    assert_eq!(account.image_url, None);
}
