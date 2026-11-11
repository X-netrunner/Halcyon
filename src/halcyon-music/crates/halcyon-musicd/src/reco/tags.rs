//! Part 5: artist tags from MusicBrainz, cached for 90 days.
//!
//! The taste clusters and the "tag neighbour" source need tags for artists. MusicBrainz is open and
//! asks for at most one request per second and a descriptive User-Agent. Tags are fetched only for
//! the few artists that candidates need, a handful per build, and an artist with no tags is cached
//! as empty too, so it is not asked for again for 90 days.
//!
//! VERIFY: the response shape (an artist search whose hits carry `tags: [{name, count}]`, and a
//! lookup `?inc=tags`) is from memory and was NOT checked against the live service in the session
//! that wrote this. `halcyon-musicd --reco-probe` checks it.

use crate::cache::Cache;
use crate::suggestions::{normalize_string, token_similarity};
use crate::taste::{artist_key, TagTable, TAG_TTL_SECS};
use std::collections::HashSet;
use std::time::Duration;

pub const USER_AGENT: &str = "HalcyonMusic/0.2 (local desktop player; no account)";
/// MusicBrainz allows 1 request per second.
const PAUSE: Duration = Duration::from_millis(1_100);
/// New artists looked up per build.
pub const TAGS_PER_BUILD: usize = 6;
const MAX_TAGS: usize = 12;
/// A search hit must score at least this (MusicBrainz's own 0..100) and look like the name.
const MIN_HIT_SCORE: i64 = 90;
const MIN_NAME_SIMILARITY: f32 = 0.8;

/// `[{"name": "lo-fi", "count": 3}, ...]` as weights 0 to 1 (the most voted tag is 1).
pub fn parse_tags(v: &serde_json::Value) -> Vec<(String, f64)> {
    let mut raw: Vec<(String, f64)> = v
        .as_array()
        .map(|rows| {
            rows.iter()
                .filter_map(|r| {
                    let name = r["name"].as_str()?.trim().to_lowercase();
                    let count = r["count"].as_f64().unwrap_or(1.0).max(1.0);
                    if name.is_empty() {
                        None
                    } else {
                        Some((name, count))
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    raw.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.cmp(&b.0))
    });
    raw.truncate(MAX_TAGS);
    let top = raw.first().map_or(1.0, |t| t.1);
    raw.into_iter().map(|(n, c)| (n, c / top)).collect()
}

/// The best search hit for `wanted`: its id and the tags the hit already carries (maybe none).
pub fn pick_hit(v: &serde_json::Value, wanted: &str) -> Option<(String, Vec<(String, f64)>)> {
    let want = normalize_string(wanted);
    for hit in v["artists"].as_array()? {
        let score = hit["score"].as_i64().unwrap_or(0);
        let name = normalize_string(hit["name"].as_str().unwrap_or(""));
        if score >= MIN_HIT_SCORE && token_similarity(&name, &want) >= MIN_NAME_SIMILARITY {
            return Some((hit["id"].as_str()?.to_string(), parse_tags(&hit["tags"])));
        }
    }
    None
}

/// Tags for one artist. `Ok(vec![])` = the artist is there and has none (or is not found).
pub async fn fetch_artist_tags(
    http: &reqwest::Client,
    artist: &str,
) -> Result<Vec<(String, f64)>, String> {
    let query = format!("artist:\"{}\"", artist.replace('"', ""));
    let res = http
        .get("https://musicbrainz.org/ws/2/artist/")
        .header("User-Agent", USER_AGENT)
        .query(&[("query", query.as_str()), ("limit", "3"), ("fmt", "json")])
        .timeout(Duration::from_secs(8))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !res.status().is_success() {
        return Err(format!("MusicBrainz search: HTTP {}", res.status()));
    }
    let body: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    let Some((id, tags)) = pick_hit(&body, artist) else {
        return Ok(Vec::new());
    };
    if !tags.is_empty() {
        return Ok(tags);
    }
    tokio::time::sleep(PAUSE).await;
    let res = http
        .get(format!("https://musicbrainz.org/ws/2/artist/{id}"))
        .header("User-Agent", USER_AGENT)
        .query(&[("inc", "tags"), ("fmt", "json")])
        .timeout(Duration::from_secs(8))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !res.status().is_success() {
        return Err(format!("MusicBrainz lookup: HTTP {}", res.status()));
    }
    let body: serde_json::Value = res.json().await.map_err(|e| e.to_string())?;
    Ok(body.get("tags").map(parse_tags).unwrap_or_default())
}

/// The artists of `wanted` that have no fresh tags in `table`, each once, at most `budget`.
pub fn missing(
    table: &TagTable,
    tried: &HashSet<String>,
    wanted: &[String],
    budget: usize,
) -> Vec<String> {
    let mut out = Vec::new();
    if budget == 0 {
        return out;
    }
    let mut seen: HashSet<String> = HashSet::new();
    for a in wanted {
        let key = artist_key(a);
        if key.is_empty() || table.get(&key).is_some() || tried.contains(&key) || !seen.insert(key)
        {
            continue;
        }
        out.push(a.clone());
        if out.len() >= budget {
            break;
        }
    }
    out
}

/// Look up the tags of up to `budget` artists that the cache has not tried within 90 days, and
/// store them (an empty answer too). Returns the artists whose tags are new. A failure of one
/// artist stops the loop (the service is probably unhappy) and is not stored.
pub async fn ensure_tags(
    cache: &Cache,
    http: &reqwest::Client,
    table: &TagTable,
    wanted: &[String],
    now: u64,
    budget: usize,
) -> Vec<String> {
    // Everything the cache holds fresh, including the stored empty answers.
    let tried: HashSet<String> = cache
        .all_artist_tags()
        .unwrap_or_default()
        .into_iter()
        .filter(|(_, _, at)| now.saturating_sub(*at) <= TAG_TTL_SECS)
        .map(|(k, _, _)| k)
        .collect();
    let mut fetched = Vec::new();
    for (i, artist) in missing(table, &tried, wanted, budget)
        .into_iter()
        .enumerate()
    {
        if i > 0 {
            tokio::time::sleep(PAUSE).await;
        }
        match fetch_artist_tags(http, &artist).await {
            Ok(tags) => {
                let _ = cache.put_artist_tags(&artist_key(&artist), &tags, now);
                fetched.push(artist);
            }
            Err(e) => {
                tracing::warn!("artist tags for {artist:?}: {e}");
                break;
            }
        }
    }
    fetched
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tags_become_weights_with_the_most_voted_at_one() {
        let v = json!([{"name": "Lo-Fi", "count": 4}, {"name": "chillhop", "count": 2}, {"name": "", "count": 9}, {"name": "jazz"}]);
        let t = parse_tags(&v);
        assert_eq!(t[0], ("lo-fi".to_string(), 1.0));
        assert_eq!(t[1], ("chillhop".to_string(), 0.5));
        assert_eq!(
            t[2],
            ("jazz".to_string(), 0.25),
            "a tag without a count counts once"
        );
        assert_eq!(t.len(), 3);
        assert!(parse_tags(&json!(null)).is_empty());
        assert!(parse_tags(&json!({"x": 1})).is_empty());
    }

    #[test]
    fn at_most_twelve_tags_are_kept() {
        let rows: Vec<serde_json::Value> = (0..30)
            .map(|i| json!({"name": format!("t{i:02}"), "count": 30 - i}))
            .collect();
        assert_eq!(parse_tags(&serde_json::Value::Array(rows)).len(), MAX_TAGS);
    }

    #[test]
    fn a_search_hit_must_score_high_and_look_like_the_name() {
        let v = json!({"artists": [
            {"id": "wrong", "name": "Ash Ketchum", "score": 100, "tags": []},
            {"id": "low", "name": "Ash", "score": 60},
            {"id": "right", "name": "Ash", "score": 100, "tags": [{"name": "rock", "count": 5}]}]});
        let (id, tags) = pick_hit(&v, "Ash").expect("a hit");
        assert_eq!(id, "right");
        assert_eq!(tags, vec![("rock".to_string(), 1.0)]);
        assert!(pick_hit(&json!({"artists": []}), "Ash").is_none());
        assert!(pick_hit(&json!({"error": "x"}), "Ash").is_none());
        assert!(pick_hit(&v, "Completely Different").is_none());
    }

    #[test]
    fn only_artists_without_fresh_tags_are_looked_up_once_and_within_budget() {
        let mut table = TagTable::default();
        table.insert("Known", &[("rock", 1.0)]);
        let tried: HashSet<String> = ["tried before".to_string()].into_iter().collect();
        let wanted: Vec<String> = [
            "Known",
            "Tried Before",
            "New One",
            "new  one",
            "Another",
            "Third",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        assert_eq!(
            missing(&table, &tried, &wanted, 10),
            vec!["New One", "Another", "Third"]
        );
        assert_eq!(
            missing(&table, &tried, &wanted, 2),
            vec!["New One", "Another"]
        );
        assert!(missing(&table, &tried, &[], 5).is_empty());
        assert!(missing(&table, &tried, &wanted, 0).is_empty());
    }
}
