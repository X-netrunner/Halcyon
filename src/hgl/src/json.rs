//! A small JSON reader (no dependencies) for what `legendary` prints and the store APIs answer. Handles every escape, including
//! `\uXXXX` pairs: legendary writes non-ASCII titles that way.

#[derive(Clone, Debug, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(Vec<(String, Json)>),
}

impl Json {
    pub fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Obj(v) => v.iter().find(|(k, _)| k == key).map(|(_, x)| x),
            _ => None,
        }
    }
    /// A string member.
    pub fn str(&self, key: &str) -> Option<&str> {
        match self.get(key)? {
            Json::Str(s) => Some(s.as_str()),
            _ => None,
        }
    }
    /// A number member.
    pub fn num(&self, key: &str) -> Option<f64> {
        match self.get(key)? {
            Json::Num(n) => Some(*n),
            _ => None,
        }
    }
    /// The elements of an array (empty for anything else).
    pub fn items(&self) -> &[Json] {
        match self {
            Json::Arr(v) => v.as_slice(),
            _ => &[],
        }
    }
    /// The members of an object (empty for anything else).
    pub fn entries(&self) -> &[(String, Json)] {
        match self {
            Json::Obj(v) => v.as_slice(),
            _ => &[],
        }
    }
}

struct P {
    c: Vec<char>,
    i: usize,
    depth: u32,
}

pub fn parse(text: &str) -> Option<Json> {
    let mut p = P { c: text.chars().collect(), i: 0, depth: 0 };
    p.ws();
    let v = p.value()?;
    p.ws();
    if p.i == p.c.len() {
        Some(v)
    } else {
        None
    }
}

impl P {
    fn peek(&self) -> Option<char> {
        self.c.get(self.i).copied()
    }

    fn ws(&mut self) {
        while let Some(c) = self.peek() {
            if c.is_whitespace() {
                self.i += 1;
            } else {
                break;
            }
        }
    }

    fn value(&mut self) -> Option<Json> {
        if self.depth > 64 {
            return None;
        }
        match self.peek()? {
            '{' => self.object(),
            '[' => self.array(),
            '"' => self.string().map(Json::Str),
            't' => self.lit("true", Json::Bool(true)),
            'f' => self.lit("false", Json::Bool(false)),
            'n' => self.lit("null", Json::Null),
            _ => self.number(),
        }
    }

    fn lit(&mut self, word: &str, v: Json) -> Option<Json> {
        for ch in word.chars() {
            if self.peek()? != ch {
                return None;
            }
            self.i += 1;
        }
        Some(v)
    }

    fn number(&mut self) -> Option<Json> {
        let start = self.i;
        while let Some(c) = self.peek() {
            if c.is_ascii_digit() || c == '+' || c == '-' || c == '.' || c == 'e' || c == 'E' {
                self.i += 1;
            } else {
                break;
            }
        }
        if start == self.i {
            return None;
        }
        let t: String = self.c[start..self.i].iter().collect();
        t.parse::<f64>().ok().map(Json::Num)
    }

    fn hex4(&mut self) -> Option<u32> {
        let mut n: u32 = 0;
        for _ in 0..4 {
            let d = self.peek()?.to_digit(16)?;
            n = n * 16 + d;
            self.i += 1;
        }
        Some(n)
    }

    fn string(&mut self) -> Option<String> {
        self.i += 1; // the opening quote
        let mut s = String::new();
        loop {
            let c = self.peek()?;
            self.i += 1;
            match c {
                '"' => return Some(s),
                '\\' => {
                    let e = self.peek()?;
                    self.i += 1;
                    match e {
                        '"' => s.push('"'),
                        '\\' => s.push('\\'),
                        '/' => s.push('/'),
                        'b' => s.push('\u{8}'),
                        'f' => s.push('\u{c}'),
                        'n' => s.push('\n'),
                        'r' => s.push('\r'),
                        't' => s.push('\t'),
                        'u' => {
                            let hi = self.hex4()?;
                            let cp = if (0xD800..0xDC00).contains(&hi) {
                                // a high surrogate must be followed by \uDC00..\uDFFF
                                if self.peek()? == '\\' && self.c.get(self.i + 1) == Some(&'u') {
                                    self.i += 2;
                                    let lo = self.hex4()?;
                                    if !(0xDC00..0xE000).contains(&lo) {
                                        return None;
                                    }
                                    0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                                } else {
                                    return None;
                                }
                            } else {
                                hi
                            };
                            s.push(char::from_u32(cp).unwrap_or('\u{fffd}'));
                        }
                        _ => return None,
                    }
                }
                c => s.push(c),
            }
        }
    }

    fn array(&mut self) -> Option<Json> {
        self.i += 1; // [
        self.depth += 1;
        let mut v = Vec::new();
        self.ws();
        if self.peek()? == ']' {
            self.i += 1;
            self.depth -= 1;
            return Some(Json::Arr(v));
        }
        loop {
            self.ws();
            v.push(self.value()?);
            self.ws();
            match self.peek()? {
                ',' => self.i += 1,
                ']' => {
                    self.i += 1;
                    break;
                }
                _ => return None,
            }
        }
        self.depth -= 1;
        Some(Json::Arr(v))
    }

    fn object(&mut self) -> Option<Json> {
        self.i += 1; // {
        self.depth += 1;
        let mut v: Vec<(String, Json)> = Vec::new();
        self.ws();
        if self.peek()? == '}' {
            self.i += 1;
            self.depth -= 1;
            return Some(Json::Obj(v));
        }
        loop {
            self.ws();
            if self.peek()? != '"' {
                return None;
            }
            let k = self.string()?;
            self.ws();
            if self.peek()? != ':' {
                return None;
            }
            self.i += 1;
            self.ws();
            let x = self.value()?;
            v.push((k, x));
            self.ws();
            match self.peek()? {
                ',' => self.i += 1,
                '}' => {
                    self.i += 1;
                    break;
                }
                _ => return None,
            }
        }
        self.depth -= 1;
        Some(Json::Obj(v))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_objects_and_arrays() {
        let j = parse(r#" {"a": [1, 2.5, -3e2], "b": {"c": "x"}, "t": true, "n": null} "#);
        let j = j.unwrap_or(Json::Null);
        assert_eq!(j.get("a").map(|a| a.items().len()), Some(3));
        assert_eq!(j.get("b").and_then(|b| b.str("c")), Some("x"));
        assert_eq!(j.get("t"), Some(&Json::Bool(true)));
        assert_eq!(j.get("n"), Some(&Json::Null));
        assert_eq!(j.get("a").map(|a| a.items()[2].clone()), Some(Json::Num(-300.0)));
    }

    #[test]
    fn escapes_and_surrogates() {
        let j = parse(r#"{"t": "Pok\u00e9mon \"x\" \\ \n \ud83c\udfae"}"#).unwrap_or(Json::Null);
        assert_eq!(j.str("t"), Some("Pokémon \"x\" \\ \n 🎮"));
    }

    #[test]
    fn refuses_broken_input() {
        assert!(parse("{").is_none());
        assert!(parse("[1,]").is_none());
        assert!(parse("{\"a\" 1}").is_none());
        assert!(parse("[1] x").is_none());
        assert!(parse("\"\\ud83c\"").is_none());
        let deep = "[".repeat(200);
        assert!(parse(&deep).is_none());
    }

    #[test]
    fn empty_accessors() {
        let j = Json::Null;
        assert!(j.items().is_empty() && j.entries().is_empty() && j.get("x").is_none());
    }
}
