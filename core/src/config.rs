//! Where the Health Access folder is, first match wins: `--dir`, `HEALTHACCESS_DIR`,
//! `~/.config/healthaccess/config.toml`, then discovery ([`crate::discover`]: iCloud Drive,
//! then the other file providers, then `~/Documents`).
//! The pre-rename names are still honoured as aliases: `TIDE_DIR`, `TIDE_CONFIG` and
//! `~/.config/tide/config.toml` (read when the new file does not exist).
//! The config file also carries the opt-in telemetry settings.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::{Error, Result};

/// Environment variable naming the Health Access folder.
pub const ENV_DIR: &str = "HEALTHACCESS_DIR";
/// Pre-rename alias of [`ENV_DIR`], still honoured.
pub const ENV_DIR_LEGACY: &str = "TIDE_DIR";
/// Environment variable overriding the config file location (mainly for tests).
pub const ENV_CONFIG: &str = "HEALTHACCESS_CONFIG";
/// Pre-rename alias of [`ENV_CONFIG`], still honoured.
pub const ENV_CONFIG_LEGACY: &str = "TIDE_CONFIG"; // alias
/// Directory under `~/.config` holding `config.toml`.
pub const CONFIG_DIR_NAME: &str = "healthaccess";
/// Pre-rename alias of [`CONFIG_DIR_NAME`] (`~/.config/tide`), read when the new file is absent.
pub const CONFIG_DIR_NAME_LEGACY: &str = "tide"; // alias

/// `~/.config/healthaccess/config.toml`.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Config {
    /// The Health Access folder.
    #[serde(default)]
    pub dir: Option<PathBuf>,
    /// Opt-in telemetry (default off).
    #[serde(default)]
    pub telemetry: bool,
    /// PostHog host, e.g. `https://eu.i.posthog.com`.
    #[serde(default)]
    pub posthog_host: Option<String>,
    /// PostHog project API key (`phc_…`).
    #[serde(default)]
    pub posthog_api_key: Option<String>,
    /// Anonymous install id, generated on first telemetry-enabled start.
    #[serde(default)]
    pub anonymous_id: Option<String>,
    /// Custom zone bounds (four ascending bpm values).
    #[serde(default)]
    pub zones: Option<Vec<u32>>,
}

impl Config {
    /// Zone bounds from the config when it names four ascending values; `None` means
    /// "not configured" (the store then estimates them from `profile.json`, or falls
    /// back to [`DEFAULT_ZONE_BOUNDS`]).
    pub fn zone_bounds(&self) -> Option<[u32; 4]> {
        match &self.zones {
            Some(z) if z.len() == 4 && z.windows(2).all(|w| w[0] < w[1]) => {
                Some([z[0], z[1], z[2], z[3]])
            }
            _ => None,
        }
    }
}

/// A non-empty environment variable.
fn env_non_empty(name: &str) -> Option<OsString> {
    std::env::var_os(name).filter(|v| !v.is_empty())
}

/// Path of the config file: `HEALTHACCESS_CONFIG` (or its alias `TIDE_CONFIG`), else
/// `~/.config/healthaccess/config.toml`, else — only when that file does not exist
/// but the pre-rename `~/.config/tide/config.toml` does — the latter.
pub fn config_path() -> Option<PathBuf> {
    if let Some(p) = env_non_empty(ENV_CONFIG).or_else(|| env_non_empty(ENV_CONFIG_LEGACY)) {
        return Some(PathBuf::from(p));
    }
    let home = dirs::home_dir()?;
    let current = home
        .join(".config")
        .join(CONFIG_DIR_NAME)
        .join("config.toml");
    if current.exists() {
        return Some(current);
    }
    let legacy = home
        .join(".config")
        .join(CONFIG_DIR_NAME_LEGACY)
        .join("config.toml");
    if legacy.exists() {
        return Some(legacy);
    }
    Some(current)
}

/// Load the config; a missing file is an empty config.
pub fn load() -> Result<Config> {
    let Some(path) = config_path() else {
        return Ok(Config::default());
    };
    if !path.exists() {
        return Ok(Config::default());
    }
    let text = std::fs::read_to_string(&path).map_err(|e| Error::io(&path, e))?;
    toml::from_str(&text).map_err(|e| Error::Config(format!("{}: {e}", path.display())))
}

/// Expand a leading `~` to the home directory.
pub fn expand_tilde(p: &Path) -> PathBuf {
    if let Ok(rest) = p.strip_prefix("~") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    p.to_path_buf()
}

/// Where the folder came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirSource {
    /// `--dir`.
    Flag,
    /// `HEALTHACCESS_DIR` or `TIDE_DIR`.
    Env,
    /// `dir = "…"` in config.toml.
    Config,
    /// Found by [`crate::discover`].
    Discovered,
}

impl DirSource {
    /// Short label for logs and `--check`.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Flag => "--dir",
            Self::Env => "environment",
            Self::Config => "config.toml",
            Self::Discovered => "found on this computer",
        }
    }
}

/// Resolve the Health Access folder: CLI flag, then `HEALTHACCESS_DIR` (or its alias
/// `TIDE_DIR`), then the config file, then discovery.
pub fn resolve_dir(cli_dir: Option<&Path>) -> Result<PathBuf> {
    resolve_dir_with_source(cli_dir).map(|(dir, _, _)| dir)
}

/// [`resolve_dir`], plus where the folder came from. A discovery that finds more than
/// one folder is an error: the user chooses (the third value is kept for callers and is
/// always empty now).
pub fn resolve_dir_with_source(
    cli_dir: Option<&Path>,
) -> Result<(PathBuf, DirSource, Vec<PathBuf>)> {
    if let Some(d) = cli_dir {
        return Ok((expand_tilde(d), DirSource::Flag, Vec::new()));
    }
    if let Some(d) = env_non_empty(ENV_DIR).or_else(|| env_non_empty(ENV_DIR_LEGACY)) {
        return Ok((expand_tilde(Path::new(&d)), DirSource::Env, Vec::new()));
    }
    if let Some(d) = load()?.dir {
        return Ok((expand_tilde(&d), DirSource::Config, Vec::new()));
    }
    let found = crate::discover::discover();
    if found.found.len() > 1 {
        // Never guess between folders: one of them may be a folder someone else shared.
        let list = found
            .found
            .iter()
            .map(|f| format!("\"{}\"", f.dir.display()))
            .collect::<Vec<_>>()
            .join(", ");
        return Err(Error::Config(format!(
            "found more than one Health Access folder ({list}); choose yours with --dir \"<folder>\", {ENV_DIR}, or `dir = \"…\"` in {}",
            config_path()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| format!("~/.config/{CONFIG_DIR_NAME}/config.toml"))
        )));
    }
    if let Some(best) = found.best() {
        return Ok((best.dir.clone(), DirSource::Discovered, Vec::new()));
    }
    let searched = if found.searched.is_empty() {
        "nothing (no home directory)".to_string()
    } else {
        found
            .searched
            .iter()
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    };
    Err(Error::Config(format!(
        "no Health Access folder found (searched {searched}); pass --dir \"<folder>\", set {ENV_DIR}, or put `dir = \"…\"` into {}",
        config_path()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| format!("~/.config/{CONFIG_DIR_NAME}/config.toml"))
    )))
}

/// Persist the anonymous telemetry id into the config file, creating it if needed.
/// Only called when telemetry is enabled.
pub fn save_anonymous_id(id: &str) -> Result<()> {
    let path = config_path().ok_or_else(|| Error::Config("no home directory".into()))?;
    let mut table: toml::Table = if path.exists() {
        let text = std::fs::read_to_string(&path).map_err(|e| Error::io(&path, e))?;
        text.parse()
            .map_err(|e| Error::Config(format!("{}: {e}", path.display())))?
    } else {
        toml::Table::new()
    };
    table.insert(
        "anonymous_id".to_string(),
        toml::Value::String(id.to_string()),
    );
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
    }
    let text = toml::to_string(&table).map_err(|e| Error::Config(e.to_string()))?;
    crate::util::atomic_write(&path, text.as_bytes())
}
