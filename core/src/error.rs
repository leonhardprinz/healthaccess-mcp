//! Error type shared by the store, the models and the codec.

use std::path::PathBuf;

/// Everything that can go wrong in `healthaccess_core`.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// A file or directory could not be read or written.
    #[error("{path}: {source}")]
    Io {
        /// The path that was being accessed.
        path: PathBuf,
        /// The underlying I/O error.
        #[source]
        source: std::io::Error,
    },
    /// A JSON file did not parse.
    #[error("{path}: invalid JSON: {source}")]
    Json {
        /// The offending file.
        path: PathBuf,
        /// The serde error.
        #[source]
        source: serde_json::Error,
    },
    /// A document declared a schema this crate does not understand.
    #[error("unsupported schema: {0}")]
    Schema(String),
    /// A workout, plan or file does not exist.
    #[error("not found: {0}")]
    NotFound(String),
    /// A short id matched more than one workout.
    #[error("ambiguous id {id}: matches {}", matches.join(", "))]
    Ambiguous {
        /// The query.
        id: String,
        /// Every matching workout id.
        matches: Vec<String>,
    },
    /// Plan or rating validation failed; every problem is listed.
    #[error("validation failed: {}", .0.join("; "))]
    Validation(Vec<String>),
    /// The request was well formed but the contract says no (for example
    /// overwriting the athlete's own Apple effort rating without `override`).
    /// The message is plain and complete; nothing is prefixed.
    #[error("{0}")]
    Refused(String),
    /// The `.workout` codec hit something outside the documented layout.
    #[error("codec: {0}")]
    Codec(String),
    /// Configuration (`HEALTHACCESS_DIR`, config.toml) is missing or malformed.
    #[error("config: {0}")]
    Config(String),
}

impl Error {
    /// Coarse, content-free category for telemetry (`error_kind`). Never contains
    /// paths, ids or messages.
    pub fn kind(&self) -> &'static str {
        match self {
            Error::Io { .. } => "io",
            Error::Json { .. } => "json",
            Error::Schema(_) => "schema",
            Error::NotFound(_) => "not_found",
            Error::Ambiguous { .. } => "ambiguous",
            Error::Validation(_) => "validation",
            Error::Refused(_) => "refused",
            Error::Codec(_) => "codec",
            Error::Config(_) => "config",
        }
    }

    /// Helper to wrap an I/O error with its path.
    pub fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Self {
        Error::Io {
            path: path.into(),
            source,
        }
    }

    /// Helper to wrap a JSON error with its path.
    pub fn json(path: impl Into<PathBuf>, source: serde_json::Error) -> Self {
        Error::Json {
            path: path.into(),
            source,
        }
    }
}

/// Result alias used throughout the crate.
pub type Result<T> = std::result::Result<T, Error>;
