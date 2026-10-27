//! `mcp/clients/<id>.json`: the handshake an MCP client (or the CLI) leaves in the folder
//! so the phone app can show "Connected". It carries the client's name and version, the
//! machine name, the MCP version, first and last seen, the last tool name and a call
//! count. Never arguments, never results, never file names.
//!
//! The MCP server writes it once after `initialize` and then, while tools are called, at
//! most once a minute ([`WRITE_THROTTLE`]); the CLI writes it once per invocation with
//! the client name `healthaccess-cli`.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::store::Store;
use crate::util::{atomic_write, read_json, to_sorted_pretty_json};
use crate::{Error, Result};

/// Schema tag of a handshake file.
pub const SCHEMA_CLIENT: &str = "healthaccess.client.v1";
/// Minimum gap between two writes for the same client while tools are called.
pub const WRITE_THROTTLE: Duration = Duration::from_secs(60);
/// Environment variable that overrides the machine name (tests use it for stable ids).
pub const ENV_MACHINE: &str = "HEALTHACCESS_MACHINE";

/// Name and version of the connected client.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ClientInfo {
    pub name: String,
    pub version: String,
}

/// One `mcp/clients/<id>.json`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ClientHandshake {
    pub schema: String,
    /// Stable hash of machine name and client name (16 hex characters).
    pub id: String,
    pub client: ClientInfo,
    /// The computer the client runs on.
    pub machine: String,
    /// Version of `healthaccess-mcp` / `healthaccess` that wrote the file.
    pub mcp_version: String,
    pub first_seen: DateTime<Utc>,
    pub last_seen: DateTime<Utc>,
    /// Name of the last tool called (never its arguments).
    #[serde(default)]
    pub last_tool: Option<String>,
    /// Tool calls recorded so far.
    #[serde(default)]
    pub calls: u64,
}

/// FNV-1a 64-bit, as 16 lower-case hex characters. Stable across builds and platforms.
fn fnv1a64(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// The stable id of a client on a machine.
pub fn client_id(machine: &str, client_name: &str) -> String {
    let key = format!(
        "{}|{}",
        machine.trim().to_ascii_lowercase(),
        client_name.trim().to_ascii_lowercase()
    );
    fnv1a64(key.as_bytes())
}

/// This computer's name: `HEALTHACCESS_MACHINE`, else `HOSTNAME`, else the first label of
/// what the `hostname` command prints (`Alexs-MacBook-Pro`, never `.local` or the router's
/// `.lan`), else `unknown-host`.
pub fn machine_name() -> String {
    for var in [ENV_MACHINE, "HOSTNAME"] {
        if let Some(v) = std::env::var_os(var) {
            let s = v.to_string_lossy().trim().to_string();
            if !s.is_empty() {
                return s;
            }
        }
    }
    if let Ok(out) = std::process::Command::new("hostname").output() {
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        let first = s.split('.').next().unwrap_or("").trim();
        if !first.is_empty() {
            return first.to_string();
        }
    }
    "unknown-host".to_string()
}

impl Store {
    /// `mcp/clients/`.
    pub fn clients_dir(&self) -> PathBuf {
        self.dir().join("mcp").join("clients")
    }

    /// `mcp/clients/<id>.json`.
    pub fn client_path(&self, id: &str) -> PathBuf {
        self.clients_dir().join(format!("{id}.json"))
    }

    /// Write (or update) the handshake of `client`: `first_seen` is kept, `last_seen`
    /// becomes now, `calls` grows by `calls`, `last_tool` is replaced when given.
    /// Atomic write; the file holds nothing about what was asked or answered.
    pub fn record_client(
        &self,
        client: &ClientInfo,
        last_tool: Option<&str>,
        calls: u64,
    ) -> Result<ClientHandshake> {
        let machine = machine_name();
        let id = client_id(&machine, &client.name);
        let path = self.client_path(&id);
        let now = Utc::now();
        let previous: Option<ClientHandshake> = path
            .is_file()
            .then(|| read_json::<ClientHandshake>(&path).ok())
            .flatten();
        let handshake = ClientHandshake {
            schema: SCHEMA_CLIENT.to_string(),
            id,
            client: client.clone(),
            machine,
            mcp_version: crate::VERSION.to_string(),
            first_seen: previous.as_ref().map(|p| p.first_seen).unwrap_or(now),
            last_seen: now,
            last_tool: last_tool
                .map(str::to_string)
                .or_else(|| previous.as_ref().and_then(|p| p.last_tool.clone())),
            calls: previous.as_ref().map(|p| p.calls).unwrap_or(0) + calls,
        };
        let dir = self.clients_dir();
        std::fs::create_dir_all(&dir).map_err(|e| Error::io(&dir, e))?;
        atomic_write(&path, to_sorted_pretty_json(&handshake)?.as_bytes())?;
        Ok(handshake)
    }

    /// Every handshake in `mcp/clients/`, most recently seen first.
    pub fn list_clients(&self) -> Result<Vec<ClientHandshake>> {
        let dir = self.clients_dir();
        if !dir.is_dir() {
            return Ok(Vec::new());
        }
        let mut out: Vec<ClientHandshake> = std::fs::read_dir(&dir)
            .map_err(|e| Error::io(&dir, e))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().map(|x| x == "json").unwrap_or(false))
            .filter_map(|p| read_json::<ClientHandshake>(&p).ok())
            .collect();
        out.sort_by_key(|c| std::cmp::Reverse(c.last_seen));
        Ok(out)
    }
}

/// Throttled handshake writer for a long-running server: `connected` writes at once,
/// `tool_called` counts and writes at most every [`WRITE_THROTTLE`].
#[derive(Debug)]
pub struct Recorder {
    store: Store,
    state: Mutex<RecorderState>,
}

#[derive(Debug, Default)]
struct RecorderState {
    client: Option<ClientInfo>,
    pending_calls: u64,
    last_tool: Option<String>,
    last_write: Option<Instant>,
}

impl Recorder {
    /// A recorder over the folder of `store`.
    pub fn new(store: Store) -> Self {
        Recorder {
            store,
            state: Mutex::new(RecorderState::default()),
        }
    }

    /// Whether a client has introduced itself in this process.
    pub fn knows_client(&self) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .client
            .is_some()
    }

    /// The client introduced itself (`initialize`, or the first request of a 2026-07-28
    /// session, which carries the client in its `_meta`): write the handshake now.
    pub fn connected(&self, client: ClientInfo) -> Result<ClientHandshake> {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        st.client = Some(client.clone());
        st.last_write = Some(Instant::now());
        self.store.record_client(&client, None, 0)
    }

    /// A tool was called: count it, write when the throttle allows.
    pub fn tool_called(&self, tool: &str) -> Result<Option<ClientHandshake>> {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        st.pending_calls += 1;
        st.last_tool = Some(tool.to_string());
        let due = st
            .last_write
            .map(|t| t.elapsed() >= WRITE_THROTTLE)
            .unwrap_or(true);
        if !due {
            return Ok(None);
        }
        let Some(client) = st.client.clone() else {
            return Ok(None);
        };
        let calls = std::mem::take(&mut st.pending_calls);
        let last_tool = st.last_tool.clone();
        st.last_write = Some(Instant::now());
        drop(st);
        self.store
            .record_client(&client, last_tool.as_deref(), calls)
            .map(Some)
    }

    /// Write whatever is pending (for example on shutdown).
    pub fn flush(&self) -> Result<Option<ClientHandshake>> {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let Some(client) = st.client.clone() else {
            return Ok(None);
        };
        if st.pending_calls == 0 {
            return Ok(None);
        }
        let calls = std::mem::take(&mut st.pending_calls);
        let last_tool = st.last_tool.clone();
        st.last_write = Some(Instant::now());
        drop(st);
        self.store
            .record_client(&client, last_tool.as_deref(), calls)
            .map(Some)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_stable_and_case_insensitive() {
        assert_eq!(
            client_id("Alexs-Mac", "Claude Code"),
            client_id("alexs-mac", "claude code")
        );
        assert_ne!(
            client_id("alexs-mac", "claude code"),
            client_id("alexs-mac", "cursor")
        );
        assert_eq!(client_id("test-mac", "test").len(), 16);
        assert_eq!(fnv1a64(b""), "cbf29ce484222325");
    }
}
