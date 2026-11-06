//! Endpoint probe table for Spotify Web API.
//!
//! Spotify closed several endpoints to new apps (Nov 2024) and tightened
//! Development Mode in Feb 2026. This module probes each optional endpoint once,
//! remembers the result for 24 hours in SQLite, and exposes the status to
//! `--doctor` and Part 5's suggestion engine.

use crate::api::{EndpointFamily, SpotifyClient};
use crate::cache::Cache;
use crate::token_store::now_secs;
use halcyon_music_core::models::{EndpointProbe, ProbeStatus};

pub const PROBE_TTL_SECS: u64 = 24 * 3600; // 24 hours

pub struct ProbeTarget {
    pub name: &'static str,
    pub endpoint: &'static str,
    pub family: EndpointFamily,
    pub description: &'static str,
}

pub const PROBE_TARGETS: &[ProbeTarget] = &[
    ProbeTarget {
        name: "recommendations",
        endpoint: "/recommendations?seed_genres=pop&limit=1",
        family: EndpointFamily::Recommendations,
        description: "Algorithmic song recommendations based on seeds",
    },
    ProbeTarget {
        name: "related_artists",
        endpoint: "/artists/06HL4z0CvFAxyc27GXpf02/related-artists", // Taylor Swift (canonical ID)
        family: EndpointFamily::Artists,
        description: "Similar / related artists graph",
    },
    ProbeTarget {
        name: "featured_playlists",
        endpoint: "/browse/featured-playlists?limit=1",
        family: EndpointFamily::Browse,
        description: "Spotify curated featured playlists",
    },
    ProbeTarget {
        name: "categories",
        endpoint: "/browse/categories?limit=1",
        family: EndpointFamily::Browse,
        description: "Browse genre/mood categories",
    },
    ProbeTarget {
        name: "new_releases",
        endpoint: "/browse/new-releases?limit=1",
        family: EndpointFamily::Browse,
        description: "Browse fresh album and single releases",
    },
];

/// Run all endpoint probes, reusing results from SQLite cache if fresher than 24h.
pub async fn evaluate_probes(client: &SpotifyClient, cache: &Cache) -> Vec<EndpointProbe> {
    let now = now_secs();
    let existing_probes = cache.get_probes().unwrap_or_default();
    let probe_map: std::collections::HashMap<String, EndpointProbe> = existing_probes
        .into_iter()
        .map(|p| (p.endpoint.clone(), p))
        .collect();

    let mut results = Vec::new();

    for target in PROBE_TARGETS {
        let name = target.name.to_string();

        // Check if cached probe is fresh (< 24h)
        if let Some(cached) = probe_map.get(&name) {
            if now < cached.checked_at.saturating_add(PROBE_TTL_SECS) {
                results.push(cached.clone());
                continue;
            }
        }

        // Run fresh probe
        let probe = match client.probe(target.endpoint, target.family).await {
            Ok(code) => {
                let status = match code {
                    200 => ProbeStatus::Available,
                    403 | 404 | 410 => ProbeStatus::Unavailable { code },
                    _ => ProbeStatus::Unknown,
                };
                let detail = match status {
                    ProbeStatus::Available => Some("Endpoint open and working".to_string()),
                    ProbeStatus::Unavailable { code } => Some(format!(
                        "Restricted by Spotify (HTTP {code}); tier fallback will be used"
                    )),
                    ProbeStatus::Unknown => Some(format!("Unexpected HTTP response {code}")),
                };
                EndpointProbe {
                    endpoint: name.clone(),
                    status,
                    checked_at: now,
                    detail,
                }
            }
            Err(e) => EndpointProbe {
                endpoint: name.clone(),
                status: ProbeStatus::Unknown,
                checked_at: now,
                detail: Some(format!("Probe failed: {e}")),
            },
        };

        let _ = cache.put_probe(&probe);
        results.push(probe);
    }

    results
}
