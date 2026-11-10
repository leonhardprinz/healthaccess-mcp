# Changelog

Versions are one number for everything: the app's `MARKETING_VERSION`, the Rust crates and the npm packages (`scripts/bump-version.sh`). The app's build number counts up on its own. Dates are Europe/Ljubljana.

## 1.0.1 (app build 24), 2026-11-10: your whole history, and the fixes from a review before 1.0

### New
- **Older data.** Settings → Older data imports the years before the app was set up: the last 12 months, the last 3 years, or everything Health has. It says how many workouts and days that is before anything is written, goes newest first, can be paused, and carries on where it stopped. It runs while the app is open and the phone unlocked (iOS locks Health with the phone). Days long ago are read by what Health had back then, not by the catalog's last 90 days, so a type you stopped using is still exported.
- **No more gaps.** Every sync queues the days since the last one and writes them. A new install gets its 60 days of day files (it got two), and a week with the app swiped away is filled in when you open it.
- A folder with years of sessions is listed without opening every file on every sync: the app remembers what it read and looks again only at files that changed.
- Dates in another year show the year.

### Fixed in the app
- **Day files: activity rings are written as `{goal, actual}`**, the shape of the contract. Builds up to 23 wrote them flat, which server 1.0.0 could not parse: it dropped the whole day.
- **A rating changed through your AI stays.** The app copied Apple's older rating back over it on the next sync; it now does that only when Apple's own number changes.
- **Workouts wake the app from the first launch.** On a fresh install the observer started before Health access was asked for, ended with an error, and stayed dead until the app was restarted.
- A wake that arrives while a sync runs waits for it and runs after, inside its own background time, and a sync asks iOS for time to finish when you leave. Before, the wake was answered "done" at once and the work could be suspended.
- **A plan is put on the Watch once.** Its WorkoutKit id comes from the plan id, so a lost or unreadable status file no longer schedules it again.
- **Plan steps without a kind are work**, as the plan tool says. The app took a time goal without one for a rest, so the hard intervals of a HIIT plan went onto the Watch as recoveries.
- Picking a different folder writes the last 60 days there (it stayed empty), also when a sync was running at that moment.
- A phone that locks in the middle of a read no longer leaves a half-empty session or day file, and the catalog is not saved from a locked Health (day files would have lost values for a day).
- A day file is only written when the day has values, and never replaces a fuller one with nothing.
- A queued day that cannot be written (storage full, a server that is away) stays queued instead of being dropped.
- Route sidecars are not counted as unreadable sessions; an orphan sidecar no longer hides its session from the import.
- Crash guards: a GPS point that is not a number, a negative activity code, and durations or distances from files that do not fit a number.
- The support card asks the App Store for prices again when the first try got no answer; a stale folder bookmark is renewed; plan files have upper bounds (256 KB, 50 blocks, 50 steps a block).

### Fixed in the MCP server and CLI
- **Day files with flat rings parse** (both shapes are read), so days written by builds up to 23 are no longer dropped.
- **Days and weeks are local.** Sessions were put into days and weeks by UTC while day files are local: west of Greenwich an evening session landed on the next day and "today" turned over hours early. `list_workouts since=<date>` means local midnight.
- **`push_plan` writes `kind: "work"`** on block steps that have none.
- **`rate_workout` no longer reports a failure after it has written the rating** (when `index.json` was half synced).
- **Ids match exactly, by a prefix of four characters or more, or by the id at the end of the file name.** "3", "pool" or a time of day used to pick a workout.
- Route sidecars (`*.route.json`) are not read as workouts: `doctor` reported every GPS workout as broken, and a scan read each sidecar in full.
- A panic on a corrupt file answers the request with an error instead of leaving it open.
- Plans are only read for the sports they are joined onto (a long `training_summary` on a folder with many plans took seconds).

### Known, not in this release
- Plan file names contain colons, which Windows does not allow: `push_plan` fails there.
- Tool results have no size cap (ten years of `get_vitals` is about 1 MB), and values in day files are rounded to one decimal on the way out.
- Folder discovery stops at the first place that has a folder; a shared folder in iCloud Drive can win over your own elsewhere. Set `--dir` when you have more than one.

## 1.0.0 (app build 23), 2026-11-07

- **A plain explainer under each status tile**, on Export and Import: what happens on its own from here and what needs you. For example, that exports run after every workout even with the app closed, pause while the phone is locked or after the app is swiped away, and that plans go onto the Watch by a tap or, with Automatic, by themselves within hours.

## 1.0.0 (app build 22), 2026-11-07: first App Store build

- **Signed by PTC's team** (72995T7U66); App ID `com.healthaccessmcp.app` with HealthKit and background delivery.
- `NSHealthUpdateUsageDescription` added: App Store upload requires it for HealthKit apps; the text says the app never writes to Health.
- **App Store Connect:** app record "Health Access MCP" (Apple ID 6831916470), listing text, five screenshots, privacy labels (data not linked to you: usage data, diagnostics), age rating, free with two in-app purchases (card €9.99, coffee €2.99), available in 175 countries. Build 1.0.0 (22) uploaded and in internal TestFlight.
- `scripts/archive-upload.sh` signs and uploads with the Xcode account (an App Manager API key may not use cloud-managed distribution certificates).
- The MCP server and CLI carry the version number only; npm stays at 0.6.2 until the next server change.

## 0.6.2 (app build 21), 2026-10-27: security fixes before the source goes public

An independent review before opening the repository found these; all are fixed, with regression tests.
- **Folder confinement in the MCP server and CLI.** Workout ids, file names, index rows and plan ids are single names inside `workouts/` or `plans/`. Absolute paths, `..`, symlinks, FIFOs and devices are refused; reads are capped at 64 MB; an error never echoes a file's contents.
- **`rate_workout` writes only into files that parse as workouts**, and keeps the file's permissions.
- **Folder discovery never guesses.** With more than one Health Access folder on the computer (one could be a folder someone shared with you), the server lists them and asks for `--dir`, `HEALTHACCESS_DIR` or `dir` in the config.
- **Temp files** for atomic writes get random names and are created exclusively, so a planted symlink is never followed.
- **Plans have upper bounds** (a step at most 1000 km or 24 h, pool length at most 100 m), in the server and in the app.
- **App:** no number from a file can crash it (every conversion is checked, scores are 1 to 10, repeat counts are clamped); paths from the index stay inside the folder; reads are capped; plan names are one line in notifications and `briefing.md`.
- **CLI** drops terminal control characters from everything it prints. **MCP instructions** tell the AI that text in the folder is data, not instructions.
- **Site:** http and www redirect to https; HSTS, a strict CSP (the site runs no scripts) and `X-Frame-Options`.
- **Build:** release binaries no longer carry the build machine's paths; the release workflow pins its actions to commit hashes and keeps no token in the checkout; tool versions in scripts are exact; the site is built only from tracked files.
- **Test data:** every value in tests and docs comes from the synthetic athlete in `examples/`.

## Distribution, 2026-10-27

- **npm:** `healthaccess-mcp` 0.6.1 and its five platform packages are live (published by `pt-consultancy`, passkey 2FA). `npx -y healthaccess-mcp` installs and runs from a clean cache.
- **Official MCP registry:** listed as `com.healthaccessmcp/healthaccess-mcp` 0.6.1, pointing at the npm package. The namespace is verified by a TXT record on healthaccessmcp.com; the key lives outside the repo in `~/.config/healthaccessmcp/`. Release step: `scripts/publish-registry.sh`.
- **Claude plugin:** `claude-plugin/` holds a plugin with the MCP server (pinned `npx`) and the eleven prompts as skills. Validated, not submitted: Anthropic's directory needs the repository public before a listing goes live.
- **Codex CLI:** setup documented on the local-models page.
- **App Store kit** in `appstore/`: every App Store Connect field as paste-ready text within Apple's limits, privacy labels, age rating, in-app purchases, EU trader details, review notes with a sample plan (`site/review/sample-walk-plan.json`), five 6.9" screenshots, `scripts/archive-upload.sh`.
- **Website:** healthaccessmcp.com on Cloudflare Workers; support@ and privacy@healthaccessmcp.com on iCloud+ custom email domain.

## 0.6.1 (app build 20), 2026-10-27

- **Three tabs, one layout.** Export ("Export your Apple Health data"), Import ("Import workout plans"), Settings. Each tab: a small brand bar, the tab title as the one big element, one line on what it does. Export and Import then share one order: status tile, Folder, Your AI, Sync, content, Ideas for your AI.
- **Status tile shows a state.** Green check and no button when everything is done; the mark draws itself while syncing; a lock while Health waits for unlock; "Sync failed" with Try again; orange with its one fix only when you are needed. Pull down to sync or check again.
- **Brand type in the app.** IBM Plex Sans Condensed (bundled, OFL) for every heading, the system font for everything you read, the brand ground behind the lists. The title steps down a size on narrow phones and wraps only with very large text.
- **Prompts as a list.** One row per tab opens the prompts of that tab's group; each prompt has its own page with Copy. Every prompt has an about line.
- **Words.** Finished sessions are "Workouts" everywhere; Settings shows the Health data folder and the Workout plans folder; "Connected · Claude Code" no longer repeats the client name.
- **Opt-in `ai_connected` event** (`{client}`, from a fixed list, once per client) in the app's usage statistics, off by default. Listed in both privacy pages.
- Site: real screenshots of the three tabs (synthetic data), a social preview image in the brand face (`scripts/make-og.py`).

## 0.6.0, 2026-10-27

- **Import tab** (first called Plans): what your AI wrote with the day and time it goes onto the Watch, what is on the Watch with Remove from Watch, what was there earlier, unreadable plans.
- **The plan's own `scheduled_for` sets the Watch time**; without one, or once it has passed, the next morning at 10:00. The "Put on Watch means" setting is gone.
- **Opt-in "Put new plans on my Watch automatically"**: confirmed once, runs on launch, on return to the app and on every sync or wake, one notification per plan.
- **Prompts rewritten for any sport**, eleven in two groups: Export (weekly check-in, explain my last session, am I overdoing it, sleep and recovery, long-term trends, summary for a coach or doctor) and Import (plan my next session, plan my week, change my plan, build up to a goal, make my workout a Watch workout). Every Import prompt asks when you will train. `scripts/sync-prompts.py` copies `docs/prompts.md` into the app and the site.
- **Plans for eleven sports:** run, indoor run, walk, hike, cycle, indoor cycle, pool swim, open-water swim, indoor row, HIIT, elliptical (the last two take time goals only).

## 0.5.0 (app build 9), 2026-10-26

- **npm distribution:** a launcher package plus five platform packages (macOS arm64 and x64, Linux x64 and arm64, Windows x64), cross-compiled with zig. No network code in any published binary.
- **Folder discovery:** without `--dir`, the server finds the Health Access folder in iCloud Drive, then Dropbox, Google Drive, OneDrive and Box, then `~/Documents`. The setup command is the same for everyone: `npx -y healthaccess-mcp`.
- **Fix:** Claude Code speaks MCP 2026-07-28 without `initialize`, so the handshake file was never written and the app stayed "Not connected yet". Now recorded on `server/discover` and the first list request, with a regression test.
- **Website:** Cloudflare Workers static assets, self-hosted IBM Plex, a formal privacy policy (PTC d.o.o. as controller), a support page, the imprint in every footer, install docs on `npx`.

## 0.4.3 (app build 8), 2026-10-25

- **Support card** at the end of the Export tab, StoreKit 2: €4.99 removes it for good, €2.99 coffee leaves it. Restore purchases in Settings.

## 0.4.2 (app build 7), 0.4.1 MCP, 2026-10-25

- Fix: the Health permission sheet crashed on share-only types (vision prescriptions, medication dose events).
- Walkthrough fixes: the status mark after a sync, the folder line after a relaunch, first-setup wording, the setup message's share sheet, the handshake machine name without the network suffix.

## 0.4.0, 2026-10-25

- First full release: export everything with a data catalog, day files, profile and ECG files, explicit confirmations, connection state from handshake files, the MCP with prompts, briefing and coverage tools, the docs site and `llms.txt`, synthetic examples.
