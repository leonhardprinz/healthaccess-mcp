//! [`Store`]: the Health Access folder as an API. Read-only everywhere except
//! `plans/<id>.json` (written) and the `effort` / `feel` fields of a workout file.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Duration, NaiveDate, Utc};
use serde::Serialize;
use serde_json::Value;

use crate::coverage::{Catalog, Coverage, Profile};
use crate::derive::{self, CardiacCost, WeekSummary};
use crate::model::day::Day;
use crate::model::index::{Index, IndexEntry};
use crate::model::plan::{Plan, PlanStatus};
use crate::model::vitals::Vitals;
use crate::model::workout::{detect_schema, parse_workout, schema_tag, EffortSource, Workout};
use crate::model::PlanRef;
use crate::util::{
    atomic_write, is_plain_name, looks_pretty, read_json, read_to_string, to_sorted_pretty_json,
};
use crate::{Error, Result};

/// Plans scheduled within this window of a workout start are matched to it.
pub const PLAN_MATCH_WINDOW_H: i64 = 2;

/// Handle on a Health Access folder.
#[derive(Debug, Clone)]
pub struct Store {
    dir: PathBuf,
    /// Bounds from config.toml, when configured.
    configured_bounds: Option<[u32; 4]>,
}

/// Where the index came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum IndexSource {
    /// `index.json` written by the app.
    File,
    /// Built by scanning `workouts/` (index absent or unreadable).
    Scan,
}

/// Result of scanning `workouts/`.
#[derive(Debug, Clone)]
pub struct Scan {
    pub index: Index,
    /// `(file name, error)` for files that did not parse.
    pub errors: Vec<(String, String)>,
}

/// A workout located through the index.
#[derive(Debug, Clone)]
pub struct Resolved {
    pub entry: IndexEntry,
    pub path: PathBuf,
}

/// Outcome of [`Store::rate_workout`].
#[derive(Debug, Clone, Serialize)]
pub struct RateOutcome {
    pub id: String,
    pub file: String,
    pub effort: u8,
    /// Always `ai`: the MCP and CLI only ever write ratings the athlete said.
    pub effort_source: String,
    pub feel: Option<String>,
    /// What the file carried before this call.
    pub previous_effort: Option<u8>,
    pub previous_source: Option<String>,
    pub index_updated: bool,
    pub summary: String,
}

/// One plan in [`Store::list_plans`].
#[derive(Debug, Clone, Serialize)]
pub struct PlanListEntry {
    pub id: String,
    pub name: String,
    pub sport: String,
    pub file: String,
    pub created_at: Option<DateTime<Utc>>,
    pub created_by: Option<String>,
    pub scheduled_for: Option<DateTime<Utc>>,
    /// `scheduled | failed | cancelled` from the status file, else `pending`.
    pub state: String,
    pub status: Option<PlanStatus>,
    pub planned_distance_m: f64,
    pub planned_time_s: f64,
}

/// One swim in the cardiac-cost trend.
#[derive(Debug, Clone, Serialize)]
pub struct CardiacTrendPoint {
    pub date: NaiveDate,
    pub id: String,
    pub name: String,
    pub activity: String,
    #[serde(flatten)]
    pub cost: CardiacCost,
}

/// Output of [`Store::training_summary`].
#[derive(Debug, Clone, Serialize)]
pub struct TrainingSummary {
    pub from: NaiveDate,
    pub to: NaiveDate,
    /// The bounds in use, `None` when neither config.toml nor profile.json gives any
    /// (zones then come from the workout files).
    pub zone_bounds: Option<[u32; 4]>,
    /// `config` or `estimated` (from the age in profile.json); `None` with `zone_bounds`.
    pub bounds_source: Option<derive::BoundsSource>,
    pub workouts_considered: usize,
    /// `days/<date>.json` files inside the window (0 before app v0.4).
    pub days_considered: usize,
    pub weeks: Vec<WeekSummary>,
    pub cardiac_cost_trend: Vec<CardiacTrendPoint>,
    pub notes: Vec<String>,
}

/// One file checked by [`Store::doctor`].
#[derive(Debug, Clone, Serialize)]
pub struct FileCheck {
    pub file: String,
    pub bytes: u64,
    pub ok: bool,
    pub schema: Option<String>,
    pub id: Option<String>,
    pub error: Option<String>,
}

/// Health of `index.json`.
#[derive(Debug, Clone, Serialize)]
pub struct IndexHealth {
    pub present: bool,
    pub parse_ok: bool,
    pub entries: usize,
    /// Index rows whose file does not exist.
    pub missing_files: Vec<String>,
    /// Workout files not listed in the index.
    pub unindexed_files: Vec<String>,
    pub error: Option<String>,
}

/// Output of [`Store::doctor`].
#[derive(Debug, Clone, Serialize)]
pub struct DoctorReport {
    pub dir: PathBuf,
    pub core_version: String,
    pub workouts_dir: bool,
    pub vitals_dir: bool,
    pub plans_dir: bool,
    pub index: IndexHealth,
    pub workouts: Vec<FileCheck>,
    pub schema_counts: BTreeMap<String, usize>,
    pub duplicates_dropped: Vec<String>,
    pub vitals: Vec<FileCheck>,
    pub plans: Vec<FileCheck>,
    pub plan_statuses: Vec<FileCheck>,
    /// `days/` exists (app v0.4).
    pub days_dir: bool,
    pub days: Vec<FileCheck>,
    /// `catalog.json`, when present.
    pub catalog: Option<FileCheck>,
    /// `profile.json`, when present.
    pub profile: Option<FileCheck>,
    /// `ecg/*.json` summaries (voltage sidecars are not parsed).
    pub ecgs: Vec<FileCheck>,
    /// The catalog compared with this build's identifier list, when a catalog exists.
    pub coverage: Option<Coverage>,
    /// `mcp/clients/*.json`, most recently seen first.
    pub clients: Vec<crate::handshake::ClientHandshake>,
    pub warnings: Vec<String>,
}

impl DoctorReport {
    /// `true` when nothing failed to parse. Coverage findings are warnings, not failures.
    pub fn healthy(&self) -> bool {
        self.workouts_dir
            && self.workouts.iter().all(|f| f.ok)
            && self.vitals.iter().all(|f| f.ok)
            && self.plans.iter().all(|f| f.ok)
            && self.plan_statuses.iter().all(|f| f.ok)
            && self.days.iter().all(|f| f.ok)
            && self.ecgs.iter().all(|f| f.ok)
            && self.catalog.as_ref().map(|f| f.ok).unwrap_or(true)
            && self.profile.as_ref().map(|f| f.ok).unwrap_or(true)
            && (!self.index.present || self.index.parse_ok)
    }
}

fn file_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// `index.json.file` as the app writes it: relative to the folder.
fn index_file_for(name: &str) -> String {
    format!("workouts/{name}")
}

/// A 1-to-10 score out of a raw JSON value (numbers of either kind; else `None`).
fn score_of(v: &Value) -> Option<u8> {
    let f = v.as_f64()?;
    (f.is_finite() && (0.0..=255.0).contains(&f.round())).then(|| f.round() as u8)
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

impl Store {
    /// Open a Health Access folder (must exist).
    pub fn open(dir: impl Into<PathBuf>) -> Result<Self> {
        let dir = dir.into();
        if !dir.is_dir() {
            return Err(Error::Config(format!(
                "{} is not a directory",
                dir.display()
            )));
        }
        Ok(Store {
            dir,
            configured_bounds: None,
        })
    }

    /// Use the zone bounds from config.toml (`None` when it names none).
    pub fn with_zone_bounds(mut self, bounds: Option<[u32; 4]>) -> Self {
        self.configured_bounds = bounds;
        self
    }

    /// The folder.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The zone bounds in use: config.toml when it names four values, else an estimate
    /// from the athlete's age in `profile.json`; `None` when neither exists (zones then
    /// come from the workout files, when they carry any).
    pub fn zone_bounds(&self) -> Option<[u32; 4]> {
        self.effective_bounds().map(|(b, _)| b)
    }

    /// Where [`Store::zone_bounds`] came from, when known.
    pub fn bounds_source(&self) -> Option<derive::BoundsSource> {
        self.effective_bounds().map(|(_, s)| s)
    }

    /// Bounds and their source, resolved now (`profile.json` is read on demand).
    pub fn effective_bounds(&self) -> Option<([u32; 4], derive::BoundsSource)> {
        if let Some(b) = self.configured_bounds {
            return Some((b, derive::BoundsSource::Config));
        }
        self.profile_age().map(|age| {
            (
                derive::estimate_bounds(age),
                derive::BoundsSource::Estimated,
            )
        })
    }

    /// The athlete's age from `profile.json`: `age`, else this year minus `birth_year`.
    fn profile_age(&self) -> Option<f64> {
        let profile = self.profile().ok().flatten()?;
        if let Some(age) = profile.age.filter(|a| *a > 0.0) {
            return Some(age);
        }
        let year = f64::from(chrono::Datelike::year(&Utc::now().date_naive()));
        profile
            .birth_year
            .filter(|b| *b > 1900.0 && *b <= year)
            .map(|b| year - b)
    }

    /// Zones of a workout as the Rust side sees them: computed from `hr_series` with the
    /// effective bounds (`bounds_source` config or estimated); without bounds, or without
    /// a series, the zones the file carries (`file`); `None` when there is neither.
    pub fn zones(&self, w: &Workout) -> Option<crate::model::Zones> {
        let from_file = || {
            w.zones.as_ref().map(|z| crate::model::Zones {
                bounds: z.bounds.clone(),
                bounds_source: Some(derive::BoundsSource::File.as_str().to_string()),
                seconds: z.seconds,
            })
        };
        match self.effective_bounds() {
            Some((bounds, source)) => derive::zones_for(w, &bounds)
                .map(|mut z| {
                    z.bounds_source = Some(source.as_str().to_string());
                    z
                })
                .or_else(from_file),
            None => from_file(),
        }
    }

    /// `workouts/`.
    pub fn workouts_dir(&self) -> PathBuf {
        self.dir.join("workouts")
    }

    /// `vitals/`.
    pub fn vitals_dir(&self) -> PathBuf {
        self.dir.join("vitals")
    }

    /// `plans/`.
    pub fn plans_dir(&self) -> PathBuf {
        self.dir.join("plans")
    }

    /// `index.json`.
    pub fn index_path(&self) -> PathBuf {
        self.dir.join("index.json")
    }

    // ------------------------------------------------------------ workouts

    /// Build an index by scanning `workouts/` (parse errors are collected, not fatal).
    pub fn scan(&self) -> Result<Scan> {
        let mut index = Index::empty();
        let mut errors = Vec::new();
        for path in json_files(&self.workouts_dir())? {
            let name = file_name(&path);
            match self.load_workout_file(&path) {
                Ok(w) => index
                    .workouts
                    .push(IndexEntry::from_workout(&w, &index_file_for(&name))),
                Err(e) => errors.push((name, e.to_string())),
            }
        }
        index.sort_newest_first();
        Ok(Scan { index, errors })
    }

    /// The index: `index.json` when present and readable, else a scan. Deduped,
    /// newest first. Returns where it came from.
    pub fn load_index(&self) -> Result<(Index, IndexSource)> {
        let path = self.index_path();
        if path.is_file() {
            if let Ok(mut idx) = read_json::<Index>(&path) {
                idx.dedupe();
                return Ok((idx, IndexSource::File));
            }
        }
        let mut idx = self.scan()?.index;
        idx.dedupe();
        Ok((idx, IndexSource::Scan))
    }

    /// The deduped index, newest first.
    pub fn index(&self) -> Result<Index> {
        self.load_index().map(|(i, _)| i)
    }

    /// Absolute path of an index row's file. Only `workouts/<name>` or a bare `<name>` is
    /// honoured; any other row (absolute, `..`, another folder) points at a name that
    /// never exists inside `workouts/`, so it cannot reach a file outside the folder.
    pub fn workout_path(&self, entry: &IndexEntry) -> PathBuf {
        let name = entry.file.strip_prefix("workouts/").unwrap_or(&entry.file);
        if is_plain_name(name) {
            self.workouts_dir().join(name)
        } else {
            self.workouts_dir().join(".refused-index-row")
        }
    }

    /// Find a workout by full id, id prefix (≥ 4 chars, e.g. the `uuid8` in the
    /// file name), file name, or path.
    ///
    /// The index (`index.json`, or a scan when it is absent) is consulted first. When
    /// it does not know the id — the app's index can lag behind iCloud, skip files it
    /// could not read, or hide a dedupe twin — `workouts/` is scanned, so every read
    /// *and* write path (`show`, `get_workout`, `rate_workout`, …) resolves the same
    /// set of files.
    pub fn resolve(&self, id_or_file: &str) -> Result<Resolved> {
        let q = id_or_file.trim();
        if q.is_empty() {
            return Err(Error::NotFound("empty id".into()));
        }
        if q.ends_with(".json") || q.contains('/') {
            return self.resolve_file(q);
        }
        if let Some(found) = self.resolve_in(&self.index()?, q)? {
            return Ok(found);
        }
        // not in the index: the files on disk are the truth
        if let Some(found) = self.resolve_in(&self.scan()?.index, q)? {
            return Ok(found);
        }
        Err(Error::NotFound(format!("workout {q}")))
    }

    /// Resolve a file name or path: through the index row when listed, else straight
    /// from disk (no index needed).
    fn resolve_file(&self, q: &str) -> Result<Resolved> {
        let rel = q.strip_prefix("workouts/").unwrap_or(q);
        let name = if is_plain_name(rel) {
            rel.to_string()
        } else {
            // A path typed on the command line: accepted only when it is a file directly
            // inside workouts/ (after resolving symlinks and `..`).
            let typed = Path::new(q);
            let typed = if typed.is_absolute() {
                typed.to_path_buf()
            } else {
                self.dir.join(typed)
            };
            match (typed.canonicalize(), self.workouts_dir().canonicalize()) {
                (Ok(c), Ok(w)) if c.parent() == Some(w.as_path()) => file_name(&c),
                _ => {
                    return Err(Error::NotFound(format!(
                        "workout file {q} (only files inside workouts/ are read)"
                    )))
                }
            }
        };
        let path = self.workouts_dir().join(&name);
        if let Some(entry) = self
            .index()?
            .workouts
            .iter()
            .find(|e| file_name(Path::new(&e.file)) == name)
        {
            return Ok(Resolved {
                path: self.workout_path(entry),
                entry: entry.clone(),
            });
        }
        if path.is_file() {
            let w = self.load_workout_file(&path)?;
            return Ok(Resolved {
                entry: IndexEntry::from_workout(&w, &index_file_for(&name)),
                path,
            });
        }
        Err(Error::NotFound(format!("workout file {q}")))
    }

    /// Match `q` (full id or prefix, case-insensitive) against the rows of `index`.
    /// `Ok(None)` when nothing matches; `Ambiguous` when several rows match and none
    /// is the exact id.
    fn resolve_in(&self, index: &Index, q: &str) -> Result<Option<Resolved>> {
        let upper = q.to_ascii_uppercase();
        let matches: Vec<&IndexEntry> = index
            .workouts
            .iter()
            .filter(|e| {
                e.id.to_ascii_uppercase().starts_with(&upper)
                    || e.file.to_ascii_uppercase().contains(&format!("_{upper}"))
            })
            .collect();
        let pick = |e: &IndexEntry| Resolved {
            entry: e.clone(),
            path: self.workout_path(e),
        };
        match matches.as_slice() {
            [] => Ok(None),
            [one] => Ok(Some(pick(one))),
            many => {
                // exact id wins over prefix matches
                if let Some(exact) = many.iter().find(|e| e.id.eq_ignore_ascii_case(q)) {
                    return Ok(Some(pick(exact)));
                }
                Err(Error::Ambiguous {
                    id: q.to_string(),
                    matches: many.iter().map(|e| e.id.clone()).collect(),
                })
            }
        }
    }

    /// Parse one workout file (v0 or v1) without plan enrichment.
    pub fn load_workout_file(&self, path: &Path) -> Result<Workout> {
        let text = read_to_string(path)?;
        parse_workout(&text).map_err(|e| match e {
            Error::Json { source, .. } => Error::json(path, source),
            other => other,
        })
    }

    /// Load a workout by id / file and join plan labels and kinds when a plan matches.
    pub fn load_workout(&self, id_or_file: &str) -> Result<Workout> {
        let resolved = self.resolve(id_or_file)?;
        let mut w = self.load_workout_file(&resolved.path)?;
        self.enrich_with_plan(&mut w);
        Ok(w)
    }

    /// Load every workout in the deduped index whose start is on/after `since`,
    /// oldest first. Unreadable files are skipped and reported in `warnings`.
    pub fn load_workouts_since(
        &self,
        since: DateTime<Utc>,
        warnings: &mut Vec<String>,
    ) -> Result<Vec<Workout>> {
        let index = self.index()?;
        let mut out = Vec::new();
        for entry in index.workouts.iter().filter(|e| e.start >= since) {
            match self.load_workout_file(&self.workout_path(entry)) {
                Ok(mut w) => {
                    self.enrich_with_plan(&mut w);
                    out.push(w);
                }
                Err(e) => warnings.push(format!("skipped {}: {e}", entry.file)),
            }
        }
        out.sort_by_key(|w| w.start);
        Ok(out)
    }

    /// Match the workout to a plan (by `plan_ref.plan_id`, else by `scheduled_for`
    /// within ±2 h and the same sport) and fill step labels and kinds from it.
    pub fn enrich_with_plan(&self, w: &mut Workout) {
        let Ok(plans) = self.list_plans_full() else {
            return;
        };
        if plans.is_empty() {
            return;
        }
        let sport = match w.activity.as_str() {
            "pool_swim" | "open_water_swim" => "pool_swim",
            "indoor_row" => "indoor_row",
            _ => return,
        };
        let by_id = w
            .plan_ref
            .as_ref()
            .and_then(|r| r.plan_id.as_deref())
            .and_then(|id| plans.iter().find(|(p, _)| p.id == id));
        let plan = match by_id {
            Some((p, _)) => p,
            None => {
                let window = Duration::hours(PLAN_MATCH_WINDOW_H);
                let max_block = w.steps.iter().map(|s| s.block).max().unwrap_or(0);
                let Some((p, _)) = plans
                    .iter()
                    .filter(|(p, _)| p.sport == sport)
                    .filter(|(p, _)| max_block <= p.blocks.len() as u32 + 1)
                    .filter_map(|pp| {
                        let sf = pp.0.scheduled_for?;
                        let diff = (sf - w.start).num_seconds().abs();
                        (diff <= window.num_seconds()).then_some((pp, diff))
                    })
                    .min_by_key(|(_, diff)| *diff)
                    .map(|(pp, _)| pp)
                else {
                    return;
                };
                p
            }
        };
        for step in &mut w.steps {
            if let Some((ps, kind)) = plan.step_for_key(step.block, step.step) {
                step.kind = kind;
                if step.label.is_none() {
                    step.label = ps.label.clone();
                }
            }
        }
        let pr = w.plan_ref.get_or_insert_with(PlanRef::default);
        if pr.plan_id.is_none() {
            pr.plan_id = Some(plan.id.clone());
        }
        if pr.name.is_none() {
            pr.name = Some(plan.name.clone());
        }
    }

    /// One-line LLM summary of a workout with the store's zones.
    pub fn summary(&self, w: &Workout) -> String {
        derive::summary_line(w, self.zones(w).as_ref())
    }

    /// Write `effort` (1 to 10), `effort_source: "ai"` and, when given, `feel` into
    /// the workout file, nothing else, atomically (temp file + rename), then update
    /// the matching row of `index.json` if that file exists.
    ///
    /// A file that already carries the athlete's own rating from Apple
    /// (`effort_source: "apple"`) is refused unless `override_apple` is set: the
    /// number the athlete entered on the Watch wins over anything an AI heard later,
    /// unless the athlete asks to change it.
    pub fn rate_workout(
        &self,
        id_or_file: &str,
        effort: u8,
        feel: Option<&str>,
        override_apple: bool,
    ) -> Result<RateOutcome> {
        let mut problems = Vec::new();
        if !(1..=10).contains(&effort) {
            problems.push(format!("effort must be 1 to 10, got {effort}"));
        }
        if let Some(f) = feel {
            if f.chars().count() > 500 {
                problems.push("feel must be at most 500 characters".to_string());
            }
        }
        if !problems.is_empty() {
            return Err(Error::Validation(problems));
        }
        let resolved = self.resolve(id_or_file)?;
        let path = &resolved.path;
        let text = read_to_string(path)?;
        // only ever write into a file that is a workout
        parse_workout(&text).map_err(|e| match e {
            Error::Json { source, .. } => Error::json(path, source),
            other => other,
        })?;
        let mut doc: Value = serde_json::from_str(&text).map_err(|e| Error::json(path, e))?;
        let obj = doc
            .as_object_mut()
            .ok_or_else(|| Error::Schema(format!("{} is not a JSON object", path.display())))?;
        let previous_effort = obj.get("effort").and_then(score_of);
        let previous_source = obj
            .get("effort_source")
            .and_then(Value::as_str)
            .map(str::to_string);
        let apple_rated = previous_effort.is_some()
            && previous_source.as_deref().and_then(EffortSource::parse)
                == Some(EffortSource::Apple);
        if apple_rated && !override_apple {
            return Err(Error::Refused(format!(
                "{} already has the athlete's own effort rating from Apple: {}/10. Keep it. \
                 If the athlete asks to change it, call again with override set to true.",
                file_name(path),
                previous_effort.unwrap_or_default()
            )));
        }
        obj.insert("effort".to_string(), Value::from(effort));
        obj.insert(
            "effort_source".to_string(),
            Value::from(EffortSource::Ai.as_str()),
        );
        if let Some(f) = feel {
            obj.insert("feel".to_string(), Value::from(f.trim()));
        }
        let out = if looks_pretty(&text) {
            let mut s = serde_json::to_string_pretty(&doc).map_err(|e| Error::json(path, e))?;
            s.push('\n');
            s
        } else {
            serde_json::to_string(&doc).map_err(|e| Error::json(path, e))?
        };
        atomic_write(path, out.as_bytes())?;

        let index_updated = self.update_index_effort(&resolved.entry.id, effort)?;
        let w = self.load_workout_file(path)?;
        Ok(RateOutcome {
            id: w.id.clone(),
            file: file_name(path),
            effort,
            effort_source: EffortSource::Ai.as_str().to_string(),
            feel: w.feel.clone(),
            previous_effort,
            previous_source,
            index_updated,
            summary: self.summary(&w),
        })
    }

    fn update_index_effort(&self, id: &str, effort: u8) -> Result<bool> {
        let path = self.index_path();
        if !path.is_file() {
            return Ok(false);
        }
        let text = read_to_string(&path)?;
        let mut doc: Value = serde_json::from_str(&text).map_err(|e| Error::json(&path, e))?;
        let mut touched = false;
        if let Some(rows) = doc.get_mut("workouts").and_then(Value::as_array_mut) {
            for row in rows.iter_mut() {
                let same = row
                    .get("id")
                    .and_then(Value::as_str)
                    .map(|s| s.eq_ignore_ascii_case(id))
                    .unwrap_or(false);
                if same {
                    if let Some(o) = row.as_object_mut() {
                        o.insert("effort".to_string(), Value::from(effort));
                        // the app owns the row's shape: only update a key that is there
                        if o.contains_key("effort_source") {
                            o.insert(
                                "effort_source".to_string(),
                                Value::from(EffortSource::Ai.as_str()),
                            );
                        }
                        touched = true;
                    }
                }
            }
        }
        if !touched {
            return Ok(false);
        }
        let out = if looks_pretty(&text) {
            let mut s = serde_json::to_string_pretty(&doc).map_err(|e| Error::json(&path, e))?;
            s.push('\n');
            s
        } else {
            serde_json::to_string(&doc).map_err(|e| Error::json(&path, e))?
        };
        atomic_write(&path, out.as_bytes())?;
        Ok(true)
    }

    // ------------------------------------------------------------ vitals

    /// Vitals for the last `days` days, oldest first. Reads `days/<date>.json` (app
    /// v0.4) mapped onto the seven-metric view and `vitals/<date>.json` (the earlier
    /// file, kept readable as an alias). When both exist for a date the day file wins
    /// and the old file only fills values the day file lacks.
    pub fn vitals(&self, days: u32) -> Result<Vec<Vitals>> {
        self.vitals_at(days, Utc::now().date_naive())
    }

    /// [`Store::vitals`] with an explicit "today" (the last day of the window).
    pub fn vitals_at(&self, days: u32, today: NaiveDate) -> Result<Vec<Vitals>> {
        let cutoff = today - Duration::days(i64::from(days.max(1)) - 1);
        let mut by_date: BTreeMap<NaiveDate, Vitals> = BTreeMap::new();
        for path in json_files(&self.vitals_dir())? {
            if let Ok(v) = read_json::<Vitals>(&path) {
                if v.date >= cutoff {
                    by_date.insert(v.date, v);
                }
            }
        }
        for day in self.days(cutoff, NaiveDate::MAX)? {
            let fresh = day.vitals();
            let merged = match by_date.remove(&day.date) {
                Some(old) => Vitals {
                    schema: fresh.schema.or(old.schema),
                    date: day.date,
                    resting_hr: fresh.resting_hr.or(old.resting_hr),
                    hrv_sdnn_ms: fresh.hrv_sdnn_ms.or(old.hrv_sdnn_ms),
                    body_mass_kg: fresh.body_mass_kg.or(old.body_mass_kg),
                    sleep_s: fresh.sleep_s.or(old.sleep_s),
                    steps: fresh.steps.or(old.steps),
                    vo2max: fresh.vo2max.or(old.vo2max),
                    bp: fresh.bp.or(old.bp),
                },
                None => fresh,
            };
            by_date.insert(day.date, merged);
        }
        Ok(by_date.into_values().collect())
    }

    // ------------------------------------------------------------ plans

    /// `plans/<id>.json`.
    pub fn plan_path(&self, id: &str) -> PathBuf {
        self.plans_dir().join(format!("{id}.json"))
    }

    /// `plans/<id>.status.json`.
    pub fn plan_status_path(&self, id: &str) -> PathBuf {
        self.plans_dir().join(format!("{id}.status.json"))
    }

    /// Validate, finalize (`id`, `schema`, `created_*`) and write `plans/<id>.json`.
    pub fn write_plan(&self, mut plan: Plan, created_by_default: &str) -> Result<(Plan, PathBuf)> {
        plan.finalize(created_by_default, Utc::now());
        plan.validate()?;
        check_plan_id(&plan.id)?;
        let dir = self.plans_dir();
        fs::create_dir_all(&dir).map_err(|e| Error::io(&dir, e))?;
        let path = self.plan_path(&plan.id);
        if path.exists() {
            return Err(Error::Validation(vec![format!(
                "plan {} already exists",
                plan.id
            )]));
        }
        atomic_write(&path, to_sorted_pretty_json(&plan)?.as_bytes())?;
        Ok((plan, path))
    }

    /// Load one plan by id.
    pub fn plan(&self, id: &str) -> Result<Plan> {
        check_plan_id(id)?;
        let path = self.plan_path(id);
        if !path.is_file() {
            return Err(Error::NotFound(format!("plan {id}")));
        }
        read_json(&path)
    }

    /// Status of a plan: `Ok(None)` when the app has not written one yet; `NotFound`
    /// when the plan itself does not exist.
    pub fn plan_status(&self, id: &str) -> Result<Option<PlanStatus>> {
        check_plan_id(id)?;
        if !self.plan_path(id).is_file() {
            return Err(Error::NotFound(format!("plan {id}")));
        }
        let path = self.plan_status_path(id);
        if !path.is_file() {
            return Ok(None);
        }
        read_json(&path).map(Some)
    }

    fn list_plans_full(&self) -> Result<Vec<(Plan, PathBuf)>> {
        let mut out = Vec::new();
        for path in json_files(&self.plans_dir())? {
            if file_name(&path).ends_with(".status.json") {
                continue;
            }
            if let Ok(p) = read_json::<Plan>(&path) {
                out.push((p, path));
            }
        }
        Ok(out)
    }

    /// All plans with their status, newest `scheduled_for` / `created_at` first.
    pub fn list_plans(&self) -> Result<Vec<PlanListEntry>> {
        let mut out: Vec<PlanListEntry> = self
            .list_plans_full()?
            .into_iter()
            .map(|(p, path)| {
                let status = read_json::<PlanStatus>(&self.plan_status_path(&p.id)).ok();
                PlanListEntry {
                    state: status
                        .as_ref()
                        .map(|s| s.state.clone())
                        .unwrap_or_else(|| "pending".into()),
                    status,
                    file: file_name(&path),
                    planned_distance_m: p.planned_distance_m(),
                    planned_time_s: p.planned_time_s(),
                    id: p.id,
                    name: p.name,
                    sport: p.sport,
                    created_at: p.created_at,
                    created_by: p.created_by,
                    scheduled_for: p.scheduled_for,
                }
            })
            .collect();
        out.sort_by(|a, b| {
            b.scheduled_for
                .or(b.created_at)
                .cmp(&a.scheduled_for.or(a.created_at))
                .then_with(|| b.id.cmp(&a.id))
        });
        Ok(out)
    }

    // ------------------------------------------------------------ summaries

    /// Weekly volume for the last `weeks` ISO weeks plus the cardiac-cost trend.
    pub fn training_summary(&self, weeks: u32) -> Result<TrainingSummary> {
        self.training_summary_at(weeks, Utc::now().date_naive())
    }

    /// [`Store::training_summary`] with an explicit "today" (the last week shown).
    pub fn training_summary_at(&self, weeks: u32, today: NaiveDate) -> Result<TrainingSummary> {
        let weeks = weeks.clamp(1, 104);
        let first = derive::week_start(today) - Duration::weeks(i64::from(weeks) - 1);
        let since = first
            .and_hms_opt(0, 0, 0)
            .map(|d| d.and_utc())
            .unwrap_or_else(Utc::now);
        let mut notes = Vec::new();
        let workouts = self.load_workouts_since(since, &mut notes)?;
        let to = derive::week_start(today) + Duration::days(6);
        let days = self.days(first, to)?;
        let effective = self.effective_bounds();
        let weeks_out =
            derive::weekly_summaries(&workouts, &days, weeks, today, &|w| self.zones(w));
        let trend = workouts
            .iter()
            .filter_map(|w| {
                derive::cardiac_cost(w).map(|cost| CardiacTrendPoint {
                    date: w.start.date_naive(),
                    id: w.id.clone(),
                    name: w.display_name(),
                    activity: w.activity.clone(),
                    cost,
                })
            })
            .collect();
        notes.push("cardiac cost = avg_hr × best freestyle 100 m pace (s) / 60 = heart beats per 100 m; lower is better".into());
        if !days.is_empty() {
            notes.push("rings and mean_physical_effort_met come from days/<date>.json (activity.rings, activity.physical_effort_avg_met); mean_effort is the athlete's rating of sessions, any source".into());
        }
        notes.push(match effective {
            Some((bounds, source)) => format!(
                "Z1–2 % uses zone bounds {:?} ({}): each HR sample's time until the next sample goes to its zone, within the workout, gaps capped at {} s",
                bounds,
                match source {
                    derive::BoundsSource::Config => "from config.toml",
                    derive::BoundsSource::Estimated => "estimated from the age in profile.json, 208 - 0.7 x age, bounds at 72/79/86/92 %",
                    derive::BoundsSource::File => "from the workout files",
                },
                derive::MAX_GAP_S
            ),
            None => "no zone bounds known: set zones in config.toml or let the app write profile.json (age); Z1–2 % uses the zones a workout file carries, when any".to_string(),
        });
        Ok(TrainingSummary {
            from: first,
            to: derive::week_start(today) + Duration::days(6),
            zone_bounds: effective.map(|(b, _)| b),
            bounds_source: effective.map(|(_, s)| s),
            workouts_considered: workouts.len(),
            days_considered: days.len(),
            weeks: weeks_out,
            cardiac_cost_trend: trend,
            notes,
        })
    }

    // ------------------------------------------------------------ doctor

    fn check_json<T: serde::de::DeserializeOwned>(
        path: &Path,
        id_of: impl Fn(&T) -> Option<String>,
        schema_of: impl Fn(&T) -> Option<String>,
    ) -> FileCheck {
        let bytes = fs::metadata(path).map(|m| m.len()).unwrap_or(0);
        match read_json::<T>(path) {
            Ok(v) => FileCheck {
                file: file_name(path),
                bytes,
                ok: true,
                schema: schema_of(&v),
                id: id_of(&v),
                error: None,
            },
            Err(e) => FileCheck {
                file: file_name(path),
                bytes,
                ok: false,
                schema: None,
                id: None,
                error: Some(e.to_string()),
            },
        }
    }

    /// Check the folder: directories, index consistency, every JSON file, schema versions.
    pub fn doctor(&self) -> Result<DoctorReport> {
        let mut warnings = Vec::new();
        let mut schema_counts: BTreeMap<String, usize> = BTreeMap::new();
        let mut workouts = Vec::new();
        for path in json_files(&self.workouts_dir())? {
            let bytes = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
            let check = match read_to_string(&path) {
                Err(e) => FileCheck {
                    file: file_name(&path),
                    bytes,
                    ok: false,
                    schema: None,
                    id: None,
                    error: Some(e.to_string()),
                },
                Ok(text) => {
                    // report the tag as written (pre-rename files say `tide.workout.v*`)
                    let schema = schema_tag(&text)
                        .or_else(|| detect_schema(&text).ok().map(|s| s.to_string()));
                    match parse_workout(&text) {
                        Ok(w) => {
                            if w.duration_s <= 0.0 {
                                warnings.push(format!(
                                    "{}: duration_s is {}",
                                    file_name(&path),
                                    w.duration_s
                                ));
                            }
                            FileCheck {
                                file: file_name(&path),
                                bytes,
                                ok: true,
                                schema,
                                id: Some(w.id),
                                error: None,
                            }
                        }
                        Err(e) => FileCheck {
                            file: file_name(&path),
                            bytes,
                            ok: false,
                            schema,
                            id: None,
                            error: Some(e.to_string()),
                        },
                    }
                }
            };
            if let Some(s) = &check.schema {
                *schema_counts.entry(s.clone()).or_default() += 1;
            } else {
                *schema_counts.entry("unknown".into()).or_default() += 1;
            }
            workouts.push(check);
        }

        let index_path = self.index_path();
        let mut index = IndexHealth {
            present: index_path.is_file(),
            parse_ok: false,
            entries: 0,
            missing_files: Vec::new(),
            unindexed_files: Vec::new(),
            error: None,
        };
        if index.present {
            match read_json::<Index>(&index_path) {
                Ok(idx) => {
                    index.parse_ok = true;
                    index.entries = idx.workouts.len();
                    let on_disk: Vec<String> = workouts.iter().map(|w| w.file.clone()).collect();
                    for e in &idx.workouts {
                        if !self.workout_path(e).is_file() {
                            index.missing_files.push(e.file.clone());
                        }
                    }
                    let listed: Vec<String> = idx
                        .workouts
                        .iter()
                        .map(|e| file_name(Path::new(&e.file)))
                        .collect();
                    index.unindexed_files = on_disk
                        .into_iter()
                        .filter(|f| !listed.contains(f))
                        .collect();
                }
                Err(e) => {
                    index.error = Some(e.to_string());
                    warnings.push(format!("index.json unreadable, falling back to scan: {e}"));
                }
            }
        }

        // duplicates hidden by the contract rule, from a raw scan; the app leaves the
        // shorter duplicate out of index.json on purpose, so it is not "unindexed"
        let raw = self.scan()?;
        let duplicates_dropped = {
            let mut raw_idx = raw.index.clone();
            raw_idx.dedupe()
        };
        let dropped_files: Vec<String> = raw
            .index
            .workouts
            .iter()
            .filter(|e| duplicates_dropped.contains(&e.id))
            .map(|e| file_name(Path::new(&e.file)))
            .collect();
        index.unindexed_files.retain(|f| !dropped_files.contains(f));

        let vitals = json_files(&self.vitals_dir())?
            .iter()
            .map(|p| {
                Self::check_json::<Vitals>(p, |v| Some(v.date.to_string()), |v| v.schema.clone())
            })
            .collect();
        let mut plans = Vec::new();
        let mut plan_statuses = Vec::new();
        for p in json_files(&self.plans_dir())? {
            if file_name(&p).ends_with(".status.json") {
                plan_statuses.push(Self::check_json::<PlanStatus>(
                    &p,
                    |s| Some(s.plan_id.clone()),
                    |_| None,
                ));
            } else {
                plans.push(Self::check_json::<Plan>(
                    &p,
                    |pl| Some(pl.id.clone()),
                    |pl| Some(pl.schema.clone()),
                ));
            }
        }

        let days: Vec<FileCheck> = json_files(&self.days_dir())?
            .iter()
            .map(|p| Self::check_json::<Day>(p, |d| Some(d.date.to_string()), |d| d.schema.clone()))
            .collect();
        let catalog = self
            .catalog_path()
            .is_file()
            .then(|| Self::check_json::<Catalog>(&self.catalog_path(), |_| None, |_| None));
        let profile = self
            .profile_path()
            .is_file()
            .then(|| Self::check_json::<Profile>(&self.profile_path(), |_| None, |_| None));
        let ecgs: Vec<FileCheck> = json_files(&self.ecg_dir())?
            .iter()
            .filter(|p| !file_name(p).ends_with(".voltage.json"))
            .map(|p| Self::check_json::<Value>(p, |_| None, |_| None))
            .collect();
        let coverage = match &catalog {
            Some(c) if c.ok => self.coverage()?,
            _ => None,
        };
        if let Some(c) = &coverage {
            if !c.types_with_data_not_exported.is_empty() {
                warnings.push(format!(
                    "coverage: {} type(s) with data that the app exported nowhere: {}",
                    c.types_with_data_not_exported.len(),
                    c.types_with_data_not_exported.join(", ")
                ));
            }
            if !c.unknown_types_with_data.is_empty() {
                warnings.push(format!(
                    "coverage: {} type(s) with data not known to this build ({}): {}",
                    c.unknown_types_with_data.len(),
                    c.sdk,
                    c.unknown_types_with_data.join(", ")
                ));
            }
        }

        Ok(DoctorReport {
            dir: self.dir.clone(),
            core_version: crate::VERSION.to_string(),
            workouts_dir: self.workouts_dir().is_dir(),
            vitals_dir: self.vitals_dir().is_dir(),
            plans_dir: self.plans_dir().is_dir(),
            index,
            workouts,
            schema_counts,
            duplicates_dropped,
            vitals,
            plans,
            plan_statuses,
            days_dir: self.days_dir().is_dir(),
            days,
            catalog,
            profile,
            ecgs,
            coverage,
            clients: self.list_clients().unwrap_or_default(),
            warnings,
        })
    }
}

/// A plan id names one file in `plans/`: a plain name of at most 128 characters.
fn check_plan_id(id: &str) -> Result<()> {
    if is_plain_name(id) && id.chars().count() <= 128 {
        Ok(())
    } else {
        Err(Error::Validation(vec![format!(
            "{id:?} is not a plan id (one name, no folders, at most 128 characters)"
        )]))
    }
}
