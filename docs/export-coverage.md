# Export coverage audit (2026-10-25)

Ground truth: every data type in the iOS 27.1 SDK's HealthKit headers, enumerated by grep, not from memory. Counts: **122 quantity types, 73 category types, 6 characteristics, 2 correlations**, plus the special types `HKWorkoutType`, `HKWorkoutRoute`, `HKActivitySummary` (the rings), `HKElectrocardiogram`, `HKHeartbeatSeries`, `HKStateOfMind` (mood logging, iOS 18), `HKScoredAssessment` (PHQ-9 / GAD-7), `HKAudiogram`, `HKVisionPrescription`, `HKMedicationDoseEvent` (iOS 26), and clinical records (FHIR, separate entitlement). 71 metadata keys.

## Verdict on v0.2 / v0.3
The workout file is good on the swim specifics and thin on everything else. The daily file covers 7 metrics out of roughly 90 that a person with a Watch actually produces. Two concrete misses that matter now:
1. **The athlete's own Effort rating** (`WorkoutEffortScore`, iOS 18) and Apple's **estimated** effort were not read at all. Fixed in the contract; app and MCP are implementing it.
2. **Apple's own 1-minute heart-rate recovery** (`HeartRateRecoveryOneMinute`) exists as a sample; we were computing our own from the series. Export Apple's and keep ours as `recovery_hr.computed`.

## Rule going forward: export everything, catalogued
Rather than a hand-picked list, the app embeds the full SDK identifier list, requests read access to **all of it**, and writes whatever has data. A `catalog.json` reports, per type: authorized, has data, sample count (90 days), first and last date. `healthaccess doctor` compares the catalog against the embedded list and prints "types with data that are not exported" (should always be empty) and "new types in Health not known to this build" (the signal to update). That is the triple check, every sync, forever.

## Files

### `workouts/<...>.json` (per workout, exhaustive)
Keep everything in v1 except `zones` (app-computed zone seconds; the MCP/CLI compute them from `hr_series`, see schema.md "Zones") and add:
- `effort`, `effort_source`, `effort_estimated` (see schema.md "Effort").
- `recovery_hr.apple_1min` from `HeartRateRecoveryOneMinute` + its metadata (`HeartRateRecoveryActivityType`, `...MaxObservedRecoveryHeartRate`); `recovery_hr.computed` as today.
- `statistics`: every entry of `HKWorkout.allStatistics` as `{type: {avg, min, max, sum}}` where present (heart rate, distance types, energy, swimming stroke count, running power/speed/stride/vertical oscillation/ground contact, cycling power/cadence/speed, rowing speed, paddle/skiing speeds, physical effort, respiratory rate, oxygen saturation, underwater depth, water temperature, elevation).
- `totals`: `swimming_stroke_count`, `flights_climbed`, `energy_basal` if present.
- `events`: ALL event types (lap, segment, marker, pause, resume, motion_paused, motion_resumed) with metadata, not just laps. `laps[]` stays as the derived swim view.
- `series`: per-sample series inside the workout window, downsampled to ≥4 s: `heart_rate` (today), `respiratory_rate`, `oxygen_saturation`, `running_power`, `running_speed`, `cycling_power`, `cycling_cadence`, `rowing_speed`, `physical_effort`, `underwater_depth`, `water_temperature`, `swimming_stroke_count`, `distance_<sport>` per sample (gives per-length distance for swims). Only series that have samples are present.
- `route`: for outdoor workouts, `HKWorkoutRouteQuery` → sidecar `workouts/<name>.route.json` with `[[t, lat, lon, alt_m, h_acc_m, speed_mps, course_deg], …]`; main file carries `route_file` and a summary (points, distance, ascent from `ElevationAscended`).
- `device`: name, model, manufacturer, OS version from `sourceRevision` and `device`.
- `metadata`: all keys, stringified (today), plus typed copies of the useful ones: `indoor`, `pool_length_m`, `swimming_location`, `weather` {temp_c, humidity, condition}, `elevation_ascended_m`, `average_mets`, `coached`, `fitness_plus`, `brand`, `time_zone`.
- `plan_ref`, `workout_plan_id` (WorkoutKit) as today.

### `days/YYYY-MM-DD.json` (replaces `vitals/`; `vitals/` stays as an alias for one release)
Groups, each present only when it has data; inside a present group, absent values are explicit `null`:
- `activity`: rings from `HKActivitySummary` (move kcal goal/actual, exercise min goal/actual, stand hours goal/actual, move mode), `steps`, `distance_walking_running_m`, `distance_cycling_m`, `distance_swimming_m`, other distance types present, `flights_climbed`, `active_energy_kcal`, `basal_energy_kcal`, `exercise_min`, `stand_min`, `move_min`, `time_in_daylight_min`, `physical_effort_avg_met`, `push_count`.
- `heart`: `resting_hr`, `walking_hr_avg`, `hr` {min, avg, max, samples}, `hrv_sdnn_ms`, `hrv_rmssd_ms` (if present), `recovery_1min_bpm` (Apple's, non-workout contexts), `vo2max`, `afib_burden_pct`, `events` {high_hr, low_hr, irregular_rhythm, low_cardio_fitness} counts with times.
- `respiratory`: `rate_avg`, `spo2` {avg, min}, `breathing_disturbances`, `sleep_apnea_events`, `fev1`, `fvc`, `peak_flow` if present.
- `sleep`: `in_bed_s`, `asleep_s`, `core_s`, `deep_s`, `rem_s`, `awake_s`, `sessions` [{start, end, source}], `wrist_temperature_delta_c`, `respiratory_rate_sleep`, `spo2_sleep`.
- `body`: `mass_kg`, `fat_pct`, `lean_kg`, `bmi`, `waist_cm`, `height_cm`, `temperature_c`, `basal_body_temperature_c`.
- `blood`: `pressure` [{sys, dia, at}], `glucose` [{mmol_l, at, meal_time}], `alcohol_pct`, `insulin` [{units, reason, at}].
- `mobility`: `walking_speed_mps`, `step_length_m`, `asymmetry_pct`, `double_support_pct`, `stair_ascent_mps`, `stair_descent_mps`, `steadiness_pct` + events, `six_minute_walk_m`, `falls`.
- `hearing`: `environmental_exposure_db`, `headphone_exposure_db`, events.
- `nutrition`: every `Dietary*` quantity that has a sample that day (energy, macros, water, caffeine, micronutrients), by identifier.
- `mind`: `mindful_minutes`, `state_of_mind` [{at, kind, valence, labels, associations}], `assessments` [{kind: phq9|gad7, score, risk, at}].
- `symptoms`: any of the 30+ symptom category types logged that day: [{type, severity, at}].
- `cycle`: `menstrual_flow`, `cycle_start`, ovulation/pregnancy/progesterone test results, contraceptive, lactation, menopausal state, and the related symptom types. Present only when data exists. **Settings toggle "Include reproductive health data", default on**, off removes the group and the types from the read request.
- `medications`: dose events (iOS 26) [{name if available, at, status}].
- `hygiene`: handwashing count, toothbrushing count.
- `uv`: `uv_index_max`.
- `wheelchair`: push count, wheelchair distance (also under activity).
- `audiogram`, `vision`: rare, exported when present as raw dictionaries.

### `ecg/<timestamp>.json`
`HKElectrocardiogramQuery`: classification, symptoms status, average heart rate, sampling frequency, algorithm version, device; voltage series in a sidecar `ecg/<timestamp>.voltage.json` only when Settings → "Include ECG voltage" is on (large).

### `profile.json`
`age` and `birth_year` (not the full date), `biological_sex`, `blood_type`, `wheelchair_use`, `activity_move_mode`, `fitzpatrick_skin_type`. Characteristics are read once per sync.

### `catalog.json`
`{ "generated": …, "app_version": …, "types": { "<identifier>": { "kind": "quantity|category|…", "authorized": bool|null, "has_data": bool, "samples_90d": n, "first": date|null, "last": date|null, "exported_in": "workouts|days|ecg|profile|none" } }, "unknown_types_with_data": [] }`. Note: iOS hides read-authorization state; `authorized` is `null` and `has_data` is the real signal.

## Not exported, and why
- **Clinical records (FHIR)**: needs the `health-records` entitlement and Apple approval; also only exists for US/UK providers. Later, as its own folder `clinical/`.
- **Raw per-sample history outside workouts** (every heart-rate sample of the day): daily aggregates are what an AI uses; raw dumps are available on demand through the CLI later (`healthaccess samples <type> --from --to`), not written by default.
- **Workout route voltage/ECG voltage by default**: size. Sidecars behind toggles.

## Permission sheet
One request with all read types. The usage string says: "Health Access writes the Health data you allow into a folder you choose, as files for your AI or coach. Everything is optional; nothing leaves your phone." App Review accepts this for export apps (Health Auto Export does the same). We never request write access.

## Sequencing
1. App agent, after the v0.3 UI lands: implement this as the v0.4 export engine (`days/`, `catalog.json`, `profile.json`, `ecg/`, the workout additions), with a migration that keeps writing `vitals/` for one release.
2. Rust: parse `days/`, `catalog.json`, `profile.json`; tools `get_day`, `get_days(from,to,groups)`, `get_catalog`, `get_profile`, `list_ecgs`; `doctor` coverage check; `training_summary` gains physical effort and ring totals.
3. Docs: the files page lists every group with one example (synthetic, from `examples/days/2026-05-14.json`; `examples/generate.py` keeps it consistent).
