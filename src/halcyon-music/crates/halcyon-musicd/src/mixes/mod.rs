//! Part 6: recommended playlists, built on the Part 4 taste profile and the Part 5 pipeline.
//!
//! ```text
//!   clock.rs   dates and weekdays with a fake clock          (pure)
//!   mod.rs     the kinds of mix, their schedules, titles      (pure)
//!              and one-line reasons
//!   plan.rs    which candidates a kind may use, the caps,     (pure)
//!              the blocklist, Smart Shuffle and radio order
//!   store.rs   what was built and what you said about it      (a JSON file)
//!   build.rs   the daemon side: build, refresh, feedback,     (async)
//!              radio, Smart Shuffle
//! ```
//!
//! Rules (master plan, Part 6): a mix does not reshuffle on every launch. It changes on its own
//! schedule (Daily Mix and On Repeat every day, Discover Weekly on Monday, Release Radar on
//! Friday, Repeat Rewind on Wednesday, Daylist three times a day) or when the listener taps
//! Refresh. Every mix carries a one-line reason. "Less like this" and "Not my taste" reach the
//! taste model at once. Nothing here needs the Spotify Web API.

pub mod build;
pub mod clock;
pub mod plan;
pub mod store;

use crate::reco::bandit::fnv64;
use crate::taste::artist_key;
use clock::{
    date_string, last_weekday_on_or_before, local_day, local_hour, next_weekday_after, to_unix,
    weekday, weekday_name,
};
use halcyon_music_core::state::Track;

/// Most Daily Mixes (one per taste cluster).
pub const MAX_DAILY_MIXES: usize = 6;
/// Songs per list.
pub const DAILY_LEN: usize = 30;
pub const DISCOVER_LEN: usize = 30;
pub const RADAR_LEN: usize = 25;
pub const REPEAT_LEN: usize = 30;
pub const DAYLIST_LEN: usize = 30;
pub const RADIO_BATCH: usize = 20;

/// Monday.
pub const DISCOVER_WEEKDAY: u32 = 0;
/// Friday.
pub const RELEASE_WEEKDAY: u32 = 4;
/// Wednesday: spreads the Spotify lookups over the week.
pub const REWIND_WEEKDAY: u32 = 2;
/// The Daylist changes at these hours of the listener's day: three times a day.
pub const DAYLIST_SLOT_HOURS: [u32; 3] = [5, 12, 19];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum MixKind {
    DailyMix,
    DiscoverWeekly,
    ReleaseRadar,
    OnRepeat,
    RepeatRewind,
    Daylist,
}

impl MixKind {
    pub const ALL: [MixKind; 6] = [
        MixKind::DailyMix,
        MixKind::DiscoverWeekly,
        MixKind::ReleaseRadar,
        MixKind::OnRepeat,
        MixKind::RepeatRewind,
        MixKind::Daylist,
    ];

    /// The wire name (`MixMeta::kind`).
    pub fn name(self) -> &'static str {
        match self {
            MixKind::DailyMix => "daily_mix",
            MixKind::DiscoverWeekly => "discover_weekly",
            MixKind::ReleaseRadar => "release_radar",
            MixKind::OnRepeat => "on_repeat",
            MixKind::RepeatRewind => "repeat_rewind",
            MixKind::Daylist => "daylist",
        }
    }

    pub fn from_name(name: &str) -> Option<MixKind> {
        MixKind::ALL.iter().copied().find(|k| k.name() == name)
    }

    pub fn songs(self) -> usize {
        match self {
            MixKind::DailyMix => DAILY_LEN,
            MixKind::DiscoverWeekly => DISCOVER_LEN,
            MixKind::ReleaseRadar => RADAR_LEN,
            MixKind::OnRepeat | MixKind::RepeatRewind => REPEAT_LEN,
            MixKind::Daylist => DAYLIST_LEN,
        }
    }

    /// The order the shelves have on Home.
    pub fn display_rank(self) -> u32 {
        match self {
            MixKind::DailyMix => 0,
            MixKind::DiscoverWeekly => 1,
            MixKind::ReleaseRadar => 2,
            MixKind::OnRepeat => 3,
            MixKind::RepeatRewind => 4,
            MixKind::Daylist => 5,
        }
    }
}

// ------------------------------------------------------------------ ids

/// Stable ids: the same mix keeps its id for ever, so a card, a play queue and the exploration
/// beliefs keep pointing at it.
pub fn daily_mix_id(slot: usize) -> String {
    format!("daily-mix-{slot}")
}

pub fn mix_id(kind: MixKind, slot: usize) -> String {
    match kind {
        MixKind::DailyMix => daily_mix_id(slot),
        MixKind::DiscoverWeekly => "discover-weekly".to_string(),
        MixKind::ReleaseRadar => "release-radar".to_string(),
        // The old engine's "On Repeat" used this id too; the Part 6 mix replaces it on Home.
        MixKind::OnRepeat => "on-repeat".to_string(),
        MixKind::RepeatRewind => "repeat-rewind".to_string(),
        MixKind::Daylist => "daylist".to_string(),
    }
}

/// The kind and slot of a stored mix id, or `None` for an id that is not a Part 6 mix.
pub fn parse_mix_id(id: &str) -> Option<(MixKind, usize)> {
    if let Some(n) = id.strip_prefix("daily-mix-") {
        let slot: usize = n.parse().ok()?;
        return (1..=MAX_DAILY_MIXES)
            .contains(&slot)
            .then_some((MixKind::DailyMix, slot));
    }
    match id {
        "discover-weekly" => Some((MixKind::DiscoverWeekly, 0)),
        "release-radar" => Some((MixKind::ReleaseRadar, 0)),
        "on-repeat" => Some((MixKind::OnRepeat, 0)),
        "repeat-rewind" => Some((MixKind::RepeatRewind, 0)),
        "daylist" => Some((MixKind::Daylist, 0)),
        _ => None,
    }
}

// ------------------------------------------------------------------ schedule

/// The name of the period a mix built `now` belongs to. A stored mix whose key differs from the
/// key of `now` is due for a rebuild; one with the same key is left alone, however often the app
/// is opened.
pub fn period_key(kind: MixKind, now: u64, tz: i64) -> String {
    let day = local_day(now, tz);
    match kind {
        MixKind::DailyMix | MixKind::OnRepeat => format!("d:{}", date_string(day)),
        MixKind::DiscoverWeekly => format!(
            "w:{}",
            date_string(last_weekday_on_or_before(day, DISCOVER_WEEKDAY))
        ),
        MixKind::ReleaseRadar => format!(
            "w:{}",
            date_string(last_weekday_on_or_before(day, RELEASE_WEEKDAY))
        ),
        MixKind::RepeatRewind => format!(
            "w:{}",
            date_string(last_weekday_on_or_before(day, REWIND_WEEKDAY))
        ),
        MixKind::Daylist => {
            let (d, slot) = daylist_slot(now, tz);
            format!("dl:{}#{slot}", date_string(d))
        }
    }
}

/// The Daylist slot (0, 1 or 2) and the day it belongs to. The small hours belong to the evening
/// slot of the day before.
pub fn daylist_slot(now: u64, tz: i64) -> (u64, usize) {
    let day = local_day(now, tz);
    let hour = local_hour(now, tz);
    let [a, b, c] = DAYLIST_SLOT_HOURS;
    if hour < a {
        (day.saturating_sub(1), 2)
    } else if hour < b {
        (day, 0)
    } else if hour < c {
        (day, 1)
    } else {
        (day, 2)
    }
}

/// When a mix built at `now` changes by itself next, as unix seconds.
pub fn next_refresh_at(kind: MixKind, now: u64, tz: i64) -> u64 {
    let day = local_day(now, tz);
    match kind {
        MixKind::DailyMix | MixKind::OnRepeat => to_unix(day + 1, 0, tz),
        MixKind::DiscoverWeekly => to_unix(next_weekday_after(day, DISCOVER_WEEKDAY), 0, tz),
        MixKind::ReleaseRadar => to_unix(next_weekday_after(day, RELEASE_WEEKDAY), 0, tz),
        MixKind::RepeatRewind => to_unix(next_weekday_after(day, REWIND_WEEKDAY), 0, tz),
        MixKind::Daylist => {
            let hour = local_hour(now, tz);
            let [a, b, c] = DAYLIST_SLOT_HOURS;
            if hour < a {
                to_unix(day, a, tz)
            } else if hour < b {
                to_unix(day, b, tz)
            } else if hour < c {
                to_unix(day, c, tz)
            } else {
                to_unix(day + 1, a, tz)
            }
        }
    }
}

/// True when the stored mix (its period key) is not the one for `now`.
pub fn is_due(kind: MixKind, stored_period: Option<&str>, now: u64, tz: i64) -> bool {
    stored_period != Some(period_key(kind, now, tz).as_str())
}

// ------------------------------------------------------------------ words

/// The part of the day for the Daylist title.
pub fn day_part(hour: u32) -> &'static str {
    match hour {
        5..=11 => "morning",
        12..=16 => "afternoon",
        17..=21 => "evening",
        _ => "late-night",
    }
}

/// `Daily Mix 2: lo-fi, chillhop`. An empty label gives `Daily Mix 2`.
pub fn daily_mix_title(slot: usize, label: &str) -> String {
    let label = label.trim();
    if label.is_empty() {
        format!("Daily Mix {slot}")
    } else {
        format!("Daily Mix {slot}: {label}")
    }
}

/// `Tuesday late-night synthwave`. Without a tag: `Tuesday late-night mix`.
pub fn daylist_title(now: u64, tz: i64, tag: Option<&str>) -> String {
    let day = local_day(now, tz);
    let word = tag
        .map(str::trim)
        .filter(|t| !t.is_empty())
        .unwrap_or("mix");
    format!(
        "{} {} {}",
        weekday_name(weekday(day)),
        day_part(local_hour(now, tz)),
        word
    )
}

/// `A`, `A and B`, `A, B and C`.
pub fn join_names(names: &[String]) -> String {
    match names {
        [] => String::new(),
        [a] => a.clone(),
        [a, b] => format!("{a} and {b}"),
        [rest @ .., last] => format!("{} and {last}", rest.join(", ")),
    }
}

/// Up to `n` distinct artists of a mix, those you play most first, then the order of the list.
pub fn lead_artists(tracks: &[Track], top_keys: &[String], n: usize) -> Vec<String> {
    let mut seen: Vec<(usize, usize, String)> = Vec::new();
    for (pos, t) in tracks.iter().enumerate() {
        let key = artist_key(&t.artist);
        if t.artist.trim().is_empty() || seen.iter().any(|(_, _, a)| artist_key(a) == key) {
            continue;
        }
        let rank = top_keys
            .iter()
            .position(|k| *k == key)
            .unwrap_or(usize::MAX);
        seen.push((rank, pos, t.artist.clone()));
    }
    seen.sort_by_key(|(rank, pos, _)| (*rank, *pos));
    seen.into_iter().take(n).map(|(_, _, a)| a).collect()
}

/// The one line under a mix. `leads` are artists from [`lead_artists`]; `label` is the cluster's
/// tags for a Daily Mix, or the Daylist's mood word.
pub fn mix_reason(kind: MixKind, leads: &[String], label: &str) -> String {
    let who = join_names(leads);
    let label = label.trim();
    match kind {
        MixKind::DailyMix => match (label.is_empty(), who.is_empty()) {
            (false, false) => {
                format!("Your {label} listening: {who} and more, with a few new ones")
            }
            (false, true) => format!("Your {label} listening, with a few new ones"),
            (true, false) => format!("Because you've been playing {who}, with a few new ones"),
            (true, true) => "Songs you know, with a few new ones".to_string(),
        },
        MixKind::DiscoverWeekly => {
            if who.is_empty() {
                "New artists picked for you, fresh every Monday".to_string()
            } else {
                format!("New artists close to what you play, like {who}. Fresh every Monday")
            }
        }
        MixKind::ReleaseRadar => {
            if who.is_empty() {
                "New releases from artists you play, every Friday".to_string()
            } else {
                format!("New from {who} and other artists you play. Every Friday")
            }
        }
        MixKind::OnRepeat => {
            if who.is_empty() {
                "The songs you keep coming back to".to_string()
            } else {
                format!("The songs you keep coming back to, like {who}")
            }
        }
        MixKind::RepeatRewind => {
            if who.is_empty() {
                "Songs you loved and have not played in a while".to_string()
            } else {
                format!("Songs you loved and have not played in a while, like {who}")
            }
        }
        MixKind::Daylist => {
            if label.is_empty() {
                "Made for this time of day".to_string()
            } else {
                format!("Made for this time of day: {label}")
            }
        }
    }
}

/// Up to four distinct cover thumbnails for the mosaic cover.
pub fn cover_urls(tracks: &[Track]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for t in tracks {
        if let Some(u) = t.art_url.as_deref().filter(|u| !u.is_empty()) {
            if !out.iter().any(|x| x == u) {
                out.push(u.to_string());
            }
        }
        if out.len() >= 4 {
            break;
        }
    }
    out
}

/// The colour of the gradient cover when there is no thumbnail: stable per mix id.
pub fn cover_hue(id: &str) -> u16 {
    (fnv64(id) % 360) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-11-09 00:00:00 UTC, a Monday.
    const MON: u64 = 1_794_182_400;
    const H: u64 = 3600;
    const D: u64 = 86_400;

    fn track(artist: &str, art: Option<&str>) -> Track {
        let mut t = Track::simple(
            format!("id-{artist}"),
            "Song".into(),
            artist.into(),
            "Album".into(),
            1000,
        );
        t.art_url = art.map(str::to_string);
        t
    }

    #[test]
    fn ids_are_stable_and_parse_back() {
        assert_eq!(mix_id(MixKind::DailyMix, 3), "daily-mix-3");
        assert_eq!(parse_mix_id("daily-mix-3"), Some((MixKind::DailyMix, 3)));
        assert_eq!(parse_mix_id("daily-mix-0"), None);
        assert_eq!(parse_mix_id("daily-mix-9"), None);
        for k in [
            MixKind::DiscoverWeekly,
            MixKind::ReleaseRadar,
            MixKind::OnRepeat,
            MixKind::RepeatRewind,
            MixKind::Daylist,
        ] {
            assert_eq!(parse_mix_id(&mix_id(k, 0)).map(|x| x.0), Some(k));
        }
        assert_eq!(parse_mix_id("liked-songs"), None);
        assert_eq!(MixKind::from_name("daylist"), Some(MixKind::Daylist));
    }

    #[test]
    fn discover_weekly_refreshes_on_monday_only() {
        let mon = period_key(MixKind::DiscoverWeekly, MON + 9 * H, 0);
        let sun_before = period_key(MixKind::DiscoverWeekly, MON - H, 0);
        assert_ne!(mon, sun_before, "Monday starts a new list");
        for d in 0..7u64 {
            assert_eq!(
                period_key(MixKind::DiscoverWeekly, MON + d * D + 3 * H, 0),
                mon,
                "day {d} of the week"
            );
        }
        assert_ne!(
            period_key(MixKind::DiscoverWeekly, MON + 7 * D, 0),
            mon,
            "the next Monday"
        );
        assert!(!is_due(MixKind::DiscoverWeekly, Some(&mon), MON + 5 * D, 0));
        assert!(is_due(
            MixKind::DiscoverWeekly,
            Some(&mon),
            MON + 7 * D + H,
            0
        ));
        assert!(is_due(MixKind::DiscoverWeekly, None, MON, 0));
    }

    #[test]
    fn release_radar_refreshes_on_friday_only() {
        let thu = period_key(MixKind::ReleaseRadar, MON + 3 * D + 20 * H, 0);
        let fri = period_key(MixKind::ReleaseRadar, MON + 4 * D + H, 0);
        let sun = period_key(MixKind::ReleaseRadar, MON + 6 * D, 0);
        assert_ne!(thu, fri);
        assert_eq!(fri, sun);
        assert_eq!(
            period_key(MixKind::ReleaseRadar, MON + 10 * D + 23 * H, 0),
            fri,
            "through next Thursday"
        );
        assert_ne!(
            period_key(MixKind::ReleaseRadar, MON + 11 * D, 0),
            fri,
            "next Friday"
        );
    }

    #[test]
    fn daily_mix_and_on_repeat_change_at_local_midnight() {
        let tz = 5 * 3600 + 1800;
        let a = period_key(MixKind::DailyMix, MON + 10 * H, tz);
        // 18:29 UTC is 23:59 in India, 18:30 UTC is already the next day there.
        assert_eq!(period_key(MixKind::DailyMix, MON + 18 * H + 29 * 60, tz), a);
        assert_ne!(period_key(MixKind::DailyMix, MON + 18 * H + 30 * 60, tz), a);
        assert_eq!(
            next_refresh_at(MixKind::DailyMix, MON + 10 * H, tz),
            MON + 18 * H + 30 * 60
        );
    }

    #[test]
    fn daylist_changes_three_times_a_day() {
        let keys: Vec<String> = [3u64, 6, 11, 12, 18, 19, 23]
            .iter()
            .map(|h| period_key(MixKind::Daylist, MON + h * H, 0))
            .collect();
        // 03:00 is the evening slot of Sunday; 06:00 and 11:00 are the morning slot.
        assert!(keys[0].ends_with("#2") && keys[0].contains("2026-11-08"));
        assert_eq!(keys[1], keys[2]);
        assert_ne!(keys[2], keys[3], "noon starts the afternoon slot");
        assert_eq!(keys[3], keys[4]);
        assert_ne!(keys[4], keys[5], "19:00 starts the evening slot");
        assert_eq!(keys[5], keys[6]);
        let distinct: std::collections::BTreeSet<&String> = keys.iter().collect();
        assert_eq!(
            distinct.len(),
            4,
            "three slots in the day plus the tail of last night"
        );
        assert_eq!(
            next_refresh_at(MixKind::Daylist, MON + 6 * H, 0),
            MON + 12 * H
        );
        assert_eq!(
            next_refresh_at(MixKind::Daylist, MON + 20 * H, 0),
            MON + D + 5 * H
        );
        assert_eq!(
            next_refresh_at(MixKind::Daylist, MON + 2 * H, 0),
            MON + 5 * H
        );
    }

    #[test]
    fn next_refresh_matches_the_period_change() {
        for kind in MixKind::ALL {
            for start in [MON + H, MON + 4 * D + 13 * H, MON + 6 * D + 23 * H] {
                let at = next_refresh_at(kind, start, 0);
                assert!(at > start, "{kind:?} next refresh is in the future");
                assert_ne!(
                    period_key(kind, at, 0),
                    period_key(kind, start, 0),
                    "{kind:?} changes exactly then"
                );
                assert_eq!(
                    period_key(kind, at - 1, 0),
                    period_key(kind, start, 0),
                    "{kind:?} not a second sooner"
                );
            }
        }
    }

    #[test]
    fn titles_follow_the_examples() {
        assert_eq!(
            daily_mix_title(2, "lo-fi, chillhop"),
            "Daily Mix 2: lo-fi, chillhop"
        );
        assert_eq!(daily_mix_title(1, "  "), "Daily Mix 1");
        // Tuesday 2026-11-10 at 23:30.
        assert_eq!(
            daylist_title(MON + D + 23 * H + 1800, 0, Some("synthwave")),
            "Tuesday late-night synthwave"
        );
        assert_eq!(daylist_title(MON + 8 * H, 0, None), "Monday morning mix");
        assert_eq!(day_part(2), "late-night");
        assert_eq!(day_part(13), "afternoon");
        assert_eq!(day_part(18), "evening");
    }

    #[test]
    fn names_are_joined_in_plain_english() {
        let n = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(join_names(&n(&[])), "");
        assert_eq!(join_names(&n(&["A"])), "A");
        assert_eq!(join_names(&n(&["A", "B"])), "A and B");
        assert_eq!(join_names(&n(&["A", "B", "C"])), "A, B and C");
    }

    #[test]
    fn lead_artists_prefer_what_you_play_most() {
        let tracks = vec![
            track("Zed", None),
            track("Mid", None),
            track("Zed", None),
            track("Top", None),
        ];
        let top = vec!["top".to_string(), "mid".to_string()];
        assert_eq!(
            lead_artists(&tracks, &top, 2),
            vec!["Top".to_string(), "Mid".to_string()]
        );
        assert_eq!(
            lead_artists(&tracks, &[], 2),
            vec!["Zed".to_string(), "Mid".to_string()],
            "list order without a ranking"
        );
    }

    #[test]
    fn every_kind_has_a_reason_with_and_without_names() {
        let leads = vec!["Nujabes".to_string(), "Tycho".to_string()];
        for kind in MixKind::ALL {
            assert!(!mix_reason(kind, &leads, "lo-fi").is_empty());
            assert!(!mix_reason(kind, &[], "").is_empty());
        }
        assert_eq!(
            mix_reason(MixKind::DailyMix, &leads, ""),
            "Because you've been playing Nujabes and Tycho, with a few new ones"
        );
        assert!(mix_reason(MixKind::ReleaseRadar, &leads, "").contains("Friday"));
        assert!(mix_reason(MixKind::DiscoverWeekly, &[], "").contains("Monday"));
    }

    #[test]
    fn covers_use_four_distinct_thumbnails_and_the_hue_is_stable() {
        let tracks = vec![
            track("A", Some("u1")),
            track("B", Some("u1")),
            track("C", None),
            track("D", Some("u2")),
            track("E", Some("u3")),
            track("F", Some("u4")),
            track("G", Some("u5")),
        ];
        assert_eq!(cover_urls(&tracks), vec!["u1", "u2", "u3", "u4"]);
        assert!(cover_urls(&[track("A", None)]).is_empty());
        assert_eq!(cover_hue("daily-mix-1"), cover_hue("daily-mix-1"));
        assert!(cover_hue("daylist") < 360);
    }
}
