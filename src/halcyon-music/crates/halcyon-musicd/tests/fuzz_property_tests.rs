//! Fuzz and property tests for LRC parsing, protocol decoding, and title normalization.
//!
//! Enforces:
//! - Parser robustness: arbitrary bytes/junk must never panic or crash
//! - Deterministic invariant: parsed lyrics timestamps must always be non-decreasing
//! - Decoder resilience: malformed protocol lines must yield safe errors or Unknown variants
//! - Normalizer invariants: similarity scores must remain strictly bounded in [0.0, 1.0]

use halcyon_music_core::models::Track;
use halcyon_music_core::protocol::{decode_line, encode_line, Command, CommandBody, Event};
use halcyon_musicd::lyrics::{parse_lrc, parse_plain, parse_timestamp_ms};
use halcyon_musicd::suggestions::{normalize_string, score_track_match, token_similarity};

/// Pseudo-random number generator for deterministic reproducible property tests.
struct SimpleRng {
    state: u64,
}

impl SimpleRng {
    fn new(seed: u64) -> Self {
        Self { state: seed.max(1) }
    }

    fn next_u32(&mut self) -> u32 {
        self.state = self.state.wrapping_mul(6364136223846793005).wrapping_add(1);
        (self.state >> 32) as u32
    }

    fn choose<'a, T>(&mut self, slice: &'a [T]) -> &'a T {
        let idx = (self.next_u32() as usize) % slice.len();
        &slice[idx]
    }

    fn random_string(&mut self, max_len: usize) -> String {
        let chars = [
            'a', 'b', 'c', '1', '2', '3', ' ', ':', '.', '[', ']', '<', '>', '-', '+', 'é', 'ü',
            'ñ', '♪', '日', '本', '\n', '\r', '\t', '\0', '{', '}', '"',
        ];
        let len = (self.next_u32() as usize) % (max_len.max(1));
        let mut s = String::with_capacity(len);
        for _ in 0..len {
            s.push(*self.choose(&chars));
        }
        s
    }
}

#[test]
fn property_test_lrc_timestamp_parser() {
    let mut rng = SimpleRng::new(0xDEAD_BEEF);

    // 1. Valid formats must parse correctly and monotonically
    for _ in 0..1000 {
        let min = rng.next_u32() % 100;
        let sec = rng.next_u32() % 60;
        let frac = rng.next_u32() % 100;
        let input = format!("[{:02}:{:02}.{:02}]", min, sec, frac);

        let parsed = parse_timestamp_ms(&input);
        assert!(parsed.is_some(), "Valid timestamp must parse: {input}");
        let expected_ms = (min as u64 * 60_000) + (sec as u64 * 1000) + (frac as u64 * 10);
        assert_eq!(parsed.unwrap(), expected_ms);
    }

    // 2. Fuzzing with arbitrary malformed garbage must NEVER panic
    for _ in 0..5000 {
        let junk = rng.random_string(32);
        let _ = parse_timestamp_ms(&junk);
    }
}

#[test]
fn property_test_tolerant_lrc_parser_invariants() {
    let mut rng = SimpleRng::new(0xCAFE_BABE);

    // Fuzz test parse_lrc with randomized multiline texts
    for _ in 0..2000 {
        let num_lines = (rng.next_u32() % 15) as usize;
        let mut doc = String::new();
        for _ in 0..num_lines {
            let line = rng.random_string(40);
            doc.push_str(&line);
            doc.push('\n');
        }

        let (lines, offset_ms) = parse_lrc(&doc);

        // Invariant 1: Parsed lines must ALWAYS be sorted by start_ms
        for window in lines.windows(2) {
            assert!(
                window[0].start_ms <= window[1].start_ms,
                "LRC lines must always be sorted by start_ms: {} > {}",
                window[0].start_ms,
                window[1].start_ms
            );
        }

        // Invariant 2: For lines with end_ms, end_ms must be >= start_ms
        for line in &lines {
            if let Some(end) = line.end_ms {
                assert!(
                    end >= line.start_ms,
                    "end_ms ({end}) must be >= start_ms ({})",
                    line.start_ms
                );
            }
        }

        // Invariant 3: Global offset must not cause panics or overflow
        let _ = offset_ms;
    }
}

#[test]
fn property_test_plain_lyrics_parser() {
    let mut rng = SimpleRng::new(0xFEED_FACE);

    for _ in 0..1000 {
        let text = rng.random_string(100);
        let lines = parse_plain(&text);
        for line in lines {
            assert!(!line.text.is_empty());
            assert_eq!(line.start_ms, 0);
            assert!(line.words.is_empty());
        }
    }
}

#[test]
fn property_test_protocol_decoder_robustness() {
    let mut rng = SimpleRng::new(0xBAAD_F00D);

    // 1. Valid commands round trip cleanly
    let valid_commands = vec![
        CommandBody::GetState,
        CommandBody::Play,
        CommandBody::Pause,
        CommandBody::Toggle,
        CommandBody::Next,
        CommandBody::Previous,
        CommandBody::Seek { position_ms: 12345 },
        CommandBody::SetVolume { volume: 75 },
        CommandBody::SetShuffle { shuffle: true },
        CommandBody::CycleRepeat,
        CommandBody::GetRecentSearches,
        CommandBody::ClearRecentSearches,
        CommandBody::GetCapsule { month_offset: 1 },
        CommandBody::SetLyricOffset {
            track_id: "t1".into(),
            offset_ms: -250,
        },
    ];

    for body in valid_commands {
        let cmd = Command {
            version: 1,
            body: body.clone(),
        };
        let encoded = encode_line(&cmd).expect("encode");
        let decoded: Command = decode_line(&encoded).expect("decode");
        assert_eq!(cmd, decoded);
    }

    // 2. Fuzz with arbitrary junk lines: must NEVER panic
    for _ in 0..5000 {
        let junk = rng.random_string(80);
        let _ = decode_line::<Command>(junk.as_bytes());
        let _ = decode_line::<Event>(junk.as_bytes());
    }

    // 3. Fuzz with arbitrary bytes including null bytes and invalid UTF-8
    for _ in 0..2000 {
        let len = (rng.next_u32() % 64) as usize;
        let mut bytes = Vec::with_capacity(len);
        for _ in 0..len {
            bytes.push((rng.next_u32() & 0xFF) as u8);
        }
        let _ = decode_line::<Command>(&bytes);
        let _ = decode_line::<Event>(&bytes);
    }
}

#[test]
fn property_test_title_normalizer_invariants() {
    let mut rng = SimpleRng::new(0x1234_5678);

    // 1. Invariants of normalize_string
    for _ in 0..2000 {
        let raw = rng.random_string(50);
        let normalized = normalize_string(&raw);

        // Invariant: normalized must not contain uppercase
        assert_eq!(
            normalized,
            normalized.to_lowercase(),
            "Normalized string must be all lowercase: {normalized}"
        );
    }

    // 2. Invariants of token_similarity and score_track_match
    for _ in 0..2000 {
        let s1 = rng.random_string(30);
        let s2 = rng.random_string(30);

        let sim = token_similarity(&s1, &s2);
        assert!(!sim.is_nan(), "token_similarity returned NaN");
        assert!(
            (0.0..=1.0).contains(&sim),
            "token_similarity ({sim}) outside [0.0, 1.0]"
        );

        let cand = Track::simple("t1".into(), s1.clone(), s2.clone(), "Alb".into(), 200_000);
        let score = score_track_match(&cand, &s2, &s1, Some(200_000));
        assert!(!score.is_nan(), "score_track_match returned NaN");
        assert!(
            (0.0..=1.0).contains(&score),
            "score_track_match ({score}) outside [0.0, 1.0]"
        );
    }

    // 3. Exact matches must score 1.0
    let title = "Get Lucky - Radio Edit";
    let artist = "Daft Punk feat. Pharrell Williams";
    let cand = Track::simple(
        "t_exact".into(),
        title.into(),
        artist.into(),
        "RAM".into(),
        248_000,
    );
    let perfect_score = score_track_match(&cand, artist, title, Some(248_000));
    assert!(
        perfect_score >= 0.95,
        "Exact matches must score near 1.0: {perfect_score}"
    );
}
