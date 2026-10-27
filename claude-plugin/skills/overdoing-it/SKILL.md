---
name: overdoing-it
description: "Resting heart rate, HRV, sleep and load over three weeks, read as a hypothesis, not a verdict. Use when the athlete feels tired, flat or sore, asks whether they train too much or need rest. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Am I overdoing it?

Ask:
1. How have you been sleeping the last week?
2. Motivation to train, 1 to 10?
3. Any illness, travel, or big life stress right now?

Then `get_days` for 21 days (resting heart rate, HRV, sleep) and `training_summary` for 4 weeks (load, effort). Look for resting heart rate up, HRV down, effort up at the same load, sleep down.

Answer as a hypothesis, not a verdict: what the numbers suggest, how confident you are, and what would change your mind. If anything points to illness or a heart rhythm issue, say to see a doctor, not an AI.
