//! Byte-identical round trip of every real `.workout` file. Set
//! `HEALTHACCESS_WORKOUT_FILES_DIR` (alias: the pre-rename `TIDE_WORKOUT_FILES_DIR`) to
//! the folder holding them (sub-folders are included); the test is skipped when the
//! variable is unset or the folder is missing.

use std::path::{Path, PathBuf};

use healthaccess_core::codec::{
    decode, encode, WorkoutFile, ACTIVITY_INDOOR_ROW, ACTIVITY_POOL_SWIM,
};

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in rd.flatten() {
        let p = entry.path();
        if p.is_dir() {
            collect(&p, out);
        } else if p.extension().map(|e| e == "workout").unwrap_or(false) {
            out.push(p);
        }
    }
}

#[test]
fn every_real_workout_file_round_trips_byte_for_byte() {
    let dir = std::env::var_os("HEALTHACCESS_WORKOUT_FILES_DIR")
        .or_else(|| std::env::var_os("TIDE_WORKOUT_FILES_DIR")); // alias
    let Some(dir) = dir else {
        eprintln!("HEALTHACCESS_WORKOUT_FILES_DIR not set; skipping real-file round trip");
        return;
    };
    let dir = PathBuf::from(dir);
    if !dir.is_dir() {
        eprintln!("{} missing; skipping", dir.display());
        return;
    }
    let mut files = Vec::new();
    collect(&dir, &mut files);
    files.sort();
    assert!(
        !files.is_empty(),
        "no .workout files under {}",
        dir.display()
    );
    let mut failures = Vec::new();
    let mut swims = 0;
    let mut rows = 0;
    for path in &files {
        let bytes = std::fs::read(path).unwrap();
        match decode(&bytes) {
            Ok(file) => {
                match file.activity {
                    ACTIVITY_POOL_SWIM => swims += 1,
                    ACTIVITY_INDOOR_ROW => rows += 1,
                    _ => {}
                }
                let again = encode(&file);
                if again != bytes {
                    failures.push(format!(
                        "{}: re-encoded {} bytes vs {} original",
                        path.display(),
                        again.len(),
                        bytes.len()
                    ));
                }
                // the plan bridge must be lossless too: decode → plan → from_plan → encode
                let plan = file.to_plan().unwrap();
                assert_eq!(plan.blocks.len(), file.blocks.len());
                assert_eq!(plan.warmup.is_some(), file.warmup.is_some());
                let rebuilt =
                    WorkoutFile::from_plan_unchecked(&plan, Some(file.uuid.clone())).unwrap();
                if encode(&rebuilt) != bytes {
                    failures.push(format!("{}: plan bridge changed the bytes", path.display()));
                }
            }
            Err(e) => failures.push(format!("{}: {e}", path.display())),
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} files failed:\n{}",
        failures.len(),
        files.len(),
        failures.join("\n")
    );
    eprintln!(
        "round-tripped {} .workout files byte-for-byte ({swims} swims, {rows} rows)",
        files.len()
    );
}
