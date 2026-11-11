//! The seam between Halcyon and a language model.
//!
//! Everything the LLM layer needs from a model is the [`TasteLlm`] trait: send a system prompt
//! and a user message, get text back, and say whether you are reachable. Ollama on this
//! machine is the default backend; a remote provider can be added later without touching the
//! rest of the layer. No async-trait crate: the methods return boxed futures by hand.

use serde::{Deserialize, Serialize};
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;
use thiserror::Error;

pub type BoxFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The shape of the JSON a request expects back. The embedded model turns it into a grammar so a
/// tiny model cannot return broken JSON; Ollama only gets `format: "json"` and ignores the rest.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Shape {
    /// Any JSON object.
    #[default]
    AnyJson,
    /// `{"mixes":[{"id":"m1","title":"..","reason":".."}, ...]}` with exactly `mixes` entries.
    WhyMix { mixes: usize },
    /// The search plan for "Describe a mood".
    Query,
    /// `{"title":"..","reason":"..","picks":["t3","t1"]}` over `candidates` numbered songs.
    Pick { candidates: usize },
    /// `{"picks":["t3","t1"]}` over `candidates` numbered songs.
    Rerank { candidates: usize },
}

/// One request to the model.
#[derive(Debug, Clone)]
pub struct LlmRequest {
    pub system: String,
    pub user: String,
    pub temperature: f32,
    pub max_tokens: u32,
    /// What the answer must look like (see [`Shape`]).
    pub shape: Shape,
}

/// Why a model call failed. Every message is plain language with a fix.
#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum LlmError {
    #[error("The language model isn't answering at {0}. Start it (for Ollama: `ollama serve`) or turn Smart suggestions off.")]
    Unreachable(String),
    #[error("The model \"{0}\" isn't installed. Install it with `ollama pull {0}`, or pick another model in Settings.")]
    ModelMissing(String),
    #[error(
        "The model took too long to answer. Try a smaller model, or wait until Ollama is idle."
    )]
    Timeout,
    #[error("The model sent an answer Halcyon couldn't use ({0}). Try another model in Settings.")]
    BadResponse(String),
    /// The built-in model is not on disk (not downloaded yet, or deleted).
    #[error("The built-in model \"{0}\" isn't downloaded yet. Open Settings, then Smart suggestions, and tap Download.")]
    LocalModelMissing(String),
    /// This build has no embedded model engine.
    #[error("This build of Halcyon Music has no built-in model engine. Rebuild it with `--features local-llm`, or switch Smart suggestions to Ollama in Settings.")]
    EngineMissing,
    /// The model file is there but cannot be loaded or used.
    #[error("The built-in model could not be loaded ({0}). Delete it in Settings and download it again, or pick another model.")]
    LocalModelBroken(String),
}

impl LlmError {
    /// Asking again cannot fix this, so the caller does not retry.
    pub fn is_permanent(&self) -> bool {
        matches!(
            self,
            Self::ModelMissing(_)
                | Self::LocalModelMissing(_)
                | Self::EngineMissing
                | Self::LocalModelBroken(_)
        )
    }
}

pub trait TasteLlm: Send + Sync {
    /// Short backend name shown in Settings (`local` or `ollama`).
    fn backend_name(&self) -> &str;
    /// The model this backend asks.
    fn model(&self) -> &str;
    /// Ask the model. The caller owns the timeout and the retry.
    fn complete<'a>(&'a self, req: &'a LlmRequest) -> BoxFuture<'a, Result<String, LlmError>>;
    /// `Ok(())` when the backend answers and has the model; otherwise the reason, with a fix.
    fn probe<'a>(&'a self) -> BoxFuture<'a, Result<(), LlmError>>;
    /// How long one call may take before it counts as failed. A model running inside this
    /// process on the CPU needs longer than a model server that is already warm.
    fn call_timeout(&self) -> Duration {
        Duration::from_secs(20)
    }
}

/// Local Ollama over HTTP.
pub struct OllamaBackend {
    http: reqwest::Client,
    endpoint: String,
    model: String,
}

#[derive(Serialize)]
struct ChatMessage<'a> {
    role: &'static str,
    content: &'a str,
}

#[derive(Serialize)]
struct ChatOptions {
    temperature: f32,
    num_predict: u32,
}

#[derive(Serialize)]
struct ChatBody<'a> {
    model: &'a str,
    messages: Vec<ChatMessage<'a>>,
    stream: bool,
    format: &'static str,
    options: ChatOptions,
}

#[derive(Deserialize)]
struct ChatReply {
    #[serde(default)]
    message: Option<ReplyMessage>,
}

#[derive(Deserialize)]
struct ReplyMessage {
    #[serde(default)]
    content: String,
}

#[derive(Deserialize)]
struct TagsReply {
    #[serde(default)]
    models: Vec<TagModel>,
}

#[derive(Deserialize)]
struct TagModel {
    #[serde(default)]
    name: String,
}

/// Does an installed model name match the one the user asked for? `qwen2.5:3b` matches itself;
/// a bare `llama3` matches `llama3:latest` and any other tag of it.
pub fn model_installed(installed: &[String], wanted: &str) -> bool {
    let wanted = wanted.trim();
    installed.iter().any(|name| {
        name == wanted
            || *name == format!("{wanted}:latest")
            || (!wanted.contains(':') && name.starts_with(&format!("{wanted}:")))
    })
}

impl OllamaBackend {
    pub fn new(http: reqwest::Client, endpoint: &str, model: &str) -> Self {
        Self {
            http,
            endpoint: endpoint.trim_end_matches('/').to_string(),
            model: model.to_string(),
        }
    }

    fn map_send_error(&self, e: reqwest::Error) -> LlmError {
        if e.is_timeout() {
            LlmError::Timeout
        } else if e.is_connect() {
            LlmError::Unreachable(self.endpoint.clone())
        } else {
            LlmError::BadResponse(e.without_url().to_string())
        }
    }
}

impl TasteLlm for OllamaBackend {
    fn backend_name(&self) -> &str {
        "ollama"
    }

    fn model(&self) -> &str {
        &self.model
    }

    fn complete<'a>(&'a self, req: &'a LlmRequest) -> BoxFuture<'a, Result<String, LlmError>> {
        Box::pin(async move {
            let body = ChatBody {
                model: &self.model,
                messages: vec![
                    ChatMessage {
                        role: "system",
                        content: &req.system,
                    },
                    ChatMessage {
                        role: "user",
                        content: &req.user,
                    },
                ],
                stream: false,
                format: "json",
                options: ChatOptions {
                    temperature: req.temperature,
                    num_predict: req.max_tokens,
                },
            };
            let resp = self
                .http
                .post(format!("{}/api/chat", self.endpoint))
                .timeout(Duration::from_secs(60))
                .json(&body)
                .send()
                .await
                .map_err(|e| self.map_send_error(e))?;
            let status = resp.status();
            if status == reqwest::StatusCode::NOT_FOUND {
                return Err(LlmError::ModelMissing(self.model.clone()));
            }
            if !status.is_success() {
                return Err(LlmError::BadResponse(format!("HTTP {}", status.as_u16())));
            }
            let reply: ChatReply = resp.json().await.map_err(|e| self.map_send_error(e))?;
            let content = reply.message.map(|m| m.content).unwrap_or_default();
            if content.trim().is_empty() {
                return Err(LlmError::BadResponse("empty answer".to_string()));
            }
            Ok(content)
        })
    }

    fn probe<'a>(&'a self) -> BoxFuture<'a, Result<(), LlmError>> {
        Box::pin(async move {
            let resp = self
                .http
                .get(format!("{}/api/tags", self.endpoint))
                .timeout(Duration::from_secs(3))
                .send()
                .await
                .map_err(|e| self.map_send_error(e))?;
            if !resp.status().is_success() {
                return Err(LlmError::BadResponse(format!(
                    "HTTP {}",
                    resp.status().as_u16()
                )));
            }
            let tags: TagsReply = resp.json().await.map_err(|e| self.map_send_error(e))?;
            let names: Vec<String> = tags.models.into_iter().map(|m| m.name).collect();
            if model_installed(&names, &self.model) {
                Ok(())
            } else {
                Err(LlmError::ModelMissing(self.model.clone()))
            }
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn model_matching_handles_tags_and_latest() {
        let installed = names(&["qwen2.5:3b", "llama3:latest", "mistral:7b-instruct"]);
        assert!(model_installed(&installed, "qwen2.5:3b"));
        assert!(model_installed(&installed, "llama3"));
        assert!(model_installed(&installed, "mistral"));
        assert!(!model_installed(&installed, "qwen2.5:7b"));
        assert!(!model_installed(&[], "llama3"));
    }

    #[test]
    fn errors_are_plain_language_with_a_fix() {
        let down = LlmError::Unreachable("http://127.0.0.1:11434".into()).to_string();
        assert!(down.contains("ollama serve"));
        let missing = LlmError::ModelMissing("qwen2.5:3b".into()).to_string();
        assert!(missing.contains("ollama pull qwen2.5:3b"));
        assert!(LlmError::Timeout.to_string().contains("smaller model"));
    }
}
