//! pr-assignee-nudge (PostToolUse・PostToolUseFailure・matcher Bash): `gh pr create` が assignee を指定せずに PR を作ったとき (と、作ったあとの段で
//! 落ちたとき)、gh の認証ユーザーを Assignees に付けて確かめるよう Claude の文脈へ 1 文を差し込む。Linux の
//! `nix/files/claude/hooks/pr-assignee-nudge.sh` (dotfiles-private の ADR 039) の写し。コマンドの読み方 (heredoc の本文と引用符を外し、
//! `; & |` 改行で分け、`gh pr create` の後ろの語に `--assignee`・`-a` があるか) は bash の版の jq の式と同じ。
//!
//! 黙る場面も同じ: skill (pjp-gh-pr-create) が無い・skillOverrides で off か user-invocable-only・出力に PR の URL が無い・既存の PR を返しただけ・
//! 指定して作った。

use super::{answer, config_dir, contains_in_order, field, is_space};
use crate::process::Sys;
use serde_json::Value;

pub fn run(input: &Value, sys: &dyn Sys) -> Option<String> {
    let config = config_dir(sys)?;
    if !config
        .join("skills")
        .join("pjp-gh-pr-create")
        .join("SKILL.md")
        .is_file()
    {
        return None;
    }
    // skill を Claude が呼べない値なら黙る (読めない・壊れている・知らない値なら知らせる)
    let overridden = std::fs::read_to_string(config.join("settings.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .map(|s| field(&s, &["skillOverrides", "pjp-gh-pr-create"]))
        .unwrap_or_default();
    if overridden == "off" || overridden == "user-invocable-only" {
        return None;
    }
    let event = field(input, &["hook_event_name"]);
    if event != "PostToolUse" && event != "PostToolUseFailure" {
        return None;
    }
    if field(input, &["tool_name"]) != "Bash" {
        return None;
    }
    let cmd = field(input, &["tool_input", "command"]);
    if !contains_in_order(&cmd, &["gh", "pr", "create"]) {
        return None;
    }
    let out = output_text(input)?;
    if contains_in_order(&out, &["a pull request for branch", "already exists"]) {
        return None;
    }
    let pr_url = pr_urls(&out).pop()?;
    let state = match input.get("tool_input").and_then(|t| t.get("command")) {
        Some(Value::String(c)) => assignee_state(c),
        _ => return None,
    };
    let msg = if out.contains("pull request update failed") {
        format!(
            "[assignee] gh pr create は PR を作ったあとの段で落ちた (pull request update failed) が、PR は出来ている ({pr_url})。作り直さず、pjp-gh-pr-create skill を読み、gh pr view {pr_url} で Assignees を確かめ、空なら gh pr edit {pr_url} --add-assignee @me で付けること。"
        )
    } else if state == State::Some {
        format!(
            "[assignee] assignee を指定せずに PR を作った ({pr_url}) ので、Assignees が空かもしれない。pjp-gh-pr-create skill を読み、gh pr edit {pr_url} --add-assignee @me で gh の認証ユーザーを付け、gh pr view で確かめること。"
        )
    } else {
        return None;
    };
    Some(answer(&event, &[("additionalContext", &msg)]))
}

/// コマンドの出力 (bash の `[(.tool_response | objects | .stdout, .stderr), .error] | map(strings) | join("\n")` を `$(…)` で受けたもの)。
/// 入力が object でなければ jq が落ちる (None)。
fn output_text(input: &Value) -> Option<String> {
    let Value::Object(top) = input else {
        return None;
    };
    let mut parts: Vec<&str> = Vec::new();
    if let Some(Value::Object(r)) = top.get("tool_response") {
        for k in ["stdout", "stderr"] {
            if let Some(Value::String(s)) = r.get(k) {
                parts.push(s);
            }
        }
    }
    if let Some(Value::String(s)) = top.get("error") {
        parts.push(s);
    }
    Some(parts.join("\n").trim_end_matches('\n').to_string())
}

/// 出力の中の PR の URL (grep -oE 'https://[^[:space:]/]+/[^[:space:]/]+/[^[:space:]/]+/pull/[0-9]+' の当たりを順に)。
fn pr_urls(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(i) = text[from..].find("https://") {
        let start = from + i;
        match pr_url_at(&text[start..]) {
            Some(len) => {
                found.push(text[start..start + len].to_string());
                from = start + len;
            }
            None => from = start + "https://".len(),
        }
    }
    found
}

/// `s` の頭が PR の URL ならその長さ。
fn pr_url_at(s: &str) -> Option<usize> {
    let mut pos = "https://".len();
    // 3 つの区切り (空白と / を含まない 1 字以上) と、その後ろの /
    for _ in 0..3 {
        let seg: usize = s[pos..]
            .chars()
            .take_while(|c| !is_space(*c) && *c != '/')
            .map(char::len_utf8)
            .sum();
        if seg == 0 || !s[pos + seg..].starts_with('/') {
            return None;
        }
        pos += seg + 1;
    }
    let rest = s[pos..].strip_prefix("pull/")?;
    let digits = rest.bytes().take_while(u8::is_ascii_digit).count();
    (digits > 0).then_some(pos + "pull/".len() + digits)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    /// gh pr create が無い (heredoc の本文にだけ書いたものなど)
    None,
    /// どの gh pr create にも指定がある
    All,
    /// 指定の無いものがある
    Some,
}

/// gh pr create の assignee の指定を見る (bash の版の jq の式と同じ読み方)。
fn assignee_state(command: &str) -> State {
    let cmd = strip_heredocs(command);
    if find_gh_pr_create(&cmd, 0).is_none() {
        return State::None;
    }
    let quoted = strip_quotes(&cmd);
    let joined = quoted.replace("\\\n", " ");
    let mut found: Vec<bool> = joined
        .split([';', '&', '|', '\n'])
        .filter_map(create_args)
        .map(|a| has_assignee(&a))
        .collect();
    if found.is_empty() {
        // 引用符の中にだけある (bash -c '…')。最初の gh pr create の後ろを、引用符を空白にして次の区切りまで読む
        if let Some((_, end)) = find_gh_pr_create(&cmd, 0) {
            let tail: String = cmd[end..]
                .chars()
                .take_while(|c| !matches!(c, ';' | '&' | '|' | '\n'))
                .map(|c| if c == '\'' || c == '"' { ' ' } else { c })
                .collect();
            found.push(has_assignee(&tail));
        }
    }
    if found.iter().all(|b| *b) {
        State::All
    } else {
        State::Some
    }
}

/// heredoc の本文 (<<EOF・<<'EOF'・<<"EOF"・<<-EOF の次の行から、終わりの印の行まで) を外す。1 行に heredoc が 2 つあれば前の 1 つだけ。
/// `<<<` (here-string) は heredoc と読まない。
fn strip_heredocs(command: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    let mut end: Option<(String, bool)> = None;
    for line in command.split('\n') {
        if let Some((mark, tabs)) = &end {
            let l = if *tabs {
                line.trim_start_matches('\t')
            } else {
                line
            };
            if l == mark {
                end = None;
            }
            continue;
        }
        out.push(line);
        end = heredoc_start(line);
    }
    out.join("\n")
}

/// 行の中の最初の heredoc の始まり (`(?:^|[^<])<<(-?)[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2`) の、終わりの印と `-` の有無。
fn heredoc_start(line: &str) -> Option<(String, bool)> {
    let b = line.as_bytes();
    let mut i = 0;
    while i + 1 < b.len() {
        if b[i] == b'<' && b[i + 1] == b'<' && (i == 0 || b[i - 1] != b'<') {
            let mut j = i + 2;
            let tabs = j < b.len() && b[j] == b'-';
            if tabs {
                j += 1;
            }
            while j < b.len() && (b[j] == b' ' || b[j] == b'\t') {
                j += 1;
            }
            let quote = (j < b.len() && (b[j] == b'\'' || b[j] == b'"')).then(|| b[j]);
            // 引用符があり、閉じが合わなければ、引用符なしとして読み直す (正規表現の後戻り。引用符は名前の頭の字にならないので外れる)
            for q in [quote, None] {
                let k = if q.is_some() { j + 1 } else { j };
                if k < b.len() && (b[k].is_ascii_alphabetic() || b[k] == b'_') {
                    let mut e = k + 1;
                    while e < b.len() && (b[e].is_ascii_alphanumeric() || b[e] == b'_') {
                        e += 1;
                    }
                    match q {
                        None => return Some((line[k..e].to_string(), tabs)),
                        Some(qc) => {
                            // 名前を短くして閉じの引用符を探す (名前の字に引用符は無いので、閉じは名前のすぐ後ろだけ)
                            if e < b.len() && b[e] == qc {
                                return Some((line[k..e].to_string(), tabs));
                            }
                        }
                    }
                }
                if quote.is_none() {
                    break;
                }
            }
        }
        i += 1;
    }
    None
}

/// '…'・"…" を中身ごと 1 語 (Q) にする。左から先に始まる方を取るので、"it's" の ' では切れない。閉じの無い引用符は字のまま。
fn strip_quotes(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let close = match c {
            '\'' => chars[i + 1..]
                .iter()
                .position(|x| *x == '\'')
                .map(|p| i + 1 + p),
            '"' => {
                let mut k = i + 1;
                let mut end = None;
                while k < chars.len() {
                    match chars[k] {
                        '"' => {
                            end = Some(k);
                            break;
                        }
                        '\\' if k + 1 < chars.len() => k += 2,
                        '\\' => break,
                        _ => k += 1,
                    }
                }
                end
            }
            _ => None,
        };
        match close {
            Some(e) => {
                out.push('Q');
                i = e + 1;
            }
            None => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

/// `from` から先の最初の `gh\s+pr\s+create` の (始まり, 終わり) (前の字は問わない)。
fn find_gh_pr_create(text: &str, from: usize) -> Option<(usize, usize)> {
    let mut i = from;
    while let Some(p) = text[i..].find("gh") {
        let start = i + p;
        if let Some(end) = match_gh_pr_create(&text[start..]) {
            return Some((start, start + end));
        }
        i = start + 1;
    }
    None
}

/// `s` の頭が `gh\s+pr\s+create` ならその長さ。
fn match_gh_pr_create(s: &str) -> Option<usize> {
    let mut pos = s.strip_prefix("gh").map(|_| 2)?;
    for word in ["pr", "create"] {
        let ws: usize = s[pos..]
            .chars()
            .take_while(|c| c.is_whitespace())
            .map(char::len_utf8)
            .sum();
        if ws == 0 || !s[pos + ws..].starts_with(word) {
            return None;
        }
        pos += ws + word.len();
    }
    Some(pos)
}

/// 単純コマンドの `gh pr create` の後ろ (`(?:^|[\s/(\x60])gh\s+pr\s+create(?<a>(?:\s.*)?)$` の a)。無ければ None。
fn create_args(simple: &str) -> Option<String> {
    let mut from = 0;
    while let Some((start, end)) = find_gh_pr_create(simple, from) {
        let before_ok = simple[..start]
            .chars()
            .next_back()
            .is_none_or(|c| c.is_whitespace() || c == '/' || c == '(' || c == '`');
        let rest = &simple[end..];
        let after_ok = rest.is_empty() || rest.chars().next().is_some_and(char::is_whitespace);
        if before_ok && after_ok {
            return Some(rest.to_string());
        }
        from = start + 1;
    }
    None
}

/// 後ろの語に assignee の指定 (`--assignee`・`--assignee=…`・`-a…` と、`-d`・`-e`・`-f`・`-w` と束ねた `-da` など) があるか。
fn has_assignee(args: &str) -> bool {
    args.split(char::is_whitespace).any(|w| {
        w == "--assignee"
            || w.starts_with("--assignee=")
            || w.strip_prefix('-')
                .map(|r| r.trim_start_matches(['d', 'e', 'f', 'w']))
                .is_some_and(|r| r.starts_with('a'))
    })
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 指定なしで作った・作ったあとの段で落ちた、で文を返し、指定して作った・既存の PR・URL の無い出力・gh pr create でないコマンドでは黙る
    //! - コマンドの読み方: heredoc の本文と引用符の中の `--assignee` を数えない・`-da` などの束ね・`bash -c '…'` の中・`/usr/bin/gh`・複数の gh pr create
    //! - skill が無い・skillOverrides で止めたマシンでは黙る
    //! - bash の版 (nix/files/claude/hooks/pr-assignee-nudge.sh) と同じ入力で同じ答え (bash と jq がある Linux)

    use super::*;
    use crate::hooks::parity;
    use crate::testutil::{FakeSys, TempDir};
    use serde_json::json;

    const URL: &str = "https://github.com/o/r/pull/12";

    fn input(event: &str, command: &str, stdout: &str) -> Value {
        let mut v = json!({
            "session_id": "s",
            "hook_event_name": event,
            "tool_name": "Bash",
            "tool_input": {"command": command}
        });
        if event == "PostToolUseFailure" {
            v["error"] = json!(stdout);
        } else {
            v["tool_response"] = json!({"stdout": stdout, "stderr": "", "interrupted": false});
        }
        v
    }

    /// skill を置いた設定の dir と、その dir を CLAUDE_CONFIG_DIR に持つ偽の口
    fn env(settings: Option<&str>) -> (TempDir, FakeSys) {
        let t = TempDir::new("pr-assignee");
        t.write(
            "claude/skills/pjp-gh-pr-create/SKILL.md",
            "---\nname: x\n---\n",
        );
        if let Some(s) = settings {
            t.write("claude/settings.json", s);
        }
        let dir = t.path().join("claude").to_string_lossy().into_owned();
        let sys = FakeSys::new(|_| unreachable!()).with_env("CLAUDE_CONFIG_DIR", &dir);
        (t, sys)
    }

    fn cases() -> Vec<Value> {
        let made = format!("{URL}\n");
        let mut v = Vec::new();
        for cmd in [
            "gh pr create -t x -b y",
            "gh pr create -t x -b y --assignee @me",
            "gh pr create --assignee=@me -t x",
            "gh pr create -da @me -t x",
            "gh pr create -w",
            "gh pr create -t 'use --assignee here' -b y",
            "gh pr create -t x -F - <<'EOF'\n--assignee @me\nEOF",
            "gh pr create -t x -F - <<-EOF\n\t-a @me\n\tEOF\necho done",
            "cd r && /usr/bin/gh pr create -t x -a @me",
            "git push && gh pr create -t x; gh pr create -t y -a @me",
            "bash -c 'gh pr create -t x'",
            "bash -c 'gh pr create -t x --assignee @me'",
            "echo 'gh pr create' > notes.txt",
            "gh pr create -t \"it's\" -b \"a \\\" b\" -a @me",
            "cat <<< 'x' && gh pr create -t x",
            "gh  pr\tcreate\\\n  --assignee @me -t x",
            "(gh pr create -t x)",
            "gh pr createx -t x",
        ] {
            v.push(input("PostToolUse", cmd, &made));
        }
        v.push(input("PostToolUse", "gh pr create -t x", "a pull request for branch \"b\" into branch \"main\" already exists:\nhttps://github.com/o/r/pull/3\n"));
        v.push(input("PostToolUse", "gh pr create -t x", "no url here\n"));
        v.push(input("PostToolUse", "gh pr create -t x", "https://github.com/o/r/issues/3\nhttps://github.com/o/r/pull/4 and https://ghe.example/a/b/pull/55\n"));
        v.push(input(
            "PostToolUseFailure",
            "gh pr create -t x -a @me",
            &format!("{URL}\npull request update failed: GraphQL: x\n"),
        ));
        v.push(input(
            "PostToolUseFailure",
            "gh pr create -t x",
            "Exit code 1\nhttps://github.com/o/r/pull/9\n",
        ));
        v.push(input("PreToolUse", "gh pr create -t x", &made));
        v.push(json!({"hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": {"command": "gh pr create"}}));
        v.push(json!({"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "gh pr create"}, "tool_response": "x https://github.com/o/r/pull/1"}));
        v.push(json!({"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": ["gh pr create"]}, "error": "https://github.com/o/r/pull/1"}));
        v
    }

    #[test]
    fn nudges_when_no_assignee() {
        let (_t, sys) = env(None);
        let says = |cmd: &str| run(&input("PostToolUse", cmd, &format!("{URL}\n")), &sys);
        let a = says("gh pr create -t x -b y").unwrap();
        let v: Value = serde_json::from_str(&a).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PostToolUse");
        assert!(
            v["hookSpecificOutput"]["additionalContext"]
                .as_str()
                .unwrap()
                .contains(URL)
        );
        assert_eq!(says("gh pr create -t x --assignee @me"), None);
        assert_eq!(says("gh pr create -da @me"), None);
        assert!(says("gh pr create -t 'use --assignee here'").is_some());
        assert!(says("gh pr create -t x -F - <<'EOF'\n--assignee @me\nEOF").is_some());
        assert!(says("bash -c 'gh pr create -t x'").is_some());
        assert_eq!(says("bash -c 'gh pr create -t x --assignee @me'"), None);
        // 引用符の中にだけあると bash -c の中として読み直すので、知らせる側に倒れる (bash の版と同じ)
        assert!(says("echo 'gh pr create' > notes.txt").is_some());
        assert_eq!(says("echo hi"), None);
        // 作ったあとで落ちた: 指定があっても知らせる
        let failed = input(
            "PostToolUseFailure",
            "gh pr create -a @me",
            &format!("{URL}\npull request update failed\n"),
        );
        let a = run(&failed, &sys).unwrap();
        assert!(
            a.contains("PostToolUseFailure") && a.contains("pull request update failed"),
            "{a}"
        );
    }

    #[test]
    fn silent_when_skill_is_missing_or_off() {
        let i = input("PostToolUse", "gh pr create -t x", &format!("{URL}\n"));
        let (_t, sys) = env(Some(
            "{\"skillOverrides\": {\"pjp-gh-pr-create\": \"off\"}}",
        ));
        assert_eq!(run(&i, &sys), None);
        let (_t, sys) = env(Some(
            "{\"skillOverrides\": {\"pjp-gh-pr-create\": \"user-invocable-only\"}}",
        ));
        assert_eq!(run(&i, &sys), None);
        let (_t, sys) = env(Some("{broken"));
        assert!(run(&i, &sys).is_some());
        let t = TempDir::new("pr-assignee-noskill");
        let sys = FakeSys::new(|_| unreachable!())
            .with_env("CLAUDE_CONFIG_DIR", &t.path().to_string_lossy());
        assert_eq!(run(&i, &sys), None);
    }

    #[test]
    fn reads_urls_like_grep() {
        assert_eq!(pr_urls("x https://github.com/o/r/pull/12 y"), vec![URL]);
        assert_eq!(
            pr_urls("https://a/b/c/pull/1https://d/e/f/pull/2"),
            vec!["https://a/b/c/pull/1", "https://d/e/f/pull/2"]
        );
        assert!(pr_urls("https://github.com/o/r/issues/1").is_empty());
        assert!(pr_urls("https://github.com/o/pull/1").is_empty());
    }

    #[test]
    fn matches_bash() {
        if !parity::available() {
            return;
        }
        let script = parity::repo_file("nix/files/claude/hooks/pr-assignee-nudge.sh");
        for settings in [
            None,
            Some("{\"skillOverrides\": {\"pjp-gh-pr-create\": \"off\"}}"),
        ] {
            let (t, sys) = env(settings);
            let dir = t.path().join("claude");
            for case in cases() {
                let text = case.to_string();
                let bash = parity::run_bash(
                    &script,
                    &text,
                    &[("CLAUDE_CONFIG_DIR", Some(&dir.to_string_lossy()))],
                    None,
                );
                let ours = run(&case, &sys).unwrap_or_default();
                assert_eq!(parity::parsed(&ours), parity::parsed(&bash), "入力: {text}");
            }
        }
    }
}
