//! Health Access MCP core: the shared library behind the `healthaccess` CLI and the
//! `healthaccess-mcp` server.
//!
//! The folder chosen by the user (`HEALTHACCESS_DIR`) *is* the API. The iOS app writes
//! `workouts/`, `vitals/`, `index.json` and `plans/*.status.json`; this crate reads
//! all of it, derives training views for an LLM, writes `plans/<id>.json`, and may
//! update exactly two fields (`effort`, `feel`) of a workout file. The binding data
//! contract lives in `docs/schema.md`.
//!
//! Modules:
//! - [`model`]: serde models for workouts (v0 and v1), vitals, the index and plans.
//! - [`store`]: [`Store`], the folder reader/writer (dedupe, rating, plan writing).
//! - [`derive`]: zone seconds, pace, cardiac cost, weekly volume, LLM summaries.
//! - [`briefing`]: `briefing.md`, read from the folder or generated from it.
//! - [`coverage`]: `days/`, `catalog.json`, `profile.json`, `ecg/` and the coverage check.
//! - [`hk_types`]: every HealthKit type identifier of the SDK, for that check.
//! - [`handshake`]: `mcp/clients/<id>.json`, the file that lets the app show "Connected".
//! - [`prompts`]: the six prompts of `docs/prompts.md`, parsed at build time.
//! - [`codec`]: the Apple `.workout` protobuf codec (byte-identical round trip).
//! - [`config`]: `HEALTHACCESS_DIR` / `~/.config/healthaccess/config.toml` resolution
//!   (the pre-rename `TIDE_DIR` / `~/.config/tide/config.toml` stay valid as aliases).

pub mod briefing;
pub mod codec;
pub mod config;
pub mod coverage;
pub mod derive;
pub mod discover;
pub mod error;
pub mod handshake;
pub mod hk_types;
pub mod model;
pub mod prompts;
pub mod store;
pub mod util;

pub use briefing::{Briefing, BriefingSource};
pub use coverage::{Catalog, CatalogType, Coverage, EcgSummary, Profile};
pub use error::{Error, Result};
pub use handshake::{ClientHandshake, ClientInfo};
pub use model::day::Day;
pub use model::index::{Index, IndexEntry};
pub use model::plan::{Plan, PlanStatus};
pub use model::vitals::Vitals;
pub use model::workout::{EffortSource, Workout};
pub use prompts::PromptDef;
pub use store::Store;

/// The bounds the Phase 0 exporter used for the `zone_seconds` it wrote into v0 files
/// (`z1 < 133 <= z2 < 146 <= z3 < 159 <= z4 < 171 <= z5`). Not a default: the reading
/// side takes bounds from config.toml or estimates them from the athlete's age, and
/// otherwise uses whatever zones a workout file carries.
pub const V0_EXPORTER_ZONE_BOUNDS: [u32; 4] = [133, 146, 159, 171];

/// Crate version, surfaced by the CLI (`healthaccess doctor`) and the MCP server (`mcp_started`).
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
