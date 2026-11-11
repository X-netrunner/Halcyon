//! The model downloader against a small local HTTP server: fresh download, checksum handling,
//! resume after a dropped connection, a server that ignores ranges, cancel, and error cases.

use halcyon_musicd::llm::models::{disk_status, download, DownloadError, Plan, Progress};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const FILE: &str = "tiny.gguf";

fn body(len: usize, seed: u8) -> Vec<u8> {
    let mut v = b"GGUF".to_vec();
    v.extend((0..len - 4).map(|i| (i as u8).wrapping_mul(31).wrapping_add(seed)));
    v
}

fn sha_hex(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}

#[derive(Clone)]
struct Cfg {
    body: Arc<Vec<u8>>,
    /// Sent as `x-linked-etag` (quoted), when set.
    etag: Option<String>,
    /// Claimed total size for the header (defaults to the body length).
    claimed_size: Option<u64>,
    honour_range: bool,
    /// Close the connection after this many body bytes of the first GET.
    cut_first_get_at: Option<usize>,
    pause_per_chunk: Duration,
    status: Option<u16>,
}

impl Cfg {
    fn new(body: Vec<u8>) -> Self {
        let etag = Some(sha_hex(&body));
        Self {
            body: Arc::new(body),
            etag,
            claimed_size: None,
            honour_range: true,
            cut_first_get_at: None,
            pause_per_chunk: Duration::ZERO,
            status: None,
        }
    }
}

#[derive(Default)]
struct Seen {
    ranges: Mutex<Vec<String>>,
    gets: AtomicUsize,
    heads: AtomicUsize,
}

async fn serve(cfg: Cfg) -> (String, Arc<Seen>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("addr");
    let seen = Arc::new(Seen::default());
    let seen2 = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            let cfg = cfg.clone();
            let seen = seen2.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let mut got = 0;
                loop {
                    let Ok(n) = sock.read(&mut buf[got..]).await else {
                        return;
                    };
                    if n == 0 {
                        return;
                    }
                    got += n;
                    if buf[..got].windows(4).any(|w| w == b"\r\n\r\n") {
                        break;
                    }
                }
                let text = String::from_utf8_lossy(&buf[..got]).to_string();
                let mut lines = text.lines();
                let method = lines
                    .next()
                    .unwrap_or("")
                    .split(' ')
                    .next()
                    .unwrap_or("")
                    .to_string();
                let headers: HashMap<String, String> = lines
                    .filter_map(|l| l.split_once(':'))
                    .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
                    .collect();
                let total = cfg.body.len();
                let claimed = cfg.claimed_size.unwrap_or(total as u64);
                let mut extra = String::new();
                if let Some(e) = &cfg.etag {
                    extra.push_str(&format!("x-linked-etag: \"{e}\"\r\n"));
                }
                extra.push_str(&format!("x-linked-size: {claimed}\r\n"));
                if let Some(code) = cfg.status {
                    let _ = sock.write_all(format!("HTTP/1.1 {code} Nope\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).await;
                    return;
                }
                if method == "HEAD" {
                    seen.heads.fetch_add(1, Ordering::SeqCst);
                    let head = format!("HTTP/1.1 200 OK\r\nContent-Length: {total}\r\n{extra}Connection: close\r\n\r\n");
                    let _ = sock.write_all(head.as_bytes()).await;
                    return;
                }
                let n_get = seen.gets.fetch_add(1, Ordering::SeqCst);
                let mut start = 0usize;
                let mut partial = false;
                if let Some(r) = headers.get("range") {
                    seen.ranges.lock().expect("lock").push(r.clone());
                    if cfg.honour_range {
                        if let Some(s) = r
                            .strip_prefix("bytes=")
                            .and_then(|v| v.strip_suffix('-'))
                            .and_then(|v| v.parse::<usize>().ok())
                        {
                            if s >= total {
                                let _ = sock.write_all(b"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
                                return;
                            }
                            start = s;
                            partial = true;
                        }
                    }
                }
                let len = total - start;
                let head = if partial {
                    format!("HTTP/1.1 206 Partial Content\r\nContent-Length: {len}\r\nContent-Range: bytes {start}-{}/{total}\r\n{extra}Connection: close\r\n\r\n", total - 1)
                } else {
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {len}\r\n{extra}Connection: close\r\n\r\n")
                };
                if sock.write_all(head.as_bytes()).await.is_err() {
                    return;
                }
                let mut sent = 0usize;
                for chunk in cfg.body[start..].chunks(65_536) {
                    if n_get == 0 {
                        if let Some(cut) = cfg.cut_first_get_at {
                            if sent >= cut {
                                return; // drop the connection mid-body
                            }
                        }
                    }
                    if sock.write_all(chunk).await.is_err() {
                        return;
                    }
                    sent += chunk.len();
                    if !cfg.pause_per_chunk.is_zero() {
                        tokio::time::sleep(cfg.pause_per_chunk).await;
                    }
                }
                let _ = sock.shutdown().await;
            });
        }
    });
    (format!("http://{addr}/{FILE}"), seen)
}

async fn run(
    url: &str,
    dir: &std::path::Path,
    pinned: Option<&str>,
    cancel: &AtomicBool,
) -> (Result<String, DownloadError>, Vec<Progress>) {
    let plan = Plan {
        url,
        file: FILE,
        pinned_sha: pinned,
        approx_bytes: 1_500_000,
    };
    let events = Arc::new(Mutex::new(Vec::new()));
    let e2 = events.clone();
    let mut on = move |p: Progress| e2.lock().expect("lock").push(p);
    let r = download(&plan, dir, cancel, &mut on).await;
    let v = events.lock().expect("lock").clone();
    (r, v)
}

#[tokio::test]
async fn fresh_download_is_verified_against_the_server_checksum() {
    let data = body(1_500_000, 1);
    let (url, seen) = serve(Cfg::new(data.clone())).await;
    let dir = tempfile::tempdir().expect("dir");
    let (r, events) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert_eq!(r, Ok("server".to_string()));
    assert_eq!(std::fs::read(dir.path().join(FILE)).expect("file"), data);
    let d = disk_status(dir.path(), FILE);
    assert!(d.installed);
    assert_eq!(d.verified, "server");
    assert_eq!(d.partial, 0);
    // no leftovers besides the file and its marker
    let mut names: Vec<String> = std::fs::read_dir(dir.path())
        .expect("dir")
        .map(|e| e.expect("e").file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, vec![FILE.to_string(), format!("{FILE}.verified")]);
    // progress: starts downloading at 0, never goes backwards, ends with done
    assert_eq!(
        events.first().map(|p| (p.state, p.done)),
        Some(("downloading", 0))
    );
    assert!(events
        .windows(2)
        .all(|w| w[0].done <= w[1].done || w[1].state == "verifying"));
    assert_eq!(events.last().map(|p| p.state), Some("done"));
    assert!(events.iter().any(|p| p.state == "verifying"));
    assert_eq!(seen.heads.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_pinned_checksum_wins_and_a_wrong_one_deletes_the_file() {
    let data = body(1_300_000, 2);
    let (url, _) = serve(Cfg::new(data.clone())).await;
    let dir = tempfile::tempdir().expect("dir");
    let (r, _) = run(
        &url,
        dir.path(),
        Some(&sha_hex(&data)),
        &AtomicBool::new(false),
    )
    .await;
    assert_eq!(r, Ok("pinned".to_string()));
    assert_eq!(disk_status(dir.path(), FILE).verified, "pinned");

    let dir2 = tempfile::tempdir().expect("dir");
    let (r, _) = run(
        &url,
        dir2.path(),
        Some(&"0".repeat(64)),
        &AtomicBool::new(false),
    )
    .await;
    assert_eq!(r, Err(DownloadError::Checksum));
    assert_eq!(
        std::fs::read_dir(dir2.path()).expect("dir").count(),
        0,
        "a file that fails its checksum must not stay"
    );
}

#[tokio::test]
async fn a_corrupted_file_fails_the_servers_own_checksum() {
    let good = body(1_300_000, 3);
    let mut cfg = Cfg::new(good.clone());
    let mut bad = good;
    bad[700_000] ^= 0xFF;
    cfg.body = Arc::new(bad); // the checksum header still describes the good file
    let (url, _) = serve(cfg).await;
    let dir = tempfile::tempdir().expect("dir");
    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert_eq!(r, Err(DownloadError::Checksum));
    assert!(!disk_status(dir.path(), FILE).installed);
    assert_eq!(disk_status(dir.path(), FILE).partial, 0);
}

#[tokio::test]
async fn without_any_checksum_the_file_is_marked_size_only() {
    let mut cfg = Cfg::new(body(1_200_000, 4));
    cfg.etag = None;
    let (url, _) = serve(cfg).await;
    let dir = tempfile::tempdir().expect("dir");
    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert_eq!(r, Ok("size".to_string()));
    assert_eq!(disk_status(dir.path(), FILE).verified, "size");
}

#[tokio::test]
async fn a_dropped_connection_keeps_the_partial_file_and_the_next_run_resumes() {
    let data = body(1_600_000, 5);
    let mut cfg = Cfg::new(data.clone());
    cfg.cut_first_get_at = Some(600_000);
    let (url, seen) = serve(cfg).await;
    let dir = tempfile::tempdir().expect("dir");

    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert!(matches!(r, Err(DownloadError::Offline(_))), "{r:?}");
    let partial = disk_status(dir.path(), FILE);
    assert!(!partial.installed);
    assert!(
        partial.partial > 0 && (partial.partial as usize) < data.len(),
        "partial = {}",
        partial.partial
    );

    let (r, events) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert_eq!(r, Ok("server".to_string()));
    assert_eq!(std::fs::read(dir.path().join(FILE)).expect("file"), data);
    // The second run asked for the rest, not everything again, and its first progress is the resume point.
    let ranges = seen.ranges.lock().expect("lock").clone();
    assert_eq!(ranges.len(), 1, "{ranges:?}");
    assert_eq!(ranges[0], format!("bytes={}-", partial.partial));
    assert_eq!(events.first().map(|p| p.done), Some(partial.partial));
}

#[tokio::test]
async fn a_server_that_ignores_ranges_restarts_cleanly() {
    let data = body(1_400_000, 6);
    let mut cfg = Cfg::new(data.clone());
    cfg.honour_range = false;
    cfg.cut_first_get_at = Some(300_000);
    let (url, _) = serve(cfg).await;
    let dir = tempfile::tempdir().expect("dir");
    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert!(r.is_err());
    assert!(disk_status(dir.path(), FILE).partial > 0);
    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert_eq!(r, Ok("server".to_string()));
    assert_eq!(
        std::fs::read(dir.path().join(FILE)).expect("file"),
        data,
        "must not be the old partial glued to a full copy"
    );
}

#[tokio::test]
async fn a_partial_file_from_a_different_download_is_discarded() {
    let data = body(1_400_000, 7);
    let (url, seen) = serve(Cfg::new(data.clone())).await;
    let dir = tempfile::tempdir().expect("dir");
    // Leftovers whose marker names another checksum
    std::fs::write(dir.path().join(format!("{FILE}.part")), vec![9u8; 500_000]).expect("write");
    let meta = format!(
        r#"{{"url":"{url}","sha":"{}","total":1400000}}"#,
        "f".repeat(64)
    );
    std::fs::write(dir.path().join(format!("{FILE}.part.json")), meta).expect("write");
    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert_eq!(r, Ok("server".to_string()));
    assert_eq!(std::fs::read(dir.path().join(FILE)).expect("file"), data);
    assert!(
        seen.ranges.lock().expect("lock").is_empty(),
        "must start from zero, not resume"
    );
}

#[tokio::test]
async fn cancel_stops_early_and_leaves_a_resumable_partial() {
    let data = body(1_800_000, 8);
    let mut cfg = Cfg::new(data.clone());
    cfg.pause_per_chunk = Duration::from_millis(30);
    let (url, _) = serve(cfg).await;
    let dir = tempfile::tempdir().expect("dir");
    let cancel = Arc::new(AtomicBool::new(false));
    let c2 = cancel.clone();
    let plan = Plan {
        url: &url,
        file: FILE,
        pinned_sha: None,
        approx_bytes: 1_800_000,
    };
    let mut on = move |p: Progress| {
        if p.state == "downloading" && p.done > 200_000 {
            c2.store(true, Ordering::SeqCst);
        }
    };
    let r = download(&plan, dir.path(), &cancel, &mut on).await;
    assert_eq!(r, Err(DownloadError::Cancelled));
    let d = disk_status(dir.path(), FILE);
    assert!(!d.installed && d.partial > 0 && (d.partial as usize) < data.len());
    // and it finishes afterwards
    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert_eq!(r, Ok("server".to_string()));
    assert_eq!(std::fs::read(dir.path().join(FILE)).expect("file"), data);
}

#[tokio::test]
async fn server_errors_and_an_unreachable_server_are_plain_errors() {
    let mut cfg = Cfg::new(body(1_200_000, 9));
    cfg.status = Some(404);
    let (url, _) = serve(cfg).await;
    let dir = tempfile::tempdir().expect("dir");
    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert_eq!(r, Err(DownloadError::Server(404)));

    // nothing listens here
    let (r, _) = run(
        "http://127.0.0.1:9/none.gguf",
        dir.path(),
        None,
        &AtomicBool::new(false),
    )
    .await;
    assert!(matches!(r, Err(DownloadError::Offline(_))), "{r:?}");
    assert!(r.expect_err("offline").to_string().contains("try again"));
}

#[tokio::test]
async fn too_little_free_disk_is_refused_before_any_download() {
    let mut cfg = Cfg::new(body(1_200_000, 10));
    cfg.claimed_size = Some(900_000_000_000_000); // 900 TB
    let (url, seen) = serve(cfg).await;
    let dir = tempfile::tempdir().expect("dir");
    let (r, _) = run(&url, dir.path(), None, &AtomicBool::new(false)).await;
    assert!(matches!(r, Err(DownloadError::DiskFull { .. })), "{r:?}");
    assert_eq!(
        seen.gets.load(Ordering::SeqCst),
        0,
        "no bytes should be fetched when the disk cannot hold the file"
    );
}
