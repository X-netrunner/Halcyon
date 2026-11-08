# Changelog

## Unreleased: LLM layer, feature 1 of 3 ("Why this mix")

Added
- Optional Smart suggestions (off by default, local Ollama by default): a better title and a one-sentence
  reason for each Home mix. The engine still builds every mix and every track; the model only writes words.
- `TasteLlm` trait with an Ollama backend; a scripted mock for tests.
- Taste summary (pure function, under 1.5 KB): top artists and genres, per-artist skip rate, completion rate,
  "currently into", "stale favourites", typical hours.
- Answers cached in SQLite per (feature, mix + taste + prompt version, model); a warm cache makes no call.
- Protocol (additive): `get_llm_status`, `set_llm_settings`, `test_llm_connection`, `llm_status`, `mix_enriched`.
- Settings card: toggle, model name, Test connection with a plain-language fix.
- `docs/llm-layer.md`: data flow, privacy table, failure modes.

Tested (written, **not run**: see below)
- Unit: taste summary (ordering, skip rate, currently-into, stale favourites, hours, byte budget,
  determinism, fingerprint, thin logs); JSON validation (fences, junk, nulls, wrong shapes, unknown and repeated
  ids, markup and links stripped, caps); `filter_ids` (invented ids, fallback, empty, cap); prompt building
  (ids never sent, valid JSON, injection stays inside one string, example outputs pass the validator).
- Integration with a scripted model: happy path, warm cache, reshuffle/changed mix/other model/changed taste,
  timeout + single retry + rest, retry rescue, malformed JSON (5 shapes), hallucinated ids, empty candidates,
  thin listening, backend down (message carries a fix), missing model not retried, busy = cache only,
  prompt-injection fixture, aggregates-only check.
- Protocol: round trips, `llm_status` without `hint`, unknown kinds still decode.

NOT tested
- **Nothing in this change has been compiled or run.** It was written without a Rust toolchain; run
  `cargo check --workspace --tests` and `cargo test --workspace` first and expect to fix small compile errors.
- `OllamaBackend` against a real Ollama (request shape, `format: "json"`, `/api/tags` matching).
- All GUI paths: the Settings card, status line, the live swap of titles on Home, the hover tooltip.
- Clippy (`-D warnings`) and "zero new warnings".

Not built yet
- Feature 2 (prompt to playlist) and feature 3 (rerank).
