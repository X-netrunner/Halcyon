//! A fixed set of prompts for comparing built-in models on one machine (`halcyon-musicd --model-bench`).
//!
//! It runs the real prompt builders and the real validators, so "valid" means what it means in the
//! app: the answer parsed and gave something usable. Quality of the words is for a person to read in
//! the samples; the numbers here are validity, latency and memory.

use super::backend::{LlmError, TasteLlm};
use super::prompts;
use super::taste::{ArtistTaste, GenreTaste, TasteSummary};
use super::validate;
use halcyon_music_core::models::{MusicMix, Track};
use std::time::{Duration, Instant};

#[derive(Debug, Clone)]
pub struct CaseResult {
    pub case: &'static str,
    pub runs: usize,
    pub valid: usize,
    pub errors: usize,
    pub latencies: Vec<Duration>,
    pub samples: Vec<String>,
}

impl CaseResult {
    pub fn avg_ms(&self) -> u128 {
        if self.latencies.is_empty() {
            0
        } else {
            self.latencies.iter().map(Duration::as_millis).sum::<u128>() / self.latencies.len() as u128
        }
    }
    pub fn max_ms(&self) -> u128 {
        self.latencies.iter().map(Duration::as_millis).max().unwrap_or(0)
    }
}

pub fn taste() -> TasteSummary {
    let a = |n: &str, w: f32, s: f32| ArtistTaste { name: n.to_string(), weight: w, skip_rate: s };
    TasteSummary {
        top_artists: vec![a("Nova", 1.0, 0.05), a("Echo", 0.7, 0.1), a("Pulse", 0.4, 0.5)],
        top_genres: vec![GenreTaste { name: "ambient".into(), weight: 1.0 }, GenreTaste { name: "synthwave".into(), weight: 0.6 }],
        completion_rate: 0.8,
        currently_into: vec!["Echo".into()],
        stale_favourites: vec!["Nova".into()],
        typical_hours: vec![22, 23],
        plays_considered: 400,
    }
}

fn tracks(n: usize) -> Vec<Track> {
    let artists = ["Nova", "Echo", "Pulse", "Drift", "Haze"];
    (0..n)
        .map(|i| {
            Track::simple(
                format!("id{i}"),
                format!("Song {i}"),
                artists.get(i % artists.len()).copied().unwrap_or("Nova").to_string(),
                "Album".to_string(),
                200_000,
            )
        })
        .collect()
}

fn mix(id: &str, title: &str, n: usize) -> MusicMix {
    MusicMix {
        id: id.to_string(),
        title: title.to_string(),
        description: String::new(),
        source: "Halcyon Local".to_string(),
        tracks: tracks(n),
        art_url: None,
    }
}

const MOODS: &[&str] = &["rainy night coding, no lyrics", "upbeat 90s workout", "slow sunday morning with coffee"];

/// Run every case `runs` times against `llm`.
pub async fn run(llm: &dyn TasteLlm, runs: usize) -> Vec<CaseResult> {
    let t = taste();
    let timeout = llm.call_timeout();
    let mut out = Vec::new();

    let mixes = [mix("a", "On Repeat", 10), mix("b", "Rediscover", 10), mix("c", "Late Night", 10)];
    let refs: Vec<&MusicMix> = mixes.iter().collect();
    let why = prompts::build_why_mix(&t, &refs);
    out.push(
        one(llm, "why-mix", runs, timeout, |_| why.request.clone(), |raw| validate::parse_why_mix(raw, &why.aliases).len() == mixes.len())
            .await,
    );

    out.push(
        one(
            llm,
            "mood-plan",
            runs,
            timeout,
            |i| prompts::build_query(&t, MOODS.get(i % MOODS.len()).copied().unwrap_or("calm")),
            |raw| validate::parse_query(raw).map(|q| !q.genres.is_empty()).unwrap_or(false),
        )
        .await,
    );

    let cands = tracks(14);
    let plan = validate::QuerySpec { genres: vec!["ambient".into()], ..Default::default() };
    let pick = prompts::build_pick(&t, MOODS.first().copied().unwrap_or("calm"), &plan, &cands);
    out.push(
        one(llm, "mood-pick", runs, timeout, |_| pick.request.clone(), |raw| {
            validate::parse_pick(raw, &pick.aliases).map(|p| !p.ids.is_empty()).unwrap_or(false)
        })
        .await,
    );

    let rr = prompts::build_rerank(&t, "On Repeat", &cands);
    out.push(
        one(llm, "rerank", runs, timeout, |_| rr.request.clone(), |raw| {
            validate::parse_pick(raw, &rr.aliases).map(|p| p.ids.len() >= 3).unwrap_or(false)
        })
        .await,
    );
    out
}

async fn one(
    llm: &dyn TasteLlm,
    case: &'static str,
    runs: usize,
    timeout: Duration,
    request: impl Fn(usize) -> super::backend::LlmRequest,
    usable: impl Fn(&str) -> bool,
) -> CaseResult {
    let mut r = CaseResult { case, runs, valid: 0, errors: 0, latencies: Vec::new(), samples: Vec::new() };
    for i in 0..runs {
        let req = request(i);
        let start = Instant::now();
        let res: Result<String, LlmError> = super::call_with_retry(llm, &req, timeout).await;
        r.latencies.push(start.elapsed());
        match res {
            Ok(text) => {
                if usable(&text) {
                    r.valid += 1;
                }
                if r.samples.len() < 3 {
                    r.samples.push(text);
                }
            }
            Err(e) => {
                r.errors += 1;
                if r.samples.len() < 3 {
                    r.samples.push(format!("ERROR: {e}"));
                }
            }
        }
    }
    r
}

/// Resident and peak memory of this process in MB, from /proc (Linux).
pub fn memory_mb() -> (u64, u64) {
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    let kb = |key: &str| {
        status
            .lines()
            .find(|l| l.starts_with(key))
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(0)
    };
    (kb("VmRSS:") / 1024, kb("VmHWM:") / 1024)
}

/// A markdown block to paste into docs/model-choice.md.
pub fn report(model: &str, rows: &[CaseResult], threads: usize) -> String {
    let (rss, peak) = memory_mb();
    let mut s = format!("### {model}\n\n| case | valid | errors | avg ms | max ms |\n| --- | --- | --- | --- | --- |\n");
    for r in rows {
        s.push_str(&format!("| {} | {}/{} | {} | {} | {} |\n", r.case, r.valid, r.runs, r.errors, r.avg_ms(), r.max_ms()));
    }
    s.push_str(&format!("\nProcess memory after the run: {rss} MB resident, {peak} MB peak. CPU threads available: {threads}.\n\nSamples (read these for quality):\n\n"));
    for r in rows {
        for sample in r.samples.iter().take(2) {
            s.push_str(&format!("- {}: `{}`\n", r.case, sample.replace('`', "'")));
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::mock::{ScriptedLlm, Step};

    #[tokio::test]
    async fn bench_counts_valid_and_failed_answers() {
        let good_why = r#"{"mixes":[{"id":"m1","title":"One","reason":"A fine reason here."},{"id":"m2","title":"Two","reason":"A fine reason here."},{"id":"m3","title":"Three","reason":"A fine reason here."}]}"#;
        let plan = r#"{"title":"Calm Code","seed_artists":[],"genres":["ambient"],"energy":0.3,"instrumental":true,"era":null}"#;
        let pick = r#"{"title":"Calm Code","reason":"Quiet picks for late hours.","picks":["t1","t2","t3"]}"#;
        let rerank = r#"{"picks":["t3","t1","t2"]}"#;
        let llm = ScriptedLlm::new(vec![
            Step::Reply(good_why.into()),
            Step::Reply(plan.into()),
            Step::Reply("not json".into()),
            Step::Reply(pick.into()),
            Step::Reply(rerank.into()),
        ]);
        let rows = run(&llm, 1).await;
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].valid, 1);
        assert_eq!(rows[1].valid, 1);
        assert_eq!(rows[2].valid, 0, "plain text is not a usable pick");
        assert_eq!(rows[3].valid, 1);
        let md = report("mock", &rows, 4);
        assert!(md.contains("| why-mix | 1/1 |") && md.contains("### mock"));
    }
}
