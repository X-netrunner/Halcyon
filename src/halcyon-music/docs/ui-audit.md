# UI audit (Part 8)

Written from reading the code and from the numbers the tests can produce. **Nothing here comes from
watching the app run**: this environment has no display and no Spotify session, so there is no
recorded walkthrough and no real frame-time capture. Where a line says "not verified", a person has to look.

## Motion language (done)

`animation.rs` now has one set of tokens. Everything that moves uses them:

| token | value | used by |
| --- | --- | --- |
| `FAST_MS` | 120 | reserved for hover and press (nothing animated by time at this speed yet) |
| `BASE_MS` | 220 | sidebar pill and width, search notch, toast |
| `SLOW_MS` | 420 | page entrance, queue drawer |
| `Easing::Standard` | cubic-bezier(0.2, 0, 0, 1) | everything at `BASE_MS` |
| `Easing::Emphasised` | cubic-bezier(0.05, 0.7, 0.1, 1) | page entrance |
| `Easing::Spring` | back-out overshoot | queue drawer |

Before: 260, 320, 380, 240 and 420 ms with three different curves. A test fails if any animation uses a
duration outside the three tokens.

Reduce motion: `GTK_ENABLE_ANIMATIONS=0` (system, wins) or the new Settings switch (saved in
`~/.local/state/halcyon-music/reduce-motion`). Turning it on stops what is moving at once. Tested in
`animation.rs`: every animation entry point, breath and clock, the visualiser flag. Not verified by eye.

## Frame-time readout (done)

Diagnostics now shows two measurements, and says which is which:

- **Frame cadence**: gaps between animation ticks while something moves (gaps over 250 ms are idle, not
  frames). This is how evenly frames are asked for. It is NOT draw cost.
- **Interface build**: how long `view` took to build the whole interface, against the 16 ms budget.
  Layout and GPU time after that are not included: iced gives no hook for them here.

Numbers: NOT MEASURED. Open Diagnostics on a real session while scrolling Home and playing, and write the
result here: cadence avg/worst, build avg/worst.

## Screens

| screen | state | notes |
| --- | --- | --- |
| Home | chips added: All / Music / New (Music = your music, New = Discover, charts and releases); skeleton and "Jump back in" already existed; empty New shows one line and one action | staggered rise, hover lift and hover play button NOT done |
| Now playing / full screen | unchanged | cover-to-full-screen morph NOT done; lyrics line easing NOT done |
| Queue drawer | width animation now uses the drawer spring token | drag to reorder and a "From your phone" tag NOT done |
| Playlist, album, artist | unchanged | collapsing header, sticky action row, shared-element cover NOT done |
| Settings | Reduce motion row added | |
| Empty, error, offline | `views::empty_state` (icon, one line, one action) added, used on Home/New | other screens still have their own wording: NOT migrated |
| Keyboard | unchanged | a visible focus ring on every control NOT done (iced 0.13 gives per-widget focus only on text inputs) |

## Rendering rules

Checked by reading: the new chips row and empty state use plain rows, columns and buttons, no `stack!` and
no custom layers, so nothing in them can fall out of a scroll area. The earlier rule (covers in one layer,
test a card scrolled half under the player bar while covers change) is NOT re-verified.

## Idle CPU

Unchanged and still correct by construction: `is_animating()` is false when reduce motion is on or nothing
is in flight, which stops the tick subscription. The Home slideshow timer already stopped under reduce
motion. NOT measured (no display).

## What a person must do

1. Run the app, open Diagnostics while scrolling Home with a song playing; paste the two lines above.
2. Click All / Music / New; the shelves should change and rise into place; New with nothing loaded shows the Refresh line.
3. Settings, Appearance, Reduce motion On: pages, sidebar, queue, toast and glow stop animating.
4. Record the 60-second walkthrough from the plan and look for overlap, flicker, layout jumps.
