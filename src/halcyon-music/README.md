# Halcyon Music

A Spotify player for the Halcyon rice: fast, reliable first. The GUI is a pure
view; the daemon owns playback, the session and the state, so music keeps
playing when the window closes or crashes.

Built part by part from `HALCYON-MUSIC-PLAYER-PROMPTS.md`; see `changelog.md`
at the repo root for what each part delivered and what was tested.

## Layout

- `crates/halcyon-music-core` — shared types (`Track`, `Album`, `Playlist`, `PlayerState`, `AuthStatus`) and the
  versioned NDJSON protocol over `$XDG_RUNTIME_DIR/halcyon-music/ctl.sock`.
- `crates/halcyon-musicd` — the daemon. Supervised tasks (panic → crash report
  → restart with backoff), atomic state saves, corrupt-state recovery,
  sd_notify watchdog, SQLite cache (stale-while-revalidate, LRU image store),
  Spotify PKCE authentication & token store (Secret Service keyring + 0600 file),
  resilient Web API client (rate limiting, circuit breaker, 8s timeout, 401 refresh),
  endpoint probes table (24h TTL), and `--doctor`.
- `crates/halcyon-music` — the iced GUI client. Pure view with first-run Client ID
  paste flow, PKCE browser sign-in, cached library viewing offline, and auto-reconnect.
- `packaging/halcyon-musicd.service` — systemd user unit
  (`Restart=always`, `WatchdogSec=30`).

## Build and run

```sh
cargo build --workspace
./target/debug/halcyon-musicd          # daemon
./target/debug/halcyon-music           # GUI (starts the daemon if needed)
./target/debug/halcyon-musicd --doctor # checks with PASS/WARN/FAIL + fix hints
```

State lives in `~/.local/state/halcyon-music/`, the cache in
`~/.cache/halcyon-music/`, and the socket in `$XDG_RUNTIME_DIR/halcyon-music/`.
Covers: the GUI asks the daemon for art (`GetArt`), the daemon downloads and caches it, and
the GUI decodes it off the UI thread (`art.rs` in both crates).

Part 3 replaces the simulated player with librespot playback.
