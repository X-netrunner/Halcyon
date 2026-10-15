//! birthday-sync: Google Calendar's "Birthdays" calendar -> the managed block in ~/.config/Halcyon/birthdays.txt
//!
//! Google gives the built-in Birthdays calendar no iCal address, so gcal.py can't read it. This goes through the
//! Calendar API instead (read-only scope, loopback OAuth + PKCE, nothing is ever written to Google).
//!
//!   birthday-sync setup FILE.json | ID SECRET   store the OAuth client (Google Cloud Console > Credentials > Desktop app)
//!   birthday-sync auth                           log in once in the browser
//!   birthday-sync sync [--dry-run] [--json]      fetch birthdays, rewrite the Google block of birthdays.txt
//!   birthday-sync status                         what is set up (no secrets printed)
//!   birthday-sync logout                         revoke the login and forget it
//!
//! State: ~/.local/state/island/calendar/google-oauth.json (mode 0600). Lines you typed or imported from contacts are
//! never touched; only the block between the two "Google Calendar" marker lines is replaced.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fmt::Display;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use std::{env, fs, process};

const SCOPE: &str = "https://www.googleapis.com/auth/calendar.readonly";
const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const REVOKE_URL: &str = "https://oauth2.googleapis.com/revoke";
const API: &str = "https://www.googleapis.com/calendar/v3";
const ADDRESSBOOK: &str = "addressbook#contacts@group.v.calendar.google.com"; // the built-in "Birthdays" calendar
const BEGIN: &str = "# >>> imported from Google Calendar (managed by Halcyon: syncing again replaces everything up to the end marker) >>>";
const END: &str = "# <<< end of Google Calendar birthdays <<<";
const BEGIN_PREFIX: &str = "# >>> imported from Google Calendar";
const END_PREFIX: &str = "# <<< end of Google Calendar";

type Res<T> = Result<T, String>;

fn err<E: Display>(ctx: &'static str) -> impl Fn(E) -> String {
    move |e| format!("{ctx}: {e}")
}

// ------------------------------------------------------------------ paths / files
fn home() -> PathBuf {
    PathBuf::from(env::var_os("HOME").unwrap_or_else(|| "/".into()))
}
fn auth_file() -> PathBuf {
    home().join(".local/state/island/calendar/google-oauth.json")
}
fn birthdays_file() -> PathBuf {
    home().join(".config/Halcyon/birthdays.txt")
}

/// created with the right mode from the start (never world-readable, not even for a moment)
fn write_private(path: &Path, data: &str) -> Res<()> {
    let dir = path.parent().ok_or("bad path")?;
    fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).map_err(err("state dir"))?;
    let tmp = path.with_extension("tmp");
    let mut f = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&tmp).map_err(err("write"))?;
    f.write_all(data.as_bytes()).map_err(err("write"))?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600)).map_err(err("chmod"))?;
    fs::rename(&tmp, path).map_err(err("rename"))
}

fn load_cfg() -> Value {
    fs::read_to_string(auth_file()).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_else(|| json!({}))
}
fn save_cfg(v: &Value) -> Res<()> {
    write_private(&auth_file(), &v.to_string())
}
fn field(cfg: &Value, k: &str) -> Option<String> {
    cfg.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

// ------------------------------------------------------------------ small helpers
fn random_bytes(n: usize) -> Res<Vec<u8>> {
    let mut b = vec![0u8; n];
    fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).map_err(err("urandom"))?;
    Ok(b)
}

fn pct_encode(s: &str) -> String {
    let mut o = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            o.push(b as char);
        } else {
            o.push_str(&format!("%{b:02X}"));
        }
    }
    o
}

fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut o = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        let hex = if b[i] == b'%' && i + 2 < b.len() { std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) } else { None };
        match (b[i], hex) {
            (_, Some(v)) => {
                o.push(v);
                i += 2;
            }
            (b'+', None) => o.push(b' '),
            (c, None) => o.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&o).into_owned()
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new().timeout(Duration::from_secs(25)).build()
}

fn read_json(r: Result<ureq::Response, ureq::Error>) -> Res<Value> {
    match r {
        Ok(resp) => resp.into_json::<Value>().map_err(err("bad reply from Google")),
        Err(ureq::Error::Status(code, resp)) => {
            let body = resp.into_string().unwrap_or_default();
            Err(format!("Google answered {code}: {}", body.chars().take(300).collect::<String>()))
        }
        Err(e) => Err(format!("network: {e}")),
    }
}

/// days since 1970-01-01 -> civil year (Howard Hinnant's algorithm)
fn year_from_days(z: i64) -> i64 {
    let z = z + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    yoe + era * 400 + if m <= 2 { 1 } else { 0 }
}
fn current_year() -> i64 {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    year_from_days(secs / 86400)
}

// ------------------------------------------------------------------ setup / auth
fn cmd_setup(args: &[String]) -> Res<()> {
    let (id, secret) = if args.len() >= 2 {
        (args[0].clone(), args[1].clone())
    } else if let Some(p) = args.first() {
        let v: Value = serde_json::from_str(&fs::read_to_string(p).map_err(err("cannot read the file"))?).map_err(err("not valid JSON"))?;
        let c = v.get("installed").or_else(|| v.get("web")).unwrap_or(&v);
        (
            field(c, "client_id").ok_or("no client_id in that file (create the credential as type 'Desktop app')")?,
            field(c, "client_secret").ok_or("no client_secret in that file")?,
        )
    } else {
        return Err("usage: birthday-sync setup client_secret.json   (or: setup CLIENT_ID CLIENT_SECRET)".into());
    };
    save_cfg(&json!({ "client_id": id, "client_secret": secret }))?;
    println!("Saved. Next: birthday-sync auth");
    Ok(())
}

fn query_param(line: &str, key: &str) -> Option<String> {
    let path = line.strip_prefix("GET ")?.split(' ').next()?;
    let q = path.split_once('?')?.1;
    q.split('&').filter_map(|kv| kv.split_once('=')).find(|(k, _)| *k == key).map(|(_, v)| pct_decode(v))
}

fn reply(s: &mut std::net::TcpStream, code: &str, msg: &str) {
    let body = format!("<!doctype html><meta charset=utf-8><title>Halcyon</title><body style=\"font:16px sans-serif;margin:3em\">{msg}");
    let _ = write!(s, "HTTP/1.1 {code}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
}

fn cmd_auth() -> Res<()> {
    let mut cfg = load_cfg();
    let (id, secret) = match (field(&cfg, "client_id"), field(&cfg, "client_secret")) {
        (Some(a), Some(b)) => (a, b),
        _ => return Err("no OAuth client yet. Run: birthday-sync setup client_secret.json".into()),
    };
    let verifier = URL_SAFE_NO_PAD.encode(random_bytes(48)?);
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let state = URL_SAFE_NO_PAD.encode(random_bytes(16)?);
    let listener = TcpListener::bind("127.0.0.1:0").map_err(err("local port"))?;
    let redirect = format!("http://127.0.0.1:{}", listener.local_addr().map_err(err("local port"))?.port());
    let url = format!(
        "{AUTH_URL}?client_id={}&redirect_uri={}&response_type=code&scope={}&code_challenge={challenge}&code_challenge_method=S256&state={}&access_type=offline&prompt=consent",
        pct_encode(&id), pct_encode(&redirect), pct_encode(SCOPE), pct_encode(&state)
    );
    println!("Open this address and allow read-only calendar access:\n\n{url}\n");
    let _ = process::Command::new("xdg-open").arg(&url).stdout(process::Stdio::null()).stderr(process::Stdio::null()).spawn();

    listener.set_nonblocking(true).map_err(err("local port"))?;
    let deadline = Instant::now() + Duration::from_secs(300);
    let code = loop {
        match listener.accept() {
            Ok((mut s, _)) => {
                let _ = s.set_nonblocking(false);
                let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
                let mut buf = [0u8; 8192];
                let n = s.read(&mut buf).unwrap_or(0);
                let first = String::from_utf8_lossy(&buf[..n]).lines().next().unwrap_or("").to_string();
                if let Some(e) = query_param(&first, "error") {
                    reply(&mut s, "400 Bad Request", "Access was not granted. You can close this tab.");
                    return Err(format!("Google: {e}"));
                }
                match (query_param(&first, "code"), query_param(&first, "state")) {
                    (Some(c), Some(st)) if st == state => {
                        reply(&mut s, "200 OK", "Done. You can close this tab and go back to the terminal.");
                        break c;
                    }
                    (Some(_), _) => reply(&mut s, "400 Bad Request", "State mismatch, ignored."),
                    _ => reply(&mut s, "404 Not Found", "Waiting for Google..."), // favicon and the like
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if Instant::now() > deadline {
                    return Err("timed out waiting for the browser (5 min)".into());
                }
                std::thread::sleep(Duration::from_millis(150));
            }
            Err(e) => return Err(format!("local port: {e}")),
        }
    };

    let v = read_json(agent().post(TOKEN_URL).send_form(&[
        ("code", &code), ("client_id", &id), ("client_secret", &secret),
        ("redirect_uri", &redirect), ("grant_type", "authorization_code"), ("code_verifier", &verifier),
    ]))?;
    let refresh = field(&v, "refresh_token").ok_or("Google sent no refresh token. Remove the app at myaccount.google.com/permissions and run auth again")?;
    cfg["refresh_token"] = Value::String(refresh);
    save_cfg(&cfg)?;
    println!("Logged in. Next: birthday-sync sync");
    Ok(())
}

fn access_token(cfg: &Value) -> Res<String> {
    let (id, secret, refresh) = match (field(cfg, "client_id"), field(cfg, "client_secret"), field(cfg, "refresh_token")) {
        (Some(a), Some(b), Some(c)) => (a, b, c),
        _ => return Err("not logged in. Run: birthday-sync setup ... then birthday-sync auth".into()),
    };
    let v = read_json(agent().post(TOKEN_URL).send_form(&[
        ("client_id", &id), ("client_secret", &secret), ("refresh_token", &refresh), ("grant_type", "refresh_token"),
    ]))
    .map_err(|e| {
        if e.contains("invalid_grant") {
            "Google refused the saved login (expired or revoked). Run: birthday-sync auth".to_string()
        } else {
            e
        }
    })?;
    field(&v, "access_token").ok_or_else(|| "no access token in Google's reply".to_string())
}

fn cmd_status() -> Res<()> {
    let cfg = load_cfg();
    println!("OAuth client : {}", if field(&cfg, "client_id").is_some() && field(&cfg, "client_secret").is_some() { "stored" } else { "missing (setup)" });
    println!("Login        : {}", if field(&cfg, "refresh_token").is_some() { "yes" } else { "no (auth)" });
    println!("birthdays.txt: {}", birthdays_file().display());
    Ok(())
}

fn cmd_logout() -> Res<()> {
    let cfg = load_cfg();
    if let Some(t) = field(&cfg, "refresh_token") {
        let _ = agent().post(REVOKE_URL).send_form(&[("token", &t)]); // best effort
    }
    let _ = fs::remove_file(auth_file());
    println!("Logged out and forgot the client.");
    Ok(())
}

// ------------------------------------------------------------------ names
fn collapse(s: &str) -> String {
    s.chars().map(|c| if c.is_control() { ' ' } else { c }).collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ")
}

fn strip_possessive(s: &str) -> &str {
    let s = s.trim_end_matches(|c: char| c.is_whitespace() || ":-–—,.".contains(c));
    for suf in ["'s", "’s", "'S", "’S", "'", "’"] {
        if let Some(r) = s.strip_suffix(suf) {
            return r;
        }
    }
    s
}

/// "Sarah's birthday" / "Rahul's 21st Birthday" / "Birthday: Mom" / "🎂 Amit B'day" / "Mom" -> the person
fn clean_name(summary: &str) -> String {
    let s = collapse(summary);
    let mut s = s.trim_start_matches(|c: char| !c.is_alphanumeric()).to_string();
    if s.to_ascii_lowercase().starts_with("happy ") {
        s = s[6..].to_string();
    }
    let low = s.to_ascii_lowercase();
    let mut name = s.clone();
    for word in ["birthday", "b'day", "bday", "b-day"] {
        if let Some(i) = low.rfind(word) {
            let (before, after) = (s[..i].trim(), s[i + word.len()..].trim());
            name = if !before.is_empty() { before.to_string() } else { after.trim_start_matches(|c: char| ":-–—".contains(c) || c.is_whitespace()).trim_start_matches("of ").to_string() };
            break;
        }
    }
    let mut name = strip_possessive(&name).to_string();
    // "Rahul's 21st" -> drop the ordinal, then the possessive again
    if let Some((head, last)) = name.rsplit_once(' ') {
        let digits = last.trim_end_matches(|c: char| c.is_ascii_alphabetic());
        if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) && matches!(&last[digits.len()..].to_ascii_lowercase()[..], "st" | "nd" | "rd" | "th") {
            name = strip_possessive(head).to_string();
        }
    }
    // birthdays.txt has no room for '(' (the year goes there) and '#' would turn the line into a comment
    let mut cleaned = String::new();
    let mut depth = 0;
    for c in name.chars() {
        match c {
            '(' => depth += 1,
            ')' if depth > 0 => depth -= 1,
            ')' => {}
            _ if depth == 0 => cleaned.push(c),
            _ => {}
        }
    }
    collapse(&cleaned).trim_start_matches('#').trim().to_string()
}

// ------------------------------------------------------------------ events -> birthdays
#[derive(Debug, Clone, PartialEq)]
struct Bday {
    name: String,
    month: u32,
    day: u32,
    year: Option<i64>,
}

impl Bday {
    fn line(&self) -> String {
        format!("{:02}-{:02} {}{}", self.month, self.day, self.name, self.year.map(|y| format!(" ({y})")).unwrap_or_default())
    }
}

fn event_to_bday(ev: &Value, structured_cal: bool, this_year: i64) -> Option<Bday> {
    if ev.get("status").and_then(Value::as_str) == Some("cancelled") || ev.get("recurringEventId").is_some() {
        return None; // a deleted event / a one-off change of a single year
    }
    let kind = ev.pointer("/birthdayProperties/type").and_then(Value::as_str);
    if matches!(kind, Some(k) if k != "birthday" && k != "self") {
        return None; // anniversaries and custom dates of a contact
    }
    let structured = structured_cal || ev.get("eventType").and_then(Value::as_str) == Some("birthday");
    let start = ev.pointer("/start/date").or_else(|| ev.pointer("/start/dateTime")).and_then(Value::as_str)?;
    let (y, m, d) = (start.get(0..4)?.parse::<i64>().ok()?, start.get(5..7)?.parse::<u32>().ok()?, start.get(8..10)?.parse::<u32>().ok()?);
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    let name = clean_name(ev.get("summary").and_then(Value::as_str)?);
    if name.is_empty() {
        return None;
    }
    // only a real birth year counts: plain events keep no year, and 1604 / current-year placeholders are no year either
    let year = if structured && (1900..this_year).contains(&y) { Some(y) } else { None };
    Some(Bday { name, month: m, day: d, year })
}

fn get(tok: &str, url: &str, q: &[(&str, &str)]) -> Res<Value> {
    let mut r = agent().get(url).set("Authorization", &format!("Bearer {tok}"));
    for (k, v) in q {
        r = r.query(k, v);
    }
    read_json(r.call())
}

fn fetch_events(tok: &str, cal_id: &str, only_birthday_type: bool, structured: bool, this_year: i64) -> Res<Vec<Bday>> {
    let url = format!("{API}/calendars/{}/events", pct_encode(cal_id));
    let (mut out, mut page) = (Vec::new(), String::new());
    loop {
        let mut q = vec![("maxResults", "2500"), ("singleEvents", "false"), ("showDeleted", "false")];
        if only_birthday_type {
            q.push(("eventTypes", "birthday"));
        }
        if !page.is_empty() {
            q.push(("pageToken", &page));
        }
        let v = get(tok, &url, &q)?;
        for ev in v.get("items").and_then(Value::as_array).into_iter().flatten() {
            out.extend(event_to_bday(ev, structured, this_year));
        }
        match v.get("nextPageToken").and_then(Value::as_str) {
            Some(t) => page = t.to_string(),
            None => break,
        }
    }
    Ok(out)
}

fn collect(tok: &str) -> Res<Vec<Bday>> {
    let this_year = current_year();
    let mut all = Vec::new();
    let mut ids: Vec<(String, bool)> = Vec::new(); // (calendar id, is the built-in one)
    let mut page = String::new();
    loop {
        let mut q = vec![("maxResults", "250")];
        if !page.is_empty() {
            q.push(("pageToken", &page));
        }
        let v = get(tok, &format!("{API}/users/me/calendarList"), &q)?;
        for c in v.get("items").and_then(Value::as_array).into_iter().flatten() {
            let id = c.get("id").and_then(Value::as_str).unwrap_or("");
            let name = c.get("summary").and_then(Value::as_str).unwrap_or("").to_lowercase();
            if id == ADDRESSBOOK || name.contains("birthday") {
                ids.push((id.to_string(), id == ADDRESSBOOK));
            }
        }
        match v.get("nextPageToken").and_then(Value::as_str) {
            Some(t) => page = t.to_string(),
            None => break,
        }
    }
    for (id, builtin) in &ids {
        all.extend(fetch_events(tok, id, false, *builtin, this_year)?);
    }
    // birthday events you add straight to your own calendar live on the primary calendar
    all.extend(fetch_events(tok, "primary", true, true, this_year)?);
    Ok(all)
}

// ------------------------------------------------------------------ birthdays.txt
fn line_key(line: &str) -> Option<(String, u32, u32)> {
    let l = line.trim();
    if l.is_empty() || l.starts_with('#') {
        return None;
    }
    let (date, rest) = l.split_once(char::is_whitespace)?;
    let parts: Vec<&str> = date.split(|c| c == '-' || c == '/').collect();
    let nums: Vec<u32> = parts.iter().filter_map(|p| p.parse().ok()).collect();
    if nums.len() != parts.len() || !(2..=3).contains(&nums.len()) {
        return None;
    }
    let (m, d) = (nums[nums.len() - 2], nums[nums.len() - 1]);
    Some((rest.split('(').next()?.trim().to_lowercase(), m, d))
}

/// -> (new file text, how many lines went into the block, how many were already listed elsewhere, name clashes)
fn merge(existing: &str, found: &[Bday]) -> Res<(String, usize, usize, Vec<String>)> {
    let lines: Vec<&str> = existing.lines().collect();
    let begin = lines.iter().position(|l| l.starts_with(BEGIN_PREFIX));
    let (before, after): (Vec<&str>, Vec<&str>) = match begin {
        None => (lines.clone(), vec![]),
        Some(a) => {
            let b = lines.iter().enumerate().position(|(i, l)| i > a && l.starts_with(END_PREFIX)).ok_or("birthdays.txt has the start marker of the Google block but no end marker; fix or remove it by hand")?;
            (lines[..a].to_vec(), lines[b + 1..].to_vec())
        }
    };
    let others: Vec<(String, u32, u32)> = before.iter().chain(after.iter()).filter_map(|l| line_key(l)).collect();
    let mut sorted = found.to_vec();
    sorted.sort_by(|a, b| (a.month, a.day, a.name.to_lowercase()).cmp(&(b.month, b.day, b.name.to_lowercase())));
    let (mut out, mut seen, mut skipped, mut clashes) = (Vec::new(), Vec::new(), 0, Vec::new());
    for b in &sorted {
        let key = (b.name.to_lowercase(), b.month, b.day);
        if others.contains(&key) || seen.contains(&key) {
            skipped += 1;
            continue;
        }
        if let Some(o) = others.iter().find(|o| o.0 == key.0) {
            clashes.push(format!("{}: {:02}-{:02} in your list, {:02}-{:02} in Google", b.name, o.1, o.2, b.month, b.day));
        }
        seen.push(key);
        out.push(b.line());
    }
    let mut head: Vec<&str> = before;
    while head.last().map_or(false, |l| l.trim().is_empty()) {
        head.pop();
    }
    let mut text: Vec<String> = head.iter().map(|s| s.to_string()).collect();
    if !text.is_empty() {
        text.push(String::new());
    }
    text.push(BEGIN.into());
    text.extend(out.iter().cloned());
    text.push(END.into());
    let tail: Vec<&str> = after.iter().skip_while(|l| l.trim().is_empty()).cloned().collect();
    if !tail.is_empty() {
        text.push(String::new());
        text.extend(tail.iter().map(|s| s.to_string()));
    }
    Ok((text.join("\n") + "\n", out.len(), skipped, clashes))
}

fn cmd_sync(flags: &[String]) -> Res<()> {
    let (dry, json_out) = (flags.iter().any(|f| f == "--dry-run"), flags.iter().any(|f| f == "--json"));
    let tok = access_token(&load_cfg())?;
    let found = collect(&tok)?;
    if found.is_empty() {
        return Err("no birthday events found in the Birthdays calendar or as birthday events in your main calendar".into());
    }
    let path = birthdays_file();
    let existing = fs::read_to_string(&path).unwrap_or_default();
    let (text, count, skipped, clashes) = merge(&existing, &found)?;
    if dry {
        print!("{text}");
        return Ok(());
    }
    fs::create_dir_all(path.parent().ok_or("bad path")?).map_err(err("config dir"))?;
    let tmp = path.with_extension("txt.tmp");
    fs::write(&tmp, &text).map_err(err("write birthdays.txt"))?;
    fs::rename(&tmp, &path).map_err(err("write birthdays.txt"))?;
    if json_out {
        println!("{}", json!({ "ok": true, "count": count, "skipped": skipped, "clashes": clashes }));
    } else {
        println!("{count} birthdays from Google written to {} ({skipped} already in your list)", path.display());
        for c in clashes {
            println!("  differs: {c}");
        }
        println!("The island picks them up on its next sync (every 15 min), or press refresh in the calendar.");
    }
    Ok(())
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let rest = args.get(1..).unwrap_or(&[]);
    let r = match args.first().map(String::as_str) {
        Some("setup") => cmd_setup(rest),
        Some("auth") => cmd_auth(),
        Some("sync") => cmd_sync(rest),
        Some("status") => cmd_status(),
        Some("logout") => cmd_logout(),
        _ => {
            eprintln!("usage: birthday-sync setup FILE.json | auth | sync [--dry-run] [--json] | status | logout");
            process::exit(2);
        }
    };
    if let Err(e) = r {
        if args.iter().any(|a| a == "--json") {
            println!("{}", json!({ "ok": false, "error": e }));
        } else {
            eprintln!("birthday-sync: {e}");
        }
        process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        for (i, o) in [
            ("Sarah's birthday", "Sarah"),
            ("Sarah’s Birthday", "Sarah"),
            ("James' birthday", "James"),
            ("Chris's birthday", "Chris"),
            ("Rahul's 21st Birthday", "Rahul"),
            ("Birthday: Mom", "Mom"),
            ("Birthday of Dad", "Dad"),
            ("🎂 Amit B'day", "Amit"),
            ("Mom", "Mom"),
            ("Anna Maria (work)'s birthday", "Anna Maria"),
            ("# evil\n12-31 Fake", "evil 12-31 Fake"),
            ("Happy Birthday Priya", "Priya"),
        ] {
            assert_eq!(clean_name(i), o, "input {i:?}");
        }
    }

    #[test]
    fn pct() {
        assert_eq!(pct_decode("4%2F0Abc%3D+x"), "4/0Abc= x");
        assert_eq!(pct_decode("100%"), "100%");
        assert_eq!(pct_decode("%zz"), "%zz");
        assert_eq!(pct_encode(ADDRESSBOOK), "addressbook%23contacts%40group.v.calendar.google.com");
    }

    #[test]
    fn years() {
        assert_eq!(year_from_days(0), 1970);
        assert_eq!(year_from_days(20_000), 2024);
        assert_eq!(year_from_days(-1), 1969);
    }

    #[test]
    fn query() {
        let l = "GET /?state=abc&code=4%2F0X&scope=x HTTP/1.1";
        assert_eq!(query_param(l, "code").as_deref(), Some("4/0X"));
        assert_eq!(query_param(l, "state").as_deref(), Some("abc"));
        assert_eq!(query_param("GET /favicon.ico HTTP/1.1", "code"), None);
    }

    #[test]
    fn events() {
        let ev = json!({"summary":"Sarah's birthday","start":{"date":"1998-10-25"},"eventType":"birthday","birthdayProperties":{"type":"birthday"}});
        assert_eq!(event_to_bday(&ev, false, 2026), Some(Bday { name: "Sarah".into(), month: 10, day: 25, year: Some(1998) }));
        let noyear = json!({"summary":"Bob's birthday","start":{"date":"1604-03-02"},"eventType":"birthday"});
        assert_eq!(event_to_bday(&noyear, true, 2026).unwrap().year, None);
        let thisyr = json!({"summary":"Bob's birthday","start":{"date":"2026-03-02"}});
        assert_eq!(event_to_bday(&thisyr, true, 2026).unwrap().year, None);
        let plain = json!({"summary":"Mom","start":{"date":"1970-04-14"}});
        assert_eq!(event_to_bday(&plain, false, 2026).unwrap().year, None);
        let anniv = json!({"summary":"Their anniversary","start":{"date":"2010-04-14"},"birthdayProperties":{"type":"anniversary"}});
        assert_eq!(event_to_bday(&anniv, true, 2026), None);
        let moved = json!({"summary":"Sarah's birthday","start":{"date":"2025-10-26"},"recurringEventId":"x"});
        assert_eq!(event_to_bday(&moved, true, 2026), None);
    }

    fn b(n: &str, m: u32, d: u32, y: Option<i64>) -> Bday {
        Bday { name: n.into(), month: m, day: d, year: y }
    }

    #[test]
    fn merge_keeps_your_lines_and_is_idempotent() {
        let existing = "# header\n12-28 Linus (1969)\n\n# >>> imported from contacts (x) >>>\n04-14 Mom\n# <<< end of imported contacts <<<\n";
        let found = vec![b("Mom", 4, 14, None), b("Sarah", 10, 25, Some(1998)), b("Sarah", 10, 25, None), b("Amit", 1, 5, None)];
        let (t1, n, skipped, clashes) = merge(existing, &found).unwrap();
        assert_eq!((n, skipped), (2, 2));
        assert!(clashes.is_empty());
        assert!(t1.starts_with("# header\n12-28 Linus (1969)\n\n# >>> imported from contacts (x) >>>\n04-14 Mom\n# <<< end of imported contacts <<<\n\n# >>> imported from Google Calendar"));
        assert!(t1.contains("\n01-05 Amit\n10-25 Sarah (1998)\n# <<< end of Google Calendar birthdays <<<\n"));
        let (t2, ..) = merge(&t1, &found).unwrap();
        assert_eq!(t1, t2);
        // a block in the middle keeps what follows it
        let mid = format!("a\n{BEGIN}\n01-01 Old\n{END}\n\n# tail\n02-02 Typed\n");
        let (t3, ..) = merge(&mid, &[b("New", 3, 3, None)]).unwrap();
        assert_eq!(t3, format!("a\n\n{BEGIN}\n03-03 New\n{END}\n\n# tail\n02-02 Typed\n"));
    }

    #[test]
    fn merge_reports_date_clash_and_refuses_broken_block() {
        let (_, _, _, clashes) = merge("10-25 Sarah\n", &[b("Sarah", 10, 26, None)]).unwrap();
        assert_eq!(clashes.len(), 1);
        assert!(merge(&format!("{BEGIN}\n01-01 X\n"), &[]).is_err());
    }
}
