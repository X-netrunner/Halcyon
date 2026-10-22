//! Paths (XDG, nothing hardcoded), small process helpers, text helpers.

use std::cmp::Ordering;
use std::env;
use std::fs;
use std::io::{self, BufRead, Write};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub fn home() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

fn xdg(var: &str, rel: &str) -> PathBuf {
    match env::var_os(var) {
        Some(v) if !v.is_empty() && Path::new(&v).is_absolute() => PathBuf::from(v),
        _ => home().join(rel),
    }
}

pub fn config_dir() -> PathBuf {
    xdg("XDG_CONFIG_HOME", ".config").join("Halcyon")
}
pub fn games_dir() -> PathBuf {
    config_dir().join("games")
}
pub fn data_dir() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share").join("Halcyon")
}
pub fn data_home() -> PathBuf {
    xdg("XDG_DATA_HOME", ".local/share")
}
pub fn proton_dir() -> PathBuf {
    data_dir().join("proton")
}
pub fn prefixes_dir() -> PathBuf {
    data_dir().join("prefixes")
}
pub fn covers_dir() -> PathBuf {
    data_dir().join("covers")
}
pub fn state_dir() -> PathBuf {
    xdg("XDG_STATE_HOME", ".local/state").join("Halcyon").join("hgl")
}
pub fn logs_dir() -> PathBuf {
    state_dir().join("logs")
}
pub fn gamemode_script() -> PathBuf {
    config_dir().join("scripts").join("gamemode.sh")
}

pub fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

pub fn uid() -> u32 {
    fs::metadata("/proc/self").map(|m| m.uid()).unwrap_or(0)
}

pub fn which(cmd: &str) -> Option<PathBuf> {
    if cmd.contains('/') {
        let p = PathBuf::from(cmd);
        return if p.is_file() { Some(p) } else { None };
    }
    let path = env::var_os("PATH")?;
    env::split_paths(&path).map(|d| d.join(cmd)).find(|p| p.is_file())
}

pub fn have(cmd: &str) -> bool {
    which(cmd).is_some()
}

/// stdout of a successful command, or None.
pub fn out(cmd: &str, args: &[&str]) -> Option<String> {
    let o = Command::new(cmd).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    if o.status.success() {
        Some(String::from_utf8_lossy(&o.stdout).into_owned())
    } else {
        None
    }
}

/// Run a command quietly with a time limit. True when it exited 0 in time.
pub fn run_quiet(cmd: &str, args: &[&str], secs: u64) -> bool {
    let child = Command::new(cmd).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(_) => return false,
    };
    let t0 = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(st)) => return st.success(),
            Ok(None) => {
                if t0.elapsed() > Duration::from_secs(secs) {
                    let _ = child.kill();
                    let _ = child.wait();
                    return false;
                }
                sleep(Duration::from_millis(40));
            }
            Err(_) => return false,
        }
    }
}

pub fn atomic_write(path: &Path, content: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(content.as_bytes())?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)
}

/// `Hades II (GOG)` -> `hades-ii-gog`
pub fn slugify(name: &str) -> String {
    let mut s = String::new();
    let mut dash = false;
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            s.push(c.to_ascii_lowercase());
            dash = false;
        } else if !dash && !s.is_empty() {
            s.push('-');
            dash = true;
        }
    }
    while s.ends_with('-') {
        s.pop();
    }
    if s.is_empty() {
        "game".to_string()
    } else {
        s
    }
}

/// Ids end up in file names and unit names: letters, digits, `.`, `_`, `-`, not starting with a dot.
pub fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 80
        && !s.starts_with('.')
        && !s.starts_with('-')
        && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
}

pub fn valid_env_name(s: &str) -> bool {
    let mut it = s.chars();
    match it.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    it.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Version-aware compare: `GE-Proton9-27` < `GE-Proton10-4`.
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let si = i;
            while i < a.len() && a[i].is_ascii_digit() {
                i += 1;
            }
            let sj = j;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            let na = String::from_utf8_lossy(&a[si..i]).trim_start_matches('0').to_string();
            let nb = String::from_utf8_lossy(&b[sj..j]).trim_start_matches('0').to_string();
            let ord = na.len().cmp(&nb.len()).then_with(|| na.cmp(&nb));
            if ord != Ordering::Equal {
                return ord;
            }
        } else {
            if a[i] != b[j] {
                return a[i].cmp(&b[j]);
            }
            i += 1;
            j += 1;
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

pub fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

pub fn fmt_duration(secs: u64) -> String {
    let (h, m, s) = (secs / 3600, (secs % 3600) / 60, secs % 60);
    if h > 0 {
        format!("{h}h {m:02}m")
    } else if m > 0 {
        format!("{m}m {s:02}s")
    } else {
        format!("{s}s")
    }
}

pub fn ask_yes_no(prompt: &str) -> bool {
    eprint!("{prompt} [y/N] ");
    let _ = io::stderr().flush();
    let mut line = String::new();
    if io::stdin().lock().read_line(&mut line).is_err() {
        return false;
    }
    matches!(line.trim().to_ascii_lowercase().as_str(), "y" | "yes")
}

pub fn is_tty() -> bool {
    // fd 2 is a terminal when /proc/self/fd/2 points at a /dev/pts or /dev/tty node
    fs::read_link("/proc/self/fd/2")
        .map(|p| {
            let s = p.to_string_lossy().to_string();
            s.starts_with("/dev/pts/") || s.starts_with("/dev/tty")
        })
        .unwrap_or(false)
}

/// Split a command-line fragment into words: spaces separate, '...' and "..." group, backslash escapes outside quotes.
pub fn shell_split(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                } else if c == '\\' && q == '"' && matches!(chars.peek(), Some('"') | Some('\\')) {
                    if let Some(n) = chars.next() {
                        cur.push(n);
                    }
                } else {
                    cur.push(c);
                }
            }
            None => {
                if c == '\'' || c == '"' {
                    quote = Some(c);
                    in_word = true;
                } else if c == '\\' {
                    if let Some(n) = chars.next() {
                        cur.push(n);
                        in_word = true;
                    }
                } else if c.is_whitespace() {
                    if in_word {
                        out.push(std::mem::take(&mut cur));
                        in_word = false;
                    }
                } else {
                    cur.push(c);
                    in_word = true;
                }
            }
        }
    }
    if in_word {
        out.push(cur);
    }
    out
}

/// `key=value` lines. `#` starts a comment line. Order is kept.
pub fn parse_kv(text: &str) -> Vec<(String, String)> {
    let mut v = Vec::new();
    for line in text.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        if let Some((k, val)) = t.split_once('=') {
            v.push((k.trim().to_string(), val.trim().to_string()));
        }
    }
    v
}

pub fn parse_bool(s: &str) -> Option<bool> {
    match s.trim().to_ascii_lowercase().as_str() {
        "1" | "on" | "true" | "yes" => Some(true),
        "0" | "off" | "false" | "no" => Some(false),
        _ => None,
    }
}

/// Own-user processes: (pid, comm).
pub fn processes() -> Vec<(u32, String)> {
    let mut v = Vec::new();
    if let Ok(rd) = fs::read_dir("/proc") {
        for e in rd.flatten() {
            let name = e.file_name();
            let name = name.to_string_lossy();
            if let Ok(pid) = name.parse::<u32>() {
                if let Ok(c) = fs::read_to_string(format!("/proc/{pid}/comm")) {
                    v.push((pid, c.trim().to_string()));
                }
            }
        }
    }
    v
}

pub fn pid_alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn natural_order() {
        assert_eq!(natural_cmp("GE-Proton9-27", "GE-Proton10-4"), Ordering::Less);
        assert_eq!(natural_cmp("GE-Proton10-4", "GE-Proton10-4"), Ordering::Equal);
        assert_eq!(natural_cmp("GE-Proton10-10", "GE-Proton10-9"), Ordering::Greater);
    }

    #[test]
    fn slugs_and_ids() {
        assert_eq!(slugify("Hades II (GOG)"), "hades-ii-gog");
        assert_eq!(slugify("***"), "game");
        assert!(valid_id("steam-1145360"));
        assert!(!valid_id("../x"));
        assert!(!valid_id(""));
        assert!(!valid_id(".hidden"));
    }

    #[test]
    fn splitting() {
        assert_eq!(shell_split("-windowed 'my file.txt' \"a b\" c\\ d"), vec!["-windowed", "my file.txt", "a b", "c d"]);
        assert_eq!(shell_split("  "), Vec::<String>::new());
        assert_eq!(shell_split("\"\""), vec![""]);
    }

    #[test]
    fn json_escape() {
        assert_eq!(json_str("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"");
    }

    #[test]
    fn env_names() {
        assert!(valid_env_name("PROTON_LOG"));
        assert!(!valid_env_name("1X"));
        assert!(!valid_env_name("A=B"));
    }
}
