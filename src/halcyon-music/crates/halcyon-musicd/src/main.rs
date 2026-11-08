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
        "--version" | "-V" => {
            println!("halcyon-musicd {}", halcyon_music_core::CORE_VERSION);
            ExitCode::SUCCESS
        }
        "--login" => login_cli(),
        "--probe" => probe_cli_main(),
        "--eval" => eval_main(&args),
        "--connect-spike" => connect_spike_main(&args),
        "--help" | "-h" => {
            println!(
                "halcyon-musicd — Halcyon Music daemon\n\nUSAGE:\n    halcyon-musicd            run the daemon\n    halcyon-musicd --doctor   check the install and print PASS/WARN/FAIL (exit 1 on any FAIL)\n    halcyon-musicd --version  print the version\n    halcyon-musicd --login    sign in with Spotify in the browser\n    halcyon-musicd --probe    check which Spotify endpoints work with the current sign-in\n    halcyon-musicd --eval [--out DIR] [--write-baseline]\n                              replay the play log offline and score the recommendation engine\n    halcyon-musicd --connect-spike [--volume N]\n                              register as a Spotify Connect device until Ctrl+C (needs --features connect)"
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

/// `--connect-spike`: register as a Spotify Connect device in a separate session (Part 2, Step A).
fn connect_spike_main(args: &[String]) -> ExitCode {
    let volume = match args.iter().position(|a| a == "--volume") {
        Some(i) => match args.get(i + 1).and_then(|v| v.parse::<u8>().ok()) {
            Some(v) if v <= 100 => v,
            _ => {
                eprintln!("--volume needs a number from 0 to 100");
                return ExitCode::from(2);
            }
        },
        None => 50,
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("could not start the async runtime: {e}");
            return ExitCode::from(2);
        }
    };
    match runtime.block_on(halcyon_musicd::connect::run_spike(volume)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// `--eval`: offline scoring of the recommendation engine (Part 3). No network, no Spotify.
fn eval_main(args: &[String]) -> ExitCode {
    use halcyon_musicd::{cache::Cache, eval};
    let state_private = halcyon_music_core::paths::state_dir().join("eval");
    let docs = match args.iter().position(|a| a == "--out") {
        Some(i) => match args.get(i + 1) {
            Some(d) => std::path::PathBuf::from(d),
            None => {
                eprintln!("--out needs a directory");
                return ExitCode::from(2);
            }
        },
        None if std::path::Path::new("docs").is_dir() => std::path::PathBuf::from("docs"),
        None => state_private.clone(),
    };
    let write_baseline = args.iter().any(|a| a == "--write-baseline");

    // The user's own history, if the cache exists (never created by this command).
    let db = halcyon_music_core::paths::cache_dir().join("cache.db");
    let real = if db.exists() {
        match Cache::open_default() {
            Ok(cache) => {
                let mut plays = cache.get_recent_plays(1_000_000).unwrap_or_default();
                // Tracks left early live in their own table; the harness reads both.
                plays.extend(cache.get_skips(1_000_000).unwrap_or_default());
                let liked: std::collections::HashSet<String> = cache
                    .get_liked_tracks(100_000, 0)
                    .map(|(t, _)| t.into_iter().map(|t| t.id).collect())
                    .unwrap_or_default();
                Some((plays, liked))
            }
            Err(e) => {
                eprintln!("could not open the cache ({e}); evaluating the fixtures only");
                None
            }
        }
    } else {
        None
    };

    let out = match eval::build_output(real.as_ref().map(|(p, l)| (p.as_slice(), l))) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("eval failed: {e}");
            return ExitCode::FAILURE;
        }
    };
    println!("{}", out.fixtures_md);
    if let Some(md) = &out.real_md {
        println!("{md}");
    } else {
        println!("No play history found; only the fixtures were scored.");
    }
    let dirs = eval::OutputDirs { docs, private: state_private };
    match eval::write_all(&dirs, &out, write_baseline) {
        Ok(files) => {
            for f in files {
                println!("wrote {}", f.display());
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("could not write the reports: {e}");
            ExitCode::FAILURE
        }
    }
}
