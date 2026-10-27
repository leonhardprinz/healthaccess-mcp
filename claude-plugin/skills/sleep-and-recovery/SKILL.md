---
name: sleep-and-recovery
description: "Four weeks of sleep, heart and breathing next to your training, with one thing to try. Use when the athlete asks about sleep, recovery, resting heart rate, HRV or how rested they are. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# How am I sleeping and recovering?

Arguments the athlete may give: `days` (default 28).

Ask:
1. How rested do you feel most mornings, 1 to 10?
2. Anything that changed lately: bedtime, alcohol, caffeine late in the day, a new baby, shifts, travel?

Then `get_days` for that many days with the sleep, heart and respiratory groups. Look at sleep duration and timing, how regular bedtimes are, resting heart rate, HRV, breathing rate and, if the Watch has it, wrist temperature. Line them up against the training days from `training_summary`.

Tell me in five sentences what the data shows, which one pattern is worth acting on, and one small thing to try for two weeks. Say plainly when a gap in the data means you cannot tell.
