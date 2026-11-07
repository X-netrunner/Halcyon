//! LRCLIB API client and tolerant LRC parser.
//!
//! Features:
//! - Exact-match query `/api/get` with fallback to `/api/search`
//! - Tolerant LRC parser handling multiple timestamps per line, word-level `<mm:ss.xx>` tags,
//!   `[offset:+/-ms]` tags, and bad timestamp tolerance
//! - Plain lyrics fallback and instrumental detection
//! - Per-song manual offset (+/- 100ms) adjustments

use halcyon_music_core::models::{LyricLine, LyricWord, Lyrics};
use serde::Deserialize;
use std::time::Duration;
use tracing::{debug, info};

pub const LRCLIB_BASE_URL: &str = "https://lrclib.net/api";
pub const USER_AGENT: &str = "Halcyon-Music/0.2.0 (https://github.com/halcyon-suite/halcyon-music)";

#[derive(Debug, Deserialize)]
pub struct LrclibResponse {
    pub id: Option<i64>,
    pub name: Option<String>,
    #[serde(rename = "trackName")]
    pub track_name: Option<String>,
    #[serde(rename = "artistName")]
    pub artist_name: Option<String>,
    #[serde(rename = "albumName")]
    pub album_name: Option<String>,
    pub duration: Option<f64>,
    #[serde(default)]
    pub instrumental: bool,
    #[serde(rename = "plainLyrics")]
    pub plain_lyrics: Option<String>,
    #[serde(rename = "syncedLyrics")]
    pub synced_lyrics: Option<String>,
}

/// Parse timestamp formatted as `mm:ss`, `mm:ss.xx`, or `mm:ss.xxx` into milliseconds.
pub fn parse_timestamp_ms(s: &str) -> Option<u64> {
    let clean = s.trim().trim_matches(|c| c == '[' || c == ']' || c == '<' || c == '>');
    let mut parts = clean.split(':');
    let mins_str = parts.next()?;
    let secs_str = parts.next()?;

    let mins: u64 = mins_str.parse().ok()?;

    let (secs, ms) = if let Some((sec_part, frac_part)) = secs_str.split_once('.') {
        let sec: u64 = sec_part.parse().ok()?;
        let frac_val: u64 = frac_part.parse().ok()?;
        let ms = match frac_part.len() {
            1 => frac_val.saturating_mul(100),
            2 => frac_val.saturating_mul(10),
            3 => frac_val,
            _ => {
                let frac_trimmed = frac_part.get(..3).unwrap_or(frac_part);
                frac_trimmed.parse::<u64>().unwrap_or(0)
            }
        };
        (sec, ms)
    } else {
        let sec: u64 = secs_str.parse().ok()?;
        (sec, 0)
    };

    Some(mins.saturating_mul(60_000).saturating_add(secs.saturating_mul(1000)).saturating_add(ms))
}

/// Parse word-level tags in a line (e.g., `<00:12.34>word1 <00:13.00>word2`).
/// Returns the cleaned line text and word tokens.
fn parse_words(text_with_words: &str) -> (String, Vec<LyricWord>) {
    if !text_with_words.contains('<') || !text_with_words.contains('>') {
        return (text_with_words.trim().to_string(), Vec::new());
    }

    let mut words = Vec::new();
    let mut clean_text = String::new();
    let mut rest = text_with_words;

    while let Some(start_bracket) = rest.find('<') {
        let before = rest.get(..start_bracket).unwrap_or("");
        if !before.is_empty() {
            clean_text.push_str(before);
        }

        let after_bracket = rest.get(start_bracket..).unwrap_or("");
        if let Some(end_bracket) = after_bracket.find('>') {
            let tag_content = after_bracket.get(1..end_bracket).unwrap_or("");
            let remaining = after_bracket.get(end_bracket + 1..).unwrap_or("");

            if let Some(ts) = parse_timestamp_ms(tag_content) {
                // Find next word or boundary
                let word_end = remaining.find('<').unwrap_or(remaining.len());
                let word_str = remaining.get(..word_end).unwrap_or("").trim();
                if !word_str.is_empty() {
                    clean_text.push_str(word_str);
                    clean_text.push(' ');
                    words.push(LyricWord {
                        start_ms: ts,
                        end_ms: ts.saturating_add(500),
                        text: word_str.to_string(),
                    });
                }
                rest = remaining.get(word_end..).unwrap_or("");
            } else {
                rest = remaining;
            }
        } else {
            break;
        }
    }

    if clean_text.is_empty() {
        (text_with_words.trim().to_string(), Vec::new())
    } else {
        (clean_text.trim().to_string(), words)
    }
}

/// Parse tolerant LRC text into lines and global offset.
pub fn parse_lrc(lrc_text: &str) -> (Vec<LyricLine>, i64) {
    let mut lines = Vec::new();
    let mut global_offset_ms = 0i64;

    for raw_line in lrc_text.lines() {
        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Check for [offset:+/-ms] tag
        if trimmed.starts_with("[offset:") && trimmed.ends_with(']') {
            let inner = trimmed.get(8..trimmed.len().saturating_sub(1)).unwrap_or("");
            if let Ok(val) = inner.trim().parse::<i64>() {
                global_offset_ms = val;
            }
            continue;
        }

        // Check for other ID tags [ti:...], [ar:...], [al:...], [by:...]
        if trimmed.starts_with('[') {
            if let Some(colon_pos) = trimmed.find(':') {
                let tag = trimmed.get(1..colon_pos).unwrap_or("");
                if matches!(tag, "ti" | "ar" | "al" | "by" | "re" | "ve" | "length") {
                    continue;
                }
            }
        }

        // Extract multiple timestamp tags at the beginning of the line: [00:12.34][00:24.56]Text
        let mut timestamps = Vec::new();
        let mut text_start = 0;

        let bytes = trimmed.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            if let Some(&b'[') = bytes.get(i) {
                if let Some(close) = trimmed.get(i..).and_then(|sub| sub.find(']')) {
                    let full_close = i + close;
                    let ts_slice = trimmed.get(i + 1..full_close).unwrap_or("");
                    if let Some(ms) = parse_timestamp_ms(ts_slice) {
                        timestamps.push(ms);
                        i = full_close + 1;
                        text_start = i;
                        continue;
                    }
                }
            }
            break;
        }

        let content = trimmed.get(text_start..).unwrap_or("").trim();
        let (clean_text, words) = parse_words(content);

        for ts in timestamps {
            let adjusted = (ts as i64).saturating_add(global_offset_ms).max(0) as u64;
            lines.push(LyricLine {
                start_ms: adjusted,
                end_ms: None,
                text: clean_text.clone(),
                translation: None,
                words: words.clone(),
            });
        }
    }

    // Sort by timestamp
    lines.sort_by_key(|l| l.start_ms);

    // Compute end_ms based on adjacent start times
    let len = lines.len();
    for idx in 0..len {
        let next_start = lines.get(idx + 1).map(|n| n.start_ms);
        if let Some(cur) = lines.get_mut(idx) {
            let end = match next_start {
                Some(next) => next.min(cur.start_ms.saturating_add(10_000)),
                None => cur.start_ms.saturating_add(6_000),
            };
            cur.end_ms = Some(end);
        }
    }

    (lines, global_offset_ms)
}

/// Parse plain (unsynced) text into lines.
pub fn parse_plain(plain_text: &str) -> Vec<LyricLine> {
    plain_text
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .map(|l| LyricLine {
            start_ms: 0,
            end_ms: None,
            text: l.to_string(),
            translation: None,
            words: Vec::new(),
        })
        .collect()
}

/// Fetch lyrics from LRCLIB with exact match and search fallback.
pub async fn fetch_lrclib(
    http: &reqwest::Client,
    track_id: &str,
    artist: &str,
    title: &str,
    album: &str,
    duration_ms: u64,
) -> Result<Option<Lyrics>, String> {
    let duration_s = (duration_ms / 1000).to_string();

    // 1. Try Exact Match endpoint `/api/get`
    let exact_url = format!("{LRCLIB_BASE_URL}/get");
    let exact_req = http
        .get(&exact_url)
        .header("User-Agent", USER_AGENT)
        .query(&[
            ("artist_name", artist),
            ("track_name", title),
            ("album_name", album),
            ("duration", &duration_s),
        ])
        .timeout(Duration::from_secs(5));

    if let Ok(resp) = exact_req.send().await {
        if resp.status().is_success() {
            if let Ok(item) = resp.json::<LrclibResponse>().await {
                if let Some(lyrics) = convert_lrclib_item(track_id, item) {
                    debug!("Found exact LRCLIB lyrics for {artist} - {title}");
                    return Ok(Some(lyrics));
                }
            }
        }
    }

    // 2. Fallback to Search endpoint `/api/search`
    let search_url = format!("{LRCLIB_BASE_URL}/search");
    let query = format!("{artist} {title}");
    let search_req = http
        .get(&search_url)
        .header("User-Agent", USER_AGENT)
        .query(&[("q", &query)])
        .timeout(Duration::from_secs(5));

    if let Ok(resp) = search_req.send().await {
        if resp.status().is_success() {
            if let Ok(items) = resp.json::<Vec<LrclibResponse>>().await {
                // Find best candidate with lyrics
                for item in items {
                    if let Some(lyrics) = convert_lrclib_item(track_id, item) {
                        info!("Found search fallback LRCLIB lyrics for {artist} - {title}");
                        return Ok(Some(lyrics));
                    }
                }
            }
        }
    }

    Ok(None)
}

fn convert_lrclib_item(track_id: &str, item: LrclibResponse) -> Option<Lyrics> {
    if item.instrumental {
        return Some(Lyrics {
            track_id: track_id.to_string(),
            synced: false,
            lines: vec![LyricLine {
                start_ms: 0,
                end_ms: None,
                text: "♪ Instrumental ♪".to_string(),
                translation: None,
                words: Vec::new(),
            }],
            offset_ms: 0,
        });
    }

    if let Some(synced) = item.synced_lyrics {
        let (lines, offset_ms) = parse_lrc(&synced);
        if !lines.is_empty() {
            return Some(Lyrics {
                track_id: track_id.to_string(),
                synced: true,
                lines,
                offset_ms,
            });
        }
    }

    if let Some(plain) = item.plain_lyrics {
        let lines = parse_plain(&plain);
        if !lines.is_empty() {
            return Some(Lyrics {
                track_id: track_id.to_string(),
                synced: false,
                lines,
                offset_ms: 0,
            });
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_timestamps() {
        assert_eq!(parse_timestamp_ms("[00:12.34]"), Some(12_340));
        assert_eq!(parse_timestamp_ms("[01:05.500]"), Some(65_500));
        assert_eq!(parse_timestamp_ms("[02:10]"), Some(130_000));
        assert_eq!(parse_timestamp_ms("<00:03.20>"), Some(3_200));
    }

    #[test]
    fn test_parse_lrc_multiple_timestamps_and_offset() {
        let lrc = r#"
        [ti:Test Song]
        [offset:500]
        [00:10.00][00:20.00]Repeat line
        [00:30.00]Final line
        "#;

        let (lines, offset) = parse_lrc(lrc);
        assert_eq!(offset, 500);
        assert_eq!(lines.len(), 3);
        // line 1 shifted by +500ms
        assert_eq!(lines[0].start_ms, 10_500);
        assert_eq!(lines[0].text, "Repeat line");
        // line 2 shifted by +500ms
        assert_eq!(lines[1].start_ms, 20_500);
        assert_eq!(lines[1].text, "Repeat line");
        // line 3 shifted by +500ms
        assert_eq!(lines[2].start_ms, 30_500);
        assert_eq!(lines[2].text, "Final line");
    }

    #[test]
    fn test_parse_plain_lyrics() {
        let plain = "First verse\n\nSecond line\nThird line";
        let lines = parse_plain(plain);
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0].text, "First verse");
        assert_eq!(lines[1].text, "Second line");
        assert_eq!(lines[2].text, "Third line");
    }

    #[test]
    fn test_word_level_tags_and_instrumental() {
        let lrc = "[00:05.00]<00:05.10>Hello <00:05.80>World";
        let (lines, _) = parse_lrc(lrc);
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].text, "Hello World");
        assert_eq!(lines[0].words.len(), 2);
        assert_eq!(lines[0].words[0].text, "Hello");
        assert_eq!(lines[0].words[0].start_ms, 5_100);
        assert_eq!(lines[0].words[1].text, "World");
        assert_eq!(lines[0].words[1].start_ms, 5_800);

        let instrumental_item = LrclibResponse {
            id: Some(123),
            name: Some("Song".into()),
            track_name: Some("Song".into()),
            artist_name: Some("Artist".into()),
            album_name: Some("Album".into()),
            duration: Some(180.0),
            instrumental: true,
            plain_lyrics: None,
            synced_lyrics: None,
        };

        let converted = convert_lrclib_item("t_inst", instrumental_item).expect("converted");
        assert!(!converted.synced);
        assert_eq!(converted.lines.len(), 1);
        assert_eq!(converted.lines[0].text, "♪ Instrumental ♪");
    }
}
