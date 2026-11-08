//! Library surface of the daemon, used by integration tests.
//! The binary itself is a thin shell over [`daemon::run`].

// Part 0 rules apply to non-test code; tests may use expect/unwrap freely.
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing
    )
)]

pub mod api;
pub mod art;
pub mod audio;
pub mod auth;
pub mod auth_mode;
pub mod beat;
pub mod cache;
pub mod daemon;
pub mod doctor;
pub mod faults;
pub mod lyrics;
pub mod mpris;
pub mod panic_hook;
pub mod probe_cli;
pub mod probes;
pub mod sd_notify;
pub mod session_browse;
pub mod state_store;
pub mod stream_auth;
pub mod suggestions;
pub mod supervisor;
pub mod tap;
pub mod token_store;

/// Entry point used by both the real `main` and the socket integration test.
pub fn daemon_run_for_test() -> anyhow::Result<()> {
    daemon::run()
}
