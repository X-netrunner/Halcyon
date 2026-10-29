//! hal audio-set <sink|source> <name>

pub fn run(args: &[String]) -> i32 {
    let kind = match args.first().map(|s| s.as_str()) {
        Some("sink") => "sink",
        Some("source") => "source",
        _ => {
            eprintln!("usage: hal audio-set sink|source <name>");
            return 2;
        }
    };
    let name = match args.get(1).map(|s| s.as_str()) {
        Some(n) if !n.is_empty() => n,
        _ => {
            eprintln!("usage: hal audio-set sink|source <name>");
            return 2;
        }
    };

    if kind == "sink" {
        let _ = crate::util::ok("pactl", &["set-default-sink", name]);
        let out = crate::util::out("pactl", &["list", "short", "sink-inputs"]);
        for line in out.lines() {
            if let Some(id) = line.split_whitespace().next() {
                let _ = crate::util::ok("pactl", &["move-sink-input", id, name]);
            }
        }
    } else {
        let _ = crate::util::ok("pactl", &["set-default-source", name]);
        let out = crate::util::out("pactl", &["list", "short", "source-outputs"]);
        for line in out.lines() {
            if let Some(id) = line.split_whitespace().next() {
                let _ = crate::util::ok("pactl", &["move-source-output", id, name]);
            }
        }
    }

    0
}
