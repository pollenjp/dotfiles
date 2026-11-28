//! 送る前の守り: 相手の端末で Claude Code (エージェント) が動いているかを、`hc get <端末> --json` の
//! `status` (OSC 7501 の報告) と `foreground` (前面のプロセス) で見分ける。
//!
//! Claude が終わった (落ちた・core が止まって立て直した) 端末は、hc の keep で中身が shell に替わり、名前・label・住所・
//! `turn` は前のまま残る。`argv` と `foreground` は shell になり、`status` は null、`reported` は false になる (hc 0.1.21 で、
//! 本物の子の端末と、自分専用の core で落とした偽の claude の両方で見た)。そこへ文を送ると shell が 1 行ずつコマンドとして
//! 打つので、送る前に確かめる。
//!
//! 画面の字 (prompt・status line) では見分けない。hc の手引きが画面の字から状態を推さないよう言い、`restore_screen` を
//! 入れた core は前の program の画面を新しい shell の上に出し、prompt と status line の形は人の設定で変わる。

use serde_json::{Map, Value};

/// 相手の端末のエージェント。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Agent {
    /// 動いている (状態を報告している、か前面のプロセスが claude)。
    Running,
    /// 端末が終わっている (終了コード。`?` は分からない)。hc send も断る。
    Finished(String),
    /// 生きた端末の前面に、エージェントでないプロセスがいて、状態の報告も無い (前面のプロセスの名前)。
    Other(String),
    /// 見分けられない (わけ)。
    Unknown(String),
}

/// `hc get <端末> --json` の答えから見分ける。
pub(super) fn agent_of(term: &Value) -> Agent {
    if crate::hc::finished(term) {
        let code = term["exit_code"]
            .as_i64()
            .map_or("?".to_owned(), |c| c.to_string());
        return Agent::Finished(code);
    }
    // 状態の報告 (OSC 7501 の root の record) は、program が終わる・root の対話 shell が前面に戻ると消える (hc の手引き)。
    // core の立て直し (hc server restart) では残る
    if term["status"]["state"].as_str().is_some() {
        return Agent::Running;
    }
    match term.get("foreground") {
        Some(Value::Object(fg)) => {
            if is_claude(fg) {
                // 報告しない claude (立てた直後・報告しない立てられ方) も、前面にいれば動いている
                return Agent::Running;
            }
            let name = fg
                .get("name")
                .and_then(Value::as_str)
                .filter(|n| !n.is_empty())
                .unwrap_or("(名前なし)");
            Agent::Other(name.to_owned())
        }
        // hc 0.1.21 は前面が無いと foreground を省く。生きた端末で reason が付いているのは、program が落ちて、hc が
        // shell に替えている途中 (落とした直後の 1 秒ほど。reason: signaled・pid: null を見た)
        _ => Agent::Unknown(match term["reason"].as_str() {
            Some(reason) => format!(
                "前面のプロセスが無く、状態の報告も無い (reason: {reason}。program が落ちて、hc が shell に替えている途中)"
            ),
            None => "hc get に前面のプロセス (foreground) が無く、状態の報告も無い (hc が古いか、前面を読めない)"
                .to_owned(),
        }),
    }
}

/// 前面のプロセスが Claude Code か。名前か argv の頭の名前が claude (Windows は claude.exe)、または npm で入れた
/// Claude Code (node の上で `@anthropic-ai/claude-code` を動かす)。
fn is_claude(fg: &Map<String, Value>) -> bool {
    let stem = |s: &str| -> String {
        let base = s
            .rsplit(['/', '\\'])
            .next()
            .unwrap_or(s)
            .to_ascii_lowercase();
        base.strip_suffix(".exe").unwrap_or(&base).to_owned()
    };
    let name = fg.get("name").and_then(Value::as_str).unwrap_or_default();
    let argv: Vec<&str> = fg
        .get("argv")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    stem(name) == "claude"
        || argv.first().is_some_and(|a| stem(a) == "claude")
        || argv
            .iter()
            .any(|a| a.replace('\\', "/").contains("@anthropic-ai/claude-code"))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    /// hc 0.1.21 の `hc get` で見た、Claude が動いている子の端末 (argv と foreground の依頼の文は縮めた)。
    fn running_child() -> Value {
        json!({
            "address": "t6f",
            "argv": ["env", "-u", "HERDR_ENV", "/home/u/.local/share/mise/shims/claude", "--dangerously-skip-permissions", "依頼"],
            "foreground": {
                "argv": ["/home/u/.local/share/mise/installs/claude/latest/claude", "--dangerously-skip-permissions", "依頼"],
                "cwd": "/home/u/.herdr/worktrees/claude-skills/send-guard",
                "name": "claude",
                "pid": 547_133
            },
            "keep": true,
            "pid": 547_133,
            "reason": null,
            "reported": true,
            "state": "live",
            "status": {"app": "claude-code", "msg": "Reading", "state": "working"},
            "turn": 0
        })
    }

    /// hc 0.1.21 の `hc get` で見た、Claude が終わって hc の keep が shell に替えた子の端末 (名前・label・turn は残る)。
    fn shell_child() -> Value {
        json!({
            "address": "t5j",
            "name": "docs-notion",
            "argv": ["/bin/bash"],
            "foreground": {"argv": ["/bin/bash"], "cwd": "/home/u/.herdr/worktrees/repo-x/docs-notion", "name": "bash", "pid": 714},
            "keep": true,
            "pid": 714,
            "reason": null,
            "reported": false,
            "state": "live",
            "status": null,
            "status_ms": 1_795_041_610_124_u64,
            "turn": 2,
            "labels": {"pjp.letter": "E", "pjp.role": "child", "pjp.ticket": "ABC-790"}
        })
    }

    #[test]
    fn reporting_claude_is_running() {
        assert_eq!(agent_of(&running_child()), Agent::Running);
        // 確認の画面 (blocked) も動いている。断るのは hc send (今の振る舞いのまま)
        let mut t = running_child();
        t["status"]["state"] = json!("blocked");
        assert_eq!(agent_of(&t), Agent::Running);
    }

    #[test]
    fn shell_after_keep_is_other() {
        assert_eq!(agent_of(&shell_child()), Agent::Other("bash".to_owned()));
    }

    #[test]
    fn claude_exited_back_to_root_shell_is_other() {
        // root の bash の中で立てた claude が終わると、status が消え、前面が bash に戻る (reported は true のまま)
        let t = json!({
            "argv": ["/home/u/.nix-profile/bin/bash"],
            "foreground": {"argv": ["/home/u/.nix-profile/bin/bash"], "cwd": "/w", "name": "bash", "pid": 647_091},
            "pid": 647_091, "reported": true, "state": "live", "status": null
        });
        assert_eq!(agent_of(&t), Agent::Other("bash".to_owned()));
    }

    #[test]
    fn quiet_claude_in_front_is_running() {
        // 状態を報告しない claude (前面の名前は claude)
        let mut t = running_child();
        t["status"] = Value::Null;
        t["reported"] = json!(false);
        assert_eq!(agent_of(&t), Agent::Running);
        // shell script の claude (名前は script の名前、argv の頭は /bin/sh)
        let t = json!({
            "foreground": {"argv": ["/bin/sh", "/tmp/x/bin-quiet/claude", "x"], "cwd": "/w", "name": "claude", "pid": 1},
            "state": "live", "status": null
        });
        assert_eq!(agent_of(&t), Agent::Running);
    }

    #[test]
    fn claude_names() {
        let fg = |name: &str, argv: Value| -> Map<String, Value> {
            json!({"name": name, "argv": argv, "cwd": "/", "pid": 1})
                .as_object()
                .unwrap()
                .clone()
        };
        assert!(is_claude(&fg("claude", json!(["claude"]))));
        assert!(is_claude(&fg(
            "claude.exe",
            json!(["C:\\Users\\u\\.local\\bin\\claude.exe"])
        )));
        assert!(is_claude(&fg(
            "node",
            json!([
                "node",
                "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"
            ])
        )));
        assert!(is_claude(&fg(
            "node.exe",
            json!([
                "node.exe",
                "C:\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js"
            ])
        )));
        assert!(!is_claude(&fg("bash", json!(["/bin/bash"]))));
        assert!(!is_claude(&fg(
            "pwsh.exe",
            json!(["C:\\pwsh.exe", "-NoExit"])
        )));
        assert!(!is_claude(&fg("vim", json!(["vim", "claude.md"]))));
        assert!(!is_claude(&fg("claude-helper", json!(["claude-helper"]))));
    }

    #[test]
    fn windows_hub_in_pwsh() {
        // Windows の core は、pwsh の中で動く claude でも前面に root の pwsh.exe を出す。状態の報告で見分ける
        let mut t = json!({
            "argv": ["C:\\pwsh.exe", "-NoExit"],
            "foreground": {"argv": ["C:\\pwsh.exe", "-NoExit"], "cwd": "C:\\h", "name": "pwsh.exe", "pid": 18_668},
            "pid": 18_668, "reported": true, "state": "live",
            "status": {"app": "claude-code", "state": "working"}
        });
        assert_eq!(agent_of(&t), Agent::Running);
        t["status"] = Value::Null;
        t["reported"] = json!(false);
        assert_eq!(agent_of(&t), Agent::Other("pwsh.exe".to_owned()));
    }

    #[test]
    fn unknown_and_finished() {
        // 落ちた直後 (hc が shell に替える前): hc 0.1.21 は foreground を省き、reason が付く (自分専用の core で見た)
        let mut t = json!({
            "argv": ["/tmp/x/bin/claude"], "pid": null,
            "reason": "signaled", "reported": true, "state": "live", "status": null
        });
        for fg in [None, Some(Value::Null)] {
            if let Some(v) = fg {
                t["foreground"] = v;
            }
            let Agent::Unknown(why) = agent_of(&t) else {
                panic!("Unknown でない: {t}")
            };
            assert!(why.contains("reason: signaled"), "{why}");
        }
        // 前面も reason も無い (foreground を返さない古い hc など)
        let t = json!({"address": "t1", "state": "live", "status": null});
        let Agent::Unknown(why) = agent_of(&t) else {
            panic!("Unknown でない")
        };
        assert!(why.contains("hc が古いか"), "{why}");
        // 終わった端末 (foreground は省かれる)
        let t = json!({"state": "finished", "exit_code": 0, "reason": "exited", "status": null});
        assert_eq!(agent_of(&t), Agent::Finished("0".to_owned()));
    }
}
