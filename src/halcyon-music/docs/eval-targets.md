# Eval targets (Part 5)

What a list from the recommendation pipeline should look like, measured with `halcyon-musicd --eval`.
The fixtures have no outside candidates and no tags, so some targets can only be checked on your own
history (marked *real*).

| metric | target | why |
|---|---|---|
| NDCG@10, ranker vs Part 4 | not lower by more than 0.03 on any fixture; higher on average | the ranker should not lose what Part 4 already did |
| skip AUC, "recent taste shift" | at least +0.03 over Part 4 | the case Part 4's fast scale and the online model are for |
| diversity (1 - same-artist pairs), pipeline | at least +0.10 over the ranker alone | the reranker's whole job |
| coverage, pipeline | not below Part 4 | lists should not collapse onto a few artists |
| NDCG@10, pipeline vs Part 4 | not lower by more than 0.05 | variety may cost a little relevance, not a lot |
| skip AUC, pipeline vs ranker | not lower by more than 0.06 | reranking only touches the top of the list |
| novelty (*real*) | 0.15 to 0.30 for a Home shelf | about 20% unheard artists is the exploration share |
| repeat rate (*real*) | below 0.5 for shelves; On Repeat is exempt | nothing played in the last 6 hours comes back |
| first Home paint | under 200 ms from cache | `ShelfResult` is cached by the caller (Part 6) |
| full rebuild | under 10 s with warm caches | first build is slower: every uncached song match waits 0.6 s |

`tests/reco_eval.rs` enforces the rows that can be checked on the fixtures.
