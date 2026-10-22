//! hal tools: the everyday tools that sit on a key, ported from scripts/halcyon-tools.py so a key press does not start Python
//! (about 25 ms on every press; this starts in about 1 ms). Same behaviour, messages and files as the Python version, which
//! keeps the rest (Wi-Fi QR, updates, mixer, phone, VPN, adding snippets) and still works for these too.
//!
//!   hal tools colorpick [hex|rgb|hsl]    pick a pixel, copy its colour, a swatch in the notification, logged in colors.log
//!   hal tools measure                    drag a box, copy its size (WxH)
//!   hal tools zoom in|out|reset|toggle   magnify the screen (Hyprland cursor zoom)
//!   hal tools snippets pick|list|copy|type [name]   a saved text ({date} {time} {clip} filled in)
//!   hal tools windows last|next|prev|pick|list      flip between windows
//!
//! Exit codes: 0 done, 1 could not do it (or cancelled), 2 wrong usage.

use crate::json::{self, Json};
use crate::util::{command_exists, home, notify};
use std::fs;
use std::io::{IsTerminal, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// A tool cannot do what was asked: the text is shown to the person.
struct Fail(String);
type R = Result<i32, Fail>;

fn fail<T>(msg: impl Into<String>) -> Result<T, Fail> {
    Err(Fail(msg.into()))
}

fn is_tty() -> bool {
    std::io::stderr().is_terminal() && std::io::stdin().is_terminal()
}

/// Run a program, feeding `input` on stdin; (exit code, stdout). A program that cannot start is (127, "").
fn sh(cmd: &str, args: &[&str], input: Option<&str>) -> (i32, String) {
    let mut c = Command::new(cmd);
    c.args(args).stdout(Stdio::piped()).stderr(Stdio::null()).stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() });
    let Ok(mut child) = c.spawn() else { return (127, String::new()) };
    if let (Some(text), Some(mut si)) = (input, child.stdin.take()) {
        let _ = si.write_all(text.as_bytes());
    }
    match child.wait_with_output() {
        Ok(o) => (o.status.code().unwrap_or(1), String::from_utf8_lossy(&o.stdout).into_owned()),
        Err(_) => (127, String::new()),
    }
}

fn need(cmd: &str, hint: &str) -> Result<(), Fail> {
    if command_exists(cmd) {
        Ok(())
    } else {
        fail(format!("{cmd} is not installed{}", if hint.is_empty() { String::new() } else { format!(" ({hint})") }))
    }
}

/// A Hyprland dispatcher: the Lua form first (Hyprland 0.55+ refuses the legacy one but still exits 0, so the answer decides).
fn dispatch(lua: &str, legacy: &[&str]) -> Result<(), Fail> {
    let (rc, out) = sh("hyprctl", &["dispatch", lua], None);
    if out.trim() == "ok" {
        return Ok(());
    }
    if !legacy.is_empty() {
        let mut a = vec!["dispatch"];
        a.extend_from_slice(legacy);
        if sh("hyprctl", &a, None).1.trim() == "ok" {
            return Ok(());
        }
    }
    fail(format!("Hyprland refused {lua}: {}", out.lines().next().map(str::to_string).unwrap_or_else(|| format!("exit {rc}"))))
}

fn copy(text: &str) -> Result<(), Fail> {
    need("wl-copy", "pacman -S wl-clipboard")?;
    sh("wl-copy", &[], Some(text));
    Ok(())
}

fn clipboard_text() -> String {
    if !command_exists("wl-paste") {
        return String::new();
    }
    let (rc, out) = sh("wl-paste", &["--no-newline"], None);
    if rc == 0 {
        out
    } else {
        String::new()
    }
}

/// Tell the person: a notification, and a line in the terminal when there is one.
fn done(title: &str, body: &str, icon: Option<&str>) {
    notify(title, body, icon, 5000);
    if is_tty() || !command_exists("notify-send") {
        if body.is_empty() {
            println!("{title}");
        } else {
            println!("{title}: {body}");
        }
    }
}

/// One line from `options` in fuzzel (else wofi / rofi). The index, or None when the menu was closed.
fn pick(options: &[String], prompt: &str) -> Result<Option<usize>, Fail> {
    if options.is_empty() {
        return Ok(None);
    }
    let input = options.join("\n") + "\n";
    let lines = options.len().min(12).to_string();
    let p1 = format!("{prompt}> ");
    let menus: [(&str, Vec<&str>); 3] = [
        ("fuzzel", vec!["--dmenu", "--prompt", &p1, "--width", "50", "--lines", &lines]),
        ("wofi", vec!["--dmenu", "--prompt", prompt]),
        ("rofi", vec!["-dmenu", "-p", prompt]),
    ];
    for (cmd, args) in menus.iter() {
        if command_exists(cmd) {
            let (rc, out) = sh(cmd, args, Some(&input));
            let choice = out.trim_end_matches('\n');
            if rc != 0 || choice.is_empty() {
                return Ok(None);
            }
            return Ok(options.iter().position(|o| o == choice));
        }
    }
    fail("no menu program found (install fuzzel)")
}

fn runtime_dir() -> PathBuf {
    PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into()))
}

fn state_dir() -> PathBuf {
    std::env::var("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(home()).join(".local/state")).join("island")
}

fn conf_dir() -> PathBuf {
    std::env::var("XDG_CONFIG_HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from(home()).join(".config")).join("Halcyon")
}

// ------------------------------------------------------------------------------------------------ colour picker
fn crc32(data: &[u8]) -> u32 {
    let mut c = 0xFFFF_FFFFu32;
    for &b in data {
        c ^= b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
        }
    }
    !c
}

/// zlib framing around "stored" deflate blocks: no compression needed for a 12 KB swatch.
fn zlib_stored(data: &[u8]) -> Vec<u8> {
    let mut o = vec![0x78, 0x01];
    let chunks: Vec<&[u8]> = if data.is_empty() { vec![&[][..]] } else { data.chunks(65535).collect() };
    for (i, ch) in chunks.iter().enumerate() {
        o.push(if i + 1 == chunks.len() { 1 } else { 0 });
        let n = ch.len() as u16;
        o.extend_from_slice(&n.to_le_bytes());
        o.extend_from_slice(&(!n).to_le_bytes());
        o.extend_from_slice(ch);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for &x in data {
        a = (a + x as u32) % 65521;
        b = (b + a) % 65521;
    }
    o.extend_from_slice(&((b << 16) | a).to_be_bytes());
    o
}

/// A solid-colour PNG, written by hand (no imaging library).
pub fn swatch_png(rgb: (u8, u8, u8), size: u32) -> Vec<u8> {
    let mut raw = Vec::with_capacity((size * (size * 3 + 1)) as usize);
    for _ in 0..size {
        raw.push(0);
        for _ in 0..size {
            raw.extend_from_slice(&[rgb.0, rgb.1, rgb.2]);
        }
    }
    let chunk = |tag: &[u8], data: &[u8]| {
        let mut c = (data.len() as u32).to_be_bytes().to_vec();
        let mut td = tag.to_vec();
        td.extend_from_slice(data);
        c.extend_from_slice(&td);
        c.extend_from_slice(&crc32(&td).to_be_bytes());
        c
    };
    let mut ihdr = size.to_be_bytes().to_vec();
    ihdr.extend_from_slice(&size.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    let mut png = b"\x89PNG\r\n\x1a\n".to_vec();
    png.extend(chunk(b"IHDR", &ihdr));
    png.extend(chunk(b"IDAT", &zlib_stored(&raw)));
    png.extend(chunk(b"IEND", &[]));
    png
}

pub fn parse_hex(s: &str) -> Option<(u8, u8, u8)> {
    let b = s.as_bytes();
    (0..b.len()).find_map(|i| {
        let h = s.get(i..i + 6)?;
        let before_ok = i == 0 || !b[i - 1].is_ascii_hexdigit();
        let after_ok = b.get(i + 6).map(|c| !c.is_ascii_alphanumeric()).unwrap_or(true);
        if before_ok && after_ok && h.bytes().all(|c| c.is_ascii_hexdigit()) {
            let v = |k: usize| u8::from_str_radix(&h[k..k + 2], 16).ok();
            Some((v(0)?, v(2)?, v(4)?))
        } else {
            None
        }
    })
}

pub fn rgb_to_hsl(rgb: (u8, u8, u8)) -> (i32, i32, i32) {
    let (r, g, b) = (rgb.0 as f64 / 255.0, rgb.1 as f64 / 255.0, rgb.2 as f64 / 255.0);
    let (mx, mn) = (r.max(g).max(b), r.min(g).min(b));
    let l = (mx + mn) / 2.0;
    if mx == mn {
        return (0, 0, (l * 100.0).round() as i32);
    }
    let d = mx - mn;
    let s = if l > 0.5 { d / (2.0 - mx - mn) } else { d / (mx + mn) };
    let h = if mx == r {
        (g - b) / d + if g < b { 6.0 } else { 0.0 }
    } else if mx == g {
        (b - r) / d + 2.0
    } else {
        (r - g) / d + 4.0
    };
    ((h * 60.0).round() as i32 % 360, (s * 100.0).round() as i32, (l * 100.0).round() as i32)
}

pub fn format_color(rgb: (u8, u8, u8), fmt: &str) -> String {
    match fmt {
        "rgb" => format!("rgb({}, {}, {})", rgb.0, rgb.1, rgb.2),
        "hsl" => {
            let (h, s, l) = rgb_to_hsl(rgb);
            format!("hsl({h}, {s}%, {l}%)")
        }
        _ => format!("#{:02x}{:02x}{:02x}", rgb.0, rgb.1, rgb.2),
    }
}

/// Without hyprpicker: slurp one point, grim that pixel as PPM.
fn pixel_with_grim() -> Result<Option<(u8, u8, u8)>, Fail> {
    need("slurp", "pacman -S slurp")?;
    need("grim", "pacman -S grim")?;
    let (rc, pt) = sh("slurp", &["-p", "-f", "%x,%y 1x1"], None);
    if rc != 0 || pt.trim().is_empty() {
        return Ok(None);
    }
    let o = Command::new("grim").args(["-g", pt.trim(), "-t", "ppm", "-"]).stdin(Stdio::null()).stderr(Stdio::null()).output();
    match o {
        Ok(o) if o.status.success() && o.stdout.starts_with(b"P6") && o.stdout.len() >= 3 => {
            let n = o.stdout.len();
            Ok(Some((o.stdout[n - 3], o.stdout[n - 2], o.stdout[n - 1])))
        }
        _ => fail("grim could not read the pixel"),
    }
}

fn colorpick(args: &[String]) -> R {
    let fmt = args.first().map(|s| s.to_ascii_lowercase()).unwrap_or_else(|| "hex".into());
    if !["hex", "rgb", "hsl"].contains(&fmt.as_str()) {
        return fail("colorpick: format is hex, rgb or hsl");
    }
    let rgb = if command_exists("hyprpicker") {
        let (rc, out) = sh("hyprpicker", &["-f", "hex"], None);
        if rc != 0 {
            return Ok(1); // Escape: nothing to do
        }
        match parse_hex(&out) {
            Some(c) => c,
            None => return fail("hyprpicker gave no colour"),
        }
    } else {
        match pixel_with_grim()? {
            Some(c) => c,
            None => return Ok(1),
        }
    };
    let text = format_color(rgb, &fmt);
    copy(&text)?;
    let png = runtime_dir().join("halcyon-swatch.png");
    let wrote = fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&png).and_then(|mut f| f.write_all(&swatch_png(rgb, 64))).is_ok();
    if wrote && command_exists("systemd-run") {
        let p = png.to_string_lossy();
        sh("systemd-run", &["--user", "--quiet", "--on-active=60s", "rm", "-f", &p], None);
    }
    let st = state_dir();
    let _ = fs::create_dir_all(&st);
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(st.join("colors.log")) {
        let _ = writeln!(f, "{secs} {}", format_color(rgb, "hex"));
    }
    let icon = png.to_string_lossy().to_string();
    done("Colour copied", &text, if wrote { Some(icon.as_str()) } else { None });
    Ok(0)
}

// ------------------------------------------------------------------------------------------------ measure
fn measure() -> R {
    need("slurp", "pacman -S slurp")?;
    let (rc, out) = sh("slurp", &["-f", "%w %h %x %y"], None);
    if rc != 0 || out.trim().is_empty() {
        return Ok(1);
    }
    let v: Vec<i64> = out.split_whitespace().filter_map(|x| x.parse().ok()).collect();
    if v.len() != 4 {
        return fail("could not read the size");
    }
    let text = format!("{}x{}", v[0], v[1]);
    copy(&text)?;
    done("Size copied", &format!("{text} px  ·  at {},{}", v[2], v[3]), None);
    Ok(0)
}

// ------------------------------------------------------------------------------------------------ zoom
pub fn zoom_next(cur: f64, sub: &str) -> f64 {
    let r2 = |x: f64| (x * 100.0).round() / 100.0;
    match sub {
        "in" => {
            if cur >= 1.0 {
                f64::min(10.0, r2(cur + 0.5))
            } else {
                1.5
            }
        }
        "out" => f64::max(1.0, r2(cur - 0.5)),
        "reset" => 1.0,
        _ => {
            if cur > 1.0 {
                1.0
            } else {
                2.0
            }
        }
    }
}

fn zoom(args: &[String]) -> R {
    let sub = args.first().map(String::as_str).unwrap_or("toggle");
    if !["in", "out", "reset", "toggle"].contains(&sub) {
        return fail("zoom: in | out | reset | toggle");
    }
    need("hyprctl", "")?;
    let cur = json::parse(&sh("hyprctl", &["getoption", "cursor:zoom_factor", "-j"], None).1).and_then(|j| j.num("float")).unwrap_or(1.0);
    let z = zoom_next(cur, sub);
    let (rc, out) = sh("hyprctl", &["eval", &format!("hl.config({{ cursor = {{ zoom_factor = {z} }} }})")], None);
    if out.trim() != "ok" {
        let (rc2, out2) = sh("hyprctl", &["keyword", "cursor:zoom_factor", &z.to_string()], None);
        if out2.trim() != "ok" {
            let why = if out2.trim().is_empty() { format!("exit {}", if rc2 != 0 { rc2 } else { rc }) } else { out2.trim().to_string() };
            return fail(format!("Hyprland did not take the zoom: {why}"));
        }
    }
    Ok(0)
}

// ------------------------------------------------------------------------------------------------ snippets
fn load_snippets() -> Vec<(String, String)> {
    let text = fs::read_to_string(conf_dir().join("snippets.json")).unwrap_or_default();
    let mut v: Vec<(String, String)> = json::parse(&text)
        .map(|j| j.entries().iter().filter_map(|(k, x)| if let Json::Str(s) = x { Some((k.clone(), s.clone())) } else { None }).collect())
        .unwrap_or_default();
    v.sort_by(|a, b| a.0.cmp(&b.0));
    v
}

/// {date} {time} {clip} inside a snippet.
pub fn expand(text: &str, date: &dyn Fn(&str) -> String, clip: &dyn Fn() -> String) -> String {
    let mut out = text.to_string();
    if out.contains("{date}") {
        out = out.replace("{date}", &date("+%Y-%m-%d"));
    }
    if out.contains("{time}") {
        out = out.replace("{time}", &date("+%H:%M"));
    }
    if out.contains("{clip}") {
        out = out.replace("{clip}", &clip());
    }
    out
}

fn expand_now(text: &str) -> String {
    expand(text, &|f| sh("date", &[f], None).1.trim().to_string(), &clipboard_text)
}

/// Type it into the focused window with wtype; without wtype, copy it and press Ctrl+V.
fn type_text(text: &str) -> Result<(), Fail> {
    if command_exists("wtype") {
        sh("wtype", &["--", text], None);
        return Ok(());
    }
    copy(text)?;
    if command_exists("hyprctl") {
        std::thread::sleep(std::time::Duration::from_millis(150));
        dispatch("hl.dsp.send_shortcut({ mods = \"CTRL\", key = \"V\" })", &["sendshortcut", "CTRL,V,activewindow"])?;
    }
    Ok(())
}

fn first_line(s: &str, n: usize) -> String {
    s.lines().next().unwrap_or("").chars().take(n).collect()
}

fn snippets(args: &[String]) -> R {
    let sub = args.first().map(String::as_str).unwrap_or("pick");
    let d = load_snippets();
    let get = |name: Option<&String>| name.and_then(|n| d.iter().find(|(k, _)| k == n)).map(|(_, v)| v.clone());
    match sub {
        "list" => {
            for (k, v) in &d {
                println!("{k:<16} {}", first_line(v, 70));
            }
            if d.is_empty() {
                println!("no snippets yet: halcyon snippets add <name> [text]   ({{date}} {{time}} {{clip}} are filled in when it is typed)");
            }
            Ok(0)
        }
        "copy" | "type" => {
            let Some(t) = get(args.get(1)) else { return fail("no such snippet (halcyon snippets list)") };
            let t = expand_now(&t);
            if sub == "copy" {
                copy(&t)?;
            } else {
                type_text(&t)?;
            }
            Ok(0)
        }
        "pick" => {
            if d.is_empty() {
                done("No snippets yet", "halcyon snippets add <name> <text>", None);
                return Ok(1);
            }
            let rows: Vec<String> = d.iter().map(|(k, v)| format!("{k}  ·  {}", first_line(v, 60))).collect();
            match pick(&rows, "Snippet")? {
                Some(i) => {
                    type_text(&expand_now(&d[i].1))?;
                    Ok(0)
                }
                None => Ok(1),
            }
        }
        _ => fail("snippets: pick | list | copy | type   (adding and removing: halcyon snippets add / rm)"),
    }
}

// ------------------------------------------------------------------------------------------------ windows
#[derive(Clone, Debug)]
pub struct Win {
    pub address: String,
    pub class: String,
    pub title: String,
    pub ws_id: i64,
    pub ws_name: String,
    pub x: i64,
    pub y: i64,
    pub history: i64,
}

pub fn parse_clients(text: &str) -> Option<Vec<Win>> {
    let j = json::parse(text)?;
    let b = |c: &Json, k: &str, def: bool| match c.get(k) {
        Some(Json::Bool(v)) => *v,
        _ => def,
    };
    Some(
        j.items()
            .iter()
            .filter(|c| b(c, "mapped", true) && !b(c, "hidden", false))
            .filter_map(|c| {
                let ws = c.get("workspace");
                let at = c.get("at").map(|a| a.items().to_vec()).unwrap_or_default();
                let n = |i: usize| match at.get(i) {
                    Some(Json::Num(v)) => *v as i64,
                    _ => 0,
                };
                Some(Win {
                    address: c.str("address")?.to_string(),
                    class: c.str("class").unwrap_or("?").to_string(),
                    title: c.str("title").unwrap_or("").to_string(),
                    ws_id: ws.and_then(|w| w.num("id")).unwrap_or(0.0) as i64,
                    ws_name: ws.and_then(|w| w.str("name")).unwrap_or("").to_string(),
                    x: n(0),
                    y: n(1),
                    history: c.num("focusHistoryID").unwrap_or(99.0) as i64,
                })
            })
            .collect(),
    )
}

/// A steady order to cycle through: by workspace, then left to right, then top to bottom.
pub fn window_order(mut v: Vec<Win>) -> Vec<Win> {
    v.sort_by_key(|c| (c.ws_id, c.x, c.y));
    v
}

pub fn window_label(c: &Win) -> String {
    let ws = if c.ws_name.is_empty() { c.ws_id.to_string() } else { c.ws_name.clone() };
    let t = c.title.trim();
    let title: String = (if t.is_empty() { c.class.as_str() } else { t }).chars().take(60).collect();
    format!("{}  ·  {title}  [{ws}]", c.class)
}

fn clients() -> Result<Vec<Win>, Fail> {
    need("hyprctl", "")?;
    parse_clients(&sh("hyprctl", &["clients", "-j"], None).1).map_or_else(|| fail("hyprctl gave no window list (is Hyprland running?)"), Ok)
}

fn focus(c: &Win) -> Result<(), Fail> {
    let a = format!("address:{}", c.address);
    dispatch(&format!("hl.dsp.focus({{ window = \"{a}\" }})"), &["focuswindow", &a])?;
    dispatch("hl.dsp.window.bring_to_top()", &["bringactivetotop"])
}

fn windows(args: &[String]) -> R {
    let sub = args.first().map(String::as_str).unwrap_or("last");
    match sub {
        "last" => {
            need("hyprctl", "")?;
            dispatch("hl.dsp.focus({ last = true })", &["focuscurrentorlast"])?;
            Ok(0)
        }
        "list" => {
            for c in window_order(clients()?) {
                println!("{}", window_label(&c));
            }
            Ok(0)
        }
        "next" | "prev" => {
            let order = window_order(clients()?);
            if order.is_empty() {
                return Ok(1);
            }
            let active = json::parse(&sh("hyprctl", &["activewindow", "-j"], None).1).and_then(|j| j.str("address").map(str::to_string)).unwrap_or_default();
            let n = order.len() as i64;
            let idx = order.iter().position(|c| c.address == active).map(|i| i as i64).unwrap_or(-1);
            let step = if sub == "next" { 1 } else { -1 };
            focus(&order[((idx + step).rem_euclid(n)) as usize])?;
            Ok(0)
        }
        "pick" => {
            let mut order = clients()?;
            order.sort_by_key(|c| c.history); // most recently used first
            let rows: Vec<String> = order.iter().map(window_label).collect();
            match pick(&rows, "Window")? {
                Some(i) => {
                    focus(&order[i])?;
                    Ok(0)
                }
                None => Ok(1),
            }
        }
        _ => fail("windows: last | next | prev | pick | list"),
    }
}

// ------------------------------------------------------------------------------------------------ entry
pub fn run(args: &[String]) -> i32 {
    let Some(tool) = args.first().map(String::as_str) else {
        eprintln!("hal tools colorpick [hex|rgb|hsl] | measure | zoom in|out|reset|toggle | snippets pick|list|copy|type | windows last|next|prev|pick|list");
        return 2;
    };
    let rest = &args[1..];
    let res = match tool {
        "colorpick" | "color" => colorpick(rest),
        "measure" => measure(),
        "zoom" => zoom(rest),
        "snippets" | "snippet" => snippets(rest),
        "windows" => windows(rest),
        other => {
            eprintln!("hal tools: unknown tool '{other}' (the other tools are in scripts/halcyon-tools.py)");
            return 2;
        }
    };
    match res {
        Ok(c) => c,
        Err(Fail(msg)) => {
            if is_tty() || !command_exists("notify-send") {
                eprintln!("halcyon {tool}: {msg}");
            } else {
                notify(&format!("Halcyon: {tool}"), &msg, Some("dialog-warning"), 5000);
            }
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn colours() {
        assert_eq!(parse_hex("#1a2B3c\n"), Some((0x1a, 0x2b, 0x3c)));
        assert_eq!(parse_hex("no colour"), None);
        assert_eq!(format_color((255, 0, 0), "hsl"), "hsl(0, 100%, 50%)");
        assert_eq!(format_color((18, 52, 86), "rgb"), "rgb(18, 52, 86)");
        assert_eq!(format_color((18, 52, 86), "hex"), "#123456");
        assert_eq!(rgb_to_hsl((128, 128, 128)), (0, 0, 50));
    }

    #[test]
    fn swatch_is_a_valid_png() {
        let p = swatch_png((10, 20, 30), 64);
        assert!(p.starts_with(b"\x89PNG\r\n\x1a\n"));
        assert!(p.ends_with(&[0xAE, 0x42, 0x60, 0x82])); // the IEND CRC every PNG ends with
        assert_eq!(crc32(b"IEND"), 0xAE42_6082);
    }

    #[test]
    fn zoom_steps() {
        assert_eq!(zoom_next(1.0, "toggle"), 2.0);
        assert_eq!(zoom_next(2.0, "toggle"), 1.0);
        assert_eq!(zoom_next(1.0, "in"), 1.5);
        assert_eq!(zoom_next(10.0, "in"), 10.0);
        assert_eq!(zoom_next(1.2, "out"), 1.0);
    }

    #[test]
    fn snippet_placeholders() {
        let d = |f: &str| if f.contains('Y') { "2026-10-22".to_string() } else { "18:30".to_string() };
        assert_eq!(expand("on {date} at {time}: {clip}", &d, &|| "X".to_string()), "on 2026-10-22 at 18:30: X");
        assert_eq!(expand("plain", &d, &|| panic!("clipboard read without {{clip}}")), "plain");
    }

    #[test]
    fn hyprctl_clients() {
        let t = r#"[{"address":"0xa","mapped":true,"hidden":false,"at":[900,40],"workspace":{"id":2,"name":"2"},"class":"foot","title":"vim","focusHistoryID":1},
                   {"address":"0xb","mapped":true,"hidden":false,"at":[10,40],"workspace":{"id":2,"name":"2"},"class":"firefox","title":"","focusHistoryID":0},
                   {"address":"0xc","mapped":false,"hidden":false,"at":[0,0],"workspace":{"id":1,"name":"1"},"class":"x","title":"x","focusHistoryID":2}]"#;
        let v = parse_clients(t).unwrap_or_default();
        assert_eq!(v.len(), 2);
        let o = window_order(v);
        assert_eq!(o[0].address, "0xb");
        assert_eq!(window_label(&o[0]), "firefox  ·  firefox  [2]");
    }
}
