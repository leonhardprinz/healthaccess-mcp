//! End-to-end: spawn the binary, speak JSON-RPC over stdio.

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};

use serde_json::{json, Value};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../core/tests/fixtures")
}

struct Session {
    child: std::process::Child,
    stdin: std::process::ChildStdin,
    reader: BufReader<std::process::ChildStdout>,
}

impl Session {
    fn start(dir: &std::path::Path) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_healthaccess-mcp"))
            .arg("--dir")
            .arg(dir)
            .env_remove("HEALTHACCESS_DIR")
            .env_remove("TIDE_DIR")
            .env("HEALTHACCESS_CONFIG", dir.join("no-config.toml"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn healthaccess-mcp");
        let stdin = child.stdin.take().unwrap();
        let reader = BufReader::new(child.stdout.take().unwrap());
        Session {
            child,
            stdin,
            reader,
        }
    }

    fn send(&mut self, msg: Value) {
        let mut line = msg.to_string();
        line.push('\n');
        self.stdin.write_all(line.as_bytes()).unwrap();
        self.stdin.flush().unwrap();
    }

    fn recv(&mut self) -> Value {
        let mut line = String::new();
        let n = self.reader.read_line(&mut line).unwrap();
        assert!(n > 0, "server closed stdout");
        serde_json::from_str(&line).unwrap_or_else(|e| panic!("bad JSON {e}: {line}"))
    }

    fn call(&mut self, id: u64, method: &str, params: Value) -> Value {
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        let resp = self.recv();
        assert_eq!(resp["id"], id, "{resp}");
        assert!(resp.get("error").is_none(), "error response: {resp}");
        resp["result"].clone()
    }

    fn tool_text(&mut self, id: u64, name: &str, args: Value) -> (bool, Value) {
        let result = self.call(id, "tools/call", json!({"name": name, "arguments": args}));
        let is_error = result["isError"].as_bool().unwrap_or(false);
        let text = result["content"][0]["text"].as_str().expect("text content");
        let value = serde_json::from_str(text).unwrap_or_else(|_| Value::String(text.to_string()));
        (is_error, value)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn full_stdio_session() {
    let tmp = tempfile::tempdir().unwrap();
    let w = tmp.path().join("workouts");
    std::fs::create_dir_all(&w).unwrap();
    for entry in std::fs::read_dir(fixtures()).unwrap().flatten() {
        if entry.path().extension().is_some_and(|x| x == "json") {
            std::fs::copy(entry.path(), w.join(entry.file_name())).unwrap();
        }
    }
    let mut s = Session::start(tmp.path());

    let init = s.call(
        1,
        "initialize",
        json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}),
    );
    assert_eq!(init["serverInfo"]["name"], "healthaccess-mcp");
    assert!(init["capabilities"]["tools"].is_object());
    assert!(init["capabilities"]["resources"].is_object());
    assert!(init["capabilities"]["prompts"].is_object(), "{init}");
    let instructions = init["instructions"].as_str().unwrap();
    assert!(instructions.contains("push_plan"));
    assert!(instructions.contains("middleware") && instructions.contains("The folder is the API"));
    assert!(instructions.contains("Never invent an effort rating"));
    assert!(
        !instructions.contains('\u{2014}'),
        "no em dashes in the instructions"
    );
    s.send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));

    let tools = s.call(2, "tools/list", json!({}));
    let mut names: Vec<&str> = tools["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    names.sort_unstable();
    assert_eq!(
        names,
        [
            "get_catalog",
            "get_day",
            "get_days",
            "get_plan_status",
            "get_profile",
            "get_vitals",
            "get_workout",
            "list_ecgs",
            "list_plans",
            "list_workouts",
            "push_plan",
            "rate_workout",
            "training_summary"
        ]
    );
    let push = tools["tools"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "push_plan")
        .unwrap();
    assert!(
        push["inputSchema"]["properties"]["plan"].is_object(),
        "{push}"
    );
    let rate = tools["tools"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["name"] == "rate_workout")
        .unwrap();
    assert!(rate["description"].as_str().unwrap().contains(
        "only after the athlete told you the number; Apple's own rating wins unless the athlete asks to change it"
    ));
    assert!(
        rate["inputSchema"]["properties"]["override"].is_object(),
        "{rate}"
    );
    for t in tools["tools"].as_array().unwrap() {
        assert!(
            !t["description"].as_str().unwrap().contains('\u{2014}'),
            "em dash in {}",
            t["name"]
        );
    }

    // prompts: the six of docs/prompts.md, text byte-identical to the file
    let prompts = s.call(23, "prompts/list", json!({}));
    let names: Vec<&str> = prompts["prompts"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "weekly_checkin",
            "explain_last_session",
            "overdoing_it",
            "sleep_and_recovery",
            "long_term_trends",
            "coach_summary",
            "next_session",
            "plan_my_week",
            "adjust_plans",
            "build_up_to_goal",
            "convert_workout"
        ]
    );
    let explain = &prompts["prompts"][1];
    assert_eq!(explain["title"], "Explain my last session");
    assert_eq!(explain["arguments"][0]["name"], "id");
    assert_eq!(explain["arguments"][0]["required"], false);
    assert_eq!(prompts["prompts"][5]["arguments"][0]["name"], "weeks");
    assert!(prompts["prompts"][0].get("arguments").is_none());
    let got = s.call(24, "prompts/get", json!({"name": "next_session"}));
    assert_eq!(got["description"], "Plan my next session");
    assert_eq!(got["messages"].as_array().unwrap().len(), 1);
    assert_eq!(got["messages"][0]["role"], "user");
    assert_eq!(
        got["messages"][0]["content"]["text"].as_str().unwrap(),
        expected_prompt_body("next_session")
    );
    let got = s.call(
        25,
        "prompts/get",
        json!({"name": "explain_last_session", "arguments": {"id": "7a1c3e90"}}),
    );
    assert_eq!(
        got["messages"][0]["content"]["text"].as_str().unwrap(),
        expected_prompt_body("explain_last_session")
    );
    assert_eq!(
        got["messages"][1]["content"]["text"],
        "The session to explain: id 7a1c3e90."
    );
    let got = s.call(26, "prompts/get", json!({"name": "coach_summary"}));
    assert_eq!(got["messages"].as_array().unwrap().len(), 1);
    assert_eq!(
        got["messages"][0]["content"]["text"].as_str().unwrap(),
        expected_prompt_body("coach_summary")
    );
    s.send(
        json!({"jsonrpc": "2.0", "id": 27, "method": "prompts/get", "params": {"name": "nope"}}),
    );
    let resp = s.recv();
    assert!(resp["error"]["message"]
        .as_str()
        .unwrap()
        .contains("unknown prompt"));
    s.send(json!({"jsonrpc": "2.0", "id": 28, "method": "prompts/get",
                  "params": {"name": "coach_summary", "arguments": {"days": "7"}}}));
    let resp = s.recv();
    assert!(
        resp["error"].is_object(),
        "unknown argument is an error: {resp}"
    );

    let (err, list) = s.tool_text(3, "list_workouts", json!({"limit": 5}));
    assert!(!err);
    assert_eq!(list["returned"], 2);
    assert_eq!(list["rows"][0]["short_id"], "7A1C3E90");
    assert_eq!(list["rows"][0]["rated"], true);
    assert_eq!(list["rows"][0]["effort_source"], "apple");
    assert_eq!(list["rows"][0]["plan_name"], "S12");
    assert!(list["rows"][0]["summary"]
        .as_str()
        .unwrap()
        .contains("1200 m"));

    let (err, swims) = s.tool_text(
        4,
        "list_workouts",
        json!({"sport": "swim", "since": "2026-05-01"}),
    );
    assert!(!err);
    assert_eq!(swims["returned"], 1);

    let (err, w) = s.tool_text(5, "get_workout", json!({"id": "7a1c3e90"}));
    assert!(!err, "{w}");
    assert_eq!(w["activity"], "pool_swim");
    assert!(
        w["hr_series"].is_null() || w["hr_series"].as_array().map(Vec::is_empty).unwrap_or(true)
    );
    assert!(w["laps"].as_array().unwrap().len() > 10);
    assert_eq!(w["steps"][0]["key"], "0.0.0");
    assert_eq!(w["cardiac_cost"]["best_100_pace_s"], 132);
    let parts = w["parts_text"].as_array().unwrap();
    assert_eq!(parts.len(), w["steps"].as_array().unwrap().len());
    assert_eq!(
        parts[0],
        "FR easy, find your breathing · 200 m · 2:20/100 · HR 100"
    );
    assert!(
        parts
            .iter()
            .any(|p| p == "FR 100 steady, breathe every 3 · 100 m · 2:12/100 · HR 151"),
        "{parts:?}"
    );
    assert_eq!(w["effort_source"], "apple");
    assert_eq!(w["effort_estimated"], 5);
    assert!(
        w["zones"].is_null(),
        "no config, no profile, no zones in the file: {}",
        w["zones"]
    );
    assert!(!w["summary"].as_str().unwrap().contains("Z1–2"));
    // the athlete's age in profile.json gives estimated bounds
    std::fs::write(
        tmp.path().join("profile.json"),
        json!({"age": 34}).to_string(),
    )
    .unwrap();
    let (_, w) = s.tool_text(36, "get_workout", json!({"id": "7a1c3e90"}));
    assert_eq!(w["zones"]["bounds_source"], "estimated");
    assert_eq!(w["zones"]["bounds"], json!([133, 146, 158, 169]));
    assert!(
        w["summary"].as_str().unwrap().contains("Z1–2 93%"),
        "{}",
        w["summary"]
    );
    std::fs::remove_file(tmp.path().join("profile.json")).unwrap();

    // the handshake the phone app reads to show "Connected"
    let id = healthaccess_core::handshake::client_id(
        &healthaccess_core::handshake::machine_name(),
        "test",
    );
    let handshake_path = tmp
        .path()
        .join("mcp")
        .join("clients")
        .join(format!("{id}.json"));
    assert!(handshake_path.is_file(), "{}", handshake_path.display());
    let handshake: Value =
        serde_json::from_str(&std::fs::read_to_string(&handshake_path).unwrap()).unwrap();
    assert_eq!(handshake["schema"], "healthaccess.client.v1");
    assert_eq!(handshake["client"]["name"], "test");
    assert_eq!(handshake["client"]["version"], "0");
    assert_eq!(handshake["mcp_version"], healthaccess_core::VERSION);
    assert!(handshake.get("arguments").is_none() && handshake.get("results").is_none());

    let (err, w) = s.tool_text(
        6,
        "get_workout",
        json!({"id": "7a1c3e90", "include_hr_series": true, "include_laps": false}),
    );
    assert!(!err);
    assert!(w["hr_series"].as_array().unwrap().len() > 400);
    assert!(w["laps"].as_array().unwrap().is_empty());

    let (err, missing) = s.tool_text(7, "get_workout", json!({"id": "deadbeef"}));
    assert!(err, "{missing}");
    assert!(missing.as_str().unwrap().contains("not found"));

    let (err, summary) = s.tool_text(8, "training_summary", json!({"weeks": 104}));
    assert!(!err);
    assert_eq!(summary["weeks"].as_array().unwrap().len(), 104);
    assert_eq!(summary["workouts_considered"], 2);

    let (err, vitals) = s.tool_text(9, "get_vitals", json!({}));
    assert!(!err);
    assert_eq!(vitals["count"], 0);

    let (err, plan) = s.tool_text(
        10,
        "push_plan",
        json!({"plan": {"name": "S27", "sport": "pool_swim", "pool_length_m": 50,
            "warmup": {"goal": {"type": "time_s", "value": 120}, "zone": 1},
            "blocks": [{"repeat": 4, "steps": [
                {"kind": "work", "goal": {"type": "distance_m", "value": 100}, "zone": 3, "label": "100 steady FR"},
                {"kind": "recovery", "goal": {"type": "time_s", "value": 30}}]}],
            "cooldown": {"goal": {"type": "distance_m", "value": 100}, "zone": 1},
            "notes": "threshold touch", "scheduled_for": "2026-10-26T07:30:00Z"}}),
    );
    assert!(!err, "{plan}");
    let id = plan["id"].as_str().unwrap().to_string();
    assert!(id.ends_with("-s27"));
    assert!(tmp
        .path()
        .join("plans")
        .join(format!("{id}.json"))
        .is_file());
    assert_eq!(plan["planned_distance_m"], 500);

    let (err, bad) = s.tool_text(
        11,
        "push_plan",
        json!({"plan": {"name": "bad", "sport": "skiing", "blocks": []}}),
    );
    assert!(err);
    assert!(bad.as_str().unwrap().contains("sport"));

    let (err, status) = s.tool_text(12, "get_plan_status", json!({"id": id}));
    assert!(!err);
    assert_eq!(status["state"], "pending");
    std::fs::write(
        tmp.path().join("plans").join(format!("{id}.status.json")),
        json!({"plan_id": id, "state": "scheduled", "at": "2026-10-25T20:00:00Z", "error": null})
            .to_string(),
    )
    .unwrap();
    let (_, status) = s.tool_text(13, "get_plan_status", json!({"id": id}));
    assert_eq!(status["state"], "scheduled");

    let (err, plans) = s.tool_text(14, "list_plans", json!({}));
    assert!(!err);
    assert_eq!(plans["count"], 1);
    assert_eq!(plans["plans"][0]["state"], "scheduled");

    // the example swim carries the athlete's own Apple rating: refused as is
    let (err, refused) = s.tool_text(
        15,
        "rate_workout",
        json!({"id": "7a1c3e90", "effort": 6, "feel": "legs heavy"}),
    );
    assert!(err, "{refused}");
    assert!(refused.as_str().unwrap().contains("Apple"), "{refused}");
    let (err, rated) = s.tool_text(
        35,
        "rate_workout",
        json!({"id": "7a1c3e90", "effort": 6, "feel": "legs heavy", "override": true}),
    );
    assert!(!err, "{rated}");
    assert_eq!(rated["effort"], 6);
    assert_eq!(rated["effort_source"], "ai");
    assert_eq!(rated["previous_effort"], 6);
    assert_eq!(rated["previous_source"], "apple");
    let (_, w) = s.tool_text(16, "get_workout", json!({"id": "7a1c3e90"}));
    assert_eq!(w["effort"], 6);
    assert_eq!(w["effort_source"], "ai");
    assert_eq!(w["feel"], "legs heavy");
    let (_, list) = s.tool_text(29, "list_workouts", json!({"sport": "swim"}));
    assert_eq!(list["rows"][0]["rated"], true);
    assert_eq!(list["rows"][0]["effort_source"], "ai");

    // the athlete's own Apple rating is kept unless the athlete asks to change it
    let row_path = tmp
        .path()
        .join("workouts")
        .join("2026-05-12_0630_IndoorRow_3F8B2D41.json");
    let mut doc: Value =
        serde_json::from_str(&std::fs::read_to_string(&row_path).unwrap()).unwrap();
    doc["effort"] = json!(7);
    doc["effort_source"] = json!("apple");
    std::fs::write(&row_path, doc.to_string()).unwrap();
    let (err, refused) = s.tool_text(30, "rate_workout", json!({"id": "3f8b2d41", "effort": 3}));
    assert!(err, "{refused}");
    let msg = refused.as_str().unwrap();
    assert!(msg.contains("Apple") && msg.contains("7/10"), "{msg}");
    assert!(
        !msg.starts_with("rate_workout failed"),
        "plain message: {msg}"
    );
    let (_, w) = s.tool_text(31, "get_workout", json!({"id": "3f8b2d41"}));
    assert_eq!(w["effort"], 7);
    assert_eq!(w["effort_source"], "apple");
    let (err, rated) = s.tool_text(
        32,
        "rate_workout",
        json!({"id": "3f8b2d41", "effort": 3, "override": true}),
    );
    assert!(!err, "{rated}");
    assert_eq!(rated["effort_source"], "ai");
    assert_eq!(rated["previous_source"], "apple");
    assert_eq!(rated["previous_effort"], 7);

    let resources = s.call(17, "resources/list", json!({}));
    let uris: Vec<&str> = resources["resources"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["uri"].as_str().unwrap())
        .collect();
    assert!(uris.contains(&"healthaccess://index"));
    assert_eq!(uris[0], "healthaccess://briefing");
    let briefing = resources["resources"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["uri"] == "healthaccess://briefing")
        .unwrap();
    assert_eq!(briefing["mimeType"], "text/markdown");
    assert!(uris
        .iter()
        .any(|u| u.starts_with("healthaccess://workout/7A1C3E90")));
    assert!(
        !uris.iter().any(|u| u.starts_with("tide://")),
        "pre-rename URIs are aliases, not advertised"
    );
    let read = s.call(
        18,
        "resources/read",
        json!({"uri": "healthaccess://workout/7a1c3e90"}),
    );
    let text = read["contents"][0]["text"].as_str().unwrap();
    let doc: Value = serde_json::from_str(text).unwrap();
    assert_eq!(doc["schema"], "healthaccess.workout.v1");
    let read = s.call(19, "resources/read", json!({"uri": "healthaccess://index"}));
    let doc: Value = serde_json::from_str(read["contents"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(doc["workouts"].as_array().unwrap().len(), 2);
    // pre-rename URIs still resolve (alias)
    let read = s.call(
        20,
        "resources/read",
        json!({"uri": "tide://workout/7a1c3e90"}),
    );
    let doc: Value = serde_json::from_str(read["contents"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(doc["id"], "7A1C3E90-5B2D-4F61-9C8E-2A7D40B6E1F3");
    let read = s.call(21, "resources/read", json!({"uri": "tide://index"}));
    assert!(read["contents"][0]["text"]
        .as_str()
        .unwrap()
        .contains("7A1C3E90"));

    s.send(json!({"jsonrpc": "2.0", "id": 22, "method": "resources/read", "params": {"uri": "healthaccess://nope"}}));
    let resp = s.recv();
    assert!(resp["error"].is_object(), "{resp}");

    // the briefing: generated from the folder until the app writes briefing.md
    let read = s.call(
        33,
        "resources/read",
        json!({"uri": "healthaccess://briefing"}),
    );
    assert_eq!(read["contents"][0]["mimeType"], "text/markdown");
    let text = read["contents"][0]["text"].as_str().unwrap();
    let first = text.lines().next().unwrap();
    assert!(
        first.starts_with("# Health Access briefing for the athlete, written "),
        "{first}"
    );
    assert!(
        first.contains("healthaccess-mcp") && first.contains("not by the app"),
        "{first}"
    );
    for heading in [
        "## Last 4 weeks",
        "## Recent sessions",
        "## Vitals",
        "## Next session",
        "## Open",
        "## Limits",
    ] {
        assert!(text.contains(heading), "missing {heading}: {text}");
    }
    assert!(
        text.contains("## Next session\n- none"),
        "S27 was scheduled earlier in this test: {text}"
    );
    assert!(
        text.contains("effort 6/10 (ai)") && text.contains("effort 3/10 (ai)"),
        "{text}"
    );
    assert!(
        text.contains("## Open\n- nothing"),
        "both sessions rated, S27 scheduled: {text}"
    );
    std::fs::write(
        tmp.path().join("briefing.md"),
        "# Health Access briefing for Alex, written 2026-10-25T08:00Z\n\n## Last 4 weeks\n- app text\n",
    )
    .unwrap();
    let read = s.call(
        34,
        "resources/read",
        json!({"uri": "healthaccess://briefing"}),
    );
    assert!(read["contents"][0]["text"]
        .as_str()
        .unwrap()
        .starts_with("# Health Access briefing for Alex"));
}

#[test]
fn days_catalog_profile_and_ecg_tools() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(tmp.path().join("workouts")).unwrap();
    let mut s = Session::start(tmp.path());
    s.call(
        1,
        "initialize",
        json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}),
    );
    s.send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));

    let (err, missing) = s.tool_text(2, "get_day", json!({"date": "2026-10-24"}));
    assert!(err, "{missing}");
    assert!(missing.as_str().unwrap().contains("days/2026-10-24.json"));
    let (err, bad) = s.tool_text(3, "get_day", json!({"date": "yesterday"}));
    assert!(err && bad.as_str().unwrap().contains("YYYY-MM-DD"));

    std::fs::create_dir_all(tmp.path().join("days")).unwrap();
    for (date, rhr) in [("2026-10-23", 60), ("2026-10-24", 61)] {
        std::fs::write(
            tmp.path().join("days").join(format!("{date}.json")),
            json!({"schema": "healthaccess.day.v1", "date": date,
                   "activity": {"rings": {"move_kcal": {"goal": 600, "actual": 650}}, "steps": 8000, "physical_effort_avg_met": 2.1},
                   "heart": {"resting_hr": rhr, "hrv_sdnn_ms": 41.5},
                   "sleep": {"asleep_s": 25000},
                   "mind": {"mindful_minutes": 5}})
            .to_string(),
        )
        .unwrap();
    }
    let (err, day) = s.tool_text(4, "get_day", json!({"date": "2026-10-24"}));
    assert!(!err, "{day}");
    assert_eq!(day["file"], "days/2026-10-24.json");
    assert_eq!(day["day"]["heart"]["resting_hr"], 61);
    assert_eq!(day["day"]["mind"]["mindful_minutes"], 5);
    assert_eq!(
        day["day"]["groups"],
        json!(["activity", "heart", "sleep", "mind"])
    );

    let (err, days) = s.tool_text(
        5,
        "get_days",
        json!({"from": "2026-10-20", "to": "2026-10-25", "groups": ["heart", "sleep"]}),
    );
    assert!(!err, "{days}");
    assert_eq!(days["count"], 2);
    assert_eq!(
        days["groups_available"],
        json!(["activity", "heart", "sleep", "mind"])
    );
    assert_eq!(days["days"][0]["date"], "2026-10-23");
    assert_eq!(days["days"][0]["heart"]["resting_hr"], 60);
    assert!(
        days["days"][0].get("activity").is_none(),
        "filtered out: {days}"
    );
    assert_eq!(days["days"][1]["sleep"]["asleep_s"], 25000);
    let (err, bad) = s.tool_text(
        6,
        "get_days",
        json!({"from": "2026-10-25", "to": "2026-10-20"}),
    );
    assert!(err && bad.as_str().unwrap().contains("before"));

    // the seven-metric view reads the day files too
    let (err, vitals) = s.tool_text(7, "get_vitals", json!({"days": 3650}));
    assert!(!err);
    assert_eq!(vitals["count"], 2);
    assert_eq!(vitals["latest"]["resting_hr"], 61);
    assert_eq!(vitals["latest"]["sleep_s"], 25000);

    // training_summary carries rings and physical effort for the weeks with days
    let (err, summary) = s.tool_text(8, "training_summary", json!({"weeks": 60}));
    assert!(!err);
    assert_eq!(summary["days_considered"], 2);
    let week = summary["weeks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|w| w["week"] == "2026-W43")
        .unwrap();
    assert_eq!(week["rings"]["move_kcal"], 1300);
    assert_eq!(week["rings"]["move_goal_days"], 2);
    assert_eq!(week["mean_physical_effort_met"], 2.1);

    let (err, cat) = s.tool_text(9, "get_catalog", json!({}));
    assert!(!err);
    assert!(cat["catalog"].is_null());
    assert!(cat["known_types"].as_u64().unwrap() > 200);
    std::fs::write(
        tmp.path().join("catalog.json"),
        json!({"generated": "2026-10-25T08:00:00Z", "app_version": "0.4.0",
               "types": {
                   "HKQuantityTypeIdentifierRestingHeartRate": {"kind": "quantity", "authorized": null, "has_data": true, "samples_90d": 90, "first": "2026-07-28", "last": "2026-10-25", "exported_in": "days"},
                   "HKQuantityTypeIdentifierBodyMass": {"kind": "quantity", "authorized": null, "has_data": true, "samples_90d": 12, "first": null, "last": null, "exported_in": "none"}},
               "unknown_types_with_data": ["HKQuantityTypeIdentifierSomethingNew"]})
        .to_string(),
    )
    .unwrap();
    let (err, cat) = s.tool_text(10, "get_catalog", json!({}));
    assert!(!err, "{cat}");
    assert_eq!(cat["coverage"]["with_data"], 2);
    assert_eq!(
        cat["coverage"]["types_with_data_not_exported"],
        json!(["HKQuantityTypeIdentifierBodyMass"])
    );
    assert_eq!(
        cat["coverage"]["unknown_types_with_data"],
        json!(["HKQuantityTypeIdentifierSomethingNew"])
    );
    assert_eq!(cat["catalog"]["app_version"], "0.4.0");

    let (err, profile) = s.tool_text(11, "get_profile", json!({}));
    assert!(!err && profile["profile"].is_null());
    std::fs::write(
        tmp.path().join("profile.json"),
        json!({"age": 38, "birth_year": 1988, "biological_sex": "male"}).to_string(),
    )
    .unwrap();
    let (_, profile) = s.tool_text(12, "get_profile", json!({}));
    assert_eq!(profile["profile"]["birth_year"], 1988);

    let (err, ecgs) = s.tool_text(13, "list_ecgs", json!({}));
    assert!(!err && ecgs["count"] == 0);
    std::fs::create_dir_all(tmp.path().join("ecg")).unwrap();
    std::fs::write(
        tmp.path().join("ecg").join("2026-10-24T07-31-05Z.json"),
        json!({"classification": "sinus_rhythm", "average_heart_rate": 62}).to_string(),
    )
    .unwrap();
    let (_, ecgs) = s.tool_text(14, "list_ecgs", json!({}));
    assert_eq!(ecgs["count"], 1);
    assert_eq!(ecgs["ecgs"][0]["classification"], "sinus_rhythm");
    assert_eq!(ecgs["ecgs"][0]["at"], "2026-10-24T07:31:05Z");
    assert!(ecgs["ecgs"][0]["voltage_file"].is_null());
}

/// The body of one prompt in docs/prompts.md, computed independently of the parser:
/// everything after the `**id:**` line up to the next heading, surrounding blank lines removed.
fn expected_prompt_body(id: &str) -> String {
    let md = include_str!("../../docs/prompts.md");
    let marker = format!("**id:** `{id}`");
    let at = md.find(&marker).expect("id line");
    let after = &md[at..];
    let mut body = &after[after.find('\n').unwrap() + 1..];
    if body.starts_with("**about:**") {
        body = &body[body.find('\n').unwrap() + 1..];
    }
    let end = body.find("\n## ").map(|i| i + 1).unwrap_or(body.len());
    body[..end].trim().to_string()
}

/// Claude Code speaks the 2026-07-28 protocol: no `initialize`, a session opens with
/// `server/discover` and every request carries the client in `_meta`. The handshake file
/// must still appear, or the app shows "Not connected yet" forever.
#[test]
fn handshake_without_initialize() {
    let tmp = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(tmp.path().join("workouts")).unwrap();
    std::fs::write(
        tmp.path().join("index.json"),
        r#"{"schema":"healthaccess.index.v1","workouts":[]}"#,
    )
    .unwrap();
    let mut s = Session::start(tmp.path());
    let meta = json!({
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {"name": "claude-code", "version": "9.9.9"},
        "io.modelcontextprotocol/clientCapabilities": {}
    });
    let discovered = s.call(1, "server/discover", json!({"_meta": meta}));
    assert!(
        discovered.to_string().contains("healthaccess-mcp"),
        "{discovered}"
    );
    let tools = s.call(2, "tools/list", json!({"_meta": meta}));
    assert!(
        tools["tools"].as_array().is_some_and(|t| t.len() == 13),
        "{tools}"
    );
    let clients: Vec<_> = std::fs::read_dir(tmp.path().join("mcp/clients"))
        .expect("mcp/clients exists")
        .flatten()
        .collect();
    assert_eq!(clients.len(), 1, "one handshake file");
    let handshake: Value =
        serde_json::from_str(&std::fs::read_to_string(clients[0].path()).unwrap()).unwrap();
    assert_eq!(handshake["client"]["name"], "claude-code");
    assert_eq!(handshake["client"]["version"], "9.9.9");
}
