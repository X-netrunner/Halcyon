//! The built-in language models: what can be downloaded, what is on disk, and the downloader.
//!
//! One small GGUF model is fetched the first time Smart suggestions is turned on with the built-in
//! backend (never at install). The download resumes after an interruption, is checked against a
//! checksum, can be cancelled and deleted, and lives under `~/.local/share/halcyon-music/models/`.
//!
//! Network: this is the only code in the LLM layer that talks to the internet, and only because the
//! person pressed Download or switched Smart suggestions on. Prompts and play history never go anywhere.
//!
//! Checksums: a catalogue entry may carry a pinned SHA-256. When it does not, the download is
//! checked against the SHA-256 the download server publishes for the file (Hugging Face sends it in
//! `x-linked-etag`), and the file is marked `server`. That catches truncated or corrupted files, not
//! a hostile server; pin the hashes (`halcyon-musicd --model-check` prints them) to close that gap.

use halcyon_music_core::models::LlmModelInfo;
use halcyon_music_core::paths;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;

/// One downloadable model.
#[derive(Debug, Clone, Copy)]
pub struct ModelSpec {
    pub id: &'static str,
    pub name: &'static str,
    /// File name on disk (also the last part of the URL).
    pub file: &'static str,
    pub url: &'static str,
    /// Rough size for the Settings card before the real size is known.
    pub approx_bytes: u64,
    /// SHA-256 of the file when it has been pinned in this repo. `None`: use the server's.
    pub sha256: Option<&'static str>,
    pub licence: &'static str,
}

/// The four candidates from the master plan. URLs and sizes are NOT verified from this build
/// environment (it cannot reach the download host): run `halcyon-musicd --model-check`.
pub const CATALOGUE: &[ModelSpec] = &[
    ModelSpec {
        id: "qwen2.5-0.5b-instruct",
        name: "Qwen2.5 0.5B Instruct (Q4_K_M)",
        file: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        url: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf",
        approx_bytes: 491_000_000,
        sha256: None,
        licence: "Apache-2.0",
    },
    ModelSpec {
        id: "qwen3-0.6b",
        name: "Qwen3 0.6B (Q8_0)",
        file: "Qwen3-0.6B-Q8_0.gguf",
        url: "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf",
        approx_bytes: 639_000_000,
        sha256: None,
        licence: "Apache-2.0",
    },
    ModelSpec {
        id: "llama3.2-1b-instruct",
        name: "Llama 3.2 1B Instruct (Q4_K_M)",
        file: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
        url: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
        approx_bytes: 808_000_000,
        sha256: None,
        licence: "Llama 3.2 Community License",
    },
    ModelSpec {
        id: "gemma3-1b-instruct",
        name: "Gemma 3 1B Instruct (Q4_K_M)",
        file: "gemma-3-1b-it-Q4_K_M.gguf",
        url: "https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf",
        approx_bytes: 806_000_000,
        sha256: None,
        licence: "Gemma Terms of Use",
    },
];

/// Smallest and Apache-licensed. A provisional default until `--model-bench` has been run on the
/// target machine and the result written to docs/model-choice.md.
pub const DEFAULT_LOCAL_MODEL: &str = "qwen2.5-0.5b-instruct";

/// A file smaller than this is never a usable model.
const MIN_MODEL_BYTES: u64 = 1_000_000;
/// Free space kept back on top of the file itself.
const SPACE_MARGIN: u64 = 64 * 1024 * 1024;
/// No data for this long counts as a dropped connection.
const STALL: Duration = Duration::from_secs(30);
const PROGRESS_EVERY: Duration = Duration::from_millis(250);

pub fn find(id: &str) -> Option<&'static ModelSpec> {
    CATALOGUE.iter().find(|m| m.id == id)
}

pub fn is_known(id: &str) -> bool {
    find(id).is_some()
}

/// `~/.local/share/halcyon-music/models/`.
pub fn models_dir() -> PathBuf {
    paths::models_dir()
}

pub fn model_path(dir: &Path, file: &str) -> PathBuf {
    dir.join(file)
}

fn part_path(dir: &Path, file: &str) -> PathBuf {
    dir.join(format!("{file}.part"))
}

fn meta_path(dir: &Path, file: &str) -> PathBuf {
    dir.join(format!("{file}.part.json"))
}

fn verified_path(dir: &Path, file: &str) -> PathBuf {
    dir.join(format!("{file}.verified"))
}

// ---------------------------------------------------------------- what is on disk

/// Does this file start with the GGUF magic and have a believable size?
pub fn looks_like_gguf(path: &Path) -> bool {
    let Ok(meta) = std::fs::metadata(path) else {
        return false;
    };
    if !meta.is_file() || meta.len() < MIN_MODEL_BYTES {
        return false;
    }
    let mut magic = [0u8; 4];
    std::fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut magic))
        .is_ok()
        && &magic == b"GGUF"
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DiskStatus {
    pub installed: bool,
    pub size: u64,
    pub partial: u64,
    pub verified: String,
}

pub fn disk_status(dir: &Path, file: &str) -> DiskStatus {
    let final_path = model_path(dir, file);
    let installed = looks_like_gguf(&final_path);
    let size = if installed {
        std::fs::metadata(&final_path).map(|m| m.len()).unwrap_or(0)
    } else {
        0
    };
    let partial = std::fs::metadata(part_path(dir, file))
        .map(|m| m.len())
        .unwrap_or(0);
    let verified = if installed {
        std::fs::read_to_string(verified_path(dir, file))
            .map(|s| s.trim().to_string())
            .unwrap_or_default()
    } else {
        String::new()
    };
    DiskStatus {
        installed,
        size,
        partial,
        verified,
    }
}

pub fn info(spec: &ModelSpec, dir: &Path) -> LlmModelInfo {
    let d = disk_status(dir, spec.file);
    LlmModelInfo {
        id: spec.id.to_string(),
        name: spec.name.to_string(),
        size_bytes: if d.installed {
            d.size
        } else {
            spec.approx_bytes
        },
        licence: spec.licence.to_string(),
        installed: d.installed,
        partial_bytes: if d.installed { 0 } else { d.partial },
        verified: d.verified,
    }
}

pub fn list(dir: &Path) -> Vec<LlmModelInfo> {
    CATALOGUE.iter().map(|m| info(m, dir)).collect()
}

/// Remove the model file, any half-finished download of it and its markers.
pub fn delete_files(dir: &Path, file: &str) {
    for p in [
        model_path(dir, file),
        part_path(dir, file),
        meta_path(dir, file),
        verified_path(dir, file),
    ] {
        let _ = std::fs::remove_file(p);
    }
}

fn free_bytes(dir: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(dir.as_os_str().as_bytes()).ok()?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid NUL-terminated path and `st` is a properly sized, zeroed statvfs.
    let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    if rc != 0 {
        return None;
    }
    Some((st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
}

// ---------------------------------------------------------------- downloading

/// Why a download ended without a model. Every message says what to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DownloadError {
    Offline(String),
    Server(u16),
    DiskFull { needed: u64, free: u64 },
    Checksum,
    TooSmall,
    Cancelled,
    Io(String),
}

impl fmt::Display for DownloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Offline(why) => write!(
                f,
                "Couldn't reach the download server ({why}). Check the connection and try again; the download picks up where it stopped."
            ),
            Self::Server(code) => write!(f, "The download server answered with an error (HTTP {code}). Try again later, or pick another model."),
            Self::DiskFull { needed, free } => write!(
                f,
                "Not enough free disk space: the model needs about {} MB and {} MB are free. Free some space and try again.",
                needed / 1_000_000,
                free / 1_000_000
            ),
            Self::Checksum => write!(f, "The downloaded file did not match its checksum, so it was deleted. Try the download again."),
            Self::TooSmall => write!(f, "The download ended early with a file too small to be a model. Try again."),
            Self::Cancelled => write!(f, "Download cancelled. It resumes where it stopped next time."),
            Self::Io(why) => write!(f, "Couldn't write the model file ({why}). Check the models folder is writable."),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    /// `downloading` or `verifying`.
    pub state: &'static str,
    pub done: u64,
    pub total: u64,
}

/// What to fetch. Separate from [`ModelSpec`] so tests can point it at a local server.
#[derive(Debug, Clone)]
pub struct Plan<'a> {
    pub url: &'a str,
    pub file: &'a str,
    pub pinned_sha: Option<&'a str>,
    pub approx_bytes: u64,
}

impl<'a> Plan<'a> {
    pub fn from_spec(spec: &'a ModelSpec) -> Self {
        Self {
            url: spec.url,
            file: spec.file,
            pinned_sha: spec.sha256,
            approx_bytes: spec.approx_bytes,
        }
    }
}

#[derive(Serialize, Deserialize, PartialEq, Eq, Debug)]
struct PartMeta {
    url: String,
    sha: Option<String>,
    total: Option<u64>,
}

/// What the server says about the file before any bytes are fetched.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HeadInfo {
    /// SHA-256 the server published (`x-linked-etag`), lower-case hex.
    pub sha: Option<String>,
    pub total: Option<u64>,
}

fn clean_sha(raw: &str) -> Option<String> {
    let t = raw
        .trim()
        .trim_start_matches("W/")
        .trim_matches('"')
        .to_ascii_lowercase();
    (t.len() == 64 && t.chars().all(|c| c.is_ascii_hexdigit())).then_some(t)
}

fn client(redirects: bool) -> reqwest::Client {
    let policy = if redirects {
        reqwest::redirect::Policy::limited(8)
    } else {
        reqwest::redirect::Policy::none()
    };
    reqwest::Client::builder()
        .redirect(policy)
        .connect_timeout(Duration::from_secs(15))
        .user_agent(concat!("halcyon-music/", env!("CARGO_PKG_VERSION")))
        .build()
        .unwrap_or_else(|_| reqwest::Client::new())
}

fn map_err(e: reqwest::Error) -> DownloadError {
    DownloadError::Offline(e.without_url().to_string())
}

/// Ask the server about the file without following redirects: the checksum and size are on the
/// first answer (the redirect), not on the storage host it points to.
pub async fn head(url: &str) -> Result<HeadInfo, DownloadError> {
    let resp = client(false)
        .head(url)
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(map_err)?;
    let status = resp.status();
    if status.is_client_error() || status.is_server_error() {
        return Err(DownloadError::Server(status.as_u16()));
    }
    let h = resp.headers();
    let sha = h
        .get("x-linked-etag")
        .and_then(|v| v.to_str().ok())
        .and_then(clean_sha);
    let total = h
        .get("x-linked-size")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .or_else(|| {
            if status.is_success() {
                h.get(reqwest::header::CONTENT_LENGTH)
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse().ok())
            } else {
                None
            }
        })
        .filter(|n| *n > 0);
    Ok(HeadInfo { sha, total })
}

fn content_range(resp: &reqwest::Response) -> Option<(u64, Option<u64>)> {
    let v = resp
        .headers()
        .get(reqwest::header::CONTENT_RANGE)?
        .to_str()
        .ok()?;
    let rest = v.strip_prefix("bytes ")?;
    let (range, total) = rest.split_once('/')?;
    let (start, _end) = range.split_once('-')?;
    Some((start.parse().ok()?, total.parse().ok()))
}

fn sha256_file(
    path: &Path,
    cancel: &AtomicBool,
    mut on_block: impl FnMut(u64),
) -> Result<String, DownloadError> {
    let mut f = std::fs::File::open(path).map_err(|e| DownloadError::Io(e.to_string()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut done = 0u64;
    loop {
        if cancel.load(Ordering::SeqCst) {
            return Err(DownloadError::Cancelled);
        }
        let n = f
            .read(&mut buf)
            .map_err(|e| DownloadError::Io(e.to_string()))?;
        if n == 0 {
            break;
        }
        hasher.update(buf.get(..n).unwrap_or(&[]));
        done += n as u64;
        on_block(done);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Download `plan` into `dir`, resuming a partial file when the server agrees. Returns how the
/// finished file was checked (`pinned`, `server` or `size`).
pub async fn download(
    plan: &Plan<'_>,
    dir: &Path,
    cancel: &AtomicBool,
    on_progress: &mut (dyn FnMut(Progress) + Send),
) -> Result<String, DownloadError> {
    std::fs::create_dir_all(dir).map_err(|e| DownloadError::Io(e.to_string()))?;
    let part = part_path(dir, plan.file);
    let meta = meta_path(dir, plan.file);
    let final_path = model_path(dir, plan.file);

    let info = head(plan.url).await?;
    let mut total = info.total;

    // Is there a partial file that belongs to this exact download?
    let mut have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    if have > 0 {
        let same = std::fs::read_to_string(&meta)
            .ok()
            .and_then(|s| serde_json::from_str::<PartMeta>(&s).ok())
            .map(|m| {
                m.url == plan.url
                    && m.sha == info.sha
                    && (m.total.is_none() || total.is_none() || m.total == total)
            })
            .unwrap_or(false);
        if !same || total.map(|t| have > t).unwrap_or(false) {
            let _ = std::fs::remove_file(&part);
            have = 0;
        }
    }

    let expected_total = total.unwrap_or(plan.approx_bytes);
    let needed = expected_total
        .saturating_sub(have)
        .saturating_add(SPACE_MARGIN);
    if let Some(free) = free_bytes(dir) {
        if free < needed {
            return Err(DownloadError::DiskFull { needed, free });
        }
    }
    let write_meta = |total: Option<u64>| {
        let m = PartMeta {
            url: plan.url.to_string(),
            sha: info.sha.clone(),
            total,
        };
        if let Ok(json) = serde_json::to_string(&m) {
            let _ = std::fs::write(&meta, json);
        }
    };
    write_meta(total);

    let mut last = Instant::now() - PROGRESS_EVERY;
    let mut emit = |state: &'static str,
                    done: u64,
                    total: u64,
                    force: bool,
                    f: &mut (dyn FnMut(Progress) + Send)| {
        if force || last.elapsed() >= PROGRESS_EVERY {
            last = Instant::now();
            f(Progress { state, done, total });
        }
    };

    if total != Some(have) || have == 0 {
        let http = client(true);
        let mut attempt = 0;
        loop {
            attempt += 1;
            if cancel.load(Ordering::SeqCst) {
                return Err(DownloadError::Cancelled);
            }
            let mut req = http.get(plan.url);
            if have > 0 {
                req = req.header(reqwest::header::RANGE, format!("bytes={have}-"));
            }
            let mut resp = req.send().await.map_err(map_err)?;
            let status = resp.status();
            if status == reqwest::StatusCode::RANGE_NOT_SATISFIABLE && have > 0 && attempt < 3 {
                let _ = std::fs::remove_file(&part);
                have = 0;
                continue;
            }
            if !status.is_success() {
                return Err(DownloadError::Server(status.as_u16()));
            }
            // 206 must start where we asked; a 200 means the server ignored the range.
            let append = if status == reqwest::StatusCode::PARTIAL_CONTENT {
                match content_range(&resp) {
                    Some((start, t)) if start == have => {
                        if total.is_none() {
                            total = t;
                        }
                        true
                    }
                    _ if attempt < 3 => {
                        let _ = std::fs::remove_file(&part);
                        have = 0;
                        continue;
                    }
                    _ => return Err(DownloadError::Server(206)),
                }
            } else {
                if total.is_none() {
                    total = resp.content_length().filter(|n| *n > 0);
                }
                false
            };
            if !append {
                have = 0;
            }
            write_meta(total);

            let mut file = tokio::fs::OpenOptions::new()
                .create(true)
                .write(true)
                .append(append)
                .truncate(!append)
                .open(&part)
                .await
                .map_err(|e| DownloadError::Io(e.to_string()))?;
            let mut done = have;
            let shown_total = total.unwrap_or(plan.approx_bytes);
            emit("downloading", done, shown_total, true, on_progress);
            loop {
                if cancel.load(Ordering::SeqCst) {
                    let _ = file.flush().await;
                    return Err(DownloadError::Cancelled);
                }
                match tokio::time::timeout(STALL, resp.chunk()).await {
                    Err(_) => {
                        let _ = file.flush().await;
                        return Err(DownloadError::Offline("the connection stalled".into()));
                    }
                    Ok(Err(e)) => {
                        let _ = file.flush().await;
                        return Err(map_err(e));
                    }
                    Ok(Ok(None)) => break,
                    Ok(Ok(Some(bytes))) => {
                        file.write_all(&bytes)
                            .await
                            .map_err(|e| DownloadError::Io(e.to_string()))?;
                        done += bytes.len() as u64;
                        emit(
                            "downloading",
                            done,
                            total.unwrap_or(plan.approx_bytes).max(done),
                            false,
                            on_progress,
                        );
                    }
                }
            }
            file.flush()
                .await
                .map_err(|e| DownloadError::Io(e.to_string()))?;
            file.sync_all()
                .await
                .map_err(|e| DownloadError::Io(e.to_string()))?;
            break;
        }
    }

    let size = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    if let Some(t) = total {
        if size < t {
            return Err(DownloadError::Offline("the connection closed early".into()));
        }
        if size > t {
            let _ = std::fs::remove_file(&part);
            let _ = std::fs::remove_file(&meta);
            return Err(DownloadError::Checksum);
        }
    }
    if size < MIN_MODEL_BYTES {
        let _ = std::fs::remove_file(&part);
        let _ = std::fs::remove_file(&meta);
        return Err(DownloadError::TooSmall);
    }

    // Verify: read the whole file once.
    let expected = plan
        .pinned_sha
        .map(str::to_ascii_lowercase)
        .or_else(|| info.sha.clone());
    let mut how = "size";
    if let Some(expected) = expected {
        emit("verifying", 0, size, true, on_progress);
        let part2 = part.clone();
        let actual = {
            // The hash runs on a blocking thread; the flag is shared by value through a static-free Arc.
            let flag = std::sync::Arc::new(AtomicBool::new(false));
            let flag2 = flag.clone();
            let handle = tokio::task::spawn_blocking(move || sha256_file(&part2, &flag2, |_| {}));
            // Mirror the caller's cancel flag onto the blocking task while it runs.
            let mut handle = handle;
            loop {
                tokio::select! {
                    res = &mut handle => break res.map_err(|e| DownloadError::Io(e.to_string()))??,
                    _ = tokio::time::sleep(Duration::from_millis(200)) => {
                        if cancel.load(Ordering::SeqCst) {
                            flag.store(true, Ordering::SeqCst);
                        }
                    }
                }
            }
        };
        if actual != expected {
            let _ = std::fs::remove_file(&part);
            let _ = std::fs::remove_file(&meta);
            return Err(DownloadError::Checksum);
        }
        how = if plan.pinned_sha.is_some() {
            "pinned"
        } else {
            "server"
        };
    }

    std::fs::rename(&part, &final_path).map_err(|e| DownloadError::Io(e.to_string()))?;
    let _ = std::fs::remove_file(&meta);
    let _ = std::fs::write(verified_path(dir, plan.file), how);
    emit("done", size, size, true, on_progress);
    Ok(how.to_string())
}

// ---------------------------------------------------------------- daemon glue

use crate::daemon::DaemonContext;
use halcyon_music_core::protocol::{self, EventBody};
use std::sync::{Arc, Mutex};
use tracing::{info, warn};

struct Active {
    id: String,
    cancel: Arc<AtomicBool>,
}

static ACTIVE: Mutex<Option<Active>> = Mutex::new(None);

fn download_event(
    id: &str,
    state: &str,
    done: u64,
    total: u64,
    error: Option<String>,
) -> protocol::Event {
    protocol::event(EventBody::LlmDownload {
        id: id.to_string(),
        state: state.to_string(),
        done,
        total,
        error,
    })
}

/// Tell every client which models exist and what is on disk.
pub fn announce_models(ctx: &DaemonContext) {
    let settings = super::load_settings(&ctx.cache);
    let active = if settings.backend == "local" {
        settings.local_model.clone()
    } else {
        String::new()
    };
    let _ = ctx.events_tx.send(protocol::event(EventBody::LlmModels {
        models: list(&models_dir()),
        engine: super::local::engine_available(),
        active,
        dir: models_dir().display().to_string(),
    }));
}

pub fn is_downloading() -> bool {
    ACTIVE.lock().map(|a| a.is_some()).unwrap_or(false)
}

/// Start downloading model `id` in the background. Does nothing when it is already installed or
/// a download is running; says so on the event stream when the id is unknown.
pub fn spawn_download(ctx: Arc<DaemonContext>, id: String) {
    let Some(spec) = find(&id) else {
        let _ = ctx.events_tx.send(download_event(
            &id,
            "failed",
            0,
            0,
            Some("That model isn't in the list.".into()),
        ));
        return;
    };
    if disk_status(&models_dir(), spec.file).installed {
        announce_models(&ctx);
        return;
    }
    let cancel = Arc::new(AtomicBool::new(false));
    {
        let Ok(mut active) = ACTIVE.lock() else {
            return;
        };
        if let Some(a) = active.as_ref() {
            if a.id != id {
                let _ = ctx.events_tx.send(download_event(
                    &id,
                    "failed",
                    0,
                    0,
                    Some("Another model is downloading. Wait for it or cancel it first.".into()),
                ));
            }
            return;
        }
        *active = Some(Active {
            id: id.clone(),
            cancel: cancel.clone(),
        });
    }
    crate::supervisor::run_guarded("llm-model-download", async move {
        info!(model = spec.id, "model download started");
        let tx = ctx.events_tx.clone();
        let model_id = spec.id.to_string();
        let mut progress = move |p: Progress| {
            let _ = tx.send(download_event(&model_id, p.state, p.done, p.total, None));
        };
        let dir = models_dir();
        let result = download(&Plan::from_spec(spec), &dir, &cancel, &mut progress).await;
        if let Ok(mut active) = ACTIVE.lock() {
            *active = None;
        }
        match result {
            Ok(how) => {
                info!(model = spec.id, checked = %how, "model download finished");
                let size = disk_status(&dir, spec.file).size;
                let _ = ctx
                    .events_tx
                    .send(download_event(spec.id, "done", size, size, None));
                announce_models(&ctx);
                super::model_ready(ctx.clone(), spec.id);
            }
            Err(DownloadError::Cancelled) => {
                let d = disk_status(&dir, spec.file);
                let _ =
                    ctx.events_tx
                        .send(download_event(spec.id, "cancelled", d.partial, 0, None));
                announce_models(&ctx);
            }
            Err(e) => {
                warn!(model = spec.id, "model download failed: {e}");
                let d = disk_status(&dir, spec.file);
                let _ = ctx.events_tx.send(download_event(
                    spec.id,
                    "failed",
                    d.partial,
                    0,
                    Some(e.to_string()),
                ));
                announce_models(&ctx);
            }
        }
    });
}

/// Stop the running download (what was fetched stays for the next try).
pub fn cancel_download() {
    if let Ok(active) = ACTIVE.lock() {
        if let Some(a) = active.as_ref() {
            a.cancel.store(true, Ordering::SeqCst);
        }
    }
}

/// Delete a model file. Refused while that model is downloading.
pub fn delete_model(ctx: &DaemonContext, id: &str) {
    let Some(spec) = find(id) else { return };
    let busy = ACTIVE
        .lock()
        .map(|a| a.as_ref().map(|a| a.id == id).unwrap_or(false))
        .unwrap_or(false);
    if busy {
        let _ = ctx.events_tx.send(download_event(
            id,
            "failed",
            0,
            0,
            Some("Cancel the download before deleting it.".into()),
        ));
        return;
    }
    // The model may be loaded in memory: let go of it first.
    super::local::unload_now();
    delete_files(&models_dir(), spec.file);
    info!(model = spec.id, "model deleted");
    announce_models(ctx);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> tempfile::TempDir {
        tempfile::tempdir().expect("tempdir")
    }

    #[test]
    fn catalogue_is_sane() {
        assert_eq!(CATALOGUE.len(), 4);
        let mut ids = std::collections::HashSet::new();
        for m in CATALOGUE {
            assert!(ids.insert(m.id), "duplicate id {}", m.id);
            assert!(m.url.starts_with("https://"), "{}", m.id);
            assert!(
                m.url.ends_with(m.file),
                "file name must be the end of the URL: {}",
                m.id
            );
            assert!(
                m.file.ends_with(".gguf") && !m.file.contains('/'),
                "{}",
                m.id
            );
            assert!(
                m.approx_bytes > 100_000_000 && m.approx_bytes < 2_000_000_000,
                "{}",
                m.id
            );
            assert!(!m.licence.is_empty());
            if let Some(h) = m.sha256 {
                assert!(clean_sha(h).is_some(), "bad pinned checksum for {}", m.id);
            }
        }
        assert!(is_known(DEFAULT_LOCAL_MODEL));
        assert!(!is_known("../../etc/passwd"));
        // The default must be the permissively licensed one.
        assert_eq!(
            find(DEFAULT_LOCAL_MODEL).map(|m| m.licence),
            Some("Apache-2.0")
        );
    }

    #[test]
    fn checksums_are_cleaned_from_etag_shapes() {
        let h = "a".repeat(64);
        assert_eq!(clean_sha(&format!("\"{h}\"")), Some(h.clone()));
        assert_eq!(clean_sha(&format!("W/\"{h}\"")), Some(h.clone()));
        assert_eq!(clean_sha(&h.to_uppercase()), Some(h));
        assert_eq!(clean_sha("\"abc123\""), None);
        assert_eq!(clean_sha(&"g".repeat(64)), None);
    }

    #[test]
    fn disk_status_needs_the_gguf_magic_and_a_real_size() {
        let dir = tmp();
        let file = "m.gguf";
        assert_eq!(disk_status(dir.path(), file), DiskStatus::default());
        // too small
        std::fs::write(dir.path().join(file), b"GGUF").expect("write");
        assert!(!disk_status(dir.path(), file).installed);
        // big enough but not a GGUF
        std::fs::write(dir.path().join(file), vec![0u8; 2_000_000]).expect("write");
        assert!(!disk_status(dir.path(), file).installed);
        // a believable file
        let mut bytes = b"GGUF".to_vec();
        bytes.resize(2_000_000, 0);
        std::fs::write(dir.path().join(file), &bytes).expect("write");
        std::fs::write(dir.path().join("m.gguf.verified"), "server\n").expect("write");
        let d = disk_status(dir.path(), file);
        assert!(d.installed);
        assert_eq!(d.size, 2_000_000);
        assert_eq!(d.verified, "server");
    }

    #[test]
    fn partial_downloads_are_reported_and_delete_removes_everything() {
        let dir = tmp();
        std::fs::write(dir.path().join("m.gguf.part"), vec![1u8; 1234]).expect("write");
        std::fs::write(dir.path().join("m.gguf.part.json"), "{}").expect("write");
        let d = disk_status(dir.path(), "m.gguf");
        assert!(!d.installed);
        assert_eq!(d.partial, 1234);
        delete_files(dir.path(), "m.gguf");
        assert_eq!(std::fs::read_dir(dir.path()).expect("dir").count(), 0);
    }

    #[test]
    fn info_shows_the_estimate_until_the_file_exists() {
        let dir = tmp();
        let spec = &CATALOGUE[0];
        let i = info(spec, dir.path());
        assert!(!i.installed);
        assert_eq!(i.size_bytes, spec.approx_bytes);
        assert_eq!(i.verified, "");
        assert_eq!(list(dir.path()).len(), CATALOGUE.len());
    }

    #[test]
    fn error_messages_are_plain_language_with_a_next_step() {
        assert!(DownloadError::Offline("dns".into())
            .to_string()
            .contains("try again"));
        assert!(DownloadError::DiskFull {
            needed: 600_000_000,
            free: 100_000_000
        }
        .to_string()
        .contains("Free some space"));
        assert!(DownloadError::Checksum.to_string().contains("deleted"));
        assert!(DownloadError::Cancelled.to_string().contains("resumes"));
        assert!(DownloadError::Server(503).to_string().contains("503"));
    }

    #[test]
    fn content_range_parsing() {
        // Parsed through a real response object in the integration tests; here only the sha cleaner and
        // sha256_file are checked.
        let dir = tmp();
        let p = dir.path().join("f");
        std::fs::write(&p, b"abc").expect("write");
        let h = sha256_file(&p, &AtomicBool::new(false), |_| {}).expect("hash");
        assert_eq!(
            h,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_file(&p, &AtomicBool::new(true), |_| {}),
            Err(DownloadError::Cancelled)
        );
    }
}
