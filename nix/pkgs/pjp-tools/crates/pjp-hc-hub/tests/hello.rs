//! `pjp hub hello` の結合のテスト。ハブの見分けと雛形の行を、本物の git で作ったハブで見る (hc の行の中身は src/hello.rs の
//! 単体のテストが偽の hc で見る。ここでは PATH に hc を置かず、hc が無いときの NG を見る)。

mod common;

use std::path::{Path, PathBuf};
use std::process::Output;

use common::{Sandbox, stderr, stdout};

/// git だけが見える PATH。手元の hc (git と同じ bin にあることがある) を見せない: テストからユーザーの hc の session を
/// 読まない・見回り役を立てない。Unix は git の symlink だけを置いた bin、Windows は Git for Windows の git.exe のある所。
fn path_with_git_only(sb: &Sandbox) -> PathBuf {
    let git = pjp_core::process::find_in_path("git").expect("git が PATH に無い");
    #[cfg(unix)]
    {
        let bin = sb.root.join("bin-git-only");
        if !bin.exists() {
            std::fs::create_dir_all(&bin).unwrap();
            std::os::unix::fs::symlink(&git, bin.join("git")).unwrap();
        }
        bin
    }
    #[cfg(windows)]
    {
        let _ = sb;
        let dir = git.parent().unwrap().to_path_buf();
        assert!(
            pjp_core::process::find_in(dir.as_os_str(), "hc").is_none(),
            "git と同じ所に hc がある"
        );
        dir
    }
}

fn hello(sb: &Sandbox, cwd: &Path) -> Output {
    let mut c = sb.hub(&["hello"]);
    c.current_dir(cwd).env("PATH", path_with_git_only(sb));
    c.output().unwrap()
}

fn line<'a>(out: &'a str, starts: &str) -> &'a str {
    out.lines()
        .map(str::trim)
        .find(|l| l.starts_with(starts))
        .unwrap_or_else(|| panic!("{starts} で始まる行が無い:\n{out}"))
}

/// pjp hub init で作ったハブと、その worktree。
fn hub_and_worktree(sb: &Sandbox) -> (PathBuf, PathBuf) {
    hub_and_branch(sb, "abc-690-hello")
}

/// pjp hub init で作ったハブと、branch `branch` の worktree。
fn hub_and_branch(sb: &Sandbox, branch: &str) -> (PathBuf, PathBuf) {
    let hub = sb.home.join("h");
    let out = sb.hub(&["init"]).output().unwrap();
    assert_eq!(out.status.code(), Some(0), "{}", stderr(&out));
    let wt = sb
        .home
        .join(".herdr")
        .join("worktrees")
        .join("h")
        .join(branch.replace('/', "-"));
    sb.git(
        &hub,
        &["worktree", "add", "-q", "-b", branch, &wt.to_string_lossy()],
    );
    (hub, wt)
}

#[test]
fn old_herdr_branch_name_is_flagged() {
    // 旧 herdr のハブの worktree/<名前> と同じ形の branch は、WSL の見回りもチケットを読みうる (spec §7.10)
    let sb = Sandbox::new("hello-branch");
    let (_, wt) = hub_and_branch(&sb, "worktree/rapid-stone");
    let o = stdout(&hello(&sb, &wt));
    assert!(
        line(&o, "ok  ハブ:").contains("branch worktree/rapid-stone"),
        "{o}"
    );
    assert!(line(&o, "!!  ハブ:").contains("WSL の見回り"), "{o}");
}

#[test]
fn in_a_hub_worktree() {
    let sb = Sandbox::new("hello-worktree");
    let (_, wt) = hub_and_worktree(&sb);
    let out = hello(&sb, &wt);
    let o = stdout(&out);
    let hub = line(&o, "ok  ハブ:");
    assert!(hub.contains("branch abc-690-hello"), "{hub}");
    assert!(hub.contains("Repositories の行 ~/h"), "{hub}");
    assert!(
        line(&o, "ok  雛形:").contains("この worktree も雛形どおり"),
        "{o}"
    );
    // hc が無いと NG (ハブの会話は hc の端末で動く)
    assert!(line(&o, "NG  hc:").contains("PATH にありません"), "{o}");
    assert_eq!(out.status.code(), Some(1), "{o}");
    assert!(o.trim_end().ends_with("NG が 1 件あります。"), "{o}");
}

#[test]
fn in_the_main_checkout() {
    let sb = Sandbox::new("hello-main");
    let (hub, _) = hub_and_worktree(&sb);
    let out = hello(&sb, &hub);
    let o = stdout(&out);
    assert!(line(&o, "!!  ハブ:").contains("main の checkout"), "{o}");
    assert!(line(&o, "ok  雛形:").contains("は雛形どおり"), "{o}");
}

#[test]
fn outside_a_hub() {
    let sb = Sandbox::new("hello-outside");
    let plain = sb.root.join("plain");
    std::fs::create_dir_all(&plain).unwrap();
    let out = hello(&sb, &plain);
    let o = stdout(&out);
    assert!(line(&o, "NG  ハブ:").contains("ハブの外"), "{o}");
    assert!(!o.contains("雛形:"), "{o}");

    let repo = sb.root.join("repo");
    sb.init_repo(&repo, true, Some("https://github.com/o/r.git"));
    let o = stdout(&hello(&sb, &repo));
    assert!(line(&o, "NG  ハブ:").contains("remote"), "{o}");
}

#[test]
fn in_an_old_herdr_hub() {
    // hub-init.sh が作った旧 herdr のハブ (pjp.hub.skill が無い) では、雛形を見ず、見回り役も立てない
    let sb = Sandbox::new("hello-herdr");
    let hub = sb.home.join("h");
    sb.init_repo(&hub, true, None);
    sb.git(&hub, &["config", "pjp.devtracker.repo", "~/h"]);
    let o = stdout(&hello(&sb, &hub));
    assert!(line(&o, "!!  ハブ:").contains("旧 herdr"), "{o}");
    assert!(line(&o, "--  雛形:").contains("旧 herdr"), "{o}");
}

#[test]
fn old_worktree_files_are_flagged() {
    // 雛形が変わる前に切った worktree は、hook と skillOverrides が古いまま
    let sb = Sandbox::new("hello-old-wt");
    let (_, wt) = hub_and_worktree(&sb);
    std::fs::write(wt.join(".claude").join("settings.json"), "{}\n").unwrap();
    let o = stdout(&hello(&sb, &wt));
    let old = line(&o, "!!  雛形:");
    assert!(old.contains(".claude/settings.json"), "{old}");
    assert!(!old.contains("CLAUDE.md"), "{old}");
}

#[test]
fn in_t3_code() {
    // T3 Code の会話 (HC_TERMINAL_ID が無く T3CODE_THREAD_ID がある): この端末の代わりに T3 の行を出し、見回り役は立てない
    let sb = Sandbox::new("hello-t3");
    let (hub, _) = hub_and_worktree(&sb);
    // T3 Code の worktree のスレッドの worktree (~/.t3/worktrees/h/…。branch は t3/…)
    let wt = sb
        .home
        .join(".t3")
        .join("worktrees")
        .join("h")
        .join("t3-hello");
    sb.git(
        &hub,
        &[
            "worktree",
            "add",
            "-q",
            "-b",
            "t3/hello",
            &wt.to_string_lossy(),
        ],
    );
    let t3 = sb.home.join(".claude").join("t3");
    sb.write(&t3.join("settings.json"), "{}\n");
    sb.write(&t3.join("CLAUDE.t3.md"), "# T3\n");
    sb.write(
        &sb.home.join(".t3").join("userdata").join("settings.json"),
        r#"{"providerInstances":{"claudeAgent":{"config":{"launchArgs":"--settings ~/.claude/t3/settings.json --append-system-prompt-file ~/.claude/t3/CLAUDE.t3.md"}}}}"#,
    );
    // cli は T3 の CLI (env T3CODE_CLI_PATH)。今は 2026-11-23T00:00:00Z に止める (リンクの期限と比べる)
    let t3_hello = |cwd: &Path, cli: Option<&Path>| {
        let mut c = sb.hub(&["hello"]);
        c.current_dir(cwd)
            .env("PATH", path_with_git_only(&sb))
            .env("T3CODE_THREAD_ID", "thread-it")
            .env("PJP_NOW", "2026-11-23T00:00:00Z");
        if let Some(cli) = cli {
            c.env("T3CODE_CLI_PATH", cli);
        }
        c.output().unwrap()
    };

    let out = t3_hello(&wt, None);
    let o = stdout(&out);
    assert!(line(&o, "ok  ハブ:").contains("branch t3/hello"), "{o}");
    assert!(
        line(&o, "ok  雛形:").contains("この worktree も雛形どおり"),
        "{o}"
    );
    assert_eq!(
        line(&o, "ok  T3 のスレッド:"),
        "ok  T3 のスレッド: thread-it"
    );
    assert!(!o.contains("この端末"), "{o}");
    // T3 の CLI が無ければ、T3 のリンクは見ない
    assert!(
        line(&o, "--  T3 のリンク:").contains("T3CODE_CLI_PATH"),
        "{o}"
    );
    assert_eq!(
        o.lines()
            .filter(|l| l.trim().starts_with("ok  T3 の設定:"))
            .count(),
        2,
        "{o}"
    );
    assert!(line(&o, "--  見回り役:").contains("T3"), "{o}");
    // hc が無いと NG (長い子の見張りと、Windows に無い pjp ticket の command に使う)。NG はそれだけ
    assert!(line(&o, "NG  hc:").contains("PATH にありません"), "{o}");
    assert_eq!(out.status.code(), Some(1), "{o}");
    assert!(o.trim_end().ends_with("NG が 1 件あります。"), "{o}");

    // T3 の CLI (Windows は本物と同じ .cmd) でリンク先を見る。つなぐ先 (urls) は出さない
    let cli = fake_t3_cli(
        &sb,
        r#"[{"environmentId":"e1","label":"host-a","urls":["https://host-a.example:3773/?token=s3cr3t"],"access":"full-access","linkedAt":"2026-11-22T06:06:54.611Z","expiresAt":"2026-12-22T06:06:54.611Z","lastReachedAt":"2026-11-23T00:27:40.235Z","lastError":null,"status":"reachable"}]"#,
    );
    let o = stdout(&t3_hello(&wt, Some(&cli)));
    assert_eq!(
        line(&o, "ok  T3 のリンク host-a:"),
        "ok  T3 のリンク host-a: reachable (access full-access・期限 2026-12-22 まであと 30 日)",
        "{o}"
    );
    assert!(!o.contains("s3cr3t"), "{o}");

    // main の checkout では、T3 で worktree のスレッドを作るよう促す
    let o = stdout(&t3_hello(&hub, None));
    assert!(
        line(&o, "!!  ハブ:").contains("T3 Code で worktree のスレッド"),
        "{o}"
    );
}

/// 偽の T3 の CLI。どの引数でも `json` を 1 行出す。Windows は本物 (`~/.t3/bin/t3.cmd`) と同じく .cmd、Unix は sh。
fn fake_t3_cli(sb: &Sandbox, json: &str) -> PathBuf {
    let dir = sb.root.join("t3-bin");
    #[cfg(windows)]
    {
        // cmd の echo は残りの字をそのまま出す (json に % ^ & | < > が無いこと)
        assert!(!json.contains(['%', '^', '&', '|', '<', '>']), "{json}");
        let p = dir.join("t3.cmd");
        sb.write(&p, format!("@echo off\r\necho {json}\r\n"));
        p
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert!(!json.contains('\''), "{json}");
        let p = dir.join("t3");
        sb.write(&p, format!("#!/bin/sh\nprintf '%s\\n' '{json}'\n"));
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p
    }
}

#[test]
fn hub_with_differences_is_flagged() {
    let sb = Sandbox::new("hello-diff");
    let (hub, wt) = hub_and_worktree(&sb);
    std::fs::write(hub.join("CLAUDE.md"), "# 手で直した\n").unwrap();
    let o = stdout(&hello(&sb, &wt));
    assert!(line(&o, "!!  雛形:").contains("pjp hub check"), "{o}");
}
