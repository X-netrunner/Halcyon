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
        "--reco-explain" => reco_explain_main(&args),
        "--reco-reset" => reco_reset_main(),
        "--reco-probe" => reco_probe_main(),
        "--model-check" => model_check_main(),
        "--model-fetch" => model_fetch_main(&args),
        "--model-bench" => model_bench_main(&args),
        "--help" | "-h" => {
            println!(
                "halcyon-musicd — Halcyon Music daemon\n\nUSAGE:\n    halcyon-musicd            run the daemon\n    halcyon-musicd --doctor   check the install and print PASS/WARN/FAIL (exit 1 on any FAIL)\n    halcyon-musicd --version  print the version\n    halcyon-musicd --login    sign in with Spotify in the browser\n    halcyon-musicd --probe    check which Spotify endpoints work with the current sign-in\n    halcyon-musicd --eval [--out DIR] [--write-baseline]\n                              replay the play log offline and score the recommendation engine\n    halcyon-musicd --reco-explain ARTIST [TITLE]\n                              show what the recommendation ranker makes of an artist or song\n    halcyon-musicd --reco-reset\n                              forget what the ranker learned from your skips and likes (history is kept)\n    halcyon-musicd --reco-probe\n                              check that the outside sources the recommendations use answer as expected\n    halcyon-musicd --model-check\n                              ask the download server about every built-in model (size, checksum)\n    halcyon-musicd --model-fetch ID\n                              download a built-in model from the terminal\n    halcyon-musicd --model-bench [ID|all] [RUNS]\n                              run the prompt fixtures on a built-in model (needs --features local-llm)\n    halcyon-musicd --connect-spike [--volume N]\n                              register as a Spotify Connect device until Ctrl+C (needs --features connect)"
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

/// `--reco-explain ARTIST [TITLE]`: the debug view of the Part 5 ranker. Reads the cache only.
fn reco_explain_main(args: &[String]) -> ExitCode {
    use halcyon_musicd::{cache::Cache, reco::engine};
    let Some(artist) = args.get(2).filter(|a| !a.starts_with("--")) else {
        eprintln!("usage: halcyon-musicd --reco-explain ARTIST [TITLE]");
        return ExitCode::from(2);
    };
    let title = args.get(3).map(String::as_str).unwrap_or("");
    let db = halcyon_music_core::paths::cache_dir().join("cache.db");
    if !db.exists() {
        eprintln!("no play history yet (no cache at {})", db.display());
        return ExitCode::FAILURE;
    }
    match Cache::open_default() {
        Ok(cache) => {
            println!("{}", engine::explain(&cache, artist, title, 0));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("could not open the cache: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `--reco-reset`: the weights go back to the prior and the exploration beliefs are forgotten.
/// The play history is untouched and is not replayed again.
fn reco_reset_main() -> ExitCode {
    use halcyon_musicd::{cache::Cache, reco::model};
    let path = model::default_path();
    let (mut state, _) = model::RecoState::load_or_default(&path);
    let (mut last_play, mut last_skip) = (state.last_play_id, state.last_skip_id);
    let db = halcyon_music_core::paths::cache_dir().join("cache.db");
    if db.exists() {
        if let Ok(cache) = Cache::open_default() {
            last_play = cache.get_recent_plays(1).ok().and_then(|v| v.first().map(|p| p.id)).unwrap_or(last_play);
            last_skip = cache.get_skips(1_000_000).ok().and_then(|v| v.iter().map(|p| p.id).max()).unwrap_or(last_skip);
        }
    }
    state.reset(last_play, last_skip);
    match state.save(&path) {
        Ok(()) => {
            println!("The recommendation model is back to its starting weights ({}).", path.display());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("could not save: {e}");
            ExitCode::FAILURE
        }
    }
}

/// `--reco-probe`: does each outside source answer in the shape the code expects?
fn reco_probe_main() -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("could not start the async runtime: {e}");
            return ExitCode::from(2);
        }
    };
    let http = reqwest::Client::new();
    let rows = runtime.block_on(halcyon_musicd::reco::engine::probe_sources(&http));
    let mut all_ok = true;
    for r in &rows {
        println!("{:<32} {:<5} {}", r.name, if r.ok { "PASS" } else { "FAIL" }, r.detail);
        all_ok &= r.ok;
    }
    if all_ok {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

fn cli_runtime() -> Option<tokio::runtime::Runtime> {
    match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
        Ok(rt) => Some(rt),
        Err(e) => {
            eprintln!("could not start the async runtime: {e}");
            None
        }
    }
}

/// `--model-check`: HEAD every catalogue URL and print status, size and the server's checksum.
fn model_check_main() -> ExitCode {
    use halcyon_musicd::llm::models;
    let Some(rt) = cli_runtime() else { return ExitCode::from(2) };
    let mut all_ok = true;
    for m in models::CATALOGUE {
        match rt.block_on(models::head(m.url)) {
            Ok(h) => println!(
                "{:<24} PASS size={} sha256={}  (catalogue says ~{} MB, licence {})",
                m.id,
                h.total.map(|n| n.to_string()).unwrap_or_else(|| "?".into()),
                h.sha.unwrap_or_else(|| "none".into()),
                m.approx_bytes / 1_000_000,
                m.licence
            ),
            Err(e) => {
                all_ok = false;
                println!("{:<24} FAIL {e}", m.id);
            }
        }
    }
    if all_ok { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}

/// `--model-fetch ID`: download one model with a progress line.
fn model_fetch_main(args: &[String]) -> ExitCode {
    use halcyon_musicd::llm::models;
    let Some(id) = args.get(2) else {
        eprintln!("usage: halcyon-musicd --model-fetch ID   (ids: {})", models::CATALOGUE.iter().map(|m| m.id).collect::<Vec<_>>().join(", "));
        return ExitCode::from(2);
    };
    let Some(spec) = models::find(id) else {
        eprintln!("unknown model {id}");
        return ExitCode::from(2);
    };
    let Some(rt) = cli_runtime() else { return ExitCode::from(2) };
    let cancel = std::sync::atomic::AtomicBool::new(false);
    let mut shown = |p: models::Progress| {
        eprint!("\r{:<10} {:>4} / {:>4} MB   ", p.state, p.done / 1_000_000, p.total / 1_000_000);
    };
    let r = rt.block_on(models::download(&models::Plan::from_spec(spec), &models::models_dir(), &cancel, &mut shown));
    eprintln!();
    match r {
        Ok(how) => {
            println!("{} ready in {} (checked: {how})", spec.id, models::models_dir().display());
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}

/// `--model-bench [ID|all] [RUNS]`: run the fixtures and print a markdown report.
fn model_bench_main(args: &[String]) -> ExitCode {
    use halcyon_musicd::llm::{bench, local, models};
    if !local::engine_available() {
        eprintln!("this build has no built-in model engine; rebuild with `--features local-llm`");
        return ExitCode::from(2);
    }
    let which = args.get(2).map(String::as_str).unwrap_or("all");
    let runs = args.get(3).and_then(|v| v.parse::<usize>().ok()).unwrap_or(3).clamp(1, 20);
    let Some(rt) = cli_runtime() else { return ExitCode::from(2) };
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1);
    let mut any = false;
    for spec in models::CATALOGUE.iter().filter(|m| which == "all" || m.id == which) {
        if !models::disk_status(&models::models_dir(), spec.file).installed {
            eprintln!("{}: not downloaded (run --model-fetch {})", spec.id, spec.id);
            continue;
        }
        any = true;
        let backend = local::LocalGgufBackend::production(spec.id);
        let rows = rt.block_on(bench::run(&backend, runs));
        println!("{}", bench::report(spec.id, &rows, threads));
        local::unload_now();
    }
    if any { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
