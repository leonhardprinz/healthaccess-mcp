//! `days/<yyyy-MM-dd>.json`: one file per day with everything Health holds for that
//! day, in groups (`docs/export-coverage.md`). A group is present only when it has
//! data; inside a present group absent values are explicit `null`. The reader keeps
//! every key it does not model (`extra` maps and the `other` groups), so an AI sees
//! the whole file; the typed fields are the ones derived views need.
//!
//! `vitals/<yyyy-MM-dd>.json` (seven metrics) is the pre-v0.4 file and stays readable
//! as an alias: [`Day::vitals`] maps a day onto it.

use std::collections::BTreeMap;

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::vitals::{BloodPressure, Vitals};

/// Schema tag the app writes for a day file (absent on early files; any tag is accepted).
pub const SCHEMA_DAY: &str = "healthaccess.day.v1";

/// Goal and actual of one activity ring.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Ring {
    #[serde(default)]
    pub goal: Option<f64>,
    #[serde(default)]
    pub actual: Option<f64>,
}

impl Ring {
    /// `true` when the actual reached the goal (both known, goal above zero).
    pub fn hit(&self) -> Option<bool> {
        match (self.goal, self.actual) {
            (Some(g), Some(a)) if g > 0.0 => Some(a >= g),
            _ => None,
        }
    }
}

/// The three rings of `HKActivitySummary`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Rings {
    #[serde(default)]
    pub move_kcal: Option<Ring>,
    #[serde(default)]
    pub exercise_min: Option<Ring>,
    #[serde(default)]
    pub stand_hours: Option<Ring>,
    /// `active_energy` or `move_time` (Apple's move mode).
    #[serde(default)]
    pub move_mode: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// `activity` group.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Activity {
    #[serde(default)]
    pub rings: Option<Rings>,
    #[serde(default)]
    pub steps: Option<f64>,
    #[serde(default)]
    pub distance_walking_running_m: Option<f64>,
    #[serde(default)]
    pub distance_cycling_m: Option<f64>,
    #[serde(default)]
    pub distance_swimming_m: Option<f64>,
    #[serde(default)]
    pub flights_climbed: Option<f64>,
    #[serde(default)]
    pub active_energy_kcal: Option<f64>,
    #[serde(default)]
    pub basal_energy_kcal: Option<f64>,
    #[serde(default)]
    pub exercise_min: Option<f64>,
    #[serde(default)]
    pub stand_min: Option<f64>,
    #[serde(default)]
    pub move_min: Option<f64>,
    #[serde(default)]
    pub time_in_daylight_min: Option<f64>,
    /// Mean physical effort of the day in MET (Apple's `PhysicalEffort`).
    #[serde(default)]
    pub physical_effort_avg_met: Option<f64>,
    #[serde(default)]
    pub push_count: Option<f64>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// Min, mean, max and sample count of the day's heart rate.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct HrStats {
    #[serde(default)]
    pub min: Option<f64>,
    #[serde(default)]
    pub avg: Option<f64>,
    #[serde(default)]
    pub max: Option<f64>,
    #[serde(default)]
    pub samples: Option<f64>,
}

/// `heart` group.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Heart {
    #[serde(default)]
    pub resting_hr: Option<f64>,
    #[serde(default)]
    pub walking_hr_avg: Option<f64>,
    #[serde(default)]
    pub hr: Option<HrStats>,
    #[serde(default)]
    pub hrv_sdnn_ms: Option<f64>,
    #[serde(default)]
    pub hrv_rmssd_ms: Option<f64>,
    /// Apple's one-minute recovery outside workouts.
    #[serde(default)]
    pub recovery_1min_bpm: Option<f64>,
    #[serde(default)]
    pub vo2max: Option<f64>,
    #[serde(default)]
    pub afib_burden_pct: Option<f64>,
    /// High HR, low HR, irregular rhythm, low cardio fitness: counts with times.
    #[serde(default)]
    pub events: Option<Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// `sleep` group.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Sleep {
    #[serde(default)]
    pub in_bed_s: Option<f64>,
    #[serde(default)]
    pub asleep_s: Option<f64>,
    #[serde(default)]
    pub core_s: Option<f64>,
    #[serde(default)]
    pub deep_s: Option<f64>,
    #[serde(default)]
    pub rem_s: Option<f64>,
    #[serde(default)]
    pub awake_s: Option<f64>,
    #[serde(default)]
    pub sessions: Option<Value>,
    #[serde(default)]
    pub wrist_temperature_delta_c: Option<f64>,
    #[serde(default)]
    pub respiratory_rate_sleep: Option<f64>,
    #[serde(default)]
    pub spo2_sleep: Option<f64>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// `body` group.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Body {
    #[serde(default)]
    pub mass_kg: Option<f64>,
    #[serde(default)]
    pub fat_pct: Option<f64>,
    #[serde(default)]
    pub lean_kg: Option<f64>,
    #[serde(default)]
    pub bmi: Option<f64>,
    #[serde(default)]
    pub waist_cm: Option<f64>,
    #[serde(default)]
    pub height_cm: Option<f64>,
    #[serde(default)]
    pub temperature_c: Option<f64>,
    #[serde(default)]
    pub basal_body_temperature_c: Option<f64>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// One blood-pressure reading of the day.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct PressureReading {
    #[serde(default)]
    pub sys: Option<f64>,
    #[serde(default)]
    pub dia: Option<f64>,
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,
}

/// `blood` group.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Blood {
    #[serde(default)]
    pub pressure: Vec<PressureReading>,
    #[serde(default)]
    pub glucose: Option<Value>,
    #[serde(default)]
    pub alcohol_pct: Option<f64>,
    #[serde(default)]
    pub insulin: Option<Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// One day. The groups the derived views read are typed; every other group
/// (`respiratory`, `mobility`, `hearing`, `nutrition`, `mind`, `symptoms`, `cycle`,
/// `medications`, `hygiene`, `uv`, `wheelchair`, `audiogram`, `vision`, and whatever
/// a later app adds) lands in `other` under its own name.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Day {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema: Option<String>,
    pub date: NaiveDate,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub activity: Option<Activity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heart: Option<Heart>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sleep: Option<Sleep>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<Body>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blood: Option<Blood>,
    #[serde(flatten)]
    pub other: BTreeMap<String, Value>,
}

/// The group names of the contract, in its order.
pub const GROUPS: &[&str] = &[
    "activity",
    "heart",
    "respiratory",
    "sleep",
    "body",
    "blood",
    "mobility",
    "hearing",
    "nutrition",
    "mind",
    "symptoms",
    "cycle",
    "medications",
    "hygiene",
    "uv",
    "wheelchair",
    "audiogram",
    "vision",
];

impl Day {
    /// Names of the groups present in this day, contract order first, then the rest.
    pub fn groups(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        let typed: [(&str, bool); 5] = [
            ("activity", self.activity.is_some()),
            ("heart", self.heart.is_some()),
            ("sleep", self.sleep.is_some()),
            ("body", self.body.is_some()),
            ("blood", self.blood.is_some()),
        ];
        for g in GROUPS {
            let present = typed
                .iter()
                .find(|(n, _)| n == g)
                .map(|(_, p)| *p)
                .unwrap_or_else(|| self.other.get(*g).map(|v| !v.is_null()).unwrap_or(false));
            if present {
                out.push((*g).to_string());
            }
        }
        for (k, v) in &self.other {
            if !GROUPS.contains(&k.as_str()) && !v.is_null() && k != "schema" && !k.starts_with('_')
            {
                out.push(k.clone());
            }
        }
        out
    }

    /// The seven-metric `vitals` view of this day (the pre-v0.4 file shape).
    pub fn vitals(&self) -> Vitals {
        let bp = self
            .blood
            .as_ref()
            .and_then(|b| b.pressure.last())
            .map(|p| BloodPressure {
                sys: p.sys,
                dia: p.dia,
                at: p.at,
            });
        Vitals {
            schema: Some(super::vitals::SCHEMA_VITALS.to_string()),
            date: self.date,
            resting_hr: self.heart.as_ref().and_then(|h| h.resting_hr),
            hrv_sdnn_ms: self.heart.as_ref().and_then(|h| h.hrv_sdnn_ms),
            body_mass_kg: self.body.as_ref().and_then(|b| b.mass_kg),
            sleep_s: self.sleep.as_ref().and_then(|s| s.asleep_s),
            steps: self.activity.as_ref().and_then(|a| a.steps),
            vo2max: self.heart.as_ref().and_then(|h| h.vo2max),
            bp,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_round_trip_and_map_to_vitals() {
        let text = serde_json::json!({
            "schema": "healthaccess.day.v1", "date": "2026-10-24",
            "activity": {"rings": {"move_kcal": {"goal": 600, "actual": 655}, "exercise_min": {"goal": 30, "actual": 41},
                                   "stand_hours": {"goal": 12, "actual": 9}, "move_mode": "active_energy"},
                         "steps": 9120, "physical_effort_avg_met": 2.4, "distance_walking_running_m": null},
            "heart": {"resting_hr": 54, "hrv_sdnn_ms": 44.1, "vo2max": 46.3, "hr": {"min": 46, "avg": 70, "max": 158, "samples": 1060},
                      "events": {"high_hr": []}, "walking_hr_avg": 95},
            "sleep": {"asleep_s": 26160, "in_bed_s": 27900, "deep_s": 4200, "sessions": [{"start": "2026-10-23T22:10:00Z", "end": "2026-10-24T05:55:00Z", "source": "Watch"}]},
            "body": {"mass_kg": 78.4},
            "blood": {"pressure": [{"sys": 118, "dia": 76, "at": "2026-10-24T07:00:00Z"}]},
            "respiratory": {"rate_avg": 13.8, "spo2": {"avg": 98, "min": 95}},
            "nutrition": {"HKQuantityTypeIdentifierDietaryCaffeine": {"sum": 120, "unit": "mg"}},
            "mind": {"mindful_minutes": 10},
            "_comment": "not a group"
        })
        .to_string();
        let day: Day = serde_json::from_str(&text).unwrap();
        assert_eq!(
            day.groups(),
            [
                "activity",
                "heart",
                "respiratory",
                "sleep",
                "body",
                "blood",
                "nutrition",
                "mind"
            ]
        );
        let rings = day.activity.as_ref().unwrap().rings.as_ref().unwrap();
        assert_eq!(rings.move_kcal.as_ref().unwrap().hit(), Some(true));
        assert_eq!(rings.stand_hours.as_ref().unwrap().hit(), Some(false));
        let v = day.vitals();
        assert_eq!(v.resting_hr, Some(54.0));
        assert_eq!(v.sleep_s, Some(26160.0));
        assert_eq!(v.steps, Some(9120.0));
        assert_eq!(v.bp.unwrap().sys, Some(118.0));
        // nothing is lost on the way through
        let back: Value = serde_json::to_value(&day).unwrap();
        assert_eq!(back["respiratory"]["spo2"]["min"], 95);
        assert_eq!(back["heart"]["walking_hr_avg"], 95.0);
        assert_eq!(
            back["nutrition"]["HKQuantityTypeIdentifierDietaryCaffeine"]["sum"],
            120
        );
        assert!(back.get("mobility").is_none(), "absent groups stay absent");
    }

    #[test]
    fn a_bare_day_is_valid() {
        let day: Day = serde_json::from_str(r#"{"date": "2026-10-25"}"#).unwrap();
        assert!(day.groups().is_empty());
        assert_eq!(day.vitals().resting_hr, None);
    }
}
