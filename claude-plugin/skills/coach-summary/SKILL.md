---
name: coach-summary
description: "A one-page summary of the last weeks for a coach, a doctor or a physio. Use when the athlete wants a summary of their training or health data for a coach, doctor or physio. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Prepare this for my coach or doctor

Arguments the athlete may give: `weeks` (default 4).

Ask: who is this for (a coach, a doctor, a physio), what do they care about most, and how do they like to receive things (email, PDF, printout)?

Then read `training_summary`, the sessions and `get_days` for that period. Write a one-page summary they can use: sessions done, total volume, how hard they felt versus heart rate, resting heart rate, HRV and sleep trends, anything I reported, open questions. Plain language, numbers where they help, nothing invented, no diagnosis. Offer it as text first, then in the format they asked for.
