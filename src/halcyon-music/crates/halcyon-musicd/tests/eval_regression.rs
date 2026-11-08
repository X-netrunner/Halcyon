//! Part 3 guard: the engine under test must not do worse than the saved baseline on the fixtures.
//! Regenerate the baseline on purpose with `halcyon-musicd --eval --write-baseline` (from
//! src/halcyon-music/) and say why in the changelog.

use halcyon_musicd::eval::{run_fixtures, Report};

const TOLERANCE: f64 = 0.02;

fn load_baseline() -> Vec<(String, Vec<Report>)> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/eval-baseline.json");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}; run --eval --write-baseline", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("baseline is not valid: {e}"))
}

#[test]
fn fixtures_are_reproducible() {
    assert_eq!(run_fixtures(), run_fixtures());
}

#[test]
fn the_current_engine_does_not_regress_against_the_saved_baseline() {
    let baseline = load_baseline();
    let now = run_fixtures();
    assert_eq!(baseline.len(), now.len(), "listener set changed");
    for ((name, base), (_, cur)) in baseline.iter().zip(now.iter()) {
        let b = &base[0].metrics;
        let c = &cur[0].metrics;
        assert_eq!(base[0].engine, cur[0].engine, "{name}: engine order changed");
        // Higher is better for all of these; diversity too (fewer same-artist pairs).
        for (label, old, new) in [
            ("recall", b.recall_at_k, c.recall_at_k),
            ("ndcg", b.ndcg_at_k, c.ndcg_at_k),
            ("skip auc", b.skip_auc, c.skip_auc),
            ("diversity", b.diversity, c.diversity),
            ("coverage", b.coverage, c.coverage),
        ] {
            if let (Some(o), Some(n)) = (old, new) {
                assert!(n + TOLERANCE >= o, "{name}: {label} fell from {o:.3} to {n:.3}");
            }
        }
    }
}
