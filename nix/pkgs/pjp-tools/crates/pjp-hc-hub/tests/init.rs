//! `pjp hub init` / `check` の結合のテスト (偽のホームの一時ディレクトリをハブにする。手元の ~/h には触らない)。
//! pjp-herdr-hub の test_hub_init.py の場面を写し、hc 版で足したもの (pjp.hub.skill・旧 herdr のハブ・CRLF・check) を足した。

mod common;

use std::path::{Path, PathBuf};
use std::process::Output;

use common::{Sandbox, TEMPLATES, link_dir, rel_path, stderr, stdout};

struct T {
    sb: Sandbox,
    hub: PathBuf,
}

impl T {
    fn new(name: &str) -> T {
        let sb = Sandbox::new(name);
        let hub = sb.home.join("h");
        T { sb, hub }
    }

    fn run(&self, args: &[&str], cwd: Option<&Path>) -> Output {
        let mut c = self.sb.hub(args);
        if let Some(d) = cwd {
            c.current_dir(d);
        }
        c.output().unwrap()
    }

    fn init(&self, args: &[&str]) -> Output {
        let mut all = vec!["init"];
        all.extend(args);
        self.run(&all, None)
    }

    fn made_in(&self, args: &[&str], cwd: Option<&Path>) -> Output {
        let mut all = vec!["init"];
        all.extend(args);
        let out = self.run(&all, cwd);
        assert_eq!(
            out.status.code(),
            Some(0),
            "stdout: {}\nstderr: {}",
            stdout(&out),
            stderr(&out)
        );
        out
    }

    fn made(&self, args: &[&str]) -> Output {
        self.made_in(args, None)
    }

    fn git(&self, dir: &Path, args: &[&str]) -> String {
        self.sb.git(dir, args)
    }

    fn commits(&self, d: &Path) -> usize {
        self.git(d, &["rev-list", "--count", "HEAD"])
            .parse()
            .unwrap()
    }

    fn config(&self, d: &Path, key: &str) -> String {
        self.git(d, &["config", "--local", "--get", key])
    }

    fn row_name(&self, d: &Path) -> String {
        self.config(d, "pjp.devtracker.repo")
    }

    fn assert_hub_files(&self, d: &Path) {
        for (rel, src) in TEMPLATES {
            assert_eq!(
                std::fs::read(rel_path(d, rel)).unwrap(),
                self.sb.template(src),
                "{rel}"
            );
        }
    }

    fn ls_files(&self, d: &Path) -> Vec<String> {
        let mut v: Vec<String> = self
            .git(d, &["ls-files"])
            .lines()
            .map(str::to_owned)
            .collect();
        v.sort();
        v
    }

    fn assert_stopped(&self, out: &Output, words: &[&str]) {
        assert_eq!(out.status.code(), Some(1), "stdout: {}", stdout(out));
        let err = stderr(out);
        assert!(err.starts_with("pjp hub init: "), "{err}");
        for w in words {
            assert!(err.contains(w), "{w} が無い: {err}");
        }
    }
}

fn sorted_templates() -> Vec<String> {
    let mut v: Vec<String> = TEMPLATES.iter().map(|(r, _)| (*r).to_owned()).collect();
    v.sort();
    v
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

// ---- 作る

#[test]
fn makes_a_hub_from_nothing() {
    let t = T::new("from-nothing");
    let out = t.made(&["--dir", &s(&t.hub)]);
    t.assert_hub_files(&t.hub);
    assert_eq!(t.row_name(&t.hub), "~/h");
    assert_eq!(t.config(&t.hub, "pjp.hub.skill"), "pjp-hc-hub");
    assert_eq!(t.commits(&t.hub), 1);
    assert_eq!(t.git(&t.hub, &["branch", "--show-current"]), "main");
    assert_eq!(t.git(&t.hub, &["status", "--porcelain"]), "");
    assert_eq!(t.ls_files(&t.hub), sorted_templates());
    let o = stdout(&out);
    for (rel, _) in TEMPLATES {
        assert!(o.contains(&format!("書いた: {rel}")), "{o}");
    }
    assert!(
        o.contains("git config pjp.hub.skill = pjp-hc-hub を付けた"),
        "{o}"
    );
    // 作り済みの worktree は直さない、と添える
    assert!(o.lines().last().unwrap().contains("worktree"), "{o}");
    // 書いたファイルの改行は LF
    for (rel, _) in TEMPLATES {
        assert!(
            !std::fs::read(rel_path(&t.hub, rel))
                .unwrap()
                .contains(&b'\r')
        );
    }
}

#[test]
fn default_dir_is_home_h() {
    let t = T::new("default-dir");
    t.made(&[]);
    t.assert_hub_files(&t.hub);
    assert_eq!(t.row_name(&t.hub), "~/h");
}

#[test]
fn relative_dir_is_made_absolute() {
    let t = T::new("relative-dir");
    t.made_in(&["--dir", "./h/"], Some(&t.sb.home));
    assert_eq!(t.row_name(&t.hub), "~/h");
}

#[test]
fn dir_outside_home_uses_the_absolute_path() {
    let t = T::new("outside-home");
    let d = t.sb.root.join("hub");
    t.made(&["--dir", &s(&d)]);
    assert_eq!(t.row_name(&d), s(&d));
}

#[test]
fn dir_that_is_a_link_keeps_the_given_name() {
    let t = T::new("link-dir");
    let real = t.sb.root.join("disk").join("h");
    std::fs::create_dir_all(&real).unwrap();
    link_dir(&t.hub, &real);
    t.made(&[]);
    t.assert_hub_files(&real);
    assert_eq!(t.row_name(&t.hub), "~/h");
}

#[test]
fn existing_git_repo_without_remote_becomes_a_hub() {
    // ユーザーが先に git init だけしていた ~/h もハブにする
    let t = T::new("existing-repo");
    t.sb.init_repo(&t.hub, false, None);
    t.made(&[]);
    assert_eq!(t.commits(&t.hub), 1);
    assert_eq!(t.row_name(&t.hub), "~/h");
}

#[test]
fn settings_local_json_is_allowed_and_ignored() {
    // Claude Code がこの場所の許可を書いた .claude/settings.local.json は雛形の外と数えず、commit にも入れない
    let t = T::new("settings-local");
    t.sb.write(
        &t.hub.join(".claude").join("settings.local.json"),
        "{\"permissions\": {}}\n",
    );
    t.made(&[]);
    assert!(
        !t.ls_files(&t.hub)
            .contains(&".claude/settings.local.json".to_owned())
    );
    assert_eq!(t.git(&t.hub, &["status", "--porcelain"]), "");
}

#[test]
fn commit_is_not_signed_even_if_config_asks() {
    let t = T::new("no-sign");
    std::fs::write(
        &t.sb.gitconfig,
        "[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = false\n",
    )
    .unwrap();
    t.made(&[]);
    assert_eq!(t.commits(&t.hub), 1);
}

#[test]
fn global_ignore_of_dot_claude_does_not_drop_the_hook_settings() {
    // 全体の ignore に .claude/ があるマシンでも .claude/settings.json を commit する (無いと worktree で hook が効かない)
    let t = T::new("global-ignore");
    let ignore = t.sb.root.join("global-ignore");
    std::fs::write(&ignore, ".claude/\n").unwrap();
    std::fs::write(
        &t.sb.gitconfig,
        format!(
            "[core]\n\texcludesFile = {}\n",
            s(&ignore).replace('\\', "/")
        ),
    )
    .unwrap();
    t.made(&[]);
    assert_eq!(t.ls_files(&t.hub), sorted_templates());
}

#[test]
fn global_pre_commit_hook_does_not_stop_the_commit() {
    let t = T::new("pre-commit");
    let hooks = t.sb.root.join("hooks");
    let hook = hooks.join("pre-commit");
    t.sb.write(&hook, "#!/bin/sh\nexit 1\n");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    std::fs::write(
        &t.sb.gitconfig,
        format!("[core]\n\thooksPath = {}\n", s(&hooks).replace('\\', "/")),
    )
    .unwrap();
    t.made(&[]);
    assert_eq!(t.commits(&t.hub), 1);
}

#[test]
fn commits_with_a_fallback_name_when_git_has_none() {
    // dotfiles の runner が、git の名前とメールを決める前の Windows で打っても止まらない
    let t = T::new("no-identity");
    std::fs::write(&t.sb.gitconfig, "[user]\n\tuseConfigOnly = true\n").unwrap();
    let mut c = t.sb.hub(&["init"]);
    for k in [
        "GIT_AUTHOR_NAME",
        "GIT_AUTHOR_EMAIL",
        "GIT_COMMITTER_NAME",
        "GIT_COMMITTER_EMAIL",
        "EMAIL",
    ] {
        c.env_remove(k);
    }
    let out = c.output().unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    assert!(
        stdout(&out).contains("pjp hub init の名前で"),
        "{}",
        stdout(&out)
    );
    assert_eq!(
        t.git(&t.hub, &["log", "-1", "--format=%an <%ae>"]),
        "pjp hub init <pjp-hub@localhost>"
    );
}

#[test]
fn tilde_in_dir_is_expanded() {
    // --dir=~/h の ~ は shell が展開しない (PowerShell の '~/h' も)。cwd の下に ~ という名前のディレクトリを作らない
    let t = T::new("tilde");
    for args in [&["--dir=~/h"][..], &["--dir", "~/h"]] {
        t.made_in(args, Some(&t.sb.home));
        assert!(!t.sb.home.join("~").exists());
        assert_eq!(t.row_name(&t.hub), "~/h");
    }
}

#[test]
fn worktree_of_the_hub_has_the_files() {
    // herdr-app の New worktree が切る worktree にも、commit した決まりのファイルが入る
    let t = T::new("worktree-files");
    t.made(&[]);
    let wt =
        t.sb.home
            .join(".herdr")
            .join("worktrees")
            .join("h")
            .join("rapid-stone");
    t.git(
        &t.hub,
        &["worktree", "add", "-q", "-b", "rapid-stone", &s(&wt)],
    );
    t.assert_hub_files(&wt);
    assert_eq!(t.row_name(&wt), "~/h"); // .git/config を共有する
    assert_eq!(t.config(&wt, "pjp.hub.skill"), "pjp-hc-hub");
}

// ---- 打ち直す

#[test]
fn second_run_changes_nothing() {
    let t = T::new("second-run");
    t.made(&[]);
    let mtimes = |t: &T| -> Vec<std::time::SystemTime> {
        TEMPLATES
            .iter()
            .map(|(rel, _)| {
                std::fs::metadata(rel_path(&t.hub, rel))
                    .unwrap()
                    .modified()
                    .unwrap()
            })
            .collect()
    };
    let before = mtimes(&t);
    let out = t.made(&[]);
    assert_eq!(t.commits(&t.hub), 1);
    assert_eq!(mtimes(&t), before);
    assert!(stdout(&out).contains("差は無い"), "{}", stdout(&out));
}

#[test]
fn crlf_checkout_counts_as_the_same() {
    // core.autocrlf=true の Windows の git が CRLF で出したファイルは、書き直さない
    let t = T::new("crlf");
    t.made(&[]);
    let path = t.hub.join("CLAUDE.md");
    let crlf = String::from_utf8(t.sb.template("CLAUDE.md"))
        .unwrap()
        .replace('\n', "\r\n");
    std::fs::write(&path, &crlf).unwrap();
    let out = t.made(&[]);
    let o = stdout(&out);
    assert!(o.contains("同じ: CLAUDE.md"), "{o}");
    assert!(o.contains("commit するものは無い"), "{o}");
    assert_eq!(t.commits(&t.hub), 1, "{o}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), crlf);
    let check = t.run(&["check"], None);
    assert_eq!(check.status.code(), Some(0), "{}", stdout(&check));
}

#[test]
fn crlf_file_stays_lf_in_head_when_another_file_is_committed() {
    // パスを渡す commit は作業ツリーから入れ直すので、CRLF の「同じ」ファイルが一緒に CRLF で commit されないこと
    let t = T::new("crlf-mixed");
    t.made(&[]);
    std::fs::write(t.hub.join(".gitignore"), "# 古い雛形\n").unwrap();
    t.git(&t.hub, &["commit", "-q", "-am", "old"]);
    let crlf = String::from_utf8(t.sb.template("CLAUDE.md"))
        .unwrap()
        .replace('\n', "\r\n");
    std::fs::write(t.hub.join("CLAUDE.md"), &crlf).unwrap();
    t.made(&[]);
    assert_eq!(t.commits(&t.hub), 3);
    assert_eq!(
        t.git(&t.hub, &["show", "--name-only", "--format=", "HEAD"]),
        ".gitignore"
    );
    let head_claude = t.git(&t.hub, &["cat-file", "blob", "HEAD:CLAUDE.md"]);
    assert!(!head_claude.contains('\r'));
}

#[test]
fn rewrites_only_what_differs() {
    let t = T::new("rewrite");
    t.made(&[]);
    std::fs::write(t.hub.join("CLAUDE.md"), "# 古い雛形\n").unwrap();
    t.git(&t.hub, &["commit", "-q", "-am", "old"]);
    t.made(&[]);
    t.assert_hub_files(&t.hub);
    assert_eq!(t.commits(&t.hub), 3);
    assert_eq!(
        t.git(&t.hub, &["show", "--name-only", "--format=", "HEAD"]),
        "CLAUDE.md"
    );
}

#[test]
fn other_files_in_the_hub_are_left_alone() {
    // ハブになった後に会話が残したファイルは、stage されていても消しも commit もしない (会話の終わりに git status で見る)
    let t = T::new("other-files");
    t.made(&[]);
    std::fs::write(t.hub.join("CLAUDE.md"), "# 古い雛形\n").unwrap();
    t.git(&t.hub, &["commit", "-q", "-am", "old"]);
    std::fs::write(t.hub.join("stray.md"), "x\n").unwrap();
    t.git(&t.hub, &["add", "stray.md"]);
    t.made(&[]);
    assert_eq!(t.git(&t.hub, &["status", "--porcelain"]), "A  stray.md");
    assert_eq!(
        t.git(&t.hub, &["show", "--name-only", "--format=", "HEAD"]),
        "CLAUDE.md"
    );
}

#[test]
fn a_different_row_name_is_kept() {
    let t = T::new("row-kept");
    t.made(&[]);
    t.git(&t.hub, &["config", "pjp.devtracker.repo", "hub"]);
    let out = t.made(&[]);
    assert_eq!(t.row_name(&t.hub), "hub");
    assert!(
        stdout(&out).contains("pjp.devtracker.repo = hub"),
        "{}",
        stdout(&out)
    );
}

// ---- check

#[test]
fn check_on_a_clean_hub_is_0() {
    let t = T::new("check-clean");
    t.made(&[]);
    for args in [&["init", "--check"][..], &["check"]] {
        let out = t.run(args, None);
        assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
        assert!(stdout(&out).contains("差は無い"), "{}", stdout(&out));
    }
}

#[test]
fn check_reports_differences_without_writing() {
    let t = T::new("check-diffs");
    t.made(&[]);
    std::fs::write(t.hub.join("CLAUDE.md"), "# 手で直した\n").unwrap();
    t.git(&t.hub, &["config", "--unset", "pjp.devtracker.repo"]);
    let out = t.run(&["check"], None);
    assert_eq!(out.status.code(), Some(1));
    let o = stdout(&out);
    assert!(o.contains("CLAUDE.md"), "{o}");
    assert!(o.contains("pjp.devtracker.repo"), "{o}");
    assert_eq!(
        std::fs::read_to_string(t.hub.join("CLAUDE.md")).unwrap(),
        "# 手で直した\n"
    );
    assert_eq!(t.commits(&t.hub), 1);
}

#[test]
fn check_reports_uncommitted_template_files() {
    // 中身は雛形どおりでも、commit されていなければ worktree に入らないので差と数える
    let t = T::new("check-uncommitted");
    t.made(&[]);
    std::fs::write(t.hub.join("CLAUDE.md"), "# 古い雛形\n").unwrap();
    t.git(&t.hub, &["commit", "-q", "-am", "old"]);
    std::fs::write(t.hub.join("CLAUDE.md"), t.sb.template("CLAUDE.md")).unwrap();
    let out = t.run(&["check"], None);
    assert_eq!(out.status.code(), Some(1));
    assert!(stdout(&out).contains("commit"), "{}", stdout(&out));
    assert_eq!(t.commits(&t.hub), 2);
}

#[test]
fn check_sees_template_files_missing_from_head() {
    // 作業ツリーには雛形どおりあっても、HEAD に無ければ worktree に入らない (全体の ignore で add されなかったなど)
    let t = T::new("check-missing-head");
    let ignore = t.sb.root.join("global-ignore");
    std::fs::write(&ignore, ".claude/\n").unwrap();
    std::fs::write(
        &t.sb.gitconfig,
        format!(
            "[core]\n\texcludesFile = {}\n",
            s(&ignore).replace('\\', "/")
        ),
    )
    .unwrap();
    t.sb.init_repo(&t.hub, false, None);
    for (rel, src) in TEMPLATES {
        t.sb.write(&rel_path(&t.hub, rel), t.sb.template(src));
    }
    t.git(&t.hub, &["config", "pjp.devtracker.repo", "~/h"]);
    t.git(&t.hub, &["config", "pjp.hub.skill", "pjp-hc-hub"]);
    t.git(&t.hub, &["add", "CLAUDE.md", ".gitignore"]);
    t.git(&t.hub, &["commit", "-q", "-m", "without settings.json"]);
    let out = t.run(&["check"], None);
    assert_eq!(out.status.code(), Some(1), "{}", stdout(&out));
    assert!(
        stdout(&out).contains(".claude/settings.json"),
        "{}",
        stdout(&out)
    );
}

#[test]
fn check_on_a_missing_dir_is_1_and_makes_nothing() {
    let t = T::new("check-missing");
    let out = t.run(&["check"], None);
    assert_eq!(out.status.code(), Some(1));
    assert!(!t.hub.exists());
}

// ---- 止まる (何も書かない)

#[test]
fn stops_inside_another_repo() {
    let t = T::new("inside-repo");
    let repo = t.sb.root.join("repo");
    t.sb.init_repo(&repo, false, None);
    std::fs::create_dir_all(repo.join("h2")).unwrap();
    for d in [repo.join("h"), repo.join("h2")] {
        t.assert_stopped(&t.init(&["--dir", &s(&d)]), &[&s(&repo)]);
    }
    assert!(!repo.join("h").exists());
    assert_eq!(std::fs::read_dir(repo.join("h2")).unwrap().count(), 0);
}

#[test]
fn stops_inside_a_git_directory() {
    let t = T::new("inside-git-dir");
    let repo = t.sb.root.join("repo");
    t.sb.init_repo(&repo, false, None);
    let d = repo.join(".git").join("h");
    t.assert_stopped(&t.init(&["--dir", &s(&d)]), &["git のディレクトリ"]);
    assert!(!d.exists());
}

#[test]
fn stops_on_a_repo_with_a_remote() {
    let t = T::new("remote");
    t.sb.init_repo(&t.hub, false, Some("https://github.com/o/r.git"));
    t.assert_stopped(&t.init(&[]), &["remote"]);
    assert!(!t.hub.join("CLAUDE.md").exists());
}

#[test]
fn stops_on_a_hub_worktree() {
    let t = T::new("hub-worktree");
    t.made(&[]);
    let wt =
        t.sb.home
            .join(".herdr")
            .join("worktrees")
            .join("h")
            .join("rapid-stone");
    t.git(
        &t.hub,
        &["worktree", "add", "-q", "-b", "rapid-stone", &s(&wt)],
    );
    t.assert_stopped(&t.init(&["--dir", &s(&wt)]), &["worktree"]);
}

#[test]
fn stops_on_foreign_files() {
    let t = T::new("foreign");
    std::fs::create_dir_all(t.hub.join("sub")).unwrap();
    std::fs::write(t.hub.join("notes.md"), "x\n").unwrap();
    std::fs::create_dir_all(t.hub.join(".claude").join("commands")).unwrap();
    let out = t.init(&[]);
    t.assert_stopped(&out, &["notes.md", "sub", ".claude/commands"]);
    assert!(!t.hub.join(".git").exists());
    assert!(!t.hub.join("CLAUDE.md").exists());
}

#[test]
fn stops_on_a_different_claude_md_before_it_is_a_hub() {
    let t = T::new("different-claude-md");
    t.sb.write(&t.hub.join("CLAUDE.md"), "# 自分で書いた\n");
    t.assert_stopped(&t.init(&[]), &["CLAUDE.md"]);
    assert_eq!(
        std::fs::read_to_string(t.hub.join("CLAUDE.md")).unwrap(),
        "# 自分で書いた\n"
    );
    assert!(!t.hub.join(".git").exists());
}

#[test]
fn stops_on_a_herdr_hub() {
    // pjp-herdr-hub の hub-init.sh が作った旧 herdr のハブ (pjp.hub.skill が無い) を、hc 版の雛形で書き換えない
    let t = T::new("herdr-hub");
    t.sb.init_repo(&t.hub, true, None);
    t.git(&t.hub, &["config", "pjp.devtracker.repo", "~/h"]);
    let out = t.init(&[]);
    t.assert_stopped(
        &out,
        &[
            "pjp-herdr-hub",
            "bootstrap-herdr-hub",
            "git -C",
            "pjp.hub.skill pjp-hc-hub",
        ],
    );
    assert_eq!(
        std::fs::read_to_string(t.hub.join("CLAUDE.md")).unwrap(),
        "x\n"
    );
    let check = t.run(&["check"], None);
    assert_eq!(check.status.code(), Some(1));
    assert!(
        stdout(&check).contains("pjp-herdr-hub"),
        "{}",
        stdout(&check)
    );

    // hc 版に移すと決めたら、設定を付けて打ち直す
    t.git(&t.hub, &["config", "pjp.hub.skill", "pjp-hc-hub"]);
    t.made(&[]);
    t.assert_hub_files(&t.hub);
}

#[test]
fn stops_on_a_hub_of_another_skill() {
    let t = T::new("other-skill");
    t.sb.init_repo(&t.hub, true, None);
    t.git(&t.hub, &["config", "pjp.devtracker.repo", "~/h"]);
    t.git(&t.hub, &["config", "pjp.hub.skill", "pjp-x-hub"]);
    t.assert_stopped(&t.init(&[]), &["pjp-x-hub"]);
}

#[test]
fn stops_on_a_file() {
    let t = T::new("file");
    t.sb.write(&t.hub, "x\n");
    t.assert_stopped(&t.init(&[]), &["ディレクトリでない"]);
}

// ---- 引数

#[test]
fn usage() {
    let t = T::new("usage");
    for args in [
        &["init", "--bogus"][..],
        &["init", "--dir"],
        &["nope"],
        &["hello", "x"],
    ] {
        let out = t.run(args, None);
        assert_eq!(out.status.code(), Some(2), "{args:?}");
        assert!(
            stderr(&out).contains("使い方"),
            "{args:?}: {}",
            stderr(&out)
        );
    }
    for args in [&["init", "-h"][..], &["--help"], &[]] {
        let out = t.run(args, None);
        assert_eq!(out.status.code(), Some(0), "{args:?}");
        assert!(stdout(&out).contains("使い方"), "{args:?}");
    }
}

#[test]
fn without_git_is_a_config_error() {
    let t = T::new("no-git");
    let empty = t.sb.root.join("empty-path");
    std::fs::create_dir_all(&empty).unwrap();
    let out = t.sb.hub(&["init"]).env("PATH", &empty).output().unwrap();
    assert_eq!(out.status.code(), Some(2), "{}", stderr(&out));
    assert!(stderr(&out).contains("git"), "{}", stderr(&out));
    assert!(!t.hub.exists());
}

// ---- Windows のパス

#[cfg(windows)]
#[test]
fn windows_dir_case_and_slashes_are_the_same_hub() {
    // Windows はパスの大文字小文字を区別しない。git が返す C:/… の形とも同じハブとみる
    let t = T::new("win-case");
    t.made(&[]);
    let upper = s(&t.hub).to_uppercase().replace('\\', "/");
    let out = t.made(&["--dir", &upper]);
    assert!(stdout(&out).contains("差は無い"), "{}", stdout(&out));
    assert_eq!(t.commits(&t.hub), 1);
}

// ---- 雛形の重ね (private な足し分の skill pjp-hc-hub-private の settings.overlay.json)

/// 偽のホームに重ねのファイルを置く。
fn put_overlay(t: &T, text: &str) -> PathBuf {
    let p = pjp_hc_hub::templates::overlay_path(&t.sb.home);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(&p, text).unwrap();
    p
}

fn settings_of(d: &Path) -> serde_json::Value {
    serde_json::from_str(&std::fs::read_to_string(d.join(".claude").join("settings.json")).unwrap())
        .unwrap()
}

#[test]
fn without_overlay_the_settings_have_no_skill_overrides() {
    let t = T::new("overlay-none");
    t.made(&[]);
    let v = settings_of(&t.hub);
    assert!(v.get("skillOverrides").is_none(), "{v}");
    assert!(v.get("hooks").is_some(), "{v}");
}

#[test]
fn overlay_puts_skill_overrides_after_the_hooks_in_the_old_form() {
    // 重ねた settings.json は、前の雛形 (skillOverrides を雛形に書いていた形) と同じバイト列になる (作り済みのハブを書き直さない)
    let t = T::new("overlay-form");
    put_overlay(
        &t,
        "{\n  \"skillOverrides\": {\n    \"pjp-b\": \"on\",\n    \"pjp-a\": \"on\"\n  }\n}\n",
    );
    t.made(&[]);
    let written = std::fs::read_to_string(t.hub.join(".claude").join("settings.json")).unwrap();
    let base = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("assets")
            .join("hub")
            .join("settings.json"),
    )
    .unwrap()
    .replace("\r\n", "\n");
    let head = base.trim_end().strip_suffix('}').unwrap().trim_end();
    let old_form = format!(
        "{head},\n  \"skillOverrides\": {{\n    \"pjp-b\": \"on\",\n    \"pjp-a\": \"on\"\n  }}\n}}\n"
    );
    assert_eq!(written, old_form);
    let check = t.run(&["check"], None);
    assert_eq!(check.status.code(), Some(0), "{}", stdout(&check));
}

#[test]
fn check_sees_a_changed_overlay() {
    let t = T::new("overlay-check");
    put_overlay(&t, r#"{"skillOverrides": {"pjp-a": "on"}}"#);
    t.made(&[]);
    put_overlay(&t, r#"{"skillOverrides": {"pjp-a": "on", "pjp-b": "on"}}"#);
    let out = t.run(&["check"], None);
    assert_eq!(out.status.code(), Some(1), "{}", stdout(&out));
    assert!(
        stdout(&out).contains(".claude/settings.json が雛形と違う"),
        "{}",
        stdout(&out)
    );
    t.made(&[]);
    assert_eq!(settings_of(&t.hub)["skillOverrides"]["pjp-b"], "on");
    assert_eq!(t.run(&["check"], None).status.code(), Some(0));
}

#[test]
fn broken_overlay_stops_without_writing() {
    let t = T::new("overlay-broken");
    let p = put_overlay(&t, "{\"skillOverrides\": ");
    for args in [&["init"][..], &["check"][..]] {
        let out = t.run(args, None);
        assert_eq!(out.status.code(), Some(2), "{args:?} {}", stdout(&out));
        let err = stderr(&out);
        assert!(err.contains(&s(&p)), "{err}");
        assert!(err.contains("JSON として読めない"), "{err}");
    }
    assert!(!t.hub.exists());
}
