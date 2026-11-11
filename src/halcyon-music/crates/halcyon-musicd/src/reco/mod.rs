//! Part 5: the recommendation pipeline. Retrieve, rank, rerank.
//!
//! ```text
//!   retrieve   many cheap sources, each may fail alone      (retrieve.rs)
//!      |       merged and de-duplicated into `Candidate`s
//!   rank       11 features -> transparent weighted score,    (features.rs, model.rs)
//!      |       then a tiny online logistic model on top
//!   rerank     MMR diversity, artist caps, no back-to-back,   (rerank.rs, bandit.rs)
//!      |       flow, recently-played filter, ~20% exploration
//!   resolve    only the winners are matched on Spotify        (engine.rs)
//! ```
//!
//! Everything here works without the Spotify Web API. The only Spotify call is the song search
//! that turns the final picks into playable tracks, and it goes through the existing, budgeted
//! `suggestions::resolve_outside_track` (the librespot session in the default sign-in).
//!
//! The pure parts (features, model, rerank, bandit, merging) have no clock, no network and no
//! randomness except a seeded generator, so the same input always gives the same list.

pub mod bandit;
pub mod engine;
pub mod features;
pub mod model;
pub mod rerank;
pub mod retrieve;
pub mod tags;

use crate::cache::PlayLogEntry;
use serde::{Deserialize, Serialize};

/// Below this many plays the list comes from charts and editorial picks only (master plan, Part 5).
pub const COLD_START_PLAYS: usize = 50;

/// Where a candidate came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum Source {
    /// A song from your own play log.
    History,
    /// A song you liked.
    Liked,
    /// Songs of artists Deezer lists as similar to ones you play.
    Similar,
    /// A recent release by an artist you play.
    NewRelease,
    /// A song by an unheard artist whose tags are close to one of your taste clusters.
    TagNeighbour,
    /// ListenBrainz collaborative recommendations. Only with the opt-in on.
    ListenBrainz,
    /// A chart.
    Chart,
    /// A hand-made list of well-known songs.
    Editorial,
}

impl Source {
    pub const ALL: [Source; 8] = [
        Source::History,
        Source::Liked,
        Source::Similar,
        Source::NewRelease,
        Source::TagNeighbour,
        Source::ListenBrainz,
        Source::Chart,
        Source::Editorial,
    ];

    pub fn name(self) -> &'static str {
        match self {
            Source::History => "history",
            Source::Liked => "liked",
            Source::Similar => "similar",
            Source::NewRelease => "new-release",
            Source::TagNeighbour => "tag-neighbour",
            Source::ListenBrainz => "listenbrainz",
            Source::Chart => "chart",
            Source::Editorial => "editorial",
        }
    }

    /// A prior for how much a hit from this source is worth, 0 to 1. The ranker multiplies it by a
    /// learned weight, so only the order between sources matters here.
    pub fn trust(self) -> f64 {
        match self {
            Source::History | Source::Liked => 1.0,
            Source::NewRelease => 0.8,
            Source::Similar => 0.7,
            Source::ListenBrainz => 0.6,
            Source::TagNeighbour => 0.5,
            Source::Editorial => 0.4,
            Source::Chart => 0.3,
        }
    }

    /// Sources that depend on knowing you. Charts and editorial lists do not.
    pub fn is_personal(self) -> bool {
        !matches!(self, Source::Chart | Source::Editorial)
    }
}

/// Which pool of sources is used.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Fewer than [`COLD_START_PLAYS`] plays: charts and editorial lists only.
    ColdStart,
    /// Enough history: everything.
    Personal,
}

pub fn phase_for(plays_seen: usize) -> Phase {
    if plays_seen < COLD_START_PLAYS {
        Phase::ColdStart
    } else {
        Phase::Personal
    }
}

impl Phase {
    pub fn allows(self, source: Source) -> bool {
        match self {
            Phase::ColdStart => !source.is_personal(),
            Phase::Personal => true,
        }
    }
}

/// One song (or one album) that might go on a list.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Candidate {
    pub artist: String,
    /// Song title, or album title when `is_album`. Empty only in the offline evaluation.
    pub title: String,
    /// Set when the song is already a Spotify track (your history, your likes).
    pub track_id: Option<String>,
    pub is_album: bool,
    /// Every source that offered it, best first after `merge`.
    pub sources: Vec<Source>,
    /// Artist tags, strongest first. May be empty.
    pub tags: Vec<(String, f64)>,
    /// 0 to 1 (chart position, for example). `None` = unknown.
    pub popularity: Option<f64>,
    /// Release time, unix seconds, for new releases.
    pub released: Option<u64>,
    pub duration_ms: Option<u64>,
    /// Why it is here, for the one-line reason under a list: "Because you play X".
    pub because: Option<String>,
}

impl Candidate {
    pub fn new(artist: &str, title: &str, source: Source) -> Self {
        Candidate {
            artist: artist.trim().to_string(),
            title: title.trim().to_string(),
            sources: vec![source],
            ..Default::default()
        }
    }

    /// The identity used to drop duplicates: artist and title with case, brackets and punctuation
    /// removed. Without a title (the offline evaluation) the Spotify id.
    pub fn key(&self) -> String {
        if self.title.trim().is_empty() {
            return format!("id:{}", self.track_id.as_deref().unwrap_or(""));
        }
        format!(
            "{}|{}{}",
            crate::suggestions::normalize_string(&self.artist),
            crate::suggestions::normalize_string(&self.title),
            if self.is_album { "|album" } else { "" }
        )
    }

    /// The best trust among its sources.
    pub fn best_trust(&self) -> f64 {
        self.sources.iter().map(|s| s.trust()).fold(0.0, f64::max)
    }

    /// The source that counts for the bandit and the reason line: the most trusted one.
    pub fn primary_source(&self) -> Option<Source> {
        self.sources.iter().copied().max_by(|a, b| {
            a.trust()
                .partial_cmp(&b.trust())
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| b.cmp(a))
        })
    }

    /// A song from the play log or the liked list.
    pub fn from_play(p: &PlayLogEntry, source: Source) -> Self {
        Candidate {
            artist: p.artist.clone(),
            title: p.title.clone(),
            track_id: Some(p.track_id.clone()),
            sources: vec![source],
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cold_start_uses_charts_and_editorial_only_until_fifty_plays() {
        assert_eq!(phase_for(0), Phase::ColdStart);
        assert_eq!(phase_for(COLD_START_PLAYS - 1), Phase::ColdStart);
        assert_eq!(phase_for(COLD_START_PLAYS), Phase::Personal);
        for s in Source::ALL {
            assert_eq!(Phase::ColdStart.allows(s), !s.is_personal(), "{s:?}");
            assert!(Phase::Personal.allows(s));
        }
        assert!(!Source::Chart.is_personal() && !Source::Editorial.is_personal());
        assert!(Source::History.is_personal() && Source::ListenBrainz.is_personal());
    }

    #[test]
    fn trust_puts_your_own_music_first_and_charts_last() {
        let mut order: Vec<Source> = Source::ALL.to_vec();
        order.sort_by(|a, b| {
            b.trust()
                .partial_cmp(&a.trust())
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        assert!(matches!(
            order.first(),
            Some(Source::History) | Some(Source::Liked)
        ));
        assert_eq!(order.last(), Some(&Source::Chart));
    }

    #[test]
    fn key_ignores_case_and_brackets_and_falls_back_to_the_id() {
        let a = Candidate::new("Daft Punk", "Get Lucky (Radio Edit)", Source::Chart);
        let b = Candidate::new("daft punk", "get lucky", Source::Similar);
        assert_eq!(a.key(), b.key());
        let album = Candidate {
            is_album: true,
            ..Candidate::new("Daft Punk", "Get Lucky", Source::NewRelease)
        };
        assert_ne!(
            a.key(),
            album.key(),
            "an album is not the song of the same name"
        );
        let bare = Candidate {
            track_id: Some("abc".into()),
            ..Default::default()
        };
        assert_eq!(bare.key(), "id:abc");
    }

    #[test]
    fn primary_source_is_the_most_trusted_one() {
        let mut c = Candidate::new("A", "T", Source::Chart);
        c.sources.push(Source::Similar);
        assert_eq!(c.primary_source(), Some(Source::Similar));
        assert!((c.best_trust() - 0.7).abs() < 1e-9);
        assert_eq!(Candidate::default().primary_source(), None);
    }
}
