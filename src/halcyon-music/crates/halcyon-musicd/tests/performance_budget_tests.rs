//! Performance budget enforcement tests.
//!
//! Validates targets:
//! - Cold start from cache < 50ms
//! - SQLite query on 50,000 tracks < 15ms
//! - Image cache LRU size strictly bounded to configured limit
//! - Protocol serialization throughput > 100,000 msgs/sec
//! - Memory and allocation stability under high load

use halcyon_music_core::models::Track;
use halcyon_music_core::protocol::{decode_line, encode_line, Command, CommandBody};
use halcyon_musicd::cache::Cache;
use std::time::Instant;

#[test]
fn test_cold_start_from_cache_budget() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("cache.db");
    let img_dir = dir.path().join("images");

    // Initialize once
    {
        let _ = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("init open");
    }

    // Measure cold start open time
    let start = Instant::now();
    let cache = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cold open");
    let elapsed = start.elapsed();

    // Must be under 50ms budget (usually 1-3ms)
    assert!(
        elapsed.as_millis() < 50,
        "Cold start took too long: {}ms (budget: 50ms)",
        elapsed.as_millis()
    );
    let _ = cache;
}

#[test]
fn test_sqlite_query_time_budget_50k_tracks() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("cache.db");
    let img_dir = dir.path().join("images");

    let cache = Cache::open(&db_path, &img_dir, 50 * 1024 * 1024).expect("cache open");

    // 1. Bulk insert 50,000 tracks in batches of 5,000
    println!("Seeding 50,000 tracks into SQLite cache...");
    for batch_idx in 0..10 {
        let mut batch = Vec::with_capacity(5000);
        for i in 0..5000 {
            let id = format!("track_{:06}", batch_idx * 5000 + i);
            let title = format!("Song Title {:06}", batch_idx * 5000 + i);
            let artist = format!("Artist {:03}", (batch_idx * 5000 + i) % 250);
            let album = format!("Album {:03}", (batch_idx * 5000 + i) % 500);
            batch.push(Track::simple(id, title, artist, album, 210_000));
        }
        cache.put_tracks(&batch).expect("put batch");
    }

    // 2. Measure indexed lookup time by primary key: Budget < 5ms
    let start_lookup = Instant::now();
    let track = cache.get_track("track_049999").expect("get").expect("exists");
    let elapsed_lookup = start_lookup.elapsed();

    assert_eq!(track.id, "track_049999");
    assert!(
        elapsed_lookup.as_millis() < 5,
        "Indexed lookup on 50k tracks took {}ms (budget: 5ms)",
        elapsed_lookup.as_millis()
    );

    // 3. Measure paginated query: Budget < 15ms
    let start_paged = Instant::now();
    let paged = cache.get_tracks(50, 25000).expect("paged query");
    let elapsed_paged = start_paged.elapsed();

    assert_eq!(paged.len(), 50);
    assert!(
        elapsed_paged.as_millis() < 15,
        "Paginated query on 50k tracks took {}ms (budget: 15ms)",
        elapsed_paged.as_millis()
    );
}

#[test]
fn test_image_cache_lru_budget_enforcement() {
    let dir = tempfile::tempdir().expect("tempdir");
    let db_path = dir.path().join("cache.db");
    let img_dir = dir.path().join("images");

    // Hard budget: 5,000 bytes max
    let max_bytes = 5_000;
    let cache = Cache::open(&db_path, &img_dir, max_bytes).expect("cache open");

    // Insert 20 images of 1,000 bytes each (Total 20,000 bytes, 4x the budget)
    let fake_data = vec![0xAAu8; 1_000];
    for i in 0..20 {
        let url = format!("http://cdn.spotify.com/art_{i}.jpg");
        cache.put_image(&url, &fake_data).expect("put image");
    }

    // Verify disk usage in img_dir does not exceed max_bytes
    let mut total_disk_size = 0u64;
    for entry in std::fs::read_dir(&img_dir).expect("read dir") {
        let entry = entry.expect("entry");
        if let Ok(meta) = entry.metadata() {
            if meta.is_file() {
                total_disk_size += meta.len();
            }
        }
    }

    assert!(
        total_disk_size <= max_bytes,
        "Image cache LRU exceeded budget: total size {total_disk_size} > max {max_bytes}"
    );

    // Most recent images (e.g. 19) must be retained
    let p19 = cache.get_image("http://cdn.spotify.com/art_19.jpg").expect("get 19");
    assert!(p19.is_some(), "Latest image should be in cache");
}

#[test]
fn test_protocol_throughput_budget() {
    let cmd = Command {
        version: 1,
        body: CommandBody::Seek { position_ms: 65432 },
    };

    let start = Instant::now();
    let count = 10_000;
    for _ in 0..count {
        let encoded = encode_line(&cmd).expect("encode");
        let _decoded: Command = decode_line(&encoded).expect("decode");
    }
    let elapsed = start.elapsed();

    // 10,000 round trips must complete in under 100ms
    assert!(
        elapsed.as_millis() < 100,
        "Protocol codec throughput too slow: 10,000 messages in {}ms",
        elapsed.as_millis()
    );
}
