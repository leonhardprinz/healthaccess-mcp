# Health Access MCP

Apple Health and Apple Watch workouts for Claude, from files on your own computer. The Health Access iPhone app writes your workouts, daily health data and a one-page briefing as plain files into a folder you pick (iCloud Drive, Dropbox, any Files provider). This plugin lets Claude read that folder and write workout plans back, which the app puts on your Apple Watch. No cloud, no account.

## What you need

- The Health Access app on your iPhone, with a folder that syncs to this computer.
- Node.js 18 or newer, so `npx` exists. Check with `npx --version`.
- Claude Code, or Cowork running on your computer. Chat on claude.ai does not start local servers, so there the prompts load but cannot read your data.

## What it adds

- The `healthaccess` MCP server, started on your computer with `npx -y healthaccess-mcp@0.6.2`. It finds the Health Access folder on its own: iCloud Drive first, then Dropbox, Google Drive, OneDrive and Box, then `~/Documents`. Thirteen tools read workouts, days, vitals and trends, and write plans and effort ratings.
- Eleven skills, the same prompts the app and the site show. Each one asks you first, reads your data second and writes only after your yes.

Read and explain: `weekly-checkin`, `explain-last-session`, `overdoing-it`, `sleep-and-recovery`, `long-term-trends`, `coach-summary`.

Write plans for the Watch: `next-session`, `plan-my-week`, `adjust-plans`, `build-up-to-goal`, `convert-workout`.

## Use it

Ask in your own words, for example "how was my week?" or "plan my next swim", and Claude picks the matching skill. To pick one yourself in Claude Code, type `/healthaccess-mcp:plan-my-week`. A plan Claude writes shows up in the app's Import tab; tap Put on Watch, or switch on "Put new plans on my Watch automatically".

## What it runs and where data goes

- The first start downloads the server from npm: the `healthaccess-mcp` package and the one binary for your computer, a few MB. Later starts use the copy npm keeps.
- The server contains no network code. It talks to Claude over standard input and output and opens no port.
- It reads files in your Health Access folder. It writes there only workout plans (`plans/<id>.json`), an effort rating and note when you give one, and one small file per computer and AI client (`mcp/clients/<id>.json`: client name and version, computer name, server version, first and last use, last tool name, call count; never tool arguments or results) so the app can show that an AI is connected.
- What Claude reads from the folder becomes part of your conversation and goes to Anthropic under your Claude plan's terms. Nothing goes to us.

Privacy policy: https://healthaccessmcp.com/privacy-policy. Docs: https://healthaccessmcp.com/docs/claude-code.

Made by Prinz Tech Consulting d.o.o., Ljubljana. MIT licence. Support: support@healthaccessmcp.com
