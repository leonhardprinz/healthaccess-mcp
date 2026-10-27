# Health Access iOS app (v0.6.2, build 21)

SwiftUI, iOS 17+, Swift only, no third-party UI. Reads HealthKit, writes the files described in [`../docs/schema.md`](../docs/schema.md) and [`../docs/export-coverage.md`](../docs/export-coverage.md) into a folder you pick, and puts `plans/*.json` on the Watch through WorkoutKit. Local-first: no server, no account, no iCloud entitlement (the folder is reached through a document-picker bookmark, which works on a free personal team). Checked against [`../docs/north-star.md`](../docs/north-star.md) before every build.

Health Access is middleware. The app writes the files and gets out of the way; the AI is the user of the data. There are no charts and no analysis in the app. Three tabs: Export, Import, Settings. The MCP and the "Your AI" connection state are the front door. Rating a session is the Watch's job: Apple asks after every workout and exports that number, so the app never asks.

Names: Xcode target and scheme `HealthAccess`, product `Health Access` (the name under the icon), bundle id `com.healthaccessmcp.app`, Swift module `HealthAccess`. The app was called "Tide" until 2026-10-25 (the codename); see "Migration from the old build" below.

## Layout

```
app/
  project.yml                 XcodeGen spec (bundle id, entitlements, Info.plist keys, PostHog SPM pin, version from scripts/bump-version.sh)
  scripts/make_icon.py        Pillow script that draws AppIcon.png + LaunchMark PNGs from the mark's path (docs/brand.md, "The mark")
  scripts/gen_health_types.py Regenerates Services/HealthTypes.swift from the SDK's HKTypeIdentifiers.h (ground truth, not memory)
  HealthAccess/
    App/        HealthAccessApp (entry), AppDelegate (launch-time registrations),
                AppModel (the one object the UI talks to: sync, plans, clients, confirmations, results, undo)
    Model/      Schema (Codable mirror of the contract and the v0.4 workout additions), HealthAccessJSON (sorted keys,
                ISO-8601 Z), ActivityMapping, Format, PlanEstimate ("900 m · 5 parts · about 35 min", parts as text)
    Services/   HealthTypes (generated list of 200 SDK types), HealthUnits, HealthQueries (generic reads, special types,
                characteristics), HealthService (observer, wakes, Effort scores), WorkoutExporter (exhaustive session files),
                DayExporter (days/), CatalogBuilder (catalog.json), ProfileExporter (profile.json), ECGExporter (ecg/),
                VitalsExporter (vitals/, alias for one release), IndexBuilder (+ Dedupe), RatingStore (Apple's effort into
                files, late recovery HR), PlanInstaller, ClientStore (mcp/clients handshakes), FolderStore, Briefing,
                SetupMessage, Prompts (generated from docs/prompts.md by scripts/sync-prompts.py), Notifier (plan
                notifications), SupportStore (StoreKit 2 tip jar), NetworkLedger, Telemetry, DiskLog,
                BackgroundRefresh, AppSettings, JSONBuilder
    Views/      RootView (+ MainTabs), HomeView (the Export tab, + ConnectRow, SupportCard, ClientsView), PlansView (the
                Import tab, + ScheduledPlanRow), SettingsView (+ What left this phone), Layout (TabHeader, BrandBar,
                StatusTile, SectionTitle, FolderRow, InfoRow), Brand (fonts, colours, Wordmark), OnboardingView (4 screens),
                SyncLogView, SessionsView (+ text detail), DaysView, PromptsView (+ PromptDetailView), PlanPartsView,
                Components (confirmation sheet, result line, share sheet), Mark (the mark as a Shape)
    Resources/  Assets.xcassets (AppIcon, AccentColor, Signal, Ground, LaunchBackground, LaunchMark), Fonts (IBM Plex Sans
                Condensed SemiBold and Bold, OFL.txt), PrivacyInfo.xcprivacy,
                TelemetryConfig.example.plist (copy to TelemetryConfig.plist, which is gitignored)
```

## Build, install, simulate

```sh
cd app
xcodegen generate
# device
xcodebuild -project HealthAccess.xcodeproj -scheme HealthAccess -destination 'id=<device udid>' \
  -configuration Debug -allowProvisioningUpdates -derivedDataPath build build
xcrun devicectl device install app --device <device udid> "build/Build/Products/Debug-iphoneos/Health Access.app"
xcrun devicectl device process launch --device <device udid> com.healthaccessmcp.app
# simulator (screenshots in light and dark before anything reaches the phone)
xcodebuild -project HealthAccess.xcodeproj -scheme HealthAccess -destination 'generic/platform=iOS Simulator' \
  -configuration Debug -derivedDataPath build build
xcrun simctl boot "iPhone 18 Pro" && xcrun simctl install booted "build/Build/Products/Debug-iphonesimulator/Health Access.app"
xcrun simctl launch booted com.healthaccessmcp.app
```

`xcrun devicectl list devices` prints the udid. The team id lives in `project.yml` (`DEVELOPMENT_TEAM`); change it and `PRODUCT_BUNDLE_IDENTIFIER` if you are not the author. First install on a phone: Settings → General → VPN & Device Management → trust the developer. Free-team builds expire after 7 days; reinstall. Both builds are warning-free (Xcode's `appintentsmetadataprocessor` notice is not a compiler warning). The project file is generated: change `project.yml` and run `xcodegen generate` again, never edit the `.xcodeproj` by hand. The PostHog SDK is pinned to an exact tag in `project.yml`; `Package.resolved` is committed. `xcuserdata/` and `build/` are ignored (`app/.gitignore`). On the simulator HealthKit is empty and WorkoutKit reports "unsupported"; every screen still renders.

## One component system

Every screen is a standard `List` with `.insetGrouped` style and system sections, on the brand ground. Buttons live inside rows; results and Undo appear inside the row the action came from. The custom pieces are few and shared by every tab (`Views/Layout.swift`): the tab header, the status tile (a list row with the mark's blue or the signal orange as its background), section titles in IBM Plex Sans Condensed, the folder row. The only custom drawing is the mark (`MarkShape`). The warm signal appears only where the user is needed: the orange tile and the orange dot on a plan that waits.

## The app

**Every tab** starts with the same header (`TabHeader`): a small brand bar (the mark and "Health Access MCP" at body size), the tab title in IBM Plex Sans Condensed Bold 32 pt (27 pt when it would not fit one line; it wraps only with very large text), and one line on what the tab does. The tab bar reads Export · Import · Settings. A plan notification opens Import.

**Export**, "Export your Apple Health data" / "Workouts and daily data, as files for your AI."

- **Status tile**, a state, not a chore: "Up to date" with a green check and "14 workouts · synced 2 min ago", no button (the count is the deduped list; the Sync log says "14 files · 13 listed · 1 duplicate hidden"). While a check runs, the mark draws itself and the tile says "Syncing". "Waiting for unlock" with a lock when a wake came in while Health was locked. "Sync failed" with the error and Try again. Orange "Folder missing" / "Needs Health access" / "Notifications off" with the one button that fixes it. Pull to refresh runs a check; the app also checks when it comes to the front and the last check is older than 15 minutes.
- **Folder**: the folder's name with "Connected" and the provider when the bookmark reveals it; tapping opens it in the Files app (`shareddocuments` scheme). No folder: "No folder yet" with Pick.
- **Your AI**: a connection state read from the MCP's handshake files `mcp/clients/<id>.json` (schema `healthaccess.client.v1`). An AI seen within 7 days gives "Connected · Claude Code" / "On MacBook · last seen 2 min ago" and "Connect another AI"; otherwise "Not connected" with Copy (the setup message). After a copy the row shows "Waiting for your AI to connect…" until a handshake file appears. Several clients: "All connected AIs".
- **Sync from Health**: "Automatic · After every workout, while your phone is unlocked." Footer: pull down to sync now.
- **Your files**: Workouts (N workouts, newest date), Days (N files, one per day).
- **Ideas for your AI**: one Prompts row that opens the six Export prompts as a list (title and one line each); each prompt has its own page with Copy.
- **The support card** (StoreKit 2), last.

**Import**, "Import workout plans" / "AI-written plans, scheduled on your Watch."

- **Status tile**: "Up to date" with a green check and "1 on your Watch · checked 2 min ago", or orange "1 plan waiting" / "Tap Put on Watch below, or turn on Automatic.", or "Folder missing" with Pick folder.
- **Folder**: `<folder> / plans`, opens the plans folder in Files.
- **Your AI**: the same connection row as Export.
- **Sync to Watch**: the Automatic switch, "Put new plans on my Watch automatically", off by default and confirmed once when switched on.
- **Waiting for you**: one row per plan without a status file, "Your AI wrote S12" · "1,200 m · 5 parts · about 38 min" · "For Thu 14 May at 07:00, the time in the plan." with Put on Watch and See parts. Failed plans stay here with the error.
- **On your Watch**: scheduled plans still ahead, "Workout app → Scheduled, for Wed 28 Oct at 17:00." with Remove from Watch and See parts. **Earlier**: past and removed plans. **Could not read**: plan files that fail validation, with the reason.
- **Ideas for your AI**: the five Import prompts, same list-and-page pattern.

**Workouts** (the list behind Export's "Workouts" row) are plain rows: plan name or activity, "Thu 14 May · 1,200 m · 36:06 · 129 bpm", and "Rated 7 on your Watch" (effort_source apple), "Rated 6 with your AI" (ai) or "Unrated". No button. The text detail has the summary line, recovery HR (ours and Apple's), the route summary, the parts as "label · distance · pace · HR", the laps in one line, what else the file holds (statistics, events, series, device) and Share (the JSON file).

**Every action is explicit and confirmed.** Put on Watch, Preview on Watch, Copy setup message, picking a folder, the three "write again" buttons in the Sync log and switching usage statistics on all open a confirmation sheet that states the exact effect in one sentence ("Put S26 on your Watch for Sat 26 Oct 10:00. This schedules the workout in the Watch's Workout app and writes plans/<id>.status.json.") with Confirm / Cancel. The sheet shows progress, then the row updates in place with a checkmark and the concrete result and time ("On your Watch for Sat 26 Oct 10:00. Workout app → Scheduled." / "Setup message copied. Paste it to your AI on your computer." / "Folder: Health Access (iCloud Drive). Set 09:41.") and Undo for 10 seconds where undoing is possible. Pull to refresh, "Open in Files" and the Copy buttons on the Prompts screen act directly: the gesture itself is the choice, nothing is written, and the result is visible in place.

**Onboarding**, four screens, one sentence of why and one button each: what it is → pick a folder ("Anything the Files app can see: iCloud Drive, Dropbox, Google Drive, OneDrive, a NAS. Pick one that syncs to the computer where your AI runs.") → allow Health (read only, one sheet for every type) and notifications → connect your AI ("Copy setup message" / "I'll do it later", with the sentence about where plans come from). Then the Export tab runs the first check.

**Settings**, "Settings" / "Folders, permissions and privacy.": Access (Health data folder, tap to change; Workout plans folder, `<folder> / plans`, opens in Files; Health access, "Managed in Health", because iOS does not expose read grants; Notifications) · What gets exported (Reproductive health, on by default; ECG voltage, off by default) · Privacy (What left this phone; Usage statistics, off by default; Sync log) · About (version, Docs, Support, Privacy policy, Restore purchases). "Write the last N days again", "Write the last 30 days" and "Write the catalog again" are small text buttons at the bottom of the Sync log.

## Export everything, catalogued (v0.4)

`scripts/gen_health_types.py` reads `HKTypeIdentifiers.h` of the SDK Xcode builds against and emits `Services/HealthTypes.swift`: 121 quantity, 71 category, 6 characteristic and 2 correlation types (iOS 27.1 SDK; the one deprecated identifier is listed, never requested), each with iOS availability, unit and aggregation style. The app asks for read access to all of it in one sheet, plus workouts, routes, activity summaries, ECGs, heartbeat series, audiograms, vision prescriptions, state of mind, GAD-7 / PHQ-9 assessments and medication dose events (iOS 26). Types the running iOS does not know are skipped, not crashed on. The usage string is the one from `docs/export-coverage.md`.

- **`workouts/<...>.json`** keeps everything of v1 and adds `effort`, `effort_source`, `effort_estimated`; `recovery_hr.apple_1min` (Apple's `HeartRateRecoveryOneMinute` with its metadata) next to the app's own `end` / `1min` / `2min` (also repeated under `computed`); `statistics` (every entry of `HKWorkout.allStatistics` as `{unit, avg, min, max, sum}` keyed by the type's snake name); `totals`; `events` (every event type with metadata; `laps[]` stays as the swim view); `series` (respiratory rate, SpO2, running power and speed, cycling power and cadence, rowing speed, physical effort, underwater depth, water temperature, stroke count, the sport's distance per sample, each `{unit, samples: [[t, v], …]}` ≥ 4 s apart; heart rate stays in `hr_series`); `route_file` + `route_summary` with a sidecar `workouts/<name>.route.json` (a bare array of `[t_unix_s, lat, lon, alt_m, h_acc_m, speed_mps, course_deg]`); `device`; `metadata_typed`; `workout_plan_id`. `zones` is no longer written (the MCP computes zones from `hr_series`); old files still decode.
- **`days/YYYY-MM-DD.json`** (schema `healthaccess.day.v1`): the groups of `docs/export-coverage.md` (activity with the rings, heart with events, respiratory, sleep credited to the morning with sessions, body, blood, mobility, hearing, nutrition by identifier, mind with state of mind and assessments, symptoms, cycle, medications, hygiene, uv, wheelchair, audiogram, vision), each present only with data, named fields explicit `null` inside a present group. Written for today and yesterday on every check, rewritten only when a value changed; "Write the last 30 days" in the Sync log backfills. `vitals/<date>.json` is still written as the alias for one release.
- **`catalog.json`**: per type `{kind, ios, unit, authorized: null, has_data, samples_90d, capped, first, last, exported_in}` for all 200 identifiers and the special types, plus `unknown_types_with_data: []` (HealthKit has no way to list types this build does not know; `healthaccess doctor` compares against its own list). Counts are capped at 10,000 samples per type. Rebuilt once a day at the end of a check, or on request. The day files only query types the catalog says have data.
- **`profile.json`**: age and birth year (never the full date), biological sex, blood type, wheelchair use, move mode, skin type. Written when changed.
- **`ecg/<yyyy-MM-dd_HHmm>_<uuid8>.json`** per ECG of the last 90 days (classification, symptoms status, average heart rate, sampling frequency, number of measurements, algorithm version, device), never overwritten; the voltage series in `<same>.voltage.json` as `[[t_s, uV], …]` only with "Include ECG voltage" on.

## Effort

Apple exports the athlete's own Effort rating (`HKQuantityType(.workoutEffortScore)`, iOS 18+, 1 to 10) and its estimate (`.estimatedWorkoutEffortScore`), both read with `HKQuery.predicateForWorkoutEffortSamplesRelated(workout:activity:)`. Every new session file carries `effort` + `effort_source: "apple"` and `effort_estimated` when they exist. Because the athlete often rates minutes after the workout ends, every check re-reads the scores for the sessions of the last 3 days and patches the files (`RatingStore.applyAppleEffort`): an Apple rating overwrites a missing or `ai` effort, never one marked `app` by an older build. The app has no rating UI and sends no rating notification.

## Dedupe, everywhere

The contract's rule (same `start` ±2 s and the same `source` → one workout, keep the longer) lives in one place, `Dedupe.apply`, and every list the app draws passes through it: the scan that rebuilds `index.json`, the load of an existing `index.json`, and therefore the Export tab, the Workouts list and the briefing. So that the loaded index can apply the rule, the app writes `source` into every index row as an extension beyond the contract's key list (the Rust side reads it as optional; rows without it fall back to the activity). The loser stays on disk and out of the list.

## Notifications

Notifications are only about plans, and each plan is announced once (`announcedPlanIDs`). With Automatic off: "Your AI wrote S27" / "Open to put it on your Watch." when a plan file appears while the app is not in front. With Automatic on: "S27 is on your Watch" / "Scheduled for Wed 28 Oct 17:00." or "Could not put S27 on your Watch" with the reason. Tapping one opens the Import tab. The rating notification of 0.3.0 is gone; any still delivered is taken down on the next launch.

## Plans → Watch

Plans come from `plans/` inside the chosen folder (the AI writes there through the MCP). The app checks it on launch, when it returns to the front, after each check and on every wake while closed.

- **When**: the plan's own `scheduled_for` while it is still ahead; without one, or once it has passed, the next morning at 10:00. The row says which ("the time in the plan" / "the plan has no time"). There is no time setting; the Import prompts make the AI ask when you will train.
- **Put on Watch**: `WorkoutScheduler.schedule(_:at:)` at that time. Verified by reading `scheduledWorkouts` back, then `plans/<id>.status.json` is written with `state: scheduled, method: schedule, workoutkit_id, scheduled_for`. Undo for 10 s removes the plan from the scheduler and removes the status file the app just wrote.
- **See parts**: the plan as text ("label · goal · zone N" under Warm-up / Block n × k / Cool-down), notes, the pool-length reminder, plus Put on Watch and **Preview on Watch**. The preview opens Apple's `workoutPreview` sheet; there is no "Did you add it?" question. When the sheet closes the app writes `state: scheduled, method: preview` and says "Added via preview (unconfirmed)", with Undo.
- **Automatic** (opt-in): every pending plan is scheduled the same way on launch, on return to the front and in every check (observer wakes and background refresh included), with a notification per plan. Failed plans are left for a tap.
- **Remove from Watch**: removes the scheduled workout by its `workoutkit_id` and writes `state: cancelled`; the plan file stays and Put on Watch brings it back.
- **Sports**: run, indoor run, walk, hike, cycle, indoor cycle, pool swim, open-water swim, indoor row, HIIT, elliptical (`PlanInstaller.activity(for:)`); HIIT and elliptical take time goals only.
- Failures are written as `state: failed` with the error text and the plan stays under Waiting for you with a retry.
- `workoutkit_id` lets a finished `HKWorkout` be matched back to its plan exactly (labelled steps, `plan_ref`). Pool length cannot be set through WorkoutKit; the Watch keeps its own.

## briefing.md

Written into the folder after every check and after every plan status change, exactly per `docs/schema.md`: header with the timestamp, "Last 4 weeks" per ISO week, "Recent sessions" (newest first, max 10), "Vitals" (latest resting HR, HRV, sleep, weight, steps, VO2max with the date and the 21-day direction), "Next session", "Open", "Limits". Dates and numbers use a fixed en_US_POSIX format ("Thu 14 May 07:12", "1100 m", "14.8 km"), because the reader is an AI, not the phone's locale.

## Storage

Any folder the Files app can open. The app stores a security-scoped bookmark and never assumes iCloud. `FolderStore.provider` reads the provider from the bookmark URL where the path reveals it: iCloud Drive (`com~apple~CloudDocs` or the ubiquitous-item flag), an iCloud app container or a provider named in `Mobile Documents/<container>`, SMB, an external drive, On My iPhone. Third-party providers under `File Provider Storage` reveal no name, so none is shown. The setup message is the same for everyone: register `npx -y healthaccess-mcp`, which finds the folder on its own. It carries the folder's name, and for iCloud Drive the usual Mac path, only as a hint for `--dir` in case the search comes up empty.

## How the files get written

- **Incremental.** `HKAnchoredObjectQueryDescriptor` over workouts with a persisted `HKQueryAnchor` and a fixed lower bound (the first-run window, 60 days). A run only sees workouts added since the last run; files that already exist are never overwritten. "Write the last N days again" (Sync log) resets the anchor.
- **Per check**: new session files (+ route sidecars), the late recovery-HR patch, the Apple effort re-check, the catalog when it is a day old, vitals and day files for today and yesterday, profile.json, new ECG files, the index, the client files, the briefing.
- **Wakes.** `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` wake the app when a workout is saved; `BGAppRefreshTask` `com.healthaccessmcp.app.export` is the fallback every few hours; a locked phone defers the run to the next unlock. Every launch, wake, run and error goes to `Application Support/HealthAccess/healthaccess-log.txt`, shown under Settings → Sync log.

## Usage statistics (opt-in)

Off by default: the stored key reads as `false` until the user confirms the toggle, with or without the config plist (`AppSettings.telemetryEnabled = d.bool(forKey:)`; the only writer is the confirmed toggle). The toggle is enabled only when `HealthAccess/Resources/TelemetryConfig.plist` is bundled (copy the example, fill `PostHogHost` + `PostHogProjectToken`, run `xcodegen generate` again). Events: `app_opened`, `export_completed {workout_count, duration_ms, trigger}`, `export_failed {error_domain, code}`, `plan_put_on_watch {method}`, `plan_scheduled`, `setup_message_copied`, `ai_connected {client}` (once per handshake id, `client` normalised to claude-code, claude-desktop, cursor, codex, lm-studio, goose or other; ids kept in `AppSettings.announcedClientIDs`). Distinct id = random per-install UUID. A `setBeforeSend` allowlist strips everything else the SDK attaches. No health values, file names or folder paths, by construction. "What left this phone" lists every event name and host sent in the current session; with the toggle off it reads "Nothing. Health Access has no server."

## Copy voice

Plain, short sentences. No em dashes anywhere in the UI, no "Oops", no "Success!", no exclamation marks; states are facts, buttons are verbs. Vocabulary: session, parts, "Your AI wrote S26", "Put on Watch", "See parts", "Usage statistics", "Sync log", "What left this phone". Never "export", "pending", "rescan", "telemetry" or "background" in the UI (the log tags are `sync`, `observer`, `refresh`, `usage`; the analytics event names keep their contract names). iCloud is named only where the folder actually is iCloud. No real health data, names or paths in the repository; examples use the folder "Health Access", the id 7A1C3E90 and the source "Apple Watch".

## Migration from the old build

- **Bundle id changed** at the rename (codename-era `com.leonhardprinz.Tide` → `com.healthaccessmcp.app`), so iOS treats Health Access as a new app with its own container: onboarding runs again and the first check re-reads the 60-day window. Nothing in the folder is touched; files whose `<uuid8>` already exists are skipped. Uninstall the old app afterwards.
- **UserDefaults keys** are `healthaccess.<name>`; pre-rename `tide.<name>` keys are moved once (`AppSettings.migrateLegacyKeys()`). The v0.2 key `planInstallMode = preview` becomes `putOnWatchMode = preview` once; the stored keys `telemetryEnabled` and `exportedTotal` keep their names; `zoneBounds` is no longer read.
- **Log file** is `Application Support/HealthAccess/healthaccess-log.txt`; a codename-era `Tide/tide-log.txt` in the same container is moved there on first launch.
- **BGTask identifier** is `com.healthaccessmcp.app.export`; the notification category is `HEALTHACCESS_PLAN`.
- **Schema ids** written are `healthaccess.workout.v1`, `healthaccess.vitals.v1`, `healthaccess.index.v1`, `healthaccess.day.v1`, `healthaccess.catalog.v1`, `healthaccess.profile.v1`, `healthaccess.ecg.v1`; plans with either `healthaccess.plan.v1` or the pre-rename `tide.plan.v1` tag are accepted, and workout files that still carry `tide_version` or `zones` decode fine.

## Deviations from the written specs, and why

- **`index.json` rows carry `source`**, beyond the contract's key list, so the dedupe rule can run on the index itself and not only on the files. The Rust parsers treat it as optional.
- **Heart rate is not duplicated into `series.heart_rate`**: it stays in `hr_series` (the v1 field the MCP already strips unless asked). Every other series of `docs/export-coverage.md` is in `series`.
- **`recovery_hr` keeps `end` / `1min` / `2min` flat** for v1 readers, repeated under `computed`, with `apple_1min` beside them.
- **`catalog.json.unknown_types_with_data` is always `[]`** from the app: HealthKit cannot enumerate types a build does not know; the doctor finds them.
- **Undo of "Put on Watch" / preview removes the status file** the app itself wrote seconds earlier (the only file the app ever removes). A `cancelled` status means the athlete took the plan off the Watch (Remove from Watch), which Undo does not mean.
- **Pull to refresh, "Open in Files" and the per-prompt Copy buttons have no confirmation sheet**: the gesture is the explicit choice, nothing is written, and the result is visible in place.
- **A fourth status wording** exists inside the neutral state: "Could not write files" with the error, for a failed check that is not a locked phone. Visually it is the neutral state; the three visual states stay.
- **The plan notification** reads "Your AI wrote S27" / "Open to put it on your Watch." (title and body) instead of one line with an em dash, to keep the no-em-dash rule.
- **`plan_scheduled`** is still sent when a plan reaches the Watch; `plan_put_on_watch {method}` is the new event for the tap.

## Release hygiene

`PrivacyInfo.xcprivacy` (no tracking; UserDefaults CA92.1; file timestamps C617.1/3B52.1; product-interaction + diagnostic data declared for the opt-in usage statistics), `ITSAppUsesNonExemptEncryption = false`, `NSHealthShareUsageDescription` per `docs/export-coverage.md`, no `NSHealthUpdateUsageDescription` (nothing is written to Health), portrait only, `UIBackgroundModes: fetch`, version `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in `project.yml` (0.6.2 / 21, set by `scripts/bump-version.sh`), launch screen = `LaunchBackground` colour + `LaunchMark` image, icon generated by `scripts/make_icon.py`.

## Support card (StoreKit 2)

The last card on the Export tab is the tip jar: `com.healthaccessmcp.app.support.card` (non-consumable, removes the card for good) and `com.healthaccessmcp.app.support.coffee` (consumable, the card stays). `Services/SupportStore.swift` loads the products, finishes transactions, listens to `Transaction.updates` and reads `Transaction.currentEntitlements`; `supportCardRemoved` in settings only caches the answer. Settings → About has Restore purchases (Apple requires it for non-consumables). The scheme carries `StoreKit/HealthAccess.storekit`, so Run from Xcode shows test prices in euro and Xcode's fake payment sheet on the simulator and on a phone. `xcodebuild` plus `simctl launch` or `devicectl` does not apply that file: the card then says the App Store did not answer, which is also what a build without a paid developer account shows. Before release: create the same two product ids in App Store Connect (prices 4.99 and 2.99 euro tiers), sign the Paid Apps agreement, enrol in the Small Business Program (15 percent instead of 30), and submit the products with the first version. Wording stays "support" and "coffee", never "donate": App Review reserves donations for registered nonprofits.

## Known limits

- iOS hides which HealthKit read permissions were granted; "Managed in Health" and the catalog's `has_data` are all the app can show.
- Rowing distance per step/workout needs `distanceRowing` (iOS 18+); on iOS 17 the workout total falls back to `totalDistance`, steps have no distance.
- `WorkoutStep.displayName` (step names on the Watch), the Effort scores, state of mind and assessments need iOS 18; medication dose events need iOS 26. Older systems skip them.
- Apple's preview sheet does not report back; "Added via preview (unconfirmed)" is as honest as it gets.
- The dedupe loser stays on disk (the app never deletes session files).
- Catalog counts stop at 10,000 samples per type in 90 days (`capped: true`); heart rate and steps hit that on a Watch wearer.
