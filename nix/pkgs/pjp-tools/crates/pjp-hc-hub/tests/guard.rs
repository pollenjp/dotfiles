//! `pjp hub guard` の結合のテスト (偽のホームに本物の git でハブ・repo・worktree を作り、hook の入力の JSON を流す)。
//! pjp-herdr-hub の test_hub_guard.py の場面を写し、hc 版で足したもの (ASCII だけの出力・BOM・Windows のパス) を足した。

mod common;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use common::{Sandbox, link_dir, stderr, stdout};
use serde_json::{Value, json};

const HUB_REASON: &str = " はハブ (pjp-hc-hub) の中。";

struct T {
    sb: Sandbox,
    hub: PathBuf,
    hub_wt: PathBuf,
    repo: PathBuf,
    repo_wt: PathBuf,
    video: PathBuf,
    scratch: PathBuf,
}

impl T {
    fn new(name: &str) -> T {
        let sb = Sandbox::new(name);
        let home = sb.home.clone();
        // ハブ: remote の無い repo と、herdr-app の New worktree が切った worktree (会話ごと)
        let hub = home.join("h");
        sb.init_repo(&hub, true, None);
        let hub_wt = home
            .join(".herdr")
            .join("worktrees")
            .join("h")
            .join("rapid-stone");
        sb.git(
            &hub,
            &["worktree", "add", "-q", "-b", "rapid-stone", &s(&hub_wt)],
        );
        // remote を持つ repo (ghq の checkout) と、その子の worktree
        let repo = home.join("ghq").join("github.com").join("o").join("r");
        sb.init_repo(&repo, true, Some("https://github.com/o/r.git"));
        let repo_wt = home
            .join(".herdr")
            .join("worktrees")
            .join("r")
            .join("silver-river");
        sb.git(
            &repo,
            &["worktree", "add", "-q", "-b", "silver-river", &s(&repo_wt)],
        );
        // remote の無い work tree (解説動画の作業場所) と、git の外
        let video = home
            .join(".local")
            .join("share")
            .join("pjp-video-explainers")
            .join("o")
            .join("r")
            .join("20261020-1200-hub");
        sb.init_repo(&video, false, None);
        let scratch = sb.root.join("scratchpad");
        std::fs::create_dir_all(&scratch).unwrap();
        T {
            sb,
            hub,
            hub_wt,
            repo,
            repo_wt,
            video,
            scratch,
        }
    }

    /// hook を 1 回流す。`project` は CLAUDE_PROJECT_DIR (None なら env から消す)。
    fn guard_with(&self, input: &[u8], project: Option<&Path>, env: &[(&str, &Path)]) -> Output {
        let mut c = self.sb.hub(&["guard"]);
        if let Some(p) = project {
            c.env("CLAUDE_PROJECT_DIR", p);
        }
        for (k, v) in env {
            c.env(k, v);
        }
        feed(c, input)
    }

    fn guard_json(&self, payload: &Value, project: Option<&Path>) -> Output {
        self.guard_with(payload.to_string().as_bytes(), project, &[])
    }

    fn payload(&self, tool: &str, key: &str, path: &str, cwd: &Path) -> Value {
        json!({
            "session_id": "s",
            "hook_event_name": "PreToolUse",
            "tool_name": tool,
            "tool_input": {key: path, "content": "x"},
            "cwd": s(cwd),
        })
    }

    /// Write を 1 回 (cwd と CLAUDE_PROJECT_DIR はハブの会話の worktree)。
    fn write(&self, path: &str) -> Output {
        let p = self.payload("Write", "file_path", path, &self.hub_wt);
        self.guard_json(&p, Some(&self.hub_wt))
    }

    fn write_path(&self, path: &Path) -> Output {
        self.write(&s(path))
    }
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn feed(mut c: Command, input: &[u8]) -> Output {
    c.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = c.spawn().unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    child.wait_with_output().unwrap()
}

/// 止めた理由 (`starts` で始まる) を返す。出力は ASCII だけの 1 行の JSON。
fn assert_denied(out: &Output, starts: &str) -> String {
    assert_eq!(out.status.code(), Some(0), "{}", stderr(out));
    let text = stdout(out);
    assert!(text.is_ascii(), "ASCII でない: {text}");
    assert_eq!(text.lines().count(), 1, "{text}");
    let v: Value = serde_json::from_str(&text).unwrap();
    let o = &v["hookSpecificOutput"];
    assert_eq!(o["hookEventName"], "PreToolUse");
    assert_eq!(o["permissionDecision"], "deny");
    let reason = o["permissionDecisionReason"].as_str().unwrap().to_owned();
    assert!(
        reason.starts_with(starts),
        "{reason}\n  が次で始まらない: {starts}"
    );
    reason
}

fn assert_allowed(out: &Output) {
    assert_eq!(
        (out.status.code(), stdout(out).as_str()),
        (Some(0), ""),
        "{}",
        stderr(out)
    );
}

// ---- ハブの中は止める

#[test]
fn hub_files_are_denied() {
    let t = T::new("hub-files");
    for p in [
        t.hub_wt.join("CLAUDE.md"), // この会話の worktree
        t.hub_wt.join("notes").join("a").join("b").join("new.md"), // まだ無いパス (最も近い既存の祖先で見る)
        t.hub.join("CLAUDE.md"),                                   // ハブの main の checkout
        t.hub.join(".git").join("config"),                         // .git の中
    ] {
        let reason = assert_denied(&t.write_path(&p), &format!("{}{HUB_REASON}", p.display()));
        assert!(reason.contains("scratchpad"), "{reason}");
        assert!(reason.contains("PowerShell"), "{reason}");
    }
}

#[test]
fn another_hub_worktree_is_denied() {
    let t = T::new("other-hub-wt");
    let other =
        t.sb.home
            .join(".herdr")
            .join("worktrees")
            .join("h")
            .join("lucky-harbor");
    t.sb.git(
        &t.hub,
        &["worktree", "add", "-q", "-b", "lucky-harbor", &s(&other)],
    );
    let p = other.join("x.md");
    assert_denied(&t.write_path(&p), &format!("{}{HUB_REASON}", p.display()));
}

#[test]
fn relative_path_is_resolved_from_cwd() {
    let t = T::new("relative");
    assert_denied(
        &t.write("draft.md"),
        &format!("{}{HUB_REASON}", t.hub_wt.join("draft.md").display()),
    );
    // 区切りが / でも、その OS の形で出す
    assert_denied(
        &t.write("notes/draft.md"),
        &format!(
            "{}{HUB_REASON}",
            t.hub_wt.join("notes").join("draft.md").display()
        ),
    );
}

#[test]
fn tilde_is_expanded() {
    let t = T::new("tilde");
    assert_denied(
        &t.write("~/h/x.md"),
        &format!("{}{HUB_REASON}", t.hub.join("x.md").display()),
    );
}

#[test]
fn cwd_is_used_without_project_dir() {
    let t = T::new("no-project-dir");
    let p = t.hub.join("x.md");
    let payload = t.payload("Write", "file_path", &s(&p), &t.hub_wt);
    assert_denied(
        &t.guard_json(&payload, None),
        &format!("{}{HUB_REASON}", p.display()),
    );
}

#[test]
fn every_writing_tool_is_checked() {
    let t = T::new("tools");
    let p = t.hub_wt.join("a.ipynb");
    for (tool, key) in [
        ("Edit", "file_path"),
        ("MultiEdit", "file_path"),
        ("NotebookEdit", "notebook_path"),
    ] {
        let payload = t.payload(tool, key, &s(&p), &t.hub_wt);
        assert_denied(
            &t.guard_json(&payload, Some(&t.hub_wt)),
            &format!("{}{HUB_REASON}", p.display()),
        );
    }
}

#[test]
fn local_settings_of_a_hub_worktree_are_allowed() {
    // worktree の頭の .claude/settings.local.json は、ハブの .gitignore が外す、Claude Code のこの場所の許可の置き場。
    // ユーザーに頼まれた許可の設定 (update-config) を止めない。ほかの .claude の中は止める
    let t = T::new("local-settings");
    std::fs::create_dir_all(t.hub_wt.join(".claude")).unwrap();
    for p in [
        t.hub_wt.join(".claude").join("settings.local.json"),
        t.hub.join(".claude").join("settings.local.json"),
    ] {
        assert_allowed(&t.write_path(&p));
    }
    for p in [
        t.hub_wt.join(".claude").join("settings.json"),
        t.hub_wt
            .join("sub")
            .join(".claude")
            .join("settings.local.json"),
    ] {
        assert_denied(&t.write_path(&p), &format!("{}{HUB_REASON}", p.display()));
    }
}

#[test]
fn path_with_spaces_and_japanese() {
    let t = T::new("japanese");
    let p = t.hub_wt.join("ハブ メモ").join("図 の下書き.md");
    let reason = assert_denied(&t.write_path(&p), &format!("{}{HUB_REASON}", p.display()));
    assert!(reason.contains("ハブ メモ"), "{reason}");
}

// ---- remote を持つ repo の中は止める

#[test]
fn repo_with_remote_is_denied() {
    let t = T::new("repo");
    for (p, top) in [
        (t.repo.join("README.md"), &t.repo),
        (t.repo_wt.join("skills").join("new.md"), &t.repo_wt),
    ] {
        let reason = assert_denied(
            &t.write_path(&p),
            &format!("{} は repo ({}) の中。", p.display(), top.display()),
        );
        assert!(reason.contains("pjp child new"), "{reason}");
        assert!(
            reason.contains("Bash・PowerShell で書いても同じ決まり"),
            "{reason}"
        );
    }
}

#[test]
fn link_into_a_repo_is_denied() {
    // ~/.claude/skills/pjp-* のように、git の外の link (Windows は junction) の先が repo の中なら止める
    let t = T::new("link");
    let skill = t.repo.join("skills").join("pjp-x");
    t.sb.write(&skill.join("SKILL.md"), "x\n");
    let link = t.sb.home.join(".claude").join("skills").join("pjp-x");
    link_dir(&link, &skill);
    for p in [
        link.join("SKILL.md"),
        link.join("references").join("new.md"),
    ] {
        assert_denied(
            &t.write_path(&p),
            &format!("{} は repo ({}) の中。", p.display(), t.repo.display()),
        );
    }
}

// ---- それ以外は通す

#[test]
fn outside_git_and_remote_less_work_trees_are_allowed() {
    let t = T::new("allowed");
    for p in [
        t.scratch.join("brief.md"),
        t.scratch.join("a").join("b").join("new.svg"),
        t.video.join("brief.md"),
        t.sb.home
            .join(".claude")
            .join("projects")
            .join("x")
            .join("memory")
            .join("a.md"),
    ] {
        assert_allowed(&t.write_path(&p));
    }
}

#[test]
fn bash_and_empty_paths_are_not_looked_at() {
    let t = T::new("bash");
    let payload = json!({
        "tool_name": "Bash",
        "tool_input": {"command": format!("echo x > {}", s(&t.hub_wt.join("x.md")))},
        "cwd": s(&t.hub_wt),
    });
    assert_allowed(&t.guard_json(&payload, Some(&t.hub_wt)));
    assert_allowed(&t.write(""));
}

#[test]
fn broken_input_is_allowed() {
    let t = T::new("broken");
    for input in [&b"not json"[..], b"", b"\xff\xfe\x00"] {
        assert_allowed(&t.guard_with(input, Some(&t.hub_wt), &[]));
    }
}

#[test]
fn input_with_a_bom_is_read() {
    // shell が UTF-8 の BOM を付けて渡しても読む
    let t = T::new("bom");
    let p = t.hub_wt.join("x.md");
    let payload = t.payload("Write", "file_path", &s(&p), &t.hub_wt);
    let mut input = b"\xef\xbb\xbf".to_vec();
    input.extend(payload.to_string().as_bytes());
    assert_denied(
        &t.guard_with(&input, Some(&t.hub_wt), &[]),
        &format!("{}{HUB_REASON}", p.display()),
    );
}

#[test]
fn arguments_do_not_turn_the_hook_into_an_error() {
    // 2 で終わると Claude Code は書き込みを全部止めるので、引数が付いても hook として動いて 0 で終わる
    let t = T::new("args");
    let p = t.hub_wt.join("x.md");
    let payload = t.payload("Write", "file_path", &s(&p), &t.hub_wt);
    let mut c = t.sb.hub(&["guard", "--bogus"]);
    c.env("CLAUDE_PROJECT_DIR", &t.hub_wt);
    let out = feed(c, payload.to_string().as_bytes());
    assert_denied(&out, &format!("{}{HUB_REASON}", p.display()));
    assert!(stderr(&out).contains("--bogus"), "{}", stderr(&out));
}

// ---- 道具が無ければ見ずに通す

#[test]
fn without_git_passes_with_a_note() {
    let t = T::new("no-git");
    let empty = t.sb.root.join("empty-path");
    std::fs::create_dir_all(&empty).unwrap();
    let p = t.hub_wt.join("x.md");
    let payload = t.payload("Write", "file_path", &s(&p), &t.hub_wt);
    let out = t.guard_with(
        payload.to_string().as_bytes(),
        Some(&t.hub_wt),
        &[("PATH", &empty)],
    );
    assert_allowed(&out);
    assert_eq!(stderr(&out).lines().count(), 1, "{}", stderr(&out));
    assert!(stderr(&out).contains("git"), "{}", stderr(&out));
}

// ---- Windows のパス

#[cfg(windows)]
#[test]
fn windows_paths_ignore_case_and_slash_style() {
    let t = T::new("win-case");
    for given in [
        s(&t.hub_wt.join("x.md")).to_uppercase(),
        s(&t.hub_wt.join("x.md")).replace('\\', "/"),
    ] {
        let out = t.write(&given);
        let reason = assert_denied(&out, "");
        assert!(reason.contains(HUB_REASON.trim()), "{reason}");
    }
    // CLAUDE_PROJECT_DIR の大文字小文字が違っても同じハブ
    let p = t.hub.join("x.md");
    let payload = t.payload("Write", "file_path", &s(&p), &t.hub_wt);
    let upper = PathBuf::from(s(&t.hub_wt).to_uppercase());
    assert_denied(
        &t.guard_json(&payload, Some(&upper)),
        &format!("{}{HUB_REASON}", p.display()),
    );
    // settings.local.json の例外も大文字小文字を見ない
    std::fs::create_dir_all(t.hub_wt.join(".claude")).unwrap();
    let local = s(&t.hub_wt.join(".claude").join("SETTINGS.LOCAL.JSON"));
    assert_allowed(&t.write(&local));
}

#[cfg(windows)]
#[test]
fn windows_git_bash_paths_are_read_as_drive_paths() {
    // Git Bash の pwd などから来た /c/Users/… を、ドライブの root からの相対 (C:\c\Users\…) と読み違えて通さない
    let t = T::new("win-msys");
    let p = s(&t.hub_wt.join("x.md"));
    let drive = p.chars().next().unwrap().to_ascii_lowercase();
    let msys = format!("/{drive}{}", p[2..].replace('\\', "/"));
    assert_denied(&t.write(&msys), &format!("{p}{HUB_REASON}"));
}
