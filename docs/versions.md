# Version Center

One window to update Halcyon and its three companions (LUNA, ai-antivirus, ai-firewall), and to install an **older** version of any of them by picking a commit or a tag.

Open it with `>versions` (also `>update`) in the launcher, **Settings > System > Version Center**, or `qs ipc call ... versions`. It is an ordinary island window like the Security center: same frame, same slow animations, nothing running while it is closed.

## What it shows
One card per component, in one column: **Halcyon, LUNA, ai-antivirus, ai-firewall**.

- The installed version (short commit, date, tag if any) and the newest on GitHub `main`, with *N commits behind* or *on the latest*.
- **unreg**: the installed commit is not in the repository's history on GitHub (a build from a commit that was never pushed, or one that was rewritten away). It is never counted as an update; **Update to main** and **Roll back** still work on it.
- When the window opens and the last look at GitHub is over an hour old, it checks once, quietly, so these labels are current without pressing *Check now*. No timer, no polling; offline it keeps the cache.
- A commit list (hash, subject, date, author), newest first, loaded **only when you open it**, 30 at a time. The newest tags are chips above it; click one to install it. Every row has *Install* (not the installed one).
- **Update**, **Roll back** (to the version before the last change), **Pin / Unpin**.
- A component you did not choose at install is greyed with *Install*. It is never updated behind your back. A pacman package of ai-firewall is shown as "managed by pacman" and left to pacman.
- Top bar: **Check now** (asks GitHub), **Update all**, *last checked*, and the optional **Daily check** switch.

When GitHub cannot be reached (offline, rate limited) the cached history is shown, marked *offline*. Every network step is limited to 20 seconds, the same as `update.sh`.

## Pins
`~/.local/state/halcyon/pins.env`, one line per component: `HALCYON="<commit>"`, `LUNA=...`, `ANTIVIRUS=...`, `FIREWALL=...` (the same names as `install-choices.env`).

- Installing an old version **pins it automatically**. A pinned component is skipped by plain `update.sh`, by `update-extras.sh`, by `install.sh` (it says "pinned at ..., left as it is") and by **Update all**, and shows a pin badge.
- **Unpin** returns it to `main` and updates it now. `update.sh` refuses a detached HEAD, so a pinned Halcyon is the one case where it is allowed: `update.sh --unpin` switches back to the branch first.
- A press of **Update** on a pinned component moves it to `main` and drops the pin.

## Before a change (the confirm dialog)
Nothing runs until you accept a dialog that shows: the installed and the chosen commit, the diff stat between them, how many commits lie between, a clear **older than installed** warning, what is saved first, and the admin-password field when the step needs root.

| Component | Saved first | After | If it fails |
|---|---|---|---|
| ai-antivirus | `/var/lib/ai-antivirus` (its database is upgraded on the first start of a newer engine, schema 4; an older engine may not read it). The services stop for a moment and start again | health check | the previous package is installed again (`pacman -U` of the kept file, or a rebuild) and the database copy is put back. **Restore the database copy** is offered on the card. If an older engine is left running against the schema-4 database, the Security center says so and offers **Repair history**: `scripts/antivirus-db-repair.sh` keeps a copy in `/var/lib/ai-antivirus/backups` and lets the installed engine create a fresh database (the old alerts stay in the copy) |
| ai-firewall | `/etc/ai-firewall` | `ai-firewall check` | the previous binary and unit are put back |
| LUNA | `~/.config/luna/luna.toml`, her memory file (`history.json`) and conversations | binary runs, daemon active again | the previous binary is put back |
| Halcyon | install.sh's own copy in `~/.config/Halcyon-backups`; your own files (`hypr-user.lua`, `scheme/current.lua` ...) stay | no QML errors in the island log | the version you had is installed again by the same steps |

Backups of the three companions go to `~/.local/state/halcyon/backups/<name>/<time>/` (the last three are kept).

Health checks, after every action: service active, the installed binary matches the build that was just installed (its hash is recorded in `~/.local/state/halcyon/bin-<name>.sha`), `ai-firewall check`, `ai-antivirus status`, and the island log without QML errors. The card shows each check as a chip.

## How it works (so the window and the command line never disagree)
The window is thin. `scripts/halcyon-versions.py` (Python, like the other `scripts/halcyon-*.py` helpers; JSON on stdout) decides, and the existing scripts build:

| Action | Runs |
|---|---|
| update Halcyon | `update.sh --yes --no-extras` |
| install a Halcyon version | `update.sh --yes --no-extras --ref <commit\|tag>` (checkout of it, then `install.sh --yes` with your saved choices) |
| update / install a version of LUNA, ai-antivirus, ai-firewall | `scripts/update-extras.sh --only <name> [--ref <commit\|tag>]`: fetch, compare with the stamp, delete the old build output, build, install, write the stamp, restart what was running. A failed build leaves the installed version untouched |
| a component not installed yet | `install.sh --yes --luna` / `--antivirus` / `--firewall ai` |
| roll back | `update-extras.sh --only <name> --restore <name>` (the copy kept before the last install, no rebuild), else the recorded commit again |
| Update all | Halcyon, then LUNA, ai-firewall, ai-antivirus (install.sh's order); pinned and not-chosen ones are skipped |

Stamps (`~/.local/state/island/luna-rev`, `ai-antivirus-src`, `aifw-src`) and `install-choices.env` are the ones `install.sh` writes, so the two never disagree.

### Command line
```
scripts/halcyon-versions.py status [--refresh]
scripts/halcyon-versions.py log <component> [--from N] [--limit 30]
scripts/halcyon-versions.py tags <component>
scripts/halcyon-versions.py plan <component> <ref>
scripts/halcyon-versions.py update <component|all> [--ref X]
scripts/halcyon-versions.py install-version <component> <ref>
scripts/halcyon-versions.py rollback <component>
scripts/halcyon-versions.py pin <component>
scripts/halcyon-versions.py unpin <component> [--no-update]
scripts/halcyon-versions.py health <component>
scripts/halcyon-versions.py backups <component>
scripts/halcyon-versions.py restore-backup <component> [folder]
scripts/halcyon-versions.py autocheck on|off|status|run
```
Components: `halcyon luna ai-antivirus ai-firewall`. Steps that need root take `--password-stdin` (first line of stdin). Exit codes: 0 ok, 1 failed, 2 usage, 41 the admin password is needed, 42 wrong password, 43 another operation is running.

Without the helper, the same things by hand:
```
~/.config/Halcyon/update.sh --ref <commit|tag>        # Halcyon, pinned
~/.config/Halcyon/update.sh --unpin                   # back to main
~/.config/Halcyon/scripts/update-extras.sh --only luna --ref <commit|tag>
~/.config/Halcyon/scripts/update-extras.sh --unpin luna
```

## The admin password
Asked once in the dialog, for the steps that need root (`pacman -U`, installing to `/usr/local/bin`, `systemctl`). It goes to the helper on stdin and lives in that process's memory only. sudo is given a private `SUDO_ASKPASS` program that talks to a socket inside a 0700 folder (answers only this user, via `SO_PEERCRED`); it is tried once up front so a wrong password cannot lock the account, and the folder is removed when the helper ends. It is not stored in a file, the environment or a command line.

## Live progress and one at a time
The last lines of the build are shown in the card; the full log is `~/.local/state/halcyon/versions.log`. While something runs, the other buttons are disabled and the helper holds a `flock` (`versions.lock`), so a second window or the command line is refused (exit 43). Closing the window does not stop an operation; **Cancel** does (anything already installed stays; a build in progress is thrown away).

## The daily check (off by default)
`systemd/halcyon-versions-check.timer` (a user timer, installed by `install.sh`, **not** enabled). Switch it on in the Version Center top bar or in Settings. At most once a day it runs `autocheck run`: it only asks GitHub which versions are newest, writes `~/.cache/halcyon-versions/available.json`, and the notch bar shows a dot (click opens the window). It never installs anything. Switching it off removes the file and the dot.

## Good to know
- Installing a Halcyon version **older than this feature** removes the Version Center with it (like any older checkout). The dialog warns, and the way back is `cd ~/.config/Halcyon && git switch main && ./update.sh`.
- An `install.sh` from before pins existed does not know about them and may move a pinned companion to `main` while setting up an old Halcyon. The helper notices after a Halcyon change and puts such a companion back.
- A companion built from a bundle folder next to the Halcyon folder (`../ai-antivirus` ...) or from `LUNA_SRC` / `AV_SRC` / `AIFW_SRC` is "built from a local folder": there is no history to compare. Choosing a version always uses the managed clone in `~/.local/src/<name>`.
- Environment for forks and tests: `HALCYON_DIR`, `HALCYON_REPO`, `LUNA_REPO`, `AV_REPO`, `AIFW_REPO`, `AIFW_BIN`, `AV_BIN`, `AV_DB_DIR`.

## Tests
- `python3 tests/test_halcyon_versions.py` runs the helper, and through it the real `update.sh` and `update-extras.sh`, against local throw-away git repos with fake `cargo`, `makepkg`, `pacman`, `sudo` and `systemctl`. No network, nothing outside a temp HOME. It must run as a normal user (the scripts refuse root).
- `node tests/versions.test.js`: the QML is registered everywhere, the brief's rules hold (no polling, password via stdin, dialog first), and the helper answers with JSON.
