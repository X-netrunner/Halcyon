//! Grammars (GBNF) that force the embedded model to answer in exactly the JSON shape each
//! prompt asks for, so a 0.5B model cannot return broken JSON, extra prose or an id it was not given.
//!
//! The grammar fixes the *shape*: keys, ids, lengths, and for "Describe a mood" the genre
//! words (a fixed vocabulary). It cannot make the words good; the validators in `validate.rs`
//! still check everything the model returns, exactly as they do for Ollama.
//!
//! Everything here is plain text generation, so it is tested without llama.cpp. The tests carry a
//! small GBNF matcher of their own to check what each grammar accepts and rejects.

use super::backend::Shape;

/// Genre and mood words the embedded model may use in a search plan. Lower case, no quotes or
/// backslashes. The catalogue search turns these into queries, so every entry must be a word a
/// person would type into a music search.
pub const VOCABULARY: &[&str] = &[
    "ambient", "chillout", "chillhop", "lo-fi", "downtempo", "trip-hop", "jazz", "smooth jazz", "blues", "soul",
    "r&b", "funk", "disco", "house", "deep house", "techno", "trance", "drum and bass", "dubstep", "electronic",
    "synthwave", "synthpop", "idm", "dance", "pop", "indie pop", "indie rock", "indie folk", "folk", "acoustic",
    "singer-songwriter", "country", "rock", "classic rock", "hard rock", "alternative", "post-rock", "shoegaze",
    "punk", "pop punk", "emo", "metal", "heavy metal", "grunge", "hip hop", "rap", "trap", "reggae", "latin",
    "reggaeton", "afrobeats", "k-pop", "j-pop", "bollywood", "classical", "piano", "orchestral", "soundtrack",
    "cinematic", "instrumental", "experimental", "new age", "meditation", "sleep", "study", "focus", "workout",
    "party", "happy", "sad", "melancholic", "romantic", "energetic", "calm", "dreamy", "dark", "uplifting",
    "nostalgic", "road trip",
];

/// Decades the plan's `era` may name.
const DECADES: &[&str] = &["1950s", "1960s", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s"];

/// Most songs a pick may list (the prompts ask for up to 25).
const MAX_PICKS: usize = 25;

/// A GBNF string literal for `s`.
fn lit(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

/// `("a" | "b" | ...)` for a list of words.
fn one_of(words: &[&str]) -> String {
    let parts: Vec<String> = words.iter().map(|w| lit(w)).collect();
    format!("({})", parts.join(" | "))
}

/// Rules shared by the shaped grammars: bounded free text with no quote, backslash or control
/// character inside, so it can never break out of its JSON string.
const TEXT_RULES: &str = "tchar ::= [^\"\\\\\\x00-\\x1F]\n";

/// A grammar that accepts any JSON object, with no free whitespace runs (a model that loops on
/// spaces cannot stall it).
const ANY_JSON: &str = r#"root ::= object
value ::= object | array | string | number | ("true" | "false" | "null")
object ::= "{" ( string ":" value ("," string ":" value){0,40} )? "}"
array ::= "[" ( value ("," value){0,60} )? "]"
string ::= "\"" ( [^"\\\x7F\x00-\x1F] | "\\" ["\\/bfnrt] ){0,300} "\""
number ::= "-"? ("0" | [1-9] [0-9]{0,8}) ("." [0-9]{1,6})?
"#;

/// The grammar for `shape`, as GBNF text with `root` as its start rule.
pub fn grammar_for(shape: &Shape) -> String {
    match shape {
        Shape::AnyJson => ANY_JSON.to_string(),
        Shape::WhyMix { mixes } => {
            let n = (*mixes).clamp(1, 8);
            let items: Vec<String> = (1..=n)
                .map(|i| format!("\"{{\\\"id\\\":\\\"m{i}\\\",\\\"title\\\":\\\"\" title \"\\\",\\\"reason\\\":\\\"\" reason \"\\\"}}\""))
                .collect();
            format!(
                "root ::= \"{{\\\"mixes\\\":[\" {} \"]}}\"\n{TEXT_RULES}title ::= tchar{{2,28}}\nreason ::= tchar{{8,70}}\n",
                items.join(" \",\" ")
            )
        }
        Shape::Query => format!(
            "root ::= \"{{\\\"title\\\":\\\"\" title \"\\\",\\\"seed_artists\\\":[],\\\"genres\\\":[\" genre (\",\" genre){{0,3}} \"],\\\"energy\\\":\" energy \",\\\"instrumental\\\":\" flag \",\\\"era\\\":\" era \"}}\"\n\
             {TEXT_RULES}title ::= tchar{{2,28}}\n\
             genre ::= \"\\\"\" {} \"\\\"\"\n\
             energy ::= \"0\" (\".\" [0-9])? | \"1\" (\".0\")?\n\
             flag ::= \"true\" | \"false\" | \"null\"\n\
             era ::= \"null\" | \"\\\"\" {} \"\\\"\"\n",
            one_of(VOCABULARY),
            one_of(DECADES)
        ),
        Shape::Pick { candidates } => format!(
            "root ::= \"{{\\\"title\\\":\\\"\" title \"\\\",\\\"reason\\\":\\\"\" reason \"\\\",\\\"picks\\\":[\" pick (\",\" pick){{0,{}}} \"]}}\"\n\
             {TEXT_RULES}title ::= tchar{{2,28}}\nreason ::= tchar{{8,70}}\n{}",
            MAX_PICKS - 1,
            pick_rule(*candidates)
        ),
        Shape::Rerank { candidates } => format!(
            "root ::= \"{{\\\"picks\\\":[\" pick (\",\" pick){{0,{}}} \"]}}\"\n{}",
            MAX_PICKS - 1,
            pick_rule(*candidates)
        ),
    }
}

/// `pick ::= "\"t1\"" | "\"t2\"" ...` for the numbered candidates the model was shown.
fn pick_rule(candidates: usize) -> String {
    let n = candidates.clamp(1, 50);
    let parts: Vec<String> = (1..=n).map(|i| format!("\"\\\"t{i}\\\"\"")).collect();
    format!("pick ::= {}\n", parts.join(" | "))
}

/// A sentence appended to the system prompt of the embedded model, for shapes where the
/// grammar is stricter than the shared prompt says.
pub fn addendum(shape: &Shape) -> Option<String> {
    match shape {
        Shape::Query => Some(format!(
            "\n\nFor this app: seed_artists must always be an empty list []. The app finds artists itself. \
             genres may only use words from this list: {}. era may only be a decade like \"1990s\" or null.",
            VOCABULARY.join(", ")
        )),
        _ => None,
    }
}

#[cfg(test)]
pub(crate) mod matcher {
    //! A tiny matcher for the GBNF subset used above: literals, character classes, rule
    //! references, groups, alternation, `?` `*` `+` and `{m}` `{m,n}`. Used only by tests.

    use std::collections::{BTreeSet, HashMap};

    #[derive(Debug, Clone)]
    enum Atom {
        Lit(Vec<char>),
        Class { negated: bool, items: Vec<(char, char)> },
        Rule(String),
        Group(Vec<Vec<Item>>),
    }

    #[derive(Debug, Clone)]
    struct Item {
        atom: Atom,
        min: usize,
        max: usize,
    }

    pub struct Grammar {
        rules: HashMap<String, Vec<Vec<Item>>>,
    }

    struct Parser<'a> {
        chars: Vec<char>,
        pos: usize,
        _src: &'a str,
    }

    impl<'a> Parser<'a> {
        fn peek(&self) -> Option<char> {
            self.chars.get(self.pos).copied()
        }
        fn skip_ws(&mut self) {
            while matches!(self.peek(), Some(' ') | Some('\t')) {
                self.pos += 1;
            }
        }
        fn escape(&mut self) -> char {
            // after a backslash
            let c = self.chars[self.pos];
            self.pos += 1;
            match c {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                'x' => {
                    let hex: String = self.chars[self.pos..self.pos + 2].iter().collect();
                    self.pos += 2;
                    char::from_u32(u32::from_str_radix(&hex, 16).expect("hex escape")).expect("char")
                }
                other => other,
            }
        }
        fn alt(&mut self, in_group: bool) -> Vec<Vec<Item>> {
            let mut alts = vec![self.seq(in_group)];
            loop {
                self.skip_ws();
                if self.peek() == Some('|') {
                    self.pos += 1;
                    alts.push(self.seq(in_group));
                } else {
                    break;
                }
            }
            alts
        }
        fn seq(&mut self, in_group: bool) -> Vec<Item> {
            let mut items = Vec::new();
            loop {
                self.skip_ws();
                let atom = match self.peek() {
                    None | Some('\n') | Some('|') => break,
                    Some(')') if in_group => break,
                    Some('"') => {
                        self.pos += 1;
                        let mut s = Vec::new();
                        while self.peek() != Some('"') {
                            let c = self.chars[self.pos];
                            self.pos += 1;
                            if c == '\\' {
                                s.push(self.escape());
                            } else {
                                s.push(c);
                            }
                        }
                        self.pos += 1;
                        Atom::Lit(s)
                    }
                    Some('[') => {
                        self.pos += 1;
                        let negated = self.peek() == Some('^');
                        if negated {
                            self.pos += 1;
                        }
                        let mut items = Vec::new();
                        while self.peek() != Some(']') {
                            let lo = self.class_char();
                            if self.peek() == Some('-') && self.chars.get(self.pos + 1) != Some(&']') {
                                self.pos += 1;
                                let hi = self.class_char();
                                items.push((lo, hi));
                            } else {
                                items.push((lo, lo));
                            }
                        }
                        self.pos += 1;
                        Atom::Class { negated, items }
                    }
                    Some('(') => {
                        self.pos += 1;
                        let alts = self.alt(true);
                        self.skip_ws();
                        assert_eq!(self.peek(), Some(')'), "unclosed group");
                        self.pos += 1;
                        Atom::Group(alts)
                    }
                    Some(c) if c.is_ascii_lowercase() => {
                        let start = self.pos;
                        while matches!(self.peek(), Some(c) if c.is_ascii_alphanumeric() || c == '-') {
                            self.pos += 1;
                        }
                        Atom::Rule(self.chars[start..self.pos].iter().collect())
                    }
                    Some(c) => panic!("unexpected {c:?} in grammar"),
                };
                let (min, max) = match self.peek() {
                    Some('?') => {
                        self.pos += 1;
                        (0, 1)
                    }
                    Some('*') => {
                        self.pos += 1;
                        (0, usize::MAX)
                    }
                    Some('+') => {
                        self.pos += 1;
                        (1, usize::MAX)
                    }
                    Some('{') => {
                        self.pos += 1;
                        let start = self.pos;
                        while self.peek() != Some('}') {
                            self.pos += 1;
                        }
                        let body: String = self.chars[start..self.pos].iter().collect();
                        self.pos += 1;
                        match body.split_once(',') {
                            None => {
                                let n = body.parse().expect("{n}");
                                (n, n)
                            }
                            Some((a, "")) => (a.parse().expect("{m,}"), usize::MAX),
                            Some((a, b)) => (a.parse().expect("{m,n}"), b.parse().expect("{m,n}")),
                        }
                    }
                    _ => (1, 1),
                };
                items.push(Item { atom, min, max });
            }
            items
        }
        fn class_char(&mut self) -> char {
            let c = self.chars[self.pos];
            self.pos += 1;
            if c == '\\' {
                self.escape()
            } else {
                c
            }
        }
    }

    impl Grammar {
        pub fn parse(src: &str) -> Grammar {
            let mut rules = HashMap::new();
            for line in src.lines() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let (name, body) = line.split_once("::=").unwrap_or_else(|| panic!("not a rule: {line}"));
                let mut p = Parser { chars: body.trim().chars().collect(), pos: 0, _src: src };
                let alts = p.alt(false);
                assert_eq!(p.pos, p.chars.len(), "trailing text in rule {name}");
                rules.insert(name.trim().to_string(), alts);
            }
            assert!(rules.contains_key("root"), "no root rule");
            Grammar { rules }
        }

        /// Does the whole text match `root`?
        pub fn accepts(&self, text: &str) -> bool {
            let chars: Vec<char> = text.chars().collect();
            let ends = self.alt_ends(&self.rules["root"], &chars, &BTreeSet::from([0]));
            ends.contains(&chars.len())
        }

        fn alt_ends(&self, alts: &[Vec<Item>], text: &[char], starts: &BTreeSet<usize>) -> BTreeSet<usize> {
            let mut out = BTreeSet::new();
            for seq in alts {
                let mut cur = starts.clone();
                for item in seq {
                    cur = self.item_ends(item, text, &cur);
                    if cur.is_empty() {
                        break;
                    }
                }
                out.extend(cur);
            }
            out
        }

        fn atom_ends(&self, atom: &Atom, text: &[char], starts: &BTreeSet<usize>) -> BTreeSet<usize> {
            let mut out = BTreeSet::new();
            match atom {
                Atom::Lit(s) => {
                    for &p in starts {
                        if text.len() >= p + s.len() && text[p..p + s.len()] == s[..] {
                            out.insert(p + s.len());
                        }
                    }
                }
                Atom::Class { negated, items } => {
                    for &p in starts {
                        if let Some(&c) = text.get(p) {
                            let inside = items.iter().any(|&(lo, hi)| c >= lo && c <= hi);
                            if inside != *negated {
                                out.insert(p + 1);
                            }
                        }
                    }
                }
                Atom::Rule(name) => {
                    let alts = self.rules.get(name).unwrap_or_else(|| panic!("missing rule {name}"));
                    out = self.alt_ends(alts, text, starts);
                }
                Atom::Group(alts) => out = self.alt_ends(alts, text, starts),
            }
            out
        }

        fn item_ends(&self, item: &Item, text: &[char], starts: &BTreeSet<usize>) -> BTreeSet<usize> {
            let mut result = BTreeSet::new();
            let mut cur = starts.clone();
            let mut count = 0usize;
            if item.min == 0 {
                result.extend(cur.iter().copied());
            }
            while count < item.max && !cur.is_empty() {
                cur = self.atom_ends(&item.atom, text, &cur);
                count += 1;
                if count >= item.min {
                    result.extend(cur.iter().copied());
                }
                if count > text.len() + 2 {
                    break;
                }
            }
            result
        }
    }
}

#[cfg(test)]
mod tests {
    use super::matcher::Grammar;
    use super::*;
    use crate::llm::validate;
    use std::collections::HashMap;

    fn g(shape: &Shape) -> Grammar {
        Grammar::parse(&grammar_for(shape))
    }

    #[test]
    fn why_mix_accepts_the_prompt_shape_and_nothing_else() {
        let gr = g(&Shape::WhyMix { mixes: 2 });
        let ok = r#"{"mixes":[{"id":"m1","title":"Your Echo Phase","reason":"The songs you keep coming back to."},{"id":"m2","title":"Back To Nova","reason":"Old favourites you have not played."}]}"#;
        assert!(gr.accepts(ok));
        // wrong count, wrong id, extra key, prose around it, too-long title, quote inside text
        assert!(!gr.accepts(r#"{"mixes":[{"id":"m1","title":"Your Echo Phase","reason":"The songs you keep coming back to."}]}"#));
        assert!(!gr.accepts(&ok.replace("\"m2\"", "\"m3\"")));
        assert!(!gr.accepts(&ok.replace("\"reason\"", "\"why\"")));
        assert!(!gr.accepts(&format!("Sure! {ok}")));
        assert!(!gr.accepts(&ok.replace("Your Echo Phase", &"x".repeat(29))));
        assert!(!gr.accepts(&ok.replace("Your Echo Phase", "Your \\\"Echo\\\" Phase")));
        assert!(!gr.accepts(&ok.replace("Your Echo Phase", "Your \"Echo\" Phase")));
    }

    #[test]
    fn why_mix_output_passes_the_real_validator() {
        let gr = g(&Shape::WhyMix { mixes: 1 });
        let out = r#"{"mixes":[{"id":"m1","title":"Morning Lift","reason":"Upbeat picks for the hour you usually listen."}]}"#;
        assert!(gr.accepts(out));
        let mut aliases = HashMap::new();
        aliases.insert("m1".to_string(), ("real-1".to_string(), "Good morning Mix".to_string()));
        let blurbs = validate::parse_why_mix(out, &aliases);
        assert_eq!(blurbs.len(), 1);
        assert_eq!(blurbs[0].mix_id, "real-1");
    }

    #[test]
    fn query_grammar_forces_the_fixed_vocabulary_and_no_artists() {
        let gr = g(&Shape::Query);
        let ok = r#"{"title":"Rainy Night Code","seed_artists":[],"genres":["ambient","lo-fi","instrumental"],"energy":0.3,"instrumental":true,"era":null}"#;
        assert!(gr.accepts(ok));
        assert!(gr.accepts(&ok.replace("0.3", "1").replace("null}", "\"1990s\"}")));
        assert!(gr.accepts(&ok.replace("0.3", "0")));
        // an artist the model made up, a genre outside the vocabulary, energy out of range,
        // five genres, no genre, a century instead of a decade
        assert!(!gr.accepts(&ok.replace("[],\"genres\"", "[\"Nils Frahm\"],\"genres\"")));
        assert!(!gr.accepts(&ok.replace("\"ambient\"", "\"vaporwave\"")));
        assert!(!gr.accepts(&ok.replace("0.3", "1.5")));
        assert!(!gr.accepts(&ok.replace("0.3", "7")));
        assert!(!gr.accepts(&ok.replace("[\"ambient\",\"lo-fi\",\"instrumental\"]", "[\"ambient\",\"lo-fi\",\"jazz\",\"funk\",\"soul\"]")));
        assert!(!gr.accepts(&ok.replace("[\"ambient\",\"lo-fi\",\"instrumental\"]", "[]")));
        assert!(!gr.accepts(&ok.replace("null}", "\"19th century\"}")));
    }

    #[test]
    fn query_output_passes_the_real_validator() {
        let gr = g(&Shape::Query);
        let out = r#"{"title":"90s Workout Boost","seed_artists":[],"genres":["dance","workout"],"energy":0.9,"instrumental":null,"era":"1990s"}"#;
        assert!(gr.accepts(out));
        let spec = validate::parse_query(out).expect("plan parses");
        assert_eq!(spec.genres, vec!["dance", "workout"]);
        assert!(spec.seed_artists.is_empty());
        assert_eq!(spec.era.is_some(), true);
    }

    #[test]
    fn every_vocabulary_word_is_usable_in_a_grammar_and_a_search() {
        let gr = g(&Shape::Query);
        for w in VOCABULARY {
            assert!(!w.contains('"') && !w.contains('\\'), "{w}");
            assert_eq!(*w, w.to_lowercase(), "{w}");
            let out = format!(r#"{{"title":"Test Mix","seed_artists":[],"genres":["{w}"],"energy":0.5,"instrumental":null,"era":null}}"#);
            assert!(gr.accepts(&out), "vocabulary word {w:?} rejected");
        }
        let mut seen = std::collections::HashSet::new();
        assert!(VOCABULARY.iter().all(|w| seen.insert(*w)), "duplicate vocabulary word");
        assert!(VOCABULARY.len() >= 60);
    }

    #[test]
    fn pick_only_allows_ids_that_were_shown() {
        let gr = g(&Shape::Pick { candidates: 12 });
        let ok = r#"{"title":"Rainy Night Code","reason":"Calm instrumentals that suit late hours.","picks":["t3","t12","t1"]}"#;
        assert!(gr.accepts(ok));
        assert!(!gr.accepts(&ok.replace("\"t12\"", "\"t13\"")));
        assert!(!gr.accepts(&ok.replace("\"t12\"", "\"t0\"")));
        assert!(!gr.accepts(&ok.replace("\"t3\",\"t12\",\"t1\"", "")));
        // 25 picks is the most
        let many = |n: usize| (0..n).map(|i| format!("\"t{}\"", i % 12 + 1)).collect::<Vec<_>>().join(",");
        assert!(gr.accepts(&ok.replace("\"t3\",\"t12\",\"t1\"", &many(25))));
        assert!(!gr.accepts(&ok.replace("\"t3\",\"t12\",\"t1\"", &many(26))));
    }

    #[test]
    fn rerank_is_just_a_list_of_shown_ids() {
        let gr = g(&Shape::Rerank { candidates: 4 });
        assert!(gr.accepts(r#"{"picks":["t2","t4","t3","t1"]}"#));
        assert!(!gr.accepts(r#"{"picks":["t5"]}"#));
        assert!(!gr.accepts(r#"{"picks":[2,4]}"#));
        assert!(!gr.accepts(r#"{"picks":[]}"#));
        assert!(!gr.accepts("{\"picks\":[\"t1\"]} thanks"));
    }

    #[test]
    fn pick_and_rerank_ids_map_back_through_the_real_validators() {
        let gr = g(&Shape::Rerank { candidates: 3 });
        let out = r#"{"picks":["t3","t1"]}"#;
        assert!(gr.accepts(out));
        let mut aliases = HashMap::new();
        aliases.insert("t1".to_string(), "id-a".to_string());
        aliases.insert("t2".to_string(), "id-b".to_string());
        aliases.insert("t3".to_string(), "id-c".to_string());
        let pick = validate::parse_pick(out, &aliases);
        assert_eq!(pick.map(|p| p.ids), Some(vec!["id-c".to_string(), "id-a".to_string()]));
    }

    #[test]
    fn any_json_accepts_objects_and_rejects_prose() {
        let gr = g(&Shape::AnyJson);
        assert!(gr.accepts(r#"{"a":1,"b":[true,null,"x"],"c":{"d":-2.5}}"#));
        assert!(gr.accepts("{}"));
        assert!(!gr.accepts("hello"));
        assert!(!gr.accepts(r#"{"a":}"#));
        assert!(!gr.accepts(r#"[1,2]"#));
    }

    #[test]
    fn grammars_use_only_names_and_syntax_llama_cpp_accepts() {
        // llama.cpp rule names are lower-case letters, digits and dashes; one rule per line.
        for shape in [
            Shape::AnyJson,
            Shape::WhyMix { mixes: 8 },
            Shape::Query,
            Shape::Pick { candidates: 50 },
            Shape::Rerank { candidates: 50 },
        ] {
            let text = grammar_for(&shape);
            for line in text.lines().filter(|l| !l.trim().is_empty()) {
                let (name, _) = line.split_once("::=").expect("rule line");
                assert!(name.trim().chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'), "{name}");
            }
            assert!(text.contains("root ::="));
            // parses with our matcher too
            let _ = Grammar::parse(&text);
        }
    }

    #[test]
    fn counts_are_clamped_so_a_bad_request_cannot_build_a_huge_grammar() {
        assert!(grammar_for(&Shape::Pick { candidates: 5000 }).len() < 3000);
        assert!(grammar_for(&Shape::WhyMix { mixes: 500 }).matches("\"m").count() <= 8 * 2);
        // zero candidates still gives a usable grammar
        assert!(g(&Shape::Rerank { candidates: 0 }).accepts(r#"{"picks":["t1"]}"#));
    }

    #[test]
    fn addendum_only_for_the_plan_and_lists_the_vocabulary() {
        let a = addendum(&Shape::Query).expect("addendum");
        assert!(a.contains("ambient") && a.contains("empty list"));
        assert!(addendum(&Shape::Rerank { candidates: 3 }).is_none());
        assert!(addendum(&Shape::AnyJson).is_none());
    }
}
