# Manual test: 15 minutes on a real Spotify Premium session

This is the release gate for Halcyon Music (Part 9). Nothing here can be checked by the build:
it needs a real Premium account, a real phone with the Spotify app, and a screen. Run it top to
bottom, tick each line, and write what you saw in the **Result** column. A line that fails is a
bug report: copy the output of `halcyon-musicd --doctor` and the last 50 lines of
`journalctl --user -u halcyon-musicd` with it.

Time budget: about 15 minutes if nothing breaks (the Minutes column adds up to 15). Section 0 is setup and is not counted.

When every row from 1 to 13 passes, this is also the proof that lets you switch Connect on by
default: set `MUSIC_CONNECT_DEFAULT=1` near the top of the Halcyon Music block in `install.sh`
(see `docs/connect.md`). Until then Connect stays opt-in.

## 0. Setup (once, not counted)

1. Build and install with the extras you want to test:

   ```sh
   HALCYON_MUSIC_CONNECT=1 HALCYON_MUSIC_LOCAL_MODEL=1 ./install.sh --yes
   ```

   Without a C++ toolchain the installer skips the built-in model engine and says so; then skip
   the model lines marked **(model)** below, or use Ollama.
2. Check it is the build you think it is: `halcyon-musicd --version` and `halcyon-music --version`
   print the same number, and `systemctl --user status halcyon-musicd` is active.
3. Have your phone on the same Spotify account, Spotify app open.
4. Know your Spotify display name and which avatar you expect (Halcyon's, from `hal avatar`).

## The checklist

| # | Minutes | Do this | Pass when | Result |
| --- | --- | --- | --- | --- |
| 1 | 2 | **Sign in.** Open Halcyon Music, press *Sign in with Spotify*, finish in the browser. Run `halcyon-musicd --doctor`. | The app opens the library. `--doctor` has no FAIL; `streaming token` and `spotify session` are PASS. | |
| 2 | 1 | **Name and avatar.** Open the account menu (top right) and Settings, Account. | Your real Spotify name (not "Spotify user" or "Signed in") and `@username` with a plan chip. The circle shows the Halcyon avatar. `--doctor`: `account name` is PASS. | |
| 3 | 0.5 | **Avatar choice.** In Settings, switch the avatar source to Spotify picture, then back to Halcyon. Replace `~/.config/Halcyon/avatar.png` with another picture. | The circle changes each time (the file change within about 5 s). | |
| 4 | 1 | **Phone sees Halcyon.** On the phone: Spotify, play something, tap the Devices icon. `--doctor`: `connect device`. | "Halcyon (your-hostname)" is listed. `--doctor` says `connect device` PASS. The app's account line says "Connected as Halcyon (...)". | |
| 5 | 1 | **Transfer to Halcyon.** On the phone, pick Halcyon in Devices. | Audio comes out of the computer within a few seconds. The app shows the same song and position (within about a second). | |
| 6 | 1 | **Volume from the phone.** On the phone, move the volume slider. Then move the volume in the app. | The computer's output level follows the phone; the phone's slider follows the app. | |
| 7 | 1 | **Transfer back.** On the phone, pick the phone itself in Devices. Then in the app press play. | Computer audio stops when you transfer away (the app shows paused). Pressing play in the app loads the song again and the phone shows Halcyon as the device. | |
| 8 | 2 | **Daily Mix.** On Home, open Daily Mix 1. Press *Refresh* under it. Open a song's menu and choose *Not my taste*. Press *Refresh* again. | Refresh changes the list. The "not my taste" song is gone from Home and the queue and does not come back after the refresh. Reopening Home twice in a day gives the same mixes. | |
| 9 | 1 | **Less like this and radio.** On another mix choose *Less like this*. In a song's menu choose *Start radio* and let it run. | The mix reshuffles away from that artist or sound. The radio keeps playing past 20 songs without repeating an artist back to back. | |
| 10 | 2 | **Mood playlist (model).** Turn Smart suggestions on (Settings, Smart suggestions). It downloads the built-in model, the card shows its size first. Then *Describe a mood*: "rainy evening, quiet". | The download shows progress and ends with "verified". The playlist appears; every song is a real Spotify track; the first call may take a while, the next is faster. With the model off, nothing is downloaded and nothing breaks. `--doctor`: `model` is PASS. | |
| 11 | 1 | **429 and offline behaviour.** Block the Web API: add the line `127.0.0.1 api.spotify.com` to `/etc/hosts`, restart `halcyon-musicd`. Open Home, Search and the account menu. Then turn wifi off for 20 s and on again. Undo the hosts line afterwards. | No screen is blank and the name is still right. The app says *Cached library* (not "Offline") while the daemon is connected. Search still works through the session. Playback continues. After wifi returns the device re-registers by itself (phone's Devices list). | |
| 12 | 1 | **Reduce motion.** Settings, *Reduce motion* on. Move around: sidebar, Home, open a cover, queue drawer. Turn it off again. | With it on, nothing slides, fades or springs. With it off, motion is soft and nothing stutters. Diagnostics shows frame time under 16 ms while animating. | |
| 13 | 0.5 | **Close and kill.** Close the app window. Then `systemctl --user kill halcyon-musicd` (or kill the process). | Music keeps playing after the window closes. After the kill the daemon is back within a few seconds and the device is listed again within about a minute. | |

Rows 3, 9 and 13 go beyond the plan's list: avatar choice, "Less like this" with radio, and
closing the window. Row 13 is here because the daemon owning playback is the point of the design.

## Not part of the 15 minutes, but run once before a release

1. `scripts/check.sh` exits 0 (check, test, clippy with `-D warnings`).
2. `SOAK_CONNECT=1 SOAK_MODEL=1 scripts/soak_test.sh 30` ends with `Status: PASS`
   (the report is `docs/soak_report.md`; copy the peak and idle memory into the changelog).
3. `halcyon-musicd --model-check` shows every catalogue model reachable with the size and
   checksum the server publishes (the catalogue was written from memory).
4. `halcyon-musicd --reco-probe` shows the outside recommendation sources answering.

## Record

- Date and machine:
- Build (`halcyon-musicd --version`, git commit):
- Phone and Spotify app version:
- Rows that passed:
- Rows that failed, and what you saw:
- Anything that felt slow or wrong even though it passed:
