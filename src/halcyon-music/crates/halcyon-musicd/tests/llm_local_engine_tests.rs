//! End-to-end check of the embedded engine: real llama.cpp, real grammars, real validators.
//!
//! Needs `--features local-llm` and a GGUF in `HALCYON_TEST_GGUF` (skipped otherwise). A random-weight
//! tiny model is enough: it cannot write good words, but whatever it writes must still obey the grammar,
//! which is exactly what this proves. See docs/llm-layer.md for how the tiny model is made.
#![cfg(feature = "local-llm")]

use halcyon_musicd::llm::backend::{LlmRequest, Shape};
use halcyon_musicd::llm::grammar::VOCABULARY;
use halcyon_musicd::llm::local::{engine::LlamaGenerator, Generator};
use halcyon_musicd::llm::validate;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

fn model() -> Option<PathBuf> {
    match std::env::var("HALCYON_TEST_GGUF") {
        Ok(p) if !p.is_empty() => Some(PathBuf::from(p)),
        _ => {
            eprintln!("HALCYON_TEST_GGUF not set: skipping");
            None
        }
    }
}

fn req(shape: Shape, user: &str, max_tokens: u32) -> LlmRequest {
    LlmRequest {
        system: "You write JSON.".into(),
        user: user.into(),
        temperature: 0.8,
        max_tokens,
        shape,
    }
}

#[test]
fn every_shape_comes_back_as_valid_json_of_that_shape() {
    let Some(path) = model() else { return };
    let gen = LlamaGenerator::new();
    let cancel = AtomicBool::new(false);

    for (i, user) in ["rainy night", "gym 90s", "sunday coffee"]
        .iter()
        .enumerate()
    {
        // why-mix with two mixes
        let out = gen
            .generate(
                &path,
                "tiny",
                &req(Shape::WhyMix { mixes: 2 }, user, 400),
                &cancel,
            )
            .expect("why-mix");
        let mut aliases = HashMap::new();
        aliases.insert(
            "m1".to_string(),
            ("real-1".to_string(), "Mix One".to_string()),
        );
        aliases.insert(
            "m2".to_string(),
            ("real-2".to_string(), "Mix Two".to_string()),
        );
        let blurbs = validate::parse_why_mix(&out, &aliases);
        assert_eq!(blurbs.len(), 2, "run {i}: {out}");

        // mood plan: fixed vocabulary, no invented artists
        let out = gen
            .generate(&path, "tiny", &req(Shape::Query, user, 300), &cancel)
            .expect("query");
        let spec = validate::parse_query(&out)
            .unwrap_or_else(|| panic!("run {i}: plan did not parse: {out}"));
        assert!(!spec.genres.is_empty());
        assert!(
            spec.genres.iter().all(|g| VOCABULARY.contains(&g.as_str())),
            "{out}"
        );
        assert!(spec.seed_artists.is_empty(), "{out}");

        // picks only from the ids that were shown
        let mut ids = HashMap::new();
        for n in 1..=6 {
            ids.insert(format!("t{n}"), format!("id{n}"));
        }
        let out = gen
            .generate(
                &path,
                "tiny",
                &req(Shape::Pick { candidates: 6 }, user, 450),
                &cancel,
            )
            .expect("pick");
        let pick = validate::parse_pick(&out, &ids)
            .unwrap_or_else(|| panic!("run {i}: pick did not parse: {out}"));
        assert!(
            !pick.ids.is_empty() && pick.ids.iter().all(|id| id.starts_with("id")),
            "{out}"
        );

        let out = gen
            .generate(
                &path,
                "tiny",
                &req(Shape::Rerank { candidates: 6 }, user, 300),
                &cancel,
            )
            .expect("rerank");
        assert!(
            serde_json::from_str::<serde_json::Value>(&out).is_ok(),
            "{out}"
        );
        assert!(out.starts_with("{\"picks\":["), "{out}");
    }
    assert!(gen.loaded().is_some());
}

#[test]
fn a_cancel_flag_stops_generation_and_idle_unload_frees_the_model() {
    let Some(path) = model() else { return };
    let gen = LlamaGenerator::new();
    let stop = AtomicBool::new(true);
    let r = gen.generate(&path, "tiny", &req(Shape::AnyJson, "x", 300), &stop);
    assert_eq!(r, Err(halcyon_musicd::llm::backend::LlmError::Timeout));
    // the model was loaded by that call; it stays until it has been idle long enough
    assert!(gen.loaded().is_some());
    assert!(!gen.unload_if_idle(Duration::from_secs(3600)));
    assert!(gen.unload_if_idle(Duration::ZERO));
    assert!(gen.loaded().is_none());
}

#[test]
fn a_file_that_is_not_a_model_is_a_plain_error_not_a_crash() {
    let dir = tempfile::tempdir().expect("dir");
    let bad = dir.path().join("bad.gguf");
    let mut bytes = b"GGUF".to_vec();
    bytes.resize(2_000_000, 7);
    std::fs::write(&bad, bytes).expect("write");
    let gen = LlamaGenerator::new();
    let r = gen.generate(
        &bad,
        "bad",
        &req(Shape::AnyJson, "x", 50),
        &AtomicBool::new(false),
    );
    assert!(
        matches!(
            r,
            Err(halcyon_musicd::llm::backend::LlmError::LocalModelBroken(_))
        ),
        "{r:?}"
    );
}
