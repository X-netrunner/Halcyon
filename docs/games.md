# Halcyon game launcher (`hgl`)

The game launcher. Phase 1 is the engine: a Rust helper, no dependencies, installed to `~/.config/Halcyon/bin/hgl` (no root). Phase 2 (below) connects it to the island: `>games` / `>game <name>` in the launcher, the "now playing" pill, and the lean island. The Game Center window is Phase 3 and will call this same binary (`--json` output is for it).

## What works now
| Command | What it does |
|---|---|
| `hgl import steam` | Reads `libraryfolders.vdf` and every `appmanifest_*.acf` (native, `~/.steam`, Flatpak, extra drives), skips Steam's own tools and half-installed games, takes cover art from Steam's local cache, drops games you uninstalled. Your per-game settings are kept. |
| `hgl add game.exe [--name N] [--proton V] [--wayland]` | Adds a plain .exe. Icon extracted offline with `icoutils` when installed. |
| `hgl list [--json]` / `hgl show <id>` | Library, last played first, with a status (`ready` / `attention` and why). |
| `hgl set <id> <key> <value>` | `name exe proton prefix args wrappers gamescope wayland lean debug umu_id cover env.NAME`. `wrappers` = `gamemode,mangohud`; `gamescope` = a preset (`native 1080p 1440p fsr1080 fsr1440`) or raw gamescope options. Wayland is off by default. |
| `hgl run <id> [--dry-run]` | Starts the game (below). `--no-lean` skips the Halcyon side, `--no-scope` skips the systemd scope. |
| `hgl stop [id]` | Stops the whole scope, so no stray `wineserver` is left. |
| `hgl proton install [latest\|tag] [--family ge\|cachyos]` | GE-Proton by default, Proton-CachyOS as an option. SHA-512 checked (a download without a checksum file is refused), installed under `$XDG_DATA_HOME/Halcyon/proton`. |
| `hgl proton list / remove / default / rollback / prune / link-steam` | Keeps the newest 3 per family (`proton_keep`), never removes a version a game is pinned to or the default; `rollback` = previous version becomes the default; `link-steam` also shows them in Steam's compatibility tool list. |
| `hgl doctor [--fix] [--yes] [--json]` | Checks Vulkan (64 and 32-bit, per GPU vendor), multilib / i386, umu, gamemode (+32-bit), gamescope, mangohud, icoutils, `vm.max_map_count`, user scopes and a Proton runtime. `--fix` lists what it would install, asks once, installs with pacman or apt. Two things it will not do for you: enable `[multilib]` in `pacman.conf`, and choose an NVIDIA driver. |
| `hgl triage <id>` / `hgl fix <id> <finding>` | Scans the newest log for known causes (no Vulkan ICD, 32-bit libs, Wayland driver, D3D11, kernel map limit, gamescope, missing DLL, anti-cheat ...). Most have a one-step fix. |
| `hgl logs <id>`, `hgl status`, `hgl recover`, `hgl config` | Newest log, running game as JSON, manual restore, global options. |

## How a non-Steam game is started
`systemd-run --user --scope -p CPUWeight=800 -- [gamescope ... --] [mangohud] [gamemoderun] umu-run game.exe`, in the game's folder, with `WINEPREFIX` (its own prefix under `$XDG_DATA_HOME/Halcyon/prefixes/<id>`), `PROTONPATH` (pinned or default runtime), `GAMEID` and your per-game environment. Output goes to `$XDG_STATE_HOME/Halcyon/hgl/logs/<id>/` (newest 8 kept). Steam games are started with `steam -silent steam://rungameid/ID` (Steam stays for DRM and cloud saves) and followed until their processes are gone; they get no hgl scope because Steam owns their process tree.

## Halcyon steps aside (the parts Phase 1 does)
1. **Gaming mode**: `scripts/gamemode.sh on` at launch, `off` afterwards. Only when it was not already on, so a gaming mode you switched on yourself stays on.
2. **CPU priority**: the game's own scope has a high CPU weight; the units Halcyon's shell runs in (only units whose name says quickshell / halcyon / island, never a session or Hyprland unit) get a low weight (`halcyon_weight`, default 20, `halcyon_throttle=0` turns it off). Pinning Halcyon to one core is opt-in: `hgl config halcyon_core 0`.
3. **Always restored**: what was switched is written to `/dev/shm/halcyon-hgl-<uid>` first. A detached watchdog (`hgl __watch`) restores when the game is gone even if `hgl` was killed; `hgl recover` does the same by hand.
4. **Session report** after each game: playtime, and Halcyon's own CPU and RAM during it (`~/.local/state/Halcyon/hgl/last-session.json`, `sessions.log`).

The island's own lean mode is described under Phase 2 below.

## Phase 2: Halcyon's side (the island)
**How the island is told.** `hgl run` calls the island's IPC (`quickshell ipc -p ~/.config/Halcyon/quickshell/island call island gamestart <id> <name> <since> <lean>`) when the game starts and `gameend` once everything is put back, also when the game crashed or `hgl` was killed (the watchdog calls it). If the island restarts while a game runs it asks `hgl status` once at start. No Quickshell running, or an older island without these calls = nothing happens.

**Lean island** (`lean` on in the game's profile, the default; `hgl run --no-lean` skips it). On top of what Gaming mode already stops (the music visualizer, wallpaper cycling, constellations, the daily-brief card, the splash, slower art), lean also:
- stops the `hx stats` and `hx net` feeds, and the disk / GPU feeds if a widget wanted them (the last values stay);
- hides the desktop widgets, which stops every widget timer and reader (weather, notes, brief, lyrics, ...) at once;
- turns the island's animations off (`motion` 0) and stops the Num Lock and "last seen" polls;
- does not touch the 15 s state poll (it keeps the Gaming chip honest) or the notification server.
Everything comes back when the game ends. By hand: `quickshell ipc -p ~/.config/Halcyon/quickshell/island call island leanset true` (or `false`).

**The pill** (`GamePill.qml`): the game's name, how long it has run, a `lean` mark and a **Stop** button (`hgl stop`). It is a small window on the Top layer at the top of the screen: a fullscreen game covers it, you see it when you leave the game for a moment. It exists only while a game runs.

**Launcher commands** (`>` in the launcher, new category **Games**):
| Type | Does |
|---|---|
| `>games` | The library as rows, last played first (Enter = launch). Also the "Games" row, `halcyon`-style IPC `command games`. |
| `>game <name>` | Same, filtered by the name (prefix, contains, then fuzzy). Rows that need attention say why. |
| `>games add` | Opens the console with `hgl add ` typed in, you add the path. |
| `>games import` | `hgl import steam` in the console. |
| `>games doctor` | `hgl doctor` in the console (add `--fix` there to install what is missing). |
| `>games proton` | `hgl proton list` in the console. |
| `>games stop` | `hgl stop`. |
Until the Game Center exists (Phase 3), add / import / doctor / proton open the console (`quickTerm`) instead of a page.

## Files
`~/.config/Halcyon/games/<id>.conf` (one per game, plain `key=value`), `~/.config/Halcyon/hgl.conf` (global options), `$XDG_DATA_HOME/Halcyon/{proton,prefixes,covers}`, `$XDG_STATE_HOME/Halcyon/hgl/`. Nothing is hardcoded to a home path.

## Limits
- Kernel-level anti-cheat (Easy Anti-Cheat, BattlEye) only works when the developer enabled Proton support. No launcher changes that.
- A game that is already running refuses a second launch (a notification says so). The pill's Stop and `>games stop` end the whole scope.
- Epic / GOG login and install (legendary, gogdl), Heroic / Lutris import and SteamGridDB art are Phase 4; `hgl import` knows only Steam today.
- Tested with fake system programs (`tests/hgl.test.sh`, in CI) and unit tests; **not tested here: a real game start, a real Proton download (the sandbox cannot reach GitHub's API), real pacman / apt installs**. Phase 2: the QML is checked by `tests/qml-types.test.js` and `tests/commands-widgets.test.js`, the IPC calls by `tests/hgl.test.sh` with a fake `quickshell`; **not tested: the pill, the lean mode and the launcher rows running in a real island** (no Quickshell / Hyprland / GPU here).
