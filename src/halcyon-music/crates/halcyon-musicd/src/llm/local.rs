//! The built-in model backend: a small GGUF model run inside the daemon with llama.cpp.
//!
//! Layout:
//! - [`TasteLlm`] is implemented by [`LocalGgufBackend`], which only knows *which file* and
//!   hands the work to a [`Generator`].
//! - [`Generator`] is the seam to the engine. With the `local-llm` feature it is the llama.cpp
//!   engine in [`engine`]; without it, [`NoEngine`] answers "this build has no engine". Tests use a fake.
//! - The model is loaded on the first call and let go after [`IDLE_UNLOAD`] of silence; one job
//!   runs at a time; inference runs on its own low-priority thread with a small thread count, so
//!   the audio threads never wait for it.
//!
//! The model only writes words. The grammar (`grammar.rs`) fixes the JSON shape, and every answer still
//! goes through the same validators as an Ollama answer, so it cannot add songs.

use super::backend::{BoxFuture, LlmError, LlmRequest, TasteLlm};
use super::models;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

/// How long the model stays in memory after its last use.
pub const IDLE_UNLOAD: Duration = Duration::from_secs(120);
/// One call may take this long: loading the file, reading the prompt and writing a short answer on a few CPU threads.
pub const LOCAL_CALL_TIMEOUT: Duration = Duration::from_secs(90);
const REAPER_EVERY: Duration = Duration::from_secs(15);

/// What the backend needs from an inference engine.
pub trait Generator: Send + Sync {
    /// Is there an engine in this build?
    fn available(&self) -> bool;
    /// Run one request to the end (blocking). `cancel` is checked between tokens; when it is set the
    /// call stops and returns `Err(LlmError::Timeout)`.
    fn generate(
        &self,
        model_file: &Path,
        model_id: &str,
        req: &LlmRequest,
        cancel: &AtomicBool,
    ) -> Result<String, LlmError>;
    /// Drop the loaded model if it has not been used for `idle`. True when something was unloaded.
    fn unload_if_idle(&self, idle: Duration) -> bool;
    /// Drop the loaded model now.
    fn unload(&self);
    /// Id of the model in memory, if any.
    fn loaded(&self) -> Option<String>;
    /// Set once the idle reaper is running for this generator.
    fn reaper_flag(&self) -> &AtomicBool;
}

/// The generator of a build without the engine.
#[derive(Default)]
pub struct NoEngine {
    reaper: AtomicBool,
}

impl Generator for NoEngine {
    fn available(&self) -> bool {
        false
    }
    fn generate(
        &self,
        _: &Path,
        _: &str,
        _: &LlmRequest,
        _: &AtomicBool,
    ) -> Result<String, LlmError> {
        Err(LlmError::EngineMissing)
    }
    fn unload_if_idle(&self, _: Duration) -> bool {
        false
    }
    fn unload(&self) {}
    fn loaded(&self) -> Option<String> {
        None
    }
    fn reaper_flag(&self) -> &AtomicBool {
        &self.reaper
    }
}

static GLOBAL: OnceLock<Arc<dyn Generator>> = OnceLock::new();

/// The process-wide engine. Backends are rebuilt for every job, but the loaded model must outlive them.
pub fn global() -> Arc<dyn Generator> {
    GLOBAL
        .get_or_init(|| {
            #[cfg(feature = "local-llm")]
            {
                Arc::new(engine::LlamaGenerator::new()) as Arc<dyn Generator>
            }
            #[cfg(not(feature = "local-llm"))]
            {
                Arc::new(NoEngine::default()) as Arc<dyn Generator>
            }
        })
        .clone()
}

/// Does this build carry the embedded engine?
pub fn engine_available() -> bool {
    cfg!(feature = "local-llm")
}

/// Let go of the model now (for example before deleting its file).
pub fn unload_now() {
    if let Some(g) = GLOBAL.get() {
        g.unload();
    }
}

/// Start the task that unloads the model after a quiet spell. Once per generator.
fn start_reaper(gen: &Arc<dyn Generator>) {
    if gen.reaper_flag().swap(true, Ordering::SeqCst) {
        return;
    }
    let gen = gen.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(REAPER_EVERY).await;
            if gen.unload_if_idle(IDLE_UNLOAD) {
                tracing::debug!("built-in model unloaded after idle");
            }
        }
    });
}

/// Sets the flag when dropped before it is disarmed: a call that timed out stops its thread.
struct CancelOnDrop {
    flag: Arc<AtomicBool>,
    armed: bool,
}

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if self.armed {
            self.flag.store(true, Ordering::SeqCst);
        }
    }
}

pub struct LocalGgufBackend {
    dir: PathBuf,
    model_id: String,
    generator: Arc<dyn Generator>,
}

impl LocalGgufBackend {
    pub fn new(dir: PathBuf, model_id: &str, generator: Arc<dyn Generator>) -> Self {
        Self {
            dir,
            model_id: model_id.to_string(),
            generator,
        }
    }

    /// The real thing: the models folder and the process-wide engine.
    pub fn production(model_id: &str) -> Self {
        Self::new(models::models_dir(), model_id, global())
    }

    /// The model's file, when it is downloaded and complete.
    fn file(&self) -> Result<PathBuf, LlmError> {
        let spec = models::find(&self.model_id)
            .ok_or_else(|| LlmError::LocalModelMissing(self.model_id.clone()))?;
        if models::disk_status(&self.dir, spec.file).installed {
            Ok(models::model_path(&self.dir, spec.file))
        } else {
            Err(LlmError::LocalModelMissing(self.model_id.clone()))
        }
    }
}

impl TasteLlm for LocalGgufBackend {
    fn backend_name(&self) -> &str {
        "local"
    }

    fn model(&self) -> &str {
        &self.model_id
    }

    fn complete<'a>(&'a self, req: &'a LlmRequest) -> BoxFuture<'a, Result<String, LlmError>> {
        Box::pin(async move {
            if !self.generator.available() {
                return Err(LlmError::EngineMissing);
            }
            let file = self.file()?;
            start_reaper(&self.generator);

            let cancel = Arc::new(AtomicBool::new(false));
            let mut guard = CancelOnDrop {
                flag: cancel.clone(),
                armed: true,
            };
            let (tx, rx) = tokio::sync::oneshot::channel();
            let gen = self.generator.clone();
            let id = self.model_id.clone();
            let request = req.clone();
            // A thread of its own: it can be given a low priority without touching the runtime's
            // worker threads, and a stuck model can never starve them.
            std::thread::Builder::new()
                .name("halcyon-llm".to_string())
                .spawn(move || {
                    let _ = tx.send(gen.generate(&file, &id, &request, &cancel));
                })
                .map_err(|e| {
                    LlmError::BadResponse(format!("could not start the model thread: {e}"))
                })?;
            let result = rx
                .await
                .map_err(|_| LlmError::BadResponse("the model stopped unexpectedly".to_string()))?;
            guard.armed = false;
            result
        })
    }

    fn probe<'a>(&'a self) -> BoxFuture<'a, Result<(), LlmError>> {
        Box::pin(async move {
            if !self.generator.available() {
                return Err(LlmError::EngineMissing);
            }
            self.file().map(|_| ())
        })
    }

    fn call_timeout(&self) -> Duration {
        LOCAL_CALL_TIMEOUT
    }
}

/// How many threads inference may use: half the cores, at least one and at most four, so
/// playback and the interface keep theirs.
pub fn inference_threads(cores: usize) -> i32 {
    i32::try_from((cores / 2).clamp(1, 4)).unwrap_or(2)
}

/// ChatML, the fallback prompt format when a model carries no usable chat template.
pub fn chatml_prompt(system: &str, user: &str) -> String {
    format!("<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{user}<|im_end|>\n<|im_start|>assistant\n")
}

/// True once `text` is one complete JSON value: used to stop generating as soon as the answer is whole.
pub fn is_complete_json(text: &[u8]) -> bool {
    text.last() == Some(&b'}') && serde_json::from_slice::<serde_json::Value>(text).is_ok()
}

#[cfg(feature = "local-llm")]
pub mod engine {
    //! llama.cpp through the `llama-cpp-2` crate.

    use super::*;
    use crate::llm::grammar;
    use llama_cpp_2::context::params::LlamaContextParams;
    use llama_cpp_2::llama_backend::LlamaBackend;
    use llama_cpp_2::llama_batch::LlamaBatch;
    use llama_cpp_2::model::params::LlamaModelParams;
    use llama_cpp_2::model::{LlamaChatMessage, LlamaModel};
    use llama_cpp_2::sampling::LlamaSampler;
    use std::num::NonZeroU32;
    use std::sync::Mutex;
    use std::time::Instant;

    /// Prompt and answer must fit in this many tokens.
    const N_CTX: u32 = 4096;
    const N_BATCH: usize = 512;
    const SEED: u32 = 0x5EED;

    struct Loaded {
        path: PathBuf,
        model: LlamaModel,
        last_used: Instant,
    }

    pub struct LlamaGenerator {
        backend: OnceLock<Result<LlamaBackend, String>>,
        state: Mutex<Option<Loaded>>,
        reaper: AtomicBool,
        threads: i32,
    }

    impl Default for LlamaGenerator {
        fn default() -> Self {
            Self::new()
        }
    }

    impl LlamaGenerator {
        pub fn new() -> Self {
            let cores = std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(2);
            Self {
                backend: OnceLock::new(),
                state: Mutex::new(None),
                reaper: AtomicBool::new(false),
                threads: inference_threads(cores),
            }
        }

        fn backend(&self) -> Result<&LlamaBackend, LlmError> {
            self.backend
                .get_or_init(|| {
                    LlamaBackend::init()
                        .map(|mut b| {
                            // llama.cpp's own log lines would go to stderr; ours go to the log file.
                            b.void_logs();
                            b
                        })
                        .map_err(|e| e.to_string())
                })
                .as_ref()
                .map_err(|e| LlmError::LocalModelBroken(format!("engine did not start: {e}")))
        }
    }

    /// Lower this thread's priority so audio and the interface win any contest for the CPU. The
    /// inference thread is dedicated, so it is not restored.
    fn lower_priority() {
        // SAFETY: plain syscalls on the calling thread; failure (no permission) is ignored.
        unsafe {
            let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
            let _ = libc::setpriority(libc::PRIO_PROCESS, tid, 10);
        }
    }

    fn build_prompt(model: &LlamaModel, system: &str, user: &str) -> String {
        let clean = |s: &str| s.replace('\0', "");
        let (system, user) = (clean(system), clean(user));
        let templated = (|| {
            let tmpl = model.chat_template(None).ok()?;
            let msgs = vec![
                LlamaChatMessage::new("system".to_string(), system.clone()).ok()?,
                LlamaChatMessage::new("user".to_string(), user.clone()).ok()?,
            ];
            model.apply_chat_template(&tmpl, &msgs, true).ok()
        })();
        let mut prompt = templated.unwrap_or_else(|| chatml_prompt(&system, &user));
        // Qwen3 writes a hidden "thinking" block unless told not to; the grammar would cut it off
        // mid-thought, so close the block ourselves (the format its own non-thinking mode uses).
        if model
            .meta_val_str("general.architecture")
            .map(|a| a.starts_with("qwen3"))
            .unwrap_or(false)
        {
            prompt.push_str("<think>\n\n</think>\n\n");
        }
        prompt
    }

    fn run(
        backend: &LlamaBackend,
        model: &LlamaModel,
        req: &LlmRequest,
        cancel: &AtomicBool,
        threads: i32,
    ) -> Result<String, LlmError> {
        let stopped = || cancel.load(Ordering::SeqCst);
        let mut system = req.system.clone();
        if let Some(extra) = grammar::addendum(&req.shape) {
            system.push_str(&extra);
        }
        let prompt = build_prompt(model, &system, &req.user);

        let vocab = model.vocab();
        let mut tokens = vocab.tokenize(prompt.as_bytes(), false, true);
        if vocab.should_add_bos() && tokens.first() != Some(&vocab.bos()) {
            tokens.insert(0, vocab.bos());
        }
        let n_ctx = N_CTX as usize;
        if tokens.is_empty() || tokens.len() + 16 > n_ctx {
            return Err(LlmError::BadResponse(
                "the request was too long for the model".to_string(),
            ));
        }
        let max_new = (req.max_tokens as usize).min(n_ctx - tokens.len()).max(1);

        let params = LlamaContextParams::default()
            .with_n_ctx(NonZeroU32::new(N_CTX))
            .with_n_batch(N_BATCH as u32)
            .with_n_threads(threads)
            .with_n_threads_batch(threads);
        let mut ctx = model.new_context(backend, params).map_err(|e| {
            LlmError::BadResponse(format!("not enough memory to run the model ({e})"))
        })?;

        let grammar_text = grammar::grammar_for(&req.shape);
        let mut chain = vec![
            LlamaSampler::grammar(model, &grammar_text, "root").map_err(|e| {
                LlmError::BadResponse(format!(
                    "the answer format was rejected by the engine: {e:?}"
                ))
            })?,
        ];
        if req.temperature > 0.01 {
            chain.push(LlamaSampler::temp(req.temperature));
            chain.push(LlamaSampler::dist(SEED));
        } else {
            chain.push(LlamaSampler::greedy());
        }
        let mut sampler = LlamaSampler::chain_simple(chain);

        // Read the prompt in batches, so a long prompt can still be cancelled.
        let mut batch = LlamaBatch::new(N_BATCH, 1);
        let last = tokens.len() - 1;
        for (ci, chunk) in tokens.chunks(N_BATCH).enumerate() {
            if stopped() {
                return Err(LlmError::Timeout);
            }
            batch.clear();
            for (i, t) in chunk.iter().enumerate() {
                let pos = ci * N_BATCH + i;
                batch
                    .add(
                        *t,
                        i32::try_from(pos).unwrap_or(i32::MAX),
                        &[0],
                        pos == last,
                    )
                    .map_err(|e| LlmError::BadResponse(e.to_string()))?;
            }
            ctx.decode(&mut batch).map_err(|e| {
                LlmError::BadResponse(format!("the model could not read the request ({e})"))
            })?;
        }

        let mut out: Vec<u8> = Vec::with_capacity(512);
        let mut pos = tokens.len();
        let mut idx = batch.n_tokens() - 1;
        for _ in 0..max_new {
            if stopped() {
                return Err(LlmError::Timeout);
            }
            let tok = sampler.sample(&ctx, idx);
            if vocab.is_eog(tok) {
                break;
            }
            out.extend_from_slice(&vocab.token_to_piece(tok, false, None));
            if is_complete_json(&out) {
                break;
            }
            batch.clear();
            batch
                .add(tok, i32::try_from(pos).unwrap_or(i32::MAX), &[0], true)
                .map_err(|e| LlmError::BadResponse(e.to_string()))?;
            ctx.decode(&mut batch).map_err(|e| {
                LlmError::BadResponse(format!("the model stopped while answering ({e})"))
            })?;
            pos += 1;
            idx = 0;
        }
        let text = String::from_utf8_lossy(&out).into_owned();
        if text.trim().is_empty() {
            return Err(LlmError::BadResponse("empty answer".to_string()));
        }
        Ok(text)
    }

    impl Generator for LlamaGenerator {
        fn available(&self) -> bool {
            true
        }

        fn generate(
            &self,
            model_file: &Path,
            model_id: &str,
            req: &LlmRequest,
            cancel: &AtomicBool,
        ) -> Result<String, LlmError> {
            lower_priority();
            let backend = self.backend()?;
            // One job at a time; a poisoned lock only means an earlier job panicked.
            let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
            if state.as_ref().map(|l| l.path != model_file).unwrap_or(true) {
                *state = None; // free the old model before mapping the new one
                tracing::info!(model = model_id, "loading the built-in model");
                let params = LlamaModelParams::default();
                let model = LlamaModel::load_from_file(backend, model_file, &params)
                    .map_err(|e| LlmError::LocalModelBroken(e.to_string()))?;
                *state = Some(Loaded {
                    path: model_file.to_path_buf(),
                    model,
                    last_used: Instant::now(),
                });
            }
            let Some(loaded) = state.as_mut() else {
                return Err(LlmError::LocalModelBroken("model not loaded".to_string()));
            };
            let result = run(backend, &loaded.model, req, cancel, self.threads);
            loaded.last_used = Instant::now();
            result
        }

        fn unload_if_idle(&self, idle: Duration) -> bool {
            // Never wait for a running job: if the lock is busy the model is in use.
            let Ok(mut state) = self.state.try_lock() else {
                return false;
            };
            let expired = state
                .as_ref()
                .map(|l| l.last_used.elapsed() >= idle)
                .unwrap_or(false);
            if expired {
                *state = None;
            }
            expired
        }

        fn unload(&self) {
            let mut state = self.state.lock().unwrap_or_else(|p| p.into_inner());
            *state = None;
        }

        fn loaded(&self) -> Option<String> {
            self.state.try_lock().ok().and_then(|s| {
                s.as_ref().map(|l| {
                    l.path
                        .file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default()
                })
            })
        }

        fn reaper_flag(&self) -> &AtomicBool {
            &self.reaper
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::backend::Shape;
    use std::sync::atomic::AtomicUsize;
    use std::sync::Mutex;

    /// A scripted engine for the backend's own logic.
    struct Fake {
        reaper: AtomicBool,
        calls: AtomicUsize,
        running: AtomicUsize,
        max_running: AtomicUsize,
        loaded: Mutex<Option<String>>,
        reply: Mutex<Result<String, LlmError>>,
        delay: Duration,
        saw_cancel: AtomicBool,
        unloads: AtomicUsize,
    }

    impl Fake {
        fn new(reply: Result<String, LlmError>) -> Arc<Self> {
            Arc::new(Self {
                reaper: AtomicBool::new(false),
                calls: AtomicUsize::new(0),
                running: AtomicUsize::new(0),
                max_running: AtomicUsize::new(0),
                loaded: Mutex::new(None),
                reply: Mutex::new(reply),
                delay: Duration::ZERO,
                saw_cancel: AtomicBool::new(false),
                unloads: AtomicUsize::new(0),
            })
        }
        fn slow(delay: Duration) -> Arc<Self> {
            let mut f = Arc::try_unwrap(Self::new(Ok("{}".into())))
                .ok()
                .expect("unique");
            f.delay = delay;
            Arc::new(f)
        }
    }

    impl Generator for Fake {
        fn available(&self) -> bool {
            true
        }
        fn generate(
            &self,
            _f: &Path,
            id: &str,
            _r: &LlmRequest,
            cancel: &AtomicBool,
        ) -> Result<String, LlmError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            let now = self.running.fetch_add(1, Ordering::SeqCst) + 1;
            self.max_running.fetch_max(now, Ordering::SeqCst);
            *self.loaded.lock().expect("lock") = Some(id.to_string());
            let start = std::time::Instant::now();
            while start.elapsed() < self.delay {
                if cancel.load(Ordering::SeqCst) {
                    self.saw_cancel.store(true, Ordering::SeqCst);
                    self.running.fetch_sub(1, Ordering::SeqCst);
                    return Err(LlmError::Timeout);
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            self.running.fetch_sub(1, Ordering::SeqCst);
            self.reply.lock().expect("lock").clone()
        }
        fn unload_if_idle(&self, _: Duration) -> bool {
            false
        }
        fn unload(&self) {
            self.unloads.fetch_add(1, Ordering::SeqCst);
            *self.loaded.lock().expect("lock") = None;
        }
        fn loaded(&self) -> Option<String> {
            self.loaded.lock().expect("lock").clone()
        }
        fn reaper_flag(&self) -> &AtomicBool {
            &self.reaper
        }
    }

    fn req() -> LlmRequest {
        LlmRequest {
            system: "s".into(),
            user: "u".into(),
            temperature: 0.2,
            max_tokens: 50,
            shape: Shape::AnyJson,
        }
    }

    /// A models folder holding a believable file for the default model.
    fn dir_with_model() -> (tempfile::TempDir, &'static str) {
        let dir = tempfile::tempdir().expect("tempdir");
        let spec = models::find(models::DEFAULT_LOCAL_MODEL).expect("default model");
        let mut bytes = b"GGUF".to_vec();
        bytes.resize(1_500_000, 0);
        std::fs::write(dir.path().join(spec.file), bytes).expect("write");
        (dir, spec.id)
    }

    #[tokio::test]
    async fn answers_through_the_generator_when_the_model_is_on_disk() {
        let (dir, id) = dir_with_model();
        let fake = Fake::new(Ok("{\"picks\":[\"t1\"]}".into()));
        let b = LocalGgufBackend::new(dir.path().to_path_buf(), id, fake.clone());
        assert_eq!(b.backend_name(), "local");
        assert_eq!(b.model(), id);
        assert!(b.probe().await.is_ok());
        assert_eq!(
            b.complete(&req()).await,
            Ok("{\"picks\":[\"t1\"]}".to_string())
        );
        assert_eq!(fake.calls.load(Ordering::SeqCst), 1);
        assert_eq!(fake.loaded(), Some(id.to_string()));
    }

    #[tokio::test]
    async fn a_missing_file_is_a_plain_error_and_never_reaches_the_engine() {
        let dir = tempfile::tempdir().expect("tempdir");
        let fake = Fake::new(Ok("{}".into()));
        let b = LocalGgufBackend::new(
            dir.path().to_path_buf(),
            models::DEFAULT_LOCAL_MODEL,
            fake.clone(),
        );
        let e = b.complete(&req()).await.expect_err("missing");
        assert!(matches!(e, LlmError::LocalModelMissing(_)));
        assert!(e.is_permanent());
        assert!(e.to_string().contains("Download"));
        assert!(matches!(
            b.probe().await,
            Err(LlmError::LocalModelMissing(_))
        ));
        assert_eq!(fake.calls.load(Ordering::SeqCst), 0);
        // an unknown id is the same error, not a path lookup
        let weird = LocalGgufBackend::new(dir.path().to_path_buf(), "../../etc/passwd", fake);
        assert!(matches!(
            weird.probe().await,
            Err(LlmError::LocalModelMissing(_))
        ));
    }

    #[tokio::test]
    async fn a_build_without_the_engine_says_so() {
        let (dir, id) = dir_with_model();
        let b = LocalGgufBackend::new(dir.path().to_path_buf(), id, Arc::new(NoEngine::default()));
        let e = b.complete(&req()).await.expect_err("no engine");
        assert_eq!(e, LlmError::EngineMissing);
        assert!(e.to_string().contains("local-llm"));
        assert_eq!(b.probe().await, Err(LlmError::EngineMissing));
    }

    #[tokio::test]
    async fn engine_errors_pass_through_unchanged() {
        let (dir, id) = dir_with_model();
        let fake = Fake::new(Err(LlmError::LocalModelBroken("bad tensor".into())));
        let b = LocalGgufBackend::new(dir.path().to_path_buf(), id, fake);
        let e = b.complete(&req()).await.expect_err("broken");
        assert!(e.to_string().contains("bad tensor"));
        assert!(e.is_permanent());
    }

    #[tokio::test]
    async fn a_timed_out_call_cancels_the_thread() {
        let (dir, id) = dir_with_model();
        let fake = Fake::slow(Duration::from_secs(30));
        let b = LocalGgufBackend::new(dir.path().to_path_buf(), id, fake.clone());
        let r = tokio::time::timeout(Duration::from_millis(100), b.complete(&req())).await;
        assert!(r.is_err(), "the call should have timed out");
        // The engine thread notices the cancel flag soon after the future was dropped.
        for _ in 0..100 {
            if fake.saw_cancel.load(Ordering::SeqCst) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(
            fake.saw_cancel.load(Ordering::SeqCst),
            "engine was never told to stop"
        );
    }

    #[tokio::test]
    async fn the_idle_reaper_starts_once_per_generator() {
        let (dir, id) = dir_with_model();
        let fake = Fake::new(Ok("{}".into()));
        let b = LocalGgufBackend::new(dir.path().to_path_buf(), id, fake.clone());
        assert!(!fake.reaper_flag().load(Ordering::SeqCst));
        let _ = b.complete(&req()).await;
        assert!(fake.reaper_flag().load(Ordering::SeqCst));
        let _ = b.complete(&req()).await; // does not start a second one
        assert_eq!(fake.calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn local_calls_get_a_longer_timeout_than_ollama() {
        let b = LocalGgufBackend::new(PathBuf::new(), "x", Arc::new(NoEngine::default()));
        assert!(b.call_timeout() >= Duration::from_secs(60));
        assert!(IDLE_UNLOAD >= Duration::from_secs(60) && IDLE_UNLOAD <= Duration::from_secs(600));
    }

    #[test]
    fn thread_count_leaves_cores_for_playback() {
        assert_eq!(inference_threads(1), 1);
        assert_eq!(inference_threads(2), 1);
        assert_eq!(inference_threads(4), 2);
        assert_eq!(inference_threads(8), 4);
        assert_eq!(inference_threads(64), 4);
        assert_eq!(inference_threads(0), 1);
    }

    #[test]
    fn completion_stops_at_the_first_whole_json_value() {
        assert!(is_complete_json(b"{\"a\":1}"));
        assert!(!is_complete_json(b"{\"a\":1"));
        assert!(!is_complete_json(b"{\"a\":\"}\""[..6].as_ref()));
        assert!(is_complete_json(b"{\"a\":\"x}y\"}"));
        assert!(!is_complete_json(b""));
    }

    #[test]
    fn chatml_fallback_has_both_roles_and_leaves_the_assistant_turn_open() {
        let p = chatml_prompt("be brief", "hi");
        assert!(p.starts_with("<|im_start|>system\nbe brief<|im_end|>"));
        assert!(p.ends_with("<|im_start|>assistant\n"));
    }
}
