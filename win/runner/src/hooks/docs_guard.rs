//! docs-guard (PreToolUse・matcher Write|Edit|MultiEdit|NotebookEdit): public な repo (表に書いた pollenjp/dotfiles) の work tree の直下の docs/ に
//! 書こうとしたら止め、設計の文書を置く private な repo (pollenjp/dotfiles-private) の docs/ を返す。Linux の `nix/files/claude/hooks/docs-guard.sh`
//! (dotfiles-private の ADR 035) の写しで、判定と返す文は bash の版と同じ。
//!
//! Windows だけの違い: Claude Code は Windows のパスを `C:\…` の形で渡す (Git Bash で動かす hook にも)。`\` を `/` にしてから判定する (bash の
//! 版は `/` で始まらないパスを相対パスと読み、Windows では何も止めない)。

use super::{answer, field};
use crate::process::{CommandSpec, Sys};
use serde_json::Value;
use std::path::Path;
use std::time::Duration;

/// public な repo (origin の owner/repo。小文字) → その repo の設計の文書を置く private な repo
fn docs_home(slug: &str) -> Option<&'static str> {
    match slug {
        "pollenjp/dotfiles" => Some("pollenjp/dotfiles-private"),
        _ => None,
    }
}

/// URL の最後の 2 つを owner/repo (小文字) にする。https・ssh・scp の形・proxy の URL のどれでも (bash の origin_slug と同じ)。
pub fn origin_slug(url: &str) -> String {
    let u = url.strip_suffix('/').unwrap_or(url);
    let u = u.strip_suffix(".git").unwrap_or(u);
    let name = u.rsplit_once('/').map_or(u, |(_, n)| n);
    let rest = u.rsplit_once('/').map_or(u, |(r, _)| r);
    let owner = rest.rsplit_once(['/', ':']).map_or(rest, |(_, o)| o);
    format!("{}/{}", owner.to_lowercase(), name.to_lowercase())
}

/// jq の `tostring` を bash の `read` で受けたもの (文字列はそのまま、ほかは JSON の文。改行の後ろは read が読まない)。
fn tostring(v: Option<&Value>) -> String {
    let s = match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    };
    s.split('\n').next().unwrap_or("").to_string()
}

/// 絶対パスか (bash は `/` で始まるか。Windows はドライブ (`C:/`) と UNC (`//server`) も)。
fn is_absolute(p: &str) -> bool {
    if p.starts_with('/') {
        return true;
    }
    let b = p.as_bytes();
    cfg!(windows) && b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'/'
}

pub fn run(input: &Value, sys: &dyn Sys) -> Option<String> {
    let git = sys.which("git")?;
    let Value::Object(top) = input else {
        return None;
    };
    // `.tool_input.file_path` は tool_input が object でも null でもなければ jq が落ちる
    let tool_input = match top.get("tool_input") {
        None | Some(Value::Null) => None,
        Some(Value::Object(m)) => Some(m),
        Some(_) => return None,
    };
    let path_value = tool_input.and_then(|m| {
        [m.get("file_path"), m.get("notebook_path")]
            .into_iter()
            .flatten()
            .find(|v| !matches!(v, Value::Null | Value::Bool(false)))
    });
    let tool = field(input, &["tool_name"]);
    if !["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(&tool.as_str()) {
        return None;
    }
    let mut path = tostring(path_value);
    let mut cwd = tostring(top.get("cwd").filter(|v| !matches!(v, Value::Bool(false))));
    if cfg!(windows) {
        path = path.replace('\\', "/");
        cwd = cwd.replace('\\', "/");
    }
    if path.is_empty() {
        return None;
    }
    if !is_absolute(&path) {
        if !is_absolute(&cwd) {
            return None;
        }
        // bash の ${cwd%/} (末尾の / を 1 つだけ外す)
        path = format!("{}/{}", cwd.strip_suffix('/').unwrap_or(&cwd), path);
    }
    if !path.contains("/docs/") {
        return None;
    }
    // 在る一番近い祖先のディレクトリと、そこから先のまだ無い分
    let (mut dir, mut rest) = match path.rsplit_once('/') {
        Some((d, r)) => (d.to_string(), r.to_string()),
        None => return None,
    };
    loop {
        // Windows の `C:` は「C ドライブの今の dir」なので、ドライブの根 (`C:/`) として見る (根より上は無い)
        if cfg!(windows) && dir.len() == 2 && dir.ends_with(':') {
            dir.push('/');
            if Path::new(&dir).is_dir() {
                break;
            }
            return None;
        }
        if !dir.is_empty() && Path::new(&dir).is_dir() {
            break;
        }
        let (d, last) = dir.rsplit_once('/')?;
        rest = format!("{last}/{rest}");
        dir = d.to_string();
    }
    let git_out = |args: &[&str]| -> Option<String> {
        let mut spec = CommandSpec::new(git.clone())
            .arg("-C")
            .arg(&dir)
            .stdout_only()
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .timeout(Duration::from_secs(10));
        for a in args {
            spec = spec.arg(a);
        }
        let r = sys.run(&spec, &mut |_| {});
        (r.code() == Some(0)).then(|| r.output.join("\n").trim_end_matches('\n').to_string())
    };
    let prefix = git_out(&["rev-parse", "--show-prefix"])?;
    let rel = format!("{prefix}{rest}");
    if !rel.starts_with("docs/") {
        return None;
    }
    let url = git_out(&["remote", "get-url", "origin"])?;
    let slug = origin_slug(&url);
    let home = docs_home(&slug)?;
    let reason = format!(
        "'{path}' は public な {slug} の docs/ の中です。{slug} の設計の文書 (spec・実装計画・ADR・textbook・図) は
この repo に置かず、private な {home} の docs/ に書きます ({slug} の直下の CLAUDE.md)。

書き先: {home} の {rel}
  手元: $(ghq root)/github.com/{home} の clone から worktree を切り、その branch で書いて PR を出す
        (clone が無ければ ghq get {home})
  cloud: session に {home} を足し (add_repo)、その clone に書いて PR を出す
取れなければ書かずに、そのことをユーザーに伝える (この repo には置かない)。

Bash (cat > … など) に書き換えて回り込まない (CI の lint も、この repo に docs/ があれば落ちる)。
public な repo に置く文書が要るなら、ユーザーに聞く。"
    );
    Some(answer(
        "PreToolUse",
        &[
            ("permissionDecision", "deny"),
            ("permissionDecisionReason", &reason),
        ],
    ))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - 表の repo の直下の docs/ への Write・Edit・MultiEdit・NotebookEdit を止め、書き先 (dotfiles-private の同じ相対パス) を返す。まだ無い深い
    //!   パス・cwd から解く相対パスでも止める
    //! - docs/ の外・下の階層の docs/・表に無い repo・origin の無い repo・git の外・ほかの tool・壊れた入力では黙る
    //! - origin の URL の形によらず owner/repo で当てる
    //! - Windows の `C:\…` のパスでも止める (Windows の CI)
    //! - bash の版 (nix/files/claude/hooks/docs-guard.sh) と同じ入力で同じ答え (bash と jq と git がある Linux)

    use super::*;
    use crate::hooks::parity;
    use crate::process::RealSys;
    use crate::testutil::TempDir;
    use serde_json::json;
    use std::path::PathBuf;
    use std::process::Command;

    fn git(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env(
                "GIT_CONFIG_GLOBAL",
                if cfg!(windows) { "NUL" } else { "/dev/null" },
            )
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    }

    /// `<t>/<name>` に repo を作る (url が空なら origin を付けない)
    fn repo(t: &TempDir, name: &str, url: &str) -> PathBuf {
        let d = t.path().join(name);
        std::fs::create_dir_all(&d).unwrap();
        git(&d, &["init", "-q"]);
        if !url.is_empty() {
            git(&d, &["remote", "add", "origin", url]);
        }
        d
    }

    fn input(tool: &str, path: &str, cwd: Option<&str>) -> Value {
        let key = if tool == "NotebookEdit" {
            "notebook_path"
        } else {
            "file_path"
        };
        let mut v = json!({"session_id": "s", "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {key: path}});
        if let Some(c) = cwd {
            v["cwd"] = json!(c);
        }
        v
    }

    fn denied(out: &Option<String>) -> Option<String> {
        let v: Value = serde_json::from_str(out.as_ref()?).unwrap();
        assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PreToolUse");
        assert_eq!(v["hookSpecificOutput"]["permissionDecision"], "deny");
        Some(
            v["hookSpecificOutput"]["permissionDecisionReason"]
                .as_str()
                .unwrap()
                .to_string(),
        )
    }

    fn git_available() -> bool {
        Command::new("git").arg("--version").output().is_ok()
    }

    #[test]
    fn slugs() {
        for (url, want) in [
            (
                "https://github.com/pollenjp/dotfiles.git",
                "pollenjp/dotfiles",
            ),
            ("git@github.com:pollenjp/dotfiles.git", "pollenjp/dotfiles"),
            (
                "ssh://git@github.com/PollenJP/Dotfiles/",
                "pollenjp/dotfiles",
            ),
            (
                "http://local_proxy@127.0.0.1:1234/git/pollenjp/dotfiles",
                "pollenjp/dotfiles",
            ),
            ("foo", "foo/foo"),
        ] {
            assert_eq!(origin_slug(url), want, "{url}");
        }
    }

    #[test]
    fn denies_docs_of_the_public_repo() {
        if !git_available() {
            return;
        }
        let t = TempDir::new("docs-guard");
        let d = repo(&t, "dotfiles", "git@github.com:pollenjp/dotfiles.git");
        let other = repo(&t, "other", "https://github.com/someone/dotfiles.git");
        let ds = d.to_string_lossy().into_owned();
        let sys = RealSys;
        let r = denied(&run(
            &input("Write", &format!("{ds}/docs/superpowers/specs/x.md"), None),
            &sys,
        ))
        .unwrap();
        assert!(
            r.contains("書き先: pollenjp/dotfiles-private の docs/superpowers/specs/x.md"),
            "{r}"
        );
        assert!(denied(&run(&input("Edit", "docs/adr/a.md", Some(&ds)), &sys)).is_some());
        assert!(
            denied(&run(
                &input("NotebookEdit", &format!("{ds}/docs/n.ipynb"), None),
                &sys
            ))
            .is_some()
        );
        assert_eq!(
            run(&input("Write", &format!("{ds}/nix/docs/x.md"), None), &sys),
            None
        );
        assert_eq!(
            run(&input("Write", &format!("{ds}/docs.md"), None), &sys),
            None
        );
        assert_eq!(
            run(&input("Read", &format!("{ds}/docs/x.md"), None), &sys),
            None
        );
        let os = other.to_string_lossy();
        assert_eq!(
            run(&input("Write", &format!("{os}/docs/x.md"), None), &sys),
            None
        );
        assert_eq!(run(&input("Write", "docs/x.md", None), &sys), None);
        if cfg!(windows) {
            let win = format!("{}\\docs\\adr\\b.md", ds.replace('/', "\\"));
            let r = denied(&run(&input("Write", &win, None), &sys)).unwrap();
            assert!(r.contains("docs/adr/b.md"), "{r}");
        }
    }

    #[test]
    fn matches_bash() {
        if !parity::available() || !git_available() {
            return;
        }
        let t = TempDir::new("docs-guard-parity");
        let d = repo(&t, "dotfiles", "git@github.com:pollenjp/dotfiles.git");
        std::fs::create_dir_all(d.join("docs").join("adr")).unwrap();
        let none = repo(&t, "noorigin", "");
        let proxy = repo(
            &t,
            "proxy",
            "http://local_proxy@127.0.0.1:1/git/PollenJP/Dotfiles",
        );
        std::fs::create_dir_all(t.path().join("plain").join("docs")).unwrap();
        let ds = d.to_string_lossy().into_owned();
        let script = parity::repo_file("nix/files/claude/hooks/docs-guard.sh");
        let cases = vec![
            input("Write", &format!("{ds}/docs/superpowers/specs/x.md"), None),
            input("MultiEdit", &format!("{ds}/docs/adr/001/README.md"), None),
            input("Edit", "docs/adr/a.md", Some(&ds)),
            input("Edit", "./docs/a.md", Some(&format!("{ds}/"))),
            input("NotebookEdit", &format!("{ds}/docs/n.ipynb"), None),
            input("Write", &format!("{ds}/nix/docs/x.md"), None),
            input("Write", &format!("{ds}/docsite/x.md"), None),
            input("Write", &format!("{}/docs/x.md", none.display()), None),
            input("Write", &format!("{}/docs/x.md", proxy.display()), None),
            input(
                "Write",
                &format!("{}/plain/docs/x.md", t.path().display()),
                None,
            ),
            input("Write", "docs/x.md", None),
            input("Write", "docs/x.md", Some("relative")),
            input("Bash", &format!("{ds}/docs/x.md"), None),
            json!({"tool_name": "Write", "tool_input": "x"}),
            json!({"tool_name": "Write"}),
            json!([1]),
        ];
        let sys = RealSys;
        for case in cases {
            let text = case.to_string();
            let envs = [
                ("GIT_CONFIG_GLOBAL", Some("/dev/null")),
                ("GIT_CONFIG_NOSYSTEM", Some("1")),
            ];
            let bash = parity::run_bash(&script, &text, &envs, None);
            let ours = run(&case, &sys).unwrap_or_default();
            assert_eq!(parity::parsed(&ours), parity::parsed(&bash), "入力: {text}");
        }
    }
}
