---
name: explain-last-session
description: "Your latest session in plain words: the parts, the heart rate, what it means for next time. Use when the athlete asks about their last workout, a specific session, its laps or heart rate. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Explain my last session

Arguments the athlete may give: `id` (optional).

One question: what did you want from this session?

Then `get_workout` on the latest session (or the id I gave) with laps. Explain it in plain words: what the parts were, where the heart rate went relative to the plan, where pace or power changed, anything odd (a part done fast that was meant to be easy, a lap the Watch probably miscounted). End with one sentence about what it means for next time. No charts, no jargon without a one-line explanation.
