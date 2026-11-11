//! halcyon-music-core: shared types and the daemon/GUI protocol.
//!
//! Both binaries (`halcyon-musicd` and `halcyon-music`) depend only on this
//! crate for everything that crosses the process boundary.

pub mod art;
pub mod error;
pub mod models;
pub mod paths;
pub mod protocol;
pub mod state;
pub mod tokens;

pub use art::ArtSize;
pub use error::CoreError;
pub use models::{
    Album, Artist, AuthMode, AuthStatus, Device, EndpointProbe, Page, Playlist, ProbeStatus, Track,
};
pub use protocol::{Command, Envelope, Event, Message, PROTOCOL_VERSION};
pub use state::{PlayerState, RepeatMode};

/// Crate version, also surfaced through the protocol so a GUI can warn when
/// the daemon it connected to speaks a different generation of the protocol.
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
