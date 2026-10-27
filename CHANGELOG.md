# Changelog

Versions are one number for everything: the app's `MARKETING_VERSION`, the Rust crates and the npm packages (`scripts/bump-version.sh`). The app's build number counts up on its own. Dates are Europe/Ljubljana.

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
