//! status line (`dotfiles-win claude-statusline`): 1 行を stdout へ出す。Linux の `nix/files/claude/statusline-command.sh` の写しで、並び・色・文字は
//! bash の版と同じ。
//!
//! ```text
//! 📄top · <model> · <dir の名前> · <git の branch>[*] · <context の残り>% left
//! ```
//!
//! 📄top (cc-pages の会話のトップページへのリンク) は、session_id が英数字と - だけで、cc-pages が PATH にあり、CC_PAGES_DISABLE が空のときだけ
//! (Windows には今 cc-pages が無いので出ない)。port は Linux で `dotfiles.ccPages.port` が null のときと同じ cc-pages の既定の 7777。

use crate::process::{CommandSpec, Sys};
use serde_json::Value;
use std::time::Duration;

/// cc-pages の port (Linux の home/modules/claude.nix が @ccPagesPort@ を埋める値の既定)
pub const CC_PAGES_PORT: u16 = 7777;

const RESET: &str = "\x1b[0m";
const C_MODEL: &str = "\x1b[2m";
const C_DIR: &str = "\x1b[2;36m";
const C_BRANCH: &str = "\x1b[2;33m";
const C_CTX: &str = "\x1b[2;32m";
const C_SEP: &str = "\x1b[2;90m";
const C_LINK: &str = "\x1b[4m";

/// jq の `tostring | gsub("[[:cntrl:]]"; " ")` (制御文字を空白に)。
fn clean(v: Option<&Value>) -> String {
    let s = match v {
        None | Some(Value::Null) | Some(Value::Bool(false)) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    };
    s.chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect()
}

/// 入力の 4 つの値 (model・cwd・残り・session_id)。入力が壊れている・途中が object でない (jq が落ちる) なら、全部が空。
fn fields(input: &str) -> [String; 4] {
    let empty = || [String::new(), String::new(), String::new(), String::new()];
    let Ok(Value::Object(top)) = serde_json::from_str::<Value>(input) else {
        return empty();
    };
    // `.a.b` は a が object でも null でもなければ jq が落ちる
    let sub = |key: &str, inner: &str| -> Result<Option<Value>, ()> {
        match top.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::Object(m)) => Ok(m.get(inner).cloned()),
            Some(_) => Err(()),
        }
    };
    let alt = |v: Option<Value>| v.filter(|x| !matches!(x, Value::Null | Value::Bool(false)));
    let (Ok(model), Ok(dir), Ok(remaining)) = (
        sub("model", "display_name"),
        sub("workspace", "current_dir"),
        sub("context_window", "remaining_percentage"),
    ) else {
        return empty();
    };
    let cwd = alt(dir).or_else(|| alt(top.get("cwd").cloned()));
    [
        clean(alt(model).as_ref()),
        clean(cwd.as_ref()),
        clean(alt(remaining).as_ref()),
        clean(alt(top.get("session_id").cloned()).as_ref()),
    ]
}

/// coreutils の basename (末尾の区切りを落とした最後の要素。区切りだけなら `/`)。Windows は `\` も区切り。
fn basename(p: &str) -> String {
    let is_sep = |c: char| c == '/' || (cfg!(windows) && c == '\\');
    let t = p.trim_end_matches(is_sep);
    if t.is_empty() {
        return if p.is_empty() {
            String::new()
        } else {
            "/".to_string()
        };
    }
    t.rsplit(is_sep).next().unwrap_or(t).to_string()
}

/// `^[0-9]+(\.[0-9]+)?$`
fn is_decimal(s: &str) -> bool {
    let (int, frac) = match s.split_once('.') {
        Some((i, f)) => (i, Some(f)),
        None => (s, None),
    };
    !int.is_empty()
        && int.bytes().all(|b| b.is_ascii_digit())
        && frac.is_none_or(|f| !f.is_empty() && f.bytes().all(|b| b.is_ascii_digit()))
}

/// status line の 1 行 (改行なし)。
pub fn line(input: &str, sys: &dyn Sys) -> String {
    let [model, cwd, remaining, session_id] = fields(input);
    let dir_name = if cwd.is_empty() {
        String::new()
    } else {
        basename(&cwd)
    };

    let mut branch = String::new();
    if !cwd.is_empty()
        && let Some(git) = sys.which("git")
    {
        let run = |args: &[&str]| -> (bool, Vec<String>) {
            let mut spec = CommandSpec::new(git.clone())
                .arg("-C")
                .arg(&cwd)
                .arg("--no-optional-locks")
                .stdout_only()
                .timeout(Duration::from_secs(10));
            for a in args {
                spec = spec.arg(a);
            }
            let r = sys.run(&spec, &mut |_| {});
            (r.code() == Some(0), r.output)
        };
        let text = |lines: Vec<String>| lines.join("\n").trim_end_matches('\n').to_string();
        if run(&["rev-parse", "--is-inside-work-tree"]).0 {
            branch = text(run(&["branch", "--show-current"]).1);
            if branch.is_empty() {
                branch = text(run(&["rev-parse", "--short", "HEAD"]).1);
            }
            if !branch.is_empty() && !text(run(&["status", "--porcelain"]).1).is_empty() {
                branch.push('*');
            }
        }
    }

    // 数でないときは出さない (bash の printf がエラーを吐かないよう、確かめてから整形するのと同じ)
    let ctx = if is_decimal(&remaining) {
        remaining
            .parse::<f64>()
            .map(|r| format!("{r:.0}% left"))
            .unwrap_or_default()
    } else {
        String::new()
    };

    let top = if !session_id.is_empty()
        && session_id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        && sys.env("CC_PAGES_DISABLE").unwrap_or_default().is_empty()
        && sys.which("cc-pages").is_some()
    {
        format!(
            "\x1b]8;;http://localhost:{CC_PAGES_PORT}/s/{session_id}/\x07{C_LINK}📄top{RESET}\x1b]8;;\x07"
        )
    } else {
        String::new()
    };

    let mut segments: Vec<String> = Vec::new();
    if !top.is_empty() {
        segments.push(top);
    }
    if !model.is_empty() {
        segments.push(format!("{C_MODEL}{model}{RESET}"));
    }
    if !dir_name.is_empty() {
        segments.push(format!("{C_DIR}{dir_name}{RESET}"));
    }
    if !branch.is_empty() {
        segments.push(format!("{C_BRANCH}{branch}{RESET}"));
    }
    if !ctx.is_empty() {
        segments.push(format!("{C_CTX}{ctx}{RESET}"));
    }
    segments.join(&format!("{C_SEP} · {RESET}"))
}

#[cfg(test)]
mod tests {
    //! ## 確かめること
    //!
    //! - model・dir の名前・branch (変更があれば *)・残りを並べる。値の無い欄は飛ばす。数でない残りは出さない
    //! - 📄top は session_id の形・cc-pages の有無・CC_PAGES_DISABLE で出し分ける
    //! - 残りの丸めは bash の printf の %.0f と同じ (ちょうど半分は偶数へ)
    //! - bash の版 (nix/files/claude/statusline-command.sh の @ccPagesPort@ を 7777 にしたもの) と同じ入力で同じ 1 行 (bash と jq と git が
    //!   ある Linux)

    use super::*;
    use crate::hooks::parity;
    use crate::process::{Exit, RunResult};
    use crate::testutil::{FakeSys, TempDir};
    use serde_json::json;
    use std::path::Path;
    use std::process::Command;

    fn no_git() -> FakeSys {
        FakeSys::new(|_| unreachable!())
    }

    #[test]
    fn joins_the_segments() {
        let sys = FakeSys::new(|c| {
            let args = c.args_lossy();
            let out = match args[3].as_str() {
                "rev-parse" if args[4] == "--is-inside-work-tree" => vec!["true".to_string()],
                "branch" => vec!["main".to_string()],
                "status" => vec![" M x".to_string()],
                _ => vec![],
            };
            RunResult {
                exit: Exit::Code(0),
                output: out,
            }
        })
        .with_program("git", "git");
        let input = json!({"model": {"display_name": "Opus"}, "workspace": {"current_dir": "/w/proj"}, "context_window": {"remaining_percentage": 42.5}, "session_id": "s-1"});
        let l = line(&input.to_string(), &sys);
        assert_eq!(
            l,
            format!(
                "{C_MODEL}Opus{RESET}{C_SEP} · {RESET}{C_DIR}proj{RESET}{C_SEP} · {RESET}{C_BRANCH}main*{RESET}{C_SEP} · {RESET}{C_CTX}42% left{RESET}"
            )
        );
        assert_eq!(line("{}", &no_git()), "");
        assert_eq!(line("not json", &no_git()), "");
        let l = line(&json!({"model": "x", "cwd": "/w/a"}).to_string(), &no_git());
        assert_eq!(l, "", "model が object でなければ jq が落ちて全部が空");
        let l = line(
            &json!({"cwd": "/w/a/", "context_window": {"remaining_percentage": "n/a"}}).to_string(),
            &no_git(),
        );
        assert_eq!(l, format!("{C_DIR}a{RESET}"));
    }

    #[test]
    fn top_link_needs_cc_pages_and_a_plain_session_id() {
        let with = FakeSys::new(|_| unreachable!()).with_program("cc-pages", "/bin/cc-pages");
        let l = line(&json!({"session_id": "abc-1"}).to_string(), &with);
        assert_eq!(
            l,
            format!("\x1b]8;;http://localhost:7777/s/abc-1/\x07{C_LINK}📄top{RESET}\x1b]8;;\x07")
        );
        assert_eq!(line(&json!({"session_id": "a/b"}).to_string(), &with), "");
        assert_eq!(
            line(&json!({"session_id": "abc"}).to_string(), &no_git()),
            ""
        );
        let off = FakeSys::new(|_| unreachable!())
            .with_program("cc-pages", "/bin/cc-pages")
            .with_env("CC_PAGES_DISABLE", "1");
        assert_eq!(line(&json!({"session_id": "abc"}).to_string(), &off), "");
    }

    #[test]
    fn rounds_like_printf() {
        for (v, want) in [
            (0.5, "0"),
            (1.5, "2"),
            (2.5, "2"),
            (99.4, "99"),
            (12.0, "12"),
        ] {
            assert_eq!(format!("{v:.0}"), want, "{v}");
        }
        assert!(is_decimal("42") && is_decimal("42.5"));
        assert!(!is_decimal("42.") && !is_decimal(".5") && !is_decimal("-1") && !is_decimal(""));
        assert_eq!(basename("/a/b/"), "b");
        assert_eq!(basename("/"), "/");
        assert_eq!(basename("rel"), "rel");
    }

    fn git(dir: &Path, args: &[&str]) {
        let ok = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_NAME", "t")
            .env("GIT_AUTHOR_EMAIL", "t@example.com")
            .env("GIT_COMMITTER_NAME", "t")
            .env("GIT_COMMITTER_EMAIL", "t@example.com")
            .output()
            .unwrap()
            .status
            .success();
        assert!(ok, "git {args:?}");
    }

    #[test]
    fn matches_bash() {
        if !parity::available() || Command::new("git").arg("--version").output().is_err() {
            return;
        }
        let t = TempDir::new("statusline-parity");
        // bash の版の @ccPagesPort@ を 7777 にした写し (Linux の home-manager が埋めるのと同じ)
        let src =
            std::fs::read_to_string(parity::repo_file("nix/files/claude/statusline-command.sh"))
                .unwrap();
        let script = t.write(
            "statusline.sh",
            &src.replace("@ccPagesPort@", &CC_PAGES_PORT.to_string()),
        );
        let repo = t.path().join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "feat/x"]);
        let detached = t.path().join("detached");
        std::fs::create_dir_all(&detached).unwrap();
        git(&detached, &["init", "-q"]);
        git(&detached, &["commit", "-q", "--allow-empty", "-m", "c"]);
        git(&detached, &["checkout", "-q", "--detach"]);
        // cc-pages の偽物 (PATH の先頭)
        let bin = t.path().join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let fake = t.write("bin/cc-pages", "#!/bin/sh\nexit 0\n");
        std::process::Command::new("chmod")
            .arg("+x")
            .arg(&fake)
            .status()
            .unwrap();
        let path_with = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap());
        let r = repo.to_string_lossy().into_owned();
        let d = detached.to_string_lossy().into_owned();
        let cases = [
            json!({"model": {"display_name": "Opus 5.5"}, "workspace": {"current_dir": r}, "context_window": {"remaining_percentage": 42.5}, "session_id": "abc-1"}),
            json!({"model": {"display_name": "M\tx"}, "cwd": r, "context_window": {"remaining_percentage": "7"}, "session_id": "a/b"}),
            json!({"workspace": {"current_dir": d}, "context_window": {"remaining_percentage": 99.5}}),
            json!({"workspace": {"current_dir": "/no/such/dir"}, "context_window": {}}),
            json!({"model": "x"}),
            json!({}),
        ];
        // 変更のある work tree (status の *)
        std::fs::write(repo.join("f"), "x").unwrap();
        for case in &cases {
            for (path, disable) in [(path_with.as_str(), None), (path_with.as_str(), Some("1"))] {
                let text = case.to_string();
                let envs = [
                    ("PATH", Some(path)),
                    ("CC_PAGES_DISABLE", disable),
                    ("GIT_CONFIG_GLOBAL", Some("/dev/null")),
                    ("GIT_CONFIG_NOSYSTEM", Some("1")),
                ];
                let bash = parity::run_bash(&script, &text, &envs, None);
                let sys = FakeSysEnv::new(&envs);
                let ours = line(&text, &sys);
                assert_eq!(ours, bash, "入力: {text} CC_PAGES_DISABLE={disable:?}");
            }
        }
    }

    /// 本物のコマンドを打ち、環境変数と PATH だけを差し替える口 (突き合わせ用)
    struct FakeSysEnv {
        envs: Vec<(String, Option<String>)>,
    }

    impl FakeSysEnv {
        fn new(envs: &[(&str, Option<&str>)]) -> Self {
            FakeSysEnv {
                envs: envs
                    .iter()
                    .map(|(k, v)| (k.to_string(), v.map(str::to_string)))
                    .collect(),
            }
        }
    }

    impl Sys for FakeSysEnv {
        fn run(&self, spec: &CommandSpec, on_line: &mut dyn FnMut(&str)) -> RunResult {
            let mut spec = spec.clone();
            for (k, v) in &self.envs {
                spec = match v {
                    Some(v) => spec.env(k, v),
                    None => spec.env_remove(k),
                };
            }
            crate::process::RealSys.run(&spec, on_line)
        }

        fn which(&self, name: &str) -> Option<std::path::PathBuf> {
            let path = self.env("PATH")?;
            std::env::split_paths(&path)
                .map(|d| d.join(name))
                .find(|p| p.is_file())
        }

        fn env(&self, name: &str) -> Option<String> {
            match self.envs.iter().find(|(k, _)| k == name) {
                Some((_, v)) => v.clone(),
                None => std::env::var(name).ok(),
            }
        }
    }
}
