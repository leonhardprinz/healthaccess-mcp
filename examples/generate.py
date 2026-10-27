#!/usr/bin/env python3
"""Generate the synthetic example folder next to this file.

Everything under `examples/` is made up: a 34-year-old recreational athlete who swims
and rows, with an Apple Watch and the Health Access app. No file here comes from a
real export. The numbers are built to be internally consistent (step durations sum to
the workout, distances sum to the total, pace = duration / distance), so the Rust
tests, the docs and the site can quote them. Workout files carry no `zones`: zone
seconds are computed by the MCP/CLI from the heart-rate series (schema.md); the
generator prints them for the record, with the same rule, so a doc can quote them.

Python 3 standard library only. Deterministic: the same seed writes the same bytes.

    python3 examples/generate.py          # rewrite every example file
    python3 examples/generate.py --check  # exit 1 if a committed file differs

Formats: docs/schema.md (workouts, vitals, index, plans, briefing.md) and
docs/export-coverage.md (days/, catalog.json, profile.json).
"""

from __future__ import annotations

import json
import math
import os
import random
import sys
from datetime import datetime, timedelta, timezone

SEED = 20260514
ROOT = os.path.dirname(os.path.abspath(__file__))
APP_VERSION = "0.4.0"
SOURCE = "Apple Watch"
TIME_ZONE = "Europe/Berlin"  # UTC+2 in May
ZONE_BOUNDS = [133, 146, 158, 170]  # estimated from age 34: max 208 - 0.7 * 34, bounds at 72/79/86/92 % (schema.md)
MAX_GAP_S = 60  # a longer gap between HR samples counts as a sensor dropout

# ----------------------------------------------------------------------------- helpers


def utc(y: int, mo: int, d: int, h: int, mi: int, s: int) -> datetime:
    return datetime(y, mo, d, h, mi, s, tzinfo=timezone.utc)


def iso(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def dumps(value, indent: int = 0) -> str:
    """Sorted keys, two-space indent, lists of scalars on one line (`["2026-…", 81]`)."""
    pad = "  " * indent
    if isinstance(value, dict):
        if not value:
            return "{}"
        rows = [
            f"{pad}  {json.dumps(k, ensure_ascii=False)}: {dumps(value[k], indent + 1)}"
            for k in sorted(value)
        ]
        return "{\n" + ",\n".join(rows) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        if all(not isinstance(v, (dict, list)) for v in value):
            return "[" + ", ".join(json.dumps(v, ensure_ascii=False) for v in value) + "]"
        rows = [f"{pad}  {dumps(v, indent + 1)}" for v in value]
        return "[\n" + ",\n".join(rows) + "\n" + pad + "]"
    if isinstance(value, float):
        if value != value or value in (math.inf, -math.inf):
            raise ValueError("non-finite float")
        return json.dumps(round(value, 6))
    return json.dumps(value, ensure_ascii=False)


def zone_of(bpm: int) -> int:
    """`bpm < bounds[0]` is zone 1, `bpm >= bounds[3]` is zone 5 (half-open on the bounds)."""
    return 1 + sum(1 for b in ZONE_BOUNDS if bpm >= b)


def zone_seconds(series: list[tuple[datetime, int]], start: datetime, end: datetime) -> dict:
    """Each sample's time until the next sample goes to that sample's zone, capped at 60 s,
    only inside [start, end]. The same rule as healthaccess-core (`derive::zone_seconds`)."""
    z = {f"z{i}": 0 for i in range(1, 6)}
    for (t0, bpm), (t1, _) in zip(series, series[1:]):
        a, b = max(t0, start), min(t1, end)
        raw = int((b - a).total_seconds())
        if raw <= 0:
            continue
        z[f"z{zone_of(bpm)}"] += min(raw, MAX_GAP_S)
    return z


def pace(distance_m, duration_s: int):
    """Seconds per 100 m, one decimal; none under 20 m (the contract's floor)."""
    if distance_m is None or distance_m < 20:
        return None
    return round(duration_s / distance_m * 100.0, 1)


def mean_hr(series, start: datetime, end: datetime):
    vals = [bpm for t, bpm in series if start <= t < end]
    return round(sum(vals) / len(vals)) if vals else None


def simulate_hr(rng: random.Random, start: datetime, duration_s: int, targets, hr0: float):
    """First-order heart-rate dynamics towards a per-second target, sampled every ~5 s.

    `targets` is a list of (step_start_s, step_duration_s, target_at_start, target_at_end);
    inside a step the target moves linearly. A first-order lag (tau 15 s up, 18 s down)
    gives the step-shaped rises and the drops in the rests."""
    per_second = []
    for s0, dur, a, b in targets:
        for k in range(dur):
            per_second.append(a + (b - a) * k / max(dur - 1, 1))
    assert len(per_second) == duration_s
    hr = hr0
    trace = []
    for target in per_second:
        tau = 15.0 if target > hr else 18.0
        hr += (target - hr) * (1.0 - math.exp(-1.0 / tau))
        trace.append(hr)
    series = []
    t = 1  # the first sample lands a second after the start
    while t <= duration_s - 1:
        bpm = int(round(trace[t] + rng.gauss(0.0, 1.0)))
        series.append((start + timedelta(seconds=t), bpm))
        t += rng.choice([5, 5, 5, 5, 5, 5, 5, 4, 6])
    return series


def expand(plan: dict) -> list[dict]:
    """Apple's numbering of a custom workout: warm-up `0.0.0`, blocks 1..n as `block.rep.step`
    (reps 0-based), cool-down as a trailing single-step block `(n+1).0.0`."""
    out = []
    if plan.get("warmup"):
        out.append({"key": "0.0.0", "block": 0, "rep": 0, "step": 0, "kind": "warmup", "plan": plan["warmup"]})
    for b, block in enumerate(plan["blocks"], start=1):
        for rep in range(block["repeat"]):
            for s, step in enumerate(block["steps"]):
                kind = step.get("kind") or ("work" if step["goal"]["type"] == "distance_m" else "recovery")
                out.append({"key": f"{b}.{rep}.{s}", "block": b, "rep": rep, "step": s, "kind": kind, "plan": step})
    if plan.get("cooldown"):
        n = len(plan["blocks"]) + 1
        out.append({"key": f"{n}.0.0", "block": n, "rep": 0, "step": 0, "kind": "cooldown", "plan": plan["cooldown"]})
    return out


def check_plan(plan: dict) -> None:
    assert 0 < len(plan["name"]) <= 40
    steps = ([plan["warmup"]] if plan.get("warmup") else []) + [
        s for b in plan["blocks"] for s in b["steps"]
    ] + ([plan["cooldown"]] if plan.get("cooldown") else [])
    for s in steps:
        assert s["goal"]["type"] in ("time_s", "distance_m") and s["goal"]["value"] > 0, s
        if s.get("zone") is not None:
            assert 1 <= s["zone"] <= 5, s
        if s.get("label") is not None:
            assert len(s["label"]) <= 40, (len(s["label"]), s["label"])
    for b in plan["blocks"]:
        assert 1 <= b["repeat"] <= 99 and b["steps"]


# ----------------------------------------------------------------------------- plans

SWIM_PLAN_ID = "2026-05-13T19:02:11Z-s12"
SWIM_PLAN = {
    "schema": "healthaccess.plan.v1",
    "id": SWIM_PLAN_ID,
    "name": "S12",
    "sport": "pool_swim",
    "pool_length_m": 50,
    "warmup": {"goal": {"type": "distance_m", "value": 200}, "zone": 1, "label": "FR easy, find your breathing"},
    "blocks": [
        {"repeat": 3, "steps": [
            {"kind": "work", "goal": {"type": "distance_m", "value": 50}, "zone": 1, "label": "DRILL 6-3-6: 6 kicks side, 3 strokes"},
            {"kind": "work", "goal": {"type": "distance_m", "value": 50}, "zone": 1, "label": "FR easy, long strokes"},
            {"kind": "recovery", "goal": {"type": "time_s", "value": 30}},
        ]},
        {"repeat": 4, "steps": [
            {"kind": "work", "goal": {"type": "distance_m", "value": 100}, "zone": 2, "label": "FR 100 steady, breathe every 3"},
            {"kind": "recovery", "goal": {"type": "time_s", "value": 40}},
        ]},
        {"repeat": 2, "steps": [
            {"kind": "work", "goal": {"type": "time_s", "value": 120}, "zone": 1, "label": "KICK on back, no board, hips up"},
            {"kind": "recovery", "goal": {"type": "time_s", "value": 45}},
        ]},
        {"repeat": 1, "steps": [
            {"kind": "work", "goal": {"type": "distance_m", "value": 100}, "zone": 2, "label": "FR 100, carry the drill into it"},
        ]},
    ],
    "cooldown": {"goal": {"type": "distance_m", "value": 100}, "zone": 1, "label": "Easy, any stroke, long exhale"},
    "notes": "Technique week 2. Short drill reps, then four steady 100s to carry the feel over. Kick on back is for the hips, not for speed. Target effort 5 to 6.",
    "created_by": "claude-code",
    "created_at": "2026-05-13T19:02:11Z",
    "scheduled_for": "2026-05-14T05:00:00Z",
}
SWIM_WORKOUTKIT_ID = "D4E7A2C1-6F3B-4E8A-9B5C-1A2F3E4D5C6B"
SWIM_STATUS = {
    "plan_id": SWIM_PLAN_ID,
    "state": "scheduled",
    "at": "2026-05-13T19:04:40Z",
    "method": "schedule",
    "workoutkit_id": SWIM_WORKOUTKIT_ID,
    "scheduled_for": "2026-05-14T05:00:00Z",
    "error": None,
}

ROW_PLAN_ID = "2026-05-11T18:40:02Z-r4"
ROW_PLAN = {
    "schema": "healthaccess.plan.v1",
    "id": ROW_PLAN_ID,
    "name": "R4",
    "sport": "indoor_row",
    "pool_length_m": None,
    "warmup": {"goal": {"type": "time_s", "value": 180}, "zone": 1, "label": "Easy, 18 spm, find the rhythm"},
    "blocks": [
        {"repeat": 4, "steps": [
            {"kind": "work", "goal": {"type": "time_s", "value": 240}, "zone": 3, "label": "24 spm, pull harder if HR under 147"},
            {"kind": "recovery", "goal": {"type": "time_s", "value": 60}, "zone": 1, "label": "Paddle, 16 spm"},
        ]},
    ],
    "cooldown": {"goal": {"type": "time_s", "value": 300}, "zone": 1, "label": "Paddle it out, drop the rate"},
    "notes": "Four steady pieces at 24 spm with a minute of paddling between them. The Watch reads low on the rower, so go by rate and effort; heart rate is a hint. Target effort 6 to 7.",
    "created_by": "claude-code",
    "created_at": "2026-05-11T18:40:02Z",
    "scheduled_for": "2026-05-12T04:30:00Z",
}
ROW_WORKOUTKIT_ID = "8B1F6C3A-2D4E-4F90-A7B3-6E5D4C3B2A19"
ROW_STATUS = {
    "plan_id": ROW_PLAN_ID,
    "state": "scheduled",
    "at": "2026-05-11T18:41:20Z",
    "method": "schedule",
    "workoutkit_id": ROW_WORKOUTKIT_ID,
    "scheduled_for": "2026-05-12T04:30:00Z",
    "error": None,
}

# ----------------------------------------------------------------------------- the swim
# 2026-05-14 07:12 local, 50 m pool, 1,200 m in 36:06. One entry per expanded plan step:
# laps (seconds per 50 m length), the push-off delay before the first length, strokes per
# length (SWOLF = seconds + strokes), the stroke the Watch detects, and the heart-rate
# target at the start and the end of the step.

SWIM_ID = "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3"
SWIM_START = utc(2026, 5, 14, 5, 12, 4)
SWIM_PERF = [
    # warm-up 200
    dict(laps=[67, 68, 70, 71], offset=3, strokes=[21, 22, 22, 23], stroke="freestyle", hr=(84, 120)),
    # 3 x (50 drill / 50 easy / 30 s)
    dict(laps=[83], offset=2, strokes=[10], stroke="mixed", hr=(125, 127)),
    dict(laps=[66], offset=2, strokes=[22], stroke="freestyle", hr=(129, 132)),
    dict(rest=30, hr=(122, 112)),
    dict(laps=[81], offset=2, strokes=[11], stroke="mixed", hr=(126, 128)),
    dict(laps=[65], offset=2, strokes=[23], stroke="freestyle", hr=(130, 133)),
    dict(rest=30, hr=(123, 112)),
    dict(laps=[85], offset=2, strokes=[9], stroke="mixed", hr=(126, 129)),
    dict(laps=[67], offset=2, strokes=[22], stroke="freestyle", hr=(131, 134)),
    dict(rest=30, hr=(124, 113)),
    # 4 x (100 steady / 40 s); the fourth one gets swum hard
    dict(laps=[66, 68], offset=2, strokes=[22, 23], stroke="freestyle", hr=(135, 140)),
    dict(rest=40, hr=(128, 114)),
    dict(laps=[66, 69], offset=2, strokes=[23, 23], stroke="freestyle", hr=(138, 143)),
    dict(rest=40, hr=(130, 115)),
    dict(laps=[67, 70], offset=2, strokes=[23, 24], stroke="freestyle", hr=(140, 146)),
    dict(rest=40, hr=(132, 116)),
    dict(laps=[64, 66], offset=2, strokes=[24, 25], stroke="freestyle", hr=(146, 165)),
    dict(rest=40, hr=(145, 120)),
    # 2 x (2:00 kick on back / 45 s): a time step, the length ends a few seconds before the alert
    dict(laps=[114], offset=3, strokes=None, stroke="kickboard", hr=(134, 141), time=120, distance=50),
    dict(rest=45, hr=(126, 113)),
    dict(laps=[113], offset=3, strokes=None, stroke="kickboard", hr=(136, 143), time=120, distance=50),
    dict(rest=45, hr=(128, 113)),
    # 100 easy, then cool-down 100 breaststroke
    dict(laps=[65, 67], offset=2, strokes=[21, 22], stroke="freestyle", hr=(139, 147)),
    dict(laps=[82, 85], offset=3, strokes=[11, 9], stroke="breaststroke", hr=(126, 114)),
]
SWIM_META = {
    "HKAverageMETs": "6.84 kcal/hr·kg",
    "HKIndoorWorkout": "0",
    "HKLapLength": "50 m",
    "HKSwimmingLocationType": "1",
    "HKTimeZone": TIME_ZONE,
}

# ----------------------------------------------------------------------------- the row
# 2026-05-12 06:30 local, 28:00, time-based steps, no distance (the Watch was paired with an
# iPhone on iOS 17, which does not give rowing distance per step; the athlete skipped it).

ROW_ID = "3F8B2D41-9E6C-4A17-B2D8-5C3E7F9A1B04"
ROW_START = utc(2026, 5, 12, 4, 30, 11)
ROW_PERF = [
    dict(time=180, hr=(82, 122)),
    dict(time=240, hr=(142, 150)), dict(time=60, hr=(138, 126)),
    dict(time=240, hr=(146, 154)), dict(time=60, hr=(141, 128)),
    dict(time=240, hr=(149, 157)), dict(time=60, hr=(143, 129)),
    dict(time=240, hr=(152, 165)), dict(time=60, hr=(146, 130)),
    dict(time=300, hr=(124, 102)),
]
ROW_META = {
    "HKAverageMETs": "7.52 kcal/hr·kg",
    "HKIndoorWorkout": "1",
    "HKTimeZone": TIME_ZONE,
    "HKWeatherHumidity": "5800 %",
    "HKWeatherTemperature": "54 degF",
}


def build_workout(rng, *, wid, start, plan, status, perf, meta, activity, pool_length, kcal,
                  effort, effort_estimated, recovery_after, hr0):
    steps_plan = expand(plan)
    assert len(steps_plan) == len(perf), (len(steps_plan), len(perf))
    steps, laps, targets = [], [], []
    t = start
    for sp, p in zip(steps_plan, perf):
        goal = sp["plan"]["goal"]
        if "rest" in p:
            assert goal["type"] == "time_s" and goal["value"] == p["rest"]
            dur, dist, step_laps = p["rest"], None, []
        elif "laps" in p:
            if "time" in p:
                assert goal["type"] == "time_s" and goal["value"] == p["time"]
                dur, dist = p["time"], p["distance"]
            else:
                dur = p["offset"] + sum(p["laps"])
                dist = pool_length * len(p["laps"])
                assert goal["type"] == "distance_m" and goal["value"] == dist, (sp["key"], dist)
            step_laps, lt = [], t + timedelta(seconds=p["offset"])
            for i, ld in enumerate(p["laps"]):
                strokes = p["strokes"][i] if p["strokes"] else None
                step_laps.append({
                    "start": iso(lt), "end": iso(lt + timedelta(seconds=ld)), "duration_s": ld,
                    "stroke": p["stroke"],
                    "swolf": float(ld + strokes) if strokes is not None else None,
                })
                lt += timedelta(seconds=ld)
            assert lt <= t + timedelta(seconds=dur)
        else:
            assert goal["type"] == "time_s" and goal["value"] == p["time"]
            dur, dist, step_laps = p["time"], None, []
        end = t + timedelta(seconds=dur)
        steps.append({
            "key": sp["key"], "block": sp["block"], "rep": sp["rep"], "step": sp["step"],
            "label": sp["plan"].get("label"), "kind": sp["kind"],
            "start": iso(t), "end": iso(end), "duration_s": dur,
            "distance_m": dist, "avg_hr": None, "goal_met": True,
            "pace_s_per_100m": pace(dist, dur),
            "_t": (t, end),
        })
        laps.extend(step_laps)
        targets.append((int((t - start).total_seconds()), dur, p["hr"][0], p["hr"][1]))
        t = end
    duration = int((t - start).total_seconds())
    series = simulate_hr(rng, start, duration, targets, hr0)
    for s in steps:
        s["avg_hr"] = mean_hr(series, *s.pop("_t"))
    distance = sum(s["distance_m"] for s in steps if s["distance_m"]) or None
    bpms = [b for _, b in series]
    return {
        "schema": "healthaccess.workout.v1",
        "healthaccess_version": APP_VERSION,
        "id": wid,
        "activity": activity,
        "source": SOURCE,
        "start": iso(start),
        "end": iso(t),
        "duration_s": duration,
        "distance_m": distance,
        "active_kcal": kcal,
        "avg_hr": round(sum(bpms) / len(bpms)),
        "max_hr": max(bpms),
        "pool_length_m": pool_length,
        "plan_ref": {"plan_id": plan["id"], "name": plan["name"]},
        "steps": steps,
        "laps": laps,
        "hr_series": [[iso(ts), bpm] for ts, bpm in series],
        "recovery_hr": {"end": bpms[-1], "1min": recovery_after[0], "2min": recovery_after[1]},
        "effort": effort,
        "effort_source": "apple",
        "effort_estimated": effort_estimated,
        "feel": None,
        "metadata": meta,
    }


def check_workout(w: dict, *, steps: int, laps: int, distance, series_about: int) -> None:
    assert len(w["steps"]) == steps and len(w["laps"]) == laps
    assert sum(s["duration_s"] for s in w["steps"]) == w["duration_s"]
    assert w["steps"][0]["start"] == w["start"] and w["steps"][-1]["end"] == w["end"]
    for a, b in zip(w["steps"], w["steps"][1:]):
        assert a["end"] == b["start"], (a["key"], b["key"])
    assert w["distance_m"] == distance
    for s in w["steps"]:
        assert s["pace_s_per_100m"] == pace(s["distance_m"], s["duration_s"])
        if s["label"] is not None:
            assert len(s["label"]) <= 40
    for lap in w["laps"]:
        inside = any(s["start"] <= lap["start"] and lap["end"] <= s["end"] for s in w["steps"])
        assert inside, lap
        if lap["swolf"] is not None:
            assert 60 <= lap["swolf"] <= 95, lap
    assert abs(len(w["hr_series"]) - series_about) <= 15, len(w["hr_series"])
    assert w["max_hr"] == max(b for _, b in w["hr_series"])


# ----------------------------------------------------------------------------- the day

SYNC_AT = "2026-05-14T06:03:17Z"  # 08:03 local: the phone was unlocked, the app exported

DAY = {
    "_comment": "format per export-coverage.md v0.4, example",
    "schema": "healthaccess.day.v1",
    "date": "2026-05-14",
    "activity": {
        "rings": {
            "move_kcal": {"goal": 650, "actual": 712.3},
            "exercise_min": {"goal": 30, "actual": 47},
            "stand_hours": {"goal": 12, "actual": 13},
            "move_mode": "active_energy",
        },
        "steps": 9412,
        "distance_walking_running_m": 7180.4,
        "distance_cycling_m": None,
        "distance_swimming_m": 1200,
        "flights_climbed": 11,
        "active_energy_kcal": 712.3,
        "basal_energy_kcal": 1748.9,
        "exercise_min": 47,
        "stand_min": 96,
        "move_min": None,
        "time_in_daylight_min": 63,
        "physical_effort_avg_met": 2.4,
        "push_count": None,
    },
    "heart": {
        "resting_hr": 54,
        "walking_hr_avg": 98,
        "hr": {"min": 47, "avg": 72, "max": 162, "samples": 1184},
        "hrv_sdnn_ms": 58.3,
        "hrv_rmssd_ms": None,
        "recovery_1min_bpm": None,
        "vo2max": 44.1,
        "afib_burden_pct": None,
        "events": {
            "high_hr": {"count": 0, "times": []},
            "low_hr": {"count": 0, "times": []},
            "irregular_rhythm": {"count": 0, "times": []},
            "low_cardio_fitness": {"count": 0, "times": []},
        },
    },
    "respiratory": {
        "rate_avg": 14.6,
        "spo2": {"avg": 96.8, "min": 94},
        "breathing_disturbances": 3.1,
        "sleep_apnea_events": 0,
        "fev1": None,
        "fvc": None,
        "peak_flow": None,
    },
    "sleep": {
        "in_bed_s": 28137,
        "asleep_s": 26160,
        "core_s": 15420,
        "deep_s": 4980,
        "rem_s": 5760,
        "awake_s": 1977,
        "sessions": [{"start": "2026-05-13T20:58:12Z", "end": "2026-05-14T04:47:09Z", "source": SOURCE}],
        "wrist_temperature_delta_c": -0.12,
        "respiratory_rate_sleep": 14.6,
        "spo2_sleep": 96.8,
    },
    "body": {
        "mass_kg": 78.4,
        "fat_pct": None,
        "lean_kg": None,
        "bmi": 24.2,
        "waist_cm": None,
        "height_cm": 180,
        "temperature_c": None,
        "basal_body_temperature_c": None,
    },
    "mobility": {
        "walking_speed_mps": 1.38,
        "step_length_m": 0.74,
        "asymmetry_pct": 1.9,
        "double_support_pct": 27.4,
        "stair_ascent_mps": 0.52,
        "stair_descent_mps": 0.61,
        "steadiness_pct": None,
        "steadiness_events": [],
        "six_minute_walk_m": None,
        "falls": None,
    },
}

VITALS = {
    "schema": "healthaccess.vitals.v1",
    "date": "2026-05-14",
    "resting_hr": DAY["heart"]["resting_hr"],
    "hrv_sdnn_ms": DAY["heart"]["hrv_sdnn_ms"],
    "body_mass_kg": DAY["body"]["mass_kg"],
    "sleep_s": DAY["sleep"]["asleep_s"],
    "steps": DAY["activity"]["steps"],
    "vo2max": DAY["heart"]["vo2max"],
    "bp": None,
}

# mcp/clients/<id>.json: the presence file the MCP server writes (schema.md). The id is the
# server's stable hash of machine + client; the shape is core/src/handshake.rs.
CLIENT_ID = "9f3c1a7e5b2d4c80"
CLIENT = {
    "schema": "healthaccess.client.v1",
    "id": CLIENT_ID,
    "client": {"name": "Claude Code", "version": "2.1.0"},
    "machine": "Alex's MacBook Pro",
    "mcp_version": "0.2.0",
    "first_seen": "2026-05-09T17:20:41Z",
    "last_seen": "2026-05-14T06:11:02Z",
    "last_tool": "list_workouts",
    "calls": 123,
}

PROFILE = {
    "generated": SYNC_AT,
    "age": 34,
    "birth_year": 1992,
    "biological_sex": "male",
    "blood_type": "o_positive",
    "wheelchair_use": "no",
    "activity_move_mode": "active_energy",
    "fitzpatrick_skin_type": "not_set",
}

# ----------------------------------------------------------------------------- the catalog
# Every identifier of the iOS 27.1 SDK, the same list as core/src/hk_types.rs (and the one
# the app embeds). Types with data for this athlete over 90 days: the Watch basics, sleep,
# the smart scale, mobility, swims and rows.

HK_QUANTITY = """ActiveEnergyBurned AppleExerciseTime AppleMoveTime AppleSleepingBreathingDisturbances
AppleSleepingWristTemperature AppleStandTime AppleWalkingSteadiness AtrialFibrillationBurden
BasalBodyTemperature BasalEnergyBurned BloodAlcoholContent BloodGlucose BloodPressureDiastolic
BloodPressureSystolic BodyFatPercentage BodyMass BodyMassIndex BodyTemperature CrossCountrySkiingSpeed
CyclingCadence CyclingFunctionalThresholdPower CyclingPower CyclingSpeed DietaryBiotin DietaryCaffeine
DietaryCalcium DietaryCarbohydrates DietaryChloride DietaryCholesterol DietaryChromium DietaryCopper
DietaryEnergyConsumed DietaryFatMonounsaturated DietaryFatPolyunsaturated DietaryFatSaturated
DietaryFatTotal DietaryFiber DietaryFolate DietaryIodine DietaryIron DietaryMagnesium DietaryManganese
DietaryMolybdenum DietaryNiacin DietaryPantothenicAcid DietaryPhosphorus DietaryPotassium DietaryProtein
DietaryRiboflavin DietarySelenium DietarySodium DietarySugar DietaryThiamin DietaryVitaminA
DietaryVitaminB12 DietaryVitaminB6 DietaryVitaminC DietaryVitaminD DietaryVitaminE DietaryVitaminK
DietaryWater DietaryZinc DistanceCrossCountrySkiing DistanceCycling DistanceDownhillSnowSports
DistancePaddleSports DistanceRowing DistanceSkatingSports DistanceSwimming DistanceWalkingRunning
DistanceWheelchair ElectrodermalActivity EnvironmentalAudioExposure EnvironmentalSoundReduction
EstimatedWorkoutEffortScore FlightsClimbed ForcedExpiratoryVolume1 ForcedVitalCapacity
HeadphoneAudioExposure HeartRate HeartRateRecoveryOneMinute HeartRateVariabilityRMSSD
HeartRateVariabilitySDNN Height InhalerUsage InsulinDelivery LeanBodyMass NikeFuel
NumberOfAlcoholicBeverages NumberOfTimesFallen OxygenSaturation PaddleSportsSpeed PeakExpiratoryFlowRate
PeripheralPerfusionIndex PhysicalEffort PushCount RespiratoryRate RestingHeartRate RowingSpeed
RunningGroundContactTime RunningPower RunningSpeed RunningStrideLength RunningVerticalOscillation
SixMinuteWalkTestDistance StairAscentSpeed StairDescentSpeed StepCount SwimmingStrokeCount TimeInDaylight
UVExposure UnderwaterDepth VO2Max WaistCircumference WalkingAsymmetryPercentage
WalkingDoubleSupportPercentage WalkingHeartRateAverage WalkingSpeed WalkingStepLength WaterTemperature
WorkoutEffortScore""".split()

HK_CATEGORY = """AbdominalCramps Acne AppetiteChanges AppleStandHour AppleWalkingSteadinessEvent
AudioExposureEvent BladderIncontinence BleedingAfterMenopause BleedingAfterPregnancy
BleedingDuringPregnancy Bloating BreastPain CervicalMucusQuality ChestTightnessOrPain Chills Constipation
Contraceptive Coughing Diarrhea Dizziness DrySkin EnvironmentalAudioExposureEvent Fainting Fatigue Fever
GeneralizedBodyAche HairLoss HandwashingEvent Headache HeadphoneAudioExposureEvent Heartburn
HighHeartRateEvent HotFlashes HypertensionEvent InfrequentMenstrualCycles IntermenstrualBleeding
IrregularHeartRhythmEvent IrregularMenstrualCycles Lactation LossOfSmell LossOfTaste LowCardioFitnessEvent
LowHeartRateEvent LowerBackPain MemoryLapse MenopausalState MenstrualFlow MindfulSession MoodChanges
Nausea NightSweats OvulationTestResult PelvicPain PersistentIntermenstrualBleeding Pregnancy
PregnancyTestResult ProgesteroneTestResult ProlongedMenstrualPeriods RapidPoundingOrFlutteringHeartbeat
RunnyNose SexualActivity ShortnessOfBreath SinusCongestion SkippedHeartbeat SleepAnalysis SleepApneaEvent
SleepChanges SoreThroat ToothbrushingEvent VaginalDryness Vomiting Wheezing""".split()

HK_CHARACTERISTIC = "ActivityMoveMode BiologicalSex BloodType DateOfBirth FitzpatrickSkinType WheelchairUse".split()
HK_CORRELATION = "BloodPressure Food".split()
HK_DOCUMENT = ["CDA"]
HK_CLINICAL = """AllergyRecord ClinicalNoteRecord ConditionRecord CoverageRecord ImmunizationRecord
LabResultRecord MedicationRecord ProcedureRecord VitalSignRecord""".split()
HK_SPECIAL = [
    ("HKActivitySummaryTypeIdentifier", "activity_summary"),
    ("HKDataTypeIdentifierAudiogram", "audiogram"),
    ("HKDataTypeIdentifierElectrocardiogram", "electrocardiogram"),
    ("HKDataTypeIdentifierHeartbeatSeries", "heartbeat_series"),
    ("HKDataTypeIdentifierStateOfMind", "state_of_mind"),
    ("HKDataTypeIdentifierUserAnnotatedMedicationConcept", "medication_concept"),
    ("HKMedicationDoseEventTypeIdentifierMedicationDoseEvent", "medication_dose_event"),
    ("HKScoredAssessmentTypeIdentifierGAD7", "scored_assessment"),
    ("HKScoredAssessmentTypeIdentifierPHQ9", "scored_assessment"),
    ("HKVisionPrescriptionTypeIdentifier", "vision_prescription"),
    ("HKWorkoutRouteTypeIdentifier", "workout_route"),
    ("HKWorkoutTypeIdentifier", "workout"),
]

# identifier stem -> (samples in 90 days, first date, exported_in)
WITH_DATA = {
    "HKQuantityTypeIdentifierActiveEnergyBurned": (61284, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierAppleExerciseTime": (4120, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierAppleSleepingBreathingDisturbances": (84, "2026-02-14", "days"),
    "HKQuantityTypeIdentifierAppleSleepingWristTemperature": (86, "2026-02-14", "days"),
    "HKQuantityTypeIdentifierAppleStandTime": (7830, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierAppleWalkingSteadiness": (12, "2026-02-16", "days"),
    "HKQuantityTypeIdentifierBasalEnergyBurned": (29412, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierBodyMass": (38, "2026-02-15", "days"),
    "HKQuantityTypeIdentifierBodyMassIndex": (38, "2026-02-15", "days"),
    "HKQuantityTypeIdentifierDistanceSwimming": (1206, "2026-02-17", "workouts"),
    "HKQuantityTypeIdentifierDistanceWalkingRunning": (17902, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore": (23, "2026-02-17", "workouts"),
    "HKQuantityTypeIdentifierFlightsClimbed": (1104, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierHeartRate": (84210, "2026-02-13", "workouts"),
    "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute": (23, "2026-02-17", "workouts"),
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN": (412, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierHeight": (1, "2026-02-15", "days"),
    "HKQuantityTypeIdentifierOxygenSaturation": (1230, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierPhysicalEffort": (6420, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierRespiratoryRate": (2870, "2026-02-14", "days"),
    "HKQuantityTypeIdentifierRestingHeartRate": (90, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierSixMinuteWalkTestDistance": (13, "2026-02-16", "days"),
    "HKQuantityTypeIdentifierStairAscentSpeed": (232, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierStairDescentSpeed": (198, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierStepCount": (11540, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierSwimmingStrokeCount": (1118, "2026-02-17", "workouts"),
    "HKQuantityTypeIdentifierTimeInDaylight": (2210, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierVO2Max": (24, "2026-02-14", "days"),
    "HKQuantityTypeIdentifierWalkingAsymmetryPercentage": (610, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage": (1470, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierWalkingHeartRateAverage": (89, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierWalkingSpeed": (1480, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierWalkingStepLength": (1480, "2026-02-13", "days"),
    "HKQuantityTypeIdentifierWorkoutEffortScore": (21, "2026-02-17", "workouts"),
    "HKCategoryTypeIdentifierAppleStandHour": (1128, "2026-02-13", "days"),
    "HKCategoryTypeIdentifierSleepAnalysis": (2214, "2026-02-13", "days"),
    "HKCharacteristicTypeIdentifierActivityMoveMode": (None, None, "profile"),
    "HKCharacteristicTypeIdentifierBiologicalSex": (None, None, "profile"),
    "HKCharacteristicTypeIdentifierBloodType": (None, None, "profile"),
    "HKCharacteristicTypeIdentifierDateOfBirth": (None, None, "profile"),
    "HKCharacteristicTypeIdentifierWheelchairUse": (None, None, "profile"),
    "HKActivitySummaryTypeIdentifier": (90, "2026-02-13", "days"),
    "HKWorkoutTypeIdentifier": (23, "2026-02-17", "workouts"),
}


def catalog() -> dict:
    families = (
        [("HKQuantityTypeIdentifier" + s, "quantity") for s in HK_QUANTITY]
        + [("HKCategoryTypeIdentifier" + s, "category") for s in HK_CATEGORY]
        + [("HKCharacteristicTypeIdentifier" + s, "characteristic") for s in HK_CHARACTERISTIC]
        + [("HKCorrelationTypeIdentifier" + s, "correlation") for s in HK_CORRELATION]
        + [("HKDocumentTypeIdentifier" + s, "document") for s in HK_DOCUMENT]
        + [("HKClinicalTypeIdentifier" + s, "clinical") for s in HK_CLINICAL]
        + HK_SPECIAL
    )
    assert len(HK_QUANTITY) == 121 and len(HK_CATEGORY) == 72, (len(HK_QUANTITY), len(HK_CATEGORY))
    ids = [i for i, _ in families]
    assert len(set(ids)) == len(ids) and set(WITH_DATA) <= set(ids), set(WITH_DATA) - set(ids)
    types = {}
    for ident, kind in families:
        if ident in WITH_DATA:
            n, first, where = WITH_DATA[ident]
            types[ident] = {
                "kind": kind, "authorized": None, "has_data": True,
                "samples_90d": n, "first": first, "last": "2026-05-14" if n else None,
                "exported_in": where,
            }
        else:
            types[ident] = {
                "kind": kind, "authorized": None, "has_data": False,
                "samples_90d": 0, "first": None, "last": None, "exported_in": "none",
            }
    return {
        "generated": SYNC_AT,
        "app_version": APP_VERSION,
        "sdk": "iOS 27.1",
        "types": types,
        "unknown_types_with_data": [],
    }


# ----------------------------------------------------------------------------- briefing


def fmt_duration(secs: int) -> str:
    h, m, s = secs // 3600, (secs % 3600) // 60, secs % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def briefing(swim: dict, row: dict) -> str:
    def line(w, label):
        bits = []
        if w["distance_m"]:
            bits.append(f"{w['distance_m']} m")
        bits.append(fmt_duration(w["duration_s"]))
        bits.append(f"avg HR {w['avg_hr']}")
        bits.append(f"effort {w['effort']}/10 ({w['effort_source']})")
        return f"- {w['start'][:10]} {label} \"{w['plan_ref']['name']}\": " + ", ".join(bits)

    week_total = swim["duration_s"] + row["duration_s"]
    mean_effort = (swim["effort"] + row["effort"]) / 2
    sleep_h = DAY["sleep"]["asleep_s"] // 60
    return "\n".join([
        "# Health Access briefing for the athlete, written 2026-05-14 08:03 (Europe/Berlin)",
        "",
        "## Last 4 weeks",
        "- 2026-W17 (2026-04-20 to 2026-04-26): no sessions",
        "- 2026-W18 (2026-04-27 to 2026-05-03): no sessions",
        "- 2026-W19 (2026-05-04 to 2026-05-10): no sessions",
        f"- 2026-W20 (2026-05-11 to 2026-05-17): 2 sessions, {swim['distance_m']} m, "
        f"{fmt_duration(week_total)}, mean effort {mean_effort} (2 of 2 rated)",
        "",
        "## Recent sessions",
        line(swim, "Pool swim"),
        line(row, "Indoor row"),
        "",
        "## Vitals",
        f"- Resting HR {DAY['heart']['resting_hr']} bpm (2026-05-14), 21 days: too few days to tell",
        f"- HRV {DAY['heart']['hrv_sdnn_ms']} ms (2026-05-14), 21 days: too few days to tell",
        f"- Sleep {sleep_h // 60}:{sleep_h % 60:02d} h (2026-05-14), 21 days: too few days to tell",
        f"- Weight {DAY['body']['mass_kg']} kg (2026-05-14), 21 days: too few days to tell",
        "",
        "## Next session",
        "- none",
        "",
        "## Open",
        "- nothing: both sessions carry the rating from the Watch, no plan is waiting for Put on Watch",
        "",
        "## Limits",
        "- Health data can only be read while the phone is unlocked, so a workout finished with the "
        "phone in the bag exports on the next unlock, not before.",
        "- The Watch keeps its own pool length setting; the plan cannot set it.",
        "",
    ])


# ----------------------------------------------------------------------------- main


def index_row(w: dict, file: str) -> dict:
    return {
        "id": w["id"], "file": file, "activity": w["activity"], "start": w["start"],
        "duration_s": w["duration_s"], "distance_m": w["distance_m"], "avg_hr": w["avg_hr"],
        "effort": w["effort"], "effort_source": w["effort_source"],
        "plan_name": w["plan_ref"]["name"], "source": w["source"],
    }


def generate() -> dict[str, str]:
    rng = random.Random(SEED)
    for plan in (SWIM_PLAN, ROW_PLAN):
        check_plan(plan)

    swim = build_workout(
        rng, wid=SWIM_ID, start=SWIM_START, plan=SWIM_PLAN, status=SWIM_STATUS, perf=SWIM_PERF,
        meta=SWIM_META, activity="pool_swim", pool_length=50, kcal=338.6,
        effort=6, effort_estimated=5, recovery_after=(104, 96), hr0=84.0,
    )
    check_workout(swim, steps=24, laps=24, distance=1200, series_about=433)
    row = build_workout(
        rng, wid=ROW_ID, start=ROW_START, plan=ROW_PLAN, status=ROW_STATUS, perf=ROW_PERF,
        meta=ROW_META, activity="indoor_row", pool_length=None, kcal=286.4,
        effort=7, effort_estimated=6, recovery_after=(109, 99), hr0=82.0,
    )
    check_workout(row, steps=10, laps=0, distance=None, series_about=336)
    assert row["duration_s"] == 28 * 60

    swim_file = "workouts/2026-05-14_0712_PoolSwim_7A1C3E90.json"
    row_file = "workouts/2026-05-12_0630_IndoorRow_3F8B2D41.json"
    index = {
        "schema": "healthaccess.index.v1",
        "updated": SYNC_AT,
        "workouts": [index_row(swim, swim_file), index_row(row, row_file)],
    }
    files = {
        swim_file: swim,
        row_file: row,
        "index.json": index,
        "days/2026-05-14.json": DAY,
        "vitals/2026-05-14.json": VITALS,
        f"plans/{SWIM_PLAN_ID}.json": SWIM_PLAN,
        f"plans/{SWIM_PLAN_ID}.status.json": SWIM_STATUS,
        f"plans/{ROW_PLAN_ID}.json": ROW_PLAN,
        f"plans/{ROW_PLAN_ID}.status.json": ROW_STATUS,
        "catalog.json": catalog(),
        "profile.json": PROFILE,
        f"mcp/clients/{CLIENT_ID}.json": CLIENT,
    }
    out = {path: dumps(doc) + "\n" for path, doc in files.items()}
    out["briefing.md"] = briefing(swim, row)
    return out


def main(argv: list[str]) -> int:
    out = generate()
    check = "--check" in argv
    changed = []
    for rel, text in out.items():
        path = os.path.join(ROOT, rel)
        if check:
            try:
                with open(path, encoding="utf-8") as f:
                    if f.read() != text:
                        changed.append(rel)
            except FileNotFoundError:
                changed.append(rel)
            continue
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    # Files under examples/ that this script did not write. The healthaccess CLI drops a
    # presence file with your real machine name into mcp/clients/ whenever it runs against
    # this folder; it must not be committed.
    own = set(out) | {"generate.py", "README.md"}
    stray = []
    for dirpath, _, names in os.walk(ROOT):
        for name in names:
            rel = os.path.relpath(os.path.join(dirpath, name), ROOT)
            if rel not in own and not name.startswith("."):
                stray.append(rel)
    for rel in sorted(stray):
        print(f"stray file, not generated (delete before committing): {rel}")
    if check:
        for rel in changed:
            print(f"differs: {rel}")
        return 1 if changed or stray else 0
    swim = json.loads(out["workouts/2026-05-14_0712_PoolSwim_7A1C3E90.json"])
    row = json.loads(out["workouts/2026-05-12_0630_IndoorRow_3F8B2D41.json"])
    for w in (swim, row):
        parse = lambda s: datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        series = [(parse(t), bpm) for t, bpm in w["hr_series"]]
        zones = zone_seconds(series, parse(w["start"]), parse(w["end"]))
        print(
            f"{w['activity']}: {w['duration_s']} s, {w['distance_m']} m, avg HR {w['avg_hr']}, "
            f"max {w['max_hr']}, {len(w['steps'])} steps, {len(w['laps'])} laps, "
            f"{len(w['hr_series'])} HR samples; zone seconds for bounds {ZONE_BOUNDS}: {zones}"
        )
    print(f"wrote {len(out)} files under {ROOT}")
    return 1 if stray else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
