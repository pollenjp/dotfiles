//! Windows の Claude Code の hook と status line の口 (`dotfiles-win claude-hook <名前>`・`dotfiles-win claude-statusline`)。
//!
//! Linux の `nix/files/claude/hooks/<名前>.sh` と `nix/files/claude/statusline-command.sh` (bash と jq) を写したもの。Windows の Git Bash には jq が
//! 無く (Git for Windows が同梱しない)、bash の hook は黙って何もしない。そこで runner の claude-files が runner の exe を
//! `%USERPROFILE%\.claude\hooks\dotfiles-claude.exe` に写し、claude-hook と claude-statusline が settings.json にこの口を登録する
//! (dotfiles-private の docs/adr/065_win_claude_config_*)。
//!
//! ふるまいは bash の版と同じにする。bash の版を直したら、ここも同じに直す (Linux の試験が bash の版と突き合わせる。bash と jq が無い
//! マシンでは飛ばし、`DOTFILES_WIN_BASH_PARITY=1` なら落ちる)。hook はいつも終了コード 0 で終える (止めるときは JSON の permissionDecision。
//! 入力の誤りで tool の流れを止めない)。

pub mod docs_guard;
pub mod guard;
pub mod pr_assignee_nudge;
pub mod run_through_nudge;
pub mod statusline;

use crate::process::Sys;
use serde_json::Value;
use std::path::PathBuf;

/// Windows に写した hook の名前 (`claude-hook <名前>`)。Linux の `nix/files/claude/hooks/<名前>.sh` と同じ名前
pub const NAMES: [&str; 6] = [
    "docs-guard",
    "gist-guard",
    "install-iac-guard",
    "pr-assignee-nudge",
    "run-through-nudge",
    "xref-guard",
];

/// hook を流す。stdout に出す文 (JSON の 1 行と改行) を返す。黙るときは None。知らない名前も黙る (登録の誤りで tool を止めない)。
pub fn run(name: &str, raw: &str, sys: &dyn Sys) -> Option<String> {
    let input: Value = serde_json::from_str(raw).ok()?;
    match name {
        "docs-guard" => docs_guard::run(&input, sys),
        "gist-guard" => quiet(|| guard::gist::run(raw, &input, sys)),
        "install-iac-guard" => quiet(|| guard::iac::run(raw, &input, sys)),
        "pr-assignee-nudge" => pr_assignee_nudge::run(&input, sys),
        "run-through-nudge" => run_through_nudge::run(&input),
        "xref-guard" => quiet(|| guard::xref::run(raw, &input, sys)),
        _ => None,
    }
}

/// コマンドを読む guard は、思わぬ入力で panic しても黙って 0 で終える (bash の版の「何があっても exit 0」。0 と 2 のほかの終了コードは tool の
/// 流れを乱す)。panic の文は stderr に出る
fn quiet(f: impl FnOnce() -> Option<String>) -> Option<String> {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(None)
}

/// ホーム (Windows は `USERPROFILE`、ほかは `HOME`。Linux の hook の `${HOME}` に当たる)。
pub fn home(sys: &dyn Sys) -> Option<PathBuf> {
    let name = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    sys.env(name).filter(|s| !s.is_empty()).map(PathBuf::from)
}

/// Claude Code の設定の dir (bash の `${CLAUDE_CONFIG_DIR:-${HOME}/.claude}`)。
pub fn config_dir(sys: &dyn Sys) -> Option<PathBuf> {
    match sys.env("CLAUDE_CONFIG_DIR").filter(|s| !s.is_empty()) {
        Some(dir) => Some(PathBuf::from(dir)),
        None => home(sys).map(|h| h.join(".claude")),
    }
}

/// `jq -r '<path> // empty'` を bash の `$(…)` で受けた文字列。無い・null・false は空、文字列はそのまま、ほかは JSON の文。途中が object でも
/// null でもなければ jq は落ちるので空 (bash は `|| true`)。末尾の改行は `$(…)` と同じく落とす。
pub fn field(v: &Value, path: &[&str]) -> String {
    let mut cur = v;
    for key in path {
        match cur {
            Value::Object(m) => match m.get(*key) {
                Some(next) => cur = next,
                None => return String::new(),
            },
            _ => return String::new(),
        }
    }
    let text = match cur {
        Value::Null | Value::Bool(false) => return String::new(),
        Value::String(s) => s.clone(),
        Value::Bool(true) => "true".to_string(),
        Value::Number(n) => n.to_string(),
        other => serde_json::to_string_pretty(other).unwrap_or_default(),
    };
    text.trim_end_matches('\n').to_string()
}

/// hook の答え `{hookSpecificOutput: {hookEventName, …}}` の 1 行 (jq -c の出力と同じく末尾に改行)。
pub fn answer(event: &str, fields: &[(&str, &str)]) -> String {
    let mut inner = serde_json::Map::new();
    inner.insert(
        "hookEventName".to_string(),
        Value::String(event.to_string()),
    );
    for (k, v) in fields {
        inner.insert(k.to_string(), Value::String(v.to_string()));
    }
    let mut top = serde_json::Map::new();
    top.insert("hookSpecificOutput".to_string(), Value::Object(inner));
    format!("{}\n", Value::Object(top))
}

/// POSIX の `[[:space:]]` (grep の文字の類)。
pub fn is_space(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\x0B' | '\x0C' | '\r')
}

/// bash の glob の `*a*b*c*` (字がこの順に現れるか)。
pub fn contains_in_order(text: &str, parts: &[&str]) -> bool {
    let mut rest = text;
    for p in parts {
        match rest.find(p) {
            Some(i) => rest = &rest[i + p.len()..],
            None => return false,
        }
    }
    true
}

#[cfg(test)]
pub(crate) mod parity {
    //! bash の版と突き合わせる試験の道具。bash と jq が PATH に無ければ飛ばす (`DOTFILES_WIN_BASH_PARITY=1` なら落ちる。CI の Linux の job)。

    use std::io::Write;
    use std::path::{Path, PathBuf};
    use std::process::{Command, Stdio};

    /// 突き合わせを流せるか (Windows では流さない: Git Bash の bash は jq を持たず、bash の版は Linux の形)。
    pub fn available() -> bool {
        let must = std::env::var("DOTFILES_WIN_BASH_PARITY").is_ok_and(|v| v == "1");
        let found = cfg!(unix) && which("bash").is_some() && which("jq").is_some();
        if must && !found {
            panic!("DOTFILES_WIN_BASH_PARITY=1 なのに bash か jq が無い");
        }
        found
    }

    fn which(name: &str) -> Option<PathBuf> {
        let path = std::env::var_os("PATH")?;
        std::env::split_paths(&path)
            .map(|d| d.join(name))
            .find(|p| p.is_file())
    }

    /// dotfiles の repo の中のパス (`rel` は `/` 区切り)
    pub fn repo_file(rel: &str) -> PathBuf {
        let mut p = Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..");
        for seg in rel.split('/') {
            p.push(seg);
        }
        p
    }

    /// bash の script を、stdin に `input` を渡して流し、stdout を返す。`envs` は足す環境変数 (`None` は外す)。
    pub fn run_bash(
        script: &Path,
        input: &str,
        envs: &[(&str, Option<&str>)],
        cwd: Option<&Path>,
    ) -> String {
        let mut c = Command::new("bash");
        c.arg(script)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        for (k, v) in envs {
            match v {
                Some(v) => c.env(k, v),
                None => c.env_remove(k),
            };
        }
        if let Some(d) = cwd {
            c.current_dir(d);
        }
        let mut child = c.spawn().expect("bash を起こせない");
        child
            .stdin
            .take()
            .unwrap()
            .write_all(input.as_bytes())
            .unwrap();
        let out = child.wait_with_output().unwrap();
        assert_eq!(
            out.status.code(),
            Some(0),
            "{} が 0 で終わらない",
            script.display()
        );
        String::from_utf8(out.stdout).unwrap()
    }

    /// hook の stdout を比べられる形にする (JSON なら値、空なら None)。
    pub fn parsed(out: &str) -> Option<serde_json::Value> {
        if out.trim().is_empty() {
            return None;
        }
        Some(
            serde_json::from_str(out.trim()).unwrap_or_else(|e| panic!("JSON でない ({e}): {out}")),
        )
    }
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - `field` は jq の `-r '<path> // empty'` を `$(…)` で受けたのと同じ (null・false・無い・途中が object でない → 空。末尾の改行を落とす)
    //! - 答えの形 (hookSpecificOutput の中に hookEventName と、渡した項目)
    //! - 壊れた入力・知らない名前は黙る

    use super::*;
    use crate::testutil::FakeSys;
    use serde_json::json;

    #[test]
    fn field_reads_like_jq() {
        let v =
            json!({"a": {"b": "x\n\n", "f": false, "n": null, "t": true, "num": 3}, "s": "str"});
        assert_eq!(field(&v, &["a", "b"]), "x");
        assert_eq!(field(&v, &["a", "f"]), "");
        assert_eq!(field(&v, &["a", "n"]), "");
        assert_eq!(field(&v, &["a", "t"]), "true");
        assert_eq!(field(&v, &["a", "num"]), "3");
        assert_eq!(field(&v, &["a", "nope"]), "");
        assert_eq!(field(&v, &["s", "x"]), "");
        assert_eq!(field(&v, &["nope", "x"]), "");
    }

    #[test]
    fn answer_shape() {
        let a = answer("PreToolUse", &[("permissionDecision", "deny")]);
        assert!(a.ends_with('\n'));
        let v: Value = serde_json::from_str(&a).unwrap();
        assert_eq!(
            v,
            json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny"}})
        );
    }

    #[test]
    fn broken_input_and_unknown_names_are_silent() {
        let sys = FakeSys::new(|_| unreachable!());
        assert_eq!(run("run-through-nudge", "{", &sys), None);
        assert_eq!(run("no-such-hook", "{}", &sys), None);
        assert_eq!(run("run-through-nudge", "", &sys), None);
    }

    #[test]
    fn glob_in_order() {
        assert!(contains_in_order(
            "gh pr create -t x",
            &["gh", "pr", "create"]
        ));
        assert!(contains_in_order("ghXprYcreate", &["gh", "pr", "create"]));
        assert!(!contains_in_order("create pr gh", &["gh", "pr", "create"]));
    }
}
