# Health Access MCP server and CLI

The Rust half of Health Access MCP: `healthaccess_core` (library, crate `healthaccess-core`),
`healthaccess-mcp` (MCP server over stdio) and `healthaccess` (CLI, crate `healthaccess-cli`).
All three read the folder the iOS app writes (`HEALTHACCESS_DIR`, contract in
[`schema.md`](schema.md), the v0.4 export files in [`export-coverage.md`](export-coverage.md))
and write only `plans/<id>.json`, the rating keys of a workout file (`effort`,
`effort_source`, `feel`) and their own handshake file `mcp/clients/<id>.json`.

Health Access is middleware. The app does the one thing Apple requires a phone app for,
writing workouts and vitals as JSON into a folder you pick, and gets out of the way. The
folder is the API. This server is the convenient door to it for an AI; the files work
without it, and `briefing.md` is the one page any AI can read.

Until 2026-10-25 the project ran under the codename "Tide"; the old names are kept as
aliases wherever a user could have relied on them (environment variables, config path,
schema ids, resource URIs), listed under [Aliases](#aliases-from-before-the-rename).

## Install

```sh
npx -y healthaccess-mcp --check     # downloads the server once, prints the folder it found
```

The npm package `healthaccess-mcp` is a small Node launcher with five optional
dependencies, one per platform (`healthaccess-mcp-darwin-arm64`, `-darwin-x64`,
`-linux-x64`, `-linux-arm64`, `-win32-x64`); npm installs only the one that matches,
the way esbuild and Biome ship native binaries. Each carries both `healthaccess-mcp` and
`healthaccess`, built with `--no-default-features`, so the npm binaries contain no network
code. Node.js 18 or newer is the only requirement. `npm install -g healthaccess-mcp` puts
both commands on the PATH; `npx -y -p healthaccess-mcp healthaccess <command>` runs the CLI
without installing.

From a checkout instead (Rust stable 1.99 or newer via [rustup](https://rustup.rs)):

```sh
cargo install --path mcp --locked     # ~/.cargo/bin/healthaccess-mcp
cargo install --path cli --locked     # ~/.cargo/bin/healthaccess
```

Releasing: `scripts/bump-version.sh <version>` sets one version in Cargo, npm, the
registry manifest `npm/server.json`, the Claude plugin, the Homebrew formula and the app;
`scripts/build-npm.sh` cross-compiles the five platforms (zig and cargo-zigbuild for Linux
and Windows) and packs every npm package into `dist/npm/`; `npm/test/local-registry.sh`
publishes them to a throwaway local registry and runs them through `npx`;
`scripts/publish-npm.sh` publishes the platform packages first, then the launcher;
`scripts/publish-registry.sh` then publishes `npm/server.json` to the official MCP registry
(`com.healthaccessmcp/healthaccess-mcp`, DNS auth with the key in
`~/.config/healthaccessmcp/`) and checks the listing.
Homebrew (`packaging/homebrew/healthaccess-mcp.rb`) and crates.io (`cargo publish
--dry-run --workspace` passes) are prepared and wait for the public repository. See
[Distribution](#distribution).

`cargo install --path mcp --no-default-features` builds a server from source that contains
no network code either (the optional telemetry client sits behind the `telemetry` cargo
feature; see [Telemetry](#telemetry)).

## Where the folder is

Resolution order, first hit wins:

1. `--dir <folder>` on the command line
2. `HEALTHACCESS_DIR` environment variable (alias: `TIDE_DIR`)
3. `dir = "..."` in `~/.config/healthaccess/config.toml` (when that file does not exist
   but the pre-rename `~/.config/tide/config.toml` does, the old one is read)
4. Discovery (`core/src/discover.rs`), in stages, stopping at the first stage with a hit:
   iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs`, symlinks followed, so
   the iCloud-synced Desktop and Documents count; `%USERPROFILE%\iCloudDrive` on Windows),
   then the other providers (`~/Library/CloudStorage/*`, `~/Dropbox`, `~/Google Drive`,
   `~/OneDrive*`, `~/Box`), then `~/Documents`. A Health Access folder is a directory with
   an `index.json` of schema `healthaccess.index.v1` (or `tide.index.v1`) and a `workouts/`
   directory. The walk skips hidden directories, bundles and build folders, goes 8 levels
   deep and stops after 40,000 directories or 4 seconds per stage. Several hits: the server
   refuses to guess (one of them could be a folder someone else shared with you), lists
   them and asks for `--dir`, the environment variable or `dir` in the config. The search
   takes under a second on a typical Mac.

```toml
# ~/.config/healthaccess/config.toml (every key optional)
dir = "/Users/alex/Library/Mobile Documents/com~apple~CloudDocs/Health Access"   # skips the search
zones = [133, 146, 159, 171]        # HR zone bounds in bpm; else estimated from the age in profile.json

telemetry = false                   # opt-in, default off; source builds with the `telemetry` feature only
posthog_host = "https://eu.i.posthog.com"
posthog_api_key = "phc_..."
# anonymous_id = "..."              # written by healthaccess-mcp on the first telemetry-enabled start
```

`zones` is optional. Without it the server estimates the bounds from the athlete's age in
`profile.json` (maximum heart rate 208 - 0.7 x age, bounds at 72, 79, 86 and 92 % of it,
so age 34 gives [133, 146, 158, 169]); without a profile either, no bounds are assumed and
only the zones a workout file carries are shown. Every zones object says where its
bounds came from (`bounds_source`: `config`, `estimated` or `file`), and
`healthaccess-mcp --check` prints the bounds with their source.

The folder can live on any provider the iOS Files app can open (iCloud Drive, Dropbox,
Google Drive, OneDrive, Proton Drive, a NAS). The one rule: the same folder has to be
reachable from the machine the AI runs on.

`healthaccess-mcp --check` prints the resolved folder and where it came from, any other
folders the search found, the zone bounds, the telemetry state and the config file path,
then exits. `HEALTHACCESS_CONFIG=/path/to/other.toml` overrides the config file location
(tests use it; alias `TIDE_CONFIG`).

## Claude Code

```sh
claude mcp add --scope user healthaccess -- npx -y healthaccess-mcp
```

Equivalent `.mcp.json` (project scope; the `--scope user` form above registers it for all
projects):

```json
{
  "mcpServers": {
    "healthaccess": {
      "command": "npx",
      "args": ["-y", "healthaccess-mcp"]
    }
  }
}
```

Add `"--dir", "<absolute path>"` to `args` to skip the search. Logs go to stderr;
`HEALTHACCESS_LOG=debug` turns them up (stdout is reserved for MCP frames; alias
`TIDE_LOG`).

## Claude Desktop, Cursor, LM Studio

`~/Library/Application Support/Claude/claude_desktop_config.json`, `~/.cursor/mcp.json`,
LM Studio's `mcp.json`: the same entry as above. A GUI app that reports
`spawn npx ENOENT` does not see the shell PATH; use the absolute path from `which npx` as
`command`.

The server announces itself as `healthaccess-mcp`, title "Health Access MCP: Apple Health
for your AI", with the capabilities `tools`, `resources` and `prompts`.

## What the server tells the AI

The `initialize` instructions are short and in plain words. They say that Health Access
is middleware and the folder is the API; the order of things in four lines (once: install,
pick a folder, allow Health, connect the AI; every workout: nobody does anything, the
file appears; sometimes: one tap to rate a session or to put a plan on the Watch;
whenever asked: the AI reads here and writes plans); the two Apple limits (health data is
only readable while the phone is unlocked, so a session can arrive a little later; the
Watch keeps its own pool length, a plan cannot set it); the two rules for the AI (ask the
athlete before writing a plan; never invent an effort rating, Apple's own rating stays
unless the athlete asks to change it); that ids are the first 8 characters of the
workout UUID; and the units (metres, seconds, bpm, UTC with a `Z`). The exact text is
`INSTRUCTIONS` in `mcp/src/server.rs`.

## Tools

All results are pretty-printed JSON text (floats rounded to one decimal). Domain errors
(unknown id, failed validation) come back as `isError: true` content so the model sees the
reason; malformed arguments are JSON-RPC errors. A refusal (see `rate_workout`) is also
`isError: true`, with a plain sentence and no `failed:` prefix. Ids are HKWorkout UUIDs;
the first 8 characters (the suffix of the file name) are enough, and a file name works
too. Every tool that takes an id, reads and `rate_workout` alike, resolves it the same
way: through `index.json` when it lists the workout, else by scanning `workouts/` (so a
missing or stale index never hides a file that exists).

### `list_workouts {since?, sport?, limit?=20}` (read-only)

`since`: `YYYY-MM-DD` or RFC 3339. `sport`: `pool_swim`, `indoor_row`, `cycle`, `walk`,
`run` (`swim` matches both swim kinds). Rows come from `index.json` (or a scan of
`workouts/` when the index is absent), deduplicated, newest first. `effort`,
`effort_source`, `rated` and `plan_name` are read from the workout file, because the
app's index can lag behind the files.

```json
{"name": "list_workouts", "arguments": {"since": "2026-05-01", "sport": "swim", "limit": 5}}
```
```json
{
```json
{
```json
{
  "total_workouts": 2, "matched": 1, "returned": 1,
  "rows": [{
    "id": "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3", "short_id": "7A1C3E90",
    "start": "2026-05-14T05:12:04Z", "activity": "pool_swim",
    "duration_s": 2166, "distance_m": 1200, "avg_hr": 129,
    "effort": 6, "effort_source": "apple", "rated": true, "plan_name": "S12",
    "file": "workouts/2026-05-14_0712_PoolSwim_7A1C3E90.json",
    "summary": "2026-05-14 Pool swim \"S12\" · 1200 m · 36:06 · avg HR 129 (max 162) · Z1–2 93% · effort 6/10 (apple) · best FR 100 2:12 → 284 beats/100 m"
  }]
}
```

### `get_workout {id, include_hr_series?=false, include_laps?=true}` (read-only)

The `healthaccess.workout.v1` document (v0 files are converted on the fly) plus `summary`,
`file`, `parts_text` and `cardiac_cost`. `zones` is computed here from the heart-rate
series (see [Zones](#heuristics-how-the-derived-numbers-are-made)) and carries
`bounds_source`; the zones an older app version wrote into the file are legacy and only
show when no bounds are known or the file has no series. Without either, `zones` is
`null`. Steps carry the interval key path
`block.rep.step` (`0.0.0` = warm-up), `kind`, per-step distance, average HR and pace, and
`label` when a plan matched (see [Heuristics](#heuristics-how-the-derived-numbers-are-made)).
`parts_text` is one line per step an AI can quote without parsing `steps[]`:
`label · 200 m · 2:18/100 · HR 108` for a step with a distance and a pace,
`label · 0:45 · HR 97` for a timed step; the label falls back to the kind.

```json
{"name": "get_workout", "arguments": {"id": "7A1C3E90"}}
```
```json
{
```json
{
```json
{
  "summary": "2026-05-14 Pool swim \"S12\" · 1200 m · 36:06 · avg HR 129 (max 162) · Z1–2 93% · effort 6/10 (apple) · best FR 100 2:12 → 284 beats/100 m",
  "file": "workouts/2026-05-14_0712_PoolSwim_7A1C3E90.json",
  "parts_text": ["FR easy, find your breathing · 200 m · 2:20/100 · HR 100", "DRILL 6-3-6: 6 kicks side, 3 strokes · 50 m · 2:50/100 · HR 125", "FR easy, long strokes · 50 m · 2:16/100 · HR 130", "recovery · 0:30 · HR 126", "...", "FR 100 steady, breathe every 3 · 100 m · 2:12/100 · HR 151", "recovery · 0:40 · HR 146", "...", "Easy, any stroke, long exhale · 100 m · 2:50/100 · HR 123"],
  "cardiac_cost": {"beats_per_100m": 283.8, "best_100_pace_s": 132, "avg_hr": 129, "basis": "step 2.3.0 100 m in 2:12"},
  "activity": "pool_swim", "distance_m": 1200, "duration_s": 2166, "pool_length_m": 50,
  "plan_ref": {"plan_id": "2026-05-13T19:02:11Z-s12", "name": "S12"},
  "zones": {"bounds": [133, 146, 158, 169], "bounds_source": "estimated", "seconds": {"z1": 1182, "z2": 827, "z3": 110, "z4": 42, "z5": 0}},
  "steps": [
    {"key": "0.0.0", "block": 0, "rep": 0, "step": 0, "kind": "warmup", "label": "FR easy, find your breathing", "duration_s": 279, "distance_m": 200, "avg_hr": 100, "pace_s_per_100m": 139.5, "goal_met": true, "start": "2026-05-14T05:12:04Z", "end": "2026-05-14T05:16:43Z"},
    {"key": "2.3.0", "block": 2, "rep": 3, "step": 0, "kind": "work", "label": "FR 100 steady, breathe every 3", "duration_s": 132, "distance_m": 100, "avg_hr": 151, "pace_s_per_100m": 132, "goal_met": true, "...": "..."}
  ],
  "laps": [{"start": "2026-05-14T05:12:07Z", "end": "2026-05-14T05:13:14Z", "duration_s": 67, "stroke": "freestyle", "swolf": 88}],
  "recovery_hr": {"end": 115, "1min": 104, "2min": 96},
  "effort": 6, "effort_source": "apple", "effort_estimated": 5, "feel": null,
  "metadata": {"HKLapLength": "50 m", "...": "..."}
}
```

### Effort fields

Apple exports the athlete's own effort rating (`WorkoutEffortScore`, iOS 18), so a
workout carries, each nullable:

- `effort` (1 to 10): the athlete's rating.
- `effort_source`: `apple` (entered on the Watch or in Fitness), `app` (rated in Health
  Access) or `ai` (written by `rate_workout`, only ever after the athlete said the number).
  Files from before this part of the contract have none.
- `effort_estimated` (1 to 10): Apple's own estimate. Never used as `effort`; shown so the
  AI can compare it with what the athlete said.
- `feel`: free text from the athlete.

The parsers accept the scores as integers, floats or numeric strings (Apple's score is a
double in HealthKit) and round them. `training_summary` uses `effort` from any source
for `mean_effort`. The one-line summary names the source: `effort 7/10 (apple)`.

### `get_vitals {days?=30}` (read-only)

The seven-metric view (resting HR, HRV, body mass, sleep, steps, VO2max, blood pressure)
of the last N days, oldest first, with `latest` and simple `averages`. It reads
`days/<date>.json` (app v0.4, mapped: `heart.resting_hr`, `heart.hrv_sdnn_ms`,
`body.mass_kg`, `sleep.asleep_s`, `activity.steps`, `heart.vo2max`, last
`blood.pressure`) and `vitals/<date>.json` (the earlier file, kept readable as an alias
for one release). When both exist for a date the day file wins and the old file only
fills values the day lacks. Empty with a note until the app has written either.

### `training_summary {weeks?=8}` (read-only)

One entry per ISO week ending in the current week (empty weeks included so trends stay
aligned): `sessions`, `duration_s`, `distance_m`, duration-weighted `avg_hr`, `z12_pct`,
`mean_effort` over rated sessions (any `effort_source`), `cardiac_cost` (mean over swims),
`by_sport`. From the day files of the window (app v0.4) each week also carries
`days_with_data`, `rings` (`days`, `move_kcal`, `exercise_min`, `stand_hours` totals and
`move_goal_days`, `exercise_goal_days`, `stand_goal_days`, the days each ring closed) and
`mean_physical_effort_met` (mean of the days' `activity.physical_effort_avg_met`); the
top level says `days_considered`, `zone_bounds` and `bounds_source` (`config` or
`estimated`; both `null` when neither config.toml nor profile.json gives bounds, in which
case `z12_pct` uses the zones a file carries, if any). Plus `cardiac_cost_trend`, one point per swim, and
`notes` stating the heuristics.

```json
{"name": "training_summary", "arguments": {"weeks": 8}}
```
```json
{
```json
{
```json
{
  "from": "2026-03-23", "to": "2026-05-17", "zone_bounds": [133, 146, 158, 169], "bounds_source": "estimated",
  "workouts_considered": 2, "days_considered": 1,
  "weeks": [
    {"week": "2026-W13", "start": "2026-03-23", "end": "2026-03-29", "sessions": 0, "duration_s": 0, "distance_m": 0,
     "avg_hr": null, "z12_pct": null, "mean_effort": null, "rated_sessions": 0, "cardiac_cost": null, "by_sport": {},
     "days_with_data": 0, "rings": null, "mean_physical_effort_met": null},
    {"week": "2026-W20", "start": "2026-05-11", "end": "2026-05-17", "sessions": 2, "duration_s": 3846, "distance_m": 1200,
     "avg_hr": 132, "z12_pct": 73, "mean_effort": 6.5, "rated_sessions": 2, "cardiac_cost": 284,
     "by_sport": {"indoor_row": {"sessions": 1, "duration_s": 1680, "distance_m": 0}, "pool_swim": {"sessions": 1, "duration_s": 2166, "distance_m": 1200}},
     "days_with_data": 1, "rings": {"days": 1, "move_kcal": 612, "exercise_min": 58, "stand_hours": 12, "move_goal_days": 1, "exercise_goal_days": 1, "stand_goal_days": 1},
     "mean_physical_effort_met": 2.3}
  ],
  "cardiac_cost_trend": [
    {"date": "2026-05-14", "id": "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3", "name": "S12", "activity": "pool_swim",
     "beats_per_100m": 283.8, "best_100_pace_s": 132, "avg_hr": 129, "basis": "step 2.3.0 100 m in 2:12"}
  ],
  "notes": ["cardiac cost = avg_hr × best freestyle 100 m pace (s) / 60 = heart beats per 100 m; lower is better", "..."]
}
```

### `rate_workout {id, effort, feel?, override?=false}` (writes)

Stores `effort` (1 to 10) and `effort_source: "ai"` and, when given, `feel` in the workout
file. Only those keys change; the file is rewritten atomically (temp file + rename,
formatting preserved) and the matching `index.json` row gets the new effort if the index
exists and lists the workout (`index_updated` says whether it did; the row's
`effort_source` is updated only when the app wrote that key). Omitting `feel` keeps the
previous note. The result carries `previous_effort` and `previous_source` so the AI sees
what it replaced, and the new one-line summary.

The tool description says it in one sentence: call it only after the athlete told you
the number; Apple's own rating wins unless the athlete asks to change it. So a file that
already has `effort_source: "apple"` is refused (`isError: true`, plain text, nothing
written) unless the call passes `override: true`:

```
2026-05-14_0712_PoolSwim_7A1C3E90.json already has the athlete's own effort rating from Apple: 6/10. Keep it. If the athlete asks to change it, call again with override set to true.
```

```json
{"name": "rate_workout", "arguments": {"id": "7A1C3E90", "effort": 6, "feel": "legs heavy, breathing fine"}}
```

### `push_plan {plan}` (writes)

Validates a `healthaccess.plan.v1` plan and writes `plans/<id>.json` with
`id = <RFC 3339 UTC seconds>-<slug(name)>`, e.g. `2026-10-24T20:22:05Z-s30`. The app shows
it as "Your AI wrote S30"; the athlete taps Put on Watch; the app installs it through
WorkoutKit and writes `plans/<id>.status.json`.

Rules: `sport` is one of `run`, `indoor_run`, `walk`, `hike`, `cycle`, `indoor_cycle`, `pool_swim`, `open_water_swim`, `indoor_row`, `hiit` or `elliptical` (`hiit` and `elliptical` take `time_s` goals only); `name` non-empty, at most 40 characters;
at least one block, `repeat` 1 to 99, each with at least one step; `goal.type` is
`time_s` or `distance_m` with a positive value; `zone` 1 to 5 (the Watch's own HR zones);
`label` at most 40 characters; `kind` is `work` or `recovery`. Every violation is
reported in one message. Labels are what the athlete reads on the wrist and what names
the executed steps later, so make them instructions.

```json
{"name": "push_plan", "arguments": {"plan": {
  "name": "S30", "sport": "pool_swim", "pool_length_m": 50,
  "warmup": {"goal": {"type": "time_s", "value": 120}, "zone": 1},
  "blocks": [
    {"repeat": 1, "steps": [
      {"kind": "work", "goal": {"type": "distance_m", "value": 200}, "zone": 2, "label": "Easy FR, long strokes"},
      {"kind": "recovery", "goal": {"type": "time_s", "value": 45}}]},
    {"repeat": 4, "steps": [
      {"kind": "work", "goal": {"type": "distance_m", "value": 100}, "zone": 3, "label": "100 steady, breathe every 3"},
      {"kind": "recovery", "goal": {"type": "time_s", "value": 30}}]}
  ],
  "cooldown": {"goal": {"type": "distance_m", "value": 100}, "zone": 1},
  "notes": "Aerobic 100s with controlled breathing.",
  "scheduled_for": "2026-10-27T07:30:00Z"
}}}
```
```json
{"id": "2026-10-24T20:22:05Z-s30", "file": "2026-10-24T20:22:05Z-s30.json", "path": ".../plans/2026-10-24T20:22:05Z-s30.json",
 "planned_distance_m": 700, "planned_time_s": 285, "plan": {"...": "..."},
 "next": "the app shows the plan under Your AI wrote <name>; the athlete taps Put on Watch; the app writes plans/<id>.status.json; poll get_plan_status"}
```

### `get_plan_status {id}` (read-only)

`{"plan_id", "state", "at", "error", "method", "workoutkit_id", "scheduled_for"}` with
`state` = `pending` (no status file yet), `scheduled`, `failed` or `cancelled`. `method`
is the app's `schedule` or `preview` (Apple's "Add to Watch" sheet), `workoutkit_id` the
WorkoutKit plan id; both `null` when the app did not write them. Unknown plan: `isError`.

### `list_plans {}` (read-only)

Every plan in `plans/` with its state, planned distance and time, newest first.

### Days, catalog, profile, ECG (app v0.4)

The export-everything rule of [`export-coverage.md`](export-coverage.md) adds four kinds
of files to the folder. The Rust side reads them leniently: every key it does not model
is kept and returned as written, groups are present only when the app wrote them, and a
file that does not parse is reported by `doctor`, never fatal for the other tools. Until
the app ships v0.4 these tools answer with a `note` and no data.

#### `get_day {date}` (read-only)

`days/<date>.json`: one file per day with everything Health holds for it, in groups
(`activity`, `heart`, `respiratory`, `sleep`, `body`, `blood`, `mobility`, `hearing`,
`nutrition`, `mind`, `symptoms`, `cycle`, `medications`, `hygiene`, `uv`, `wheelchair`,
`audiogram`, `vision`). The result is `{"file", "day"}`; `day` is the document plus a
`groups` list naming the groups present. Unknown date: `isError`.

```json
{"name": "get_day", "arguments": {"date": "2026-05-14"}}
```
```json
{"file": "days/2026-05-14.json",
 "day": {"date": "2026-05-14", "groups": ["activity", "heart", "respiratory", "sleep", "body", "mobility"],
         "activity": {"rings": {"move_kcal": {"goal": 650, "actual": 712.3}, "exercise_min": {"goal": 30, "actual": 47},
                                "stand_hours": {"goal": 12, "actual": 13}, "move_mode": "active_energy"},
                      "steps": 9412, "physical_effort_avg_met": 2.4, "...": "..."},
         "heart": {"resting_hr": 54, "hrv_sdnn_ms": 58.3, "vo2max": 44.1, "hr": {"min": 47, "avg": 72, "max": 162, "samples": 1184}, "...": "..."},
         "sleep": {"asleep_s": 26160, "in_bed_s": 28137, "deep_s": 4980, "...": "..."},
         "body": {"mass_kg": 78.4}}}
```

#### `get_days {from, to, groups?}` (read-only)

The day files with `from <= date <= to` (at most 366 days), oldest first. `groups`
reduces every day to the named groups (plus `date` and `groups`), so one call follows
sleep or resting heart rate over a month. `groups_available` lists every group seen in
the range.

```json
{"name": "get_days", "arguments": {"from": "2026-05-01", "to": "2026-05-17", "groups": ["heart", "sleep"]}}
```

#### `get_catalog {}` (read-only)

`catalog.json` as the app wrote it (`generated`, `app_version`, `types` keyed by
HealthKit identifier with `kind`, `authorized`, `has_data`, `samples_90d`, `first`,
`last`, `exported_in`, and `unknown_types_with_data`) plus `coverage`, the same check
`doctor` runs: this build embeds every HealthKit type identifier of the iOS 27.1 SDK
(`core/src/hk_types.rs`, 223 identifiers: 121 quantity, 72 category, 6 characteristic,
2 correlation, 1 document, 9 clinical, 12 special types) and reports
`types_with_data_not_exported` (has data, `exported_in` is `none`; should always be
empty), `unknown_types_with_data` (the app's own list plus every catalog entry with data
that this build does not know; the signal to update), `known_types_missing_from_catalog`,
and the counts. Identifiers match in any spelling: `HKQuantityTypeIdentifierBodyMass`,
`bodyMass` with kind `quantity`, or `HKDataTypeIdentifierElectrocardiogram` against the
special type's stem. Without a catalog the tool returns `catalog: null`, the number of
known types and a note.

#### `get_profile {}` (read-only)

`profile.json`: `age`, `birth_year`, `biological_sex`, `blood_type`, `wheelchair_use`,
`activity_move_mode`, `fitzpatrick_skin_type`, plus anything else the app wrote.

#### `list_ecgs {}` (read-only)

Every `ecg/<timestamp>.json`, newest first: `file`, `at` (from the file name, or from a
`start`/`at` key), `classification`, `symptoms_status`, `average_heart_rate`,
`sampling_frequency_hz`, `algorithm_version`, `device`, `voltage_file` (the
`.voltage.json` sidecar when the athlete turned voltage export on; never loaded) and
`document`, the summary as written.

## Prompts

The eleven prompts of [`prompts.md`](prompts.md) are exposed through `prompts/list` and
`prompts/get`, in two groups: export prompts read and explain, plans prompts write
sessions for the Watch. None assumes a sport. The ids, titles and arguments:

| id | group | title | arguments |
|---|---|---|---|
| `weekly_checkin` | export | Weekly check-in | none |
| `explain_last_session` | export | Explain my last session | `id` (optional) |
| `overdoing_it` | export | Am I overdoing it? | none |
| `sleep_and_recovery` | export | How am I sleeping and recovering? | `days` (default 28) |
| `long_term_trends` | export | What changed over the last months? | `weeks` (default 12) |
| `coach_summary` | export | Prepare this for my coach or doctor | `weeks` (default 4) |
| `next_session` | plans | Plan my next session | none |
| `plan_my_week` | plans | Plan my week | none |
| `adjust_plans` | plans | Change my plan | none |
| `build_up_to_goal` | plans | Build up to a goal | none |
| `convert_workout` | plans | Make my workout a Watch workout | none |

The prompt text is byte-identical to the body in `docs/prompts.md`: the core crate
embeds the file at build time (`include_str!` through the symlink `core/prompts.md`) and
parses the `## N. Title` / `**id:**` sections, so the Markdown stays the single source
for the server, the CLI, the app's copy and the site. `prompts/get` returns one user
message with the body. When an argument is given, a second user message carries it
(`The session to explain: id 7A1C3E90.` or `The period: the last 6 weeks.`); with no
arguments the body stands alone, since the text already covers the defaults. An unknown
prompt or an unknown argument name is an invalid-params error that lists what exists.

```json
{"method": "prompts/get", "params": {"name": "explain_last_session", "arguments": {"id": "7A1C3E90"}}}
```
```json
{"description": "Explain my last session",
 "messages": [
   {"role": "user", "content": {"type": "text", "text": "One question: what did you want from this session?\n\nThen `get_workout` on the latest session (or the id I gave) with laps. ..."}},
   {"role": "user", "content": {"type": "text", "text": "The session to explain: id 7A1C3E90."}}
 ]}
```

## Resources

- `healthaccess://briefing` (`text/markdown`): the one-page summary. When the folder has
  `briefing.md` (the app writes it after every sync), that file is returned as is.
  Otherwise the server generates an equivalent on the fly with the same sections in the
  contract's order (Last 4 weeks, Recent sessions, Vitals, Next session, Open, Limits) and
  says so in the first line: `# Health Access briefing for the athlete, written
  <timestamp> by healthaccess-mcp (generated by the MCP from the folder, not by the app:
  there is no briefing.md yet)`. The 21-day direction of a vital compares the mean of the
  last 7 days with the mean of the days before (tolerance 2 bpm resting HR, 5 ms HRV,
  20 min sleep, 0.5 kg weight; fewer days than that reads "too few days to tell").
- `healthaccess://index` (`application/json`): the deduplicated index.
- `healthaccess://workout/<id>` (`application/json`): one workout as
  `healthaccess.workout.v1` JSON, HR series included (full UUID or 8-character prefix).
  Listed for the newest 200 workouts; a resource template `healthaccess://workout/{id}`
  is advertised.
- The pre-rename URIs `tide://index` and `tide://workout/<id>` are still readable
  (aliases); they are not advertised in `resources/list`.

## Client handshake

So the phone app can show "Connected", the server leaves a small file in the folder:
`mcp/clients/<id>.json`, schema `healthaccess.client.v1`. `id` is a stable hash
(FNV-1a 64, 16 hex characters) of the machine name and the client name, so one file per
client per computer. Fields: `client {name, version}` (from the MCP `initialize`
request), `machine` (the computer's name), `mcp_version`, `first_seen`, `last_seen`,
`last_tool` (the name of the last tool called) and `calls`. Never arguments, never
results, never file names. The server writes it once after `initialize` and then, while
tools are called, at most once a minute (counts are carried over). The CLI writes the
same file with the client name `healthaccess-cli` only from the commands that write
into the folder anyway (`rate`, `plan push`), with the subcommand as `last_tool`; read
commands (`list`, `show`, `doctor`, `briefing`, ...) leave no trace. Writes are atomic;
a failure to write never fails a tool call. `healthaccess doctor` lists the handshakes
it finds.
`HEALTHACCESS_MACHINE` overrides the machine name (tests use it); otherwise `HOSTNAME`
or the `hostname` command (without a trailing `.local`) names the machine.

```json
{
  "schema": "healthaccess.client.v1",
  "id": "9d7f3c1a2b4e6f80",
  "client": {"name": "Claude Code", "version": "2.1.0"},
  "machine": "alexs-mac",
  "mcp_version": "0.4.0",
  "first_seen": "2026-10-25T07:58:12Z",
  "last_seen": "2026-10-25T09:40:51Z",
  "last_tool": "get_workout",
  "calls": 14
}
```

## CLI

```
healthaccess list [--since YYYY-MM-DD] [--sport pool_swim] [--limit 20]
healthaccess show <id> [--hr]                 # steps, laps, zones, recovery, cardiac cost
healthaccess summary [--weeks 8]
healthaccess rate <id> <effort 1-10> [--override] [feel words...]
healthaccess briefing                         # briefing.md, or one generated from the folder
healthaccess prompts                          # the prompt ids with group, title and arguments
healthaccess prompt <id>                      # one prompt's text, byte for byte
healthaccess day <YYYY-MM-DD>                 # one days/<date>.json with its groups
healthaccess days --from <date> --to <date> [--groups heart,sleep]
healthaccess catalog                          # catalog.json against this build's HealthKit type list
healthaccess profile                          # profile.json
healthaccess ecgs                             # ecg/ summaries, newest first
healthaccess plan push <plan.json>            # validates, writes plans/<id>.json
healthaccess plan status <id>
healthaccess plan list
healthaccess workout-file <plan.json> -o S30_PoolSwim.workout [--uuid ...]   # old import flow, no folder needed
healthaccess doctor                           # dirs, index health, every JSON file, schema versions; exit 1 on problems
```

`--dir` and `--json` work on every subcommand (`prompts`, `prompt` and `workout-file` need
no folder). Times print in UTC with a `Z`. `<id>` is a full UUID, the 8-character short id
or a file name; see `rate_workout` above for how it is resolved (same code path for every
command). `rate` refuses to replace an Apple rating unless `--override` is given, with the
same sentence the MCP uses. Missing values print as `-` in tables.

`doctor` also checks the v0.4 files: `days/` (every file parsed), `catalog.json`,
`profile.json`, `ecg/` (summaries; voltage sidecars are not parsed), and prints the
coverage check from `get_catalog` as two lines, "types with data not exported" and
"unknown types with data". Those two are warnings, not failures: the exit code is 1
only when a file does not parse. Without a catalog the line says how many types this
build knows.

Example (`healthaccess doctor` on a copy of `examples/`, the synthetic folder in the
repo; `healthaccess --dir examples doctor` prints the same):

```
```
```
```
healthaccess 0.4.0  folder /Users/alex/Library/Mobile Documents/com~apple~CloudDocs/Health Access
dirs      workouts/ yes  vitals/ yes  plans/ yes
index     present, parse ok  2 entries  missing files 0  unindexed files 0
workouts  2 files, 43 KB, 2 ok, 0 failed
          healthaccess.workout.v1: 2
vitals    1 files, 0 failed
plans     2 plans (0 failed), 2 status files (0 failed)
days      1 files, 0 failed
catalog   present, parse ok
profile   present, parse ok
ecg       0 files, 0 failed
coverage  223 types in the catalog, 43 with data, 43 exported; this build knows 223 (iOS 27.1)
          types with data not exported: none
          unknown types with data: none
clients   Claude Code 2.1.0 on Alex's MacBook Pro (last seen 2026-05-14 06:11Z, 123 calls)
healthy
```

(`doctor` prints each file's schema tag as written, so files from before the rename show
their old `tide.*` ids: accepted aliases, not a problem. The `clients` line comes from
the handshake files; `doctor` only reads them.)

## Heuristics (how the derived numbers are made)

- **Zones.** Four bounds, five zones: with bounds [133, 146, 158, 169], `bpm < 133` is
  Z1 and `bpm >= 169` is Z5. The bounds come from `zones` in config.toml
  (`bounds_source: config`), else from the athlete's age in `profile.json` (`estimated`:
  maximum heart rate 208 - 0.7 x age, bounds at 72, 79, 86 and 92 % of it). There is no
  built-in default. Zone seconds are computed here from `hr_series` with the app's old
  rule: each sample's time until the next sample goes to that sample's zone, only time
  inside `[start, end]` counts, gaps longer than 60 s count as 60 s (sensor dropout).
  The `zones` object an older app wrote into a workout file is legacy: it is returned
  (`bounds_source: file`) only when no bounds are known or the file has no series;
  Phase 0 files carry the exporter's [133, 146, 159, 171].
- **Per-step pace** `duration_s / distance_m × 100`, only for steps that covered at least
  20 m (a 13 m drift during a rest step would otherwise show a nonsense pace).
- **Cardiac cost per 100 m** = `avg_hr × best FR 100 pace (s) / 60` = heart beats spent
  per 100 m when swimming at the session's best freestyle 100 pace. Lower is better;
  compare sessions of similar structure. "Best FR 100 pace" is the fastest *work* step of
  at least 95 m whose overlapping laps were at least half freestyle (steps without stroke
  data are accepted), normalised to 100 m; if no step qualifies and the swim is at least
  100 m, the whole-workout pace is used. Swims only.
- **Step kinds without a plan** (v0 conversion; v1 files carry the app's kinds). `0.0.0`
  is `warmup`; the trailing block, when it holds a single step, is `cooldown`; a step
  with a distance goal (`WOIntervalStepDistacnceGoalAchievedDuration`, Apple's typo) or a
  recorded distance of at least 20 m is `work`; remaining time-only steps alternate, even
  step index `work`, odd `recovery`. Activities without a key path in a multi-activity
  workout get `key` = activity index, `block` = index.
- **Plan matching.** A workout is joined to the plan named by `plan_ref.plan_id`, else to
  the plan of the same sport whose `scheduled_for` lies within 2 h of the workout start
  (closest wins, and the workout's highest block number must fit the plan). Key path
  block 0 = warm-up, 1 to n = blocks, n+1 = cool-down. Matching fills step `kind` and
  missing `label`s and sets `plan_ref`.
- **Weekly summary.** ISO weeks (Monday start); `avg_hr` is duration-weighted;
  `mean_effort` averages rated sessions only, whatever the source of the rating.
- **Dedupe.** Same `start` (within 2 s) and same `source` means one workout, the longer is
  kept (a third-party cycling app writes two entries per ride). When the app's index rows carry no
  `source`, the same `activity` is used instead. Nothing is deleted; the app leaves the
  shorter twin out of `index.json` and `healthaccess doctor` does not count it as
  unindexed.
- **Briefing directions.** See [Resources](#resources).
- **Rings and physical effort.** Per week, over the day files whose date falls in the
  week: ring totals are sums of `actual`, a ring "closed" when `actual >= goal` with a
  goal above zero, and `mean_physical_effort_met` is the plain mean of the days that
  carry `activity.physical_effort_avg_met`.
- **Coverage.** `has_data` is the signal (iOS hides read authorization, so `authorized`
  is usually `null`); `exported_in` anything but `none` or empty counts as exported.

## Telemetry

Off by default. Nothing is sent unless `--telemetry` is passed or `telemetry = true` is
set in `config.toml` **and** `posthog_api_key` is configured. When on, exactly two event
types go to the configured PostHog host (the event names did not change with the rename):

| event | properties |
|---|---|
| `mcp_started` | `version` |
| `mcp_tool_called` | `tool`, `duration_ms`, `ok`, `error_kind?` (one of `io`, `json`, `schema`, `not_found`, `ambiguous`, `validation`, `refused`, `codec`, `config`) |

plus `$lib` (`healthaccess-mcp`), `$lib_version`, `os` (name only) and an anonymous
install id (`anonymous_id`, a random UUID written to `config.toml` on first use;
`$process_person_profile = false`). Never tool arguments, results, workout contents, file
names or paths. The HTTP client exists only in binaries built with the `telemetry` cargo
feature (on by default); `--no-default-features` yields a binary with no network code,
and with the feature compiled in but telemetry off at runtime no network code path is
executed.

## Development

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo clippy -p healthaccess-mcp --no-default-features --all-targets -- -D warnings
HEALTHACCESS_WORKOUT_FILES_DIR="<a folder of Apple .workout files>" \
  cargo test --workspace                        # the codec test round-trips every .workout file in that folder, byte-identical
RUSTFLAGS=-Dwarnings cargo build --workspace --release
cargo publish --dry-run --workspace             # packages and verifies all three crates, uploads nothing
```

Those are the CI gate. `core/tests/fixtures/` holds copies of the two synthetic workouts
and the plans of `examples/` (generated by `examples/generate.py`; no real health data
lives in the repo) plus two generated Phase 0 files under `fixtures/v0/`
(`fixtures/v0/generate.py`) that keep the v0 converter covered; `tests/` is still left
out of the published crates to keep them small. The `.workout` codec test skips itself when `HEALTHACCESS_WORKOUT_FILES_DIR`
(alias `TIDE_WORKOUT_FILES_DIR`) is unset. `core/prompts.md` is a symlink to
`../docs/prompts.md`; edit the docs file, never the link.

`core/src/hk_types.rs` is generated from the SDK headers with a grep over
`HealthKit.framework/Headers/*.h` for `HK_EXTERN <Family>TypeIdentifier const <Name>`
(the header of the file says how). Regenerate it when a new SDK ships; the unit test
pins the family counts so a stale list fails loudly. The three sample types without a
public identifier constant (activity summary, electrocardiogram, audiogram) are listed
as the runtime reports them.

## Distribution

- **npm** (the install everyone uses). `npm/healthaccess-mcp/` is the launcher package
  (`bin/healthaccess-mcp.js`, `bin/healthaccess.js`, `lib/run.js`): it resolves
  `healthaccess-mcp-<platform>-<arch>/bin/<name>` from its optional dependencies and
  spawns it with inherited stdio, forwarding signals and the exit code.
  `HEALTHACCESS_MCP_BINARY` / `HEALTHACCESS_CLI_BINARY` point it at another binary.
  `scripts/build-npm.sh` builds the platform packages (macOS natively, Linux musl and
  Windows GNU through `cargo zigbuild`), `npm/test/local-registry.sh` tests the result
  end to end against a local registry, `scripts/publish-npm.sh` publishes.
  Live since 2026-10-26 (0.5.0), current 0.6.2, published by the npm user `pt-consultancy`
  with passkey 2FA: run `scripts/publish-npm.sh` in a terminal, press Enter at the prompt,
  tick "do not challenge for 5 minutes" and approve once for all six packages.
- **Official MCP registry.** Listed as `com.healthaccessmcp/healthaccess-mcp` (0.6.2,
  active) since 2026-10-27, pointing at the npm package. `package.json` carries
  `mcpName`; `npm/server.json` is the entry; the namespace is verified by a TXT record on
  healthaccessmcp.com whose private key lives outside the repo in
  `~/.config/healthaccessmcp/`. Each release: `scripts/publish-registry.sh` after npm.
- **Claude plugin.** `claude-plugin/` (the MCP server through a pinned `npx`, the eleven
  prompts as skills) passes `claude plugin validate`. Not submitted: Anthropic's
  directory (claude.ai/directory/manage) lists a plugin only from a public repository.
  The directory no longer accepts `.mcpb` desktop extensions. ChatGPT's app directory
  needs a remote HTTPS server, so it is out of scope by design.
- **Website.** `scripts/deploy-site.sh` stages `dist/site` (`site/`, `docs/*.md` under
  `/ref/`, `examples/` under `/examples/`) and deploys it with `wrangler deploy` to
  Cloudflare Workers static assets (`wrangler.jsonc`, `site-worker/worker.js` redirects
  www and sets headers).

Prepared, not published:

- **crates.io.** `healthaccess-core`, `healthaccess-mcp` and `healthaccess-cli` carry
  description, `license = "MIT"`, repository, homepage, keywords (`mcp`, `apple-health`,
  `healthkit`, `apple-watch`, `workout`), categories and `readme = "../docs/mcp.md"`
  (cargo copies the readme into the package). The path dependency on the core crate also
  names its version, so the published manifests resolve. `cargo publish --dry-run
  --workspace` packages the three crates and verifies the two binaries against the
  freshly packaged core through a temporary local registry; publish in the order core,
  cli, mcp (or let `cargo publish --workspace` do it).
- **Homebrew.** `packaging/homebrew/healthaccess-mcp.rb` is the formula for a tap
  `leonhardprinz/homebrew-tap`: it installs both binaries from the universal macOS tarball
  of a GitHub release. `url` and `sha256` are `TODO` placeholders until the first release.
- **GitHub release.** `.github/workflows/release.yml` runs on tags `v*`, checks that the
  tag matches the workspace version, builds `aarch64-apple-darwin` and
  `x86_64-apple-darwin` release binaries, joins them with `lipo`, smoke-tests them, and
  attaches `healthaccess-mcp-<version>-macos-universal.tar.gz` plus its `.sha256` to the
  release. The tarball holds `healthaccess-mcp`, `healthaccess`, `LICENSE` and this page.

## Aliases from before the rename

Kept for good, not deprecated:

| today | pre-rename alias |
|---|---|
| `HEALTHACCESS_DIR` | `TIDE_DIR` |
| `~/.config/healthaccess/config.toml` | `~/.config/tide/config.toml` (read only when the new file is absent) |
| `HEALTHACCESS_CONFIG`, `HEALTHACCESS_LOG` | `TIDE_CONFIG`, `TIDE_LOG` (aliases) |
| `healthaccess.workout.v1` (+ `.v0`), `healthaccess.vitals.v1`, `healthaccess.index.v1`, `healthaccess.plan.v1` | `tide.workout.v1` / `tide.workout.v0`, `tide.vitals.v1`, `tide.index.v1`, `tide.plan.v1` |
| workout key `healthaccess_version` | `tide_version` (alias, read-only) |
| `healthaccess://index`, `healthaccess://workout/<id>` | `tide://index`, `tide://workout/<id>` |
| `HEALTHACCESS_WORKOUT_FILES_DIR` (tests) | `TIDE_WORKOUT_FILES_DIR` (alias) |

Not aliased: the binaries (`healthaccess`, `healthaccess-mcp`; reinstall and re-register
the MCP server), the crate names, `created_by` defaults (`healthaccess-mcp` /
`healthaccess-cli`), the `$lib` telemetry property and the new
`healthaccess://briefing` resource.

## Deviations and assumptions (vs. `schema.md`)

The contract was followed where it is explicit; these are the places where it was silent,
impossible from the data, or where the real data disagreed. Nothing here changes what the
app must write.

1. **`max_hr` for v0 files** is the maximum of `hr_series` (170 for 7A1C3E90), not
   HealthKit's own aggregate (161 in the schema example); v0 has no `max_hr`.
2. **`goal_met` is nullable**: HealthKit omits `WOIntervalStepSuccessful` on the last step
   of a session (`4.0.0` in 7A1C3E90). Schema shows a plain boolean.
3. **`recovery_hr`** fields are individually nullable and the object is `null` when no
   sample is near the end; values are read from `hr_series` (end = last sample within 20 s
   before the end; +1/+2 min = nearest sample within 15 s either way).
4. **Steps for free workouts** follow the app's deviation 4: a workout whose single
   activity has no `WOIntervalStepKeyPath` gets `steps: []`; in multi-activity workouts
   an activity without a key path becomes an index-keyed step.
5. **Step kind inference** follows the app's rule (warm-up, trailing single-step
   cool-down, distance means work) with two refinements: "distance recorded" means at
   least 20 m (a 13 m drift during a 25 s rest is not work), and time-only steps
   alternate work/recovery instead of all being `recovery` (rowing intervals would
   otherwise all read as recovery). Applies to v0 files only; v1 files keep the app's
   kinds.
6. **`pace_s_per_100m`** is `null` under 20 m even when a distance exists.
7. **Zones for v0 files** are the exporter's `zone_seconds` with the default bounds;
   recomputed zones (custom bounds, or files without zones) use the app's rule (60 s cap,
   inside `[start, end]`) on second-truncated timestamps, so they differ slightly from
   the app's numbers.
8. **`other:<hk raw>`** uses the numeric HKWorkoutActivityType (e.g. `other:24`).
9. **Index.** `file` is `workouts/<name>.json` relative to the folder (app deviation 8); a
   bare file name is accepted too. Scan-built rows carry an extra optional `source` (used
   for dedupe) and `effort_source`; the app's rows may omit both, in which case dedupe
   falls back to `activity` and the source is read from the file.
10. **`rate_workout`** keeps the existing `feel` when none is given, and updates
    `index.json` only if it already exists and lists the workout (the MCP never creates
    or extends the index; the app owns it). Ids are resolved through the index first and
    then by scanning `workouts/`, so a stale index does not block a rating (fixed
    2026-10-25; before, ids missing from a present `index.json` were reported as "not
    found" by every command, reads and writes alike).
11. **Plan ids contain `:`** as the contract prescribes; APFS and iCloud Drive accept
    that, Finder displays the colon as `/`.
12. **`created_by`** defaults to `healthaccess-mcp` (CLI: `healthaccess-cli`); a provided
    value is kept. Schema example shows `claude-code`.
13. **Plan matching is also done on the reading side** (schema assigns it to the app).
    The app's `plan_ref`, when present, wins.
14. **`.workout` codec.** Body field 2 is `HKWorkoutSessionLocationType` (2 indoor, 3
    outdoor); the user's 59 pool-swim files all use 3, the 10 rowing files 2, so
    `pool_swim` is 3 and `indoor_row` is 2. Two historical files carry a 41-character
    label: the Watch accepts it, the plan validator (`push_plan`, `healthaccess plan push`,
    `healthaccess workout-file`) does not; `WorkoutFile::from_plan_unchecked` re-emits
    such files byte-identically.
15. **CI.** No CI configuration runs the gate yet; lints are set in the workspace
    `Cargo.toml` and the gate commands are listed under Development. The only workflow
    is the release build.
16. **Weekly summary** always returns the requested number of weeks, including empty
    ones; `training_summary.weeks` is clamped to 1 to 104.
17. **Times are UTC** everywhere (contract), including CLI tables; the local time is in
    the file name and in `metadata.HKTimeZone`.
18. **`status.json` extras** (`method`, `workoutkit_id`, `scheduled_for`, app deviation
    2) are parsed, preserved and returned by `get_plan_status` / `list_plans`; the state
    `scheduled` written via Apple's preview sheet is shown as such with
    `method: preview`.
19. **Schema aliases.** Every `tide.*` id and the `tide_version` key are accepted forever
    (schema.md, "Schema ids and aliases"); `push_plan` writes `healthaccess.plan.v1`
    even when given the old tag.
20. **Three rating keys, not two.** With the Effort section of the contract,
    `rate_workout` writes `effort`, `effort_source: "ai"` and (when given) `feel`; the
    rule "the MCP never writes under `workouts/` except the rating fields" now covers
    those three keys. Nothing else in the file changes.
21. **Apple ratings are protected.** A file with `effort_source: "apple"` and an effort is
    refused by `rate_workout` unless `override: true` (CLI `--override`); the refusal is
    `isError` with a plain sentence. A file with `effort_source: "app"` can be re-rated
    (the athlete told the AI a new number); the result reports what was replaced.
22. **Lenient scores.** `effort`, `effort_estimated` and the index row's `effort` accept
    integers, floats and numeric strings and round to whole numbers; `effort_estimated`
    keeps its decimals. Unknown `effort_source` strings are kept as written and simply
    not treated as Apple's.
23. **Generated briefing.** When `briefing.md` is absent, the MCP and `healthaccess
    briefing` generate one with the contract's sections and say so in the first line; the
    contract names only the app as writer. Direction heuristics as under Resources.
24. **Prompt arguments** travel as a second user message rather than being substituted
    into the body, so the body stays byte-identical to `docs/prompts.md`.
25. **Day file field names.** `export-coverage.md` names the groups and most fields but
    not the shape of the rings; the Rust side reads
    `activity.rings = {move_kcal: {goal, actual}, exercise_min: {goal, actual},
    stand_hours: {goal, actual}, move_mode}` and keeps every other key as written. The
    typed groups are `activity`, `heart`, `sleep`, `body`, `blood` (what the derived
    views need); all other groups pass through untouched. `schema` is optional and any
    tag is accepted. A day file's name sets its date.
26. **Catalog identifiers.** The embedded list counts 121 quantity and 72 category
    identifiers; the audit's 122 and 73 counted the family typedef names
    (`HKQuantityTypeIdentifier`, `HKCategoryTypeIdentifier`) as well. Deprecated
    identifiers stay in the list because Health still holds their samples.
27. **ECG summaries** are read as plain JSON with a handful of known keys
    (`classification`, `symptoms_status`, `average_heart_rate`, `sampling_frequency_hz`,
    `algorithm_version`, `device`); the time comes from the file name (`2026-10-24T07-31-05Z`,
    RFC 3339 with colons, or `2026-10-24_0731`). The voltage sidecar is listed, never read.
28. **`vitals/` alias.** `get_vitals`, the briefing and the CLI read `vitals/<date>.json`
    for as long as it exists; a day file for the same date wins field by field.
29. **Zones are computed on the reading side.** This side treats the `zones` a workout
    file carries as legacy and computes zone seconds from `hr_series` with bounds from
    config.toml or the age in `profile.json`, reporting `bounds_source` (`config`,
    `estimated`, `file`). Without config, profile or file zones there are no zones and no
    guess. `training_summary` names its bounds and source too (or `null`).
30. **Handshake files.** Besides plans and rating keys the server and the CLI write
    `mcp/clients/<id>.json` (see [Client handshake](#client-handshake)); that is the
    third thing the Rust side writes into the folder.
