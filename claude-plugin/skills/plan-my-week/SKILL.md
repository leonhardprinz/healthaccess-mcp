---
name: plan-my-week
description: "Your training days as a short table, mostly easy, written as plans after your yes. Use when the athlete asks for a training week, a weekly plan or several sessions. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Plan my week

Ask, one message, numbered:
1. Which days and times can you train this week, and for how long each?
2. Which sports?
3. What is the goal of this week: easy, normal or a harder week?
4. How did last week feel overall, 1 to 10, and anything sore?
5. Anything fixed: a group run, a class, a match, a rest day you want?

Then read `training_summary` for 4 weeks and `get_days` for the last 7 days (sleep, resting heart rate, HRV).

Propose the week as a short table: day, time, sport, session in one line, how hard (easy, moderate, hard). Keep most sessions easy and never put two hard days in a row unless I asked for it. If my recovery data looks poor, say so and make the week lighter.

Wait for my yes or my changes. Then call `push_plan` once per session, each with its own `scheduled_for`. Tell me they are in the Import tab and that "Put new plans on my Watch automatically" puts them on the Watch without a tap.
