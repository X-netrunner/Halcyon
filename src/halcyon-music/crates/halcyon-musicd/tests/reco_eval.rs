//! Part 5 guard: the new ranker must not do worse than Part 4 on the fixtures, must predict skips
//! better for the listener whose taste changed, and the reranker must make lists clearly more
//! varied without giving back much. Numbers were first computed with a Python twin of this code
//! (see CHANGELOG); tolerances leave room for the two implementations differing in the last digits.

use halcyon_musicd::eval::{run_fixtures, Metrics, Report};

fn find<'a>(reports: &'a [Report], needle: &str) -> &'a Metrics {
    &reports
        .iter()
        .find(|r| r.engine.contains(needle))
        .unwrap_or_else(|| panic!("no engine matching {needle:?}"))
        .metrics
}

fn get(v: Option<f64>, what: &str) -> f64 {
    v.unwrap_or_else(|| panic!("{what} is n/a"))
}

#[test]
fn the_ranker_is_not_worse_than_part_four_and_predicts_skips_better_after_a_taste_change() {
    for (name, reports) in run_fixtures() {
        let p4 = find(&reports, "taste v2");
        let p5 = find(&reports, "part 5 ranker");
        for (label, old, new) in [
            ("recall", p4.recall_at_k, p5.recall_at_k),
            ("ndcg", p4.ndcg_at_k, p5.ndcg_at_k),
            ("skip auc", p4.skip_auc, p5.skip_auc),
        ] {
            let (o, n) = (get(old, label), get(new, label));
            assert!(n + 0.03 >= o, "{name}: {label} fell from {o:.3} to {n:.3}");
        }
        if name == "recent taste shift" {
            let (o, n) = (get(p4.skip_auc, "auc"), get(p5.skip_auc, "auc"));
            assert!(n >= o + 0.03, "{name}: skip AUC only {o:.3} -> {n:.3}");
        }
    }
}

#[test]
fn the_reranker_makes_lists_more_varied_at_a_bounded_cost() {
    for (name, reports) in run_fixtures() {
        let p4 = find(&reports, "taste v2");
        let rank = find(&reports, "part 5 ranker");
        let pipe = find(&reports, "part 5 pipeline");
        let (dr, dp) = (get(rank.diversity, "diversity"), get(pipe.diversity, "diversity"));
        assert!(dp >= dr + 0.10, "{name}: diversity {dr:.3} -> {dp:.3}");
        assert!(get(pipe.coverage, "coverage") >= get(p4.coverage, "coverage"), "{name}: coverage fell");
        // The price: NDCG may lose a little against Part 4, never a lot.
        let (o, n) = (get(p4.ndcg_at_k, "ndcg"), get(pipe.ndcg_at_k, "ndcg"));
        assert!(n + 0.05 >= o, "{name}: NDCG {o:.3} -> {n:.3}");
        // The AUC of the pipeline stays close to the ranker's: reranking only touches the top.
        let (ar, ap) = (get(rank.skip_auc, "auc"), get(pipe.skip_auc, "auc"));
        assert!(ap + 0.06 >= ar, "{name}: skip AUC {ar:.3} -> {ap:.3}");
    }
}
