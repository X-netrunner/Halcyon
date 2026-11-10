# Recommendation pipeline (Part 5)

```
retrieve  -> rank -> rerank -> match on Spotify
```

Code: `crates/halcyon-musicd/src/reco/`. Nothing here needs the Spotify Web API.

## Retrieve (`retrieve.rs`)

Every source runs alone and can fail without hurting the others (`SourceReport`).

| source | where from | when |
|---|---|---|
| history, liked | your play log and liked songs | personal phase |
| similar | Deezer related artists of your top 5 artists, 3 songs each | personal phase |
| new release | iTunes albums of your top artists, last 120 days | personal phase |
| tag neighbour | unheard artists whose cached tags are close to a taste cluster, songs from Deezer | personal phase |
| ListenBrainz | collaborative recommendations of YOUR ListenBrainz account | only if `listenbrainz.json` in the state dir says `{"enabled": true, "user": "..."}`; off by default |
| chart, editorial | Deezer / ListenBrainz charts, the built-in classics list | always |

Cold start: fewer than 50 plays means chart and editorial only.

Results are cached in the key-value table (6 to 12 hours), tags for 90 days. Candidates are NOT matched
on Spotify during retrieval; only the reranked winners are (`engine::resolve_picks`), through the
existing budgeted search, so the number of Spotify searches stays small.

Nothing is sent to ListenBrainz by this code. If you turn the opt-in on, it only reads recommendations
that your ListenBrainz account already has. Scrobbling (sending your plays) is not implemented.

## Rank (`features.rs`, `model.rs`)

Eleven features per candidate, all about -1 to 1: slow affinity, fast affinity, cluster fit, time of day,
novelty, release recency, source trust, popularity, recent skip rate (14-day memory), track history,
comeback. The score is their dot product with the weights. The starting weights are written in
`features::PRIOR_WEIGHTS`. The online logistic model keeps those 11 weights plus a bias, bounded to +-4 and
pulled back to the prior (L2), and updates them with one SGD step per finished song, like or skip.

- First use: the last 21 days are replayed day by day. Each day's features come from the profile built
  from BEFORE that day, so nothing from the future leaks in.
- After that, a daemon task (`reco-learner`, every 5 minutes) reads new rows of `play_log` and `skip_log`
  and takes one step per row, against a profile that does not include the row itself.
- State: `reco-state.json` in the state dir (atomic writes; an unreadable file is moved to `.corrupt`).
- Reset: `halcyon-musicd --reco-reset` (weights back to the prior, exploration beliefs forgotten, history
  not replayed again).
- Debug view: `halcyon-musicd --reco-explain "Artist" ["Title"]` prints every feature, its current weight,
  its starting weight and what it added.

## Rerank (`rerank.rs`, `bandit.rs`)

1. Songs played in the last 6 hours are dropped (not on On Repeat).
2. 20% of the slots are exploration slots for artists you never played, spread evenly over the list. The
   source that fills each one is picked by Thompson sampling: one Beta(alpha, beta) per (shelf, source),
   updated when you finish or skip an exploration song (the learner does this).
3. The other slots are filled by maximal marginal relevance: rank score minus similarity to what is already
   on the list (same artist 1, otherwise 0.6 times tag cosine) minus a small penalty for a jump in energy
   (from tags, only when tags say something).
4. Hard limits: 2 songs per artist (3 for "describe a mood" lists), never the same artist twice in a row
   unless nothing else is left. A list may end up shorter than asked rather than break the cap.

The seed is the shelf and the day, so a list does not change on every launch. A refresh bumps `epoch`.

## Not done here (Part 6 and later)

- Part 6 builds the shelves on it (`engine::prepare` + `shelf_from`), see `docs/playlists.md`.
- No GUI for the reset, the ListenBrainz opt-in, or the debug view (CLI only).
- Skips are only logged by the direct playback engine, not by the Connect backend (Part 4 finding).

## Unverified

Marked `VERIFY` in the code and not checked against the live services: MusicBrainz tag response shape,
ListenBrainz `cf/recommendation` and `metadata/recording` response shapes. Run
`halcyon-musicd --reco-probe` on a machine with a network.
