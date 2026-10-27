//! Store behaviour on a temp copy of the fixtures.

use std::fs;
use std::path::{Path, PathBuf};

use chrono::NaiveDate;
use healthaccess_core::handshake::{client_id, machine_name, Recorder};
use healthaccess_core::model::{EffortSource, StepKind, ZoneSeconds, Zones};
use healthaccess_core::store::IndexSource;
use healthaccess_core::ClientInfo;
use healthaccess_core::{derive, BriefingSource};
use healthaccess_core::{Error, Plan, Store};
use serde_json::{json, Value};

const POOL: &str = "2026-05-14_0712_PoolSwim_7A1C3E90.json";
const ROW: &str = "2026-05-12_0630_IndoorRow_3F8B2D41.json";

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn temp_store() -> (tempfile::TempDir, Store) {
    let tmp = tempfile::tempdir().unwrap();
    let w = tmp.path().join("workouts");
    fs::create_dir_all(&w).unwrap();
    for f in [POOL, ROW] {
        fs::copy(fixtures().join(f), w.join(f)).unwrap();
    }
    let store = Store::open(tmp.path()).unwrap();
    (tmp, store)
}

fn minimal_v0(uuid: &str, start: &str, end: &str, duration: f64, source: &str) -> Value {
    json!({
        "schema": "tide.workout.v0", "uuid": uuid, "activity": 13, "activity_name": "Cycle",
        "source": source, "start": start, "end": end, "duration_s": duration,
        "active_kcal": 100.0, "avg_hr": 135, "hr_samples": 0, "hr_series": [],
        "zone_seconds": {"z1": 10}, "activities": [], "events": [], "metadata": {}
    })
}

#[test]
fn scan_fallback_builds_index_newest_first() {
    let (_tmp, store) = temp_store();
    let (index, source) = store.load_index().unwrap();
    assert_eq!(source, IndexSource::Scan);
    assert_eq!(index.workouts.len(), 2);
    assert_eq!(index.workouts[0].file, format!("workouts/{POOL}"));
    assert_eq!(index.workouts[0].activity, "pool_swim");
    assert_eq!(index.workouts[1].activity, "indoor_row");
    assert!(index.workouts[0].source.is_some());
}

#[test]
fn index_file_is_preferred_and_resolution_accepts_short_ids() {
    let (tmp, store) = temp_store();
    // the app's pre-rename index tag is an accepted alias
    let idx = json!({"schema": "tide.index.v1", "updated": "2026-10-24T00:00:00Z", "workouts": [
        {"id": "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3", "file": POOL, "activity": "pool_swim",
         "start": "2026-05-14T05:12:04Z", "duration_s": 2166, "distance_m": 1200, "avg_hr": 129, "effort": null, "plan_name": "S26"}
    ]});
    fs::write(
        tmp.path().join("index.json"),
        serde_json::to_string_pretty(&idx).unwrap(),
    )
    .unwrap();
    let (index, source) = store.load_index().unwrap();
    assert_eq!(source, IndexSource::File);
    assert_eq!(index.workouts.len(), 1);

    assert_eq!(
        store.resolve("7a1c3e90").unwrap().entry.file,
        POOL,
        "bare names in the app's index still resolve"
    );
    assert!(store.resolve("7a1c3e90").unwrap().path.is_file());
    assert_eq!(
        store.resolve(POOL).unwrap().entry.id,
        "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3"
    );
    assert!(matches!(
        store.resolve("nope").unwrap_err(),
        Error::NotFound(_)
    ));
    // not in the index but on disk: loadable by file name, short id and full id
    // (the index falls back to a scan of workouts/ on a miss)
    assert_eq!(store.load_workout(ROW).unwrap().activity, "indoor_row");
    assert_eq!(
        store.load_workout("3f8b2d41").unwrap().activity,
        "indoor_row"
    );
    assert_eq!(
        store
            .load_workout("3F8B2D41-9E6C-4A17-B2D8-5C3E7F9A1B04")
            .unwrap()
            .activity,
        "indoor_row"
    );
}

#[test]
fn rate_workout_without_index_resolves_like_reads() {
    // no index.json at all: full UUID, 8-char short id and file name must all work
    let (tmp, store) = temp_store();
    assert!(!tmp.path().join("index.json").exists());
    let by_short = store
        .rate_workout("3f8b2d41", 4, Some("short id"), true)
        .unwrap();
    assert_eq!(by_short.id, "3F8B2D41-9E6C-4A17-B2D8-5C3E7F9A1B04");
    assert_eq!(by_short.file, ROW);
    assert!(!by_short.index_updated, "no index to update");
    let by_full = store
        .rate_workout("3F8B2D41-9E6C-4A17-B2D8-5C3E7F9A1B04", 5, None, true)
        .unwrap();
    assert_eq!(by_full.feel.as_deref(), Some("short id"), "feel kept");
    let by_file = store.rate_workout(ROW, 6, Some("file name"), true).unwrap();
    assert_eq!(by_file.effort, 6);
    let after: Value =
        serde_json::from_str(&fs::read_to_string(tmp.path().join("workouts").join(ROW)).unwrap())
            .unwrap();
    assert_eq!(after["effort"], 6);
    assert_eq!(after["feel"], "file name");
    assert!(
        !tmp.path().join("index.json").exists(),
        "the MCP never creates the index"
    );
    // what get_workout/show see is what rate_workout wrote
    assert_eq!(store.load_workout("3f8b2d41").unwrap().effort, Some(6));
}

#[test]
fn rate_workout_falls_back_to_a_scan_when_index_json_lacks_the_workout() {
    // index.json present but stale: it lists only the swim, the row exists on disk
    let (tmp, store) = temp_store();
    let idx = json!({"schema": "healthaccess.index.v1", "updated": "2026-10-24T00:00:00Z", "workouts": [
        {"id": "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3", "file": format!("workouts/{POOL}"), "activity": "pool_swim",
         "start": "2026-05-14T05:12:04Z", "duration_s": 2166, "distance_m": 1200, "avg_hr": 129, "effort": null, "plan_name": null}
    ]});
    fs::write(tmp.path().join("index.json"), idx.to_string()).unwrap();
    assert_eq!(store.load_index().unwrap().1, IndexSource::File);

    let out = store
        .rate_workout("3f8b2d41", 3, Some("stale index"), true)
        .unwrap();
    assert_eq!(out.id, "3F8B2D41-9E6C-4A17-B2D8-5C3E7F9A1B04");
    assert!(
        !out.index_updated,
        "the row is not in index.json, so nothing to update"
    );
    let after: Value =
        serde_json::from_str(&fs::read_to_string(tmp.path().join("workouts").join(ROW)).unwrap())
            .unwrap();
    assert_eq!(after["effort"], 3);
    // the index itself is left as the app wrote it
    let index: Value =
        serde_json::from_str(&fs::read_to_string(tmp.path().join("index.json")).unwrap()).unwrap();
    assert_eq!(index["workouts"].as_array().unwrap().len(), 1);
    // reads agree
    assert_eq!(store.load_workout("3f8b2d41").unwrap().effort, Some(3));
    // and a row that is in the index still updates it
    let out = store.rate_workout("7a1c3e90", 8, None, true).unwrap();
    assert!(out.index_updated);
    assert!(matches!(
        store.rate_workout("deadbeef", 5, None, false).unwrap_err(),
        Error::NotFound(_)
    ));
}

#[test]
fn dedupe_keeps_the_longer_of_two_same_start_same_source_workouts() {
    let (tmp, store) = temp_store();
    let w = tmp.path().join("workouts");
    fs::write(
        w.join("2026-10-22_1213_Cycle_AAAAAAAA.json"),
        minimal_v0(
            "AAAAAAAA-0000-4000-8000-000000000000",
            "2026-10-22T10:13:07Z",
            "2026-10-22T11:39:09Z",
            5163.0,
            "Cycling App",
        )
        .to_string(),
    )
    .unwrap();
    fs::write(
        w.join("2026-10-22_1213_Cycle_BBBBBBBB.json"),
        minimal_v0(
            "BBBBBBBB-0000-4000-8000-000000000000",
            "2026-10-22T10:13:08Z",
            "2026-10-22T11:39:22Z",
            4308.0,
            "Cycling App",
        )
        .to_string(),
    )
    .unwrap();
    // same start, different source → a different workout
    fs::write(
        w.join("2026-10-22_1213_Cycle_CCCCCCCC.json"),
        minimal_v0(
            "CCCCCCCC-0000-4000-8000-000000000000",
            "2026-10-22T10:13:08Z",
            "2026-10-22T10:20:00Z",
            400.0,
            "Apple Watch",
        )
        .to_string(),
    )
    .unwrap();
    let index = store.index().unwrap();
    let ids: Vec<&str> = index.workouts.iter().map(|e| e.id.as_str()).collect();
    assert!(ids.contains(&"AAAAAAAA-0000-4000-8000-000000000000"));
    assert!(!ids.contains(&"BBBBBBBB-0000-4000-8000-000000000000"));
    assert!(ids.contains(&"CCCCCCCC-0000-4000-8000-000000000000"));
    assert_eq!(index.workouts.len(), 4);

    let report = store.doctor().unwrap();
    assert_eq!(
        report.duplicates_dropped,
        vec!["BBBBBBBB-0000-4000-8000-000000000000"]
    );
    assert!(report.healthy());
    assert_eq!(report.schema_counts["tide.workout.v0"], 3);
    assert_eq!(report.schema_counts["healthaccess.workout.v1"], 2);
}

#[test]
fn rate_workout_changes_only_two_fields_and_updates_index() {
    let (tmp, store) = temp_store();
    let path = tmp.path().join("workouts").join(POOL);
    let before: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let idx = json!({"schema": "healthaccess.index.v1", "updated": "2026-10-24T00:00:00Z", "workouts": [
        {"id": "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3", "file": POOL, "activity": "pool_swim",
         "start": "2026-05-14T05:12:04Z", "duration_s": 2166, "distance_m": 1200, "avg_hr": 129, "effort": null, "plan_name": null}
    ]});
    fs::write(
        tmp.path().join("index.json"),
        serde_json::to_string(&idx).unwrap(),
    )
    .unwrap();

    assert!(matches!(
        store.rate_workout("7a1c3e90", 11, None, false).unwrap_err(),
        Error::Validation(_)
    ));

    let out = store
        .rate_workout("7a1c3e90", 7, Some("legs heavy, breathing fine"), true)
        .unwrap();
    assert_eq!(out.effort, 7);
    assert!(out.index_updated);
    assert!(out.summary.contains("effort 7/10"), "{}", out.summary);

    let after: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(after["effort"], 7);
    assert_eq!(after["feel"], "legs heavy, breathing fine");
    let mut a = after.clone();
    let mut b = before.clone();
    assert_eq!(after["effort_source"], "ai");
    for v in [&mut a, &mut b] {
        let o = v.as_object_mut().unwrap();
        o.remove("effort");
        o.remove("effort_source");
        o.remove("feel");
    }
    assert_eq!(a, b, "nothing but effort, effort_source and feel changed");

    let index: Value =
        serde_json::from_str(&fs::read_to_string(tmp.path().join("index.json")).unwrap()).unwrap();
    assert_eq!(index["workouts"][0]["effort"], 7);
    assert!(
        !fs::read_to_string(tmp.path().join("index.json"))
            .unwrap()
            .contains('\n'),
        "compact stays compact"
    );

    // rating again without feel keeps the previous feel
    store.rate_workout("7a1c3e90", 5, None, false).unwrap();
    let again: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(again["effort"], 5);
    assert_eq!(again["feel"], "legs heavy, breathing fine");
    // no temp files left behind
    let leftovers: Vec<_> = fs::read_dir(tmp.path().join("workouts"))
        .unwrap()
        .filter(|e| {
            e.as_ref()
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains(".tmp-")
        })
        .collect();
    assert!(leftovers.is_empty());
}

fn s26_plan() -> Plan {
    serde_json::from_value(json!({
        "name": "S26", "sport": "pool_swim", "pool_length_m": 50,
        "warmup": {"goal": {"type": "time_s", "value": 120}, "zone": 1},
        "blocks": [
            {"repeat": 1, "steps": [
                {"kind": "work", "goal": {"type": "distance_m", "value": 200}, "zone": 2, "label": "Easy swim"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 45}}]},
            {"repeat": 3, "steps": [
                {"kind": "work", "goal": {"type": "distance_m", "value": 50}, "zone": 1, "label": "6-3-6: 6 kicks on side, 3 strokes"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 25}},
                {"kind": "work", "goal": {"type": "distance_m", "value": 50}, "zone": 2, "label": "Catch-up drill"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 30}}]},
            {"repeat": 3, "steps": [
                {"kind": "work", "goal": {"type": "distance_m", "value": 100}, "zone": 3, "label": "100 steady"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 40}}]}
        ],
        "cooldown": {"goal": {"type": "distance_m", "value": 100}, "zone": 1},
        "notes": "aerobic base", "scheduled_for": "2026-05-14T05:00:00Z"
    }))
    .unwrap()
}

#[test]
fn plans_are_written_listed_and_joined_onto_workouts() {
    let (tmp, store) = temp_store();
    let (plan, path) = store.write_plan(s26_plan(), "healthaccess-test").unwrap();
    assert!(path.starts_with(tmp.path().join("plans")));
    assert!(plan.id.ends_with("-s26"), "{}", plan.id);
    assert_eq!(plan.schema, "healthaccess.plan.v1");
    assert_eq!(plan.created_by.as_deref(), Some("healthaccess-test"));
    let text = fs::read_to_string(&path).unwrap();
    let first_key = text.lines().nth(1).unwrap().trim();
    assert!(
        first_key.starts_with("\"blocks\""),
        "sorted keys, got {first_key}"
    );

    let listed = store.list_plans().unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].state, "pending");
    assert_eq!(
        listed[0].planned_distance_m,
        200.0 + 3.0 * 100.0 + 300.0 + 100.0
    );
    assert_eq!(store.plan_status(&plan.id).unwrap(), None);
    assert!(matches!(
        store.plan_status("missing").unwrap_err(),
        Error::NotFound(_)
    ));

    fs::write(
        store.plan_status_path(&plan.id),
        json!({"plan_id": plan.id, "state": "scheduled", "at": "2026-10-23T07:00:00Z", "error": null}).to_string(),
    )
    .unwrap();
    assert_eq!(
        store.plan_status(&plan.id).unwrap().unwrap().state,
        "scheduled"
    );
    assert_eq!(store.list_plans().unwrap()[0].state, "scheduled");

    // the swim is scheduled within 2 h of S26, but S26 has fewer blocks than the swim
    // used, so the file's own plan_ref (S12, from the app) stays
    let w = store.load_workout("7a1c3e90").unwrap();
    assert_eq!(w.plan_ref.as_ref().unwrap().name.as_deref(), Some("S12"));

    // with the app's plans in the folder the join goes by plan_id and fills kinds
    for f in [
        "2026-05-13T19:02:11Z-s12.json",
        "2026-05-11T18:40:02Z-r4.json",
    ] {
        fs::copy(fixtures().join("plans").join(f), store.plans_dir().join(f)).unwrap();
    }
    let w = store.load_workout("7a1c3e90").unwrap();
    assert_eq!(
        w.plan_ref.as_ref().unwrap().plan_id.as_deref(),
        Some("2026-05-13T19:02:11Z-s12")
    );
    let drill = w.steps.iter().find(|s| s.key == "1.0.0").unwrap();
    assert_eq!(
        drill.label.as_deref(),
        Some("DRILL 6-3-6: 6 kicks side, 3 strokes")
    );
    assert_eq!(drill.kind, StepKind::Work);
    let rest = w.steps.iter().find(|s| s.key == "1.0.2").unwrap();
    assert_eq!(rest.kind, StepKind::Recovery);
    let cool = w.steps.iter().find(|s| s.key == "5.0.0").unwrap();
    assert_eq!(cool.kind, StepKind::Cooldown);
    assert!(store.summary(&w).contains("Pool swim \"S12\""));

    // a workout without plan_ref is matched by time: same sport, scheduled within 2 h
    let row_path = tmp.path().join("workouts").join(ROW);
    let mut doc: Value = serde_json::from_str(&fs::read_to_string(&row_path).unwrap()).unwrap();
    doc["plan_ref"] = Value::Null;
    fs::write(&row_path, doc.to_string()).unwrap();
    let row = store.load_workout("3f8b2d41").unwrap();
    assert_eq!(row.plan_ref.as_ref().unwrap().name.as_deref(), Some("R4"));
    assert_eq!(
        row.steps.iter().find(|s| s.key == "1.0.1").unwrap().kind,
        StepKind::Recovery
    );

    // validation errors are reported together
    let mut bad = s26_plan();
    bad.sport = "skiing".into();
    bad.blocks[0].steps[0].zone = Some(9);
    match store.write_plan(bad, "healthaccess-test").unwrap_err() {
        Error::Validation(p) => assert_eq!(p.len(), 2, "{p:?}"),
        other => panic!("{other:?}"),
    }
    // S26 plus its status file, and the two copied example plans
    assert_eq!(fs::read_dir(tmp.path().join("plans")).unwrap().count(), 4);
}

#[test]
fn weekly_summary_covers_both_fixtures() {
    let (_tmp, store) = temp_store();
    let today = NaiveDate::from_ymd_opt(2026, 5, 17).unwrap();
    let s = store.training_summary_at(8, today).unwrap();
    assert_eq!(s.weeks.len(), 8);
    assert_eq!(
        s.weeks[0].start,
        NaiveDate::from_ymd_opt(2026, 3, 23).unwrap()
    );
    assert_eq!(s.weeks[7].week, "2026-W20");
    assert_eq!(s.workouts_considered, 2);
    assert_eq!(s.bounds_source, None, "no config, no profile");
    let w20 = &s.weeks[7];
    assert_eq!(w20.sessions, 2);
    assert_eq!(w20.by_sport["indoor_row"].sessions, 1);
    assert_eq!(w20.by_sport["pool_swim"].sessions, 1);
    assert_eq!(w20.avg_hr, Some(132.0), "duration-weighted");
    assert_eq!(w20.duration_s, 3846.0);
    assert_eq!(w20.distance_m, 1200.0);
    assert_eq!(
        w20.z12_pct, None,
        "v0.4 files carry no zones and no bounds are known"
    );
    assert_eq!(w20.cardiac_cost, Some(284.0));
    assert_eq!(w20.mean_effort, Some(6.5), "Apple ratings count");
    assert_eq!(w20.rated_sessions, 2);
    assert_eq!(s.cardiac_cost_trend.len(), 1);
    assert_eq!(s.cardiac_cost_trend[0].name, "S12");
    assert_eq!(s.weeks.iter().filter(|w| w.sessions == 0).count(), 7);
    // with bounds the easy-zone share appears
    let configured = Store::open(_tmp.path())
        .unwrap()
        .with_zone_bounds(Some([133, 146, 159, 171]));
    let s = configured.training_summary_at(8, today).unwrap();
    assert_eq!(s.bounds_source, Some(derive::BoundsSource::Config));
    assert_eq!(s.weeks[7].z12_pct, Some(73.0));
}

#[test]
fn doctor_reports_broken_files() {
    let (tmp, store) = temp_store();
    fs::write(tmp.path().join("workouts").join("broken.json"), "{not json").unwrap();
    fs::create_dir_all(tmp.path().join("vitals")).unwrap();
    fs::write(
        tmp.path().join("vitals").join("2026-10-24.json"),
        json!({"schema": "healthaccess.vitals.v1", "date": "2026-10-24", "resting_hr": 54, "hrv_sdnn_ms": 44.1, "body_mass_kg": 78.4, "sleep_s": 26160, "steps": 9120, "vo2max": 46.3, "bp": null}).to_string(),
    )
    .unwrap();
    let report = store.doctor().unwrap();
    assert!(!report.healthy());
    assert_eq!(report.workouts.iter().filter(|f| !f.ok).count(), 1);
    assert_eq!(report.schema_counts["unknown"], 1);
    assert_eq!(report.vitals.len(), 1);
    assert!(report.vitals[0].ok);
    assert!(!report.index.present);
    let vitals = store.vitals(3650).unwrap();
    assert_eq!(vitals.len(), 1);
    assert_eq!(vitals[0].resting_hr, Some(54.0));
    assert!(Path::new(&report.dir).is_dir());
}

#[test]
fn rate_workout_marks_the_source_ai_and_keeps_apple_ratings_unless_overridden() {
    let (tmp, store) = temp_store();
    let path = tmp.path().join("workouts").join(ROW);
    // the example row carries the athlete's own Apple rating (7/10): refused as is
    let err = store
        .rate_workout("3f8b2d41", 6, Some("legs"), false)
        .unwrap_err();
    match &err {
        Error::Refused(msg) => {
            assert!(msg.contains("Apple") && msg.contains("7/10"), "{msg}");
            assert!(
                !msg.contains("validation"),
                "plain message, no prefix: {msg}"
            );
        }
        other => panic!("expected Refused, got {other:?}"),
    }
    assert_eq!(err.kind(), "refused");
    let untouched: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(untouched["effort"], 7);
    assert_eq!(untouched["effort_source"], "apple");
    assert_eq!(untouched["effort_estimated"], 6);

    // the athlete asked to change it
    let out = store
        .rate_workout("3f8b2d41", 6, Some("legs"), true)
        .unwrap();
    assert_eq!(out.effort, 6);
    assert_eq!(out.effort_source, "ai");
    assert_eq!(out.previous_effort, Some(7));
    assert_eq!(out.previous_source.as_deref(), Some("apple"));
    let after: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(after["effort"], 6);
    assert_eq!(after["effort_source"], "ai");
    assert_eq!(after["feel"], "legs");
    assert_eq!(
        after["effort_estimated"], 6,
        "Apple's estimate is never touched"
    );
    let w = store.load_workout("3f8b2d41").unwrap();
    assert_eq!(w.effort_source(), Some(EffortSource::Ai));
    assert!(
        store.summary(&w).contains("effort 6/10 (ai)"),
        "{}",
        store.summary(&w)
    );

    // once the number is the AI's, a plain re-rate works and keeps the note
    let out = store.rate_workout("3f8b2d41", 4, None, false).unwrap();
    assert_eq!(out.previous_source.as_deref(), Some("ai"));
    assert_eq!(out.feel.as_deref(), Some("legs"), "feel kept");

    // Apple's score is a double in HealthKit: floats round to the score and still protect
    let mut doc: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    doc["effort"] = json!(8.0);
    doc["effort_source"] = json!("apple");
    fs::write(&path, serde_json::to_string_pretty(&doc).unwrap()).unwrap();
    assert_eq!(store.load_workout("3f8b2d41").unwrap().effort, Some(8));
    assert!(matches!(
        store.rate_workout("3f8b2d41", 4, None, false).unwrap_err(),
        Error::Refused(_)
    ));
}

#[test]
fn index_rows_keep_effort_source_only_when_the_app_wrote_the_key() {
    let (tmp, store) = temp_store();
    let idx = json!({"schema": "healthaccess.index.v1", "updated": "2026-10-24T00:00:00Z", "workouts": [
        {"id": "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3", "file": POOL, "activity": "pool_swim",
         "start": "2026-05-14T05:12:04Z", "duration_s": 2166, "distance_m": 1200, "avg_hr": 129,
         "effort": 7, "effort_source": "apple", "plan_name": null},
        {"id": "3F8B2D41-9E6C-4A17-B2D8-5C3E7F9A1B04", "file": ROW, "activity": "indoor_row",
         "start": "2026-05-12T04:30:11Z", "duration_s": 1680, "distance_m": null, "avg_hr": 137,
         "effort": null, "plan_name": null}
    ]});
    fs::write(tmp.path().join("index.json"), idx.to_string()).unwrap();
    let index = store.index().unwrap();
    assert_eq!(index.workouts[0].effort_source.as_deref(), Some("apple"));
    assert_eq!(index.workouts[1].effort_source, None);
    // both files carry Apple ratings; the athlete asked to change them
    store.rate_workout("7a1c3e90", 5, None, true).unwrap();
    store.rate_workout("3f8b2d41", 3, None, true).unwrap();
    let raw: Value =
        serde_json::from_str(&fs::read_to_string(tmp.path().join("index.json")).unwrap()).unwrap();
    assert_eq!(raw["workouts"][0]["effort"], 5);
    assert_eq!(raw["workouts"][0]["effort_source"], "ai");
    assert_eq!(raw["workouts"][1]["effort"], 3);
    assert!(
        raw["workouts"][1].get("effort_source").is_none(),
        "the row's shape stays as the app wrote it"
    );
}

#[test]
fn parts_text_quotes_each_step_in_one_line() {
    let (_tmp, store) = temp_store();
    let w = store.load_workout("7a1c3e90").unwrap();
    let parts = derive::parts_text(&w);
    assert_eq!(parts.len(), w.steps.len());
    assert_eq!(
        parts[0], "FR easy, find your breathing · 200 m · 2:20/100 · HR 100",
        "{parts:?}"
    );
    let hundred = w.steps.iter().position(|s| s.key == "2.3.0").unwrap();
    assert_eq!(
        parts[hundred], "FR 100 steady, breathe every 3 · 100 m · 2:12/100 · HR 151",
        "{parts:?}"
    );
    // a step without a label falls back to its kind
    assert!(
        parts.contains(&"recovery · 0:30 · HR 126".to_string()),
        "{parts:?}"
    );
}

#[test]
fn briefing_is_generated_when_the_app_has_not_written_one() {
    let (tmp, store) = temp_store();
    fs::create_dir_all(tmp.path().join("vitals")).unwrap();
    // two days before the last week, two inside it: resting HR goes up, weight stays
    for (i, rhr) in [(1, 58.0), (2, 59.0), (15, 62.0), (16, 63.0)] {
        let date = format!("2026-05-{i:02}");
        fs::write(
            tmp.path().join("vitals").join(format!("{date}.json")),
            json!({"schema": "healthaccess.vitals.v1", "date": date, "resting_hr": rhr, "hrv_sdnn_ms": null,
                   "body_mass_kg": 78.0, "sleep_s": 26000, "steps": 8000, "vo2max": null, "bp": null}).to_string(),
        )
        .unwrap();
    }
    store.write_plan(s26_plan(), "healthaccess-test").unwrap();
    let now = "2026-05-17T09:00:00Z".parse().unwrap();
    let text = store.generate_briefing(now).unwrap();
    println!("{text}");
    let first = text.lines().next().unwrap();
    assert!(
        first.starts_with("# Health Access briefing for the athlete, written 2026-05-17T09:00Z")
    );
    assert!(
        first.contains("healthaccess-mcp") && first.contains("not by the app"),
        "{first}"
    );
    let headings: Vec<&str> = text.lines().filter(|l| l.starts_with("## ")).collect();
    assert_eq!(
        headings,
        [
            "## Last 4 weeks",
            "## Recent sessions",
            "## Vitals",
            "## Next session",
            "## Open",
            "## Limits"
        ]
    );
    assert!(text.lines().count() < 60, "{} lines", text.lines().count());
    assert!(
        text.contains("- 2026-W18 (2026-04-27 to 2026-05-03): no sessions"),
        "{text}"
    );
    assert!(
        text.contains(
            "- 2026-W20 (2026-05-11 to 2026-05-17): 2 sessions, 1200 m, 1:04:06, mean effort 6.5 (2 of 2 rated)"
        ),
        "{text}"
    );
    assert!(
        text.contains(
            "- 2026-05-14 Pool swim \"S12\": 1200 m, 36:06, avg HR 129, effort 6/10 (apple)"
        ),
        "{text}"
    );
    assert!(
        text.contains("- 2026-05-12 Indoor row \"R4\": 28:00, avg HR 137, effort 7/10 (apple)"),
        "{text}"
    );
    assert!(
        text.contains("- Resting HR 63 bpm (2026-05-16), 21 days: up"),
        "{text}"
    );
    assert!(text.contains("- HRV: no data"), "{text}");
    assert!(
        text.contains("- Sleep 7:13 h (2026-05-16), 21 days: flat"),
        "{text}"
    );
    assert!(
        text.contains("- Weight 78 kg (2026-05-16), 21 days: flat"),
        "{text}"
    );
    assert!(text.contains("- S26 (Pool swim): 900 m planned"), "{text}");
    assert!(text.contains("waiting for Put on Watch"), "{text}");
    assert!(
        !text.contains("without an effort rating"),
        "both sessions are rated: {text}"
    );
    assert!(
        text.contains("- 1 plan waiting for Put on Watch: S26"),
        "{text}"
    );
    assert!(
        text.contains("## Limits\nHealth data can only be read while the phone is unlocked"),
        "{text}"
    );
    assert!(!text.contains('\u{2014}'), "no em dashes");

    // the app's own briefing wins
    assert_eq!(store.briefing().unwrap().source, BriefingSource::Generated);
    fs::write(
        store.briefing_path(),
        "# Health Access briefing for Alex, written by the app\n",
    )
    .unwrap();
    let b = store.briefing().unwrap();
    assert_eq!(b.source, BriefingSource::File);
    assert!(b.text.starts_with("# Health Access briefing for Alex"));
}

#[test]
fn days_catalog_profile_and_ecg_are_read_and_checked() {
    let (tmp, store) = temp_store();
    let root = tmp.path();
    let d = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
    fs::create_dir_all(root.join("days")).unwrap();
    fs::create_dir_all(root.join("vitals")).unwrap();
    fs::create_dir_all(root.join("ecg")).unwrap();
    // the pre-v0.4 file for a day the app also wrote as a day file, and one older day
    fs::write(
        root.join("vitals/2026-10-24.json"),
        json!({"schema": "healthaccess.vitals.v1", "date": "2026-10-24", "resting_hr": 56, "hrv_sdnn_ms": 40.0,
               "body_mass_kg": null, "sleep_s": null, "steps": 100, "vo2max": null, "bp": null}).to_string(),
    )
    .unwrap();
    fs::write(
        root.join("vitals/2026-10-20.json"),
        json!({"schema": "healthaccess.vitals.v1", "date": "2026-10-20", "resting_hr": 55})
            .to_string(),
    )
    .unwrap();
    let day = |date: &str, rhr: f64, met: f64, move_actual: f64| {
        json!({
            "schema": "healthaccess.day.v1", "date": date,
            "activity": {"rings": {"move_kcal": {"goal": 600, "actual": move_actual}, "exercise_min": {"goal": 30, "actual": 41},
                                   "stand_hours": {"goal": 12, "actual": 12}, "move_mode": "active_energy"},
                         "steps": 9120, "physical_effort_avg_met": met},
            "heart": {"resting_hr": rhr, "hrv_sdnn_ms": null, "vo2max": 46.3},
            "sleep": {"asleep_s": 26160, "in_bed_s": 27900},
            "body": {"mass_kg": 78.4},
            "respiratory": {"rate_avg": 13.8},
            "nutrition": {"HKQuantityTypeIdentifierDietaryCaffeine": {"sum": 120}}
        })
    };
    fs::write(
        root.join("days/2026-10-24.json"),
        day("2026-10-24", 54.0, 2.4, 655.0).to_string(),
    )
    .unwrap();
    fs::write(
        root.join("days/2026-10-25.json"),
        day("2026-10-25", 55.0, 2.0, 500.0).to_string(),
    )
    .unwrap();

    // vitals: the day file wins, the old file fills what the day lacks, old-only days stay
    let vitals = store.vitals(3650).unwrap();
    assert_eq!(vitals.len(), 3);
    assert_eq!(vitals[0].date, d("2026-10-20"));
    let d24 = vitals.iter().find(|v| v.date == d("2026-10-24")).unwrap();
    assert_eq!(d24.resting_hr, Some(54.0), "day file wins");
    assert_eq!(d24.hrv_sdnn_ms, Some(40.0), "old file fills the gap");
    assert_eq!(d24.steps, Some(9120.0));
    assert_eq!(d24.sleep_s, Some(26160.0));
    assert_eq!(d24.body_mass_kg, Some(78.4));

    let days = store.days(d("2026-10-24"), d("2026-10-25")).unwrap();
    assert_eq!(days.len(), 2);
    assert_eq!(
        days[0].groups(),
        [
            "activity",
            "heart",
            "respiratory",
            "sleep",
            "body",
            "nutrition"
        ]
    );
    assert!(store.day(d("2026-10-23")).unwrap().is_none());
    assert!(store.has_days());

    // training summary gains ring totals and the mean physical effort
    let s = store.training_summary_at(2, d("2026-10-25")).unwrap();
    assert_eq!(s.days_considered, 2);
    let w43 = s.weeks.last().unwrap();
    assert_eq!(w43.days_with_data, 2);
    let rings = w43.rings.as_ref().unwrap();
    assert_eq!(rings.days, 2);
    assert_eq!(rings.move_kcal, 1155.0);
    assert_eq!(rings.exercise_min, 82.0);
    assert_eq!(rings.stand_hours, 24.0);
    assert_eq!(rings.move_goal_days, 1);
    assert_eq!(rings.exercise_goal_days, 2);
    assert_eq!(rings.stand_goal_days, 2);
    assert_eq!(w43.mean_physical_effort_met, Some(2.2));
    assert!(s.weeks[0].rings.is_none());
    assert!(s.notes.iter().any(|n| n.contains("rings")));

    // catalog and the coverage check
    fs::write(
        root.join("catalog.json"),
        json!({
            "generated": "2026-10-25T08:00:00Z", "app_version": "0.4.0",
            "types": {
                "HKQuantityTypeIdentifierHeartRate": {"kind": "quantity", "authorized": null, "has_data": true, "samples_90d": 50000, "first": "2026-07-28", "last": "2026-10-25", "exported_in": "workouts"},
                "HKQuantityTypeIdentifierBodyMass": {"kind": "quantity", "authorized": null, "has_data": true, "samples_90d": 12, "first": "2026-08-01", "last": "2026-10-24", "exported_in": "none"},
                "HKCategoryTypeIdentifierSleepAnalysis": {"kind": "category", "authorized": null, "has_data": true, "samples_90d": 400, "first": null, "last": null, "exported_in": "days"},
                "HKQuantityTypeIdentifierHoverboardSpeed": {"kind": "quantity", "authorized": null, "has_data": true, "samples_90d": 3, "first": null, "last": null, "exported_in": "days"},
                "HKWorkoutTypeIdentifier": {"kind": "workout", "authorized": null, "has_data": true, "samples_90d": 14, "first": null, "last": null, "exported_in": "workouts"},
                "HKQuantityTypeIdentifierBloodGlucose": {"kind": "quantity", "authorized": null, "has_data": false, "samples_90d": 0, "first": null, "last": null, "exported_in": "none"}
            },
            "unknown_types_with_data": []
        })
        .to_string(),
    )
    .unwrap();
    let cov = store.coverage().unwrap().unwrap();
    assert_eq!(cov.catalog_types, 6);
    assert_eq!(cov.with_data, 5);
    assert_eq!(cov.exported, 4);
    assert_eq!(
        cov.types_with_data_not_exported,
        ["HKQuantityTypeIdentifierBodyMass"]
    );
    assert_eq!(
        cov.unknown_types_with_data,
        ["HKQuantityTypeIdentifierHoverboardSpeed"]
    );
    assert_eq!(cov.app_version.as_deref(), Some("0.4.0"));
    assert!(!cov.clean());

    // profile and ECG summaries
    fs::write(
        root.join("profile.json"),
        json!({"age": 38, "birth_year": 1988, "biological_sex": "male", "blood_type": "not_set",
               "wheelchair_use": "no", "activity_move_mode": "active_energy", "fitzpatrick_skin_type": "not_set"}).to_string(),
    )
    .unwrap();
    let profile = store.profile().unwrap().unwrap();
    assert_eq!(profile.birth_year, Some(1988.0));
    assert_eq!(profile.biological_sex.as_deref(), Some("male"));
    fs::write(
        root.join("ecg/2026-10-24T07-31-05Z.json"),
        json!({"classification": "sinus_rhythm", "symptoms_status": "none", "average_heart_rate": 62,
               "sampling_frequency_hz": 512, "algorithm_version": "2", "device": {"name": "Apple Watch", "model": "Watch7,4"}}).to_string(),
    )
    .unwrap();
    fs::write(
        root.join("ecg/2026-10-24T07-31-05Z.voltage.json"),
        "[[0,0.1]]",
    )
    .unwrap();
    fs::write(
        root.join("ecg/2026-09-01T06-00-00Z.json"),
        json!({"classification": "inconclusive"}).to_string(),
    )
    .unwrap();
    let ecgs = store.ecgs().unwrap();
    assert_eq!(ecgs.len(), 2, "voltage sidecars are not ECGs");
    assert_eq!(ecgs[0].classification.as_deref(), Some("sinus_rhythm"));
    assert_eq!(ecgs[0].average_heart_rate, Some(62.0));
    assert_eq!(
        ecgs[0].voltage_file.as_deref(),
        Some("ecg/2026-10-24T07-31-05Z.voltage.json")
    );
    assert_eq!(
        ecgs[0].at.unwrap().to_rfc3339(),
        "2026-10-24T07:31:05+00:00"
    );
    assert!(ecgs[1].voltage_file.is_none());
    assert_eq!(ecgs[1].classification.as_deref(), Some("inconclusive"));

    // doctor sees all of it; coverage findings are warnings, parse failures are not
    let report = store.doctor().unwrap();
    assert!(report.days_dir);
    assert_eq!(report.days.len(), 2);
    assert!(report.days.iter().all(|f| f.ok));
    assert!(report.catalog.as_ref().unwrap().ok);
    assert!(report.profile.as_ref().unwrap().ok);
    assert_eq!(report.ecgs.len(), 2);
    let cov = report.coverage.as_ref().unwrap();
    assert_eq!(
        cov.unknown_types_with_data,
        ["HKQuantityTypeIdentifierHoverboardSpeed"]
    );
    assert!(report
        .warnings
        .iter()
        .any(|w| w.contains("exported nowhere") && w.contains("BodyMass")));
    assert!(report
        .warnings
        .iter()
        .any(|w| w.contains("not known to this build") && w.contains("HoverboardSpeed")));
    assert!(report.healthy(), "coverage findings are warnings");
    fs::write(root.join("catalog.json"), "{nope").unwrap();
    let report = store.doctor().unwrap();
    assert!(!report.catalog.as_ref().unwrap().ok);
    assert!(report.coverage.is_none());
    assert!(!report.healthy());
}

#[test]
fn zones_come_from_config_then_profile_then_the_file() {
    let (tmp, store) = temp_store();
    let d = |s: &str| NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
    let w = store.load_workout("7a1c3e90").unwrap();
    // nothing configured, no profile, no zones in the file: no zones, no guess
    assert_eq!(store.effective_bounds(), None);
    assert!(store.zones(&w).is_none());
    assert!(!store.summary(&w).contains("Z1–2"), "{}", store.summary(&w));

    // config wins and the seconds are recomputed from the series
    let configured = Store::open(tmp.path())
        .unwrap()
        .with_zone_bounds(Some([120, 130, 140, 150]));
    assert_eq!(
        configured.bounds_source(),
        Some(derive::BoundsSource::Config)
    );
    let z = configured.zones(&w).unwrap();
    assert_eq!(z.bounds_source.as_deref(), Some("config"));
    assert_eq!(z.bounds, vec![120, 130, 140, 150]);
    assert!(
        z.seconds.z5 > 0,
        "the 100s go above 150 bpm: {:?}",
        z.seconds
    );
    assert!(z.seconds.total() > 1800, "{:?}", z.seconds);

    // the athlete's age estimates the bounds when nothing is configured
    fs::write(
        tmp.path().join("profile.json"),
        json!({"age": 38}).to_string(),
    )
    .unwrap();
    let (bounds, source) = store.effective_bounds().unwrap();
    assert_eq!(source, derive::BoundsSource::Estimated);
    assert_eq!(bounds, [131, 143, 156, 167]);
    let z = store.zones(&w).unwrap();
    assert_eq!(z.bounds_source.as_deref(), Some("estimated"));
    assert_eq!(z.bounds, vec![131, 143, 156, 167]);
    let s = store.training_summary_at(2, d("2026-10-25")).unwrap();
    assert_eq!(s.bounds_source, Some(derive::BoundsSource::Estimated));
    assert_eq!(s.zone_bounds, Some([131, 143, 156, 167]));
    assert!(
        s.notes.iter().any(|n| n.contains("estimated from the age")),
        "{:?}",
        s.notes
    );
    assert!(store.summary(&w).contains("Z1–2 "), "{}", store.summary(&w));

    // birth_year works too
    let this_year = chrono::Datelike::year(&chrono::Utc::now().date_naive());
    fs::write(
        tmp.path().join("profile.json"),
        json!({"birth_year": this_year - 36}).to_string(),
    )
    .unwrap();
    assert_eq!(
        store.effective_bounds(),
        Some(([132, 144, 157, 168], derive::BoundsSource::Estimated))
    );

    // without a series, the zones an older app wrote into the file are the only source
    fs::remove_file(tmp.path().join("profile.json")).unwrap();
    let mut legacy = w.clone();
    legacy.hr_series.clear();
    legacy.zones = Some(Zones {
        bounds: vec![130, 140, 150, 160],
        bounds_source: None,
        seconds: ZoneSeconds {
            z1: 100,
            z2: 200,
            z3: 300,
            z4: 0,
            z5: 0,
        },
    });
    let z = store.zones(&legacy).unwrap();
    assert_eq!(z.bounds_source.as_deref(), Some("file"));
    assert_eq!(z.bounds, vec![130, 140, 150, 160]);
    assert_eq!(z.seconds.z3, 300);
    // and without those either there is nothing to say
    legacy.zones = None;
    assert!(store.zones(&legacy).is_none());
}

#[test]
fn handshake_files_are_written_updated_and_listed() {
    let (tmp, store) = temp_store();
    let info = ClientInfo {
        name: "Claude Code".into(),
        version: "2.1.0".into(),
    };
    let h = store.record_client(&info, None, 0).unwrap();
    assert_eq!(h.schema, "healthaccess.client.v1");
    assert_eq!(h.id, client_id(&machine_name(), "Claude Code"));
    assert_eq!(h.calls, 0);
    assert!(h.last_tool.is_none());
    assert_eq!(h.first_seen, h.last_seen);
    let path = store.client_path(&h.id);
    assert!(path.is_file());
    assert!(path.starts_with(tmp.path().join("mcp").join("clients")));
    let h2 = store
        .record_client(&info, Some("list_workouts"), 3)
        .unwrap();
    assert_eq!(h2.first_seen, h.first_seen, "first_seen is kept");
    assert!(h2.last_seen >= h.last_seen);
    assert_eq!(h2.calls, 3);
    assert_eq!(h2.last_tool.as_deref(), Some("list_workouts"));
    let raw: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let mut keys: Vec<&str> = raw
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort_unstable();
    assert_eq!(
        keys,
        [
            "calls",
            "client",
            "first_seen",
            "id",
            "last_seen",
            "last_tool",
            "machine",
            "mcp_version",
            "schema"
        ],
        "nothing but the handshake fields"
    );
    assert_eq!(raw["client"]["name"], "Claude Code");

    // the CLI sits beside it and doctor lists both
    store
        .record_client(
            &ClientInfo {
                name: "healthaccess-cli".into(),
                version: healthaccess_core::VERSION.into(),
            },
            Some("doctor"),
            1,
        )
        .unwrap();
    assert_eq!(store.list_clients().unwrap().len(), 2);
    let report = store.doctor().unwrap();
    assert_eq!(report.clients.len(), 2);
    assert!(report.healthy());

    // the recorder writes on connect and throttles tool calls to once a minute
    let rec = Recorder::new(store.clone());
    let c = rec
        .connected(ClientInfo {
            name: "Cursor".into(),
            version: "1".into(),
        })
        .unwrap();
    assert_eq!(c.calls, 0);
    assert!(
        rec.tool_called("get_workout").unwrap().is_none(),
        "within a minute of the connect write nothing is written"
    );
    let flushed = rec.flush().unwrap().unwrap();
    assert_eq!(flushed.calls, 1);
    assert_eq!(flushed.last_tool.as_deref(), Some("get_workout"));
    assert!(rec.flush().unwrap().is_none(), "nothing pending");
    assert_eq!(store.list_clients().unwrap().len(), 3);
}

// ------------------------------------------------------------ confinement (security)

#[test]
fn ids_and_index_rows_cannot_reach_outside_the_folder() {
    let (tmp, store) = temp_store();
    // a workout-shaped file and a secret outside the folder
    let outside = tempfile::tempdir().unwrap();
    let pool = fs::read_to_string(tmp.path().join("workouts").join(POOL)).unwrap();
    let elsewhere = outside.path().join("elsewhere-workout.json");
    fs::write(&elsewhere, &pool).unwrap();
    fs::write(outside.path().join("creds.json"), r#"{"schema": "my-private-token-ABC123"}"#).unwrap();
    fs::write(outside.path().join("secret.status.json"), r#"{"plan_id":"x","state":"scheduled","at":"2026-05-14T05:00:00Z","error":null}"#).unwrap();
    fs::write(outside.path().join("secret.json"), "{}").unwrap();

    // absolute paths and `..` in ids are refused
    let abs = elsewhere.display().to_string();
    assert!(store.resolve(&abs).is_err(), "absolute path outside the folder");
    let rel = format!("../{}/elsewhere-workout.json", outside.path().file_name().unwrap().to_string_lossy());
    assert!(store.resolve(&rel).is_err(), "relative path outside the folder");
    assert!(store.rate_workout(&abs, 3, Some("x"), false).is_err());
    let err = store.resolve(&outside.path().join("creds.json").display().to_string()).unwrap_err().to_string();
    assert!(!err.contains("ABC123"), "file contents never echo: {err}");
    let secret = format!("../../{}/secret", outside.path().file_name().unwrap().to_string_lossy());
    assert!(store.plan_status(&secret).is_err(), "plan ids are plain names");
    assert!(store.plan(&secret).is_err());

    // an index row that points outside resolves to nothing, and nothing is written there
    let mut idx: Value = serde_json::from_str(&fs::read_to_string(tmp.path().join("index.json")).unwrap_or_else(|_| r#"{"schema":"healthaccess.index.v1","updated":"2026-05-17T00:00:00Z","workouts":[]}"#.into())).unwrap();
    idx["workouts"].as_array_mut().unwrap().push(json!({"id": "CAFEF00D-0000-4000-8000-000000000000", "file": abs, "activity": "pool_swim", "start": "2026-05-15T05:00:00Z", "duration_s": 60}));
    fs::write(tmp.path().join("index.json"), idx.to_string()).unwrap();
    let before = fs::read_to_string(&elsewhere).unwrap();
    let _ = store.rate_workout("CAFEF00D", 3, Some("x"), false);
    assert_eq!(fs::read_to_string(&elsewhere).unwrap(), before, "the outside file is untouched");
}

#[test]
fn rating_only_writes_into_workout_files() {
    let (tmp, store) = temp_store();
    let not_a_workout = tmp.path().join("workouts").join("notes.json");
    fs::write(&not_a_workout, r#"{"schema": "something.else.v1", "secret": 1}"#).unwrap();
    assert!(store.rate_workout("notes.json", 4, None, false).is_err());
    assert!(!fs::read_to_string(&not_a_workout).unwrap().contains("effort"));
}

#[cfg(unix)]
#[test]
fn symlinks_and_fifos_are_not_read() {
    let (tmp, store) = temp_store();
    let outside = tempfile::tempdir().unwrap();
    let target = outside.path().join("t.json");
    fs::write(&target, fs::read_to_string(tmp.path().join("workouts").join(POOL)).unwrap()).unwrap();
    std::os::unix::fs::symlink(&target, tmp.path().join("workouts").join("link.json")).unwrap();
    assert!(store.resolve("link.json").is_err(), "a symlink inside workouts/ is not followed");
    let fifo = tmp.path().join("workouts").join("pipe.json");
    assert!(std::process::Command::new("mkfifo").arg(&fifo).status().unwrap().success());
    assert!(store.resolve("pipe.json").is_err(), "a FIFO is refused instead of blocking");
}

#[test]
fn plan_numbers_have_upper_bounds() {
    let (_tmp, store) = temp_store();
    let mut p = s26_plan();
    p.blocks[0].steps[0].goal.value = 1e19;
    assert!(store.write_plan(p, "healthaccess-test").is_err());
    let mut p = s26_plan();
    p.pool_length_m = Some(1e300);
    assert!(store.write_plan(p, "healthaccess-test").is_err());
}
