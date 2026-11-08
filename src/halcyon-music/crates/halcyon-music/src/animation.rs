//! Time-based animation engine with display refresh timing and zero idle CPU.
//!
//! Features:
//! - Easing curves: ease-out cubic, ease-in-out, spring
//! - Zero idle CPU: subscription only ticks while an animation is in flight
//! - `reduce_motion` setting and `GTK_ENABLE_ANIMATIONS=0` check
//! - Performance frame budget tracking (`--perf`)

#![allow(dead_code)]

use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Easing {
    EaseOutCubic,
    EaseInOut,
    Spring,
    Linear,
}

impl Easing {
    pub fn apply(&self, t: f32) -> f32 {
        let t = t.clamp(0.0, 1.0);
        match self {
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
    pub reduce_motion: bool,
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
}

impl Default for AnimationManager {
    fn default() -> Self {
        let reduce_motion = std::env::var("GTK_ENABLE_ANIMATIONS")
            .map(|v| v == "0")
            .unwrap_or(false);

        Self {
            reduce_motion,
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
        }
    }
}

impl AnimationManager {
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
    }

    /// Trigger a page switch transition: the new page floats up into place.
    pub fn animate_page_switch(&mut self) {
        if self.reduce_motion {
            self.page_transition = Animation::instant(1.0);
        } else {
            self.page_transition = Animation::new(0.0, 1.0, 420, Easing::EaseOutCubic);
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
            self.sidebar_pill = Animation::new(from, target_pos, 320, Easing::EaseOutCubic);
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
            self.sidebar_expand = Animation::new(from, target, 260, Easing::EaseOutCubic);
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
            self.queue_expand = Animation::new(from, target, 380, Easing::EaseOutCubic);
        }
    }

    /// 0.0 (closed) to 1.0 (open). Drives the drawer's width.
    pub fn queue_progress(&self) -> f32 {
        self.queue_expand.peek().clamp(0.0, 1.0)
    }

    /// Show toast slide-in.
    pub fn animate_toast_show(&mut self) {
        if self.reduce_motion {
            self.toast_slide = Animation::instant(1.0);
        } else {
            self.toast_slide = Animation::new(0.0, 1.0, 320, Easing::EaseOutCubic);
        }
    }

    /// Advance active animations on display refresh tick.
    pub fn tick(&mut self) {
        let now = Instant::now();
        self.last_frame_time = now.duration_since(self.last_tick);
        self.last_tick = now;

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
}
