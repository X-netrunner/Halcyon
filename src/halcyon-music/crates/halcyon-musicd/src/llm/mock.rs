//! A scripted stand-in for a model, for tests. Public (not `cfg(test)`) so the integration
//! tests in `tests/` can use it too. Nothing in the daemon constructs it.

use super::backend::{BoxFuture, LlmError, LlmRequest, TasteLlm};
use super::playlist::Catalogue;
use halcyon_music_core::models::Track;
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// What the mock does on one call.
#[derive(Debug, Clone)]
pub enum Step {
    /// Answer with this text.
    Reply(String),
    /// Fail with this error.
    Fail(LlmError),
    /// Never answer (to exercise the timeout).
    Hang,
}

pub struct ScriptedLlm {
    model: String,
    script: Mutex<VecDeque<Step>>,
    probe_result: Mutex<Result<(), LlmError>>,
    calls: Arc<AtomicUsize>,
    last_request: Mutex<Option<LlmRequest>>,
}

impl ScriptedLlm {
    pub fn new(steps: Vec<Step>) -> Self {
        Self {
            model: "mock-model".to_string(),
            script: Mutex::new(steps.into()),
            probe_result: Mutex::new(Ok(())),
            calls: Arc::new(AtomicUsize::new(0)),
            last_request: Mutex::new(None),
        }
    }

    /// A mock whose backend is down: every call and every probe fails as "unreachable".
    pub fn down() -> Self {
        let err = LlmError::Unreachable("http://127.0.0.1:11434".to_string());
        let mock = Self::new(vec![
            Step::Fail(err.clone()),
            Step::Fail(err.clone()),
            Step::Fail(err.clone()),
        ]);
        if let Ok(mut p) = mock.probe_result.lock() {
            *p = Err(err);
        }
        mock
    }

    /// The same mock under another model name (answers are cached per model).
    pub fn with_model(mut self, name: &str) -> Self {
        self.model = name.to_string();
        self
    }

    pub fn calls(&self) -> usize {
        self.calls.load(Ordering::SeqCst)
    }

    /// The most recent request the layer sent, for asserting what the model was shown.
    pub fn last_request(&self) -> Option<LlmRequest> {
        self.last_request.lock().ok().and_then(|g| g.clone())
    }
}

impl TasteLlm for ScriptedLlm {
    fn backend_name(&self) -> &str {
        "mock"
    }

    fn model(&self) -> &str {
        &self.model
    }

    fn complete<'a>(&'a self, req: &'a LlmRequest) -> BoxFuture<'a, Result<String, LlmError>> {
        Box::pin(async move {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if let Ok(mut last) = self.last_request.lock() {
                *last = Some(req.clone());
            }
            let step = self.script.lock().ok().and_then(|mut s| s.pop_front());
            match step {
                Some(Step::Reply(text)) => Ok(text),
                Some(Step::Fail(e)) => Err(e),
                Some(Step::Hang) => {
                    std::future::pending::<()>().await;
                    Err(LlmError::Timeout)
                }
                None => Err(LlmError::BadResponse(
                    "the test script ran out of steps".to_string(),
                )),
            }
        })
    }

    fn probe<'a>(&'a self) -> BoxFuture<'a, Result<(), LlmError>> {
        Box::pin(async move {
            self.probe_result
                .lock()
                .map(|p| p.clone())
                .unwrap_or(Ok(()))
        })
    }
}

/// A scripted stand-in for the song catalogue, for tests. It answers a text query with the songs
/// it was given for that query (matched case-insensitively), an empty list for any other query,
/// or, when built with [`MockCatalogue::down`], nothing at all (as if offline or signed out).
#[derive(Default)]
pub struct MockCatalogue {
    answers: HashMap<String, Vec<Track>>,
    down: bool,
    queries: Mutex<Vec<String>>,
}

impl MockCatalogue {
    pub fn new() -> Self {
        Self::default()
    }

    /// A catalogue that cannot be reached.
    pub fn down() -> Self {
        Self {
            down: true,
            ..Self::default()
        }
    }

    /// Answer `query` with `tracks`.
    pub fn with(mut self, query: &str, tracks: Vec<Track>) -> Self {
        self.answers.insert(query.to_lowercase(), tracks);
        self
    }

    /// Every query the layer sent, in order.
    pub fn queries(&self) -> Vec<String> {
        self.queries.lock().map(|q| q.clone()).unwrap_or_default()
    }
}

impl Catalogue for MockCatalogue {
    fn search_songs<'a>(&'a self, query: &'a str) -> BoxFuture<'a, Option<Vec<Track>>> {
        Box::pin(async move {
            if let Ok(mut q) = self.queries.lock() {
                q.push(query.to_string());
            }
            if self.down {
                return None;
            }
            Some(
                self.answers
                    .get(&query.to_lowercase())
                    .cloned()
                    .unwrap_or_default(),
            )
        })
    }
}
