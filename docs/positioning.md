# Positioning, canonical copy

Reuse these verbatim: site, App Store, README, registries (official MCP registry, live since 2026-10-27; Smithery, Glama, PulseMCP, mcp.so), the npm package, the Claude plugin, crates.io and Homebrew when they ship. The same words everywhere is what makes AI recall reliable. Voice: plain, short, no em dashes, no exclamation marks, no consultant words. Say what Apple does and does not do without sneering.

## Headline

Apple won't let your AI read your Watch. This does.

## The paragraph

Health Access is middleware. It does the one thing Apple requires a phone app for, writing your workouts and daily health data as JSON into a folder you pick, and then it gets out of the way. Your AI reads that folder, through the MCP or just as files. If it writes you a workout plan, one tap puts it on your Watch, or none with Automatic on.

## One sentence (registry descriptions, App Store promotional text, repository description)

Apple Health workouts and vitals as JSON in a folder you own, a local MCP server for any AI, and training plans back to your Apple Watch. No account, no server.

## Who this is for, five bullets

1. **You have an Apple Watch and an AI coach.** Claude, ChatGPT, Cursor, a local model, whatever. You want it to see your actual sessions, heart rate, sleep and weight instead of what you remember to type. That is the main job.
2. **You coach yourself** in the pool, on the rower, on the road, and want a coach with memory: one that has read every session, not the last screenshot.
3. **You will not put your health data on someone else's server.** No account, no cloud, a folder you own, on the storage you already use. Usage statistics off by default and never a health value.
4. **Or a human coach.** Same folder, shared with a person. They get the real splits instead of a screenshot.
5. **Second job: plans back to the Watch.** Your AI writes the session as a small JSON file. The app turns it into a custom workout with the step names on your wrist. No file import, no Watch app to configure. None of the other Apple-Health-to-AI products does this.

Not for: looking at charts in the app. There are none. The AI is the user of this data, so the effort goes into the files, the MCP and the docs, not into screens.

## App Store

- Name: `Health Access MCP`
- Subtitle (30 characters max): `Apple Health for your AI`
- Promotional text: the one sentence above.
- Description: the paragraph, then the five bullets, then the two limits in "Honest limits" below.

## Honest limits, two sentences, always together

Health data can only be read while the phone is unlocked, so a workout finished with the phone in the bag exports the next time the phone is unlocked, not before. And the Watch keeps its own pool length setting, the plan can't set it.

## Words

Use: "Export your Apple Health data" and "Import workout plans" (the two tabs), workouts (finished sessions), workout plans (what the AI writes), "Put on Watch", Automatic, "writes files into your folder", usage statistics, sync log, "What left this phone", "Ideas for your AI" (the prompts: suggestions, never a setup step).
Avoid: iCloud as a product word (any Files provider works; iCloud is one of them), telemetry, "powered by AI", "sessions" for finished workouts, and any claim about what the data proves. States are facts: "Up to date", "Waiting for unlock", "Sync failed", "On your Watch for Wed 17:30".

## The AI sentence, once per surface

What you share with an AI, and what it tells you, is between you and that AI.

## Rating

The app never asks for a rating. The Watch asks after a workout and Apple exports the number; the app picks it up. Notifications are only about plans: "Your AI wrote S27", and with Automatic on, "S27 is on your Watch".

## Where the copy lives

- Site: `site/index.html` (header, "Who this is for", "The order of things"), `site/llms.txt` (blockquote).
- README: `README.md`, first section.
- App: the tab titles and subtitles in `app/HealthAccess/Views/HomeView.swift`, `PlansView.swift`, `SettingsView.swift`.
- npm and registry: `npm/healthaccess-mcp/README.md`, `npm/server.json`; Claude plugin: `claude-plugin/README.md`.
- Brand notes: `docs/brand.md`.
