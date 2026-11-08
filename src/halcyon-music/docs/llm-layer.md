# The optional LLM layer ("Smart suggestions")

Status: **Feature 1 of 3 (Why this mix) is implemented.** Prompt-to-playlist and Rerank are designed
here and not built yet; they reuse everything below.

## What it is, and what it is not

The deterministic engine (`suggestions.rs`) still builds every mix and every candidate list. The LLM
layer only *reads* what the engine produced and writes words about it. It never invents a song, never
adds or removes a track, and is off by default.

Feature 1, **Why this mix**: for each Home mix, a better title and one short reason, cached per mix.
Home renders the engine's mixes at once; the words arrive later as `MixEnriched` and are swapped in
without moving anything.

## Data flow

```
 GetHomeFeed
     |
     v
 build_home_feed (deterministic) ---> HomeFeedResult ---> GUI shows mixes right away
     |
     +--> llm::spawn_enrichment(mixes)            (returns at once; settings off -> stops here)
              |
              v   background task, panics caught (supervisor::run_guarded)
        taste_from_cache -> TasteSummary (<1.5 KB, aggregates only)
              |
              v
        for each mix: key = (feature, hash(mix songs + taste fingerprint + PROMPT_VERSION), model)
              |
        cache hit  ---------------------------> MixEnriched   (no model call)
        cache miss -> ONE call for all missed mixes
                        timeout 20 s, one retry, then a 10-minute rest after a failure
                        |
                        v
                   TasteLlm::complete  (default: Ollama on 127.0.0.1:11434)
                        |
                        v
                   validate::parse_why_mix  (serde, caps, markup stripped, unknown ids dropped)
                        |
                        +--> store in SQLite kv --> MixEnriched --> GUI swaps title + reason in
```

## Privacy: what is sent and what is not

| Sent to the model | Never sent |
|---|---|
| Taste summary: top artists and genres with relative weights, per-artist skip rate, completion rate, up to 3 "currently into" and 3 "stale favourite" artist names, the 3 busiest listening hours | The raw play log, play timestamps, per-track history |
| For each mix: its title and up to 8 "Artist - Title" lines | Spotify ids, track URIs, mix ids (the model sees `m1`, `m2`...) |
| | Account name, tokens, file paths, playlists the user made |

- Default backend is Ollama on this computer, so with the defaults nothing leaves the machine.
- The setting is **off by default**. Turning it off stops all calls and clears the words at the next refresh.
- Prompts and answers are not logged at info level; the log gets one line per failure (an error message
  with a fix, never the prompt).
- Track titles, artist names and mix names are cleaned (one line, no control characters, capped),
  JSON-escaped, and the system prompt says they are data and not instructions.

## Failure modes

| What goes wrong | What the user sees | What happens |
|---|---|---|
| Layer off | Nothing | No call, no network |
| Ollama not running | Mixes keep their own titles. Settings says how to start it | One retry, then a 10-minute rest; "Test connection" clears it |
| Model not installed | Settings says `ollama pull <model>` | Not retried (asking again cannot install it) |
| Model too slow (>20 s) | Mixes keep their own titles | Timeout, one retry, then rest |
| Model returns prose or broken JSON | Mixes keep their own titles | Nothing is shown or cached; rest |
| Model invents ids or mixes | Those entries are dropped, the valid ones are used | Per-entry filtering |
| Model words contain markup, links, `{}` | Those characters are stripped; unusable text is dropped | `clean_output`, length caps (title 32, reason 90) |
| Metadata tries to instruct the model | No effect on validity | Data is escaped; output is checked the same way regardless |
| Cache is warm | Words appear with the page | No model call at all |
| Two Home loads at once | Second one shows cached words only | One model call at a time |
| A panic in the background task | Nothing | Caught at the join handle, logged, skipped |

## Cache

SQLite `kv` table, key `llm.v1.<feature>.<model>.<input hash>`, 30-day lifetime. The input hash covers
the mix (its id and its songs, in any order), the taste fingerprint and `PROMPT_VERSION`. The
fingerprint is built from *who* the listener is into (top 5 artists, current obsessions, stale
favourites), not from counts, so it changes when the taste moves and not when a number ticks up.

## Protocol (additive only)

New commands: `get_llm_status`, `set_llm_settings { enabled, backend, model }`, `test_llm_connection`.
New events: `llm_status { enabled, backend, model, reachable, hint? }`, `mix_enriched { mix_id, title, reason }`.
`PROTOCOL_VERSION` is unchanged; an older peer decodes the new kinds as `Unknown`.

## Code map

| File | Role |
|---|---|
| `halcyon-musicd/src/llm/backend.rs` | `TasteLlm` trait, `OllamaBackend`, `LlmError` (plain-language messages with a fix) |
| `halcyon-musicd/src/llm/taste.rs` | `summarise` (pure, tested) and `TasteSummary::fingerprint` |
| `halcyon-musicd/src/llm/prompts.rs` | all prompt text, `PROMPT_VERSION`, few-shot examples |
| `halcyon-musicd/src/llm/validate.rs` | output cleaning, JSON parsing, `filter_ids` (used by features 2 and 3) |
| `halcyon-musicd/src/llm/mod.rs` | settings, cache keys, `enrich_mixes`, daemon glue |
| `halcyon-musicd/src/llm/mock.rs` | `ScriptedLlm` for tests |
| `halcyon-music/src/views/llm_settings.rs` | the Settings card |

## Trying it by hand

1. `ollama pull qwen2.5:3b` and make sure `ollama serve` is running.
2. Start the daemon and the app. Settings -> Smart suggestions -> On. The card says "Checking..." then
   "Connected. The model is ready." (or tells you what to fix).
3. Open Home. The mixes show at once; within a few seconds (first time only) their titles and one-line
   reasons change in place. Hover a mix title to read the whole reason.
4. Restart the app: the words are back immediately, with no model call (check `ollama ps`).
5. Turn it Off: nothing is sent; at the next refresh the original titles return.
