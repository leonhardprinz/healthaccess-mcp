//! Opt-in telemetry. OFF by default. When on, two events go to PostHog:
//! `mcp_started {version}` and `mcp_tool_called {tool, duration_ms, ok, error_kind?}`
//! under an anonymous install id persisted in config.toml. Never arguments,
//! results, file names or paths. The HTTP client only exists when the crate is
//! built with the `telemetry` feature; with the feature off this module is inert.

use std::sync::Arc;

use healthaccess_core::config::{self, Config};
use serde_json::{json, Map, Value};

/// Default PostHog ingestion host (EU).
pub const DEFAULT_HOST: &str = "https://eu.i.posthog.com";

#[derive(Debug)]
struct Inner {
    #[cfg_attr(not(feature = "telemetry"), allow(dead_code))]
    host: String,
    api_key: String,
    distinct_id: String,
    #[cfg(feature = "telemetry")]
    client: reqwest::Client,
}

/// Cheap, cloneable handle; `None` inside means disabled.
#[derive(Debug, Clone, Default)]
pub struct Telemetry {
    inner: Option<Arc<Inner>>,
}

impl Telemetry {
    /// A disabled handle.
    pub fn disabled() -> Self {
        Self::default()
    }

    /// Build from the config. Returns a disabled handle unless `enabled` is set,
    /// the binary was built with the `telemetry` feature, and an API key exists.
    pub fn init(enabled: bool, cfg: &Config) -> Self {
        if !enabled {
            return Self::disabled();
        }
        if cfg!(not(feature = "telemetry")) {
            tracing::warn!("telemetry requested but this binary was built without the `telemetry` feature; staying off");
            return Self::disabled();
        }
        let Some(api_key) = cfg.posthog_api_key.clone().filter(|k| !k.trim().is_empty()) else {
            tracing::warn!(
                "telemetry requested but `posthog_api_key` is missing in config.toml; staying off"
            );
            return Self::disabled();
        };
        let distinct_id = match cfg.anonymous_id.clone().filter(|s| !s.trim().is_empty()) {
            Some(id) => id,
            None => {
                let id = uuid::Uuid::new_v4().to_string();
                if let Err(e) = config::save_anonymous_id(&id) {
                    tracing::warn!("could not persist anonymous telemetry id: {e}");
                }
                id
            }
        };
        let host = cfg
            .posthog_host
            .clone()
            .filter(|h| !h.trim().is_empty())
            .unwrap_or_else(|| DEFAULT_HOST.to_string())
            .trim_end_matches('/')
            .to_string();
        Self::build(host, api_key, distinct_id)
    }

    #[cfg(feature = "telemetry")]
    fn build(host: String, api_key: String, distinct_id: String) -> Self {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(5))
            .user_agent(format!("healthaccess-mcp/{}", healthaccess_core::VERSION))
            .build();
        match client {
            Ok(client) => Telemetry {
                inner: Some(Arc::new(Inner {
                    host,
                    api_key,
                    distinct_id,
                    client,
                })),
            },
            Err(e) => {
                tracing::warn!("telemetry client failed to build: {e}; staying off");
                Self::disabled()
            }
        }
    }

    #[cfg(not(feature = "telemetry"))]
    fn build(_host: String, _api_key: String, _distinct_id: String) -> Self {
        Self::disabled()
    }

    /// `true` when events will be sent.
    pub fn enabled(&self) -> bool {
        self.inner.is_some()
    }

    /// `mcp_started {version}`.
    pub fn started(&self) {
        let mut props = Map::new();
        props.insert("version".into(), json!(healthaccess_core::VERSION));
        self.capture("mcp_started", props);
    }

    /// `mcp_tool_called {tool, duration_ms, ok, error_kind?}`.
    pub fn tool_called(&self, tool: &str, duration_ms: u128, ok: bool, error_kind: Option<&str>) {
        if !self.enabled() {
            return;
        }
        let mut props = Map::new();
        props.insert("tool".into(), json!(tool));
        props.insert("duration_ms".into(), json!(duration_ms as u64));
        props.insert("ok".into(), json!(ok));
        if let Some(k) = error_kind {
            props.insert("error_kind".into(), json!(k));
        }
        self.capture("mcp_tool_called", props);
    }

    fn capture(&self, event: &'static str, mut props: Map<String, Value>) {
        let Some(inner) = &self.inner else { return };
        props.insert("$lib".into(), json!("healthaccess-mcp"));
        props.insert("$lib_version".into(), json!(healthaccess_core::VERSION));
        props.insert("os".into(), json!(std::env::consts::OS));
        props.insert("$process_person_profile".into(), json!(false));
        props.insert("$geoip_disable".into(), json!(true));
        let body = json!({
            "api_key": inner.api_key,
            "event": event,
            "distinct_id": inner.distinct_id,
            "properties": Value::Object(props),
            "timestamp": chrono::Utc::now().to_rfc3339(),
        });
        self.send(Arc::clone(inner), body);
    }

    #[cfg(feature = "telemetry")]
    fn send(&self, inner: Arc<Inner>, body: Value) {
        let url = format!("{}/capture/", inner.host);
        tokio::spawn(async move {
            if let Err(e) = inner.client.post(url).json(&body).send().await {
                tracing::debug!("telemetry post failed: {e}");
            }
        });
    }

    #[cfg(not(feature = "telemetry"))]
    fn send(&self, _inner: Arc<Inner>, _body: Value) {}
}
