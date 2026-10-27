//! Derived training views: zone seconds, pace, cardiac cost, weekly volume and the
//! one-line LLM summary. Every heuristic is documented on its function.

use std::collections::BTreeMap;

use chrono::{DateTime, Datelike, Duration, NaiveDate, Utc};
use serde::Serialize;

use crate::model::day::Day;
use crate::model::workout::activity_label;
use crate::model::{HrSample, RecoveryHr, StepKind, Workout, ZoneSeconds, Zones};
use crate::util::{fmt_duration, fmt_pace, round_to};

/// A gap between two HR samples longer than this counts as a sensor dropout and is
/// capped (the Watch samples every ~5 s while worn). Same rule as the iOS app.
pub const MAX_GAP_S: i64 = 60;
/// Steps shorter than this (metres) get no pace: a 12 m "drift" during a rest step
/// would otherwise produce a nonsense pace.
pub const MIN_PACE_DISTANCE_M: f64 = 20.0;
/// A work step must be at least this long to count as a "100" for the cardiac-cost pace.
pub const MIN_100_STEP_M: f64 = 95.0;

/// Zone (1–5) of a heart rate given four ascending bounds: `bpm < bounds[0]` → 1, …, `bpm >= bounds[3]` → 5.
pub fn zone_of(bpm: u32, bounds: &[u32]) -> u8 {
    1 + bounds.iter().filter(|b| bpm >= **b).count() as u8
}

/// Seconds per zone from an HR series: each sample's time until the next sample
/// goes to that sample's zone, gaps are capped at [`MAX_GAP_S`], and when a
/// `window` (workout start/end) is given only time inside it counts. This mirrors
/// the iOS app's rule.
pub fn zone_seconds(
    series: &[HrSample],
    bounds: &[u32],
    window: Option<(DateTime<Utc>, DateTime<Utc>)>,
) -> ZoneSeconds {
    let mut zs = ZoneSeconds::default();
    for w in series.windows(2) {
        let (mut a, mut b) = (w[0].t, w[1].t);
        if let Some((start, end)) = window {
            a = a.max(start);
            b = b.min(end);
        }
        let raw = (b - a).num_seconds();
        if raw <= 0 {
            continue;
        }
        zs.add(zone_of(w[0].bpm, bounds), raw.min(MAX_GAP_S) as u32);
    }
    zs
}

/// Where zone bounds came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BoundsSource {
    /// `zones = [...]` in config.toml.
    Config,
    /// From the athlete's age in `profile.json` (see [`estimate_bounds`]).
    Estimated,
    /// The workout file's own zones (legacy: the app used to compute them).
    File,
}

impl BoundsSource {
    /// The string in `zones.bounds_source`.
    pub const fn as_str(self) -> &'static str {
        match self {
            BoundsSource::Config => "config",
            BoundsSource::Estimated => "estimated",
            BoundsSource::File => "file",
        }
    }
}

/// Zone bounds from an age: maximum heart rate `208 - 0.7 * age` (Tanaka), bounds at
/// 72, 79, 86 and 92 % of it, rounded.
pub fn estimate_bounds(age_years: f64) -> [u32; 4] {
    let max = 208.0 - 0.7 * age_years;
    let at = |pct: f64| (max * pct).round().max(1.0) as u32;
    [at(0.72), at(0.79), at(0.86), at(0.92)]
}

/// Zones for `bounds`, computed from `hr_series` whenever the series has two or more
/// samples (`bounds_source` left to the caller); else the file's own zones when their
/// bounds match; else `None`.
pub fn zones_for(w: &Workout, bounds: &[u32]) -> Option<Zones> {
    if w.hr_series.len() >= 2 {
        return Some(Zones {
            bounds: bounds.to_vec(),
            bounds_source: None,
            seconds: zone_seconds(&w.hr_series, bounds, Some((w.start, w.end))),
        });
    }
    if let Some(z) = &w.zones {
        if z.bounds == bounds {
            return Some(z.clone());
        }
    }
    None
}

/// Highest sample of the series.
pub fn max_hr(series: &[HrSample]) -> Option<f64> {
    series.iter().map(|s| s.bpm).max().map(f64::from)
}

fn sample_near(series: &[HrSample], at: DateTime<Utc>, tolerance_s: i64) -> Option<u32> {
    series
        .iter()
        .filter(|s| (s.t - at).num_seconds().abs() <= tolerance_s)
        .min_by_key(|s| (s.t - at).num_seconds().abs())
        .map(|s| s.bpm)
}

/// Heart rate at the end (last sample within 20 s before the end) and the samples
/// nearest to end + 60 s / + 120 s (±15 s). `None` when nothing qualifies.
pub fn recovery_hr(series: &[HrSample], end: DateTime<Utc>) -> Option<RecoveryHr> {
    let end_hr = series
        .iter()
        .filter(|s| s.t <= end + Duration::seconds(5) && s.t >= end - Duration::seconds(20))
        .max_by_key(|s| s.t)
        .map(|s| s.bpm);
    let one = sample_near(series, end + Duration::seconds(60), 15);
    let two = sample_near(series, end + Duration::seconds(120), 15);
    if end_hr.is_none() && one.is_none() && two.is_none() {
        return None;
    }
    Some(RecoveryHr {
        end: end_hr,
        one_min: one,
        two_min: two,
    })
}

/// Seconds per 100 m, one decimal; `None` under [`MIN_PACE_DISTANCE_M`].
pub fn pace_s_per_100m(distance_m: Option<f64>, duration_s: f64) -> Option<f64> {
    let d = distance_m?;
    (d >= MIN_PACE_DISTANCE_M && duration_s > 0.0).then(|| round_to(duration_s / d * 100.0, 1))
}

/// Cardiac cost of a swim.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct CardiacCost {
    /// `avg_hr × best_100_pace_s / 60`: heart beats spent per 100 m when swimming
    /// at the session's best freestyle 100 pace. Lower is better; compare sessions
    /// of similar structure.
    pub beats_per_100m: f64,
    /// Best freestyle 100 m pace (s/100 m) found in the session.
    pub best_100_pace_s: f64,
    /// Workout average HR used in the formula.
    pub avg_hr: f64,
    /// Where the pace came from (`step 3.2.0 100 m in 1:52` or `whole workout`).
    pub basis: String,
}

/// Share (0–1) of lap time overlapping `[start, end]` that was freestyle; `None` when
/// no lap in the window carries a stroke.
fn freestyle_share(w: &Workout, start: DateTime<Utc>, end: DateTime<Utc>) -> Option<f64> {
    let mut total = 0.0;
    let mut free = 0.0;
    for lap in &w.laps {
        let Some(stroke) = &lap.stroke else { continue };
        let overlap = (lap.end.min(end) - lap.start.max(start)).num_seconds();
        if overlap <= 0 {
            continue;
        }
        total += overlap as f64;
        if stroke == "freestyle" {
            free += overlap as f64;
        }
    }
    (total > 0.0).then(|| free / total)
}

/// Best freestyle 100 m pace: the fastest work step of ≥ 95 m whose laps were at
/// least half freestyle (steps without any stroke data are accepted), normalised to
/// 100 m. Falls back to the whole-workout pace for swims of ≥ 100 m without steps.
pub fn best_freestyle_100_pace(w: &Workout) -> Option<(f64, String)> {
    let mut best: Option<(f64, String)> = None;
    for s in &w.steps {
        if s.kind != StepKind::Work {
            continue;
        }
        let Some(d) = s.distance_m else { continue };
        if d < MIN_100_STEP_M || s.duration_s <= 0.0 {
            continue;
        }
        if let Some(share) = freestyle_share(w, s.start, s.end) {
            if share < 0.5 {
                continue;
            }
        }
        let pace = s.duration_s / d * 100.0;
        if best.as_ref().map(|(p, _)| pace < *p).unwrap_or(true) {
            best = Some((
                round_to(pace, 1),
                format!(
                    "step {} {} m in {}",
                    s.key,
                    round_to(d, 0),
                    fmt_duration(s.duration_s)
                ),
            ));
        }
    }
    if best.is_some() {
        return best;
    }
    let d = w.distance_m?;
    (d >= 100.0 && w.duration_s > 0.0).then(|| {
        (
            round_to(w.duration_s / d * 100.0, 1),
            "whole workout".to_string(),
        )
    })
}

/// Cardiac cost for swims (see [`CardiacCost`]); `None` for other sports or when
/// HR or pace are missing.
pub fn cardiac_cost(w: &Workout) -> Option<CardiacCost> {
    if !w.is_swim() {
        return None;
    }
    let avg_hr = w.avg_hr?;
    let (pace, basis) = best_freestyle_100_pace(w)?;
    Some(CardiacCost {
        beats_per_100m: round_to(avg_hr * pace / 60.0, 1),
        best_100_pace_s: pace,
        avg_hr,
        basis,
    })
}

/// `effort 7/10 (apple)`, `effort 7/10` when the source is unknown, or `effort unrated`.
pub fn effort_text(effort: Option<u8>, source: Option<&str>) -> String {
    match (effort, source.map(str::trim).filter(|s| !s.is_empty())) {
        (Some(e), Some(src)) => format!("effort {e}/10 ({src})"),
        (Some(e), None) => format!("effort {e}/10"),
        (None, _) => "effort unrated".to_string(),
    }
}

/// One line per step an AI can quote without parsing `steps[]`:
/// `label · 200 m · 2:18/100 · HR 108` for a step with a distance and a pace,
/// `label · 0:45 · HR 97` for a timed step. The label falls back to the kind
/// (`warmup`, `work`, `recovery`, `cooldown`).
pub fn parts_text(w: &Workout) -> Vec<String> {
    w.steps
        .iter()
        .map(|s| {
            let mut parts: Vec<String> = Vec::with_capacity(4);
            parts.push(
                s.label
                    .as_deref()
                    .map(str::trim)
                    .filter(|l| !l.is_empty())
                    .map(str::to_string)
                    .unwrap_or_else(|| s.kind.to_string()),
            );
            match (s.distance_m, s.pace_s_per_100m) {
                (Some(d), Some(p)) => {
                    parts.push(format!("{} m", round_to(d, 0)));
                    parts.push(format!("{}/100", fmt_pace(p)));
                }
                _ => parts.push(fmt_duration(s.duration_s)),
            }
            if let Some(hr) = s.avg_hr {
                parts.push(format!("HR {}", hr.round()));
            }
            parts.join(" · ")
        })
        .collect()
}

/// One line for an LLM: date, name, distance, duration, avg HR, Z1–2 % (when zones are
/// known), effort.
pub fn summary_line(w: &Workout, zones: Option<&Zones>) -> String {
    let mut parts: Vec<String> = Vec::with_capacity(8);
    let date = w.start.format("%Y-%m-%d").to_string();
    let name = match w.plan_ref.as_ref().and_then(|p| p.name.as_deref()) {
        Some(n) => format!("{} \"{}\"", activity_label(&w.activity), n),
        None => activity_label(&w.activity),
    };
    parts.push(format!("{date} {name}"));
    if let Some(d) = w.distance_m {
        if d > 0.0 {
            parts.push(format!("{} m", round_to(d, 0)));
        }
    }
    parts.push(fmt_duration(w.duration_s));
    match (w.avg_hr, w.max_hr) {
        (Some(a), Some(m)) => parts.push(format!("avg HR {} (max {})", a.round(), m.round())),
        (Some(a), None) => parts.push(format!("avg HR {}", a.round())),
        _ => parts.push("no HR".to_string()),
    }
    if let Some(p) = zones.and_then(|z| z.seconds.z12_pct()) {
        parts.push(format!("Z1–2 {}%", p.round()));
    }
    parts.push(effort_text(w.effort, w.effort_source.as_deref()));
    if let Some(cc) = cardiac_cost(w) {
        parts.push(format!(
            "best FR 100 {} → {} beats/100 m",
            fmt_pace(cc.best_100_pace_s),
            cc.beats_per_100m.round()
        ));
    }
    parts.join(" · ")
}

/// Per-sport volume inside a week.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct SportVolume {
    pub sessions: u32,
    pub duration_s: f64,
    pub distance_m: f64,
}

/// Activity ring totals over the days of a week that have an activity summary.
#[derive(Debug, Clone, Default, Serialize, PartialEq)]
pub struct RingTotals {
    /// Days with a ring summary in the week.
    pub days: u32,
    pub move_kcal: f64,
    pub exercise_min: f64,
    pub stand_hours: f64,
    /// Days on which the ring closed (goal known and reached).
    pub move_goal_days: u32,
    pub exercise_goal_days: u32,
    pub stand_goal_days: u32,
}

/// One ISO week of training.
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct WeekSummary {
    /// ISO week label, e.g. `2026-W43`.
    pub week: String,
    /// Monday.
    pub start: NaiveDate,
    /// Sunday.
    pub end: NaiveDate,
    pub sessions: u32,
    pub duration_s: f64,
    pub distance_m: f64,
    /// Duration-weighted average HR over sessions that have one.
    pub avg_hr: Option<f64>,
    /// Share of zone time in Z1–2 across the week.
    pub z12_pct: Option<f64>,
    /// Mean effort over rated sessions.
    pub mean_effort: Option<f64>,
    pub rated_sessions: u32,
    /// Mean cardiac cost over swims that have one.
    pub cardiac_cost: Option<f64>,
    pub by_sport: BTreeMap<String, SportVolume>,
    /// Days of the week with a `days/<date>.json` file.
    pub days_with_data: u32,
    /// Ring totals from those days, when any carried a ring summary.
    pub rings: Option<RingTotals>,
    /// Mean of the days' `physical_effort_avg_met`, when present.
    pub mean_physical_effort_met: Option<f64>,
}

/// Monday of the week containing `date`.
pub fn week_start(date: NaiveDate) -> NaiveDate {
    date - Duration::days(i64::from(date.weekday().num_days_from_monday()))
}

/// `YYYY-Www` ISO label.
pub fn week_label(date: NaiveDate) -> String {
    let iw = date.iso_week();
    format!("{}-W{:02}", iw.year(), iw.week())
}

/// Weekly summaries for the `weeks` ISO weeks ending in the week of `today`,
/// oldest first; weeks without sessions are included with zeros so trends stay aligned.
/// `days` (the `days/` files of the window, any order) add ring totals and the mean
/// physical effort per week. `zones_of` gives each workout's zones (the store's view:
/// configured or estimated bounds, else the file's own), or `None`.
pub fn weekly_summaries(
    workouts: &[Workout],
    days: &[Day],
    weeks: u32,
    today: NaiveDate,
    zones_of: &dyn Fn(&Workout) -> Option<Zones>,
) -> Vec<WeekSummary> {
    let weeks = weeks.max(1);
    let last_start = week_start(today);
    let first_start = last_start - Duration::weeks(i64::from(weeks) - 1);
    let mut out: Vec<WeekSummary> = (0..weeks)
        .map(|i| {
            let start = first_start + Duration::weeks(i64::from(i));
            WeekSummary {
                week: week_label(start),
                start,
                end: start + Duration::days(6),
                sessions: 0,
                duration_s: 0.0,
                distance_m: 0.0,
                avg_hr: None,
                z12_pct: None,
                mean_effort: None,
                rated_sessions: 0,
                cardiac_cost: None,
                by_sport: BTreeMap::new(),
                days_with_data: 0,
                rings: None,
                mean_physical_effort_met: None,
            }
        })
        .collect();
    let index_of = |date: NaiveDate| -> Option<usize> {
        let ws = week_start(date);
        (ws >= first_start && ws <= last_start)
            .then(|| ((ws - first_start).num_days() / 7) as usize)
    };
    // accumulators per week: (hr_weight_sum, hr_dur, z12, ztotal, effort_sum, cc_sum, cc_n)
    let mut acc = vec![(0.0f64, 0.0f64, 0u64, 0u64, 0.0f64, 0.0f64, 0u32); weeks as usize];
    for w in workouts {
        let Some(i) = index_of(w.start.date_naive()) else {
            continue;
        };
        let week = &mut out[i];
        let a = &mut acc[i];
        week.sessions += 1;
        week.duration_s += w.duration_s;
        week.distance_m += w.distance_m.unwrap_or(0.0);
        let sv = week.by_sport.entry(w.activity.clone()).or_default();
        sv.sessions += 1;
        sv.duration_s += w.duration_s;
        sv.distance_m += w.distance_m.unwrap_or(0.0);
        if let Some(hr) = w.avg_hr {
            a.0 += hr * w.duration_s;
            a.1 += w.duration_s;
        }
        if let Some(z) = zones_of(w) {
            a.2 += u64::from(z.seconds.z12());
            a.3 += u64::from(z.seconds.total());
        }
        if let Some(e) = w.effort {
            a.4 += f64::from(e);
            week.rated_sessions += 1;
        }
        if let Some(cc) = cardiac_cost(w) {
            a.5 += cc.beats_per_100m;
            a.6 += 1;
        }
    }
    // days: ring totals and physical effort
    let mut effort_acc = vec![(0.0f64, 0u32); weeks as usize];
    for d in days {
        let Some(i) = index_of(d.date) else { continue };
        let week = &mut out[i];
        week.days_with_data += 1;
        let Some(activity) = &d.activity else {
            continue;
        };
        if let Some(met) = activity.physical_effort_avg_met {
            effort_acc[i].0 += met;
            effort_acc[i].1 += 1;
        }
        if let Some(rings) = &activity.rings {
            let r = week.rings.get_or_insert_with(RingTotals::default);
            r.days += 1;
            if let Some(m) = &rings.move_kcal {
                r.move_kcal += m.actual.unwrap_or(0.0);
                r.move_goal_days += u32::from(m.hit() == Some(true));
            }
            if let Some(e) = &rings.exercise_min {
                r.exercise_min += e.actual.unwrap_or(0.0);
                r.exercise_goal_days += u32::from(e.hit() == Some(true));
            }
            if let Some(st) = &rings.stand_hours {
                r.stand_hours += st.actual.unwrap_or(0.0);
                r.stand_goal_days += u32::from(st.hit() == Some(true));
            }
        }
    }
    for ((week, a), e) in out.iter_mut().zip(acc).zip(effort_acc) {
        if a.1 > 0.0 {
            week.avg_hr = Some(round_to(a.0 / a.1, 0));
        }
        if a.3 > 0 {
            week.z12_pct = Some(round_to(100.0 * a.2 as f64 / a.3 as f64, 0));
        }
        if week.rated_sessions > 0 {
            week.mean_effort = Some(round_to(a.4 / f64::from(week.rated_sessions), 1));
        }
        if a.6 > 0 {
            week.cardiac_cost = Some(round_to(a.5 / f64::from(a.6), 0));
        }
        if e.1 > 0 {
            week.mean_physical_effort_met = Some(round_to(e.0 / f64::from(e.1), 1));
        }
        if let Some(r) = &mut week.rings {
            r.move_kcal = r.move_kcal.round();
            r.exercise_min = r.exercise_min.round();
            r.stand_hours = r.stand_hours.round();
        }
        week.duration_s = week.duration_s.round();
        week.distance_m = week.distance_m.round();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(t: &str, bpm: u32) -> HrSample {
        HrSample {
            t: t.parse().unwrap(),
            bpm,
        }
    }

    #[test]
    fn zones_are_half_open_on_the_bounds() {
        let b = [133, 146, 159, 171];
        assert_eq!(zone_of(132, &b), 1);
        assert_eq!(zone_of(133, &b), 2);
        assert_eq!(zone_of(158, &b), 3);
        assert_eq!(zone_of(171, &b), 5);
    }

    #[test]
    fn zone_seconds_attribute_gap_to_earlier_sample_and_cap_dropouts() {
        let series = vec![
            s("2026-01-01T00:00:00Z", 120),
            s("2026-01-01T00:00:05Z", 140),
            s("2026-01-01T00:00:10Z", 160),
            s("2026-01-01T00:02:10Z", 100), // 120 s gap → capped at 60
        ];
        let z = zone_seconds(&series, &[133, 146, 159, 171], None);
        assert_eq!((z.z1, z.z2, z.z3, z.z4, z.z5), (5, 5, 0, 60, 0));
        assert_eq!(z.total(), 70);
        // clipped to the workout window: starts 2 s in, ends after 8 s
        let win = Some((
            "2026-01-01T00:00:02Z".parse().unwrap(),
            "2026-01-01T00:00:08Z".parse().unwrap(),
        ));
        let z = zone_seconds(&series, &[133, 146, 159, 171], win);
        assert_eq!((z.z1, z.z2, z.z3, z.z4, z.z5), (3, 3, 0, 0, 0));
    }

    #[test]
    fn effort_text_names_the_source() {
        assert_eq!(effort_text(Some(7), Some("apple")), "effort 7/10 (apple)");
        assert_eq!(effort_text(Some(7), None), "effort 7/10");
        assert_eq!(effort_text(Some(7), Some("  ")), "effort 7/10");
        assert_eq!(effort_text(None, Some("apple")), "effort unrated");
    }

    #[test]
    fn bounds_from_age() {
        assert_eq!(estimate_bounds(38.0), [131, 143, 156, 167]);
        assert_eq!(estimate_bounds(20.0), [140, 153, 167, 178]);
    }

    #[test]
    fn pace_floor() {
        assert_eq!(pace_s_per_100m(Some(52.5), 48.0), Some(91.4));
        assert_eq!(pace_s_per_100m(Some(12.8), 25.0), None);
        assert_eq!(pace_s_per_100m(None, 25.0), None);
    }

    #[test]
    fn weeks_are_iso_and_start_monday() {
        let d = NaiveDate::from_ymd_opt(2026, 10, 23).unwrap(); // Friday
        assert_eq!(
            week_start(d),
            NaiveDate::from_ymd_opt(2026, 10, 19).unwrap()
        );
        assert_eq!(week_label(d), "2026-W43");
    }
}
