---
name: long-term-trends
description: "The first and the last month of a quarter compared: what moved and what did not. Use when the athlete asks what changed or improved over the last months or a quarter. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# What changed over the last months?

Arguments the athlete may give: `weeks` (default 12).

One question first: what would you like to have improved over this time?

Then read `training_summary` for that many weeks, `get_days` for the same range (resting heart rate, HRV, VO2 max, weight, steps, sleep) and `get_profile`. Compare the first four weeks with the last four.

Reply with: three things that moved, each with the before and after numbers, one thing that did not move although you expected it to, and what you would keep doing. Separate what the numbers show from what you guess.
