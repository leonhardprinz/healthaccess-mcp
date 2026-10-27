# Phase 0 spike — checklist

Gate: a real swim ends → `workouts/<date>_PoolSwim_<id>.json` appears in the chosen iCloud folder with no tap.

- [x] Xcode installed, signed in, Personal Team visible
- [x] iPhone Developer Mode on
- [ ] `xcodegen generate` → open → Team set → build to phone
- [x] App: Choose folder → an iCloud Drive folder (e.g. `Health Access`)
- [x] App: Request Health access → allow all
- [x] App: Export last 10 → files appear on the Mac within a minute (iCloud sync)
- [x] Check one JSON: `activities[]` carries the custom step names? (metadata) — this decides whether splits need `workoutEvents` instead
- [ ] Swim with the Watch, phone in the bag → unlock phone afterwards → did the observer fire and write the file? (log shows "observer fired")
- [ ] Note: was the HealthKit background-delivery entitlement accepted on the free team?

Known unknowns to record here, not guess: where Apple puts custom-workout step labels in HealthKit (activities metadata vs events), whether `frequency: .immediate` is honoured for workouts, battery impact.

## Findings 2026-10-24
- Free personal team accepted `healthkit` + `healthkit.background-delivery` entitlements. Signed via `xcodebuild -allowProvisioningUpdates`, installed via `devicectl` — no Xcode UI needed.
- Export → iCloud → Mac: < 1 min.
- Custom-workout steps arrive as `workoutActivities` with metadata `WOIntervalStepKeyPath` = "block.rep.step" (warm-up = 0.0.0), `WOIntervalStepSuccessful`, `WOIntervalStepDistacnceGoalAchievedDuration` (sic, Apple's typo). Per-step distance + avg HR available (worked per-step values: see `examples/`, synthetic). **Step labels are NOT exported** → join key path against the plan we generated.
- Lap events: type 3 = length (HKSwimmingStrokeStyle, HKSWOLFScore), type 7 = segment, type 1 = pause.
- The Watch can under-count a slow, drill-adjacent 50 m length (logged as ~35 m). Not our bug.
- A third-party cycling app wrote duplicate workouts (two entries, same start) — dedupe by start time + source in core.
- Remaining gate item: background delivery after a real swim, phone unlocked later. Test = the next planned swim.

## Phase 1 findings (2026-10-24, app v0.2.0)

Verified against the iOS 27.1 SDK (`WorkoutKit.framework/Modules/WorkoutKit.swiftmodule/arm64e-apple-ios.swiftinterface`, 511 lines) and a macOS harness that compiles the Model + Services sources and runs the encoder, zone/recovery maths, plan validation, `CustomWorkout` building, index dedupe and the rating patch (all pass). Phone: iPhone 15 Pro, iOS 26.6.2.

**WorkoutKit, as it really is**
- `CustomWorkout(activity:location:displayName:warmup:blocks:cooldown:)`, `location` is `HKWorkoutSessionLocationType` (`.indoor` for pool). There is no pool-length or swimming-location parameter on `CustomWorkout` (`swimmingLocation` exists only on `SingleGoalWorkout`). Pool length stays a Watch setting.
- `IntervalBlock(steps:iterations:)`, `IntervalStep(.work|.recovery, step: WorkoutStep)`, `WorkoutStep(goal:alert:displayName:)` — `displayName` is iOS 18+; `WorkoutGoal.distance(Double, UnitLength)` / `.time(Double, UnitDuration)` / `.open` / `.poolSwimDistanceWithTime` (18+); alerts: `HeartRateZoneAlert(zone:)` a.k.a. `.heartRate(zone:)`, plus range/cadence/power/speed variants. `CustomWorkout.supportsGoal/supportsAlert/supportsActivity` exist and are used before building.
- `WorkoutScheduler.shared.schedule(_:at: DateComponents) async` does not throw; success is verified by reading `scheduledWorkouts` back. `requestAuthorization() async -> AuthorizationState`, `authorizationState`, `isSupported`, `maxAllowedScheduledWorkoutCount`. `AuthorizationState` is not `Sendable` (strict-concurrency warning when returned into the main actor) — the installer returns a Bool + String instead.
- The preview sheet is `View.workoutPreview(_ plan: WorkoutPlan, isPresented:)` from `_WorkoutKit_SwiftUI`, auto-loaded as a cross-import overlay when both SwiftUI and WorkoutKit are imported. It installs the workout into the Watch's Workout app ("Add to Watch"); it does **not** schedule and does not report what the user tapped → the app asks afterwards.
- `HKWorkout.workoutPlan` (`get async throws`, WorkoutKit extension) returns the `WorkoutPlan` a finished workout was started from. Its `id` is the UUID we created → exact `plan_ref`, no name matching needed. Stored as `workoutkit_id` in the status file.
- `WorkoutPlan.openInWorkoutApp()` is watchOS-only.
- Building a `CustomWorkout` works even on macOS 26 (`supportsActivity(.swimming/.rowing) == true`; `WorkoutScheduler.isSupported == false` there, as expected).

**HealthKit**
- Apple numbers custom-workout steps `block.rep.step`, reps 0-based, warm-up `0.0.0`, cool-down as a trailing single-step block `(blocks+1).0.0` (seen in every real swim/row export). Step labels never reach HealthKit; the join against the plan is the only way.
- Lap events carry `HKSwimmingStrokeStyle` (1 mixed … 6 kickboard) and `HKSWOLFScore`; segment events (type 7) carry SWOLF only; pause = 1.
- `HKLapLength` metadata is an `HKQuantity` ("50 m"), `HKSwimmingLocationType` 1 = pool, 2 = open water; indoor row = `HKIndoorWorkout = 1`.
- `distanceRowing` is iOS 18+; `HKAnchoredObjectQueryDescriptor` / `HKSampleQueryDescriptor` / `HKStatisticsQueryDescriptor` (iOS 15.4+) make everything async without continuations. `SortDescriptor(\.startDate)` on HK types triggers "KeyPath is not Sendable" warnings under strict concurrency — sorted in memory instead.
- Observer timing: HealthKit fires the moment the workout sample is saved, before the recovery heart-rate samples exist → `recovery_hr` is patched on the next run (see README).
- Observer queries and `BGTaskScheduler.register` must happen in `application(_:didFinishLaunchingWithOptions:)`; in a background launch no SwiftUI scene is connected, so the Phase 0 `.task` registration would never have run. v0.2.0 uses `@UIApplicationDelegateAdaptor`.

**PostHog iOS 3.92.0**
- `PostHogConfig(projectToken:host:)`; lifecycle/screen capture, swizzling, session replay, feature-flag preload, surveys, exception autocapture all off; `personProfiles = .never`; `getAnonymousId` pins the distinct id to the install UUID; `setBeforeSend` allowlist strips `$locale`, `$timezone`, `$network_*`, `$screen_*`, `$device_*` etc. `remoteConfig` is deprecated (always on, no-op); `PostHogLogsConfig` has no `enabled` flag (logs only flow through explicit `captureLog`, which the app never calls). `close()` resets the SDK so the toggle can re-enable in the same session.

**Still unverified without a tap on the phone** (see the report / test list): background wake after a real swim, WorkoutKit authorization prompt, the preview sheet's exact buttons, `HKWorkout.workoutPlan` returning a non-nil plan for a Watch-run scheduled workout, notification tap → rating sheet routing, iCloud placeholder download when a plan file written on the Mac has not been downloaded yet.
