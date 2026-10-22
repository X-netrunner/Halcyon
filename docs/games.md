# Halcyon game launcher (`hgl`)

The game launcher. Phase 1 is the engine: a Rust helper, no dependencies, installed to `~/.config/Halcyon/bin/hgl` (no root). Phase 2 (below) connects it to the island: `>games` / `>game <name>` in the launcher, the "now playing" pill, and the lean island. The Game Center window (Phase 3) calls this same binary (`--json` output is for it). Phase 4 adds Epic and GOG, cover art and a known-fixes list (below).

## What works now
| Command | What it does |
|---|---|
| `hgl import steam` | Reads `libraryfolders.vdf` and every `appmanifest_*.acf` (native, `~/.steam`, Flatpak, extra drives), skips Steam's own tools and half-installed games, takes cover art from Steam's local cache, drops games you uninstalled. Your per-game settings are kept. |
| `hgl import flatpak` | Adds the installed Flatpak apps whose desktop entry is in the Game category (Sober, PrismLauncher, RetroArch ...), with their icon, and drops uninstalled ones. They start with `flatpak run <app id>` (environment variables through `--env`), no Proton or prefix; `hgl stop` uses `flatpak kill`. The Game Center's **Refresh** reads Flatpak and Steam. |
| `hgl add game.exe [--name N] [--proton V] [--wayland]` | Adds a plain .exe. Icon extracted offline with `icoutils` when installed. |
| `hgl list [--json]` / `hgl show <id>` | Library, last played first, with a status (`ready` / `attention` and why). |
| `hgl set <id> <key> <value>` | `name exe proton prefix args wrappers gamescope wayland lean debug umu_id cover env.NAME`. `wrappers` = `gamemode,mangohud`; `gamescope` = a preset (`native 1080p 1440p fsr1080 fsr1440`) or raw gamescope options. Wayland is off by default. |
| `hgl run <id> [--dry-run]` | Starts the game (below). `--no-lean` skips the Halcyon side, `--no-scope` skips the systemd scope. |
| `hgl stop [id]` | Stops the whole scope, so no stray `wineserver` is left. |
| `hgl proton install [latest\|tag] [--family ge\|cachyos]` | GE-Proton by default, Proton-CachyOS as an option. SHA-512 checked (a download without a checksum file is refused), installed under `$XDG_DATA_HOME/Halcyon/proton`. The release list comes from the GitHub API, with your token when there is one (`GITHUB_TOKEN`, `GH_TOKEN` or a `gh` login; 5000 requests an hour instead of 60 per network address); when the API refuses, from github.com's release pages instead. Always the x86_64 build (GE-Proton 11 also ships aarch64). |
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
| `>gamecenter` | Opens the Game Center window (below). Also `halcyon games`, `island command gamecenter`, or the IPC calls `gamecenter` and `gamecenterpage library\|runtimes\|doctor`. |
| `>games` | The library as rows, last played first (Enter = launch). Also the "Games" row, `halcyon`-style IPC `command games`. |
| `>game <name>` | Same, filtered by the name (prefix, contains, then fuzzy). Rows that need attention say why. |
| Stop the game | `hgl stop`. Only listed while a game runs. |

Adding, importing, Proton, the stores and the Doctor are in the Game Center (typing `>proton`, `>doctor`, `>epic` or `>add exe` finds it). The old ids still work from IPC and `island command`: `games-add` (opens the .exe browser), `games-import`, `games-doctor`, `games-proton`, `games-stores`, `games-stop`.

## Phase 3: the Game Center (`GameCenter.qml`)
One window (Glass, Chip, Toggle: the same look as the rest of the island), opened with `>gamecenter`. It has no engine of its own: it reads `hgl list --json`, `hgl proton list --json`, `hgl doctor --json` and `hgl triage <id> --json`, and changes things with `hgl set / add / import / remove / proton ... / fix`. While it is closed nothing runs (LazyLoader, no timers, no processes).

**Library.** A grid of cover art, last played first. Type to search, the arrow keys move, **Enter plays**, a double click or the play button on a hovered cover plays, Esc closes. Filter chips appear only for the stores you have games from. A badge shows *Playing* or *Needs attention* (the reason is in the drawer; a reason that names the Doctor opens it on click). **Read Steam** imports your Steam library again.

**Add game** opens a .exe browser inside the window (`ExePicker.qml`; a normal file chooser would open underneath the overlay): Downloads, ~/Games (when it exists), Home and mounted drives on the left; type to filter, or type a path and press Enter. **Look in subfolders** lists every .exe up to 6 folders down (hidden folders and Windows system folders skipped), because a game's program often sits in `Binaries/Win64`. Uninstallers, redistributables and crash reporters are dimmed and listed last. Picking one fills in a name from the folders around it (`~/Games/Hollow Knight/x64/hollow_knight.exe` → *Hollow Knight*); check it and press Enter. A path can still be pasted into the add bar.

The **drawer** on the right is the selected game's profile, under its cover:
- **Play / Stop**, the play time, and the last session's report (Halcyon's own CPU and memory while you played).
- **Runs with:** the **Proton version** (a game's own, or the default) and a **Gamescope** preset (Off, Native, 1080p, 1440p, FSR 1080p / 1440p).
- **While playing:** **Gamemode** and **MangoHud** wrappers, **Lean island** and **Wayland mode**. Steam games only show Lean island: Steam starts them, so Proton, wrappers and Gamescope are set in Steam.
- The crash check's findings show right under Play when it finds something.
- **Advanced** (folded): launch options (saved on Enter or when you leave the box), environment variables (add and remove), and the tools: *Prefix folder* (opens the game's Wine prefix), *Wine settings* (winecfg in the console), *Show log* (the newest log, last 60 lines), *Check last run* (the crash triage). Each finding has a **Fix it** button: the ones that change a setting run at once, the ones that install packages open the console. A game whose last exit was not clean is checked when you select it.
- **Remove from library** (asks twice; the prefix and the game files stay).

**Runtimes.** Installed Proton versions (family, default, pinned by a game), *Install GE-Proton*, *Install Proton-CachyOS*, *Make default*, *Remove*, *Roll back the default*, *Remove old versions* and a *Show in Steam* switch. Installs run in the background; the dot at the top pulses while one works.

**Doctor.** The result of `hgl doctor` as a list (green, yellow, red, with what is missing and what to do by hand). *Check again* re-reads it, *Fix what is missing* closes the window and runs `hgl doctor --fix` in the console, because installing packages asks for your password.

## Phase 4: Epic, GOG, cover art, known fixes
**Epic** (needs `legendary`; the Doctor says if it is missing). `hgl epic login` (legendary shows the sign-in page and asks for the code; needs a terminal, the Game Center opens one), `logout`, `status`, `list` (what you own, installed ones marked), `install <app name>` (Windows build under `~/Games/Halcyon/Epic`, or `games_dir`). `hgl import epic` adds what legendary has installed and drops what was uninstalled. A game is started with `legendary launch <app> --no-wine --wrapper "[mangohud] [gamemoderun] umu-run"` inside the usual scope, so legendary supplies the login parameters and umu runs the game. Per-game launch options are passed to the game; add `--offline` there to play without going online.

**GOG** (install needs `gogdl`, Heroic's downloader; `hgl config gogdl PATH` if it has another name). `hgl gog login` prints the sign-in address; after signing in, copy the address you land on and run `hgl gog login '<address>'` (the Game Center has a box for it). The login lives in `~/.config/Halcyon/gog/auth.json` (mode 600). `hgl gog list` reads your library from GOG's account API (renewing the token itself), `hgl gog install <id> [--title T]` runs gogdl. **`hgl import gog [folder ...]`** reads the `goggame-<id>.info` file of every installed game (so games installed by Heroic, GOG's installer under Wine, or gogdl are all found) in `~/Games/Halcyon/GOG`, `~/Games/Heroic`, `gog_dirs` and the folders you name; the program and arguments come from the file, add-ons are skipped. GOG games start through umu directly: they need no client.

**Cover art** (`hgl art [id] [--force]`, and automatically after an Epic / GOG import): Steam's CDN when Steam's own cache has none, Epic's key images, GOG's box art, and SteamGridDB for any game still without art if you set `hgl config steamgriddb_key KEY` (a free key from steamgriddb.com). Nothing is fetched for a game that has art, adding a game touches the network only if you set a key, and the key is kept in a 600-mode file, never printed, never on a command line. The icon taken from a .exe counts as "no art".

**Known fixes** (`hgl fixes <id> [--apply]`; `src/hgl/fixes.db`, built in; yours in `~/.config/Halcyon/hgl-fixes.conf`, read after it). An entry matches `steam:<appid>`, `epic:<app name>`, `gog:<id>` or `name:<text>` and has a `note` (shown in the Game Center drawer), `env.NAME` and `set.KEY` lines (only wrappers, args, wayland, gamescope, umu_id, lean, debug: never the program or the prefix). Settings are applied once, when a game is added or imported; a change you make later is not undone. The built-in list is deliberately short: four anti-cheat warnings (Destiny 2, Apex Legends, PUBG, Fortnite). It is a mechanism to grow with your own entries, not a database of tested fixes.

**Game Center**: a **Stores** tab (Epic and GOG side by side: log in, My library, Install, Read installed, Get cover art) and Epic / GOG filter chips. `>games stores` opens it.

**Not tested against the real services:** the Epic and GOG commands were written from their documented behaviour and checked with fake `legendary`, `gogdl` and `curl` in `tests/hgl.test.sh`. The exact `legendary` / `gogdl` options, the GOG API answers and the SteamGridDB and CDN URLs have not been run against the real thing. If one of them differs, the log or the error line says which.

## After Play
The Game Center stays open after Play and says what is happening, from `hgl run`'s output (`$XDG_RUNTIME_DIR/hgl-launch.out`) and the game's log: *Starting*, *Downloading the Steam Runtime* (first start), *Setting up the Windows folder* (first start), *Opening*. It steps aside when the game's window appears. If the game closes within a minute (and you did not stop it), the window comes back with "*Game* closed after *N* s", the last lines of the log (gamemode noise left out), the crash check's findings, Full log and Try again. An error before the game starts (a missing file, no Proton) shows the same way.

## Machine class and suggested settings
`hgl class [--json]` sorts the machine into a gaming class from its best GPU (by name: RTX / GTX, RX, Arc, the Radeon 680M-890M iGPUs; by video memory when the name is unknown), capped by video memory (under 8 GB: at most B), CPU threads and system memory:

| Class | Typical hardware | Aim |
|---|---|---|
| A, high end | RTX 4070 / 3080, RX 7800 / 6800 and up | native 1440p, High to Ultra |
| B, mid range | RTX 4050 / 4060 / 3060, RX 6600 / 7600, Arc A750 / B580 | 1080p High, heavy effects Medium, DLSS / FSR Quality, 60 fps |
| C, entry | GTX 1650 / 1060, RX 6500, Arc A380, Radeon 780M | 1080p upscaled or 900p, Low to Medium |
| D, integrated | Intel UHD / Iris Xe, older Radeon iGPUs | 720p Low, upscaled to 1080p by gamescope FSR |

`hgl suggest <id> [--apply] [--json]` turns the class into changes hgl can make (only what differs from the game's profile): Lean island on; gamemode; gamescope off from class C up, 720p upscaled with FSR on class D; on a laptop with an NVIDIA card next to integrated graphics the PRIME offload variables (`__NV_PRIME_RENDER_OFFLOAD`, `__VK_LAYER_NV_optimus`, `__GLX_VENDOR_LIBRARY_NAME`) so the game runs on the NVIDIA card; `PROTON_ENABLE_NVAPI=1` on RTX cards (DLSS, Reflex). Custom gamescope options are left alone; Steam games only get Lean island. It also lists what to set in the game's own menu, which hgl cannot reach. It recommends a Proton too: GE-Proton (the most game fixes, what umu's per-game fixes are tested with), with Proton-CachyOS named as the alternative when the CPU can run its x86-64-v3 build; when none is installed, or the game is pinned to one that is missing, the card has an **Install** button (a download, so never part of `--apply`). In the Game Center the drawer's **For your PC** card shows the class, the changes with an **Apply** button, and the in-game settings.

## Files
`~/.config/Halcyon/games/<id>.conf` (one per game, plain `key=value`), `~/.config/Halcyon/hgl.conf` (global options, mode 600), `~/.config/Halcyon/gog/auth.json`, `~/.config/Halcyon/hgl-fixes.conf`, `$XDG_DATA_HOME/Halcyon/{proton,prefixes,covers}`, `$XDG_STATE_HOME/Halcyon/hgl/`. Nothing is hardcoded to a home path.

## Limits
- The first start of a Windows game is slow: umu downloads its Steam Runtime once (about 700 MB) and the game's Wine prefix is created. `hgl run` sends a notification when that is about to happen; let it finish.
- Kernel-level anti-cheat (Easy Anti-Cheat, BattlEye) only works when the developer enabled Proton support. No launcher changes that.
- A game that is already running refuses a second launch (a notification says so). The pill's Stop and `>games stop` end the whole scope.
- Heroic and Lutris libraries are not read (a Heroic legendary install can be used: `hgl config epic_config ~/.config/heroic/legendaryConfig/legendary`). "Add game" has its own .exe browser inside the window (a system file chooser would open under it); a pasted path works too, `~` included.
- Tested with fake system programs (`tests/hgl.test.sh`, in CI) and unit tests; **not tested here: a real game start, a real Proton download (the sandbox cannot reach GitHub's API), real pacman / apt installs**. Phase 2: the QML is checked by `tests/qml-types.test.js` and `tests/commands-widgets.test.js`, the IPC calls by `tests/hgl.test.sh` with a fake `quickshell`; **not tested: the pill, the lean mode, the launcher rows and the Game Center running in a real island** (no Quickshell / Hyprland / GPU here). Phase 3: `GameCenter.qml` passes the repo's QML checks (`tests/qml-types.test.js`, `tests/commands-widgets.test.js`) but has never been loaded by Quickshell: if the window does not open, `quickshell log` names the line.
