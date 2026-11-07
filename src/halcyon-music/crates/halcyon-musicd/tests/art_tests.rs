//! Phase 2 art pipeline: download, cache, de-duplication, safety limits.

use halcyon_music_core::art::ArtSize;
use halcyon_musicd::art::{ArtError, ArtFetcher};
use halcyon_musicd::cache::Cache;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// A JPEG-signature blob: enough for the pipeline, which only sniffs the header.
fn fake_jpeg() -> Vec<u8> {
    let mut v = vec![0xFF, 0xD8, 0xFF, 0xE0];
    v.extend(std::iter::repeat(7u8).take(2048));
    v
}

struct Mock {
    addr: SocketAddr,
    hits: Arc<AtomicUsize>,
}

async fn start_mock() -> Mock {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let hits = Arc::new(AtomicUsize::new(0));
    let hits_c = hits.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else { return };
            let hits = hits_c.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 4096];
                let n = sock.read(&mut buf).await.unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = req.split_whitespace().nth(1).unwrap_or("/").to_string();
                hits.fetch_add(1, Ordering::SeqCst);
                let resp: Vec<u8> = match path.as_str() {
                    p if p.starts_with("/ok") => {
                        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                        let body = fake_jpeg();
                        let mut r = format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        )
                        .into_bytes();
                        r.extend(body);
                        r
                    }
                    "/html" => b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\nConnection: close\r\n\r\n<html>".to_vec(),
                    "/huge" => b"HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\nConnection: close\r\n\r\n".to_vec(),
                    _ => b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec(),
                };
                let _ = sock.write_all(&resp).await;
                let _ = sock.shutdown().await;
            });
        }
    });
    Mock { addr, hits }
}

fn fetcher() -> (ArtFetcher, Cache, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("tempdir");
    let cache = Cache::open(&dir.path().join("c.db"), &dir.path().join("img"), 50 * 1024 * 1024).expect("cache");
    (ArtFetcher::new(cache.clone()), cache, dir)
}

#[tokio::test]
async fn downloads_once_then_serves_from_disk() {
    let mock = start_mock().await;
    let (f, _cache, _dir) = fetcher();
    let url = format!("http://{}/ok1.jpg", mock.addr);

    let p1 = f.fetch(&url, ArtSize::Medium).await.expect("first fetch");
    assert!(p1.exists());
    let p2 = f.fetch(&url, ArtSize::Medium).await.expect("second fetch");
    assert_eq!(p1, p2);
    assert_eq!(mock.hits.load(Ordering::SeqCst), 1, "second call must be a cache hit");
    assert_eq!(f.cached(&url, ArtSize::Medium), Some(p1));
    assert_eq!(f.cached(&url, ArtSize::Small), None, "sizes are cached separately");
}

#[tokio::test]
async fn concurrent_requests_share_one_download() {
    let mock = start_mock().await;
    let (f, _cache, _dir) = fetcher();
    let url = format!("http://{}/ok2.jpg", mock.addr);

    let mut tasks = Vec::new();
    for _ in 0..12 {
        let f = f.clone();
        let url = url.clone();
        tasks.push(tokio::spawn(async move { f.fetch(&url, ArtSize::Small).await }));
    }
    for t in tasks {
        assert!(t.await.expect("join").is_ok());
    }
    assert_eq!(mock.hits.load(Ordering::SeqCst), 1, "in-flight requests must be de-duplicated");
}

#[tokio::test]
async fn rejects_non_images_and_oversize_and_404() {
    let mock = start_mock().await;
    let (f, cache, _dir) = fetcher();

    let html = format!("http://{}/html", mock.addr);
    assert_eq!(f.fetch(&html, ArtSize::Small).await, Err(ArtError::NotAnImage));
    assert!(cache.get_image(&format!("{html}#64")).expect("lookup").is_none(), "garbage must not be cached");

    let huge = format!("http://{}/huge", mock.addr);
    assert!(matches!(f.fetch(&huge, ArtSize::Large).await, Err(ArtError::TooLarge(_))));

    let missing = format!("http://{}/missing", mock.addr);
    assert_eq!(f.fetch(&missing, ArtSize::Small).await, Err(ArtError::Status(404)));
    // A second ask is answered from the failure memory, not the network.
    let before = mock.hits.load(Ordering::SeqCst);
    assert!(matches!(f.fetch(&missing, ArtSize::Small).await, Err(ArtError::RecentlyFailed(_))));
    assert_eq!(mock.hits.load(Ordering::SeqCst), before);
}

#[tokio::test]
async fn refuses_unsafe_urls() {
    let (f, _cache, _dir) = fetcher();
    for bad in ["file:///etc/passwd", "http://example.com/a.jpg", "ftp://x/y", "nonsense"] {
        assert_eq!(f.fetch(bad, ArtSize::Small).await, Err(ArtError::BadUrl), "{bad}");
    }
}

#[tokio::test]
async fn offline_fails_fast_with_a_plain_error() {
    let (f, _cache, _dir) = fetcher();
    // Nothing listens on port 9 (discard) of loopback.
    let started = std::time::Instant::now();
    let r = f.fetch("http://127.0.0.1:9/x.jpg", ArtSize::Small).await;
    assert!(matches!(r, Err(ArtError::Network(_))));
    assert!(started.elapsed() < std::time::Duration::from_secs(15));
}
