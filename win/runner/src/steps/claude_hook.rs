//! claude-hook (order 50): Windows の Claude Code の settings.json の `hooks` に、runner が写した hook の口 (`%USERPROFILE%\.claude\hooks\
//! dotfiles-claude.exe`。claude-files が写す) を登録する。Linux の `nix/scripts/bootstrap-claude-hook.sh` に当たる。
//!
//! Windows に入れる hook は、Linux の hook のうち Rust に写したもの (`crate::hooks`) だけ。どれを入れ、どれを入れないかとわけは
//! dotfiles-private の docs/adr/065_win_claude_config_* と win/README.md の「Claude Code の設定」。
//!
//! 登録は exec form (`command` に exe のパス、`args` に引数。shell を通さない。Claude Code 2.1.139 から)。shell form にすると、Git Bash が
//! 見つからない Windows では PowerShell が command を読み、PreToolUse の hook の失敗が tool を止めうる。exec form は exe を直に起こすので、
//! どちらの shell にも頼らない。
//!
//! Linux と同じく、同じ event・matcher・if・command (と args) の組が既にあれば足さない。Linux と違い、この手順の口 (command の名前が
//! `dotfiles-claude.exe`) の登録で、今は入れない組 (前の版で入れた hook・別の場所の exe) は外す (この手順が持つ口なので)。ほかの hook と
//! キーの順は残す。

use super::claude_settings::{self, HOOK_EXE, hook_exe};
use super::{Gate, Mode, Outcome, Step, StepInfo};
use crate::context::Ctx;
use crate::ojson::OValue;
use crate::report::Kind;

/// 登録する組 (event・matcher (空なら付けない)・if (空なら付けない)・hook の名前)。Linux の bootstrap-claude-hook.sh の同じ hook の行と同じ形
pub const REGISTRATIONS: &[(&str, &str, &str, &str)] = &[
    (
        "PreToolUse",
        "Write|Edit|MultiEdit|NotebookEdit",
        "",
        "docs-guard",
    ),
    ("PostToolUse", "Skill", "", "run-through-nudge"),
    (
        "PostToolUse",
        "Bash",
        "Bash(gh pr create *)",
        "pr-assignee-nudge",
    ),
    (
        "PostToolUseFailure",
        "Bash",
        "Bash(gh pr create *)",
        "pr-assignee-nudge",
    ),
];

pub struct ClaudeHook;

impl Step for ClaudeHook {
    fn info(&self) -> StepInfo {
        StepInfo {
            id: "claude-hook",
            order: 50,
            title: "Claude Code の settings.json の hooks に、runner が写した hook の口 (dotfiles-claude.exe) を登録する",
            gate: Gate::Tool("windowsClaudeCode"),
            ported: true,
            windows_only: true,
        }
    }

    fn run(&self, ctx: &mut Ctx, mode: Mode) -> Vec<Outcome> {
        let path = claude_settings::path(ctx);
        let (before, existed) = match claude_settings::load(&path) {
            Ok(v) => v,
            Err(e) => {
                ctx.say(format!("!! {e}"));
                return vec![Outcome::new(Kind::Failed, e)];
            }
        };
        let exe = hook_exe(ctx);
        let after = match with_hooks(&before, &exe.to_string_lossy()) {
            Ok(v) => v,
            Err(why) => {
                ctx.say(format!("!! {}: {why}", path.display()));
                return vec![Outcome::new(
                    Kind::Failed,
                    format!("{}: {why} → 手で直す", path.display()),
                )];
            }
        };
        let mut o = claude_settings::apply_change(
            ctx,
            mode,
            &path,
            (&before, existed),
            &after,
            "hooks",
            "Claude Code を起動し直すと効く",
        );
        if !exe.is_file() {
            o = o.note(format!(
                "hook の口 {} が無い。claude-files の手順が写す (dotfiles apply)",
                exe.display()
            ));
        }
        vec![o]
    }
}

/// command の名前が hook の口か (この手順の登録か。別の場所の口も)。
fn is_ours(command: &str) -> bool {
    let name = command.rsplit(['/', '\\']).next().unwrap_or(command);
    name.eq_ignore_ascii_case(HOOK_EXE)
}

/// hook の口に渡す引数 (`claude-hook <名前>`)
fn args_of(name: &str) -> OValue {
    OValue::Array(vec![
        OValue::String("claude-hook".to_string()),
        OValue::String(name.to_string()),
    ])
}

/// 登録の 1 件 (`{type, command, args, if?}`)
fn entry(exe: &str, cond: &str, name: &str) -> OValue {
    let mut e = vec![
        ("type".to_string(), OValue::String("command".to_string())),
        ("command".to_string(), OValue::String(exe.to_string())),
        ("args".to_string(), args_of(name)),
    ];
    if !cond.is_empty() {
        e.push(("if".to_string(), OValue::String(cond.to_string())));
    }
    OValue::Object(e)
}

fn str_of<'a>(v: &'a OValue, key: &str) -> &'a str {
    match v.get(key) {
        Some(OValue::String(s)) => s,
        _ => "",
    }
}

/// この組が登録済みか (同じ event・matcher・if・command・args)。
fn registered(
    hooks: &OValue,
    event: &str,
    matcher: &str,
    cond: &str,
    exe: &str,
    name: &str,
) -> bool {
    let want_args = args_of(name);
    let Some(OValue::Array(groups)) = hooks.get(event) else {
        return false;
    };
    groups.iter().any(|g| {
        str_of(g, "matcher") == matcher
            && matches!(g.get("hooks"), Some(OValue::Array(hs)) if hs.iter().any(|h| {
                str_of(h, "command") == exe && str_of(h, "if") == cond && h.get("args") == Some(&want_args)
            }))
    })
}

/// settings.json に、この手順の登録を入れたもの (ほかの hook とキーの順は残す)。
fn with_hooks(settings: &OValue, exe: &str) -> Result<OValue, String> {
    let mut hooks = match settings.get("hooks") {
        None | Some(OValue::Null) => OValue::Object(Vec::new()),
        Some(v @ OValue::Object(_)) => v.clone(),
        Some(_) => return Err("hooks が object でない".to_string()),
    };
    // 1. この手順の口の登録で、今は入れない組を外す。外して空になった組と event は消す (もとから空のものは残す)
    let keep = |event: &str, matcher: &str, h: &OValue| -> bool {
        !is_ours(str_of(h, "command"))
            || REGISTRATIONS.iter().any(|(ev, m, cond, name)| {
                *ev == event
                    && *m == matcher
                    && str_of(h, "if") == *cond
                    && str_of(h, "command") == exe
                    && h.get("args") == Some(&args_of(name))
            })
    };
    if let OValue::Object(events) = &mut hooks {
        events.retain_mut(|(event, groups)| {
            let OValue::Array(gs) = groups else {
                return true;
            };
            let had_groups = !gs.is_empty();
            gs.retain_mut(|g| {
                let matcher = str_of(g, "matcher").to_string();
                let Some(OValue::Array(hs)) = g.get("hooks").cloned() else {
                    return true;
                };
                let before = hs.len();
                let kept: Vec<OValue> = hs
                    .into_iter()
                    .filter(|h| keep(event, &matcher, h))
                    .collect();
                let emptied = kept.len() < before && kept.is_empty();
                g.set("hooks", OValue::Array(kept));
                !emptied
            });
            !(had_groups && gs.is_empty())
        });
    }
    // 2. 無い組を足す (event の配列の末尾に、1 件だけの組として。Linux の bootstrap-claude-hook.sh と同じ形)
    for (event, matcher, cond, name) in REGISTRATIONS {
        if registered(&hooks, event, matcher, cond, exe, name) {
            continue;
        }
        let mut group = Vec::new();
        if !matcher.is_empty() {
            group.push(("matcher".to_string(), OValue::String(matcher.to_string())));
        }
        group.push((
            "hooks".to_string(),
            OValue::Array(vec![entry(exe, cond, name)]),
        ));
        let mut list = match hooks.get(event) {
            Some(OValue::Array(a)) => a.clone(),
            None | Some(OValue::Null) => Vec::new(),
            Some(_) => return Err(format!("hooks.{event} が配列でない")),
        };
        list.push(OValue::Object(group));
        hooks.set(event, OValue::Array(list));
    }
    let mut result = settings.clone();
    result.set("hooks", hooks);
    Ok(result)
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 無ければ 4 件を exec form (command・args) で足し、2 回目は登録済み。ほかの hook・キーの順は残す
    //! - 前の版の口の登録 (今は入れない hook・別の場所の exe) は外し、外して空になった組・event は消す (もとから空のものは残す)
    //! - hooks が object でない・event が配列でない settings.json は failed (書かない)
    //! - 登録する組 (event・matcher・if) は Linux の bootstrap-claude-hook.sh の同じ hook の行と同じ

    use super::*;
    use crate::hooks;
    use crate::host::{Groups, HostValues};
    use crate::manifest::Roots;
    use crate::testutil::{FakeSys, TempDir};
    use std::path::Path;

    const EXE: &str = "C:\\Users\\u\\.claude\\hooks\\dotfiles-claude.exe";

    #[test]
    fn adds_exec_form_entries_and_keeps_others() {
        let before = OValue::parse(
            "{\"theme\": \"dark\", \"hooks\": {\"PreToolUse\": [{\"matcher\": \"Write\", \"hooks\": [{\"type\": \"command\", \"command\": \"pjp hub guard\"}]}]}, \"env\": {}}",
        )
        .unwrap();
        let after = with_hooks(&before, EXE).unwrap();
        let text = after.to_pretty();
        assert!(text.find("\"theme\"").unwrap() < text.find("\"hooks\"").unwrap());
        assert!(text.find("\"hooks\"").unwrap() < text.find("\"env\"").unwrap());
        let v = after.to_value();
        let pre = v["hooks"]["PreToolUse"].as_array().unwrap();
        assert_eq!(pre.len(), 2);
        assert_eq!(pre[0]["hooks"][0]["command"], "pjp hub guard");
        assert_eq!(pre[1]["matcher"], "Write|Edit|MultiEdit|NotebookEdit");
        assert_eq!(pre[1]["hooks"][0]["command"], EXE);
        assert_eq!(
            pre[1]["hooks"][0]["args"],
            serde_json::json!(["claude-hook", "docs-guard"])
        );
        assert!(pre[1]["hooks"][0].get("if").is_none());
        let post = v["hooks"]["PostToolUse"].as_array().unwrap();
        assert_eq!(post[1]["hooks"][0]["if"], "Bash(gh pr create *)");
        assert_eq!(
            v["hooks"]["PostToolUseFailure"][0]["hooks"][0]["args"][1],
            "pr-assignee-nudge"
        );
        // 2 回目は同じ
        assert_eq!(with_hooks(&after, EXE).unwrap().to_value(), v);
    }

    #[test]
    fn removes_stale_entries_of_ours() {
        let before = OValue::parse(&format!(
            "{{\"hooks\": {{\"PreToolUse\": [{{\"matcher\": \"Bash\", \"hooks\": [{{\"type\": \"command\", \"command\": \"{old}\", \"args\": [\"claude-hook\", \"xref-guard\"]}}]}}, {{\"matcher\": \"Bash\", \"hooks\": [{{\"type\": \"command\", \"command\": \"mine.sh\"}}, {{\"type\": \"command\", \"command\": \"{old}\", \"args\": [\"claude-hook\", \"x\"]}}]}}], \"Stop\": [], \"SessionStart\": [{{\"hooks\": [{{\"type\": \"command\", \"command\": \"{old}\", \"args\": [\"claude-hook\", \"y\"]}}]}}]}}}}",
            old = "D:/old/dotfiles-claude.exe"
        ))
        .unwrap();
        let after = with_hooks(&before, EXE).unwrap().to_value();
        let pre = after["hooks"]["PreToolUse"].as_array().unwrap();
        // 前の口だけの組は消え、ほかの hook がある組は残る
        assert_eq!(
            pre[0]["hooks"],
            serde_json::json!([{"type": "command", "command": "mine.sh"}])
        );
        assert!(
            pre.iter()
                .all(|g| g["hooks"][0]["command"] != "D:/old/dotfiles-claude.exe")
        );
        // もとから空の Stop は残し、外して空になった SessionStart は消す
        assert_eq!(after["hooks"]["Stop"], serde_json::json!([]));
        assert!(after["hooks"].get("SessionStart").is_none());
    }

    #[test]
    fn rejects_odd_shapes() {
        assert!(with_hooks(&OValue::parse("{\"hooks\": []}").unwrap(), EXE).is_err());
        assert!(
            with_hooks(
                &OValue::parse("{\"hooks\": {\"PostToolUse\": {}}}").unwrap(),
                EXE
            )
            .is_err()
        );
    }

    #[test]
    fn step_writes_and_notes_missing_exe() {
        let t = TempDir::new("claude-hook");
        let sys = FakeSys::new(|_| unreachable!());
        let mut out = Vec::new();
        let mut ctx = Ctx {
            repo: t.path().join("dotfiles"),
            roots: Roots::from_home(&t.path().join("home")),
            state_dir: t.path().join("state"),
            host: HostValues::missing(Path::new("h.toml"), Groups::embedded().unwrap()),
            sys: &sys,
            out: &mut out,
        };
        let o = ClaudeHook.run(&mut ctx, Mode::Check).remove(0);
        assert_eq!(o.kind, Kind::Missing, "{o:?}");
        assert!(o.notes.iter().any(|n| n.contains("claude-files")), "{o:?}");
        let o = ClaudeHook
            .run(&mut ctx, Mode::Apply { force: false })
            .remove(0);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
        let o = ClaudeHook.run(&mut ctx, Mode::Check).remove(0);
        assert_eq!(o.kind, Kind::Ok, "{o:?}");
    }

    /// Linux の bootstrap-claude-hook.sh の `register <event> <matcher> <if> "${…}"` の行と、同じ hook の組が同じ
    #[test]
    fn registrations_follow_linux() {
        let text = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../nix/scripts/bootstrap-claude-hook.sh"),
        )
        .unwrap();
        let var_of = |name: &str| -> String {
            // hooks_dir の下の変数 (guard="${hooks_dir}/nix-managed-guard.sh" の形)
            text.lines()
                .find_map(|l| {
                    let (var, rest) = l.split_once("=\"${hooks_dir}/")?;
                    (rest.trim_end_matches('"') == format!("{name}.sh")).then(|| var.to_string())
                })
                .unwrap_or_else(|| panic!("{name}.sh の変数が無い"))
        };
        for name in hooks::NAMES {
            let var = var_of(name);
            let linux: Vec<(String, String, String)> = text
                .lines()
                .filter_map(|l| l.strip_prefix("register "))
                .filter(|l| l.contains(&format!("\"${{{var}}}\"")))
                .map(|l| {
                    let q: Vec<&str> = l.split('"').collect();
                    (q[0].trim().to_string(), q[1].to_string(), q[3].to_string())
                })
                .collect();
            let ours: Vec<(String, String, String)> = REGISTRATIONS
                .iter()
                .filter(|r| r.3 == name)
                .map(|(e, m, c, _)| (e.to_string(), m.to_string(), c.to_string()))
                .collect();
            assert!(!ours.is_empty(), "{name} を登録していない");
            assert_eq!(ours, linux, "{name}");
        }
    }
}
