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
  librespot playback (real position and errors from the engine), the Spotify sign-in and its
  token store (Secret Service keyring + 0600 file), resilient Web API client (rate limiting,
  circuit breaker, 8s timeout, 401 refresh), endpoint probes table (24h TTL), `--doctor`,
  `--login` and `--probe`.
- `crates/halcyon-music` — the iced GUI client. Pure view with a one-button Sign in with
  Spotify screen, cached library viewing offline, and auto-reconnect.
- `packaging/halcyon-musicd.service` — systemd user unit
  (`Restart=always`, `WatchdogSec=30`).

## Build and run

```sh
cargo build --workspace
./target/debug/halcyon-musicd          # daemon
./target/debug/halcyon-music           # GUI (starts the daemon if needed)
./target/debug/halcyon-musicd --doctor # checks with PASS/WARN/FAIL + fix hints
```

## Signing in

Press **Sign in with Spotify** on first launch (or run `halcyon-musicd --login` from a terminal).
One browser sign-in through librespot's own OAuth flow serves both browsing and playback; there
is no Client ID to paste. The token renews itself in the background.

- **Premium is required to play music.** Free accounts can still browse; the app says so.
- **Advanced: use my own Client ID.** Browsing only (the owner of the Client ID needs Premium,
  Spotify allows one Development Mode Client ID per developer and five users, and search is
  capped at 10 results). Playback always uses the Spotify sign-in above.

## Install and update

`./install.sh` (also run by `update.sh`) builds both binaries, installs them atomically and then
**restarts `halcyon-musicd`**, including a daemon that systemd does not manage (one the app
started itself). A daemon keeps running the old build after its file is replaced until it is
restarted, so playback stops for a moment during an update. Without a systemd user session the
daemon starts the next time you open the app.

Both binaries answer `--version`. The app also shows a toast if it meets a daemon of another
version: restart it with `systemctl --user restart halcyon-musicd`.

**Two extras, both off unless you ask** (set the variable for one run; the choice is remembered in
`~/.config/halcyon-music/build.conf`, so `update.sh` keeps it; `=0` turns it off again):

| Variable | What it does |
| --- | --- |
| `HALCYON_MUSIC_CONNECT=1` | Builds the Spotify Connect code and sets `HALCYON_CONNECT=1` for the service (a drop-in named `halcyon-connect.conf`, never your own `override.conf`), so Halcyon is listed under Devices on your phone. See `docs/connect.md`. |
| `HALCYON_MUSIC_LOCAL_MODEL=1` | Builds the engine for the built-in small model (needs cmake, a C++ compiler and libclang; without them the installer says so and builds without it). |

```sh
HALCYON_MUSIC_CONNECT=1 HALCYON_MUSIC_LOCAL_MODEL=1 ./install.sh --yes
```

The model file is never downloaded by the installer. It downloads the first time you turn on
Smart suggestions (Settings shows the size first). If a build with an extra fails, the installer
builds the plain player instead, so an update never leaves you without one. Connect is off by
default because its phone checklist (`docs/manual-test.md`) has not been completed on a real
session yet; once it has, a single line in `install.sh` (`MUSIC_CONNECT_DEFAULT`) turns it on for new installs.

## `halcyon-musicd --doctor`

One line per check, PASS / WARN / FAIL (or INFO for facts that are not about the install, such
as an endpoint Spotify refuses for your account), each FAIL with a fix. Exit code 0 when there is
no FAIL, 1 when there is one. It checks:

| Check | What it looks at | FAIL means |
| --- | --- | --- |
| daemon socket / process | the daemon answers; exactly one runs and its file was not replaced after it started | not running, an old build still runs, or two daemons run |
| daemon version / app version | the running daemon, the installed daemon and the installed app report the same version | restart the daemon or reinstall both |
| streaming token | a sign-in with the streaming permission exists and has not expired | sign in again |
| spotify session | connects a Spotify session with the saved token and asks for a token, as a track load does | Spotify rejects the sign-in (`INVALID_CREDENTIALS`), Free account, or no connection |
| audio output | opens the default audio output once | no PipeWire / PulseAudio device |
| browsing sign-in | the token browsing uses, by sign-in mode | Client ID mode without a saved sign-in |
| account name | the Spotify name the daemon has saved (read from the cache, no Web API) | never FAIL: WARN when only the username is known yet |
| connect device | whether Halcyon is registered as a Spotify Connect device | never FAIL: WARN when it was asked for but is not registered, INFO when off |
| model | whether the built-in model is on disk, when Smart suggestions use it | never FAIL: WARN when it is chosen but missing, half downloaded, or this build has no engine; INFO when Smart suggestions are off or use Ollama |

The doctor never renews the token (the running daemon does), and never prints it. The session
check opens a second, short Spotify session with its own device id; whether that can interrupt
a track playing at that moment has not been tested, so run `--doctor` while idle if in doubt.

## Soak test

`scripts/soak_test.sh [minutes]` sends random commands to the running daemon and writes
`docs/soak_report.md` from what it measured: commands that could not be sent, daemon restarts,
peak memory against the 150 MB budget, open files at the start and the end (a leak signal), and
whether the daemon still answers. It exits 1 on any problem. It does not inject faults (start the
daemon with `HALCYON_MUSIC_FAULTS` for that).

The release run uses both extras:

```sh
SOAK_CONNECT=1 SOAK_MODEL=1 scripts/soak_test.sh 30
```

`SOAK_CONNECT=1` fails the run if the Connect device is not registered at the start, or is gone
or a different process at the end. `SOAK_MODEL=1` keeps asking for mixes and suggestions so the
built-in model works; the 150 MB budget excludes the loaded model, so the script then waits for
it to unload (2 minutes idle) and fails if the daemon is still above 150 MB.

State lives in `~/.local/state/halcyon-music/`, the cache in
`~/.cache/halcyon-music/`, and the socket in `$XDG_RUNTIME_DIR/halcyon-music/`.
Covers: the GUI asks the daemon for art (`GetArt`), the daemon downloads and caches it, and
the GUI decodes it off the UI thread (`art.rs` in both crates).

Playback is librespot's: the position, play/pause state and errors shown in the app come from
the engine's own events.

## Release checklist

`scripts/check.sh` (check, test, clippy `-D warnings`), the soak run above, and the 15-minute
checklist in `docs/manual-test.md` on a real Premium session. Other docs: `docs/connect.md`,
`docs/profile.md`, `docs/llm-layer.md`, `docs/playlists.md`, `docs/reco.md`.

## Look and feel

Five moods under Settings, Appearance, Mood: **Wallpaper** (follows the colours the rice writes to
`~/.local/state/halcyon-music/palette.toml` whenever the wallpaper or theme changes; the app checks the file
every few seconds and re-colours itself), and the fixed Dusk, Dawn, Forest and Ocean. With no saved choice the
app starts in Wallpaper when that file exists, otherwise Dusk. The page gradient and glow also follow the
album cover. Motion is slow and soft; set `GTK_ENABLE_ANIMATIONS=0` to turn it off.

The sidebar, the title bar and the player bar are one frame around the page. The sidebar opens under the
pointer and pushes the page aside; its icons stay where they are and the labels fade in on the same line.

## Discover and All-Time Best

- **Discover** (sidebar, second row): new music, built without the Spotify Web API (the default
  sign-in is rate limited there, and cannot read the followed-artists list). It starts from the
  artists you listen to, taken from your play log and liked songs. *New from your artists* is what
  they released lately (iTunes Search, no key); *Latest releases* are the newest popular albums
  (Apple Music's most played, Deezer's editorial releases, ListenBrainz fresh releases; Spotify's
  own list too when you use your own Client ID); *New songs* is a song from each; *Trending this
  week* is what ListenBrainz listeners play; *If you like ...* are two mixes a day made from one of
  your artists and similar artists (Deezer). Everything is matched on Spotify through the session
  search, which has no Web API quota. A source that fails is skipped and logged
  (`journalctl --user -u halcyon-musicd | grep -i "discover\|itunes\|apple\|deezer"`).
  The daemon answers `get_discover` at once with the last finished page, then again as each part
  is fetched (`discover_result`, the last one has `complete: true`).
- **All-Time Best** (a Home mix) blends the greatest English-language songs of all time (a
  built-in list, a different slice each day, matched on Spotify) with your own most played songs,
  two of the first for every one of yours. Matches are cached, so it fills in over a few loads;
  with no match yet it shows your own top songs, as before.
