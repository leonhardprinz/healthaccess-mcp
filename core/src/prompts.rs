//! The prompts of `docs/prompts.md`, parsed from that file at build time so the
//! Markdown stays the single source: the MCP server (`prompts/list`, `prompts/get`),
//! the CLI (`healthaccess prompts`, `healthaccess prompt <id>`), the app's copy and
//! the site all show the same text.
//!
//! The crate root carries `prompts.md`, a symlink to `../docs/prompts.md`, so
//! `include_str!` finds the file both in the workspace and in the packaged crate
//! (`cargo package` follows the link and stores a regular file).

use std::sync::OnceLock;

/// `docs/prompts.md`, byte for byte.
pub const PROMPTS_MD: &str = include_str!("../prompts.md");

/// One argument of a prompt, from the `**args:**` line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptArg {
    pub name: String,
    /// `false` when the note says `optional` or gives a default.
    pub required: bool,
    /// The default from a note like `default 4`.
    pub default: Option<String>,
    /// The parenthesised note as written, e.g. `optional` or `default 4`.
    pub note: Option<String>,
}

impl PromptArg {
    /// `id (optional)` or `weeks (default 4)` or just the name.
    pub fn describe(&self) -> String {
        match &self.note {
            Some(n) => format!("{} ({n})", self.name),
            None => self.name.clone(),
        }
    }
}

/// One prompt: its id, title, arguments and the body text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PromptDef {
    /// Position in the file (1-based), the heading number.
    pub number: u32,
    /// The MCP prompt name, e.g. `next_session`.
    pub id: String,
    /// The heading, e.g. `Plan my next session`.
    pub title: String,
    /// `export` (reads and explains what the Watch recorded) or `plans` (writes sessions
    /// for the Watch), from the `**group:**` part of the id line; `export` when absent.
    pub group: String,
    /// One sentence about the prompt, from the `**about:**` line under the id line.
    pub about: String,
    pub args: Vec<PromptArg>,
    /// Everything after the `**id:**` line up to the next heading, byte-identical
    /// to the file apart from the blank lines around it.
    pub text: String,
}

impl PromptDef {
    /// `none`, or the arguments joined with commas, e.g. `weeks (default 4)`.
    pub fn args_text(&self) -> String {
        if self.args.is_empty() {
            "none".to_string()
        } else {
            self.args
                .iter()
                .map(PromptArg::describe)
                .collect::<Vec<_>>()
                .join(", ")
        }
    }

    /// The argument named `name`.
    pub fn arg(&self, name: &str) -> Option<&PromptArg> {
        self.args.iter().find(|a| a.name == name)
    }
}

/// Every prompt in file order.
pub fn all() -> &'static [PromptDef] {
    static ALL: OnceLock<Vec<PromptDef>> = OnceLock::new();
    ALL.get_or_init(|| parse(PROMPTS_MD))
}

/// The prompt with this id.
pub fn get(id: &str) -> Option<&'static PromptDef> {
    all().iter().find(|p| p.id == id.trim())
}

/// All ids, in file order.
pub fn ids() -> Vec<&'static str> {
    all().iter().map(|p| p.id.as_str()).collect()
}

/// Text between the first pair of backticks.
fn backticked(s: &str) -> Option<&str> {
    let start = s.find('`')? + 1;
    let len = s[start..].find('`')?;
    Some(&s[start..start + len])
}

/// Parse the `**args:**` part of an id line: `none`, or a list of
/// `` `name` (note) `` items.
fn parse_args(spec: &str) -> Vec<PromptArg> {
    let spec = spec.trim();
    if spec.is_empty() || spec.eq_ignore_ascii_case("none") {
        return Vec::new();
    }
    let mut args = Vec::new();
    let mut rest = spec;
    while let Some(name) = backticked(rest) {
        let after_name = rest.find('`').unwrap_or(0) + name.len() + 2;
        rest = &rest[after_name..];
        let mut note = None;
        let trimmed = rest.trim_start();
        if let Some(inner) = trimmed.strip_prefix('(') {
            if let Some(close) = inner.find(')') {
                note = Some(inner[..close].trim().to_string());
                rest = &inner[close + 1..];
            }
        }
        let default = note
            .as_deref()
            .and_then(|n| n.strip_prefix("default"))
            .map(|d| d.trim().trim_start_matches(':').trim().to_string())
            .filter(|d| !d.is_empty());
        let optional = note
            .as_deref()
            .map(|n| n.contains("optional") || n.starts_with("default"))
            .unwrap_or(false);
        args.push(PromptArg {
            name: name.trim().to_string(),
            required: !optional,
            default,
            note,
        });
    }
    args
}

/// Parse a prompts Markdown file. A prompt is a `## N. Title` heading whose next
/// non-blank line starts with `**id:**`; the body runs to the next `## ` heading.
pub fn parse(md: &str) -> Vec<PromptDef> {
    let mut heads: Vec<(usize, u32, String)> = Vec::new();
    let mut pos = 0;
    for line in md.split_inclusive('\n') {
        let trimmed = line.trim_end_matches(['\n', '\r']);
        if let Some(rest) = trimmed.strip_prefix("## ") {
            if let Some((num, title)) = rest.split_once(". ") {
                if let Ok(n) = num.trim().parse::<u32>() {
                    heads.push((pos, n, title.trim().to_string()));
                }
            }
        }
        pos += line.len();
    }
    let mut out = Vec::new();
    for (i, (start, number, title)) in heads.iter().enumerate() {
        let end = heads.get(i + 1).map(|h| h.0).unwrap_or(md.len());
        let section = &md[*start..end];
        let mut lines = section.split_inclusive('\n');
        let mut consumed = lines.next().map_or(0, str::len); // the heading line
        let mut id = None;
        let mut group = "export".to_string();
        let mut about = String::new();
        let mut args = Vec::new();
        let rest_lines: Vec<&str> = lines.collect();
        let mut k = 0;
        // the optional about line right under the id line
        let take_about = |from: usize, consumed: &mut usize, about: &mut String| {
            let mut j = from;
            let mut skipped = 0;
            while j < rest_lines.len() && rest_lines[j].trim().is_empty() {
                skipped += rest_lines[j].len();
                j += 1;
            }
            if let Some(a) = rest_lines
                .get(j)
                .and_then(|l| l.trim().strip_prefix("**about:**"))
            {
                *about = a.trim().to_string();
                *consumed += skipped + rest_lines[j].len();
            }
        };
        while k < rest_lines.len() {
            let line = rest_lines[k];
            k += 1;
            consumed += line.len();
            let t = line.trim();
            if t.is_empty() {
                continue;
            }
            if let Some(rest) = t.strip_prefix("**id:**") {
                id = backticked(rest).map(str::to_string);
                if let Some(g) = rest.split("**group:**").nth(1) {
                    let g = g.split('·').next().unwrap_or("").trim();
                    if !g.is_empty() {
                        group = g.to_string();
                    }
                }
                if let Some(a) = rest.split("**args:**").nth(1) {
                    args = parse_args(a);
                }
                take_about(k, &mut consumed, &mut about);
            }
            break;
        }
        let Some(id) = id else { continue };
        let text = section[consumed..]
            .trim_start_matches('\n')
            .trim_end()
            .to_string();
        out.push(PromptDef {
            number: *number,
            id,
            title: title.clone(),
            group,
            about,
            args,
            text,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_prompts_parse_in_order_with_their_groups() {
        let ids = ids();
        assert_eq!(
            ids,
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
        let groups: Vec<&str> = all().iter().map(|p| p.group.as_str()).collect();
        assert_eq!(groups.iter().filter(|g| **g == "export").count(), 6);
        assert_eq!(groups.iter().filter(|g| **g == "plans").count(), 5);
        let next = get("next_session").unwrap();
        assert_eq!(next.number, 7);
        assert_eq!(next.title, "Plan my next session");
        assert_eq!(next.group, "plans");
        assert!(next.args.is_empty());
        assert_eq!(next.args_text(), "none");
        assert!(next
            .text
            .starts_with("Ask me these, one message, numbered, then wait:"));
        assert!(
            next.text.ends_with("under Import, for Wednesday 10:00.\""),
            "{}",
            next.text
        );
        for p in all().iter().filter(|p| p.group == "plans") {
            assert!(
                p.text.contains("scheduled_for"),
                "{} never sets a time",
                p.id
            );
            assert!(
                !p.text.to_lowercase().contains("swim session"),
                "{} assumes a sport",
                p.id
            );
        }
    }

    #[test]
    fn arguments_carry_optional_and_default() {
        let explain = get("explain_last_session").unwrap();
        assert_eq!(explain.args.len(), 1);
        let id = explain.arg("id").unwrap();
        assert!(!id.required);
        assert_eq!(id.default, None);
        assert_eq!(explain.args_text(), "id (optional)");

        let coach = get("coach_summary").unwrap();
        let weeks = coach.arg("weeks").unwrap();
        assert!(!weeks.required);
        assert_eq!(weeks.default.as_deref(), Some("4"));
        assert_eq!(coach.args_text(), "weeks (default 4)");
        assert_eq!(coach.title, "Prepare this for my coach or doctor");
    }

    #[test]
    fn bodies_are_slices_of_the_file_and_carry_no_headings() {
        for p in all() {
            assert!(PROMPTS_MD.contains(&p.text), "{} is not verbatim", p.id);
            assert!(!p.text.contains("\n## "), "{} swallowed a heading", p.id);
            assert!(!p.text.starts_with("**id:**"), "{} kept its id line", p.id);
            assert!(
                !p.text.starts_with("**about:**"),
                "{} kept its about line",
                p.id
            );
            assert!(!p.about.is_empty(), "{} has no about line", p.id);
            assert!(!p.text.contains('\u{2014}'), "{} has an em dash", p.id);
            assert!(!p.text.is_empty());
        }
    }

    #[test]
    fn parser_handles_a_minimal_file() {
        let md = "# T\n\nintro\n\n## 1. One\n**id:** `one` · **args:** `a` (optional), `b`\n**about:** First.\n\nBody one.\n\nMore.\n\n## 2. Two\n**id:** `two` · **group:** plans · **args:** none\n\nBody two.\n";
        let got = parse(md);
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].text, "Body one.\n\nMore.");
        assert_eq!(got[0].args.len(), 2);
        assert!(!got[0].args[0].required);
        assert!(got[1].args.is_empty());
        assert_eq!(got[1].text, "Body two.");
        assert_eq!(got[0].group, "export");
        assert_eq!(got[1].group, "plans");
        assert_eq!(got[0].about, "First.");
        assert_eq!(got[1].about, "");
    }
}
