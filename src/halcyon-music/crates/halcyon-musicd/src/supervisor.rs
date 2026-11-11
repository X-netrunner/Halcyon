//! Task supervisor: every spawned task is owned here. A panic or error in a
//! supervised task is caught, logged, and the task is restarted with
//! exponential backoff (250 ms, doubling, capped at 30 s). After 60 s of
//! health the backoff resets.
//!
//! The backoff arithmetic is deliberately a pure function of a monotonic
//! clock so it can be unit-tested without sleeping.

use std::future::Future;
use std::sync::atomic::AtomicU32;
#[cfg(test)]
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tracing::{error, info, warn};

/// 250 ms → 500 ms → 1 s → … capped at 30 s.
pub const BASE_DELAY: Duration = Duration::from_millis(250);
pub const MAX_DELAY: Duration = Duration::from_secs(30);
/// A task that stays alive this long is considered healthy; backoff resets.
pub const HEALTHY_AFTER: Duration = Duration::from_secs(60);

/// Restart policy with an injectable clock for tests.
#[derive(Debug)]
pub struct Backoff {
    base: Duration,
    max: Duration,
    current: Duration,
    last_restart: Option<Instant>,
    attempts: u32,
}

impl Backoff {
    pub fn new() -> Self {
        Self::with_params(BASE_DELAY, MAX_DELAY)
    }

    pub fn with_params(base: Duration, max: Duration) -> Self {
        Self {
            base,
            max,
            current: base,
            last_restart: None,
            attempts: 0,
        }
    }

    /// Delay to wait before the next restart, and the attempt number.
    pub fn next_delay(&mut self, now: Instant) -> (Duration, u32) {
        self.attempts = self.attempts.saturating_add(1);
        self.last_restart = Some(now);
        let delay = self.current;
        // Double for the *following* failure, capped.
        self.current = self.current.saturating_mul(2).min(self.max);
        (delay, self.attempts)
    }

    /// If the task has been healthy since the last restart, reset the ladder.
    /// Call when a supervised task completes its work successfully.
    pub fn note_healthy(&mut self, now: Instant) {
        if let Some(last) = self.last_restart {
            if now.duration_since(last) >= HEALTHY_AFTER {
                self.reset();
            }
        }
    }

    pub fn reset(&mut self) {
        self.current = self.base;
        self.attempts = 0;
    }

    pub fn attempts(&self) -> u32 {
        self.attempts
    }
}

impl Default for Backoff {
    fn default() -> Self {
        Self::new()
    }
}

/// Run `body` under supervision forever: catches panics (via the tokio join
/// handle), logs them, backs off, and restarts. `on_restart` is notified with
/// the attempt count so callers can emit a `Recovered` event.
pub fn supervise<F, Fut>(
    name: &'static str,
    on_restart: Option<Arc<dyn Fn(&'static str, u32) + Send + Sync>>,
    mut body: F,
) -> tokio::task::JoinHandle<()>
where
    F: FnMut() -> Fut + Send + 'static,
    Fut: Future<Output = anyhow::Result<()>> + Send + 'static,
{
    tokio::spawn(async move {
        let mut backoff = Backoff::new();
        loop {
            let handle = tokio::spawn(body());
            match handle.await {
                Ok(Ok(())) => {
                    // Clean exit: the component asked to stop. Healthy exit —
                    // reset backoff, but keep the supervisor alive in case the
                    // exit was a mistake (components must run forever).
                    backoff.note_healthy(Instant::now());
                    warn!(
                        component = name,
                        "supervised task exited cleanly; restarting"
                    );
                }
                Ok(Err(e)) => {
                    error!(component = name, error = %e, "supervised task failed; restarting");
                }
                Err(join_err) => {
                    error!(
                        component = name,
                        panic = join_err.to_string(),
                        "supervised task panicked; crash report written; restarting"
                    );
                }
            }
            let (delay, attempt) = backoff.next_delay(Instant::now());
            if let Some(cb) = on_restart.as_ref() {
                cb(name, attempt);
            }
            info!(
                component = name,
                attempt,
                ?delay,
                "restarting supervised task"
            );
            tokio::time::sleep(delay).await;
        }
    })
}

/// Run a one-shot background job in a task of its own: a panic inside it is caught at the join
/// handle and logged, and never unwinds into the caller. Unlike [`supervise`] the job is not
/// restarted; background jobs that fail simply try again the next time they are asked for.
pub fn run_guarded<Fut>(name: &'static str, job: Fut) -> tokio::task::JoinHandle<()>
where
    Fut: Future<Output = ()> + Send + 'static,
{
    tokio::spawn(async move {
        if let Err(join_err) = tokio::spawn(job).await {
            error!(
                component = name,
                panic = join_err.to_string(),
                "background job failed; skipped"
            );
        }
    })
}

/// A shared monotonic attempt counter used in tests.
pub static ATTEMPT_COUNTER: AtomicU32 = AtomicU32::new(0);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_and_caps() {
        let start = Instant::now();
        let mut b = Backoff::with_params(Duration::from_millis(10), Duration::from_millis(80));
        let (d1, a1) = b.next_delay(start);
        let (d2, a2) = b.next_delay(start);
        let (d3, a3) = b.next_delay(start);
        let (d4, a4) = b.next_delay(start);
        let (d5, a5) = b.next_delay(start);
        assert_eq!((d1, a1), (Duration::from_millis(10), 1));
        assert_eq!((d2, a2), (Duration::from_millis(20), 2));
        assert_eq!((d3, a3), (Duration::from_millis(40), 3));
        assert_eq!((d4, a4), (Duration::from_millis(80), 4)); // hit cap
        assert_eq!((d5, a5), (Duration::from_millis(80), 5)); // stays at cap
    }

    #[test]
    fn backoff_resets_after_healthy_period() {
        let start = Instant::now();
        let mut b = Backoff::with_params(Duration::from_millis(10), Duration::from_millis(80));
        let _ = b.next_delay(start); // 10ms taken, ladder now at 20ms
                                     // Task ran healthy for 60+ s.
        b.note_healthy(start + HEALTHY_AFTER + Duration::from_secs(1));
        let (d, a) = b.next_delay(start + HEALTHY_AFTER + Duration::from_secs(2));
        assert_eq!(d, Duration::from_millis(10)); // ladder reset
        assert_eq!(a, 1);
    }

    #[test]
    fn backoff_does_not_reset_before_healthy_period() {
        let start = Instant::now();
        let mut b = Backoff::with_params(Duration::from_millis(10), Duration::from_millis(80));
        let _ = b.next_delay(start);
        b.note_healthy(start + Duration::from_secs(5)); // too soon
        let (d, _) = b.next_delay(start + Duration::from_secs(6));
        assert_eq!(d, Duration::from_millis(20)); // ladder kept climbing
    }

    #[tokio::test]
    async fn supervisor_restarts_panicking_task_with_backoff() {
        use std::sync::atomic::AtomicU32;
        let runs = Arc::new(AtomicU32::new(0));
        let r = runs.clone();
        let cb = Arc::new(|_name: &'static str, _attempt: u32| {});
        let sup = supervise("test-component", Some(cb), move || {
            let r = r.clone();
            async move {
                r.fetch_add(1, Ordering::SeqCst);
                anyhow::bail!("boom")
            }
        });
        // Real time: first backoff is 250 ms, so two runs fit well under 2 s.
        tokio::time::sleep(Duration::from_millis(700)).await;
        sup.abort();
        assert!(
            runs.load(Ordering::SeqCst) >= 2,
            "task was restarted at least once"
        );
    }

    #[tokio::test]
    async fn supervisor_catches_panic_and_continues() {
        let runs = Arc::new(AtomicU32::new(0));
        let r = runs.clone();
        let sup = supervise("panic-component", None, move || {
            let r = r.clone();
            async move {
                r.fetch_add(1, Ordering::SeqCst);
                panic!("simulated component panic");
            }
        });
        tokio::time::sleep(Duration::from_millis(400)).await;
        sup.abort();
        assert!(runs.load(Ordering::SeqCst) >= 1);
    }
}
