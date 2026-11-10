//! Part 6: what the mixes are right now, and what you said about songs and artists.
//!
//! One JSON file (`mixes-state.json` in the state dir). Written atomically (a temp file, then a
//! rename); an unreadable file is moved aside to `.corrupt` and replaced by an empty store, so a
//! damaged file can never keep the app from starting. Lists and the blocklist are bounded.

use super::{cover_hue, cover_urls, MixKind};
use crate::suggestions::normalize_string;
use crate::taste::artist_key;
use halcyon_music_core::models::{MixMeta, MusicMix};
use halcyon_music_core::state::Track;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const STORE_VERSION: u32 = 1;
pub const MAX_BLOCKED_TRACKS: usize = 2_000;
pub const MAX_BLOCKED_ARTISTS: usize = 500;
pub const MAX_LESS_ENTRIES: usize = 1_000;
/// After this many "less like this" an artist is left out of every mix.
pub const BLOCK_AT: u32 = 3;

pub fn default_path() -> PathBuf {
    halcyon_music_core::paths::state_dir().join("mixes-state.json")
}

/// The identity of a song by name, so the same song on another Spotify id stays blocked.
pub fn name_key(artist: &str, title: &str) -> String {
    format!("{}|{}", normalize_string(artist), normalize_string(title))
}

/// One built mix as it is kept between runs.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct StoredMix {
    pub id: String,
    /// [`MixKind::name`].
    pub kind: String,
    pub title: String,
    pub reason: String,
    /// The [`super::period_key`] it was built for.
    pub period: String,
    pub built_at: u64,
    pub next_refresh_at: u64,
    /// Bumped by the Refresh button, so a refresh gives a different list the same day.
    pub epoch: u64,
    /// The taste cluster a Daily Mix is about.
    pub cluster_id: Option<u32>,
    /// The cluster's tags, or the Daylist's mood word.
    pub label: String,
    pub tracks: Vec<Track>,
    /// One line per song, same order as `tracks`.
    pub reasons: Vec<String>,
    pub explore: Vec<bool>,
}

impl StoredMix {
    pub fn to_music_mix(&self) -> MusicMix {
        MusicMix {
            id: self.id.clone(),
            title: self.title.clone(),
            description: self.reason.clone(),
            source: "Halcyon Local".to_string(),
            tracks: self.tracks.clone(),
            art_url: self.tracks.iter().find_map(|t| t.art_url.clone()),
        }
    }

    pub fn to_meta(&self) -> MixMeta {
        MixMeta {
            mix_id: self.id.clone(),
            kind: self.kind.clone(),
            reason: self.reason.clone(),
            reasons: self.reasons.clone(),
            explore: self.explore.clone(),
            built_at: self.built_at,
            next_refresh_at: self.next_refresh_at,
            cover_urls: cover_urls(&self.tracks),
            cover_hue: cover_hue(&self.id),
        }
    }
}

/// What the listener said. Applied to every build, so it holds across refreshes and restarts.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Feedback {
    /// Spotify ids of songs that never come back, oldest first.
    pub blocked_tracks: Vec<String>,
    /// The same songs by [`name_key`], for the copy of the song on another id.
    pub blocked_names: Vec<String>,
    /// Artist keys left out of every mix.
    pub blocked_artists: Vec<String>,
    /// Artist key to how many times "less like this" was said.
    pub less: BTreeMap<String, u32>,
}

impl Feedback {
    pub fn block_track(&mut self, id: &str, artist: &str, title: &str) {
        if !id.is_empty() && !self.blocked_tracks.iter().any(|x| x == id) {
            self.blocked_tracks.push(id.to_string());
        }
        let name = name_key(artist, title);
        if name != "|" && !self.blocked_names.contains(&name) {
            self.blocked_names.push(name);
        }
        self.trim();
    }

    pub fn block_artist(&mut self, artist: &str) {
        let key = artist_key(artist);
        if !key.is_empty() && !self.blocked_artists.contains(&key) {
            self.blocked_artists.push(key);
        }
        self.trim();
    }

    /// "Less like this": one more for the artist. At [`BLOCK_AT`] the artist is blocked.
    pub fn less_like(&mut self, artist: &str) -> u32 {
        let key = artist_key(artist);
        if key.is_empty() {
            return 0;
        }
        let n = {
            let e = self.less.entry(key.clone()).or_insert(0);
            *e = e.saturating_add(1);
            *e
        };
        if n >= BLOCK_AT && !self.blocked_artists.contains(&key) {
            self.blocked_artists.push(key);
        }
        self.trim();
        n
    }

    pub fn is_artist_blocked(&self, artist: &str) -> bool {
        let key = artist_key(artist);
        self.blocked_artists.contains(&key)
    }

    pub fn is_track_blocked(&self, id: Option<&str>, artist: &str, title: &str) -> bool {
        if let Some(id) = id {
            if self.blocked_tracks.iter().any(|x| x == id) {
                return true;
            }
        }
        if title.trim().is_empty() {
            return false;
        }
        let name = name_key(artist, title);
        self.blocked_names.contains(&name)
    }

    /// How many songs of this artist one list may hold, given the usual cap.
    pub fn artist_cap(&self, artist: &str, usual: usize) -> usize {
        if self.is_artist_blocked(artist) {
            return 0;
        }
        match self.less.get(&artist_key(artist)) {
            Some(n) if *n >= 1 => usual.min(1),
            _ => usual,
        }
    }

    fn trim(&mut self) {
        let cut = |v: &mut Vec<String>, max: usize| {
            if v.len() > max {
                let extra = v.len() - max;
                v.drain(..extra);
            }
        };
        cut(&mut self.blocked_tracks, MAX_BLOCKED_TRACKS);
        cut(&mut self.blocked_names, MAX_BLOCKED_TRACKS);
        cut(&mut self.blocked_artists, MAX_BLOCKED_ARTISTS);
        while self.less.len() > MAX_LESS_ENTRIES {
            // Drop the entries said least often; ties by key, so the result is deterministic.
            let drop = self.less.iter().min_by(|a, b| a.1.cmp(b.1).then_with(|| a.0.cmp(b.0))).map(|(k, _)| k.clone());
            match drop {
                Some(k) => {
                    self.less.remove(&k);
                }
                None => break,
            }
        }
    }

    pub fn is_empty(&self) -> bool {
        self.blocked_tracks.is_empty() && self.blocked_names.is_empty() && self.blocked_artists.is_empty() && self.less.is_empty()
    }
}

fn retain_keep<T>(v: &mut Vec<T>, keep: &[bool]) {
    let mut i = 0;
    v.retain(|_| {
        let k = keep.get(i).copied().unwrap_or(true);
        i += 1;
        k
    });
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MixStore {
    pub version: u32,
    pub mixes: BTreeMap<String, StoredMix>,
    /// Daily Mix slot (1 to 6) to the taste cluster id it follows, so a Daily Mix keeps its
    /// number when the clusters are recomputed.
    pub slots: BTreeMap<u32, u32>,
    pub feedback: Feedback,
}

impl Default for MixStore {
    fn default() -> Self {
        MixStore { version: STORE_VERSION, mixes: BTreeMap::new(), slots: BTreeMap::new(), feedback: Feedback::default() }
    }
}

impl MixStore {
    /// The saved store. A missing file is an empty store; one that cannot be read or has another
    /// version is moved aside (`.corrupt`) and replaced. The flag says that happened.
    pub fn load_or_default(path: &Path) -> (Self, bool) {
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(_) => return (MixStore::default(), false),
        };
        match serde_json::from_slice::<MixStore>(&bytes) {
            Ok(s) if s.version == STORE_VERSION => (s, false),
            _ => {
                let _ = std::fs::rename(path, path.with_extension("json.corrupt"));
                (MixStore::default(), true)
            }
        }
    }

    /// Atomic: a temp file, then a rename.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
        }
        let json = serde_json::to_vec(self).map_err(|e| e.to_string())?;
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, &json).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, path).map_err(|e| e.to_string())
    }

    pub fn get(&self, id: &str) -> Option<&StoredMix> {
        self.mixes.get(id)
    }

    pub fn put(&mut self, mix: StoredMix) {
        self.mixes.insert(mix.id.clone(), mix);
    }

    /// Take a song out of a mix at once (it was rejected). True when something was removed.
    pub fn remove_track(&mut self, mix_id: &str, track_id: &str) -> bool {
        let Some(m) = self.mixes.get_mut(mix_id) else { return false };
        let Some(pos) = m.tracks.iter().position(|t| t.id == track_id) else { return false };
        m.tracks.remove(pos);
        if pos < m.reasons.len() {
            m.reasons.remove(pos);
        }
        if pos < m.explore.len() {
            m.explore.remove(pos);
        }
        true
    }

    /// Take every blocked song and every blocked artist out of every stored mix, so a "Not my
    /// taste" shows on Home before the next rebuild. True when something changed.
    pub fn purge_blocked(&mut self) -> bool {
        let fb = self.feedback.clone();
        let mut changed = false;
        for m in self.mixes.values_mut() {
            let keep: Vec<bool> = m
                .tracks
                .iter()
                .map(|t| !fb.is_track_blocked(Some(&t.id), &t.artist, &t.title) && !fb.is_artist_blocked(&t.artist))
                .collect();
            if keep.iter().all(|k| *k) {
                continue;
            }
            changed = true;
            retain_keep(&mut m.tracks, &keep);
            if m.reasons.len() == keep.len() {
                retain_keep(&mut m.reasons, &keep);
            }
            if m.explore.len() == keep.len() {
                retain_keep(&mut m.explore, &keep);
            }
        }
        changed
    }

    /// Give each cluster a Daily Mix slot. A cluster that already had one keeps it; the others
    /// take the free slots in the order given (biggest share first). Slots whose cluster is gone
    /// are released. Returns `(slot, cluster id)` by slot.
    pub fn assign_slots(&mut self, cluster_ids: &[u32], max: usize) -> Vec<(usize, u32)> {
        let wanted: Vec<u32> = cluster_ids.iter().copied().take(max).collect();
        self.slots.retain(|slot, cid| (1..=max as u32).contains(slot) && wanted.contains(cid));
        for cid in &wanted {
            if self.slots.values().any(|v| v == cid) {
                continue;
            }
            if let Some(free) = (1..=max as u32).find(|s| !self.slots.contains_key(s)) {
                self.slots.insert(free, *cid);
            }
        }
        self.slots.iter().map(|(s, c)| (*s as usize, *c)).collect()
    }

    /// Mixes in the order Home shows them, as the wire types.
    pub fn to_wire(&self) -> (Vec<MusicMix>, Vec<MixMeta>) {
        let mut all: Vec<&StoredMix> = self.mixes.values().filter(|m| !m.tracks.is_empty()).collect();
        all.sort_by(|a, b| {
            let ra = MixKind::from_name(&a.kind).map_or(99, |k| k.display_rank());
            let rb = MixKind::from_name(&b.kind).map_or(99, |k| k.display_rank());
            ra.cmp(&rb).then_with(|| a.id.cmp(&b.id))
        });
        (all.iter().map(|m| m.to_music_mix()).collect(), all.iter().map(|m| m.to_meta()).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(id: &str, artist: &str, title: &str) -> Track {
        Track::simple(id.into(), title.into(), artist.into(), "Album".into(), 1000)
    }

    fn mix(id: &str, kind: &str, tracks: Vec<Track>) -> StoredMix {
        let n = tracks.len();
        StoredMix {
            id: id.into(),
            kind: kind.into(),
            title: id.into(),
            reason: "why".into(),
            reasons: (0..n).map(|i| format!("r{i}")).collect(),
            explore: vec![false; n],
            tracks,
            ..Default::default()
        }
    }

    #[test]
    fn blocking_a_song_covers_the_same_song_on_another_id() {
        let mut f = Feedback::default();
        f.block_track("sp1", "Daft Punk", "Get Lucky");
        assert!(f.is_track_blocked(Some("sp1"), "x", "y"));
        assert!(f.is_track_blocked(Some("sp2"), "daft punk", "Get Lucky (Radio Edit)"), "same name, other id");
        assert!(!f.is_track_blocked(Some("sp3"), "Daft Punk", "Around the World"));
        assert!(!f.is_track_blocked(None, "Daft Punk", ""));
    }

    #[test]
    fn less_like_this_caps_then_blocks_the_artist() {
        let mut f = Feedback::default();
        assert_eq!(f.artist_cap("Muse", 2), 2);
        f.less_like("Muse");
        assert_eq!(f.artist_cap("  MUSE ", 2), 1, "one song per list after the first less");
        assert_eq!(f.artist_cap("Muse", 3), 1);
        f.less_like("Muse");
        assert!(!f.is_artist_blocked("Muse"));
        f.less_like("Muse");
        assert!(f.is_artist_blocked("muse"), "three times: gone");
        assert_eq!(f.artist_cap("Muse", 2), 0);
        assert_eq!(f.artist_cap("Other", 2), 2);
    }

    #[test]
    fn the_blocklist_stays_bounded_and_keeps_the_newest() {
        let mut f = Feedback::default();
        for i in 0..(MAX_BLOCKED_TRACKS + 50) {
            f.block_track(&format!("id{i}"), "A", &format!("t{i}"));
        }
        assert_eq!(f.blocked_tracks.len(), MAX_BLOCKED_TRACKS);
        assert!(f.is_track_blocked(Some(&format!("id{}", MAX_BLOCKED_TRACKS + 49)), "x", ""));
        assert!(!f.is_track_blocked(Some("id0"), "x", ""), "the oldest fell out");
    }

    #[test]
    fn save_and_load_round_trip_and_a_bad_file_is_moved_aside() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("mixes-state.json");
        let mut s = MixStore::default();
        s.put(mix("on-repeat", "on_repeat", vec![t("a", "A", "One")]));
        s.feedback.less_like("A");
        s.save(&path).expect("save");
        let (back, bad) = MixStore::load_or_default(&path);
        assert!(!bad);
        assert_eq!(back, s);

        std::fs::write(&path, b"{not json").expect("write");
        let (empty, bad) = MixStore::load_or_default(&path);
        assert!(bad);
        assert!(empty.mixes.is_empty());
        assert!(path.with_extension("json.corrupt").exists());
        assert!(!path.exists());

        let (missing, bad) = MixStore::load_or_default(&dir.path().join("none.json"));
        assert!(!bad && missing.mixes.is_empty());
    }

    #[test]
    fn a_store_from_a_newer_version_is_not_trusted() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("m.json");
        std::fs::write(&path, br#"{"version":99,"mixes":{}}"#).expect("write");
        let (s, bad) = MixStore::load_or_default(&path);
        assert!(bad);
        assert_eq!(s.version, STORE_VERSION);
    }

    #[test]
    fn removing_a_track_keeps_reasons_and_flags_in_step() {
        let mut s = MixStore::default();
        s.put(mix("m", "daylist", vec![t("a", "A", "1"), t("b", "B", "2"), t("c", "C", "3")]));
        assert!(s.remove_track("m", "b"));
        let m = s.get("m").expect("mix");
        assert_eq!(m.tracks.len(), 2);
        assert_eq!(m.reasons, vec!["r0", "r2"]);
        assert_eq!(m.explore.len(), 2);
        assert!(!s.remove_track("m", "zzz"));
        assert!(!s.remove_track("nope", "a"));
    }

    #[test]
    fn purge_removes_blocked_songs_and_artists_everywhere() {
        let mut s = MixStore::default();
        s.put(mix("m1", "daily_mix", vec![t("a", "A", "1"), t("b", "B", "2"), t("c", "A", "3")]));
        s.put(mix("m2", "on_repeat", vec![t("d", "D", "4"), t("a", "A", "1")]));
        s.feedback.block_artist("B");
        s.feedback.block_track("a", "A", "1");
        assert!(s.purge_blocked());
        assert_eq!(s.get("m1").expect("m1").tracks.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), vec!["c"]);
        assert_eq!(s.get("m1").expect("m1").reasons, vec!["r2"]);
        assert_eq!(s.get("m2").expect("m2").tracks.len(), 1);
        assert!(!s.purge_blocked(), "nothing left to remove");
    }

    #[test]
    fn slots_are_kept_when_clusters_are_recomputed() {
        let mut s = MixStore::default();
        assert_eq!(s.assign_slots(&[10, 20, 30], 6), vec![(1, 10), (2, 20), (3, 30)]);
        // Cluster 10 disappears and a new one (40) appears; 20 and 30 keep their numbers.
        assert_eq!(s.assign_slots(&[20, 40, 30], 6), vec![(1, 40), (2, 20), (3, 30)]);
        // Never more than the maximum.
        let many: Vec<u32> = (100..110).collect();
        let mut s2 = MixStore::default();
        assert_eq!(s2.assign_slots(&many, 6).len(), 6);
    }

    #[test]
    fn wire_order_follows_the_home_shelves_and_skips_empty_mixes() {
        let mut s = MixStore::default();
        s.put(mix("daylist", "daylist", vec![t("a", "A", "1")]));
        s.put(mix("daily-mix-2", "daily_mix", vec![t("b", "B", "2")]));
        s.put(mix("daily-mix-1", "daily_mix", vec![t("c", "C", "3")]));
        s.put(mix("release-radar", "release_radar", vec![t("d", "D", "4")]));
        s.put(mix("empty", "on_repeat", vec![]));
        let (mixes, meta) = s.to_wire();
        let ids: Vec<&str> = mixes.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, vec!["daily-mix-1", "daily-mix-2", "release-radar", "daylist"]);
        assert_eq!(meta.iter().map(|m| m.mix_id.as_str()).collect::<Vec<_>>(), ids);
        assert!(mixes.iter().all(|m| m.source == "Halcyon Local"));
        assert_eq!(meta.first().map(|m| m.reasons.len()), Some(1));
    }
}
