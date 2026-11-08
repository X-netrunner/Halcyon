# Account identity (Part 1)

Goal: the account menu and Settings show the real Spotify name, `@username`, plan and where the app
is connected, without depending on the rate-limited Web API, with Halcyon's own avatar by default.

## Why the name was missing

The name used to come only from `GET /v1/me`. On the default sign-in the Web API answers 429 with a
very long wait, so that call failed (one warning in the log) and the GUI fell back to "Spotify user".

## Resolution order (`halcyon-musicd/src/profile.rs`, `daemon.rs::refresh_account`)

1. **Cache.** The saved account (kv key `account.me`) is shown at once, even when old.
2. **Session.** Over the streaming session, no Web API quota:
   - `session.username()` gives the canonical username;
   - `session.get_user_attribute("type")` gives the plan ("premium" is shown as Premium; "free" and
     "open" as Free; anything else is left out rather than guessed);
   - `GET /user-profile-view/v3/profile/<username>?playlist_limit=0&artist_limit=0&episode_limit=0`
     through `spclient` gives the name and picture.
3. **Web API.** `GET /v1/me` only when steps 1 and 2 gave no name **and** no rate-limit wait is
   running for that endpoint family.

An answer never makes things worse: a fresh non-empty value replaces an old one, an empty or missing
one never does (`profile::merge`). If the name is still unknown the task tries again in the
background after 10 s, 1 min and 10 min (one task at a time); the Refresh button in Settings
(`RefreshProfile`) cuts the wait short. Nothing blocks the UI.

Protocol changes (additive): `Profile` gained `username` and `plan` (serde defaults, so an older
daemon's event still decodes); new command `refresh_profile`. `PROTOCOL_VERSION` is unchanged.

## What is verified and what is not

**Not run against a real Spotify session. Nothing here was compiled.** Specifically:

| Item | Status |
| --- | --- |
| Path prefix `/user-profile-view/v3/profile/<username>` | Already used by `get_followed_artists` (`.../following`), so the prefix is in use; the bare profile path with the three `*_limit=0` parameters is **assumed**, not seen |
| Shape of the profile answer | **Unknown.** The parser accepts `name` / `display_name`, and `image_url` / `images[0].url` / `image.url`, and reads `uri` = `spotify:user:<name>`; if none match, the first 300 characters of the answer are logged (`profile: no name found in the answer`) so the parser can be fixed from the log |
| `Session::get_user_attribute("type")` in librespot-core 0.8.0 | **Assumed** to exist and return `Option<String>`; if the build fails here, `session.user_data()` is the other spelling to try. Values other than premium/free/open give no plan |
| librespot-core 0.8 source | Not available in the review environment, so it was not read |

## Avatar

Settings > Account > Account picture: **Halcyon avatar** (default), **Spotify picture**, **Initial**.
The chosen source goes first, the other is the fallback, the initial is always the last fallback, so
the circle is never empty (`avatar.rs`: `order`, `pick`). The choice is saved in
`~/.local/state/halcyon-music/avatar-source`.

The Halcyon avatar is the first non-empty file in the same list `hal avatar` uses
(`halcyon_music_core::paths::avatar_candidates_in`, kept in step with `src/hal/src/avatar.rs`):
`~/.face`, `~/.face.icon`, `/var/lib/AccountsService/icons/$USER`,
`~/.config/Halcyon/avatar.{png,jpg,jpeg,webp}`, `~/Pictures/avatar.{png,jpg,jpeg,webp}`.
The GUI looks again every 5 seconds (a few `stat` calls, no shell); a new or changed file is decoded in
the background (`art::local_decode_task`), cropped square and masked to a circle at decode time, so it
updates live.

## Manual check on a real session

1. Sign in. The menu should show your name and `@username` within seconds, with a plan chip.
2. With the Web API blocked (or while it returns 429) restart `halcyon-musicd`: the name is still right.
3. `halcyon-musicd --doctor`: "account name" is PASS (WARN means only the username is known).
4. Replace `~/.config/Halcyon/avatar.png`: the circle changes within about 5 seconds.
5. If the name is missing, look in `journalctl --user -u halcyon-musicd` for `profile:` lines and send
   me the `body_head` text; that is all the parser needs.
