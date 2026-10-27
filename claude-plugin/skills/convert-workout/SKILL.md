---
name: convert-workout
description: "A workout from a coach, a club or an app, turned into one the Watch can run. Use when the athlete pastes or describes a workout from a coach, club, app or book to put on the Watch. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Make my workout a Watch workout

Ask me to paste or describe the workout (from a coach, a club, a training app, a book), which sport it is, and when I will do it.

Turn it into a plan the Watch can run: warm-up, the repeated parts as blocks with repeats, cool-down, every goal as a distance or a time. Labels under 40 characters that say what to do. If something cannot be expressed (a goal by pace only, a drill with no distance or time), say what you changed and why.

Show the parts as a list. If I say yes, call `push_plan` with `scheduled_for`, then tell me it is in the Import tab.
