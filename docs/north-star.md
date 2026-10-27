# North Star (acceptance checklist)

Every build, page and tool is checked against this before Leo sees it. If an item fails, the build does not ship.

1. **Middleware.** The app writes files into a folder the user picks and gets out of the way. The AI is the user of the data. No charts, no analysis, no opinions in the app.
2. **The app does nothing the system already does.** The Watch asks for effort (Apple exports it); Fitness lists workouts; the folder provider syncs. After setup, the only human action in the app is "Put on Watch", and with "Put new plans on my Watch automatically" switched on, not even that.
3. **MCP first, one command for everyone.** Setup ends with connecting an AI, and the app can prove the connection (handshake files from the MCP). The server is `npx -y healthaccess-mcp` and finds the folder on its own, so the setup message carries no path. Docs are written so an AI installs itself from `llms.txt`.
4. **Explicit and confirmed.** Every action: one sentence stating the exact effect, Confirm, then the row shows the result and when, with Undo where possible. No silent writes.
5. **One native component system.** Standard inset grouped lists, system sections, system corners and spacing. The only coloured element is the status tile at the top of Export and Import, and it is a list row too. No other custom boxes.
6. **Any storage.** Anything the Files app can open. iCloud is named only when the folder is iCloud.
7. **Boring by design.** Each tab is a status, a folder, a connection and a list. Explanations live in onboarding and info screens, not on the tabs.
8. **Plain voice.** Short sentences, no em dashes, no exclamation marks, states are facts, buttons are verbs, correct grammar.
9. **Export everything, catalogued.** Every Health type with data is written; `catalog.json` proves it; `doctor` reports gaps.
10. **No real health data in the repo.** Synthetic `examples/` only.
11. **Privacy by construction.** No server, no account. The MCP binaries we publish contain no network code. The app's usage statistics are off by default, allowlisted events only (the full list is on the privacy pages), and "What left this phone" shows the truth.
12. **Suggestions are suggestions.** Prompts are ideas for the user's AI, in two groups (Export: understand the data; Import: write workout plans), for any sport. Every prompt asks before it reads and reads before it writes. What you share with an AI is between you and that AI, said once.
13. **Free, open source, one tip jar.** Nothing is gated: read path, write path, MCP. The last card on the Export tab says what the project is and asks once, through the App Store: a one-off removes the card for good, a coffee leaves it. Apple's payment sheet is the confirmation; the card shows the result like any row; Restore lives in Settings. No other upsell anywhere.
14. **Three tabs, three jobs.** Export ("Export your Apple Health data": workouts and daily data as files for your AI), Import ("Import workout plans": AI-written plans, scheduled on your Watch), Settings (the two folders, permissions, privacy). Finished sessions are "workouts"; what the AI writes are "workout plans".
15. **One layout, one headline.** Every tab opens the same way: a small brand bar (mark and "Health Access MCP" at body size), the tab title as the only big element, one line on what the tab does. Export and Import then follow the same order: status tile, Folder, Your AI, Sync, the content, Ideas for your AI. The title fits one line on every iPhone (it steps down a size on narrow ones) and wraps only with very large text; nothing is ever cut off.
16. **The status tile shows a state, not a chore.** Green check and no button when everything is done; the mark draws itself while syncing; a lock while Health waits for unlock; "Sync failed" with Try again; orange with its one fix only when you are needed. Doing it again by hand is pull to refresh.
17. **Two typefaces, one rule.** IBM Plex Sans Condensed for every heading and the wordmark, the system font for everything you read. Prompts sit behind one row per tab: a list, one prompt per page.
18. **The plan decides when.** A plan goes onto the Watch at its own `scheduled_for`, which every Import prompt makes the AI ask for; without one, the next morning. There is no time setting. Automatic is opt-in and confirmed once.

Review method: build for the iOS Simulator and for the device; screenshot every screen in the simulator in light and dark, at the default text size and at a large accessibility size; walk the checklist; only then install on the phone. Screenshots for the site use the synthetic `examples/` data and an English region.

Last reviewed 2026-10-27 against app 0.6.2 (build 21).
