//! Finding the Health Access folder when nobody said where it is.
//!
//! The app writes an `index.json` with the schema `healthaccess.index.v1` (or the
//! pre-rename `tide.index.v1`) next to a `workouts/` directory. Discovery walks the
//! places a phone folder syncs to on a computer, in stages, and stops at the first
//! stage that finds one, so a Dropbox or Google Drive mount is only touched when
//! iCloud Drive has nothing:
//!
//! 1. iCloud Drive (`~/Library/Mobile Documents/com~apple~CloudDocs` on a Mac,
//!    `%USERPROFILE%\iCloudDrive` on Windows).
//! 2. The other file providers (`~/Library/CloudStorage/*` on a Mac, `~/Dropbox`,
//!    `~/Google Drive`, `~/OneDrive*`, `~/Box`).
//! 3. `~/Documents`.
//!
//! The walk skips hidden directories, bundles (`*.app`, `*.photoslibrary`, …) and
//! build folders, goes at most [`Limits::max_depth`] levels deep and visits at most
//! [`Limits::max_dirs`] directories per stage. When several folders qualify, the one
//! whose `index.json` changed last wins; the others are reported.

use std::collections::{HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

/// Bounds of one stage of the walk.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Levels below a root (the root is level 0).
    pub max_depth: usize,
    /// Directories visited per stage.
    pub max_dirs: usize,
    /// Wall-clock budget per stage.
    pub max_time: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_depth: 8,
            max_dirs: 40_000,
            max_time: Duration::from_secs(4),
        }
    }
}

/// One Health Access folder found on disk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    /// The folder (the directory holding `index.json`).
    pub dir: PathBuf,
    /// When its `index.json` last changed.
    pub modified: SystemTime,
}

/// What a discovery run saw.
#[derive(Debug, Clone, Default)]
pub struct Discovery {
    /// Every folder found in the first stage that found any, newest first.
    pub found: Vec<Found>,
    /// The roots that were searched, in order.
    pub searched: Vec<PathBuf>,
}

impl Discovery {
    /// The newest folder found. Callers use it only when it is the only one (see
    /// [`crate::config::resolve_dir_with_source`]).
    pub fn best(&self) -> Option<&Found> {
        self.found.first()
    }
}

/// The search stages for this machine, each a list of roots that exist.
pub fn stages() -> Vec<Vec<PathBuf>> {
    let Some(home) = dirs::home_dir() else {
        return Vec::new();
    };
    let mut icloud = vec![
        home.join("Library")
            .join("Mobile Documents")
            .join("com~apple~CloudDocs"),
        home.join("iCloudDrive"),
    ];
    icloud.retain(|p| p.is_dir());

    let mut providers = Vec::new();
    if let Ok(entries) = std::fs::read_dir(home.join("Library").join("CloudStorage")) {
        let mut mounts: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .collect();
        mounts.sort();
        providers.extend(mounts);
    }
    if let Ok(entries) = std::fs::read_dir(&home) {
        let mut legacy: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.is_dir()
                    && p.file_name().and_then(|n| n.to_str()).is_some_and(|n| {
                        n == "Dropbox"
                            || n == "Google Drive"
                            || n == "Box"
                            || n.starts_with("OneDrive")
                    })
            })
            .collect();
        legacy.sort();
        providers.extend(legacy);
    }

    let mut documents = vec![home.join("Documents")];
    documents.retain(|p| p.is_dir());

    vec![icloud, providers, documents]
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect()
}

/// Run the staged search on this machine.
pub fn discover() -> Discovery {
    discover_in(&stages(), Limits::default())
}

/// Run the staged search over the given stages (testable core of [`discover`]).
pub fn discover_in(stages: &[Vec<PathBuf>], limits: Limits) -> Discovery {
    let mut out = Discovery::default();
    for roots in stages {
        out.searched.extend(roots.iter().cloned());
        let mut found = Vec::new();
        for root in roots {
            walk(root, limits, &mut found);
        }
        if !found.is_empty() {
            found.sort_by(|a: &Found, b: &Found| {
                b.modified.cmp(&a.modified).then(a.dir.cmp(&b.dir))
            });
            found.dedup_by(|a, b| a.dir == b.dir);
            out.found = found;
            break;
        }
    }
    out
}

fn walk(root: &Path, limits: Limits, found: &mut Vec<Found>) {
    let started = Instant::now();
    let mut visited = 0usize;
    // Canonical paths already walked: iCloud Drive links `Documents` and `Desktop` to the
    // home folders, so symlinks are followed, and this set keeps a loop from repeating.
    let mut seen: HashSet<PathBuf> = HashSet::new();
    let mut queue = VecDeque::from([(root.to_path_buf(), 0usize)]);
    while let Some((dir, depth)) = queue.pop_front() {
        let canonical = std::fs::canonicalize(&dir).unwrap_or_else(|_| dir.clone());
        if !seen.insert(canonical) {
            continue;
        }
        visited += 1;
        if visited > limits.max_dirs || started.elapsed() > limits.max_time {
            break;
        }
        if let Some(hit) = check(&dir) {
            found.push(hit);
            continue; // a Health Access folder never contains another one
        }
        if depth >= limits.max_depth {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        let mut children: Vec<PathBuf> = entries
            .flatten()
            .filter(|e| {
                e.file_type()
                    .is_ok_and(|t| t.is_dir() || (t.is_symlink() && e.path().is_dir()))
            })
            .map(|e| e.path())
            .filter(|p| !skip(p))
            .collect();
        children.sort();
        queue.extend(children.into_iter().map(|c| (c, depth + 1)));
    }
}

/// Directories never worth entering.
fn skip(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
        return true;
    };
    if name.starts_with('.') {
        return true;
    }
    const NAMES: [&str; 6] = [
        "node_modules",
        "target",
        "build",
        "Library",
        "Applications",
        "__pycache__",
    ];
    if NAMES.contains(&name) {
        return true;
    }
    const BUNDLES: [&str; 10] = [
        ".app",
        ".photoslibrary",
        ".musiclibrary",
        ".tvlibrary",
        ".bundle",
        ".framework",
        ".xcodeproj",
        ".xcworkspace",
        ".pkg",
        ".fcpbundle",
    ];
    BUNDLES.iter().any(|ext| name.ends_with(ext))
}

/// `dir` is a Health Access folder when it holds an `index.json` with the index schema
/// and a `workouts/` directory.
fn check(dir: &Path) -> Option<Found> {
    let index = dir.join("index.json");
    let meta = std::fs::metadata(&index).ok()?;
    if !meta.is_file() || !dir.join("workouts").is_dir() {
        return None;
    }
    let text = crate::util::read_to_string(&index).ok()?;
    let schema_ok = [
        crate::model::index::SCHEMA_INDEX,
        crate::model::index::SCHEMA_INDEX_LEGACY,
    ]
    .iter()
    .any(|s| text.contains(&format!("\"{s}\"")));
    if !schema_ok {
        return None;
    }
    Some(Found {
        dir: dir.to_path_buf(),
        modified: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn make_folder(path: &Path, schema: &str) {
        fs::create_dir_all(path.join("workouts")).unwrap();
        fs::write(
            path.join("index.json"),
            format!("{{\"schema\":\"{schema}\",\"workouts\":[]}}"),
        )
        .unwrap();
    }

    fn quick() -> Limits {
        Limits {
            max_depth: 8,
            max_dirs: 10_000,
            max_time: Duration::from_secs(5),
        }
    }

    #[test]
    fn finds_a_nested_folder() {
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("Documents/Health/Apple_Health_Exports");
        make_folder(&target, "healthaccess.index.v1");
        let d = discover_in(&[vec![tmp.path().to_path_buf()]], quick());
        assert_eq!(d.best().map(|f| f.dir.clone()), Some(target));
    }

    #[test]
    fn accepts_the_legacy_schema_and_ignores_other_index_files() {
        let tmp = tempfile::tempdir().unwrap();
        make_folder(&tmp.path().join("old"), "tide.index.v1");
        make_folder(&tmp.path().join("other"), "something.else.v1");
        let d = discover_in(&[vec![tmp.path().to_path_buf()]], quick());
        assert_eq!(d.found.len(), 1);
        assert!(d.found[0].dir.ends_with("old"));
    }

    #[test]
    fn newest_index_wins() {
        let tmp = tempfile::tempdir().unwrap();
        let a = tmp.path().join("a");
        let b = tmp.path().join("b");
        make_folder(&a, "healthaccess.index.v1");
        std::thread::sleep(Duration::from_millis(1100));
        make_folder(&b, "healthaccess.index.v1");
        let d = discover_in(&[vec![tmp.path().to_path_buf()]], quick());
        assert_eq!(d.found.len(), 2);
        assert!(d.found[0].dir.ends_with("b"));
    }

    #[test]
    fn skips_hidden_and_bundle_directories_and_respects_depth() {
        let tmp = tempfile::tempdir().unwrap();
        make_folder(&tmp.path().join(".hidden/x"), "healthaccess.index.v1");
        make_folder(
            &tmp.path().join("Photos Library.photoslibrary/x"),
            "healthaccess.index.v1",
        );
        make_folder(&tmp.path().join("1/2/3/4"), "healthaccess.index.v1");
        let shallow = Limits {
            max_depth: 3,
            ..quick()
        };
        assert!(discover_in(&[vec![tmp.path().to_path_buf()]], shallow)
            .found
            .is_empty());
        assert_eq!(
            discover_in(&[vec![tmp.path().to_path_buf()]], quick())
                .found
                .len(),
            1
        );
    }

    #[cfg(unix)]
    #[test]
    fn follows_symlinked_directories_without_looping() {
        let tmp = tempfile::tempdir().unwrap();
        let home_docs = tmp.path().join("home/Documents");
        make_folder(&home_docs.join("Health/Exports"), "healthaccess.index.v1");
        let drive = tmp.path().join("drive");
        fs::create_dir_all(&drive).unwrap();
        std::os::unix::fs::symlink(&home_docs, drive.join("Documents")).unwrap();
        std::os::unix::fs::symlink(&drive, drive.join("loop")).unwrap();
        let d = discover_in(&[vec![drive.clone()]], quick());
        assert_eq!(d.found.len(), 1);
        assert!(d.found[0].dir.starts_with(&drive));
    }

    #[test]
    fn stops_at_the_first_stage_with_a_hit() {
        let first = tempfile::tempdir().unwrap();
        let second = tempfile::tempdir().unwrap();
        make_folder(&second.path().join("x"), "healthaccess.index.v1");
        let d = discover_in(
            &[
                vec![first.path().to_path_buf()],
                vec![second.path().to_path_buf()],
            ],
            quick(),
        );
        assert_eq!(d.found.len(), 1);
        assert_eq!(d.searched.len(), 2);
        make_folder(&first.path().join("y"), "healthaccess.index.v1");
        let d = discover_in(
            &[
                vec![first.path().to_path_buf()],
                vec![second.path().to_path_buf()],
            ],
            quick(),
        );
        assert!(d.found[0].dir.starts_with(first.path()));
        assert_eq!(d.searched.len(), 1);
    }
}
