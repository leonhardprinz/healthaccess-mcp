//! `healthaccess`: command-line companion of the MCP server.

use std::path::PathBuf;
use std::process::ExitCode;

use anyhow::{bail, Context};
use chrono::{DateTime, NaiveDate, Utc};
use clap::{Parser, Subcommand};
use healthaccess_core::codec::{self, WorkoutFile};
use healthaccess_core::derive;
use healthaccess_core::model::plan::Plan;
use healthaccess_core::model::Workout;
use healthaccess_core::util::{fmt_duration, fmt_pace, round_floats, round_to};
use healthaccess_core::{config, prompts, Store};

/// Text from the folder (names, notes, `feel`) is printed as data: control characters
/// other than newline and tab are dropped, so a file cannot send escape codes to the terminal.
fn clean(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .collect()
}

// Every print in this binary goes through `clean`.
macro_rules! println {
    () => { std::println!() };
    ($($arg:tt)*) => { std::println!("{}", crate::clean(&format!($($arg)*))) };
}
macro_rules! print {
    ($($arg:tt)*) => { std::print!("{}", crate::clean(&format!($($arg)*))) };
}
macro_rules! eprintln {
    () => { std::eprintln!() };
    ($($arg:tt)*) => { std::eprintln!("{}", crate::clean(&format!($($arg)*))) };
}

/// Health Access MCP in the terminal: list, show and rate Apple Health workouts, push plans, print the briefing and the prompts.
#[derive(Debug, Parser)]
#[command(name = "healthaccess", version, about, propagate_version = true)]
struct Cli {
    /// Health Access folder (overrides HEALTHACCESS_DIR / TIDE_DIR and config.toml).
    #[arg(long, global = true, value_name = "DIR")]
    dir: Option<PathBuf>,
    /// Print JSON instead of tables.
    #[arg(long, global = true)]
    json: bool,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Debug, Subcommand)]
enum Cmd {
    /// List workouts, newest first.
    List {
        /// Only workouts on/after this date (YYYY-MM-DD).
        #[arg(long)]
        since: Option<String>,
        /// Activity filter, e.g. pool_swim, indoor_row, swim.
        #[arg(long)]
        sport: Option<String>,
        /// Maximum rows.
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Show one workout (id prefix, full id or file name).
    Show {
        id: String,
        /// Also print the heart-rate series.
        #[arg(long)]
        hr: bool,
    },
    /// Weekly training summary.
    Summary {
        /// How many ISO weeks ending this week.
        #[arg(long, default_value_t = 8)]
        weeks: u32,
    },
    /// Store the athlete's effort (1 to 10) and an optional feel note in a workout file.
    Rate {
        id: String,
        effort: u8,
        /// Replace the athlete's own rating from Apple (only when the athlete asks).
        #[arg(long = "override")]
        override_apple: bool,
        /// Free text; the remaining arguments are joined with spaces.
        #[arg(trailing_var_arg = true)]
        feel: Vec<String>,
    },
    /// Plans: push, status, list.
    Plan {
        #[command(subcommand)]
        cmd: PlanCmd,
    },
    /// Build an Apple `.workout` file from a plan JSON (old import flow).
    WorkoutFile {
        /// Plan JSON (healthaccess.plan.v1; id/schema may be missing).
        plan: PathBuf,
        /// Output file, e.g. S30_PoolSwim.workout.
        #[arg(short = 'o', long)]
        out: PathBuf,
        /// Fixed UUID instead of a random one.
        #[arg(long)]
        uuid: Option<String>,
    },
    /// Check the folder: directories, index, every JSON file, schema versions.
    Doctor,
    /// Print the briefing: briefing.md from the folder, or one generated from it.
    Briefing,
    /// One day file (days/<date>.json): every group Health had data for, as JSON.
    Day {
        /// YYYY-MM-DD.
        date: String,
    },
    /// Day files of a range, oldest first, as JSON (optionally only some groups).
    Days {
        /// First day, YYYY-MM-DD.
        #[arg(long)]
        from: String,
        /// Last day, YYYY-MM-DD (inclusive).
        #[arg(long)]
        to: String,
        /// Comma-separated group names to keep, e.g. heart,sleep.
        #[arg(long)]
        groups: Option<String>,
    },
    /// The coverage check: catalog.json against the HealthKit type list of this build.
    Catalog,
    /// The athlete's characteristics (profile.json) as JSON.
    Profile,
    /// Every ECG summary in ecg/, newest first.
    Ecgs,
    /// List the prompts (ids and titles) from docs/prompts.md.
    Prompts,
    /// Print one prompt's text, byte for byte as in docs/prompts.md.
    Prompt {
        /// Prompt id, e.g. next_session.
        id: String,
    },
}

#[derive(Debug, Subcommand)]
enum PlanCmd {
    /// Validate a plan JSON and write plans/<id>.json.
    Push { file: PathBuf },
    /// Show the scheduling status of a plan.
    Status { id: String },
    /// List all plans.
    List,
}

// ------------------------------------------------------------------ tables

#[derive(Debug, Default)]
struct Table {
    headers: Vec<String>,
    rows: Vec<Vec<String>>,
    right: Vec<bool>,
}

impl Table {
    fn new(headers: &[(&str, bool)]) -> Self {
        Table {
            headers: headers.iter().map(|(h, _)| h.to_string()).collect(),
            rows: Vec::new(),
            right: headers.iter().map(|(_, r)| *r).collect(),
        }
    }

    fn row(&mut self, cells: Vec<String>) {
        self.rows.push(cells);
    }

    fn render(&self) -> String {
        let width = |s: &str| s.chars().count();
        let mut widths: Vec<usize> = self.headers.iter().map(|h| width(h)).collect();
        for r in &self.rows {
            for (i, c) in r.iter().enumerate() {
                if i < widths.len() {
                    widths[i] = widths[i].max(width(c));
                }
            }
        }
        let line = |cells: &[String]| -> String {
            cells
                .iter()
                .enumerate()
                .map(|(i, c)| {
                    let w = widths.get(i).copied().unwrap_or(0);
                    let pad = w.saturating_sub(width(c));
                    if self.right.get(i).copied().unwrap_or(false) {
                        format!("{}{}", " ".repeat(pad), c)
                    } else {
                        format!("{}{}", c, " ".repeat(pad))
                    }
                })
                .collect::<Vec<_>>()
                .join("  ")
                .trim_end()
                .to_string()
        };
        let mut out = String::new();
        out.push_str(&line(&self.headers));
        out.push('\n');
        out.push_str(
            &widths
                .iter()
                .map(|w| "─".repeat(*w))
                .collect::<Vec<_>>()
                .join("  "),
        );
        out.push('\n');
        for r in &self.rows {
            out.push_str(&line(r));
            out.push('\n');
        }
        out
    }
}

/// Placeholder for a missing value in tables.
const NONE: &str = "-";

fn opt_num(v: Option<f64>, decimals: i32) -> String {
    v.map(|x| format!("{}", round_to(x, decimals)))
        .unwrap_or_else(|| NONE.into())
}

fn opt_str<T: ToString>(v: Option<T>) -> String {
    v.map(|x| x.to_string()).unwrap_or_else(|| NONE.into())
}

fn print_json<T: serde::Serialize>(v: &T) -> anyhow::Result<()> {
    let mut val = serde_json::to_value(v)?;
    round_floats(&mut val, 1);
    println!("{}", serde_json::to_string_pretty(&val)?);
    Ok(())
}

fn parse_since(s: &str) -> anyhow::Result<DateTime<Utc>> {
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Ok(dt.with_timezone(&Utc));
    }
    let d = NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .with_context(|| format!("--since {s:?}: use YYYY-MM-DD"))?;
    Ok(d.and_hms_opt(0, 0, 0).expect("midnight").and_utc())
}

// ------------------------------------------------------------------ commands

fn cmd_list(
    store: &Store,
    since: Option<String>,
    sport: Option<String>,
    limit: usize,
    json: bool,
) -> anyhow::Result<()> {
    let since = since.as_deref().map(parse_since).transpose()?;
    let (index, source) = store.load_index()?;
    let rows: Vec<_> = index
        .workouts
        .iter()
        .filter(|e| since.map(|s| e.start >= s).unwrap_or(true))
        .filter(|e| {
            sport
                .as_deref()
                .map(|s| e.activity == s || e.activity.contains(&s.to_ascii_lowercase()))
                .unwrap_or(true)
        })
        .take(limit.max(1))
        .collect();
    if json {
        return print_json(&serde_json::json!({"index_source": source, "workouts": rows}));
    }
    let mut t = Table::new(&[
        ("DATE", false),
        ("TIME", false),
        ("ACTIVITY", false),
        ("PLAN", false),
        ("DURATION", true),
        ("DIST m", true),
        ("AVG HR", true),
        ("EFFORT", true),
        ("SOURCE", false),
        ("ID", false),
    ]);
    for e in &rows {
        t.row(vec![
            e.start.format("%Y-%m-%d").to_string(),
            e.start.format("%H:%MZ").to_string(),
            e.activity.clone(),
            opt_str(e.plan_name.clone()),
            fmt_duration(e.duration_s),
            opt_num(e.distance_m, 0),
            opt_num(e.avg_hr, 0),
            opt_str(e.effort),
            opt_str(e.effort_source.clone()),
            e.short_id(),
        ]);
    }
    print!("{}", t.render());
    println!(
        "{} of {} workouts (index: {})",
        rows.len(),
        index.workouts.len(),
        match source {
            healthaccess_core::store::IndexSource::File => "index.json",
            healthaccess_core::store::IndexSource::Scan => "scanned workouts/",
        }
    );
    Ok(())
}

fn print_workout(store: &Store, w: &Workout, hr: bool) {
    println!("{}", store.summary(w));
    println!();
    println!("id        {}", w.id);
    println!("activity  {}  source: {}", w.activity, w.source);
    println!(
        "time      {} to {}  active {}",
        w.start.format("%Y-%m-%d %H:%M:%SZ"),
        w.end.format("%H:%M:%SZ"),
        fmt_duration(w.duration_s)
    );
    println!(
        "totals    distance {}  kcal {}  avg HR {}  max HR {}  pool {}",
        opt_num(w.distance_m, 0),
        opt_num(w.active_kcal, 0),
        opt_num(w.avg_hr, 0),
        opt_num(w.max_hr, 0),
        w.pool_length_m
            .map(|p| format!("{p} m"))
            .unwrap_or_else(|| NONE.into())
    );
    if let Some(pr) = &w.plan_ref {
        println!(
            "plan      {} ({})",
            opt_str(pr.name.clone()),
            opt_str(pr.plan_id.clone())
        );
    }
    println!(
        "rating    {}  feel {}{}",
        derive::effort_text(w.effort, w.effort_source.as_deref()),
        w.feel.clone().unwrap_or_else(|| NONE.into()),
        w.effort_estimated
            .map(|e| format!("  (Apple's estimate {})", round_to(e, 1)))
            .unwrap_or_default()
    );
    if let Some(r) = w.recovery_hr {
        println!(
            "recovery  end {}  +1min {}  +2min {}",
            opt_str(r.end),
            opt_str(r.one_min),
            opt_str(r.two_min)
        );
    }
    if let Some(cc) = derive::cardiac_cost(w) {
        println!(
            "cardiac   {} beats/100 m at best FR 100 {} ({})",
            cc.beats_per_100m.round(),
            fmt_pace(cc.best_100_pace_s),
            cc.basis
        );
    }
    if let Some(z) = store.zones(w) {
        let total = z.seconds.total().max(1) as f64;
        let cell = |s: u32| {
            format!(
                "{} ({}%)",
                fmt_duration(f64::from(s)),
                (100.0 * f64::from(s) / total).round()
            )
        };
        println!(
            "zones     bounds {:?} ({})  Z1 {}  Z2 {}  Z3 {}  Z4 {}  Z5 {}",
            z.bounds,
            z.bounds_source.as_deref().unwrap_or("file"),
            cell(z.seconds.z1),
            cell(z.seconds.z2),
            cell(z.seconds.z3),
            cell(z.seconds.z4),
            cell(z.seconds.z5)
        );
    }
    if !w.steps.is_empty() {
        println!();
        let mut t = Table::new(&[
            ("KEY", false),
            ("KIND", false),
            ("LABEL", false),
            ("DUR", true),
            ("DIST m", true),
            ("PACE/100", true),
            ("HR", true),
            ("GOAL", false),
        ]);
        for s in &w.steps {
            t.row(vec![
                s.key.clone(),
                s.kind.to_string(),
                s.label.clone().unwrap_or_default(),
                fmt_duration(s.duration_s),
                opt_num(s.distance_m, 0),
                s.pace_s_per_100m
                    .map(fmt_pace)
                    .unwrap_or_else(|| NONE.into()),
                opt_num(s.avg_hr, 0),
                match s.goal_met {
                    Some(true) => "met".into(),
                    Some(false) => "missed".into(),
                    None => NONE.into(),
                },
            ]);
        }
        print!("{}", t.render());
    }
    if !w.laps.is_empty() {
        let mut strokes: std::collections::BTreeMap<String, usize> =
            std::collections::BTreeMap::new();
        let mut swolf = Vec::new();
        for l in &w.laps {
            *strokes
                .entry(l.stroke.clone().unwrap_or_else(|| "unknown".into()))
                .or_default() += 1;
            if let Some(s) = l.swolf {
                swolf.push(s);
            }
        }
        let mean_swolf = if swolf.is_empty() {
            NONE.to_string()
        } else {
            format!(
                "{}",
                (swolf.iter().sum::<f64>() / swolf.len() as f64).round()
            )
        };
        println!();
        println!(
            "laps      {} lengths  strokes {}  mean SWOLF {}",
            w.laps.len(),
            strokes
                .iter()
                .map(|(k, v)| format!("{k} ×{v}"))
                .collect::<Vec<_>>()
                .join(", "),
            mean_swolf
        );
    }
    if hr {
        println!();
        println!("hr series ({} samples)", w.hr_series.len());
        for s in &w.hr_series {
            println!("  {}  {:>3}", s.t.format("%H:%M:%S"), s.bpm);
        }
    }
}

fn cmd_show(store: &Store, id: &str, hr: bool, json: bool) -> anyhow::Result<()> {
    let mut w = store.load_workout(id)?;
    if json {
        if !hr {
            w.hr_series.clear();
        }
        let summary = store.summary(&w);
        return print_json(
            &serde_json::json!({"summary": summary, "cardiac_cost": derive::cardiac_cost(&w), "workout": w}),
        );
    }
    print_workout(store, &w, hr);
    Ok(())
}

fn cmd_summary(store: &Store, weeks: u32, json: bool) -> anyhow::Result<()> {
    let s = store.training_summary(weeks)?;
    if json {
        return print_json(&s);
    }
    println!(
        "{} to {}  ({} workouts, zone bounds {})",
        s.from,
        s.to,
        s.workouts_considered,
        match (s.zone_bounds, s.bounds_source) {
            (Some(b), Some(src)) => format!("{b:?} {}", src.as_str()),
            _ => "not known, file zones where present".to_string(),
        }
    );
    let mut t = Table::new(&[
        ("WEEK", false),
        ("SESSIONS", true),
        ("TIME", true),
        ("DIST m", true),
        ("AVG HR", true),
        ("Z1-2 %", true),
        ("EFFORT", true),
        ("CC b/100m", true),
        ("BY SPORT", false),
    ]);
    for w in &s.weeks {
        t.row(vec![
            w.week.clone(),
            w.sessions.to_string(),
            fmt_duration(w.duration_s),
            format!("{}", w.distance_m.round()),
            opt_num(w.avg_hr, 0),
            opt_num(w.z12_pct, 0),
            opt_num(w.mean_effort, 1),
            opt_num(w.cardiac_cost, 0),
            w.by_sport
                .iter()
                .map(|(k, v)| format!("{k} ×{}", v.sessions))
                .collect::<Vec<_>>()
                .join(", "),
        ]);
    }
    print!("{}", t.render());
    if !s.cardiac_cost_trend.is_empty() {
        println!();
        println!("cardiac cost trend (avg HR x best FR 100 pace / 60 = beats per 100 m, lower is better)");
        let mut t = Table::new(&[
            ("DATE", false),
            ("NAME", false),
            ("BEST 100", true),
            ("AVG HR", true),
            ("BEATS/100m", true),
            ("BASIS", false),
        ]);
        for p in &s.cardiac_cost_trend {
            t.row(vec![
                p.date.to_string(),
                p.name.clone(),
                fmt_pace(p.cost.best_100_pace_s),
                format!("{}", p.cost.avg_hr.round()),
                format!("{}", p.cost.beats_per_100m.round()),
                p.cost.basis.clone(),
            ]);
        }
        print!("{}", t.render());
    }
    for n in &s.notes {
        println!("note: {n}");
    }
    Ok(())
}

fn cmd_rate(
    store: &Store,
    id: &str,
    effort: u8,
    feel: Vec<String>,
    override_apple: bool,
    json: bool,
) -> anyhow::Result<()> {
    let feel = feel.join(" ");
    let feel = (!feel.trim().is_empty()).then_some(feel);
    let out = store.rate_workout(id, effort, feel.as_deref(), override_apple)?;
    if json {
        return print_json(&out);
    }
    println!(
        "rated {}: effort {} ({}){}",
        out.file,
        out.effort,
        out.effort_source,
        out.feel
            .as_ref()
            .map(|f| format!(", feel \"{f}\""))
            .unwrap_or_default()
    );
    if let Some(prev) = out.previous_effort {
        println!(
            "replaced effort {prev} ({})",
            out.previous_source.as_deref().unwrap_or("source unknown")
        );
    }
    println!(
        "index.json {}",
        if out.index_updated {
            "updated"
        } else {
            "not present or row not listed, unchanged"
        }
    );
    println!("{}", out.summary);
    Ok(())
}

fn read_plan(path: &PathBuf) -> anyhow::Result<Plan> {
    let text =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    serde_json::from_str(&text)
        .with_context(|| format!("{} is not a healthaccess.plan.v1 document", path.display()))
}

fn describe_plan(plan: &Plan) -> String {
    let mut out = String::new();
    if let Some(w) = &plan.warmup {
        out.push_str(&format!("  warmup    {}\n", w.describe()));
    }
    for (i, b) in plan.blocks.iter().enumerate() {
        out.push_str(&format!("  block {}  ×{}\n", i + 1, b.repeat));
        for s in &b.steps {
            out.push_str(&format!(
                "    {:<8} {}\n",
                s.kind.clone().unwrap_or_else(|| "work".into()),
                s.describe()
            ));
        }
    }
    if let Some(c) = &plan.cooldown {
        out.push_str(&format!("  cooldown  {}\n", c.describe()));
    }
    out.push_str(&format!(
        "  planned   {} m distance goals, {} time goals",
        plan.planned_distance_m().round(),
        fmt_duration(plan.planned_time_s())
    ));
    out
}

fn cmd_plan(store: &Store, cmd: PlanCmd, json: bool) -> anyhow::Result<()> {
    match cmd {
        PlanCmd::Push { file } => {
            let plan = read_plan(&file)?;
            let (plan, path) = store.write_plan(plan, "healthaccess-cli")?;
            if json {
                return print_json(&serde_json::json!({"id": plan.id, "path": path, "plan": plan}));
            }
            println!("wrote {}", path.display());
            println!("id    {}", plan.id);
            println!("{}", describe_plan(&plan));
            println!(
                "the app shows it as Your AI wrote {}; one tap puts it on the Watch. Check with `healthaccess plan status {}`",
                plan.name, plan.id
            );
        }
        PlanCmd::Status { id } => {
            let status = store.plan_status(&id)?;
            if json {
                return print_json(&serde_json::json!({"plan_id": id, "status": status}));
            }
            match status {
                Some(s) => println!(
                    "{}: {}{}{}",
                    s.plan_id,
                    s.state,
                    s.at.map(|a| format!(" at {}", a.format("%Y-%m-%d %H:%M:%SZ")))
                        .unwrap_or_default(),
                    s.error.map(|e| format!(": {e}")).unwrap_or_default()
                ),
                None => println!(
                    "{id}: pending (no status file yet; the app writes it once the athlete taps Put on Watch)"
                ),
            }
        }
        PlanCmd::List => {
            let plans = store.list_plans()?;
            if json {
                return print_json(&plans);
            }
            let mut t = Table::new(&[
                ("ID", false),
                ("NAME", false),
                ("SPORT", false),
                ("SCHEDULED", false),
                ("STATE", false),
                ("DIST m", true),
                ("TIME", true),
            ]);
            for p in &plans {
                t.row(vec![
                    p.id.clone(),
                    p.name.clone(),
                    p.sport.clone(),
                    p.scheduled_for
                        .map(|d| d.format("%Y-%m-%d %H:%MZ").to_string())
                        .unwrap_or_else(|| NONE.into()),
                    p.state.clone(),
                    format!("{}", p.planned_distance_m.round()),
                    fmt_duration(p.planned_time_s),
                ]);
            }
            print!("{}", t.render());
            println!("{} plans", plans.len());
        }
    }
    Ok(())
}

fn cmd_workout_file(plan: PathBuf, out: PathBuf, uuid: Option<String>) -> anyhow::Result<()> {
    let plan = read_plan(&plan)?;
    let file = WorkoutFile::from_plan(&plan, uuid)?;
    let bytes = codec::encode(&file);
    // belt and braces: what we wrote must decode to what we meant
    let back = codec::decode(&bytes).context("self-check decode")?;
    if back != file {
        bail!("self-check failed: decoded file differs from the encoded one");
    }
    std::fs::write(&out, &bytes).with_context(|| format!("writing {}", out.display()))?;
    println!(
        "wrote {} ({} bytes, uuid {})",
        out.display(),
        bytes.len(),
        file.uuid
    );
    println!("{}", describe_plan(&plan));
    println!("AirDrop or open the file on the iPhone to import it into the Workout app.");
    Ok(())
}

fn cmd_doctor(store: &Store, json: bool) -> anyhow::Result<bool> {
    let r = store.doctor()?;
    if json {
        print_json(&r)?;
        return Ok(r.healthy());
    }
    let yn = |b: bool| if b { "yes" } else { "no" };
    println!(
        "healthaccess {}  folder {}",
        r.core_version,
        r.dir.display()
    );
    println!(
        "dirs      workouts/ {}  vitals/ {}  plans/ {}",
        yn(r.workouts_dir),
        yn(r.vitals_dir),
        yn(r.plans_dir)
    );
    if r.index.present {
        println!(
            "index     present, parse {}  {} entries  missing files {}  unindexed files {}",
            if r.index.parse_ok { "ok" } else { "FAILED" },
            r.index.entries,
            r.index.missing_files.len(),
            r.index.unindexed_files.len()
        );
        for f in &r.index.missing_files {
            println!("          missing: {f}");
        }
        for f in &r.index.unindexed_files {
            println!("          unindexed: {f}");
        }
        if let Some(e) = &r.index.error {
            println!("          {e}");
        }
    } else {
        println!("index     absent, listing scans workouts/ (fine, the app writes index.json)");
    }
    let bytes: u64 = r.workouts.iter().map(|f| f.bytes).sum();
    println!(
        "workouts  {} files, {} KB, {} ok, {} failed",
        r.workouts.len(),
        bytes / 1024,
        r.workouts.iter().filter(|f| f.ok).count(),
        r.workouts.iter().filter(|f| !f.ok).count()
    );
    for (schema, n) in &r.schema_counts {
        println!("          {schema}: {n}");
    }
    for f in r.workouts.iter().filter(|f| !f.ok) {
        println!(
            "          FAILED {}: {}",
            f.file,
            f.error.clone().unwrap_or_default()
        );
    }
    if !r.duplicates_dropped.is_empty() {
        println!(
            "dedupe    {} duplicate(s) hidden: {}",
            r.duplicates_dropped.len(),
            r.duplicates_dropped.join(", ")
        );
    }
    println!(
        "vitals    {} files, {} failed",
        r.vitals.len(),
        r.vitals.iter().filter(|f| !f.ok).count()
    );
    for f in r.vitals.iter().filter(|f| !f.ok) {
        println!(
            "          FAILED {}: {}",
            f.file,
            f.error.clone().unwrap_or_default()
        );
    }
    println!(
        "plans     {} plans ({} failed), {} status files ({} failed)",
        r.plans.len(),
        r.plans.iter().filter(|f| !f.ok).count(),
        r.plan_statuses.len(),
        r.plan_statuses.iter().filter(|f| !f.ok).count()
    );
    for f in r
        .plans
        .iter()
        .chain(r.plan_statuses.iter())
        .filter(|f| !f.ok)
    {
        println!(
            "          FAILED {}: {}",
            f.file,
            f.error.clone().unwrap_or_default()
        );
    }
    println!(
        "days      {}{} files, {} failed",
        if r.days_dir { "" } else { "(no days/ yet) " },
        r.days.len(),
        r.days.iter().filter(|f| !f.ok).count()
    );
    for f in r.days.iter().filter(|f| !f.ok) {
        println!(
            "          FAILED {}: {}",
            f.file,
            f.error.clone().unwrap_or_default()
        );
    }
    let one = |label: &str, f: &Option<healthaccess_core::store::FileCheck>| match f {
        None => println!("{label} absent"),
        Some(c) if c.ok => println!("{label} present, parse ok"),
        Some(c) => println!(
            "{label} present, parse FAILED: {}",
            c.error.clone().unwrap_or_default()
        ),
    };
    one("catalog  ", &r.catalog);
    one("profile  ", &r.profile);
    println!(
        "ecg       {} files, {} failed",
        r.ecgs.len(),
        r.ecgs.iter().filter(|f| !f.ok).count()
    );
    match &r.coverage {
        Some(c) => {
            println!(
                "coverage  {} types in the catalog, {} with data, {} exported; this build knows {} ({})",
                c.catalog_types, c.with_data, c.exported, c.known_types, c.sdk
            );
            println!(
                "          types with data not exported: {}",
                if c.types_with_data_not_exported.is_empty() {
                    "none".to_string()
                } else {
                    c.types_with_data_not_exported.join(", ")
                }
            );
            println!(
                "          unknown types with data: {}",
                if c.unknown_types_with_data.is_empty() {
                    "none".to_string()
                } else {
                    c.unknown_types_with_data.join(", ")
                }
            );
        }
        None => println!(
            "coverage  no catalog.json to check against the {} types this build knows",
            healthaccess_core::hk_types::count()
        ),
    }
    if r.clients.is_empty() {
        println!("clients   none yet (mcp/clients/ is written when an AI connects)");
    } else {
        println!(
            "clients   {}",
            r.clients
                .iter()
                .map(|c| format!(
                    "{} {} on {} (last seen {}, {} calls)",
                    c.client.name,
                    c.client.version,
                    c.machine,
                    c.last_seen.format("%Y-%m-%d %H:%MZ"),
                    c.calls
                ))
                .collect::<Vec<_>>()
                .join("; ")
        );
    }
    for w in &r.warnings {
        println!("warning   {w}");
    }
    println!(
        "{}",
        if r.healthy() {
            "healthy"
        } else {
            "PROBLEMS FOUND"
        }
    );
    Ok(r.healthy())
}

fn cmd_prompts(json: bool) -> anyhow::Result<()> {
    let all = prompts::all();
    if json {
        let v: Vec<_> = all
            .iter()
            .map(|p| {
                serde_json::json!({"id": p.id, "title": p.title, "args": p.args_text(), "text": p.text})
            })
            .collect();
        return print_json(&v);
    }
    let mut t = Table::new(&[("ID", false), ("TITLE", false), ("ARGS", false)]);
    for p in all {
        t.row(vec![p.id.clone(), p.title.clone(), p.args_text()]);
    }
    print!("{}", t.render());
    println!("`healthaccess prompt <id>` prints the text. Every prompt asks the athlete first.");
    Ok(())
}

fn cmd_prompt(id: &str, json: bool) -> anyhow::Result<()> {
    let Some(p) = prompts::get(id) else {
        bail!(
            "no prompt {id:?}; the prompts are {}",
            prompts::ids().join(", ")
        );
    };
    if json {
        return print_json(
            &serde_json::json!({"id": p.id, "title": p.title, "args": p.args_text(), "text": p.text}),
        );
    }
    println!("{}", p.text);
    Ok(())
}

fn cmd_day(store: &Store, date: &str, json: bool) -> anyhow::Result<()> {
    let date = NaiveDate::parse_from_str(date.trim(), "%Y-%m-%d")
        .with_context(|| format!("{date:?}: use YYYY-MM-DD"))?;
    let Some(day) = store.day(date)? else {
        bail!("no days/{date}.json (the app writes one file per day from v0.4 on)");
    };
    if json {
        return print_json(&day);
    }
    println!("{date}  groups: {}", day.groups().join(", "));
    println!("{}", serde_json::to_string_pretty(&day)?);
    Ok(())
}

fn cmd_days(
    store: &Store,
    from: &str,
    to: &str,
    groups: Option<String>,
    json: bool,
) -> anyhow::Result<()> {
    let parse = |s: &str| {
        NaiveDate::parse_from_str(s.trim(), "%Y-%m-%d")
            .with_context(|| format!("{s:?}: use YYYY-MM-DD"))
    };
    let (from, to) = (parse(from)?, parse(to)?);
    if to < from {
        bail!("--to {to} is before --from {from}");
    }
    let keep: Option<Vec<String>> = groups.map(|g| {
        g.split(',')
            .map(|x| x.trim().to_ascii_lowercase())
            .filter(|x| !x.is_empty())
            .collect()
    });
    let days = store.days(from, to)?;
    let rows: Vec<serde_json::Value> = days
        .iter()
        .map(|d| {
            let mut v = serde_json::to_value(d).unwrap_or_default();
            if let (Some(keep), Some(obj)) = (&keep, v.as_object_mut()) {
                obj.retain(|k, _| k == "date" || k == "schema" || keep.contains(k));
            }
            v
        })
        .collect();
    if json {
        return print_json(
            &serde_json::json!({"from": from, "to": to, "count": rows.len(), "days": rows}),
        );
    }
    if rows.is_empty() {
        println!("no days/<date>.json between {from} and {to}");
        return Ok(());
    }
    for (d, v) in days.iter().zip(&rows) {
        println!("# {}  groups: {}", d.date, d.groups().join(", "));
        println!("{}", serde_json::to_string_pretty(v)?);
    }
    Ok(())
}

fn cmd_catalog(store: &Store, json: bool) -> anyhow::Result<()> {
    let Some(catalog) = store.catalog()? else {
        if json {
            return print_json(&serde_json::json!({"catalog": null, "coverage": null,
                "known_types": healthaccess_core::hk_types::count(), "sdk": healthaccess_core::hk_types::SDK}));
        }
        println!(
            "no catalog.json yet (the app writes it after every sync from v0.4 on); this build knows {} HealthKit types ({})",
            healthaccess_core::hk_types::count(),
            healthaccess_core::hk_types::SDK
        );
        return Ok(());
    };
    let coverage = healthaccess_core::Coverage::of(&catalog);
    if json {
        return print_json(&serde_json::json!({"coverage": coverage, "catalog": catalog}));
    }
    println!(
        "catalog   written {}  app {}  {} types listed, {} with data, {} exported",
        coverage
            .generated
            .map(|g| g.format("%Y-%m-%d %H:%MZ").to_string())
            .unwrap_or_else(|| NONE.into()),
        coverage.app_version.clone().unwrap_or_else(|| NONE.into()),
        coverage.catalog_types,
        coverage.with_data,
        coverage.exported
    );
    println!(
        "build     knows {} types ({}); {} of them missing from the catalog",
        coverage.known_types,
        coverage.sdk,
        coverage.known_types_missing_from_catalog.len()
    );
    println!(
        "types with data not exported: {}",
        if coverage.types_with_data_not_exported.is_empty() {
            "none".to_string()
        } else {
            coverage.types_with_data_not_exported.join(", ")
        }
    );
    println!(
        "unknown types with data:      {}",
        if coverage.unknown_types_with_data.is_empty() {
            "none".to_string()
        } else {
            coverage.unknown_types_with_data.join(", ")
        }
    );
    let mut t = Table::new(&[
        ("TYPE", false),
        ("KIND", false),
        ("SAMPLES 90D", true),
        ("FIRST", false),
        ("LAST", false),
        ("EXPORTED IN", false),
    ]);
    for (id, ty) in catalog.types.iter().filter(|(_, t)| t.has_data) {
        t.row(vec![
            id.clone(),
            ty.kind.clone().unwrap_or_else(|| NONE.into()),
            opt_num(ty.samples_90d, 0),
            ty.first.clone().unwrap_or_else(|| NONE.into()),
            ty.last.clone().unwrap_or_else(|| NONE.into()),
            ty.exported_in.clone().unwrap_or_else(|| NONE.into()),
        ]);
    }
    println!();
    print!("{}", t.render());
    Ok(())
}

fn cmd_profile(store: &Store, json: bool) -> anyhow::Result<()> {
    match store.profile()? {
        Some(p) => print_json(&p),
        None if json => print_json(&serde_json::json!({"profile": null})),
        None => {
            println!("no profile.json yet (the app writes it from v0.4 on)");
            Ok(())
        }
    }
}

fn cmd_ecgs(store: &Store, json: bool) -> anyhow::Result<()> {
    let ecgs = store.ecgs()?;
    if json {
        return print_json(&ecgs);
    }
    if ecgs.is_empty() {
        println!("no ECGs in ecg/ yet");
        return Ok(());
    }
    let mut t = Table::new(&[
        ("AT", false),
        ("CLASSIFICATION", false),
        ("SYMPTOMS", false),
        ("AVG HR", true),
        ("HZ", true),
        ("VOLTAGE", false),
        ("FILE", false),
    ]);
    for e in &ecgs {
        t.row(vec![
            e.at.map(|a| a.format("%Y-%m-%d %H:%MZ").to_string())
                .unwrap_or_else(|| NONE.into()),
            e.classification.clone().unwrap_or_else(|| NONE.into()),
            e.symptoms_status.clone().unwrap_or_else(|| NONE.into()),
            opt_num(e.average_heart_rate, 0),
            opt_num(e.sampling_frequency_hz, 0),
            if e.voltage_file.is_some() {
                "yes"
            } else {
                "no"
            }
            .to_string(),
            e.file.clone(),
        ]);
    }
    print!("{}", t.render());
    println!("{} ECGs", ecgs.len());
    Ok(())
}

fn cmd_briefing(store: &Store, json: bool) -> anyhow::Result<()> {
    let b = store.briefing()?;
    if json {
        return print_json(&b);
    }
    print!("{}", b.text);
    if !b.text.ends_with('\n') {
        println!();
    }
    Ok(())
}

/// The tool-like name of a subcommand for the handshake file.
fn command_name(cmd: &Cmd) -> &'static str {
    match cmd {
        Cmd::List { .. } => "list",
        Cmd::Show { .. } => "show",
        Cmd::Summary { .. } => "summary",
        Cmd::Rate { .. } => "rate",
        Cmd::Plan { cmd } => match cmd {
            PlanCmd::Push { .. } => "plan push",
            PlanCmd::Status { .. } => "plan status",
            PlanCmd::List => "plan list",
        },
        Cmd::WorkoutFile { .. } => "workout-file",
        Cmd::Doctor => "doctor",
        Cmd::Briefing => "briefing",
        Cmd::Prompts => "prompts",
        Cmd::Prompt { .. } => "prompt",
        Cmd::Day { .. } => "day",
        Cmd::Days { .. } => "days",
        Cmd::Catalog => "catalog",
        Cmd::Profile => "profile",
        Cmd::Ecgs => "ecgs",
    }
}

fn run(cli: Cli) -> anyhow::Result<bool> {
    match cli.cmd {
        Cmd::WorkoutFile { plan, out, uuid } => {
            cmd_workout_file(plan, out, uuid)?;
            return Ok(true);
        }
        Cmd::Prompts => {
            cmd_prompts(cli.json)?;
            return Ok(true);
        }
        Cmd::Prompt { ref id } => {
            cmd_prompt(id, cli.json)?;
            return Ok(true);
        }
        _ => {}
    }
    let cfg = config::load()?;
    let dir = config::resolve_dir(cli.dir.as_deref())?;
    let store = Store::open(&dir)
        .with_context(|| format!("opening {}", dir.display()))?
        .with_zone_bounds(cfg.zone_bounds());
    // the handshake the app reads to show "Connected": only commands that write into the
    // folder leave one (reads stay reads); a failure never stops a command
    if matches!(
        cli.cmd,
        Cmd::Rate { .. }
            | Cmd::Plan {
                cmd: PlanCmd::Push { .. }
            }
    ) {
        let _ = store.record_client(
            &healthaccess_core::ClientInfo {
                name: "healthaccess-cli".to_string(),
                version: healthaccess_core::VERSION.to_string(),
            },
            Some(command_name(&cli.cmd)),
            1,
        );
    }
    match cli.cmd {
        Cmd::List {
            since,
            sport,
            limit,
        } => cmd_list(&store, since, sport, limit, cli.json)?,
        Cmd::Show { id, hr } => cmd_show(&store, &id, hr, cli.json)?,
        Cmd::Summary { weeks } => cmd_summary(&store, weeks, cli.json)?,
        Cmd::Rate {
            id,
            effort,
            override_apple,
            feel,
        } => cmd_rate(&store, &id, effort, feel, override_apple, cli.json)?,
        Cmd::Plan { cmd } => cmd_plan(&store, cmd, cli.json)?,
        Cmd::Doctor => return cmd_doctor(&store, cli.json),
        Cmd::Briefing => cmd_briefing(&store, cli.json)?,
        Cmd::Day { date } => cmd_day(&store, &date, cli.json)?,
        Cmd::Days { from, to, groups } => cmd_days(&store, &from, &to, groups, cli.json)?,
        Cmd::Catalog => cmd_catalog(&store, cli.json)?,
        Cmd::Profile => cmd_profile(&store, cli.json)?,
        Cmd::Ecgs => cmd_ecgs(&store, cli.json)?,
        Cmd::WorkoutFile { .. } | Cmd::Prompts | Cmd::Prompt { .. } => {
            unreachable!("handled above")
        }
    }
    Ok(true)
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(1),
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::from(1)
        }
    }
}
