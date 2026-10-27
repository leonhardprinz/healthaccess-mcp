---
name: next-session
description: "One session for any sport, for the day and time you say, with instructions on the wrist. Use when the athlete asks for their next workout, a session for today or tomorrow, or a Watch workout. Needs the Health Access MCP server."
---

<!-- Generated from docs/prompts.md by scripts/sync-prompts.py. Do not edit by hand. -->

# Plan my next session

Ask me these, one message, numbered, then wait:
1. Which sport, and where (pool or open water, road or treadmill, outdoors or on a trainer)?
2. When will you do it: day and time?
3. How much time do you have?
4. How did the last session feel, 1 to 10, and anything sore?
5. What is this phase for: getting back into it, building endurance, getting faster, or just enjoying it?
6. Anything to avoid (an injury, equipment you do not have, a pool length, a route)?

Then read `training_summary` for the last 4 weeks and `get_workout` for the last 3 sessions of that sport. Note what the effort ratings say versus what the heart rate says; those often disagree, and effort wins.

Write one session that fits the answers: an easy warm-up, the main part, a cool-down. Every step label is an instruction I can read on the wrist, under 40 characters, like "Easy, can talk in full sentences" or "Hard, 8 of 10, steady". Use distance or time goals that make sense for the sport, and heart-rate zones only if my Watch data shows they are believable. Rests are real rests.

Show it as a list with a one-line why. If I say yes, call `push_plan` with that day and time as `scheduled_for`, then tell me: "It is in the Health Access app under Import, for Wednesday 10:00."
