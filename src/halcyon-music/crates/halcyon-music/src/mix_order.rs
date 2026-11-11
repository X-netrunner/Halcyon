//! Applying the optional LLM layer's reorder of a Home mix.
//!
//! The daemon sends only ids. This keeps the songs the GUI already holds, in the daemon's order,
//! and ignores every id it does not have, so a reorder can never add a song. When too few ids match
//! (the mix was rebuilt since) the engine's own order is kept.

use halcyon_music_core::models::Track;
use std::collections::{HashMap, HashSet};

/// Fewest matching songs for a reorder to be used (the daemon never sends fewer than this either).
pub const MIN_KEPT: usize = 10;

/// `tracks` in the order of `ids`, without the ones not named and without repeats. `None` when
/// fewer than `MIN_KEPT` ids match a song in `tracks`.
pub fn reorder(tracks: &[Track], ids: &[String]) -> Option<Vec<Track>> {
    let by_id: HashMap<&str, &Track> = tracks.iter().map(|t| (t.id.as_str(), t)).collect();
    let mut seen: HashSet<&str> = HashSet::new();
    let mut out: Vec<Track> = Vec::new();
    for id in ids {
        if !seen.insert(id.as_str()) {
            continue;
        }
        if let Some(t) = by_id.get(id.as_str()) {
            out.push((*t).clone());
        }
    }
    (out.len() >= MIN_KEPT).then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tracks(n: usize) -> Vec<Track> {
        (0..n)
            .map(|i| {
                Track::simple(
                    format!("id{i}"),
                    format!("S{i}"),
                    "A".into(),
                    "Al".into(),
                    1000,
                )
            })
            .collect()
    }

    fn ids(nums: &[usize]) -> Vec<String> {
        nums.iter().map(|n| format!("id{n}")).collect()
    }

    #[test]
    fn follows_the_daemons_order_and_drops_the_rest() {
        let out = reorder(&tracks(30), &ids(&[11, 10, 9, 8, 7, 6, 5, 4, 3, 2])).expect("ten match");
        let got: Vec<&str> = out.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(got.first(), Some(&"id11"));
        assert_eq!(out.len(), 10, "trimmed");
    }

    #[test]
    fn unknown_ids_and_repeats_are_ignored_and_never_add_a_song() {
        let mut wanted = ids(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 1, 2]);
        wanted.push("not-in-this-mix".to_string());
        let out = reorder(&tracks(20), &wanted).expect("ten distinct matches");
        assert_eq!(out.len(), 10);
        assert!(out.iter().all(|t| t.id.starts_with("id")));
    }

    #[test]
    fn too_few_matches_keep_the_engines_order() {
        assert!(reorder(&tracks(30), &ids(&[1, 2, 3])).is_none());
        assert!(reorder(&tracks(30), &[]).is_none());
        assert!(reorder(&[], &ids(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10])).is_none());
    }

    #[test]
    fn applying_twice_gives_the_same_result() {
        let first = reorder(&tracks(30), &ids(&[5, 4, 3, 2, 1, 0, 6, 7, 8, 9, 10])).expect("first");
        let again = reorder(&first, &ids(&[5, 4, 3, 2, 1, 0, 6, 7, 8, 9, 10])).expect("again");
        assert_eq!(first, again);
    }
}
