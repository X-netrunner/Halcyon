# Choosing the built-in model

Status: **no measurements yet.** Nothing in this file was measured. The build environment that wrote
Part 7 could not reach the download host and has one CPU core, so it could not run these models. The
default below is a provisional pick for size and licence, not a result.

## Candidates

| id | file | about | licence | notes |
| --- | --- | --- | --- | --- |
| `qwen2.5-0.5b-instruct` (provisional default) | Q4_K_M | 0.5 GB | Apache-2.0 | smallest, ChatML template |
| `qwen3-0.6b` | Q8_0 | 0.6 GB | Apache-2.0 | only Q8_0 is published officially; Halcyon closes its "thinking" block itself |
| `llama3.2-1b-instruct` | Q4_K_M | 0.8 GB | Llama 3.2 Community License | custom licence: attribution and use terms |
| `gemma3-1b-instruct` | Q4_K_M | 0.8 GB | Gemma Terms of Use | custom licence; check the mirror is not gated |

Sizes and URLs are from memory and NOT verified. Run `halcyon-musicd --model-check` first: it asks
the server for each file's real size and SHA-256. Paste the hashes into `CATALOGUE` in
`src/llm/models.rs` (`sha256: Some("...")`) to pin them; until then the download is checked against the
checksum the server publishes (marked "checksum verified" in Settings) and not against one in this repo.

## How to measure (on the machine it will run on)

```
cargo build --release -p halcyon-musicd --features local-llm
halcyon-musicd --model-fetch qwen2.5-0.5b-instruct     # repeat for each candidate
halcyon-musicd --model-bench all 5 > bench.md
```

`--model-bench` runs the real prompts (mix titles, mood plan, song pick, rerank) through the real
validators, `RUNS` times each, and prints per case: answers that were usable, errors, average and
worst latency, process memory, and sample outputs. The grammar makes the JSON itself always valid, so
"valid" here means *usable*: all mixes covered, at least one genre, at least one pick.

Judge three things and write them below:

1. **Usable answers**: should be all of them. Fewer means the model ignores the prompt even inside the grammar.
2. **Words**: read the samples. Titles 2 to 4 words that fit; reasons that do not repeat the title or invent facts.
3. **Cost**: first-call latency (includes loading the file), warm latency, peak RSS, and whether playback
   stays clean while it runs (listen; also `halcyon-musicd --eval` timings).

## Results

NOT RUN. Fill this table from `bench.md`:

| model | usable | first call | warm call | peak RSS | words (1 to 5) | licence ok |
| --- | --- | --- | --- | --- | --- | --- |
| qwen2.5-0.5b-instruct | | | | | | |
| qwen3-0.6b | | | | | | |
| llama3.2-1b-instruct | | | | | | |
| gemma3-1b-instruct | | | | | | |

Decision: keep the provisional default until the table is filled in.
