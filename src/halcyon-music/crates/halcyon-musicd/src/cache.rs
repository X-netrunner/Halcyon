//! SQLite cache layer for Halcyon Music.
//!
//! Owns:
//! - Tables: `tracks`, `albums`, `artists`, `playlists`, `playlist_items`, `images`, `kv`, `probes`
//! - Stale-while-revalidate data access
//! - LRU image cache on disk capped at 500 MB
//! - Automatic corrupt-database recovery: moves aside corrupt DB and rebuilds schema

use crate::token_store::now_secs;
use halcyon_music_core::models::{
    EndpointProbe, Playlist, ProbeStatus, Track,
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
}
