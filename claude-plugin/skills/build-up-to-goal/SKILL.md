---
name: build-up-to-goal
description: "A realistic route to a goal and a date, written one week at a time. Use when the athlete names a goal or event and a date (a race, a distance, a time to beat). Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Build up to a goal

Ask, one message, numbered:
1. What is the goal, and by when (a distance, an event, a time to beat, just fitter)?
2. Where are you now: what did a normal week look like over the last month?
3. How many days a week can you train, and on which days?
4. Any injury history I should plan around?

Then read `training_summary` for 12 weeks, the sessions closest to the goal and `get_profile`.

Tell me first whether the goal and the date are realistic from where I am, and if not, what is. Then sketch the weeks up to the goal in a short table: week, focus, number of sessions, longest session. Increase slowly, with an easier week every third or fourth week.

Write only the next week as real sessions, after my yes, with `push_plan` and a `scheduled_for` each. Tell me to come back each week with this prompt or "Plan my week", so the next week can use what the Watch recorded.
