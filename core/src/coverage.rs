//! The v0.4 export files beyond workouts: `days/`, `catalog.json`, `profile.json`,
//! `ecg/` (`docs/export-coverage.md`), and the coverage check that compares the
//! catalog with the identifier list this build embeds ([`crate::hk_types`]).

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::hk_types;
use crate::model::day::Day;
use crate::store::Store;
use crate::util::read_json;
use crate::{Error, Result};

/// One entry of `catalog.json`'s `types`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct CatalogType {
    /// `quantity`, `category`, `characteristic`, `correlation`, `workout`, ...
    #[serde(default)]
    pub kind: Option<String>,
    /// iOS hides read authorization, so this is usually `null`; `has_data` is the signal.
    #[serde(default)]
    pub authorized: Option<bool>,
    #[serde(default)]
    pub has_data: bool,
    #[serde(default)]
    pub samples_90d: Option<f64>,
    #[serde(default)]
    pub first: Option<String>,
    #[serde(default)]
    pub last: Option<String>,
    /// `workouts`, `days`, `ecg`, `profile` or `none`.
    #[serde(default)]
    pub exported_in: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

impl CatalogType {
    /// `true` when the app wrote this type somewhere.
    pub fn exported(&self) -> bool {
        matches!(
            self.exported_in.as_deref().map(str::trim),
            Some(e) if !e.is_empty() && !e.eq_ignore_ascii_case("none")
        )
    }
}

/// `catalog.json`, written by the app after every sync.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Catalog {
    #[serde(default)]
    pub generated: Option<DateTime<Utc>>,
    #[serde(default)]
    pub app_version: Option<String>,
    #[serde(default)]
    pub types: BTreeMap<String, CatalogType>,
    /// Types Health reported with data that the app's own list did not know.
    #[serde(default)]
    pub unknown_types_with_data: Vec<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// `profile.json`: the characteristics, read once per sync.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Profile {
    #[serde(default)]
    pub age: Option<f64>,
    #[serde(default)]
    pub birth_year: Option<f64>,
    #[serde(default)]
    pub biological_sex: Option<String>,
    #[serde(default)]
    pub blood_type: Option<String>,
    #[serde(default)]
    pub wheelchair_use: Option<String>,
    #[serde(default)]
    pub activity_move_mode: Option<String>,
    #[serde(default)]
    pub fitzpatrick_skin_type: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}

/// One `ecg/<timestamp>.json` summary (the voltage sidecar is never loaded).
#[derive(Debug, Clone, Serialize)]
pub struct EcgSummary {
    pub file: String,
    /// From the file name when it is a timestamp, else from a `start`/`at` key.
    pub at: Option<DateTime<Utc>>,
    pub classification: Option<String>,
    pub symptoms_status: Option<String>,
    pub average_heart_rate: Option<f64>,
    pub sampling_frequency_hz: Option<f64>,
    pub algorithm_version: Option<String>,
    pub device: Option<Value>,
    /// `ecg/<timestamp>.voltage.json` exists next to it.
    pub voltage_file: Option<String>,
    /// The whole document as written.
    pub document: Value,
}

/// Result of comparing `catalog.json` with [`hk_types`].
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Coverage {
    pub sdk: String,
    pub generated: Option<DateTime<Utc>>,
    pub app_version: Option<String>,
    /// Identifiers this build knows.
    pub known_types: usize,
    /// Entries in the catalog.
    pub catalog_types: usize,
    pub with_data: usize,
    pub exported: usize,
    /// Should always be empty: Health has samples, the app wrote them nowhere.
    pub types_with_data_not_exported: Vec<String>,
    /// Types with data that this build's list does not know (the app's own list and
    /// ours): the signal to update.
    pub unknown_types_with_data: Vec<String>,
    /// Known identifiers the catalog does not mention at all.
    pub known_types_missing_from_catalog: Vec<String>,
}

impl Coverage {
    /// Compare a catalog with the embedded list.
    pub fn of(catalog: &Catalog) -> Self {
        let mut not_exported = Vec::new();
        let mut unknown: Vec<String> = catalog.unknown_types_with_data.clone();
        let mut with_data = 0;
        let mut exported = 0;
        for (id, t) in &catalog.types {
            if t.has_data {
                with_data += 1;
                if !t.exported() {
                    not_exported.push(id.clone());
                }
                if !hk_types::is_known(id, t.kind.as_deref()) && !unknown.contains(id) {
                    unknown.push(id.clone());
                }
            }
            if t.exported() {
                exported += 1;
            }
        }
        let listed: Vec<String> = catalog
            .types
            .iter()
            .map(|(id, t)| hk_types::normalize(id, t.kind.as_deref()))
            .collect();
        let missing: Vec<String> = hk_types::all()
            .filter(|k| !listed.contains(&hk_types::normalize(k, None)))
            .map(str::to_string)
            .collect();
        unknown.sort();
        unknown.dedup();
        Coverage {
            sdk: hk_types::SDK.to_string(),
            generated: catalog.generated,
            app_version: catalog.app_version.clone(),
            known_types: hk_types::count(),
            catalog_types: catalog.types.len(),
            with_data,
            exported,
            types_with_data_not_exported: not_exported,
            unknown_types_with_data: unknown,
            known_types_missing_from_catalog: missing,
        }
    }

    /// `true` when nothing with data is unexported and nothing with data is unknown.
    pub fn clean(&self) -> bool {
        self.types_with_data_not_exported.is_empty() && self.unknown_types_with_data.is_empty()
    }
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Date out of `days/2026-10-24.json`.
fn date_of(path: &Path) -> Option<NaiveDate> {
    path.file_stem()
        .and_then(|s| s.to_str())
        .and_then(|s| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
}

/// `2026-10-24T07-31-05Z`, `2026-10-24T07:31:05Z` or `2026-10-24_0731` out of a file stem.
fn timestamp_of(stem: &str) -> Option<DateTime<Utc>> {
    let s = stem.trim_end_matches(".voltage");
    if let Ok(t) = DateTime::parse_from_rfc3339(s) {
        return Some(t.with_timezone(&Utc));
    }
    for fmt in [
        "%Y-%m-%dT%H-%M-%SZ",
        "%Y-%m-%dT%H%M%SZ",
        "%Y-%m-%d_%H%M%S",
        "%Y-%m-%d_%H%M",
    ] {
        if let Ok(t) = chrono::NaiveDateTime::parse_from_str(s, fmt) {
            return Some(t.and_utc());
        }
    }
    None
}

fn json_files(dir: &Path) -> Result<Vec<PathBuf>> {
    if !dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut files: Vec<PathBuf> = fs::read_dir(dir)
        .map_err(|e| Error::io(dir, e))?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| {
            p.is_file()
                && p.extension().map(|x| x == "json").unwrap_or(false)
                && !file_name(p).starts_with('.')
        })
        .collect();
    files.sort();
    Ok(files)
}

fn str_key(v: &Value, keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|k| v.get(*k)).and_then(|x| match x {
        Value::String(s) => Some(s.clone()),
        Value::Null => None,
        other => Some(other.to_string()),
    })
}

fn num_key(v: &Value, keys: &[&str]) -> Option<f64> {
    keys.iter().find_map(|k| v.get(*k)).and_then(Value::as_f64)
}

impl Store {
    /// `days/`.
    pub fn days_dir(&self) -> PathBuf {
        self.dir().join("days")
    }

    /// `ecg/`.
    pub fn ecg_dir(&self) -> PathBuf {
        self.dir().join("ecg")
    }

    /// `catalog.json`.
    pub fn catalog_path(&self) -> PathBuf {
        self.dir().join("catalog.json")
    }

    /// `profile.json`.
    pub fn profile_path(&self) -> PathBuf {
        self.dir().join("profile.json")
    }

    /// `days/<date>.json`.
    pub fn day_path(&self, date: NaiveDate) -> PathBuf {
        self.days_dir().join(format!("{date}.json"))
    }

    /// One day, `Ok(None)` when the app has not written that date.
    pub fn day(&self, date: NaiveDate) -> Result<Option<Day>> {
        let path = self.day_path(date);
        if !path.is_file() {
            return Ok(None);
        }
        read_json(&path).map(Some)
    }

    /// Every day file with `from <= date <= to`, oldest first. Files that do not
    /// parse are skipped (`doctor` reports them).
    pub fn days(&self, from: NaiveDate, to: NaiveDate) -> Result<Vec<Day>> {
        let mut out = Vec::new();
        for path in json_files(&self.days_dir())? {
            let Some(date) = date_of(&path) else { continue };
            if date < from || date > to {
                continue;
            }
            if let Ok(mut d) = read_json::<Day>(&path) {
                d.date = date;
                out.push(d);
            }
        }
        out.sort_by_key(|d| d.date);
        Ok(out)
    }

    /// `true` when the app has written at least one day file.
    pub fn has_days(&self) -> bool {
        json_files(&self.days_dir())
            .map(|f| !f.is_empty())
            .unwrap_or(false)
    }

    /// `catalog.json`, `Ok(None)` when absent.
    pub fn catalog(&self) -> Result<Option<Catalog>> {
        let path = self.catalog_path();
        if !path.is_file() {
            return Ok(None);
        }
        read_json(&path).map(Some)
    }

    /// The coverage check of `catalog.json` against this build's list; `None` without a catalog.
    pub fn coverage(&self) -> Result<Option<Coverage>> {
        Ok(self.catalog()?.as_ref().map(Coverage::of))
    }

    /// `profile.json`, `Ok(None)` when absent.
    pub fn profile(&self) -> Result<Option<Profile>> {
        let path = self.profile_path();
        if !path.is_file() {
            return Ok(None);
        }
        read_json(&path).map(Some)
    }

    /// Every `ecg/*.json` summary (voltage sidecars are listed, not loaded), newest first.
    pub fn ecgs(&self) -> Result<Vec<EcgSummary>> {
        let files = json_files(&self.ecg_dir())?;
        let mut out = Vec::new();
        for path in &files {
            let name = file_name(path);
            if name.ends_with(".voltage.json") {
                continue;
            }
            let Ok(doc) = read_json::<Value>(path) else {
                continue;
            };
            let stem = name.trim_end_matches(".json");
            let voltage = format!("{stem}.voltage.json");
            let voltage_file = files
                .iter()
                .any(|f| file_name(f) == voltage)
                .then_some(format!("ecg/{voltage}"));
            let at = timestamp_of(stem).or_else(|| {
                str_key(&doc, &["start", "at", "timestamp", "date"])
                    .and_then(|s| DateTime::parse_from_rfc3339(&s).ok())
                    .map(|t| t.with_timezone(&Utc))
            });
            out.push(EcgSummary {
                file: format!("ecg/{name}"),
                at,
                classification: str_key(&doc, &["classification"]),
                symptoms_status: str_key(&doc, &["symptoms_status", "symptoms"]),
                average_heart_rate: num_key(&doc, &["average_heart_rate", "avg_hr", "average_hr"]),
                sampling_frequency_hz: num_key(
                    &doc,
                    &["sampling_frequency_hz", "sampling_frequency"],
                ),
                algorithm_version: str_key(&doc, &["algorithm_version"]),
                device: doc.get("device").cloned().filter(|v| !v.is_null()),
                voltage_file,
                document: doc,
            });
        }
        out.sort_by(|a, b| b.at.cmp(&a.at).then_with(|| b.file.cmp(&a.file)));
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coverage_flags_unexported_and_unknown_types() {
        let mut types = BTreeMap::new();
        types.insert(
            "HKQuantityTypeIdentifierHeartRate".to_string(),
            CatalogType {
                kind: Some("quantity".into()),
                has_data: true,
                exported_in: Some("workouts".into()),
                ..Default::default()
            },
        );
        types.insert(
            "HKQuantityTypeIdentifierBodyMass".to_string(),
            CatalogType {
                kind: Some("quantity".into()),
                has_data: true,
                exported_in: Some("none".into()),
                ..Default::default()
            },
        );
        types.insert(
            "HKQuantityTypeIdentifierBrandNewThing".to_string(),
            CatalogType {
                kind: Some("quantity".into()),
                has_data: true,
                exported_in: Some("days".into()),
                ..Default::default()
            },
        );
        types.insert(
            "HKCategoryTypeIdentifierSleepAnalysis".to_string(),
            CatalogType {
                kind: Some("category".into()),
                has_data: false,
                exported_in: Some("none".into()),
                ..Default::default()
            },
        );
        let catalog = Catalog {
            types,
            unknown_types_with_data: vec!["HKQuantityTypeIdentifierFromTheApp".into()],
            ..Default::default()
        };
        let c = Coverage::of(&catalog);
        assert_eq!(c.catalog_types, 4);
        assert_eq!(c.with_data, 3);
        assert_eq!(c.exported, 2);
        assert_eq!(
            c.types_with_data_not_exported,
            ["HKQuantityTypeIdentifierBodyMass"]
        );
        assert_eq!(
            c.unknown_types_with_data,
            [
                "HKQuantityTypeIdentifierBrandNewThing",
                "HKQuantityTypeIdentifierFromTheApp"
            ]
        );
        assert!(!c.clean());
        assert_eq!(c.known_types, hk_types::count());
        assert_eq!(
            c.known_types_missing_from_catalog.len(),
            hk_types::count() - 3,
            "the three known entries are accounted for"
        );
    }

    #[test]
    fn ecg_timestamps_come_from_file_names() {
        assert_eq!(
            timestamp_of("2026-10-24T07-31-05Z").map(|t| t.to_rfc3339()),
            Some("2026-10-24T07:31:05+00:00".into())
        );
        assert!(timestamp_of("2026-10-24T07:31:05Z").is_some());
        assert!(timestamp_of("2026-10-24_0731").is_some());
        assert!(timestamp_of("notes").is_none());
        assert_eq!(
            date_of(Path::new("days/2026-10-24.json")),
            Some(NaiveDate::from_ymd_opt(2026, 10, 24).unwrap())
        );
    }
}
