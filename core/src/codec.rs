//! Apple `.workout` codec (the file WorkoutKit imports when opened on the phone).
//!
//! Protobuf wire layout, reverse engineered and verified byte-for-byte against the
//! user's existing files (`core/tests/codec_roundtrip.rs`):
//!
//! ```text
//! root:  f9  string uuid (upper-case, 36 chars)
//!        f11 BODY
//!        f1000 varint 1, f1002 varint 5           (constant markers)
//! BODY:  f1 varint activity (46 pool swim / 35 indoor row)
//!        f2 varint location (HKWorkoutSessionLocationType: 2 indoor / 3 outdoor;
//!                            the existing pool swims use 3, rows use 2)
//!        f3 string name
//!        f4 STEP warm-up, f5 repeated BLOCK, f6 STEP cool-down
//! BLOCK: f1 repeated ITEM { f1 varint 1 work / 2 recovery, f2 STEP }, f2 varint repeat
//! STEP:  f1 GOAL, f2 ALERT?, f3 string label?
//! GOAL:  f1 varint 1 time / 3 distance, VALUE in f2 (time) or f4 (distance)
//! VALUE: f1 varint 1, f2 fixed64 double (seconds or metres)
//! ALERT: f1 varint 5, f2 varint 3, f7 { f1 { f1 varint zone } }
//! ```
//!
//! Encoding is canonical (fields in ascending order, minimal varints), which is
//! exactly how Apple's encoder writes them, hence the byte-identical round trip.

use crate::model::plan::{Goal, Plan, PlanBlock, PlanStep, SCHEMA_PLAN};
use crate::{Error, Result};

/// HKWorkoutActivityType.swimming.
pub const ACTIVITY_POOL_SWIM: u64 = 46;
/// HKWorkoutActivityType.rowing.
pub const ACTIVITY_INDOOR_ROW: u64 = 35;
/// HKWorkoutSessionLocationType.indoor.
pub const LOCATION_INDOOR: u64 = 2;
/// HKWorkoutSessionLocationType.outdoor.
pub const LOCATION_OUTDOOR: u64 = 3;
/// ITEM kind: work.
pub const ITEM_WORK: u64 = 1;
/// ITEM kind: recovery.
pub const ITEM_RECOVERY: u64 = 2;
/// GOAL kind: time (seconds).
pub const GOAL_TIME: u64 = 1;
/// GOAL kind: distance (metres).
pub const GOAL_DISTANCE: u64 = 3;

/// A decoded `.workout` file.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkoutFile {
    pub uuid: String,
    pub activity: u64,
    pub location: u64,
    pub name: String,
    pub warmup: Option<CodecStep>,
    pub blocks: Vec<CodecBlock>,
    pub cooldown: Option<CodecStep>,
    /// Root field 1000, always 1 in the wild.
    pub marker_1000: u64,
    /// Root field 1002, always 5 in the wild.
    pub marker_1002: u64,
}

/// A block of repeated items.
#[derive(Debug, Clone, PartialEq)]
pub struct CodecBlock {
    pub items: Vec<CodecItem>,
    pub repeat: u64,
}

/// One item: work or recovery step.
#[derive(Debug, Clone, PartialEq)]
pub struct CodecItem {
    pub kind: u64,
    pub step: CodecStep,
}

/// A step with goal, optional zone alert and optional label.
#[derive(Debug, Clone, PartialEq)]
pub struct CodecStep {
    pub goal: CodecGoal,
    pub alert: Option<CodecAlert>,
    pub label: Option<String>,
}

/// Step goal.
#[derive(Debug, Clone, PartialEq)]
pub struct CodecGoal {
    /// [`GOAL_TIME`] or [`GOAL_DISTANCE`].
    pub kind: u64,
    /// VALUE f1, always 1 in the wild.
    pub unit: u64,
    pub value: f64,
}

/// Heart-rate zone alert.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodecAlert {
    /// ALERT f1, always 5.
    pub a: u64,
    /// ALERT f2, always 3.
    pub b: u64,
    pub zone: u64,
}

impl CodecAlert {
    /// The alert for a zone.
    pub fn zone(zone: u64) -> Self {
        CodecAlert { a: 5, b: 3, zone }
    }
}

// ---------------------------------------------------------------- wire writer

fn put_varint(buf: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            buf.push(b);
            return;
        }
        buf.push(b | 0x80);
    }
}

fn put_tag(buf: &mut Vec<u8>, field: u32, wire_type: u8) {
    put_varint(buf, (u64::from(field) << 3) | u64::from(wire_type));
}

fn put_u(buf: &mut Vec<u8>, field: u32, v: u64) {
    put_tag(buf, field, 0);
    put_varint(buf, v);
}

fn put_f64(buf: &mut Vec<u8>, field: u32, v: f64) {
    put_tag(buf, field, 1);
    buf.extend_from_slice(&v.to_le_bytes());
}

fn put_bytes(buf: &mut Vec<u8>, field: u32, data: &[u8]) {
    put_tag(buf, field, 2);
    put_varint(buf, data.len() as u64);
    buf.extend_from_slice(data);
}

fn encode_value(unit: u64, value: f64) -> Vec<u8> {
    let mut b = Vec::with_capacity(11);
    put_u(&mut b, 1, unit);
    put_f64(&mut b, 2, value);
    b
}

fn encode_goal(g: &CodecGoal) -> Vec<u8> {
    let mut b = Vec::with_capacity(16);
    put_u(&mut b, 1, g.kind);
    let field = if g.kind == GOAL_DISTANCE { 4 } else { 2 };
    put_bytes(&mut b, field, &encode_value(g.unit, g.value));
    b
}

fn encode_alert(a: &CodecAlert) -> Vec<u8> {
    let mut inner2 = Vec::with_capacity(2);
    put_u(&mut inner2, 1, a.zone);
    let mut inner = Vec::with_capacity(4);
    put_bytes(&mut inner, 1, &inner2);
    let mut b = Vec::with_capacity(10);
    put_u(&mut b, 1, a.a);
    put_u(&mut b, 2, a.b);
    put_bytes(&mut b, 7, &inner);
    b
}

fn encode_step(s: &CodecStep) -> Vec<u8> {
    let mut b = Vec::with_capacity(64);
    put_bytes(&mut b, 1, &encode_goal(&s.goal));
    if let Some(a) = &s.alert {
        put_bytes(&mut b, 2, &encode_alert(a));
    }
    if let Some(l) = &s.label {
        put_bytes(&mut b, 3, l.as_bytes());
    }
    b
}

fn encode_block(block: &CodecBlock) -> Vec<u8> {
    let mut b = Vec::with_capacity(128);
    for item in &block.items {
        let mut ib = Vec::with_capacity(64);
        put_u(&mut ib, 1, item.kind);
        put_bytes(&mut ib, 2, &encode_step(&item.step));
        put_bytes(&mut b, 1, &ib);
    }
    put_u(&mut b, 2, block.repeat);
    b
}

/// Encode to the `.workout` byte format.
pub fn encode(w: &WorkoutFile) -> Vec<u8> {
    let mut body = Vec::with_capacity(512);
    put_u(&mut body, 1, w.activity);
    put_u(&mut body, 2, w.location);
    put_bytes(&mut body, 3, w.name.as_bytes());
    if let Some(s) = &w.warmup {
        put_bytes(&mut body, 4, &encode_step(s));
    }
    for block in &w.blocks {
        put_bytes(&mut body, 5, &encode_block(block));
    }
    if let Some(s) = &w.cooldown {
        put_bytes(&mut body, 6, &encode_step(s));
    }
    let mut out = Vec::with_capacity(body.len() + 48);
    put_bytes(&mut out, 9, w.uuid.as_bytes());
    put_bytes(&mut out, 11, &body);
    put_u(&mut out, 1000, w.marker_1000);
    put_u(&mut out, 1002, w.marker_1002);
    out
}

// ---------------------------------------------------------------- wire reader

#[derive(Debug)]
enum Field<'a> {
    Varint(u32, u64),
    Fixed64(u32, f64),
    Bytes(u32, &'a [u8]),
}

impl Field<'_> {
    fn number(&self) -> u32 {
        match self {
            Field::Varint(n, _) | Field::Fixed64(n, _) | Field::Bytes(n, _) => *n,
        }
    }
}

fn read_varint(data: &[u8], pos: &mut usize, what: &str) -> Result<u64> {
    let mut result = 0u64;
    let mut shift = 0u32;
    loop {
        let byte = *data
            .get(*pos)
            .ok_or_else(|| Error::Codec(format!("truncated varint in {what}")))?;
        *pos += 1;
        if shift >= 64 {
            return Err(Error::Codec(format!("varint overflow in {what}")));
        }
        result |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
        shift += 7;
    }
}

fn read_fields<'a>(data: &'a [u8], what: &str) -> Result<Vec<Field<'a>>> {
    let mut pos = 0usize;
    let mut out = Vec::new();
    while pos < data.len() {
        let tag = read_varint(data, &mut pos, what)?;
        let field = (tag >> 3) as u32;
        match tag & 7 {
            0 => out.push(Field::Varint(field, read_varint(data, &mut pos, what)?)),
            1 => {
                let end = pos + 8;
                let bytes = data
                    .get(pos..end)
                    .ok_or_else(|| Error::Codec(format!("truncated fixed64 in {what}")))?;
                let mut arr = [0u8; 8];
                arr.copy_from_slice(bytes);
                out.push(Field::Fixed64(field, f64::from_le_bytes(arr)));
                pos = end;
            }
            2 => {
                let len = read_varint(data, &mut pos, what)? as usize;
                let end = pos
                    .checked_add(len)
                    .filter(|e| *e <= data.len())
                    .ok_or_else(|| {
                        Error::Codec(format!("truncated bytes field {field} in {what}"))
                    })?;
                out.push(Field::Bytes(field, &data[pos..end]));
                pos = end;
            }
            wt => {
                return Err(Error::Codec(format!(
                    "unsupported wire type {wt} (field {field}) in {what}"
                )))
            }
        }
    }
    Ok(out)
}

fn unexpected(f: &Field<'_>, what: &str) -> Error {
    Error::Codec(format!("unexpected field {} ({f:?}) in {what}", f.number()))
}

fn utf8(bytes: &[u8], what: &str) -> Result<String> {
    String::from_utf8(bytes.to_vec()).map_err(|_| Error::Codec(format!("{what} is not UTF-8")))
}

fn decode_value(data: &[u8]) -> Result<(u64, f64)> {
    let mut unit = None;
    let mut value = None;
    for f in read_fields(data, "VALUE")? {
        match f {
            Field::Varint(1, v) => unit = Some(v),
            Field::Fixed64(2, v) => value = Some(v),
            other => return Err(unexpected(&other, "VALUE")),
        }
    }
    Ok((
        unit.ok_or_else(|| Error::Codec("VALUE without unit".into()))?,
        value.ok_or_else(|| Error::Codec("VALUE without number".into()))?,
    ))
}

fn decode_goal(data: &[u8]) -> Result<CodecGoal> {
    let mut kind = None;
    let mut value = None;
    for f in read_fields(data, "GOAL")? {
        match f {
            Field::Varint(1, v) => kind = Some(v),
            Field::Bytes(2, b) => value = Some((2u32, decode_value(b)?)),
            Field::Bytes(4, b) => value = Some((4u32, decode_value(b)?)),
            other => return Err(unexpected(&other, "GOAL")),
        }
    }
    let kind = kind.ok_or_else(|| Error::Codec("GOAL without kind".into()))?;
    let (field, (unit, value)) = value.ok_or_else(|| Error::Codec("GOAL without VALUE".into()))?;
    let expected = if kind == GOAL_DISTANCE { 4 } else { 2 };
    if field != expected {
        return Err(Error::Codec(format!(
            "GOAL kind {kind} carries VALUE in field {field}, expected {expected}"
        )));
    }
    Ok(CodecGoal { kind, unit, value })
}

fn decode_alert(data: &[u8]) -> Result<CodecAlert> {
    let (mut a, mut b, mut zone) = (None, None, None);
    for f in read_fields(data, "ALERT")? {
        match f {
            Field::Varint(1, v) => a = Some(v),
            Field::Varint(2, v) => b = Some(v),
            Field::Bytes(7, inner) => {
                for g in read_fields(inner, "ALERT.f7")? {
                    match g {
                        Field::Bytes(1, inner2) => {
                            for h in read_fields(inner2, "ALERT.f7.f1")? {
                                match h {
                                    Field::Varint(1, z) => zone = Some(z),
                                    other => return Err(unexpected(&other, "ALERT.f7.f1")),
                                }
                            }
                        }
                        other => return Err(unexpected(&other, "ALERT.f7")),
                    }
                }
            }
            other => return Err(unexpected(&other, "ALERT")),
        }
    }
    Ok(CodecAlert {
        a: a.ok_or_else(|| Error::Codec("ALERT without f1".into()))?,
        b: b.ok_or_else(|| Error::Codec("ALERT without f2".into()))?,
        zone: zone.ok_or_else(|| Error::Codec("ALERT without zone".into()))?,
    })
}

fn decode_step(data: &[u8]) -> Result<CodecStep> {
    let mut goal = None;
    let mut alert = None;
    let mut label = None;
    for f in read_fields(data, "STEP")? {
        match f {
            Field::Bytes(1, b) => goal = Some(decode_goal(b)?),
            Field::Bytes(2, b) => alert = Some(decode_alert(b)?),
            Field::Bytes(3, b) => label = Some(utf8(b, "STEP label")?),
            other => return Err(unexpected(&other, "STEP")),
        }
    }
    Ok(CodecStep {
        goal: goal.ok_or_else(|| Error::Codec("STEP without GOAL".into()))?,
        alert,
        label,
    })
}

fn decode_block(data: &[u8]) -> Result<CodecBlock> {
    let mut items = Vec::new();
    let mut repeat = None;
    for f in read_fields(data, "BLOCK")? {
        match f {
            Field::Bytes(1, b) => {
                let mut kind = None;
                let mut step = None;
                for g in read_fields(b, "ITEM")? {
                    match g {
                        Field::Varint(1, v) => kind = Some(v),
                        Field::Bytes(2, s) => step = Some(decode_step(s)?),
                        other => return Err(unexpected(&other, "ITEM")),
                    }
                }
                items.push(CodecItem {
                    kind: kind.ok_or_else(|| Error::Codec("ITEM without kind".into()))?,
                    step: step.ok_or_else(|| Error::Codec("ITEM without STEP".into()))?,
                });
            }
            Field::Varint(2, v) => repeat = Some(v),
            other => return Err(unexpected(&other, "BLOCK")),
        }
    }
    Ok(CodecBlock {
        items,
        repeat: repeat.ok_or_else(|| Error::Codec("BLOCK without repeat".into()))?,
    })
}

/// Decode a `.workout` file. Anything outside the documented layout is an error,
/// so the round-trip test doubles as a layout check.
pub fn decode(data: &[u8]) -> Result<WorkoutFile> {
    let mut uuid = None;
    let mut body = None;
    let mut m1000 = None;
    let mut m1002 = None;
    for f in read_fields(data, "root")? {
        match f {
            Field::Bytes(9, b) => uuid = Some(utf8(b, "uuid")?),
            Field::Bytes(11, b) => body = Some(b),
            Field::Varint(1000, v) => m1000 = Some(v),
            Field::Varint(1002, v) => m1002 = Some(v),
            other => return Err(unexpected(&other, "root")),
        }
    }
    let body = body.ok_or_else(|| Error::Codec("no BODY (field 11)".into()))?;
    let (mut activity, mut location, mut name) = (None, None, None);
    let (mut warmup, mut cooldown) = (None, None);
    let mut blocks = Vec::new();
    for f in read_fields(body, "BODY")? {
        match f {
            Field::Varint(1, v) => activity = Some(v),
            Field::Varint(2, v) => location = Some(v),
            Field::Bytes(3, b) => name = Some(utf8(b, "name")?),
            Field::Bytes(4, b) => warmup = Some(decode_step(b)?),
            Field::Bytes(5, b) => blocks.push(decode_block(b)?),
            Field::Bytes(6, b) => cooldown = Some(decode_step(b)?),
            other => return Err(unexpected(&other, "BODY")),
        }
    }
    Ok(WorkoutFile {
        uuid: uuid.ok_or_else(|| Error::Codec("no uuid (field 9)".into()))?,
        activity: activity.ok_or_else(|| Error::Codec("BODY without activity".into()))?,
        location: location.ok_or_else(|| Error::Codec("BODY without location".into()))?,
        name: name.ok_or_else(|| Error::Codec("BODY without name".into()))?,
        warmup,
        blocks,
        cooldown,
        marker_1000: m1000.ok_or_else(|| Error::Codec("no field 1000".into()))?,
        marker_1002: m1002.ok_or_else(|| Error::Codec("no field 1002".into()))?,
    })
}

// ---------------------------------------------------------------- plan bridge

fn step_from_plan(s: &PlanStep) -> CodecStep {
    CodecStep {
        goal: CodecGoal {
            kind: if s.goal.is_time() {
                GOAL_TIME
            } else {
                GOAL_DISTANCE
            },
            unit: 1,
            value: s.goal.value,
        },
        alert: s.zone.map(|z| CodecAlert::zone(u64::from(z))),
        label: s.label.clone(),
    }
}

fn step_to_plan(s: &CodecStep, kind: Option<&str>) -> PlanStep {
    PlanStep {
        kind: kind.map(str::to_string),
        goal: if s.goal.kind == GOAL_DISTANCE {
            Goal::distance(s.goal.value)
        } else {
            Goal::time(s.goal.value)
        },
        zone: s.alert.as_ref().map(|a| a.zone.min(255) as u8),
        label: s.label.clone(),
    }
}

/// A fresh upper-case UUID v4 as Apple writes it.
pub fn new_uuid() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

impl WorkoutFile {
    /// Build a `.workout` from a plan after validating it. `uuid` defaults to a fresh v4.
    pub fn from_plan(plan: &Plan, uuid: Option<String>) -> Result<Self> {
        plan.validate()?;
        Self::from_plan_unchecked(plan, uuid)
    }

    /// Build a `.workout` without running the plan validator (the Watch itself
    /// accepts e.g. labels longer than 40 chars; two of the user's historical files
    /// have one). Only an unknown sport can fail.
    pub fn from_plan_unchecked(plan: &Plan, uuid: Option<String>) -> Result<Self> {
        let (activity, location) = match plan.sport.as_str() {
            "pool_swim" => (ACTIVITY_POOL_SWIM, LOCATION_OUTDOOR),
            "indoor_row" => (ACTIVITY_INDOOR_ROW, LOCATION_INDOOR),
            other => return Err(Error::Codec(format!("unsupported sport {other}"))),
        };
        Ok(WorkoutFile {
            uuid: uuid.unwrap_or_else(new_uuid),
            activity,
            location,
            name: plan.name.clone(),
            warmup: plan.warmup.as_ref().map(step_from_plan),
            blocks: plan
                .blocks
                .iter()
                .map(|b| CodecBlock {
                    items: b
                        .steps
                        .iter()
                        .map(|s| CodecItem {
                            kind: if s.is_recovery() {
                                ITEM_RECOVERY
                            } else {
                                ITEM_WORK
                            },
                            step: step_from_plan(s),
                        })
                        .collect(),
                    repeat: u64::from(b.repeat),
                })
                .collect(),
            cooldown: plan.cooldown.as_ref().map(step_from_plan),
            marker_1000: 1,
            marker_1002: 5,
        })
    }

    /// Convert back into a plan (no id / timestamps; `schema` set).
    pub fn to_plan(&self) -> Result<Plan> {
        let sport = match self.activity {
            ACTIVITY_POOL_SWIM => "pool_swim",
            ACTIVITY_INDOOR_ROW => "indoor_row",
            other => return Err(Error::Codec(format!("unsupported activity {other}"))),
        };
        Ok(Plan {
            schema: SCHEMA_PLAN.to_string(),
            id: String::new(),
            name: self.name.clone(),
            sport: sport.to_string(),
            pool_length_m: None,
            warmup: self.warmup.as_ref().map(|s| step_to_plan(s, None)),
            blocks: self
                .blocks
                .iter()
                .map(|b| PlanBlock {
                    repeat: b.repeat.min(u64::from(u32::MAX)) as u32,
                    steps: b
                        .items
                        .iter()
                        .map(|i| {
                            step_to_plan(
                                &i.step,
                                Some(if i.kind == ITEM_RECOVERY {
                                    "recovery"
                                } else {
                                    "work"
                                }),
                            )
                        })
                        .collect(),
                })
                .collect(),
            cooldown: self.cooldown.as_ref().map(|s| step_to_plan(s, None)),
            notes: None,
            created_by: None,
            created_at: None,
            scheduled_for: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn varints_are_minimal() {
        let mut b = Vec::new();
        put_varint(&mut b, 300);
        assert_eq!(b, vec![0xac, 0x02]);
        let mut b = Vec::new();
        put_tag(&mut b, 1000, 0);
        assert_eq!(b, vec![0xc0, 0x3e]);
        let mut pos = 0;
        assert_eq!(read_varint(&[0xac, 0x02], &mut pos, "t").unwrap(), 300);
    }

    #[test]
    fn synthetic_round_trip() {
        let w = WorkoutFile {
            uuid: "5C1B728E-71F7-4389-BB33-95EE23BEA5A9".into(),
            activity: ACTIVITY_INDOOR_ROW,
            location: LOCATION_INDOOR,
            name: "RW0".into(),
            warmup: Some(CodecStep {
                goal: CodecGoal {
                    kind: GOAL_TIME,
                    unit: 1,
                    value: 180.0,
                },
                alert: Some(CodecAlert::zone(1)),
                label: None,
            }),
            blocks: vec![CodecBlock {
                items: vec![
                    CodecItem {
                        kind: ITEM_WORK,
                        step: CodecStep {
                            goal: CodecGoal {
                                kind: GOAL_DISTANCE,
                                unit: 1,
                                value: 500.0,
                            },
                            alert: Some(CodecAlert::zone(3)),
                            label: Some("Hard, ümlaut ok".into()),
                        },
                    },
                    CodecItem {
                        kind: ITEM_RECOVERY,
                        step: CodecStep {
                            goal: CodecGoal {
                                kind: GOAL_TIME,
                                unit: 1,
                                value: 60.0,
                            },
                            alert: None,
                            label: None,
                        },
                    },
                ],
                repeat: 4,
            }],
            cooldown: None,
            marker_1000: 1,
            marker_1002: 5,
        };
        let bytes = encode(&w);
        assert!(bytes.starts_with(&[0x4a, 0x24]));
        let back = decode(&bytes).unwrap();
        assert_eq!(back, w);
        assert_eq!(encode(&back), bytes);
    }

    #[test]
    fn plan_bridge_round_trips() {
        let plan: Plan = serde_json::from_value(serde_json::json!({
            "name": "S30", "sport": "pool_swim",
            "warmup": {"goal": {"type": "time_s", "value": 120}, "zone": 1},
            "blocks": [{"repeat": 2, "steps": [
                {"kind": "work", "goal": {"type": "distance_m", "value": 100}, "zone": 3, "label": "steady"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 30}}
            ]}],
            "cooldown": {"goal": {"type": "distance_m", "value": 100}, "zone": 1}
        }))
        .unwrap();
        let file =
            WorkoutFile::from_plan(&plan, Some("00000000-0000-4000-8000-000000000000".into()))
                .unwrap();
        assert_eq!(file.activity, ACTIVITY_POOL_SWIM);
        assert_eq!(file.location, LOCATION_OUTDOOR);
        let decoded = decode(&encode(&file)).unwrap();
        let back = decoded.to_plan().unwrap();
        assert_eq!(back.name, "S30");
        assert_eq!(back.blocks[0].steps[0].label.as_deref(), Some("steady"));
        assert_eq!(back.blocks[0].steps[1].kind.as_deref(), Some("recovery"));
        assert_eq!(back.cooldown.unwrap().goal.value, 100.0);
    }

    #[test]
    fn rejects_garbage() {
        assert!(decode(&[0x4a, 0x24, 0x00]).is_err());
        assert!(decode(&[0x0d, 1, 2, 3, 4]).is_err()); // field 1 fixed32: unsupported wire type
    }
}
