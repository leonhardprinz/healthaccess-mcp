//! `healthaccess-mcp`: MCP server over stdio exposing a Health Access folder to AI assistants.
//!
//! stdout carries MCP frames only; all logging goes to stderr (`HEALTHACCESS_LOG=debug`;
//! the pre-rename `TIDE_LOG` is still read as an alias).

mod server;
mod telemetry;

use std::path::PathBuf;

use anyhow::Context;
use clap::Parser;
use healthaccess_core::config;
use healthaccess_core::Store;
use rmcp::transport::stdio;
use rmcp::ServiceExt;

/// Health Access MCP server (stdio).
#[derive(Debug, Parser)]
#[command(name = "healthaccess-mcp", version, about)]
struct Args {
    /// Health Access folder (overrides HEALTHACCESS_DIR / TIDE_DIR and config.toml). Without
    /// any of them the server looks for the folder in iCloud Drive, then the other file
    /// providers, then ~/Documents.
    #[arg(long, value_name = "DIR")]
    dir: Option<PathBuf>,
    /// Enable opt-in telemetry for this run (PostHog host/key come from config.toml).
    #[arg(long)]
    telemetry: bool,
    /// Print the resolved folder and config, then exit.
    #[arg(long)]
    check: bool,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("HEALTHACCESS_LOG")
                .or_else(|_| tracing_subscriber::EnvFilter::try_from_env("TIDE_LOG")) // alias
                .or_else(|_| tracing_subscriber::EnvFilter::try_from_default_env())
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .init();

    let args = Args::parse();
    let cfg = config::load().context("reading config")?;
    let (dir, source, others) = config::resolve_dir_with_source(args.dir.as_deref())
        .context("resolving the Health Access folder")?;
    if source == config::DirSource::Discovered {
        tracing::warn!(dir = %dir.display(), "no folder configured, using the only Health Access folder found on this computer");
    }
    let store = Store::open(&dir)
        .with_context(|| format!("opening {}", dir.display()))?
        .with_zone_bounds(cfg.zone_bounds());

    let telemetry = telemetry::Telemetry::init(args.telemetry || cfg.telemetry, &cfg);

    if args.check {
        println!("dir: {} ({})", dir.display(), source.as_str());
        for other in &others {
            println!("also found: {}", other.display());
        }
        match store.effective_bounds() {
            Some((bounds, source)) => println!("zone bounds: {:?} ({})", bounds, source.as_str()),
            None => println!(
                "zone bounds: none known (set zones in config.toml or let the app write profile.json); a workout file's own zones are used when it carries any"
            ),
        }
        println!(
            "telemetry: {}",
            if telemetry.enabled() { "on" } else { "off" }
        );
        println!(
            "config file: {}",
            config::config_path()
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        );
        return Ok(());
    }

    telemetry.started();
    tracing::info!(dir = %dir.display(), "healthaccess-mcp {} starting", healthaccess_core::VERSION);

    let service = server::HealthAccessServer::new(store, telemetry)
        .serve(stdio())
        .await
        .context("MCP handshake failed")?;
    service.waiting().await.context("server task failed")?;
    Ok(())
}
