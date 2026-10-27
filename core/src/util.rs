//! Small helpers: atomic writes, sorted JSON, slugs, float rounding, lenient serde.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::de::Deserializer;
use serde::Deserialize;
use serde_json::Value;

use crate::{Error, Result};

/// Largest file the library reads (workouts with long heart-rate series stay far below).
pub const MAX_READ_BYTES: u64 = 64 * 1024 * 1024;

/// `true` for one plain file name: no path separators, no `..`, no leading dot, no
/// control characters, no drive prefix. Ids and file names that reach a path go through this.
pub fn is_plain_name(s: &str) -> bool {
    use std::path::Component;
    if s.is_empty()
        || s.len() > 255
        || s.starts_with('.')
        || s.contains(['/', '\\', '\0'])
        || s.chars().any(char::is_control)
    {
        return false;
    }
    let mut parts = Path::new(s).components();
    matches!((parts.next(), parts.next()), (Some(Component::Normal(_)), None))
}

/// Write `bytes` to `path` atomically: write a fresh sibling temp file (random name,
/// created exclusively, so a planted symlink is never followed), fsync, keep the target's
/// permissions, rename.
pub fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let file_name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_string());
    let tmp = dir.join(format!(
        ".{file_name}.tmp-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4().simple()
    ));
    let write = || -> std::io::Result<()> {
        use std::io::Write;
        let mut f = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        if let Ok(meta) = fs::metadata(path) {
            fs::set_permissions(&tmp, meta.permissions())?;
        }
        Ok(())
    };
    if let Err(e) = write() {
        let _ = fs::remove_file(&tmp);
        return Err(Error::io(&tmp, e));
    }
    fs::rename(&tmp, path).map_err(|e| {
        let _ = fs::remove_file(&tmp);
        Error::io(path, e)
    })
}

/// Read a whole file into a string with a path-carrying error. Only regular files are
/// read (no symlinks, FIFOs or devices) and only up to [`MAX_READ_BYTES`].
pub fn read_to_string(path: &Path) -> Result<String> {
    use std::io::{Error as IoError, ErrorKind, Read};
    let meta = fs::symlink_metadata(path).map_err(|e| Error::io(path, e))?;
    if !meta.is_file() {
        return Err(Error::io(
            path,
            IoError::new(ErrorKind::InvalidInput, "not a regular file"),
        ));
    }
    let too_big = || Error::io(path, IoError::new(ErrorKind::InvalidData, "file too large"));
    if meta.len() > MAX_READ_BYTES {
        return Err(too_big());
    }
    let mut text = String::new();
    fs::File::open(path)
        .and_then(|f| f.take(MAX_READ_BYTES + 1).read_to_string(&mut text))
        .map_err(|e| Error::io(path, e))?;
    if text.len() as u64 > MAX_READ_BYTES {
        return Err(too_big());
    }
    Ok(text)
}

/// Parse a JSON file into `T` with a path-carrying error.
pub fn read_json<T: serde::de::DeserializeOwned>(path: &Path) -> Result<T> {
    let text = read_to_string(path)?;
    serde_json::from_str(&text).map_err(|e| Error::json(path, e))
}

/// Serialize `value` as pretty JSON with sorted keys (the data contract requires
/// sorted keys; `serde_json::Map` is a `BTreeMap`, so a `Value` round trip sorts).
pub fn to_sorted_pretty_json<T: serde::Serialize>(value: &T) -> Result<String> {
    let v = serde_json::to_value(value).map_err(|e| Error::json("<memory>", e))?;
    let mut s = serde_json::to_string_pretty(&v).map_err(|e| Error::json("<memory>", e))?;
    s.push('\n');
    Ok(s)
}

/// Serialize `value` as compact JSON with sorted keys.
pub fn to_sorted_json<T: serde::Serialize>(value: &T) -> Result<String> {
    let v = serde_json::to_value(value).map_err(|e| Error::json("<memory>", e))?;
    serde_json::to_string(&v).map_err(|e| Error::json("<memory>", e))
}

/// `true` when a JSON document looks pretty-printed (a newline inside the first 64 bytes).
pub fn looks_pretty(json: &str) -> bool {
    json.chars().take(64).any(|c| c == '\n')
}

/// Lower-case URL-ish slug: `a-z0-9` runs separated by single dashes.
pub fn slug(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut dash = false;
    for c in input.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            dash = false;
        } else if !dash && !out.is_empty() {
            out.push('-');
            dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() {
        "plan".to_string()
    } else {
        out
    }
}

/// Round to `decimals` places.
pub fn round_to(value: f64, decimals: i32) -> f64 {
    let f = 10f64.powi(decimals);
    (value * f).round() / f
}

/// Recursively round every float in a JSON value to `decimals` places, turning
/// whole numbers into integers. Used to keep tool output compact for an LLM.
pub fn round_floats(value: &mut Value, decimals: i32) {
    match value {
        Value::Number(n) => {
            if let Some(f) = n.as_f64() {
                if n.is_f64() {
                    let r = round_to(f, decimals);
                    *value = if r.fract() == 0.0 && r.abs() < 9.0e15 {
                        Value::from(r as i64)
                    } else {
                        serde_json::Number::from_f64(r)
                            .map(Value::Number)
                            .unwrap_or(Value::Null)
                    };
                }
            }
        }
        Value::Array(items) => items.iter_mut().for_each(|v| round_floats(v, decimals)),
        Value::Object(map) => map.values_mut().for_each(|v| round_floats(v, decimals)),
        _ => {}
    }
}

/// Deserialize a JSON object of arbitrary values into a string map (HealthKit
/// metadata arrives "stringified" but we stay lenient about numbers/bools).
pub fn string_map<'de, D: Deserializer<'de>>(
    d: D,
) -> std::result::Result<BTreeMap<String, String>, D::Error> {
    let raw: Option<BTreeMap<String, Value>> = Option::deserialize(d)?;
    Ok(raw
        .unwrap_or_default()
        .into_iter()
        .map(|(k, v)| {
            let s = match v {
                Value::String(s) => s,
                Value::Null => String::new(),
                other => other.to_string(),
            };
            (k, s)
        })
        .collect())
}

/// Deserialize an optional 1-to-10 score leniently: integers, floats (Apple's
/// effort scores are doubles in HealthKit) and numeric strings all round to the
/// nearest whole number; `null` or a missing key is `None`; anything else is an error.
pub fn opt_score<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Option<u8>, D::Error> {
    let raw: Option<Value> = Option::deserialize(d)?;
    let Some(raw) = raw else { return Ok(None) };
    let n = match &raw {
        Value::Null => return Ok(None),
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    };
    match n {
        Some(f) if f.is_finite() && (0.0..=255.0).contains(&f.round()) => Ok(Some(f.round() as u8)),
        _ => Err(serde::de::Error::custom(format!(
            "expected a number between 0 and 255 for a score, got {raw}"
        ))),
    }
}

/// Format seconds as `m:ss` or `h:mm:ss`.
pub fn fmt_duration(secs: f64) -> String {
    let total = secs.round().max(0.0) as u64;
    let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60);
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

/// Format a pace in seconds per 100 m as `m:ss`.
pub fn fmt_pace(secs_per_100m: f64) -> String {
    fmt_duration(secs_per_100m)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_basics() {
        assert_eq!(slug("S26"), "s26");
        assert_eq!(slug("  Easy  Aerobic / Drill #2 "), "easy-aerobic-drill-2");
        assert_eq!(slug("***"), "plan");
    }

    #[test]
    fn rounding_turns_whole_floats_into_ints() {
        let mut v = serde_json::json!({"a": 81.0, "b": 2166.41730098214, "c": [1.25, 3.0], "d": 7});
        round_floats(&mut v, 1);
        assert_eq!(
            v,
            serde_json::json!({"a": 81, "b": 2166.4, "c": [1.3, 3], "d": 7})
        );
    }

    #[test]
    fn scores_accept_ints_floats_and_strings() {
        #[derive(Deserialize)]
        struct S {
            #[serde(default, deserialize_with = "opt_score")]
            effort: Option<u8>,
        }
        let f = |j: &str| serde_json::from_str::<S>(j).map(|s| s.effort);
        assert_eq!(f(r#"{"effort": 7}"#).unwrap(), Some(7));
        assert_eq!(f(r#"{"effort": 6.6}"#).unwrap(), Some(7));
        assert_eq!(f(r#"{"effort": "4"}"#).unwrap(), Some(4));
        assert_eq!(f(r#"{"effort": null}"#).unwrap(), None);
        assert_eq!(f(r#"{}"#).unwrap(), None);
        assert!(f(r#"{"effort": "hard"}"#).is_err());
        assert!(f(r#"{"effort": -1}"#).is_err());
    }

    #[test]
    fn durations() {
        assert_eq!(fmt_duration(2166.4), "36:06");
        assert_eq!(fmt_duration(5163.0), "1:26:03");
        assert_eq!(fmt_duration(48.0), "0:48");
    }
}
