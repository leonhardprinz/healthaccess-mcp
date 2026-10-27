//! `index.json` — compact listing rewritten by the app after every export. The
//! store falls back to scanning `workouts/` when it is absent.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::workout::Workout;

/// Schema tag of the index.
pub const SCHEMA_INDEX: &str = "healthaccess.index.v1";
/// Pre-rename tag of the index, accepted forever as an alias of [`SCHEMA_INDEX`].
pub const SCHEMA_INDEX_LEGACY: &str = "tide.index.v1";

/// The whole index.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Index {
    pub schema: String,
    #[serde(default)]
    pub updated: Option<DateTime<Utc>>,
    #[serde(default)]
    pub workouts: Vec<IndexEntry>,
}

/// One row of the index. `source` is an extension written only by the scan
/// fallback; the app's index may omit it (dedupe then falls back to `activity`).
/// `effort_source` is optional for the same reason.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct IndexEntry {
    pub id: String,
    /// File name inside `workouts/` (a path with `/` is taken relative to the folder).
    pub file: String,
    pub activity: String,
    pub start: DateTime<Utc>,
    pub duration_s: f64,
    #[serde(default)]
    pub distance_m: Option<f64>,
    #[serde(default)]
    pub avg_hr: Option<f64>,
    #[serde(default, deserialize_with = "crate::util::opt_score")]
    pub effort: Option<u8>,
    /// `apple | app | ai`; the app's rows may omit it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort_source: Option<String>,
    #[serde(default)]
    pub plan_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

impl IndexEntry {
    /// Build a row from a parsed workout and its file name.
    pub fn from_workout(w: &Workout, file: &str) -> Self {
        IndexEntry {
            id: w.id.clone(),
            file: file.to_string(),
            activity: w.activity.clone(),
            start: w.start,
            duration_s: w.duration_s,
            distance_m: w.distance_m,
            avg_hr: w.avg_hr,
            effort: w.effort,
            effort_source: w.effort_source.clone(),
            plan_name: w.plan_ref.as_ref().and_then(|p| p.name.clone()),
            source: Some(w.source.clone()),
        }
    }

    /// First 8 characters of the id.
    pub fn short_id(&self) -> String {
        self.id.chars().take(8).collect()
    }
}

impl Index {
    /// An empty index stamped now.
    pub fn empty() -> Self {
        Index {
            schema: SCHEMA_INDEX.to_string(),
            updated: Some(Utc::now()),
            workouts: Vec::new(),
        }
    }

    /// Newest first.
    pub fn sort_newest_first(&mut self) {
        self.workouts
            .sort_by(|a, b| b.start.cmp(&a.start).then_with(|| a.id.cmp(&b.id)));
    }

    /// Apply the contract's dedupe rule: same `start` (±2 s) and same `source`
    /// (falling back to same `activity` when a side lacks `source`) → one workout,
    /// keep the longer. Returns the ids that were dropped.
    pub fn dedupe(&mut self) -> Vec<String> {
        let mut entries = std::mem::take(&mut self.workouts);
        entries.sort_by_key(|e| e.start);
        let mut kept: Vec<IndexEntry> = Vec::with_capacity(entries.len());
        let mut dropped = Vec::new();
        for e in entries {
            let same = |k: &IndexEntry| {
                (k.start - e.start).num_seconds().abs() <= 2
                    && match (&k.source, &e.source) {
                        (Some(a), Some(b)) => a == b,
                        _ => k.activity == e.activity,
                    }
            };
            match kept.iter().position(same) {
                Some(pos) => {
                    if e.duration_s > kept[pos].duration_s {
                        dropped.push(std::mem::replace(&mut kept[pos], e).id);
                    } else {
                        dropped.push(e.id);
                    }
                }
                None => kept.push(e),
            }
        }
        self.workouts = kept;
        self.sort_newest_first();
        dropped
    }
}
