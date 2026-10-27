//! `healthaccess.workout.v1` — the canonical in-memory workout. v0 files are
//! converted into this shape on load (see [`super::workout_v0`]). Files written before
//! the rename carry the tags `tide.workout.v0` / `tide.workout.v1` and the key
//! `tide_version`; both are accepted forever as aliases.

use std::collections::BTreeMap;
use std::fmt;

use chrono::{DateTime, Utc};
use serde::de::Deserializer;
use serde::ser::SerializeTuple;
use serde::{Deserialize, Serialize};

use crate::{Error, Result};

/// Schema tag of a v1 workout file.
pub const SCHEMA_V1: &str = "healthaccess.workout.v1";
/// Pre-rename tag of a v1 workout file, accepted forever as an alias of [`SCHEMA_V1`].
pub const SCHEMA_V1_LEGACY: &str = "tide.workout.v1";

/// Values of `effort_source` (contract section "Effort").
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EffortSource {
    /// The athlete's own rating as exported by Apple (`WorkoutEffortScore`).
    Apple,
    /// Rated in the Health Access app.
    App,
    /// Written by `rate_workout`, only ever after the athlete said the number.
    Ai,
}

impl EffortSource {
    /// The string written into the file.
    pub const fn as_str(self) -> &'static str {
        match self {
            EffortSource::Apple => "apple",
            EffortSource::App => "app",
            EffortSource::Ai => "ai",
        }
    }

    /// Parse the file value (case-insensitive); unknown strings give `None`.
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "apple" => Some(EffortSource::Apple),
            "app" => Some(EffortSource::App),
            "ai" => Some(EffortSource::Ai),
            _ => None,
        }
    }
}

impl fmt::Display for EffortSource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// One workout as written by the app (v1) or derived from a v0 export.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Workout {
    /// `healthaccess.workout.v1` (or the pre-rename `tide.workout.v1`).
    pub schema: String,
    /// Version of the exporter that wrote the file (`healthaccess_version`; read also
    /// under its pre-rename alias `tide_version`).
    #[serde(
        default,
        alias = "tide_version",
        skip_serializing_if = "Option::is_none"
    )]
    pub healthaccess_version: Option<String>,
    /// Full HKWorkout UUID.
    pub id: String,
    /// `pool_swim | open_water_swim | indoor_row | run | walk | cycle | other:<hk raw>`.
    pub activity: String,
    /// Source device or app name, e.g. "Apple Watch" or a third-party cycling app.
    #[serde(default)]
    pub source: String,
    /// Workout start (UTC).
    pub start: DateTime<Utc>,
    /// Workout end (UTC).
    pub end: DateTime<Utc>,
    /// Active duration in seconds (pauses excluded).
    pub duration_s: f64,
    /// Total distance in metres, when the activity has one.
    #[serde(default)]
    pub distance_m: Option<f64>,
    /// Active energy in kcal.
    #[serde(default)]
    pub active_kcal: Option<f64>,
    /// Average heart rate in bpm.
    #[serde(default)]
    pub avg_hr: Option<f64>,
    /// Maximum heart rate in bpm.
    #[serde(default)]
    pub max_hr: Option<f64>,
    /// Pool length in metres (from `HKLapLength`).
    #[serde(default)]
    pub pool_length_m: Option<f64>,
    /// Zone bounds and seconds per zone.
    #[serde(default)]
    pub zones: Option<Zones>,
    /// The plan this workout executed, when matched.
    #[serde(default)]
    pub plan_ref: Option<PlanRef>,
    /// One step per HKWorkoutActivity, in order.
    #[serde(default)]
    pub steps: Vec<Step>,
    /// Pool lengths (HKWorkoutEvent type 3).
    #[serde(default)]
    pub laps: Vec<Lap>,
    /// Heart-rate series, ~1 sample / 5 s.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hr_series: Vec<HrSample>,
    /// Heart-rate recovery after the end.
    #[serde(default)]
    pub recovery_hr: Option<RecoveryHr>,
    /// The athlete's effort, 1 to 10. Comes from Apple (the rating entered on the
    /// Watch or in Fitness), from the Health Access app, or from `rate_workout`.
    #[serde(default, deserialize_with = "crate::util::opt_score")]
    pub effort: Option<u8>,
    /// Where `effort` came from: `apple`, `app` or `ai` (see [`EffortSource`]).
    /// Files written before the Effort section of the contract carry none.
    #[serde(default)]
    pub effort_source: Option<String>,
    /// Apple's own estimate of the effort (1 to 10). Never used as `effort`.
    #[serde(default)]
    pub effort_estimated: Option<f64>,
    /// Free text from the athlete (app or ai).
    #[serde(default)]
    pub feel: Option<String>,
    /// Raw HealthKit metadata, stringified.
    #[serde(default, deserialize_with = "crate::util::string_map")]
    pub metadata: BTreeMap<String, String>,
}

/// Heart-rate zone bounds plus seconds spent per zone.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Zones {
    /// Four ascending bpm bounds separating five zones.
    pub bounds: Vec<u32>,
    /// Where the bounds came from when the Rust side computed the zones: `config`,
    /// `estimated` (from the athlete's age in `profile.json`), `file` (the workout
    /// file's own zones) or `default`. Absent in files written by the app.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bounds_source: Option<String>,
    /// Seconds per zone.
    pub seconds: ZoneSeconds,
}

/// Seconds spent in each of the five zones.
#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ZoneSeconds {
    #[serde(default)]
    pub z1: u32,
    #[serde(default)]
    pub z2: u32,
    #[serde(default)]
    pub z3: u32,
    #[serde(default)]
    pub z4: u32,
    #[serde(default)]
    pub z5: u32,
}

impl ZoneSeconds {
    /// Total seconds covered by the zone model.
    pub fn total(&self) -> u32 {
        self.z1 + self.z2 + self.z3 + self.z4 + self.z5
    }

    /// Seconds in zones 1 and 2.
    pub fn z12(&self) -> u32 {
        self.z1 + self.z2
    }

    /// Percentage of time in zones 1–2, `None` when the model is empty.
    pub fn z12_pct(&self) -> Option<f64> {
        let total = self.total();
        (total > 0).then(|| 100.0 * f64::from(self.z12()) / f64::from(total))
    }

    /// Add seconds to zone `zone` (1–5).
    pub fn add(&mut self, zone: u8, secs: u32) {
        match zone {
            1 => self.z1 += secs,
            2 => self.z2 += secs,
            3 => self.z3 += secs,
            4 => self.z4 += secs,
            _ => self.z5 += secs,
        }
    }
}

/// Reference to the plan a workout executed.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct PlanRef {
    /// `plans/<plan_id>.json`.
    #[serde(default)]
    pub plan_id: Option<String>,
    /// Plan display name, e.g. "S26".
    #[serde(default)]
    pub name: Option<String>,
}

/// The role of a step inside the session.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StepKind {
    Work,
    Recovery,
    Warmup,
    Cooldown,
}

impl fmt::Display for StepKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            StepKind::Work => "work",
            StepKind::Recovery => "recovery",
            StepKind::Warmup => "warmup",
            StepKind::Cooldown => "cooldown",
        })
    }
}

/// One interval step (HKWorkoutActivity with a `WOIntervalStepKeyPath`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Step {
    /// `block.rep.step`, warm-up is `0.0.0`.
    pub key: String,
    pub block: u32,
    pub rep: u32,
    pub step: u32,
    /// Joined from the plan when matched; HealthKit does not export labels.
    #[serde(default)]
    pub label: Option<String>,
    pub kind: StepKind,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub duration_s: f64,
    #[serde(default)]
    pub distance_m: Option<f64>,
    #[serde(default)]
    pub avg_hr: Option<f64>,
    /// `WOIntervalStepSuccessful`; `None` when HealthKit did not record it.
    #[serde(default)]
    pub goal_met: Option<bool>,
    /// Seconds per 100 m; only for steps that covered at least 20 m.
    #[serde(default)]
    pub pace_s_per_100m: Option<f64>,
}

/// One pool length.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Lap {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub duration_s: f64,
    /// `mixed | freestyle | backstroke | breaststroke | butterfly | kickboard | unknown`.
    #[serde(default)]
    pub stroke: Option<String>,
    #[serde(default)]
    pub swolf: Option<f64>,
}

/// One heart-rate sample, serialized as `["2026-05-14T05:12:10Z", 84]`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HrSample {
    pub t: DateTime<Utc>,
    pub bpm: u32,
}

impl Serialize for HrSample {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        let mut t = s.serialize_tuple(2)?;
        t.serialize_element(&self.t)?;
        t.serialize_element(&self.bpm)?;
        t.end()
    }
}

impl<'de> Deserialize<'de> for HrSample {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        let (t, bpm): (DateTime<Utc>, f64) = Deserialize::deserialize(d)?;
        Ok(HrSample {
            t,
            bpm: bpm.round().max(0.0) as u32,
        })
    }
}

/// Heart rate at the end of the workout and 1 / 2 minutes later.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct RecoveryHr {
    #[serde(default)]
    pub end: Option<u32>,
    #[serde(rename = "1min", default)]
    pub one_min: Option<u32>,
    #[serde(rename = "2min", default)]
    pub two_min: Option<u32>,
}

/// Map an HKWorkoutActivityType raw value (+ swim location metadata) to the v1 activity string.
pub fn activity_from_hk(raw: u32, metadata: &BTreeMap<String, String>) -> String {
    match raw {
        46 => match metadata.get("HKSwimmingLocationType").map(String::as_str) {
            Some("2") => "open_water_swim".to_string(),
            _ => "pool_swim".to_string(),
        },
        35 => "indoor_row".to_string(),
        37 => "run".to_string(),
        52 => "walk".to_string(),
        13 => "cycle".to_string(),
        other => format!("other:{other}"),
    }
}

/// Short human name for an activity string ("pool_swim" → "Pool swim").
pub fn activity_label(activity: &str) -> String {
    match activity {
        "pool_swim" => "Pool swim".into(),
        "open_water_swim" => "Open water swim".into(),
        "indoor_row" => "Indoor row".into(),
        "run" => "Run".into(),
        "walk" => "Walk".into(),
        "cycle" => "Cycle".into(),
        other => other.replace('_', " "),
    }
}

/// Which schema a JSON document claims.
#[derive(Debug, Deserialize)]
struct SchemaPeek {
    #[serde(default)]
    schema: Option<String>,
    #[serde(default)]
    uuid: Option<String>,
    #[serde(default)]
    id: Option<String>,
}

/// Detected schema version of a workout document.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SchemaVersion {
    V0,
    V1,
}

impl fmt::Display for SchemaVersion {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            SchemaVersion::V0 => super::workout_v0::SCHEMA_V0,
            SchemaVersion::V1 => SCHEMA_V1,
        })
    }
}

/// The literal `schema` tag of a workout JSON text, if it carries one (pre-rename
/// `tide.*` alias tags are returned as written; see [`detect_schema`] for what is accepted).
pub fn schema_tag(json: &str) -> Option<String> {
    serde_json::from_str::<SchemaPeek>(json).ok()?.schema
}

/// Detect the schema version of a workout JSON text without parsing the whole file.
/// Both the current `healthaccess.*` tags and the pre-rename `tide.*` aliases are accepted.
pub fn detect_schema(json: &str) -> Result<SchemaVersion> {
    let peek: SchemaPeek = serde_json::from_str(json).map_err(|e| Error::json("<workout>", e))?;
    match peek.schema.as_deref() {
        Some(SCHEMA_V1 | SCHEMA_V1_LEGACY) => Ok(SchemaVersion::V1),
        Some(super::workout_v0::SCHEMA_V0 | super::workout_v0::SCHEMA_V0_LEGACY) => {
            Ok(SchemaVersion::V0)
        }
        Some(other) => Err(Error::Schema(
            if other.len() <= 40
                && other
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
            {
                other.to_string()
            } else {
                "unrecognised `schema` value".to_string()
            },
        )),
        None if peek.uuid.is_some() && peek.id.is_none() => Ok(SchemaVersion::V0),
        None if peek.id.is_some() => Ok(SchemaVersion::V1),
        None => Err(Error::Schema("missing `schema` field".to_string())),
    }
}

/// Parse a workout JSON text of either schema version into the v1 model.
pub fn parse_workout(json: &str) -> Result<Workout> {
    let text = json.trim_start_matches('\u{feff}');
    match detect_schema(text)? {
        SchemaVersion::V1 => {
            serde_json::from_str::<Workout>(text).map_err(|e| Error::json("<workout>", e))
        }
        SchemaVersion::V0 => {
            let v0: super::workout_v0::WorkoutV0 =
                serde_json::from_str(text).map_err(|e| Error::json("<workout>", e))?;
            Ok(v0.into_v1())
        }
    }
}

impl Workout {
    /// First 8 characters of the UUID, as used in file names.
    pub fn short_id(&self) -> String {
        self.id.chars().take(8).collect()
    }

    /// Plan name if matched, else a human activity label.
    pub fn display_name(&self) -> String {
        self.plan_ref
            .as_ref()
            .and_then(|p| p.name.clone())
            .unwrap_or_else(|| activity_label(&self.activity))
    }

    /// `true` for pool and open-water swims.
    pub fn is_swim(&self) -> bool {
        matches!(self.activity.as_str(), "pool_swim" | "open_water_swim")
    }

    /// `true` when the session carries an effort rating from any source.
    pub fn is_rated(&self) -> bool {
        self.effort.is_some()
    }

    /// The parsed `effort_source`, when it is one of the known values.
    pub fn effort_source(&self) -> Option<EffortSource> {
        self.effort_source.as_deref().and_then(EffortSource::parse)
    }
}
