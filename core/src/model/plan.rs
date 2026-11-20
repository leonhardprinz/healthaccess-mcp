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
pub const SPORTS: [&str; 12] = [
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
    "strength",
];
/// Sports the Watch measures no distance for: their steps take time or open goals.
pub const NO_DISTANCE_SPORTS: [&str; 3] = ["hiit", "elliptical", "strength"];
/// Sports a plan can be a pacer for (WorkoutKit's PacerWorkout: one distance in one time).
pub const PACER_SPORTS: [&str; 2] = ["run", "cycle"];
/// Sports whose steps can carry a pace alert (WorkoutKit's speed range alert; checked with
/// `CustomWorkout.supportsAlert` on the iOS 27.2 SDK: walk, hike and the swims say no).
pub const PACE_SPORTS: [&str; 4] = ["run", "indoor_run", "cycle", "indoor_cycle"];
/// Fastest and slowest pace an alert may name, in seconds per km (120 km/h and 2 km/h).
pub const PACE_LIMITS_S_PER_KM: (f64, f64) = (30.0, 1800.0);
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
    /// open_water_swim | indoor_row | hiit | elliptical | strength`.
    pub sport: String,
    #[serde(default)]
    pub pool_length_m: Option<f64>,
    #[serde(default)]
    pub warmup: Option<PlanStep>,
    /// The steps. Empty for a pacer plan.
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
    /// A race-pace target instead of steps: the Watch paces the whole distance against one
    /// time (WorkoutKit's pacer workout). Run and cycle only; a pacer plan has no blocks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pacer: Option<Pacer>,
}

/// One distance in one time, paced evenly by the Watch.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Pacer {
    pub distance_m: f64,
    pub time_s: f64,
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
    /// Pace range to alert on, seconds per km, fast end first: `[290, 310]` is 4:50 to
    /// 5:10 per km. Run and cycle only; a step has one alert, a zone or a pace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pace_s_per_km: Option<Vec<f64>>,
    #[serde(default)]
    pub label: Option<String>,
}

/// Step goal.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Goal {
    /// `time_s | distance_m | open`. An open step ends when the athlete taps on the Watch
    /// (a strength set, a rest until ready); it has no value.
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
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

    /// An open goal: the step lasts until the athlete taps.
    pub fn open() -> Self {
        Goal {
            kind: "open".into(),
            value: 0.0,
        }
    }

    /// `true` for a time goal.
    pub fn is_time(&self) -> bool {
        self.kind == "time_s"
    }

    /// `true` for an open goal.
    pub fn is_open(&self) -> bool {
        self.kind == "open"
    }
}

impl PlanStep {
    /// The pace alert as (fast, slow) seconds per km, whichever order the plan gave them.
    pub fn pace_range(&self) -> Option<(f64, f64)> {
        match self.pace_s_per_km.as_deref() {
            Some([a, b]) => Some((a.min(*b), a.max(*b))),
            _ => None,
        }
    }

    /// `true` when the step is a recovery step.
    pub fn is_recovery(&self) -> bool {
        self.kind.as_deref() == Some("recovery")
    }

    /// Compact one-line rendering, e.g. `4×50 m` style pieces are rendered per step.
    pub fn describe(&self) -> String {
        let goal = if self.goal.is_open() {
            "open".to_string()
        } else if self.goal.is_time() {
            crate::util::fmt_duration(self.goal.value)
        } else {
            format!("{} m", crate::util::round_to(self.goal.value, 1))
        };
        let mut s = goal;
        if let Some(z) = self.zone {
            s.push_str(&format!(" Z{z}"));
        }
        if let Some((fast, slow)) = self.pace_range() {
            s.push_str(&format!(
                " @{}-{}/km",
                crate::util::fmt_pace(fast),
                crate::util::fmt_pace(slow)
            ));
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
    if !matches!(step.goal.kind.as_str(), "time_s" | "distance_m" | "open") {
        problems.push(format!(
            "{prefix}: goal.type must be time_s, distance_m or open, got {:?}",
            step.goal.kind
        ));
    }
    if step.goal.is_open() {
        // no value: the athlete ends the step
    } else if !(step.goal.value.is_finite() && step.goal.value > 0.0) {
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
    if let Some(pace) = &step.pace_s_per_km {
        let (lo, hi) = PACE_LIMITS_S_PER_KM;
        if pace.len() != 2
            || pace
                .iter()
                .any(|v| !(v.is_finite() && *v >= lo && *v <= hi))
        {
            problems.push(format!(
                "{prefix}: pace_s_per_km must be two paces in seconds per km from {lo} to {hi}, fast end first, e.g. [290, 310] for 4:50 to 5:10"
            ));
        } else if pace[0] == pace[1] {
            problems.push(format!(
                "{prefix}: pace_s_per_km needs a range, e.g. [290, 310]; the Watch taps whenever the pace leaves it"
            ));
        }
        if step.zone.is_some() {
            problems.push(format!(
                "{prefix}: a step has one alert on the Watch: zone or pace_s_per_km, not both"
            ));
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
    /// Every step with its place in the plan (`warmup`, `blocks[0].steps[1]`, `cooldown`).
    pub fn all_steps(&self) -> Vec<(String, &PlanStep)> {
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
        steps
    }

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
        for (at, s) in self.all_steps() {
            if NO_DISTANCE_SPORTS.contains(&self.sport.as_str()) && s.goal.kind == "distance_m" {
                problems.push(format!(
                    "{at}: the Watch measures no distance for {}; use time_s or open",
                    self.sport
                ));
            }
            if s.pace_s_per_km.is_some() && !PACE_SPORTS.contains(&self.sport.as_str()) {
                problems.push(format!(
                    "{at}: the Watch has pace alerts for {} only, not {}; use zone",
                    PACE_SPORTS.join(", "),
                    self.sport
                ));
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
        if let Some(pacer) = &self.pacer {
            if !PACER_SPORTS.contains(&self.sport.as_str()) {
                problems.push(format!(
                    "pacer works for {} only, got {:?}",
                    PACER_SPORTS.join(" and "),
                    self.sport
                ));
            }
            if !self.blocks.is_empty() || self.warmup.is_some() || self.cooldown.is_some() {
                problems.push(
                    "a pacer plan has no warmup, blocks or cooldown: the Watch paces the whole distance"
                        .to_string(),
                );
            }
            if !(pacer.distance_m.is_finite()
                && pacer.distance_m > 0.0
                && pacer.distance_m <= MAX_GOAL_DISTANCE_M)
            {
                problems.push(format!(
                    "pacer.distance_m must be more than 0 and at most {MAX_GOAL_DISTANCE_M}"
                ));
            }
            if !(pacer.time_s.is_finite() && pacer.time_s > 0.0 && pacer.time_s <= MAX_GOAL_TIME_S)
            {
                problems.push(format!(
                    "pacer.time_s must be more than 0 and at most {MAX_GOAL_TIME_S}"
                ));
            }
        } else if self.blocks.is_empty() {
            problems.push("blocks must contain at least one block (or a pacer)".to_string());
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
        // "default work": written out, because a reader that sees no kind has to guess (the app took a time goal
        // without one for a rest).
        for block in &mut self.blocks {
            for step in &mut block.steps {
                if step.kind.as_deref().map(str::is_empty).unwrap_or(true) {
                    step.kind = Some("work".to_string());
                }
            }
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
        if let Some(p) = &self.pacer {
            return p.distance_m;
        }
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
        if let Some(p) = &self.pacer {
            return p.time_s;
        }
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
    fn no_distance_sports_reject_distance_goals() {
        for sport in NO_DISTANCE_SPORTS {
            let err = plan(sport, "distance_m").validate().unwrap_err();
            assert!(
                err.to_string().contains("measures no distance"),
                "{sport}: {err}"
            );
        }
        assert!(plan("run", "distance_m").validate().is_ok());
    }

    #[test]
    fn strength_sets_are_open_steps_without_a_value() {
        let p: Plan = serde_json::from_value(serde_json::json!({
            "name": "Legs A", "sport": "strength",
            "blocks": [{"repeat": 5, "steps": [
                {"goal": {"type": "open"}, "label": "Squat 5 x 60 kg"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 120}}
            ]}]
        }))
        .unwrap();
        p.validate().unwrap();
        assert_eq!(p.planned_time_s(), 600.0);
        assert_eq!(p.blocks[0].steps[0].describe(), "open \"Squat 5 x 60 kg\"");
        let bad = plan("strength", "rest_until_ready");
        assert!(bad
            .validate()
            .unwrap_err()
            .to_string()
            .contains("time_s, distance_m or open"));
    }

    fn paced(sport: &str, pace: serde_json::Value, zone: Option<u8>) -> Plan {
        serde_json::from_value(serde_json::json!({
            "name": "6x1k", "sport": sport,
            "blocks": [{"repeat": 6, "steps": [
                {"goal": {"type": "distance_m", "value": 1000}, "pace_s_per_km": pace, "zone": zone, "label": "1k"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 90}}
            ]}]
        }))
        .unwrap()
    }

    #[test]
    fn pace_alerts_are_a_range_on_run_and_cycle_steps_only() {
        for sport in PACE_SPORTS {
            paced(sport, serde_json::json!([290, 310]), None)
                .validate()
                .unwrap();
        }
        let p = paced("run", serde_json::json!([310, 290]), None);
        assert_eq!(p.blocks[0].steps[0].pace_range(), Some((290.0, 310.0)));
        assert_eq!(
            p.blocks[0].steps[0].describe(),
            "1000 m @4:50-5:10/km \"1k\""
        );
        for (sport, pace, zone, says) in [
            (
                "walk",
                serde_json::json!([600, 660]),
                None,
                "pace alerts for run",
            ),
            (
                "pool_swim",
                serde_json::json!([100, 110]),
                None,
                "pace alerts for run",
            ),
            ("run", serde_json::json!([300]), None, "two paces"),
            ("run", serde_json::json!([5, 310]), None, "two paces"),
            ("run", serde_json::json!([300, 300]), None, "needs a range"),
            (
                "run",
                serde_json::json!([290, 310]),
                Some(3),
                "zone or pace_s_per_km",
            ),
        ] {
            let err = paced(sport, pace, zone).validate().unwrap_err().to_string();
            assert!(err.contains(says), "{sport}: {err}");
        }
        // written back without the field when a step has none
        let plain = serde_json::to_value(plan("run", "time_s")).unwrap();
        assert!(plain["blocks"][0]["steps"][0]
            .get("pace_s_per_km")
            .is_none());
    }

    fn pacer(sport: &str) -> Plan {
        serde_json::from_value(serde_json::json!({
            "name": "10K race", "sport": sport,
            "pacer": {"distance_m": 10000, "time_s": 3000}
        }))
        .unwrap()
    }

    #[test]
    fn a_pacer_plan_has_no_steps_and_counts_its_distance_and_time() {
        let p = pacer("run");
        p.validate().unwrap();
        assert_eq!(p.planned_distance_m(), 10000.0);
        assert_eq!(p.planned_time_s(), 3000.0);
        assert!(pacer("cycle").validate().is_ok());
        let swim = pacer("pool_swim").validate().unwrap_err().to_string();
        assert!(swim.contains("pacer works for run and cycle"), "{swim}");
        let mut mixed = pacer("run");
        mixed.blocks = plan("run", "time_s").blocks;
        assert!(mixed
            .validate()
            .unwrap_err()
            .to_string()
            .contains("no warmup, blocks or cooldown"));
        let mut zero = pacer("run");
        zero.pacer.as_mut().unwrap().time_s = 0.0;
        assert!(zero.validate().is_err());
        let empty =
            serde_json::from_value::<Plan>(serde_json::json!({"name": "x", "sport": "run"}))
                .unwrap();
        assert!(empty
            .validate()
            .unwrap_err()
            .to_string()
            .contains("or a pacer"));
    }
}
