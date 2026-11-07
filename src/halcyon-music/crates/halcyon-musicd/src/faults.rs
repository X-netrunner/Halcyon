//! Fault injection engine for soak testing and recovery verification.
//! Enabled when `HALCYON_MUSIC_FAULTS` environment variable is set.

use std::sync::atomic::{AtomicBool, Ordering};
use tracing::warn;

static FAULT_NETWORK_DROP_TRIGGERED: AtomicBool = AtomicBool::new(false);
static FAULT_AUDIO_STALL_TRIGGERED: AtomicBool = AtomicBool::new(false);
static FAULT_AUTH_EXPIRED_TRIGGERED: AtomicBool = AtomicBool::new(false);

/// Check if a specific fault kind is enabled in `HALCYON_MUSIC_FAULTS`.
pub fn is_fault_enabled(fault: &str) -> bool {
    if let Ok(var) = std::env::var("HALCYON_MUSIC_FAULTS") {
        var.split(',').any(|f| f.trim().eq_ignore_ascii_case(fault))
    } else {
        false
    }
}

/// Reset all one-shot fault injection triggers.
pub fn reset_faults() {
    FAULT_NETWORK_DROP_TRIGGERED.store(false, Ordering::SeqCst);
    FAULT_AUDIO_STALL_TRIGGERED.store(false, Ordering::SeqCst);
    FAULT_AUTH_EXPIRED_TRIGGERED.store(false, Ordering::SeqCst);
}

/// Returns true once if `network_drop` fault is requested.
pub fn should_simulate_network_drop() -> bool {
    if is_fault_enabled("network_drop") {
        let prev = FAULT_NETWORK_DROP_TRIGGERED.fetch_or(true, Ordering::SeqCst);
        if !prev {
            warn!("FAULT INJECTION: Simulating transient network drop!");
            return true;
        }
    }
    false
}

/// Returns true once if `auth_expired` fault is requested.
pub fn should_simulate_auth_expired() -> bool {
    if is_fault_enabled("auth_expired") {
        let prev = FAULT_AUTH_EXPIRED_TRIGGERED.fetch_or(true, Ordering::SeqCst);
        if !prev {
            warn!("FAULT INJECTION: Simulating expired access token (401)!");
            return true;
        }
    }
    false
}

/// Returns true if `audio_stall` fault is requested.
pub fn should_simulate_audio_stall() -> bool {
    if is_fault_enabled("audio_stall") {
        let prev = FAULT_AUDIO_STALL_TRIGGERED.fetch_or(true, Ordering::SeqCst);
        if !prev {
            warn!("FAULT INJECTION: Simulating audio engine stall (watchdog trigger)!");
        }
        return true;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fault_checks() {
        std::env::set_var("HALCYON_MUSIC_FAULTS", "network_drop,auth_expired");
        assert!(is_fault_enabled("network_drop"));
        assert!(is_fault_enabled("auth_expired"));
        assert!(!is_fault_enabled("audio_stall"));

        reset_faults();
        assert!(should_simulate_network_drop());
        // Second call should not trigger again because it was one-shot
        assert!(!should_simulate_network_drop());

        std::env::remove_var("HALCYON_MUSIC_FAULTS");
        reset_faults();
        assert!(!is_fault_enabled("network_drop"));
    }
}
