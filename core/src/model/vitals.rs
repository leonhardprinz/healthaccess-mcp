//! `vitals/<yyyy-MM-dd>.json` — one file per day, every field nullable.

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

/// Schema tag of a vitals file.
pub const SCHEMA_VITALS: &str = "healthaccess.vitals.v1";
/// Pre-rename tag of a vitals file, accepted forever as an alias of [`SCHEMA_VITALS`].
pub const SCHEMA_VITALS_LEGACY: &str = "tide.vitals.v1";

/// One day of vitals.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Vitals {
    #[serde(default)]
    pub schema: Option<String>,
    pub date: NaiveDate,
    #[serde(default)]
    pub resting_hr: Option<f64>,
    #[serde(default)]
    pub hrv_sdnn_ms: Option<f64>,
    #[serde(default)]
    pub body_mass_kg: Option<f64>,
    #[serde(default)]
    pub sleep_s: Option<f64>,
    #[serde(default)]
    pub steps: Option<f64>,
    #[serde(default)]
    pub vo2max: Option<f64>,
    #[serde(default)]
    pub bp: Option<BloodPressure>,
}

/// A blood-pressure reading.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BloodPressure {
    #[serde(default)]
    pub sys: Option<f64>,
    #[serde(default)]
    pub dia: Option<f64>,
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,
}
