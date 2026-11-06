//! halcyon-musicd — the Halcyon Music daemon (binary shell over the library).

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

use halcyon_musicd::{daemon, doctor};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    let arg = args.get(1).map(String::as_str).unwrap_or("");

    match arg {
        "--doctor" => match doctor::run() {
            Ok(code) => code,
            Err(e) => {
                eprintln!("doctor failed to run: {e:#}");
                ExitCode::from(2)
            }
        },
        "--help" | "-h" => {
            println!(
                "halcyon-musicd — Halcyon Music daemon\n\nUSAGE:\n    halcyon-musicd            run the daemon\n    halcyon-musicd --doctor   check the install and print PASS/WARN/FAIL"
            );
            ExitCode::SUCCESS
        }
        "" => match daemon::run() {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("halcyon-musicd exited: {e:#}");
                ExitCode::FAILURE
            }
        },
        other => {
            eprintln!("unknown argument: {other} (try --help)");
            ExitCode::from(2)
        }
    }
}
