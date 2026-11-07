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

use halcyon_musicd::{daemon, doctor, probe_cli, stream_auth};
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
        "--login" => login_cli(),
        "--probe" => probe_cli_main(),
        "--help" | "-h" => {
            println!(
                "halcyon-musicd — Halcyon Music daemon\n\nUSAGE:\n    halcyon-musicd            run the daemon\n    halcyon-musicd --doctor   check the install and print PASS/WARN/FAIL\n    halcyon-musicd --login    sign in with Spotify in the browser\n    halcyon-musicd --probe    check which Spotify endpoints work with the current sign-in"
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

/// `--login`: run the browser sign-in once, store the streaming token, and exit. Meant for
/// testing and headless setups; the GUI uses the `login_start_librespot` command instead.
fn login_cli() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("could not start the async runtime: {e}");
            return ExitCode::from(2);
        }
    };
    runtime.block_on(async {
        let (cancel_tx, cancel_rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let _ = tokio::signal::ctrl_c().await;
            let _ = cancel_tx.send(());
        });
        println!("Opening your browser to sign in with Spotify (Ctrl+C cancels)...");
        match stream_auth::sign_in(cancel_rx).await {
            Ok(token) => {
                println!(
                    "Signed in. The streaming token is saved and valid for about {} minutes; it renews itself.",
                    token.seconds_left() / 60
                );
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("{e}");
                ExitCode::FAILURE
            }
        }
    })
}

/// `--probe`: PASS/FAIL table of the Web API endpoints for the current browsing mode.
fn probe_cli_main() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("could not start the async runtime: {e}");
            return ExitCode::from(2);
        }
    };
    if runtime.block_on(probe_cli::run()) {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}
