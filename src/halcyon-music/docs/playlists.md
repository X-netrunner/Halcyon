# Recommended playlists (Part 6)

Code: `crates/halcyon-musicd/src/mixes/` (clock, mod, plan, store, build). Built on the Part 4 taste
profile and the Part 5 pipeline (`reco::engine::prepare` + `shelf_from`). Nothing here uses the
Spotify Web API.

## The mixes

| id | what | changes | how it is picked |
|---|---|---|---|
| `daily-mix-1..6` | one per taste cluster, titled `Daily Mix 2: lo-fi, chillhop` | every day (local midnight) | candidates by artists of the cluster, plus unheard artists whose tags fit it (about 15% exploration) |
| `discover-weekly` | about 30 songs | Monday | artists you never played, 50% exploration slots chosen by the bandit |
| `release-radar` | about 25 songs | Friday | new releases (last 120 days) by artists you play |
| `on-repeat` | about 30 songs | every day | your songs finished 2+ times in 30 days (relaxes to 1+) |
| `repeat-rewind` | about 30 songs | Wednesday | your songs by artists you like, not played for 60+ days |
| `daylist` | about 30 songs | 05:00, 12:00, 19:00 | artists you play in this time slot, mood word from their tags (`Tuesday late-night synthwave`) |
| radio | infinite queue from one song | while it plays | similar artists, the artist's own songs, tag neighbours, your library, scored by the same ranker plus a closeness boost |
| Smart Shuffle | your list shuffled, one suggestion after every 3 songs | on request | suggestions from a radio seeded by one of your songs |

"On Repeat" replaces the old engine's mix with the same id on Home. The old mixes that are not in
this table stay.

Times use the system time zone (`localtime_r`). Daily Mix numbers are kept when clusters are
recomputed (a cluster keeps its slot). At cold start (fewer than 50 plays) only Discover Weekly
(charts and editorial picks) and the Daylist are made.

## Rules

- A mix is stored in `mixes-state.json` (state dir, atomic writes, a bad file is moved to `.corrupt`).
  Opening the app shows it from that file at once. A mix is rebuilt only when its period changes or
  the listener taps Refresh. An automatic check runs at most every 30 minutes.
- Refresh bumps the mix's `epoch`. The ranker is deterministic, so a refresh adds a small repeatable
  jitter (`plan::refresh_jitter`) to the scores; epoch 0 (the scheduled list) has none.
- Every mix has a one-line reason (`MusicMix.description` and `MixMeta.reason`) and one reason per song.
- Artist cap: 2 per mix (3 for "describe a mood"), enforced again after songs are matched on Spotify
  (`plan::enforce_caps`), never the same artist back to back when it can be helped.

## Feedback

- Song, "Less like this": one skip row for the song in `skip_log` (so the next taste profile reads it),
  the artist is capped at 1 song per list; the third time the artist is blocked everywhere.
- Song, "Not my taste": three skip rows, the song is blocked for good (by id and by name), the artist
  gets one "less like this". The song leaves every stored mix and the queue at once.
- Whole mix: acts on the songs by artists you had not played (the exploration slots), then the mix is
  rebuilt now.
- Smart Shuffle "Not this" is "Not my taste" for that song.
- Reset: delete the `feedback` object in `mixes-state.json` (no GUI yet).

## Protocol (additive, version stays 1)

Commands: `get_mixes`, `refresh_mix`, `mix_feedback`, `start_radio`, `stop_radio`, `smart_shuffle`.
Events: `mixes_updated` (mixes plus `MixMeta` with reasons, schedule and cover data), `radio_started`,
`radio_stopped`, `smart_shuffle_started`. `HomeFeed.mix_meta` (serde default). The Home feed handler
also puts the stored mixes into the feed it sends, from the file.

## Not done / not verified

See the changelog entry for Part 6.
