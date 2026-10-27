# Health Access MCP — brand, design language, and the functionality that matters

Drafted 2026-10-24 as "Tidegate", revised 2026-10-25 to "Watchpipe", and the same day settled by Leo as **Health Access MCP**. The rename of the codebase (codename "Tide") happened on 2026-10-25; only the directory on disk, `~/Developer/tide`, still carries the codename until Leo moves it.

---

## 1. The name: **Health Access MCP** (final, 2026-10-25)

**Why this one.** The first job of the name is to say *Apple Health → AI* before anyone reads a tagline, and to be found by the people who type "Apple Health MCP" into a search box or an assistant. "Health Access" says what the product does in two plain words — it gives access to your health data — and reads as a permission the user grants, which is exactly the posture: you decide, the AI gets a folder, nothing else. The "MCP" suffix names the mechanism and is the keyword that matters for AI recall and registries. Descriptive-first, distinctive-second.

**What came before, and why it was dropped**

| Name | Verdict |
|---|---|
| Tide (codename) | Detergent, ocean tides — zero findability for SEO or AI recall. Stays as the historical codename only. |
| Tidegate (v1, built on the codename) | Rejected by Leo: too metaphorical; nothing in it says Apple Health. |
| Watchpipe (v2) | Said "Watch" and "pipe", not "Health" or "MCP"; clever rather than clear. |
| HealthPipe / HealthRelay / HealthPort / HealthWire / HealthLoop / HealthDrop / HealthFlow | existing apps or a live competitor (healthpipe.app) with those names |
| HealthMCP (one word) | App Store "Health MCP: Private Sync" (Iddo Gino, Sep 2026, cloud/TEE) — too close as a bare name; "Health Access MCP" is a different mark with "Access" as the distinctive middle. |

**Competitive intel surfaced while checking:** the Apple-Health-to-AI space got three entrants in two months — Health MCP: Private Sync (encrypted cloud + TEE), Somvia (training load + MCP), HealthPipe (account-based sync). **All three are cloud/account products.** Health Access MCP's position: *no account, no cloud, a folder you own — and the only one that writes workouts back to the Watch.* Add a comparison page row for each.

**Trademark note:** "Health" and "MCP" are generic; the registrable element is the combination and the mark. Never use "Apple Health" in the product name itself, never Apple's device imagery or the Health app's icon language in the mark. Subtitle may say "for Apple Health".

**Names in use (2026-10-27):** domain `healthaccessmcp.com` (Cloudflare, owned by PTC d.o.o.; `healthaccess.dev` not bought); npm `healthaccess-mcp` plus five `healthaccess-mcp-<platform>` packages (user `pt-consultancy`); official MCP registry `com.healthaccessmcp/healthaccess-mcp`; GitHub `leonhardprinz/healthaccess-mcp` (private); bundle id `com.healthaccessmcp.app`; CLI `healthaccess`; MCP server id `healthaccess` (`claude mcp add --scope user healthaccess -- npx -y healthaccess-mcp`). Still to reserve when published: the crates `healthaccess-core`, `healthaccess-mcp`, `healthaccess-cli`.

**Wordmark:** **Health Access** in IBM Plex Sans Condensed, with **MCP** as a small suffix: smaller size, same baseline, letter-spaced, in the access blue, so the human name reads first and the mechanism second. Never "HealthAccess" as one word in prose (the single word is reserved for identifiers: target, module, binaries, keys).

### The mark (final, 2026-10-25)

A heartbeat that leaves as an arrow: health, going out. One stroke, readable at 16 px and at 1024 px. Not Apple's heart, not a bracket.

- Grid 64 × 64. Stroke path `M6 34 H20 L26 20 L34 48 L40 34 H52` (the heartbeat) plus the arrowhead `M46 26 L56 34 L46 42`.
- Stroke white `#FFFFFF`, round caps and joins, width ≈ 4.2 on 64 (5 at 60 px, 6 at 29 px when the mark is tiny).
- Ground `#0D366B`, flat, no gloss, no text. Icon corner radius is iOS's own.
- Sources of truth: `app/scripts/make_icon.py` draws `AppIcon.png` (1024) and the launch marks from exactly these points; `app/HealthAccess/Views/Mark.swift` (`MarkShape`) draws the same path in SwiftUI for onboarding and the status card, where the arrow draws itself while a sync runs (1.2 s per pass, still with Reduce Motion).
- Nothing resembling Apple's Health icon, the Health permission sheet or the Fitness rings.

**Headline:** "Apple won't let your AI read your Watch. This does." (site and README). Social preview: "Your Apple Health data, for your AI." (`scripts/make-og.py`).
- App Store name: `Health Access MCP` · subtitle: `Apple Health for your AI` (see `docs/positioning.md`, the canonical copy).

## 2. Positioning

One paragraph, reused verbatim on the site, App Store, README, registries (consistency is what makes AI recall reliable):

> Health Access MCP exports your Apple Health workouts and vitals — heart rate, zones, per-interval splits, sleep, weight — as clean JSON into a folder you choose, automatically after every workout. A local MCP server lets Claude, Cursor, ChatGPT or any agent read it, and an AI-written training plan can be pushed back onto your Apple Watch. No account, no server: your data never leaves your devices.

Audiences, in order: (1) people already using Claude/Cursor/ChatGPT who want their Watch data in the conversation; (2) self-coached endurance athletes (swim, row, run) who want a coach with memory; (3) privacy-first quantified-self users who refuse cloud exporters.

## 3. SEO + AIO plan

- **Answer-shaped pages**, one per question people actually type: "How do I get Apple Health data into Claude?", "Apple Health MCP server", "Export Apple Watch workouts as JSON automatically", "Health Auto Export alternative", "Put a custom workout on Apple Watch from ChatGPT". Each page: the answer in the first 60 words, the three commands, a real JSON sample.
- **Integration docs** for Claude Desktop, Claude Code, Cursor, ChatGPT (MCP), Ollama/local — each its own URL (AI assistants cite specific URLs).
- `llms.txt` and `llms-full.txt` at the root; JSON-LD `SoftwareApplication` + `FAQPage`; OpenGraph.
- **Registries:** official MCP registry, Smithery, Glama, PulseMCP, mcp.so; crates.io; Homebrew tap `healthaccess-mcp/tap`; GitHub topics `apple-health`, `healthkit`, `mcp`, `mcp-server`.
- **Honest comparison page** vs Health Auto Export, Health Export AI, Health MCP: Private Sync, HealthPipe, Somvia and Apple's own export — table, no spin. These pages rank and get cited.
- The repo README *is* the landing page's twin; same positioning paragraph, same screenshots.

## 4. Functionality that matters (beyond "sync for the robots")

Ranked by how much it differentiates per unit of work. Status as of 2026-10-27.

1. **Write-back to the Watch. Built.** AI-written workout plans go into the Watch's Workout app as scheduled custom workouts, for eleven sports, at the plan's own time; one tap, or none with Automatic. Nobody else ships this. It is the reason to exist.
2. **Effort without the app asking. Built.** The Watch asks for the effort rating; Apple exports it (`WorkoutEffortScore`) and the app picks it up as `effort_source: apple`. The app never asks for a rating.
3. **Step names. Built.** HealthKit drops custom-step labels; Health Access joins them back from the plan. Every interval in the JSON says what it was.
4. **A briefing any AI can read. Built.** `briefing.md`, regenerated after each sync: the last four weeks on one page. Works without the MCP.
5. **Reliability as a feature. Built, without the widget.** Sync log (every wake, what it wrote), the status tile's states (up to date, syncing, waiting for unlock, failed), `healthaccess doctor`. The Home-screen widget is not built.
6. **One command for every AI. Built.** `npx -y healthaccess-mcp` finds the folder itself; listed in the official MCP registry; a Claude plugin is prepared.
7. **Privacy ledger. Built.** "What left this phone" in Settings, empty unless usage statistics are on.
8. **Not built, still ideas:** trend alerts computed locally (`get_alerts`), App Intents and Shortcuts ("Sync now", "Put plan on Watch"), the Home-screen widget.

Explicitly not doing: cloud sync, social, Garmin/Strava/Oura import, coaching content, subscriptions.

## 5. Design language — "instrument, not dashboard"

The app is a gauge you glance at, not a place you spend time. Every tab has one state that matters and at most one action. The main job happens while the app is closed. The acceptance rules are `docs/north-star.md`, items 14 to 18.

**Principles**
- **Zero-tap default path.** Export, index and briefing update in the background. Each tab shows a state, not a to-do list.
- **No charts.** The AI is the user of the data; the app shows states, folders and lists. No illustrations, no card-in-card.
- **One warm color, reserved.** Everything is ink and two blues. The status tile is the mark's blue `#0D366B` with a green check when everything is done; it turns the warm signal (`#E8632B`) *only* when the user is needed: a plan waiting, a folder or permission missing. When nothing is warm, nothing needs you.
- **Quiet motion.** One animation: the mark draws itself, heartbeat to arrow, while a sync runs (≈1.2 s per pass). Honors Reduce Motion.
- **States are facts.** "Up to date." "Waiting for unlock." "Sync failed." "On your Watch for Wed 17:30." Never "Oops", never "Success!".

**Tokens**
| | Light | Dark |
|---|---|---|
| Ground | `#F3F5F6` (cool off-white, not cream) | `#0B0F11` |
| Surface | `#FFFFFF` | `#161B1E` |
| Ink / ink-2 / ink-3 | `#0D1114` / `#4B545A` / `#7F8A91` | `#F1F4F6` / `#B2BBC1` / `#7D878D` |
| Accent (access blue) | `#1C5CAB` | `#6BA4EA` |
| Signal (needs you) | `#E8632B` | `#F08A5B` |
| Zone ramp Z1→Z5 | `#CDE2FB · #86B6EF · #3987E5 · #1C5CAB · #0D366B` (one hue, light→dark; never rainbow — Apple's zone colors are the thing to *not* look like) |
| Hairline | `#DDE3E6` | `#2A3135` |

- **Type (revised 2026-10-27, after Leo: "the title looks like a normal Arial font, no brand identity"):** one brand face across app and site, **IBM Plex Sans Condensed** (SemiBold 600, Bold 700), for the wordmark, navigation titles, onboarding headlines and the site's headings; IBM Plex Mono for commands and figures on the site; IBM Plex Serif for body text on the site. Inside the app everything you *read* (rows, explanations, buttons) stays system SF Pro for Dynamic Type and legibility; only the brand moments use Plex. The two app weights are bundled (`app/HealthAccess/Resources/Fonts/`, SIL Open Font License in `OFL.txt` next to them, registered with `UIAppFonts`), so nothing loads at runtime. All figures `.monospacedDigit()`; never SF Rounded (Apple Fitness's voice).
- **Brand bar in the app (revised 2026-10-27, "less busy"):** every tab starts with a small brand bar, the mark on a 24 pt tile and "Health Access MCP" at body size (`BrandBar` in `Views/Layout.swift`), then the tab title in Plex Sans Condensed Bold 32 pt (27 pt on narrow phones) as the only big element, then one line in the system font. The large `Wordmark` stays for onboarding. Section titles are Plex Sans Condensed 18 pt; navigation titles get Plex through `Brand.applyAppearance()`. Lists sit on the brand ground `#F3F5F6` / `#0B0F11` instead of the system grey.
- **Grid:** 8 pt; list-first layouts with hairline separators; section titles as small caps labels; 16 pt gutters; nothing floats.
- **Icon:** the mark (heartbeat to arrow, see "The mark" above), white on `#0D366B`, no gloss, no text.

**Screens (what it shows / the one action), app 0.6.1**
- **Export, "Export your Apple Health data":** status tile (Up to date with a green check, or the one fix), Folder, Your AI (connected client, or Copy the setup message), Sync from Health (automatic after every workout), Your files (Workouts, Days), Ideas for your AI (six Export prompts), the support card. Action: none when done; pull to sync.
- **Import, "Import workout plans":** status tile (Up to date, or "N plans waiting"), Folder (the plans folder), Your AI, Sync to Watch (the Automatic switch), Waiting for you (Put on Watch, See parts), On your Watch (Remove from Watch), Earlier, Ideas for your AI (five Import prompts).
- **Settings:** the Health data folder and the Workout plans folder, Health access, notifications, what gets exported, privacy (What left this phone, usage statistics, sync log), about (version, docs, support, privacy policy, Restore purchases).
- **Onboarding (4 screens, one button each):** what it is, pick a folder, allow Health and notifications, connect your AI.

**CLI / MCP output:** same vocabulary as the app; tables by default, `--json` everywhere; zone bands rendered as block characters in the ramp; the only color is the signal color for stale/warn. MCP tool results are compact and summary-first (one line per workout) so an LLM pays few tokens for a listing and only opens a file when it needs the series.

## 6. Voice
Plain, dry, confident. Short sentences. Verbs on buttons. Say what Apple does and doesn't do without sneering. One joke allowed per surface, maximum. Never "powered by AI".

## 7. What changed in the code (rename done 2026-10-25)

| Surface | Now | Before (codename era) |
|---|---|---|
| Product / App Store | Health Access MCP | Tide (the codename) |
| Home-screen name, Xcode target & scheme, Swift module | Health Access / `HealthAccess` | Tide (codename) |
| Bundle id, BGTask id | `com.healthaccessmcp.app`, `com.healthaccessmcp.app.export` | `com.leonhardprinz.Tide`, `com.leonhardprinz.tide.export` (codename era) |
| App log, UserDefaults keys | `Application Support/HealthAccess/healthaccess-log.txt`, `healthaccess.*` (old values migrated once) | `Tide/tide-log.txt`, `tide.*` (codename era; migrated) |
| Rust crates / binaries | `healthaccess-core` (lib `healthaccess_core`), `healthaccess-mcp`, `healthaccess-cli` (bin `healthaccess`) | `tide_core`, `tide-mcp`, `tide-cli` (bin `tide`) (codename era) |
| MCP server name / title / resources | `healthaccess-mcp`, "Health Access MCP — Apple Health for AI", `healthaccess://…` | `tide-mcp`, `tide://…` (still readable) |
| Env / config | `HEALTHACCESS_DIR`, `~/.config/healthaccess/config.toml` | `TIDE_DIR`, `~/.config/tide/config.toml` (still read as fallbacks) |
| Schema ids | `healthaccess.workout.v1`, `.vitals.v1`, `.index.v1`, `.plan.v1`; key `healthaccess_version` | `tide.*`, `tide_version` — accepted forever as aliases by the app and the Rust parsers |
| `created_by` defaults | `healthaccess-mcp`, `healthaccess-cli` | `tide-mcp`, `tide-cli` (codename era) |
| Telemetry | event names unchanged; `$lib` = `healthaccess-mcp` | — |

Decision taken at rename time: schema ids were bumped now, while there is one user, instead of waiting for a v2 — old files are never rewritten, the parsers accept both.
