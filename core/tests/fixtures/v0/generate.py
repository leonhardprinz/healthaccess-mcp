#!/usr/bin/env python3
"""Generate the two synthetic Phase 0 (v0) workout fixtures in this folder.

No real health data lives in the repository. The v1 fixtures one level up are copies of
examples/workouts (see examples/generate.py); these two keep the v0 converter covered.
They have the shape of a Phase 0
export (`tide.workout.v0`: raw HealthKit activities, events, HR series) so that the v0
converter, the plan matching, the summaries and the MCP end-to-end test all have
something realistic to chew on, but every value is made up here, deterministically.

    python3 core/tests/fixtures/v0/generate.py   # rewrites the two JSON files

Swim 5C0D9A7E: a 50 m pool session of 1200 m, warm-up step, 300 m easy, three drill
reps, four 100 m steady pieces, 200 m cool-down. Row 9B4F2E61: 31 minutes on the
rower, warm-up, one long piece, five work/rest pairs, cool-down. The step structure of
the swim matches the S26 plan of the store tests (blocks 1 to 3, cool-down as block 4).
"""
from __future__ import annotations

import json
import math
import pathlib
from datetime import datetime, timedelta, timezone

HERE = pathlib.Path(__file__).resolve().parent  # core/tests/fixtures/v0
BOUNDS = [133, 146, 159, 171]


def iso(t: datetime) -> str:
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def zone_of(bpm: int) -> int:
    return 1 + sum(1 for b in BOUNDS if bpm >= b)


def zone_seconds(series, start: datetime, end: datetime) -> dict:
    zs = {"z1": 0, "z2": 0, "z3": 0, "z4": 0, "z5": 0}
    for (t0, bpm), (t1, _) in zip(series, series[1:]):
        a, b = max(t0, start), min(t1, end)
        raw = int((b - a).total_seconds())
        if raw <= 0:
            continue
        zs[f"z{zone_of(bpm)}"] += min(raw, 60)
    return zs


def hr_series(start: datetime, end: datetime, target):
    """One sample every 5 s from start+1 s to end+125 s; `target(t_s)` gives the mean HR
    at second t of the workout, a deterministic wobble is added, no randomness."""
    out = []
    total = (end - start).total_seconds()
    t = 1.0
    while t <= total + 125:
        base = target(min(t, total)) if t <= total else target(total) - (t - total) * 0.25
        wobble = 3.0 * math.sin(t / 7.0) + 2.0 * math.sin(t / 23.0)
        out.append((start + timedelta(seconds=t), int(round(base + wobble))))
        t += 5.0
    return out


def avg(values):
    return round(sum(values) / len(values))


def write(path: pathlib.Path, doc: dict) -> None:
    text = json.dumps(doc, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8")
    print(f"wrote {path.name}: {len(text)} bytes, {len(doc['activities'])} activities, "
          f"{len(doc['events'])} events, {len(doc['hr_series'])} hr samples")


def swim() -> None:
    start = datetime(2026, 10, 21, 8, 30, 0, tzinfo=timezone.utc)
    # (key, seconds, distance_m or None, hr level, strokes per lap, stroke style raw, goal keys)
    plan = [("0.0.0", 120, None, 92, None, None, True)]
    plan.append(("1.0.0", 375, 300.0, 124, 22, "2", True))
    plan.append(("1.0.1", 45, 8.0, 118, None, None, True))
    for rep in range(3):
        plan.append((f"2.{rep}.0", 48 + rep, 52.0, 116 + rep, 26, "6", True))   # kick drill
        plan.append((f"2.{rep}.1", 25, 10.0, 112, None, None, True))
        plan.append((f"2.{rep}.2", 47 + rep, 51.0, 120 + rep, 20, "2", True))   # catch-up drill
        plan.append((f"2.{rep}.3", 30, 6.0, 114, None, None, True))
    for rep, secs in enumerate([110, 108, 109, 112]):
        plan.append((f"3.{rep}.0", secs, 100.0, 148 + 2 * rep, 21, "2", True))
        plan.append((f"3.{rep}.1", 40, 5.0, 138 + rep, None, None, True))
    plan.append(("4.0.0", 300, 200.0, 121, 19, "3", False))                    # cool-down, backstroke

    activities, events = [], []
    t = start
    levels = []  # (t_start_s, t_end_s, level) for the HR target function
    for key, secs, dist, level, strokes, style, success in plan:
        a_start, a_end = t, t + timedelta(seconds=secs)
        levels.append(((a_start - start).total_seconds(), (a_end - start).total_seconds(), level))
        meta = {"WOIntervalStepKeyPath": key}
        if success:
            meta["WOIntervalStepSuccessful"] = "1"
        if dist is not None and dist >= 50:
            meta["WOIntervalStepDistacnceGoalAchievedDuration"] = str(secs)
        act = {"kind": 46, "start": iso(a_start), "end": iso(a_end), "avg_hr": None, "metadata": meta}
        if dist is not None:
            act["distance_m"] = dist
        activities.append(act)
        if dist is not None and dist >= 50:
            laps = int(round(dist / 50))
            lap_len = secs / laps
            for i in range(laps):
                l_start = a_start + timedelta(seconds=round(i * lap_len))
                l_end = a_start + timedelta(seconds=round((i + 1) * lap_len))
                lap_secs = (l_end - l_start).total_seconds()
                swolf = round(lap_secs + strokes + (i % 2), 1)
                raw = style
                if key == "4.0.0" and i >= 2:
                    raw = "2"  # the last two cool-down lengths are freestyle
                events.append({"type": 3, "start": iso(l_start), "end": iso(l_end),
                               "metadata": {"HKSWOLFScore": str(swolf), "HKSwimmingStrokeStyle": raw}})
        t = a_end
    end = t
    events.insert(0, {"type": 7, "start": iso(start), "end": iso(start + timedelta(seconds=120)), "metadata": {}})

    def target(sec: float) -> float:
        for s0, s1, level in levels:
            if s0 <= sec < s1:
                # ramp in over the first 20 s of a step
                prev = next((lv for a, b, lv in levels if b == s0), level - 10)
                frac = min(1.0, (sec - s0) / 20.0)
                return prev + (level - prev) * frac
        return levels[-1][2]

    series = hr_series(start, end, target)
    in_window = [bpm for ts, bpm in series if start <= ts <= end]
    for act in activities:
        a0 = datetime.strptime(act["start"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        a1 = datetime.strptime(act["end"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        inside = [bpm for ts, bpm in series if a0 <= ts <= a1]
        act["avg_hr"] = round(sum(inside) / len(inside), 1) if inside else None
    doc = {
        "schema": "tide.workout.v0",
        "uuid": "5C0D9A7E-1B2C-4D3E-8F4A-6B7C8D9E0F11",
        "activity": 46,
        "activity_name": "PoolSwim",
        "source": "Apple Watch",
        "start": iso(start),
        "end": iso(end),
        "duration_s": (end - start).total_seconds(),
        "distance_m": 1200.0,
        "active_kcal": 412.0,
        "avg_hr": avg(in_window),
        "hr_samples": len(series),
        "hr_series": [[iso(ts), bpm] for ts, bpm in series],
        "zone_seconds": zone_seconds(series, start, end),
        "activities": activities,
        "events": events,
        "metadata": {
            "HKAverageMETs": "7.6 kcal/hr·kg",
            "HKIndoorWorkout": "0",
            "HKLapLength": "50 m",
            "HKSwimmingLocationType": "1",
            "HKTimeZone": "Europe/Berlin",
        },
    }
    write(HERE / "2026-10-21_1030_PoolSwim_5C0D9A7E.json", doc)


def row() -> None:
    start = datetime(2026, 9, 9, 6, 40, 0, tzinfo=timezone.utc)
    plan = [("0.0.0", 180, 98, True), ("1.0.0", 300, 128, True)]
    for block in range(2, 7):
        plan.append((f"{block}.0.0", 180, 134 + block, True))
        plan.append((f"{block}.0.1", 60, 117, True))
    plan.append(("7.0.0", 180, 108, False))
    activities, levels = [], []
    t = start
    for key, secs, level, success in plan:
        a_start, a_end = t, t + timedelta(seconds=secs)
        levels.append(((a_start - start).total_seconds(), (a_end - start).total_seconds(), level))
        meta = {"WOIntervalStepKeyPath": key}
        if success:
            meta["WOIntervalStepSuccessful"] = "1"
        activities.append({"kind": 35, "start": iso(a_start), "end": iso(a_end), "avg_hr": None, "metadata": meta})
        t = a_end
    end = t

    def target(sec: float) -> float:
        for s0, s1, level in levels:
            if s0 <= sec < s1:
                prev = next((lv for a, b, lv in levels if b == s0), level - 25)
                frac = min(1.0, (sec - s0) / 30.0)
                return prev + (level - prev) * frac
        return levels[-1][2]

    series = hr_series(start, end, target)
    in_window = [bpm for ts, bpm in series if start <= ts <= end]
    for act in activities:
        a0 = datetime.strptime(act["start"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        a1 = datetime.strptime(act["end"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        inside = [bpm for ts, bpm in series if a0 <= ts <= a1]
        act["avg_hr"] = round(sum(inside) / len(inside), 1) if inside else None
    doc = {
        "schema": "tide.workout.v0",
        "uuid": "9B4F2E61-3C5D-4E7F-A8B9-C0D1E2F3A4B5",
        "activity": 35,
        "activity_name": "IndoorRow",
        "source": "Apple Watch",
        "start": iso(start),
        "end": iso(end),
        "duration_s": (end - start).total_seconds(),
        "active_kcal": 296.0,
        "avg_hr": avg(in_window),
        "hr_samples": len(series),
        "hr_series": [[iso(ts), bpm] for ts, bpm in series],
        "zone_seconds": zone_seconds(series, start, end),
        "activities": activities,
        "events": [],
        "metadata": {
            "HKAverageMETs": "6.4 kcal/hr·kg",
            "HKIndoorWorkout": "1",
            "HKTimeZone": "Europe/Berlin",
            "HKWeatherHumidity": "6100 %",
            "HKWeatherTemperature": "58.4 degF",
        },
    }
    write(HERE / "2026-09-09_0840_IndoorRow_9B4F2E61.json", doc)


if __name__ == "__main__":
    swim()
    row()
