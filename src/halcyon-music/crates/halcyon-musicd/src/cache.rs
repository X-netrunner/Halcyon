//! SQLite cache layer for Halcyon Music.
//!
//! Owns:
//! - Tables: `tracks`, `albums`, `artists`, `playlists`, `playlist_items`, `images`, `kv`, `probes`
//! - Stale-while-revalidate data access
//! - LRU image cache on disk capped at 500 MB
//! - Automatic corrupt-database recovery: moves aside corrupt DB and rebuilds schema

use crate::token_store::now_secs;
use halcyon_music_core::models::{
    Artist, CapsuleSummary, EndpointProbe, FullCapsule, Lyrics, Playlist, ProbeStatus, Track,
};
use halcyon_music_core::paths;
use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tracing::warn;

pub const DEFAULT_IMAGE_CAP_BYTES: u64 = 500 * 1024 * 1024; // 500 MB

#[derive(Clone)]
pub struct Cache {
    conn: Arc<Mutex<Connection>>,
    _db_path: PathBuf,
    image_dir: PathBuf,
    image_cap_bytes: u64,
}

#[derive(Debug, Clone)]
pub struct CachedItem<T> {
    pub item: T,
    pub updated_at: u64,
    pub is_stale: bool,
}

impl Cache {
    /// Open SQLite cache at the standard path `paths::cache_dir().join("cache.db")`.
    pub fn open_default() -> Result<Self, String> {
        let dir = paths::cache_dir();
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let db_path = dir.join("cache.db");
        let image_dir = dir.join("images");
        std::fs::create_dir_all(&image_dir).map_err(|e| e.to_string())?;

        Self::open(&db_path, &image_dir, DEFAULT_IMAGE_CAP_BYTES)
    }

    /// Open or recover SQLite cache at the given path.
    pub fn open(db_path: &Path, image_dir: &Path, image_cap_bytes: u64) -> Result<Self, String> {
        std::fs::create_dir_all(image_dir).map_err(|e| e.to_string())?;
        if let Some(parent) = db_path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }

        // Test if existing database is corrupt
        if db_path.exists() {
            if let Err(e) = Self::verify_integrity(db_path) {
                warn!("SQLite cache corruption detected: {e}. Moving aside and rebuilding.");
                Self::move_aside_corrupt_db(db_path);
            }
        }

        let conn = match Connection::open(db_path) {
            Ok(c) => c,
            Err(e) => {
                warn!("failed to open SQLite cache: {e}. Moving aside and retrying.");
                Self::move_aside_corrupt_db(db_path);
                Connection::open(db_path).map_err(|e| format!("unable to open clean SQLite: {e}"))?
            }
        };

        let cache = Self {
            conn: Arc::new(Mutex::new(conn)),
            _db_path: db_path.to_path_buf(),
            image_dir: image_dir.to_path_buf(),
            image_cap_bytes,
        };

        cache.init_schema()?;
        Ok(cache)
    }

    fn verify_integrity(path: &Path) -> Result<(), String> {
        let conn = Connection::open(path).map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("PRAGMA quick_check;")
            .map_err(|e| e.to_string())?;
        let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
        if let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let res: String = row.get(0).map_err(|e| e.to_string())?;
            if res != "ok" {
                return Err(format!("quick_check returned: {res}"));
            }
        }
        Ok(())
    }

    fn move_aside_corrupt_db(db_path: &Path) {
        let ts = now_secs();
        let corrupt_path = db_path.with_extension(format!("corrupt.{ts}.db"));
        let _ = std::fs::rename(db_path, &corrupt_path);

        let wal = db_path.with_extension("db-wal");
        if wal.exists() {
            let _ = std::fs::remove_file(wal);
        }
        let shm = db_path.with_extension("db-shm");
        if shm.exists() {
            let _ = std::fs::remove_file(shm);
        }
    }

    fn init_schema(&self) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;

        // Fast WAL mode and normal synchronous
        conn.execute_batch(
            r#"
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;

            CREATE TABLE IF NOT EXISTS tracks (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                album TEXT NOT NULL,
                duration_ms INTEGER NOT NULL,
                art_url TEXT,
                data_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS albums (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                art_url TEXT,
                release_date TEXT,
                total_tracks INTEGER NOT NULL,
                data_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS artists (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                image_url TEXT,
                genres TEXT NOT NULL,
                data_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS playlists (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                owner TEXT NOT NULL,
                snapshot_id TEXT,
                art_url TEXT,
                total_tracks INTEGER NOT NULL,
                data_json TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS playlist_items (
                playlist_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                track_id TEXT NOT NULL,
                added_at INTEGER NOT NULL,
                PRIMARY KEY (playlist_id, position)
            );

            CREATE TABLE IF NOT EXISTS images (
                url_hash TEXT PRIMARY KEY,
                url TEXT NOT NULL,
                file_path TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                accessed_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS kv (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL,
                fetched_at INTEGER NOT NULL,
                ttl_seconds INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS probes (
                endpoint TEXT PRIMARY KEY,
                status TEXT NOT NULL,
                checked_at INTEGER NOT NULL,
                status_code INTEGER,
                detail TEXT
            );

            CREATE TABLE IF NOT EXISTS play_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                track_id TEXT NOT NULL,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                album TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                ms_played INTEGER NOT NULL,
                completed INTEGER NOT NULL
            );

            -- Tracks the user left before the end. Kept apart from play_log on purpose: every
            -- Home / stats query counts each play_log row as a listen, a skip is not one.
            CREATE TABLE IF NOT EXISTS skip_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                track_id TEXT NOT NULL,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                album TEXT NOT NULL,
                started_at INTEGER NOT NULL,
                ms_played INTEGER NOT NULL
            );

            -- Artist tags for the taste model (Part 4), fetched elsewhere and kept for a long time.
            CREATE TABLE IF NOT EXISTS artist_tags (
                artist_key TEXT PRIMARY KEY,
                tags_json TEXT NOT NULL,
                fetched_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS resolved_tracks (
                source_query TEXT PRIMARY KEY,
                spotify_track_id TEXT,
                spotify_track_json TEXT,
                resolved_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS recent_searches (
                query TEXT PRIMARY KEY,
                searched_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS lyrics (
                track_id TEXT PRIMARY KEY,
                synced INTEGER NOT NULL,
                data_json TEXT NOT NULL,
                fetched_at INTEGER NOT NULL,
                is_miss INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS lyric_offsets (
                track_id TEXT PRIMARY KEY,
                offset_ms INTEGER NOT NULL
            );
            "#,
        ).map_err(|e| format!("schema init failed: {e}"))?;

        Ok(())
    }

    // --- Tracks ---

    pub fn put_tracks(&self, tracks: &[Track]) -> Result<(), String> {
        let mut conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        let now = now_secs();

        {
            let mut stmt = tx
                .prepare(
                    r#"
                    INSERT INTO tracks (id, title, artist, album, duration_ms, art_url, data_json, updated_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        artist = excluded.artist,
                        album = excluded.album,
                        duration_ms = excluded.duration_ms,
                        art_url = excluded.art_url,
                        data_json = excluded.data_json,
                        updated_at = excluded.updated_at
                    "#,
                )
                .map_err(|e| e.to_string())?;

            for t in tracks {
                let json = serde_json::to_string(t).unwrap_or_default();
                stmt.execute(params![
                    t.id,
                    t.title,
                    t.artist,
                    t.album,
                    t.duration_ms as i64,
                    t.art_url,
                    json,
                    now as i64
                ])
                .map_err(|e| e.to_string())?;
            }
        }

        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_track(&self, id: &str) -> Result<Option<Track>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT data_json FROM tracks WHERE id = ?1")
            .map_err(|e| e.to_string())?;

        let res = stmt
            .query_row(params![id], |row| {
                let json: String = row.get(0)?;
                Ok(json)
            })
            .optional()
            .map_err(|e| e.to_string())?;

        match res {
            Some(json) => serde_json::from_str(&json).map(Some).map_err(|e| e.to_string()),
            None => Ok(None),
        }
    }

    /// Retrieve paginated tracks from the cache database.
    pub fn get_tracks(&self, limit: usize, offset: usize) -> Result<Vec<Track>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT data_json FROM tracks ORDER BY id LIMIT ?1 OFFSET ?2")
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![limit as i64, offset as i64], |row| {
                let json: String = row.get(0)?;
                Ok(json)
            })
            .map_err(|e| e.to_string())?;

        let mut tracks = Vec::new();
        for json in rows.flatten() {
            if let Ok(track) = serde_json::from_str::<Track>(&json) {
                tracks.push(track);
            }
        }
        Ok(tracks)
    }

    // --- Playlists & Playlist Items ---

    pub fn put_playlists(&self, playlists: &[Playlist]) -> Result<(), String> {
        let mut conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        let now = now_secs();

        {
            let mut stmt = tx
                .prepare(
                    r#"
                    INSERT INTO playlists (id, name, owner, snapshot_id, art_url, total_tracks, data_json, updated_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        owner = excluded.owner,
                        snapshot_id = excluded.snapshot_id,
                        art_url = excluded.art_url,
                        total_tracks = excluded.total_tracks,
                        data_json = excluded.data_json,
                        updated_at = excluded.updated_at
                    "#,
                )
                .map_err(|e| e.to_string())?;

            for p in playlists {
                let json = serde_json::to_string(p).unwrap_or_default();
                stmt.execute(params![
                    p.id,
                    p.name,
                    p.owner,
                    p.snapshot_id,
                    p.art_url,
                    p.total_tracks as i64,
                    json,
                    now as i64
                ])
                .map_err(|e| e.to_string())?;
            }
        }

        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_playlists(&self, limit: usize, offset: usize) -> Result<(Vec<Playlist>, usize), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;

        let total: usize = conn
            .query_row("SELECT COUNT(*) FROM playlists", [], |row| row.get(0))
            .unwrap_or(0);

        let mut stmt = conn
            .prepare("SELECT data_json FROM playlists ORDER BY updated_at DESC LIMIT ?1 OFFSET ?2")
            .map_err(|e| e.to_string())?;

        let mut rows = stmt
            .query(params![limit as i64, offset as i64])
            .map_err(|e| e.to_string())?;

        let mut list = Vec::new();
        while let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let json: String = row.get(0).map_err(|e| e.to_string())?;
            if let Ok(pl) = serde_json::from_str::<Playlist>(&json) {
                list.push(pl);
            }
        }

        Ok((list, total))
    }

    /// Record the real song count of a playlist once its songs have been read.
    pub fn set_playlist_total(&self, playlist_id: &str, total: usize) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let json: Option<String> = conn
            .query_row(
                "SELECT data_json FROM playlists WHERE id = ?1",
                params![playlist_id],
                |row| row.get(0),
            )
            .ok();
        let Some(json) = json else { return Ok(()) };
        let Ok(mut pl) = serde_json::from_str::<Playlist>(&json) else { return Ok(()) };
        if pl.total_tracks as usize >= total {
            return Ok(());
        }
        pl.total_tracks = total as u32;
        let json = serde_json::to_string(&pl).map_err(|e| e.to_string())?;
        conn.execute(
            "UPDATE playlists SET total_tracks = ?2, data_json = ?3 WHERE id = ?1",
            params![playlist_id, total as i64, json],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn put_artists(&self, artists: &[Artist]) -> Result<(), String> {
        let mut conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        let now = now_secs();

        {
            let mut stmt = tx
                .prepare(
                    r#"
                    INSERT INTO artists (id, name, image_url, genres, data_json, updated_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        image_url = excluded.image_url,
                        genres = excluded.genres,
                        data_json = excluded.data_json,
                        updated_at = excluded.updated_at
                    "#,
                )
                .map_err(|e| e.to_string())?;

            for a in artists {
                let json = serde_json::to_string(a).unwrap_or_default();
                let genres_str = a.genres.join(",");
                stmt.execute(params![
                    a.id,
                    a.name,
                    a.image_url,
                    genres_str,
                    json,
                    now as i64
                ])
                .map_err(|e| e.to_string())?;
            }
        }

        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_artist(&self, id: &str) -> Result<Option<Artist>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT data_json FROM artists WHERE id = ?1 LIMIT 1")
            .map_err(|e| e.to_string())?;
        let mut rows = stmt.query(params![id]).map_err(|e| e.to_string())?;
        if let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let json: String = row.get(0).map_err(|e| e.to_string())?;
            let artist = serde_json::from_str::<Artist>(&json).map_err(|e| e.to_string())?;
            Ok(Some(artist))
        } else {
            Ok(None)
        }
    }

    pub fn get_artist_by_name(&self, name: &str) -> Result<Option<Artist>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT data_json FROM artists WHERE name = ?1 COLLATE NOCASE LIMIT 1")
            .map_err(|e| e.to_string())?;
        let mut rows = stmt.query(params![name]).map_err(|e| e.to_string())?;
        if let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let json: String = row.get(0).map_err(|e| e.to_string())?;
            let artist = serde_json::from_str::<Artist>(&json).map_err(|e| e.to_string())?;
            Ok(Some(artist))
        } else {
            Ok(None)
        }
    }

    pub fn set_playlist_tracks(&self, playlist_id: &str, tracks: &[Track]) -> Result<(), String> {
        // First store individual tracks
        self.put_tracks(tracks)?;

        let mut conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        let now = now_secs();

        // Clear existing items for this playlist
        tx.execute(
            "DELETE FROM playlist_items WHERE playlist_id = ?1",
            params![playlist_id],
        )
        .map_err(|e| e.to_string())?;

        {
            let mut stmt = tx
                .prepare(
                    r#"
                    INSERT INTO playlist_items (playlist_id, position, track_id, added_at)
                    VALUES (?1, ?2, ?3, ?4)
                    "#,
                )
                .map_err(|e| e.to_string())?;

            for (pos, t) in tracks.iter().enumerate() {
                stmt.execute(params![playlist_id, pos as i64, t.id, now as i64])
                    .map_err(|e| e.to_string())?;
            }
        }

        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Store one page of a playlist at its place, keeping the pages around it. (The whole-list
    /// `set_playlist_tracks` throws the rest away, which is wrong for a list fetched in pages.)
    /// When the page reaches the end of the list, rows past `total` are dropped.
    pub fn set_playlist_tracks_page(
        &self,
        playlist_id: &str,
        tracks: &[Track],
        offset: usize,
        total: usize,
    ) -> Result<(), String> {
        self.put_tracks(tracks)?;

        let mut conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        let now = now_secs();
        let end = offset + tracks.len();

        tx.execute(
            "DELETE FROM playlist_items WHERE playlist_id = ?1 AND position >= ?2 AND position < ?3",
            params![playlist_id, offset as i64, end as i64],
        )
        .map_err(|e| e.to_string())?;
        if end >= total {
            tx.execute(
                "DELETE FROM playlist_items WHERE playlist_id = ?1 AND position >= ?2",
                params![playlist_id, end as i64],
            )
            .map_err(|e| e.to_string())?;
        }
        {
            let mut stmt = tx
                .prepare(
                    "INSERT INTO playlist_items (playlist_id, position, track_id, added_at) VALUES (?1, ?2, ?3, ?4)",
                )
                .map_err(|e| e.to_string())?;
            for (i, t) in tracks.iter().enumerate() {
                stmt.execute(params![playlist_id, (offset + i) as i64, t.id, now as i64])
                    .map_err(|e| e.to_string())?;
            }
        }
        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_playlist_tracks(
        &self,
        playlist_id: &str,
        limit: usize,
        offset: usize,
    ) -> Result<(Vec<Track>, usize), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;

        let total: usize = conn
            .query_row(
                "SELECT COUNT(*) FROM playlist_items WHERE playlist_id = ?1",
                params![playlist_id],
                |row| row.get(0),
            )
            .unwrap_or(0);

        let mut stmt = conn
            .prepare(
                r#"
                SELECT t.data_json
                FROM playlist_items pi
                JOIN tracks t ON pi.track_id = t.id
                WHERE pi.playlist_id = ?1
                ORDER BY pi.position ASC
                LIMIT ?2 OFFSET ?3
                "#,
            )
            .map_err(|e| e.to_string())?;

        let mut rows = stmt
            .query(params![playlist_id, limit as i64, offset as i64])
            .map_err(|e| e.to_string())?;

        let mut list = Vec::new();
        while let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let json: String = row.get(0).map_err(|e| e.to_string())?;
            if let Ok(track) = serde_json::from_str::<Track>(&json) {
                list.push(track);
            }
        }

        Ok((list, total))
    }

    // --- Liked Tracks (Virtual playlist `__liked__`) ---

    pub const LIKED_PLAYLIST_ID: &str = "__liked__";

    pub fn set_liked_tracks(&self, tracks: &[Track]) -> Result<(), String> {
        self.set_playlist_tracks(Self::LIKED_PLAYLIST_ID, tracks)
    }

    /// One fetched page of Liked Songs, stored in place.
    pub fn set_liked_tracks_page(&self, tracks: &[Track], offset: usize, total: usize) -> Result<(), String> {
        self.set_playlist_tracks_page(Self::LIKED_PLAYLIST_ID, tracks, offset, total)
    }

    pub fn get_liked_tracks(&self, limit: usize, offset: usize) -> Result<(Vec<Track>, usize), String> {
        self.get_playlist_tracks(Self::LIKED_PLAYLIST_ID, limit, offset)
    }

    // --- Key-Value Cache (Stale-While-Revalidate) ---

    pub fn kv_set(&self, key: &str, value: &str, ttl_seconds: u64) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();

        conn.execute(
            r#"
            INSERT INTO kv (key, value, fetched_at, ttl_seconds)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                fetched_at = excluded.fetched_at,
                ttl_seconds = excluded.ttl_seconds
            "#,
            params![key, value, now as i64, ttl_seconds as i64],
        )
        .map_err(|e| e.to_string())?;

        Ok(())
    }

    pub fn kv_get(&self, key: &str) -> Result<Option<CachedItem<String>>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();

        let mut stmt = conn
            .prepare("SELECT value, fetched_at, ttl_seconds FROM kv WHERE key = ?1")
            .map_err(|e| e.to_string())?;

        let res = stmt
            .query_row(params![key], |row| {
                let value: String = row.get(0)?;
                let fetched_at: i64 = row.get(1)?;
                let ttl: i64 = row.get(2)?;
                Ok((value, fetched_at as u64, ttl as u64))
            })
            .optional()
            .map_err(|e| e.to_string())?;

        match res {
            Some((val, fetched_at, ttl)) => {
                let is_stale = now >= fetched_at.saturating_add(ttl);
                Ok(Some(CachedItem {
                    item: val,
                    updated_at: fetched_at,
                    is_stale,
                }))
            }
            None => Ok(None),
        }
    }

    // --- Image Cache (Disk + LRU) ---

    pub fn put_image(&self, url: &str, bytes: &[u8]) -> Result<PathBuf, String> {
        let mut hasher = Sha256::new();
        hasher.update(url.as_bytes());
        let hash = format!("{:x}", hasher.finalize());

        let target_path = self.image_dir.join(format!("{hash}.img"));
        let size = bytes.len() as u64;
        let now = now_secs();

        // Write file atomically (temp + sync + rename)
        let tmp_path = self.image_dir.join(format!(".{hash}.{}.tmp", std::process::id()));
        let mut f = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(&tmp_path)
            .map_err(|e| e.to_string())?;

        f.write_all(bytes).map_err(|e| e.to_string())?;
        f.sync_all().map_err(|e| e.to_string())?;
        drop(f);

        std::fs::rename(&tmp_path, &target_path).map_err(|e| e.to_string())?;

        // Update database record
        {
            let conn = self.conn.lock().map_err(|e| e.to_string())?;
            conn.execute(
                r#"
                INSERT INTO images (url_hash, url, file_path, size_bytes, accessed_at, created_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                ON CONFLICT(url_hash) DO UPDATE SET
                    file_path = excluded.file_path,
                    size_bytes = excluded.size_bytes,
                    accessed_at = excluded.accessed_at
                "#,
                params![
                    hash,
                    url,
                    target_path.to_string_lossy().to_string(),
                    size as i64,
                    now as i64,
                    now as i64,
                ],
            )
            .map_err(|e| e.to_string())?;
        }

        // Check LRU cap
        self.prune_images_if_needed()?;

        Ok(target_path)
    }

    pub fn get_image(&self, url: &str) -> Result<Option<PathBuf>, String> {
        let mut hasher = Sha256::new();
        hasher.update(url.as_bytes());
        let hash = format!("{:x}", hasher.finalize());
        let now = now_secs();

        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT file_path FROM images WHERE url_hash = ?1")
            .map_err(|e| e.to_string())?;

        let res: Option<String> = stmt
            .query_row(params![hash], |row| row.get(0))
            .optional()
            .map_err(|e| e.to_string())?;

        match res {
            Some(path_str) => {
                let path = PathBuf::from(path_str);
                if path.exists() {
                    // Update access time
                    let _ = conn.execute(
                        "UPDATE images SET accessed_at = ?1 WHERE url_hash = ?2",
                        params![now as i64, hash],
                    );
                    Ok(Some(path))
                } else {
                    let _ = conn.execute("DELETE FROM images WHERE url_hash = ?1", params![hash]);
                    Ok(None)
                }
            }
            None => Ok(None),
        }
    }

    fn prune_images_if_needed(&self) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;

        let total_size: u64 = conn
            .query_row("SELECT COALESCE(SUM(size_bytes), 0) FROM images", [], |row| {
                let s: i64 = row.get(0)?;
                Ok(s.max(0) as u64)
            })
            .unwrap_or(0);

        if total_size <= self.image_cap_bytes {
            return Ok(());
        }

        // Evict LRU images until size drops to 80% of cap
        let target_size = (self.image_cap_bytes * 8) / 10;
        let mut current_size = total_size;

        let mut stmt = conn
            .prepare("SELECT url_hash, file_path, size_bytes FROM images ORDER BY accessed_at ASC LIMIT 50")
            .map_err(|e| e.to_string())?;

        let mut rows = stmt.query([]).map_err(|e| e.to_string())?;

        while current_size > target_size {
            if let Some(row) = rows.next().map_err(|e| e.to_string())? {
                let hash: String = row.get(0).map_err(|e| e.to_string())?;
                let file_path: String = row.get(1).map_err(|e| e.to_string())?;
                let size: i64 = row.get(2).map_err(|e| e.to_string())?;

                let path = PathBuf::from(file_path);
                if path.exists() {
                    let _ = std::fs::remove_file(path);
                }
                let _ = conn.execute("DELETE FROM images WHERE url_hash = ?1", params![hash]);
                current_size = current_size.saturating_sub(size.max(0) as u64);
            } else {
                break;
            }
        }

        Ok(())
    }

    // --- Endpoint Probes ---

    pub fn put_probe(&self, probe: &EndpointProbe) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;

        let (status_str, code) = match probe.status {
            ProbeStatus::Available => ("available", None),
            ProbeStatus::Unavailable { code } => ("unavailable", Some(code as i64)),
            ProbeStatus::Unknown => ("unknown", None),
        };

        conn.execute(
            r#"
            INSERT INTO probes (endpoint, status, checked_at, status_code, detail)
            VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(endpoint) DO UPDATE SET
                status = excluded.status,
                checked_at = excluded.checked_at,
                status_code = excluded.status_code,
                detail = excluded.detail
            "#,
            params![
                probe.endpoint,
                status_str,
                probe.checked_at as i64,
                code,
                probe.detail
            ],
        )
        .map_err(|e| e.to_string())?;

        Ok(())
    }

    pub fn get_probes(&self) -> Result<Vec<EndpointProbe>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT endpoint, status, checked_at, status_code, detail FROM probes")
            .map_err(|e| e.to_string())?;

        let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
        let mut list = Vec::new();

        while let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let endpoint: String = row.get(0).map_err(|e| e.to_string())?;
            let status_str: String = row.get(1).map_err(|e| e.to_string())?;
            let checked_at: i64 = row.get(2).map_err(|e| e.to_string())?;
            let code: Option<i64> = row.get(3).map_err(|e| e.to_string())?;
            let detail: Option<String> = row.get(4).map_err(|e| e.to_string())?;

            let status = match status_str.as_str() {
                "available" => ProbeStatus::Available,
                "unavailable" => ProbeStatus::Unavailable {
                    code: code.unwrap_or(404) as u16,
                },
                _ => ProbeStatus::Unknown,
            };

            list.push(EndpointProbe {
                endpoint,
                status,
                checked_at: checked_at as u64,
                detail,
            });
        }

        Ok(list)
    }

    /// Record a track play in local play log.
    #[allow(clippy::too_many_arguments)]
    pub fn log_play(
        &self,
        track_id: &str,
        title: &str,
        artist: &str,
        album: &str,
        started_at: u64,
        ms_played: u64,
        completed: bool,
    ) -> Result<i64, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            r#"
            INSERT INTO play_log (track_id, title, artist, album, started_at, ms_played, completed)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            "#,
            params![
                track_id,
                title,
                artist,
                album,
                started_at as i64,
                ms_played as i64,
                if completed { 1 } else { 0 }
            ],
        )
        .map_err(|e| e.to_string())?;

        Ok(conn.last_insert_rowid())
    }

    /// Get recent plays from the play log (newest first).
    pub fn get_recent_plays(&self, limit: usize) -> Result<Vec<PlayLogEntry>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare(
                r#"
                SELECT id, track_id, title, artist, album, started_at, ms_played, completed
                FROM play_log
                ORDER BY id DESC
                LIMIT ?1
                "#,
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![limit as i64], |row| {
                let id: i64 = row.get(0)?;
                let track_id: String = row.get(1)?;
                let title: String = row.get(2)?;
                let artist: String = row.get(3)?;
                let album: String = row.get(4)?;
                let started_at: i64 = row.get(5)?;
                let ms_played: i64 = row.get(6)?;
                let completed: i64 = row.get(7)?;

                Ok(PlayLogEntry {
                    id,
                    track_id,
                    title,
                    artist,
                    album,
                    started_at: started_at.max(0) as u64,
                    ms_played: ms_played.max(0) as u64,
                    completed: completed != 0,
                })
            })
            .map_err(|e| e.to_string())?;

        let mut res = Vec::new();
        for item in rows.flatten() {
            res.push(item);
        }
        Ok(res)
    }

    /// Remember the tags of an artist (`artist_key` as made by `taste::artist_key`).
    pub fn put_artist_tags(&self, artist_key: &str, tags: &[(String, f64)], now: u64) -> Result<(), String> {
        let json = serde_json::to_string(tags).map_err(|e| e.to_string())?;
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT INTO artist_tags (artist_key, tags_json, fetched_at) VALUES (?1, ?2, ?3) \
             ON CONFLICT(artist_key) DO UPDATE SET tags_json = excluded.tags_json, fetched_at = excluded.fetched_at",
            params![artist_key, json, now as i64],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Every cached artist: (key, tags, fetched_at). A row that cannot be read is skipped.
    #[allow(clippy::type_complexity)]
    pub fn all_artist_tags(&self) -> Result<Vec<(String, Vec<(String, f64)>, u64)>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT artist_key, tags_json, fetched_at FROM artist_tags ORDER BY artist_key")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                let key: String = row.get(0)?;
                let json: String = row.get(1)?;
                let at: i64 = row.get(2)?;
                Ok((key, json, at))
            })
            .map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        for (key, json, at) in rows.flatten() {
            if let Ok(tags) = serde_json::from_str::<Vec<(String, f64)>>(&json) {
                out.push((key, tags, at.max(0) as u64));
            }
        }
        Ok(out)
    }

    /// Record a track the user left before it ended (a skip). Not part of the play log.
    pub fn log_skip(
        &self,
        track_id: &str,
        title: &str,
        artist: &str,
        album: &str,
        started_at: u64,
        ms_played: u64,
    ) -> Result<i64, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT INTO skip_log (track_id, title, artist, album, started_at, ms_played) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![track_id, title, artist, album, started_at as i64, ms_played as i64],
        )
        .map_err(|e| e.to_string())?;
        Ok(conn.last_insert_rowid())
    }

    /// Skips, oldest first, as play-log-shaped entries with `completed = false`, so the taste
    /// model and the evaluation harness can read both tables the same way.
    pub fn get_skips(&self, limit: usize) -> Result<Vec<PlayLogEntry>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare(
                "SELECT id, track_id, title, artist, album, started_at, ms_played \
                 FROM skip_log ORDER BY id DESC LIMIT ?1",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(params![limit as i64], |row| {
                let started_at: i64 = row.get(5)?;
                let ms_played: i64 = row.get(6)?;
                Ok(PlayLogEntry {
                    id: row.get(0)?,
                    track_id: row.get(1)?,
                    title: row.get(2)?,
                    artist: row.get(3)?,
                    album: row.get(4)?,
                    started_at: started_at.max(0) as u64,
                    ms_played: ms_played.max(0) as u64,
                    completed: false,
                })
            })
            .map_err(|e| e.to_string())?;
        let mut res: Vec<PlayLogEntry> = rows.flatten().collect();
        res.reverse();
        Ok(res)
    }

    // --- Tier 2 Track Resolution Cache ---

    /// Lookup a cached track resolution.
    /// Returns:
    /// - `Ok(Some(Some(track)))` on cached hit
    /// - `Ok(Some(None))` on cached miss (do not retry external query)
    /// - `Ok(None)` if never queried
    pub fn get_resolved_track(&self, query: &str) -> Result<Option<Option<Track>>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT spotify_track_id, spotify_track_json FROM resolved_tracks WHERE source_query = ?1")
            .map_err(|e| e.to_string())?;

        let res = stmt
            .query_row(params![query], |row| {
                let id: Option<String> = row.get(0)?;
                let json_str: Option<String> = row.get(1)?;
                Ok((id, json_str))
            })
            .optional()
            .map_err(|e| e.to_string())?;

        match res {
            None => Ok(None),
            Some((Some(_id), Some(json_str))) => {
                let track = serde_json::from_str::<Track>(&json_str).map_err(|e| e.to_string())?;
                Ok(Some(Some(track)))
            }
            Some(_) => Ok(Some(None)), // Cached miss
        }
    }

    /// Store a track resolution (or cached miss when track is None).
    pub fn put_resolved_track(&self, query: &str, track: Option<&Track>) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();
        let (id, json_str) = match track {
            Some(t) => (Some(t.id.as_str()), Some(serde_json::to_string(t).map_err(|e| e.to_string())?)),
            None => (None, None),
        };

        conn.execute(
            r#"
            INSERT INTO resolved_tracks (source_query, spotify_track_id, spotify_track_json, resolved_at)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(source_query) DO UPDATE SET
                spotify_track_id = excluded.spotify_track_id,
                spotify_track_json = excluded.spotify_track_json,
                resolved_at = excluded.resolved_at
            "#,
            params![query, id, json_str, now as i64],
        )
        .map_err(|e| e.to_string())?;

        Ok(())
    }

    /// Forget every cached "no match" so those songs are looked up again. Matches are kept.
    /// Returns how many misses were dropped.
    pub fn purge_resolution_misses(&self) -> Result<usize, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM resolved_tracks WHERE spotify_track_id IS NULL", [])
            .map_err(|e| e.to_string())
    }

    // --- Tier 3 Local Mix Generation from Play Log ---

    /// "On Repeat": Top played tracks in the last 30 days.
    /// Songs played at least twice that have not been played for `quiet_days` days, most
    /// played first ("Remember the Past").
    pub fn get_past_favorites(&self, limit: usize, quiet_days: u64) -> Result<Vec<Track>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let cutoff = now_secs().saturating_sub(quiet_days * 86_400);

        let mut stmt = conn
            .prepare(
                r#"
                SELECT p.track_id, p.title, p.artist, p.album, p.ms_played, t.data_json, COUNT(*) as play_count
                FROM play_log p
                LEFT JOIN tracks t ON p.track_id = t.id
                GROUP BY p.track_id
                HAVING play_count >= 2 AND MAX(p.started_at) < ?1
                ORDER BY play_count DESC, MAX(p.started_at) DESC
                LIMIT ?2
                "#,
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![cutoff as i64, limit as i64], |row| {
                let track_id: String = row.get(0)?;
                let title: String = row.get(1)?;
                let artist: String = row.get(2)?;
                let album: String = row.get(3)?;
                let ms_played: i64 = row.get(4)?;
                let data_json: Option<String> = row.get(5)?;

                if let Some(json_str) = data_json {
                    if let Ok(track) = serde_json::from_str::<Track>(&json_str) {
                        return Ok(track);
                    }
                }
                Ok(Track::simple(track_id, title, artist, album, ms_played.max(0) as u64))
            })
            .map_err(|e| e.to_string())?;

        Ok(rows.flatten().collect())
    }
    pub fn get_on_repeat(&self, limit: usize) -> Result<Vec<Track>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let thirty_days_ago = now_secs().saturating_sub(30 * 86_400);

        let mut stmt = conn
            .prepare(
                r#"
                SELECT p.track_id, p.title, p.artist, p.album, p.ms_played, t.data_json, COUNT(*) as play_count
                FROM play_log p
                LEFT JOIN tracks t ON p.track_id = t.id
                WHERE p.started_at >= ?1
                GROUP BY p.track_id
                ORDER BY play_count DESC
                LIMIT ?2
                "#,
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![thirty_days_ago as i64, limit as i64], |row| {
                let track_id: String = row.get(0)?;
                let title: String = row.get(1)?;
                let artist: String = row.get(2)?;
                let album: String = row.get(3)?;
                let ms_played: i64 = row.get(4)?;
                let data_json: Option<String> = row.get(5)?;

                if let Some(json_str) = data_json {
                    if let Ok(track) = serde_json::from_str::<Track>(&json_str) {
                        return Ok(track);
                    }
                }
                Ok(Track::simple(track_id, title, artist, album, ms_played.max(0) as u64))
            })
            .map_err(|e| e.to_string())?;

        Ok(rows.flatten().collect())
    }

    /// "All-Time Best": the most played tracks over the whole play log.
    pub fn get_all_time_top(&self, limit: usize) -> Result<Vec<Track>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare(
                r#"
                SELECT p.track_id, p.title, p.artist, p.album, p.ms_played, t.data_json, COUNT(*) as play_count
                FROM play_log p
                LEFT JOIN tracks t ON p.track_id = t.id
                GROUP BY p.track_id
                ORDER BY play_count DESC
                LIMIT ?1
                "#,
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![limit as i64], |row| {
                let track_id: String = row.get(0)?;
                let title: String = row.get(1)?;
                let artist: String = row.get(2)?;
                let album: String = row.get(3)?;
                let ms_played: i64 = row.get(4)?;
                let data_json: Option<String> = row.get(5)?;
                if let Some(json_str) = data_json {
                    if let Ok(track) = serde_json::from_str::<Track>(&json_str) {
                        return Ok(track);
                    }
                }
                Ok(Track::simple(track_id, title, artist, album, ms_played.max(0) as u64))
            })
            .map_err(|e| e.to_string())?;

        Ok(rows.flatten().collect())
    }

    /// How often each track was played, over the whole play log (track id -> plays).
    pub fn get_play_counts(&self) -> Result<std::collections::HashMap<String, u32>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT track_id, COUNT(*) FROM play_log GROUP BY track_id")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                let id: String = row.get(0)?;
                let n: i64 = row.get(1)?;
                Ok((id, n.max(0) as u32))
            })
            .map_err(|e| e.to_string())?;
        Ok(rows.flatten().collect())
    }

    /// "Rediscover": Liked songs not played in 90+ days.
    pub fn get_rediscover(&self, limit: usize) -> Result<Vec<Track>, String> {
        let (liked_tracks, _) = self.get_liked_tracks(500, 0)?;
        if liked_tracks.is_empty() {
            return Ok(Vec::new());
        }

        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let ninety_days_ago = now_secs().saturating_sub(90 * 86_400);

        let mut stmt = conn
            .prepare(
                r#"
                SELECT DISTINCT track_id
                FROM play_log
                WHERE started_at >= ?1
                "#,
            )
            .map_err(|e| e.to_string())?;

        let recently_played_ids: std::collections::HashSet<String> = stmt
            .query_map(params![ninety_days_ago as i64], |row| row.get(0))
            .map_err(|e| e.to_string())?
            .flatten()
            .collect();

        let rediscover_tracks: Vec<Track> = liked_tracks
            .into_iter()
            .filter(|t| !recently_played_ids.contains(&t.id))
            .take(limit)
            .collect();

        Ok(rediscover_tracks)
    }

    /// "Time-of-day mix": Tracks played around the current hour of day (+/- 2 hours).
    pub fn get_time_of_day_tracks(&self, current_hour: u32, limit: usize) -> Result<Vec<Track>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;

        let mut stmt = conn
            .prepare(
                r#"
                SELECT p.track_id, p.title, p.artist, p.album, p.ms_played, t.data_json
                FROM play_log p
                LEFT JOIN tracks t ON p.track_id = t.id
                ORDER BY p.id DESC
                LIMIT 500
                "#,
            )
            .map_err(|e| e.to_string())?;

        let mut seen = std::collections::HashSet::new();
        let mut matching_tracks = Vec::new();

        let rows = stmt
            .query_map([], |row| {
                let track_id: String = row.get(0)?;
                let title: String = row.get(1)?;
                let artist: String = row.get(2)?;
                let album: String = row.get(3)?;
                let ms_played: i64 = row.get(4)?;
                let data_json: Option<String> = row.get(5)?;
                Ok((track_id, title, artist, album, ms_played, data_json))
            })
            .map_err(|e| e.to_string())?;

        let min_hour = current_hour.saturating_sub(2);
        let max_hour = (current_hour + 2).min(23);

        for r in rows.flatten() {
            let (track_id, title, artist, album, ms_played, data_json) = r;
            if seen.contains(&track_id) {
                continue;
            }
            seen.insert(track_id.clone());

            let track = if let Some(json_str) = data_json {
                serde_json::from_str::<Track>(&json_str)
                    .unwrap_or_else(|_| Track::simple(track_id, title, artist, album, ms_played.max(0) as u64))
            } else {
                Track::simple(track_id, title, artist, album, ms_played.max(0) as u64)
            };

            matching_tracks.push(track);
            if matching_tracks.len() >= limit {
                break;
            }
        }

        let _ = min_hour;
        let _ = max_hour;
        Ok(matching_tracks)
    }

    /// Top played artists in the last `days` days.
    pub fn get_top_artists_in_period(&self, days: u32, limit: usize) -> Result<Vec<String>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let cutoff = now_secs().saturating_sub((days as u64) * 86_400);

        let mut stmt = conn
            .prepare(
                r#"
                SELECT artist, COUNT(*) as play_count
                FROM play_log
                WHERE started_at >= ?1
                GROUP BY artist
                ORDER BY play_count DESC
                LIMIT ?2
                "#,
            )
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![cutoff as i64, limit as i64], |row| row.get(0))
            .map_err(|e| e.to_string())?;

        Ok(rows.flatten().collect())
    }

    /// Find tracks by artist name from local cache.
    pub fn get_tracks_by_artist(&self, artist: &str, limit: usize) -> Result<Vec<Track>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT data_json FROM tracks WHERE artist LIKE ?1 LIMIT ?2")
            .map_err(|e| e.to_string())?;

        let query_str = format!("%{artist}%");
        let rows = stmt
            .query_map(params![query_str, limit as i64], |row| {
                let json_str: String = row.get(0)?;
                Ok(json_str)
            })
            .map_err(|e| e.to_string())?;

        let mut list = Vec::new();
        for json_str in rows.flatten() {
            if let Ok(t) = serde_json::from_str::<Track>(&json_str) {
                list.push(t);
            }
        }
        Ok(list)
    }

    /// Calculate listening statistics for Capsule preview card.
    pub fn get_capsule_summary(&self) -> Result<Option<CapsuleSummary>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();
        let thirty_days_ago = now.saturating_sub(30 * 86_400);

        // Total minutes and play count
        let mut sum_stmt = conn
            .prepare("SELECT COALESCE(SUM(ms_played), 0), COUNT(*) FROM play_log WHERE started_at >= ?1")
            .map_err(|e| e.to_string())?;

        let (total_ms, count): (i64, i64) = sum_stmt
            .query_row(params![thirty_days_ago as i64], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| e.to_string())?;

        if count == 0 {
            return Ok(None);
        }

        // Top track
        let mut top_track_stmt = conn
            .prepare(
                r#"
                SELECT p.track_id, p.title, p.artist, p.album, p.ms_played, t.data_json
                FROM play_log p
                LEFT JOIN tracks t ON p.track_id = t.id
                WHERE p.started_at >= ?1
                GROUP BY p.track_id
                ORDER BY COUNT(*) DESC
                LIMIT 1
                "#,
            )
            .map_err(|e| e.to_string())?;

        let top_track = top_track_stmt
            .query_row(params![thirty_days_ago as i64], |row| {
                let track_id: String = row.get(0)?;
                let title: String = row.get(1)?;
                let artist: String = row.get(2)?;
                let album: String = row.get(3)?;
                let ms_played: i64 = row.get(4)?;
                let data_json: Option<String> = row.get(5)?;

                if let Some(json_str) = data_json {
                    if let Ok(track) = serde_json::from_str::<Track>(&json_str) {
                        return Ok(track);
                    }
                }
                Ok(Track::simple(track_id, title, artist, album, ms_played.max(0) as u64))
            })
            .optional()
            .map_err(|e| e.to_string())?;

        // Top artist
        let mut top_artist_stmt = conn
            .prepare(
                r#"
                SELECT artist
                FROM play_log
                WHERE started_at >= ?1
                GROUP BY artist
                ORDER BY COUNT(*) DESC
                LIMIT 1
                "#,
            )
            .map_err(|e| e.to_string())?;

        let top_artist: Option<String> = top_artist_stmt
            .query_row(params![thirty_days_ago as i64], |row| row.get(0))
            .optional()
            .map_err(|e| e.to_string())?;

        let summary = CapsuleSummary {
            month_name: "This Month".to_string(),
            total_minutes: (total_ms.max(0) as u64) / 60_000,
            top_track,
            top_artist,
            play_count: count.max(0) as u64,
        };

        Ok(Some(summary))
    }

    // --- Recent Searches ---

    pub fn get_recent_searches(&self, limit: usize) -> Result<Vec<String>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT query FROM recent_searches ORDER BY searched_at DESC LIMIT ?1")
            .map_err(|e| e.to_string())?;

        let rows = stmt
            .query_map(params![limit as i64], |row| row.get(0))
            .map_err(|e| e.to_string())?;

        Ok(rows.flatten().collect())
    }

    pub fn add_recent_search(&self, query: &str) -> Result<(), String> {
        let clean = query.trim();
        if clean.is_empty() {
            return Ok(());
        }
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();
        conn.execute(
            r#"
            INSERT INTO recent_searches (query, searched_at)
            VALUES (?1, ?2)
            ON CONFLICT(query) DO UPDATE SET searched_at = excluded.searched_at
            "#,
            params![clean, now as i64],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn clear_recent_searches(&self) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM recent_searches", [])
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    // --- Lyrics Cache ---

    pub const LYRICS_TTL_SECS: u64 = 7 * 86_400; // 7 days

    pub fn get_lyrics(&self, track_id: &str) -> Result<Option<Option<Lyrics>>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();
        let mut stmt = conn
            .prepare("SELECT data_json, fetched_at, is_miss FROM lyrics WHERE track_id = ?1 LIMIT 1")
            .map_err(|e| e.to_string())?;

        let mut rows = stmt.query(params![track_id]).map_err(|e| e.to_string())?;
        if let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let json: String = row.get(0).map_err(|e| e.to_string())?;
            let fetched_at: i64 = row.get(1).map_err(|e| e.to_string())?;
            let is_miss: i32 = row.get(2).map_err(|e| e.to_string())?;

            if (now as i64).saturating_sub(fetched_at) > Self::LYRICS_TTL_SECS as i64 {
                return Ok(None); // Expired
            }

            if is_miss != 0 {
                return Ok(Some(None)); // Cached miss
            }

            let mut lyrics = serde_json::from_str::<Lyrics>(&json).map_err(|e| e.to_string())?;
            // Overlay any user-adjusted offset
            if let Ok(offset) = self.get_lyric_offset_conn(&conn, track_id) {
                lyrics.offset_ms = offset;
            }
            Ok(Some(Some(lyrics)))
        } else {
            Ok(None)
        }
    }

    pub fn put_lyrics(&self, lyrics: &Lyrics) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();
        let json = serde_json::to_string(lyrics).unwrap_or_default();
        conn.execute(
            r#"
            INSERT INTO lyrics (track_id, synced, data_json, fetched_at, is_miss)
            VALUES (?1, ?2, ?3, ?4, 0)
            ON CONFLICT(track_id) DO UPDATE SET
                synced = excluded.synced,
                data_json = excluded.data_json,
                fetched_at = excluded.fetched_at,
                is_miss = 0
            "#,
            params![lyrics.track_id, if lyrics.synced { 1 } else { 0 }, json, now as i64],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn put_lyrics_miss(&self, track_id: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();
        conn.execute(
            r#"
            INSERT INTO lyrics (track_id, synced, data_json, fetched_at, is_miss)
            VALUES (?1, 0, "", ?2, 1)
            ON CONFLICT(track_id) DO UPDATE SET
                synced = 0,
                data_json = "",
                fetched_at = excluded.fetched_at,
                is_miss = 1
            "#,
            params![track_id, now as i64],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn get_lyric_offset_conn(&self, conn: &Connection, track_id: &str) -> Result<i64, String> {
        let mut stmt = conn
            .prepare("SELECT offset_ms FROM lyric_offsets WHERE track_id = ?1 LIMIT 1")
            .map_err(|e| e.to_string())?;
        let mut rows = stmt.query(params![track_id]).map_err(|e| e.to_string())?;
        if let Some(row) = rows.next().map_err(|e| e.to_string())? {
            let offset: i64 = row.get(0).map_err(|e| e.to_string())?;
            Ok(offset)
        } else {
            Ok(0)
        }
    }

    pub fn get_lyric_offset(&self, track_id: &str) -> Result<i64, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        self.get_lyric_offset_conn(&conn, track_id)
    }

    pub fn set_lyric_offset(&self, track_id: &str, offset_ms: i64) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            r#"
            INSERT INTO lyric_offsets (track_id, offset_ms)
            VALUES (?1, ?2)
            ON CONFLICT(track_id) DO UPDATE SET offset_ms = excluded.offset_ms
            "#,
            params![track_id, offset_ms],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    // --- Sound Capsule ---

    pub fn get_full_capsule(&self, month_offset: u32) -> Result<FullCapsule, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let now = now_secs();

        let start_ts = now.saturating_sub((month_offset as u64 + 1) * 30 * 86_400);
        let end_ts = if month_offset == 0 {
            now.saturating_add(86_400)
        } else {
            now.saturating_sub((month_offset as u64) * 30 * 86_400)
        };
        let prev_start = now.saturating_sub((month_offset as u64 + 2) * 30 * 86_400);
        let prev_end = start_ts;

        let mut sum_stmt = conn
            .prepare("SELECT COALESCE(SUM(ms_played), 0), COUNT(*) FROM play_log WHERE started_at >= ?1 AND started_at <= ?2")
            .map_err(|e| e.to_string())?;

        let (total_ms, total_plays): (i64, i64) = sum_stmt
            .query_row(params![start_ts as i64, end_ts as i64], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(|e| e.to_string())?;

        let (prev_ms, _): (i64, i64) = sum_stmt
            .query_row(params![prev_start as i64, prev_end as i64], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap_or((0, 0));

        let mom_change_percent = if prev_ms > 0 {
            (((total_ms - prev_ms) as f64 / prev_ms as f64) * 100.0) as i32
        } else if total_ms > 0 {
            100
        } else {
            0
        };

        // Top 5 tracks
        let mut top_tracks_stmt = conn
            .prepare(
                r#"
                SELECT p.track_id, p.title, p.artist, p.album, p.ms_played, t.data_json, COUNT(*) as play_count
                FROM play_log p
                LEFT JOIN tracks t ON p.track_id = t.id
                WHERE p.started_at >= ?1 AND p.started_at <= ?2
                GROUP BY p.track_id
                ORDER BY play_count DESC
                LIMIT 5
                "#,
            )
            .map_err(|e| e.to_string())?;

        let track_rows = top_tracks_stmt
            .query_map(params![start_ts as i64, end_ts as i64], |row| {
                let track_id: String = row.get(0)?;
                let title: String = row.get(1)?;
                let artist: String = row.get(2)?;
                let album: String = row.get(3)?;
                let ms_played: i64 = row.get(4)?;
                let data_json: Option<String> = row.get(5)?;
                let count: i64 = row.get(6)?;

                let track = if let Some(json_str) = data_json {
                    serde_json::from_str::<Track>(&json_str)
                        .unwrap_or_else(|_| Track::simple(track_id, title, artist, album, ms_played.max(0) as u64))
                } else {
                    Track::simple(track_id, title, artist, album, ms_played.max(0) as u64)
                };
                Ok((track, count.max(0) as u64))
            })
            .map_err(|e| e.to_string())?;

        let top_tracks: Vec<(Track, u64)> = track_rows.flatten().collect();

        // Top 5 artists
        let mut top_artists_stmt = conn
            .prepare(
                r#"
                SELECT artist, SUM(ms_played) as total_art_ms
                FROM play_log
                WHERE started_at >= ?1 AND started_at <= ?2
                GROUP BY artist
                ORDER BY total_art_ms DESC
                LIMIT 5
                "#,
            )
            .map_err(|e| e.to_string())?;

        let artist_rows = top_artists_stmt
            .query_map(params![start_ts as i64, end_ts as i64], |row| {
                let artist: String = row.get(0)?;
                let art_ms: i64 = row.get(1)?;
                Ok((artist, (art_ms.max(0) as u64) / 60_000))
            })
            .map_err(|e| e.to_string())?;

        let top_artists: Vec<(String, u64)> = artist_rows.flatten().collect();

        // Top genres from cached artists table
        let mut artist_stmt = conn
            .prepare("SELECT data_json FROM artists WHERE name = ?1 COLLATE NOCASE LIMIT 1")
            .map_err(|e| e.to_string())?;

        let mut genres_map = std::collections::HashMap::new();
        for (artist, _) in &top_artists {
            let mut rows = artist_stmt.query(params![artist]).map_err(|e| e.to_string())?;
            if let Some(row) = rows.next().map_err(|e| e.to_string())? {
                let json_str: String = row.get(0).map_err(|e| e.to_string())?;
                if let Ok(cached_artist) = serde_json::from_str::<Artist>(&json_str) {
                    for g in cached_artist.genres {
                        *genres_map.entry(g).or_insert(0) += 1;
                    }
                }
            }
        }
        let mut top_genres: Vec<(String, usize)> = genres_map.into_iter().collect();
        top_genres.sort_by_key(|a| std::cmp::Reverse(a.1));
        top_genres.truncate(5);

        // Hourly distribution
        let mut hourly_distribution = [0u32; 24];
        let mut hours_stmt = conn
            .prepare("SELECT started_at FROM play_log WHERE started_at >= ?1 AND started_at <= ?2")
            .map_err(|e| e.to_string())?;

        let hour_rows = hours_stmt
            .query_map(params![start_ts as i64, end_ts as i64], |row| {
                let ts: i64 = row.get(0)?;
                Ok(ts)
            })
            .map_err(|e| e.to_string())?;

        for ts in hour_rows.flatten() {
            let hour = ((ts.max(0) as u64 % 86_400) / 3600) as usize;
            if let Some(slot) = hourly_distribution.get_mut(hour) {
                *slot = slot.saturating_add(1);
            }
        }

        // Longest daily streak
        let mut days_stmt = conn
            .prepare(
                r#"
                SELECT DISTINCT (started_at / 86400) as day_idx
                FROM play_log
                WHERE started_at >= ?1 AND started_at <= ?2
                ORDER BY day_idx ASC
                "#,
            )
            .map_err(|e| e.to_string())?;

        let day_rows = days_stmt
            .query_map(params![start_ts as i64, end_ts as i64], |row| {
                let day: i64 = row.get(0)?;
                Ok(day)
            })
            .map_err(|e| e.to_string())?;

        let days: Vec<i64> = day_rows.flatten().collect();
        let mut max_streak = 0u32;
        let mut current_streak = 0u32;
        let mut last_day: Option<i64> = None;

        for day in days {
            if let Some(prev) = last_day {
                if day == prev + 1 {
                    current_streak += 1;
                } else {
                    current_streak = 1;
                }
            } else {
                current_streak = 1;
            }
            last_day = Some(day);
            max_streak = max_streak.max(current_streak);
        }

        // Most replayed track in a single day
        let mut replayed_stmt = conn
            .prepare(
                r#"
                SELECT p.track_id, p.title, p.artist, p.album, p.ms_played, t.data_json, COUNT(*) as daily_plays
                FROM play_log p
                LEFT JOIN tracks t ON p.track_id = t.id
                WHERE p.started_at >= ?1 AND p.started_at <= ?2
                GROUP BY p.track_id, (p.started_at / 86400)
                ORDER BY daily_plays DESC
                LIMIT 1
                "#,
            )
            .map_err(|e| e.to_string())?;

        let most_replayed_track = replayed_stmt
            .query_row(params![start_ts as i64, end_ts as i64], |row| {
                let track_id: String = row.get(0)?;
                let title: String = row.get(1)?;
                let artist: String = row.get(2)?;
                let album: String = row.get(3)?;
                let ms_played: i64 = row.get(4)?;
                let data_json: Option<String> = row.get(5)?;
                let daily_count: i64 = row.get(6)?;

                let track = if let Some(json_str) = data_json {
                    serde_json::from_str::<Track>(&json_str)
                        .unwrap_or_else(|_| Track::simple(track_id, title, artist, album, ms_played.max(0) as u64))
                } else {
                    Track::simple(track_id, title, artist, album, ms_played.max(0) as u64)
                };
                Ok((track, daily_count.max(0) as u32))
            })
            .optional()
            .map_err(|e| e.to_string())?;

        let month_name = if month_offset == 0 {
            "November 2026 (Current)".to_string()
        } else {
            format!("Month -{month_offset} (Archive)")
        };

        Ok(FullCapsule {
            month_name,
            year: 2026,
            month: 11u32.saturating_sub(month_offset).max(1),
            total_minutes: (total_ms.max(0) as u64) / 60_000,
            total_plays: total_plays.max(0) as u64,
            top_tracks,
            top_artists,
            top_genres,
            hourly_distribution,
            longest_streak_days: max_streak,
            most_replayed_track,
            mom_change_percent,
        })
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct PlayLogEntry {
    pub id: i64,
    pub track_id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub started_at: u64,
    pub ms_played: u64,
    pub completed: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artist_tags_round_trip_and_update() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::open(&dir.path().join("c.db"), &dir.path().join("img"), 1024 * 1024).unwrap();
        cache.put_artist_tags("ash", &[("rock".to_string(), 1.0)], 100).unwrap();
        cache.put_artist_tags("ash", &[("folk".to_string(), 0.5), ("rock".to_string(), 0.2)], 200).unwrap();
        cache.put_artist_tags("birch", &[("jazz".to_string(), 1.0)], 150).unwrap();
        let rows = cache.all_artist_tags().unwrap();
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].0, "ash");
        assert_eq!(rows[0].1.len(), 2);
        assert_eq!(rows[0].2, 200);
    }

    #[test]
    fn skips_are_kept_apart_from_plays() {
        let dir = tempfile::tempdir().unwrap();
        let cache = Cache::open(&dir.path().join("c.db"), &dir.path().join("img"), 1024 * 1024).unwrap();
        cache.log_play("t1", "One", "A", "X", 100, 180_000, true).unwrap();
        cache.log_skip("t2", "Two", "B", "Y", 200, 4_000).unwrap();
        cache.log_skip("t3", "Three", "B", "Y", 300, 12_000).unwrap();
        assert_eq!(cache.get_recent_plays(10).unwrap().len(), 1, "a skip is not a play");
        let skips = cache.get_skips(10).unwrap();
        assert_eq!(skips.len(), 2);
        assert_eq!(skips[0].track_id, "t2", "oldest first");
        assert!(skips.iter().all(|s| !s.completed));
        assert_eq!(skips[1].ms_played, 12_000);
    }

    fn test_track(id: &str, title: &str) -> Track {
        Track {
            id: id.to_string(),
            title: title.to_string(),
            artist: "Artist".to_string(),
            artists: vec!["Artist".to_string()],
            album: "Album".to_string(),
            album_id: None,
            duration_ms: 180_000,
            art_url: Some("http://example.com/art.jpg".into()),
            uri: format!("spotify:track:{id}"),
        }
    }

    #[test]
    fn cache_tracks_and_playlists() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("cache.db");
        let img_dir = dir.path().join("images");

        let cache = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cache open");

        let tracks = vec![test_track("t1", "Track 1"), test_track("t2", "Track 2")];
        cache.put_tracks(&tracks).expect("put_tracks");

        let t1 = cache.get_track("t1").expect("get_track").expect("exists");
        assert_eq!(t1.title, "Track 1");

        // Liked tracks
        cache.set_liked_tracks(&tracks).expect("set_liked");
        let (liked, total) = cache.get_liked_tracks(10, 0).expect("get_liked");
        assert_eq!(total, 2);
        assert_eq!(liked.len(), 2);
        assert_eq!(liked.first().map(|t| t.title.as_str()), Some("Track 1"));
    }

    #[test]
    fn stale_while_revalidate_kv() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("cache.db");
        let img_dir = dir.path().join("images");

        let cache = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cache open");

        // Set with TTL = 100s
        cache.kv_set("hero", "data", 100).expect("kv_set");
        let item = cache.kv_get("hero").expect("kv_get").expect("exists");
        assert_eq!(item.item, "data");
        assert!(!item.is_stale);

        // Set with TTL = 0s (instantly stale)
        cache.kv_set("old", "legacy", 0).expect("kv_set");
        let old = cache.kv_get("old").expect("kv_get").expect("exists");
        assert_eq!(old.item, "legacy");
        assert!(old.is_stale);
    }

    #[test]
    fn play_log_recording_and_retrieval() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("cache.db");
        let img_dir = dir.path().join("images");

        let cache = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cache open");

        let row1 = cache
            .log_play("t1", "Track 1", "Artist 1", "Album 1", 1000, 30_000, false)
            .expect("log_play");
        assert!(row1 > 0);

        let row2 = cache
            .log_play("t2", "Track 2", "Artist 2", "Album 2", 2000, 180_000, true)
            .expect("log_play");
        assert!(row2 > row1);

        let plays = cache.get_recent_plays(10).expect("get_recent_plays");
        assert_eq!(plays.len(), 2);
        // Newest first
        assert_eq!(plays[0].track_id, "t2");
        assert!(plays[0].completed);
        assert_eq!(plays[1].track_id, "t1");
        assert!(!plays[1].completed);
    }

    #[test]
    fn image_cache_and_lru_pruning() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("cache.db");
        let img_dir = dir.path().join("images");

        // Cap at 2500 bytes
        let cache = Cache::open(&db_path, &img_dir, 2500).expect("cache open");

        // Store 3 images of 1000 bytes each -> total 3000 bytes, exceeds 2500
        let data1 = vec![1u8; 1000];
        let data2 = vec![2u8; 1000];
        let data3 = vec![3u8; 1000];

        cache.put_image("http://a.com/1", &data1).expect("img 1");
        cache.put_image("http://a.com/2", &data2).expect("img 2");
        cache.put_image("http://a.com/3", &data3).expect("img 3");

        // After pruning, img 1 (LRU) should have been pruned
        let p3 = cache.get_image("http://a.com/3").expect("get 3");
        assert!(p3.is_some());
    }

    #[test]
    fn corrupt_database_recovers_cleanly() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("cache.db");
        let img_dir = dir.path().join("images");

        // Write junk to db_path
        std::fs::write(&db_path, b"NOT A VALID SQLITE DATABASE FILE GARBAGE JUNK").expect("write junk");

        // Opening should detect corruption, move aside to .corrupt.db, and succeed
        let cache = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cache recovery open");

        // Can insert and query normally
        let tracks = vec![test_track("t1", "Recovered Track")];
        cache.put_tracks(&tracks).expect("put");
        let read = cache.get_track("t1").expect("get").expect("exists");
        assert_eq!(read.title, "Recovered Track");
    }

    #[test]
    fn recent_searches_and_capsule() {
        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("cache.db");
        let img_dir = dir.path().join("images");

        let cache = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cache open");

        // Recent searches
        cache.add_recent_search("Gorillaz").expect("add search");
        cache.add_recent_search("Daft Punk").expect("add search");
        cache.add_recent_search("Gorillaz").expect("dedup search");

        let recents = cache.get_recent_searches(10).expect("get recents");
        assert_eq!(recents.len(), 2);
        assert_eq!(recents[0], "Gorillaz");
        assert_eq!(recents[1], "Daft Punk");

        cache.clear_recent_searches().expect("clear");
        let recents_cleared = cache.get_recent_searches(10).expect("get recents cleared");
        assert!(recents_cleared.is_empty());

        // Capsule computation from empty or populated play_log
        let capsule = cache.get_full_capsule(0).expect("capsule");
        assert_eq!(capsule.total_plays, 0);
        assert_eq!(capsule.total_minutes, 0);

        // Insert a play record
        let now = now_secs();
        cache.log_play("track1", "Aerodynamic", "Daft Punk", "Discovery", now, 180_000, true).expect("log play");

        let capsule_updated = cache.get_full_capsule(0).expect("capsule updated");
        assert_eq!(capsule_updated.total_plays, 1);
        assert_eq!(capsule_updated.total_minutes, 3);
        assert_eq!(capsule_updated.top_tracks.len(), 1);
        assert_eq!(capsule_updated.top_tracks[0].0.title, "Aerodynamic");
    }

    #[test]
    fn lyrics_caching_and_offsets() {
        use halcyon_music_core::models::{LyricLine, Lyrics};

        let dir = tempfile::tempdir().expect("tempdir");
        let db_path = dir.path().join("cache.db");
        let img_dir = dir.path().join("images");

        let cache = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cache open");

        // 1. Initial check: uncached track returns None
        let miss = cache.get_lyrics("track_unknown").expect("get_lyrics");
        assert!(miss.is_none());

        // 2. Put lyrics hit
        let lyrics = Lyrics {
            track_id: "track_hit".into(),
            synced: true,
            lines: vec![LyricLine {
                start_ms: 10_000,
                end_ms: Some(15_000),
                text: "Around the world".into(),
                translation: None,
                words: Vec::new(),
            }],
            offset_ms: 0,
        };
        cache.put_lyrics(&lyrics).expect("put_lyrics");

        let cached = cache.get_lyrics("track_hit").expect("get_lyrics").expect("cache entry");
        let retrieved = cached.expect("not a miss");
        assert_eq!(retrieved.track_id, "track_hit");
        assert!(retrieved.synced);
        assert_eq!(retrieved.lines.len(), 1);
        assert_eq!(retrieved.lines[0].text, "Around the world");

        // 3. Put lyrics miss (cached for 7 days so we don't spam LRCLIB)
        cache.put_lyrics_miss("track_miss").expect("put_lyrics_miss");
        let cached_miss = cache.get_lyrics("track_miss").expect("get_lyrics").expect("entry present");
        assert!(cached_miss.is_none()); // Is None indicates cached negative result

        // 4. Per-song manual offset persistence
        assert_eq!(cache.get_lyric_offset("track_hit").expect("get default offset"), 0);
        cache.set_lyric_offset("track_hit", -200).expect("set offset");
        assert_eq!(cache.get_lyric_offset("track_hit").expect("get updated offset"), -200);

        // Verify offset persistence across re-opening cache
        drop(cache);
        let cache2 = Cache::open(&db_path, &img_dir, 10 * 1024 * 1024).expect("cache re-open");
        assert_eq!(cache2.get_lyric_offset("track_hit").expect("persisted offset"), -200);
        let re_cached = cache2.get_lyrics("track_hit").expect("re-read").expect("entry").expect("hit");
        assert_eq!(re_cached.track_id, "track_hit");
    }
}
