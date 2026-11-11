# Halcyon Music: baseline (Part 0)

Status date: 2026-11-08. Read this before Part 1.

## Honest summary

This baseline was produced **without a Rust toolchain** (the review sandbox has no `cargo`, and no
network to install one). Nothing below was compiled or run here. What was done is a read-through of the
code plus one real fix. **Part 0 is not finished until `scripts/check.sh` exits 0 on your machine.**

Run it from the repo root:

    scripts/check.sh            # check + test + clippy -D warnings, all three always run
    scripts/check.sh --offline  # only already-downloaded crates

It prints PASS/FAIL per step and keeps the output in `docs/check-latest.log`. Paste that log back
if anything fails and the next step is to fix exactly those errors, nothing else.

## Versions (from the manifests, not from a build)

| Item | Value |
| --- | --- |
| Workspace | `src/halcyon-music/`, members `halcyon-music-core` 0.2.0, `halcyon-musicd`, `halcyon-music` |
| Edition | 2021 |
| GUI toolkit | iced `=0.13.1` (tiny-skia + wgpu, image, svg, canvas, advanced) |
| Streaming | librespot 0.8 family (see `crates/halcyon-musicd/Cargo.toml`) |
| Release profile | `panic = "unwind"` (the supervisor must be able to catch and restart) |

## What changed in Part 0

1. **Queue drawer cover/ripples no longer use `stack!`.** `views/queue_drawer.rs` put the orbit
   ripples and the cover in an `iced::widget::stack!` inside a `scrollable`. A stack draws its extra
   children as separate layers after the whole window, so it is the same class of bug that painted
   covers over the player bar elsewhere. It now uses `views::crossfade::Crossfade`, which draws both
   children in the layer the scroll area already clipped. Visible difference to expect: the cover's
   glow (a quad) is now drawn *under* the thin ripples instead of over them, because within one
   layer iced draws quads, then canvas geometry, then images. NOT RUN, NOT SEEN on screen.
2. `scripts/check.sh` added (above).
3. This file.

## Checked by reading (no compiler)

- Cover/overlay fix present: no `iced::widget::stack` around covers in scrolling pages (`home.rs`
  uses `Crossfade`; `art.rs` has no stack; `views/crossfade.rs` draws without `with_layer`).
- Remaining `stack!` uses are not inside a scrollable: `sidebar.rs` nav pill (sidebar is not
  scrolled), `account.rs` menu overlay, `fullscreen.rs` lyrics haze (the scrollable is a child *of*
  the stack, haze sits over it), and the top-level layers in `main.rs`. `views/slide.rs` uses
  `with_layer`, but clips to the intersection with the parent viewport first.
- Every icon in `icons.rs` has its SVG under `assets/icons/` (all `include_bytes!` targets exist).
- Every item imported by `tests/llm_tests.rs`, `llm_playlist_tests.rs` and `llm_rerank_tests.rs`
  exists and is `pub` (`check_connection`, `clear_pause`, `enrich_mixes`, `rerank_mixes`,
  `build_prompt_playlist`, `MockCatalogue`, `ScriptedLlm`, `Step`, `PlayLogEntry`, and so on).
- GUI-side LLM files (`mix_order.rs`, `views/prompt_card.rs`) use only theme tokens, icons and helper
  signatures that exist (`space::XS..LG`, `radius::*`, `type_size::CAPTION/SMALL/BODY`,
  `palette.danger`, `Track::simple`, `play_orb`, `ghost`, `ellipsize`).

## Still untested (be suspicious of these first)

- **Compilation of everything.** the changelog says features 1-2 of the LLM
  layer once passed `cargo check`, but feature 3 (rerank) and the GUI wiring were written without a
  compiler. Expect small type or borrow errors there.
- **`cargo test`**: the changelog says it never ran for the LLM tests (a broken `target/` stopped the
  last attempt). Some expectations in those tests may need adjusting. Do not delete a failing test to
  get green; fix the code or the expectation with a reason.
- **Clippy `-D warnings`** has not been run for the LLM files.
- The queue drawer change above, on screen: scroll the queue so the now-playing cover is half under
  the player bar while the beat pulses, and look for paint over the bar.
- Everything needing a real Spotify session (playback, search through the session, sign-in).

## How to run the soak test

Needs the daemon running (`systemctl --user start halcyon-musicd`):

    scripts/soak_test.sh 30        # 30 minutes; writes docs/soak_report.md

It sends random commands and reports commands that could not be sent, daemon restarts and measured
memory. Part 9 reruns it with Connect and the local model on; for Part 0 it is optional.

## Acceptance for Part 0

`scripts/check.sh` exits 0 and `docs/check-latest.log` shows PASS for check, test and clippy.
