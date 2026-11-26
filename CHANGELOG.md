# Changelog

Versions are one number for everything: the app's `MARKETING_VERSION`, the Rust crates and the npm packages (`scripts/bump-version.sh`). The app's build number counts up on its own. Dates are Europe/Ljubljana.

## 1.1.0 (app build 38), unreleased: Cloud upload to Google Drive, a WebDAV server or S3 storage, and plans back from there

Not released. What the app offers in this version: Google Drive, any WebDAV server, any S3 storage. Google Drive is tested on a real iPhone against a real account (sign-in, first upload, the folder in My Drive). WebDAV is tested against a real server (the Apache that ships with macOS: unit tests, the simulator with 1,649 files up and a plan back, and a real iPhone over the local network). The S3 signature matches Amazon's published examples; a real upload to a bucket is not tested.

OneDrive and Box are shown greyed out as "Soon": a tap, after a confirmation, sends one anonymous `drive_interest` event so we learn who wants them. The code for OneDrive, Dropbox, Box and pCloud is in the app and tested against a stubbed network only. Each stays hidden until its client id is in `CloudConfig.plist` (see `app/README.md`, "Cloud upload"). What follows describes all seven.

### New
- **Cloud upload (Settings).** The app uploads a copy of the folder to Google Drive, OneDrive or Dropbox itself, after a sign-in on the drive's own page. The folder picker cannot reach these storage apps, so this is the way to them. The folder you picked stays the original; after every sync the new and changed files go up, newest first, `index.json` and `briefing.md` last. A first upload of a long history runs while the app is open and picks up where it stopped. Nothing passes through a server of ours.
- **Seven places in the code, three offered.** Google Drive, OneDrive (personal and work accounts), Dropbox, Box and pCloud through a sign-in on their own page. Any WebDAV server (Nextcloud, ownCloud, a Synology or QNAP NAS, Koofr, Hetzner Storage Box and others) through its address, a name and a password. Any S3 storage (Amazon S3, Cloudflare R2, Backblaze B2, MinIO, Wasabi) through a bucket and a key pair. Several can be on at once. Not possible: MEGA and Proton Drive (no public API for an app like this one), iCloud Drive (pick it as the folder).
- **A server in your own network** may be reached over plain http (`NSAllowsLocalNetworking`); everything else has to be https. iOS asks once for local network access.
- **The app asks for one folder, not the drive.** Box is the exception: it has no permission for one folder, so the sign-in covers the account and the app says so before it. pCloud: an app with its own folder. WebDAV: the folder whose address you give. S3: give the key access to one bucket. Google: only the files the app created (`drive.file`). OneDrive: the app's own folder (`Files.ReadWrite.AppFolder`, Apps › Health Access). Dropbox: an app-folder app (Apps › Health Access). The sign-in is OAuth 2 with PKCE in the system sign-in sheet; the long-lived token is in the keychain.
- **Plans come back.** On OneDrive, Dropbox, Box, pCloud, WebDAV and S3 a plan file that an AI puts into `plans/` there is brought to the phone on the next sync and shows up in the Import tab like any plan. Google shows an app only its own files, so there the AI edits `plans/inbox.json`, a file the app made for that (one plan, or a list). The inbox works on the other two as well.
- **The app says where the folder goes before you connect.** Google Drive: a new folder, Health Access, at the top level of My Drive, which you may move inside Drive. WebDAV: inside the folder whose address you give. S3: under the folder (prefix) you set. The same sentence is in the confirmation and under the drive's row.
- **`README.md` in the uploaded folder** tells an AI that reads the drive through its own connector what the files are and how to write a plan, with an example the app's own validator accepts.
- "What left this phone" lists every upload run by drive, with the number of files.

### Thought through before anyone had to ask
- **"Pick folder" asks first: a folder or a cloud drive.** On the Export tab, the Import tab, in the first steps and in Settings, the button opens one question, "Where do your files go?". "A folder" opens the iOS picker. "A cloud drive" shows the drives; when one is connected, the app keeps the files on this iPhone (On My iPhone › Health Access) and uploads them from there, with no second step. The confirmation says so. Before this, the picker and the drives were two separate places, and a tester without a folder did not find the drives.
- **No folder to pick? "Keep it on this iPhone."** The first steps and Settings offer a folder in the app's own storage (On My iPhone › Health Access in the Files app), for someone whose AI reads a cloud drive. The Export tab shows Cloud upload under the folder, and each connected drive with what it is doing.
- **A new connection starts from nothing.** Connecting again may mean another account or another server, so what the last one held is forgotten and the files already there are found by name. Before this, a reconnect to a different account could have skipped the upload.
- **A sign-in that ran out says so.** The Export tab shows it, and a notification is posted once.
- **A long first upload goes on with the app closed**, as a background processing task when the phone rests.
- **Wi-Fi only** as a switch; Low Data Mode always holds uploads back.
- **Files that iCloud moved off the phone** are asked back and uploaded when they arrive, and the count is shown. They are never taken for deleted.
- **A plan the app cannot read gets a status file** with `failed` and the reason ("not a valid plan: …"), so an AI that only sees the drive learns why nothing happened. The note goes when the file is a valid plan again.
- **The message for the AI** (Export → Your AI → Copy) names the uploaded folder and tells an AI with a connector to start with `README.md`.
- **Errors say what is wrong**: an unknown address, a certificate iOS does not trust, http outside the local network, a refused name and password, a drive that keeps asking to slow down. A redirect to another host never carries the sign-in along.
- **A second plain-English pass over every string in the app and every page of the site.** One word for one thing (a recorded workout is a workout, a planned one a workout plan; the app uploads, it does not send or mirror; the folder is the Health data folder), shorter sentences, the condition before the instruction. The site and the store texts name what 1.1.0 offers; `llms-full.txt` lists all thirteen tools and twelve sports.
- **Names are made safe for every drive** (`: * ? " < > | \` become `_`), not only for OneDrive: the Windows sync of Dropbox, Box, pCloud and Nextcloud stumbles over them too.

### Limits
- A file deleted on the phone stays on the drive; only a plan's status file that you undo is removed there.
- A plan the app uploaded and an AI then edits on the drive is not read again. A changed plan is a new file, or goes through the inbox.
- Woken in the background the app has a few seconds for uploads; the rest goes with the next sync, when the app is opened, or in a background processing task. How well that works on a locked phone is not tested yet.

### For developers
- `Services/Cloud/`: `OAuth.swift`, `CloudHTTP.swift`, the three drives, `CloudMirror.swift` (state in Application Support, decisions in `CloudPlanner`). Unit tests in `HealthAccessTests` (73), run with `xcodebuild test`; `scripts/webdav-test-server.sh start` first, or the two live WebDAV tests are skipped.
- Client ids come from `Resources/CloudConfig.plist` (gitignored; copy the example). Without the file Cloud upload offers WebDAV and S3 only.

## 1.0.6, never released on its own, part of 1.1.0: Google Drive and OneDrive can't be picked, and the app says so

A user wrote that Google Drive is greyed out in the folder picker. That is not a bug in the app and not a missed step: when an app asks iOS for a folder, the picker only offers storage apps that let other apps open their folders. iCloud Drive, On My iPhone and network drives do. Google Drive and OneDrive don't (seen on iOS 27.2), for any app. The app, the site and the README promised them anyway.

### Fixed
- **The app no longer promises storage it can't use.** The folder step of the onboarding names iCloud Drive and a network drive, and says under the buttons why Google Drive and OneDrive are greyed out. Settings → Access carries the same sentence.
- **The same claim, everywhere else:** the site (home page, comparison pages, privacy pages, `llms.txt`, `llms-full.txt`), the README files, `docs/schema.md`, `docs/mcp.md`, the App Store description, and the sentence the server gives an AI when it finds no folder. Dropbox and Proton Drive are no longer named, because nobody has tested them.
- New on the support page: "Google Drive or OneDrive is greyed out in the folder picker". New question in the FAQ: "Can I export Apple Health data to Google Drive or OneDrive?"

### Server
- Only the no-folder sentence changed.

## 1.0.5 (app build 29), 2026-11-21: strength, race day, pace alerts, run splits, and sleep counted by night

Most of this release comes from the first feedback of someone other than the developer.

### New
- **Strength workouts.** A plan can have `sport: "strength"`, and any step can have an `open` goal: it lasts until the athlete taps on the Watch. One open step per set, with the exercise, reps and weight in the label ("Squat 5 x 60 kg"), and a timed rest. HIIT, elliptical and strength take time or open goals; the Watch measures no distance for them. Strength plans are joined onto strength workouts like every other sport.
- **Race day.** A run or cycle plan can be a `pacer` instead of steps: one distance in one time (`{"distance_m": 10000, "time_s": 3000}`). The app puts it on the Watch as Apple's pacer workout, which shows ahead of or behind the even pace for the whole distance.
- **Automatic, offered when it matters.** The first plan you put on your Watch by hand offers "Turn on Automatic" once, under its result. It leads to the same confirmation as the switch; nothing changes without it, and it does not come back.
- **Pace alerts.** A run or cycle step can carry `pace_s_per_km: [fast, slow]`, e.g. `[290, 310]` for 4:50 to 5:10 per km; the Watch taps when the current pace leaves the range. The app shows it as "4:50–5:10 per km" (a ride as km/h). Walk, hike and the swims have no pace alerts on the Watch (checked with WorkoutKit's `supportsAlert`), so a plan for them is refused with a clear message. One alert per step: a zone or a pace.
- **Splits for runs, walks and hikes.** The workout file gets `splits`: one per km, or per mile when the athlete uses miles in Health, cut from the Watch's own distance samples, with moving time (pauses left out), pace and average heart rate per split. `get_workout` and `healthaccess show` print them as lines for a session without a plan. Runs of the last three days written by an older app get their splits on the next sync.
- **Elevation.** `get_workout` and the summary line now report metres climbed and descended (`elevation_gain_m`, `elevation_loss_m`). The app always wrote it; the server never read it. Older files carry it only in the raw metadata ("722 cm"), which is read too.
- **Run and ride steps read in pace per km.** `parts_text`, `healthaccess show` and a new `pace_s_per_km` on each step, instead of a pace per 100 m that only makes sense in the pool.
- **Last night's sleep arrives on its own.** The app now also wakes when the Watch hands the night over to the phone, so the day file has it before anyone opens the app. For a set moment there is a Shortcuts action, **Sync Health data**, e.g. in an automation "When Sleep Focus turns off". The sync log shows the last wake by sleep and the last run from Shortcuts.
- `push_plan` says when a plan needs app 1.0.5 (strength, an open step or a pacer; an older app lists it under Could not read) and when it has pace alerts (an older app puts it on the Watch without them).

### Fixed
- **A workout exported before the Watch had passed on its samples kept no heart-rate curve.** When the Watch dies or is out of range at the end of a workout, the phone can get the workout's summary first and the samples later. For three days the app now reads such a workout again on every sync and, once Health has the samples, adds the heart-rate series, the per-sample series and recovery heart rate to the file.
- **A night of sleep was split over two days.** The Watch saves a night as dozens of short stage samples, and each counted for the day it ended, so the part before midnight landed on the previous day. A night now counts as a whole for the morning it ends on (a gap of more than an hour starts a new session, so a nap is its own). The first launch of 1.0.5 checks the day files of the last year once and rewrites the ones whose sleep changes. `vitals/` gets the same rule.
- **`in_bed_s` was always null for Watch sleepers.** The Watch records sleep stages, not time in bed; the iPhone does (Health → Sleep → Track Time in Bed with iPhone). The app took every figure from the source with the most sleep, which dropped the iPhone's time in bed. It now takes time in bed from whichever source recorded it, and leaves it null when nobody did.
- **Weather humidity was 100 times too high** (6200 instead of 62). The Watch stores 62 % as 62 in Health's percent unit.
- **The distance series of a workout did not add up.** It mixed the iPhone's samples with the Watch's for the same minutes, and thinning it to one sample per 4 s dropped metres. It now holds only the workout's own samples, summed.
- The sync log said "Last refresh by iOS: none yet" and promised a refresh every few hours. iOS decides when that runs, and for a new app it can take days; the log now says so, next to the wakes that do happen.
- An unlabelled work step of a non-swim plan was called "Swim" in the app's plan view; it is "Work" now.

## 1.0.4, 2026-11-17: a plan started late keeps its name, and the server starts before the first sync

### Fixed
- **A workout run from one of your plans came back without the plan's name and step labels** when the Watch reported another id than the one the app had scheduled. That happens when the plan is started from the Watch's own list, for example days after its slot: the Watch gives the workout it keeps there a new id. The server (and the app, from its next build) now recognises the plan by its steps: every recorded step is a step of the plan, the workout got past the warm-up, and at least seven in ten steps hit their goal. A workout with an unknown id and other steps still gets no plan, so the wrong-label case fixed in 1.0.2 stays fixed.
- **Plans were only joined onto swims and rows.** The server now joins them for all eleven sports a plan can have.
- **The server refused to start when it found no Health Access folder**, so an AI client registered before the first sync showed a failed server and a directory that inspects servers saw none. It now connects, lists its tools and answers every call with what is missing and what to do, and it looks for the folder again on every call: after the first sync nothing has to be restarted. `--check` still ends with an error when there is no folder.
- **Swim paces read 10 to 20 s per 100 m slow.** The Watch starts a step the moment the rest before it ends, and the athlete pushes off when ready; the step's duration counts that wait. For pool swims the server now adds `swim_s` and `swim_pace_s_per_100m` to a step whose lengths account for its distance (push-off of the first length to the touch of the last). The one-line `parts_text`, the summary line and the cardiac cost use the swim pace; `pace_s_per_100m` in the file is unchanged. Cardiac cost figures of swims with lengths come out lower than before, for old sessions too.
- `healthaccess list` shows a plan name the app's index does not carry yet.

### Security and upkeep
- `rmcp` 3.7.0 → 3.10.0 (RUSTSEC-2026-0462, unbounded buffering in the Streamable HTTP client; the server does not build that client in, the pin is what scanners flag) and `rustix` 1.1.5 → 1.1.6 (RUSTSEC-2026-0486).
- A local run of the server against `examples/` leaves a presence file with the computer's name there; `.gitignore` now keeps it out of the repository.
- `Dockerfile` for directories that build and inspect a server in a container; the repository is its own Claude plugin marketplace (`.claude-plugin/marketplace.json`).

### App
- The same plan matching by steps in the exporter. Not on the App Store until the next app build; until then the server does the join when your AI reads a workout.

## 1.0.3 (app build 27), 2026-11-13: one message for any AI

### New
- **One message, and the AI picks what it can do.** Export → Your AI → Copy now gives one message for every AI. An AI that can run a program on the computer (Claude Desktop, Claude Code, Cursor) registers the server from it and reads the folder from then on. One that cannot (ChatGPT, any AI app on a phone, a chat in a browser) is told not to explain the setup and to work from the summary the message carries: the last four weeks, recent workouts, vitals and the next planned workout. Nobody has to know which kind of AI they have. For ChatGPT it is a snapshot; copy a new one after new workouts.
- The message therefore contains health data once there is some, and the confirmation says so. Before the first sync it carries none and tells the AI to ask for a fresh copy.

### Fixed
- **The onboarding no longer sends ChatGPT users into a dead end.** It named ChatGPT next to Claude and Cursor for a message that only asked for a local server; ChatGPT answered, rightly, that it cannot launch one.

### Server
- Unchanged; 1.0.3 only keeps the one version number.

## 1.0.2 (app build 25), 2026-11-11: a workout that synced says so

### New
- **"Pool swim synced" on the Export tab.** After a sync wrote a fresh workout, the status tile shows it for a day in place of "Up to date": what it was, when and by what it was recorded, when it was written to the folder and what started that sync (automatically, when you opened the app, or when you synced), with a button to the workout. The line under it says the one thing left: the folder has to reach your computer.

### Fixed
- **A workout started from another workout on the Watch no longer gets a plan's name and step labels.** The app and the server attached the plan scheduled closest to the start (same sport, within two hours). Health says which WorkoutKit plan a workout ran; when that id belongs to none of the folder's plans, no plan is attached. The time rule is left for workouts that carry no such id. The server also reads `workout_plan_id` and joins a plan on it when the file has no `plan_ref`.

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
