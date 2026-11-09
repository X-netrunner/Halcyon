//! Just enough of Valve's text KeyValues format to read libraryfolders.vdf and appmanifest_*.acf.

#[derive(Debug, Clone, PartialEq)]
pub enum V {
    S(String),
    M(Vec<(String, V)>),
}

impl V {
    pub fn get(&self, key: &str) -> Option<&V> {
        match self {
            V::M(m) => m.iter().find(|(k, _)| k.eq_ignore_ascii_case(key)).map(|(_, v)| v),
            V::S(_) => None,
        }
    }
    pub fn str(&self, key: &str) -> Option<&str> {
        match self.get(key) {
            Some(V::S(s)) => Some(s.as_str()),
            _ => None,
        }
    }
    pub fn entries(&self) -> &[(String, V)] {
        match self {
            V::M(m) => m,
            V::S(_) => &[],
        }
    }
}

#[derive(Debug, PartialEq)]
enum Tok {
    Str(String),
    Open,
    Close,
}

fn tokens(text: &str) -> Vec<Tok> {
    let mut out = Vec::new();
    let mut it = text.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            '{' => out.push(Tok::Open),
            '}' => out.push(Tok::Close),
            '"' => {
                let mut s = String::new();
                while let Some(c) = it.next() {
                    match c {
                        '"' => break,
                        '\\' => match it.next() {
                            Some('n') => s.push('\n'),
                            Some('t') => s.push('\t'),
                            Some(o) => s.push(o),
                            None => break,
                        },
                        o => s.push(o),
                    }
                }
                out.push(Tok::Str(s));
            }
            '/' if it.peek() == Some(&'/') => {
                for c in it.by_ref() {
                    if c == '\n' {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn parse_map(t: &[Tok], i: &mut usize, depth: usize) -> Vec<(String, V)> {
    let mut m = Vec::new();
    while *i < t.len() {
        match &t[*i] {
            Tok::Close => {
                *i += 1;
                return m;
            }
            Tok::Open => {
                *i += 1; // stray brace
            }
            Tok::Str(k) => {
                *i += 1;
                match t.get(*i) {
                    Some(Tok::Str(v)) => {
                        m.push((k.clone(), V::S(v.clone())));
                        *i += 1;
                    }
                    Some(Tok::Open) => {
                        *i += 1;
                        if depth > 32 {
                            return m; // absurdly deep: stop rather than recurse forever
                        }
                        let sub = parse_map(t, i, depth + 1);
                        m.push((k.clone(), V::M(sub)));
                    }
                    _ => {}
                }
            }
        }
    }
    m
}

/// Top level: `"AppState" { ... }` gives `M([("AppState", M(..))])`.
pub fn parse(text: &str) -> V {
    let t = tokens(text);
    let mut i = 0;
    V::M(parse_map(&t, &mut i, 0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest() {
        let v = parse("\"AppState\"\n{\n\t\"appid\"\t\t\"1145360\"\n\t\"name\"\t\t\"Hades\"\n\t\"installdir\" \"Hades\"\n\t\"LastPlayed\"\t\"1700000000\"\n // c\n\t\"UserConfig\" { \"language\" \"english\" }\n}");
        let name = v.get("AppState").and_then(|a| a.str("name"));
        assert_eq!(name, Some("Hades"));
        assert_eq!(v.get("appstate").and_then(|x| x.get("userconfig")).and_then(|x| x.str("language")), Some("english"));
    }

    #[test]
    fn libraries() {
        let v = parse("\"libraryfolders\"\n{\n\"0\"\n{\n\"path\"\t\"/home/u/.local/share/Steam\"\n\"apps\"\n{\n\"228980\"\t\"1\"\n}\n}\n\"1\"\n{\n\"path\"\t\"/mnt/games/SteamLibrary\"\n}\n}");
        let lf = v.get("libraryfolders");
        let paths: Vec<&str> = lf.map(|l| l.entries().iter().filter_map(|(_, f)| f.str("path")).collect()).unwrap_or_default();
        assert_eq!(paths, vec!["/home/u/.local/share/Steam", "/mnt/games/SteamLibrary"]);
    }

    #[test]
    fn garbage_does_not_panic() {
        let _ = parse("\"a\" { \"b\" { \"c\"");
        let _ = parse("}}}{{{\"");
        let deep = "\"a\" {".repeat(500);
        let _ = parse(&deep);
    }
}
