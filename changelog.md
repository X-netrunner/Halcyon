- **AI overview guardrails.** Source code and terminal commands are not sent to the model: the line is just "Code snippet (Rust), 2 lines" / "Terminal commands, 3 lines", and the note is never sorted into a task. A note of fewer than 8 words gets no summary (a tiny note only made the model guess, e.g. "...and it is a personal meeting"); if the task sorting is on, a tiny note's line is the fixed "A task with a time: I will remind you ..." instead. The prompt says to keep tenses (things to do never become "fixed"/"completed"), and in code an overview line with a done-word (fixed, completed, sent, called ...) that the note itself does not contain is dropped. Ollama not answering is now told apart from "nothing to summarise". (`scripts/halcyon-notes.py`)

- **AI overviews no longer invent facts.** The overview prompt asks for a headline (the main point, or what finally happened when a note corrects itself) plus 2-3 short bullets, using only what the note says, at temperature 0. Every line is then checked against the note in code: a number that is not in the note, or more than 30% of its words missing from the note ("reduces latency by up to 90%", "exceeded expectations"), and the line is dropped. When nothing survives, the note's own first and last sentences are shown instead. (`scripts/halcyon-notes.py`)

- **New: AI overview under every note** (Settings > Notes > "AI overview under every note", `notes set NOTES_OVERVIEW 1`, off by default). Separate from "Sort new notes into tasks": with only the overview on, notes are never turned into tasks, each one just gets a summary under it: one sentence for a short note, a short intro plus up to four bullet points for a longer one. The Think button (now on every note) writes it again. (`scripts/halcyon-notes.py`, `island/Settings.qml`)

- **Fixed: long notes got no AI line at all.** The notes AI skipped any note over 280 characters or 4 lines, so pasted paragraphs were never looked at. Now a long note is never turned into a task: the AI only writes a short overview of what it says (up to 30 words), shown under the note like the other AI lines. The **Think** button is now on every note (it was hidden on notes the AI had not looked at), so older long notes can get their overview too. (`scripts/halcyon-notes.py`, `island/NotesMenu.qml`)

- **New: Lyrics desktop widget** (`island/WLyrics.qml`, Widget builder > Media > Lyrics): the line being sung is lit and the lines around it fade away with their distance (styles: Fade, Karaoke sweep, Spotlight, One line; options: lines on screen, text size, fade speed, width, timing offset). `scripts/halcyon-music.py` now keeps the LRC time stamps (`times`, seconds, beside `lines`) from LRCLIB and from a `.lrc` next to a local file; the lyrics panel is unchanged.
- **Fixed: the notes AI answered with the wording of its examples** ("A call you want to make at 6, so I set a reminder for 18:00" for a note about noodles). It now writes a short summary of what the note is about (`summary`, shown as the AI line, with the reminder time appended when one was set); the prompt examples no longer contain reminder sentences. (`scripts/halcyon-notes.py`)

## Unreleased

- **Changed: the local AI model choices now match what was tested (installer, `--choose`, advisor, notes).** After testing qwen2.5:3b-instruct, qwen3:4b and gemma2:2b on the Notes AI overview, **qwen2.5:3b-instruct** (~1.9 GB) is the pick: fastest (3-6 s a note), most consistent, and the only one that got the final outcome of a note that corrects itself right on its own. `install.sh`: the Tier 3 recommendation (a dGPU with 4 GB+ VRAM, or 16 GB RAM and 8+ threads) is now qwen2.5:3b-instruct instead of llama3.2:1b; Tier 1 / Tier 2 keep qwen2.5:0.5b / 1.5b but say that the Notes overview is better on the 3B; the model menu lists "Qwen 2.5 3B Instruct" first; a saved choice with no model, or `--llm` on its own, now falls back to the machine's own tier instead of a fixed 1B. **A choice you already made is kept**: `update.sh` does not change your model; run `./install.sh --choose` to be asked again, or `advisor model switch qwen2.5:3b-instruct`. **New: Notes can have its own model**: `notes set NOTES_MODEL qwen2.5:3b-instruct` (`default` goes back to the advisor's model), so chat can stay on a bigger model like llama3.1:8b while the Notes overview stays fast and light; order: `HALCYON_AI_MODEL`, then `NOTES_MODEL`, then the advisor's model (`ai-advisor.conf`), then qwen2.5:3b-instruct. `advisor model recommend` shows the 3B-instruct and the NOTES_MODEL tip; `advisor model qwen3b` / `3b-instruct` now mean qwen2.5:3b-instruct (the tested tag). The fallback when no model is configured or installed is qwen2.5:3b-instruct in the notes, `ai` and advisor scripts. The tier choice was tested here with a faked CPU/RAM/GPU (RTX 4050 6 GB -> 3B-instruct; 12 GB iGPU -> 1.5B; 6 GB iGPU -> 0.5B; 32 GB -> 3B-instruct); the interactive menu itself was not run (`bash -n` only). (`install.sh`, `scripts/halcyon-notes.py`, `halcyon-chat.py`, `adaptive-advisor.py`, `ai-models.py`)

- **Fixed: overview bullets lost after the real-model tests (notes).** Tested on a real qwen2.5:3b-instruct, qwen3:4b and gemma2:2b. A bullet is now only dropped as a repeat of the headline when it says nearly the same thing (before, bullets that merely shared words with a summarising headline were dropped, and the stock-dip line of a finance note was lost with them). A note that corrects itself and gets no headline from the model (qwen3, gemma2) now gets the final outcome as its headline. Result on your 4 test notes: qwen2.5:3b-instruct was the fastest (3-6 s) and the most consistent; qwen3:4b and gemma2:2b were slower (7-23 s) and left out the outcome of the transit note. (`scripts/halcyon-notes.py`)

- **Changed: `notes think <n>` now prints the result when typed in a terminal** (the model used, the seconds it took, and the AI line), so models can be compared: `HALCYON_AI_MODEL=qwen3:4b notes think 5`. Before, it was silent and the result only appeared under the note in the notes window; running it twice on one note just replaced the first result with the second. (`scripts/halcyon-notes.py`)

- **Fixed: the overview of a note that corrects itself, and repeated bullets (notes, tested with qwen2.5:3b).** A note that first says what was reported or expected and then turns around ("Initial reports ... However ... By 2 PM ... confirmed") now gets the final outcome as its headline and only the lines from after the turn; before, a 3B model put the rumour first. Bullets that only repeat the headline or an earlier bullet are dropped. A "Despite ..." / "However ..." caveat the overview left out is added (e.g. "Developers still face severe hardware constraints"). (`scripts/halcyon-notes.py`)

- **Fixed: AI overview edge cases from the 1B tests (notes).** (1) A time written in the note now wins over the model's guess: "Meeting at 9:30 AM." is due tomorrow 09:30 (it was 19:58), also "at 6", "17:30", "friday 17:30"; the tiny-note line is "Reminder set for tomorrow 09:30." instead of "I will remind you ...". (2) A snippet pasted inside quotes is counted correctly ("Code snippet (Rust), 7 lines", not 8). (3) A list of 3+ bullets / dashes / numbers is shown as it is ("Checklist, 4 items" and the items, no model call), so no item is dropped and no to-do becomes "fixed"; a bullet glued to the previous line ("UPI error• pick up") is split. (4) Bad news is not left out: a decline with a % figure in the note ("net income fell by 3%", "the stock dipped 4%") that the model skipped is added from the note's own words; the prompt also asks for it. (5) A long note whose model answer had a headline only now also shows its "First, / Second, / Third," sentences. (`scripts/halcyon-notes.py`) Tested here against a stand-in Ollama server; the real model was not run, so try Think on your four test notes.

- **Fixed: AI overview edge cases from the 1B tests (notes).** (1) A time written in the note now wins over the model's guess: "Meeting at 9:30 AM." is due tomorrow 09:30 (it was 19:58), also "at 6", "17:30", "friday 17:30"; the tiny-note line is "Reminder set for tomorrow 09:30." instead of "I will remind you ...". (2) A snippet pasted inside quotes is counted correctly ("Code snippet (Rust), 7 lines", not 8). (3) A list of 3+ bullets / dashes / numbers is shown as it is ("Checklist, 4 items" and the items, no model call), so no item is dropped and no to-do becomes "fixed"; a bullet glued to the previous line ("UPI error• pick up") is split. (4) Bad news is not left out: a decline with a % figure in the note ("net income fell by 3%", "the stock dipped 4%") that the model skipped is added from the note's own words; the prompt also asks for it. (5) A long note whose model answer had a headline only now also shows its "First, / Second, / Third," sentences. (`scripts/halcyon-notes.py`) Tested here against a stand-in Ollama server; the real model was not run, so try Think on your four test notes.

- **Changed: lyrics no longer need `spotify_player` (part 11).** `scripts/halcyon-music.py` now has several lyrics sources and `auto` tries them in this order: a `.lrc` / `.txt` next to the song file (offline; the player has to say where the file is), **lrclib.net** (free, no account, no key; the title, artist, album and length are the only things sent), **api.lyrics.ovh** (a second free site, last resort) and `spotify_player lyrics` when it is installed. Pick one with `halcyon-music.py source auto|local|lrclib|ovh|spotify` (`LYRICS_SOURCE` in `~/.config/Halcyon/music.conf`). `MusicMenu.qml` / `shell.qml` now hand the helper the title, artist, album, length and file address from MPRIS, so it works with the Spotify app, a browser, mpv, VLC and so on; in a terminal (`halcyon lyrics`) it asks `playerctl` when that is installed. Synced (timestamped) lyrics are shown as plain lines. The panel footer says which source answered. The **queue** is unchanged and still needs `spotify_player` (Spotify has no other queue we can read). No new process, no cache file, no log. Tested here against a stand-in lyrics server (exact match, search fallback that picks the version closest in length, a second site, no lyrics, local file, network down, no title, source setting).
- **New: "Later today" reminders (part 12).** A task can now be "later today" instead of having a clock time: Remind > **Later today** on a task, `notes due <n> later`, or the AI sees "later" / "this evening" in the note. Halcyon then sends a quiet **"Still on your list"** notification every `NOTES_NUDGE_HOURS` hours (default 3; Settings > Notes), only between `NOTES_NUDGE_FROM` and `NOTES_NUDGE_TO` o'clock (09 to 21), at most `NOTES_NUDGE_MAX` times (default 4), and it all ends at midnight. It stops the moment the task is done, deleted or given a clock time. "Later" said after 21:00 means tomorrow. The next nudge is counted from the one that was really sent, so a laptop that slept does not send a burst. It uses the same once-a-minute check as timed tasks, which is only switched on while a task is waiting. All settings also work from the terminal: `notes set NOTES_NUDGE_HOURS 2`.
- **New: the AI's comment under each note (part 13).** With Settings > Notes > Sort new notes into tasks on, the note is still saved first; then, in the background, the local model decides, and a short line appears right under the note in All notes: **"AI is thinking ..."** while it works, then **"AI · A chore for later today, so I will nudge you."** If the model gives no sentence of its own, a plain one is written from what it decided. If Ollama is not running the line says so (it never stays on "thinking": a crashed helper is replaced, and the window ignores a "thinking" older than 2 minutes). **Think** on a note's row asks again (`notes think <n>`); a note that already is a task keeps its state, only the line is renewed.
- **New: Adaptive update speed learns from you (part 14).** Besides what the machine is doing (busy, on battery), Adaptive now counts how often your Wi-Fi / Bluetooth picture really changes (a network or device connects or goes, a radio is switched; signal strength is not counted). After 3 days of use: under 1 change a day = looks up to **4x** less often, under 4 = 3x, under 12 = 2x, more = no change; never slower than one look a minute, and live again for 5 minutes after any change. Things you do in the island still show at once (they poke the feed). The data is two kinds of line (a day number, a time) in `~/.local/state/island/adaptive-net.tsv`, last 14 days only, no network names; Settings > Performance > Update speed has **Forget what it learned**. Done in the Rust feed (`src/hx/src/sysfeeds.rs`, `Learner`) and the same way in the fallback `quickshell/island/scripts/net.sh`; both read and write the same file. The bash version was tested here with made-up histories (no data, 2 days, quiet / medium / busy users, a change a minute ago, signal-only change ignored, file deleted = forget, the resulting waits). **The Rust part could not be compiled here (no Rust toolchain in my sandbox): please run `cargo build --release --manifest-path src/hx/Cargo.toml` once. If it fails, send me the error; until then `touch ~/.local/state/island/net-legacy` makes the island use `net.sh`, which has the learning too.**
- **What could go wrong, and how to undo it (parts 11 to 14).** Lyrics: a song a site does not know says "No lyrics found" (R reads again; `halcyon-music.py source spotify` goes back to the old behaviour). Nudges: `notes due <n> none` stops them for one task, `notes set NOTES_NUDGE_MAX 1` makes them rare. AI line: turn Settings > Notes > Sort new notes into tasks off and no new line appears. Adaptive learning: choose High / Medium / Low instead of Adaptive, or delete `adaptive-net.tsv`.

- **Fixed / updated: the stars in the panels now really follow the Desktop builder, and the tour covers everything.** An audit of the list of ideas against the tree found everything built except one thing: `NoteStars.qml` was still the older version (stars falling down, a vertical trail, always the same colours). It now slides the stars across the pane at three depths in the direction you chose, twinkles, gives the near ones a small glint, and sends an occasional shooting star across the way they drift. **Direction, speed, size and colour (accent / mix / white) are read from the Desktop builder's `deskStarDir`, `deskStarSpeed`, `deskStarSize` and `deskStarTone`**, so changing them there changes the panels too. Count, twinkle and the shooting stars are fixed per panel (they are small). `NotesMenu`, `ClipMenu`, `ShotMenu` and `MusicMenu` got an `opt` property and `shell.qml` passes `root.opt` to all four. Still the same cost: one Canvas, a timer only while the panel is open, stops when motion is turned down, and the panel star switch / safe mode still turn it off. Not run in Quickshell (balance check only): look at one panel with direction Left and with Up.
- **Tour updated (`features.json`).** New entries, shown once after the update (and in the full tour): **Notes, tasks and reminders** (Super + N, Tasks filter, the Add a note row, the optional model sorting, the stars), **Memory graph and Health**, **Timelines**, **Profiles**, **Safe mode** (Super + Alt + F12), **Blurred wallpaper on the lock screen**. **Lyrics and queue** now points at the music page itself (it opens it and puts the dark screen's hole on it). **One thing plays at a time** is rev 2 and now names the two extra options (bring the music back, wait 1 / 2 / 5 / 10 s). The Media page step mentions the two chips. Checked with the real `Tour.js` logic in Node: a first install shows 36 steps; an existing user who had the part 9 copy sees only the 8 new or changed ones.

- **New: lyrics and queue (part 10).** The music page (hover the music in the bar) has two new chips next to the artist, **Lyrics** and **Queue**. They open a panel on the side of the screen, in the look of the clipboard and new-note panels, with the two tabs: the lyrics of the song that plays, and what plays next (number, title, artist, length). Also `>lyrics` and `>queue` in the launcher, `halcyon music [lyrics|queue]` (the panel), and in a terminal `halcyon lyrics`, `halcyon queue`, `halcyon music status` (plain text, no island needed). Keys: Tab (or Left / Right) switches tab, Up / Down / Page Up / Page Down scroll, R reads again, Esc closes. When the song changes while the panel is open it reads again by itself after about a second. New files: `MusicMenu.qml`, `scripts/halcyon-music.py`. Changed: `MediaPage.qml`, `shell.qml`, `Launcher.qml`, `features.json` (one tour entry), `config/fish/functions/halcyon.fish` + completions, `README.md`, `Halcyon-FILEMAP.md`.
- **What I found out before building (part 10), and how it differs from the plan.** I read the real `spotify_player` source (github.com/aome510/spotify-player, current main) instead of guessing. (1) **Lyrics ARE possible without an outside website**: `spotify_player lyrics` exists (added in v0.24.0, April 2026) and asks Spotify itself through the session spotify_player already has. So the plan's fallback (queue only) was not needed and there is no third-party lyrics service. (2) **The queue** is `spotify_player get key queue` (old, in every release since the CLI was added); it returns the account's queue as JSON. (3) Both work **with or without spotify_player running**: when it is not running, the command starts a short-lived client of its own for that one answer, so the first read can take a few seconds. (4) Both ask **your Spotify account**, not one program, so they work when the Spotify app or a phone is the player. The panel shows the song the answer is about (the script's own title and artist) so a mismatch with the media page is visible. (5) **What it cannot do:** the lyrics are plain lines, no timestamps (the command prints no timing), so there is no line that follows the music; the queue is **read-only** (spotify_player has no "play this one now" command, so a row is not a button); a song Spotify has no lyrics for says so; the queue is whatever Spotify returns (the panel shows up to 50 of it).
- **How it runs (part 10).** No new background process, no file, no cache on disk, no log. `halcyon-music.py` is a one-shot command: the panel starts it when it opens, when the song changes and on R; while the panel is closed nothing runs (LazyLoader, no surface, no timer). Lyrics already read are kept in memory for the last 6 songs until the island restarts (reopening on the same song does not ask again); a failed read is never kept, so R retries. An answer is only kept when the song did not change during the read. It reads and displays; it never changes your Spotify account, queue or playback. Everything that can go wrong is said in words in the panel: spotify_player not installed, too old for lyrics (needs 0.24.0), not logged in (`spotify_player authenticate`), nothing playing, no lyrics for this song, timed out (25 s), unreadable answer.
- Tested here: `halcyon-music.py` against a stand-in `spotify_player` (lyrics: normal, "Lyrics not found", a title that contains " - " with two artists, blank-line runs squeezed, empty output, not logged in, nothing playing, old CLI with an old and with a new version number; queue: normal with junk and nameless entries skipped, invalid JSON, empty queue, a podcast episode, a length written as seconds + nanoseconds, 150 songs with the limit applied and clamped to 100, not logged in, nothing playing; plain-text output and exit codes; `status` for a new and an old version; spotify_player missing; a 30 s hang cut by the timeout). **Not run here:** the QML (`MusicMenu.qml`, `MediaPage.qml`, `shell.qml`, `Launcher.qml`; no Quickshell here, only a brace / bracket balance check and a check that every `pal` property it uses exists), the fish function and completions (no fish here), and **a real `spotify_player` and a real Spotify account**: the stand-in follows the source code of the command, not a live answer, and your installed version may differ (`halcyon music status` or `spotify_player --version`; lyrics need 0.24.0+). Three icons are from memory of the Material Design set and unchecked (the refresh button `0xF0450` in the panel, `0xF0387` and `0xF0CB9` for the two launcher rows): if one looks wrong, change the `glyph`.
- **What could go wrong, and how to undo it (part 10).** The panel only runs one command and shows what it says, so the worst case is a panel that says it could not read something. Lyrics for a song can be missing or in a licensed-out region; the queue can lag a second behind a skip (press R). If the chips crowd a long artist name, the name is shortened with "..." first. In a bash shell `halcyon lyrics` is not available (the bash shim only knows `safe-mode` and `profile`, like `halcyon shot` and `clip`): use `python3 ~/.config/Halcyon/scripts/halcyon-music.py lyrics`. To remove it: delete `MusicMenu.qml` and `scripts/halcyon-music.py`, the `MusicMenu {}` block, the `case "lyrics"` / `case "queue"` lines and the three IPC functions (`lyrics`, `queue`, `music`) in `shell.qml`, the two `ActionChip`s and the `openMusic` signal in `MediaPage.qml` (and the `onOpenMusic` block in `shell.qml`), and the two rows in `Launcher.qml`.

- **New: clipboard history panel (part 8).** `>clipboard` in the launcher (also `halcyon clipboard`, and the IPC call `clipboard`) opens a panel on the side of the screen, in the look of the new-note panel: what you copied lately, search as you type, Up / Down + Enter or a click puts a line back on the clipboard (`wl-copy`) and the panel leaves, the x on a row forgets that one, **Clear history** empties everything (it asks twice: the first click only changes the button to "Click again to clear"). Pictures show as "Image · png 800x600". If the watchers are off, or cliphist / wl-clipboard are not installed, the panel says so instead of showing an empty list, with a **Turn on** button for the watchers. New files: `ClipMenu.qml`, `scripts/halcyon-clip.py` (`json`, `copy`, `delete`, `clear`, `status`), `scripts/clip-store.sh`. Terminal: `halcyon clip` (list), `halcyon clip clear`, `halcyon clip status`.
- **How it differs from the plan (part 8).** (1) **No new background process.** The project already had a clipboard history: two `wl-paste --watch cliphist store` watchers, Settings > Startup & background > Clipboard history, and Super + V (a fuzzel picker). The panel is a second way to read that same history, so nothing was added to run. (2) **It is ON by default, as it already was**; I did not turn an existing default off. The Settings switch still stops the watchers at once. (3) **The list is its own panel, not rows inside the launcher's own list**: the launcher's layout is built around fixed-height command rows and I could not run Quickshell here to test a new mode in it, so `>clipboard` runs a command that opens the panel (same as `>all notes`). (4) The size cap is cliphist's own (750 entries); the panel shows the newest 80. Super + V is unchanged.
- **Privacy (part 8).** The watchers now run `scripts/clip-store.sh` instead of `cliphist store` directly. It checks the copy's types and drops it when the app marked it as a secret (`x-kde-passwordManagerHint`, which KeePassXC, Bitwarden, 1Password and similar set), before anything is written. It cannot know about a password copied from an app that does not set the hint (a plain text editor, a terminal): for those, use Clear history. `CLIP_GUARD=0` in the environment of the watchers turns the check off. `autostart-extras.sh`, `startup-conf.sh` and `startup-view.py` match the new command line as well as the old one, so the Settings switch and the Startup window still find and stop them. **After updating, the watchers that are already running are the old, unguarded ones until the next login**: turn Clipboard history off and on once in Settings > Startup & background to start the guarded ones now.
- **New: screenshot panel (part 9).** **Super + Ctrl + S**, `>screenshot`, `halcyon screenshot`: **Region**, **Window** or **Full screen**, then **Copy** (clipboard only, no file), **Save** (`~/Pictures/Screenshots/<seconds>.png`, the same place and name as before) or **Both**. The choice of Copy / Save / Both is remembered (`~/.local/state/island/shot.json`). R / W / F and C / S / B work as keys, Esc closes. The panel leaves first (about 0.4 s) so it is not in the picture. Region freezes the screen with `wayfreeze` when it is installed, like Super + Shift + S; Window lets you click any window you can see now (the shown workspace of each screen, and a shown scratchpad); Full screen takes the screen that has focus. A target whose tool is missing (`grim`, `slurp`, `wl-clipboard`) is greyed out, with the missing name shown. Esc during the selection cancels: no file, no clipboard change, no notification. A failed capture leaves no empty file, and two shots in the same second do not overwrite each other. New files: `ShotMenu.qml`, `scripts/halcyon-shot.py`. Terminal, without the island: `halcyon shot region|window|full [copy|save|both]`.
- **Decision made for you (part 9): the panel sits BESIDE your screenshot shortcuts, it does not replace them.** Super + Shift + S (`screenshot-area.sh`), Print and Super + Shift + Print are not touched, so nothing you rely on changes. To make the panel your main one, change `shotpanel` / `shotarea` in the shortcuts cheatsheet (both are remappable there). Super + Ctrl + S was free; it is the `shotpanel` entry in `Binds.js` and `hyprland/keybinds.lua`.
- Also: two new tour entries (`features.json`: `clipboardpanel`, `screenshotpanel`, shown once after the update), the Clipboard history description in Settings now names the panel and the password guard, `shell.qml` closes both panels with Esc / the global close and counts them as overlays. Files: `quickshell/island/{ClipMenu,ShotMenu,shell,Launcher,Settings}.qml`, `Binds.js`, `features.json`, `hyprland/keybinds.lua`, `scripts/{halcyon-clip.py,clip-store.sh,halcyon-shot.py,autostart-extras.sh,startup-conf.sh,startup-view.py}`, `config/fish/functions/halcyon.fish` + completions.
- Tested here: `halcyon-clip.py` against a stand-in `cliphist` / `wl-copy` / `pgrep` (list, image entries, copy, copy of a missing id, non-numeric id, delete, clear, 400 entries clamped to 300, junk lines, 900-character entries, cliphist not installed); `clip-store.sh` against a stand-in `wl-paste` (normal copy stored; password-manager hint dropped in three letter cases; `CLIP_GUARD=0`; no types; `wl-paste` missing still stores); `startup-conf.sh set CLIPBOARD 1/0` (starts the two guarded watchers, stops them, writes `autostart.conf`); `halcyon-shot.py` against stand-in `grim`, `slurp`, `hyprctl`, `wl-copy`, `notify-send`, `wayfreeze` (region / window / full in all three actions, cancel, no visible window, grim failing, same-second names, missing tools, unwritable folder with the freeze always released, corrupt `shot.json`, bad arguments). **Not run here:** the QML (`ClipMenu.qml`, `ShotMenu.qml`, `shell.qml`, `Launcher.qml`; no Quickshell here, only a brace / bracket balance check and a check that every `pal` property used exists), the fish function and completions (no fish here), real `grim` / `slurp` / `cliphist` / `wl-paste`, and a real password manager. The two launcher icons (`0xF014C`, `0xF0100`) are from memory of the Material Design set and unchecked: if one looks wrong, change the `glyph` in `Launcher.qml`.
- **What could go wrong, and how to undo it (parts 8 and 9).** Clipboard: if history stops filling after the update, run `ps aux | grep wl-paste` and check the watchers run `clip-store.sh`; the quick undo is to put `cliphist store` back in place of `bash ".../clip-store.sh"` in `autostart-extras.sh` and `startup-conf.sh` (or set `CLIP_GUARD=0`). A copy made at the same moment the clipboard changes again can be judged on the newer one's types (the guard asks wl-paste for the types after the copy). Screenshots: the panel only runs a script once per capture; if it misbehaves, Super + Shift + S and Print still work exactly as before. Remove the panel's key by setting `shotpanel` to `none` in the cheatsheet. To remove everything: delete `ClipMenu.qml` / `ShotMenu.qml` and their blocks in `shell.qml` (the `ClipMenu {}` and `ShotMenu {}` instances, the two `case` lines and the two IPC functions).

- **New: timelines elsewhere (part 6).** The Backup & safety timeline component (`DayTimeline.qml`) now also shows three things that have no due date. **Wallpaper** (top of Settings > Wallpaper): when the picture last changed, and "Changes by itself every N min" when that is on. **System update** (third rail in Settings > Backup & safety): when pacman last really replaced a package, amber after 60 days; it only shows the date, nothing is started from there, and Halcyon's own last install / update is in the line under it. **Focus streak** (top of Settings > Focus mode): days in a row you reached the goal, against your best streak, with "N to go" to beat it and the minutes still missing today. The goal is the Focus widget's "Minutes that count as a focus day" (25 when there is no Focus widget), so it matches the widget. The timeline has a new *plain* mode for this (no due date, never "late", the end ring is a goal, the words can be replaced); the Backup and Safety rails are unchanged.
- **How it reads data (part 6).** New `scripts/timeline.py` (`conf` = one line of JSON for Settings, `status` = plain text for a terminal) only READS: `/var/log/pacman.log` (last `[ALPM] upgraded` line, read from the end of the file in chunks), `~/.local/state/halcyon/installed-commit`, `~/.local/state/island/focus-days.json` and the Focus widget's goal in `settings.json`. It runs only while Settings is open (at open, every 60 s, and 1.5 s after the wallpaper changes), no new process while it is closed. The one new thing written: `island/scripts/wallpaper.sh` saves `~/.local/state/island/wallpaper-changed` (one epoch number) when the picture really changes; picking the same picture again is not a change, a failed write never stops the wallpaper, and the `wallpaper` state file that `palette.sh` reads keeps its format. Installs from before this have no such file: the date of the `wallpaper` state file is used (the rail says "Approximate") until the next change. "Last update" is unknown, and says so, where there is no readable `/var/log/pacman.log` (not Arch, log rotated away); nothing is guessed. Days are calendar days (a change at 23:50 is 1 day old at 00:10).
- **Hardened: blurred wallpaper on the lock screen (part 7).** The lock screen already had Settings > Power & lock > Lock screen background (Solid colour / Blurred wallpaper) with Blur and Tint (the "opacity": 0 % shows the wallpaper as it is). This part makes it safe to rely on, in `Lock.qml`: (1) the picture is only drawn once it has really loaded; until then, and for good if the file is missing or cannot be read, you get exactly the Solid colour look, with no empty full-screen texture behind it; (2) it fades in instead of popping (the wallpaper path is known a moment after the lock at login, or the wallpaper may change while locked); (3) a wallpaper whose file name has `#`, `?`, `%` or spaces no longer breaks the address; (4) the picture is loaded with `cache: false` (like the desktop wallpaper) and its source is emptied the moment the lock ends, so the decoded picture is let go on unlock instead of waiting in Qt's cache. The password box, PAM, the key-press rings, the constellation and the session lock itself are not touched. Off by default (Solid colour) as before; safe mode still forces Solid colour.
- Tested here: `timeline.py` against a fake home (no files at all, wallpaper stamp / file fallback / garbage and future stamps, a 3 MB pacman log with the last upgrade far from the end, a log with only a full-upgrade line, empty and binary logs, 8 focus-streak cases including today still to be earned, a gap, never reaching the goal, corrupt JSON and the widget's goal from `settings.json`), `wallpaper.sh` (8 cases: first pick, same boot, same file again, a new file, a missing file, `next`, unwritable state directory, state file format kept), and the lock screen's address expression for 7 awkward file names. **Not run here:** the QML (`DayTimeline.qml`, `Settings.qml`, `Lock.qml`; no Quickshell here, only a brace / bracket balance check), so look at the three timelines and lock the screen once with Blurred wallpaper on before relying on it.
- Undo (parts 6 and 7): the timelines add no setting; delete `~/.local/state/island/wallpaper-changed` to forget the stamp. Lock screen: Settings > Power & lock > Lock screen background > Solid colour. If the lock screen ever misbehaves, `loginctl unlock-session` from a TTY, or restart the island. Files: `scripts/timeline.py` (new), `quickshell/island/scripts/wallpaper.sh`, `quickshell/island/DayTimeline.qml`, `quickshell/island/Settings.qml`, `quickshell/island/Lock.qml`.

- **New: Safe mode (part 4).** `halcyon safe-mode` (or **Super + Alt + F12**, or Settings > Performance > Profiles & safe mode > Turn on safe mode) switches off blur, shadows, window animations, stars, island motion and the other heavy effects (moving stars, music bars, accent cycling, the blurred lock wallpaper, the tree view's constellation and dots) and reloads the island. **Back to normal** (`halcyon safe-mode back`, the shortcut again, or the Settings button) puts your earlier values back exactly, keys that did not exist included. Your values are saved first in `~/.local/state/island/safe-mode.json`. It is a script (`scripts/halcyon-fx.py`), not part of the island, so it works when the island is stuck or not running and from a TTY: it finds the Hyprland session by itself, pushes the blur / shadow / animation switches straight to Hyprland, asks the island to reload, and if the island does not answer it reloads Hyprland and restarts the island (start-shell.sh brings it back). No new running process: it only writes settings and reloads. The bar, the launcher, the lock screen's password box and every other setting are not touched. Files: `scripts/halcyon-fx.py`, `hyprland/keybinds.lua`, `Binds.js`, `Settings.qml`, `shell.qml`, `config/fish/functions/halcyon.fish` + completions, `scripts/user-setup.sh` (a `halcyon` shim in `~/.local/bin` so it also works in bash).
- **New: Profiles (part 5).** Settings > Performance > Profiles & safe mode: **Custom / Work / Gaming / Battery / Night**, one switch for stars, blur, island motion, screen brightness and the top bar; terminal: `halcyon profile <name>` (`halcyon profile list` shows what each one does). Work = no stars, blur on, fast motion. Gaming = no stars, no blur, no motion, top bar off (it only changes the look; Gaming mode on Super + F10 still does the CPU / GPU / helper side). Battery = no stars, no blur, fast motion, brightness 40 %. Night = stars on, brightness 15 %. The first time you leave Custom your own values are saved (`profile.json`, brightness included); switching between profiles keeps that first copy, and Custom brings it back. Defaults can be changed in `~/.local/state/island/profiles.json` (`{ "battery": { "brightness": 30 } }`); values outside the allowed range are refused. A profile is not applied while safe mode is on. The island reads the changed file in place (new IPC `applyFx`), no restart; going back to Custom restarts the island only when needed. Brightness needs `brightnessctl` and a backlight; without them the rest still applies.
- Tested here: `halcyon-fx.py` against a fake home with stand-in `quickshell`, `hyprctl`, `pgrep`, `pkill` and `brightnessctl` (round trips restore settings.json exactly, repeated `on` keeps the first backup, corrupt settings / backup files, island not answering, profile overrides). **Not run here:** the QML (`shell.qml`, `Settings.qml`) and the fish function / completions (no Quickshell, no fish), and the real Hyprland reload.

- **New: memory graph in Startup & processes > Health (part 3).** A line graph of all Halcyon parts together (one point per 5 s poll, about the last 10 minutes), and under it the Halcyon parts that grew most since the window opened ("from -> to, +N MB"), so a step up can be matched to its cause instead of guessed. History lives only in the open window and is dropped when it closes; no new process, no file, no extra polling. File: `StartupWindow.qml`.
- **New: "Add a note" row on the Notes & agenda desktop widget (part 2).** A button row at the bottom (Widget builder > Notes & agenda > on by default) opens the Super + N panel; the widget itself never takes keyboard input, so the desktop stays stable. Tasks with a time show it after the text. Files: `WNotes.qml`, `WidgetData.js`, `shell.qml` (`deskAct("notes")`).
- **New: tasks in Notes (part 1 of the notes/tasks work).** Settings > Desktop > Notes has a switch, "Sort new notes into tasks" (off by default).
  When it is on, Super + N still saves at once; a background `notes sort <id>` then asks your local Ollama model (the one `ai` uses) whether the note
  is a task and when it is due: "call mom at 6" is a task due 18:00, "idea: dark theme for the lock screen" stays a note. The second setting picks
  *Ask me first* (the note shows "Make task / Keep as note") or *Do it automatically*. If Ollama is not running nothing happens to the note.
  The model's time is only used when the note contains a digit or a time word, a bare "at 6" is read as 18:00, and a time that is past is dropped.
- **New: Tasks filter and reminders in the All notes window.** Filters are All / Open / Tasks / Pinned / Done; a task shows "Due Today 18:00" (red once
  overdue); each row has Task / Note and Remind (30 min, 1 hour, 18:00, tomorrow 09:00, none). The latest-notes list in the Super + N panel shows the time too.
- **New: `halcyon-notes-due.timer`.** The existing `halcyon-remind.timer` only looks once a day at 10:00, which cannot catch "6 pm", so tasks get a sibling
  that runs `notes remind-check` once a minute **only while a task with a time is waiting** (`notes` enables and disables it itself). A reminder missed while
  the PC was off is shown in the first minute after login. It sends a normal notification once per task.
- **New: CLI.** `notes task|due|tasks|sort|accept|dismiss|remind-check|conf|set` (see the top of `scripts/halcyon-notes.py`); `notes due 2 18:00`, `+30m`,
  `tomorrow 09:00`, `none`. A note that merely starts with one of these words ("notes set the table") is still just a note.
- Files: `scripts/halcyon-notes.py`, `quickshell/island/NotesMenu.qml`, `Settings.qml`, `systemd/halcyon-notes-due.{service,timer}`, `install.sh`
  (installs the two units, keeps `notes.conf`). Not run in Quickshell here: the script was tested against a fake Ollama, the QML was not.

- **New: SUPER + N is a new-note panel.** It opens a small panel (520 px, the console's size) on the side of the screen over your windows, with the
  cursor already in it: type, press Enter, the note is saved, "Saved" shows for a moment and the panel leaves. Shift + Enter makes a new line, Esc
  or a click outside closes it. It opens on the opposite side from the pop-out console (same height), so the two never overlap. The latest three notes
  are listed under the text; the "All notes" chip opens the full list.
- **New: `>all notes`.** The launcher's commands got a second entry for the whole list (also `halcyon notes-all` and `quickshell ipc call island
  notesAll`): search, filter (All / Open / Pinned / Done), pin, tick off, copy, delete, clear completed. Times read "Today 14:30" instead of a raw
  date. No emoji anywhere in the notes; the old clipboard / pencil / star glyphs are text buttons now.
- **New: falling stars in the notes** (`NoteStars.qml`). One Canvas with drifting, twinkling stars, trails on the near ones and an occasional shooting
  star. It only runs while a notes window is open and visible, and stops when motion is turned down; it follows Settings > Constellations.
- **Fixed: Esc did nothing for the notes overlay** from the global close (`shell.qml` called `notesMenu.close()`, which did not exist).
- **New: Backup and safety check timelines** (`DayTimeline.qml`, Settings > Backup & safety, top of the group). The two rings became one timeline each:
  last time, a marker for today, the day it is due, a tick per day (quarters for long intervals); amber when it is due, green while a scan runs.
  The backup got a countdown too: `remind.sh conf` gained `backupSince`, `backupNext` (days until the reminder, -1 = none) and `backupSpan`.
- **Fixed: a stacked music title jumped to the left when its visualizer hid.** Widgets stacked above / below each other share the width of the widest
  one, but a member that was hidden (a visualizer with nothing playing) stopped counting, so the title under it shrank to its own text and slid
  to the left edge of the stack. A hidden member now keeps its share of the width; only a widget you switched off drops out
  (`DeskWidgets.groupW`).
- **New: SUPER + arrows move between windows.** There was no key to move focus, so in the scrolling (niri) layout you could not get back to what
  you opened earlier. SUPER + Left / Right / Up / Down now focus the window next to you (in Scrolling the view follows), SUPER + SHIFT + arrows
  move the window. Both are in the cheatsheet and can be remapped there (`focus_*`, `movewin_*`).
- **New: one thing plays at a time.** `scripts/audio-focus.sh` watches every player on the media bus (Spotify, browser tabs, mpv, VLC ...). When
  something starts while another player is going, the other one is paused; when it stops or ends, only the players the script paused start again.
  A player you paused yourself is never touched. Switch: Settings > Startup & background > One thing plays at a time (`AUDIO_FOCUS` in
  `autostart.conf`, started at login by `autostart-extras.sh`, needs playerctl).
- **New: safety check clock.** Settings > Backup & safety shows two rings: days since the last scan and days left until the next one (the automatic
  run, or the reminder when only that is on), plus whether a scan is running right now. `remind.sh conf` gained `safetySince`, `safetyNext`,
  `safetyNextKind` and `safetyRunning`; `remind.sh status` prints the next scan. The automatic-run block is no longer hidden under Advanced.
- **New: Shortcuts in Tree or Pages.** The cheatsheet now has the same two views as Settings: the tree, or Pages (a menu of groups on the left, one
  group at a time). Chip in its header, or Settings > Look > Shortcuts layout (`opt.keysStyle`). Search shows every match in both.
- **Tour:** new steps for window arrows, one-thing-at-a-time audio and the safety clock; the shortcuts step is re-announced (rev 2).
- **New: choose your shell prompt in the installer.** `install.sh` now asks once, when it finds another prompt setup on the machine (your own
  `~/.config/starship.toml`, a Starship started from your shell config, the CachyOS fish prompt, oh-my-posh, powerlevel10k): *Keep mine* (Halcyon
  does not touch your prompt, your `starship.toml` or fish's Starship start-up), *My layout, Halcyon colours*, or *Halcyon's prompt*. The answer is
  saved (`PROMPT` in `install-choices.env`), so `update.sh` and later installs never ask again; `./install.sh --choose` asks again, and
  `--prompt keep|colours|halcyon` answers it on the command line. The first install of Halcyon on a machine asks everything once by itself (no
  `--choose` needed). Whatever a switch replaces is saved next to the file (`starship.toml.before-halcyon`, `starship.toml.halcyon`), so every
  choice can be undone. Before this, a first install replaced an existing `starship.toml` with Halcyon's.
- **Fixed: the sysmode badge checked for sysmode even when it is not installed.** Halcyon's prompt ran a small shell before every prompt to read the
  sysmode mode, which on a machine without sysmode (and a slow start) ended in "Executing custom command ... timed out" warnings. While sysmode
  is not installed the badge is now `disabled = true` (Starship starts nothing for it) and it is switched on again by the next install / update
  once sysmode is there (`starship_sysmode_sync` in `scripts/app-themes.sh`).
- **New: several widgets can follow the same one.** In the Widget builder > Link, two (or more) widgets can now be linked to one widget. On the same
  side of it they line up one after the other instead of lying on top of each other (a visualizer and a song title both below the clock, two
  boxes to the right of the workspaces ...); a new "Place in line" row says who comes first. They keep sharing size (and, stacked, width), and
  the whole group still moves and resizes together (`WidgetData.siblings` / `setLinkSlot`, `DeskWidgets.linkHostOf`).
- **New: more widget styles.** Special workspaces now come in ten looks (added: Outline, Segmented, Tabs, Labels, Rings, Stack, Glow), Workspaces
  get Squares and Outline, Month calendar gets Compact grid and Dot grid, Horizon gets Sun arc and Hour ticks, Breathe gets Ripples and Bars,
  Quick toggles gets List, Outline and Bare icons, and App shortcuts gets Outline and Bare.
- **Removed: Passman (the password manager).** `passman`, its automatic save / fill watcher, the Brave / Chromium extension and
  helper, the Settings toggle, the launcher and console entries and the tour page are gone. The installer no longer pulls in
  python-gobject, at-spi2-core or wtype for it. An old `PASSMAN_AUTO` line in `autostart.conf` is dropped the next time that file
  is written. (Your own vault files are not touched by an update; `apply-update.sh --purge-vault` deletes them.)
- **New: pick the AI advisor's model from Settings.** Settings > Performance > Optimization & Suggestions now has an "AI advisor
  model" drop-down: the models installed in Ollama (click one to use it), then a list scraped from ollama.com/library (click one
  to download it; it becomes the model in use when the download finishes). The list is sorted so what fits this PC's memory
  comes first, marks the best fit per family, shows a progress bar with Cancel, caches for 12 h and falls back to a built-in list
  offline. New `scripts/ai-models.py` does the work; the choice is saved in `ai-advisor.conf`, the file `advisor model switch`
  already used, so `ai`, `advisor --llm` and the console all follow it.
- **New: "Special workspaces" desktop widget** (Widget builder > Desktop). The scratch, music, chat and monitor workspaces as
  buttons: lit while shown, a count of the windows hidden in each, a click shows / hides one (music and chat start their app the
  first time, like SUPER+M / SUPER+D). Layouts: pills, icons, dots, outline, segmented, tabs, labels, rings, stack, glow.

- **Linked widgets stay on screen.** A widget linked to the LEFT of another one (uptime next to the workspaces) used to grow off the left edge
  when its text got longer ("9h" -> "2h 59m"). The first widget of a chain is now kept far enough from the screen edge for everything linked
  to it (`DeskWidgets.chainExt`, `WidgetHost.chainX`), so the whole group slides over instead.
- **Mixed wallpaper patches.** Where the picture behind a widget is part bright, part dark (pink next to black), the widgets now use light text
  with a strong dark outline (like subtitles) instead of dark text that vanished on the dark part. `Pal.lumSpreadAt` / `lumMaxAt`.
- **`hx ctl` no longer leaves a `pactl subscribe` behind** each time the panel closes (PDEATHSIG).
- **Widgets stay readable on bright wallpapers.** `palette.sh` now also writes a 12 x 8 luminance grid of the wallpaper; each desktop widget
  looks up the brightness right behind itself (`Pal.lumAt`) and, when it is bright and the widget has no dark box, switches its text, lit colour,
  bars and tracks to a DARK shade of the wallpaper accent with a light halo (`WidgetHost.qml`: `onBright`). Dark wallpapers are unchanged.
  Only the "Theme" text colour adapts: a text colour you picked yourself is left alone.
- **`advisor leaks`**: new `scripts/halcyon-leaks.py` reads a leak-watch log and computes what leaked (steady leak vs one-time jump vs stair-steps,
  open-file / thread growth, process clones, zombies; kernel threads ignored). `advisor leaks watch 30 60` records and analyses; the local model
  only explains the verdict. The agent (`ai`, `advisor "..."`) got two tools: `leak_report` and `start_leak_watch`.

# Changelog

## Bug check, round 11: the password manager and the browser helper

- Fixed: **Copied passwords ended up in the clipboard history.** The clipboard history (`wl-paste --watch cliphist store`, shown by SUPER+V) stored every password `passman get` / `add` / `gen` copied, in plain text on disk; the 30-second clear never reached it. Passwords are now copied with `wl-copy --sensitive`, which tells the history tool to skip them (older `wl-copy` without the flag falls back to the plain call). `passman status` warns when `wl-copy` is too old and cliphist is installed (`scripts/halcyon-pass.py`).
- Fixed: **`passman import` took minutes and destroyed its own backup.** Every row decrypted and re-encrypted the vault several times (40 rows: 21 s; a few hundred logins: minutes) and overwrote `vault.enc.bak` at every row, so afterwards the backup held the vault from one row before the end instead of from before the import. The file is now merged in memory and the vault is written once (40 rows: 0.5 s) and the backup is the vault as it was before. A file that is not a password export now says so and changes nothing.
- Fixed: **A question left open froze every other writer.** `passman add` ("Replace it?"), `edit` (new password) and `del` ("Delete?") asked while holding the vault lock, so the browser's "save this login?" and the island waited until someone answered. The questions are now asked first and the lock is only held while writing (tested: another writer finished in 0.4 s while a delete prompt was open).
- Fixed: **`passman add github -g 32`** took the 32 as the user name; the number right after `-g` is the length now.
- Fixed: **Browser helper "never ask for this site" list**: two tabs answering at once could lose one, and the file was readable by others until the write ended. It is written atomically, under the vault lock, and private from the first byte (`scripts/passman-host.py`).
- Checked, nothing to change: the vault format and key handling, the openssl calls, the clipboard clearing, `passman-host.py` message handling. Known limit, not changed: the key sits next to the vault (`~/.local/state/island/.vault.key`), so the vault is only as safe as that folder; there is no master password.

## Bug check, round 10: scripts the earlier rounds had not looked at (recording, notes, layout, caffeine, gaming mode, hotspot)

- Fixed: **Screen recording could kill an unrelated program.** The recorder's process number was saved in `~/.local/state/island` (it survives a crash or a reboot) and trusted as it was. When that number belonged to another program by the next time, `status` said "recording" and `stop` sent it Ctrl+C, TERM and then KILL. The pid files now hold the number and the process start time, and a process that does not match is never signalled (`scripts/screen-record.sh`).
- Fixed: **Screen recording with sound: the sound came late.** The sound recorder is started first and waits 0.3 s, so its first moments were older than the first picture; joined as they were, everything you heard was about half a second behind what you saw. The launch gap is now cut off the start of the sound when the two are joined.
- Fixed: **Recording: the sound was lost or hidden.** If no picture came out, the sound stayed in the hidden state folder forever, and when joining failed the message pointed at a file in that folder. The sound is now saved as an `.m4a` next to the recording in both cases.
- Fixed: **Notes lost entries when two things wrote at once** (the notes menu, the notes widget, `notes ...` in a terminal). Each one read the list, changed it and wrote it back, all through one shared temp-file name; 30 simultaneous adds kept 5 notes. Writers now take a lock and use a temp file of their own, and two notes added in the same millisecond no longer get the same id (`scripts/halcyon-notes.py`).
- Fixed: **SUPER+ALT+T could stop switching.** The layout was read from `general.lua` only; with the file missing, unreadable or saying something else, every press chose the same layout. It now reads the layout Hyprland is really using, keeps a symlinked `general.lua` a symlink, and says so when Hyprland did not take the change (`scripts/toggle_layout.sh`).
- Fixed: **Gaming mode left the NVIDIA GPU on maximum performance** after switching off (it set `GPUPowerMizerMode=1` and never put it back). It now reads the mode first, sets it only when it could read it, and restores it on `off`. The saved state is also written private, never reused if it is a symlink or someone else's file, and the unit names read back from it are checked (`scripts/gamemode.sh`). The comment at the top now lists the real default `KILL` list (it includes `dropbox nextcloud`).
- Fixed: **Caffeine**: `caffeine.sh on 30` while it was already on did nothing, so "30 minutes" after "until I turn it off" (or the other way round) kept the old length. A new length now replaces the running one; the same request still does nothing. A typo in the minutes now says so instead of "is systemd-run available?" (`scripts/caffeine.sh`).
- Fixed: **Lab hotspot used a fixed, published password** (`password123`) and kept a stale `Halcyon-Hotspot` profile that could pile up or keep an old SSID / password. The password is now random, made on first use and kept in `~/.local/state/island/hotspot-pass` (mode 600); `HOTSPOT_PASS` still overrides it and `hotspot.sh status` prints it. Our own old profile is removed before a new one is made (`scripts/hotspot.sh`).
- Fixed: **Settings did not load: "Q is not a type" in `WidgetBuilderWindow.qml`.** The two "?" markers of the Link section used a file-local helper type (`component Q: HelpTip`); Quickshell could not resolve it when the type is used inside another component's body, which stopped Settings and with it the whole shell. They now use `HelpTip` directly, each with its own id (`quickshell/island/WidgetBuilderWindow.qml`).
- Checked, nothing to change: `brightness.sh`, `backlight.sh`, `ws-nav.sh`, `idle.sh`, `lock.sh`, `refresh-ram.sh`, `toggle_touchpad.sh`, `remind.sh`, `focus.sh`, `focus-log.sh`; every shell script, Python file and `.js` file in the project passes a syntax check.

## Bug check, round 9: system usage, quick toggles, background apps, Wi-Fi scripts

- Fixed: **System usage widget rebuilt every row on every reading.** Each new CPU / RAM / temperature reading made a new list, so every bar, ring and label was destroyed and made again, and the bars could never slide to their new value (the animation was written but never ran). The rows now stay alive and only their numbers change (`WSysmon.qml`). A very large text size could also give the bar a negative width; it has a floor now.
- Fixed: **Quick toggles and App shortcuts rebuilt every button** each time the Wi-Fi / Bluetooth reading or any switch changed, which dropped hover and press and skipped the colour fade. Each button now asks for its own state (`WToggles.qml`). A button with a long name is as wide as its (cut-off) text, not wider.
- Fixed: **Background apps: "Open" did nothing for tray apps that only offer a menu.** It now opens that app's menu (`BgApps.qml`).
- Fixed: **A Wi-Fi network with a colon or backslash in its name** (for example "Cafe: Guest") was shown as `Cafe\: Guest` (`scripts/net.sh`).
- Fixed: **Connecting to a saved Wi-Fi network with a colon or backslash in its name** was not seen as saved, and if that connect failed the script deleted the profile "it had just created" - which was the saved network and its password. Only a Wi-Fi profile with exactly that name counts as saved now, and a profile that was already there is never deleted (`scripts/wifi-connect.sh`).
- Checked, nothing to change: `WWorkspaces.qml`, `Osd.qml`, `Visualizer.qml`, `TrayMenu.qml`, `scripts/stats.sh`, `gpu.sh`, `bt-set.sh`, `audio-set.sh`.

## Bug check, rounds 4-8

- Round 4: Uptime reads `/proc/uptime` once and lets the clock carry it (no process every minute, no drift after suspend); Weather clears the old city at once and asks again when the place changed during a request; Notes: the heading date follows midnight, a failed read keeps the lists, lists only swap when they differ, the calendar is read once a minute; Focus updates the streak only when the day changes and refreshes when visible again; Horizon refreshes when visible again (`WNet.qml`, `WWeather.qml`, `WNotes.qml`, `WFocus.qml`, `WHorizon.qml`).
- Round 5: Volume / Brightness: a fast wheel builds on the value just asked for, an unread value counts as 0 (no NaN), the history style records only while visible (`WMetric.qml`); the Utilities box has the same NaN guard and says "1 app" (`WBoxes.qml`); Breathe: every breath starts fully closed / open (`WBreathe.qml`).
- Round 6: the Utilities box asks for the volume / brightness reader (`WidgetData.js`); "Reset the desktop" looks at every star setting (`DeskSpots.js`); its sliders follow the mouse and send one value per percent (`WbLevel.qml`).
- Round 7: the bar builder's "Move X to the right / left" moves the widget straight across (`BarLayout.js`); "Clear all" from the keyboard resets the unread bar (`Notifs.qml`); the stars drift by real time (`DesktopStars.qml`); a text field sends its value once (`WbText.qml`).
- Round 8: shortcuts with Shift + a number or symbol can be chosen (`Binds.js`, `Cheatsheet.qml`); the notes menu queues every change, re-reads when a read was asked for during another, and keeps the list after a failed read (`NotesMenu.qml`).

## Linked widgets: right of / left of

- New: a link can also put a widget **Right of** or **Left of** the one it follows (centred on it, each keeps its own width), so two widgets side by side - uptime and workspaces - are pushed along instead of overlapping when one gets wider ("9h" becoming "1d 11h"). Above / Below still share one width. The Link section of the Widget builder has the two new choices and two "?" explanations (`WidgetData.js`, `DeskWidgets.qml`, `WidgetHost.qml`, `WidgetBuilderWindow.qml`).

## Bug check, round 3: clock and date widgets

- Fixed: **Clock, Month calendar, Text & greeting and Moon showed old values for a while after coming back on screen** (for example after a full-screen app): their timers only fired at the next tick, up to a minute (clock, month), 5 minutes (greeting) or 10 minutes (moon) later. They now refresh the moment the widget is visible again (`WClock.qml`, `WMonth.qml`, `WText.qml`, `WMoon.qml`).
- Fixed: **Clock: switching "Seconds" on** only took effect after the next minute tick, because the interval was reset from inside the tick. It is a binding now.
- Faster: **Month calendar** rebuilt its 42 cells (and the week numbers) every minute; it now does it once a day. **Text & greeting** only updates when the hour changes.

## Bug check, round 2: wallpaper changes, widget builder, desktop editor grid

- Fixed: **changing the wallpaper again while the previous change was still finishing** wiped the name of the new picture, so the colours were then worked out from an empty path. The new picture now keeps its name until it is shown (`Wallpaper.qml`). Switching the wallpaper picture off in the middle of a change no longer leaves a stale name that blocked choosing the same picture later.
- Fixed: **Widget builder: a change made right after a slider was lost.** The slider's last value waits up to 70 ms for the timer; a click in that time was computed from the old layout and then overwritten by the slider's value. Every edit now starts from the newest layout (`WidgetBuilderWindow.qml`).
- Faster: **the desktop editor's grid is one canvas** instead of a rectangle per line (about 150 items at 20 px) (`DeskGuides.qml`).
- The desktop editor's hint now says that linked widgets move and resize together.

## Bug check: widget links, desktop widgets, console

- Fixed: **removing a widget that others followed** left them pointing at its id, and the next new widget got the same id and was followed by accident. They are freed on removal. Duplicating a linked widget gives a free copy (it used to sit exactly on top of its sibling), and "Put it at" on a linked widget moves the first widget of its chain (it used to do nothing).
- Fixed: **resizing a widget with the corner dot** made it jump back to the old size for a frame when you let go.
- Fixed: **Console**: a command ending in a `# comment` was a syntax error (the closing bracket was swallowed), and the answer of a command you had just replaced could appear in the new one's box.
- Faster: **the desktop widgets are only re-bound when the saved widgets really change** (before, every setting you changed anywhere made every widget re-evaluate), and the link bookkeeping does nothing at all while no widget is linked.
- Checked: no QML file in the project has a signal that clashes with a property's change signal (the error that stopped Quickshell earlier).

## Linked widgets, Desktop builder without the widget placer

- New: **Link** (Widget builder > pick a widget > Link > "Follow"). A linked widget sits straight below or above the one it follows (the gap is a slider), takes its size and shares one width with it: every widget in a chain is as wide as the widest of them, so the visualizer and the song title line up edge to edge whatever the title length. Dragging, resizing (wheel) or nudging any of them on the desktop moves or resizes the whole chain; a linked widget is picked by a click and shows "linked to ...". Removing the leader frees the others. Cycles are refused. Visualizer (all styles but the circle) and Now playing (card, compact) stretch to the shared width; Now playing "minimal" and "cover" and every other widget keep their own look, centred (left-aligned for the other widgets) in the shared width.
- Changed: **Desktop builder**: the widget placer is gone. The picture of the screen now shows only the boxes and their corners (no Widgets / Boxes switch); widgets are placed with "Place them on the desktop".

## Colour depth, no-box widgets, console, blur on every window, Thunar live sync

- Fixed: **Quickshell did not start** ("Duplicate signal name" in `DesktopEditor.qml`): the signal `optChanged` clashed with the automatic change signal of `property var opt`. Renamed to `optToggled` (also in `shell.qml`).
- New: **Colour depth** (Widget builder > Look, default 50 %): pours the wallpaper accent into the box, the hairline, the quiet text and the bars. Readability no longer washes the accent towards white as much.
- Fixed: **"No box" had a black box behind it.** The Readability backing is gone; "No box" draws nothing, the letters only get a thin outline.
- Fixed: **Console widget**: commands that never end are stopped after a few seconds (shown with what they printed), a new command replaces the running one at once, "Most lines" applies immediately, an empty answer reads "(no output)", `TERM=dumb` / `COLUMNS` keep tools inside the box, and no dark frame or scanlines on "No box".
- New: **blur on the power menu, Settings, the builders, the wallpaper gallery, Startup & processes, the calendar, the shortcut sheet and the command tree** (`hyprland/rules.lua`). It follows Resource use: Low has no blur (stronger dim on the power menu), Medium a light blur, High the full one.
- New: **Thunar and other GTK apps repaint live** when the wallpaper (palette) changes: `gtk-theme.sh` now makes running GTK 3 / 4 apps re-read their CSS (only when the colours really changed). `~/.local/state/island/gtk-live = off` turns it off.
- Removed: the 7b model option from the AI advisor (`llama3.1:8b` is the recommended one).

## Desktop editor: dragging fixed, grid and measuring, readable widgets, Console and corner-box widgets, switch-off

- Fixed: **widgets could not be dragged in the desktop editor.** In `WidgetHost.qml` the drag handler declared `var sx` / `var sy` for the snap results; QML hoists `var`, so they shadowed the MouseArea's own `sx` / `sy` (the press position) and every move came out as `NaN`. The press position is now `pressX` / `pressY` and the snap results `snapX` / `snapY`.
- New: **a view bar in the desktop editor** (above the toolbar), remembered between sessions: **Grid** (20 / 40 / 80 / 120 px, lines start at the margins, every 5th stronger) with **Snap to grid**, **Centre** lines (they turn pink when the picked widget is exactly centred), **Thirds**, **Safe area** (the margin box) and **Measure**.
- New: **measuring, like a design tool.** The picked widget shows the gap in px to the screen edge or the next widget on each side (edge lines in the accent colour, widget-to-widget gaps in the second colour), a cross through its middle when it is level with the screen's middle, and a label with its size and place (`382 x 170 at 24, 96`). Live while you drag.
- New: **Readability** (Widget builder > Look, default 60 %). It lifts the lit colour toward white, brightens the quiet text, draws a thin outline round every letter and, with "No box", puts a dim backing behind the widget. Existing widgets get it automatically. **Text colour** also has **White** and **Dark** now.
- New: **Console widget** (Desktop group): a terminal-style box that shows what a command prints, run again every N seconds only while it is on screen. Looks: Terminal, Window, Glass lines, Retro green (scanlines), Minimal. A click opens the real console. It shows output only; it does not take the keyboard.
- New: **Utilities box** (Wi-Fi, Bluetooth, Do not disturb, volume, brightness, power; List / Tiles / Slim bar) and **Background apps box** (the tray apps; List / Icons / Count only) as widgets.
- New: **switch a widget off without deleting it**: "Switch off" above a picked widget in the editor, or "Show this widget on the desktop" in the Widget builder. A switched-off widget is not drawn and none of its readers run. **All desktop widgets** (Widget builder) is a master switch (`opt.deskWidgetsOn`).
- Changed: **blur behind special workspaces is on** (`blurSpecialWs = true` in `variables.lua`). It was off since the memory pass and did not depend on the resource level. Set it to `false` to turn it off again. Windows inside need some transparency to look frosted.
- Files: `WidgetHost.qml`, `WidgetData.js` (`contrast`, `off`, `setOff`, `measure`, `gridLines`, three new types), `DeskWidgets.qml`, `DesktopEditor.qml`, `WidgetBuilderWindow.qml`, `WLbl.qml`, `WIco.qml`, `WBase.qml`, `Wallpaper.qml`, `shell.qml`; new `DeskGuides.qml`, `DgTag.qml`, `DgGap.qml`, `WConsole.qml`, `WBoxes.qml`, `WbLevel.qml`, `WbRow.qml`.

## Dots instead of counts; widgets snap to each other

- Changed: **notification and background-app indicators are dots, not numbers.** `Badge.qml` is a small dot by default (`dot: false` brings the count back), which covers the Notifications tab in the drop-down header and the Background apps header. The unread hint in the screen corner (`Notifs.qml`) and the background-apps hint in the corner (`shell.qml`) are plain dots too, and in the bars (`NotchBar.qml`, `CustomBar.qml`, `Home.qml`) the background-apps icon carries a dot on its corner instead of "icon + number". The Settings entry is now "Background apps dot".
- New: **dragging a widget snaps to the other widgets**, not only to the screen middle and edges. Its edge or middle lines up with another widget's (guide line shown), and next to a neighbour it stops exactly **16 px** away (`snapGap` in `WidgetHost.qml`), so rows and columns come out even. Hold **Alt** or **Ctrl** to move freely.
- New: **arrow keys nudge the picked widget** 1 px, **Shift + arrow** 10 px (Desktop editor).
- Fixed: **resizing moved the widget.** Positions are stored as a fraction of the room left on the screen, which changes with the widget's size, so the corner-dot resize (and the wheel) slid the widget while you did it and wrecked any gap you had just set. The top-left corner now stays put (`WD.setScalePos`).
- Files: `WidgetData.js` (`snapAxis`, `setScalePos`), `WidgetHost.qml`, `DeskWidgets.qml`, `DesktopEditor.qml`, `Badge.qml`, `Notifs.qml`, `NotchBar.qml`, `CustomBar.qml`, `Home.qml`, `Settings.qml`, `shell.qml`.

## The local AI can now manage the system, not only suggest; Add-a-widget button no longer leaks

- Fixed: **"Add a widget" overflowed its pill in the Widget builder** (`WidgetBuilderWindow.qml`, `ActionChip.qml`). The left column is ~222 px wide; "Add a widget", "Copy" and "Remove" on one line squeezed the first button to ~46 px and its label spilled out. "Add a widget" now has its own full-width line and Copy / Remove share the next. `ActionChip` also clips and elides its label when it is made narrower than its text, so no chip can spill again anywhere.
- New: **the AI is now an agent** (`scripts/halcyon-agent.py`, used by `ai` and `advisor "<question>"`). It calls tools, reads what came back, and carries on until it can answer.
  - *Read* tools run at once and change nothing: system status, failed services (with diagnosis), service status, journal, top processes, disks, network, Hyprland state, Quickshell log, pacman updates / orphans, read a file (secrets refused).
  - *Action* tools show the exact command and wait: `y` / `N` / `a` (yes for the rest of the session). Restart / start / stop / enable / disable / mask / reset-failed a unit, kill a process, trim RAM, volume, brightness, Halcyon desktop modes, clean the package cache, and `run_shell` as a last resort. Risky ones (kill, stop / disable / mask, cache clean, shell) ask every time; `--yes` / `/yes` only pre-approve the low-risk ones.
  - After an action the tool re-checks the result and the model is given the new state plus the journal if it failed, so it reports what really happened and finds the cause instead of repeating the command.
  - Guard rails: protected units (dbus, logind, journald, network, display manager ...) cannot be stopped; `run_shell` refuses `rm -rf /`, disk formatting, `dd` onto devices, `curl | sh`, reboot / poweroff, sudoers / account edits and removing core packages.
  - Works with tool-capable models (`llama3.1:8b`: `advisor model switch 8b`), also with models that write the call as JSON text. A model without tool support falls back to chat and each ```bash block it writes is offered for approval. `llama3.2:1b` is too small to use tools reliably, and says so.
  - In `ai`: `/tools` lists everything, `/yes` pre-approves low-risk actions, `/agent` turns tool use off.
- Fixed: **the advisor told you to restart units that cannot be restarted.** `systemd-pcr*` and `systemd-tpm2-setup*` fail when Linux has no usable TPM2 (often fTPM / PTT off in the BIOS), so `systemctl restart` fails again, and the old score dropped 28 points for it. They are now recognised as harmless (LOW), the advice is `reset-failed` (clear the flag) or `mask`, and they no longer cost health score. Any other failed unit gets its status / journal shown, and when a restart fails the reason is printed right there.
- Fixed: sudo-needing fixes now say `sudo` and have time to type the password (they had 15 s and no `sudo`); the doubled space in `systemctl  restart` is gone.
- Fixed: zombie processes were "reaped" with `kill -9`, which does nothing to a dead process; the parent is now sent SIGCHLD.
- Fixed: the Quickshell log check always reported 0 errors (a variable typo that an exception swallowed).
- Changed: `advisor "what is dnd?"` is a question and goes to the model; `advisor "gaming mode"` is still a command and runs at once. A question no longer prints a stale dashboard under the answer.
- Files: `scripts/halcyon-agent.py` (new), `scripts/adaptive-advisor.py`, `scripts/halcyon-chat.py`, `quickshell/island/ActionChip.qml`, `quickshell/island/WidgetBuilderWindow.qml`. Copy over the ones in `~/.config/Halcyon/`, restart the island, open a new terminal.

## Smoother tour, tour updated for the widgets

- Fixed: **the tour was laggy and not smooth** (`Tour.qml`).
  - The spotlight hole was re-read 30 times a second and each read restarted five 70 ms animations, so on the bar it trailed behind and moved in steps. The bar and its pages are now read on every frame and the hole sits exactly on them; a new step still glides to its place, once.
  - The card was aimed at the *animating* hole, so its own animation was re-targeted on every frame of the glide and ended with a jump. It is now placed from where the target is, and glides once, on the same curve as the hole.
  - The input mask (the pointer-through hole) followed the glide too, so the compositor was told a new input region on every frame. It now changes once per step.
  - The pulsing light changed the colour of four rings on every frame, forever. It is now one opacity value on a group, off when Motion is low, and the faintest ring (about 5 % strong) is gone.
- Changed: the closing step "That's it" is now last. On a fresh install it used to show as step 13 of 21, with eight more steps after it.
- New tour steps (shown once to existing users as "What's new"): **Desktop widgets** (`>widget builder`), **Place widgets with the mouse** (`>place widgets on the desktop`), **Desktop builder**, **Top bar on or off**, **Password manager**. The Settings step also points at `>widget builder`.
- Files: `quickshell/island/Tour.qml`, `quickshell/island/features.json`. Copy both over the ones in `~/.config/Halcyon/quickshell/island/` and restart the island; `>tour` replays it.

## Bigger desktop builder preview, curl installer, update.sh options

- Changed: the **Desktop builder** picture is much bigger (the card grew to 1560 x 900 and the picture takes about two thirds of it) and has a **Widgets / Boxes** switch above it. In *Widgets* mode only the widgets can be dragged and the four corner boxes are drawn faint and ignore the mouse; in *Boxes* mode only the corner boxes react (click one, then the corner) and the widgets are faint. They no longer sit on top of each other, so dragging a widget onto a corner works.
- New: **`get.sh`**, the one-line installer: `curl -fsSL https://raw.githubusercontent.com/X-netrunner/Halcyon/HEAD/get.sh | bash` (options after `bash -s --`). Clones into `~/.config/Halcyon`, runs `install.sh` with the terminal for its questions, records the version for `update.sh`; hands over to `update.sh` when Halcyon is already there.
- Changed: `update.sh` passes every install option on to `install.sh` (`--browser`, `--files`, `--editor`, `--music`, `--resources`, `--resource-offset`, `--no-apps`, `--no-tune`, `--no-drivers`, `--no-aur`, `--sysmode`, `--lock-login`, `--no-lock-login`, `--tty-autostart`), values after a space or `=`; `--help` lists them; the log keeps the options you typed.

## Desktop widgets, top bar off, roomier console command list

- New: **Widget builder** (`widget-builder`, Settings > Appearance > Widget builder). 23 kinds of desktop widgets: clock (digital, big, stacked, analog, minimal), date, month calendar, CPU, memory, temperature, GPU, disk, battery, volume, brightness, system usage (bars, rings, list, compact), network, uptime, now playing, audio visualizer (bars, mirror, wave, dots, circle), Focus timer with a day **streak**, workspaces, quick toggles (Wi-Fi, Bluetooth, DND, Caffeine, Gaming, Num Lock, theme, night light, lock, power), your own app shortcuts, notes and agenda, weather, text and greeting. Each has several layouts and options, and a look (box, opacity, corners, colours, font, text size). Save looks of your own and reuse them on any widget.
- New: **Place the widgets on the desktop** (`desktop-edit`): drag, resize (corner dot or wheel), add and remove them right on the screen; they snap to the middle and the edges.
- Changed: the **Desktop builder** is now the overview: a picture of where every widget sits (drag them there too), the top bar switch, and the activation zone (screen corner) of each box. The old notes / calendar choice became a Notes widget by itself.
- New: **top bar Off** (Settings > Bar style > Style > Off, or `halcyon bar`). The launcher, the pages and every box still open from the top edge.
- New: the Focus streak counts the minutes of every work phase (`scripts/focus-log.sh`, `~/.local/state/island/focus-days.json`).
- Changed: the console command tree (SUPER+ALT+/) has taller rows, a fixed-width command column and wrapped descriptions, and more space between groups.
- New files: `WidgetData.js`, `WidgetHost.qml`, `DeskWidgets.qml`, `DesktopEditor.qml`, `WidgetBuilder.qml`, `WidgetBuilderWindow.qml`, `WbText.qml`, `WBase.qml`, `WLbl.qml`, `WIco.qml`, `WClock.qml`, `WMetric.qml`, `WSysmon.qml`, `WNet.qml`, `WMusic.qml`, `WViz.qml`, `WFocus.qml`, `WWorkspaces.qml`, `WToggles.qml`, `WNotes.qml`, `WMonth.qml`, `WWeather.qml`, `WText.qml`, `cava-desk.conf`, `cava-desk-light.conf`, `scripts/focus-log.sh`, fish `widget-builder`, `desktop-edit`. Removed: `DesktopNotesWidget.qml`.
- Nothing is read for a widget that is not on the desktop (cava, volume, disk, GPU and the weather request only start when a widget needs them).

## Latest
- Console: `ai`, `advisor`, `notes` and `passman` now run in the island console (they were fish functions, the console runs bash: "command not found"). The installer also puts real commands in ~/.local/bin.
- passman: `passman browser` sets up a Brave / Chromium extension that asks "Save password for <site>?" after a login (Save / Not now / Never); `passman import <csv>` brings in a Brave / Chrome export.
- Desktop builder: the four corner buttons of each box sit on one line.
- App menu ">" commands: grouped (System, Desktop, Tools, Power) in a fixed order; the description moved behind an (i) button that opens a popup under the list.
- Fix: ChipRow set a read-only property on Flow ("implicitHeight is a read-only property").

- **Password manager (`scripts/halcyon-pass.py`, `passman`)**
  - **Cause of lost passwords:** when the key file was missing or did not match, every command treated the vault as empty and the next `passman add` saved a new vault over the old one (a test vault of 62 entries became 1). Now an unreadable vault stops the command with a clear message and is never overwritten; the key is only created when there is no vault yet; the last good vault is kept as `vault.enc.bak`; a new vault is checked by decrypting it before it replaces the old one; writes are locked so two `passman` calls cannot collide.
  - The passphrase now goes to openssl through its own pipe instead of sharing stdin with the data (old vaults still open: same format).
  - Fixed the broken colour code in the auto-generated password message, `passman get` with no name crashing, the documented but missing `passman search`, and the password showing up in the process list while copying (wl-copy now reads it from stdin; the 30-second clear compares a hash).
  - New: `passman edit`, `passman backup`, `passman status`, `add ... -g 32` (length), `add ... --stdin`; a replaced password's previous version is kept (last 3); `add` and `del` ask before replacing / deleting in a terminal.
- **Desktop builder**
  - The corner rows ("Top-left / Top-right / Bottom-left / Bottom-right"), Direction, Colour, Background, Desktop view and Notif trigger rows ran out of the panel; they are now `ChipRow.qml` rows that wrap.
  - The desktop notes / calendar widget showed empty bullets (it read `summary`, the calendar calls it `title`) and listed the first cached events instead of today's. It now shows today's unfinished events with their time, pinned notes first, and updates at once when you change the Desktop view.
  - The live picture now shows the widget and keeps the screen's shape on small windows.
  - Slider drags (blur, stars) are throttled: they rewrote every shared option on every pixel.
  - "Reset the desktop" in Settings and in the window now reset the same things (the widget and the star details were left behind) and the Settings button greys out correctly.
  - Wallpaper paths with `#`, `?` or `%` now show in the preview.
- **Screen & audio recording (`scripts/screen-record.sh`, Settings > Desktop > Screen & audio recording)**: record **desktop sound, microphone or both** with the screen, or **audio only** (.m4a). Buttons to start / stop, play the latest recording and open the folder. Sound is recorded by ffmpeg beside the video and joined when you stop, so it works with wf-recorder, wl-screenrec and gpu-screen-recorder. If sound cannot start, the screen is still recorded and a notification says why.
- New: `quickshell/island/ChipRow.qml`. Changed: `halcyon-pass.py`, `screen-record.sh`, `DesktopBuilderWindow.qml`, `DesktopBuilder.qml`, `DesktopNotesWidget.qml`, `DeskSpots.js`, `Settings.qml`, `shell.qml`, `Launcher.qml`.

## Notification box closed itself about a second after opening
- **Cause:** `shell.qml` counted `notifs.centerOpen` as an "overlay", so opening the box scheduled `notifs.raise()` (260 ms later). `raise()` un-maps the notification window for 60 ms; the edge strip reported "pointer left", `closeT` (700 ms) started, and because the pointer had not moved no new "enter" came to cancel it.
- **Fix:** `notifs.centerOpen` is no longer part of `anyOverlay` (`shell.qml`), and `Notifs.setHover(false)` is ignored while the window is being re-mapped (`cycling`). Raising for toasts and for other overlays is unchanged.
- Changed: `quickshell/island/shell.qml`, `quickshell/island/Notifs.qml`.

## Desktop builder, corner boxes and a quicker launcher
- **Settings > Appearance > Desktop builder** (also `>desktop builder` in the launcher): one window with a small live picture of the screen. **Wallpaper on / off** (off = a plain theme-colour, black or gradient background; no picture is decoded, so it also saves RAM; the colours still follow the last wallpaper), **wallpaper blur**, and **moving stars** over the wallpaper or over the plain background (amount, speed, size, direction, colours, twinkle, an occasional shooting star; they stand still in Gaming mode).
- **Where the boxes open**: the utilities box, the background apps box and the console can each open from the top-left, bottom-left or bottom-right corner (click a box in the picture, then a corner; a taken corner swaps). The top-right corner stays with the notifications, whose trigger can be the right edge or that corner.
- **Settings > Mouse, touchpad & keyboard > Launcher speed** (Normal / Quick / Instant, default Quick): the launcher grows out of the bar in about half the time. It still opens when Super is *released* (a lone tap cannot be told from the start of Super+T until then); `scripts/super_tap.sh` now runs under plain `sh`, a few ms faster.
- New files: `DesktopBuilder.qml`, `DesktopBuilderWindow.qml`, `DesktopStars.qml`, `DeskSpots.js`. Changed: `Wallpaper.qml`, `shell.qml`, `QuickTerm.qml`, `Settings.qml`, `Launcher.qml`, `scripts/super_tap.sh`.

## Installer: pick how much of the machine Halcyon may use

- **install.sh** now asks (once, remembered for update.sh) how much of the computer Halcyon may use: **Low / Medium / High / Adaptive**, each with a rough estimate of the RAM and CPU all of Halcyon needs (shown with a +/- offset range) and a **headroom** choice (Tight 10 % / Balanced 15 % / Relaxed 25 %). The pre-selected answer follows your hardware (low-end = Low, mid-range = Medium, strong = High).
- The answer becomes the default of **Settings > Performance > Resource use** and of the RAM / CPU limits in **Startup & processes > Health**: limit = estimate + headroom. **Adaptive** starts as Medium with limits learned from your own use.
- The numbers are planning estimates, not measurements of your machine. See the real ones in Settings > Performance > Memory.
- Options: `--resources low|medium|high|adaptive`, `--resource-offset N`. Applied once at the first start after the install (resource-seed.json, then deleted), so later changes in Settings are never overwritten.

# Halcyon Optimization & Bugfix Changelog

This changelog documents the complete audit, optimizations, bug fixes, and reliability improvements implemented across the Halcyon repository.

---

## 2026-10-14: Google Birthdays sync (`birthday-sync`)

- New Rust helper `src/birthday-sync`: reads the built-in Google Birthdays calendar (no iCal address exists for it) through the Calendar API with a read-only login, and rewrites only the block between the two "Google Calendar" marker lines in `birthdays.txt`. Lines you typed and the contacts-import block are left alone; people already listed elsewhere are skipped.
- `install.sh` builds it with the other helpers and installs it to `~/.config/Halcyon/bin/birthday-sync` (no root).
- `Calendar.qml`: **Connect Google Birthdays** (picks up `client_secret_*.json` from Downloads, logs in in the browser, syncs) and **Sync Google Birthdays** buttons next to Import Contacts.
- Not run against the real Google API yet: only the offline merge/parse tests were run.

---

## Audit 2026-10-13: security, bugs and reliability fixes

Line-by-line read of the installer, updater, launchers, the root-run parts of `sysmode`, the backup / restore scripts and the calendar helper, targeted searches across the rest (QML, Rust, scripts), plus
syntax checks on everything (all `*.sh`, `sysmode`, `halcyon-tune`, `*.py`, `*.json`, `*.js`, the Rust sources) and a
`install.sh --dry-run` run. Nothing here changes how Halcyon looks or what its features do.

### Summary

| # | Severity | Area | Problem | Fixed in |
|---|----------|------|---------|----------|
| 1 | **High** | Security | `sysmode` (root) could run helper programs from your **home folder**: any program running as you could swap one and become root the next time you ran `sudo sysmode ...` | `sysmode/sysmode` |
| 2 | **High** | Security | Backup / restore disk picker ran `eval` on `lsblk` output: a USB stick whose **label** contains `$(...)` or backticks ran that command as you | `scripts/backup-device.sh`, `scripts/restore-device.sh` |
| 3 | **High** | Install | Installer **aborted in the middle of step 11** on any machine without a DMI table (Raspberry Pi, some VMs / containers) | `install.sh` |
| 4 | Medium | Security | `sysmode` ran `xhost +local:` (opens the X server to every local account and process) | `sysmode/sysmode` |
| 5 | Medium | Security | Calendar's secret address was written **world-readable** first and `chmod`-ed afterwards; plain `http://` and unlimited downloads were accepted | `quickshell/island/scripts/gcal.py` |
| 6 | Medium | Bug | `update.sh --rollback` could pop the **wrong git stash** (your clashing edit from an earlier update) over the rolled-back tree | `update.sh` |
| 7 | Medium | Bug | After `pkill quickshell; start-shell.sh island` the new supervisor often found the old one's lock still held, said "already running" and quit: **no island at all** | `scripts/start-shell.sh`, `update.sh` |
| 8 | Medium | Bug | Island forced the Mesa EGL driver on **every** machine: on a desktop with only an NVIDIA card Quickshell lost its GPU driver | `scripts/start-shell.sh` |
| 9 | Medium | Repo | Author's machine state was committed: `gpu-mode` (`dgpu`), `gpu.lua` (hybrid laptop) and `scheme/current.lua`; a fresh install on an NVIDIA PC started in "dGPU" mode | removed + `.gitignore` |
| 10 | Low | Bug | Settings > Backup > "Safety check" never marked itself done (shell quoting: the reminder script path had literal `"` characters) | `quickshell/island/shell.qml` |
| 11 | Low | Bug | Touchpad toggle fell back to the author's own touchpad name, reported "Disabled" when nothing happened | `scripts/toggle_touchpad.sh` |
| 12 | Low | Security | Text from a log line / attacker request that starts with `-` was passed to `notify-send` as an **option** | `src/log-analyst`, `src/recon-deceiver`, `src/hx/src/ids.rs` |
| 13 | Low | Safety | `--yes` could say yes to the one question that must default to no (`confirm_no`) | `install.sh` |
| 14 | Low | Safety | `pkill -f recon-deceiver` / `log-analyst` also killed anything with those words in its command line (an editor, `tail -f`) | `sysmode/sysmode` |
| 15 | Low | Optimisation | The four sysmode-only Rust helpers were built (minutes of compile time) even with `--no-sysmode`, and then reported as "missing" | `install.sh` |
| 16 | Low | Bug | `user-setup.sh` autostart removal left the tty1 line in `.bash_profile` / `.zprofile` and returned an error | `scripts/user-setup.sh` |
| 17 | Low | Bug | `gpu-mode.sh status` exited 1 when Hyprland was not running | `scripts/gpu-mode.sh` |

### Details

#### 1. `sysmode` only runs root-owned helpers
- **Before:** `sysmode` fell back to `~/.config/Halcyon/bin/*` and `~/CustomHyprScripts/...` for `attacker-dossier`, `recon-deceiver` and `log-analyst`, and `python3` scripts from `SCRIPTS_DIR`. Those files are writable by your user, but `sysmode` runs as root.
- **Now:** new `trusted_file` / `trusted_bin` helpers accept a file only when root owns it, it is not writable by group / others, and every folder above it is the same. The user-home fallbacks are gone. The normal install is not affected: `install.sh` already copies the helpers to `/usr/local/lib/halcyon/sysmode` and `/usr/local/bin`.
- Checked: `/usr/bin/ls` accepted; a user-owned binary refused; a root-owned helper accepted; the same file at mode 777 refused.

#### 2. No `eval` on `lsblk` output
- **Before:** `eval "$line"` on `lsblk -P` lines in both disk pickers.
- **Now:** `parse_pairs` reads `KEY="value"` as plain text (only the nine known keys are accepted, `|` in labels is replaced). A label of ``$(touch /tmp/PWNED)`id` `` stays text (tested; nothing ran). The `rm=$RM` variable (shadowed a command name) became `isrm`.

#### 3. Installer no longer dies without `/sys/class/dmi`
- `tr ... < /sys/class/dmi/id/sys_vendor` failed on machines with no DMI table; with `set -e` that ended the whole install in `setup_asus_extras`. It now reads with `cat ... 2>/dev/null | tr ... || true`. `./install.sh --dry-run --no-packages --yes --user NAME` now runs to the end (it stopped at step 11 before).

#### 4. `xhost`
- `xhost +local:` became `xhost +SI:localuser:<your user>`: only you, not every local account.

#### 5. Calendar (`gcal.py`)
- `config.json` (the secret iCal address) is **created** with mode `0600`, its folder with `0700`.
- Only `https://` / `webcal://` addresses are accepted, in `add-url` and again in `fetch` (so `file://`, `ftp://` and plain `http://` are refused).
- A feed is read up to 25 MB, not without limit.

#### 6. Rollback
- `git stash push` exits 0 when there is nothing to stash; the old code then ran `stash pop` on whatever stash was newest. It now compares `refs/stash` before and after and pops only a stash it just made.

#### 7. Restarting the island
- `start-shell.sh` waits up to 6 s for the supervisor lock (`flock -w 6`) instead of giving up at once. `update.sh` also matches the short `qs` binary name when it restarts the island.

#### 8. Island GPU environment
- `__EGL_VENDOR_LIBRARY_FILENAMES` (Mesa) is set only when a non-NVIDIA GPU is really present; `VK_DRIVER_FILES` (radeon) only when an AMD GPU is present. Hybrid laptops keep exactly the old behaviour.

#### 9. Per-machine files out of the repo
- Removed `gpu-mode`, `gpu.lua`, `scheme/current.lua` (identical to `default.lua`) and added them (plus `special.conf`, `apps.custom`, `autostart.conf`, `gamemode.conf`) to `.gitignore`. `hyprland.lua` recreates `scheme/current.lua` from `default.lua`; `install.sh` and `update.sh` already keep your copies.
- **Existing git checkouts:** run once `git rm --cached gpu-mode gpu.lua scheme/current.lua` before pulling this, so git does not delete your own copies.

#### 10-15. Smaller fixes
- **10:** in `shell.qml` the "safety check done" command had `\\\"` where `\"` was meant.
- **11:** `toggle_touchpad.sh` now finds the touchpad by name only, says "No touchpad found" otherwise, and only reports / remembers the new state if `hyprctl` accepted it. It also no longer depends on `$XDG_RUNTIME_DIR` being set.
- **12:** a `--` now ends the options before the title and message of `notify-send` in the three Rust helpers.
- **13:** `confirm_no` returns "no" with `--yes`.
- **14:** daemons are matched with `pkill -x NAME` (and the exact `python3 .../NAME.py` form for the Python fallbacks); the duplicate `source /etc/sysmode.conf` was removed.
- **15:** `recon-deceiver`, `log-analyst`, `attacker-dossier` and `setStaticMac` are built, installed and checked only when sysmode is chosen.

#### 16-17. Found in the dry-run pass
- **16:** `login_remove` now strips the whole snippet (and the older single-line form) from `~/.bash_profile` and `~/.zprofile`, and always returns 0.
- **17:** `gpu-mode.sh status` ends with `true`, so reading the status outside a Hyprland session is no longer an error.

### Checked and fine (not changed)
- The AWS keys, passwords and private-key text in `src/recon-deceiver` are **decoys** for the honeypot, not real secrets. A pattern search for tokens, keys and personal paths found no real ones.
- No `curl | sh`, no `rm -rf` on an unguarded variable, no predictable files in `/tmp` (the installer log dir uses `mktemp -d`), no QML timer set below 500 ms.
- Notification history and toast lists are trimmed and dismissed properly (`Notifs.qml`): no leak found.

### Known, left alone on purpose
- `sysmode` appends the daemons' output to files in `~/logs` as root. If you do not trust other programs running as your user, point `LOGS_DIR` at a root-owned folder.
- `setStaticMac` builds `sh -c` strings from `nmcli` output (connection UUID, interface name); only root can set those names. Worth moving to `Command::arg` the next time the crate is touched.
- `gcal.py add-url URL` takes the secret address as an argument, so it shows in `ps` for a moment.

### How this was checked
- `bash -n` on every shell script (installer, updater, launchers, `sysmode`, `halcyon-tune`, all `scripts/`), `py_compile` on every Python file, JSON parsed, JS files parsed with Node, QML braces counted, the Rust files that were changed parsed with `rustfmt`.
- Run: hostile-label test of `parse_pairs`, `trusted_bin` against four cases, the stash before/after logic in a scratch repo, `gcal.py` file modes and scheme refusal, and `install.sh --dry-run`.
- Dry-run pass: every `install.sh` flag combination; NVIDIA / Intel / AMD / hybrid paths with fake `pacman` / `lspci`; every `user-setup.sh` subcommand; `start-shell.sh` crash loop and restart; `update.sh` check / update / rollback against a local git origin; `sysmode help|status|doctor`; all 18 Lua files parsed and `hyprland.lua` run against a mock `hl` API; every `hl.*` call, config key and window-rule field compared with current Hyprland master.
- QML heuristic scan: the repeated `id: slot` / `id: ld` in `CustomBar.qml` sit in separate delegates (valid) and the unfamiliar type names are components defined in the same file. No problem found.
- **Not run:** a Rust build (crates.io is not reachable here), Quickshell / QML loading, a real Arch install. Please run `./install.sh` (or `update.sh`) and `scripts/halcyon-doctor.sh` on your machine and send the output if anything differs.

---
## Calendar on Super + R, from the clock, tasks that nag

- **The calendar page from the clock now stays open.** In the notch style the bar is another window, so the pointer on the clock did not count as being on the page and it folded away after 600 ms. Now it stays until the pointer has been on it and has left, or until you click the time again.
- **Wi-Fi power saving now survives a reconnect and a reboot.** It used to change only the live card (`iw ... set power_save`). `halcyon-tune wifi-ps` now also writes `/etc/NetworkManager/conf.d/zz-halcyon-wifi-powersave.conf` (`wifi.powersave` 2 = off, 3 = on; the name sorts last so it beats a distro `default-wifi-powersave-on.conf`) when NetworkManager is there, and the toggle remembers the choice and puts it back at login (`toggle_wifi_powersave.sh apply`, for setups without NetworkManager). Run `./install.sh` (or `./update.sh`) once so the root copy of `halcyon-tune` in `/usr/local/bin` gets the change.
- **Super + R opens the Halcyon calendar** (the same window as `>calendar`). The Todoist special workspace and its `todoCmd` variable are gone; the shortcut keeps its `todo` id, so changed keys and gestures still work. A window still sitting in the old workspace keeps its bar icon until you close it.
- **Click the bar clock** and the calendar drops out of the bar as a page of it, so it is the pill in the island style and the notch in the notch style (the same container as the media and performance pages). Click the time again, or move the pointer away, to close it.
- **Settings > Desktop > Calendar**: master switch, clock click, reminder notifications, what counts as a task (events you mark / every event), auto Focus mode, keep reminding until done (every 2 to 30 min, give up after 1 h to 3 days).
- **Tasks**: each event row has a Task button and, for tasks, a round check. A task is nagged (an urgent notification with a Done button, each one replacing the last) and can start Focus mode for its length. Done is stored on this computer only (`~/.local/state/island/calendar/`), nothing is sent to Google. Google Tasks are not part of the iCal feed.
- **Fix: the shell did not load** ("Calendar unavailable ... Step is not a type"). `Step` is now its own file (`CalStep.qml`) and the function named `goto`, a reserved word that Qt 6.8 to 6.10 reject, is `gotoDay`.


## Calendar (`>calendar`) and notifications on top of everything

- **`>calendar`** (or `halcyon calendar`): your Google Calendar as a month plus the selected day's agenda and a "Next up" card. Arrows move the day, PageUp / PageDown the month, T = today, R = refresh, Esc closes.
- **Connecting**: no Google login. The **Open Google Calendar** button opens the settings in your browser and steps aside; copy the calendar's *Secret address in iCal format* (your calendar > Integrate calendar) and the island sees it on the clipboard, connects, and comes back. (It looks at the clipboard every 1.5 s for at most 6 minutes after you press the button, and only acts on a calendar.google.com iCal link.) The connect page is a numbered timeline (same look as the Timeline notifications) with the buttons inside the steps; **Paste from clipboard** and a text box are fallbacks. If every event says "Busy" (the public free/busy address), a banner offers **Fix it**, and the public address is refused up front. `gcal.py inspect` shows what a feed really contains. It is read-only, stored in `~/.local/state/island/calendar/config.json` (readable only by you), and any other calendar that offers an iCal link works too. Repeating events, time zones, all-day, moved and cancelled events are handled. Google *Tasks* (the to-do list) is not part of that address, only calendar events.
- **Reminders** arrive as ordinary notifications (app "Calendar"): 10 minutes before and at the start by default, changeable in the calendar's settings page; all-day events notify at 08:00. Synced every 15 minutes; `scripts/gcal.py` does the work.
- **Notifications now show above every window**, the tree view, Settings, the shortcuts tree and the rest included: while a toast or the centre is showing, the notification window moves to the Overlay layer, and is put back on top when another big window opens at the same time.

## Guided tour and "what's new" (first start and after updates)

- **First start**: the screen dims except for a light-ringed hole around the part being explained, with a card in the island's glass style (what it does, what can happen, key caps). Steps: island, search bar and `>` commands, performance and media pages, quick settings, notification centre, console, shortcuts tree, sysmode commands tree, tree view, settings. The island opens each thing for its step, and the highlighted part can be used. **Esc skips**, Right / Enter / Space = next, Left = back.
- The light follows the real size of the bar (it grows into pages, shrinks, slides), and the notch / auto-hide styles.
- **The only file to edit when a feature ships is `quickshell/island/features.json`.** After an update the island compares it with the copy the user saw last (`~/.local/state/island/features.seen.json`) and shows only entries that are new, or whose `rev` went up, as "What's new". Skipping counts as seen.
- Replay everything with `>tour` or `halcyon tour`. New files: `Tour.qml`, `Tour.js`, `features.json`.

## Choose the fish greeting's logo (adaptive, BlackArch, your own ASCII art)

- The greeting used to be hard-wired: the Kali dragon inside a Kali container, the Arch logo everywhere else. **Settings > Terminal greeting** now has **Logo in new terminals**: Adaptive (default), Arch, BlackArch, Kali, Linux, Custom, Info only, Off. `scripts/greeting-conf.sh` does the same from a terminal (`list`, `set LOGO <name>`, `paste`, `import FILE`, `edit`, `preview`); the choice is in `~/.config/Halcyon/greeting.conf`.
- **Adaptive** reads `/etc/os-release`: Arch, CachyOS, EndeavourOS, Manjaro, Garuda, Artix and ArcoLinux (and anything else that says it is Arch-like) show the Arch logo, BlackArch and Kali show their own, every other system shows a small Linux penguin. The `distro` line now shows the system's real name (`PRETTY_NAME`), so CachyOS no longer says "Arch Linux".
- **Custom**: your own ASCII art. In Settings, *Paste from clipboard* saves what you copied (needs `wl-clipboard`, which the clipboard history already uses) and switches to Custom; *Edit file* opens `~/.config/Halcyon/greeting-custom.txt` (starting from the penguin if it is new); *Preview* shows the greeting in a terminal. `@C1@` / `@C2@` in the text switch to the accent / grey colour, ready-made colour codes are kept, every other escape code is dropped when pasting, and at most 40 rows are shown. A missing or empty custom file quietly falls back to Adaptive.
- The logos moved out of the function into plain files (`config/fish/greeting/logos/arch.txt`, `kali.txt`, `blackarch.txt`, `linux.txt`), and the info block now centres itself next to whatever logo is shown (before, each logo had its row numbers typed in). The Arch layout is unchanged; the Kali info now sits in the middle of the dragon instead of at its head. The Kali and BlackArch logos keep their own colours; the others follow the wallpaper. The BlackArch logo is a stylised drawing, not the official artwork.
- `greeting.conf` and `greeting-custom.txt` are yours: git ignores them and `install.sh` never overwrites them.

## Commands tree: SUPER + ALT + /

- New `CmdTree.qml`: every console command as a tree, same look as the SUPER+/ shortcuts tree. Branches: Sysmode (secure, stealth, relaxed, lockdown, status, verify, logs, dossier, doctor; the ones that ask for your password are marked `sudo`), Hotspot, Halcyon windows, and the console's own words. Type to search, click a command to put it in the console (it is not run, you press Enter there), Esc or Super+Q closes it.
- Only set up with sysmode: `hyprland/keybinds.lua` binds `SUPER + ALT + slash` only when `/usr/local/bin/sysmode` exists, the island's `cmdlist` call does nothing without it, and the shortcut is hidden in the SUPER+/ tree (and not counted) until sysmode is installed. Like the other shortcuts it can be changed in the SUPER+/ tree.
- The console's `help` mentions it.

## Console takes the keyboard when it pops out; hotspot commands work in the console

- The top-left console now takes the keyboard by itself about 150 ms after it pops out (touching the corner, or clicking it in click mode), so typing goes straight into it even with a terminal open beside it. Brushing past the corner steals nothing. While the pointer is over the console it holds the keyboard exclusively (Hyprland's `follow_mouse` could otherwise hand it back to the terminal beside it); when the pointer leaves it is on-demand again, so clicking another window just works. A new window still makes it let go.
- `hotspot-on` / `hotspot-off` did nothing in the console and were missing from Tab completion: they were fish functions, and the console runs bash. The work moved to `scripts/hotspot.sh on | off | status` (fish functions now just call it), and the console knows both commands itself. The same goes for `halcyon <command>`, `bar-builder`, `notification-builder`, `wallpaper-gallery` and `startup-view`, which also complete with Tab (`halcyon` completes its sub-commands).
- `hotspot-off` no longer assumes the adapter is called `wlan0`: it finds the Wi-Fi adapter, stops only its own connection (`Halcyon-Hotspot`, so the decoy hotspot of `sysmode stealth --hotspot` is left alone), and puts the adapter back on normal Wi-Fi. The hotspot no longer starts by itself at boot. The hint now says `sudo sysmode relaxed`.
- Colour codes in command output are removed in the console (they used to show as stray characters).

## Autocomplete in the top-left console

- **Tab** completes the word under the cursor: commands (and the console's own words: `help`, `clear`, `cd`, `sm`, `sysmode`, the mode names) at the start of a command, also after `;`, `|`, `&` and after `sudo`; folders after `cd`; the sysmode actions after `sysmode` / `sm`; files and folders everywhere else (`~` works, folders get a `/`, spaces are escaped). One match completes it; several complete their common start and list up to 8 above the input line.
- Tab again goes through the matches (**Shift+Tab** back), **Esc** closes the list, typing anything else closes it too.
- A grey suggestion from your earlier commands follows what you type: **Right arrow** or **End** takes it.
- Completion runs in the background (`bash` `compgen`), only when you press Tab; nothing runs while you type.

## Fish commands, and the notification box slides when you move its parts

- install.sh / update.sh now install fish commands (`scripts/user-setup.sh fish-commands`, only when fish is installed): `bar-builder`, `notification-builder`, `wallpaper-gallery`, `startup-view`, and `halcyon <command>` for everything else (`halcyon --help` lists them: launcher, settings, notifications, dnd, cheatsheet, power-menu, quick-terminal, overview, gaming-mode, caffeine, lock, theme, reload ...), with tab completion. They use the island's IPC; two new IPC functions: `barbuilder`, `notifbuilder`.
- The notification box and its builder no longer use inline QML components (new files `NotifBlock.qml`, `NbCap.qml`): some Qt versions refuse them with "X is not a type".
- The fish step also installs `hotspot-on` / `hotspot-off` and the one-time command hints (`hints.fish`, in conf.d; for interactive shells only). `fish_greeting` was already shipped and is unchanged.
- Moving a part of the notification box with the arrows now animates: in the builder's list of parts and in the box itself (real and preview) the parts slide to their new places, and a part that is switched on or off fades while the others slide to fill or open the gap. It also slides when a notification arrives above another part.

## Notification box builder

- Settings > Panels & notifications > **Notification box builder** > "Open the notification box builder": its own window with a live copy of the real box (sample notifications; the buttons and the ✕ work, nothing real is touched). Everything saves and shows on the real box at once.
- **Parts**: the constellation band, the title and buttons, and the list can each be switched on or off and moved up or down.
- **Constellations and stars**: the drawing in the band on or off, the band's height, the drifting dots, the constellation behind the whole box, the flying stars (0 to 20) and the stars in popups.
- **Spacing and shape**: padding, space between the parts, space between notifications, corner roundness, width.
- **Place**: Top, Middle or Bottom of the right edge, with a distance from the edge, and a small picture of the screen. It still opens from the right edge of the screen.
- Also from the app menu: type `>` and then "notification box builder" (or "notif", "stars", "padding").
- A constellation band with nothing to draw (the drawing off and no dots, or no constellation available) takes no room instead of leaving a gap. "Distance from edge" can now go negative, and "Line up with the popups" puts the box at the same height as the popups; the box never goes nearer than 8 px to the screen edge.
- Fix: the ▲ ▼ and Shown / Hidden buttons for the parts did nothing once the layout had been saved (the saved list of parts was read back wrongly and the default order came back).
- The constellation band only takes room while there is a constellation to draw in it; the drifting dots now sit behind the whole box and take no room, so hiding the band (or having no constellation) lets the title and the notifications move up.
- SUPER+Q closes the notification box builder first, like the other builders, instead of the window under it.
- "Reset the box" goes back to the old look. New files: `NotifLayout.js`, `NotifBox.qml`, `NotifSurface.qml`, `NotifBuilder.qml`, `NotifBuilderWindow.qml`, `NbSlider.qml`. `Notifs.qml` now draws its panel with `NotifSurface`.

## Notification style: Stack, Timeline or Grouped by app, with the drifting stars

- Settings > Panels & notifications > **Notification style**: **Stack** (a card per notification, the default), **Timeline** (a thin rail with a dot per notification, under Just now / Earlier today / Yesterday / Older, no cards) or **Grouped by app** (one card per app with a count, its notifications inside, and a remove-all button on hover). Works in the right-edge panel and in the bar's drop-down page. New files: `NotifList.qml`, `NotifLine.qml`, `NotifGroup.qml`.
- The small stars that drift across the bar now also drift behind the notification panel and behind each popup. They follow Settings > Constellations (the notifications switch) and stop in Gaming mode like the other boxes.

## Notification box redesign, every message kept, smoother constellations

- Notification rows: an accent edge and a soft wash on the left (urgent ones in red), the app name in the accent colour with the time beside it, a round remove button on hover, a slightly bigger picture and title. A new notification lights its edge for a moment and slides in from the right; rows slide into place when others go. The header says "3 notifications" (or "You are all caught up") instead of "3 of 30 kept".
- Fix: only one `notify-send` message was shown. Messages from `notify-send` with the same title replaced each other. Now only Halcyon's own status messages (`-a Halcyon`) replace an earlier one with the same title; everything else, `notify-send` included, is kept unless it is an exact repeat (same title and text).
- Constellations: the breathing / sway / twinkle clocks no longer restart from 0 every time the art comes into view (that made the whole sky jump at the start); they keep their place. The motion eases in over about 1.6 s, the drawing fades in instead of popping into place, and the drifting dots carry on from where they were.

## Adaptive RAM / CPU limits

- Settings > Performance & memory > **Limits**: Manual (the two sliders, as before, still the default) or **Adaptive**. In Adaptive the island takes one reading of Halcyon's own RAM and CPU every 5 minutes (`startup-view.py adapt-sample`, kept in `~/.local/state/island/adaptive.tsv`, 14 days at most). Nothing is sampled while Adaptive is off or Gaming mode is on.
- After 3 days and 150 readings the limits are set from your own use: the busy 5 % of the time (95th percentile) plus headroom (RAM x1.25 rounded up to 50 MB, CPU x1.5 + 1 point), inside the same range as the sliders (300-1500 MB, 3-30 %). They keep adjusting over the last 14 days. Until then the manual limits apply.
- The Health tab shows the limits in use and how far the learning is. "Forget what it learned" in Settings (or `startup-view.py adapt-reset`) starts over; `startup-view.py adapt-status` prints the state as JSON.
- Like the manual limits, they only measure and advise: nothing is changed or stopped by itself.

## Adaptive RAM / CPU limits

- Settings > Performance & memory > **Limits**: Manual (the two sliders, as before, still the default) or **Adaptive**. In Adaptive the island takes one reading of Halcyon's own RAM and CPU every 5 minutes (`startup-view.py adapt-sample`, kept in `~/.local/state/island/adaptive.tsv`, 14 days at most). Nothing is sampled while Adaptive is off or Gaming mode is on.
- After 3 days and 150 readings the limits are set from your own use: the busy 5 % of the time (95th percentile) plus headroom (RAM x1.25 rounded up to 50 MB, CPU x1.5 + 1 point), inside the same range as the sliders (300-1500 MB, 3-30 %). They keep adjusting over the last 14 days. Until then the manual limits apply.
- The Health tab shows the limits in use and how far the learning is. "Forget what it learned" in Settings (or `startup-view.py adapt-reset`) starts over; `startup-view.py adapt-status` prints the state as JSON.
- Like the manual limits, they only measure and advise: nothing is changed or stopped by itself.

## Startup window: hover explanations, Health tab with limits

- The explanation line at the bottom of the Startup & processes window is gone. Every column title (ITEM, STARTED BY, MEMORY, CPU, PROCS), every caption of the memory bar, the filter row and the Suggestions tab now has a small round **?**: hover it and one bubble explains that word. The bubble lives on the card, so no list or row can cut it off (new `HelpTip.qml`). The bottom line only shows the answer to what you just did (for example "applies the next time you log in") and clears itself after a few seconds.
- New **Health** tab. It adds up all of Halcyon (Hyprland, the island with its helpers, the daemons) and compares it with two limits: RAM (default 600 MB) and CPU (default 10 % of the whole processor). Both are sliders in Settings > Performance & memory ("Halcyon RAM limit", "Halcyon CPU limit"). Over a limit, the tab lists the parts that cause it, the likely causes worked out from your own settings (resource preset, frame rate, moving stars, music bars, line drawing, background refresh, wallpaper size, how long the island has been running ...) and what to do, with buttons where one click is safe (switch to Low / Medium resource use, turn off a tray applet, End a program that is eating the machine). CPU is only flagged after two readings in a row (about 10 s), so a short burst raises no alarm. When the whole machine is short of memory it also says which other programs hold it.
- A "Halcyon is over its limit: see why" button and a "!" on the Health tab appear while a limit is exceeded. It only measures and advises; nothing is changed by itself, and nothing runs while the window is closed.
- Fix: the reader (`startup-view.py`) runs under the island, so its own process and the helpers it starts were counted as the island's load while the window was open. They are left out now.

---

## Notification centre: constellations above the text

- The constellations (dots, your profile constellation, the lockdown / stealth art) used to be drawn behind the whole panel, so notification text ran over their lines. They now have a band of their own at the top of the panel (about 150 px, smaller on short screens), and the title, DND / Clear and the notifications sit underneath, so the box is taller. The list is capped so the panel still fits on small screens. Settings > Constellations switches the band off (the panel is then as short as before).

---

## Settings: no more lag when searching

- The gesture and mouse-button editors built every hidden action list (about 45 chips and an app menu per row, up to six rows) as soon as they appeared, and each app menu listed all installed apps. A search that brought them up made typing stutter. The lists and the app menu are now created only while a row is open, and the editors read their data at most every 2 s.

---

## Startup window: Suggestions, honest CPU numbers

- **Suggestions tab** (and a "N suggestions" chip on the Startup tab): startup items that are running and can be turned off, each with the reason, the memory it would free, *Turn off* and *Keep* (Keep hides it for good, `~/.local/state/island/startup-keep`). It flags things that do nothing on this machine (touchpad gestures service without a touchpad, blueman without a Bluetooth adapter), things Halcyon already covers (nm-applet, the screen-sharing portal, which starts by itself when needed), file indexers / Evolution helpers, and chat / sync apps or heavy autostart entries (Steam, Discord ...) that can be opened by hand. Audio, portals, polkit, the keyring and the desktop itself are never suggested. Nothing is switched off without the button.
- **CPU** now shows the share of the whole processor (matches your overall usage) with the share of one core under it. Values are averaged over the last refreshes, so a short burst (power-manager starting `nvidia-smi` / `powerprofilesctl` during the 0.4 s snapshot read 116 %) fades instead of reading as a steady load.
- *PROC* is now *PROCS* (how many processes the item runs) with a wider column.
- micro: the current line was the colour of the text (micro paints it with the foreground colour of `cursor-line`); it is now a dark tint of the accent, text colours stay as they are.

---

## micro follows the wallpaper, and is transparent

- `scripts/app-themes.sh` writes `~/.config/micro/colorschemes/halcyon.micro` and selects it (`"colorscheme": "halcyon"` in micro's `settings.json`; your old file is kept once as `settings.json.before-halcyon`). The scheme gives the text, status bar, tabs and gutter no background, so micro shows the terminal's own translucent background (the grey blob was micro's built-in scheme painting over it). Syntax colours are the wallpaper's bright colours so they stay readable over it; only the current line, the selection and search hits have a background.
- Regenerated on every wallpaper change like btop and yazi; an open micro keeps the old colours until you restart it. `halcyon-doctor.sh` checks it.

---

## Startup & processes window, in the builder's and gallery's look

- Same header as the wallpaper gallery (icon, title, search box, segmented *Startup / Processes* switch, round refresh and close buttons) and the same few stars drifting over the card (follows Settings > Look > Moving stars).
- The three number cards are one memory bar: startup items, the rest of your session, everything else, free. Filters and sorting are segmented switches too.
- Rows light up on hover, memory has a small bar under the number, and the lists are updated in place every 5 s instead of rebuilt, so nothing flashes or jumps while you read. `/` searches, Esc clears the search first, then closes.

---

## Editable touchpad gestures and mouse buttons

- **Settings > Touchpad gestures**: 3 or 4 fingers, swipe left / right / up / down and pinch in / out, each set from a grouped list of actions (workspaces, windows, island panels, lock / sleep / screenshot, media, volume / brightness, terminal / browser / files, *Open an app* from the same app menu as the shortcut editor, *Run a command*). The defaults are what Halcyon always did. A gesture left on *Nothing* is not registered, so apps still receive it; pinch in and out set to the same thing is registered as one gesture. *Restore defaults* is there too.
- **Settings > Mouse buttons**: looks for connected mice (touchpads and virtual devices are not counted; checked every 4 s while the section is open) and, when there is one, offers back, forward and middle click, plus three extra buttons for gaming mice. Actions are the same as for gestures, plus *Move / Resize a window while held*. Left and right click are never rebound.
- How it works: `scripts/input-conf.sh` (`conf`, `set`, `reset`, `run`, no jq needed) keeps `~/.local/state/island/gestures.conf`; `hyprland/inputconf.lua` reads it for `hyprland/gestures.lua` and the new `hyprland/mouse.lua`; each gesture or button runs `input-conf.sh run ID`. Settings asks the island for a batched Hyprland reload after a change (new action `hypr-reload`).
- The old Workspaces > *4-finger swipe* option is gone: set 4-finger left / right to next / previous in the new section (an old "right = next" choice is carried over as the default).

---

## Settings regrouped, notifications that stay, a safer update.sh

- **Settings**: 24 groups became 16 (Mouse + Touchpad + Keyboard, Power + Sleep, Bar style + Bar, Motion + Shadows + Blur, Night light into Colours, Panels into Notifications, Rice into Apps). Long descriptions show one line with a "?" for the rest. Each group has an **Advanced** row for the rarely used settings (a search, or the header switch, shows them all). The two Backup / Safety-check reminder blocks are built by one helper.
- **Two Settings layouts, both kept.** The branching **Tree** (default) and new **Pages**: a trunk of 7 pages on the left (Appearance, Bar, Desktop, Input, Power & lock, System, Backup), one page of flat cards on the right, a short branch only where a row depends on the one above, Advanced inside each card. Switch with the chip in the Settings header or Settings > Look > Settings layout; same settings, same saving, the choice is remembered (`opt.settingsStyle`).
- **Notifications now stay in the centre.** An app that withdrew its own notification (read in the chat, tab focused ...) used to remove it from the centre too, and transient ones were never stored. Both are kept until you remove them.
- **Urgent popups no longer wait for a click for ever.** Browsers send "requires interaction" as critical. They hide after 30 s (Settings > Notifications > Urgent popups: 15 s / 30 s / 1 min / wait for a click); the notification stays in the centre. The cross on a popup is a real button now (removes it without opening the app).
- **update.sh**: runs inside one function (replacing itself mid-run is safe), one run at a time, network steps time out, a log in `~/.local/state/halcyon/update.log`, `--changes`, `--rollback`, `--notify`, `-q`, exit code 10 from `--check` when an update exists. An edit of yours that clashes with the update is saved in a git stash instead of leaving conflict markers in the file. After the reload it reads the island's log and reports a QML error at once, and runs a syntax check over the scripts and halcyon-doctor.

---

## Terminal music player routing, blurred lock screen, focus mode in Rust

- **spotify-player (and other terminal music players) now go to the music workspace.** The island only recognised the Spotify *app* by its window class; a terminal player has the terminal's class (`foot`, `kitty` ...), so it was never moved. `scripts/apps.sh run music` now starts a terminal music player with the window class `halcyon-music` (foot / kitty / alacritty / ghostty / wezterm / xterm / gnome-terminal) and `Routes.js` sends that class to SUPER+M. (konsole has no class option, so it keeps its own.)
- **Lock screen background option** (Settings > Sleep & lock): *Solid colour* (as before) or *Blurred wallpaper*, with **Lock screen blur** and **Lock screen tint** sliders. The tint is the opacity of the theme colour over the wallpaper (0 % = wallpaper as it is). The wallpaper is only decoded while the screen is locked; the blur is drawn once into a layer, not every frame.
- **Settings read Hyprland on/off options correctly**: `hypr-values.sh` also understands `"bool": true|false` (newer Hyprland), so switches like *Pause while typing* show what Hyprland really has.
- **Focus mode helper is native**: `hx focus ...` (`src/hx/src/focus.rs`) replaces `focus.py`; same files, same JSON. A running session no longer keeps a Python interpreter in RAM. `scripts/focus.sh` uses `hx focus` when the installed `hx` has it and falls back to `focus.py` otherwise.

---

## spotify-player in the rice, and a much shorter Settings

- **spotify-player** (the terminal Spotify client) is a choice in the installer: `./install.sh --choose` now asks "Music player" (Spotify, spotify-player, None; **several can be picked**, the first is SUPER+M), or `--music spotify,spotify-player`; the answer is remembered for update.sh. It is themed like btop / yazi: `app-themes.sh` writes a `halcyon` theme to `~/.config/spotify-player/theme.toml` from the wallpaper colours (your own themes in that file are kept, the terminal's background and blur show through) and sets `theme = "halcyon"` in `app.toml` (the old file is saved as `app.toml.before-halcyon`). It is read each time spotify-player starts. First run: `spotify_player authenticate`. It is also a choice in Settings > Default apps > Music (opens in your terminal on SUPER+M), and `halcyon-doctor.sh` checks it.
- **Settings is shorter: 152 rows became 123, and 26 groups became 24**, with nothing removed:
  - **Backup & safety** reads as one flow: **Backup** (Whole system / Home folder only), **Restore** (From a backup / Home folder only), **Remind me to back up** (Off / Day / Week / Month / 3 months / Custom in one row; the day count only shows for Custom), then the safety check, its reminder and the automatic run. Before: 14 rows in the order backup, backup home, restore, restore home, safety check, then six reminder rows.
  - Two new row kinds do most of it: **several buttons in one row** (Backup, Restore, Memory report + Detect RAM, Edit config + Shortcuts + Reload) and **several switches in one row** (what the bar shows, the clock, the constellation boxes, touchpad behaviour, focus options, workspace behaviour, Do not disturb + Wi-Fi errors only).
  - Options that only matter while another is on now hide until it is: time per colour (colour cycling), terminal colour options (terminals follow the wallpaper), blur strength / quality (blur), the page-close speed (hover opens a page), how long the volume bar stays (volume bar on), the constellation boxes (constellations on).
  - **Colours** now includes the terminal colours, and **Workspaces & windows** includes switching workspaces.
- **Your own command for every special workspace.** Settings > Workspaces & windows > Special workspace commands: a command per workspace (scratch, music, communication, system monitor, todo), started whenever it is opened with no window in it. Empty = the default. Scratch (SUPER+S), system monitor and todo now start through `special.sh --run`, so a change applies at once with no Hyprland reload.

---

## SUPER+D is yours: WhatsApp and any website

- **Settings > Default apps > Chat** now also lists websites that open in your browser as their own window: WhatsApp, Telegram (web), Messenger, Google Messages, Discord (web), Teams (web). They show whenever a browser is installed. SUPER+D still opens whatever is picked, on the communication workspace.
- **Add website**: type a name and an address (`web.whatsapp.com`) and it is added and chosen at once; the **×** next to one you added removes it. Same from a terminal: `apps.sh add-web <Name> <url>` / `apps.sh remove-web <id>`. Chromium-family browsers (Chromium, Chrome, Brave, Vivaldi) open it with `--app` (no tabs or address bar); other browsers open a new window.
- A website is never picked for you: with no chat app installed, SUPER+D starts nothing until you choose one. Windows of the built-in sites are moved to the communication workspace like Discord and Telegram are.
- Fixed: the bar builder failed to load (`Slot is not a type`); its inline components are renamed.

---

## Bar builder: Island or Notch, the real bar as the editor, padding you can type

- **Shape.** Style = Custom can now be a **Notch** (hangs from the top edge, flared corners, as before) or an **Island** (a floating rounded pill a little below the edge). Pick it in Settings > Bar style > Bar builder, or at the top of the builder window. Saved in `opt.barLayout.shape`; layouts saved before this stay Notch.
- **The bar is the editor.** The builder window now draws the bar itself, with the same widgets, sizes and spacing as the real one (samples for the time, battery, Wi-Fi ...), at the chosen shape. Drag a widget along it to reorder, onto another place to move it, onto the shelf to take it off. Widgets that only show sometimes (Caffeine, Focus, Bg apps) are always shown there so they can be placed.
- **Symmetry help.** While you drag, a line marks the exact centre of the screen and the drop shows what Left / Right would come to ("✓ the sides match" or "N px apart"). When the sides differ, the builder suggests the one move that evens them out, with a button to apply it. The middle is always centred.
- **Padding.** Type px (or use - / +, or leave "auto") for the edge padding, the gap between widgets and the clearance around the middle. Click a widget on the bar to give just that one its own padding. Saved in `opt.barLayout` (`edge`, `gap`, `clear`, `pads`); `null` = the automatic spacing, so nothing changes until you type a number.

## Yes by default, backup / safety-check reminders, automatic safety check, pitch-black boxes

- **Starship badge really fixed.** Starship ran the badge command in fish (your login shell) and it was POSIX `sh`, so it printed nothing. The table now has `shell = ["sh"]`; `app-themes.sh` repairs an installed starship.toml that has either earlier version of the badge (a copy is kept as `starship.toml.before-sysmode-fix`).
- **Questions default to yes** ([Y/n], Enter = yes): the installer's confirmations (including adding the safety check, which is now on by default; `--no-safety-check` skips it), and `backup-device.sh` (start the backup, eject the disk). The one exception is setting up the lock-screen login, which stays [y/N]: it was deliberately made opt-in after it left a machine booting into a broken desktop. With no terminal to ask on, `confirm` still answers no, so a piped install never goes ahead by itself.
- **Settings > Backup > Remind me**: a toggle for backups and one for the safety check, each with Day / Week / Month / 3 months / Custom (1-365 days). `scripts/remind.sh`, a user timer (`halcyon-remind.timer`) that only runs while a reminder is on, one notification when it is due. "Done" is noted by `backup-device.sh` and by the Settings safety-check button.
- **Settings > Backup > Safety check > Run it automatically**: a root timer (`scripts/safety-auto.sh`) with the same schedule choices. Switching it on, changing how often and switching it off all need your sudo password (`sudo -k -S`: a password you typed a minute ago does not count). Everything that runs as root is root-owned (`/usr/local/bin/safety-check`, a small wrapper written to `/usr/local/bin`, the unit files), nothing in your home folder. New `safety-check --auto`: never updates the system, never asks, never formats; the backup step only runs when the known backup disk is plugged in; waits for AC power. Needs the safety-check binary rebuilt (`./update.sh`).
- **Settings > Look > Box background**: Wallpaper tint (as before) / Matte black / Pitch black. Matte and black make every box, the bar and the Settings window solid. The drifting dots and constellations keep the accent colour and get brighter so they still show on black. Dark theme only.
- `halcyon-doctor.sh` now also checks the installed sysmode, the mode file, the starship badge and the reminders.

---

## Performance, Memory Leak, CPU Usage & Daemon Optimization Audit (October 2026)

### 1. Root Cause Analysis: Unusually High CPU & RAM Usage
- **Root Cause Identified:** A runaway `gvfsd-metadata` daemon process (PID 24128) was trapped in an infinite spin loop, consuming **96.8% CPU (104+ minutes of cumulative CPU time) and 1.2 GB RSS / 1.3 GB VmPeak RAM**.
- **Underlying Cause:** `scripts/backup-device.sh` executed `rsync` recursively across `$HOME` (`HOME_ONLY=1`) without excluding volatile lockfiles and internal socket structures, notably `~/.local/share/gvfs-metadata`. When rsync accessed active metadata journals while file operations were occurring, GVFS metadata journals corrupted, causing `gvfsd-metadata` to endlessly spin attempting to parse corrupted journal structures.
- **Resolution:**
  - Terminated the hung `gvfsd-metadata` process and cleaned invalid journal locks; system RAM usage dropped from 4.3 GiB to 2.8 GiB, and CPU utilization normalized to near zero.
  - Updated `scripts/backup-device.sh` to explicitly exclude `--exclude=.local/share/gvfs-metadata` and `--exclude=*.sock`.

---

### 2. Fork Storm & CPU Optimization in `src/hx/src/ctl.rs`
- **Issue:** The main control loop in `hx ctl` runs every 60ms to deliver instant slider feedback. In `bright(&bl)`, when `/sys/class/backlight` is unavailable (e.g. desktop systems, external monitors, or unexposed GPU backlights), the function fell back to executing `util::run("brightnessctl", &["-m"], 2)`. This resulted in **16 subprocess forks every second**, causing continuous CPU thrashing and process churn.
- **Resolution:** Introduced cached state tracking with an `Instant` rate limiter. If sysfs is unavailable, `brightnessctl` is now queried at most once every 1,500ms, returning the cached brightness value between checks.

---

### 3. Memory Spike & Allocation Optimization in `src/hx/src/status.rs`
- **Issue:** `hx status` read entire log files (`fs::read(format!("{}/recon-attempts.log", logs))` and `ids-alerts.log`) into memory buffers on every status poll, converting whole files into lossy UTF-8 strings before splitting into lines. As attack and IDS logs accumulate tens or hundreds of megabytes, this triggered periodic multimegabyte heap allocations and memory spikes.
- **Resolution:** Replaced full-file reads with `std::io::BufReader` line streaming. Lines are now processed sequentially with fixed memory footprint ($O(1)$ RAM buffer of ~8 KB) regardless of file size.

---

### 4. Power Manager Daemon (`src/power-manager/src/main.rs`) Optimizations & Bug Fixes
- **Eliminated Synchronous 500ms Thread Sleep:**
  - *Issue:* `get_cpu_usage()` previously called `thread::sleep(Duration::from_millis(500))` inside the polling loop to measure CPU usage deltas. This blocked the daemon thread for half a second on every poll tick.
  - *Fix:* Extended `LoadState` to track previous `/proc/stat` CPU snapshots across normal 15-second loop iterations, computing deltas asynchronously with zero sleep.
- **Fixed evdev Input Polling & File Descriptor Thrashing:**
  - *Issue:* `has_input_activity()` previously iterated `/dev/input`, opened every `event*` device, ran `poll(timeout = 0)`, and immediately closed them. Because newly opened evdev file descriptors have empty kernel buffers, this almost never detected real user activity and generated dozens of wasteful syscalls per poll.
  - *Fix:* `LoadState` now retains open `Device` handles across poll ticks, allowing the kernel to buffer input events over the 15-second interval. It drains events non-blockingly each tick and gracefully re-enumerates on device disconnects. In addition, it checks `/dev/shm/halcyon-dim` to immediately detect hypridle dim states.
- **Fixed Game Mode Detection:**
  - *Issue:* `is_gaming_mode()` invoked `qs -c caelestia ipc call gameMode isEnabled`, which always failed because Halcyon uses the Island shell rather than Caelestia, spawning a failed subprocess every 15s. It also failed to check Halcyon's active gamemode indicator.
  - *Fix:* Added an instant check for `/dev/shm/halcyon-gamemode` before falling back to `gamemoded -s`, and removed the defunct Caelestia command.
- **Fixed PPM Binary Image Parsing in `get_dominant_color_from_video()`:**
  - *Issue:* Attempted to parse binary PPM (`P6`) frames from ffmpeg by converting raw stdout into UTF-8 strings and splitting on `\n`. Binary pixel bytes containing `0x0A` were misinterpreted as newlines, corrupting color calculations.
  - *Fix:* Replaced UTF-8 splitting with a robust binary PPM header parser operating directly on raw byte slices.

---

### 5. Memory & Process Leaks in Security Daemons
- **`src/recon-deceiver/src/main.rs`:**
  - *Socket Panic / Resource Fix:* Replaced redundant `s.try_clone().unwrap()` on accepted TCP sockets by directly moving `s` into connection handler threads, eliminating file descriptor duplication and panics on abrupt client disconnects.
  - *Zombie Process Leak:* Spawning `notify-send` previously dropped child process handles without waiting for exit, leaking zombie processes. Wrapped child process invocations with asynchronous waiter threads.
- **`src/log-analyst/src/main.rs`:**
  - *Zombie Process Leak:* Reaped `notify-send` child processes via background helper threads to prevent zombie process leaks.
  - *Log Rotation Truncation:* Added file size inspection to reset seek position to beginning of file if log files are rotated or truncated.

---

### 6. Shell Script Reliability Fixes
- **`scripts/osd-watch.sh`:**
  - Guarded against bash division-by-zero crashes when brightness or keyboard backlight maximum values are reported as 0 (`[ "$bmax" -gt 0 ]` and `[ "$kmax" -gt 0 ]`).
  - Added fallback sleep (`|| sleep 0.25`) to prevent tight CPU spin in case `inotifywait` fails or is interrupted.
- **`scripts/halcyon-doctor.sh`:**
  - Added new automated **"System & Process Health"** diagnostics section checking for runaway `gvfsd-metadata` processes, zombie processes, and low available memory.

---

### 7. Quickshell & QML UI Bug Fixes
- **`quickshell/island/NotchBar.qml`:**
  - Fixed Qt Quick runtime warning: `Cannot anchor to an item that isn't a parent or sibling` by replacing invalid cross-hierarchy `anchors.fill: rightMain` with bound geometry coordinates (`x`, `y`, `width`, `height`).
- **`quickshell/island/Cheatsheet.qml`:**
  - Fixed recurring `ReferenceError: search is not defined` runtime exceptions (triggered whenever the cheatsheet was opened or closed) by relocating the focus `Timer` and `Connections` inside `TextInput { id: search }` where `search` is in scope.

---

## Drag the bar down: utilities box and notifications inside the bar, launcher arrow keys

- **Settings > Bar style > Drag the bar down** (Off / Two steps / Side by side; default Off). Pull the bar down (island or notch) and the utilities box drops out of it as a page, the same box as the bottom-right corner one (Wi-Fi, Bluetooth, audio, sliders, power mode, Focus, Settings, power). **Two steps**: drag down again for the notifications, drag up to go back. **Side by side**: the notifications sit next to the utilities box. The corner box and the right-edge notification centre keep working as before.
  - The page has a small handle at the bottom: drag it down / up or tap it to move between the bar, the utilities box and the notifications. It folds back by itself when the pointer leaves (like the media and performance pages), and with Esc / SUPER+Q.
  - New `NotifCentre.qml` (same header and rows as the notification centre, no window of its own). Looking at the notifications here marks them read and hides the popups. The Wi-Fi password field works in the page (it asks for the keyboard like the corner box does); the volume OSD stays quiet while the box is open, like with the corner box.
  - Scrolling over the bar no longer changes pages while one of these two pages is open (it would have fired while moving a slider).
- **Launcher: the arrow keys walk through the apps once you have typed something.** Up / Down move a row, Left / Right one app. With the box empty (or while paging through old searches) Up / Down still step through search history as before; Shift / Alt / Ctrl + Left / Right still move the text cursor.

---

## Clock centring: island and notch

- **Notch: the clock is now always dead centre of the screen.** Before, it only was with Bar spacing "Spacious" or the "Keep the clock centred" switch; by default the bar was just as wide as its content, so the clock sat wherever the content put it. `centerClock` in `NotchBar.qml` is now always on (the shorter side keeps empty space) and the "Keep the clock centred" switch is gone from Settings > Bar style.
- **The ":" of the clock is on the screen's centre line (both bars).** The whole text "05:57 PM" was centred, so the colon sat a few pixels left of the middle (over a centre webcam it looked off). The clock is pushed right by exactly the distance between the middle of the text and the colon, measured from the real font (`colonShift` in `Home.qml` and `NotchBar.qml`); the bar stays centred, the left side gets the extra room.
- **Settings > Clock: "Centre the" (Colon / Whole text) and "Nudge the clock" (4 left ... 6 right).** The colon alignment is on by default; "Whole text" gives the old behaviour, and the nudge adds pixels on top for a screen or webcam that sits a little off. Both bars follow it.
- **Clock shortcuts in the bar (both styles):** right-click the time = 12 / 24 hour, middle-click = seconds.
- **Settings cleanup:** the dead `notchCenter` option is dropped from the defaults and ignored when an old `settings.json` still has it.
- **Island: the time stays centred when one side is empty and while the hover stats slide out.** `Home.qml` used to size the two slots equally only when both had content, and grew only the right slot on hover (which pushed the time left). Both slots now always share one width.

---

## sysmode "mixed" badge fixed, lighter prompt and greeting

- **`[mx]` / "CUSTOM / MIXED" instead of relaxed is fixed.** `sysmode`'s `detect_mode` returned `/etc/sysmode.mode` as written, so a file that still said `cyber` (or `hacking`) matched no mode and was shown as mixed. It now reads `cyber` as `relaxed` and `hacking` as `stealth`, like `stats.sh` and `hx status` already did. Needs the new `sysmode` installed to `/usr/local/bin` (`./update.sh`).
- **Starship no longer runs `sysmode status` on every prompt.** That call ran ~15 commands (systemctl x4, docker inspect, auditctl, pgrep, sysctl ...) before each prompt. The badge now reads `/etc/sysmode.mode` in one small `sh` (`[rx]` relaxed, `[se]` secure, `[st]` stealth, `[ld]` lockdown, `[mx]` anything else), and only asks `sysmode status` when the file does not exist yet. The old badge command also had an escape-code regex that never matched; that is gone with it.
- **`app-themes.sh` fixes an installed `~/.config/starship.toml`** too (the file is yours and is never replaced): only its old `[custom.sysmode]` table is swapped for the new one, once, with a copy kept as `starship.toml.before-sysmode-fix`.
- **The `halcyon` badge is plain text in the prompt format**, so it no longer starts a shell per prompt just to print a constant.
- **fish greeting**: reads the mode file directly (same names and colours as `sysmode status`), uses `$version` and `$USER` instead of `fish --version` / `id -un`, and one `free` call instead of two.

---

## App picker menus (Focus block list, shortcuts) and "cyber" is now "relaxed"

- **New `AppPicker.qml`**: a searchable, scrollable list of every installed app (the launcher's own list, from the desktop entries). Click one and it hands back the app's name, a window class guess, its program name and a ready-to-run command (terminal apps are wrapped so they open in your terminal; arguments are quoted).
- **Settings > Focus > Blocked apps**: "Pick from all your installed apps" blocks an app that is not open right now. It adds the class from the app's launcher entry plus its program name in one write (`focus.sh block CLASS [CLASS...]` now takes several classes). The open-windows chips and the typed class box are still there; if a picked app still opens, click it under "Open right now" while it runs to get its exact class.
- **Shortcuts (SUPER+/) > Your shortcuts**: both the "+ Add a shortcut" form and the editor of a shortcut you added have a **Pick an app instead of typing** button. Choosing an app fills the command (and the name, unless you typed your own); you can still edit the command afterwards.
- **sysmode: the `cyber` mode is now `relaxed`** (`sudo sysmode relaxed`). `cyber` still works as an alias, and an old `/etc/sysmode.mode` that says `cyber` is read as `relaxed` until the next switch. Renamed in the CLI, `sysmode status` (shows RELAXED), the man page, bash completion, the Performance page colour, the quick terminal (`relaxed`, `cyber` still typed as a one-word command), the shortcut tree, the installer text, the README and the Starship prompt badge (`[rx]`, was `[cy]`).

---

## Optional safety check in install.sh and Settings, install.sh shows SUPER+/

- **install.sh now says SUPER + / (not SUPER + Alt + /)** for the shortcut tree in the "First keys" list at the end; the comment in `scripts/cheatsheet.sh` matches. (The binding itself was already SUPER+/ in `keybinds.lua` and `Binds.js`.)
- **Safety check** (new, optional): the `safety-check` program (`src/safety-check`, Rust) runs a system update, a ClamAV malware scan, an rkhunter rootkit check, a firewall check, a Lynis audit, an AIDE integrity check (every 30 days) and a backup to an external disk, with a log in `~/logs/safety_check/`.
  - `./install.sh` asks "Add the safety check?" (default **no**; answer remembered as `SAFETY_CHECK` in `install-choices.env`, so `update.sh` does not ask again). Command line: `--safety-check` / `--no-safety-check` (`update.sh` passes both on); `--choose` asks again.
  - Yes: installs `clamav rkhunter lynis aide ufw rsync libnotify`, builds the crate with the other helpers and installs it **root-owned** as `/usr/local/bin/safety-check` (it runs as root through sudo, so nothing running as you may be able to change it).
  - No: nothing is installed, and a binary left from an earlier "yes" is removed.
  - **Settings > Backup > Safety check** starts it in a terminal (asks for your password). When it is not installed the entry is **greyed out and disabled** and says how to add it (`startup-conf.sh list` reports `has.safety`; `ActionChip` has a new `disabled` state; any Settings item can use `needs: "<has key>"` for the same effect).

---

## Focus mode, corner-box flicker fix, one copy of every duplicated setting

- **Focus mode** (new): utilities box > FOCUS, SUPER+ALT+F, `scripts/focus.sh` + `scripts/focus.py`. Timer (25 / 50 / 90 min, optional Pomodoro with short / long breaks), Do not disturb + Caffeine for the session (restored to what they were afterwards), a block list of window classes that are closed when they open, Pause / +5 min / Skip / Stop, the time left in both bars. Options and the list are in Settings > Focus mode. The "Blocked apps" button in the box opens that group directly (`Settings.show("focus")`).
- **Bottom-right (and bottom-left) box no longer flickers when the pointer rests in the corner.** The layer surface used to grow from a 48 px tab to the full box and shrink back, and every resize made the compositor re-pick the pointer focus: leave, close, shrink, enter, open, again. The surface now keeps one size (the input region still limits what it catches), and a box that has just closed ignores enter events for 600 ms. Costs about the 1.5 MB buffer the old code saved while the box was closed.
- **Settings: duplicates merged, options placed where you look for them.**
  - Bar style had every option twice (island and notch). Each is now ONE entry that writes both (`pair:` keys in `Settings.qml`): workspaces, capsules shown, special icons, music bars, combined status icon, Wi-Fi / look, Bluetooth, battery, battery %, Caffeine icon.
  - The time and the day / date moved from Bar style into **Clock** (the notch's separate "Show the day and date" is gone: one switch for both bars). "Bar spacing" moved into **Bar** next to "Bar size and padding".
  - "Show the background apps count" (notch only) is gone: Bar > Background apps count already decides it.
  - **Edge gestures** existed twice (Touchpad, a temporary mute; Startup, start at login). Now one switch in **Touchpad** (starts / stops the helper and is remembered across logins). SUPER+ALT+G still mutes them for a moment.
  - "Music bars in the bar" (quality Full / Light / Off) moved from Performance to Bar style, right under the Music bars switch, and is called "Music bars quality".
  - The notch's "Accent colour" is now "Notch accent colour" (it had the same name as Colours > Accent colour).

---

## Smart special icons, SUPER+/ cheatsheet, Enter saves, SUPER+Q closes overlays

- **Notch bar: special workspace icons pick a side** (`NotchBar.qml`, Settings > Bar style > Special icons side: Auto / Left / Right). Auto with the clock centred puts them on whichever side does not widen the bar.
- **Island bar: Compact / Spacious (Settings > Bar style) and a truly centred time.** Left and right halves are equal, so the time is dead centre; the music bar floats between the workspaces and the time, the day / date between the time and the status icons.
- **Bar spacing: Compact / Spacious** (Settings > Bar style); spacious keeps the time dead centre with roomier gaps and the music bar floating between the workspaces and the time.
- **Cheatsheet is now SUPER+/** (was SUPER+ALT+/), in `keybinds.lua` and `Binds.js`. Enter saves a shortcut you are adding / editing.
- **SUPER+Q closes the top island overlay first** (power menu, settings, shortcuts, tree view, quick console, notification centre, launcher / perf / media page) and only closes the focused window when none is open (`scripts/close.sh`, IPC `closeTop`).

---

## Mouse move / resize, click-to-reveal auto-hide, combined status icon

- **SUPER + right button drag moves a window, SUPER + left button drag resizes it** (`hyprland/keybinds.lua`, buttons in `variables.lua` as `kbMouseMove` / `kbMouseResize`; listed in the cheatsheet under Windows).
- **Auto-hide now respects Settings > Edge boxes = Click** (island and notch). The hot strip along the top edge used to reveal the bar on hover whatever that setting said; in Click mode it now needs a click, and the bar hides again once the pointer has left it (or after 2.5 s if it never reached it). Hover mode is unchanged.
- **Combined status icon** (`island/StatusRing.qml`, Settings > Bar style > Combined status icon, on by default for both bar styles): Wi-Fi in the centre, the battery as a ring around it, Bluetooth devices as dots closing the ring's gap. `net.sh` now also reports `btn`, the number of connected Bluetooth devices. "Wi-Fi look" is hidden while the combined icon is on. `Settings.qml` `when:` conditions can now be joined with `&`.

---

## Options to use less RAM and CPU (Settings > Performance & memory, Startup & background)

- **Background refresh** (Normal / Relaxed / Slow): `stats.sh` (CPU, battery, sysmode) and `net.sh` (Wi-Fi / Bluetooth state) look again every 2 s / 4 s normally, 5 s / 10 s relaxed, 10 s / 20 s slow. The performance page and the bar's CPU / RAM / TEMP hover row keep the normal pace, and connecting to Wi-Fi or Bluetooth updates the bar label at once. Both scripts wait on a pipe in `$XDG_RUNTIME_DIR` that the island pokes when a flag changes.
- **Music bars** (Full / Light / Off): Light runs `cava` at 15 fps (`cava-light.conf`), Off does not start it. Low / Medium / High now set both options above too.
- **Clipboard history**, **Touchpad edge gestures** and **Screen-sharing helper** (at login / on demand) can be switched off in Startup & background. They used to be fixed lines in `hyprland/execs.lua`; `scripts/autostart-extras.sh` starts them from `~/.config/Halcyon/autostart.conf` now (new keys `CLIPBOARD`, `GESTURES`, `PORTAL`; defaults keep today's behaviour).
- **Fewer process starts**: `net.sh` goes from about 16 program launches per tick to 5; `net.sh`, `stats.sh`, `gpu.sh` and `osd-watch.sh` no longer start a `sleep` per tick (`osd-watch.sh` did it 4 times a second).
- The lock-screen picture and the music cover are decoded at their shown size (2x) instead of the file's own size.
- **Wi-Fi & Bluetooth: only tell me about errors** (Settings > Notifications): skips the "Connected" / "Disconnected" notifications and keeps the failures.

---

## Smaller Thunar icons and a lighter stats loop

- **Thunar icons** (`scripts/thunar-look.sh`): every preset is one step smaller. Medium (default) is now side bar 22, lists 24 px, icon view 48 px (was 24 / 36 / 72). Small and Large moved down the same way. The sizes are re-applied once on the next login for everyone who already had the old ones; a size you set by hand afterwards is left alone.
- **`stats.sh`** (runs every 2 s): `upower` is now found once and read at most every 15 s with a single call, instead of up to five process starts per tick on laptops without sysfs battery estimates. `fmt` is defined once instead of on every tick.
- **`power-manager` and `touchpad-gestures`** now build with the same release profile as the other crates (LTO, one codegen unit, stripped, panic = abort): smaller, faster binaries.
- Removed `scripts/app-themes.sh.bak`, an older copy of `app-themes.sh`.

## Backup this device, btop --force-utf

- **Settings > System > Backup** (new): "Backup this device" and "Backup my home folder only". They open a terminal running `scripts/backup-device.sh`: it lists the external disks that are plugged in (never the system disk), mounts the one you pick, and copies with rsync into `<disk>/Halcyon-backup/<host>/<date>/` (hard-linked to the last run, `latest` link, nothing is erased or formatted). `--dry-run` shows what would be copied.
- CTRL+SHIFT+ESC system monitor now starts `btop --force-utf` (`sysmonCmd` in `variables.lua`).

## Settings, notification spot and Thunar icons

- **Settings tree**: groups and items regrouped by topic (Look, Colours, Wallpaper, Transparency/blur/dimming, Motion, Night light, Workspaces & windows, Bar, Notifications, Panels & on-screen display, Input, Power, Performance & memory, Startup, Default apps, Constellations, Rice). Searching with few hits no longer draws the empty second column's tree line.
- **Notification trigger spot**: new Settings option, right edge (default) or top-right corner.
- **Thunar / GTK icons**: `gtk-theme.sh` uses Papirus-Dark / Papirus-Light when installed (`papirus-icon-theme`, now installed with Thunar; `~/.local/state/island/gtk-icons = off` keeps your own), no washed-out selection effect on icons, higher-contrast toolbar / sidebar / menu icons.

---


## 1. QuickShell Island: Idle High CPU & Memory Leak Resolution

### Problem & Diagnostic
During idle desktop usage, `/usr/bin/quickshell -p ~/.config/Halcyon/quickshell/island` consumed **40% to 63% continuous CPU** on a dedicated core and maintained an elevated RSS memory footprint (~485 MB).

Profiling revealed:
- Six backdrop instances (`Settings`, `PowerMenu`, `Cheatsheet`, `QuickTerm`, `Lock`, `Notifs`) were instantiated at shell startup.
- In each instance, `Backdrop.qml` continuously executed an unthrottled 60 FPS `NumberAnimation on tt` calculating trigonometric coordinates (`Math.sin`, `Math.cos`) across 35 floating dust particles.
- Each `Backdrop.qml` also embedded `ModeArt.qml`, which ran two infinite 60 FPS animation loops (`ph` and `cyc`), a shooting star timer, and trigonometric property bindings for over 160 star particles and traveling light beams—**even when the parent popups and overlay windows were completely closed and hidden**.
- In `Ring.qml`, four 4x MSAA Canvas elements in the performance monitor were animated offscreen on every 2-second polling update from `stats.sh`.
- Continuous QML runtime exceptions (`TypeError: Cannot read property 'indexOf' of undefined` in `Settings.qml` line 261, and `TypeError: Cannot read property '...' of null` in `NotifRow.qml`/`NotifCard.qml`) flooded logs and triggered costly JS exception handler overhead.

### Changes & Fixes
- **`quickshell/island/Backdrop.qml`**:
  - Added a reactive `live` property: `readonly property bool live: visible && opacity > 0.01 && (pal ? pal.motion > 0.3 : true)`.
  - Bound the infinite trigonometric time-loop `NumberAnimation on tt` to `root.live` instead of `root.visible`.
  - Bound the dust particles repeater model to `root.live ? root.dots : 0` to unmount particle delegates when hidden.
  - Forwarded `alive: root.live` to child `ModeArt`.
- **`quickshell/island/ModeArt.qml`**:
  - Bound the star particle repeater model to `root.visible` so offscreen star meshes are not retained in active rendering graphs.
  - Required `opacity > 0.01` in the `live` property to halt traveling beams and shooting star timers during fade transitions.
- **`quickshell/island/Settings.qml`**:
  - Bound `Backdrop` visibility to `root.open && root.opt.stars !== false && root.opt.starsSettings !== false`.
  - Added strict parameter guard to `function get(key)` (line 261) ensuring `key` is a non-null string before calling `.indexOf('/')`, eliminating recurring runtime TypeErrors.
- **`quickshell/island/PowerMenu.qml`**: Bound `Backdrop` visibility to `(root.open || fade.opacity > 0.01) && root.stars`.
- **`quickshell/island/Cheatsheet.qml`**: Bound `Backdrop` visibility to `root.open && root.stars`.
- **`quickshell/island/QuickTerm.qml`**: Bound `Backdrop` visibility to `root.shown && root.stars`.
- **`quickshell/island/Lock.qml`**: Bound `Backdrop` visibility to `root.locked && root.stars`.
- **`quickshell/island/Notifs.qml`**: Bound `Backdrop` visibility to `panel.visible && root.stars`.
- **`quickshell/island/Ring.qml`**: Added `enabled: root.visible` to `Behavior on shown` to suspend offscreen Canvas geometry redraws during periodic stats polls.
- **`quickshell/island/NotifRow.qml` & `quickshell/island/NotifCard.qml`**: Added null/undefined checks for `notif` and `notif.actions` in urgency evaluation, timeout calculations, default action triggers, and text bindings to eliminate TypeError exceptions during notification dismissal and delegate recycling.

### Outcome
Idle CPU usage of the Quickshell island dropped from **~60% to 0.0%**. System temperature, fan noise, and battery drain are substantially reduced.

---

## 2. Installer: Step 10 `user_systemctl` Execution Failure

### Problem
Running `./install.sh` failed at Step 10 (Services) with:
```
env: ‘user_systemctl’: No such file or directory
[ FAIL ] 'Reloading the user systemd' failed (exit code 127)
```

### Root Cause
`install.sh` defines `user_systemctl()` as an internal bash shell function that wraps `run_as_user env "DBUS_SESSION_BUS_ADDRESS=..." systemctl --user "$@"`. Lines 940, 943, and 945 invoked `run_as_user_cmd "..." user_systemctl ...`. `run_as_user_cmd` dispatches via `env`, which searches `PATH` for an external binary named `user_systemctl`. Because `user_systemctl` was a shell function, `env` returned exit code 127.

### Changes & Fixes
- **`install.sh`**:
  - Replaced `run_as_user_cmd` with `run_cmd` for all three calls in Step 10:
    ```bash
    try run_cmd "Reloading the user systemd" user_systemctl daemon-reload
    try run_cmd "Starting touchpad gestures" user_systemctl start touchpad-gestures.service
    [[ "$PACKAGES" == "true" ]] && try run_cmd "Enabling PipeWire for the user" user_systemctl enable --now pipewire pipewire-pulse wireplumber
    ```
  - `user_systemctl` already handles user privilege dropping and session D-Bus routing internally.

---

## 3. Power Manager Daemon: Hardware Compatibility & State Corruption Fixes

### Problems
1. **False Battery Mode**: `ac_online()` strictly looked for `/sys/class/power_supply/AC0/online`. On HP Victus and systems with `/sys/class/power_supply/ACAD/` or `/sys/class/power_supply/ADP1/`, `ac_online()` always returned `false`. This forced the daemon into battery power-saving mode permanently even when connected to wall power, reducing monitor refresh rate, disabling the dGPU, and halting live wallpapers.
2. **Broken AMD Thermal Throttling**: `get_cpu_temp()` checked only for `/sys/class/thermal/thermal_zone*/type == "x86_pkg_temp"`, an Intel-specific sysfs interface. On AMD Ryzen systems (where CPU temperature is exposed via `k10temp` in hwmon or `acpitz`/`Tctl` in thermal zones), it returned `None`, disabling thermal throttling.
3. **Hardcoded 16:10 Aspect Ratio & Monitor Output**: Screen modes were hardcoded to `1920x1200@144` and `1920x1200@60` targeting `eDP-1`. On 16:9 displays (1920x1080) and custom resolutions, sending these commands caused mode mismatches and display failure.
4. **Scheme Lua File Corruption**: `update_scheme_primary` used `content.replace("    primary = \"", &new_primary)` which replaced the prefix but preserved existing trailing characters, resulting in malformed syntax such as `primary = "abcdef",\n123456",`. Furthermore, it only modified `~/.config/hypr/scheme/` and ignored `~/.config/Halcyon/scheme/`.
5. **Hardcoded User Paths**: Fallback home directories hardcoded `/home/netrunner`.

### Changes & Fixes
- **`src/power-manager/src/main.rs`**:
  - **Dynamic AC Supply Scanner**: Rewrote `ac_online()` to scan `/sys/class/power_supply/*`, checking for `type == "Mains"` or supply names prefixed with `AC` or `ADP`, returning `true` if any online indicator equals `1`.
  - **Dual-Layer AMD & Intel CPU Thermal Sensing**: Implemented multi-source sensor discovery:
    1. First inspects `/sys/class/hwmon/` for `k10temp` (AMD Ryzen) and `coretemp` (Intel), reading `temp1_input` or `temp2_input`.
    2. Falls back to `/sys/class/thermal/thermal_zone*` for `x86_pkg_temp`, `k10temp`, `Tctl`, and `acpitz`.
  - **Dynamic Hyprland Display Detection**: Added `get_monitor_config(&mut HyprlandConnection)` querying `j/monitors` over the Hyprland IPC socket to detect the primary display name (`eDP-*`), native resolution (`<width>x<height>`), and peak available refresh rate (e.g., 144Hz vs 60Hz).
  - **Scheme Lua File Integrity**: Rewrote `update_scheme_primary` to parse lines cleanly, replace the entire `primary = "#<hex>",` line, and synchronize both `~/.config/Halcyon/scheme/current.lua` and `~/.config/hypr/scheme/current.lua`.
  - **Dynamic Home Resolution**: Added `get_user_home()` reading `/etc/sysmode.conf` (`SYS_HOME`) with fallback to the active user environment instead of hardcoded paths.

---

## 4. Touchpad Toggle Script: Dynamic Device Discovery

### Problem
`scripts/toggle_touchpad.sh` hardcoded `DEVICE="ascf1201:00-2808:0231-touchpad"` (ASUS ROG Zephyrus). On any other laptop (e.g., HP Victus `elan07fb:00-04f3:321a-touchpad`), toggling the touchpad via shortcut or script did nothing.

### Changes & Fixes
- **`scripts/toggle_touchpad.sh`**:
  - Added dynamic touchpad device discovery using `hyprctl devices -j`:
    ```bash
    DEVICE=$(hyprctl devices -j 2>/dev/null | grep -i '"name":' | grep -i 'touchpad' | head -1 | sed -E 's/.*"name": *"([^"]+)".*/\1/')
    [ -n "$DEVICE" ] || DEVICE="elan07fb:00-04f3:321a-touchpad"
    ```

---

## 5. Sysmode Daemons: Log Path Disconnect

### Problem
`recon-deceiver` and `log-analyst` run as root via systemd (`sysmode-daemons.service`) or `sudo sysmode stealth`. They determined the log output directory via `std::env::var("HOME")`, which resolved to `/root/logs/`. However, `hx status` and user UI widgets read logs from `/home/<user>/logs/` based on `/etc/sysmode.conf`. As a result, honeypot attack metrics and IDS alerts never populated in the desktop interface.

### Changes & Fixes
- **`src/recon-deceiver/src/main.rs`**: Added `/etc/sysmode.conf` parsing (`SYS_USER` and `SYS_HOME`) to `sys_user()` and added `sys_home()`. Set `logs_dir` to `format!("{}/logs", sys_home())`.
- **`src/log-analyst/src/main.rs`**: Added `/etc/sysmode.conf` parsing to `sys_user()` and added `sys_home()`. Set log input and alert output paths to `sys_home()`.
- **`src/attacker-dossier/src/main.rs`**: Updated `logs_dir()` to check `/etc/sysmode.conf` for `SYS_HOME` before falling back to `$HOME`.

---

## 6. Rust Helper Daemons: Compiler Warnings & Algorithmic Optimizations

### Changes & Fixes
- **`src/hx/src/util.rs`**: Added `#[allow(dead_code)]` to unused utility functions `epoch()` and `hostname()` to produce clean compiler output.
- **`src/hx/src/status.rs`**: Replaced $O(N)$ linear scans in a `Vec<String>` for unique attacker IP collection with an $O(1)$ `std::collections::HashSet<String>`, significantly speeding up `hx status` execution when `recon-attempts.log` contains large volumes of events.
- **Binaries Recompiled & Deployed**:
  - Built optimized release binaries for `hx`, `power-manager`, `recon-deceiver`, `log-analyst`, and `attacker-dossier`.
  - Installed binaries into both `/home/sushanth/.config/Halcyon/bin/` and `/usr/local/bin/` / `/usr/local/lib/halcyon/sysmode/`.

---

---

## 7. Quickshell Island: RAM Footprint Reduction (750 MB → ~250 MB)

### Problem & Diagnostic
During desktop usage, `/usr/bin/quickshell -p ~/.config/Halcyon/quickshell/island` consumed **700 MB to 750 MB RSS**.

Deep memory mapping inspection via `/proc/<pid>/smaps` and `/proc/<pid>/smaps_rollup` revealed the root causes:
1. **Font TTC Cache Duplication (~196 MB)**: `Pal.qml` prioritized `"Inter"` in `uiFonts`, which matched `/usr/share/fonts/inter/Inter.ttc` (a 13 MB TrueType Collection). Because Qt Quick creates independent font engines and glyph caches per window and render thread, `Inter.ttc` was mmapped 16 times in memory, consuming nearly 200 MB of page cache RSS.
2. **Unnecessary NVIDIA Driver Blob Loading (~60 MB)**: On hybrid graphics laptops (AMD HawkPoint integrated GPU + NVIDIA RTX 3050 Laptop GPU), Quickshell draws the Wayland desktop entirely on the integrated AMD GPU. However, unconstrained Vulkan and EGL ICD enumeration caused `libvulkan` and `libglvnd` to probe the NVIDIA driver, dlopening `/usr/lib/libnvidia-gpucomp.so` (56 MB) and `/usr/lib/libnvidia-eglcore.so` (4 MB).
3. **Jemalloc Arena & Dirty Page Retention (~100+ MB)**: Quickshell is linked against `libjemalloc.so.2`. On a 16-thread CPU, jemalloc defaults to allocating 64 arenas and retains freed heap memory in thread caches and dirty page lists for extended periods.
4. **Persistent Window Buffers**: Heavy overlay windows (`Settings`, `Cheatsheet`, `PowerMenu`, `Overview`, `Lock`) were created in the scene graph at startup, each maintaining its own Wayland layer surface buffers, QSG render contexts, and texture caches even when closed.
5. **Process Forking in Polling Loops**: `stats.sh` forked ~15 subprocesses (`awk`, `cat`, `sed`, `sort`, `tail`, `pgrep`) every 2 seconds, causing continuous CPU wakeups and memory churn.

### Changes & Fixes
- **`quickshell/island/Pal.qml`**:
  - Placed `"Inter Variable"` before `"Inter"` in `uiFonts`. This loads `/usr/share/fonts/inter/InterVariable.ttf` (860 KB) instead of the 13 MB `Inter.ttc` collection, slashing font mapping RSS from 196 MB down to 9.6 MB (**saving ~187 MB**).
- **`scripts/start-shell.sh`**:
  - **Hybrid GPU Isolation**: Set `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json` and `VK_DRIVER_FILES`/`VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json` to keep Quickshell on the integrated AMD GPU, preventing the 60 MB NVIDIA compiler blob from loading (**saving 60 MB**).
  - **Jemalloc Tuning**: Configured `MALLOC_CONF="narenas:2,dirty_decay_ms:0,muzzy_decay_ms:0,background_thread:true"`, restricting jemalloc to 2 arenas and immediately purging freed memory back to the kernel via `madvise(MADV_DONTNEED)` (**saving ~100+ MB**).
  - **Locale Compose Fix**: Added automatic UTF-8 locale fallback for `xkbcommon`, eliminating `No Compose file for locale` warnings.
- **Window Lazy Loading**: Wrapped `Settings.qml`, `Cheatsheet.qml`, `PowerMenu.qml`, `Overview` (in `shell.qml`), and `Lock.qml` in Quickshell native `LazyLoader` components so they are only allocated when opened, releasing GPU buffers when closed.
- **`quickshell/island/scripts/stats.sh`**: Rewrote `/proc/meminfo`, `/proc/net/dev`, thermal sensor, battery, and AC detection to use pure bash built-ins (zero subprocess forks), dropping execution time from 25ms to <1ms.
- **Reduced Polling Frequency**: Increased periodic fallback heartbeat intervals for `gamingProc` and `caffeineProc` in `shell.qml` from 5s to 15s.

### Outcome
Quickshell island RSS dropped from **~750 MB down to ~218 MB - 250 MB** (a **~500 MB / ~70% memory reduction**), with shared clean memory dropping from 365 MB to 105 MB and anonymous heap memory dropping from 300 MB to 82 MB.

---

## 8. Desktop Shell UX & Stability Fixes

### Changes & Fixes
- **Overview (Super+Tab) Live Tree**:
  - Exposed `readonly property var palObj: pal` on root in `shell.qml` and passed `pal: root.palObj` to `Overview`, resolving scope ambiguity inside `LazyLoader` and eliminating recurring `TypeError: Cannot read property 'surface'/'uiFont' of undefined` exceptions.
  - Provided safe default fallback objects for `pal` in `Overview.qml` and `ImagePicker.qml`.
  - Restored the missing `plural(n, w)` helper function in `Overview.qml`.
- **Launcher & Overview Icon Fallback**:
  - Added strict guards for empty icon strings in `Launcher.qml` (`iconFor`) and `Overview.qml` (`iconFor`), preventing `Quickshell.iconPath("", ...)` from querying invalid `?fallback=application-x-executable` icon requests.
- **Desktop Entry Warning**:
  - Removed stray trailing tab on line 9 of `~/.local/share/applications/valve-vrmonitor.desktop`, eliminating repeated `quickshell.desktopentry: Encountered invalid line in desktop entry (no =)` warnings on startup.
- **Settings & Cheatsheet Layout Stability**:
  - Added safety checks in `Settings.qml` and `Cheatsheet.qml` preventing `ReferenceError: card is not defined` and `TypeError: Cannot call method 'push' of undefined` during search filtering and column layout.

---

## Verification & Status Summary

| Component | Previous State | New State | Verification |
|---|---|---|---|
| **Quickshell Island RAM** | 700 MB – 750 MB RSS | **~218 MB – 250 MB RSS** | Verified via `ps`, `smaps_rollup` (~70% reduction) |
| **Quickshell Island CPU** | 40%–63% continuous CPU | **0.0% idle CPU usage** | Verified via `top` / `ps aux` |
| **Font Mappings** | 16x `Inter.ttc` (196 MB) | **`InterVariable.ttf` (9.6 MB)** | Verified via `/proc/<pid>/maps` |
| **GPU Isolation** | 60 MB NVIDIA blob loaded | **Integrated AMD only (0 MB NVIDIA)** | Verified via `/proc/<pid>/maps` |
| **Installer (`install.sh`)** | Step 10 failed (`exit code 127`) | **Clean execution** | Verified `user_systemctl` invocation |
| **Power Manager** | Stuck on `Battery` (AC0 missing) | **`AC BALANCED` active** | Verified in `power-manager.state` & service journal |
| **CPU Temp Sensing** | `None` on AMD Ryzen HawkPoint | **Active reading via `hwmon` / `k10temp`** | Verified temperature reads correctly |
| **Touchpad Toggle** | Hardcoded ASUS ID | **Dynamic detection (`elan07fb`)** | Tested `hyprctl devices -j` parsing |
| **Sysmode Logs** | Split between `/root/logs` and user home | **Unified to `SYS_HOME/logs`** | Verified config resolution in daemons |
| **Overview (Super+Tab)** | Threw TypeErrors on node render | **Zero errors, smooth rendering** | Tested via Quickshell IPC |
| **Launcher / Desktop Entries** | Missing icon & invalid line warnings | **Zero warnings in log** | Verified in `quickshell-island.log` |


---

## Memory pass: one Quickshell instead of two

- **Wallpaper merged into the island** (`quickshell/island/Wallpaper.qml`, `quickshell/wallpaper/` removed): one Qt/QML/GL stack less. IPC target `wallpaper` now lives in the island instance; `keybinds.lua`, `sysmode`, `shell.qml` and `halcyon-doctor.sh` updated, `execs.lua` no longer starts a second shell.
- **Wallpaper decode size**: `sourceSize` = screen width x height (was up to 2.4x screen width), so each decoded wallpaper is ~9 MB instead of ~21 MB at 1920x1200; the reveal holds two at once.
- **Incoming wallpaper released** after the reveal (it used to keep a second decoded copy + GPU texture alive until the next change).
- **Hyprland process**: `MALLOC_ARENA_MAX=2` + `MALLOC_TRIM_THRESHOLD_=131072` in `launch/halcyon.sh` (opt out: `HALCYON_NO_MALLOC_TUNE=1`).
- New `scripts/halcyon-mem.sh` prints RSS and PSS per Halcyon process for before/after comparisons.
- Trade-off: the wallpaper now restarts together with the island (reload / crash), instead of staying up on its own.

## GPU mode (dgpu / igpu)
`~/.config/Halcyon/gpu-mode` (default shipped: `dgpu`) picks the GPU that draws the desktop. `launch/halcyon.sh` sets `AQ_DRM_DEVICES` (NVIDIA first) and the NVIDIA GBM/GLX/VA-API variables, `start-shell.sh` stops forcing Mesa/radeon for the island, and `power-manager` keeps the NVIDIA GPU powered. Switch with `scripts/gpu-mode.sh igpu|dgpu|status`, then log out and in.

## Lean autostart + small closed edge windows
- `scripts/autostart-extras.sh` (settings: `~/.config/Halcyon/autostart.conf`): polkit agent = lightest installed one (hyprpolkitagent, then polkit-gnome, then polkit-kde); `nm-applet` and `blueman-applet` are off by default (island has its own Wi-Fi / Bluetooth lists; the two applets cost ~60-100 MB). Set `NM_APPLET=1` / `BLUEMAN=1` to get them back (blueman is needed to pair NEW Bluetooth devices from a GUI).
- Utilities box (bottom-right) and background-apps box (bottom-left): the layer surface is a 48x48 tab while closed and grows to the full size only while open / fading, so ~450x900 and ~450x700 buffers are not held all day.

---

## Settings: startup choices and Low / Medium / High resource use

- **Settings > Startup & background** (new): switches for nm-applet and blueman-applet (start / stop at once), a polkit agent picker (Auto, Hyprland, GNOME, KDE, None; next login), the desktop graphics card (Integrated / NVIDIA; next login) and a "Show what uses my RAM" button (runs `scripts/halcyon-mem.sh`). Backed by `scripts/startup-conf.sh`, which edits `~/.config/Halcyon/autostart.conf` and `gpu-mode`.
- **Settings > Performance > Resource use** (new): Low / Medium / High presets. They set blur, shadows, window animations, island animation speed, tree/constellation quality and frame rate, constellations, and the notification list sizes in one go. Every option can still be changed afterwards. Startup items and the GPU are not part of the presets.
- `install.sh` / `update.sh` now keep `gpu-mode` and `autostart.conf`, so a reinstall no longer resets your GPU mode or applet choices.

- **Lock-screen login now works with fish** (`./install.sh --lock-login`): it writes `~/.config/fish/conf.d/halcyon-login.fish`. `--remove-lock-login` deletes it again. bash and zsh work as before.

---

## Choose your apps, and theme them

- **`install.sh`**: new menu (and `--browser`, `--files`, `--editor`, `--sysmode`, `--choose` options) for the web browser, file manager(s), code editor(s) and sysmode. The answers are saved in `~/.local/state/island/install-choices.env` and reused by `update.sh`. Thunar is no longer forced on everybody and Yazi is installed only when chosen. Nothing is installed or made the system default without a choice; `--yes` keeps the old behaviour (keep your browser or Firefox, Thunar, sysmode).
- **`scripts/user-setup.sh`**: `default-apps browser= files= editor=` applies what you picked (and replaces an older choice); `save-choices` writes the saved answers.
- **`scripts/apps.sh`**: Yazi gets its desktop file (so it can be the default for folders); a GUI code editor becomes the default for text and source files.
- **`scripts/app-themes-extra.sh`** (new, sourced by `app-themes.sh`): wallpaper-following themes for VSCodium / Code - OSS / VS Code / Cursor, Zed, Firefox-family browsers (Firefox, Zen, LibreWolf, Floorp, Waterfox) and Qt apps (qt6ct + Kvantum). Existing settings files are backed up once (`*.before-halcyon`); only marked blocks of Halcyon are rewritten.

- **Spotify (spicetify)**: `user.css` now has a Halcyon block (floating rounded panels, card hover with accent border, pill buttons, themed menus and scrollbars); your own CSS below it is kept.
- **Vesktop / Discord**: shape rules on top of the colours (rounded sidebar, input box, menus, modals, code blocks, hover and mention highlights, thin scrollbars) and a themed loading splash. Stock Discord cannot be themed: use Vesktop.
- **Thunar and GTK 3 file managers**: flat toolbar, pill-shaped path bar, rounded side-pane rows with an accent marker, card-style icon view, rubber-band selection, status bar and tabs.

---

## Settings sorted into sections, and clearer Thunar icons

- **Settings are now in a fixed, logical order** with four sections: **Appearance** (Look, Colours, Terminal colours, Wallpaper, Transparency / blur / dimming, Motion, Night light, Constellations), **Desktop** (Bar, Clock, Workspaces & windows, Switching workspaces, Notifications, Panels & on-screen display), **Input & power** (Mouse & pointer, Touchpad, Keyboard, Power, Sleep & lock) and **System** (Performance & memory, Startup & background, Default apps, Rice). Big groups were split (clock out of Bar, workspace switching out of Workspaces, terminal colours out of Colours, touchpad / keyboard / mouse apart, sleep & lock apart from the power manager).
- **Section tabs** under the search box (All / Appearance / Desktop / Input & power / System) show one section at a time; searching still looks through everything.
- The two columns now **keep that order** (top to bottom, then the next column) instead of being balanced by height, which used to shuffle the groups. Each group shows its section next to the title.
- **Thunar icons**: new `scripts/thunar-look.sh` and **Settings > Default apps > File manager icons** (Small / Medium / Large) set Thunar's own sizes: side bar, folder tree, list / compact / icon view zoom and toolbar. Medium is applied once automatically; after that only your choice changes it. `gtk-theme.sh` adds roomier side bar and list rows, 22 px toolbar icons and bigger, bolder file names under icons. Papirus (dark / light) is still the icon theme.

