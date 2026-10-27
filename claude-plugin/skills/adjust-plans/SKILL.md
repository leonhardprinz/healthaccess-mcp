---
name: adjust-plans
description: "Missed a day or feel tired: the smallest change to the sessions still ahead. Use when the athlete missed a session, is ill, tired or travelling, or wants to change planned workouts. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Change my plan

Ask: what happened (missed a session, feel tired or sore, ill, travelling, more time than expected), and what is still possible this week?

Then `list_plans` and `get_plan_status` for the ones still ahead, the last session from `list_workouts` and `get_days` for the last 3 days.

Suggest the smallest change that works: move, shorten, swap for something easier, or drop a session. Never try to catch up missed work by doubling up. Show the new version next to the old one. If I say yes, write the changed sessions with `push_plan`, each with its new `scheduled_for`, and tell me which old ones to take off the Watch with "Remove from Watch" in the Import tab, because the app does not delete plans on its own.
