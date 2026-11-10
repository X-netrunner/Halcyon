# The optional LLM layer ("Smart suggestions")

Status: **All three features are implemented:** 1 Why this mix, 2 Describe a mood, 3 Rerank. Nothing in
this layer has been run against a real model or a real Spotify session yet (see the changelog).

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

## Feature 2: Describe a mood (prompt to playlist)

The listener types a mood on Home ("rainy night coding, no lyrics"). The model never supplies a song.

```
 PromptPlaylist { text }                      (explicit user action; layer must be On)
     |
     v   llm::playlist::spawn_prompt_playlist   (returns at once; one request at a time)
 clean + check the text  --too short--> PromptPlaylistFailed
     |
 cache hit for (words, taste fingerprint, prompt versions, model)? --yes--> Result (no call, no search)
     |
     v   Progress "understanding"
 search plan: cached 7 days, else ONE model call -> validate::parse_query
     |        (seed artists, genres, energy 0-1, instrumental yes/no/unknown, era)
     |        unusable -> Failed "try naming an artist or a genre"
     v   Progress "searching"
 DETERMINISTIC: <= 8 catalogue searches (artists first, then genre tags, 250 ms apart, 20 s total)
     |   artist searches keep only songs by that artist; round-robin merge; <= 3 songs per artist; <= 50 candidates
     |   nobody answered -> Failed "check you're signed in"; < 8 songs -> Failed "try naming ..."
     v   Progress "choosing"   (skipped when there are 12 candidates or fewer: nothing to trim)
 ONE model call: candidates shown as t1..t50 (never real ids) -> validate::parse_pick
     |   -> filter_ids(valid only, <= 25); fewer than 10 valid -> the engine's own order
     |   model failed or junk -> the engine's own order (silent)
     v
 look every id up in the candidate list  --> MusicMix (id prompt-<hash>) --> PromptPlaylistResult
     |
     +--> cached 3 days, but only when the pick was valid (a degraded mix is not remembered)
```

The model's two jobs are the plan and the pick. Every track in the mix is looked up in the list the
catalogue returned, so an invented id cannot become a song.

### Choices worth knowing about

- **Per-mix reason, not per-song reasons.** The pick returns one title and one sentence for the mix.
  Per-song reasons cost many tokens on a small local model and the UI has nowhere to show them.
- **Instrumental, energy and era are advisory.** Search results carry no such metadata, so they are
  passed to the model that picks (and "instrumental" is added to genre searches); the app cannot
  verify them. A mix for "no lyrics" can still contain a song with vocals.
- **Three songs per artist, not two.** Engine mixes use two; a listener who names an artist wants more.
- **A degraded mix is shown, not hidden.** If only the final pick fails, the listener still gets a
  mix in the engine's order. If the plan or the search fails, they get a plain-language reason.
- **User-initiated, so it ignores the failure rest** that background features obey, and never sets it.
- **Timeouts.** 20 s per model call with one retry (as everywhere), plus a 75 s ceiling for the request.

### Privacy for feature 2

| Sent to the model | Never sent |
|---|---|
| The listener's own words (cleaned, at most 200 characters) | The raw play log, timestamps, per-track history |
| The same taste summary as feature 1 | Spotify ids and URIs (the model sees `t1`, `t2` ...) |
| Plan 2: the plan it wrote itself, and up to 50 candidates as `Artist - Title` | Account name, tokens, file paths |

Catalogue searches go to Spotify with artist names and genre words, like any search the listener types.
The listener's words are not written to the log (debug lines carry only error text).

### Failure modes for feature 2

| What goes wrong | What the listener sees | What happens |
|---|---|---|
| Layer off | "Smart suggestions are off. Turn them on in Settings" (the box is disabled and says so) | No call |
| Under 3 letters or digits | The box does not send; the daemon refuses too | No call |
| Backend down / model missing / too slow | The `LlmError` text with its fix | One retry (none for a missing model) |
| Plan is junk or names nothing | "Try naming an artist or a genre" | No search is made |
| Spotify cannot be asked | "Check that you're signed in and online" | Stops after two unanswered searches |
| Under 8 songs found | "Couldn't find enough songs, try naming an artist or a genre" | The model is not asked to choose |
| Pick is junk, invents ids, or has under 10 valid | A mix in the engine's order | Not cached; the plan stays cached |
| Model words contain markup or links | Those characters are stripped | `clean_output`, caps (title 32, reason 90) |
| Track or request text tries to instruct the model | No effect on validity | Escaped into one JSON string; output checked the same way |
| A second request while one runs | "Another mood is still being made" | Not queued |
| The background job panics | "Something went wrong ... try again" | Caught; a failure event is still sent |
| The layer is turned off while waiting | The status line returns to the hint | The GUI forgets the pending request |

### Protocol additions (feature 2)

`prompt_playlist { text }`, `prompt_playlist_progress { request, step }`,
`prompt_playlist_result { request, mix }`, `prompt_playlist_failed { request, reason }`. All additive;
`PROTOCOL_VERSION` is unchanged and an older peer decodes them as `Unknown`. For every request exactly
one `result` or `failed` is sent. `request` echoes the text so the GUI can ignore answers to older requests.

### GUI

A "Describe a mood" block under the greeting on Home: a text box, a "Make a mix" button, and one status
line of fixed height (hint, a step line while working, or the failure reason), so nothing moves.
The result appears below as one card (title, reason, count and first artists, Clear, Save, Play); the
title opens the usual mix page. With the layer off the box is disabled and an "Open Settings" button
sits in the status line. No timers, no animation.

## Feature 3: Rerank (a better order for the engine's own mixes)

The engine builds every mix and every song in it. For a *personal* mix (`source == "Halcyon Local"`)
with 16 or more songs, the model may put those same songs in a better order for this listener and drop
the weakest, down to 15-25. Charts and other outside lists are never touched: trimming a "Top 200" to
25 would change what it is.

```
 Home mixes (engine)  --> GUI shows them at once
        |
        +--> spawn_enrichment (same background task as feature 1; one model job at a time)
               words (feature 1) ok? --> rerank_mixes
                 for each personal mix with >= 16 songs (at most 6 looked at):
                   cache key (feature "rerank", hash(mix id + song ids + taste fingerprint + prompt version), model)
                     hit  -> MixReranked   (no call; an empty cached answer = "keep the engine's order")
                     miss -> queued; at most 3 model calls per run, one per mix, 20 s + one retry
                   ONE call per mix: the first 50 songs as t1..t50 (never real ids) + taste + cleaned title
                     -> validate::parse_pick -> filter_ids against that mix's own songs (<= 25)
                     fewer than 10 valid -> the engine's order is kept (remembered for a day)
                     a failed call -> the feature rests 10 minutes and the run stops
                   valid -> cached 30 days -> MixReranked { mix_id, track_ids }
 GUI: keeps the songs it already holds, in the daemon's order; ids it does not have are ignored;
      fewer than 10 matches -> engine order. Re-applied when the Home feed is rebuilt.
```

Choices worth knowing about: the event carries **ids only**, so a rerank cannot add a song even in
principle; the answer is `{"picks":[...]}` with no per-song reasons (there is nowhere to show them, and
feature 1 already writes the mix's reason); a model that returns junk for every mix puts the feature to
rest, a single junk answer only leaves that mix alone; "Test connection" clears the rest for both
features.

Privacy for feature 3: the model sees the mix's title (cleaned), the same taste summary as the other
features and up to 50 `Artist - Title` lines. Never sent: the play log, timestamps, mix or track ids.

| What goes wrong | What the listener sees | What happens |
|---|---|---|
| Layer off / thin listening history | Nothing changes | No call |
| Mix is a chart or has under 16 songs | Nothing changes | Not eligible |
| Backend down or too slow | Nothing changes | One retry, then 10 minutes of rest |
| Answer is junk, invents ids, or has under 10 valid | The engine's order | Remembered for a day; one junk mix does not stop the others |
| Injection in a title or mix name | No effect | Escaped into one JSON string; the output is checked the same way |
| Home is rebuilt with different songs | Fresh engine order until a new answer | The key changes with the mix's songs |

## Part 7: the built-in model (no Ollama needed)

The backend is now a real setting: `local` (default for new installs) or `ollama` (kept for
anyone who already chose it; stored settings that say `ollama` stay `ollama`). Each backend keeps its
own model choice, and answers are cached per model, so switching back loses nothing.

- **Engine**: `LocalGgufBackend` (`llm/local.rs`) runs a small GGUF model in the daemon with
  llama.cpp via the `llama-cpp-2` crate, behind the cargo feature `local-llm`. Without the feature,
  Smart suggestions says plainly that the build has no engine and offers Ollama. Building it needs
  cmake, a C++ compiler **and libclang** (bindgen).
- **Grammar** (`llm/grammar.rs`): each prompt's answer shape becomes a GBNF grammar, so the model
  cannot return broken JSON, extra keys or an id it was not shown. For "Describe a mood" it also fixes
  the genre words to a vocabulary and forces `seed_artists` to `[]`: artists come from the
  recommendation sources (Part 5), not from the model's memory. The validators still check everything.
- **Model files** (`llm/models.rs`): one model is downloaded when Smart suggestions is turned on
  (the card shows the size first), into `~/.local/share/halcyon-music/models/`. Resumable, cancellable,
  deletable, checked against a SHA-256 (pinned in the catalogue if set, else the server's). It is the only network use.
- **Resources**: loaded on first use, unloaded after 2 minutes idle, 1 to 4 threads (half the cores), run
  on a separate thread at low priority, one job at a time, context 4096 tokens, 90 s call limit.
- **Privacy**: unchanged. Off by default; prompts never leave the machine and are never logged.
- Protocol (additive): `set_llm_settings.endpoint` (Ollama address, default 127.0.0.1:11434),
  commands `list_llm_models`, `download_llm_model`, `cancel_llm_download`, `delete_llm_model`; events
  `llm_models`, `llm_download`.
- Comparing models: `docs/model-choice.md`.

### Part 9: install, doctor and soak

- **Install**: `install.sh` never downloads a model. With `HALCYON_MUSIC_LOCAL_MODEL=1` it only builds
  the engine (`--features local-llm`), and only when cmake, a C++ compiler and libclang are found;
  otherwise it says so and builds the plain player. The model downloads the first time Smart
  suggestions is turned on.
- **Doctor**: `halcyon-musicd --doctor` has a `model` line. It is INFO when Smart suggestions are off
  or use Ollama, PASS when the chosen built-in model is on disk (size and how it was checked), WARN
  when it is missing, half downloaded, or the build has no engine. It reads the saved settings
  read-only and never loads the model or touches the network.
- **Soak**: `SOAK_MODEL=1 scripts/soak_test.sh 30` keeps asking for mixes and suggestions, then waits
  for the model to unload and checks the daemon is back under 150 MB (the budget excludes the loaded model).
- **Not measured yet**: memory, speed and word quality of a real model (see `docs/model-choice.md`).

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
New events: `llm_status { enabled, backend, model, reachable, hint? }`, `mix_enriched { mix_id, title, reason }`; feature 3 adds `mix_reranked { mix_id, track_ids }`.
`PROTOCOL_VERSION` is unchanged; an older peer decodes the new kinds as `Unknown`.

## Code map

| File | Role |
|---|---|
| `halcyon-musicd/src/llm/backend.rs` | `TasteLlm` trait, `OllamaBackend`, `LlmError` (plain-language messages with a fix) |
| `halcyon-musicd/src/llm/taste.rs` | `summarise` (pure, tested) and `TasteSummary::fingerprint` |
| `halcyon-musicd/src/llm/prompts.rs` | all prompt text, `PROMPT_VERSION`, few-shot examples |
| `halcyon-musicd/src/llm/validate.rs` | output cleaning, JSON parsing, `filter_ids` (used by features 2 and 3) |
| `halcyon-musicd/src/llm/mod.rs` | settings, cache keys, `enrich_mixes`, daemon glue |
| `halcyon-musicd/src/llm/rerank.rs` | feature 3: `rerank_mixes`, `MixOrder` |
| `halcyon-music/src/mix_order.rs` | applies a reorder to songs the GUI already holds |
| `halcyon-musicd/src/llm/playlist.rs` | feature 2: `Catalogue` trait, candidate gathering, `build_prompt_playlist`, daemon glue |
| `halcyon-musicd/src/llm/mock.rs` | `ScriptedLlm` and `MockCatalogue` for tests |
| `halcyon-music/src/views/llm_settings.rs` | the Settings card |
| `halcyon-music/src/views/prompt_card.rs` | the "Describe a mood" block on Home |

## Trying it by hand

1. `ollama pull qwen2.5:3b` and make sure `ollama serve` is running.
2. Start the daemon and the app. Settings -> Smart suggestions -> On. The card says "Checking..." then
   "Connected. The model is ready." (or tells you what to fix).
3. Open Home. The mixes show at once; within a few seconds (first time only) their titles and one-line
   reasons change in place. Hover a mix title to read the whole reason.
4. Restart the app: the words are back immediately, with no model call (check `ollama ps`).
5. Turn it Off: nothing is sent; at the next refresh the original titles return.

## Trying feature 2 by hand

1. Smart suggestions On and Ollama running (see above); signed in to Spotify.
2. Home -> "Describe a mood": type `rainy night coding, no lyrics`, press Enter. The status line reads
   "Understanding your request...", "Finding songs...", "Choosing the best ones...", then a card appears.
3. Play it; Save it (it becomes a Spotify playlist); click the title to open it as a mix page.
4. Type the same words again: the card appears at once with no model call (`ollama ps` stays idle).
5. Stop Ollama and try a new mood: the status line shows the fix ("Start it with `ollama serve`").
6. Type `ab`: the button stays disabled. Turn the layer Off: the box disables and points to Settings.

## Trying feature 3 by hand

1. Smart suggestions On, Ollama running, and enough listening history (a few dozen plays).
2. Open Home. After the mix titles change (feature 1), the personal mixes with 16+ songs reorder and
   shrink to 15-25 songs; a chart mix keeps all of its songs.
3. Restart the app: the order is back at once with no model call (`ollama ps` stays idle).
4. Turn the layer Off: the engine's order returns at the next refresh.
