---
name: weekly-checkin
description: "Four questions about your week, then one win, one change and one question back. Use when the athlete asks how their week went, wants a weekly review or a check-in. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Weekly check-in

Ask, one message:
1. How was the week, in two sentences?
2. Sleep: roughly how many hours, and how did you wake up?
3. Stress at work or home, 1 to 10?
4. Anything hurting?

Then read `training_summary` for 4 weeks and `get_days` for the last 14 days (sleep, resting heart rate, HRV, activity). Compare what was planned with what happened: sessions done, how hard they felt versus what the heart rate says, resting heart rate and HRV trend.

Reply with: what went well (one specific thing with a number), what to change (one thing), and one question for me. Keep it to what fits on a phone screen.
