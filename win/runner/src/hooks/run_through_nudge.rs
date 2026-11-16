//! run-through-nudge (PostToolUse・matcher Skill): superpowers の 4 つの skill を読み込んだ直後に、「確認を挟まずに PR まで走り切る」と Claude の
//! 文脈へ 1 文を差し込む。Linux の `nix/files/claude/hooks/run-through-nudge.sh` (dotfiles-private の ADR 019) の写し。文は bash の版と同じ。
//!
//! 黙る場面も同じ: 4 つ以外の skill・Skill 以外の tool・subagent の中 (`agent_id` がある)・読み込みの失敗 (`tool_response.success` が false)。

use super::{answer, field};
use serde_json::Value;

const SECTION: &str = "方針を承認したら PR まで走り切る";
const PHRASE: &str = "「承認したら PR まで確認を挟まずに進める」";
const FOLLOW: &str = "ユーザーがこの会話で別の進め方を言っていれば、そちらに従う。";

pub fn run(input: &Value) -> Option<String> {
    if field(input, &["tool_name"]) != "Skill" || !field(input, &["agent_id"]).is_empty() {
        return None;
    }
    // bash は `.tool_response.success | tostring` が false かを見る (真偽値の false と、文字列の "false")
    let success = input.get("tool_response").and_then(|r| r.get("success"));
    if matches!(success, Some(Value::Bool(false)))
        || success.and_then(Value::as_str) == Some("false")
    {
        return None;
    }
    let skill = field(input, &["tool_input", "skill"]);
    let msg = match skill.as_str() {
        "superpowers:brainstorming" => format!(
            "[走り切り] {skill} を読んだ。このユーザーは方針の承認 1 回のあと PR まで走り切る (~/.claude/CLAUDE.md「{SECTION}」)。方針の承認は spec を書く前に 1 回聞き、{PHRASE}と、その先の段階 (spec → 実装計画 → 実装 → PR など) とともに書き添える。承認のあとは spec の承認を待たずに writing-plans へ進み、builder check の問いは自分で決めて spec に「こちらの判断」として残す。{FOLLOW}"
        ),
        "superpowers:writing-plans" => format!(
            "[走り切り] {skill} を読んだ。この会話で{PHRASE}と書き添えた方針の承認を得ていれば、実装計画を書いたあと、計画のレビューも実行方式 (Subagent-driven / Native) の選択も聞かず、推奨の方式を理由 1 文とともに告げてそのまま実行に入る。まだ得ていなければ、計画と推奨の方式を見せるときに 1 回だけ、同じく書き添えて承認を聞く (~/.claude/CLAUDE.md「{SECTION}」)。{FOLLOW}"
        ),
        "superpowers:using-git-worktrees" => format!(
            "[走り切り] {skill} を読んだ。worktree を作るかは聞かない。worktree の外なら、その場で既定の branch から feature branch を切って進める (main では作業しない。~/.claude/CLAUDE.md「{SECTION}」)。{FOLLOW}"
        ),
        "superpowers:finishing-a-development-branch" => format!(
            "[走り切り] {skill} を読んだ。この会話で{PHRASE}と書き添えた方針の承認を得ていれば、merge / PR / そのまま の 3 択を聞かず、テストが通っていれば push して PR を作る (merge はしない)。push の前に、PR に載る commit が今回の作業だけかを git log で確かめ、他の commit が混ざっていれば止まって聞く。自分で決めたこと (builder check の判断・ruling) は PR を返すときに並べる。まだ承認を得ていなければ、3 択の代わりに PR を出してよいかを 1 回だけ聞く (~/.claude/CLAUDE.md「{SECTION}」)。{FOLLOW}"
        ),
        _ => return None,
    };
    Some(answer("PostToolUse", &[("additionalContext", &msg)]))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 4 つの skill で文を返し、ほかの skill・ほかの tool・subagent・読み込みの失敗では黙る
    //! - bash の版 (nix/files/claude/hooks/run-through-nudge.sh) と同じ入力で同じ答え (bash と jq がある Linux)

    use super::*;
    use crate::hooks::parity;
    use serde_json::json;

    fn input(skill: &str, extra: Value) -> Value {
        let mut v = json!({
            "session_id": "s",
            "hook_event_name": "PostToolUse",
            "tool_name": "Skill",
            "tool_input": {"skill": skill},
            "tool_response": {"success": true, "commandName": skill}
        });
        if let (Value::Object(m), Value::Object(e)) = (&mut v, extra) {
            m.extend(e);
        }
        v
    }

    fn cases() -> Vec<Value> {
        let mut v = Vec::new();
        for skill in [
            "superpowers:brainstorming",
            "superpowers:writing-plans",
            "superpowers:using-git-worktrees",
            "superpowers:finishing-a-development-branch",
            "superpowers:systematic-debugging",
            "brainstorming",
            "pjp-dev-tracker",
        ] {
            v.push(input(skill, json!({})));
        }
        v.push(input(
            "superpowers:brainstorming",
            json!({"agent_id": "a1"}),
        ));
        v.push(input("superpowers:brainstorming", json!({"agent_id": ""})));
        v.push(input(
            "superpowers:brainstorming",
            json!({"tool_response": {"success": false}}),
        ));
        v.push(input(
            "superpowers:brainstorming",
            json!({"tool_response": {"success": "false"}}),
        ));
        v.push(input(
            "superpowers:brainstorming",
            json!({"tool_response": {}}),
        ));
        v.push(input(
            "superpowers:brainstorming",
            json!({"tool_response": "done"}),
        ));
        v.push(input(
            "superpowers:brainstorming",
            json!({"tool_name": "Bash"}),
        ));
        v.push(json!({"tool_name": "Skill"}));
        v.push(json!([1, 2]));
        v
    }

    #[test]
    fn nudges_the_four_skills_only() {
        let says = |v: &Value| run(v).is_some();
        assert!(says(&input("superpowers:brainstorming", json!({}))));
        assert!(says(&input(
            "superpowers:finishing-a-development-branch",
            json!({})
        )));
        assert!(says(&input(
            "superpowers:brainstorming",
            json!({"tool_response": {}})
        )));
        assert!(!says(&input("superpowers:systematic-debugging", json!({}))));
        assert!(!says(&input(
            "superpowers:brainstorming",
            json!({"agent_id": "a1"})
        )));
        assert!(!says(&input(
            "superpowers:brainstorming",
            json!({"tool_response": {"success": false}})
        )));
        assert!(!says(&input(
            "superpowers:brainstorming",
            json!({"tool_name": "Bash"})
        )));
        let a = run(&input("superpowers:writing-plans", json!({}))).unwrap();
        let v: Value = serde_json::from_str(&a).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PostToolUse");
        let msg = v["hookSpecificOutput"]["additionalContext"]
            .as_str()
            .unwrap();
        assert!(
            msg.starts_with("[走り切り] superpowers:writing-plans を読んだ。"),
            "{msg}"
        );
    }

    #[test]
    fn matches_bash() {
        if !parity::available() {
            return;
        }
        let script = parity::repo_file("nix/files/claude/hooks/run-through-nudge.sh");
        for case in cases() {
            let text = case.to_string();
            let bash = parity::run_bash(&script, &text, &[], None);
            let ours = run(&case).unwrap_or_default();
            assert_eq!(parity::parsed(&ours), parity::parsed(&bash), "入力: {text}");
        }
    }
}
