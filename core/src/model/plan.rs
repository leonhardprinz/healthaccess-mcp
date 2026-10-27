//! `plans/<plan_id>.json` (written by MCP/CLI, consumed by the app) and
//! `plans/<plan_id>.status.json` (written by the app).

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::util::slug;
use crate::{Error, Result};

/// Schema tag of a plan file.
pub const SCHEMA_PLAN: &str = "healthaccess.plan.v1";
/// Pre-rename tag of a plan file, accepted forever as an alias of [`SCHEMA_PLAN`].
pub const SCHEMA_PLAN_LEGACY: &str = "tide.plan.v1";
/// Sports a plan can have: each maps to a WorkoutKit custom-workout activity and location
/// in the app (`PlanInstaller.activity(for:)`).
pub const SPORTS: [&str; 11] = [
    "run",
    "indoor_run",
    "walk",
    "hike",
    "cycle",
    "indoor_cycle",
    "pool_swim",
    "open_water_swim",
    "indoor_row",
    "hiit",
    "elliptical",
];
/// Sports whose steps take time goals only (the Watch measures no distance for them).
pub const TIME_ONLY_SPORTS: [&str; 2] = ["hiit", "elliptical"];
/// Maximum label length shown on the Watch.
pub const MAX_LABEL_CHARS: usize = 40;
/// Maximum plan name length (same Watch constraint).
pub const MAX_NAME_CHARS: usize = 40;

/// A structured workout plan. Fields the writer fills (`schema`, `id`,
/// `created_at`, `created_by`) are optional on input.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Plan {
    #[serde(default)]
    pub schema: String,
    #[serde(default)]
    pub id: String,
    pub name: String,
    /// One of [`SPORTS`]: `run | indoor_run | walk | hike | cycle | indoor_cycle | pool_swim |
    /// open_water_swim | indoor_row | hiit | elliptical`.
    pub sport: String,
    #[serde(default)]
    pub pool_length_m: Option<f64>,
    #[serde(default)]
    pub warmup: Option<PlanStep>,
    #[serde(default)]
    pub blocks: Vec<PlanBlock>,
    #[serde(default)]
    pub cooldown: Option<PlanStep>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub created_by: Option<String>,
    #[serde(default)]
    pub created_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub scheduled_for: Option<DateTime<Utc>>,
}

/// A repeated group of steps.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlanBlock {
    #[serde(default = "one")]
    pub repeat: u32,
    pub steps: Vec<PlanStep>,
}

fn one() -> u32 {
    1
}

/// One step of a plan.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlanStep {
    /// `work | recovery` (ignored for warm-up / cool-down; defaults to work).
    #[serde(default)]
    pub kind: Option<String>,
    pub goal: Goal,
    /// Watch HR zone 1–5 to alert on.
    #[serde(default)]
    pub zone: Option<u8>,
    #[serde(default)]
    pub label: Option<String>,
}

/// Step goal.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Goal {
    /// `time_s | distance_m`.
    #[serde(rename = "type")]
    pub kind: String,
    pub value: f64,
}

impl Goal {
    /// A time goal.
    pub fn time(seconds: f64) -> Self {
        Goal {
            kind: "time_s".into(),
            value: seconds,
        }
    }

    /// A distance goal.
    pub fn distance(metres: f64) -> Self {
        Goal {
            kind: "distance_m".into(),
            value: metres,
        }
    }

    /// `true` for a time goal.
    pub fn is_time(&self) -> bool {
        self.kind == "time_s"
    }
}

impl PlanStep {
    /// `true` when the step is a recovery step.
    pub fn is_recovery(&self) -> bool {
        self.kind.as_deref() == Some("recovery")
    }

    /// Compact one-line rendering, e.g. `4×50 m` style pieces are rendered per step.
    pub fn describe(&self) -> String {
        let goal = if self.goal.is_time() {
            crate::util::fmt_duration(self.goal.value)
        } else {
            format!("{} m", crate::util::round_to(self.goal.value, 1))
        };
        let mut s = goal;
        if let Some(z) = self.zone {
            s.push_str(&format!(" Z{z}"));
        }
        if let Some(l) = &self.label {
            s.push_str(&format!(" \"{l}\""));
        }
        s
    }
}

/// Largest distance goal of one step (1000 km); keeps hostile numbers out of the app.
pub const MAX_GOAL_DISTANCE_M: f64 = 1_000_000.0;
/// Largest time goal of one step (24 hours).
pub const MAX_GOAL_TIME_S: f64 = 86_400.0;

fn check_step(prefix: &str, step: &PlanStep, problems: &mut Vec<String>) {
    if step.goal.kind != "time_s" && step.goal.kind != "distance_m" {
        problems.push(format!(
            "{prefix}: goal.type must be time_s or distance_m, got {:?}",
            step.goal.kind
        ));
    }
    if !(step.goal.value.is_finite() && step.goal.value > 0.0) {
        problems.push(format!("{prefix}: goal.value must be a positive number"));
    } else if step.goal.kind == "distance_m" && step.goal.value > MAX_GOAL_DISTANCE_M {
        problems.push(format!(
            "{prefix}: a distance goal is at most {MAX_GOAL_DISTANCE_M} m"
        ));
    } else if step.goal.kind == "time_s" && step.goal.value > MAX_GOAL_TIME_S {
        problems.push(format!(
            "{prefix}: a time goal is at most {MAX_GOAL_TIME_S} s (24 hours)"
        ));
    }
    if let Some(z) = step.zone {
        if !(1..=5).contains(&z) {
            problems.push(format!("{prefix}: zone must be 1–5, got {z}"));
        }
    }
    if let Some(label) = &step.label {
        let n = label.chars().count();
        if n > MAX_LABEL_CHARS {
            problems.push(format!(
                "{prefix}: label is {n} chars, max {MAX_LABEL_CHARS}"
            ));
        }
    }
    if let Some(kind) = &step.kind {
        if kind != "work" && kind != "recovery" {
            problems.push(format!(
                "{prefix}: kind must be work or recovery, got {kind:?}"
            ));
        }
    }
}

impl Plan {
    /// Validate against the contract. Every problem is reported at once.
    pub fn validate(&self) -> Result<()> {
        let mut problems = Vec::new();
        let name_len = self.name.trim().chars().count();
        if name_len == 0 {
            problems.push("name must not be empty".to_string());
        } else if name_len > MAX_NAME_CHARS {
            problems.push(format!("name is {name_len} chars, max {MAX_NAME_CHARS}"));
        }
        if !SPORTS.contains(&self.sport.as_str()) {
            problems.push(format!(
                "sport must be one of {}, got {:?}",
                SPORTS.join(", "),
                self.sport
            ));
        }
        if TIME_ONLY_SPORTS.contains(&self.sport.as_str()) {
            let mut steps: Vec<(String, &PlanStep)> = Vec::new();
            if let Some(w) = &self.warmup {
                steps.push(("warmup".to_string(), w));
            }
            for (bi, b) in self.blocks.iter().enumerate() {
                for (si, s) in b.steps.iter().enumerate() {
                    steps.push((format!("blocks[{bi}].steps[{si}]"), s));
                }
            }
            if let Some(c) = &self.cooldown {
                steps.push(("cooldown".to_string(), c));
            }
            for (at, s) in steps {
                if !s.goal.is_time() {
                    problems.push(format!(
                        "{at}: {} takes time goals only (time_s), got {}",
                        self.sport, s.goal.kind
                    ));
                }
            }
        }
        if let Some(p) = self.pool_length_m {
            if !(p.is_finite() && p > 0.0 && p <= 100.0) {
                problems.push("pool_length_m must be a number from 1 to 100".to_string());
            }
        }
        if !self.schema.is_empty()
            && self.schema != SCHEMA_PLAN
            && self.schema != SCHEMA_PLAN_LEGACY
        {
            problems.push(format!(
                "schema must be {SCHEMA_PLAN}, got {:?}",
                self.schema
            ));
        }
        if let Some(w) = &self.warmup {
            check_step("warmup", w, &mut problems);
        }
        if let Some(c) = &self.cooldown {
            check_step("cooldown", c, &mut problems);
        }
        if self.blocks.is_empty() {
            problems.push("blocks must contain at least one block".to_string());
        }
        for (bi, block) in self.blocks.iter().enumerate() {
            if !(1..=99).contains(&block.repeat) {
                problems.push(format!(
                    "blocks[{bi}]: repeat must be 1–99, got {}",
                    block.repeat
                ));
            }
            if block.steps.is_empty() {
                problems.push(format!("blocks[{bi}]: steps must not be empty"));
            }
            for (si, step) in block.steps.iter().enumerate() {
                check_step(&format!("blocks[{bi}].steps[{si}]"), step, &mut problems);
            }
        }
        if problems.is_empty() {
            Ok(())
        } else {
            Err(Error::Validation(problems))
        }
    }

    /// Build the contract id: `<RFC3339 UTC seconds>-<slug(name)>`.
    pub fn make_id(name: &str, at: DateTime<Utc>) -> String {
        format!("{}-{}", at.format("%Y-%m-%dT%H:%M:%SZ"), slug(name))
    }

    /// Fill `schema`, `id`, `created_at`, `created_by` when missing. A pre-rename
    /// `schema` tag is upgraded to [`SCHEMA_PLAN`]; the app accepts both.
    pub fn finalize(&mut self, created_by_default: &str, now: DateTime<Utc>) {
        if self.schema.is_empty() || self.schema == SCHEMA_PLAN_LEGACY {
            self.schema = SCHEMA_PLAN.to_string();
        }
        if self.id.trim().is_empty() {
            self.id = Plan::make_id(&self.name, now);
        }
        if self.created_at.is_none() {
            self.created_at = Some(now);
        }
        if self
            .created_by
            .as_deref()
            .map(str::is_empty)
            .unwrap_or(true)
        {
            self.created_by = Some(created_by_default.to_string());
        }
    }

    /// Total planned distance in metres (distance goals only), including repeats.
    pub fn planned_distance_m(&self) -> f64 {
        let step_d = |s: &PlanStep| if s.goal.is_time() { 0.0 } else { s.goal.value };
        let mut d = self.warmup.as_ref().map(step_d).unwrap_or(0.0);
        d += self.cooldown.as_ref().map(step_d).unwrap_or(0.0);
        for b in &self.blocks {
            d += f64::from(b.repeat) * b.steps.iter().map(step_d).sum::<f64>();
        }
        d
    }

    /// Total planned time in seconds (time goals only), including repeats.
    pub fn planned_time_s(&self) -> f64 {
        let step_t = |s: &PlanStep| if s.goal.is_time() { s.goal.value } else { 0.0 };
        let mut t = self.warmup.as_ref().map(step_t).unwrap_or(0.0);
        t += self.cooldown.as_ref().map(step_t).unwrap_or(0.0);
        for b in &self.blocks {
            t += f64::from(b.repeat) * b.steps.iter().map(step_t).sum::<f64>();
        }
        t
    }

    /// Look up the plan step for a HealthKit key path `block.rep.step`:
    /// block 0 = warm-up, 1..=n = blocks, n+1 = cool-down.
    pub fn step_for_key(
        &self,
        block: u32,
        step: u32,
    ) -> Option<(&PlanStep, crate::model::StepKind)> {
        use crate::model::StepKind;
        if block == 0 {
            return self.warmup.as_ref().map(|s| (s, StepKind::Warmup));
        }
        let n = self.blocks.len() as u32;
        if block <= n {
            let s = self.blocks[(block - 1) as usize].steps.get(step as usize)?;
            let kind = if s.is_recovery() {
                StepKind::Recovery
            } else {
                StepKind::Work
            };
            return Some((s, kind));
        }
        if block == n + 1 {
            return self.cooldown.as_ref().map(|s| (s, StepKind::Cooldown));
        }
        None
    }
}

/// `plans/<plan_id>.status.json`, written by the app. `method`, `workoutkit_id` and
/// `scheduled_for` are optional additions of the iOS app (v0.2.0).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PlanStatus {
    pub plan_id: String,
    /// `scheduled | failed | cancelled`.
    pub state: String,
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub error: Option<String>,
    /// `schedule` (WorkoutScheduler) or `preview` (Apple's "Add to Watch" sheet).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    /// UUID of the WorkoutKit `WorkoutPlan`; the app matches executed workouts on it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workoutkit_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scheduled_for: Option<DateTime<Utc>>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Plan {
        serde_json::from_value(serde_json::json!({
            "name": "S26", "sport": "pool_swim", "pool_length_m": 50,
            "warmup": {"goal": {"type": "time_s", "value": 120}, "zone": 1},
            "blocks": [{"repeat": 3, "steps": [
                {"kind": "work", "goal": {"type": "distance_m", "value": 50}, "zone": 2, "label": "6-3-6 drill"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 25}}
            ]}],
            "cooldown": {"goal": {"type": "distance_m", "value": 100}, "zone": 1},
            "notes": "aerobic", "scheduled_for": "2026-10-25T10:00:00Z"
        }))
        .unwrap()
    }

    #[test]
    fn valid_plan_passes_and_finalizes() {
        let mut p = sample();
        p.validate().unwrap();
        let now = "2026-10-24T20:11:03Z".parse().unwrap();
        p.finalize("healthaccess-cli", now);
        assert_eq!(p.id, "2026-10-24T20:11:03Z-s26");
        assert_eq!(p.schema, SCHEMA_PLAN);
        assert_eq!(p.created_by.as_deref(), Some("healthaccess-cli"));
        assert_eq!(p.planned_distance_m(), 250.0);
        assert_eq!(p.planned_time_s(), 195.0);
    }

    #[test]
    fn validator_lists_every_problem() {
        let mut p = sample();
        p.sport = "skiing".into();
        p.blocks[0].steps[0].label = Some("x".repeat(41));
        p.blocks[0].steps[0].zone = Some(7);
        p.blocks[0].steps[1].goal.value = -3.0;
        p.blocks.push(PlanBlock {
            repeat: 0,
            steps: vec![],
        });
        let err = p.validate().unwrap_err();
        match err {
            Error::Validation(problems) => {
                assert_eq!(problems.len(), 6, "{problems:?}");
                assert!(problems.iter().any(|m| m.contains("sport")));
                assert!(problems.iter().any(|m| m.contains("41 chars")));
                assert!(problems.iter().any(|m| m.contains("zone must be 1–5")));
                assert!(problems.iter().any(|m| m.contains("positive number")));
                assert!(problems.iter().any(|m| m.contains("repeat must be")));
                assert!(problems
                    .iter()
                    .any(|m| m.contains("steps must not be empty")));
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn step_lookup_by_key_path() {
        let p = sample();
        assert!(matches!(
            p.step_for_key(0, 0),
            Some((_, crate::model::StepKind::Warmup))
        ));
        assert!(matches!(
            p.step_for_key(1, 1),
            Some((_, crate::model::StepKind::Recovery))
        ));
        assert!(matches!(
            p.step_for_key(2, 0),
            Some((_, crate::model::StepKind::Cooldown))
        ));
        assert!(p.step_for_key(3, 0).is_none());
    }

    #[test]
    fn legacy_schema_tag_is_accepted_and_upgraded_on_write() {
        let mut p = sample();
        p.schema = SCHEMA_PLAN_LEGACY.to_string();
        p.validate().unwrap();
        p.finalize("healthaccess-cli", "2026-10-25T08:00:00Z".parse().unwrap());
        assert_eq!(p.schema, SCHEMA_PLAN);
        let mut other = sample();
        other.schema = "somebody.plan.v1".into();
        assert!(other.validate().is_err());
    }
}

#[cfg(test)]
mod sport_tests {
    use super::*;

    fn plan(sport: &str, kind: &str) -> Plan {
        serde_json::from_value(serde_json::json!({
            "name": "T1", "sport": sport,
            "blocks": [{"repeat": 2, "steps": [{"goal": {"type": kind, "value": 60}}]}]
        }))
        .unwrap()
    }

    #[test]
    fn every_listed_sport_validates_with_time_goals() {
        for sport in SPORTS {
            assert!(plan(sport, "time_s").validate().is_ok(), "{sport}");
        }
    }

    #[test]
    fn time_only_sports_reject_distance_goals() {
        for sport in TIME_ONLY_SPORTS {
            let err = plan(sport, "distance_m").validate().unwrap_err();
            assert!(
                err.to_string().contains("time goals only"),
                "{sport}: {err}"
            );
        }
        assert!(plan("run", "distance_m").validate().is_ok());
    }
}
