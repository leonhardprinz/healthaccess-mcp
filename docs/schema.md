# Health Access MCP data contract v1 — the folder is the API

## Schema ids and aliases (rename of 2026-10-25)

The project was renamed from the codename "Tide" to **Health Access MCP**. The ids written from now on are:

| document | schema id written | pre-rename id, accepted forever as an alias |
|---|---|---|
| `workouts/*.json` | `healthaccess.workout.v1` | `tide.workout.v1` (and the Phase 0 format `tide.workout.v0`) |
| `vitals/*.json` | `healthaccess.vitals.v1` | `tide.vitals.v1` |
| `index.json` | `healthaccess.index.v1` | `tide.index.v1` |
| `plans/*.json` | `healthaccess.plan.v1` | `tide.plan.v1` |
| `plans/*.status.json` | (no schema field) | — |

**Alias rule.** Every parser — the iOS app (Swift) and `healthaccess-core` (Rust: MCP server and CLI) — accepts the old `tide.*` ids exactly like the new ones, for v0 and v1, with no end date. Existing files are never rewritten just to change the tag; `rate_workout` patches only `effort`/`feel` and leaves the tag as it found it. The MCP/CLI upgrades a plan it writes to `healthaccess.plan.v1` even when the assistant passed the old tag. The same applies to the workout key `tide_version`, which is now `healthaccess_version`: files carrying the old key still decode (alias). `healthaccess doctor` reports the tag exactly as written per file.

## Deviations (iOS app v0.2.0)

What the app actually does where the text below is silent, impossible or ambiguous. No field names or types change.

1. **Pool length is not sent to the Watch.** WorkoutKit's `CustomWorkout` has no pool-length or swimming-location parameter (only `location: .indoor`; `swimmingLocation` exists on `SingleGoalWorkout` alone). The Watch uses its own pool setting; the app shows `pool_length_m` as a reminder.
2. **`plans/<id>.status.json` gains three optional keys**: `method` (`schedule` | `preview`), `workoutkit_id` (UUID of the WorkoutKit `WorkoutPlan`) and `scheduled_for`. `state: scheduled` is also written when the plan was installed through Apple's preview sheet ("Add to Watch"), which does not schedule a date and does not report back — the app asks the user and records `method: preview`. Status files are overwritten on retry (never deleted).
3. **`plan_ref` matching**: first `HKWorkout.workoutPlan.id == workoutkit_id` (exact), then the documented fallback (same sport, `scheduled_for` within ±2 h). Watch-authored workouts match nothing → `null`. Display names are not used (Apple does not expose them on `HKWorkout`).
4. **`steps[]`**: `goal_met` is `null` when HealthKit has no `WOIntervalStepSuccessful`. A workout with one activity and no `WOIntervalStepKeyPath` gets `steps: []`. Activities without a key path (multi-sport) get `key` = activity index, `block` = index, `rep`/`step` = 0. `kind` without a matched plan is inferred: `0.0.0` → `warmup`, trailing single-step block → `cooldown`, distance recorded or distance goal → `work`, else `recovery`.
5. **`recovery_hr` can be `null` at first**: the observer wakes the app before the 2-minute window has passed; the next run (any trigger) patches `recovery_hr` and `max_hr` in place, leaving `effort`/`feel` untouched.
6. **Dedupe never deletes**: the shorter duplicate stays in `workouts/` and is left out of `index.json`. Files are never overwritten by export either (a workout whose `<uuid8>` file exists is skipped).
7. **Series and statistics**: `hr_series` keeps ≥ 4 s spacing (first and last kept); `avg_hr`/`max_hr` come from HealthKit's workout statistics when present, else from the series. Zone seconds are not written by the app any more (see "Zones"); the rule the MCP/CLI uses is the one the app used: each sample's time until the next sample, capped at 60 s, within `[start, end]`.
8. **`index.json.file`** is relative to the folder: `workouts/<name>.json`.
9. **Vitals**: `sleep_s` is credited to the day the sleep ended (the morning), summing asleep core/deep/REM/unspecified of the source with the most sleep (no double counting across Watch and iPhone); `hrv_sdnn_ms` is the day's average; `resting_hr`, `body_mass_kg`, `vo2max`, `bp` are the day's latest; `steps` the day's sum. A day with no values gets no file. Each run refreshes today and yesterday; 30-day backfill in Settings.
10. **Step labels on the Watch** need iOS 18 (`WorkoutStep.displayName`); labels longer than 40 characters are truncated (logged). Zone alerts the activity does not support are dropped (logged).
11. **Telemetry** is PostHog's SDK with a `setBeforeSend` allowlist: event name + the event's own numbers, `$app_version`, `$app_build`, `$os_name`, `$os_version`, `$lib`, `$lib_version`, `$device_type`, anonymous install id. Nothing else.


Everything lives under the user-chosen folder (`HEALTHACCESS_DIR`, e.g. `/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/Health Access`; the pre-rename `TIDE_DIR` is still read as an alias). The iOS app writes `workouts/`, `vitals/` (`days/`, `catalog.json` and `profile.json` from v0.4, see `docs/export-coverage.md`), `index.json`, `plans/*.status.json` and `briefing.md`. The MCP server/CLI writes `plans/*.json`, `mcp/clients/*.json` (see below) and may *update* `effort`/`feel` in a workout file via `rate_workout`. Nothing else writes. All JSON: UTF-8, sorted keys, ISO-8601 UTC timestamps with `Z`.

A complete synthetic folder is in `examples/` (generated by `examples/generate.py`, not a real person); every excerpt below is taken from it.

## workouts/<yyyy-MM-dd_HHmm>_<ActivityName>_<uuid8>.json
```jsonc
{
  "schema": "healthaccess.workout.v1",   // files written before the rename: "tide.workout.v1" (alias, accepted forever)
  "healthaccess_version": "0.4.0",      // was "tide_version" before the rename (alias, accepted on read)
  "id": "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3",   // HKWorkout UUID, full
  "activity": "pool_swim",         // pool_swim | open_water_swim | indoor_row | run | walk | cycle | other:<hk raw>
  "source": "Apple Watch",         // the HKSource name as Apple reports it
  "start": "2026-05-14T05:12:04Z", "end": "2026-05-14T05:48:10Z", "duration_s": 2166,
  "distance_m": 1200, "active_kcal": 338.6, "avg_hr": 129, "max_hr": 162,
  "pool_length_m": 50,             // from HKLapLength when present
  "zones": { "bounds": [..4 bpm..], "seconds": {"z1":…,"z5":…} },   // LEGACY, optional: app-computed in files before v0.4, not written any more; see "Zones"
  "plan_ref": { "plan_id": "2026-05-13T19:02:11Z-s12", "name": "S12" } | null,   // the plan the session was started from: WorkoutKit id first, else sport + schedule time ±2h
  "steps": [                        // one per HKWorkoutActivity, in order
    { "key": "1.0.0", "block": 1, "rep": 0, "step": 0,
      "label": "DRILL 6-3-6: 6 kicks side, 3 strokes" | null,   // joined from plan_ref when available
      "kind": "work" | "recovery" | "warmup" | "cooldown",       // from plan if matched, else inferred (distance goal → work)
      "start": "2026-05-14T05:16:43Z", "end": "2026-05-14T05:18:08Z", "duration_s": 85,
      "distance_m": 50 | null, "avg_hr": 125 | null, "goal_met": true | null,
      "pace_s_per_100m": 170.0 | null }
  ],
  "laps": [ { "start":"2026-05-14T05:12:07Z","end":"2026-05-14T05:13:14Z","duration_s":67,"stroke":"freestyle","swolf":88.0 } ],  // HKWorkoutEvent type 3; stroke from HKSwimmingStrokeStyle (1 mixed,2 freestyle,3 backstroke,4 breaststroke,5 butterfly,6 kickboard); swolf null for kick lengths
  "hr_series": [["2026-05-14T05:12:05Z",84], …],   // 1 sample/~5s; omitted by MCP unless asked
  "recovery_hr": { "end": 115, "1min": 104, "2min": 96 } | null,
  "effort": 6 | null, "effort_source": "apple" | "app" | "ai" | null, "effort_estimated": 5 | null,   // see "Effort"
  "feel": "legs heavy, breathing fine" | null,   // free text, app or ai
  "metadata": { "HKLapLength": "50 m", "HKTimeZone": "Europe/Berlin", … }   // raw HK metadata, stringified
}
```

## vitals/<yyyy-MM-dd>.json  (one per day, rewritten when values change)
`{ "schema":"healthaccess.vitals.v1", "date":"2026-05-14", "resting_hr":54, "hrv_sdnn_ms":58.3, "body_mass_kg":78.4, "sleep_s":26160, "steps":9412, "vo2max":44.1, "bp": {"sys":122,"dia":79,"at":"…"} | null }` — each field nullable. From v0.4 the app writes `days/<yyyy-MM-dd>.json` with every Health group (`docs/export-coverage.md`; example `examples/days/2026-05-14.json`) and keeps `vitals/` for one release.

## index.json  (rewritten by the app after every export)
`{ "schema":"healthaccess.index.v1", "updated":"…", "workouts":[ {"id","file","activity","start","duration_s","distance_m","avg_hr","effort","plan_name"} ] }` — newest first, no series. The MCP reads this for listing and only opens individual files on demand. Rows may also carry `source` (so every reader can apply the dedupe rule to the index itself) and `effort_source`; readers ignore keys they do not know. Example: `examples/index.json`.

## plans/<plan_id>.json  (written by MCP/CLI, consumed by the app)
```jsonc
{ "schema":"healthaccess.plan.v1", "id":"2026-05-13T19:02:11Z-s12", "name":"S12",
  "sport":"run" | "indoor_run" | "walk" | "hike" | "cycle" | "indoor_cycle" | "pool_swim" | "open_water_swim" | "indoor_row" | "hiit" | "elliptical", "pool_length_m": 50 | null,
  "warmup": {"goal":{"type":"distance_m","value":200},"zone":1,"label":"FR easy, find your breathing"} | null,
  "blocks":[ {"repeat":3, "steps":[
     {"kind":"work","goal":{"type":"distance_m","value":50},"zone":1,"label":"DRILL 6-3-6: 6 kicks side, 3 strokes"},
     {"kind":"work","goal":{"type":"distance_m","value":50},"zone":1,"label":"FR easy, long strokes"},
     {"kind":"recovery","goal":{"type":"time_s","value":30}} ]}, … ],
  "cooldown": {"goal":{"type":"distance_m","value":100},"zone":1,"label":"Easy, any stroke, long exhale"} | null,
  "notes":"what this session is for, shown in-app",
  "created_by":"claude-code", "created_at":"2026-05-13T19:02:11Z",   // default: healthaccess-mcp or healthaccess-cli
  "scheduled_for":"2026-05-14T05:00:00Z" | null }
```
Full example: `examples/plans/2026-05-13T19:02:11Z-s12.json`; the swim it produced is `examples/workouts/2026-05-14_0712_PoolSwim_7A1C3E90.json`, with the labels joined onto its steps.

Labels ≤ 40 chars. Zones 1–5 map to the Watch's own HR zones. The app validates, then calls WorkoutKit `WorkoutScheduler.schedule` (or presents the preview sheet if the user prefers), and writes:

## plans/<plan_id>.status.json  (written by the app)
`{ "plan_id":"…", "state":"scheduled" | "failed" | "cancelled", "at":"…", "error": null | "…" }` plus the optional keys of deviation 2. `scheduled` is written when the plan is on the Watch (by a tap on Put on Watch or by Automatic, `method: schedule`, with `scheduled_for`: the plan's own time while it is ahead, else the next morning 10:00); `cancelled` when the athlete removed it with Remove from Watch; `failed` with the error text. No status file means pending (example: `examples/plans/2026-05-13T19:02:11Z-s12.status.json`).

## mcp/clients/<id>.json  (written by the MCP, read by the app)
```jsonc
{ "schema":"healthaccess.client.v1", "id":"<stable id per machine+client>",
  "client":{"name":"Claude Code","version":"…"}, "machine":"Alex's MacBook Pro", "mcp_version":"0.2.0",
  "first_seen":"…", "last_seen":"…", "last_tool":"list_workouts", "calls":123 }
```
Written by the MCP server on start and after tool calls (throttled to once a minute); one file per machine and client, overwritten in place. The app shows "Connected · <client> on <machine> · last seen <relative>" when any file is newer than 7 days, else "Not connected yet". The file never contains tool arguments or results; it is the only thing the MCP writes outside `plans/` and the two rating fields.


## briefing.md  (written by the app after every sync; any AI can read it without the MCP)
Plain Markdown, one page, overwritten each time. Sections in this order: "Health Access briefing for <name or 'the athlete'>, written <timestamp>", "Last 4 weeks" (per ISO week: sessions, distance, time, mean effort if rated), "Recent sessions" (newest first, max 10, one line each: date, name/plan, distance, duration, avg HR, effort), "Vitals" (latest resting HR, HRV, sleep, weight with the date, and the 21-day direction up/down/flat), "Next session" (the newest plan without a scheduled status, or "none"), "Open" (unrated sessions, a plan waiting for Put on Watch), "Limits" (two fixed sentences: phone must be unlocked for export; Watch keeps its own pool length). No charts, no JSON. Target under 60 lines.

## Storage
Any folder the iOS Files app can open: iCloud Drive, Dropbox, Google Drive, OneDrive, Proton Drive, SMB/NAS, On My iPhone. The app stores a security-scoped bookmark. The only requirement for the AI side is that the same folder is reachable from the machine the AI runs on; the app does not know that path. The "setup message" the app copies contains the folder's display name and, when the provider is iCloud Drive, the usual Mac path `~/Library/Mobile Documents/com~apple~CloudDocs/<relative path>`; otherwise it asks the AI to ask the user where the folder lives on the computer.


## Effort (corrected 2026-10-25)
Apple DOES export the athlete's own Effort rating: `HKQuantityTypeIdentifierWorkoutEffortScore` (iOS 18+, unit `appleEffortScore`, 1 to 10, the number the athlete enters on the Watch or in Fitness after a workout) and `HKQuantityTypeIdentifierEstimatedWorkoutEffortScore` (Apple's own estimate), both fetched with `HKQuery.predicateForWorkoutEffortSamplesRelatedToWorkout(_:activity:)`. Fields:
- `effort` (1 to 10 or null) and `effort_source`: `"apple"` (the athlete's rating from Apple), `"app"` (rated in Health Access), `"ai"` (written by `rate_workout`, only ever after the athlete said the number).
- `effort_estimated` (Apple's estimate, 1 to 10 or null). Never used as `effort`.
- `feel` (free text, app or ai).
Precedence: an Apple rating that arrives later overwrites an `ai` effort, and an `app` effort written by an older build. The app itself never asks for a rating (v0.3.1 and later): the Watch asks after the workout, Apple exports the number, and the app shows "Rated 6 on your Watch". `app` stays in the contract for files written by earlier builds. The app's one notification is "Your AI wrote S27", when a plan file appears.

## Zones (changed 2026-10-25)
Workout files no longer carry app-computed `zones`; they keep `hr_series` and Apple's statistics (`avg_hr`, `max_hr`). Zone seconds are computed by the MCP and the CLI, with the rule of deviation 7, from four upper bounds (zones 1 to 4 in bpm; zone 5 is everything above):
- `zone_bounds = [133, 146, 158, 170]` in `~/.config/healthaccess/config.toml`, when set (`bounds_source: "config"`);
- otherwise an estimate from the age in `profile.json`: max HR = 208 − 0.7 × age, bounds at 72 / 79 / 86 / 92 % of max, rounded to the nearest bpm (`bounds_source: "estimated"`). Age 34 gives max 184.2 and `[133, 146, 158, 170]`. A population formula, documented as an estimate wherever it is shown; a tested or felt threshold belongs in the config.

Every zone output (`get_workout`, `training_summary`, `healthaccess show`, `healthaccess summary`) states `bounds` and `bounds_source`. A `zones` object in an older file is accepted (legacy) and used only when its bounds equal the bounds in force; otherwise the series is recomputed. When neither config nor age is available, zone output is omitted and the result says why.

## Rules
- Dedupe: two workouts with the same `start` (±2 s) and the same `source` are one workout; keep the longer.
- The app never deletes files. The MCP never writes under `workouts/` except the two rating fields; besides `plans/<id>.json` its only other file is `mcp/clients/<id>.json`.
- No health value ever leaves the folder via telemetry. Telemetry (opt-in, both sides) carries only: event name, tool name, duration, success/failure, app/MCP version, OS version, anonymous install id.
