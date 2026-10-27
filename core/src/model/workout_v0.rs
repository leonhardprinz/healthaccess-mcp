//! `tide.workout.v0` — the Phase 0 export format. It carries raw HealthKit
//! `activities[]` and `events[]` instead of `steps[]` / `laps[]`; the conversion in
//! [`WorkoutV0::into_v1`] derives those exactly as `docs/schema.md` describes:
//!
//! - steps: one per `HKWorkoutActivity` (`WOIntervalStepKeyPath` = `block.rep.step`,
//!   warm-up = `0.0.0`). A workout whose single activity has no key path gets
//!   `steps: []`; in multi-activity workouts an activity without a key path gets
//!   `key` = activity index, `block` = index, `rep`/`step` = 0 (same as the app).
//!   `goal_met` = `WOIntervalStepSuccessful` (null when absent), pace from
//!   distance/duration. Kind, as the app infers it: `0.0.0` → warmup; the trailing
//!   single-step block → cooldown; a distance recorded or a distance goal
//!   (`WOIntervalStepDistacnceGoalAchievedDuration`, Apple's typo) → work — "distance
//!   recorded" means ≥ 20 m, so a few metres of drift during a rest step do not count;
//!   remaining steps alternate even step → work, odd → recovery (the app labels those
//!   recovery). The store refines kinds and labels from the plan when one matches
//!   (see `Store::load_workout`).
//! - laps: `events[]` of type 3 (length) with `HKSwimmingStrokeStyle` and `HKSWOLFScore`.
//! - `max_hr`, `recovery_hr`: derived from `hr_series`.
//! - `zones`: the exporter's `zone_seconds` with the exporter's bounds (legacy; the
//!   reading side computes zones itself when it knows bounds).

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::workout::{
    activity_from_hk, HrSample, Lap, Step, StepKind, Workout, ZoneSeconds, Zones, SCHEMA_V1,
};
use crate::derive;
use crate::V0_EXPORTER_ZONE_BOUNDS;

/// Schema tag of a v0 workout file. Nothing writes v0 any more; the Phase 0 app wrote
/// [`SCHEMA_V0_LEGACY`], which is what real files carry.
pub const SCHEMA_V0: &str = "healthaccess.workout.v0";
/// Pre-rename tag of a v0 workout file, accepted forever as an alias of [`SCHEMA_V0`].
pub const SCHEMA_V0_LEGACY: &str = "tide.workout.v0";

/// A Phase 0 export.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WorkoutV0 {
    pub schema: String,
    pub uuid: String,
    /// HKWorkoutActivityType raw value (46 swim, 35 rowing, 13 cycling, 52 walking…).
    pub activity: u32,
    #[serde(default)]
    pub activity_name: Option<String>,
    #[serde(default)]
    pub source: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub duration_s: f64,
    #[serde(default)]
    pub distance_m: Option<f64>,
    #[serde(default)]
    pub active_kcal: Option<f64>,
    #[serde(default)]
    pub avg_hr: Option<f64>,
    #[serde(default)]
    pub max_hr: Option<f64>,
    #[serde(default)]
    pub hr_samples: Option<u32>,
    #[serde(default)]
    pub hr_series: Vec<HrSample>,
    #[serde(default)]
    pub zone_seconds: Option<ZoneSeconds>,
    #[serde(default)]
    pub activities: Vec<V0Activity>,
    #[serde(default)]
    pub events: Vec<V0Event>,
    #[serde(default, deserialize_with = "crate::util::string_map")]
    pub metadata: BTreeMap<String, String>,
    #[serde(default, deserialize_with = "crate::util::opt_score")]
    pub effort: Option<u8>,
    #[serde(default)]
    pub effort_source: Option<String>,
    #[serde(default)]
    pub effort_estimated: Option<f64>,
    #[serde(default)]
    pub feel: Option<String>,
}

/// Raw `HKWorkoutActivity`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct V0Activity {
    #[serde(default)]
    pub kind: Option<u32>,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    #[serde(default)]
    pub avg_hr: Option<f64>,
    #[serde(default)]
    pub distance_m: Option<f64>,
    #[serde(default, deserialize_with = "crate::util::string_map")]
    pub metadata: BTreeMap<String, String>,
}

/// Raw `HKWorkoutEvent`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct V0Event {
    /// HKWorkoutEventType: 1 pause, 2 resume, 3 lap, 4 marker, 5 motion paused,
    /// 6 motion resumed, 7 segment.
    #[serde(rename = "type")]
    pub kind: u32,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    #[serde(default, deserialize_with = "crate::util::string_map")]
    pub metadata: BTreeMap<String, String>,
}

/// HealthKit metadata key: interval step key path.
pub const KEY_PATH: &str = "WOIntervalStepKeyPath";
/// HealthKit metadata key: step goal reached.
pub const KEY_SUCCESS: &str = "WOIntervalStepSuccessful";
/// HealthKit metadata key: time to reach a distance goal (Apple's typo included).
pub const KEY_DISTANCE_GOAL: &str = "WOIntervalStepDistacnceGoalAchievedDuration";

/// HKSwimmingStrokeStyle raw value to name.
pub fn stroke_name(raw: &str) -> &'static str {
    match raw.trim() {
        "1" => "mixed",
        "2" => "freestyle",
        "3" => "backstroke",
        "4" => "breaststroke",
        "5" => "butterfly",
        "6" => "kickboard",
        _ => "unknown",
    }
}

/// Parse `"50 m"` / `"25 m"` / `"50"` into metres.
pub fn parse_lap_length(s: &str) -> Option<f64> {
    let num: String = s
        .trim()
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let v: f64 = num.parse().ok()?;
    let lower = s.to_ascii_lowercase();
    Some(if lower.contains("yd") { v * 0.9144 } else { v })
}

fn parse_key_path(s: &str) -> Option<(u32, u32, u32)> {
    let mut it = s.split('.').map(|p| p.trim().parse::<u32>().ok());
    let b = it.next()??;
    let r = it.next()??;
    let st = it.next()??;
    Some((b, r, st))
}

impl WorkoutV0 {
    /// Convert into the v1 model (see the module docs for the derivation rules).
    pub fn into_v1(self) -> Workout {
        let activity = activity_from_hk(self.activity, &self.metadata);
        let pool_length_m = self
            .metadata
            .get("HKLapLength")
            .and_then(|s| parse_lap_length(s));

        // (key, block, rep, step) per activity; a lone activity without a key path is the
        // workout itself, not a step.
        let keyed: Vec<(String, u32, u32, u32)> =
            if self.activities.len() == 1 && !self.activities[0].metadata.contains_key(KEY_PATH) {
                Vec::new()
            } else {
                self.activities
                    .iter()
                    .enumerate()
                    .map(|(i, a)| {
                        a.metadata
                            .get(KEY_PATH)
                            .and_then(|k| parse_key_path(k).map(|(b, r, s)| (k.clone(), b, r, s)))
                            .unwrap_or_else(|| (i.to_string(), i as u32, 0, 0))
                    })
                    .collect()
            };
        // the trailing block is a cool-down when it holds exactly one step (rep 0, step 0)
        let last_block = keyed.iter().map(|k| k.1).max().unwrap_or(0);
        let trailing_single = last_block > 0
            && keyed.iter().filter(|k| k.1 == last_block).count() == 1
            && keyed
                .iter()
                .any(|k| k.1 == last_block && k.2 == 0 && k.3 == 0);

        let steps: Vec<Step> = self
            .activities
            .iter()
            .zip(keyed)
            .map(|(a, (key, block, rep, step))| {
                let duration_s = (a.end - a.start).num_milliseconds() as f64 / 1000.0;
                let has_distance_goal = a.metadata.contains_key(KEY_DISTANCE_GOAL);
                let has_distance = a
                    .distance_m
                    .map(|d| d >= derive::MIN_PACE_DISTANCE_M)
                    .unwrap_or(false);
                let kind = if block == 0 {
                    StepKind::Warmup
                } else if trailing_single && block == last_block {
                    StepKind::Cooldown
                } else if has_distance_goal || has_distance || step % 2 == 0 {
                    StepKind::Work
                } else {
                    StepKind::Recovery
                };
                let goal_met = a
                    .metadata
                    .get(KEY_SUCCESS)
                    .map(|v| v.trim() == "1" || v.eq_ignore_ascii_case("true"));
                Step {
                    key,
                    block,
                    rep,
                    step,
                    label: None,
                    kind,
                    start: a.start,
                    end: a.end,
                    duration_s,
                    distance_m: a.distance_m,
                    avg_hr: a.avg_hr,
                    goal_met,
                    pace_s_per_100m: derive::pace_s_per_100m(a.distance_m, duration_s),
                }
            })
            .collect();

        let laps: Vec<Lap> = self
            .events
            .iter()
            .filter(|e| e.kind == 3)
            .map(|e| Lap {
                start: e.start,
                end: e.end,
                duration_s: (e.end - e.start).num_milliseconds() as f64 / 1000.0,
                stroke: e
                    .metadata
                    .get("HKSwimmingStrokeStyle")
                    .map(|s| stroke_name(s).to_string()),
                swolf: e
                    .metadata
                    .get("HKSWOLFScore")
                    .and_then(|s| s.trim().parse().ok()),
            })
            .collect();

        let zones = self.zone_seconds.map(|seconds| Zones {
            bounds: V0_EXPORTER_ZONE_BOUNDS.to_vec(),
            bounds_source: None,
            seconds,
        });

        let max_hr = self.max_hr.or_else(|| derive::max_hr(&self.hr_series));
        let recovery_hr = derive::recovery_hr(&self.hr_series, self.end);

        Workout {
            schema: SCHEMA_V1.to_string(),
            healthaccess_version: None,
            id: self.uuid,
            activity,
            source: self.source,
            start: self.start,
            end: self.end,
            duration_s: self.duration_s,
            distance_m: self.distance_m,
            active_kcal: self.active_kcal,
            avg_hr: self.avg_hr,
            max_hr,
            pool_length_m,
            zones,
            plan_ref: None,
            steps,
            laps,
            hr_series: self.hr_series,
            recovery_hr,
            effort: self.effort,
            effort_source: self.effort_source,
            effort_estimated: self.effort_estimated,
            feel: self.feel,
            metadata: self.metadata,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lap_length_parsing() {
        assert_eq!(parse_lap_length("50 m"), Some(50.0));
        assert_eq!(parse_lap_length("25 m"), Some(25.0));
        assert_eq!(parse_lap_length("25 yd"), Some(22.86));
        assert_eq!(parse_lap_length("nope"), None);
    }

    #[test]
    fn key_paths() {
        assert_eq!(parse_key_path("2.1.0"), Some((2, 1, 0)));
        assert_eq!(parse_key_path("0.0.0"), Some((0, 0, 0)));
        assert_eq!(parse_key_path("x"), None);
    }
}
