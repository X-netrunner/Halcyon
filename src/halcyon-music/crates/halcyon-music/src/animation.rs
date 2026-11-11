//! Time-based animation engine with display refresh timing and zero idle CPU.
//!
//! Features:
//! - Easing curves: ease-out cubic, ease-in-out, spring
//! - Zero idle CPU: subscription only ticks while an animation is in flight
//! - `reduce_motion` setting and `GTK_ENABLE_ANIMATIONS=0` check
//! - Performance frame budget tracking (`--perf`)

#![allow(dead_code)]

use std::cell::Cell;
use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// The motion language: three durations, two easings, one spring. Every animation in the app uses
/// these, so the whole interface moves with one rhythm.
pub mod motion {
    /// Hover, press, small state changes.
    pub const FAST_MS: u64 = halcyon_music_core::tokens::motion::FAST_MS;
    /// Most things: pills, toasts, the search notch, the sidebar.
    pub const BASE_MS: u64 = halcyon_music_core::tokens::motion::BASE_MS;
    /// Page entrances and drawers.
    pub const SLOW_MS: u64 = halcyon_music_core::tokens::motion::SLOW_MS;
    /// A frame that takes longer than this to build or arrive is a dropped frame.
    pub const FRAME_BUDGET_MS: f32 = 16.0;
}

fn preference_file() -> std::path::PathBuf {
    halcyon_music_core::paths::state_dir().join("reduce-motion")
}

fn desktop_flag() -> Option<std::path::PathBuf> {
    halcyon_music_core::paths::state_dir()
        .parent()
        .map(|state| state.join("halcyon/reduce-motion"))
}

/// The saved "Reduce motion" choice, or the desktop-wide one Halcyon sets (off when neither is set).
pub fn load_preference() -> bool {
    let own = std::fs::read_to_string(preference_file())
        .map(|v| v.trim() == "1")
        .unwrap_or(false);
    own || desktop_flag().is_some_and(|f| f.exists())
}

/// Remember the choice for next launch. Failure is harmless, so it is ignored.
pub fn save_preference(on: bool) {
    let path = preference_file();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let _ = std::fs::write(path, if on { "1" } else { "0" });
}

/// Solve a CSS-style cubic bezier easing `(x1, y1, x2, y2)` at time `t`.
fn bezier(x1: f32, y1: f32, x2: f32, y2: f32, t: f32) -> f32 {
    let t = t.clamp(0.0, 1.0);
    let at = |a: f32, b: f32, s: f32| {
        3.0 * a * (1.0 - s).powi(2) * s + 3.0 * b * (1.0 - s) * s * s + s.powi(3)
    };
    // Find the curve parameter whose x equals `t` (bisection: always converges, and is cheap).
    let (mut lo, mut hi) = (0.0f32, 1.0f32);
    for _ in 0..24 {
        let mid = 0.5 * (lo + hi);
        if at(x1, x2, mid) < t {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    at(y1, y2, 0.5 * (lo + hi))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Easing {
    /// The everyday curve: quick start, long gentle landing (0.2, 0, 0, 1).
    Standard,
    /// For big moves (pages, drawers): a stronger, softer landing (0.05, 0.7, 0.1, 1).
    Emphasised,
    EaseOutCubic,
    EaseInOut,
    Spring,
    Linear,
}

impl Easing {
    pub fn apply(&self, t: f32) -> f32 {
        let t = t.clamp(0.0, 1.0);
        match self {
            Easing::Standard => bezier(0.2, 0.0, 0.0, 1.0, t),
            Easing::Emphasised => bezier(0.05, 0.7, 0.1, 1.0, t),
            Easing::EaseOutCubic => 1.0 - (1.0 - t).powi(3),
            Easing::EaseInOut => t * t * (3.0 - 2.0 * t),
            Easing::Spring => {
                // Damped spring overshoot and settle
                let s = 1.70158;
                let t = t - 1.0;
                t * t * ((s + 1.0) * t + s) + 1.0
            }
            Easing::Linear => t,
        }
    }
}

/// Tracks an active or completed animation.
#[derive(Debug, Clone)]
pub struct Animation {
    start_value: f32,
    target_value: f32,
    duration: Duration,
    started_at: Instant,
    easing: Easing,
    completed: bool,
}

impl Animation {
    pub fn new(start: f32, target: f32, duration_ms: u64, easing: Easing) -> Self {
        Self {
            start_value: start,
            target_value: target,
            duration: Duration::from_millis(duration_ms),
            started_at: Instant::now(),
            easing,
            completed: false,
        }
    }

    pub fn instant(value: f32) -> Self {
        Self {
            start_value: value,
            target_value: value,
            duration: Duration::ZERO,
            started_at: Instant::now(),
            easing: Easing::Linear,
            completed: true,
        }
    }

    /// Update animation progress. Returns the current interpolated value.
    pub fn value(&mut self) -> f32 {
        if self.completed {
            return self.target_value;
        }

        let elapsed = self.started_at.elapsed();
        if elapsed >= self.duration {
            self.completed = true;
            return self.target_value;
        }

        let t = elapsed.as_secs_f32() / self.duration.as_secs_f32();
        let progress = self.easing.apply(t);
        self.start_value + (self.target_value - self.start_value) * progress
    }

    pub fn is_active(&self) -> bool {
        !self.completed && self.started_at.elapsed() < self.duration
    }

    /// Where the animation is heading (or rests).
    pub fn target(&self) -> f32 {
        self.target_value
    }

    /// The current value without advancing any state (usable from `view`).
    pub fn peek(&self) -> f32 {
        if self.completed {
            return self.target_value;
        }
        let elapsed = self.started_at.elapsed();
        if elapsed >= self.duration || self.duration.is_zero() {
            return self.target_value;
        }
        let t = elapsed.as_secs_f32() / self.duration.as_secs_f32();
        self.start_value + (self.target_value - self.start_value) * self.easing.apply(t)
    }
}

/// Central animation manager for the GUI shell.
#[derive(Debug, Clone)]
pub struct AnimationManager {
    /// The effective setting: the person's switch OR the system's (`GTK_ENABLE_ANIMATIONS=0`).
    pub reduce_motion: bool,
    /// The person's own "Reduce motion" switch (Settings), saved between launches.
    pub user_reduce_motion: bool,
    /// The system asks for no animation; the switch cannot override it.
    pub system_reduce_motion: bool,
    pub perf_overlay: bool,
    pub last_frame_time: Duration,
    last_tick: Instant,
    /// When the app started; the slow "breathing" glow is a pure function of time since then.
    epoch: Instant,
    // Page entrance animation
    pub page_transition: Animation,
    // Sidebar active pill position (slot index, 0 = first item)
    pub sidebar_pill: Animation,
    // Sidebar width: 0.0 collapsed (icons only) .. 1.0 fully open
    pub sidebar_expand: Animation,
    // Queue drawer width: 0.0 closed .. 1.0 open
    pub queue_expand: Animation,
    // Skeleton shimmer phase (0.0 ..= 1.0)
    pub shimmer_phase: f32,
    // Toast entrance animation
    pub toast_slide: Animation,
    // Search notch: 1.0 fully out, 0.0 retracted into the title bar
    pub search_reveal: Animation,
    // The Halcyon star in the tabs row: 0.0 pages tucked away .. 1.0 slid out
    pub more_expand: Animation,
    /// Recent gaps between animation ticks in milliseconds (newest last), only while moving.
    frame_gaps: VecDeque<f32>,
    /// How long the last few `view` builds took, in milliseconds.
    view_times: std::cell::RefCell<VecDeque<f32>>,
    /// `true` once a view build was recorded (so idle shows "not measured").
    view_seen: Cell<bool>,
}

/// What the frame-time readout in Diagnostics shows.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct FrameStats {
    /// Ticks measured (while something was moving).
    pub ticks: usize,
    pub avg_gap_ms: f32,
    pub worst_gap_ms: f32,
    /// Ticks that arrived later than the budget plus a vsync of slack.
    pub late_ticks: usize,
    /// Builds of the whole interface (`view`) measured.
    pub views: usize,
    pub avg_view_ms: f32,
    pub worst_view_ms: f32,
    /// Builds that took longer than the 16 ms budget.
    pub slow_views: usize,
}

const FRAME_WINDOW: usize = 240;
/// A gap longer than this means the animation had stopped; it is not a frame.
const IDLE_GAP_MS: f32 = 250.0;

impl Default for AnimationManager {
    fn default() -> Self {
        let reduce_motion = std::env::var("GTK_ENABLE_ANIMATIONS")
            .map(|v| v == "0")
            .unwrap_or(false);

        Self {
            reduce_motion,
            user_reduce_motion: false,
            system_reduce_motion: reduce_motion,
            frame_gaps: VecDeque::new(),
            view_times: std::cell::RefCell::new(VecDeque::new()),
            view_seen: Cell::new(false),
            perf_overlay: false,
            last_frame_time: Duration::ZERO,
            last_tick: Instant::now(),
            epoch: Instant::now(),
            page_transition: Animation::instant(1.0),
            sidebar_pill: Animation::instant(0.0),
            sidebar_expand: Animation::instant(0.0),
            queue_expand: Animation::instant(0.0),
            shimmer_phase: 0.0,
            toast_slide: Animation::instant(0.0),
            search_reveal: Animation::instant(1.0),
            more_expand: Animation::instant(0.0),
        }
    }
}

impl AnimationManager {
    /// Start with the person's saved "Reduce motion" choice.
    pub fn with_preference(user_reduce_motion: bool) -> Self {
        let mut m = Self::default();
        m.set_user_reduce_motion(user_reduce_motion);
        m
    }

    /// The Settings switch. Turning it on stops everything that is moving at once.
    pub fn set_user_reduce_motion(&mut self, on: bool) {
        self.user_reduce_motion = on;
        self.reduce_motion = on || self.system_reduce_motion;
        if self.reduce_motion {
            self.page_transition = Animation::instant(1.0);
            self.toast_slide = Animation::instant(self.toast_slide.target());
            self.sidebar_pill = Animation::instant(self.sidebar_pill.target());
            self.sidebar_expand = Animation::instant(self.sidebar_expand.target());
            self.queue_expand = Animation::instant(self.queue_expand.target());
            self.search_reveal = Animation::instant(self.search_reveal.target());
        }
    }

    /// Note how long one `view` build took (called from `view`, which only has `&self`).
    pub fn record_view(&self, took: Duration) {
        self.view_seen.set(true);
        let mut v = self.view_times.borrow_mut();
        if v.len() >= FRAME_WINDOW {
            v.pop_front();
        }
        v.push_back(took.as_secs_f32() * 1000.0);
    }

    /// Numbers for the diagnostics readout.
    pub fn frame_stats(&self) -> FrameStats {
        let gaps = &self.frame_gaps;
        let views = self.view_times.borrow();
        let avg = |v: &mut dyn Iterator<Item = f32>| {
            let (sum, n) = v.fold((0.0f32, 0usize), |(s, n), x| (s + x, n + 1));
            if n == 0 {
                0.0
            } else {
                sum / n as f32
            }
        };
        FrameStats {
            ticks: gaps.len(),
            avg_gap_ms: avg(&mut gaps.iter().copied()),
            worst_gap_ms: gaps.iter().copied().fold(0.0, f32::max),
            late_ticks: gaps
                .iter()
                .filter(|g| **g > motion::FRAME_BUDGET_MS + 4.0)
                .count(),
            views: views.len(),
            avg_view_ms: avg(&mut views.iter().copied()),
            worst_view_ms: views.iter().copied().fold(0.0, f32::max),
            slow_views: views
                .iter()
                .filter(|v| **v > motion::FRAME_BUDGET_MS)
                .count(),
        }
    }

    /// Forget the readout (the diagnostics "reset" and a fresh measurement).
    pub fn reset_frame_stats(&mut self) {
        self.frame_gaps.clear();
        self.view_times.borrow_mut().clear();
    }

    /// Check whether any animation is actively running.
    /// When false, the iced subscription halts, ensuring ~0% CPU at idle.
    pub fn is_animating(&self) -> bool {
        if self.reduce_motion {
            return false;
        }
        self.page_transition.is_active()
            || self.sidebar_pill.is_active()
            || self.sidebar_expand.is_active()
            || self.queue_expand.is_active()
            || self.toast_slide.is_active()
            || self.search_reveal.is_active()
            || self.more_expand.is_active()
    }

    /// Trigger a page switch transition: the new page floats up into place.
    pub fn animate_page_switch(&mut self) {
        if self.reduce_motion {
            self.page_transition = Animation::instant(1.0);
        } else {
            self.page_transition = Animation::new(0.0, 1.0, motion::SLOW_MS, Easing::Emphasised);
        }
    }

    /// 0.0 (just switched) to 1.0 (settled). Drives the page's rise-into-place offset.
    pub fn page_progress(&self) -> f32 {
        if self.reduce_motion {
            1.0
        } else {
            self.page_transition.peek().clamp(0.0, 1.0)
        }
    }

    /// A slow breathing value from 0.0 to 1.0 and back (about one breath every 9 seconds).
    /// Constant 0.5 when motion is reduced.
    pub fn breath(&self) -> f32 {
        if self.reduce_motion {
            return 0.5;
        }
        let secs = self.epoch.elapsed().as_secs_f32();
        0.5 + 0.5 * (secs * std::f32::consts::TAU / 9.0).sin()
    }

    /// Seconds since the app started; 0.0 when motion is reduced. Drives the visualizer and the
    /// little equalizer bars, which are pure functions of this clock and the playback position.
    pub fn clock(&self) -> f32 {
        if self.reduce_motion {
            0.0
        } else {
            self.epoch.elapsed().as_secs_f32()
        }
    }

    /// Slide the sidebar's active pill from where it is now to `target_pos` (a slot index).
    pub fn animate_sidebar_pill(&mut self, target_pos: f32) {
        let from = self.sidebar_pill.peek();
        if self.reduce_motion {
            self.sidebar_pill = Animation::instant(target_pos);
        } else {
            self.sidebar_pill = Animation::new(from, target_pos, motion::BASE_MS, Easing::Standard);
        }
    }

    /// Put the pill on a slot at once (used when it was hidden, so it does not fly in).
    pub fn set_sidebar_pill(&mut self, pos: f32) {
        self.sidebar_pill = Animation::instant(pos);
    }

    /// Open or close the sidebar. It starts from however open it is right now, so moving the
    /// pointer in and out quickly never makes the width jump.
    pub fn animate_sidebar(&mut self, open: bool) {
        let from = self.sidebar_expand.peek();
        let target = if open { 1.0 } else { 0.0 };
        if self.reduce_motion {
            self.sidebar_expand = Animation::instant(target);
        } else {
            self.sidebar_expand = Animation::new(from, target, motion::BASE_MS, Easing::Standard);
        }
    }

    /// 0.0 (collapsed) to 1.0 (open). Drives the sidebar width and the fade of its labels.
    pub fn sidebar_progress(&self) -> f32 {
        self.sidebar_expand.peek().clamp(0.0, 1.0)
    }

    /// Slide the queue drawer open or closed, from however open it is right now.
    pub fn animate_queue(&mut self, open: bool) {
        let from = self.queue_expand.peek();
        let target = if open { 1.0 } else { 0.0 };
        if self.reduce_motion {
            self.queue_expand = Animation::instant(target);
        } else {
            self.queue_expand = Animation::new(from, target, motion::SLOW_MS, Easing::Spring);
        }
    }

    /// 0.0 (closed) to 1.0 (open). Drives the drawer's width.
    pub fn queue_progress(&self) -> f32 {
        self.queue_expand.peek().clamp(0.0, 1.0)
    }

    /// Slide the search notch out of (or back into) the title bar, from wherever it is now.
    pub fn animate_search(&mut self, show: bool) {
        let from = self.search_reveal.peek();
        let target = if show { 1.0 } else { 0.0 };
        if self.reduce_motion {
            self.search_reveal = Animation::instant(target);
        } else {
            self.search_reveal = Animation::new(from, target, motion::BASE_MS, Easing::Standard);
        }
    }

    /// 0.0 (retracted) to 1.0 (fully out). Drives the search notch.
    pub fn search_progress(&self) -> f32 {
        self.search_reveal.peek().clamp(0.0, 1.0)
    }

    /// Slide the pages behind the tabs row's star out (or back in), from wherever they are now.
    pub fn animate_more(&mut self, open: bool) {
        let from = self.more_expand.peek();
        let target = if open { 1.0 } else { 0.0 };
        if self.reduce_motion {
            self.more_expand = Animation::instant(target);
        } else {
            self.more_expand = Animation::new(from, target, motion::BASE_MS, Easing::Standard);
        }
    }

    /// 0.0 (tucked away) to 1.0 (slid out). Drives the width of the pages behind the star.
    pub fn more_progress(&self) -> f32 {
        self.more_expand.peek().clamp(0.0, 1.0)
    }

    /// Show toast slide-in.
    pub fn animate_toast_show(&mut self) {
        if self.reduce_motion {
            self.toast_slide = Animation::instant(1.0);
        } else {
            self.toast_slide = Animation::new(0.0, 1.0, motion::BASE_MS, Easing::Standard);
        }
    }

    /// Advance active animations on display refresh tick.
    pub fn tick(&mut self) {
        let now = Instant::now();
        self.last_frame_time = now.duration_since(self.last_tick);
        self.last_tick = now;
        let gap = self.last_frame_time.as_secs_f32() * 1000.0;
        if gap < IDLE_GAP_MS {
            if self.frame_gaps.len() >= FRAME_WINDOW {
                self.frame_gaps.pop_front();
            }
            self.frame_gaps.push_back(gap);
        }

        // Advance shimmer phase
        self.shimmer_phase = (self.shimmer_phase + 0.007) % 1.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn easing_functions_endpoints() {
        assert_eq!(Easing::EaseOutCubic.apply(0.0), 0.0);
        assert_eq!(Easing::EaseOutCubic.apply(1.0), 1.0);

        assert_eq!(Easing::EaseInOut.apply(0.0), 0.0);
        assert_eq!(Easing::EaseInOut.apply(1.0), 1.0);
    }

    #[test]
    fn page_progress_is_settled_when_idle() {
        let m = AnimationManager::default();
        assert_eq!(m.page_progress(), 1.0);
    }

    #[test]
    fn sidebar_starts_collapsed_and_opens() {
        let mut m = AnimationManager::default();
        assert_eq!(m.sidebar_progress(), 0.0);
        m.reduce_motion = true;
        m.animate_sidebar(true);
        assert_eq!(m.sidebar_progress(), 1.0);
        m.animate_sidebar(false);
        assert_eq!(m.sidebar_progress(), 0.0);
    }

    #[test]
    fn search_starts_out_and_retracts() {
        let mut m = AnimationManager::default();
        assert_eq!(m.search_progress(), 1.0);
        m.reduce_motion = true;
        m.animate_search(false);
        assert_eq!(m.search_progress(), 0.0);
        m.animate_search(true);
        assert_eq!(m.search_progress(), 1.0);
    }

    #[test]
    fn breath_stays_between_zero_and_one() {
        let m = AnimationManager::default();
        let b = m.breath();
        assert!((0.0..=1.0).contains(&b));
    }

    #[test]
    fn animation_completes_at_duration() {
        let mut anim = Animation::instant(42.0);
        assert!(!anim.is_active());
        assert_eq!(anim.value(), 42.0);
    }

    #[test]
    fn tokens_are_the_three_durations_from_the_plan() {
        assert_eq!(
            (motion::FAST_MS, motion::BASE_MS, motion::SLOW_MS),
            (120, 180, 240)
        );
        assert_eq!(crate::theme::MAX_ANIMATION_MS, motion::SLOW_MS);
    }

    #[test]
    fn new_easings_start_at_zero_end_at_one_and_never_go_backwards() {
        for e in [Easing::Standard, Easing::Emphasised] {
            assert!(e.apply(0.0).abs() < 1e-3 && (e.apply(1.0) - 1.0).abs() < 1e-3);
            let mut prev = 0.0;
            for i in 0..=100 {
                let v = e.apply(i as f32 / 100.0);
                assert!(v + 1e-4 >= prev, "{e:?} went backwards at {i}");
                prev = v;
            }
            // front-loaded: more than half done at half time
            assert!(e.apply(0.5) > 0.6, "{e:?}");
        }
        assert!(Easing::Emphasised.apply(0.3) > Easing::Standard.apply(0.3));
    }

    #[test]
    fn every_started_animation_stays_within_the_slow_token() {
        let mut m = AnimationManager {
            reduce_motion: false,
            ..Default::default()
        };
        m.animate_page_switch();
        m.animate_sidebar_pill(2.0);
        m.animate_sidebar(true);
        m.animate_queue(true);
        m.animate_search(false);
        m.animate_toast_show();
        for a in [
            &m.page_transition,
            &m.sidebar_pill,
            &m.sidebar_expand,
            &m.queue_expand,
            &m.search_reveal,
            &m.toast_slide,
        ] {
            assert!(
                a.duration <= Duration::from_millis(motion::SLOW_MS),
                "{:?}",
                a.duration
            );
            assert!([motion::FAST_MS, motion::BASE_MS, motion::SLOW_MS]
                .contains(&(a.duration.as_millis() as u64)));
        }
    }

    #[test]
    fn the_reduce_motion_switch_turns_every_animation_off() {
        let mut m = AnimationManager {
            system_reduce_motion: false,
            ..Default::default()
        };
        m.set_user_reduce_motion(false);
        m.animate_page_switch();
        m.animate_sidebar(true);
        m.animate_queue(true);
        assert!(m.is_animating());
        m.set_user_reduce_motion(true);
        assert!(m.reduce_motion && m.user_reduce_motion);
        assert!(
            !m.is_animating(),
            "switching it on must stop what is moving"
        );
        assert_eq!(m.page_progress(), 1.0);
        m.animate_page_switch();
        m.animate_sidebar(false);
        m.animate_queue(true);
        m.animate_search(false);
        m.animate_toast_show();
        assert!(!m.is_animating());
        assert_eq!(
            (
                m.sidebar_progress(),
                m.queue_progress(),
                m.search_progress()
            ),
            (0.0, 1.0, 0.0)
        );
        assert_eq!((m.breath(), m.clock()), (0.5, 0.0));
        // and off again
        m.set_user_reduce_motion(false);
        assert!(!m.reduce_motion);
    }

    #[test]
    fn the_system_setting_wins_over_the_switch() {
        let mut m = AnimationManager {
            system_reduce_motion: true,
            ..Default::default()
        };
        m.set_user_reduce_motion(false);
        assert!(
            m.reduce_motion,
            "GTK_ENABLE_ANIMATIONS=0 must stay respected"
        );
        assert!(AnimationManager::with_preference(true).reduce_motion);
    }

    #[test]
    fn frame_stats_ignore_idle_gaps_and_count_slow_work() {
        let mut m = AnimationManager::default();
        assert_eq!(m.frame_stats(), FrameStats::default());
        m.frame_gaps.extend(
            [16.6, 16.7, 40.0, 16.6, 900.0_f32]
                .iter()
                .filter(|g| **g < IDLE_GAP_MS),
        );
        m.record_view(Duration::from_micros(2500));
        m.record_view(Duration::from_millis(20));
        let s = m.frame_stats();
        assert_eq!(s.ticks, 4);
        assert_eq!(s.late_ticks, 1);
        assert!((s.worst_gap_ms - 40.0).abs() < 1e-3);
        assert_eq!((s.views, s.slow_views), (2, 1));
        assert!((s.worst_view_ms - 20.0).abs() < 0.01 && s.avg_view_ms > 10.0);
        m.reset_frame_stats();
        assert_eq!(m.frame_stats(), FrameStats::default());
        // the window is bounded
        for _ in 0..1000 {
            m.record_view(Duration::from_millis(1));
        }
        assert_eq!(m.frame_stats().views, FRAME_WINDOW);
    }

    #[test]
    fn tick_records_gaps_only_while_moving() {
        let mut m = AnimationManager::default();
        m.tick(); // the first gap since creation is tiny, so it counts
        m.last_tick = Instant::now() - Duration::from_secs(5);
        m.tick(); // a 5 s gap is idle, not a frame
        assert_eq!(m.frame_stats().ticks, 1);
    }
}
