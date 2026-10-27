# Prompts (source of truth)

Every prompt asks before it reads data, and reads data before it writes anything. A plan written without asking how you feel is a guess with formatting. These are exposed as MCP prompts by `healthaccess-mcp`, shown in the app (Export prompts in the Export tab, Plans prompts in the Import tab) and published on the site. `scripts/sync-prompts.py` copies this file into the app and the site; never edit those copies by hand.

Each prompt has an id line (id, group, arguments) and an about line, the one sentence the app and the MCP show next to its title. Two groups. **Export** prompts read what the Watch recorded and explain it. **Plans** prompts write sessions that go onto the Watch. None of them assume a sport: the AI asks which one.

Voice: plain, short, no em dashes, no consultant words. The AI talks to the athlete the way a good coach does.

---

## 1. Weekly check-in
**id:** `weekly_checkin` · **group:** export · **args:** none
**about:** Four questions about your week, then one win, one change and one question back.

Ask, one message:
1. How was the week, in two sentences?
2. Sleep: roughly how many hours, and how did you wake up?
3. Stress at work or home, 1 to 10?
4. Anything hurting?

Then read `training_summary` for 4 weeks and `get_days` for the last 14 days (sleep, resting heart rate, HRV, activity). Compare what was planned with what happened: sessions done, how hard they felt versus what the heart rate says, resting heart rate and HRV trend.

Reply with: what went well (one specific thing with a number), what to change (one thing), and one question for me. Keep it to what fits on a phone screen.

## 2. Explain my last session
**id:** `explain_last_session` · **group:** export · **args:** `id` (optional)
**about:** Your latest session in plain words: the parts, the heart rate, what it means for next time.

One question: what did you want from this session?

Then `get_workout` on the latest session (or the id I gave) with laps. Explain it in plain words: what the parts were, where the heart rate went relative to the plan, where pace or power changed, anything odd (a part done fast that was meant to be easy, a lap the Watch probably miscounted). End with one sentence about what it means for next time. No charts, no jargon without a one-line explanation.

## 3. Am I overdoing it?
**id:** `overdoing_it` · **group:** export · **args:** none
**about:** Resting heart rate, HRV, sleep and load over three weeks, read as a hypothesis, not a verdict.

Ask:
1. How have you been sleeping the last week?
2. Motivation to train, 1 to 10?
3. Any illness, travel, or big life stress right now?

Then `get_days` for 21 days (resting heart rate, HRV, sleep) and `training_summary` for 4 weeks (load, effort). Look for resting heart rate up, HRV down, effort up at the same load, sleep down.

Answer as a hypothesis, not a verdict: what the numbers suggest, how confident you are, and what would change your mind. If anything points to illness or a heart rhythm issue, say to see a doctor, not an AI.

## 4. How am I sleeping and recovering?
**id:** `sleep_and_recovery` · **group:** export · **args:** `days` (default 28)
**about:** Four weeks of sleep, heart and breathing next to your training, with one thing to try.

Ask:
1. How rested do you feel most mornings, 1 to 10?
2. Anything that changed lately: bedtime, alcohol, caffeine late in the day, a new baby, shifts, travel?

Then `get_days` for that many days with the sleep, heart and respiratory groups. Look at sleep duration and timing, how regular bedtimes are, resting heart rate, HRV, breathing rate and, if the Watch has it, wrist temperature. Line them up against the training days from `training_summary`.

Tell me in five sentences what the data shows, which one pattern is worth acting on, and one small thing to try for two weeks. Say plainly when a gap in the data means you cannot tell.

## 5. What changed over the last months?
**id:** `long_term_trends` · **group:** export · **args:** `weeks` (default 12)
**about:** The first and the last month of a quarter compared: what moved and what did not.

One question first: what would you like to have improved over this time?

Then read `training_summary` for that many weeks, `get_days` for the same range (resting heart rate, HRV, VO2 max, weight, steps, sleep) and `get_profile`. Compare the first four weeks with the last four.

Reply with: three things that moved, each with the before and after numbers, one thing that did not move although you expected it to, and what you would keep doing. Separate what the numbers show from what you guess.

## 6. Prepare this for my coach or doctor
**id:** `coach_summary` · **group:** export · **args:** `weeks` (default 4)
**about:** A one-page summary of the last weeks for a coach, a doctor or a physio.

Ask: who is this for (a coach, a doctor, a physio), what do they care about most, and how do they like to receive things (email, PDF, printout)?

Then read `training_summary`, the sessions and `get_days` for that period. Write a one-page summary they can use: sessions done, total volume, how hard they felt versus heart rate, resting heart rate, HRV and sleep trends, anything I reported, open questions. Plain language, numbers where they help, nothing invented, no diagnosis. Offer it as text first, then in the format they asked for.

## 7. Plan my next session
**id:** `next_session` · **group:** plans · **args:** none
**about:** One session for any sport, for the day and time you say, with instructions on the wrist.

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

## 8. Plan my week
**id:** `plan_my_week` · **group:** plans · **args:** none
**about:** Your training days as a short table, mostly easy, written as plans after your yes.

Ask, one message, numbered:
1. Which days and times can you train this week, and for how long each?
2. Which sports?
3. What is the goal of this week: easy, normal or a harder week?
4. How did last week feel overall, 1 to 10, and anything sore?
5. Anything fixed: a group run, a class, a match, a rest day you want?

Then read `training_summary` for 4 weeks and `get_days` for the last 7 days (sleep, resting heart rate, HRV).

Propose the week as a short table: day, time, sport, session in one line, how hard (easy, moderate, hard). Keep most sessions easy and never put two hard days in a row unless I asked for it. If my recovery data looks poor, say so and make the week lighter.

Wait for my yes or my changes. Then call `push_plan` once per session, each with its own `scheduled_for`. Tell me they are in the Import tab and that "Put new plans on my Watch automatically" puts them on the Watch without a tap.

## 9. Change my plan
**id:** `adjust_plans` · **group:** plans · **args:** none
**about:** Missed a day or feel tired: the smallest change to the sessions still ahead.

Ask: what happened (missed a session, feel tired or sore, ill, travelling, more time than expected), and what is still possible this week?

Then `list_plans` and `get_plan_status` for the ones still ahead, the last session from `list_workouts` and `get_days` for the last 3 days.

Suggest the smallest change that works: move, shorten, swap for something easier, or drop a session. Never try to catch up missed work by doubling up. Show the new version next to the old one. If I say yes, write the changed sessions with `push_plan`, each with its new `scheduled_for`, and tell me which old ones to take off the Watch with "Remove from Watch" in the Import tab, because the app does not delete plans on its own.

## 10. Build up to a goal
**id:** `build_up_to_goal` · **group:** plans · **args:** none
**about:** A realistic route to a goal and a date, written one week at a time.

Ask, one message, numbered:
1. What is the goal, and by when (a distance, an event, a time to beat, just fitter)?
2. Where are you now: what did a normal week look like over the last month?
3. How many days a week can you train, and on which days?
4. Any injury history I should plan around?

Then read `training_summary` for 12 weeks, the sessions closest to the goal and `get_profile`.

Tell me first whether the goal and the date are realistic from where I am, and if not, what is. Then sketch the weeks up to the goal in a short table: week, focus, number of sessions, longest session. Increase slowly, with an easier week every third or fourth week.

Write only the next week as real sessions, after my yes, with `push_plan` and a `scheduled_for` each. Tell me to come back each week with this prompt or "Plan my week", so the next week can use what the Watch recorded.

## 11. Make my workout a Watch workout
**id:** `convert_workout` · **group:** plans · **args:** none
**about:** A workout from a coach, a club or an app, turned into one the Watch can run.

Ask me to paste or describe the workout (from a coach, a club, a training app, a book), which sport it is, and when I will do it.

Turn it into a plan the Watch can run: warm-up, the repeated parts as blocks with repeats, cool-down, every goal as a distance or a time. Labels under 40 characters that say what to do. If something cannot be expressed (a goal by pace only, a drill with no distance or time), say what you changed and why.

Show the parts as a list. If I say yes, call `push_plan` with `scheduled_for`, then tell me it is in the Import tab.
