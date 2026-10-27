# Health Access MCP

**Apple won't let your AI read your Watch. This does.**

Health Access is middleware. It does the one thing Apple requires a phone app for, writing your workouts and daily health data as JSON into a folder you pick, and then it gets out of the way. Your AI reads that folder, through the MCP or just as files. If it writes you a workout plan, one tap puts it on your Watch, or none with Automatic on.

Site: [healthaccessmcp.com](https://healthaccessmcp.com) (built from `site/`). For an AI: [llms.txt](https://healthaccessmcp.com/llms.txt), [llms-full.txt](https://healthaccessmcp.com/llms-full.txt). Server: [`healthaccess-mcp` on npm](https://www.npmjs.com/package/healthaccess-mcp), listed in the official MCP registry as `com.healthaccessmcp/healthaccess-mcp`. What changed when: [`CHANGELOG.md`](CHANGELOG.md).

> **Name.** The project ran under the codename "Tide" until 2026-10-25 and is now **Health Access MCP**. The repository directory on disk is still `~/Developer/tide` for now; everything inside uses the new names. Files and settings written before the rename keep working: the `tide.*` schema ids, `TIDE_DIR`, `~/.config/tide/config.toml` and the `tide://` resource URIs are accepted as aliases forever. See [`docs/schema.md`](docs/schema.md) and [`docs/mcp.md`](docs/mcp.md).

## Who this is for

- **You have an Apple Watch and an AI coach.** Claude, ChatGPT, Cursor, a local model, whatever. You want it to see your actual sessions, heart rate, sleep and weight instead of what you remember to type. That is the main job.
- **Or a human coach.** Same folder, shared with a person. They get the real splits instead of a screenshot.
- **Second job: plans back to the Watch.** Your AI writes the session as a small JSON file. The app turns it into a custom workout with the step names on your wrist. No file import, no Watch app to configure.
- **Not for:** looking at charts in the app. There are none. The AI is the user of this data, so the effort goes into the files, the MCP and the docs, not into screens.

## The order of things

**Once, about five minutes, you**
1. Install the app (App Store submission is next; today it is built from this repository with Xcode).
2. Pick a folder. Anything the iOS Files app can see: iCloud Drive, Dropbox, Google Drive, OneDrive, Proton Drive, a NAS, local. The one rule: your AI has to be able to reach the same folder, so pick one that syncs to the computer where the AI runs.
3. Allow Health access (read only, you choose the types) and notifications (one kind only: "Your AI wrote S27", when a plan arrives).
4. Give the MCP to your AI. Paste the setup message the app copies; the AI registers `npx -y healthaccess-mcp`, which finds your folder on its own.

**Every workout, nobody**
1. You end a workout on the Watch.
2. Next time the phone is unlocked, the app writes `workouts/2026-05-14_0712_PoolSwim_7A1C3E90.json` into the folder: distance, time, heart rate every few seconds, every interval with its name, every length with stroke and SWOLF. Vitals land once a day.
3. The folder syncs to your computer.
4. Your AI reads it. No app on that side.

**Sometimes, one tap, you**
1. Rate the session on your Watch when it asks. Effort is the one number nobody else can measure, and it turned out to matter more than heart rate. Apple exports your Effort score and the app picks it up; the app itself never asks.
2. When your AI has written a plan: tap "Put on Watch" in the Import tab, or switch on "Put new plans on my Watch automatically" once and skip even that.

**Whenever you ask, your AI**
1. Reads sessions, vitals and trends through the MCP, or reads the JSON directly. The folder is the API.
2. Writes a workout plan into `plans/` with the day and time you said. It shows up in the app's Import tab.
3. Works without the MCP too: the folder also holds `briefing.md`, a one-page summary any AI can read.

Two honest limits, both Apple's. Health data can only be read while the phone is unlocked, so a workout finished with the phone in the bag exports the next time the phone is unlocked, not before. And the Watch keeps its own pool length setting, the plan can't set it.

## Connect your AI, first thing

```sh
claude mcp add --scope user healthaccess -- npx -y healthaccess-mcp
```

That is Claude Code. For Claude Desktop, Cursor, LM Studio and most other hosts the config entry is `{"command": "npx", "args": ["-y", "healthaccess-mcp"]}`. The server finds the Health Access folder on its own (iCloud Drive, then Dropbox, Google Drive, OneDrive, Box, then `~/Documents`); `--dir "<folder>"` names it yourself. Node.js 18 or newer is the only requirement. Or paste this to your AI and let it do the setup (the app puts it on your clipboard):

```
Set up the Health Access MCP for me.
Docs for you: https://healthaccessmcp.com/llms.txt
The server runs with: npx -y healthaccess-mcp
It finds my Health Access folder on its own.
Register it in this app, then list my last 5 workouts.
```

One page per client: [Claude Code](site/docs/claude-code.html), [Claude Desktop](site/docs/claude-desktop.html), [Cursor](site/docs/cursor.html), [ChatGPT](site/docs/chatgpt.html) (files only today; ChatGPT does not launch local MCP servers), [local models](site/docs/local-models.html). The full install and setup reference is [`docs/mcp.md`](docs/mcp.md).

## What the AI gets

| Tool | Does |
|---|---|
| `list_workouts` | Compact rows, newest first. One line per session, written for an LLM. |
| `get_workout` | One session in full: every interval with its name, pace and heart rate, zone seconds, lengths, recovery heart rate, your effort rating. Heart-rate series only if asked. |
| `get_vitals` | Resting heart rate, HRV, sleep, weight, steps, VO2max by day. |
| `training_summary` | Per week: volume, sessions, easy-zone share, mean effort, and the cardiac cost trend (beats per 100 m). |
| `rate_workout` | Stores the effort you told the AI. The AI must ask you, never guess. |
| `push_plan` | Validates a session (labels under 40 characters, zones 1 to 5) and writes it to `plans/`. Then the app, then your Watch. |
| `get_plan_status` | Whether the app has put a plan on the Watch yet: pending, scheduled, failed or cancelled. |
| `list_plans` | Every plan in `plans/` with its state, newest first. |
| `get_day`, `get_days` | Everything Health holds for a day or a range, in groups: activity, heart, sleep, body, mind and more. |
| `get_catalog` | Every Health type, whether it has data and where it was exported. |
| `get_profile` | Age, sex, height and the other characteristics from `profile.json`. |
| `list_ecgs` | Every ECG summary, newest first. |

Thirteen tools. Arguments, return shapes and heuristics: [`docs/mcp.md`](docs/mcp.md). Resources: `healthaccess://index`, `healthaccess://workout/<id>`, `healthaccess://briefing`. The `healthaccess` CLI has the same views (`list`, `show`, `summary`, `rate`, `plan push|status|list`, `day`, `days`, `catalog`, `profile`, `ecgs`, `briefing`, `prompts`, `doctor`); from npm it runs as `npx -y -p healthaccess-mcp healthaccess <command>`.

## Ideas for your AI

Eleven prompts ship with the docs as suggestions, not as a step of the setup, in two groups and for any sport. Use them, change them or ignore them. Each asks first, reads second, writes last. Export: weekly check-in, explain my last session, am I overdoing it, sleep and recovery, long-term trends, a summary for a coach or doctor. Import: plan my next session, plan my week, change my plan, build up to a goal, make my workout a Watch workout. Source: [`docs/prompts.md`](docs/prompts.md); `scripts/sync-prompts.py` copies it into the app and the site.

## The folder

```
<folder>/
  index.json                 one row per workout, newest first (app)
  briefing.md                one page any AI can read (app)
  workouts/<date>_<time>_<Activity>_<uuid8>.json   one per workout (app)
  days/<date>.json           one per day, every Health group with data (app; vitals/<date>.json kept for older readers)
  catalog.json, profile.json what Health holds and the athlete's characteristics (app, v0.4)
  plans/<id>.json            written by the MCP or CLI (push_plan)
  plans/<id>.status.json     written by the app: scheduled (with the time), failed, or cancelled after "Remove from Watch"
  mcp/clients/<id>.json      presence file written by the MCP: client, machine, counts; never arguments or results
```

Nothing else writes, nothing deletes. The complete contract with every field is [`docs/schema.md`](docs/schema.md); a readable version with a trimmed example is [site/docs/files.html](site/docs/files.html). A complete synthetic folder, generated and not a real person, is [`examples/`](examples/): point the CLI at it with `healthaccess --dir examples list`. The plan format and the "Put on Watch" flow: [site/docs/plans.html](site/docs/plans.html).

## Limits

- Health data is readable only while the phone is unlocked (Apple); exports wait until it is.
- The Watch keeps its own pool length; plans cannot set it (WorkoutKit has no parameter).
- Step names on the Watch need iOS 18; labels over 40 characters are cut.
- Plans: run, indoor run, walk, hike, cycle, indoor cycle, pool and open-water swim, indoor row, HIIT and elliptical (the last two take time goals only). Plans land in the Watch's Workout app, not in Apple Fitness+.
- Automatic Put on Watch runs when the app opens or iOS wakes it, within hours; iOS does not wake apps the second a file arrives.
- Apple's "Add to Watch" sheet does not report back; the app asks and records `method: preview`.
- The npm server contains no network code. The app's usage statistics are off by default and never carry a health value, a file name or a path. The exact event names: [site/docs/privacy.html](site/docs/privacy.html).

## Repository layout

- `app/` iOS app (SwiftUI, iOS 17+). Xcode target and scheme `HealthAccess`, product `Health Access`, bundle id `com.healthaccessmcp.app`. Project generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `app/project.yml` (never hand-edit the `.xcodeproj`). Details in [`app/README.md`](app/README.md).
- `core/` Rust crate `healthaccess-core` (lib `healthaccess_core`): data contract models, folder store, zone math, derived training views, the Apple `.workout` codec.
- `mcp/` Rust crate `healthaccess-mcp`: the MCP server over stdio (binary `healthaccess-mcp`).
- `cli/` Rust crate `healthaccess-cli`: the `healthaccess` command-line tool.
- `examples/` a synthetic Health Access folder (`generate.py` rewrites it; tests, docs and the site quote it).
- `docs/` [`north-star.md`](docs/north-star.md) (the acceptance checklist every build is checked against), [`schema.md`](docs/schema.md) (the folder contract), [`mcp.md`](docs/mcp.md) (install, client setup, tools, CLI, distribution), [`prompts.md`](docs/prompts.md) (the eleven prompts, source of truth), [`positioning.md`](docs/positioning.md) (canonical copy), [`brand.md`](docs/brand.md) (name, design language), [`export-coverage.md`](docs/export-coverage.md), [`phase0-spike.md`](docs/phase0-spike.md) (findings).
- `npm/` the npm launcher package, `npm/server.json` (MCP registry entry), `npm/test/` (end-to-end test against a local registry).
- `claude-plugin/` the Claude plugin: the MCP server and the prompts as skills (validated, not yet submitted).
- `scripts/` `bump-version.sh`, `build-npm.sh`, `publish-npm.sh`, `publish-registry.sh`, `sync-prompts.py`, `build-site.sh`, `deploy-site.sh`, `make-og.py`.
- `site/` the static docs site: plain HTML, one CSS file, self-hosted fonts. `scripts/build-site.sh` stages it with `/ref/` and `/examples/` into `dist/site`, `scripts/deploy-site.sh` deploys it to Cloudflare Workers (`wrangler.jsonc`, `site-worker/`). Preview: `scripts/build-site.sh && python3 -m http.server -d dist/site 8000`.

The master plan is kept outside the repository.

## Build the app (free personal team)

1. Xcode installed, signed in with your Apple ID (Xcode, Settings, Accounts). A "Personal Team" appears.
2. iPhone: Settings, Privacy & Security, Developer Mode on (reboot).
3. `cd app && xcodegen generate && open HealthAccess.xcodeproj`
4. In Xcode: Signing & Capabilities, Team = your Personal Team. Change the bundle id if it collides.
5. Plug in the phone, select it, run. First run: trust the developer certificate on the phone (Settings, General, VPN & Device Management).
6. Free team: the build expires after 7 days; run again.

Headless build and install commands are in [`app/README.md`](app/README.md).

## Build the Rust half

```sh
cargo install --path mcp --locked     # -> ~/.cargo/bin/healthaccess-mcp
cargo install --path cli --locked     # -> ~/.cargo/bin/healthaccess
healthaccess --dir "<your folder>" doctor
```

Then register your build instead of the npm one: `claude mcp add --scope user healthaccess -- /Users/<you>/.cargo/bin/healthaccess-mcp`. Website: `scripts/deploy-site.sh` builds `dist/site` (site, `/ref/` docs, `/examples/`) and deploys it to healthaccessmcp.com on Cloudflare Workers. npm: see "Install" in [`docs/mcp.md`](docs/mcp.md). The CI gate (`cargo test`, `clippy`, `fmt`, release build) is listed in [`docs/mcp.md`](docs/mcp.md).

## License

MIT for the MCP server, the core crate and the CLI (`Cargo.toml`). Apple, Apple Watch, Apple Health and HealthKit are trademarks of Apple Inc.; this project is not affiliated with Apple.
