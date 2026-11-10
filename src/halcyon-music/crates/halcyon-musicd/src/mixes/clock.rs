//! Part 6: dates, weekdays and day parts for the schedules. No clock is read here: every function
//! takes `now` (unix seconds) and `tz` (the listener's UTC offset in seconds), so a test can use a
//! fake clock. The one exception is [`local_utc_offset_secs`], which asks the system.

pub const DAY: u64 = 86_400;

/// The listener's UTC offset in seconds right now (positive east of Greenwich). 0 when the system
/// cannot say.
pub fn local_utc_offset_secs(now: u64) -> i64 {
    let t: libc::time_t = now as libc::time_t;
    // SAFETY: `tm` is zeroed plain-old-data and `localtime_r` only writes into it. The pointer to
    // `t` is valid for the call. A null return means failure and is handled below.
    #[allow(unsafe_code)]
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        if libc::localtime_r(&t, &mut tm).is_null() {
            return 0;
        }
        tm.tm_gmtoff as i64
    }
}

/// Seconds on the listener's wall clock (never negative).
pub fn local_secs(now: u64, tz: i64) -> u64 {
    (now as i64).saturating_add(tz).max(0) as u64
}

/// Days since 1970-01-01 of the listener's date.
pub fn local_day(now: u64, tz: i64) -> u64 {
    local_secs(now, tz) / DAY
}

/// Hour of the listener's day, 0 to 23.
pub fn local_hour(now: u64, tz: i64) -> u32 {
    ((local_secs(now, tz) % DAY) / 3600) as u32
}

/// Monday = 0 … Sunday = 6. 1970-01-01 was a Thursday.
pub fn weekday(day: u64) -> u32 {
    ((day + 3) % 7) as u32
}

pub fn weekday_name(wd: u32) -> &'static str {
    match wd {
        0 => "Monday",
        1 => "Tuesday",
        2 => "Wednesday",
        3 => "Thursday",
        4 => "Friday",
        5 => "Saturday",
        _ => "Sunday",
    }
}

/// Year, month, day of a day number (days since 1970-01-01). Howard Hinnant's civil-from-days.
pub fn civil_from_days(days: u64) -> (i64, u32, u32) {
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// `2026-11-09`.
pub fn date_string(day: u64) -> String {
    let (y, m, d) = civil_from_days(day);
    format!("{y:04}-{m:02}-{d:02}")
}

/// The latest day on or before `day` that falls on weekday `target` (Monday = 0).
pub fn last_weekday_on_or_before(day: u64, target: u32) -> u64 {
    let back = (u64::from(weekday(day)) + 7 - u64::from(target % 7)) % 7;
    day.saturating_sub(back)
}

/// The first day after `day` that falls on weekday `target`.
pub fn next_weekday_after(day: u64, target: u32) -> u64 {
    let ahead = (u64::from(target % 7) + 7 - u64::from(weekday(day))) % 7;
    day + if ahead == 0 { 7 } else { ahead }
}

/// A listener-local moment (`day`, `hour`) as unix seconds.
pub fn to_unix(day: u64, hour: u32, tz: i64) -> u64 {
    ((day * DAY + u64::from(hour) * 3600) as i64).saturating_sub(tz).max(0) as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-11-09 00:00:00 UTC, a Monday.
    const MON: u64 = 1_794_182_400;

    #[test]
    fn known_dates() {
        assert_eq!(date_string(0), "1970-01-01");
        assert_eq!(date_string(local_day(MON, 0)), "2026-11-09");
        assert_eq!(date_string(11_016), "2000-02-29");
        assert_eq!(weekday(0), 3, "1970-01-01 was a Thursday");
        assert_eq!(weekday(local_day(MON, 0)), 0, "2026-11-09 is a Monday");
    }

    #[test]
    fn time_zone_moves_the_date_and_the_hour() {
        // 23:00 UTC on Sunday is already Monday 04:30 in India (+5:30).
        let sunday_23 = MON - 3600;
        assert_eq!(weekday(local_day(sunday_23, 0)), 6);
        let ist = 5 * 3600 + 1800;
        assert_eq!(weekday(local_day(sunday_23, ist)), 0);
        assert_eq!(local_hour(sunday_23, ist), 4);
    }

    #[test]
    fn weekday_search_goes_back_and_forward() {
        let monday = local_day(MON, 0);
        assert_eq!(last_weekday_on_or_before(monday, 0), monday);
        assert_eq!(last_weekday_on_or_before(monday + 3, 0), monday);
        assert_eq!(last_weekday_on_or_before(monday + 3, 4), monday - 3, "last Friday");
        assert_eq!(next_weekday_after(monday, 0), monday + 7);
        assert_eq!(next_weekday_after(monday, 4), monday + 4);
        assert_eq!(next_weekday_after(monday + 4, 4), monday + 11);
    }

    #[test]
    fn to_unix_round_trips() {
        let tz = 5 * 3600 + 1800;
        let day = local_day(MON + 10 * 3600, tz);
        let t = to_unix(day, 5, tz);
        assert_eq!(local_hour(t, tz), 5);
        assert_eq!(local_day(t, tz), day);
    }

    #[test]
    fn the_system_offset_is_sane() {
        let off = local_utc_offset_secs(MON);
        assert!((-14 * 3600..=14 * 3600 + 1800).contains(&off));
    }
}
